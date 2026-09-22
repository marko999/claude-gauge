import AppKit
import ClaudeGaugeCore
import Foundation

/// Hidden CLI mode for scripts / statuslines:
///   ClaudeGauge --status [--used] [--full | --session-only] [--force-refresh] [--verbose]
/// Prints the same text as the menu bar title and exits 0, or an error and exits 1.
private func runStatusCommand(arguments: [String]) -> Never {
    let mode: StatusDisplayMode = arguments.contains("--used") ? .used : .remaining
    var selection = MenuBarSelection.default
    if arguments.contains("--full") {
        selection.weekly = .all
    } else if arguments.contains("--session-only") {
        selection.weekly = .none
    }
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
            print(formatStatusText(snapshot, mode: mode, selection: selection))
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

/// Hidden: `ClaudeGauge --snapshot <dir>` renders README images from live data.
private func runSnapshotCommand(directory: String) -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let semaphore = DispatchSemaphore(value: 0)
    var fetched: UsageSnapshot?
    Task {
        defer { semaphore.signal() }
        if case .ok(let token, _) = await ClaudeTokenManager().accessToken(),
           case .ok(let snapshot) = await fetchUsage(accessToken: token)
        {
            fetched = snapshot
        }
    }
    semaphore.wait()
    guard let snapshot = fetched else {
        fputs("error: could not fetch usage for snapshot\n", stderr)
        exit(1)
    }
    do {
        try MainActor.assumeIsolated {
            try SnapshotRenderer.render(snapshot: snapshot, to: directory)
        }
        print("Snapshots written to \(directory)")
        exit(0)
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--status") {
    runStatusCommand(arguments: arguments)
}
if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
    runSnapshotCommand(directory: arguments[index + 1])
}

let app = NSApplication.shared
let appDelegate = AppDelegate()

app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
