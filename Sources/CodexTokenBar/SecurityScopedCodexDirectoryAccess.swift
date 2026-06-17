import Foundation

final class SecurityScopedCodexDirectoryAccess {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private var activeURL: URL?

    init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = "CodexTokenBar.selectedCodexHomeBookmark"
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

    deinit {
        activeURL?.stopAccessingSecurityScopedResource()
    }

    func saveAccess(for directory: URL) {
        guard let data = try? directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        defaults.set(data, forKey: bookmarkKey)
    }

    func restoreAccess() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            defaults.removeObject(forKey: bookmarkKey)
            return nil
        }

        if activeURL != url {
            activeURL?.stopAccessingSecurityScopedResource()
            if url.startAccessingSecurityScopedResource() {
                activeURL = url
            }
        }

        if isStale {
            saveAccess(for: url)
        }
        return url
    }
}
