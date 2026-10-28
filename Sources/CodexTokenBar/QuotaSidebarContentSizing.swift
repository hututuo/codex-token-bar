import SwiftUI

/// Fit the current intrinsic content in both directions. Native frame motion
/// supplies the transition; no extra model row or previous high-water is kept.
struct QuotaSidebarHeightBudget {
    static let verticalPadding: CGFloat = 12
    static let minimumHeight: CGFloat = 90 // actions + settings + normal padding
    private(set) var contentHeight: CGFloat = 0
    private(set) var targetHeight: CGFloat?

    mutating func update(contentHeight: CGFloat? = nil, rowHeight _: CGFloat? = nil, expanded _: Bool, rebase _: Bool = false) {
        if let contentHeight, contentHeight.isFinite, contentHeight > 0 { self.contentHeight = ceil(contentHeight) }
        guard self.contentHeight > 0 else { return }
        targetHeight = max(Self.minimumHeight, self.contentHeight + Self.verticalPadding * 2)
    }
}

struct QuotaSidebarContentMeasurement: Equatable {
    var contentHeight: CGFloat = 0
    var speedRowHeight: CGFloat = 0
}

struct QuotaSidebarContentMeasurementKey: PreferenceKey {
    static let defaultValue = QuotaSidebarContentMeasurement()
    static func reduce(value: inout QuotaSidebarContentMeasurement, nextValue: () -> QuotaSidebarContentMeasurement) {
        let next = nextValue()
        value.contentHeight = max(value.contentHeight, next.contentHeight)
        value.speedRowHeight = max(value.speedRowHeight, next.speedRowHeight)
    }
}
