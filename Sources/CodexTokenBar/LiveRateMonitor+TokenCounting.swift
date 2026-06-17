import Foundation
import TiktokenSwift

extension LiveRateMonitor {
    func warmTokenEncoder() async {
        do {
            tokenEncoder = try await Task.detached(priority: .utility) {
                try await CoreBpe.o200kBase()
            }.value
        } catch {
            tokenEncoder = nil
        }
        updateTokenCountingLabel()
    }

    func updateTokenCountingLabel() {
        let label = preciseTokenCountingEnabled && tokenEncoder != nil ? "stream deltas + o200k" : "stream deltas + calibrated"
        snapshot.interfaceLabel = label
        totalSnapshot.interfaceLabel = label
    }

    func estimateTokenCount(_ text: String) -> Int {
        estimateTokenCount(text, category: .visibleText)
    }

    func estimateTokenCount(_ text: String, category: LiveTokenCategory) -> Int {
        if preciseTokenCountingEnabled, let tokenEncoder, text.count <= 16_384 {
            return tokenEncoder.encodeOrdinary(text: text).count
        }

        var tokens = 0.0
        var asciiRun = 0
        let asciiDivisor = category == .visibleText ? 4.2 : 3.0

        func flushASCII() {
            guard asciiRun > 0 else { return }
            tokens += max(1.0, Double(asciiRun) / asciiDivisor)
            asciiRun = 0
        }

        for scalar in text.unicodeScalars {
            if scalar.value < 128, !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                asciiRun += 1
            } else {
                flushASCII()
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    tokens += Self.nonASCIITokenWeight(scalar, category: category)
                }
            }
        }
        flushASCII()
        return Int(tokens.rounded(.toNearestOrAwayFromZero))
    }

    nonisolated static func nonASCIITokenWeight(_ scalar: UnicodeScalar, category: LiveTokenCategory) -> Double {
        if isCJK(scalar) {
            return category == .visibleText ? 0.58 : 0.8
        }
        if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
            return category == .visibleText ? 0.35 : 0.7
        }
        return category == .visibleText ? 0.8 : 1.0
    }

    nonisolated static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF:
            return true
        default:
            return false
        }
    }

    nonisolated static func metricKey(threadID: String, itemID: String, category: LiveTokenCategory) -> String {
        "\(threadID):\(itemID):\(category.rawValue)"
    }
}
