import Foundation
import Darwin

public enum DiagnosticCLI {
    /// Evaluated before AppKit/SwiftUI, migration, single-instance admission or
    /// the app's default journal. Export itself never writes product state.
    public static func runIfRequested(_ arguments: [String] = CommandLine.arguments) -> Int32? {
        guard arguments.contains("--export-diagnostics") || arguments.contains("--diagnostics-probe") || arguments.contains("--record-install") else { return nil }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let home = option("--diagnostics-home").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let app = option("--diagnostics-app").map { URL(fileURLWithPath: $0) } ?? installedApplication()
        let configuration = DiagnosticConfiguration(home: home, application: app)
        if arguments.contains("--record-install") {
            let id = option("--attempt") ?? UUID().uuidString
            let targetVersion = option("--target-version") ?? ""
            let targetBuild = option("--target-build") ?? ""
            DiagnosticInstallations.prepare(configuration:configuration,attempt:id,targetVersion:targetVersion,
                targetBuild:targetBuild,sourceBuild:option("--source-build") ?? "")
            let journal=DiagnosticJournal(root:configuration.journal,version:targetVersion,build:targetBuild)
            journal.record(.installer,.replacing,attempt:id,targetVersion:targetVersion,targetBuild:targetBuild)
            _ = journal.flush()
            return 0
        }
        do {
            if let name = option("--diagnostics-probe"), let probe = DiagnosticProbe(rawValue: name), let output = option("--probe-output") {
                let data = try JSONSerialization.data(withJSONObject: DiagnosticCollector.collect(probe, configuration: configuration), options: [.sortedKeys])
                try DiagnosticFiles.create(URL(fileURLWithPath: output), data: data)
                return 0
            }
            guard arguments.contains("--export-diagnostics") else { return 64 }
            let output = option("--output").map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent("Downloads/TokenBar-Diagnostics-\(UUID().uuidString.prefix(8)).zip")
            try export(to: output, configuration: configuration, executable: executableURL())
            // Local CLI feedback is not embedded into the shareable archive.
            print("诊断包已导出 / Diagnostics exported: \(output.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("诊断包未能写入，请选择可写的新文件位置。 / Export failed; choose a new writable destination.\n".utf8))
            return 1
        }
    }

    public static func export(to output: URL, configuration: DiagnosticConfiguration, executable: URL,
                              probeTimeout: TimeInterval = 3) throws {
        let c = configuration
        let destination = output.standardizedFileURL
        guard !destination.path.hasPrefix(c.support.standardizedFileURL.path + "/"),
              !FileManager.default.fileExists(atPath: destination.path) else { throw DiagnosticFiles.Failure.io }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tokenbar-diagnostic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        var results: [String:[String:Any]] = [:]
        for probe in DiagnosticProbe.allCases {
            let target = temp.appendingPathComponent(probe.rawValue + ".json")
            var args = ["--diagnostics-probe", probe.rawValue, "--probe-output", target.path, "--diagnostics-home", c.home.path]
            if let app = c.application { args += ["--diagnostics-app", app.path] }
            let outcome = run(executable: executable, arguments: args, timeout: probeTimeout)
            guard outcome == "ok", let bytes = try? DiagnosticFiles.read(target, limit: 8 * 1024 * 1024),
                  let value = try? JSONSerialization.jsonObject(with: bytes) as? [String:Any] else {
                results[probe.rawValue] = ["status":outcome == "ok" ? "unavailable":outcome]; continue
            }
            results[probe.rawValue] = value
        }
        if let app = c.application {
            let outcome = run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                              arguments:["--verify","--deep","--strict",app.path], timeout:probeTimeout)
            results["environment"]?["signatureCheck"] = outcome
        }
        let bytes = try DiagnosticCollector.archive(probes: results)
        try DiagnosticFiles.create(destination, data: bytes)
    }
    public static func executableURL() -> URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }
    public static func installedApplication() -> URL? {
        let own = executableURL().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if own.pathExtension == "app" { return own }
        let system = URL(fileURLWithPath: "/Applications/Codex Token Bar.app")
        return FileManager.default.fileExists(atPath: system.path) ? system : nil
    }
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) -> String {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return "unavailable" }
        let deadline = ProcessInfo.processInfo.systemUptime + min(10, max(0.05, timeout))
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval:0.02) }
        if process.isRunning {
            // This PID is the child we just launched; never kill the main app.
            kill(process.processIdentifier, SIGKILL)
            return "timeout"
        }
        return process.terminationStatus == 0 ? "ok" : "failed"
    }
}
