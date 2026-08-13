import AppKit
import CoreText
import Metal

/// One rasterized app name: tight UV + on-screen size in **points**.
struct LabelLayout: Sendable {
    var sheet: Int
    /// Metal top-left normalized UV (x, y, w, h).
    var uv: SIMD4<Float>
    /// Exact display size in points (sprite must use this — never stretch).
    var widthPoints: CGFloat
    var heightPoints: CGFloat
    /// Atlas texel count. Sprite framebuffer size must match these exactly.
    var widthPixels: Int
    var heightPixels: Int
}

/// System-font atlas with grayscale antialiasing and drop shadow.
///
/// CoreText coverage and CG shadows are authored for a gamma destination.
/// 8-bit modes stay in Display P3. Quality rasterizes the same way, then
/// composites a separate shadow layer into linear float16 so the blur ramp
/// is not crushed by a linear working space.
final class TextAtlas: @unchecked Sendable {
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
    /// Resolve AppKit's dynamic system-font name once on the main thread. Atlas
    /// replacements can then use CoreText exclusively while building off-main.
    private let fontName: String

    static let pointSize: CGFloat = 14
    static let maxWidthPoints: CGFloat = 152
    static let shadowOffsetPoints = CGSize(width: 0, height: 1)
    static let shadowBlurPoints: CGFloat = 2
    static let shadowOpacity: CGFloat = 0.55
    /// Linear dest makes the same black alpha look weaker than gamma.
    /// Scale the whole ramp; do not reshape it.
    static let qualityShadowAlphaGain: Float = 1.01

    init(device: MTLDevice) {
        self.device = device
        fontName = NSFont.systemFont(ofSize: Self.pointSize, weight: .medium).fontName
    }

    private init(device: MTLDevice, fontName: String) {
        self.device = device
        self.fontName = fontName
    }

    /// Build into an isolated replacement so the renderer can keep reading the
    /// current atlas while CoreText, CoreGraphics, and texture uploads run on a
    /// utility executor.
    func rebuilt(with apps: [AppInfo], scale: CGFloat, options: Options) -> TextAtlas {
        let replacement = TextAtlas(device: device, fontName: fontName)
        replacement.rebuild(with: apps, scale: scale, options: options)
        return replacement
    }

    /// Constant-time main-thread adoption of a completed background build.
    func replaceContents(with replacement: TextAtlas) {
        sheets = replacement.sheets
        layouts = replacement.layouts
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

        let uiFont = CTFontCreateWithName(fontName as CFString, pixelFontSize, nil)

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let textColor = CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!
        let shadowColor = CGColor(colorSpace: colorSpace, components: [0, 0, 0, Self.shadowOpacity])!
        let rasterBytesPerPixel = 4
        let textureBytesPerPixel = options.useUnorm8 ? 4 : 4 * MemoryLayout<Float16>.size

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
            guard !Task.isCancelled else { return }
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
        let rasterBytesPerRow = atlasWidth * rasterBytesPerPixel
        let textureBytesPerRow = atlasWidth * textureBytesPerPixel
        let pixelFormat: MTLPixelFormat = options.useUnorm8 ? .rgba8Unorm : .rgba16Float

        var sheetIndex = 0
        var cursorX = 0
        var cursorY = 0
        var rowHeight = 0
        var currentContext: CGContext?
        var linearSheet: [Float16] = []

        func beginSheet() -> Bool {
            guard let context = Self.makeGammaContext(
                width: atlasWidth,
                height: atlasHeight,
                colorSpace: colorSpace
            ) else { return false }
            currentContext = context
            linearSheet = options.useUnorm8
                ? []
                : [Float16](repeating: 0, count: atlasWidth * atlasHeight * 4)
            cursorX = 0
            cursorY = 0
            rowHeight = 0
            return true
        }

        func finishSheet() {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: atlasWidth,
                height: atlasHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                currentContext = nil
                return
            }
            if options.useUnorm8, let data = currentContext?.data {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
                    mipmapLevel: 0,
                    withBytes: data,
                    bytesPerRow: rasterBytesPerRow
                )
            } else {
                linearSheet.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
                        mipmapLevel: 0,
                        withBytes: base,
                        bytesPerRow: textureBytesPerRow
                    )
                }
            }
            sheets.append(texture)
            currentContext = nil
            sheetIndex += 1
        }

        if !beginSheet() { return }

        for item in prepared {
            guard !Task.isCancelled else { return }
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
            let cgY = atlasHeight - packY - ph
            let cgRect = CGRect(x: packX, y: cgY, width: pw, height: ph)

            let contentW = CGFloat(pw - item.padX * 2)
            let offsetX = CGFloat(item.padX) + max(0, (contentW - item.textWidthPx) * 0.5)
            let baselineY = CGFloat(item.padY) + item.descentPx

            if options.useUnorm8, let context = currentContext {
                Self.drawLine(
                    item.line,
                    in: context,
                    dest: cgRect,
                    offsetX: offsetX,
                    baselineY: baselineY,
                    textColor: textColor,
                    shadowOffset: shadowOffsetPx,
                    shadowBlur: shadowBlurPx,
                    shadowColor: shadowColor
                )
            } else {
                Self.rasterQualityLabel(
                    line: item.line,
                    destX: packX,
                    destY: packY,
                    width: pw,
                    height: ph,
                    offsetX: offsetX,
                    baselineY: baselineY,
                    textColor: textColor,
                    shadowOffset: shadowOffsetPx,
                    shadowBlur: shadowBlurPx,
                    shadowColor: shadowColor,
                    colorSpace: colorSpace,
                    linearSheet: &linearSheet,
                    atlasWidth: atlasWidth
                )
            }

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
                heightPoints: item.heightPoints,
                widthPixels: pw,
                heightPixels: ph
            )

            cursorX += pw
            rowHeight = max(rowHeight, ph)
        }

        finishSheet()
    }

    private static func configureTextRaster(_ context: CGContext) {
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSmoothing(false)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setAllowsFontSubpixelPositioning(true)
        context.setAllowsFontSubpixelQuantization(true)
        context.textMatrix = .identity
    }

    private static func makeGammaContext(
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) -> CGContext? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        configureTextRaster(context)
        return context
    }

    private static func drawLine(
        _ line: CTLine,
        in context: CGContext,
        dest: CGRect,
        offsetX: CGFloat,
        baselineY: CGFloat,
        textColor: CGColor,
        shadowOffset: CGSize?,
        shadowBlur: CGFloat,
        shadowColor: CGColor?
    ) {
        context.saveGState()
        context.clip(to: dest.insetBy(dx: -1, dy: -1))
        if let shadowOffset, let shadowColor {
            context.setShadow(
                offset: CGSize(width: shadowOffset.width, height: -shadowOffset.height),
                blur: shadowBlur,
                color: shadowColor
            )
        } else {
            context.setShadow(offset: .zero, blur: 0)
        }
        context.setFillColor(textColor)
        context.textPosition = CGPoint(x: dest.minX + offsetX, y: dest.minY + baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Shadow and glyph are separate layers so the blur ramp is not remapped
    /// by a luma-dependent alpha curve. Text coverage still decodes through
    /// sRGB; shadow alpha is only scaled.
    private static func rasterQualityLabel(
        line: CTLine,
        destX: Int,
        destY: Int,
        width: Int,
        height: Int,
        offsetX: CGFloat,
        baselineY: CGFloat,
        textColor: CGColor,
        shadowOffset: CGSize,
        shadowBlur: CGFloat,
        shadowColor: CGColor,
        colorSpace: CGColorSpace,
        linearSheet: inout [Float16],
        atlasWidth: Int
    ) {
        guard
            let shadowCtx = makeGammaContext(width: width, height: height, colorSpace: colorSpace),
            let textCtx = makeGammaContext(width: width, height: height, colorSpace: colorSpace)
        else { return }

        let dest = CGRect(x: 0, y: 0, width: width, height: height)
        drawLine(
            line,
            in: shadowCtx,
            dest: dest,
            offsetX: offsetX,
            baselineY: baselineY,
            textColor: textColor,
            shadowOffset: shadowOffset,
            shadowBlur: shadowBlur,
            shadowColor: shadowColor
        )
        shadowCtx.saveGState()
        shadowCtx.setShadow(offset: .zero, blur: 0)
        shadowCtx.setBlendMode(.destinationOut)
        shadowCtx.setFillColor(textColor)
        shadowCtx.textPosition = CGPoint(x: dest.minX + offsetX, y: dest.minY + baselineY)
        CTLineDraw(line, shadowCtx)
        shadowCtx.restoreGState()

        drawLine(
            line,
            in: textCtx,
            dest: dest,
            offsetX: offsetX,
            baselineY: baselineY,
            textColor: textColor,
            shadowOffset: nil,
            shadowBlur: 0,
            shadowColor: nil
        )

        guard let shadowData = shadowCtx.data, let textData = textCtx.data else { return }
        let shadow = shadowData.assumingMemoryBound(to: UInt8.self)
        let text = textData.assumingMemoryBound(to: UInt8.self)
        let gain = qualityShadowAlphaGain
        for y in 0..<height {
            for x in 0..<width {
                let src = (y * width + x) * 4
                let sA = min(1, Float(shadow[src + 3]) * (1.0 / 255.0) * gain)
                let tA = srgbToLinear(Float(text[src + 3]) * (1.0 / 255.0))
                let outA = tA + sA * (1 - tA)
                let destIndex = ((destY + y) * atlasWidth + (destX + x)) * 4
                linearSheet[destIndex] = Float16(tA)
                linearSheet[destIndex + 1] = Float16(tA)
                linearSheet[destIndex + 2] = Float16(tA)
                linearSheet[destIndex + 3] = Float16(outA)
            }
        }
    }

    private static func srgbToLinear(_ encoded: Float) -> Float {
        if encoded <= 0.04045 { return encoded / 12.92 }
        return pow((encoded + 0.055) / 1.055, 2.4)
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
