import AppKit
import Combine
import Sparkle

/// Sparkle 更新管理器（对齐 QCopy / Qjiao）。
///
/// Feed URL 与 EdDSA 公钥来自 Info.plist 的 `SUFeedURL` / `SUPublicEDKey`。
/// 单例在 `AppDelegate` 启动时武装，关于页「检查更新」复用同一实例。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let releasesURL = URL(string: "https://github.com/qzrzz/QLaunch/releases")!

    private let controller: SPUStandardUpdaterController

    /// 正在检查时禁用按钮，避免重复触发。
    @Published private(set) var canCheckForUpdates = false

    /// Debug 始终可点（打开 GitHub）；Release 跟随 Sparkle 会话状态。
    var isCheckEnabled: Bool {
        #if DEBUG
        true
        #else
        canCheckForUpdates
        #endif
    }

    private init() {
        // Debug 不启动：避免把 Dev.app 换成 Release，也不弹出自动检查提示。
        #if DEBUG
        let startImmediately = false
        #else
        let startImmediately = true
        #endif

        controller = SPUStandardUpdaterController(
            startingUpdater: startImmediately,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        if startImmediately && controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        #if DEBUG
        NSWorkspace.shared.open(Self.releasesURL)
        #else
        controller.checkForUpdates(nil)
        #endif
    }
}
