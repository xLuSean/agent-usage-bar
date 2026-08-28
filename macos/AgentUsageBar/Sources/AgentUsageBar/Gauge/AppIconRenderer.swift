import AppKit

/// Draws the app's own icon at every size macOS asks for.
///
/// Original artwork. Neither vendor's logo appears here or anywhere else in the app —
/// both brand guidelines forbid recolouring or altering their marks, and the whole
/// design is a fill level drawn *inside* the shape, which would be altering it twice.
///
/// Generated in code rather than shipped as an asset so the icon and the menu bar
/// gauge cannot drift apart: they are the same shape.
enum AppIconRenderer {

    /// The sizes an `.icns` needs, as `(pixel size, iconset filename)`.
    static let iconSetEntries: [(CGFloat, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    static func writeIconSet(to directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (size, name) in iconSetEntries {
            let data = try pngData(size: size)
            try data.write(to: url.appendingPathComponent(name))
        }
    }

    static func pngData(size: CGFloat) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw CocoaError(.fileWriteUnknown) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size: size)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func draw(size: CGFloat) {
        // macOS icons sit inset inside their canvas rather than filling it edge to edge.
        let inset = size * 0.06
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

        NSGradient(
            colors: [
                NSColor(srgbRed: 0.42, green: 0.31, blue: 0.86, alpha: 1),
                NSColor(srgbRed: 0.24, green: 0.55, blue: 0.90, alpha: 1),
            ]
        )?.draw(in: tilePath, angle: -90)

        // The same upright level gauge the menu bar draws, scaled up.
        let gaugeHeight = tile.height * 0.60
        let gaugeWidth = gaugeHeight * 0.58
        let gauge = NSRect(
            x: tile.midX - gaugeWidth / 2,
            y: tile.midY - gaugeHeight / 2,
            width: gaugeWidth,
            height: gaugeHeight
        )
        let stroke = max(1, size * 0.035)
        let frame = NSBezierPath(
            roundedRect: gauge.insetBy(dx: stroke / 2, dy: stroke / 2),
            xRadius: gaugeWidth * 0.30,
            yRadius: gaugeWidth * 0.30
        )
        frame.lineWidth = stroke
        NSColor.white.setStroke()
        frame.stroke()

        // Filled to roughly two thirds: recognisable as a level, and never mistaken for
        // an empty or exhausted state in the Dock.
        //
        // The fill is clipped to the well rather than drawn as its own rounded shape.
        // A separately rounded rectangle reads as a pill floating inside another pill;
        // clipping gives it the well's curve at the bottom and a flat surface on top,
        // which is what makes it look like a level instead of a smaller icon.
        let inner = gauge.insetBy(dx: stroke * 1.9, dy: stroke * 1.9)
        let wellRadius = inner.width * 0.42
        let well = NSBezierPath(roundedRect: inner, xRadius: wellRadius, yRadius: wellRadius)

        NSColor.white.withAlphaComponent(0.22).setFill()
        well.fill()

        NSGraphicsContext.saveGraphicsState()
        well.addClip()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(
            x: inner.minX, y: inner.minY,
            width: inner.width, height: inner.height * 0.66
        )).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
