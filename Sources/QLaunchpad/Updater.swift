import AppKit
import Combine
import Sparkle

/// Sparkle 更新管理器（对齐 QCopy / Qjiao）。
///
/// Feed URL 与 EdDSA 公钥来自 Info.plist 的 `SUFeedURL` / `SUPublicEDKey`。
/// `SUEnableAutomaticChecks` 默认开启；用户可在设置-关于中改。
/// 单例在 `AppDelegate` 启动时武装，关于页「检查更新」复用同一实例。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    /// 正在检查时禁用按钮，避免重复触发。
    @Published private(set) var canCheckForUpdates = false

    /// 是否按 Sparkle 计划自动检查。值由 Sparkle 持久化在 UserDefaults。
    /// 只在用户改设置时写入，不要在启动时强行覆盖。
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Debug 在 updater 尚未启动时仍可点（首次点击再武装）；Release 跟随 Sparkle 会话状态。
    var isCheckEnabled: Bool {
        canCheckForUpdates || !didStartUpdater
    }

    private var didStartUpdater: Bool

    private init() {
        // Debug 不自动启动：避免把 Dev.app 换成 Release，也不弹出后台检查。
        // 关于页「检查更新」会按需启动。
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
        didStartUpdater = startImmediately
        // didSet 在 init 赋值时不触发，手动从 Sparkle 种子。
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        // 启动 updater 只会武装「按间隔」调度（约一天一次）。
        // 若开启了自动检查，在启动后立即做一次静默后台检查。
        if startImmediately && automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// 用户可见的检查更新（进度窗与确认提示），不打开网页。
    func checkForUpdates() {
        NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
        startUpdaterIfNeeded()
        controller.checkForUpdates(nil)
    }

    private func startUpdaterIfNeeded() {
        guard !didStartUpdater else { return }
        controller.startUpdater()
        didStartUpdater = true
    }
}
