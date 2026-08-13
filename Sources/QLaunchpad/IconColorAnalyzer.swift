import AppKit
import QLaunchpadCore

enum IconColorAnalyzer {
    private static let sampleSize = 24

    static func sample(url: URL) -> LaunchpadIconColor {
        sample(NSWorkspace.shared.icon(forFile: url.path))
    }

    static func sample(_ image: NSImage) -> LaunchpadIconColor {
        let size = sampleSize
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4,
            bitsPerPixel: 32
        ) else {
            return .neutral
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current = context
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { return .neutral }

        var sinHue = 0.0
        var cosHue = 0.0
        var satSum = 0.0
        var brightSum = 0.0
        var chromaticWeight = 0.0
        var grayBrightSum = 0.0
        var grayWeight = 0.0

        let rowBytes = bitmap.bytesPerRow
        for y in 0..<size {
            let row = data.advanced(by: y * rowBytes)
            for x in 0..<size {
                let pixel = row.advanced(by: x * 4)
                let alpha = Double(pixel[3]) / 255
                guard alpha > 0.2 else { continue }
                let red = Double(pixel[0]) / 255
                let green = Double(pixel[1]) / 255
                let blue = Double(pixel[2]) / 255
                let hsv = hsv(red: red, green: green, blue: blue)
                let weight = alpha * max(hsv.brightness, 0.08)
                if hsv.saturation < 0.16 || hsv.brightness < 0.12 {
                    grayBrightSum += hsv.brightness * weight
                    grayWeight += weight
                } else {
                    let angle = hsv.hue * 2 * Double.pi
                    let chromaWeight = weight * hsv.saturation
                    sinHue += sin(angle) * chromaWeight
                    cosHue += cos(angle) * chromaWeight
                    satSum += hsv.saturation * chromaWeight
                    brightSum += hsv.brightness * chromaWeight
                    chromaticWeight += chromaWeight
                }
            }
        }

        let total = chromaticWeight + grayWeight
        guard total > 0 else { return .neutral }
        if chromaticWeight < total * 0.18 {
            return LaunchpadIconColor(
                hue: 0,
                saturation: 0,
                brightness: grayWeight > 0 ? grayBrightSum / grayWeight : 0.5,
                isChromatic: false
            )
        }

        var hue = atan2(sinHue, cosHue) / (2 * Double.pi)
        if hue < 0 { hue += 1 }
        return LaunchpadIconColor(
            hue: hue,
            saturation: satSum / chromaticWeight,
            brightness: brightSum / chromaticWeight,
            isChromatic: true
        )
    }

    private static func hsv(red: Double, green: Double, blue: Double) -> (
        hue: Double,
        saturation: Double,
        brightness: Double
    ) {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0.0001 {
            if maxC == red {
                hue = (green - blue) / delta
            } else if maxC == green {
                hue = 2 + (blue - red) / delta
            } else {
                hue = 4 + (red - green) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxC > 0 ? delta / maxC : 0
        return (hue, saturation, maxC)
    }
}

private extension LaunchpadIconColor {
    static let neutral = LaunchpadIconColor(
        hue: 0,
        saturation: 0,
        brightness: 0.5,
        isChromatic: false
    )
}
