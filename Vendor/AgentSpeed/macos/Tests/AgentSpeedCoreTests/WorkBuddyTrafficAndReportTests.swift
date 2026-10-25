import Foundation
import Testing
@testable import AgentSpeedCore

/// WorkBuddy's agent processes (METRICS 10.5) and its sources in live reports (METRICS 11, REPORTING 6.4).
@Suite("WorkBuddy traffic and reports")
struct WorkBuddyTrafficAndReportTests {
    static let cli = "/Applications/WorkBuddy AI.app/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"

    @Test func appBundlesAreFoundByTheirContentsFolder() {
        #expect(ProcessReader.appBundle(containing: "/Applications/WorkBuddy.app/Contents/MacOS/Electron") == "/Applications/WorkBuddy.app")
        #expect(ProcessReader.appBundle(containing: "/Applications/WorkBuddy AI.app/Contents/Frameworks/WorkBuddy AI Helper.app/Contents/MacOS/WorkBuddy AI Helper")
                == "/Applications/WorkBuddy AI.app/Contents/Frameworks/WorkBuddy AI Helper.app")
        #expect(ProcessReader.appBundle(containing: "/Applications/WorkBuddy.app/Contents/Resources/bin/rg") == nil)
        #expect(ProcessReader.appBundle(containing: "/opt/tools/Contents/MacOS/tool") == nil)
        #expect(ProcessReader.appBundle(containing: "/usr/local/bin/node") == nil)
    }

    @Test func bundleIdsAreReadOncePerApp() throws {
        let directory = try TempDirectory()
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.workbuddy.workbuddy-ai", "CFBundleExecutable": "Electron"],
            format: .binary, options: 0)
        let info = directory.file("WB Copy.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: info)
        let reader = ProcessReader()
        let entry = ProcessEntry(pid: 1, ppid: 0, startUs: 0)
        let executable = directory.file("WB Copy.app/Contents/MacOS/Electron").path
        #expect(reader.bundleIdentifier(of: entry, executable: executable) == "com.workbuddy.workbuddy-ai")
        try FileManager.default.removeItem(at: info)
        #expect(reader.bundleIdentifier(of: entry, executable: executable) == "com.workbuddy.workbuddy-ai", "cached per app")
        #expect(reader.bundleIdentifier(of: entry, executable: directory.file("Other.app/Contents/MacOS/Other").path) == nil)
    }

    @Test func onlyTheEmbeddedCLIIsTheAgent() {
        let mac = AgentProcessRules(platform: TrafficPlatform(kind: .macos, home: "/Users/dev"))
        let electron = "/Applications/WorkBuddy AI.app/Contents/MacOS/Electron"
        func source(_ executable: String, bundle: String?, _ arguments: [String]) -> SourceKind? {
            mac.source(executable: executable, arguments: { arguments }, bundleIdentifier: { bundle }, ancestorExecutables: [])
        }
        #expect(source(electron, bundle: "com.workbuddy.workbuddy-ai", [electron, "--max-semi-space-size=2", Self.cli, "--prewarm"]) == .workbuddyAi)
        #expect(source(electron, bundle: "com.tencent.workbuddy.mac", ["wb-acp:1", Self.cli, "--acp"]) == .workbuddy)
        #expect(source(electron, bundle: "com.workbuddy.workbuddy-ai", [Self.cli]) == nil, "the first argument does not count")
        #expect(source(electron, bundle: "com.workbuddy.workbuddy-ai",
                       [electron, "/Applications/WorkBuddy AI.app/Contents/Resources/app.asar/main/daemon-app-server-entry.js"]) == nil)
        #expect(source(electron, bundle: "com.example.other", [electron, Self.cli]) == nil)
        #expect(mac.needsArguments(executable: electron, bundleIdentifier: { "com.workbuddy.workbuddy-ai" }))
        #expect(!mac.needsArguments(executable: electron, bundleIdentifier: { "com.example.other" }))

        let windows = AgentProcessRules(platform: TrafficPlatform(kind: .windows, home: #"C:\Users\dev"#))
        let exe = #"C:\Users\dev\AppData\Local\Programs\WorkBuddy\WorkBuddy.exe"#
        #expect(windows.source(executable: exe, arguments: { [exe, #"C:\Users\dev\AppData\Local\Programs\WorkBuddy\resources\app.asar.unpacked\cli\bin\codebuddy"#, "--serve"] },
                               ancestorExecutables: []) == .workbuddy)
        #expect(windows.needsArguments(executable: #"C:\Programs\WorkBuddy AI\WorkBuddyAI.exe"#, bundleIdentifier: { nil }))
    }

    /// Both editions are reportable sources, in source order after every other source.
    @Test func reportsListBothEditionsInSourceOrder() throws {
        var (content, sample) = ReportBodyTests.busySample()
        content.usage.add(ReportUsage(requests: 1, output: 300, input: 9000, measuredOutput: 300, measuredMs: 4000, costMicroUsd: 900),
                          to: ReportModelKey(modelId: "gpt-5.5", source: .workbuddyAi))
        content.usage.add(ReportUsage(requests: 2, output: 500, input: 30_000, cachedInput: 20_000, costMicroUsd: 1200),
                          to: ReportModelKey(modelId: "glm-5.3", source: .workbuddy))
        sample.sources[.workbuddy] = .init(live: Rate(output: 41.2, total: 2200))
        sample.live = Rate(output: sample.live.output + 41.2, total: sample.live.total + 2200)
        sample.facts.agents[.workbuddy] = ReportAgentCounts(generating: 1, tools: 0, active: 1)
        sample.facts.generatingModels[ReportModelKey(modelId: "glm-5.3", source: .workbuddy)] = 1
        let body = try JSONSerialization.jsonObject(with: ReportBody.json(ReportBodyTests.envelope, content, sample,
                                                                          ReportBodyTests.everything).compactData) as! [String: Any]
        let sources = (body["sources"] as! [[String: Any]]).map { $0["source"] as! String }
        #expect(sources == ["codex", "claudeCode", "workbuddy", "workbuddyAi"])
        let models = body["models"] as! [[String: Any]]
        let gpt = try #require(models.first { $0["id"] as? String == "gpt-5.5" })
        #expect(gpt["sources"] as? [String] == ["codex", "workbuddyAi"])
        if ReferencePython.available {
            let failures = try ReferencePython.strictErrors([ReportBody.data(ReportBodyTests.envelope, content, sample,
                                                                             ReportBodyTests.everything)])
            #expect(failures.isEmpty, "\(failures)")
        }
    }
}
