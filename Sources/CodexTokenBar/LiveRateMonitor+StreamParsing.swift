import Foundation

private enum LiveRateStreamDecoderCache {
    private static let key = "CodexTokenBar.LiveRateMonitor.streamEventDecoder"

    static var decoder: JSONDecoder {
        if let decoder = Thread.current.threadDictionary[key] as? JSONDecoder {
            return decoder
        }

        let decoder = JSONDecoder()
        Thread.current.threadDictionary[key] = decoder
        return decoder
    }
}

extension LiveRateMonitor {
    nonisolated static func streamEvent(from row: LogRow) -> ResponseStreamEvent? {
        let marker: String
        switch row.target {
        case "codex_api::sse::responses":
            marker = "SSE event: "
        case "codex_api::endpoint::responses_websocket":
            marker = "websocket event: "
        case "log":
            marker = "Received message "
        default:
            return nil
        }
        guard let range = row.feedbackLogBody.range(of: marker) else { return nil }
        let jsonText = String(row.feedbackLogBody[range.upperBound...])
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? LiveRateStreamDecoderCache.decoder.decode(ResponseStreamEvent.self, from: data)
    }

    nonisolated static func metricEvents(from streamEvent: ResponseStreamEvent, row: LogRow, toolNames: [String: String]) -> [LiveMetricEvent] {
        let timestamp = TimeInterval(row.ts) + TimeInterval(row.tsNanos) / 1_000_000_000
        let source: LiveMetricSource
        switch row.target {
        case "codex_api::sse::responses":
            source = .sse
        case "codex_api::endpoint::responses_websocket":
            source = .websocket
        default:
            source = .bridgedLog
        }
        let itemID = streamEvent.itemID ?? streamEvent.item?.id ?? "unknown"
        let turnID = streamEvent.turnID ?? streamEvent.item?.metadata?.turnID
        let callID = streamEvent.item?.callID

        switch streamEvent.type {
        case "response.output_text.delta":
            guard let delta = streamEvent.delta, !delta.isEmpty else { return [] }
            return [
                LiveMetricEvent(
                    source: source,
                    timestamp: timestamp,
                    threadID: row.threadID,
                    turnID: turnID,
                    itemID: itemID,
                    callID: callID,
                    sequenceNumber: streamEvent.sequenceNumber,
                    category: .visibleText,
                    text: delta,
                    isDelta: true
                )
            ]
        case "response.function_call_arguments.delta":
            guard let delta = streamEvent.delta, !delta.isEmpty else { return [] }
            let category = toolNames[itemID] == "apply_patch" ? LiveTokenCategory.patchInput : .toolArguments
            return [
                LiveMetricEvent(
                    source: source,
                    timestamp: timestamp,
                    threadID: row.threadID,
                    turnID: turnID,
                    itemID: itemID,
                    callID: callID,
                    sequenceNumber: streamEvent.sequenceNumber,
                    category: category,
                    text: delta,
                    isDelta: true
                )
            ]
        case "response.custom_tool_call_input.delta":
            guard let delta = streamEvent.delta, !delta.isEmpty else { return [] }
            let category = toolNames[itemID] == "apply_patch" ? LiveTokenCategory.patchInput : .toolArguments
            return [
                LiveMetricEvent(
                    source: source,
                    timestamp: timestamp,
                    threadID: row.threadID,
                    turnID: turnID,
                    itemID: itemID,
                    callID: callID,
                    sequenceNumber: streamEvent.sequenceNumber,
                    category: category,
                    text: delta,
                    isDelta: true
                )
            ]
        default:
            return []
        }
    }

    nonisolated static func streamMessageText(from item: ResponseStreamItem) -> String {
        guard let content = item.content else { return "" }
        return content.compactMap { part -> String? in
            let type = part.type
            guard type == "output_text" || type == "text" else { return nil }
            return part.text
        }.joined()
    }

    nonisolated static func traceValue(in body: String, keys: [String]) -> String? {
        for key in keys {
            guard let keyRange = body.range(of: key) else { continue }
            var value = ""
            var index = keyRange.upperBound
            var quoted = false
            if index < body.endIndex, body[index] == "\"" {
                quoted = true
                index = body.index(after: index)
            }
            while index < body.endIndex {
                let char = body[index]
                if quoted {
                    if char == "\"" { break }
                } else if char == " " || char == "}" || char == ":" || char == "," {
                    break
                }
                value.append(char)
                index = body.index(after: index)
            }
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func messageText(from payload: [String: Any]) -> String {
        guard let content = payload["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { part -> String? in
            let type = part["type"] as? String
            guard type == "output_text" || type == "text" else { return nil }
            return part["text"] as? String
        }.joined()
    }

    nonisolated static func fileSize(path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? UInt64 ?? 0
    }

    nonisolated static func logStoreSignature(logsDB: String) -> LogStoreSignature {
        let database = fileSignaturePart(path: logsDB)
        let wal = fileSignaturePart(path: logsDB + "-wal")
        return LogStoreSignature(
            database: database,
            wal: wal
        )
    }

    nonisolated static func fileSignaturePart(path: String) -> FileStoreSignature {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular
        else {
            return FileStoreSignature(device: nil, inode: nil, size: 0, modifiedAt: 0)
        }
        let size = attrs[.size] as? UInt64 ?? 0
        let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileStoreSignature(device: device, inode: inode, size: size, modifiedAt: modifiedAt)
    }
}
