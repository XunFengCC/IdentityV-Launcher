import AppKit
import Darwin
import IOKit
import IOKit.hidsystem

private func log(_ text: String) { FileHandle.standardError.write(Data("function keys: \(text)\n".utf8)) }

/// Diagnostics go to a bounded file as well as stderr: a recurrence must be
/// attributable after the fact, and the runner's session log is short-lived.
private final class Diagnostics {
    private let handle: FileHandle?
    private var written = 0
    private let limit = 256 * 1024
    private var lastHeartbeat: UInt64 = 0
    private var lastFront: Int32 = -2
    init() {
        let directory = ("~/Library/Logs/IdentityVOnMac" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let path = "\(directory)/function-keys-\(stamp).log"
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = FileHandle(forWritingAtPath: path)
        var size = stat()
        if stat(path, &size) == 0 { written = Int(size.st_size) }
    }
    /// `heartbeat` lines are additionally suppressed unless the observed
    /// frontmost pid changed or a minute passed, so a long session stays bounded.
    func write(_ text: String, force: Bool = false, heartbeat: Bool = false, front: Int32 = -2) {
        let now = DispatchTime.now().uptimeNanoseconds
        if !force {
            if heartbeat, front == lastFront, now &- lastHeartbeat < 60_000_000_000 { return }
            if !heartbeat, now &- lastHeartbeat < 1_000_000_000 { return }
        }
        if heartbeat { lastFront = front }
        lastHeartbeat = now
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if written + data.count > limit { return }
        written += data.count
        handle?.write(data)
    }
}
private let diagnostics = Diagnostics()

private struct Identity: Codable, Equatable {
    let pid: Int32
    let seconds: UInt64
    let micros: UInt64
    static func read(_ pid: Int32) -> Self? {
        guard pid > 1 else { return nil }
        var b = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, Int32(MemoryLayout.size(ofValue: b))) == MemoryLayout.size(ofValue: b), b.pbi_uid == getuid() else { return nil }
        return .init(pid: pid, seconds: b.pbi_start_tvsec, micros: b.pbi_start_tvusec)
    }
    var isAlive: Bool { Self.read(pid) == self }
}

private func isManagedGame(_ pid: Int32) -> Bool {
    // Read argv only, never environment or keystrokes. Match the two exact
    // runner-owned Windows paths, not a substring in a shell's command line.
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var bytes = [UInt8](repeating: 0, count: 65536), size = 65536
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return false }
    let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0, argc < 4096 else { return false }
    var cursor = 4
    while cursor < size && bytes[cursor] != 0 { cursor += 1 }
    while cursor < size && bytes[cursor] == 0 { cursor += 1 }
    for _ in 0..<argc {
        let start = cursor
        while cursor < size && bytes[cursor] != 0 { cursor += 1 }
        let arg = String(decoding: bytes[start..<cursor], as: UTF8.self).replacingOccurrences(of: "/", with: "\\").lowercased()
        if arg == "c:\\games\\identityv\\dwrg.exe" || arg == "c:\\games\\identityvglobal\\dwrg.exe" { return true }
        guard cursor < size else { break }; cursor += 1
    }
    return false
}

private protocol ModeBackend: AnyObject { func read() -> Int?; func write(_ value: Int) -> Bool }
private final class HIDMode: ModeBackend {
    func read() -> Int? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOHIDSystem")
        guard entry != 0 else { return nil }; defer { IOObjectRelease(entry) }
        guard let p = IORegistryEntryCreateCFProperty(entry, "HIDParameters" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let value = (p[kIOHIDFKeyModeKey] as? NSNumber)?.intValue, (0...1).contains(value) else { return nil }
        return value
    }
    func write(_ value: Int) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else {
            diagnostics.write("F-row mode service unavailable", force: true)
            return false
        }; defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else {
            diagnostics.write("F-row mode connection unavailable", force: true)
            return false
        }
        defer { IOServiceClose(connection) }
        let set = IOHIDSetCFTypeParameter(connection, kIOHIDFKeyModeKey as CFString, NSNumber(value: value))
        let verified = read() == value
        if set != KERN_SUCCESS || !verified {
            diagnostics.write("F-row mode setter/readback failed requested=\(value) kern=\(set) verified=\(verified)", force: true)
        }
        return set == KERN_SUCCESS && verified
    }
}

private struct HIDMappingPair: Codable, Equatable {
    let source: UInt64
    let destination: UInt64
}

private struct HIDServiceMapping: Codable, Equatable {
    let registryID: UInt64
    let pairs: [HIDMappingPair]
}

private struct HIDMappingSnapshot: Codable, Equatable {
    let services: [HIDServiceMapping]
}

private struct HIDMappingJournal: Codable, Equatable {
    let original: HIDMappingSnapshot
    let applied: HIDMappingSnapshot
}

private protocol UserKeyMappingBackend: AnyObject {
    func read() -> HIDMappingSnapshot?
    func write(_ value: HIDMappingSnapshot, expecting: HIDMappingSnapshot) -> Bool
    func leasedSnapshot(from original: HIDMappingSnapshot) throws -> HIDMappingSnapshot
}

private final class HIDUserKeyMapping: UserKeyMappingBackend {
    // Services depend on their event-system client even when their own CF
    // references survive. Releasing a local client before CopyProperty caused
    // a real double-free in the read-only 2026-09-20 integration probe.
    private let system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    /* TN2450 encodes a usage as (usage page << 32) | usage. Keep both values
       derived from the SDK names: 0x4D is End, not F20. */
    private let f11Usage = UInt64(kHIDPage_KeyboardOrKeypad) << 32 | UInt64(kHIDUsage_KeyboardF11)
    private let f20Usage = UInt64(kHIDPage_KeyboardOrKeypad) << 32 | UInt64(kHIDUsage_KeyboardF20)

    private func keyboardServices() -> [(id: UInt64, service: IOHIDServiceClient)]? {
        guard let services = IOHIDEventSystemClientCopyServices(system) else { return nil }
        var result: [(id: UInt64, service: IOHIDServiceClient)] = []
        for item in services as [AnyObject] {
            let service = item as! IOHIDServiceClient
            /* The event system also returns mice, trackpads, and other HID
               services.  A non-keyboard is simply irrelevant; only a keyboard
               without a stable registry id makes a snapshot unsafe. */
            guard IOHIDServiceClientConformsTo(service,
                                               UInt32(kHIDPage_GenericDesktop),
                                               UInt32(kHIDUsage_GD_Keyboard)) != 0 else { continue }
            guard let registryID = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { return nil }
            result.append((UInt64(truncating: registryID), service))
        }
        return result.sorted { $0.id < $1.id }
    }

    private func pairs(from property: CFTypeRef?) -> [HIDMappingPair]? {
        guard let property else { return [] }
        guard let array = property as? NSArray else { return nil }
        var result: [HIDMappingPair] = []
        for object in array {
            guard let dictionary = object as? NSDictionary,
                  let source = dictionary[kIOHIDKeyboardModifierMappingSrcKey as NSString] as? NSNumber,
                  let destination = dictionary[kIOHIDKeyboardModifierMappingDstKey as NSString] as? NSNumber else { return nil }
            result.append(.init(source: source.uint64Value, destination: destination.uint64Value))
        }
        return result.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.destination < $1.destination
        }
    }

    private func property(for pairs: [HIDMappingPair]) -> CFArray {
        let values: [[String: NSNumber]] = pairs.map {
            [kIOHIDKeyboardModifierMappingSrcKey: NSNumber(value: $0.source),
             kIOHIDKeyboardModifierMappingDstKey: NSNumber(value: $0.destination)]
        }
        return values as CFArray
    }

    func read() -> HIDMappingSnapshot? {
        return withExtendedLifetime(system) {
            guard let services = keyboardServices() else { return nil }
            var result: [HIDServiceMapping] = []
            for item in services {
                let property = IOHIDServiceClientCopyProperty(item.service, kIOHIDUserKeyUsageMapKey as CFString)
                guard let pairs = pairs(from: property) else { return nil }
                result.append(.init(registryID: item.id, pairs: pairs))
            }
            return .init(services: result)
        }
    }

    /// Read-only service inventory for correlating a failed mapping write with
    /// the actual HID interface; mice may advertise keyboard services too.
    func deviceSummary() -> String? {
        return withExtendedLifetime(system) {
            guard let services = keyboardServices() else { return nil }
            return services.map { item in
                let vendor = (IOHIDServiceClientCopyProperty(item.service, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? -1
                let product = (IOHIDServiceClientCopyProperty(item.service, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? -1
                return "id=\(item.id) vendor=\(vendor) product=\(product)"
            }.joined(separator: "\n")
        }
    }

    func write(_ value: HIDMappingSnapshot, expecting expected: HIDMappingSnapshot) -> Bool {
        return withExtendedLifetime(system) {
        guard let services = keyboardServices(),
              services.map(\.id) == value.services.map(\.registryID),
              value.services.map(\.registryID) == expected.services.map(\.registryID) else {
            diagnostics.write("mapping service set changed before write", force: true)
            return false
        }
        for (row, before) in zip(value.services, expected.services) {
            // Recovery includes newly attached/externally changed services in
            // its snapshot, but must never write even identical values to them.
            guard row != before else { continue }
            guard let service = services.first(where: { $0.id == row.registryID })?.service else {
                diagnostics.write("mapping service missing id=\(row.registryID)", force: true)
                return false
            }
            // The public API has no atomic compare-and-set. Re-read immediately
            // before each setter; a detected concurrent edit retains the journal
            // so recovery can recompute its remaining per-service work.
            let current = IOHIDServiceClientCopyProperty(service, kIOHIDUserKeyUsageMapKey as CFString)
            guard pairs(from: current) == before.pairs else {
                diagnostics.write("mapping service changed id=\(row.registryID)", force: true)
                return false
            }
            guard IOHIDServiceClientSetProperty(service,
                                                kIOHIDUserKeyUsageMapKey as CFString,
                                                property(for: row.pairs)) else {
                diagnostics.write("mapping setter refused id=\(row.registryID)", force: true)
                return false
            }
        }
        let verified = read() == value
        if !verified { diagnostics.write("mapping readback mismatch after write", force: true) }
        return verified
        }
    }

    func leasedSnapshot(from original: HIDMappingSnapshot) throws -> HIDMappingSnapshot {
        guard !original.services.isEmpty else { throw Failure.unavailable }
        let reserved = Set([f11Usage, f20Usage])
        for service in original.services {
            for pair in service.pairs where reserved.contains(pair.source) || reserved.contains(pair.destination) {
                /* We cannot identify a previous owner without a journal. Do not
                   overwrite a user's F11/F20 mapping or create a collision. */
                throw Failure.invalidState
            }
        }
        let applied = original.services.map { service in
            HIDServiceMapping(registryID: service.registryID,
                              pairs: (service.pairs + [.init(source: f11Usage, destination: f20Usage)]).sorted {
                                  if $0.source != $1.source { return $0.source < $1.source }
                                  return $0.destination < $1.destination
                              })
        }
        return .init(services: applied)
    }
}

private struct Journal: Codable {
    let version: Int
    let owner: Identity
    let original: Int
    let applied: Int
    let mapping: HIDMappingJournal?

    init(version: Int, owner: Identity, original: Int, applied: Int, mapping: HIDMappingJournal? = nil) {
        self.version = version
        self.owner = owner
        self.original = original
        self.applied = applied
        self.mapping = mapping
    }
}
private enum Failure: Error { case invalidState, unavailable }

private final class Store {
    let path: String
    private var lockFD: Int32 = -1
    init(_ path: String) throws {
        self.path = path
        var b = stat()
        let parent = (path as NSString).deletingLastPathComponent
        guard path.hasPrefix("/"), !path.contains("/../"), lstat(parent, &b) == 0,
              b.st_mode & S_IFMT == S_IFDIR, b.st_uid == getuid(), b.st_mode & 0o077 == 0 else { throw Failure.invalidState }
    }
    func lock() throws -> Bool {
        if lockFD >= 0 { return true }
        let fd = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.invalidState }
        var b = stat()
        guard fstat(fd, &b) == 0, b.st_mode & S_IFMT == S_IFREG, b.st_uid == getuid(), b.st_mode & 0o077 == 0 else { close(fd); throw Failure.invalidState }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        lockFD = fd; return true
    }
    func unlock() { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 } }
    deinit { unlock() }
    func read() throws -> Journal? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw Failure.invalidState }
        defer { close(fd) }; var b = stat()
        guard fstat(fd, &b) == 0, b.st_mode & S_IFMT == S_IFREG, b.st_uid == getuid(), b.st_mode & 0o077 == 0, b.st_size > 0, b.st_size < 131072 else { throw Failure.invalidState }
        var bytes = [UInt8](repeating: 0, count: Int(b.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count else { throw Failure.invalidState }
        let value = try JSONDecoder().decode(Journal.self, from: Data(bytes))
        guard value.version == 1, (0...1).contains(value.original), value.applied == 1 else { throw Failure.invalidState }
        return value
    }
    func write(_ value: Journal) throws {
        let data = try JSONEncoder().encode(value)
        let temp = path + ".tmp." + UUID().uuidString
        let fd = open(temp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.invalidState }
        defer { close(fd); unlink(temp) }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count, fsync(fd) == 0, rename(temp, path) == 0 else { throw Failure.invalidState }
        let dir = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)
        if dir >= 0 { _ = fsync(dir); close(dir) }
    }
    func remove() throws { if unlink(path) != 0 && errno != ENOENT { throw Failure.invalidState } }
}

/* Build a restore target from the services that are present now.  UserKeyMapping
   writes are per-service and the service list can change while the game is
   running.  Restore a row only when that same service still has our exact
   applied value; preserve an external edit, leave a newly appeared service
   untouched, and naturally skip a disconnected service. */
private func mappingRecoveryTarget(current: HIDMappingSnapshot,
                                  original: HIDMappingSnapshot,
                                  applied: HIDMappingSnapshot) throws -> HIDMappingSnapshot {
    func index(_ rows: [HIDServiceMapping]) -> [UInt64: HIDServiceMapping]? {
        var result: [UInt64: HIDServiceMapping] = [:]
        for row in rows {
            guard result.updateValue(row, forKey: row.registryID) == nil else { return nil }
        }
        return result
    }
    guard let originalByID = index(original.services),
          let appliedByID = index(applied.services) else { throw Failure.invalidState }
    let currentIDs = current.services.map(\.registryID)
    guard originalByID.count == original.services.count,
          appliedByID.count == applied.services.count,
          Set(originalByID.keys) == Set(appliedByID.keys),
          Set(currentIDs).count == currentIDs.count else { throw Failure.invalidState }
    let services = current.services.map { row -> HIDServiceMapping in
        guard let originalRow = originalByID[row.registryID],
              let appliedRow = appliedByID[row.registryID],
              row.pairs == appliedRow.pairs else { return row }
        return .init(registryID: row.registryID, pairs: originalRow.pairs)
    }
    return .init(services: services)
}

private final class Lease {
    let store: Store
    let backend: ModeBackend
    let mappingBackend: UserKeyMappingBackend?
    let owner: Identity
    private(set) var held = false
    init(store: Store, backend: ModeBackend, mappingBackend: UserKeyMappingBackend? = nil, owner: Identity) {
        self.store = store
        self.backend = backend
        self.mappingBackend = mappingBackend
        self.owner = owner
    }
    /// 2026-09-18: the game was left with the F row in standard mode while it was
    /// in the background, and pressing F11/F12 outside the game did nothing.
    /// Cause: the previous session had set the mode to 1 and its journal was
    /// already gone, so the new watcher saw `held == false` and never restored
    /// anything.  This product's defined resting state is the media row, so a
    /// stale 1 with no recovery record is always our own leftover; taking
    /// ownership here is what makes `leave()` able to restore it.  An owner that
    /// is still alive is never overridden (see recover()).
    @discardableResult func claimStaleStandardRow() throws -> Bool {
        guard try store.read() == nil else { return false }
        guard let current = backend.read(), current == 1 else { return false }
        try store.write(.init(version: 1, owner: owner, original: 0, applied: 1))
        held = true
        diagnostics.write("claimed stale standard F row from a previous session", force: true)
        return true
    }
    /// Caller holds the shared lock. Never recover a different live owner.
    func recover() throws -> Bool {
        guard let journal = try store.read() else { return true }
        guard journal.owner == owner || !journal.owner.isAlive else { return false }
        guard let current = backend.read() else { throw Failure.unavailable }
        if current == journal.applied, current != journal.original,
           !backend.write(journal.original) { throw Failure.unavailable }
        if let mappingJournal = journal.mapping {
            guard let mappingBackend, let current = mappingBackend.read() else { throw Failure.unavailable }
            let target = try mappingRecoveryTarget(current: current,
                                                    original: mappingJournal.original,
                                                    applied: mappingJournal.applied)
            if target != current, !mappingBackend.write(target, expecting: current) { throw Failure.unavailable }
        }
        try store.remove(); return true
    }
    @discardableResult func enter() throws -> Bool {
        if held { return true }
        guard try store.lock() else { return false }
        do {
            guard try recover() else { store.unlock(); return false }
            guard let original = backend.read() else {
                diagnostics.write("F-row mode read unavailable before enter", force: true)
                throw Failure.unavailable
            }
            var mappingJournal: HIDMappingJournal?
            if let mappingBackend {
                guard let mappingOriginal = mappingBackend.read() else {
                    diagnostics.write("mapping snapshot unavailable before enter", force: true)
                    throw Failure.unavailable
                }
                let mappingApplied = try mappingBackend.leasedSnapshot(from: mappingOriginal)
                mappingJournal = .init(original: mappingOriginal, applied: mappingApplied)
            }
            if original == 1, mappingJournal == nil { store.unlock(); return true }
            if original != 1 { try claimStaleStandardRow() }
            // Publish recovery intent before the setter, including a process
            // start identity so PID reuse cannot block later stale recovery.
            try store.write(.init(version: 1, owner: owner, original: original, applied: 1, mapping: mappingJournal))
            held = true
            if let mappingJournal, let mappingBackend,
               !mappingBackend.write(mappingJournal.applied, expecting: mappingJournal.original) { throw Failure.unavailable }
            if original != 1, !backend.write(1) { throw Failure.unavailable }
            log("standard F1–F12 while game is foreground")
            diagnostics.write("entered standard F row", force: true)
            return true
        } catch { try? leave(); if !held { store.unlock() }; throw error }
    }
    func leave() throws {
        guard held else { return }
        guard try recover() else { throw Failure.invalidState }
        held = false; store.unlock(); log("restored previous keyboard mode")
        diagnostics.write("restored media row", force: true)
    }
}

private final class Watch {
    let target: Identity, parent: Identity, lease: Lease
    var observers: [NSObjectProtocol] = [], signals: [DispatchSourceSignal] = []
    var sleeping = false, withdrawn = false, validated = false, satisfied = false
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    init(target: Identity, parent: Identity, lease: Lease) { self.target = target; self.parent = parent; self.lease = lease }
    func finish() -> Never { do { try lease.leave() } catch { log("restore unavailable; recovery journal retained") }; exit(0) }
    func tick() {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        diagnostics.write("front=\(frontPID) target=\(target.pid) mode=\(String(describing: lease.backend.read())) held=\(lease.held) withdrawn=\(withdrawn)",
                          heartbeat: true, front: frontPID)
        guard target.isAlive, parent.isAlive else { finish() }
        if !validated {
            validated = isManagedGame(target.pid)
            if !validated { if ProcessInfo.processInfo.systemUptime > deadline { finish() }; return }
        }
        let front = !sleeping && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        if !front { withdrawn = false; satisfied = false }
        // A concurrent user/tool change wins for this foreground stretch.
        // Re-enter only after a real switch away and back, never every tick.
        if front, satisfied, lease.backend.read() == 0 { withdrawn = true }
        do {
            if front && !withdrawn { if !satisfied { satisfied = try lease.enter() } }
            else {
                // Claim first: a stranded row from an earlier session is still
                // ours to release even though this watcher never set it.
                try lease.claimStaleStandardRow()
                try lease.leave()
            }
        } catch { withdrawn = true; log("mode change unavailable; using normal keyboard behavior") }
    }
    func run() -> Never {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.sleeping = true; self?.tick() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.sleeping = false; self?.tick() })
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.finish() }; source.resume(); signals.append(source)
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); tick(); RunLoop.main.run(); finish()
    }
}

@main private struct Main {
    static func main() {
        do {
            let args = CommandLine.arguments
            func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
            if args.contains("--self-test") { try selfTest(); return }
            let backend = HIDMode()
            if args.contains("--status") { print("{\"mode\":\(backend.read().map(String.init) ?? "null")}"); return }
            if args.contains("--mapping-status") {
                guard let snapshot = HIDUserKeyMapping().read() else { throw Failure.unavailable }
                print("{\"keyboards\":\(snapshot.services.count),\"mappedKeyboards\":\(snapshot.services.filter { !$0.pairs.isEmpty }.count)}")
                return
            }
            if args.contains("--mapping-devices") {
                guard let summary = HIDUserKeyMapping().deviceSummary() else { throw Failure.unavailable }
                print(summary)
                return
            }
            // Manual escape hatch for the 2026-09-18 failure: if a session dies
            // while the F row is standard, the user needs one command that puts
            // the media row back without touching the game.  Refuses while a
            // managed game is seen, because that is the watcher's job.
            if args.contains("--force-media-row") {
                guard let pid = option("--game-pid").flatMap(Int32.init) else { throw Failure.invalidState }
                // Only refuse while the game is actually frontmost: then the
                // standard row is deliberate and the watcher will release it on
                // switch-away.  A running-but-background game must not block the
                // user's escape hatch.
                if Identity.read(pid) != nil, isManagedGame(pid),
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                    print("game is foreground; the watcher owns the F row")
                    return
                }
                if backend.read() == 0 { print("media row already active"); return }
                print(backend.write(0) ? "restored media row" : "could not restore the media row")
                return
            }
            guard getuid() != 0, let path = option("--state-file"), let me = Identity.read(getpid()) else { throw Failure.invalidState }
            let store = try Store(path), lease = Lease(store: store, backend: backend,
                                                      mappingBackend: HIDUserKeyMapping(), owner: me)
            // A short, recoverable live probe for a keyboard-service failure.
            // It uses the same journal/lease as --watch and must never compete
            // with a running game. The caller passes the exact game PID from
            // the current session; no key events or typed content are read.
            if args.contains("--diagnose-lease") {
                guard let gamePID = option("--game-pid").flatMap(Int32.init),
                      Identity.read(gamePID) == nil else { throw Failure.invalidState }
                let entered = try lease.enter()
                defer { try? lease.leave() }
                print(entered ? "lease entered; restoring" : "lease unavailable")
                return
            }
            if args.contains("--guardian") {
                guard let encoded = option("--owner"), let data = Data(base64Encoded: encoded) else { throw Failure.invalidState }
                let owner = try JSONDecoder().decode(Identity.self, from: data)
                while owner.isAlive { Thread.sleep(forTimeInterval: 0.5) }
                if try store.lock() { _ = try lease.recover() }; return
            }
            if args.contains("--recover") { if try store.lock() { _ = try lease.recover() }; return }
            guard args.contains("--watch"), let pid = option("--pid").flatMap(Int32.init), let parentPID = option("--parent-pid").flatMap(Int32.init),
                  let target = Identity.read(pid), let parent = Identity.read(parentPID) else { throw Failure.invalidState }
            // An independent child survives this helper's SIGKILL. It does
            // not retain the lock, and only restores a stale owner's journal.
            let guardian = Process(); guardian.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
            guardian.arguments = ["--guardian", "--owner", try JSONEncoder().encode(me).base64EncodedString(), "--state-file", path]
            guardian.standardInput = FileHandle.nullDevice; try guardian.run()
            let watch = Watch(target: target, parent: parent, lease: lease)
            withExtendedLifetime(watch) { watch.run() }
        } catch { log("unavailable (\(error)); game may continue without automatic F keys"); exit(1) }
    }
    static func selfTest() throws {
        final class Fake: ModeBackend {
            var value = 0, available = true, rejectsWrites = false
            func read() -> Int? { available ? value : nil }
            func write(_ v: Int) -> Bool {
                guard available, !rejectsWrites else { return false }
                value = v; return true
            }
        }
        final class FakeMapping: UserKeyMappingBackend {
            let f11 = UInt64(kHIDPage_KeyboardOrKeypad) << 32 | UInt64(kHIDUsage_KeyboardF11)
            let f20 = UInt64(kHIDPage_KeyboardOrKeypad) << 32 | UInt64(kHIDUsage_KeyboardF20)
            var value: HIDMappingSnapshot
            var available = true
            var rejectsWrites = false
            var failsAfterFirstService = false
            var writtenIDs: [UInt64] = []
            var concurrentEdit: HIDServiceMapping?
            init() {
                value = .init(services: [
                    .init(registryID: 101, pairs: [.init(source: 1, destination: 2)]),
                    .init(registryID: 202, pairs: [])
                ])
            }
            func read() -> HIDMappingSnapshot? { available ? value : nil }
            func write(_ next: HIDMappingSnapshot, expecting expected: HIDMappingSnapshot) -> Bool {
                guard available, !rejectsWrites else { return false }
                guard next.services.map(\.registryID) == expected.services.map(\.registryID),
                      next.services.map(\.registryID) == value.services.map(\.registryID) else { return false }
                for (index, pair) in zip(next.services, expected.services).enumerated() {
                    let (row, before) = pair
                    guard row != before else { continue }
                    if let edit = concurrentEdit, edit.registryID == row.registryID {
                        var rows = value.services; rows[index] = edit
                        value = .init(services: rows); concurrentEdit = nil
                    }
                    guard value.services[index] == before else { return false }
                    var rows = value.services; rows[index] = row
                    value = .init(services: rows); writtenIDs.append(row.registryID)
                    if failsAfterFirstService { failsAfterFirstService = false; return false }
                }
                return value == next
            }
            func leasedSnapshot(from original: HIDMappingSnapshot) throws -> HIDMappingSnapshot {
                guard !original.services.isEmpty else { throw Failure.unavailable }
                let reserved = Set([f11, f20])
                for service in original.services {
                    for pair in service.pairs where reserved.contains(pair.source) || reserved.contains(pair.destination) {
                        throw Failure.invalidState
                    }
                }
                return .init(services: original.services.map {
                    .init(registryID: $0.registryID,
                          pairs: ($0.pairs + [.init(source: f11, destination: f20)]).sorted {
                              if $0.source != $1.source { return $0.source < $1.source }
                              return $0.destination < $1.destination
                          })
                })
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idv-fkeys-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = Fake(), store = try Store(root.appendingPathComponent("state.json").path)
        let owner = Identity.read(getpid())!, lease = Lease(store: store, backend: backend, owner: owner)
        try lease.enter(); precondition(backend.value == 1 && lease.held)
        let contender = try Store(store.path); let contended = try contender.lock(); precondition(!contended)
        try lease.leave(); let cleared = try store.read(); precondition(backend.value == 0 && !lease.held && cleared == nil)
        backend.value = 1; let alreadyStandard = try lease.enter(); precondition(alreadyStandard && !lease.held)
        try lease.leave(); precondition(backend.value == 1)
        backend.value = 0; try lease.enter(); backend.value = 0; try lease.leave(); precondition(backend.value == 0)
        // A failed setter must not strand the lock or pretend to own a mode
        // that never changed. A failed restore must retain its recovery data.
        backend.rejectsWrites = true
        do { try lease.enter(); preconditionFailure("setter failure should propagate") }
        catch Failure.unavailable { }
        let failedEntry = try store.read()
        precondition(!lease.held && backend.value == 0 && failedEntry == nil)
        backend.rejectsWrites = false; try lease.enter(); backend.available = false
        do { try lease.leave(); preconditionFailure("unavailable restore should propagate") }
        catch Failure.unavailable { }
        let retained = try store.read(); precondition(lease.held && retained != nil)
        backend.available = true; try lease.leave(); precondition(backend.value == 0 && !lease.held)
        // 2026-09-18 field case: mode left at 1 with no journal (previous session
        // ended without restoring). The watcher must adopt it and release it.
        backend.value = 1
        let adopted = try lease.claimStaleStandardRow()
        precondition(adopted && lease.held, "a stranded standard row must be adopted")
        try lease.leave()
        precondition(backend.value == 0 && !lease.held, "adopted row must restore the media row")
        // A clean media row is never adopted.
        backend.value = 0
        let adoptedClean = try lease.claimStaleStandardRow()
        precondition(!adoptedClean && !lease.held, "a clean row must not be adopted")

        let locked = try store.lock(); precondition(locked)
        try store.write(.init(version: 1, owner: .init(pid: getpid(), seconds: 0, micros: 0), original: 0, applied: 1))
        backend.value = 1; let recovered = try lease.recover(); precondition(recovered && backend.value == 0)
        try store.write(.init(version: 1, owner: owner, original: 0, applied: 1)); backend.value = 1
        let other = Lease(store: store, backend: backend, owner: .init(pid: 2, seconds: 0, micros: 0))
        let refused = try other.recover(); precondition(!refused && backend.value == 1)
        try store.remove(); store.unlock(); precondition(!isManagedGame(getpid()))

        /* UserKeyMapping uses the HID usage page plus the SDK usage value:
           F11 is 0x700000044 and F20 is 0x70000006F (0x4D is End). */
        let mapping = FakeMapping()
        precondition(mapping.f11 == 0x700000044 && mapping.f20 == 0x70000006F)
        let originalMapping = mapping.value
        backend.value = 0
        let mappingLease = Lease(store: store, backend: backend, mappingBackend: mapping, owner: owner)
        try mappingLease.enter()
        let appliedMapping = mapping.value
        precondition(mappingLease.held && backend.value == 1 && mapping.value.services.allSatisfy {
            $0.pairs.contains(.init(source: mapping.f11, destination: mapping.f20))
        })
        let mappingContender = try Store(store.path)
        let mappingContended = try mappingContender.lock()
        precondition(!mappingContended, "a second watcher must not enter the mapping lease")
        try mappingLease.leave()
        let clearedAfterMapping = try store.read()
        precondition(backend.value == 0 && mapping.value == originalMapping && clearedAfterMapping == nil)

        /* A failed setter must restore both values and remove its intent. */
        mapping.rejectsWrites = true
        do { try mappingLease.enter(); preconditionFailure("mapping setter failure should propagate") }
        catch Failure.unavailable { }
        let clearedAfterFailure = try store.read()
        precondition(!mappingLease.held && backend.value == 0 && mapping.value == originalMapping && clearedAfterFailure == nil)
        mapping.rejectsWrites = false

        /* A per-service setter can fail after changing an earlier keyboard;
           only a complete original/applied transition may be rolled back. */
        mapping.failsAfterFirstService = true
        do { try mappingLease.enter(); preconditionFailure("partial mapping setter failure should propagate") }
        catch Failure.unavailable { }
        let clearedAfterPartialFailure = try store.read()
        precondition(!mappingLease.held && backend.value == 0 && mapping.value == originalMapping && clearedAfterPartialFailure == nil)

        /* A failed restore retains the combined journal until retry. */
        try mappingLease.enter()
        mapping.rejectsWrites = true
        do { try mappingLease.leave(); preconditionFailure("mapping restore failure should propagate") }
        catch Failure.unavailable { }
        let retainedMappingJournal = try store.read()
        precondition(mappingLease.held && retainedMappingJournal?.mapping != nil)
        mapping.rejectsWrites = false
        try mappingLease.leave()

        /* An edit on one keyboard wins compare-and-restore, while another
           keyboard that still has our applied row is restored. */
        try mappingLease.enter()
        let applied202 = appliedMapping.services.first { $0.registryID == 202 }!.pairs
        let original202 = originalMapping.services.first { $0.registryID == 202 }!.pairs
        let externalMapping = HIDMappingSnapshot(services: [
            .init(registryID: 101, pairs: [.init(source: 3, destination: 4)]),
            .init(registryID: 202, pairs: applied202)
        ])
        mapping.value = externalMapping
        mapping.writtenIDs = []
        try mappingLease.leave()
        let clearedAfterExternal = try store.read()
        let expectedAfterExternal = HIDMappingSnapshot(services: [
            .init(registryID: 101, pairs: [.init(source: 3, destination: 4)]),
            .init(registryID: 202, pairs: original202)
        ])
        precondition(backend.value == 0 && mapping.value == expectedAfterExternal && clearedAfterExternal == nil)
        precondition(mapping.writtenIDs == [202], "an external row must not receive even an identical setter")

        /* A disconnected keyboard is skipped and a newly appeared keyboard is
           never seeded with our mapping.  The still-present original keyboard
           must nevertheless be restored independently. */
        mapping.value = originalMapping
        try mappingLease.enter()
        let unpluggedAndAdded = HIDMappingSnapshot(services: [
            .init(registryID: 202, pairs: applied202),
            .init(registryID: 303, pairs: [.init(source: 7, destination: 8)])
        ])
        mapping.value = unpluggedAndAdded
        mapping.writtenIDs = []
        try mappingLease.leave()
        let expectedAfterHotPlug = HIDMappingSnapshot(services: [
            .init(registryID: 202, pairs: original202),
            .init(registryID: 303, pairs: [.init(source: 7, destination: 8)])
        ])
        let clearedAfterHotPlug = try store.read()
        precondition(backend.value == 0 && mapping.value == expectedAfterHotPlug && clearedAfterHotPlug == nil)
        precondition(mapping.writtenIDs == [202], "newly attached services must not receive a setter")

        // A change after planning but before a setter must survive the retry.
        mapping.value = originalMapping
        try mappingLease.enter()
        mapping.concurrentEdit = .init(registryID: 202, pairs: [.init(source: 5, destination: 6)])
        mapping.writtenIDs = []
        do { try mappingLease.leave(); preconditionFailure("concurrent edit must stop the write") }
        catch Failure.unavailable { }
        let retainedAfterConcurrentEdit = try store.read()
        precondition(mappingLease.held && retainedAfterConcurrentEdit != nil && mapping.writtenIDs == [101])
        try mappingLease.leave()
        precondition(!mappingLease.held && mapping.value.services[1].pairs == [.init(source: 5, destination: 6)])

        /* An owner that disappears leaves a journal recoverable by a new owner. */
        mapping.value = originalMapping
        try mappingLease.enter()
        let crashedJournal = try mappingLease.store.read()!
        mappingLease.store.unlock() // simulate the crashed watcher's released file descriptor
        let recoveryStore = try Store(store.path)
        let recovery = Lease(store: recoveryStore, backend: backend, mappingBackend: mapping,
                             owner: .init(pid: 2, seconds: 0, micros: 0))
        let recoveryLocked = try recoveryStore.lock()
        precondition(recoveryLocked)
        /* Replace only the recorded owner identity with a stale start time;
           this models a process that died while leaving applied values. */
        try recoveryStore.write(.init(version: crashedJournal.version,
                                      owner: .init(pid: getpid(), seconds: 0, micros: 0),
                                      original: crashedJournal.original,
                                      applied: crashedJournal.applied,
                                      mapping: crashedJournal.mapping))
        let recoveredMapping = try recovery.recover()
        precondition(recoveredMapping)
        let clearedAfterRecovery = try recoveryStore.read()
        precondition(backend.value == 0 && mapping.value == originalMapping && clearedAfterRecovery == nil)
        recoveryStore.unlock()

        /* Existing F11/F20 user mappings are never overwritten. */
        mapping.value = HIDMappingSnapshot(services: [
            .init(registryID: 101, pairs: [.init(source: mapping.f11, destination: 9)]),
            .init(registryID: 202, pairs: [])
        ])
        let conflictLease = Lease(store: store, backend: backend, mappingBackend: mapping, owner: owner)
        do { try conflictLease.enter(); preconditionFailure("reserved mapping must be rejected") }
        catch Failure.invalidState { }
        let clearedAfterConflict = try store.read()
        precondition(!conflictLease.held && backend.value == 0 && clearedAfterConflict == nil)
        print("function-key lease fixtures passed")
    }
}
