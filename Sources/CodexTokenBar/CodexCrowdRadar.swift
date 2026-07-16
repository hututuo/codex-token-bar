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
        return "\(family) \(effort)"
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
    var bestModel: CodexCrowdRadarModel? {
        models.filter { $0.graded > 0 }.sorted {
            $0.passRate == $1.passRate ? $0.graded > $1.graded : $0.passRate > $1.passRate
        }.first
    }
}

protocol CodexCrowdRadarReading: Sendable {
    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot
}

struct LiveCodexCrowdRadarReader: CodexCrowdRadarReading, Sendable {
    private struct Table: Decodable { let baselineGeneratedAt: String; let tasks: [TaskRow]; let cells: [String: Cell] }
    private struct TaskRow: Decodable {}
    private struct Cell: Decodable {}
    private struct Leaderboard: Decodable {
        let models: [CodexCrowdRadarModel]
        let contributors: [Contributor]
        let pendingGrades: Int
        let errorGrades: Int
    }
    private struct Contributor: Decodable {}

    func readCrowdRadar() async throws -> CodexCrowdRadarSnapshot {
        async let tableData = read(URL(string: "https://api.codexradar.com/api/v1/table")!)
        async let leaderboardData = read(URL(string: "https://api.codexradar.com/api/v1/leaderboard")!)
        let decoder = JSONDecoder.codexRadar
        let table = try decoder.decode(Table.self, from: await tableData)
        let leaderboard = try decoder.decode(Leaderboard.self, from: await leaderboardData)
        return CodexCrowdRadarSnapshot(
            generatedAt: table.baselineGeneratedAt,
            taskCount: table.tasks.count,
            cellCount: table.cells.count,
            contributorCount: leaderboard.contributors.count,
            pendingGrades: leaderboard.pendingGrades,
            errorGrades: leaderboard.errorGrades,
            models: leaderboard.models
        )
    }

    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("CodexTokenBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw CodexRadarReaderError.invalidResponse
        }
        guard !data.isEmpty else { throw CodexRadarReaderError.emptyPayload }
        return data
    }
}
