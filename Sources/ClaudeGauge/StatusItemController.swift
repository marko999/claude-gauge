import AppKit
import ClaudeGaugeCore
import Foundation

/// Menu-bar status item: polling, token refresh, popover details.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, GaugePopoverDelegate {
    private static let staleOnFocus: TimeInterval = 30

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverController = GaugePopoverController()
    private let tokenManager = ClaudeTokenManager()

    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    private var lastSuccessAt: Date?
    private var lastSnapshot: UsageSnapshot?
    private var lastError: String?
    private var lastWarning: String?
    private var displayMode: StatusDisplayMode
    private var menuBarSelection: MenuBarSelection
    private var menuBarStyle: MenuBarStyle
    private var pollInterval: TimeInterval

    override init() {
        displayMode = AppPreferences.displayMode()
        menuBarSelection = AppPreferences.menuBarSelection()
        menuBarStyle = AppPreferences.menuBarStyle()
        pollInterval = AppPreferences.pollInterval()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        super.init()

        popoverController.delegate = self
        popoverController.hostingPopover = popover
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = "ClaudeGauge"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popoverController.syncSettings(
            displayMode: displayMode,
            selection: menuBarSelection,
            style: menuBarStyle,
            pollInterval: pollInterval
        )
        applyLoading()
    }

    func start() {
        schedulePolling()
        scheduleCountdown()
        HotKeyCenter.shared.onToggle = { [weak self] in
            Task { @MainActor in
                self?.togglePopoverFromHotKey()
            }
        }
        HotKeyCenter.shared.registerToggleHotKey()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIfStale()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIfStale()
            }
        }
        Task { await refresh() }
    }

    func stop() {
        closePopover()
        HotKeyCenter.shared.onToggle = nil
        HotKeyCenter.shared.unregister()
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
    }

    // MARK: - Popover

    @objc private func statusItemClicked(_ sender: Any?) {
        togglePopover()
    }

    private func togglePopoverFromHotKey() {
        statusItem.isVisible = true
        togglePopover()
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        renderPopoverContent()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func renderPopoverContent() {
        popoverController.syncSettings(
            displayMode: displayMode,
            selection: menuBarSelection,
            style: menuBarStyle,
            pollInterval: pollInterval
        )
        if let snapshot = lastSnapshot, let at = lastSuccessAt {
            popoverController.showOverview(snapshot: snapshot, lastUpdated: at, warning: lastWarning ?? lastError)
        } else if let error = lastError {
            popoverController.showOverviewError(error)
        } else {
            popoverController.showOverviewLoading()
        }
    }

    // MARK: - GaugePopoverDelegate

    func popoverDidRequestRefresh() {
        Task { await refresh() }
    }

    func popoverDidRequestOpenDashboard() {
        NSWorkspace.shared.open(claudeUsageSettingsURL)
    }

    func popoverDidRequestQuit() {
        closePopover()
        NSApp.terminate(nil)
    }

    func popoverDidChangeDisplayMode(_ mode: StatusDisplayMode) {
        displayMode = mode
        AppPreferences.setDisplayMode(mode)
        renderTitle()
    }

    func popoverDidChangeMenuBarSelection(_ selection: MenuBarSelection) {
        menuBarSelection = selection
        AppPreferences.setMenuBarSelection(selection)
        renderTitle()
    }

    func popoverDidChangeMenuBarStyle(_ style: MenuBarStyle) {
        menuBarStyle = style
        AppPreferences.setMenuBarStyle(style)
        renderTitle()
    }

    func popoverDidChangePollInterval(_ interval: TimeInterval) {
        pollInterval = interval
        AppPreferences.setPollInterval(interval)
        schedulePolling()
    }

    // MARK: - Refresh

    private func schedulePolling() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        timer.tolerance = min(15, pollInterval / 4)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Re-render countdowns ("resets in 4h 47m") once a minute without hitting the network.
    private func scheduleCountdown() {
        countdownTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.renderPopoverContent()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func refreshIfStale() {
        let stale = lastSuccessAt.map { Date().timeIntervalSince($0) >= Self.staleOnFocus } ?? true
        guard stale else { return }
        Task { await refresh() }
    }

    private func refresh() async {
        if refreshTask != nil { return }

        let task = Task { @MainActor in
            if lastSnapshot == nil {
                applyLoading()
            }
            if popover.isShown {
                popoverController.showOverviewLoading()
            }

            var warning: String?
            var token: String
            switch await tokenManager.accessToken() {
            case .ok(let value, let note):
                token = value
                warning = note
            case .needsLogin(let message), .failed(let message):
                applyError(message)
                return
            }

            var result = await fetchUsage(accessToken: token)
            if case .unauthorized = result {
                // Token looked valid but the API disagrees: rotate once and retry.
                switch await tokenManager.accessToken(forceRefresh: true) {
                case .ok(let value, let note):
                    token = value
                    warning = note ?? warning
                    result = await fetchUsage(accessToken: token)
                case .needsLogin(let message), .failed(let message):
                    applyError(message)
                    return
                }
            }

            switch result {
            case .ok(let snapshot):
                let now = Date()
                lastSnapshot = snapshot
                lastSuccessAt = now
                lastError = nil
                lastWarning = warning
                renderTitle()
                if popover.isShown {
                    popoverController.showOverview(snapshot: snapshot, lastUpdated: now, warning: warning)
                }
            case .unauthorized(let message):
                applyError(message + " " + loginHint)
            case .failed(let message, _):
                applyError(message)
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func applyLoading() {
        setTitle(formatLoadingStatus(), severity: .normal)
        lastError = nil
    }

    private func applyError(_ message: String) {
        lastError = message
        // Keep the last good numbers visible; only the tooltip explains the problem.
        if lastSnapshot == nil {
            setTitle(formatErrorStatus(), severity: .warning)
            statusItem.button?.toolTip = message
        } else {
            statusItem.button?.toolTip = "Last refresh failed: \(message)"
        }
        if popover.isShown {
            if let snapshot = lastSnapshot, let at = lastSuccessAt {
                popoverController.showOverview(snapshot: snapshot, lastUpdated: at, warning: message)
            } else {
                popoverController.showOverviewError(message)
            }
        }
    }

    private func renderTitle() {
        guard let snapshot = lastSnapshot, let at = lastSuccessAt, let button = statusItem.button else { return }
        let windows = menuBarWindows(snapshot, selection: menuBarSelection)
        switch menuBarStyle {
        case .text:
            setTitle(
                formatStatusText(snapshot, mode: displayMode, selection: menuBarSelection),
                severity: windows.map(severity(of:)).max() ?? .normal
            )
        case .bar, .barAndText:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = MenuBarImageRenderer.image(windows: windows, mode: displayMode, style: menuBarStyle)
            button.imagePosition = .imageOnly
        }
        button.toolTip = formatTooltip(snapshot, mode: displayMode, lastUpdated: at)
    }

    private func setTitle(_ title: String, severity: UsageSeverity) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        switch severity {
        case .normal:
            break
        case .warning:
            attributes[.foregroundColor] = NSColor.systemOrange
        case .critical:
            attributes[.foregroundColor] = NSColor.systemRed
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.toolTip = title
    }
}
