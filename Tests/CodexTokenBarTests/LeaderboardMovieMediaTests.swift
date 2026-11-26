import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import CodexTokenBar

@MainActor
final class LeaderboardMovieMediaTests: XCTestCase {
    @MainActor
    private final class State: ObservableObject {
        @Published var visible = true
        @Published var revision = 0
        var renderedRevision = -1
        var creations = 0
        weak var media: SpeedLeaderboardMovieMedia?

        func makeMedia() -> SpeedLeaderboardMovieMedia {
            creations += 1
            let media = SpeedLeaderboardMovieMedia(player: AVPlayer(), poster: NSImage(size: .init(width: 20, height: 12)))
            self.media = media
            return media
        }
    }

    private struct Harness: View {
        @ObservedObject var state: State

        var body: some View {
            VStack {
                Text("Revision \(state.revision)")
                    .onAppear { state.renderedRevision = state.revision }
                    .onChange(of: state.revision) { _, value in state.renderedRevision = value }
                if state.visible {
                    SpeedLeaderboardMovie(makeMedia: state.makeMedia)
                }
            }
        }
    }

    func testUnpresentedMovieDoesNotConstructPlayerOrPoster() {
        let state = State()
        let movie = SpeedLeaderboardMovie(makeMedia: state.makeMedia)
        withExtendedLifetime(movie) {
            XCTAssertEqual(state.creations, 0, "Creating a transient View value must not allocate its media.")
            XCTAssertNil(state.media)
        }
    }

    func testMountedMovieReusesMediaAcrossParentUpdatesAndReleasesOnRemoval() async throws {
        let state = State()
        let host = NSHostingView(rootView: Harness(state: state))
        let window = NSWindow(contentRect: .init(x: 150, y: 150, width: 520, height: 380),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFrontRegardless()
        try await waitUntil(host: host) {
            state.creations == 1 && state.renderedRevision == 0 && state.media?.player.isMuted == true
        }
        XCTAssertNotNil(state.media)
        XCTAssertEqual(state.media?.player.isMuted, true)

        for revision in 1...5 {
            state.revision = revision
            try await waitUntil(host: host) { state.renderedRevision == revision }
            XCTAssertEqual(state.creations, 1, "Each confirmed parent redraw must reuse the mounted media owner.")
            XCTAssertNotNil(state.media)
        }

        state.visible = false
        try await waitUntil(host: host) { state.media == nil }
        XCTAssertEqual(state.creations, 1)
        state.revision = 6
        try await waitUntil(host: host) { state.renderedRevision == 6 }
        XCTAssertNil(state.media, "Hidden parent updates must not recreate the removed movie's resources.")
        XCTAssertEqual(state.creations, 1)

        state.visible = true
        try await waitUntil(host: host) { state.creations == 2 && state.media?.player.isMuted == true }
        XCTAssertEqual(state.media?.player.isMuted, true)
    }

    private func waitUntil<Content: View>(host: NSHostingView<Content>, _ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ready(), "The native hosting tree must deliver the requested lifecycle transition.")
    }
}
