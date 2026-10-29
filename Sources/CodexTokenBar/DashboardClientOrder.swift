import Foundation

/// Strict, stable client ordering shared by the dashboard's lazy row IDs.
enum DashboardClientOrder {
    static func sorted(_ clients: Set<String>) -> [String] {
        clients.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == "codex" { return true }
            if rhs == "codex" { return false }
            return lhs < rhs
        }
    }
}
