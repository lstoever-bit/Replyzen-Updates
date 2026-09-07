import AppKit

/// User-visible branding is independent of the existing bundle/update identity.
enum ReplyZenBrand {
    static let displayName = "ReplyZen"
    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "ReplyzenLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    static let menuBarIcon: NSImage? = logo.flatMap { makeMenuBarTemplateIcon(from: $0) }

    private static func makeMenuBarTemplateIcon(from source: NSImage) -> NSImage? {
        let pixels = 36
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
            source.draw(
                in: NSRect(x: 1, y: 1, width: pixels - 2, height: pixels - 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let rowBytes = rep.bytesPerRow
        for y in 0..<pixels {
            for x in 0..<pixels {
                let i = y * rowBytes + x * 4
                let r = Int(data[i])
                let g = Int(data[i + 1])
                let b = Int(data[i + 2])
                let originalAlpha = Int(data[i + 3])
                let luminance = (r * 30 + g * 59 + b * 11) / 100
                let darkness = max(0, 255 - luminance)
                let alpha = darkness * originalAlpha / 255
                data[i] = 0
                data[i + 1] = 0
                data[i + 2] = 0
                data[i + 3] = UInt8(alpha)
            }
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

}
