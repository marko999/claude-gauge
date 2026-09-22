import AppKit
import ClaudeGaugeCore
import Foundation

@MainActor
protocol GaugePopoverDelegate: AnyObject {
    func popoverDidRequestRefresh()
    func popoverDidRequestOpenDashboard()
    func popoverDidRequestQuit()
    func popoverDidChangeDisplayMode(_ mode: StatusDisplayMode)
    func popoverDidChangeMenuBarLayout(_ layout: MenuBarLayout)
    func popoverDidChangePollInterval(_ interval: TimeInterval)
}

/// Native menu-bar popover: one row per plan limit, extra usage, settings, actions.
@MainActor
final class GaugePopoverController: NSViewController {
    weak var delegate: GaugePopoverDelegate?
    weak var hostingPopover: NSPopover?

    private static let popoverWidth: CGFloat = 400
    private static let maxContentHeight: CGFloat = 600
    private static let minContentHeight: CGFloat = 220
    private static var rowWidth: CGFloat { popoverWidth - 28 }

    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    // Header
    private let headlineLabel = NSTextField(labelWithString: "—")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let statusMessageLabel = NSTextField(wrappingLabelWithString: "")

    // Limits
    private let limitsStack = NSStackView()

    // Extra usage
    private let extraSection = NSStackView()
    private let extraValueLabel = NSTextField(labelWithString: "")
    private let extraBar = GaugeBarView()

    // Settings
    private let settingsDisclosure = NSButton(checkboxWithTitle: "Settings", target: nil, action: nil)
    private let settingsContainer = NSStackView()
    private var displayModeButtons: [NSButton] = []
    private var layoutButtons: [NSButton] = []
    private let pollPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Launch at Login",
        target: nil,
        action: nil
    )
    private let launchStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let launchHintLabel = NSTextField(wrappingLabelWithString: "")
    private var settingsExpanded = false

    private var displayMode: StatusDisplayMode = .remaining
    private var menuBarLayout: MenuBarLayout = .compact
    private var lastSnapshot: UsageSnapshot?
    private var lastUpdated: Date?

    override func loadView() {
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        view = effectView

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentStack

        effectView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: effectView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        buildContent()
        preferredContentSize = NSSize(width: Self.popoverWidth, height: Self.minContentHeight)
        showOverviewLoading()
        syncLaunchAtLoginUI()
    }

    // MARK: - Public API

    func showOverviewLoading() {
        if lastSnapshot == nil {
            statusMessageLabel.isHidden = false
            statusMessageLabel.textColor = .secondaryLabelColor
            statusMessageLabel.stringValue = "Refreshing Claude plan limits…"
            headlineLabel.stringValue = "…"
            updatedLabel.stringValue = ""
            clearArranged(limitsStack)
            extraSection.isHidden = true
        } else {
            updatedLabel.stringValue = "Refreshing…"
        }
        relayout()
    }

    func showOverviewError(_ message: String) {
        statusMessageLabel.isHidden = false
        statusMessageLabel.textColor = .systemRed
        statusMessageLabel.stringValue = message
        headlineLabel.stringValue = "?"
        updatedLabel.stringValue = ""
        clearArranged(limitsStack)
        extraSection.isHidden = true
        relayout()
    }

    func showOverview(snapshot: UsageSnapshot, lastUpdated: Date, warning: String?) {
        lastSnapshot = snapshot
        self.lastUpdated = lastUpdated

        if let warning, !warning.isEmpty {
            statusMessageLabel.isHidden = false
            statusMessageLabel.textColor = .systemOrange
            statusMessageLabel.stringValue = warning
        } else {
            statusMessageLabel.isHidden = true
            statusMessageLabel.stringValue = ""
        }

        headlineLabel.stringValue = formatStatusText(snapshot, mode: displayMode, layout: .full)
        updatedLabel.stringValue = formatUpdatedLabel(lastUpdated)

        clearArranged(limitsStack)
        let now = Date()
        for window in orderedWindows(snapshot) {
            let row = LimitRowView(width: Self.rowWidth)
            row.configure(window: window, mode: displayMode, now: now)
            limitsStack.addArrangedSubview(row)
        }

        if let extra = snapshot.extraUsage, extra.isEnabled {
            extraSection.isHidden = false
            extraValueLabel.stringValue = formatExtraUsage(extra)
            let used = extra.percentUsed ?? 0
            extraBar.fraction = (displayMode == .remaining ? (100 - used) : used) / 100
            extraBar.severity = severity(forRemainingPercent: 100 - used)
        } else {
            extraSection.isHidden = true
        }
        relayout()
    }

    func syncSettings(displayMode: StatusDisplayMode, layout: MenuBarLayout, pollInterval: TimeInterval) {
        self.displayMode = displayMode
        menuBarLayout = layout
        for button in displayModeButtons {
            button.state = button.tag == modeTag(displayMode) ? .on : .off
        }
        for button in layoutButtons {
            button.state = button.tag == layoutTag(layout) ? .on : .off
        }
        if let index = AppPreferences.allowedPollIntervals.firstIndex(of: pollInterval) {
            pollPopup.selectItem(at: index)
        }
        if let snapshot = lastSnapshot, let at = lastUpdated {
            showOverview(snapshot: snapshot, lastUpdated: at, warning: statusMessageLabel.isHidden ? nil : statusMessageLabel.stringValue)
        }
    }

    // MARK: - Build

    private func buildContent() {
        contentStack.addArrangedSubview(makeHeader())
        contentStack.addArrangedSubview(makeSeparator())

        limitsStack.orientation = .vertical
        limitsStack.alignment = .leading
        limitsStack.spacing = 10
        contentStack.addArrangedSubview(limitsStack)

        configureExtraSection()
        contentStack.addArrangedSubview(extraSection)

        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeSettingsSection())
        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeActionRow(
            title: "Refresh",
            symbol: "arrow.clockwise",
            accessibility: "Refresh usage data",
            action: #selector(refreshClicked)
        ))
        contentStack.addArrangedSubview(makeActionRow(
            title: "Open claude.ai usage settings",
            symbol: "safari",
            accessibility: "Open claude.ai usage settings in browser",
            action: #selector(dashboardClicked)
        ))
        contentStack.addArrangedSubview(makeActionRow(
            title: "Quit ClaudeGauge",
            symbol: "power",
            accessibility: "Quit ClaudeGauge",
            action: #selector(quitClicked)
        ))
        contentStack.addArrangedSubview(spacer(6))

        let footer = NSTextField(labelWithString: "Menu-bar only · unofficial · uses your Claude Code login")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        contentStack.addArrangedSubview(footer)
    }

    private func makeHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        headlineLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        headlineLabel.textColor = .labelColor
        headlineLabel.setAccessibilityLabel("Plan limits summary")

        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .tertiaryLabelColor

        statusMessageLabel.font = .systemFont(ofSize: 11)
        statusMessageLabel.textColor = .secondaryLabelColor
        statusMessageLabel.isHidden = true
        statusMessageLabel.preferredMaxLayoutWidth = Self.rowWidth

        stack.addArrangedSubview(headlineLabel)
        stack.addArrangedSubview(updatedLabel)
        stack.addArrangedSubview(statusMessageLabel)
        stack.addArrangedSubview(spacer(4))
        return stack
    }

    private func configureExtraSection() {
        extraSection.orientation = .vertical
        extraSection.alignment = .leading
        extraSection.spacing = 4
        extraSection.isHidden = true

        extraSection.addArrangedSubview(spacer(6))
        extraSection.addArrangedSubview(sectionHeader("Extra usage", symbol: "bolt"))
        extraValueLabel.font = .systemFont(ofSize: 12)
        extraValueLabel.textColor = .secondaryLabelColor
        extraSection.addArrangedSubview(extraValueLabel)
        extraBar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        extraBar.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        extraSection.addArrangedSubview(extraBar)
    }

    private func makeSettingsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        settingsDisclosure.setButtonType(.pushOnPushOff)
        settingsDisclosure.bezelStyle = .disclosure
        settingsDisclosure.title = ""
        settingsDisclosure.setAccessibilityLabel("Settings")
        settingsDisclosure.target = self
        settingsDisclosure.action = #selector(settingsDisclosureToggled)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let gear = NSImageView()
        if let image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") {
            gear.image = image
            gear.contentTintColor = .secondaryLabelColor
            gear.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        }
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        header.addArrangedSubview(settingsDisclosure)
        header.addArrangedSubview(gear)
        header.addArrangedSubview(title)

        settingsContainer.orientation = .vertical
        settingsContainer.alignment = .leading
        settingsContainer.spacing = 6
        settingsContainer.isHidden = true

        settingsContainer.addArrangedSubview(settingTitle("Numbers"))
        displayModeButtons = StatusDisplayMode.allCases.map { mode in
            let button = NSButton(
                radioButtonWithTitle: mode.settingsLabel,
                target: self,
                action: #selector(displayModeClicked(_:))
            )
            button.tag = modeTag(mode)
            button.font = .systemFont(ofSize: 12)
            return button
        }
        displayModeButtons.forEach { settingsContainer.addArrangedSubview($0) }

        settingsContainer.addArrangedSubview(spacer(4))
        settingsContainer.addArrangedSubview(settingTitle("Menu bar shows"))
        layoutButtons = MenuBarLayout.allCases.map { layout in
            let button = NSButton(
                radioButtonWithTitle: layout.settingsLabel,
                target: self,
                action: #selector(layoutClicked(_:))
            )
            button.tag = layoutTag(layout)
            button.font = .systemFont(ofSize: 12)
            return button
        }
        layoutButtons.forEach { settingsContainer.addArrangedSubview($0) }

        settingsContainer.addArrangedSubview(spacer(4))
        let pollRow = NSStackView()
        pollRow.orientation = .horizontal
        pollRow.spacing = 8
        pollRow.alignment = .centerY
        pollRow.addArrangedSubview(settingTitle("Refresh every"))
        pollPopup.removeAllItems()
        for interval in AppPreferences.allowedPollIntervals {
            pollPopup.addItem(withTitle: AppPreferences.formatPollInterval(interval))
        }
        pollPopup.font = .systemFont(ofSize: 12)
        pollPopup.controlSize = .small
        pollPopup.target = self
        pollPopup.action = #selector(pollIntervalChanged)
        pollRow.addArrangedSubview(pollPopup)
        settingsContainer.addArrangedSubview(pollRow)

        settingsContainer.addArrangedSubview(spacer(4))
        settingsContainer.addArrangedSubview(settingTitle("Hotkey"))
        let hotkeyRow = NSTextField(labelWithString: "Toggle panel: ⌥⌘K")
        hotkeyRow.font = .systemFont(ofSize: 12)
        hotkeyRow.textColor = .secondaryLabelColor
        settingsContainer.addArrangedSubview(hotkeyRow)

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginToggled)
        launchAtLoginCheckbox.font = .systemFont(ofSize: 12)
        settingsContainer.addArrangedSubview(spacer(4))
        settingsContainer.addArrangedSubview(launchAtLoginCheckbox)

        launchStatusLabel.font = .systemFont(ofSize: 11)
        launchStatusLabel.textColor = .secondaryLabelColor
        launchStatusLabel.preferredMaxLayoutWidth = Self.rowWidth
        launchHintLabel.font = .systemFont(ofSize: 10)
        launchHintLabel.textColor = .tertiaryLabelColor
        launchHintLabel.preferredMaxLayoutWidth = Self.rowWidth
        settingsContainer.addArrangedSubview(launchStatusLabel)
        settingsContainer.addArrangedSubview(launchHintLabel)

        let privacy = NSTextField(
            wrappingLabelWithString:
                "Reads the Claude Code login from Keychain. When the token expires it is refreshed and written back so the CLI stays signed in. Nothing else is stored."
        )
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = .tertiaryLabelColor
        privacy.preferredMaxLayoutWidth = Self.rowWidth
        settingsContainer.addArrangedSubview(spacer(2))
        settingsContainer.addArrangedSubview(privacy)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(settingsContainer)
        return stack
    }

    private func makeActionRow(
        title: String,
        symbol: String,
        accessibility: String,
        action: Selector
    ) -> NSView {
        let button = HoverMenuButton()
        button.rowTitle = title
        button.symbolName = symbol
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    // MARK: - Helpers

    private func settingTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        return label
    }

    private func sectionHeader(_ title: String, symbol: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            icon.image = image
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        box.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        let wrap = NSStackView(views: [spacer(8), box, spacer(8)])
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.spacing = 0
        return wrap
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func clearArranged(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func modeTag(_ mode: StatusDisplayMode) -> Int {
        StatusDisplayMode.allCases.firstIndex(of: mode) ?? 0
    }

    private func layoutTag(_ layout: MenuBarLayout) -> Int {
        MenuBarLayout.allCases.firstIndex(of: layout) ?? 0
    }

    private func syncLaunchAtLoginUI(errorMessage: String? = nil) {
        let state = LaunchAtLogin.displayState
        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        if let errorMessage, !errorMessage.isEmpty {
            launchStatusLabel.stringValue = errorMessage
            launchStatusLabel.textColor = .systemRed
        } else {
            launchStatusLabel.stringValue = formatLaunchAtLoginStatus(state)
            launchStatusLabel.textColor = .secondaryLabelColor
        }
        launchHintLabel.stringValue = formatLaunchAtLoginLimitation(
            isInApplications: LaunchAtLogin.isBundledInApplications
        )
    }

    private func relayout() {
        view.layoutSubtreeIfNeeded()
        let fitting = contentStack.fittingSize
        let height = min(Self.maxContentHeight, max(Self.minContentHeight, fitting.height + 8))
        let size = NSSize(width: Self.popoverWidth, height: height)
        preferredContentSize = size
        hostingPopover?.contentSize = size
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        delegate?.popoverDidRequestRefresh()
    }

    @objc private func dashboardClicked() {
        delegate?.popoverDidRequestOpenDashboard()
    }

    @objc private func quitClicked() {
        delegate?.popoverDidRequestQuit()
    }

    @objc private func displayModeClicked(_ sender: NSButton) {
        let mode = StatusDisplayMode.allCases[max(0, min(StatusDisplayMode.allCases.count - 1, sender.tag))]
        displayMode = mode
        for button in displayModeButtons {
            button.state = button.tag == sender.tag ? .on : .off
        }
        if let snapshot = lastSnapshot, let at = lastUpdated {
            showOverview(snapshot: snapshot, lastUpdated: at, warning: statusMessageLabel.isHidden ? nil : statusMessageLabel.stringValue)
        }
        delegate?.popoverDidChangeDisplayMode(mode)
    }

    @objc private func layoutClicked(_ sender: NSButton) {
        let layout = MenuBarLayout.allCases[max(0, min(MenuBarLayout.allCases.count - 1, sender.tag))]
        menuBarLayout = layout
        for button in layoutButtons {
            button.state = button.tag == sender.tag ? .on : .off
        }
        delegate?.popoverDidChangeMenuBarLayout(layout)
    }

    @objc private func pollIntervalChanged() {
        let index = pollPopup.indexOfSelectedItem
        guard AppPreferences.allowedPollIntervals.indices.contains(index) else { return }
        delegate?.popoverDidChangePollInterval(AppPreferences.allowedPollIntervals[index])
    }

    @objc private func settingsDisclosureToggled() {
        settingsExpanded = settingsDisclosure.state == .on
        settingsContainer.isHidden = !settingsExpanded
        if settingsExpanded {
            syncLaunchAtLoginUI()
        }
        relayout()
    }

    @objc private func launchAtLoginToggled() {
        let wantEnabled = launchAtLoginCheckbox.state == .on
        do {
            try LaunchAtLogin.setEnabled(wantEnabled)
            syncLaunchAtLoginUI()
        } catch {
            syncLaunchAtLoginUI(errorMessage: LaunchAtLogin.sanitizedErrorMessage(error))
            launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        }
        relayout()
    }
}

// MARK: - Supporting views

/// Title · percent on one line, capacity bar, reset countdown below.
@MainActor
private final class LimitRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let bar = GaugeBarView()
    private let resetLabel = NSTextField(labelWithString: "")

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        resetLabel.font = .systemFont(ofSize: 11)
        resetLabel.textColor = .tertiaryLabelColor

        let top = NSStackView(views: [titleLabel, valueLabel])
        top.orientation = .horizontal
        top.distribution = .fill
        top.alignment = .firstBaseline
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [top, bar, resetLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalToConstant: width),
            bar.widthAnchor.constraint(equalToConstant: width),
            bar.heightAnchor.constraint(equalToConstant: 8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    func configure(window: UsageWindow, mode: StatusDisplayMode, now: Date) {
        let shown = displayedPercent(window, mode: mode)
        titleLabel.stringValue = window.label + (window.isActive ? " · active" : "")
        valueLabel.stringValue = "\(formatPercent(shown)) \(displayedSuffix(mode: mode))"
        bar.fraction = shown / 100
        bar.severity = severity(of: window)
        let relative = formatResetsIn(window.resetsAt, now: now)
        resetLabel.stringValue = window.resetsAt == nil
            ? "No reset scheduled"
            : "Resets in \(relative) · \(formatResetsAbsolute(window.resetsAt))"
        setAccessibilityLabel(window.label)
        setAccessibilityValue(formatWindowLine(window, mode: mode, now: now))
    }
}

/// Compact menu-like row with light hover highlight.
@MainActor
private final class HoverMenuButton: NSControl {
    var symbolName: String = "circle" {
        didSet { refresh() }
    }

    var rowTitle: String = "" {
        didSet { refresh() }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func refresh() {
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: rowTitle) {
            iconView.image = image
            iconView.contentTintColor = .secondaryLabelColor
            iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        }
        titleLabel.stringValue = rowTitle
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor =
            hovered
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return / Space
            sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }
}
