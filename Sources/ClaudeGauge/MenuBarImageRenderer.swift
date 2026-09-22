import AppKit
import ClaudeGaugeCore

/// Draws the menu-bar title as an image: `[5h ▰▰▰▰▱ 94%] [W ▰▰▰▰▰ 97%]`.
/// Uses a drawing-handler image so colours re-resolve when the menu bar
/// switches between light and dark appearance.
enum MenuBarImageRenderer {
    static let height: CGFloat = 18
    private static let barWidth: CGFloat = 34
    private static let barHeight: CGFloat = 9
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

    /// Full track = 100 %: a clearly outlined capsule, so the filled part reads as
    /// "this much of that". The fill is inset by the outline so the border stays visible.
    private static func drawBar(in rect: NSRect, fraction: Double, severity: UsageSeverity) {
        let radius = rect.height / 2
        let outline = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius
        )
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        outline.fill()
        NSColor.labelColor.withAlphaComponent(0.65).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        let innerRadius = inner.height / 2
        let fill = NSRect(
            x: inner.minX, y: inner.minY,
            width: max(inner.height, inner.width * clamped), height: inner.height
        )
        let color: NSColor
        switch severity {
        case .normal: color = .systemGreen
        case .warning: color = .systemOrange
        case .critical: color = .systemRed
        }
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: innerRadius, yRadius: innerRadius).fill()
    }
}
