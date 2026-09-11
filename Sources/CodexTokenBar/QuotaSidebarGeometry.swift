import Foundation
import CoreGraphics

// Independent from the floating panel's placement and appearance preferences.
enum QuotaSidebarEdge: String, CaseIterable, Sendable {
    case left, right
}

struct QuotaSidebarSettings: Equatable {
    static let enabledKey = "quotaSidebarEnabled"
    static let edgeKey = "quotaSidebarEdge"
    var enabled = false
    var edge: QuotaSidebarEdge = .right

    static func load(defaults: UserDefaults) -> Self {
        Self(enabled: defaults.bool(forKey: enabledKey),
             edge: QuotaSidebarEdge(rawValue: defaults.string(forKey: edgeKey) ?? "") ?? .right)
    }
}

enum QuotaSidebarDetail: Equatable { case overview, tasks, radar, credits }

struct QuotaSidebarInteraction: Equatable {
    private(set) var expanded = false
    private(set) var detail: QuotaSidebarDetail?
    private(set) var pinned = false

    mutating func enter() { expanded = true }
    mutating func select(_ detail: QuotaSidebarDetail) {
        expanded = true
        self.detail = detail
    }
    mutating func beginDrag() { detail = nil; pinned = false }
    mutating func togglePin() { if detail != nil { pinned.toggle() } }
    mutating func leaveAfterGrace() { if !pinned { dismiss() } }
    mutating func dismiss() { expanded = false; detail = nil; pinned = false }
}

struct QuotaSidebarFrames: Equatable {
    let rail: CGRect
    let detail: CGRect

    // Cocoa points already account for display scaling; round to physical pixels.
    static func make(usableFrame: CGRect, edge: QuotaSidebarEdge,
                     expanded: Bool, scale: CGFloat = 1, hasFiveHour: Bool = true,
                     normalizedY: Double = 0.5) -> Self {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let source = usableFrame.standardized
        // Stay inside the usable display even when its origin is fractional.
        let left = ceil(source.minX * safeScale) / safeScale
        let bottom = ceil(source.minY * safeScale) / safeScale
        let area = CGRect(x: left, y: bottom,
                          width: max(0, floor(source.maxX * safeScale) / safeScale - left),
                          height: max(0, floor(source.maxY * safeScale) / safeScale - bottom))
        let railWidth = min(expanded ? 88.0 : 16.0, area.width)
        let contentHeight = expanded ? (hasFiveHour ? 560.0 : 470.0) : (hasFiveHour ? 250.0 : 192.0)
        let railHeight = min(contentHeight, area.height)
        let gap = min(12.0, max(0, area.width - railWidth))
        let detailWidth = min(420.0, max(0, area.width - railWidth - gap))
        let detailHeight = min(600.0, area.height)
        func snap(_ n: CGFloat) -> CGFloat { (n * safeScale).rounded() / safeScale }
        let fraction = normalizedY.isFinite ? min(1, max(0, normalizedY)) : 0.5
        let desiredCenter = area.minY + area.height * fraction
        func rect(x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            let y = min(max(area.minY, desiredCenter - height / 2), area.maxY - height)
            return CGRect(x: snap(x), y: snap(y),
                   width: max(0, floor(width * safeScale) / safeScale),
                   height: max(0, floor(height * safeScale) / safeScale))
        }
        let railX = edge == .left ? area.minX : area.maxX - railWidth
        let detailX = edge == .left ? railX + railWidth + gap : railX - gap - detailWidth
        return Self(rail: rect(x: railX, width: railWidth, height: railHeight),
                    detail: rect(x: detailX, width: detailWidth, height: detailHeight))
    }

    func contains(_ point: CGPoint, detailVisible: Bool) -> Bool {
        if rail.contains(point) { return true }
        guard detailVisible else { return false }
        if detail.contains(point) { return true }
        // Only bridge the physical gap alongside both surfaces; no giant
        // transparent window is allocated for this pointer grace corridor.
        let gap = CGRect(x: min(rail.maxX, detail.maxX),
                         y: max(rail.minY, detail.minY),
                         width: max(0, max(rail.minX, detail.minX) - min(rail.maxX, detail.maxX)),
                         height: max(0, min(rail.maxY, detail.maxY) - max(rail.minY, detail.minY)))
        return gap.contains(point)
    }
}

struct QuotaSidebarQuotaPresentation {
    let window: AccountQuotaWindow?
    let stale: Bool
    var remaining: Int? { window?.remainingPercent }
    var text: String { remaining.map { "\($0)%" } ?? "未知" }
    var accessibilityText: String { stale ? "\(text)，旧数据" : text }

    static func make(window: AccountQuotaWindow?, snapshot: AccountQuotaSnapshot,
                     now: Date = Date()) -> Self {
        Self(window: window, stale: snapshot.staleDataDisplayed
             || (snapshot.updatedAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? (window != nil))
             || window?.resetsAt.map { $0 <= now } == true)
    }
}


struct QuotaSidebarModelUsageItem: Identifiable, Equatable {
    let id: String
    let tokens: Int
    let share: Double
    var label: String { id.isEmpty ? "未知模型" : id }
}

enum QuotaSidebarModelUsage {
    // Percentages use all positively measured model tokens as denominator,
    // including models outside the visible top four. No placeholder models.
    static func items(snapshot: TokenDisplaySnapshot) -> [QuotaSidebarModelUsageItem] {
        guard snapshot.hasPreciseTokenUsage, snapshot.metadataOnlyStatusText == nil else { return [] }
        var totals: [String: Int] = [:]
        for row in snapshot.todayModelBreakdowns where row.breakdown.totalTokens > 0 {
            let key = row.model ?? ""
            let result = (totals[key] ?? 0).addingReportingOverflow(row.breakdown.totalTokens)
            totals[key] = result.overflow ? Int.max : result.partialValue
        }
        let total = totals.values.reduce(0.0) { $0 + Double($1) }
        guard total > 0 else { return [] }
        let measured: [QuotaSidebarModelUsageItem] = totals.map { key, tokens in
            QuotaSidebarModelUsageItem(id: key, tokens: tokens, share: Double(tokens) / total)
        }
        let ranked = measured.sorted { left, right in
            if left.tokens == right.tokens { return left.id < right.id }
            return left.tokens > right.tokens
        }
        return Array(ranked.prefix(4))
    }
}


struct QuotaSidebarPlacement: Codable, Equatable {
    static let defaultsKey = "quotaSidebarPlacementV1"
    let displayID: UInt32
    let normalizedY: Double

    static func load(defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data),
              saved.normalizedY.isFinite else { return nil }
        return Self(displayID: saved.displayID, normalizedY: min(1, max(0, saved.normalizedY)))
    }

    func save(defaults: UserDefaults) {
        guard normalizedY.isFinite, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func fraction(centerY: CGFloat, usableFrame: CGRect) -> Double {
        guard usableFrame.height > 0 else { return 0.5 }
        return min(1, max(0, Double((centerY - usableFrame.minY) / usableFrame.height)))
    }

    static func edge(at point: CGPoint, usableFrame: CGRect) -> QuotaSidebarEdge {
        abs(point.x - usableFrame.minX) <= abs(point.x - usableFrame.maxX) ? .left : .right
    }

    // AppStorage reports may arrive after a native drag. The persisted side
    // is authoritative and prevents a stale runtime report moving us back.
    static func resolvedEdge(requested: QuotaSidebarEdge, defaults: UserDefaults) -> QuotaSidebarEdge {
        defaults.string(forKey: QuotaSidebarSettings.edgeKey).flatMap(QuotaSidebarEdge.init(rawValue:)) ?? requested
    }

    static func nearestScreenIndex(to point: CGPoint, frames: [CGRect]) -> Int? {
        if let index = frames.firstIndex(where: { $0.contains(point) }) { return index }
        return frames.indices.min { distance(point, to: frames[$0]) < distance(point, to: frames[$1]) }
    }

    private static func distance(_ point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}

enum QuotaSidebarMotion {
    // The released frame may straddle a display. Interpolate from that exact
    // frame; clamping the first tick would introduce a visible position jump.
    static func snapFrame(from: CGRect, to: CGRect, time: Double, area _: CGRect, scale: CGFloat) -> CGRect {
        if time <= 0 { return from }
        if time >= 1 { return to }
        let p = CGFloat(progress(time, expanding: false))
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            ((a + (b - a) * p) * safeScale).rounded() / safeScale
        }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }

    static func progress(_ time: Double, expanding: Bool) -> Double {
        guard time > 0 else { return 0 }
        guard time < 1 else { return 1 }
        return expanding
            ? (1 - (1 + 8 * time) * exp(-8 * time)) / (1 - 9 * exp(-8))
            : 1 - pow(1 - time, 3)
    }

    static func frame(from: CGRect, to: CGRect, time: Double, expanding: Bool,
                      edge: QuotaSidebarEdge, area: CGRect, scale: CGFloat) -> CGRect {
        if time >= 1 { return to }
        if time <= 0 { return from }
        let p = CGFloat(progress(time, expanding: expanding))
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let left = ceil(area.minX * safeScale) / safeScale
        let right = floor(area.maxX * safeScale) / safeScale
        let bottom = ceil(area.minY * safeScale) / safeScale
        let top = floor(area.maxY * safeScale) / safeScale
        func size(_ a: CGFloat, _ b: CGFloat, limit: CGFloat) -> CGFloat {
            floor(min(limit, max(1 / safeScale, a + (b - a) * p)) * safeScale) / safeScale
        }
        let width = size(from.width, to.width, limit: right - left)
        let height = size(from.height, to.height, limit: top - bottom)
        let center = from.midY + (to.midY - from.midY) * p
        let y = min(max(bottom, ((center - height / 2) * safeScale).rounded() / safeScale), top - height)
        return CGRect(x: edge == .left ? left : right - width,
                      y: (y * safeScale).rounded() / safeScale, width: width, height: height)
    }
}

enum QuotaSidebarRatePresentation {
    static func fraction(rate: Double, fullScale: Double, available: Bool) -> Double {
        guard available, rate.isFinite, rate > 0 else { return 0 }
        let scale = TokenRateScaleSettings.clamped(fullScale.isFinite ? fullScale : TokenRateScaleSettings.defaultValue)
        return min(rate / scale, 1)
    }
}

struct QuotaSidebarDragSession {
    static let threshold: CGFloat = 5
    private(set) var startPoint: CGPoint
    private(set) var startFrame: CGRect
    private(set) var didDrag = false

    mutating func reanchor(point: CGPoint, frame: CGRect) {
        startPoint = point
        startFrame = frame
        didDrag = true
    }

    mutating func update(to point: CGPoint) -> CGRect? {
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        if !didDrag {
            guard dx * dx + dy * dy >= Self.threshold * Self.threshold else { return nil }
            didDrag = true
        }
        return startFrame.offsetBy(dx: dx, dy: dy)
    }
}


/// The compact rail is draggable everywhere. Expanded rows belong to their
/// buttons; the top handle and narrow side gutters remain draggable.
enum QuotaSidebarPressRouting {
    static func shouldTrackDrag(expanded: Bool, point: CGPoint, size: CGSize) -> Bool {
        guard expanded else { return true }
        return point.y >= size.height - 28 || point.x < 4 || point.x > size.width - 4
    }
}
