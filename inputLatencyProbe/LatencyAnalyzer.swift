import Foundation

enum LatencyAnalyzer {
    private static let minimumLagMilliseconds = 0.0
    private static let maximumLagMilliseconds = 250.0
    private static let lagStepMilliseconds = 1.0

    static func analyze(
        mouseEvents: [MouseSample],
        frameSamples: [FrameSample],
        extraWarnings: [String] = []
    ) -> LatencyAnalysis {
        let input = CumulativeInput(events: mouseEvents)
        let windows = analysisWindows(from: frameSamples)
        var warnings = extraWarnings

        guard input.count >= 30 else {
            warnings.append("有效鼠标事件不足，无法建立输入能量曲线。")
            return invalidAnalysis(warnings: warnings, windowCount: windows.count)
        }
        guard windows.count >= 60 else {
            warnings.append("有效画面变化窗口不足，无法可靠计算互相关。")
            return invalidAnalysis(warnings: warnings, windowCount: windows.count)
        }

        let points = correlationCurve(input: input, windows: windows)
        guard let peakIndex = points.indices.max(by: {
            points[$0].correlation < points[$1].correlation
        }) else {
            warnings.append("互相关曲线为空。")
            return invalidAnalysis(warnings: warnings, windowCount: windows.count)
        }

        let peak = points[peakIndex]
        let refinedLag = refinedPeakLag(points: points, index: peakIndex)
        let alternatives = points.filter {
            abs($0.lagMilliseconds - refinedLag) >= 20
        }
        let secondBest = alternatives.map(\.correlation).max() ?? peak.correlation
        let prominence = max(0, peak.correlation - secondBest)

        let curveMean = mean(points.map(\.correlation))
        let curveStandardDeviation = standardDeviation(points.map(\.correlation))
        let peakZScore: Double
        if curveStandardDeviation > 1e-9 {
            peakZScore = (peak.correlation - curveMean) / curveStandardDeviation
        } else {
            peakZScore = 0
        }

        let bestSeries = pairedSeries(
            input: input,
            windows: windows,
            lagSeconds: refinedLag / 1_000
        )
        let inputCV = coefficientOfVariation(bestSeries.input)
        let visualCV = coefficientOfVariation(bestSeries.visual)

        let segmentEstimates = segmentPeakEstimates(input: input, windows: windows)
        let segmentDeviation = segmentEstimates.count >= 2
            ? standardDeviation(segmentEstimates)
            : nil

        if mouseEvents.count < 300 {
            warnings.append("鼠标事件样本偏少；请连续移动并让速度有自然变化。")
        }
        if windows.count < 300 {
            warnings.append("有效画面帧偏少；建议保持游戏前台并测满 15–20 秒。")
        }
        if peak.correlation < 0.15 {
            warnings.append("输入与画面变化的相关性很弱，本次估算只能视为低置信度线索。")
        }
        if refinedLag <= 3 || refinedLag >= 247 {
            warnings.append("最佳峰落在 0–250 ms 搜索边界附近，真实峰可能在搜索范围外。")
        }
        if let inputCV, inputCV < 0.08 {
            warnings.append("输入能量变化过于均匀；下次左右甩鼠时让速度和幅度略有变化。")
        }
        if let visualCV, visualCV < 0.08 {
            warnings.append("画面变化能量过于均匀；请对准有纹理但没有动画的静态墙面。")
        }
        if let segmentDeviation, segmentDeviation > 35 {
            warnings.append("分段估算波动较大，说明相关峰不稳定。")
        }

        var score = confidenceScore(
            peakCorrelation: peak.correlation,
            prominence: prominence,
            peakZScore: peakZScore,
            segmentDeviation: segmentDeviation,
            inputCV: inputCV,
            visualCV: visualCV,
            eventCount: mouseEvents.count,
            windowCount: windows.count
        )
        if refinedLag <= 3 || refinedLag >= 247 {
            score *= 0.55
        }
        if !extraWarnings.isEmpty {
            score *= 0.75
        }
        if peak.correlation < 0.15 {
            score = min(score, 0.32)
        }
        score = clamp(score, 0, 1)

        let level: String
        if score >= 0.72 && peak.correlation >= 0.30 {
            level = "高"
        } else if score >= 0.42 && peak.correlation >= 0.15 {
            level = "中"
        } else {
            level = "低"
        }

        return LatencyAnalysis(
            valid: true,
            softwareLatencyMilliseconds: refinedLag,
            confidenceLevel: level,
            confidenceScore: score,
            peakCorrelation: peak.correlation,
            peakProminence: prominence,
            peakZScore: peakZScore,
            analyzedWindowCount: windows.count,
            segmentEstimatesMilliseconds: segmentEstimates,
            segmentStandardDeviationMilliseconds: segmentDeviation,
            inputCoefficientOfVariation: inputCV,
            visualCoefficientOfVariation: visualCV,
            correlationStepMilliseconds: lagStepMilliseconds,
            minimumLagMilliseconds: minimumLagMilliseconds,
            maximumLagMilliseconds: maximumLagMilliseconds,
            warnings: warnings,
            correlation: points
        )
    }

    private static func invalidAnalysis(
        warnings: [String],
        windowCount: Int
    ) -> LatencyAnalysis {
        LatencyAnalysis(
            valid: false,
            softwareLatencyMilliseconds: nil,
            confidenceLevel: "低",
            confidenceScore: 0,
            peakCorrelation: nil,
            peakProminence: nil,
            peakZScore: nil,
            analyzedWindowCount: windowCount,
            segmentEstimatesMilliseconds: [],
            segmentStandardDeviationMilliseconds: nil,
            inputCoefficientOfVariation: nil,
            visualCoefficientOfVariation: nil,
            correlationStepMilliseconds: lagStepMilliseconds,
            minimumLagMilliseconds: minimumLagMilliseconds,
            maximumLagMilliseconds: maximumLagMilliseconds,
            warnings: warnings,
            correlation: []
        )
    }

    private static func analysisWindows(from samples: [FrameSample]) -> [AnalysisWindow] {
        samples.compactMap { sample in
            guard let interval = sample.frameIntervalSeconds,
                  let visualEnergy = sample.visualEnergyPerSecond,
                  interval >= 1.0 / 300.0,
                  interval <= 0.100,
                  visualEnergy.isFinite,
                  visualEnergy >= 0 else {
                return nil
            }
            return AnalysisWindow(
                start: sample.analysisTimeSeconds - interval,
                end: sample.analysisTimeSeconds,
                duration: interval,
                visualEnergy: log1p(visualEnergy)
            )
        }
    }

    private static func correlationCurve(
        input: CumulativeInput,
        windows: [AnalysisWindow]
    ) -> [CorrelationPoint] {
        let stepCount = Int(
            ((maximumLagMilliseconds - minimumLagMilliseconds) / lagStepMilliseconds).rounded()
        )
        return (0...stepCount).compactMap { step in
            let lagMilliseconds = minimumLagMilliseconds + Double(step) * lagStepMilliseconds
            let series = pairedSeries(
                input: input,
                windows: windows,
                lagSeconds: lagMilliseconds / 1_000
            )
            guard let correlation = pearson(series.input, series.visual) else { return nil }
            return CorrelationPoint(
                lagMilliseconds: lagMilliseconds,
                correlation: correlation,
                sampleCount: series.input.count
            )
        }
    }

    private static func pairedSeries(
        input: CumulativeInput,
        windows: [AnalysisWindow],
        lagSeconds: Double
    ) -> (input: [Double], visual: [Double]) {
        var inputValues: [Double] = []
        var visualValues: [Double] = []
        inputValues.reserveCapacity(windows.count)
        visualValues.reserveCapacity(windows.count)

        for window in windows {
            let start = window.start - lagSeconds
            let end = window.end - lagSeconds
            guard start >= input.firstTime, end <= input.lastTime else { continue }
            let energyRate = input.energy(from: start, through: end) / window.duration
            inputValues.append(log1p(max(0, energyRate)))
            visualValues.append(window.visualEnergy)
        }
        return (inputValues, visualValues)
    }

    private static func segmentPeakEstimates(
        input: CumulativeInput,
        windows: [AnalysisWindow]
    ) -> [Double] {
        guard windows.count >= 200 else { return [] }
        let segmentCount = min(5, max(3, windows.count / 180))
        var estimates: [Double] = []
        for segment in 0..<segmentCount {
            let lower = segment * windows.count / segmentCount
            let upper = (segment + 1) * windows.count / segmentCount
            guard upper - lower >= 40 else { continue }
            let points = correlationCurve(input: input, windows: Array(windows[lower..<upper]))
            guard let index = points.indices.max(by: {
                points[$0].correlation < points[$1].correlation
            }) else { continue }
            estimates.append(refinedPeakLag(points: points, index: index))
        }
        return estimates
    }

    private static func refinedPeakLag(points: [CorrelationPoint], index: Int) -> Double {
        guard index > 0, index + 1 < points.count else {
            return points[index].lagMilliseconds
        }
        let left = points[index - 1].correlation
        let center = points[index].correlation
        let right = points[index + 1].correlation
        let denominator = left - 2 * center + right
        guard abs(denominator) > 1e-12 else {
            return points[index].lagMilliseconds
        }
        let offset = clamp(0.5 * (left - right) / denominator, -1, 1)
        return points[index].lagMilliseconds + offset * lagStepMilliseconds
    }

    private static func confidenceScore(
        peakCorrelation: Double,
        prominence: Double,
        peakZScore: Double,
        segmentDeviation: Double?,
        inputCV: Double?,
        visualCV: Double?,
        eventCount: Int,
        windowCount: Int
    ) -> Double {
        let peakFactor = clamp((peakCorrelation - 0.08) / 0.42, 0, 1)
        let prominenceFactor = clamp(prominence / 0.08, 0, 1)
        let zFactor = clamp((peakZScore - 1.0) / 4.0, 0, 1)
        let stabilityFactor: Double
        if let segmentDeviation {
            stabilityFactor = clamp(1 - segmentDeviation / 55, 0, 1)
        } else {
            stabilityFactor = 0.25
        }

        let minimumCV = min(inputCV ?? 0, visualCV ?? 0)
        let variationFactor = clamp((minimumCV - 0.04) / 0.35, 0, 1)
        let eventFactor = clamp(Double(eventCount) / 900, 0, 1)
        let windowFactor = clamp(Double(windowCount) / 700, 0, 1)
        let sampleFactor = sqrt(eventFactor * windowFactor)

        let evidence = 0.40 * peakFactor
            + 0.20 * prominenceFactor
            + 0.15 * zFactor
            + 0.15 * stabilityFactor
            + 0.10 * variationFactor
        return evidence * sampleFactor
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 30 else { return nil }
        let xMean = mean(x)
        let yMean = mean(y)
        var numerator = 0.0
        var xSumSquares = 0.0
        var ySumSquares = 0.0
        for index in x.indices {
            let dx = x[index] - xMean
            let dy = y[index] - yMean
            numerator += dx * dy
            xSumSquares += dx * dx
            ySumSquares += dy * dy
        }
        let denominator = sqrt(xSumSquares * ySumSquares)
        guard denominator > 1e-12 else { return nil }
        return numerator / denominator
    }

    private static func coefficientOfVariation(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let average = mean(values)
        guard abs(average) > 1e-12 else { return nil }
        return standardDeviation(values) / abs(average)
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { partial, value in
            let delta = value - average
            return partial + delta * delta
        } / Double(values.count - 1)
        return sqrt(max(0, variance))
    }
}

private struct AnalysisWindow {
    let start: Double
    let end: Double
    let duration: Double
    let visualEnergy: Double
}

private struct CumulativeInput {
    let times: [Double]
    let prefixEnergy: [Double]

    init(events: [MouseSample]) {
        let sorted = events
            .filter { $0.analysisTimeSeconds.isFinite && $0.energy.isFinite && $0.energy >= 0 }
            .sorted { $0.analysisTimeSeconds < $1.analysisTimeSeconds }
        times = sorted.map(\.analysisTimeSeconds)
        var prefix = [Double](repeating: 0, count: sorted.count + 1)
        for index in sorted.indices {
            prefix[index + 1] = prefix[index] + sorted[index].energy
        }
        prefixEnergy = prefix
    }

    var count: Int { times.count }
    var firstTime: Double { times.first ?? .infinity }
    var lastTime: Double { times.last ?? -.infinity }

    func energy(from start: Double, through end: Double) -> Double {
        guard end > start else { return 0 }
        let lower = upperBound(start)
        let upper = upperBound(end)
        return prefixEnergy[upper] - prefixEnergy[lower]
    }

    private func upperBound(_ value: Double) -> Int {
        var lower = 0
        var upper = times.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if times[middle] <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
