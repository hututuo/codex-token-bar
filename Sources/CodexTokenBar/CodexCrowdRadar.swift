import Foundation

struct CodexCrowdRadarModel: Decodable, Equatable, Sendable, Identifiable {
    let model: String
    let effort: String
    let graded: Int
    let passed: Int
    let passRate: Double
    let cells: Int
    var id: String { "\(model)|\(effort)" }
    var label: String {
        let family = ["Sol", "Terra", "Luna"].first { model.localizedCaseInsensitiveContains($0) } ?? model
        return "\(family) \(effort)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var iq: Double { passRate * 150 }
}

struct CodexCrowdRadarSnapshot: Equatable, Sendable {
    let generatedAt: String
    let taskCount: Int
    let cellCount: Int
    let contributorCount: Int
    let pendingGrades: Int
    let errorGrades: Int
    let models: [CodexCrowdRadarModel]
    var rankedModels: [CodexCrowdRadarModel] {
        models.filter { $0.graded > 0 }.sorted {
            $0.passRate == $1.passRate ? $0.graded > $1.graded : $0.passRate > $1.passRate
        }
    }
    var bestModel: CodexCrowdRadarModel? { rankedModels.first }
}

protocol CodexCrowdRadarReading: Sendable {
    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot
}

struct LiveCodexCrowdRadarReader: CodexCrowdRadarReading, Sendable {
    private static let maxResponseBytes = 8 * 1024 * 1024

    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot {
        async let tableData: Data? = try? read(
            URL(string: "https://api.codexradar.com/api/v1/table")!
        )
        async let leaderboardData = read(
            URL(string: "https://api.codexradar.com/api/v1/leaderboard")!
        )
        return try await CodexCrowdRadarParser.decode(
            tableData: tableData,
            leaderboardData: leaderboardData
        )
    }

    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await CodexRadarNetworkSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CodexRadarReaderError.invalidResponse
        }
        guard !data.isEmpty else { throw CodexRadarReaderError.emptyPayload }
        guard data.count <= Self.maxResponseBytes else { throw CodexRadarReaderError.invalidResponse }
        return data
    }
}
