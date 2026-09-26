import Foundation

struct QuotaSidebarResetTimePresentation: Equatable {
    let date: String
    let time: String

    static func make(_ reset: Date?, calendar: Calendar = .autoupdatingCurrent) -> Self? {
        guard let reset, reset.timeIntervalSince1970.isFinite else { return nil }
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: reset)
        guard let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute else { return nil }
        return Self(date: "\(month)/\(day)", time: String(format: "%02d:%02d", hour, minute))
    }
}

enum QuotaSidebarRecommendationPaging {
    static let pageSize = 3
    static let interval: Duration = .seconds(4)
    static func pageCount(_ count: Int) -> Int { (max(0, count) + pageSize - 1) / pageSize }
    static func range(page: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let start = (max(0, page) % pageCount(count)) * pageSize
        return start..<min(count, start + pageSize)
    }
    static func next(page: Int, count: Int) -> Int {
        let pages = pageCount(count)
        return pages > 1 ? (max(0, page) % pages + 1) % pages : 0
    }
}
