import ClaudeLocalCaptureCore
import Darwin
import Foundation

@main
enum TokenBarClaudeLocal {
    static func main() {
        do {
            guard CommandLine.arguments.count == 1 else {
                throw ClaudeStatuslineCaptureError.invalidJSON
            }
            let input = try readBoundedStandardInput()
            let snapshot = try ClaudeStatuslineParser.parse(input)
            try ClaudeStatuslineSnapshotWriter().write(snapshot)
            // A fixed neutral line keeps Claude Code's statusLine visible without
            // echoing any source JSON. Settings remain user-configured and untouched.
            FileHandle.standardOutput.write(Data("Claude · Token Bar 本地读取\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("TokenBar Claude local capture failed\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func readBoundedStandardInput() throws -> Data {
        let maximumBytes = ClaudeStatuslineParser.maximumInputBytes
        var input = Data()
        while true {
            let remainingProbe = maximumBytes + 1 - input.count
            guard remainingProbe > 0 else {
                throw ClaudeStatuslineCaptureError.inputTooLarge
            }
            let count = min(8 * 1024, remainingProbe)
            guard let chunk = try FileHandle.standardInput.read(upToCount: count), !chunk.isEmpty else {
                return input
            }
            input.append(chunk)
            if input.count > maximumBytes {
                throw ClaudeStatuslineCaptureError.inputTooLarge
            }
        }
    }
}
