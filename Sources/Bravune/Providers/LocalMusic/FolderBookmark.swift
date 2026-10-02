import Foundation

/// Persistent, security-scoped bookmark for the Local Music folder.
/// A sandboxed (App Store) build loses access to a user-chosen folder after relaunch
/// unless the folder is stored as a bookmark and re-opened with security scope.
enum FolderBookmark {
    struct Resolved {
        let url: URL
        let isStale: Bool
    }

    static func make(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) -> Resolved? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return Resolved(url: url, isStale: stale)
    }
}
