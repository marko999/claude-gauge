import AppKit
import ClaudeGaugeCore

/// Renders README artwork straight from the real views (no screen-recording
/// permission needed): menu-bar chips for every style plus the popover.
@MainActor
enum SnapshotRenderer {
    private static let scale: CGFloat = 2

    static func render(snapshot: UsageSnapshot, to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearanceName == .aqua ? "light" : "dark"
            let appearance = NSAppearance(named: appearanceName)!
            for style in MenuBarStyle.allCases {
                let chip = menuBarChip(snapshot: snapshot, style: style, appearance: appearance)
                try write(chip, to: "\(directory)/menubar-\(style.rawValue)-\(suffix).png")
            }
            try write(
                popoverImage(snapshot: snapshot, settingsExpanded: false, appearance: appearance),
                to: "\(directory)/popover-\(suffix).png"
            )
            try write(
                popoverImage(snapshot: snapshot, settingsExpanded: true, appearance: appearance),
                to: "\(directory)/settings-\(suffix).png"
            )
        }
    }

    // MARK: - Menu bar chip

    private static func menuBarChip(
        snapshot: UsageSnapshot,
        style: MenuBarStyle,
        appearance: NSAppearance
    ) -> NSBitmapImageRep {
        let selection = MenuBarSelection(showSession: true, weekly: .tightest)
        let windows = menuBarWindows(snapshot, selection: selection)
        let padding: CGFloat = 12
        let height: CGFloat = 24

        var contentWidth: CGFloat = 0
        var title: NSAttributedString?
        var image: NSImage?
        if style == .text {
            let text = formatStatusText(snapshot, mode: .remaining, selection: selection)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            title = attributed
            contentWidth = attributed.size().width
        } else {
            let rendered = MenuBarImageRenderer.image(windows: windows, mode: .remaining, style: style)
            image = rendered
            contentWidth = rendered.size.width
        }

        let size = NSSize(width: ceil(contentWidth + padding * 2), height: height)
        return draw(size: size, appearance: appearance) { rect in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            if let title {
                let textSize = title.size()
                title.draw(at: NSPoint(x: padding, y: (rect.height - textSize.height) / 2))
            }
            if let image {
                let origin = NSPoint(x: padding, y: (rect.height - image.size.height) / 2)
                image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    // MARK: - Popover

    private static func popoverImage(
        snapshot: UsageSnapshot,
        settingsExpanded: Bool,
        appearance: NSAppearance
    ) -> NSBitmapImageRep {
        let controller = GaugePopoverController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let background = isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.appearance = appearance
        window.backgroundColor = background
        window.contentViewController = controller
        controller.view.appearance = appearance
        controller.syncSettings(
            displayMode: .remaining, selection: .default, style: .text, pollInterval: 60
        )
        controller.showOverview(snapshot: snapshot, lastUpdated: Date(), warning: nil)
        if settingsExpanded {
            controller.setSettingsExpandedForSnapshot(true)
        }
        let document = controller.snapshotDocumentView()
        let size = NSSize(width: 400, height: ceil(document.frame.height))

        return draw(size: size, appearance: appearance) { rect in
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).addClip()
            if let context = NSGraphicsContext.current {
                // Draws with transparency, unlike cacheDisplay whose backing starts out white.
                document.displayIgnoringOpacity(document.bounds, in: context)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Bitmap helpers

    private static func draw(
        size: NSSize,
        appearance: NSAppearance,
        _ body: (NSRect) -> Void
    ) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // rep.size (points) vs pixel dims already gives the 2× mapping.
        appearance.performAsCurrentDrawingAppearance {
            body(NSRect(origin: .zero, size: size))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClaudeGauge.Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
