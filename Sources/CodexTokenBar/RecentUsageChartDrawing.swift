import SwiftUI

extension RecentUsageChart {
    func linePath(points: [CGPoint]) -> Path {
        Path { path in
            appendSmoothPolyline(points, to: &path)
        }
    }

    func tokenAreaPath(points: [CGPoint], plot: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: plot.maxY))
        path.addLine(to: first)
        appendSmoothPolyline(points, to: &path, moveToStart: false)
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    func optionalLinePath(points: [CGPoint?]) -> Path {
        var path = Path()
        var segment: [CGPoint] = []

        for point in points {
            guard let point else {
                if !segment.isEmpty {
                    appendOptionalSegment(segment, to: &path)
                    segment.removeAll(keepingCapacity: true)
                }
                continue
            }
            segment.append(point)
        }

        if !segment.isEmpty {
            appendOptionalSegment(segment, to: &path)
        }
        return path
    }

    /// Cache hit rate is an observation, not a continuously changing value.
    /// Only adjacent buckets with real usage are connected; idle gaps stay blank.
    func observedOptionalLinePath(points: [CGPoint?]) -> Path {
        var path = Path()
        var previous: CGPoint?
        for point in points {
            guard let point else {
                previous = nil
                continue
            }
            if let previous {
                path.move(to: previous)
                path.addLine(to: point)
            }
            previous = point
        }
        return path
    }

    func observedOptionalPointPath(points: [CGPoint?], radius: CGFloat = 1.6) -> Path {
        Path { path in
            for point in points.compactMap({ $0 }) {
                path.addEllipse(in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
        }
    }

    private func appendOptionalSegment(_ points: [CGPoint], to path: inout Path) {
        guard points.count == 1, let point = points.first else {
            appendSmoothPolyline(points, to: &path)
            return
        }
        path.move(to: point)
        path.addLine(to: CGPoint(x: point.x + 0.01, y: point.y))
    }

    private func appendSmoothPolyline(_ points: [CGPoint], to path: inout Path, moveToStart: Bool = true) {
        guard let first = points.first else { return }
        if moveToStart {
            path.move(to: first)
        }

        guard points.count > 2 else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return
        }

        guard let slopes = monotoneSlopes(for: points) else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let dx = end.x - start.x
            guard dx > .ulpOfOne else {
                path.addLine(to: end)
                continue
            }

            let controlDistance = dx / 3
            path.addCurve(
                to: end,
                control1: CGPoint(
                    x: start.x + controlDistance,
                    y: start.y + slopes[index] * controlDistance
                ),
                control2: CGPoint(
                    x: end.x - controlDistance,
                    y: end.y - slopes[index + 1] * controlDistance
                )
            )
        }
    }

    private func monotoneSlopes(for points: [CGPoint]) -> [CGFloat]? {
        guard points.count > 2 else { return nil }

        // Shape-preserving slopes keep smoothing from inventing peaks between adjacent bins.
        var intervals: [CGFloat] = []
        var deltas: [CGFloat] = []
        for index in 0..<(points.count - 1) {
            let dx = points[index + 1].x - points[index].x
            guard dx > .ulpOfOne else { return nil }
            intervals.append(dx)
            deltas.append((points[index + 1].y - points[index].y) / dx)
        }

        var slopes = Array(repeating: CGFloat.zero, count: points.count)
        slopes[0] = endpointSlope(
            edgeInterval: intervals[0],
            neighborInterval: intervals[1],
            edgeDelta: deltas[0],
            neighborDelta: deltas[1]
        )
        slopes[points.count - 1] = endpointSlope(
            edgeInterval: intervals[intervals.count - 1],
            neighborInterval: intervals[intervals.count - 2],
            edgeDelta: deltas[deltas.count - 1],
            neighborDelta: deltas[deltas.count - 2]
        )

        for index in 1..<(points.count - 1) {
            let left = deltas[index - 1]
            let right = deltas[index]
            guard left != 0, right != 0, (left > 0) == (right > 0) else {
                slopes[index] = 0
                continue
            }

            let leftInterval = intervals[index - 1]
            let rightInterval = intervals[index]
            let leftWeight = 2 * rightInterval + leftInterval
            let rightWeight = rightInterval + 2 * leftInterval
            slopes[index] = (leftWeight + rightWeight) / (leftWeight / left + rightWeight / right)
        }

        for index in 0..<deltas.count {
            let delta = deltas[index]
            guard delta != 0 else {
                slopes[index] = 0
                slopes[index + 1] = 0
                continue
            }

            let alpha = slopes[index] / delta
            let beta = slopes[index + 1] / delta
            if alpha < 0 || beta < 0 {
                if alpha < 0 { slopes[index] = 0 }
                if beta < 0 { slopes[index + 1] = 0 }
                continue
            }

            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                slopes[index] = scale * alpha * delta
                slopes[index + 1] = scale * beta * delta
            }
        }

        return slopes
    }

    private func endpointSlope(
        edgeInterval: CGFloat,
        neighborInterval: CGFloat,
        edgeDelta: CGFloat,
        neighborDelta: CGFloat
    ) -> CGFloat {
        guard edgeDelta != 0 else { return 0 }

        let slope = ((2 * edgeInterval + neighborInterval) * edgeDelta - edgeInterval * neighborDelta) / (edgeInterval + neighborInterval)
        if (slope > 0) != (edgeDelta > 0) {
            return 0
        }
        if (edgeDelta > 0) != (neighborDelta > 0), abs(slope) > abs(3 * edgeDelta) {
            return 3 * edgeDelta
        }
        return slope
    }

    func hoverIndex(at location: CGPoint, in plot: CGRect, step: CGFloat) -> Int? {
        guard plot.contains(location), !preparedData.bins.isEmpty else { return nil }
        let rawIndex = Int(round((location.x - plot.minX) / max(step, 1)))
        return min(max(rawIndex, preparedData.bins.startIndex), preparedData.bins.index(before: preparedData.bins.endIndex))
    }
}
