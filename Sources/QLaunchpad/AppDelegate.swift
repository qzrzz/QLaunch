import AppKit
import QLaunchpadCore
import SwiftUI

final class LaunchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
            return
        }
        if event.modifierFlags.contains(.command), event.keyCode == 43 {
            NotificationCenter.default.post(name: .qlaunchpadOpenSettings, object: nil)
            return
        }
        super.keyDown(with: event)
    }

    /// Fade the panel without the default AppKit window animation glitches.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        0.22
    }
}

extension Notification.Name {
    static let qlaunchpadOpenSettings = Notification.Name("QLaunchpadOpenSettings")
    static let qlaunchpadAppearanceChanged = Notification.Name("QLaunchpadAppearanceChanged")
    static let qlaunchpadHotKeyRecordingChanged = Notification.Name("QLaunchpadHotKeyRecordingChanged")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = AppStore()
    private var launchpadPanel: LaunchpadPanel!
    private var containerView: LaunchpadContainerView!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var showMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?
    private var globalHotKeyMonitor: Any?
    private var localHotKeyMonitor: Any?
    private var isAnimating = false
    private var presentationGeneration: UInt = 0
    private var activeAnimationStyle: LaunchpadAnimationStyle = .fly
    private var isRecordingHotKey = false
    private var launchReason: LaunchpadLaunchReason = .user
    private var ignoreReopenUntil: Date?
    /// Ignore Dock reopen until the first homepage icons are on screen.
    private var ignoreLaunchReopen = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The login-item Apple Event is only reliable while launch is in flight.
        launchReason = LaunchpadLaunchProbe.currentReason()
        // Overlap the filesystem scan with panel / Metal setup.
        store.load()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildLaunchpadPanel()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(layoutDidChangeExternally(_:)),
            name: .qlaunchpadLayoutDidChange,
            object: nil
        )
        store.load()
        installHotKey()
        applyDockIconPreference()
        installStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dismissRequested(_:)),
            name: .qlaunchpadDismiss,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .qlaunchpadOpenSettings,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: .qlaunchpadAppearanceChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gridLayoutChanged),
            name: .qlaunchpadGridLayoutChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotKeyRecordingChanged(_:)),
            name: .qlaunchpadHotKeyRecordingChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        // 提前武装 Sparkle，自动检查不依赖是否打开关于页。
        _ = Updater.shared

        // User-initiated starts (first install and later Finder / Spotlight /
        // `open -a`) present the launchpad. A login-item start stays in the
        // background so it does not interrupt the desktop coming up.
        if launchReason.shouldPresentLaunchpad, launchpadPanel != nil {
            ignoreLaunchReopen = true
            showLaunchpad()
        } else if let container = containerView {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.store.waitUntilLoaded()
                await container.metal.prepareFirstPageIcons()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalHotKeyMonitor { NSEvent.removeMonitor(globalHotKeyMonitor) }
        if let localHotKeyMonitor { NSEvent.removeMonitor(localHotKeyMonitor) }
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: .qlaunchpadLayoutDidChange,
            object: nil
        )
    }

    @objc private func layoutDidChangeExternally(_ note: Notification) {
        let domain = note.object as? String
        guard domain == Bundle.main.bundleIdentifier else { return }
        DispatchQueue.main.async { [weak self] in
            self?.store.reloadPersistedLayout()
        }
    }

    /// A regular Dock application receives this callback when its Dock icon is
    /// clicked. Treat the click as a toggle for the Launchpad panel.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // The same launch can deliver reopen immediately after
        // applicationDidFinishLaunching. Ignore that echo so a user start
        // that already presented the launchpad is not toggled closed.
        if ignoreLaunchReopen { return true }
        if let ignoreReopenUntil, Date() < ignoreReopenUntil {
            return true
        }
        toggleLaunchpad()
        return true
    }

    @objc private func screensChanged() {
        guard let screen = NSScreen.main else { return }
        if launchpadPanel.isVisible {
            launchpadPanel.setFrame(screen.frame, display: true)
        }
    }

    private func buildLaunchpadPanel() {
        guard let screen = NSScreen.main else { return }
        let panel = LaunchpadPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let container = LaunchpadContainerView(store: store)
        panel.contentView = container
        containerView = container
        launchpadPanel = panel
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === launchpadPanel else { return }

        // Opening Settings also makes the Launchpad resign key. Wait until
        // AppKit has finished ordering the new window or attached sheet before
        // deciding whether the Launchpad should be dismissed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let keyWindow = NSApp.keyWindow
            let isLaunchpadSheet = self.launchpadPanel.attachedSheet != nil
                || keyWindow?.sheetParent === self.launchpadPanel
            guard self.launchpadPanel.isVisible,
                  self.store.presentation != .hidden,
                  self.settingsWindow?.isKeyWindow != true,
                  !isLaunchpadSheet else { return }
            self.dismissLaunchpad()
        }
    }

    /// Settings already took key from the overlay, so `windowDidResignKey`
    /// will not fire again when the user opens a browser, Sparkle, or
    /// System Settings. Hide the fullscreen overlay so those windows are
    /// not covered.
    func applicationDidResignActive(_ notification: Notification) {
        guard settingsWindow?.isVisible == true else { return }
        dismissLaunchpad()
    }

    /// Sparkle and other in-app windows stay at the normal level. If one
    /// becomes key while the overlay is up, hide the overlay so it is visible.
    @objc private func appWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window !== launchpadPanel,
              window !== settingsWindow,
              window.sheetParent !== launchpadPanel,
              window.sheetParent !== settingsWindow,
              window.level <= .normal else { return }
        dismissLaunchpad()
    }

    private func installHotKey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, !self.isRecordingHotKey,
                  LaunchpadHotKeyPreferences.matches(event) else { return }
            self.toggleLaunchpad()
        }
        globalHotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !self.isRecordingHotKey, LaunchpadHotKeyPreferences.matches(event) {
                self.toggleLaunchpad()
                return nil
            }
            guard self.launchpadPanel.isVisible else { return event }
            // A sheet or Settings window may be key while Launchpad remains
            // visible. Let that window handle Return/arrows normally.
            guard self.launchpadPanel.isKeyWindow else { return event }

            // Do not steal arrows/Return while an IME candidate window is active.
            if let editor = self.launchpadPanel.firstResponder as? NSTextView,
               editor.hasMarkedText() {
                return event
            }
            if !modifiers.intersection([.command, .control, .option]).isEmpty {
                return event
            }

            // Typing an ASCII letter or number anywhere on the launchpad starts
            // a search. Commit the first character before requesting focus so it
            // cannot be lost while SwiftUI installs the native field editor.
            // A folder replaces the search field with its title — do not steal
            // those keys back into search.
            if self.store.openedFolderID == nil,
               !(self.launchpadPanel.firstResponder is NSTextView),
               let characters = self.searchCharacters(from: event) {
                self.store.updateSearch(self.store.searchText + characters)
                NotificationCenter.default.post(name: .qlaunchpadFocusSearch, object: nil)
                return nil
            }

            switch event.keyCode {
            case 53: // Escape
                self.dismissLaunchpad()
                return nil
            case 123: // Left
                self.store.moveKeyboardFocus(.left)
                return nil
            case 124: // Right
                self.store.moveKeyboardFocus(.right)
                return nil
            case 125: // Down
                self.store.moveKeyboardFocus(.down)
                return nil
            case 126: // Up
                self.store.moveKeyboardFocus(.up)
                return nil
            case 36, 76: // Return / keypad Enter
                switch self.store.focusedItem {
                case .app(let app):
                    self.openAppFromLaunchpad(app)
                    return nil
                case .folder(let folder):
                    self.store.enterFolder(folder.id)
                    return nil
                case nil:
                    break
                }
            default:
                break
            }
            return event
        }
    }

    private func searchCharacters(from event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        let isASCIIAlphaNumeric = characters.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
        }
        return isASCIIAlphaNumeric ? characters : nil
    }

    private func openAppFromLaunchpad(_ app: AppInfo) {
        store.recordAppLaunch(app)
        beginDismissal(openingAppID: app.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            QLaunchAppLauncher.open(app)
        }
    }

    private func installStatusItem() {
        guard statusItem == nil, showMenuBarIconPreference else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let icon = QLaunchpadAppIcon.menuBarImage {
            item.button?.image = icon
        } else {
            item.button?.image = NSImage(
                systemSymbolName: "square.grid.2x2.fill",
                accessibilityDescription: "QLaunch"
            )
        }
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "QLaunch"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        let showItem = NSMenuItem(
            title: "Show QLaunch",
            action: #selector(toggleLaunchpad),
            keyEquivalent: ""
        )
        showItem.target = self
        showMenuItem = showItem
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit QLaunch",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        statusMenu = menu
        // Do not assign the menu to NSStatusItem. That would make left-click
        // open the menu as well; the button action separates left and right.
        item.menu = nil
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        showMenuItem = nil
        statusMenu = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            statusMenu?.popUp(
                positioning: nil,
                at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY),
                in: sender
            )
        } else {
            toggleLaunchpad()
        }
    }

    private var showMenuBarIconPreference: Bool {
        UserDefaults.standard.object(forKey: QLaunchpadPreferences.showMenuBarIconKey) as? Bool
            ?? QLaunchpadPreferences.defaultShowMenuBarIcon
    }

    private var showDockIconPreference: Bool {
        UserDefaults.standard.object(forKey: QLaunchpadPreferences.showDockIconKey) as? Bool
            ?? QLaunchpadPreferences.defaultShowDockIcon
    }

    @objc private func appearanceChanged() {
        if showMenuBarIconPreference {
            installStatusItem()
        } else {
            removeStatusItem()
        }
        applyDockIconPreference()
        updateStatusMenu()
    }

    private func applyDockIconPreference() {
        NSApp.setActivationPolicy(showDockIconPreference ? .regular : .accessory)
    }

    @objc private func hotKeyRecordingChanged(_ note: Notification) {
        isRecordingHotKey = note.userInfo?["recording"] as? Bool ?? false
    }

    @objc private func gridLayoutChanged() {
        store.applyGridLayoutChange()
    }

    @objc private func toggleLaunchpad() {
        if store.isPresented || launchpadPanel.isVisible {
            dismissLaunchpad()
        } else {
            showLaunchpad()
        }
        updateStatusMenu()
    }

    // MARK: - Show / hide with correct fade

    private func showLaunchpad() {
        guard !isAnimating else { return }
        guard let screen = NSScreen.main else { return }

        isAnimating = true
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let animationStyle = LaunchpadAnimationStyle.current
        activeAnimationStyle = animationStyle

        store.beginPresenting()
        containerView.metal.beginPresentationHold()

        launchpadPanel.setFrame(screen.frame, display: false)
        // Disable AppKit's automatic utility-window transition when the user
        // explicitly selects no presentation animation. Otherwise orderOut()
        // can keep the panel (and its icons) visually disappearing slowly.
        launchpadPanel.animationBehavior = animationStyle == .none ? .none : .utilityWindow
        containerView.prepareForShow(on: screen)

        // Show the window and cached wallpaper immediately. Metal content starts
        // its own presentation animation after the primed drawable is ready.
        launchpadPanel.alphaValue = 1
        launchpadPanel.orderFrontRegardless()
        if animationStyle == .none {
            containerView.showWallpaperImmediately()
        } else {
            containerView.animateWallpaperIn()
        }
        NSApp.activate(ignoringOtherApps: true)
        launchpadPanel.makeKey()
        syncSettingsWindowLevel()

        // Prime the icon layer while the already-visible window shows its background.
        containerView.metal.submitFirstPresentationFrame(style: animationStyle) { [weak self] in
            self?.beginContentPresentation(
                generation: generation,
                animationStyle: animationStyle
            )
        }
    }

    private func beginContentPresentation(
        generation: UInt,
        animationStyle: LaunchpadAnimationStyle
    ) {
        guard generation == presentationGeneration,
              store.presentation == .presenting,
              launchpadPanel.isVisible else { return }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .qlaunchpadFocusSearch, object: nil)
        }

        // The GPU has replaced any retained drawable with this presentation's
        // transparent start frame, so revealing Metal cannot flash old icons.
        containerView.revealPrimedMetalContent()

        // Only Metal icons and overlay chrome fade in. The panel/background are
        // already fully visible and intentionally have no opening animation.
        NotificationCenter.default.post(
            name: .qlaunchpadPresentationChanged,
            object: nil,
            userInfo: [
                "showing": true,
                "animationStyle": animationStyle.rawValue
            ]
        )
        // Refresh the catalog after the open animation. The first-page bake
        // already waited for the initial scan so this pass does not block UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + animationStyle.duration) { [weak self] in
            guard let self,
                  generation == self.presentationGeneration,
                  self.store.isPresented,
                  self.launchpadPanel.isVisible else { return }
            self.store.load()
        }
        ignoreLaunchReopen = false
        ignoreReopenUntil = Date().addingTimeInterval(0.8)
        isAnimating = false
        updateStatusMenu()
    }

    @objc private func dismissLaunchpad() {
        beginDismissal(openingAppID: nil)
    }

    @objc private func dismissRequested(_ note: Notification) {
        beginDismissal(openingAppID: note.userInfo?["openingAppID"] as? String)
    }

    private func beginDismissal(openingAppID: String?) {
        // Ignore when already dismissed or mid-dismiss.
        if store.presentation == .dismissing || store.presentation == .hidden {
            return
        }
        guard launchpadPanel.isVisible || store.presentation == .presenting else {
            return
        }

        ignoreLaunchReopen = false
        isAnimating = true
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let animationStyle = activeAnimationStyle
        let dismissalDuration = animationStyle.dismissalDuration
            * CFTimeInterval(store.presentationProgress)
        store.beginDismissing()
        syncSettingsWindowLevel()

        var presentationInfo: [String: Any] = [
            "showing": false,
            "animationStyle": animationStyle.rawValue
        ]
        if let openingAppID {
            presentationInfo["openingAppID"] = openingAppID
        }
        NotificationCenter.default.post(
            name: .qlaunchpadPresentationChanged,
            object: nil,
            userInfo: presentationInfo
        )

        if dismissalDuration <= 0.0001 {
            completeDismissal(generation: generation)
        } else if animationStyle == .fade {
            // Fade the composited panel as one surface so wallpaper, Metal
            // icons, labels and SwiftUI chrome disappear in exact sync.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = dismissalDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                launchpadPanel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.completeDismissal(generation: generation)
                }
            })
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissalDuration + 0.02) {
                self.completeDismissal(generation: generation)
            }
        }
    }

    private func completeDismissal(generation: UInt) {
        guard generation == presentationGeneration else { return }
        containerView.hideImmediately()
        launchpadPanel.animationBehavior = .none
        launchpadPanel.alphaValue = 0
        launchpadPanel.orderOut(nil)
        containerView.background.refreshAfterHide()
        store.markHidden()
        isAnimating = false
        syncSettingsWindowLevel()
        updateStatusMenu()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func updateStatusMenu() {
        let visible = launchpadPanel?.isVisible == true && store.presentation != .hidden
        showMenuItem?.title = visible ? "Hide QLaunch" : "Show QLaunch"
    }

    @objc private func openSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        if let settingsWindow {
            syncSettingsWindowLevel()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 530, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "QLaunch 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 530, height: 550)
        // Keep Settings above the Launchpad panel when it is opened from the
        // main window. Drop back to `.normal` once the overlay is gone so
        // Sparkle and other app windows are not trapped underneath.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
        window.center()
        settingsWindow = window
        syncSettingsWindowLevel()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Settings must sit above the fullscreen overlay, but that same level
    /// hides Sparkle / browser windows once the overlay should go away.
    private func syncSettingsWindowLevel() {
        guard let settingsWindow else { return }
        settingsWindow.level = store.isPresented ? .popUpMenu : .normal
    }
}
