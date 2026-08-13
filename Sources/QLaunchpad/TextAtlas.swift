import AppKit
import CoreText
import Metal

/// One rasterized app name: tight UV + on-screen size in **points**.
struct LabelLayout {
    var sheet: Int
    /// Metal top-left normalized UV (x, y, w, h).
    var uv: SIMD4<Float>
    /// Exact display size in points (sprite must use this — never stretch).
    var widthPoints: CGFloat
    var heightPoints: CGFloat
}

/// Linear Display P3 system-font atlas with grayscale antialiasing and drop shadow.
@MainActor
final class TextAtlas {
    struct Options: Equatable, Sendable {
        var useUnorm8: Bool
        var maxWidth: Int
        var maxHeight: Int
        var fitToContent: Bool

        /// Quality: fixed 2048² float16.
        static let standard = Options(
            useUnorm8: false, maxWidth: 2048, maxHeight: 2048, fitToContent: false
        )
        /// Performance: fixed 2048² 8-bit, full catalog.
        static let performance = Options(
            useUnorm8: true, maxWidth: 2048, maxHeight: 2048, fitToContent: false
        )
        /// Low memory: 8-bit sheet sized to the current page window.
        static let lowMemory = Options(
            useUnorm8: true, maxWidth: 1024, maxHeight: 1024, fitToContent: true
        )
    }

    private(set) var sheets: [MTLTexture] = []
    private(set) var layouts: [String: LabelLayout] = [:]

    private let device: MTLDevice

    static let pointSize: CGFloat = 14
    static let maxWidthPoints: CGFloat = 152
    static let shadowOffsetPoints = CGSize(width: 0, height: 1)
    static let shadowBlurPoints: CGFloat = 2
    static let shadowOpacity: CGFloat = 0.55

    init(device: MTLDevice) {
        self.device = device
    }

    func clear() {
        layouts.removeAll(keepingCapacity: true)
        sheets.removeAll(keepingCapacity: true)
    }

    func rebuild(with apps: [AppInfo], scale: CGFloat, options: Options = .standard) {
        clear()
        guard !apps.isEmpty else { return }

        let scale = max(1, scale.rounded())
        let pixelFontSize = Self.pointSize * scale
        let maxWidthPixels = Self.maxWidthPoints * scale
        let shadowOffsetPx = CGSize(
            width: Self.shadowOffsetPoints.width * scale,
            height: Self.shadowOffsetPoints.height * scale
        )
        let shadowBlurPx = Self.shadowBlurPoints * scale
        let padX = Int(ceil(2 + abs(shadowOffsetPx.width) + shadowBlurPx))
        let padY = Int(ceil(2 + abs(shadowOffsetPx.height) + shadowBlurPx))

        let uiFont = CTFontCreateWithName(
            NSFont.systemFont(ofSize: pixelFontSize, weight: .medium).fontName as CFString,
            pixelFontSize,
            nil
        )

        // 8-bit bitmaps cannot use extendedLinearDisplayP3 (CGContext is nil).
        let colorSpace = CGColorSpace(
            name: options.useUnorm8
                ? CGColorSpace.linearDisplayP3
                : CGColorSpace.extendedLinearDisplayP3
        )!
        let textColor = CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!
        let shadowColor = CGColor(colorSpace: colorSpace, components: [0, 0, 0, Self.shadowOpacity])!
        let bytesPerPixel = options.useUnorm8 ? 4 : 4 * MemoryLayout<Float16>.size

        struct Prepared {
            let id: String
            let line: CTLine
            let widthPoints: CGFloat
            let heightPoints: CGFloat
            let ascentPx: CGFloat
            let descentPx: CGFloat
            let pixelWidth: Int
            let pixelHeight: Int
            let textWidthPx: CGFloat
            let padX: Int
            let padY: Int
        }

        var prepared: [Prepared] = []
        prepared.reserveCapacity(apps.count)

        for app in apps {
            let name = app.name.isEmpty ? app.bundleIdentifier : app.name
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): uiFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
            ]
            let attributed = NSAttributedString(string: name, attributes: attributes)
            let fullLine = CTLineCreateWithAttributedString(attributed)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let rawWidthPx = CGFloat(CTLineGetTypographicBounds(fullLine, &ascent, &descent, &leading))

            let line: CTLine
            let textWidthPx: CGFloat
            if rawWidthPx > maxWidthPixels,
               let truncated = CTLineCreateTruncatedLine(fullLine, Double(maxWidthPixels), .end, nil) {
                line = truncated
                textWidthPx = min(
                    maxWidthPixels,
                    CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                )
            } else {
                line = fullLine
                textWidthPx = rawWidthPx
            }

            let contentH = ceil(ascent + descent + leading)
            let contentW = max(1, ceil(textWidthPx))
            let pixelWidth = max(1, Int(contentW) + padX * 2)
            let pixelHeight = max(1, Int(contentH) + padY * 2)

            prepared.append(Prepared(
                id: app.id,
                line: line,
                widthPoints: CGFloat(pixelWidth) / scale,
                heightPoints: CGFloat(pixelHeight) / scale,
                ascentPx: ascent,
                descentPx: descent,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                textWidthPx: textWidthPx,
                padX: padX,
                padY: padY
            ))
        }

        let atlasWidth: Int
        let atlasHeight: Int
        if options.fitToContent {
            let sizes = prepared.map { (
                min($0.pixelWidth, options.maxWidth),
                min($0.pixelHeight, options.maxHeight)
            ) }
            let fitted = Self.compactAtlasSize(
                glyphs: sizes,
                maxWidth: options.maxWidth,
                maxHeight: options.maxHeight
            )
            atlasWidth = fitted.width
            atlasHeight = fitted.height
        } else {
            atlasWidth = options.maxWidth
            atlasHeight = options.maxHeight
        }
        let bytesPerRow = atlasWidth * bytesPerPixel
        let bitsPerComponent = options.useUnorm8 ? 8 : 16
        let bitmapInfo = options.useUnorm8
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
                | CGBitmapInfo.floatComponents.rawValue
        let pixelFormat: MTLPixelFormat = options.useUnorm8 ? .rgba8Unorm : .rgba16Float

        var sheetIndex = 0
        var cursorX = 0
        var cursorY = 0
        var rowHeight = 0
        var currentContext: CGContext?

        func beginSheet() -> Bool {
            guard let context = CGContext(
                data: nil,
                width: atlasWidth,
                height: atlasHeight,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight))
            // Transparent compositing needs grayscale coverage, not legacy LCD
            // subpixel colors. Geometric antialiasing remains enabled below.
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSmoothing(false)
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setAllowsFontSubpixelQuantization(true)
            context.textMatrix = .identity
            currentContext = context
            cursorX = 0
            cursorY = 0
            rowHeight = 0
            return true
        }

        func finishSheet() {
            guard let context = currentContext,
                  let data = context.data else {
                currentContext = nil
                return
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: atlasWidth,
                height: atlasHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            if let texture = device.makeTexture(descriptor: descriptor) {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
                    mipmapLevel: 0,
                    withBytes: data,
                    bytesPerRow: bytesPerRow
                )
                sheets.append(texture)
            }
            currentContext = nil
            sheetIndex += 1
        }

        if !beginSheet() { return }

        for item in prepared {
            let pw = min(item.pixelWidth, atlasWidth)
            let ph = min(item.pixelHeight, atlasHeight)

            if cursorX + pw > atlasWidth {
                cursorX = 0
                cursorY += rowHeight
                rowHeight = 0
            }
            if cursorY + ph > atlasHeight {
                finishSheet()
                if !beginSheet() { return }
            }

            let packX = cursorX
            let packY = cursorY
            // CG bottom-left y for top-left pack.
            let cgY = atlasHeight - packY - ph
            let cgRect = CGRect(x: packX, y: cgY, width: pw, height: ph)

            guard let context = currentContext else { return }
            context.saveGState()
            context.clip(to: cgRect.insetBy(dx: -1, dy: -1))

            let contentW = CGFloat(pw - item.padX * 2)
            let offsetX = CGFloat(item.padX) + max(0, (contentW - item.textWidthPx) * 0.5)
            let baselineY = CGFloat(item.padY) + item.descentPx
            let baseX = cgRect.minX + offsetX
            let baseY = cgRect.minY + baselineY

            context.setShadow(
                offset: CGSize(width: shadowOffsetPx.width, height: -shadowOffsetPx.height),
                blur: shadowBlurPx,
                color: shadowColor
            )
            context.setFillColor(textColor)
            context.textPosition = CGPoint(x: baseX, y: baseY)
            CTLineDraw(item.line, context)
            context.restoreGState()

            // CGBitmapContext stores its first memory row at the visual top for
            // this format, matching Metal's v=0 row and the top-left pack coords.
            let uv = SIMD4(
                Float(packX) / Float(atlasWidth),
                Float(packY) / Float(atlasHeight),
                Float(pw) / Float(atlasWidth),
                Float(ph) / Float(atlasHeight)
            )
            layouts[item.id] = LabelLayout(
                sheet: sheetIndex,
                uv: uv,
                widthPoints: item.widthPoints,
                heightPoints: item.heightPoints
            )

            cursorX += pw
            rowHeight = max(rowHeight, ph)
        }

        finishSheet()
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var size = 64
        while size < value { size *= 2 }
        return size
    }

    /// Pack into the smallest POT sheet that holds every glyph (one sheet if possible).
    private static func compactAtlasSize(
        glyphs: [(width: Int, height: Int)],
        maxWidth: Int,
        maxHeight: Int
    ) -> (width: Int, height: Int) {
        var packWidth = min(512, maxWidth)
        while true {
            let packed = simulatePack(glyphs, atlasWidth: packWidth, atlasHeight: maxHeight)
            if packed.sheetCount == 1 {
                let height = min(maxHeight, nextPowerOfTwo(max(packed.usedHeight, 64)))
                return (packWidth, height)
            }
            if packWidth >= maxWidth {
                return (maxWidth, maxHeight)
            }
            packWidth = min(maxWidth, packWidth * 2)
        }
    }

    private static func simulatePack(
        _ glyphs: [(width: Int, height: Int)],
        atlasWidth: Int,
        atlasHeight: Int
    ) -> (sheetCount: Int, usedHeight: Int) {
        var sheets = 1
        var cursorX = 0
        var cursorY = 0
        var rowHeight = 0
        var usedHeight = 0
        for glyph in glyphs {
            let width = min(glyph.width, atlasWidth)
            let height = min(glyph.height, atlasHeight)
            if cursorX + width > atlasWidth {
                cursorX = 0
                cursorY += rowHeight
                rowHeight = 0
            }
            if cursorY + height > atlasHeight {
                sheets += 1
                cursorX = 0
                cursorY = 0
                rowHeight = 0
            }
            cursorX += width
            rowHeight = max(rowHeight, height)
            usedHeight = max(usedHeight, cursorY + rowHeight)
        }
        return (sheets, max(usedHeight, 64))
    }
}
