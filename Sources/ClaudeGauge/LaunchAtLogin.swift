import ClaudeGaugeCore
import Foundation
import ServiceManagement

/// Thin wrapper around macOS 13+ `SMAppService.mainApp` for Launch at Login.
/// Registration is most reliable when the `.app` lives in `/Applications`.
enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static var displayState: LaunchAtLoginDisplayState {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    static var isBundledInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix("/System/Applications/")
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func sanitizedErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if text.count > 160 {
            return String(text.prefix(157)) + "…"
        }
        return text
    }
}
