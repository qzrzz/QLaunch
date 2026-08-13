import AppKit
import Darwin

@main
enum QLaunchpadMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if LaunchpadCLI.isInvocation(args) {
            Darwin.exit(LaunchpadCLI.run(args))
        }

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
