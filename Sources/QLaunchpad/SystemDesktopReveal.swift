import AppKit
import Darwin

@MainActor
enum SystemDesktopReveal {
    private typealias SendDockNotification = @convention(c) (CFString, CFDictionary?) -> Void

    private static let sendDockNotification: SendDockNotification? = {
        guard let framework = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ), let symbol = dlsym(framework, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: SendDockNotification.self)
    }()

    /// The full-screen Show Desktop overlay moved from Dock to WindowManager.
    /// Use window metadata so this works without Screen Recording permission.
    static func isActive() -> Bool? {
        guard let screen = NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        let bounds = CGDisplayBounds(displayID)
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier
        let managerPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager")
            .first?.processIdentifier
        let stageManagerEnabled = CFPreferencesGetAppBooleanValue(
            "GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString, nil
        )
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        var hasDesktopOverlay = false
        var hasExposeShield = false
        var hasStageManagerShield = false

        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid == dockPID || pid == managerPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let windowBounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: windowBounds as CFDictionary),
                  rect.insetBy(dx: -1, dy: -1).contains(bounds) else { continue }
            if layer == 18 { hasDesktopOverlay = true }
            if pid == managerPID {
                if layer == 19 { hasExposeShield = true }
                if layer == desktopIconLevel { hasStageManagerShield = true }
            }
        }

        if hasExposeShield { return false }
        if hasDesktopOverlay { return true }
        // Stage Manager can reveal the desktop by removing its event shield.
        return stageManagerEnabled && managerPID != nil && !hasStageManagerShield
    }

    static func restoreWindowsIfDesktopIsActive() {
        guard let sendDockNotification, isActive() == true else { return }
        sendDockNotification("com.apple.showdesktop.awake" as CFString, nil)
    }
}
