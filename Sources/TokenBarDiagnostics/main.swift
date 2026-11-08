import Foundation
import TokenBarDiagnosticsCore

let args = CommandLine.arguments.contains("--diagnostics-probe") || CommandLine.arguments.contains("--export-diagnostics") || CommandLine.arguments.contains("--record-install")
    ? CommandLine.arguments : CommandLine.arguments + ["--export-diagnostics"]
exit(DiagnosticCLI.runIfRequested(args) ?? 64)
