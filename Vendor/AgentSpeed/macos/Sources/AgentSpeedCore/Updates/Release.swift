import Foundation

/// One downloadable file of a release.
public struct ReleaseAsset: Sendable, Hashable {
    public let name: String
    public let downloadURL: URL
    public let size: Int64

    public init(name: String, downloadURL: URL, size: Int64) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
    }
}

/// The fields of a GitHub release that updates use (UPDATES section 1).
public struct Release: Sendable, Hashable, Identifiable {
    public let tag: String
    public let version: SemanticVersion
    public let name: String
    /// Release notes in Markdown.
    public let notes: String
    public let pageURL: URL?
    public let publishedAt: Date?
    public let assets: [ReleaseAsset]

    public init(
        tag: String,
        version: SemanticVersion,
        name: String = "",
        notes: String = "",
        pageURL: URL? = nil,
        publishedAt: Date? = nil,
        assets: [ReleaseAsset] = []
    ) {
        self.tag = tag
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    public var id: String { tag }

    public func asset(named name: String) -> ReleaseAsset? {
        assets.first { $0.name == name }
    }
}

public enum ReleaseFeedError: Error, Equatable, Sendable {
    /// The response is not a release object.
    case malformed
    /// The tag is not a version Agent Speed understands; such releases never update.
    case unsupportedTag
    /// Drafts and pre-releases are never offered.
    case notPublished
}

/// Decodes `GET /repos/{owner}/{repo}/releases/latest`.
public enum ReleaseFeed {
    /// Upper bound for the response body; a release with long notes is a few hundred KiB at most.
    public static let maxBytes = 2 << 20

    public static func decode(_ data: Data) throws -> Release {
        guard data.count <= maxBytes else { throw ReleaseFeedError.malformed }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ReleaseFeedError.malformed
        }
        if payload.draft == true || payload.prerelease == true { throw ReleaseFeedError.notPublished }
        guard let version = SemanticVersion(payload.tagName) else { throw ReleaseFeedError.unsupportedTag }
        guard !version.isPrerelease else { throw ReleaseFeedError.notPublished }
        let assets = (payload.assets ?? []).compactMap { asset -> ReleaseAsset? in
            guard let url = URL(string: asset.browserDownloadURL), asset.size >= 0 else { return nil }
            return ReleaseAsset(name: asset.name, downloadURL: url, size: asset.size)
        }
        return Release(
            tag: payload.tagName,
            version: version,
            name: payload.name ?? "",
            notes: payload.body ?? "",
            pageURL: payload.htmlURL.flatMap(URL.init(string:)),
            publishedAt: payload.publishedAt.flatMap { try? Date($0, strategy: .iso8601) },
            assets: assets
        )
    }

    private struct Payload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String?
        let publishedAt: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case draft, prerelease, assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }
}
