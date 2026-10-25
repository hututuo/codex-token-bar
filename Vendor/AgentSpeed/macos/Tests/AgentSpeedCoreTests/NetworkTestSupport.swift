import Foundation
import os
@testable import AgentSpeedCore

/// A transport that answers from a script and records every request; no network.
final class ScriptedTransport: HTTPTransport, Sendable {
    enum Answer: Sendable {
        case response(HTTPFetchResponse)
        case failure(HTTPFetchError)
    }

    private struct State {
        var answers: [String: [Answer]] = [:]
        var requests: [HTTPFetchRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Queues answers for a URL; the last one repeats.
    func script(_ url: URL, _ answers: Answer...) {
        state.withLock { $0.answers[url.absoluteString, default: []].append(contentsOf: answers) }
    }

    func reply(_ url: URL, status: Int = 200, body: Data = Data(), etag: String? = nil) {
        script(url, .response(HTTPFetchResponse(status: status, body: body, etag: etag, finalURL: url)))
    }

    var requests: [HTTPFetchRequest] { state.withLock { $0.requests } }
    var requestedURLs: [String] { requests.map(\.url.absoluteString) }

    func get(_ request: HTTPFetchRequest) async throws -> HTTPFetchResponse {
        let answer = state.withLock { state -> Answer? in
            state.requests.append(request)
            let key = request.url.absoluteString
            guard var queue = state.answers[key], !queue.isEmpty else { return nil }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            state.answers[key] = queue
            return next
        }
        switch answer {
        case .response(let response)?:
            guard response.body.count <= request.maxBytes else { throw HTTPFetchError.tooLarge }
            return response
        case .failure(let error)?:
            throw error
        case nil:
            throw HTTPFetchError.transport("offline")
        }
    }
}

/// A clock tests move by hand.
final class TestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ date: Date) {
        current = OSAllocatedUnfairLock(initialState: date)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var function: @Sendable () -> Date { { [self] in now } }
}
