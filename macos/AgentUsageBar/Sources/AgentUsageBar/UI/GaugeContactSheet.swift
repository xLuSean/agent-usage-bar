#if DEBUG
import AppKit
import UsageMeterCore

/// Renders every gauge state to a PNG so the menu bar artwork can be reviewed without
/// squinting at a 21-point icon. Development aid, reachable only via `--render-sheet`.
///
/// Each provider is drawn twice, once per appearance, because the gauge is not a
/// template image: AppKit will not adapt it, and a colour that reads on a dark menu
/// bar can vanish on a light one. Rendering both is the only way to see that.
enum GaugeContactSheet {

    private static let scale: CGFloat = 4
    private static let rowHeight = GaugeImageRenderer.size.height * scale + 18
    private static let headerHeight: CGFloat = 36
    private static let labelWidth: CGFloat = 250
    private static let cellWidth = GaugeImageRenderer.size.width * scale + 28

    private struct Column {
        let provider: ProviderKind
        let appearance: NSAppearance
        let background: NSColor
        let title: String
    }

    private static var columns: [Column] {
        ProviderKind.allCases.flatMap { provider in
            [
                Column(
                    provider: provider,
                    appearance: NSAppearance(named: .aqua)!,
                    background: NSColor(white: 0.97, alpha: 1),
                    title: "\(provider.displayName) Light"
                ),
                Column(
                    provider: provider,
                    appearance: NSAppearance(named: .darkAqua)!,
                    background: NSColor(white: 0.13, alpha: 1),
                    title: "\(provider.displayName) Dark"
                ),
            ]
        }
    }

    static func write(to path: String) throws {
        let scenarios = DemoScenario.allCases
        let columns = self.columns
        let width = labelWidth + cellWidth * CGFloat(columns.count) + 16
        let height = headerHeight + rowHeight * CGFloat(scenarios.count + 1) + 12

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

            // Each column keeps its own background all the way down, so a gauge is
            // always seen against the menu bar tone it was rendered for.
            for (index, column) in columns.enumerated() {
                let x = labelWidth + cellWidth * CGFloat(index)
                column.background.setFill()
                NSBezierPath(rect: NSRect(x: x, y: headerHeight, width: cellWidth, height: height - headerHeight)).fill()
                drawText(column.title, at: NSPoint(x: x + 10, y: 12), bold: true, color: .black)
            }
            drawText("State", at: NSPoint(x: 16, y: 12), bold: true, color: .black)

            for (row, scenario) in scenarios.enumerated() {
                let rowTop = headerHeight + rowHeight * CGFloat(row)
                drawText(scenario.title, at: NSPoint(x: 16, y: rowTop + (rowHeight - 18) / 2), color: .black)
                for (index, column) in columns.enumerated() {
                    var gauge = NSImage()
                    column.appearance.performAsCurrentDrawingAppearance {
                        let model = GaugeStyleResolver.renderModel(provider: column.provider, state: scenario.state())
                        gauge = GaugeImageRenderer.image(
                            for: model,
                            identityColor: SettingsStore.defaultColor(for: column.provider).nsColor
                        )
                    }
                    draw(
                        gauge,
                        size: NSSize(
                            width: GaugeImageRenderer.size.width * scale,
                            height: GaugeImageRenderer.size.height * scale
                        ),
                        x: labelWidth + cellWidth * CGFloat(index) + 14,
                        rowTop: rowTop,
                        appearance: column.appearance
                    )
                }
            }

            // The combined layout, drawn once per appearance so its identity cues can be
            // judged at the size they actually ship at.
            let combinedTop = headerHeight + rowHeight * CGFloat(scenarios.count)
            drawText("Combined (one icon)", at: NSPoint(x: 16, y: combinedTop + (rowHeight - 18) / 2), color: .black)
            for (index, column) in columns.enumerated() where column.provider == .claude {
                _ = index
                var combined = NSImage()
                column.appearance.performAsCurrentDrawingAppearance {
                    combined = GaugeImageRenderer.combinedImage(for: ProviderKind.allCases.map { provider in
                        (
                            model: GaugeStyleResolver.renderModel(
                                provider: provider,
                                state: provider == .claude ? DemoScenario.healthy.state() : DemoScenario.notLoggedIn.state()
                            ),
                            identityColor: SettingsStore.defaultColor(for: provider).nsColor
                        )
                    })
                }
                // The combined icon is nearly twice as wide as a single gauge, so it
                // needs its own scale to stay inside the column instead of bleeding
                // into the next one.
                let fitted = min(scale, (cellWidth - 20) / combined.size.width)
                draw(
                    combined,
                    size: NSSize(width: combined.size.width * fitted, height: combined.size.height * fitted),
                    x: labelWidth + cellWidth * CGFloat(index) + 10,
                    rowTop: combinedTop,
                    appearance: column.appearance
                )
            }

            let lastTop = headerHeight + rowHeight * CGFloat(scenarios.count + 1)
            drawText("Both disabled (default app icon)", at: NSPoint(x: 16, y: lastTop + (rowHeight - 18) / 2), color: .black)
            for (index, column) in columns.enumerated() where column.provider == .claude {
                var icon = NSImage()
                column.appearance.performAsCurrentDrawingAppearance { icon = GaugeImageRenderer.neutralAppIcon() }
                draw(
                    icon,
                    size: NSSize(width: 18 * scale, height: 18 * scale),
                    x: labelWidth + cellWidth * CGFloat(index) + 16,
                    rowTop: lastTop,
                    appearance: column.appearance
                )
            }
            return true
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// The sheet's context is flipped for text layout; the gauges are not, so each one
    /// is drawn through an unflipped transform to keep the fill growing from the
    /// bottom rather than the top.
    private static func draw(_ image: NSImage, size: NSSize, x: CGFloat, rowTop: CGFloat, appearance: NSAppearance) {
        let rect = NSRect(
            x: x,
            y: rowTop + (rowHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: rect.maxY + rect.minY)
        transform.scaleX(by: 1, yBy: -1)
        transform.concat()
        appearance.performAsCurrentDrawingAppearance {
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ text: String, at point: NSPoint, bold: Bool = false, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: bold ? .semibold : .regular),
            .foregroundColor: color,
        ]
        NSAttributedString(string: text, attributes: attributes).draw(at: point)
    }
}
#endif
