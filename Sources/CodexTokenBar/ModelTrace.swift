import CryptoKit
import Foundation
import JavaScriptCore

enum ModelTrace {
    static let defaultModel = "gpt-6.1-sol"
    static let effort = "low"
    static let counts = [307, 319, 331]
    static let upstreamCommit = "d4131b30243dfa05e70180b5eedde742103f1d73"
    static let models = [defaultModel, "gpt-5.4", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func fail(_ text: String) -> Failure { Failure(message: text) }
    static func resource(_ file: String) throws -> URL {
        guard let folder = AppResources.url(forResource: "ModelTrace", withExtension: nil) else { throw fail("缺少 ModelTrace 参考库") }
        return folder.appendingPathComponent(file)
    }
    static func parse(_ text: String, expected: Int) throws -> Sample {
        guard text.utf8.count <= 5_000 else { throw fail("回答超过长度上限") }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") || body.hasPrefix("~~~") {
            var lines = body.components(separatedBy: "\n")
            guard lines.count >= 3 else { throw fail("JSON 代码块不完整") }
            let header = lines.removeFirst().trimmingCharacters(in: .whitespaces)
            let fence = String(header.prefix(while: { $0 == header.first }))
            guard ["", "json"].contains(header.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).lowercased()), lines.removeLast().trimmingCharacters(in: .whitespaces) == fence else { throw fail("只接受完整 JSON 整数数组") }
            body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.utf8.allSatisfy({ (48...57).contains($0) || [9, 10, 13, 32, 44, 45, 91, 93].contains($0) }),
              let data = body.data(using: .utf8), let numbers = try? JSONDecoder().decode([Int].self, from: data) else { throw fail("只接受完整 JSON 整数数组") }
        let minimum = max(80, Int(ceil(Double(expected) * 0.55)))
        let accepted = numbers.filter { (1...355).contains($0) }
        guard numbers.count >= minimum, numbers.count <= Int(ceil(Double(expected) * 1.25)), accepted.count >= minimum else { throw fail("回答中的有效整数数量不足或超出范围") }
        return Sample(expectedCount: expected, returnedCount: numbers.count, outOfRangeCount: numbers.count - accepted.count, numbers: accepted, usage: nil)
    }
    static func analyze(_ samples: [Sample]) throws -> Attribution {
        guard samples.count == 3 else { throw fail("需要三份有效回答") }
        let bankData = try Data(contentsOf: resource("unified_bank.json"))
        let core = try String(contentsOf: resource("fingerprint-core.js"), encoding: .utf8)
            .replacingOccurrences(of: "export ", with: "")
        guard let context = JSContext() else { throw fail("无法初始化本地评分器") }
        context.evaluateScript(core)
        guard context.exception == nil else { throw fail("本地评分器载入失败") }
        let outputs = try samples.map { sample in
            ["text": String(decoding: try JSONEncoder().encode(sample.numbers), as: UTF8.self), "expected_count": sample.expectedCount] as [String: Any]
        }
        let outputsJSON = String(decoding: try JSONSerialization.data(withJSONObject: outputs), as: UTF8.self)
        let bankJSON = String(decoding: bankData, as: UTF8.self)
        let result = context.evaluateScript("JSON.stringify(analyzeGlobalOutputs(\(outputsJSON), \(bankJSON)))")
        guard context.exception == nil, let text = result?.toString(), let bytes = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let prediction = object["prediction"] as? String, let entries = object["results"] as? [[String: Any]],
              let calibration = object["calibration"] as? [String: Any], let beta = calibration["beta"] as? Double else { throw fail("本地指纹评分失败") }
        let candidates = try entries.map { row -> Candidate in
            guard let model = row["model"] as? String, let probability = row["probability"] as? Double,
                  let similarity = row["profile_similarity"] as? Double, let score = row["score"] as? Double,
                  probability.isFinite, similarity.isFinite, score.isFinite else { throw fail("指纹评分产生无效数值") }
            return Candidate(model: model, displayName: row["display_name"] as? String ?? model, family: row["family"] as? String ?? "", probability: probability, profileSimilarity: similarity, score: score)
        }
        return Attribution(prediction: prediction, candidates: candidates, usedOutputs: 3,
            bankSha256: SHA256.hash(data: bankData).map { String(format: "%02x", $0) }.joined(), upstreamCommit: upstreamCommit, beta: beta)
    }
    static func message(model: String, attribution: Attribution) -> String {
        if model == defaultModel { return "更接近 \(attribution.prediction) 特征。参考库未收录 6.1 Sol；本配置未经独立验证，不能据此确认模型身份或排除 Luna。" }
        return "更接近 \(attribution.prediction) 特征；相对匹配分值不是模型身份正确率。"
    }
    struct Sample: Codable, Equatable, Sendable {
        var expectedCount: Int; var returnedCount: Int; var outOfRangeCount: Int; var numbers: [Int]; var usage: [String: Int]?
    }
    struct Candidate: Codable, Equatable, Identifiable, Sendable {
        var model: String; var displayName: String; var family: String; var probability: Double; var profileSimilarity: Double; var score: Double
        var id: String { model }
    }
    struct Attribution: Codable, Equatable, Sendable {
        var prediction: String; var candidates: [Candidate]; var usedOutputs: Int; var bankSha256: String; var upstreamCommit: String; var beta: Double
    }
    struct Run: Codable, Equatable, Identifiable, Sendable {
        var id = UUID().uuidString; var model: String; var effort = ModelTrace.effort; var startedAt = Int(Date().timeIntervalSince1970)
        var completedAt: Int?; var status = "running"; var attempts = 0; var validSamples = 0; var message: String?; var attribution: Attribution?; var samples: [Sample] = []
    }
}

struct ModelTraceHistoryStore: Sendable {
    let url: URL
    func save(_ run: ModelTrace.Run, scope: String) throws {
        let json = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        try database().execute("INSERT INTO modeltrace_runs(scope,id,started_at,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE scope=excluded.scope", bindings: [.text(scope), .text(run.id), .int64(Int64(run.startedAt)), .text(json)])
    }
    func history(scope: String) throws -> [ModelTrace.Run] {
        try database().readRows("SELECT payload FROM modeltrace_runs WHERE scope=? ORDER BY started_at DESC,id DESC LIMIT 100", bindings: [.text(scope)]) { statement in
            try JSONDecoder().decode(ModelTrace.Run.self, from: Data((statement.text(0) ?? "").utf8))
        }
    }
    private func database() throws -> SQLiteDatabaseDriver {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = SQLiteDatabaseDriver(url: url)
        try db.execute("CREATE TABLE IF NOT EXISTS modeltrace_runs(scope TEXT NOT NULL,id TEXT PRIMARY KEY,started_at INTEGER NOT NULL,payload TEXT NOT NULL); CREATE INDEX IF NOT EXISTS modeltrace_scope_time ON modeltrace_runs(scope,started_at DESC);")
        return db
    }
}
