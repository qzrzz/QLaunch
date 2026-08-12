import AppKit

@main
enum QLaunchpadMain {
    static func main() {
        let application = NSApplication.shared
        // Packaged .app: use Icon Services (Assets.car / icns). Bare binary: flat PNG.
        if Bundle.main.bundleURL.pathExtension == "app" {
            application.applicationIconImage = NSWorkspace.shared.icon(
                forFile: Bundle.main.bundlePath
            )
        } else if let image = QLaunchpadAppIcon.image {
            application.applicationIconImage = image
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
