import AppKit
import ClaudeGaugeCore
import Foundation

/// Hidden CLI mode for scripts / statuslines:
///   ClaudeGauge --status [--used] [--full] [--force-refresh]
/// Prints the same text as the menu bar title and exits 0, or an error and exits 1.
private func runStatusCommand(arguments: [String]) -> Never {
    let mode: StatusDisplayMode = arguments.contains("--used") ? .used : .remaining
    let layout: MenuBarLayout = arguments.contains("--full") ? .full : .compact
    let forceRefresh = arguments.contains("--force-refresh")
    let verbose = arguments.contains("--verbose")

    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        defer { semaphore.signal() }
        let manager = ClaudeTokenManager()
        let token: String
        switch await manager.accessToken(forceRefresh: forceRefresh) {
        case .ok(let value, let warning):
            token = value
            if let warning {
                fputs("warning: \(warning)\n", stderr)
            }
        case .needsLogin(let message), .failed(let message):
            fputs("error: \(message)\n", stderr)
            exitCode = 1
            return
        }
        switch await fetchUsage(accessToken: token) {
        case .ok(let snapshot):
            print(formatStatusText(snapshot, mode: mode, layout: layout))
            if verbose {
                print(formatTooltip(snapshot, mode: mode, lastUpdated: Date()))
            }
        case .unauthorized(let message):
            fputs("error: \(message) \(loginHint)\n", stderr)
            exitCode = 1
        case .failed(let message, _):
            fputs("error: \(message)\n", stderr)
            exitCode = 1
        }
    }
    semaphore.wait()
    exit(exitCode)
}

let arguments = CommandLine.arguments
if arguments.contains("--status") {
    runStatusCommand(arguments: arguments)
}

let app = NSApplication.shared
let appDelegate = AppDelegate()

app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
