import AppKit
import Combine
import CoreServices
import Foundation
import os
import QLaunchpadCore

private let layoutLogger = Logger(subsystem: "com.qzrzz.qlaunchpad", category: "layout")

enum QLaunchpadPreferences {
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let showDockIconKey = "showDockIcon"

    // Default to a Dock-visible app. The menu bar icon is opt-in.
    static let defaultShowMenuBarIcon = false
    static let defaultShowDockIcon = true
}

enum LaunchpadHotKeyPreferences {
    static let keyCodeKey = "launchpadHotKeyCode"
    static let modifiersKey = "launchpadHotKeyModifiers"
    static let defaultKeyCode = 49 // Space
    static let defaultModifiers = Int(NSEvent.ModifierFlags.command.rawValue)

    static var keyCode: UInt16 {
        UInt16(UserDefaults.standard.object(forKey: keyCodeKey) as? Int ?? defaultKeyCode)
    }

    static var modifiers: NSEvent.ModifierFlags {
        let rawValue = UserDefaults.standard.object(forKey: modifiersKey) as? Int
            ?? defaultModifiers
        return NSEvent.ModifierFlags(rawValue: UInt(rawValue))
    }

    static func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.keyCode == keyCode
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                == modifiers.intersection(.deviceIndependentFlagsMask)
    }

    static func displayName(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        let modifierName = [
            (NSEvent.ModifierFlags.control, "⌃"),
            (NSEvent.ModifierFlags.option, "⌥"),
            (NSEvent.ModifierFlags.shift, "⇧"),
            (NSEvent.ModifierFlags.command, "⌘")
        ]
        .filter { modifiers.contains($0.0) }
        .map(\.1)
        .joined()

        let keyName: String
        switch keyCode {
        case 49: keyName = "Space"
        case 36: keyName = "Return"
        case 48: keyName = "Tab"
        case 51: keyName = "Delete"
        case 53: keyName = "Esc"
        case 123: keyName = "←"
        case 124: keyName = "→"
        case 125: keyName = "↓"
        case 126: keyName = "↑"
        case 122: keyName = "F1"
        case 120: keyName = "F2"
        case 99: keyName = "F3"
        case 118: keyName = "F4"
        case 96: keyName = "F5"
        case 97: keyName = "F6"
        case 98: keyName = "F7"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 109: keyName = "F10"
        case 103: keyName = "F11"
        case 111: keyName = "F12"
        default:
            keyName = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
                17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
                24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
                32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
                41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`"
            ][Int(keyCode)] ?? "Key \(keyCode)"
        }
        return modifierName + keyName
    }
}

struct AppInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let bundleIdentifier: String
    /// Search metadata generated once while the application catalog is built.
    /// Full pinyin and initials include polyphone variants so 音乐 matches
    /// both `yy` / `yinyue` and the Unihan default `yl` / `yinle`.
    let pinyin: PinyinSearchMetadata
    let installedAt: Date?
    let lastUsedAt: Date?

    init(
        id: String,
        name: String,
        url: URL,
        bundleIdentifier: String,
        installedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.pinyin = PinyinSearchMetadata.make(for: name)
        self.installedAt = installedAt
        self.lastUsedAt = lastUsedAt
    }
}

enum QLaunchAppLauncher {
    static func open(_ app: AppInfo) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Multiple copies can share a bundle identifier. Always launch the
        // selected bundle instead of substituting another running copy.
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(
            at: app.url,
            configuration: configuration,
            completionHandler: nil
        )
    }
}

typealias AppFolder = QLaunchpadCore.AppFolder

enum LaunchpadItem: Identifiable, Hashable {
    case app(AppInfo)
    case folder(AppFolder)

    var id: String {
        switch self {
        case .app(let app): app.id
        case .folder(let folder): folder.id
        }
    }
}

struct AppIconCache {
    /// `NSWorkspace` is already backed by the system icon cache. Returning the
    /// original multi-representation image preserves its ICC profile until the
    /// renderer performs the single linear Display P3 rasterization.
    func image(for app: AppInfo, size: CGFloat = 512) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: app.url.path)
        return (source.copy() as? NSImage) ?? source
    }
}

enum AppScanner {
    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications")
        ]
    }

    static func scan(additionalRoots: [URL] = []) -> [AppInfo] {
        struct Candidate {
            let url: URL
            let bundleIdentifier: String
            let displayName: String
            let fileName: String
        }

        let fileManager = FileManager.default
        let roots = defaultRoots + additionalRoots

        var candidates: [Candidate] = []
        var seenPaths = Set<String>()
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .localizedNameKey,
            .addedToDirectoryDateKey,
            .creationDateKey
        ]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                let standardizedPath = url.standardizedFileURL.path
                guard seenPaths.insert(standardizedPath).inserted else { continue }
                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier else { continue }
                // Skip background-only / agent helpers without a UI when possible.
                if let bgOnly = bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool, bgOnly {
                    continue
                }
                if let uiElement = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, uiElement {
                    // Still allow menu-bar apps that users expect to launch.
                }
                let fileName = url.deletingPathExtension().lastPathComponent
                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? fileName
                candidates.append(
                    Candidate(
                        url: url,
                        bundleIdentifier: identifier,
                        displayName: displayName,
                        fileName: fileName
                    )
                )
            }
        }

        let candidatesByIdentifier = Dictionary(grouping: candidates, by: \.bundleIdentifier)
        let apps = candidates.map { candidate -> AppInfo in
            let siblings = candidatesByIdentifier[candidate.bundleIdentifier] ?? [candidate]
            let sameNameSiblings = siblings.filter { $0.displayName == candidate.displayName }
            let useFileName = sameNameSiblings.count > 1
                && Set(sameNameSiblings.map(\.fileName)).count > 1

            // Keep the old bundle ID for the first path so existing hidden-app
            // and folder preferences continue to resolve after an extra copy
            // of the app is discovered.
            let primaryPath = siblings.min {
                $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path
            }?.url.standardizedFileURL.path
            let id: String
            if siblings.count == 1 || candidate.url.standardizedFileURL.path == primaryPath {
                id = candidate.bundleIdentifier
            } else {
                id = "\(candidate.bundleIdentifier)#\(candidate.url.standardizedFileURL.path)"
            }

            let dates = AppUsageMetadata.dates(for: candidate.url)
            return AppInfo(
                id: id,
                name: useFileName ? candidate.fileName : candidate.displayName,
                url: candidate.url,
                bundleIdentifier: candidate.bundleIdentifier,
                installedAt: dates.installedAt,
                lastUsedAt: dates.lastUsedAt
            )
        }

        return apps.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.url.path < $1.url.path
        }
    }
}

enum AppUsageMetadata {
    static func dates(for url: URL) -> (installedAt: Date?, lastUsedAt: Date?) {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        let installedAt = values?.addedToDirectoryDate ?? values?.creationDate
        return (installedAt, spotlightLastUsed(url: url))
    }

    private static func spotlightLastUsed(url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

// MARK: - Presentation state (fade / scale window)

enum LaunchpadPresentation: Equatable {
    case hidden
    case presenting
    case visible
    case dismissing
}

/// Icon raster + Metal filter + residency profile for Launchpad sprites.
enum IconRenderQuality: String, CaseIterable, Identifiable {
    /// 4× float16 + binomial; full catalog resident for max smoothness.
    case quality
    /// 2× 8-bit sRGB; full catalog resident for smooth paging.
    case performance
    /// Same bake as performance, but page-window lazy load / prune for low RAM.
    case lowMemory

    static let defaultsKey = "iconRenderQuality"
    static let defaultQuality: Self = .performance

    var id: Self { self }

    var title: String {
        switch self {
        case .quality: "画质优先"
        case .performance: "性能优先"
        case .lowMemory: "低内存占用"
        }
    }

    var detail: String {
        switch self {
        case .quality:
            "最高画质，设计师必备，内存消耗更高"
        case .performance:
            "常规画质，与系统显示效果相当"
        case .lowMemory:
            "常规画质，为减小内存消耗，滚动页面时图标加载会更慢"
        }
    }

    /// Source pixels per layout point when baking icon textures.
    var rasterScale: CGFloat {
        switch self {
        case .quality: 4
        case .performance, .lowMemory: 2
        }
    }

    /// `true` when icons use the linear float16 bake path (quality only).
    var usesLinearFloat16Textures: Bool {
        switch self {
        case .quality: true
        case .performance, .lowMemory: false
        }
    }

    /// `true` = page-window cache + async miss; `false` = full-catalog resident.
    var usesLazyTextureLoading: Bool {
        switch self {
        case .quality, .performance: false
        case .lowMemory: true
        }
    }

    /// Fragment path: 1 = binomial (quality), 0 = bilinear (performance / low memory).
    var shaderQualityMode: Float {
        switch self {
        case .quality: 1
        case .performance, .lowMemory: 0
        }
    }

    /// Quality keeps a float16 drawable. Performance and low memory present 8-bit Display P3.
    var usesUnorm8Drawable: Bool {
        switch self {
        case .quality: false
        case .performance, .lowMemory: true
        }
    }

    /// Triple buffer for fluent animation; double buffer to drop one 4K surface.
    var maximumDrawableCount: Int { self == .lowMemory ? 2 : 3 }

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let quality = Self(rawValue: rawValue) else {
            return defaultQuality
        }
        return quality
    }
}

enum LaunchpadAnimationStyle: String, CaseIterable, Identifiable {
    case fly
    case zoom
    case fade
    case none

    static let defaultsKey = "presentationAnimationStyle"

    var id: Self { self }

    var title: String {
        switch self {
        case .fly: "飞入（iOS 桌面）"
        case .zoom: "放大"
        case .fade: "渐入"
        case .none: "无"
        }
    }

    var duration: CFTimeInterval {
        switch self {
        case .fly: 1.3
        case .zoom: 0.62
        case .fade: 0.26
        case .none: 0
        }
    }

    var dismissalDuration: CFTimeInterval {
        switch self {
        case .fly: 0.48
        case .zoom: 0.22
        case .fade: 0.25
        case .none: 0
        }
    }

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let style = Self(rawValue: rawValue) else {
            return .fly
        }
        return style
    }
}

enum GridNavigationDirection {
    case left
    case right
    case up
    case down
}

// MARK: - App store + paging

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []
    @Published private(set) var filteredApps: [AppInfo] = []
    @Published private(set) var launchpadItems: [LaunchpadItem] = []
    @Published private(set) var folders: [AppFolder] = []
    @Published private(set) var openedFolderID: String?
    @Published private(set) var isDraggingFolderApp = false
    @Published private(set) var isFolderRemovalTargeted = false
    @Published private(set) var searchText = ""
    @Published private(set) var isLoading = true
    @Published private(set) var isApplyingRenderQuality = false
    @Published private(set) var keyboardFocusID: String?
    @Published private(set) var isKeyboardNavigationActive = false
    @Published private(set) var hiddenAppIDs: Set<String>
    @Published private(set) var customApplicationSourcePaths: [String]
    @Published private(set) var layoutProfiles: [LaunchpadLayoutProfile]
    @Published private(set) var activeLayoutProfileID: String
    @Published private(set) var layoutMode: LaunchpadLayoutMode
    @Published var showHiddenAppsInSearch: Bool {
        didSet {
            UserDefaults.standard.set(showHiddenAppsInSearch, forKey: LaunchpadPersistence.showHiddenAppsKey)
            refreshFilteredApps(resetPage: true)
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        }
    }

    /// Continuous page position (0 = first page). Driven by scroll + spring settle.
    ///
    /// Not `@Published`: Metal reads this every frame during a drag, and
    /// publishing would rebuild the SwiftUI overlay on every pointer sample.
    /// Integer page chrome observes `targetPage` / explicit `objectWillChange`.
    var pageOffset: Double = 0

    /// Target page used for snapping after a gesture ends.
    @Published private(set) var targetPage: Double = 0

    /// 0…1 presentation progress for window fade / content scale-in.
    ///
    /// Metal updates this once per display-link tick. SwiftUI does not render
    /// from it, so publishing every change only invalidates all AppStore views
    /// (and used to make PageIndicator rebuild the automatic layout each frame).
    var presentationProgress: CGFloat = 0

    @Published private(set) var presentation: LaunchpadPresentation = .hidden

    /// Horizontal page velocity in pages/second (trackpad momentum).
    private(set) var pageVelocity: Double = 0

    /// `true` while the user is actively scrolling (finger / wheel phase).
    @Published private(set) var isPageGestureActive = false

    var pageCapacity: Int { GridMetrics.pageCapacity }

    func setApplyingRenderQuality(_ applying: Bool) {
        if isApplyingRenderQuality != applying {
            isApplyingRenderQuality = applying
        }
    }
    private var scrollAccumulated: Double = 0
    private var lastScrollTime: CFTimeInterval = 0
    /// Locked for the whole trackpad gesture so noisy Y samples cannot reverse X.
    private var scrollAxis: PageScrollAxis = .undecided
    private var scrollAxisAccumX: Double = 0
    private var scrollAxisAccumY: Double = 0
    /// After finger-up settle, leftover trackpad momentum must not start a new flip.
    private var ignoreScrollMomentum = false
    /// Un-rubber-banded page at mouse-down. Pointer X maps 1:1 onto this origin.
    private var pagePanOrigin: Double = 0
    /// Root-grid page captured when a folder opens, restored when it closes.
    private var pageBeforeFolder: Double?
    /// Root-grid page captured when search starts, restored when search clears.
    private var pageBeforeSearch: Double?
    private var scanTask: Task<Void, Never>?
    private var layoutGeneration: UInt64 = 0
    /// Bumped by import / external reload so Metal can drop an in-flight drag.
    private(set) var dragGeneration: UInt64 = 0

    private enum PageScrollAxis {
        case undecided
        case horizontal
        case vertical
    }

    /// Points of scroll delta that equal one full page turn.
    private let pageScrollUnit: Double = 320
    private let scrollAxisLockPoints: Double = 8

    private var itemOrderIDs: [String]
    private var recentLaunchDates: [String: Date]
    private var iconColorByAppID: [String: LaunchpadIconColor] = [:]
    private var iconColorTask: Task<Void, Never>?
    /// Fully materialized automatic layouts. Getters and render paths only read
    /// this dictionary; filtering and sorting are performed by detached tasks.
    private var autoLayoutItemsByKind: [LaunchpadAutoLayoutKind: [LaunchpadItem]] = [:]
    private var autoLayoutFallbackItems: [LaunchpadItem] = []
    private var autoLayoutGeneration: [LaunchpadAutoLayoutKind: UInt64] = [:]
    private var autoLayoutTasks: [LaunchpadAutoLayoutKind: Task<Void, Never>] = [:]
    /// Layouts whose last complete value remains readable until it can be
    /// refreshed outside a presentation animation (currently recent launches).
    private var deferredAutoLayoutKinds = Set<LaunchpadAutoLayoutKind>()

    private static var preferenceDomain: String {
        Bundle.main.bundleIdentifier ?? (kCFPreferencesCurrentApplication as String)
    }

    init() {
        let layout = LaunchpadPreferenceStore.readLayout(domain: Self.preferenceDomain)
        LaunchpadPreferenceStore.writeThroughToStandardDefaults(layout)
        hiddenAppIDs = Set(layout.hiddenIDs)
        itemOrderIDs = layout.itemOrder
        folders = (try? LaunchpadPreferenceStore.decodeFolders(layout.foldersData)) ?? []
        let profileIndex = LaunchpadLayoutProfileStore.loadIndex(domain: Self.preferenceDomain)
        layoutProfiles = profileIndex.profiles
        activeLayoutProfileID = profileIndex.activeID

        let defaults = UserDefaults.standard
        customApplicationSourcePaths = defaults.stringArray(forKey: LaunchpadPersistence.customSourcesKey) ?? []
        showHiddenAppsInSearch = defaults.bool(forKey: LaunchpadPersistence.showHiddenAppsKey)
        layoutMode = LaunchpadLayoutMode(
            storageValue: defaults.string(forKey: LaunchpadPersistence.layoutModeKey)
        )
        if let rawDates = defaults.dictionary(forKey: LaunchpadPersistence.recentLaunchDatesKey) as? [String: Double] {
            recentLaunchDates = rawDates.mapValues { Date(timeIntervalSince1970: $0) }
        } else {
            recentLaunchDates = [:]
        }
        rebuildLaunchpadItems()
    }

    deinit {
        scanTask?.cancel()
        iconColorTask?.cancel()
        autoLayoutTasks.values.forEach { $0.cancel() }
    }

    var pageCount: Int {
        max(1, Int(ceil(Double(max(activeDisplayItems.count, 1)) / Double(pageCapacity))))
    }

    var currentPage: Int {
        min(max(Int(pageOffset.rounded()), 0), max(pageCount - 1, 0))
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isPresented: Bool {
        presentation == .visible || presentation == .presenting
    }

    var focusedItem: LaunchpadItem? {
        guard let keyboardFocusID else { return nil }
        return activeDisplayItems.first { $0.id == keyboardFocusID }
    }

    var focusedApp: AppInfo? {
        guard case .app(let app) = focusedItem else { return nil }
        return app
    }

    var hiddenApps: [AppInfo] {
        apps.filter { hiddenAppIDs.contains($0.id) }
    }

    var canDeleteActiveLayoutProfile: Bool {
        layoutMode.isUser && LaunchpadLayoutProfileStore.canDelete(activeLayoutProfileID)
    }

    var activeLayoutProfileName: String {
        layoutProfiles.first { $0.id == activeLayoutProfileID }?.name
            ?? LaunchpadLayoutProfileStore.defaultProfileName
    }

    var allowsUserLayoutEditing: Bool {
        layoutMode.isUser && !isSearching
    }

    var layoutSelectorID: String {
        switch layoutMode {
        case .user:
            return LaunchpadLayoutSelectorID.user(activeLayoutProfileID)
        case .auto(let kind):
            return LaunchpadLayoutSelectorID.auto(kind)
        }
    }

    /// Top-level items shown by Launchpad. Search intentionally remains a flat
    /// app list so a result can always be launched without opening a folder.
    var displayItems: [LaunchpadItem] {
        if isSearching {
            return filteredApps.map(LaunchpadItem.app)
        }
        switch layoutMode {
        case .user:
            return launchpadItems
        case .auto(let kind):
            // Never sort from a getter. While a new materialization is pending,
            // preserve a complete deterministic list using scanner order.
            return autoLayoutItemsByKind[kind] ?? autoLayoutFallbackItems
        }
    }

    /// Items shown by the current Launchpad view. A folder is a page whose
    /// contents use the same grid as the root view; it is not a separate panel.
    var activeDisplayItems: [LaunchpadItem] {
        guard let openedFolderID,
              let folder = folder(withID: openedFolderID) else {
            return displayItems
        }
        return folder.appIDs.compactMap { app(withID: $0).map(LaunchpadItem.app) }
    }

    var openedFolder: AppFolder? {
        guard let openedFolderID else { return nil }
        return folder(withID: openedFolderID)
    }

    /// Folder order as it appears in the root grid, used by context-menu
    /// submenus so their order always matches the visible pages.
    var orderedFolders: [AppFolder] {
        launchpadItems.compactMap { item in
            if case .folder(let folder) = item { return folder }
            return nil
        }
    }

    func app(withID id: String) -> AppInfo? {
        apps.first { $0.id == id }
    }

    func folder(withID id: String) -> AppFolder? {
        folders.first { $0.id == id }
    }

    func folderContaining(appID: String) -> AppFolder? {
        folders.first { $0.appIDs.contains(appID) }
    }

    func setFolderDragState(isDragging: Bool, removalTargeted: Bool = false) {
        let targeted = isDragging && removalTargeted
        guard isDraggingFolderApp != isDragging
                || isFolderRemovalTargeted != targeted else { return }
        isDraggingFolderApp = isDragging
        isFolderRemovalTargeted = targeted
    }

    func load() {
        // A detached scan cannot be stopped reliably once it has started.
        // Ignore duplicate requests instead of allowing two filesystem scans
        // to run at the same time. Import / external reload must not cancel
        // or nil this task — they only bump `layoutGeneration`.
        guard scanTask == nil else { return }

        isLoading = true
        let generationAtStart = layoutGeneration
        let additionalRoots = customApplicationSourcePaths.map { URL(fileURLWithPath: $0) }
        scanTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                AppScanner.scan(additionalRoots: additionalRoots)
            }.value
            guard let self else { return }
            let catalogChanged = apps != result
            let affectedAutoLayouts: Set<LaunchpadAutoLayoutKind> = catalogChanged
                ? autoLayoutsAffectedByCatalogChange(from: apps, to: result)
                : []
            let persistedLayoutChanged = layoutGeneration != generationAtStart
            let hiddenBeforeReload = hiddenAppIDs
            if catalogChanged {
                apps = result
                rebindAutoLayoutItemsToCurrentCatalog()
                rebuildAutoLayoutFallbackItems()
            }
            if persistedLayoutChanged {
                layoutLogger.debug("layout.scan.generationAdvanced readLayout=true")
                adoptPersistedLayout()
            }
            if case .auto(.iconColor) = layoutMode {
                ensureIconColors()
            }
            if catalogChanged || persistedLayoutChanged {
                reconcileLaunchpadItems()
                if hiddenAppIDs != hiddenBeforeReload {
                    invalidateAllAutoLayouts()
                } else if !affectedAutoLayouts.isEmpty {
                    invalidateAutoLayouts(affectedAutoLayouts)
                }
                // A scan also runs when the Launchpad is shown again. Keep the
                // current page while refreshing the catalog; the non-reset path
                // still clamps it if the refreshed catalog has fewer pages.
                refreshFilteredApps(resetPage: false)
            }
            isLoading = false
            scanTask = nil
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        }
    }

    /// Wait for the first catalog. A later rescan does not block presentation.
    func waitUntilLoaded() async {
        if !apps.isEmpty { return }
        if let scanTask {
            await scanTask.value
            return
        }
        if !isLoading { return }
        load()
        await scanTask?.value
    }

    func exportLayout(includeCatalog: Bool = true, includePaths: Bool = true) -> LaunchpadLayoutDocument {
        let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var seen = Set<String>()
        var items: [LaunchpadLayoutItem] = []
        for id in itemOrderIDs {
            guard seen.insert(id).inserted else { continue }
            if let folder = folderByID[id] {
                items.append(.folder(id: folder.id, name: folder.name, apps: folder.appIDs))
            } else {
                items.append(.app(id: id))
            }
        }
        for folder in folders where seen.insert(folder.id).inserted {
            items.append(.folder(id: folder.id, name: folder.name, apps: folder.appIDs))
        }
        let catalog: [LaunchpadLayoutCatalogEntry]? = includeCatalog
            ? apps.map { app in
                LaunchpadLayoutCatalogEntry(
                    id: app.id,
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.name,
                    path: includePaths ? app.url.standardizedFileURL.path : nil
                )
            }
            : nil
        let preset = GridLayoutPreset.current
        return LaunchpadLayoutDocument(
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            grid: LaunchpadLayoutGrid(
                preset: preset.rawValue,
                columns: preset.columns,
                rows: preset.rows,
                pageCapacity: preset.columns * preset.rows
            ),
            items: items,
            hidden: hiddenAppIDs.sorted(),
            catalog: catalog
        )
    }

    func applyLayout(
        _ document: LaunchpadLayoutDocument,
        mode: LaunchpadLayoutImportMode,
        writeBackup: Bool = true
    ) throws -> LaunchpadLayoutReport {
        guard !isLoading, !apps.isEmpty else {
            throw LaunchpadLayoutError.malformed("application catalog is empty")
        }
        let (applied, report) = try LaunchpadLayoutImporter.apply(
            document: document,
            mode: mode,
            strict: false,
            scanned: knownApps(),
            currentHidden: hiddenAppIDs
        )
        if writeBackup {
            writeLayoutBackupFailOpen()
        }
        let hiddenBeforeImport = hiddenAppIDs
        let foldersData = try LaunchpadPreferenceStore.encodeFolders(applied.folders)
        LaunchpadPreferenceStore.writeLayout(
            domain: Self.preferenceDomain,
            LaunchpadPersistedLayout(
                itemOrder: applied.order,
                foldersData: foldersData,
                hiddenIDs: Array(applied.hidden)
            )
        )
        folders = applied.folders
        itemOrderIDs = applied.order
        hiddenAppIDs = applied.hidden
        layoutMode = .user
        if hiddenAppIDs != hiddenBeforeImport {
            invalidateAllAutoLayouts()
        }
        persistLayoutMode()
        rebuildLaunchpadItems()
        cancelActiveDrag()
        layoutGeneration += 1
        if let openedFolderID, folder(withID: openedFolderID) == nil {
            exitFolder()
        }
        refreshFilteredApps(resetPage: false)
        layoutLogger.info(
            "layout.import imported=\(report.importedRootItems) folders=\(report.importedFolders) skipped=\(report.skippedUnknown.count)"
        )
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        return report
    }

    func selectLayoutProfile(_ id: String) throws {
        guard layoutProfiles.contains(where: { $0.id == id }) else {
            throw LaunchpadLayoutProfileError.profileNotFound(id)
        }
        if id == activeLayoutProfileID {
            if !layoutMode.isUser {
                setLayoutMode(.user)
            }
            return
        }
        try snapshotActiveLayoutProfile()
        let document = try LaunchpadLayoutProfileStore.readDocument(
            in: layoutProfilesDirectory,
            profileID: id
        )
        _ = try applyLayout(document, mode: .merge, writeBackup: false)
        activeLayoutProfileID = id
        try persistLayoutProfileIndex()
    }

    func selectLayoutSelector(_ id: String) throws {
        let parsed = LaunchpadLayoutSelectorID.parse(id)
        if let profileID = parsed.profileID {
            try selectLayoutProfile(profileID)
            return
        }
        if let kind = parsed.autoKind {
            setLayoutMode(.auto(kind))
            return
        }
        throw LaunchpadLayoutProfileError.invalidProfileID(id)
    }

    func setLayoutMode(_ mode: LaunchpadLayoutMode) {
        guard mode != layoutMode else { return }
        if !mode.isUser {
            leaveOpenedFolder()
        }
        layoutMode = mode
        persistLayoutMode()
        if case .auto(.iconColor) = mode {
            ensureIconColors()
        }
        if case .auto(let kind) = mode {
            scheduleAutoLayoutIfNeeded(kind)
        }
        cancelActiveDrag()
        layoutGeneration += 1
        refreshFilteredApps(resetPage: true)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func recordAppLaunch(_ app: AppInfo) {
        recentLaunchDates[app.id] = Date()
        // Keep the current order stable throughout dismissal. The refreshed
        // recent layout is materialized after the window has become hidden.
        invalidateAutoLayouts(
            [.recentlyUsed],
            keepStaleCache: true,
            scheduleCurrent: false
        )
        persistRecentLaunches()
    }

    func createLayoutProfile(named name: String) throws {
        guard let name = LaunchpadLayoutProfileStore.normalizedName(name) else {
            throw LaunchpadLayoutProfileError.emptyName
        }
        try snapshotActiveLayoutProfile()
        let profile = LaunchpadLayoutProfile(id: UUID().uuidString, name: name)
        try LaunchpadLayoutProfileStore.writeDocument(
            exportLayout(),
            in: layoutProfilesDirectory,
            profileID: profile.id
        )
        layoutProfiles.append(profile)
        activeLayoutProfileID = profile.id
        layoutMode = .user
        persistLayoutMode()
        try persistLayoutProfileIndex()
    }

    func deleteLayoutProfile(_ id: String) throws {
        guard LaunchpadLayoutProfileStore.canDelete(id) else {
            throw LaunchpadLayoutProfileError.defaultProfileProtected
        }
        guard layoutProfiles.contains(where: { $0.id == id }) else {
            throw LaunchpadLayoutProfileError.profileNotFound(id)
        }
        if activeLayoutProfileID == id {
            try selectLayoutProfile(LaunchpadLayoutProfileStore.defaultProfileID)
        }
        try LaunchpadLayoutProfileStore.removeDocument(
            in: layoutProfilesDirectory,
            profileID: id
        )
        layoutProfiles.removeAll { $0.id == id }
        try persistLayoutProfileIndex()
    }

    func reloadPersistedLayout() {
        layoutGeneration += 1
        let hiddenBeforeReload = hiddenAppIDs
        adoptPersistedLayout()
        if apps.isEmpty {
            rebuildLaunchpadItems()
        } else {
            reconcileLaunchpadItems(persist: false)
        }
        cancelActiveDrag()
        if let openedFolderID, folder(withID: openedFolderID) == nil {
            exitFolder()
        }
        if hiddenAppIDs != hiddenBeforeReload {
            invalidateAllAutoLayouts()
        }
        refreshFilteredApps(resetPage: false)
        layoutLogger.info("layout.reload from distributed notification")
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func updateSearch(_ text: String) {
        let willSearch = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Capture before `searchText` changes — `currentPage` is then clamped
        // to the result list, which starts at page 0.
        if !isSearching && willSearch {
            pageBeforeSearch = Double(currentPage)
        }
        searchText = text
        isKeyboardNavigationActive = false
        if !willSearch, pageBeforeSearch != nil {
            refreshFilteredApps(resetPage: false)
            restorePageAfterSearch()
        } else {
            refreshFilteredApps(resetPage: true)
        }
    }

    private func restorePageAfterSearch() {
        let saved = pageBeforeSearch
        pageBeforeSearch = nil
        pageVelocity = 0
        resetPageScrollGesture()
        let lastPage = Double(max(pageCount - 1, 0))
        let page = min(max(saved ?? 0, 0), lastPage)
        pageOffset = page
        targetPage = page
        ensureKeyboardFocus(onPage: currentPage)
    }

    func enterFolder(_ folderID: String) {
        guard layoutMode.isUser, folder(withID: folderID) != nil else { return }
        // Capture before `openedFolderID` changes — `currentPage` is clamped
        // to the folder's page count once the folder is open.
        if openedFolderID == nil {
            pageBeforeFolder = Double(currentPage)
        }
        openedFolderID = folderID
        pageBeforeSearch = nil
        searchText = ""
        refreshFilteredApps(resetPage: true)
        pageOffset = 0
        targetPage = 0
        pageVelocity = 0
        resetPageScrollGesture()
        keyboardFocusID = activeDisplayItems.compactMap { item in
            if case .app(let app) = item { return app }
            return nil
        }.first?.id
        isKeyboardNavigationActive = false
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func renameFolder(_ folderID: String, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = trimmedName.isEmpty ? "文件夹" : trimmedName
        guard folders[index].name != normalizedName else { return }

        folders[index].name = normalizedName
        persistFolders()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func exitFolder() {
        guard leaveOpenedFolder() != nil else { return }
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// Close the open folder and put the root grid back on the page it left.
    @discardableResult
    private func leaveOpenedFolder() -> String? {
        guard let folderID = openedFolderID else { return nil }
        openedFolderID = nil
        isDraggingFolderApp = false
        isFolderRemovalTargeted = false
        restoreRootPageAfterFolder()
        resetPageScrollGesture()
        ensureKeyboardFocus(onPage: currentPage)
        isKeyboardNavigationActive = false
        return folderID
    }

    private func restoreRootPageAfterFolder() {
        let saved = pageBeforeFolder
        pageBeforeFolder = nil
        pageVelocity = 0
        let lastPage = Double(max(pageCount - 1, 0))
        let page = min(max(saved ?? 0, 0), lastPage)
        pageOffset = page
        targetPage = page
    }

    func applyGridLayoutChange() {
        pageOffset = 0
        targetPage = 0
        pageVelocity = 0
        resetPageScrollGesture()
        keyboardFocusID = nil
        isKeyboardNavigationActive = false
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func hide(_ app: AppInfo) {
        guard hiddenAppIDs.insert(app.id).inserted else { return }
        invalidateAllAutoLayouts()
        persistHiddenApps()
        reconcileLaunchpadItems()
        refreshFilteredApps(resetPage: false)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func unhide(_ app: AppInfo) {
        guard hiddenAppIDs.remove(app.id) != nil else { return }
        invalidateAllAutoLayouts()
        persistHiddenApps()
        reconcileLaunchpadItems()
        refreshFilteredApps(resetPage: false)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func addApplicationSource(_ url: URL) {
        let path = url.standardizedFileURL.path
        let defaultPaths = Set(AppScanner.defaultRoots.map(\.standardizedFileURL.path))
        guard !defaultPaths.contains(path) else { return }
        guard !customApplicationSourcePaths.contains(path) else { return }
        customApplicationSourcePaths.append(path)
        persistApplicationSources()
        load()
    }

    func removeApplicationSource(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where customApplicationSourcePaths.indices.contains(index) {
            customApplicationSourcePaths.remove(at: index)
        }
        persistApplicationSources()
        load()
    }

    // MARK: Keyboard focus

    func focusApp(id: String) {
        guard activeDisplayItems.contains(where: { $0.id == id }) else { return }
        keyboardFocusID = id
        isKeyboardNavigationActive = false
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func focusFirstAppOnCurrentPage() {
        let items = activeDisplayItems
        guard !items.isEmpty else {
            keyboardFocusID = nil
            return
        }
        let start = min(currentPage * pageCapacity, items.count - 1)
        keyboardFocusID = items[start].id
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func moveKeyboardFocus(_ direction: GridNavigationDirection) {
        let items = activeDisplayItems
        guard !items.isEmpty else {
            keyboardFocusID = nil
            isKeyboardNavigationActive = false
            return
        }

        // A page gesture can finish visually before the page-settle callback
        // updates the focus item. Do not let an arrow key move that stale item
        // on the previous page; switch the focus to the page now on screen
        // first, and consume this key press.
        let displayedPage = currentPage
        let focusIsOnDisplayedPage = keyboardFocusID.flatMap { id in
            items.firstIndex { $0.id == id }
        }.map { $0 / pageCapacity == displayedPage } ?? false
        if isKeyboardNavigationActive && !focusIsOnDisplayedPage {
            let start = min(displayedPage * pageCapacity, items.count - 1)
            keyboardFocusID = items[start].id
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
            return
        }

        // The first arrow key reveals the current-page focus without moving it.
        // Until then the implicit candidate remains invisible.
        if !isKeyboardNavigationActive {
            isKeyboardNavigationActive = true
            let start = min(currentPage * pageCapacity, items.count - 1)
            keyboardFocusID = items[start].id
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
            return
        }

        // Always navigate from the page currently shown on screen. A page can
        // be changed by a trackpad/mouse gesture while the old keyboard focus
        // is still settling; using the focus item's page here would make the
        // next arrow key operate on the page that is no longer visible.
        let page = currentPage
        let pageStart = page * pageCapacity
        let fallback = min(pageStart, items.count - 1)
        let current = keyboardFocusID.flatMap { id in
            items.firstIndex { $0.id == id }
        }.flatMap { index in
            index / pageCapacity == page ? index : nil
        } ?? fallback
        let pageEnd = min(pageStart + pageCapacity, items.count)
        let local = current - pageStart
        let row = local / GridMetrics.columns
        let column = local % GridMetrics.columns
        var destination = current

        switch direction {
        case .left:
            if column > 0 {
                destination = current - 1
            } else if page > 0 {
                let previousStart = (page - 1) * pageCapacity
                let previousEnd = min(previousStart + pageCapacity, items.count)
                destination = min(previousStart + row * GridMetrics.columns + GridMetrics.columns - 1,
                                  previousEnd - 1)
            }
        case .right:
            if column + 1 < GridMetrics.columns, current + 1 < pageEnd {
                destination = current + 1
            } else if page + 1 < pageCount {
                let nextStart = (page + 1) * pageCapacity
                destination = min(nextStart + row * GridMetrics.columns, items.count - 1)
            }
        case .up:
            if row > 0 {
                destination = current - GridMetrics.columns
            }
        case .down:
            if current + GridMetrics.columns < pageEnd {
                destination = current + GridMetrics.columns
            }
        }

        keyboardFocusID = items[destination].id
        let destinationPage = destination / pageCapacity
        if destinationPage != currentPage {
            goToPage(destinationPage)
        } else {
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        }
    }

    // MARK: Paging

    /// Discrete page step (keyboard / indicator).
    /// Logical offset updates immediately; Metal springs the visual position.
    func goToPage(_ page: Int, animated: Bool = true) {
        let clamped = min(max(page, 0), pageCount - 1)
        targetPage = Double(clamped)
        pageVelocity = 0
        resetPageScrollGesture()
        pageOffset = targetPage
        ensureKeyboardFocus(onPage: clamped)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// Pick a page from a click or scrub in view coordinates.
    @discardableResult
    func selectPage(
        at point: NSPoint,
        in bounds: NSRect,
        scrubbing: Bool = false,
        flipped: Bool = false
    ) -> Bool {
        guard LaunchpadPageIndicatorHitArea.isEnabled(
            pageCount: pageCount,
            isSearching: isSearching
        ) else { return false }
        guard let page = LaunchpadPageIndicatorHitArea.pageIndex(
            at: point,
            in: bounds,
            pageCount: pageCount,
            currentPage: currentPage,
            requireHitPad: !scrubbing,
            flipped: flipped
        ) else { return false }
        if page == currentPage { return true }
        goToPage(page)
        return true
    }

    func movePage(byPages delta: Int) {
        goToPage(currentPage + delta)
    }

    // MARK: Mouse drag pan (empty area)

    /// Begin a click-drag page pan on empty background.
    func beginPagePan() {
        isKeyboardNavigationActive = false
        ignoreScrollMomentum = false
        isPageGestureActive = true
        pageVelocity = 0
        lastScrollTime = CACurrentMediaTime()
        scrollAccumulated = 0
        scrollAxis = .undecided
        scrollAxisAccumX = 0
        scrollAxisAccumY = 0
        pagePanOrigin = pageOffset
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// Map a 1:1 pointer translation onto the page (same rubber-band as scroll).
    /// `translationPages` is `(startX - currentX) / width`; positive → next page.
    func updatePagePan(translationPages: Double) {
        let now = CACurrentMediaTime()
        let dt = now - lastScrollTime
        let proposed = pagePanOrigin + translationPages
        let previousPage = currentPage
        let newOffset = clampedPageOffset(proposed)
        let moved = newOffset - pageOffset
        pageOffset = newOffset
        isPageGestureActive = true
        scrollAccumulated = translationPages

        // Skip velocity on duplicate same-frame samples (mouse event + display link).
        if dt >= 1.0 / 240.0 {
            lastScrollTime = now
            let clampedDt = min(dt, 1.0 / 20.0)
            let instant = moved / clampedDt
            pageVelocity = pageVelocity * 0.25 + instant * 0.75
        }

        if currentPage != previousPage {
            objectWillChange.send()
        }
    }

    /// End pan and snap to a page (velocity-biased, mouse-drag thresholds).
    func endPagePan() {
        isPageGestureActive = false
        settleMousePagePan(withVelocity: pageVelocity)
    }

    /// Continuous trackpad / mouse-wheel paging with phase awareness.
    func handleScroll(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        isPrecise: Bool
    ) {
        isKeyboardNavigationActive = false

        let began = phase.contains(.began)
        let ended = phase.contains(.ended) || phase.contains(.cancelled)
        let inMomentum = momentumPhase.contains(.began) || momentumPhase.contains(.changed)
        let momentumEnded = momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled)

        // Mouse wheel: one notch → one page. Trackpad never takes this path.
        if !isPrecise && phase.isEmpty && momentumPhase.isEmpty {
            let primary = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
            guard abs(primary) > 0.01 else { return }
            let pageDelta = Double(-primary) / (pageScrollUnit * 0.35)
            resetPageScrollGesture()
            settlePage(withVelocity: pageDelta > 0 ? 1.2 : -1.2)
            return
        }

        if began {
            ignoreScrollMomentum = false
            isPageGestureActive = true
            scrollAccumulated = 0
            pageVelocity = 0
            scrollAxis = .undecided
            scrollAxisAccumX = 0
            scrollAxisAccumY = 0
            lastScrollTime = CACurrentMediaTime()
        }

        // Finger-up already snapped. AppKit still sends a decaying momentum
        // stream — applying it starts another flip from between two pages.
        if ignoreScrollMomentum && !began {
            return
        }

        // Lock axis once, then ignore the other axis for the rest of the gesture.
        // Per-event "whichever is larger" lets vertical noise reverse paging.
        let axisBefore = scrollAxis
        scrollAxisAccumX += Double(deltaX)
        scrollAxisAccumY += Double(deltaY)
        if scrollAxis == .undecided {
            let absX = abs(scrollAxisAccumX)
            let absY = abs(scrollAxisAccumY)
            if absX >= scrollAxisLockPoints || absY >= scrollAxisLockPoints {
                if absX >= absY * 1.2 {
                    scrollAxis = .horizontal
                } else if absY >= absX * 1.2 {
                    scrollAxis = .vertical
                }
            }
        }

        let justLocked = axisBefore == .undecided && scrollAxis != .undecided
        let trackedDelta: Double
        switch scrollAxis {
        case .undecided:
            trackedDelta = 0
        case .horizontal:
            trackedDelta = justLocked ? scrollAxisAccumX : Double(deltaX)
        case .vertical:
            trackedDelta = justLocked ? scrollAxisAccumY : Double(deltaY)
        }

        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, min(now - lastScrollTime, 1.0 / 20.0))
        if began && abs(trackedDelta) <= 0.01 {
            lastScrollTime = now
        }

        if isPageGestureActive, abs(trackedDelta) > 0.01 {
            lastScrollTime = now
            let pageDelta = -trackedDelta / pageScrollUnit
            applyLivePageDelta(pageDelta)
            let instant = pageDelta / dt
            pageVelocity = pageVelocity * 0.55 + instant * 0.45
            if targetPage != pageOffset {
                targetPage = pageOffset
            }
        }

        // Snap as soon as the finger lifts. Waiting for momentum parks the
        // grid between pages, then the inertia burst flips through them.
        if ended && !inMomentum {
            ignoreScrollMomentum = true
            settlePage(withVelocity: pageVelocity)
            return
        }

        if momentumEnded {
            ignoreScrollMomentum = true
            settlePage(withVelocity: pageVelocity)
        }
    }

    private func applyLivePageDelta(_ pageDelta: Double) {
        pageOffset = clampedPageOffset(pageOffset + pageDelta)
        scrollAccumulated += pageDelta
    }

    private func resetPageScrollGesture() {
        isPageGestureActive = false
        scrollAccumulated = 0
        scrollAxis = .undecided
        scrollAxisAccumX = 0
        scrollAxisAccumY = 0
    }

    /// Snap to nearest page, biased by flick velocity (Launchpad-style).
    /// Logical `pageOffset` jumps to the target; the Metal layer springs visually.
    func settlePage(withVelocity velocity: Double = 0) {
        let minPage = 0.0
        let maxPage = Double(max(pageCount - 1, 0))
        var page = pageOffset

        // Flick threshold ≈ 0.85 pages/sec.
        if velocity > LaunchpadPageSnap.trackpadFlickThreshold {
            page = floor(pageOffset + 0.08) + 1
        } else if velocity < -LaunchpadPageSnap.trackpadFlickThreshold {
            page = ceil(pageOffset - 0.08) - 1
        } else {
            page = pageOffset.rounded()
        }

        applySettledPage(min(max(page, minPage), maxPage))
    }

    /// Mouse empty-area pan: lower commit / flick thresholds than trackpad.
    private func settleMousePagePan(withVelocity velocity: Double) {
        applySettledPage(
            LaunchpadPageSnap.settledPage(
                offset: pageOffset,
                origin: pagePanOrigin,
                velocity: velocity,
                pageCount: pageCount,
                flickThreshold: LaunchpadPageSnap.mouseFlickThreshold,
                commitThreshold: LaunchpadPageSnap.mouseCommitThreshold
            )
        )
    }

    private func applySettledPage(_ page: Double) {
        targetPage = page
        pageOffset = page
        pageVelocity = 0
        resetPageScrollGesture()
        ensureKeyboardFocus(onPage: Int(targetPage))
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// Legacy helper used by metal settle timer fallback.
    func settlePage() {
        settlePage(withVelocity: pageVelocity)
    }

    func movePage(by delta: Double) {
        let minPage = 0.0
        let maxPage = Double(max(pageCount - 1, 0))
        pageOffset = min(max(pageOffset + delta, minPage - 0.15), maxPage + 0.15)
        targetPage = pageOffset
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    private func rubberBand(_ overflow: Double) -> Double {
        // Classic rubber-band: diminishing return past the edge.
        let c = 0.55
        return (1 - 1 / (overflow * c + 1)) * 0.35
    }

    private func clampedPageOffset(_ proposed: Double) -> Double {
        let minPage = 0.0
        let maxPage = Double(max(pageCount - 1, 0))
        if proposed < minPage {
            return minPage - rubberBand(minPage - proposed)
        }
        if proposed > maxPage {
            return maxPage + rubberBand(proposed - maxPage)
        }
        return proposed
    }

    private func ensureKeyboardFocus(onPage page: Int) {
        let items = activeDisplayItems
        guard !items.isEmpty else {
            keyboardFocusID = nil
            return
        }
        if let id = keyboardFocusID,
           let index = items.firstIndex(where: { $0.id == id }),
           index / pageCapacity == page {
            return
        }
        let start = min(page * pageCapacity, items.count - 1)
        keyboardFocusID = items[start].id
    }

    // MARK: Reorder

    func moveItem(from source: Int, to destination: Int) {
        guard allowsUserLayoutEditing,
              launchpadItems.indices.contains(source),
              launchpadItems.indices.contains(destination),
              source != destination else {
            return
        }

        var ids = launchpadItems.map(\.id)
        let item = ids.remove(at: source)
        ids.insert(item, at: min(destination, ids.endIndex))
        itemOrderIDs = ids
        persistItemOrder()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func moveAppInsideFolder(folderID: String, from source: Int, to destination: Int) {
        guard allowsUserLayoutEditing,
              let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
              folders[folderIndex].appIDs.indices.contains(source),
              folders[folderIndex].appIDs.indices.contains(destination),
              source != destination else { return }

        let appID = folders[folderIndex].appIDs.remove(at: source)
        folders[folderIndex].appIDs.insert(appID, at: destination)
        persistFolders()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// Merge the source folder into the target. The target remains the owning
    /// folder and keeps its root-grid position and name.
    @discardableResult
    func mergeFolder(sourceID: String, into targetID: String) -> Bool {
        guard allowsUserLayoutEditing,
              sourceID != targetID,
              let source = folders.first(where: { $0.id == sourceID }),
              let targetIndex = folders.firstIndex(where: { $0.id == targetID }) else {
            return false
        }

        var existing = Set(folders[targetIndex].appIDs)
        folders[targetIndex].appIDs.append(contentsOf: source.appIDs.filter { existing.insert($0).inserted })
        folders.removeAll { $0.id == sourceID }
        itemOrderIDs.removeAll { $0 == sourceID }
        if openedFolderID == sourceID { leaveOpenedFolder() }
        persistFolders()
        persistItemOrder()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        return true
    }

    /// Replace a folder at its current root position with its member apps.
    @discardableResult
    func dissolveFolder(_ folderID: String) -> [String]? {
        guard allowsUserLayoutEditing,
              let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        let members = folders[folderIndex].appIDs
        let rootIndex = itemOrderIDs.firstIndex(of: folderID)
            ?? launchpadItems.firstIndex(where: { $0.id == folderID })
            ?? itemOrderIDs.endIndex
        folders.remove(at: folderIndex)
        itemOrderIDs.removeAll { $0 == folderID || members.contains($0) }
        itemOrderIDs.insert(contentsOf: members, at: min(rootIndex, itemOrderIDs.endIndex))
        if openedFolderID == folderID { leaveOpenedFolder() }
        persistFolders()
        persistItemOrder()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        return members
    }

    /// Move an app from its current location into a folder. This supports both
    /// root apps and apps currently residing in another folder.
    @discardableResult
    func moveAppToFolder(appID: String, folderID: String) -> Bool {
        guard allowsUserLayoutEditing,
              let targetIndex = folders.firstIndex(where: { $0.id == folderID }),
              !folders[targetIndex].appIDs.contains(appID),
              app(withID: appID) != nil else { return false }

        if let sourceIndex = folders.firstIndex(where: { $0.appIDs.contains(appID) }) {
            folders[sourceIndex].appIDs.removeAll { $0 == appID }
        } else {
            itemOrderIDs.removeAll { $0 == appID }
        }

        // Removing an empty source folder may shift the target's array index, so
        // resolve it again before appending.
        let emptyFolderIDs = Set(folders.filter(\.appIDs.isEmpty).map(\.id))
        folders.removeAll { emptyFolderIDs.contains($0.id) }
        itemOrderIDs.removeAll { emptyFolderIDs.contains($0) }
        guard let refreshedTarget = folders.firstIndex(where: { $0.id == folderID }) else {
            return false
        }
        folders[refreshedTarget].appIDs.append(appID)
        if let openedFolderID, emptyFolderIDs.contains(openedFolderID) {
            leaveOpenedFolder()
        }
        persistFolders()
        persistItemOrder()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        return true
    }

    /// Remove an app to the root, immediately after its former folder.
    @discardableResult
    func removeAppFromFolder(appID: String, folderID: String) -> Bool {
        guard allowsUserLayoutEditing,
              let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
              folders[folderIndex].appIDs.contains(appID) else { return false }

        let rootFolderIndex = itemOrderIDs.firstIndex(of: folderID)
            ?? launchpadItems.firstIndex(where: { $0.id == folderID })
            ?? itemOrderIDs.endIndex
        folders[folderIndex].appIDs.removeAll { $0 == appID }
        itemOrderIDs.removeAll { $0 == appID }

        if folders[folderIndex].appIDs.isEmpty {
            folders.remove(at: folderIndex)
            itemOrderIDs.removeAll { $0 == folderID }
            itemOrderIDs.insert(appID, at: min(rootFolderIndex, itemOrderIDs.endIndex))
            if openedFolderID == folderID { leaveOpenedFolder() }
        } else {
            let currentFolderOrder = itemOrderIDs.firstIndex(of: folderID)
                ?? min(rootFolderIndex, itemOrderIDs.endIndex)
            itemOrderIDs.insert(appID, at: min(currentFolderOrder + 1, itemOrderIDs.endIndex))
        }

        persistFolders()
        persistItemOrder()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        return true
    }

    /// Combine two top-level app items into one folder. The target app stays
    /// first, matching the usual Launchpad/iOS folder creation behavior.
    @discardableResult
    func createFolder(draggedAppID: String, targetAppID: String) -> AppFolder? {
        guard allowsUserLayoutEditing,
              draggedAppID != targetAppID,
              launchpadItems.contains(where: { $0.id == draggedAppID && isApp($0) }),
              launchpadItems.contains(where: { $0.id == targetAppID && isApp($0) }) else {
            return nil
        }

        let folder = AppFolder(appIDs: [targetAppID, draggedAppID])
        folders.append(folder)
        let targetIndex = itemOrderIDs.firstIndex(of: targetAppID)
            ?? launchpadItems.firstIndex(where: { $0.id == targetAppID })
            ?? itemOrderIDs.endIndex
        let draggedIndex = itemOrderIDs.firstIndex(of: draggedAppID)
        let insertionIndex = targetIndex - ((draggedIndex ?? targetIndex) < targetIndex ? 1 : 0)
        itemOrderIDs.removeAll { $0 == draggedAppID || $0 == targetAppID }
        itemOrderIDs.insert(folder.id, at: min(max(insertionIndex, 0), itemOrderIDs.endIndex))
        persistFolders()
        persistItemOrder()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        return folder
    }

    /// Move a top-level app into an existing folder. Nested folders are not
    /// created; dragging a folder remains a top-level reorder operation.
    func moveAppIntoFolder(appID: String, folderID: String) {
        guard !isSearching,
              launchpadItems.contains(where: { $0.id == appID && isApp($0) }) else { return }
        _ = moveAppToFolder(appID: appID, folderID: folderID)
    }

    func moveApp(from source: Int, to destination: Int) {
        guard !isSearching,
              filteredApps.indices.contains(source), filteredApps.indices.contains(destination),
              source != destination,
              let sourceIndex = apps.firstIndex(of: filteredApps[source]),
              let destinationIndex = apps.firstIndex(of: filteredApps[destination]) else {
            return
        }
        let item = apps.remove(at: sourceIndex)
        apps.insert(item, at: min(destinationIndex, apps.endIndex))
        refreshFilteredApps(resetPage: false)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    // MARK: Presentation

    func beginPresenting() {
        presentation = .presenting
        presentationProgress = 0
        isKeyboardNavigationActive = false
        focusFirstAppOnCurrentPage()
    }

    func markVisible() {
        presentation = .visible
        presentationProgress = 1
    }

    func beginDismissing() {
        presentation = .dismissing
    }

    func markHidden() {
        presentation = .hidden
        presentationProgress = 0
        isKeyboardNavigationActive = false
        leaveOpenedFolder()
        isDraggingFolderApp = false
        isFolderRemovalTargeted = false
        // Clear search when closed so next open shows full grid.
        if !searchText.isEmpty {
            updateSearch("")
        }
        // Work deliberately deferred by an app launch starts only after the
        // dismissal animation has completed.
        for kind in deferredAutoLayoutKinds {
            scheduleAutoLayoutIfNeeded(kind)
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private func refreshFilteredApps(resetPage: Bool) {
        let query = normalized(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        // Pinyin input may contain spaces, apostrophes, hyphens, or other
        // syllable separators. Search the compact form against metadata that
        // is stored without separators.
        let compactQuery = query.filter { $0.isLetter || $0.isNumber }
        filteredApps = apps.filter { app in
            let isHidden = hiddenAppIDs.contains(app.id)
            if isHidden && (query.isEmpty || !showHiddenAppsInSearch) {
                return false
            }
            return query.isEmpty
                || normalized(app.name).contains(query)
                || normalized(app.bundleIdentifier).contains(query)
                || app.pinyin.matches(compactQuery)
        }

        if resetPage {
            pageOffset = 0
            targetPage = 0
            pageVelocity = 0
        } else {
            let lastPage = Double(max(pageCount - 1, 0))
            pageOffset = min(pageOffset, lastPage)
            targetPage = min(targetPage, lastPage)
        }
        keyboardFocusID = activeDisplayItems.first?.id
    }

    private func persistHiddenApps() {
        persistLayout()
    }

    private func persistApplicationSources() {
        UserDefaults.standard.set(customApplicationSourcePaths, forKey: LaunchpadPersistence.customSourcesKey)
    }

    private func isApp(_ item: LaunchpadItem) -> Bool {
        if case .app = item { return true }
        return false
    }

    private func knownApps() -> [LaunchpadKnownApp] {
        apps.map {
            LaunchpadKnownApp(
                id: $0.id,
                bundleIdentifier: $0.bundleIdentifier,
                name: $0.name,
                path: $0.url.standardizedFileURL.path
            )
        }
    }

    private func adoptPersistedLayout() {
        let layout = LaunchpadPreferenceStore.readLayout(domain: Self.preferenceDomain)
        LaunchpadPreferenceStore.writeThroughToStandardDefaults(layout)
        itemOrderIDs = layout.itemOrder
        hiddenAppIDs = Set(layout.hiddenIDs)
        folders = (try? LaunchpadPreferenceStore.decodeFolders(layout.foldersData)) ?? []
    }

    private func writeLayoutBackupFailOpen() {
        do {
            try LaunchpadPreferenceStore.writeLayoutBackup(
                domain: Self.preferenceDomain,
                document: exportLayout(includeCatalog: true, includePaths: true)
            )
        } catch {
            layoutLogger.warning("layout.backup.failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelActiveDrag() {
        isDraggingFolderApp = false
        isFolderRemovalTargeted = false
        dragGeneration += 1
    }

    private func reconcileLaunchpadItems(persist: Bool = true) {
        let result = LaunchpadLayoutReconciler.reconcile(
            apps: knownApps(),
            folders: folders,
            order: itemOrderIDs,
            hidden: hiddenAppIDs
        )
        folders = result.folders
        itemOrderIDs = result.order
        if persist {
            persistLayout()
        }
        rebuildLaunchpadItems()
    }

    private func rebuildLaunchpadItems() {
        let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        launchpadItems = itemOrderIDs.compactMap { id in
            if let folder = folderByID[id] { return .folder(folder) }
            guard let app = apps.first(where: { $0.id == id }) else { return nil }
            return .app(app)
        }
    }

    private func persistLayout() {
        // An empty catalog is the first-scan window, not a real layout. Persisting
        // a reconcile of `apps = []` would write an empty grid over a live import.
        guard !apps.isEmpty else { return }
        guard let foldersData = try? LaunchpadPreferenceStore.encodeFolders(folders) else { return }
        LaunchpadPreferenceStore.writeLayout(
            domain: Self.preferenceDomain,
            LaunchpadPersistedLayout(
                itemOrder: itemOrderIDs,
                foldersData: foldersData,
                hiddenIDs: hiddenAppIDs.sorted()
            )
        )
    }

    private func persistFolders() {
        persistLayout()
    }

    private func persistItemOrder() {
        persistLayout()
    }

    /// Materialize one automatic layout away from the main actor. The generation
    /// check makes cancellation race-safe when catalog metadata changes while a
    /// localized comparison sort is still running.
    private func scheduleAutoLayoutIfNeeded(_ kind: LaunchpadAutoLayoutKind) {
        guard autoLayoutItemsByKind[kind] == nil || deferredAutoLayoutKinds.contains(kind),
              autoLayoutTasks[kind] == nil,
              !apps.isEmpty else { return }
        if kind == .iconColor,
           apps.contains(where: { !hiddenAppIDs.contains($0.id) && iconColorByAppID[$0.id] == nil }) {
            ensureIconColors()
            return
        }

        let generation = autoLayoutGeneration[kind, default: 0]
        let catalog = apps
        let hidden = hiddenAppIDs
        let launchDates = recentLaunchDates
        let colors = iconColorByAppID
        autoLayoutTasks[kind] = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> [String]? in
                guard !Task.isCancelled else { return nil }
                let visible = catalog.filter { !hidden.contains($0.id) }
                guard !Task.isCancelled else { return nil }
                let sortable = visible.map { app in
                    let lastUsedAt: Date?
                    switch (launchDates[app.id], app.lastUsedAt) {
                    case let (recorded?, spotlight?): lastUsedAt = max(recorded, spotlight)
                    case let (recorded?, nil): lastUsedAt = recorded
                    case let (nil, spotlight?): lastUsedAt = spotlight
                    case (nil, nil): lastUsedAt = nil
                    }
                    return LaunchpadAutoLayoutApp(
                        id: app.id,
                        name: app.name,
                        path: app.url.path,
                        lastUsedAt: lastUsedAt,
                        installedAt: app.installedAt,
                        color: colors[app.id]
                    )
                }
                guard !Task.isCancelled else { return nil }
                let ids = LaunchpadAutoLayoutSorter.sortedIDs(
                    sortable,
                    kind: kind,
                    cancellationCheck: { Task.isCancelled }
                )
                return Task.isCancelled ? nil : ids
            }
            let sortedIDs = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard let self, !Task.isCancelled, let sortedIDs else { return }
            guard self.autoLayoutGeneration[kind, default: 0] == generation else { return }
            self.autoLayoutTasks[kind] = nil
            self.deferredAutoLayoutKinds.remove(kind)
            let currentByID = Dictionary(uniqueKeysWithValues: self.apps.map { ($0.id, $0) })
            self.autoLayoutItemsByKind[kind] = sortedIDs.compactMap { id in
                currentByID[id].map(LaunchpadItem.app)
            }
            if self.layoutMode == .auto(kind), self.isPresented {
                // The cache itself is intentionally not @Published: send one
                // invalidation only when the complete replacement is ready.
                self.objectWillChange.send()
            }
        }
    }

    private func invalidateAutoLayouts(
        _ kinds: Set<LaunchpadAutoLayoutKind>,
        keepStaleCache: Bool = false,
        scheduleCurrent: Bool = true
    ) {
        for kind in kinds {
            autoLayoutGeneration[kind, default: 0] &+= 1
            autoLayoutTasks.removeValue(forKey: kind)?.cancel()
            if keepStaleCache {
                deferredAutoLayoutKinds.insert(kind)
            } else {
                autoLayoutItemsByKind.removeValue(forKey: kind)
                deferredAutoLayoutKinds.remove(kind)
            }
        }
        if scheduleCurrent,
           case .auto(let currentKind) = layoutMode,
           kinds.contains(currentKind) {
            scheduleAutoLayoutIfNeeded(currentKind)
        }
    }

    /// Determine which ordering keys changed. Metadata that only affects search
    /// still refreshes cached AppInfo payloads but performs no automatic sort.
    private func autoLayoutsAffectedByCatalogChange(
        from previous: [AppInfo],
        to current: [AppInfo]
    ) -> Set<LaunchpadAutoLayoutKind> {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        guard Set(previousByID.keys) == Set(currentByID.keys) else {
            return Set(LaunchpadAutoLayoutKind.allCases)
        }

        var affected: Set<LaunchpadAutoLayoutKind> = []
        for (id, app) in currentByID {
            guard let old = previousByID[id] else {
                return Set(LaunchpadAutoLayoutKind.allCases)
            }
            // Every mode falls back to name/path for deterministic ties.
            if old.name != app.name || old.url.path != app.url.path {
                return Set(LaunchpadAutoLayoutKind.allCases)
            }
            if old.lastUsedAt != app.lastUsedAt {
                affected.insert(.recentlyUsed)
            }
            if old.installedAt != app.installedAt {
                affected.formUnion([.installDateAscending, .installDateDescending])
            }
        }
        return affected
    }

    /// Preserve every cached order while replacing its AppInfo payload with the
    /// newest scan result. This is O(n) and performs no comparisons or sorting.
    private func rebindAutoLayoutItemsToCurrentCatalog() {
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var reboundByKind: [LaunchpadAutoLayoutKind: [LaunchpadItem]] = [:]
        reboundByKind.reserveCapacity(autoLayoutItemsByKind.count)
        for (kind, items) in autoLayoutItemsByKind {
            let rebound = items.compactMap { item -> LaunchpadItem? in
                guard let app = byID[item.id] else { return nil }
                return .app(app)
            }
            reboundByKind[kind] = rebound
        }
        autoLayoutItemsByKind = reboundByKind
    }

    private func rebuildAutoLayoutFallbackItems() {
        autoLayoutFallbackItems = apps
            .filter { !hiddenAppIDs.contains($0.id) }
            .map(LaunchpadItem.app)
    }

    private func invalidateAllAutoLayouts() {
        // Materialize the unsorted placeholder once as part of the mutation;
        // getters remain allocation-free while the detached sort is pending.
        rebuildAutoLayoutFallbackItems()
        invalidateAutoLayouts(Set(LaunchpadAutoLayoutKind.allCases))
    }

    private func persistLayoutMode() {
        UserDefaults.standard.set(layoutMode.storageValue, forKey: LaunchpadPersistence.layoutModeKey)
    }

    private func persistRecentLaunches() {
        let payload = recentLaunchDates.mapValues(\.timeIntervalSince1970)
        UserDefaults.standard.set(payload, forKey: LaunchpadPersistence.recentLaunchDatesKey)
    }

    private func ensureIconColors() {
        guard iconColorTask == nil else { return }
        let missing = apps.filter { !hiddenAppIDs.contains($0.id) && iconColorByAppID[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let snapshot = missing.map { (id: $0.id, url: $0.url) }
        iconColorTask = Task { [weak self] in
            let samples = await Task.detached(priority: .userInitiated) {
                snapshot.map { item in
                    (item.id, IconColorAnalyzer.sample(url: item.url))
                }
            }.value
            guard let self else { return }
            self.iconColorTask = nil
            for (id, color) in samples {
                self.iconColorByAppID[id] = color
            }
            self.invalidateAutoLayouts([.iconColor])
        }
    }

    private var layoutProfilesDirectory: URL {
        LaunchpadLayoutProfileStore.layoutsDirectory(domain: Self.preferenceDomain)
    }

    private func snapshotActiveLayoutProfile() throws {
        try LaunchpadLayoutProfileStore.writeDocument(
            exportLayout(),
            in: layoutProfilesDirectory,
            profileID: activeLayoutProfileID
        )
    }

    private func persistLayoutProfileIndex() throws {
        try LaunchpadLayoutProfileStore.saveIndex(
            LaunchpadLayoutProfileIndex(
                activeID: activeLayoutProfileID,
                profiles: layoutProfiles
            ),
            in: layoutProfilesDirectory
        )
    }

}
