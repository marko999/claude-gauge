import AppKit
import ClaudeGaugeCore

/// Draws the menu-bar title as an image: `[5h ▰▰▰▰▱ 94%] [W ▰▰▰▰▰ 97%]`.
/// Uses a drawing-handler image so colours re-resolve when the menu bar
/// switches between light and dark appearance.
enum MenuBarImageRenderer {
    static let height: CGFloat = 18
    private static let barWidth: CGFloat = 26
    private static let barHeight: CGFloat = 7
    private static let innerGap: CGFloat = 4
    private static let segmentGap: CGFloat = 9

    private static var labelFont: NSFont { .systemFont(ofSize: 10, weight: .semibold) }
    private static var percentFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    private struct Segment {
        var label: NSAttributedString
        var percent: NSAttributedString?
        var fraction: Double
        var severity: UsageSeverity

        var width: CGFloat {
            var w = label.size().width + innerGap + barWidth
            if let percent {
                w += innerGap + percent.size().width
            }
            return ceil(w)
        }
    }

    static func image(
        windows: [UsageWindow],
        mode: StatusDisplayMode,
        style: MenuBarStyle
    ) -> NSImage {
        let segments = windows.map { window -> Segment in
            let shown = displayedPercent(window, mode: mode)
            let label = NSAttributedString(
                string: window.shortLabel,
                attributes: [.font: labelFont, .foregroundColor: NSColor.labelColor]
            )
            var percent: NSAttributedString?
            if style == .barAndText {
                percent = NSAttributedString(
                    string: formatPercent(shown),
                    attributes: [.font: percentFont, .foregroundColor: NSColor.labelColor]
                )
            }
            return Segment(
                label: label,
                percent: percent,
                fraction: shown / 100,
                severity: severity(of: window)
            )
        }

        let totalWidth = segments.reduce(CGFloat(0)) { $0 + $1.width }
            + segmentGap * CGFloat(max(0, segments.count - 1))
        let size = NSSize(width: max(1, totalWidth), height: height)

        return NSImage(size: size, flipped: false) { rect in
            var x: CGFloat = 0
            for segment in segments {
                let labelSize = segment.label.size()
                segment.label.draw(at: NSPoint(x: x, y: (rect.height - labelSize.height) / 2))
                x += labelSize.width + innerGap

                let barRect = NSRect(
                    x: x, y: (rect.height - barHeight) / 2, width: barWidth, height: barHeight
                )
                drawBar(in: barRect, fraction: segment.fraction, severity: segment.severity)
                x += barWidth

                if let percent = segment.percent {
                    x += innerGap
                    let percentSize = percent.size()
                    percent.draw(at: NSPoint(x: x, y: (rect.height - percentSize.height) / 2))
                    x += percentSize.width
                }
                x += segmentGap
            }
            return true
        }
    }

    private static func drawBar(in rect: NSRect, fraction: Double, severity: UsageSeverity) {
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        let fill = NSRect(
            x: rect.minX, y: rect.minY,
            width: max(rect.height, rect.width * clamped), height: rect.height
        )
        let color: NSColor
        switch severity {
        case .normal: color = .systemGreen
        case .warning: color = .systemOrange
        case .critical: color = .systemRed
        }
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
