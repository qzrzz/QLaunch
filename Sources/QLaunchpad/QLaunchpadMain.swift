import AppKit

@main
enum QLaunchpadMain {
    static func main() {
        let application = NSApplication.shared
        application.applicationIconImage = QLaunchpadAppIcon.image
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
