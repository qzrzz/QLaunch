import AppKit
import QLaunchpadCore
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        let status = SMAppService.mainApp.status
        if enabled {
            if status != .enabled && status != .requiresApproval {
                try SMAppService.mainApp.register()
            }
        } else if status != .notRegistered && status != .notFound {
            try SMAppService.mainApp.unregister()
        }
        return SMAppService.mainApp.status
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum LaunchpadLaunchProbe {
    static func currentReason() -> LaunchpadLaunchReason {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return LaunchpadLaunchReason.resolve(
            commandLineArguments: Array(CommandLine.arguments.dropFirst()),
            appleEventID: event.map { UInt32($0.eventID) },
            appleEventLaunchedAsLoginItem: event.map(indicatesLoginItem) ?? false,
            loginItemEnabled: LaunchAtLogin.isEnabled,
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func indicatesLoginItem(_ event: NSAppleEventDescriptor) -> Bool {
        let loginKeyword = LaunchpadLaunchReason.launchedAsLoginItemKeyword
        if event.paramDescriptor(forKeyword: loginKeyword) != nil {
            return true
        }
        return event.paramDescriptor(forKeyword: LaunchpadLaunchReason.appleEventPropDataKeyword)?
            .paramDescriptor(forKeyword: loginKeyword) != nil
    }
}
