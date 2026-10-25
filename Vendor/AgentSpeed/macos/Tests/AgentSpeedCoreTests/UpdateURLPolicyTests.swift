import Foundation
import Testing
@testable import AgentSpeedCore

@Suite("Update URL policy")
struct UpdateURLPolicyTests {
    @Test(arguments: [
        "https://api.github.com/repos/zoefix/agent-speed/releases/latest",
        "https://github.com/zoefix/agent-speed/releases/download/v1.2.0/AgentSpeed-macOS.zip",
        "https://github.com/zoefix/agent-speed/releases/download/v1.2.0/SHA256SUMS.txt",
        "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/2?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=300",
        "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r&sv=2018-11-09&sr=b&rscd=attachment",
        "https://github.com:443/zoefix/agent-speed/releases",
        "HTTPS://GitHub.COM/zoefix/agent-speed",
        "https://API.github.com/repos/zoefix/agent-speed/releases/latest",
        "https://github.com",
        "https://github.com/zoefix/agent-speed/releases/download/v1.2.0/Agent%20Speed.zip#fragment",
    ])
    func standardAllowsGitHubHTTPS(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(UpdateURLPolicy.standard.permits(url))
        #expect(UpdateURLPolicy.testing.permits(url))
    }

    @Test(arguments: [
        "http://github.com/zoefix/agent-speed/releases/download/v1.2.0/AgentSpeed-macOS.zip",
        "http://api.github.com/repos/zoefix/agent-speed/releases/latest",
        "https://github.com.evil.com/zoefix/agent-speed",
        "https://api.github.com.evil.com/repos",
        "https://evilgithub.com/zoefix/agent-speed",
        "https://github.co/zoefix",
        "https://github.com./zoefix/agent-speed",
        "https://gist.github.com/zoefix",
        "https://uploads.github.com/repos/zoefix/agent-speed/releases/1/assets",
        "https://raw.githubusercontent.com/zoefix/agent-speed/main/install.sh",
        "https://githubusercontent.com/x",
        "https://evil-objects.githubusercontent.com/x",
        "https://evil.com/github.com",
        "https://evil.com/?next=https://github.com/",
        "https://github%2Ecom.evil.com/x",
        "https://140.82.112.3/zoefix/agent-speed",
        "https://[2606:50c0:8000::153]/zoefix/agent-speed",
        "https://localhost/feed.json",
        "https://user@github.com/zoefix/agent-speed",
        "https://user:secret@github.com/zoefix/agent-speed",
        "https://:secret@github.com/zoefix/agent-speed",
        "https://github.com@evil.com/zoefix/agent-speed",
        "https://github.com:8443/zoefix/agent-speed",
        "https://github.com:80/zoefix/agent-speed",
        "https://github.com:0/zoefix/agent-speed",
        "file:///etc/passwd",
        "file://github.com/etc/passwd",
        "ftp://github.com/zoefix/agent-speed",
        "ws://github.com/socket",
        "wss://github.com/socket",
        "data:text/plain,github.com",
        "javascript:alert(1)",
        "about:blank",
        "github.com/zoefix/agent-speed",
        "//github.com/zoefix/agent-speed",
        "/zoefix/agent-speed/releases",
        "https:///zoefix/agent-speed",
        "https://gіthub.com/zoefix/agent-speed",
    ])
    func standardRejects(text: String) {
        #expect(!UpdateURLPolicy.standard.permits(URL(string: text)))
    }

    @Test func rejectsMissingURL() {
        #expect(!UpdateURLPolicy.standard.permits(nil))
        #expect(!UpdateURLPolicy.testing.permits(nil))
    }

    @Test func checksEveryRedirectHopIndependently() throws {
        let hops = [
            "https://github.com/zoefix/agent-speed/releases/download/v1.2.0/AgentSpeed-macOS.zip",
            "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r",
        ]
        let urls = try hops.map { try #require(URL(string: $0)) }
        #expect(urls.allSatisfy { UpdateURLPolicy.standard.permits($0) })
        let hijacked = try #require(URL(string: "https://release-assets.githubusercontent.com.attacker.example/1/2"))
        #expect(!(urls + [hijacked]).allSatisfy { UpdateURLPolicy.standard.permits($0) })
    }

    @Test(arguments: [
        "http://localhost:8080/releases/latest",
        "http://127.0.0.1:9999/AgentSpeed-macOS.zip",
        "http://[::1]:8080/feed.json",
        "https://staging.example.com/releases/latest",
        "http://github.com/zoefix/agent-speed",
        "https://github.com:8443/zoefix/agent-speed",
        "HTTP://LOCALHOST/feed.json",
    ])
    func testingAllowsAnyHTTPHost(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(UpdateURLPolicy.testing.permits(url))
    }

    @Test(arguments: [
        "file:///tmp/feed.json",
        "file://localhost/tmp/feed.json",
        "ftp://localhost/feed.json",
        "data:application/json,{}",
        "javascript:alert(1)",
        "ws://localhost:8080/",
        "localhost:8080/feed.json",
        "/tmp/feed.json",
        "http:///feed.json",
    ])
    func testingStillRejectsOtherSchemes(text: String) {
        #expect(!UpdateURLPolicy.testing.permits(URL(string: text)))
    }

    @Test func fileURLsAreNeverPermitted() {
        let url = URL(fileURLWithPath: "/tmp/AgentSpeed-macOS.zip")
        #expect(!UpdateURLPolicy.standard.permits(url))
        #expect(!UpdateURLPolicy.testing.permits(url))
    }

    @Test func presetsAndHostList() {
        #expect(UpdateURLPolicy.standard == UpdateURLPolicy(allowsAnyHost: false))
        #expect(UpdateURLPolicy.testing == UpdateURLPolicy(allowsAnyHost: true))
        #expect(UpdateURLPolicy.allowedHosts == [
            "github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        ])
    }
}
