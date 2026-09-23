import Darwin
import Foundation
import IOKit

struct MonitorResourceSnapshot: Codable {
    let timestamp: Double
    let targetPID: Int32
    /// Interval CPU; 100% is one logical CPU, so a process may exceed 100%.
    let gameCPUPercent: Double?
    let containerCPUPercent: Double?
    let systemCPUPercent: Double?
    let systemGPUPercent: Double?
    let gameGPUPercent: Double?
    let gameGPULastSubmitted: UInt64?
    let sampleIntervalSeconds: Double?
    let gameResidentBytes: UInt64?
}

/// Only the owning app's serial resource queue calls this object. The unchecked
/// conformance permits transfer to that queue, not concurrent sampling.
final class MonitorResourceSampler: @unchecked Sendable {
    struct Counter {
        let pid: Int32
        let start: UInt64
        let time: UInt64
        let cpu: UInt64
    }
    private var previous: Counter?
    private var previousHost: (busy: UInt64, total: UInt64)?
    private var timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t(); mach_timebase_info(&value); return value
    }()
    private var previousGPU: GPUReading?
    struct GPUReading {
        let pid: Int32
        let start: UInt64
        let time: UInt64
        let clients: [UInt64: UInt64]
        let lastSubmitted: UInt64
    }
    func sample(targetPID: Int32) -> MonitorResourceSnapshot {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var usage = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(targetPID, RUSAGE_INFO_V4, $0) }
        }
        // macOS27/M1Pro live 0.4s single-core probe returned ~2.4% when
        // rusage ticks were treated as ns; applying the 125/3 timebase yields
        // ~100%. Keep this hardware-tested conversion (like Dense's taskinfo).
        let cpuNS = UInt64(Double(usage.ri_user_time &+ usage.ri_system_time) * Double(timebase.numer) / Double(max(1, timebase.denom)))
        let current: Counter? = read == 0 ? .init(pid: targetPID, start: usage.ri_proc_start_abstime, time: now, cpu: cpuNS) : nil
        let percent = current.flatMap { Self.cpuPercent(previous: previous, current: $0) }
        let interval = percent != nil ? previous.map { Double(now - $0.time) / 1e9 } : nil
        previous = current
        let gpu = current.flatMap { Self.processGPU(pid: targetPID, start: $0.start, time: now) }
        let gameGPU = gpu.flatMap { Self.gpuTimePercent(previous: previousGPU, current: $0) }
        previousGPU = gpu
        let host = Self.hostTicks()
        let system = host.flatMap { next in previousHost.flatMap { Self.hostPercent(previous: $0, current: next) } }
        previousHost = host
        return .init(timestamp: Date().timeIntervalSince1970, targetPID: targetPID,
                     gameCPUPercent: percent, containerCPUPercent: nil,
                     systemCPUPercent: system, systemGPUPercent: Self.gpuPercent(), gameGPUPercent: gameGPU,
                     gameGPULastSubmitted: gpu?.lastSubmitted,
                     sampleIntervalSeconds: interval, gameResidentBytes: read == 0 ? usage.ri_resident_size : nil)
    }
    // Wine's wineserver and helpers can be reparented outside the game's
    // descendant tree. Calling that partial tree a whole "container" was
    // rejected in review. Leave it unavailable until prefix/session ownership
    // can be proven. The user's compact fallback is game process CPU only.
    // AGX AppUsage is driver-defined accounting, not a public Metal API.
    // GPU-time / wall-time is a process time share (possibly overlapping
    // queues), not a fraction to subtract from device utilization. Only valid,
    // stable client sets produce an interval; missing/reset data remains nil.
    static func gpuTimePercent(previous: GPUReading?, current: GPUReading) -> Double? {
        guard let previous, previous.pid == current.pid, previous.start == current.start,
              current.time > previous.time, current.time - previous.time <= 5_000_000_000,
              !current.clients.isEmpty, Set(previous.clients.keys) == Set(current.clients.keys) else { return nil }
        var delta = 0.0
        for (id, value) in current.clients {
            guard let old = previous.clients[id], value >= old else { return nil }
            delta += Double(value - old)
        }
        return delta * 100 / Double(current.time - previous.time)
    }
    private static func processGPU(pid: Int32, start: UInt64, time: UInt64) -> GPUReading? {
        var iterator: io_iterator_t = 0
        // User-client entries are registry children, not published services:
        // matching AGXDeviceUserClient directly returned no counters in the
        // live Metal probe even though ioreg -r -c enumerated them correctly.
        guard let match = IOServiceMatching("IOAccelerator"), IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var clients: [UInt64: UInt64] = [:], submitted: UInt64 = 0
        while true {
            let root = IOIteratorNext(iterator)
            if root == 0 { break }
            defer { IOObjectRelease(root) }
            var descendants: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &descendants) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(descendants) }
            while true {
                let service = IOIteratorNext(descendants)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                guard let rawCreator = IORegistryEntryCreateCFProperty(service, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0),
                      let creator = rawCreator.takeRetainedValue() as? String, creator.hasPrefix("pid \(pid),"),
                      let rawUsage = IORegistryEntryCreateCFProperty(service, "AppUsage" as CFString, kCFAllocatorDefault, 0),
                      let usage = rawUsage.takeRetainedValue() as? [[String: Any]], !usage.isEmpty else { continue }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
                var total: UInt64 = 0, valid = true
                for entry in usage {
                    guard let time = entry["accumulatedGPUTime"] as? NSNumber else { valid = false; break }
                    let addition = total.addingReportingOverflow(time.uint64Value)
                    guard !addition.overflow else { valid = false; break }; total = addition.partialValue
                    if let stamp = entry["lastSubmittedTime"] as? NSNumber { submitted = max(submitted, stamp.uint64Value) }
                }
                if valid { clients[id] = total }
            }
        }
        guard !clients.isEmpty else { return nil }
        return .init(pid: pid, start: start, time: time, clients: clients, lastSubmitted: submitted)
    }
    static func cpuPercent(previous: Counter?, current: Counter) -> Double? {
        guard let previous, current.pid == previous.pid, current.start == previous.start,
              current.time > previous.time, current.cpu >= previous.cpu,
              current.time - previous.time <= 5_000_000_000 else { return nil }
        return Double(current.cpu - previous.cpu) * 100 / Double(current.time - previous.time)
    }
    static func hostPercent(previous: (busy: UInt64, total: UInt64), current: (busy: UInt64, total: UInt64)) -> Double? {
        guard current.busy >= previous.busy, current.total > previous.total else { return nil }
        let busy = current.busy - previous.busy, total = current.total - previous.total
        guard busy <= total else { return nil }
        return Double(busy) * 100 / Double(total)
    }
    private static func hostTicks() -> (busy: UInt64, total: UInt64)? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: load) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = load.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        return (busy, busy + UInt64(ticks.2))
    }
    private static func gpuPercent() -> Double? {
        // Driver-defined device busy percentage, verified on this M1 Pro.
        // With multiple GPUs report the busiest device, never sum percentages.
        for serviceClass in ["IOAccelerator", "AGXAccelerator"] {
            var iterator: io_iterator_t = 0
            guard let match = IOServiceMatching(serviceClass), IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { continue }
            var busiest: Double?
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                if let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                   let stats = property.takeRetainedValue() as? [String: Any], let value = stats["Device Utilization %"] as? NSNumber {
                    let number = value.doubleValue
                    if number.isFinite, (0...100).contains(number) { busiest = max(busiest ?? 0, number) }
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
            if let busiest { return busiest }
        }
        return nil
    }
    static func fixtureChecks() -> [Bool] {
        let before = Counter(pid: 1, start: 10, time: 1_000_000_000, cpu: 2_000_000_000)
        let gpuBefore = GPUReading(pid: 1, start: 10, time: 1_000_000_000, clients: [8: 10_000_000], lastSubmitted: 1)
        return [
            gpuTimePercent(previous: gpuBefore, current: .init(pid: 1, start: 10, time: 2_000_000_000, clients: [8: 510_000_000], lastSubmitted: 2)) == 50,
            gpuTimePercent(previous: gpuBefore, current: .init(pid: 1, start: 10, time: 2_000_000_000, clients: [9: 510_000_000], lastSubmitted: 2)) == nil,
            gpuTimePercent(previous: gpuBefore, current: .init(pid: 1, start: 11, time: 2_000_000_000, clients: [8: 510_000_000], lastSubmitted: 2)) == nil,
            cpuPercent(previous: nil, current: before) == nil,
            cpuPercent(previous: before, current: .init(pid: 1, start: 10, time: 2_000_000_000, cpu: 4_500_000_000)) == 250,
            cpuPercent(previous: before, current: .init(pid: 1, start: 11, time: 2_000_000_000, cpu: 4_000_000_000)) == nil,
            cpuPercent(previous: before, current: .init(pid: 2, start: 10, time: 2_000_000_000, cpu: 4_000_000_000)) == nil,
            cpuPercent(previous: before, current: before) == nil,
            cpuPercent(previous: before, current: .init(pid: 1, start: 10, time: 2_000_000_000, cpu: 1)) == nil,
            cpuPercent(previous: before, current: .init(pid: 1, start: 10, time: 9_000_000_000, cpu: 4_000_000_000)) == nil,
            hostPercent(previous: (10, 100), current: (60, 200)) == 50,
            hostPercent(previous: (10, 100), current: (9, 200)) == nil
        ]
    }
}
