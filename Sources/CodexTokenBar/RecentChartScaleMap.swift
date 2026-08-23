import CoreGraphics
import Foundation

enum RecentChartScaleTransform: Equatable {
    case linear
    case logOnePlus
}

enum RecentChartScaleSeries: Equatable {
    case tokens
    case calls
    case cacheHitRate
    case cost
    case quota
}

struct RecentChartScaleSpec: Equatable {
    let transform: RecentChartScaleTransform
    let minimum: Double
    let maximum: Double
    let outputMinimum: CGFloat
    let outputMaximum: CGFloat
    let midpoint: Double?
    let outputMidpoint: CGFloat?
}

/// Series whose vertical domains stay stable while the viewport moves.
/// Token and cost are supplied separately because their domains follow the
/// visible bucket window.
struct RecentChartFixedScaleMap: Equatable {
    let calls: RecentChartScaleSpec
    let cacheHitRate: RecentChartScaleSpec
    let quota: RecentChartScaleSpec

    init(callValues: [Int]) {
        calls = RecentChartScaleMap.linearScale(
            maximum: Double(callValues.reduce(0) { max($0, $1) }),
            outputMaximum: 1
        )
        cacheHitRate = RecentChartScaleMap.linearScale(maximum: 1, outputMaximum: 1)
        quota = RecentChartScaleMap.linearScale(maximum: 100, outputMaximum: 1)
    }

    static let empty = RecentChartFixedScaleMap(callValues: [])
}

struct RecentChartScaleMap: Equatable {
    static let tokenPeakHeightRatio: CGFloat = 0.65

    private let tokens: RecentChartScaleSpec
    private let cost: RecentChartScaleSpec
    private let fixed: RecentChartFixedScaleMap

    init(tokenValues: [Int], callValues: [Int], costs: [Double]) {
        self.init(
            tokenValues: tokenValues,
            costValues: costs,
            fixed: RecentChartFixedScaleMap(callValues: callValues)
        )
    }

    init(
        tokenValues: [Int],
        costValues: [Double],
        fixed: RecentChartFixedScaleMap
    ) {
        tokens = Self.linearScale(
            maximum: Double(tokenValues.reduce(0) { max($0, $1) }),
            outputMaximum: Self.tokenPeakHeightRatio
        )
        cost = Self.linearScale(
            maximum: costValues.reduce(0) { maximum, value in
                max(maximum, value.isFinite ? max(value, 0) : 0)
            },
            outputMaximum: 1
        )
        self.fixed = fixed
    }

    func heightFraction(for value: Double, series: RecentChartScaleSeries) -> CGFloat {
        Self.heightFraction(for: value, scale: scale(for: series))
    }

    func y(
        for value: Double,
        series: RecentChartScaleSeries,
        plotHeight: CGFloat
    ) -> CGFloat {
        let safePlotHeight = max(plotHeight, 0)
        return (1 - heightFraction(for: value, series: series)) * safePlotHeight
    }

    static func isRenderableCost(_ cost: Double) -> Bool {
        cost.isFinite && cost > 0
    }

    private func scale(for series: RecentChartScaleSeries) -> RecentChartScaleSpec {
        switch series {
        case .tokens: tokens
        case .calls: fixed.calls
        case .cacheHitRate: fixed.cacheHitRate
        case .cost: cost
        case .quota: fixed.quota
        }
    }

    private static func heightFraction(
        for value: Double,
        scale: RecentChartScaleSpec
    ) -> CGFloat {
        let minimum = finiteNonnegative(scale.minimum)
        let maximum = max(finiteNonnegative(scale.maximum), minimum)
        let outputMinimum = min(max(scale.outputMinimum, 0), 1)
        let outputMaximum = min(max(scale.outputMaximum, outputMinimum), 1)
        let safeValue = min(max(finiteNonnegative(value), minimum), maximum)
        guard maximum - minimum > .ulpOfOne else {
            guard maximum > .ulpOfOne, value > 0 else { return 0 }
            return min(
                max(scale.outputMidpoint ?? outputMaximum, outputMinimum),
                outputMaximum
            )
        }

        let transformedValue = transformed(safeValue, using: scale.transform)
        let transformedMinimum = transformed(minimum, using: scale.transform)
        let transformedMaximum = transformed(maximum, using: scale.transform)
        guard transformedMaximum - transformedMinimum > .ulpOfOne else {
            return outputMinimum
        }

        if let midpoint = scale.midpoint.map({ min(max(finiteNonnegative($0), minimum), maximum) }),
           let outputMidpoint = scale.outputMidpoint.map({ min(max($0, outputMinimum), outputMaximum) }) {
            let transformedMidpoint = transformed(midpoint, using: scale.transform)
            if transformedValue <= transformedMidpoint {
                return interpolate(
                    transformedValue,
                    inputMinimum: transformedMinimum,
                    inputMaximum: transformedMidpoint,
                    outputMinimum: outputMinimum,
                    outputMaximum: outputMidpoint
                )
            }
            return interpolate(
                transformedValue,
                inputMinimum: transformedMidpoint,
                inputMaximum: transformedMaximum,
                outputMinimum: outputMidpoint,
                outputMaximum: outputMaximum
            )
        }

        return interpolate(
            transformedValue,
            inputMinimum: transformedMinimum,
            inputMaximum: transformedMaximum,
            outputMinimum: outputMinimum,
            outputMaximum: outputMaximum
        )
    }

    fileprivate static func linearScale(
        maximum: Double,
        outputMaximum: CGFloat
    ) -> RecentChartScaleSpec {
        RecentChartScaleSpec(
            transform: .linear,
            minimum: 0,
            maximum: max(finiteNonnegative(maximum), 1),
            outputMinimum: 0,
            outputMaximum: outputMaximum,
            midpoint: nil,
            outputMidpoint: nil
        )
    }

    private static func transformed(
        _ value: Double,
        using transform: RecentChartScaleTransform
    ) -> Double {
        switch transform {
        case .linear: value
        case .logOnePlus: log1p(value)
        }
    }

    private static func interpolate(
        _ value: Double,
        inputMinimum: Double,
        inputMaximum: Double,
        outputMinimum: CGFloat,
        outputMaximum: CGFloat
    ) -> CGFloat {
        let inputSpan = inputMaximum - inputMinimum
        guard inputSpan > .ulpOfOne else { return outputMaximum }
        return min(
            max(
                outputMinimum
                    + (outputMaximum - outputMinimum)
                        * CGFloat((value - inputMinimum) / inputSpan),
                outputMinimum
            ),
            outputMaximum
        )
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }
}
