import AppKit

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

    private static func image(named name: String) -> NSImage? {
        guard let bundle = resourceBundle,
              let url = bundle.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static var resourceBundle: Bundle? {
        let bundleName = "QLaunchpad_QLaunchpad.bundle"
        let appCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ].compactMap { $0 }

        for url in appCandidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        // Fallback for `swift run` / `swift build` executable launches.
        return Bundle.module
    }
}
