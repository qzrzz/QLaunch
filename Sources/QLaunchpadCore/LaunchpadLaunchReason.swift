import Foundation

/// Why this process started. Login-item launches must stay in the background;
/// every other start (first install, later Finder / Spotlight / `open -a`)
/// should present the launchpad so the UI is reachable without a Dock or
/// menu-bar icon.
public enum LaunchpadLaunchReason: Equatable, Sendable {
    public static let launchedAtLoginArgument = "--launched-at-login"

    /// `'oapp'` — `kAEOpenApplication`.
    public static let openApplicationEventID: UInt32 = 0x6F61_7070
    /// `'logi'` — `keyAELaunchedAsLogInItem`.
    public static let launchedAsLoginItemKeyword: UInt32 = 0x6C6F_6769
    /// `'prdt'` — `keyAEPropData`.
    public static let appleEventPropDataKeyword: UInt32 = 0x7072_6474

    case user
    case loginItem

    /// Login items usually exec within this window after boot. Used only when
    /// the Apple Event flag is missing (`SMAppService.mainApp` does not always
    /// set `'logi'`).
    public static let loginItemBootWindow: TimeInterval = 45

    public static func resolve(
        commandLineArguments: [String],
        appleEventID: UInt32?,
        appleEventLaunchedAsLoginItem: Bool,
        loginItemEnabled: Bool = false,
        systemUptime: TimeInterval? = nil
    ) -> Self {
        if commandLineArguments.contains(launchedAtLoginArgument) {
            return .loginItem
        }
        if appleEventLaunchedAsLoginItem,
           appleEventID == nil || appleEventID == openApplicationEventID {
            return .loginItem
        }
        // Fallback: a registered login item starting in the first seconds
        // after boot is almost certainly launchd, not a user click.
        if loginItemEnabled,
           let systemUptime,
           systemUptime >= 0,
           systemUptime < loginItemBootWindow {
            return .loginItem
        }
        return .user
    }

    public var shouldPresentLaunchpad: Bool {
        self == .user
    }
}
