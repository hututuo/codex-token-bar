import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Release feed")
struct ReleaseFeedTests {
    static let downloadBase = "https://github.com/zoefix/agent-speed/releases/download/v1.2.0"

    /// Shaped like a real `GET /repos/{owner}/{repo}/releases/latest` response, including fields updates ignore.
    static func latestJSON(
        tag: String = "v1.2.0",
        name: String = #""Agent Speed v1.2.0""#,
        body: String = ###""## What's Changed\r\n* Automatic updates by @zoefix in https://github.com/zoefix/agent-speed/pull/42\r\n\r\n**Full Changelog**: https://github.com/zoefix/agent-speed/compare/v1.1.0...v1.2.0""###,
        draft: String = "false",
        prerelease: String = "false",
        publishedAt: String = #""2026-10-01T08:30:00Z""#
    ) -> Data {
        let json = """
        {
          "url": "https://api.github.com/repos/zoefix/agent-speed/releases/250000001",
          "assets_url": "https://api.github.com/repos/zoefix/agent-speed/releases/250000001/assets",
          "upload_url": "https://uploads.github.com/repos/zoefix/agent-speed/releases/250000001/assets{?name,label}",
          "html_url": "https://github.com/zoefix/agent-speed/releases/tag/\(tag)",
          "id": 250000001,
          "author": {
            "login": "github-actions[bot]", "id": 41898282, "node_id": "MDM6Qm90NDE4OTgyODI=",
            "avatar_url": "https://avatars.githubusercontent.com/in/15368?v=4", "type": "Bot", "site_admin": false
          },
          "node_id": "RE_kwDOOabcde4O5p6q",
          "tag_name": "\(tag)",
          "target_commitish": "main",
          "name": \(name),
          "draft": \(draft),
          "immutable": false,
          "prerelease": \(prerelease),
          "created_at": "2026-10-01T08:21:13Z",
          "updated_at": "2026-10-01T08:30:01Z",
          "published_at": \(publishedAt),
          "assets": [
            \(asset(id: 1, name: "AgentSpeed-macOS.zip", contentType: "application/zip", size: 4_194_304)),
            \(asset(id: 2, name: "AgentSpeed-Windows-x64.zip", contentType: "application/zip", size: 31_457_280)),
            \(asset(id: 3, name: "AgentSpeed-Windows-arm64.zip", contentType: "application/zip", size: 30_408_704)),
            \(asset(id: 4, name: "SHA256SUMS.txt", contentType: "text/plain", size: 279))
          ],
          "tarball_url": "https://api.github.com/repos/zoefix/agent-speed/tarball/\(tag)",
          "zipball_url": "https://api.github.com/repos/zoefix/agent-speed/zipball/\(tag)",
          "body": \(body),
          "reactions": {"url": "https://api.github.com/repos/zoefix/agent-speed/releases/250000001/reactions", "total_count": 3, "+1": 3},
          "mentions_count": 1
        }
        """
        return Data(json.utf8)
    }

    static func asset(id: Int, name: String, contentType: String, size: Int) -> String {
        """
        {
              "url": "https://api.github.com/repos/zoefix/agent-speed/releases/assets/\(id)",
              "id": \(id), "node_id": "RA_kwDOOabcde4M\(id)", "name": "\(name)", "label": null,
              "uploader": {"login": "github-actions[bot]", "id": 41898282, "type": "Bot"},
              "content_type": "\(contentType)", "state": "uploaded", "size": \(size),
              "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
              "download_count": 17, "created_at": "2026-10-01T08:29:40Z", "updated_at": "2026-10-01T08:29:41Z",
              "browser_download_url": "\(downloadBase)/\(name)"
            }
        """
    }

    @Test func decodesRealisticRelease() throws {
        let release = try ReleaseFeed.decode(Self.latestJSON())
        #expect(release.tag == "v1.2.0")
        #expect(release.id == "v1.2.0")
        #expect(release.version == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(release.name == "Agent Speed v1.2.0")
        #expect(release.notes.hasPrefix("## What's Changed\r\n* Automatic updates by @zoefix"))
        #expect(release.notes.hasSuffix("compare/v1.1.0...v1.2.0"))
        #expect(release.pageURL == URL(string: "https://github.com/zoefix/agent-speed/releases/tag/v1.2.0"))
        #expect(release.publishedAt == Date(timeIntervalSince1970: 1_790_843_400))
        #expect(release.assets.map(\.name) == [
            "AgentSpeed-macOS.zip", "AgentSpeed-Windows-x64.zip", "AgentSpeed-Windows-arm64.zip", "SHA256SUMS.txt",
        ])
        let macOS = try #require(release.asset(named: "AgentSpeed-macOS.zip"))
        #expect(macOS == ReleaseAsset(
            name: "AgentSpeed-macOS.zip",
            downloadURL: try #require(URL(string: "\(Self.downloadBase)/AgentSpeed-macOS.zip")),
            size: 4_194_304
        ))
        #expect(release.asset(named: "SHA256SUMS.txt")?.size == 279)
        #expect(release.asset(named: "agentspeed-macos.zip") == nil)
        #expect(release.asset(named: "AgentSpeed-Linux.zip") == nil)
    }

    @Test func nullNameBodyAndDateBecomeEmpty() throws {
        let release = try ReleaseFeed.decode(Self.latestJSON(name: "null", body: "null", publishedAt: "null"))
        #expect(release.name == "")
        #expect(release.notes == "")
        #expect(release.publishedAt == nil)
        #expect(release.assets.count == 4)
    }

    @Test func unreadableDateIsIgnored() throws {
        let release = try ReleaseFeed.decode(Self.latestJSON(publishedAt: #""yesterday""#))
        #expect(release.publishedAt == nil)
        #expect(release.version == SemanticVersion(major: 1, minor: 2, patch: 0))
    }

    @Test func unicodeNotesSurvive() throws {
        let release = try ReleaseFeed.decode(Self.latestJSON(body: #""更新：速度表 🚀\n- 修正""#))
        #expect(release.notes == "更新：速度表 🚀\n- 修正")
    }

    @Test func minimalReleaseUsesDefaults() throws {
        let release = try ReleaseFeed.decode(Data(#"{"tag_name":"1.0.1"}"#.utf8))
        #expect(release == Release(tag: "1.0.1", version: SemanticVersion(major: 1, minor: 0, patch: 1)))
        #expect(release.pageURL == nil)
        #expect(release.assets.isEmpty)
    }

    @Test func nullAssetsAndFlagsAreAccepted() throws {
        let json = #"{"tag_name":"v2.0.0","draft":null,"prerelease":null,"assets":null,"html_url":null}"#
        let release = try ReleaseFeed.decode(Data(json.utf8))
        #expect(release.version == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(release.assets.isEmpty)
    }

    @Test func dropsAssetsWithoutUsableURLOrSize() throws {
        let json = """
        {"tag_name": "v1.0.0", "assets": [
          {"name": "ok.zip", "browser_download_url": "https://github.com/o/r/releases/download/v1.0.0/ok.zip", "size": 10},
          {"name": "negative.zip", "browser_download_url": "https://github.com/o/r/negative.zip", "size": -1},
          {"name": "empty-url.zip", "browser_download_url": "", "size": 10},
          {"name": "empty.txt", "browser_download_url": "https://github.com/o/r/empty.txt", "size": 0}
        ]}
        """
        let release = try ReleaseFeed.decode(Data(json.utf8))
        #expect(release.assets.map(\.name) == ["ok.zip", "empty.txt"])
    }

    @Test(arguments: [
        ("true", "false"), ("false", "true"), ("true", "true"),
    ])
    func draftsAndPrereleasesAreNotOffered(draft: String, prerelease: String) {
        #expect(throws: ReleaseFeedError.notPublished) {
            try ReleaseFeed.decode(Self.latestJSON(draft: draft, prerelease: prerelease))
        }
    }

    @Test(arguments: ["v1.3.0-beta.1", "1.3.0-rc.1", "v2.0.0-0+build"])
    func prereleaseTagsAreNotOffered(tag: String) {
        #expect(throws: ReleaseFeedError.notPublished) {
            try ReleaseFeed.decode(Self.latestJSON(tag: tag))
        }
    }

    @Test(arguments: ["nightly", "latest", "1.2", "V1.2.0", "v01.2.0", "release-1.2.0", "v1.2.0.1", ""])
    func unparseableTagsAreUnsupported(tag: String) {
        #expect(throws: ReleaseFeedError.unsupportedTag) {
            try ReleaseFeed.decode(Self.latestJSON(tag: tag))
        }
    }

    @Test(arguments: [
        "", " ", "null", "[]", "{}", "42", #""v1.0.0""#, "not json", "<!DOCTYPE html><html><body>Unicorn!</body></html>",
        #"{"tag_name": 5}"#, #"{"tag_name": null}"#, #"{"name": "v1.0.0"}"#,
        #"{"tag_name": "v1.0.0", "draft": "no"}"#,
        #"{"tag_name": "v1.0.0", "assets": [{"name": "a.zip"}]}"#,
        #"{"tag_name": "v1.0.0""#,
        #"{"message": "Not Found", "documentation_url": "https://docs.github.com/rest/releases/releases#get-the-latest-release", "status": "404"}"#,
        #"{"message": "API rate limit exceeded for 203.0.113.7.", "documentation_url": "https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}"#,
    ])
    func junkIsMalformed(text: String) {
        #expect(throws: ReleaseFeedError.malformed) {
            try ReleaseFeed.decode(Data(text.utf8))
        }
    }

    @Test func invalidUTF8IsMalformed() {
        let bytes: [UInt8] = Array(#"{"tag_name":"v1.0.0","body":""#.utf8) + [0xFF, 0xFE] + Array(#""}"#.utf8)
        #expect(throws: ReleaseFeedError.malformed) {
            try ReleaseFeed.decode(Data(bytes))
        }
    }

    /// A valid release whose body pads the document to exactly `size` bytes.
    static func padded(to size: Int) -> Data {
        let prefix = #"{"tag_name":"v1.0.0","body":""#
        let suffix = #""}"#
        let filler = String(repeating: "a", count: size - prefix.utf8.count - suffix.utf8.count)
        return Data((prefix + filler + suffix).utf8)
    }

    @Test func acceptsResponsesUpToTheLimit() throws {
        let data = Self.padded(to: ReleaseFeed.maxBytes)
        #expect(data.count == 2 * 1024 * 1024)
        let release = try ReleaseFeed.decode(data)
        #expect(release.notes.utf8.count == ReleaseFeed.maxBytes - 31)
    }

    @Test func rejectsOversizedResponses() {
        #expect(throws: ReleaseFeedError.malformed) {
            try ReleaseFeed.decode(Self.padded(to: ReleaseFeed.maxBytes + 1))
        }
        var whitespace = Self.latestJSON()
        whitespace.append(Data(repeating: 0x20, count: ReleaseFeed.maxBytes))
        #expect(throws: ReleaseFeedError.malformed) {
            try ReleaseFeed.decode(whitespace)
        }
    }
}
