import SwiftUI

/// One row of headroom per opening. While open, spend that space before growing;
/// don't chase disappearing rows until the rail closes and rearms its budget.
struct QuotaSidebarHeightBudget {
    static let verticalPadding: CGFloat = 12
    private(set) var contentHeight: CGFloat = 0
    private(set) var rowHeight: CGFloat = 40
    private(set) var targetHeight: CGFloat?

    mutating func update(contentHeight: CGFloat? = nil, rowHeight: CGFloat? = nil, expanded: Bool, rebase: Bool = false) {
        if rebase { targetHeight = nil }
        if let contentHeight, contentHeight.isFinite, contentHeight > 0 { self.contentHeight = ceil(contentHeight) }
        if let rowHeight, rowHeight.isFinite, rowHeight >= 0 { self.rowHeight = ceil(rowHeight) }
        guard self.contentHeight > 0 else { return }
        let required = self.contentHeight + Self.verticalPadding * 2
        if !expanded || targetHeight == nil {
            targetHeight = max(192, required + self.rowHeight)
        } else if required > targetHeight! {
            targetHeight = required
        }
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
