import AppKit

enum QLaunchpadResources {
    private static let bundleName = "QLaunchpad_QLaunchpad.bundle"

    /// Resolve resources without using SwiftPM's generated `Bundle.module`
    /// accessor. In a packaged app SwiftPM looks beside the `.app`, while the
    /// resource bundle belongs in `Contents/Resources`; on another machine its
    /// build-directory fallback is also unavailable and traps the process.
    static var bundle: Bundle? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ].compactMap { $0 }

        return candidates.lazy.compactMap(Bundle.init(url:)).first
    }
}

enum QLaunchpadAppIcon {
    /// Full-color app icon (Dock / About / applicationIconImage).
    static var image: NSImage? {
        image(named: "QLaunchpadAppIcon")
    }

    /// Menu bar status item icon (`icons/qlaunch-menubar.png`).
    /// Template so light/dark menu bars tint correctly.
    static var menuBarImage: NSImage? {
        guard let image = image(named: "qlaunch-menubar") else { return nil }
        // 64px source → 18pt display (≈@3.5x; AppKit scales cleanly).
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    /// Bundle resource PNG (About social icons, author logo, …).
    static func resourceImage(
        named name: String,
        template: Bool = false,
        pointSize: CGFloat? = nil
    ) -> NSImage? {
        guard let image = image(named: name) else { return nil }
        if let pointSize {
            image.size = NSSize(width: pointSize, height: pointSize)
        }
        image.isTemplate = template
        return image
    }

    private static func image(named name: String) -> NSImage? {
        guard let bundle = QLaunchpadResources.bundle,
              let url = bundle.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
