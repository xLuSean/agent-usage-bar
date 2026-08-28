import AppKit
import UsageMeterCore

/// Draws the menu bar gauge.
///
/// Original artwork throughout: an upright liquid-level frame plus a letter. No
/// vendor logo is used or referenced, which is also the only way the design works —
/// the menu bar convention is a monochrome template image, recolouring a vendor logo
/// is forbidden by both vendors' brand rules, and drawing a fill level inside one
/// would be modifying it twice over.
///
/// `isTemplate` stays `false` because the image carries colour on purpose. That means
/// AppKit will not auto-adapt it to a light or dark menu bar, so the caller re-renders
/// on appearance changes and every colour here is a dynamic system colour.
enum GaugeImageRenderer {

    static let size = NSSize(width: 21, height: 18)

    private static let glyphWidth: CGFloat = 7.5
    private static let frameStroke: CGFloat = 1.5
    private static let innerInset: CGFloat = 1.2
    /// Keeps 1% used from rendering as nothing at all.
    private static let minimumVisibleFill: CGFloat = 2.0

    static func image(for model: GaugeRenderModel, identityColor: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(model: model, identityColor: identityColor)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = model.accessibilityLabel
        return image
    }

    static func draw(model: GaugeRenderModel, identityColor: NSColor, width: CGFloat? = nil) {
        let size = NSSize(width: width ?? Self.size.width, height: Self.size.height)
        let dimmed = model.frameStyle == .dashedEmpty || model.frameStyle == .disabledNeutral
        let outlineColor = dimmed ? identityColor.withAlphaComponent(0.55) : identityColor

        drawGlyph(model.glyph, color: outlineColor)

        let frameRect = NSRect(
            x: glyphWidth + 1.5,
            y: 1,
            width: size.width - glyphWidth - 3,
            height: size.height - 2
        )
        let framePath = NSBezierPath(roundedRect: frameRect.insetBy(dx: frameStroke / 2, dy: frameStroke / 2), xRadius: 3, yRadius: 3)
        framePath.lineWidth = frameStroke
        if model.frameStyle == .dashedEmpty {
            var pattern: [CGFloat] = [2.0, 1.6]
            framePath.setLineDash(&pattern, count: pattern.count, phase: 0)
        }
        outlineColor.setStroke()
        framePath.stroke()

        let innerRect = frameRect.insetBy(dx: frameStroke + innerInset, dy: frameStroke + innerInset)

        // A faint wash behind the fill. Without it the unfilled part of the gauge is
        // fully transparent, so over a photo wallpaper the icon is a thin outline with
        // the desktop showing through and reads as barely there. The wash gives the
        // whole gauge a body, which is what makes it legible against anything.
        if model.frameStyle != .dashedEmpty {
            NSColor.secondaryLabelColor.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: innerRect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        switch model.frameStyle {
        case .dashedEmpty, .disabledNeutral:
            drawNoReadingMark(in: innerRect)
        case .solid, .staleMarked, .throttledStriped:
            drawFill(model: model, in: innerRect)
        }

        if model.frameStyle == .staleMarked {
            drawStaleMark(near: frameRect)
        }
    }

    private static func drawGlyph(_ glyph: String, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = NSAttributedString(string: glyph, attributes: attributes)
        let bounds = text.size()
        text.draw(at: NSPoint(
            x: (glyphWidth - bounds.width) / 2,
            y: (size.height - bounds.height) / 2
        ))
    }

    private static func drawFill(model: GaugeRenderModel, in innerRect: NSRect) {
        // A fully consumed window gets an explicit mark rather than a full bar, so
        // "nothing left" cannot be misread as "the gauge is nicely full".
        if model.fillLevel == .exhausted {
            drawExhaustedSlash(in: innerRect)
            return
        }
        guard model.fillFraction > 0 else {
            drawNoReadingMark(in: innerRect)
            return
        }

        let height = max(minimumVisibleFill, innerRect.height * CGFloat(model.fillFraction))
        let fillRect = NSRect(x: innerRect.minX, y: innerRect.minY, width: innerRect.width, height: min(height, innerRect.height))

        let alpha: CGFloat = model.frameStyle == .staleMarked ? 0.4 : 1.0
        model.fillLevel.fillColor.withAlphaComponent(alpha).setFill()

        if model.frameStyle == .throttledStriped {
            // Horizontal stripes read as "held back" and stay distinguishable from the
            // stale style's reduced saturation, which is a different kind of doubt.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).addClip()
            var y = fillRect.minY
            while y < fillRect.maxY {
                NSBezierPath(rect: NSRect(x: fillRect.minX, y: y, width: fillRect.width, height: 1.2)).fill()
                y += 2.4
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private static func drawExhaustedSlash(in innerRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: innerRect.minX, y: innerRect.minY))
        path.line(to: NSPoint(x: innerRect.maxX, y: innerRect.maxY))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        path.stroke()
    }

    /// A neutral dash. Unknown must never look like 0%.
    ///
    /// `secondaryLabelColor` rather than `tertiaryLabelColor`: at 1.5 points the
    /// tertiary variant is close enough to invisible that "unknown" reads as "empty",
    /// which is the exact confusion the dash exists to prevent.
    private static func drawNoReadingMark(in innerRect: NSRect) {
        let markRect = NSRect(
            x: innerRect.minX + 0.5,
            y: innerRect.midY - 0.75,
            width: innerRect.width - 1,
            height: 1.5
        )
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: markRect, xRadius: 0.75, yRadius: 0.75).fill()
    }

    /// Triangle overlapping the top-right corner: a real reading, known to be old.
    ///
    /// Orange rather than a label colour so it survives both menu bar appearances, and
    /// punched out of the frame first so the corner does not blur into it at 21 points.
    private static func drawStaleMark(near frameRect: NSRect) {
        let tip = NSPoint(x: frameRect.maxX + 1, y: frameRect.maxY + 1)
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: tip.x - 7.0, y: tip.y))
        path.line(to: NSPoint(x: tip.x, y: tip.y - 7.0))
        path.close()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: tip.x - 1, y: tip.y - 1))
        mark.line(to: NSPoint(x: tip.x - 6.0, y: tip.y - 1))
        mark.line(to: NSPoint(x: tip.x - 1, y: tip.y - 6.0))
        mark.close()
        NSColor.systemOrange.setFill()
        mark.fill()
    }

    /// The entry point shown when every provider is switched off.
    ///
    /// Without it the menu bar has no icon at all and Settings becomes unreachable —
    /// the user can turn the app off but not back on. Neutral on purpose: a disabled
    /// provider is the user's choice, not a fault to report.
    static func neutralAppIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let rect = NSRect(x: 2.2, y: 1.5, width: 13.6, height: 15)
            let frame = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
            frame.lineWidth = 1.3
            NSColor.secondaryLabelColor.setStroke()
            frame.stroke()

            // A level line across the middle: the app's own mark, unrelated to any vendor's.
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: rect.minX + 2.6, y: rect.midY - 1.2))
            wave.curve(
                to: NSPoint(x: rect.maxX - 2.6, y: rect.midY + 1.2),
                controlPoint1: NSPoint(x: rect.midX - 1.6, y: rect.midY + 2.6),
                controlPoint2: NSPoint(x: rect.midX + 1.6, y: rect.midY - 2.6)
            )
            wave.lineWidth = 1.3
            wave.lineCapStyle = .round
            NSColor.secondaryLabelColor.setStroke()
            wave.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Agent Usage Bar, all providers disabled"
        return image
    }
}

extension GaugeImageRenderer {

    /// Draws several gauges inside one status item.
    ///
    /// The compact form keeps both non-colour identity cues — each gauge still carries
    /// its own letter and its own outline colour — because halving the width must not
    /// cost the ability to tell which reading belongs to whom. That is the one thing
    /// the plans make non-negotiable about this icon.
    ///
    /// Gauges are drawn narrower than in the separate layout, but the letter stays at
    /// full size: shrinking the glyph is what would actually make it unreadable.
    static func combinedImage(
        for models: [(model: GaugeRenderModel, identityColor: NSColor)]
    ) -> NSImage {
        guard !models.isEmpty else { return neutralAppIcon() }

        let spacing: CGFloat = 3
        let unitWidth = size.width - 2      // slightly tighter than standalone
        let totalWidth = unitWidth * CGFloat(models.count) + spacing * CGFloat(models.count - 1)

        let image = NSImage(size: NSSize(width: totalWidth, height: size.height), flipped: false) { _ in
            for (index, entry) in models.enumerated() {
                let x = (unitWidth + spacing) * CGFloat(index)
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: x, yBy: 0)
                transform.concat()
                draw(model: entry.model, identityColor: entry.identityColor, width: unitWidth)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = models.map(\.model.accessibilityLabel).joined(separator: "；")
        return image
    }

    static func combinedWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 24 }
        let unitWidth = size.width - 2
        return unitWidth * CGFloat(count) + 3 * CGFloat(count - 1) + 8
    }
}
