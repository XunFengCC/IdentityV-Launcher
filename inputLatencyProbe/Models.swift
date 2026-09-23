import Foundation
import CoreMedia

let targetBundleIdentifier = "com.fengyin.identityv.runner"
let measurementBoundary = "从 macOS CGEvent 的 mouseMoved 时间戳到 ScreenCaptureKit 可见窗口帧变化；不包含鼠标硬件/USB 上报前延迟、显示器扫描输出或面板像素响应。"

func hostClockSeconds() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

func finiteOrNil(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value
}

func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(upper, max(lower, value))
}

func posix(_ format: String, _ value: Double) -> String {
    String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
}

struct MouseSample: Codable {
    var sequence: Int
    let eventTimestampNanoseconds: UInt64
    let eventTimestampSeconds: Double
    let analysisTimeSeconds: Double
    let callbackHostTimeSeconds: Double
    let callbackDelayMilliseconds: Double
    let deltaX: Int64
    let deltaY: Int64
    let energy: Double
    let timestampSource: String
}

struct FrameSample: Codable {
    var sequence: Int
    let analysisTimeSeconds: Double
    let presentationTimeSeconds: Double?
    let displayMachTime: UInt64?
    let displayTimeSeconds: Double?
    let callbackHostTimeSeconds: Double
    let callbackDelayMilliseconds: Double
    let frameIntervalSeconds: Double?
    let meanAbsoluteLumaDifference: Double?
    let rmsLumaDifference: Double?
    let changedPixelFraction: Double?
    let visualEnergyPerSecond: Double?
    let timestampSource: String
    let captureWidth: Int
    let captureHeight: Int
    let sampleGridWidth: Int
    let sampleGridHeight: Int
}

struct CorrelationPoint: Codable {
    let lagMilliseconds: Double
    let correlation: Double
    let sampleCount: Int
}

struct TargetWindowMetadata: Codable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let windowIdentifier: UInt32
    let title: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let captureWidth: Int
    let captureHeight: Int
}

struct SessionMetadata: Codable {
    let schemaVersion: Int
    let toolVersion: String
    let startedAt: String
    let requestedDurationSeconds: Double
    let recordedDurationSeconds: Double
    let startHostTimeSeconds: Double
    let endHostTimeSeconds: Double
    let target: TargetWindowMetadata
    let eventTapMode: String
    let screenCaptureMode: String
    let capturesCursor: Bool
    let capturesAudio: Bool
    let storesFrames: Bool
    let eventTapReenableCount: Int
    let measurementBoundary: String
}

struct LatencyAnalysis: Codable {
    let valid: Bool
    let softwareLatencyMilliseconds: Double?
    let confidenceLevel: String
    let confidenceScore: Double
    let peakCorrelation: Double?
    let peakProminence: Double?
    let peakZScore: Double?
    let analyzedWindowCount: Int
    let segmentEstimatesMilliseconds: [Double]
    let segmentStandardDeviationMilliseconds: Double?
    let inputCoefficientOfVariation: Double?
    let visualCoefficientOfVariation: Double?
    let correlationStepMilliseconds: Double
    let minimumLagMilliseconds: Double
    let maximumLagMilliseconds: Double
    let warnings: [String]
    let correlation: [CorrelationPoint]
}

struct RawExport: Codable {
    let metadata: SessionMetadata
    let mouseEvents: [MouseSample]
    let frameSamples: [FrameSample]
}

struct ResultExport: Codable {
    let metadata: SessionMetadata
    let analysis: LatencyAnalysis
    let sampleCounts: [String: Int]
    let files: [String: String]
    let notes: [String]
}

enum ProbeFailure: LocalizedError {
    case usage(String)
    case permissions(String)
    case target(String)
    case capture(String)
    case output(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .permissions(let message), .target(let message),
             .capture(let message), .output(let message):
            return message
        }
    }
}

enum OutputWriter {
    private static let outputRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/IdentityVOnMac", isDirectory: true)
        .appendingPathComponent("Diagnostics", isDirectory: true)
        .appendingPathComponent("InputLatency", isDirectory: true)

    static func write(
        metadata: SessionMetadata,
        analysis: LatencyAnalysis,
        mouseEvents: [MouseSample],
        frameSamples: [FrameSample]
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let sessionDirectory = outputRoot.appendingPathComponent(
            "identityv-input-latency-\(formatter.string(from: Date()))",
            isDirectory: true
        )

        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true
            )

            let inputCSV = sessionDirectory.appendingPathComponent("mouse_events.csv")
            let frameCSV = sessionDirectory.appendingPathComponent("frame_samples.csv")
            let correlationCSV = sessionDirectory.appendingPathComponent("correlation.csv")
            let rawJSON = sessionDirectory.appendingPathComponent("raw_samples.json")
            let resultJSON = sessionDirectory.appendingPathComponent("result.json")

            try mouseCSV(mouseEvents).write(to: inputCSV, atomically: true, encoding: .utf8)
            try framesCSV(frameSamples).write(to: frameCSV, atomically: true, encoding: .utf8)
            try correlationsCSV(analysis.correlation).write(
                to: correlationCSV,
                atomically: true,
                encoding: .utf8
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(RawExport(
                metadata: metadata,
                mouseEvents: mouseEvents,
                frameSamples: frameSamples
            )).write(to: rawJSON, options: .atomic)

            let files = [
                "mouse_events_csv": inputCSV.lastPathComponent,
                "frame_samples_csv": frameCSV.lastPathComponent,
                "correlation_csv": correlationCSV.lastPathComponent,
                "raw_samples_json": rawJSON.lastPathComponent,
                "result_json": resultJSON.lastPathComponent,
            ]
            let result = ResultExport(
                metadata: metadata,
                analysis: analysis,
                sampleCounts: [
                    "mouse_events": mouseEvents.count,
                    "frame_samples": frameSamples.count,
                    "correlation_points": analysis.correlation.count,
                ],
                files: files,
                notes: [
                    measurementBoundary,
                    "原始画面不会写入磁盘；frame_samples 只保存每帧的标量像素差异。",
                    "估算值适合比较软件链路，不等同于手到光子的端到端物理延迟。",
                ]
            )
            try encoder.encode(result).write(to: resultJSON, options: .atomic)
            return sessionDirectory
        } catch {
            throw ProbeFailure.output("写入结果失败：\(error.localizedDescription)")
        }
    }

    private static func mouseCSV(_ samples: [MouseSample]) -> String {
        var lines = [
            "sequence,event_timestamp_ns,event_timestamp_s,analysis_time_s,callback_host_time_s,callback_delay_ms,delta_x,delta_y,input_energy,timestamp_source"
        ]
        lines.reserveCapacity(samples.count + 1)
        for sample in samples {
            lines.append([
                String(sample.sequence),
                String(sample.eventTimestampNanoseconds),
                posix("%.9f", sample.eventTimestampSeconds),
                posix("%.9f", sample.analysisTimeSeconds),
                posix("%.9f", sample.callbackHostTimeSeconds),
                posix("%.6f", sample.callbackDelayMilliseconds),
                String(sample.deltaX),
                String(sample.deltaY),
                posix("%.6f", sample.energy),
                csvEscape(sample.timestampSource),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func framesCSV(_ samples: [FrameSample]) -> String {
        var lines = [
            "sequence,analysis_time_s,presentation_time_s,display_mach_time,display_time_s,callback_host_time_s,callback_delay_ms,frame_interval_ms,mean_abs_luma_diff,rms_luma_diff,changed_pixel_fraction,visual_energy_per_s,timestamp_source,capture_width,capture_height,sample_grid_width,sample_grid_height"
        ]
        lines.reserveCapacity(samples.count + 1)
        for sample in samples {
            lines.append([
                String(sample.sequence),
                posix("%.9f", sample.analysisTimeSeconds),
                number(sample.presentationTimeSeconds, "%.9f"),
                sample.displayMachTime.map(String.init) ?? "",
                number(sample.displayTimeSeconds, "%.9f"),
                posix("%.9f", sample.callbackHostTimeSeconds),
                posix("%.6f", sample.callbackDelayMilliseconds),
                number(sample.frameIntervalSeconds.map { $0 * 1_000 }, "%.6f"),
                number(sample.meanAbsoluteLumaDifference, "%.9f"),
                number(sample.rmsLumaDifference, "%.9f"),
                number(sample.changedPixelFraction, "%.9f"),
                number(sample.visualEnergyPerSecond, "%.9f"),
                csvEscape(sample.timestampSource),
                String(sample.captureWidth),
                String(sample.captureHeight),
                String(sample.sampleGridWidth),
                String(sample.sampleGridHeight),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func correlationsCSV(_ points: [CorrelationPoint]) -> String {
        var lines = ["lag_ms,correlation,sample_count"]
        lines.reserveCapacity(points.count + 1)
        for point in points {
            lines.append([
                posix("%.3f", point.lagMilliseconds),
                posix("%.9f", point.correlation),
                String(point.sampleCount),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func number(_ value: Double?, _ format: String) -> String {
        guard let value, value.isFinite else { return "" }
        return posix(format, value)
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
