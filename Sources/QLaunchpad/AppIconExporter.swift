import AppKit

enum AppIconExportError: LocalizedError {
    case downloadsDirectoryUnavailable
    case rasterizationFailed

    var errorDescription: String? {
        switch self {
        case .downloadsDirectoryUnavailable:
            return "找不到下载目录。"
        case .rasterizationFailed:
            return "无法生成图标图片。"
        }
    }
}

/// Writes an application icon PNG into the user's Downloads folder.
enum AppIconExporter {
    /// Pixel size of the icon texture currently baked for the grid.
    static var currentPixelSize: Int {
        Int(GridLayoutPreset.current.iconPointSize * IconRenderQuality.current.rasterScale)
    }

    static func maximumPixelSize(for app: AppInfo) -> Int {
        max(maximumPixelSize(of: sourceImage(for: app)), currentPixelSize)
    }

    @discardableResult
    static func exportPNG(for app: AppInfo, pixelSize: Int) throws -> URL {
        let size = max(pixelSize, 1)
        let image = sourceImage(for: app)
        guard let data = pngData(from: image, pixelSize: size) else {
            throw AppIconExportError.rasterizationFailed
        }
        let directory = try downloadsDirectory()
        let url = uniqueURL(in: directory, baseName: app.name, pixelSize: size)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func sourceImage(for app: AppInfo) -> NSImage {
        let workspaceIcon = NSWorkspace.shared.icon(forFile: app.url.path)
        // Prefer the system icon service: it includes 1024pt / @2x variants
        // that the bundle .icns often omits. Fall back only when it is empty.
        if maximumPixelSize(of: workspaceIcon) > 0 {
            return workspaceIcon
        }
        return bundleIconImage(for: app) ?? workspaceIcon
    }

    private static func bundleIconImage(for app: AppInfo) -> NSImage? {
        guard let bundle = Bundle(url: app.url) else { return nil }

        if let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let name = (iconFile as NSString).deletingPathExtension
            let ext = (iconFile as NSString).pathExtension
            let candidates: [(String, String?)] = [
                (name, ext.isEmpty ? "icns" : ext),
                (iconFile, nil)
            ]
            for (resource, fileExtension) in candidates {
                if let url = bundle.url(forResource: resource, withExtension: fileExtension),
                   let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    private static func maximumPixelSize(of image: NSImage) -> Int {
        var largest = 0
        for representation in image.representations {
            let width = representation.pixelsWide
            let height = representation.pixelsHigh
            guard width > 0, height > 0 else { continue }
            largest = max(largest, max(width, height))
        }
        if largest > 0 { return largest }
        return max(Int(max(image.size.width, image.size.height).rounded()), 1)
    }

    private static func pngData(from source: NSImage, pixelSize: Int) -> Data? {
        if let exact = bestRepresentation(in: source, matching: pixelSize),
           let cgImage = exact.cgImage(forProposedRect: nil, context: nil, hints: nil),
           cgImage.width == pixelSize, cgImage.height == pixelSize,
           let data = pngData(from: cgImage) {
            return data
        }

        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: pixelSize, height: pixelSize)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func bestRepresentation(in image: NSImage, matching pixelSize: Int) -> NSImageRep? {
        image.representations.first {
            $0.pixelsWide == pixelSize && $0.pixelsHigh == pixelSize
        }
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func downloadsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw AppIconExportError.downloadsDirectoryUnavailable
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func uniqueURL(in directory: URL, baseName: String, pixelSize: Int) -> URL {
        let stem = "\(sanitizedFileName(baseName))-\(pixelSize)"
        let fileManager = FileManager.default
        var url = directory.appendingPathComponent("\(stem).png")
        var index = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem) \(index).png")
            index += 1
        }
        return url
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.illegalCharacters)
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "Icon"
        }
        return cleaned
    }
}
