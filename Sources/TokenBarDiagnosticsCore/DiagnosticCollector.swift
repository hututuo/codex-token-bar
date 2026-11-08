import Foundation
import Darwin
import CoreFoundation

public enum DiagnosticProbe: String, CaseIterable, Sendable { case environment, events, recovery, installation, storage, legacy, crashes }

public enum DiagnosticCollector {
    /// No SQLite import or business routing dependency exists in this target.
    /// Every probe is invoked in a killable process by DiagnosticCLI.
    public static func collect(_ probe: DiagnosticProbe, configuration c: DiagnosticConfiguration) -> [String: Any] {
        switch probe {
        case .environment:
            let os = ProcessInfo.processInfo.operatingSystemVersion
            var info: [String: Any] = ["status":"ok", "platform":"macos", "osMajor":os.majorVersion,
                "osMinor":os.minorVersion, "osPatch":os.patchVersion, "processorCount":ProcessInfo.processInfo.processorCount]
            #if arch(arm64)
            info["architecture"] = "arm64"
            #else
            info["architecture"] = "x86_64"
            #endif
            if let capacity = try? c.home.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
                info["freeBytes"] = capacity
            }
            let process=Process(), pipe=Pipe()
            process.executableURL=URL(fileURLWithPath:"/usr/bin/pgrep");process.arguments=["-x","CodexTokenBar"]
            process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
            if (try? process.run()) != nil {
                process.waitUntilExit()
                let data=(try? pipe.fileHandleForReading.read(upToCount:4096)) ?? Data()
                let count=String(decoding:data,as:UTF8.self).split(separator:"\n").filter{Int32($0) != nil}.count
                info["processCount"]=count
            }
            if let app = c.application {
                info["applicationPresent"] = FileManager.default.fileExists(atPath: app.path)
                if let data = try? DiagnosticFiles.read(app.appendingPathComponent("Contents/Info.plist")),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String:Any] {
                    info["version"] = DiagnosticEvent.version(plist["CFBundleShortVersionString"] as? String ?? "")
                    info["build"] = DiagnosticEvent.version(plist["CFBundleVersion"] as? String ?? "")
                    info["expectedBundleIdentity"] = plist["CFBundleIdentifier"] as? String == "local.codex.token-bar"
                }
            }
            return info
        case .events:
            var rows: [[String:Any]] = [], rejected = 0, omitted = 0
            guard let files = try? DiagnosticFiles.files(c.journal, prefix: "", suffix: "") else { return ["status":"unavailable"] }
            for file in files.prefix(128) where file.lastPathComponent.hasPrefix("events-") || file.lastPathComponent.hasPrefix("failure-") {
                guard let bytes = try? DiagnosticFiles.read(file) else { rejected += 1; continue }
                for line in bytes.split(separator: 10) {
                    guard rows.count < 6000 else { omitted += 1; continue }
                    guard let event = DiagnosticEvent.sanitized(Data(line)), let encoded = try? JSONEncoder().encode(event),
                          let json = try? JSONSerialization.jsonObject(with: encoded) as? [String:Any] else { rejected += 1; continue }
                    rows.append(json)
                }
            }
            rows.sort { ($0["at"] as? Int64 ?? 0) < ($1["at"] as? Int64 ?? 0) }
            return ["status":"ok", "events":rows, "rejected":rejected, "omitted":omitted + max(0, files.count - 128)]
        case .recovery:
            let roots = [c.support.appendingPathComponent("recovery-diagnostics/v1"),
                c.home.appendingPathComponent("Library/Application Support/CodexTokenBarTauri/recovery-diagnostics/v1")]
            var rows: [[String:Any]] = [], rejected = 0
            for (rootIndex, root) in roots.enumerated() {
                guard let files = try? DiagnosticFiles.files(root, prefix: "", suffix: "") else { continue }
                for file in files.prefix(64) where file.lastPathComponent.hasPrefix("session-") || file.lastPathComponent == "latest-failure.json" {
                    guard let data = try? DiagnosticFiles.read(file) else { rejected += 1; continue }
                    for line in data.split(separator: 10) {
                        guard rows.count < 3000, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String:Any] else { continue }
                        let source = object["event"] as? [String:Any] ?? object
                        guard let phase = source["phase"] as? String,
                              ["preparing","importing","verifying","activating","ready","failure"].contains(phase) else { continue }
                        var row: [String:Any] = ["phase":phase, "source":rootIndex]
                        for key in ["at","completed","total","retryCount","code"] {
                            if let value = source[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite { row[key] = value }
                        }
                        rows.append(row)
                    }
                }
            }
            return ["status":rows.isEmpty ? "unavailable":"ok", "events":rows, "rejected":rejected]
        case .installation:
            // Shell/NSIS receipts use the same safe contract as app events.
            let root = c.journal.appendingPathComponent("installations")
            guard let files = try? DiagnosticFiles.files(root, prefix: "install-", suffix: ".jsonl") else { return ["status":"unavailable"] }
            var rows: [[String:Any]] = []
            for file in files.prefix(32) {
                guard let bytes = try? DiagnosticFiles.read(file) else { continue }
                for line in bytes.split(separator: 10) {
                    guard let event = DiagnosticEvent.sanitized(Data(line)), let data = try? JSONEncoder().encode(event),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String:Any] else { continue }
                    rows.append(json)
                }
            }
            return ["status":"ok", "events":rows]
        case .storage:
            let names = ["codex-ledger.sqlite", "codex-ledger.sqlite-wal", "codex-ledger.sqlite-shm",
                         "quota-history.sqlite", "multi-client-usage.sqlite"]
            var entries: [[String:Any]] = []
            for (index, name) in names.enumerated() {
                // lstat only: never open/restore/query a ledger or follow a link.
                var info = stat()
                let exists = lstat(c.support.appendingPathComponent(name).path, &info) == 0
                var row: [String:Any] = ["object":index, "present":exists]
                if exists {
                    row["regular"] = info.st_mode & S_IFMT == S_IFREG
                    row["symlink"] = info.st_mode & S_IFMT == S_IFLNK
                    row["bytes"] = max(0, info.st_size)
                    row["modifiedAt"] = info.st_mtimespec.tv_sec
                    row["ownerMatches"] = info.st_uid == getuid()
                }
                entries.append(row)
            }
            return ["status":"ok", "objects":entries, "databaseQueriesPerformed":false,
                    "stateSource":"persisted_diagnostic_events", "rawLogsIncluded":false]
        case .legacy:
            let roots = [c.home.appendingPathComponent("Library/Logs/CodexTokenBar/refresh-performance.log"),
                c.home.appendingPathComponent("Library/Logs/CodexTokenBar/refresh-performance.log.previous"),
                c.home.appendingPathComponent("Library/Application Support/CodexTokenBarTauri/performance-trace.log"),
                c.home.appendingPathComponent("Library/Application Support/CodexTokenBarTauri/startup-trace.log")]
            var rows: [[String:Any]] = []
            for (index,file) in roots.enumerated() {
                guard let bytes=try? DiagnosticFiles.read(file,limit:6*1024*1024),let text=String(data:bytes,encoding:.utf8) else{continue}
                for line in text.split(separator:"\n").suffix(2000) {
                    var metrics:[String:Int64]=[:]
                    for part in line.split(separator:" ") {
                        let pair=part.split(separator:"=",maxSplits:1)
                        if pair.count==2,DiagnosticEvent.metricKeys.contains(String(pair[0])),let number=Double(pair[1]),number.isFinite,
                           number>=0,number<Double(Int64.max) {metrics[String(pair[0])]=Int64(number)}
                    }
                    if !metrics.isEmpty {rows.append(["source":index,"metrics":metrics])}
                }
            }
            return ["status":rows.isEmpty ? "unavailable":"ok","numericRecords":rows,"rawTextExcluded":true]
        case .crashes:
            let root=c.home.appendingPathComponent("Library/Logs/DiagnosticReports")
            guard let paths=try? DiagnosticFiles.files(root,prefix:"CodexTokenBar",suffix:".ips") else{return ["status":"unavailable"]}
            var rows:[[String:Any]]=[]
            for file in paths.suffix(10) {
                guard let bytes=try? DiagnosticFiles.read(file,limit:4*1024*1024),
                      let first=bytes.split(separator:10).first,
                      let header=try? JSONSerialization.jsonObject(with:Data(first)) as? [String:Any] else{continue}
                var row:[String:Any]=["present":true,"bytes":bytes.count]
                if let build=header["build_version"] as? String{row["build"]=DiagnosticEvent.version(build)}
                if let v=header["app_version"] as? String{row["version"]=DiagnosticEvent.version(v)}
                if let type=header["bug_type"] as? String,let n=Int(type){row["bugType"]=n}
                rows.append(row)
            }
            return ["status":"ok","reports":rows,"stacksAndMemoryExcluded":true]
        }
    }

    public static func archive(probes: [String:[String:Any]], at: Date = Date()) throws -> Data {
        let probes = probes.mapValues { DiagnosticPrivacy.project($0) }
        var entries: [(String, Data)] = []
        for name in DiagnosticProbe.allCases {
            let object = probes[name.rawValue] ?? ["status":"unavailable"]
            entries.append(("state/\(name.rawValue).json", try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])))
            if let rows = object["events"] as? [[String:Any]] {
                var lines = Data()
                for row in rows { lines.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); lines.append(10) }
                entries.append(("events/\(name.rawValue).jsonl", lines))
            }
        }
        let rows = probes["events"]?["events"] as? [[String:Any]] ?? []
        let backend = rows.last { $0["area"] as? String == "backendProgress" }
        let ui = rows.last { $0["area"] as? String == "uiProgress" }
        let statuses = DiagnosticProbe.allCases.map { "- \($0.rawValue): \(probes[$0.rawValue]?["status"] as? String ?? "unavailable")" }.joined(separator: "\n")
        let summary = """
        # Codex Token Bar 诊断包 / Diagnostic bundle

        采集时间 / Collected: \(at.ISO8601Format())
        格式 / Format: tokenbar-diagnostics-v1

        \(statuses)

        后端最后推进 / Last backend progress (Unix ms): \(backend?["at"] as? Int64 ?? 0)
        UI 最后收到进度 / Last UI progress (Unix ms): \(ui?["at"] as? Int64 ?? 0)

        0 或 unavailable 表示没有可用证据，不代表正常、空账或数据丢失。
        安装器 launched 只表示已启动；confirmed 才表示目标版本运行确认。
        没有终止记录仅表示上次运行未确认正常退出，不能据此断言崩溃。

        Only fixed-schema events, numeric metrics and approved metadata are included.
        No credentials, conversations, raw paths, database contents, raw error prose,
        environment dumps or memory dumps are included. No network requests or
        business database opens, recovery, migration, checkpoints or repairs run.
        A timeout/unavailable probe is explicitly incomplete, not a clean bill of health.
        Older releases may not have recorded the missing events. Retention is bounded.
        """
        entries.append(("SUMMARY.md", Data(summary.utf8)))
        entries.append(("manifest.json", try JSONSerialization.data(withJSONObject: ["schema":1,
            "privacy":"allowlist-only", "databaseOpened":false, "files":entries.map(\.0)], options: [.sortedKeys])))
        return try DiagnosticZIP.encode(entries)
    }
}
