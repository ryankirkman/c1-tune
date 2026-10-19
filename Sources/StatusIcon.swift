import AppKit

/// The menu bar icon: the Opal C1 seen from the front. A flat slab with the lens at the
/// left and the 4×3 vent grid at the right, cut out of a template image so macOS tints it.
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 3.25, width: 23, height: 11.5)
            let lensD: CGFloat = 9.2
            let inset = (body.height - lensD) / 2
            let lens = NSRect(x: body.minX + inset, y: body.minY + inset, width: lensD, height: lensD)
            let glassD = lensD * 0.44
            let glass = NSRect(x: lens.midX - glassD / 2, y: lens.midY - glassD / 2, width: glassD, height: glassD)

            // Vent grid: 4 columns × 3 rows between the lens and the right edge.
            let margin: CGFloat = 2.1, vent: CGFloat = 1.55
            let x0 = lens.maxX + 2, x1 = body.maxX - margin
            let y0 = body.minY + margin, y1 = body.maxY - margin
            var vents: [NSRect] = []
            for column in 0..<4 {
                for row in 0..<3 {
                    let x: CGFloat = x0 + (x1 - x0) * CGFloat(column) / 3
                    let y: CGFloat = y0 + (y1 - y0) * CGFloat(row) / 2
                    vents.append(NSRect(x: x - vent / 2, y: y - vent / 2, width: vent, height: vent))
                }
            }

            NSColor.black.set()
            NSBezierPath(roundedRect: body, xRadius: 1.2, yRadius: 1.2).fill()
            let context = NSGraphicsContext.current
            context?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: lens).fill()
            vents.forEach { NSBezierPath(ovalIn: $0).fill() }
            context?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: glass).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "C1 Tune"
        return image
    }
}
