import AppKit
import Combine
import Foundation
import os
import QLaunchpadCore

private let layoutLogger = Logger(subsystem: "com.qzrzz.qlaunchpad", category: "layout")

enum QLaunchpadPreferences {
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let showDockIconKey = "showDockIcon"

    // Preserve the existing status-bar entry for users upgrading from the
    // original build, while keeping the Dock hidden unless explicitly enabled.
    static let defaultShowMenuBarIcon = true
    static let defaultShowDockIcon = false
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

struct AppInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let bundleIdentifier: String
    /// Search metadata generated once while the application catalog is built.
    /// `pinyinFull` is compact full pinyin (e.g. `zhongguo`); initials are
    /// stored separately (e.g. `zg`) so both search styles remain fast.
    let pinyinFull: String
    let pinyinInitials: String

    init(
        id: String,
        name: String,
        url: URL,
        bundleIdentifier: String,
        pinyinFull: String? = nil,
        pinyinInitials: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        let metadata = pinyinFull == nil || pinyinInitials == nil
            ? PinyinSearchMetadata.make(for: name)
            : nil
        self.pinyinFull = pinyinFull ?? metadata?.full ?? ""
        self.pinyinInitials = pinyinInitials ?? metadata?.initials ?? ""
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

enum PinyinSearchMetadata {
    struct Result {
        let full: String
        let initials: String
    }

    static func make(for value: String) -> Result {
        let hasCJK = value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
        guard hasCJK else { return Result(full: "", initials: "") }

        let latin = NSMutableString(string: value)
        CFStringTransform(latin, nil, kCFStringTransformToLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripCombiningMarks, false)

        let syllables = latin
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }

        return Result(
            full: syllables.joined(),
            initials: syllables.compactMap(\.first).map(String.init).joined()
        )
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
    static func scan(additionalRoots: [URL] = []) -> [AppInfo] {
        struct Candidate {
            let url: URL
            let bundleIdentifier: String
            let displayName: String
            let fileName: String
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications")
        ] + additionalRoots

        var candidates: [Candidate] = []
        var seenPaths = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]

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

            return AppInfo(
                id: id,
                name: useFileName ? candidate.fileName : candidate.displayName,
                url: candidate.url,
                bundleIdentifier: candidate.bundleIdentifier
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
    /// 2× 8-bit linear; full catalog resident for smooth paging.
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

    /// Quality keeps a float16 drawable. Performance and low memory present 8-bit.
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
    @Published var showHiddenAppsInSearch: Bool {
        didSet {
            UserDefaults.standard.set(showHiddenAppsInSearch, forKey: LaunchpadPersistence.showHiddenAppsKey)
            refreshFilteredApps(resetPage: true)
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        }
    }

    /// Continuous page position (0 = first page). Driven by scroll + spring settle.
    @Published var pageOffset: Double = 0

    /// Target page used for snapping after a gesture ends.
    @Published private(set) var targetPage: Double = 0

    /// 0…1 presentation progress for window fade / content scale-in.
    @Published var presentationProgress: CGFloat = 0

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
    private var scanTask: Task<Void, Never>?
    private var layoutGeneration: UInt64 = 0
    /// Bumped by import / external reload so Metal can drop an in-flight drag.
    private(set) var dragGeneration: UInt64 = 0

    /// Points of scroll delta that equal one full page turn.
    private let pageScrollUnit: Double = 320

    private var itemOrderIDs: [String]

    private static var preferenceDomain: String {
        Bundle.main.bundleIdentifier ?? (kCFPreferencesCurrentApplication as String)
    }

    init() {
        let layout = LaunchpadPreferenceStore.readLayout(domain: Self.preferenceDomain)
        LaunchpadPreferenceStore.writeThroughToStandardDefaults(layout)
        hiddenAppIDs = Set(layout.hiddenIDs)
        itemOrderIDs = layout.itemOrder
        folders = (try? LaunchpadPreferenceStore.decodeFolders(layout.foldersData)) ?? []

        let defaults = UserDefaults.standard
        customApplicationSourcePaths = defaults.stringArray(forKey: LaunchpadPersistence.customSourcesKey) ?? []
        showHiddenAppsInSearch = defaults.bool(forKey: LaunchpadPersistence.showHiddenAppsKey)
        rebuildLaunchpadItems()
    }

    deinit {
        scanTask?.cancel()
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

    /// Top-level items shown by Launchpad. Search intentionally remains a flat
    /// app list so a result can always be launched without opening a folder.
    var displayItems: [LaunchpadItem] {
        if isSearching {
            return filteredApps.map(LaunchpadItem.app)
        }
        return launchpadItems
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
            apps = result
            if layoutGeneration != generationAtStart {
                layoutLogger.debug("layout.scan.generationAdvanced readLayout=true")
                adoptPersistedLayout()
            }
            reconcileLaunchpadItems()
            // A scan also runs when the Launchpad is shown again. Keep the
            // current page while refreshing the catalog; the non-reset path
            // still clamps it if the refreshed catalog has fewer pages.
            refreshFilteredApps(resetPage: false)
            isLoading = false
            scanTask = nil
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        }
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
        mode: LaunchpadLayoutImportMode
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
        writeLayoutBackupFailOpen()
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

    func reloadPersistedLayout() {
        layoutGeneration += 1
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
        refreshFilteredApps(resetPage: false)
        layoutLogger.info("layout.reload from distributed notification")
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func updateSearch(_ text: String) {
        searchText = text
        isKeyboardNavigationActive = false
        refreshFilteredApps(resetPage: true)
    }

    func enterFolder(_ folderID: String) {
        guard folder(withID: folderID) != nil else { return }
        openedFolderID = folderID
        searchText = ""
        refreshFilteredApps(resetPage: true)
        pageOffset = 0
        targetPage = 0
        pageVelocity = 0
        scrollAccumulated = 0
        isPageGestureActive = false
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
        guard openedFolderID != nil else { return }
        openedFolderID = nil
        isDraggingFolderApp = false
        isFolderRemovalTargeted = false
        pageOffset = 0
        targetPage = 0
        pageVelocity = 0
        scrollAccumulated = 0
        isPageGestureActive = false
        keyboardFocusID = activeDisplayItems.compactMap { item in
            if case .app(let app) = item { return app }
            return nil
        }.first?.id
        isKeyboardNavigationActive = false
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func applyGridLayoutChange() {
        pageOffset = 0
        targetPage = 0
        pageVelocity = 0
        scrollAccumulated = 0
        isPageGestureActive = false
        keyboardFocusID = nil
        isKeyboardNavigationActive = false
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func hide(_ app: AppInfo) {
        hiddenAppIDs.insert(app.id)
        persistHiddenApps()
        reconcileLaunchpadItems()
        refreshFilteredApps(resetPage: false)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func unhide(_ app: AppInfo) {
        hiddenAppIDs.remove(app.id)
        persistHiddenApps()
        reconcileLaunchpadItems()
        refreshFilteredApps(resetPage: false)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func addApplicationSource(_ url: URL) {
        let path = url.standardizedFileURL.path
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
        isPageGestureActive = false
        pageOffset = targetPage
        ensureKeyboardFocus(onPage: clamped)
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    func movePage(byPages delta: Int) {
        goToPage(currentPage + delta)
    }

    // MARK: Mouse drag pan (empty area)

    /// Begin a click-drag page pan on empty background.
    func beginPagePan() {
        isKeyboardNavigationActive = false
        isPageGestureActive = true
        pageVelocity = 0
        lastScrollTime = CACurrentMediaTime()
        scrollAccumulated = 0
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// Update pan by a fractional page delta (same rubber-band rules as scroll).
    /// Positive delta → next page (content moves left).
    func updatePagePan(deltaPages: Double) {
        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, min(now - lastScrollTime, 1.0 / 20.0))
        lastScrollTime = now

        isPageGestureActive = true
        let proposed = pageOffset + deltaPages
        let minPage = 0.0
        let maxPage = Double(max(pageCount - 1, 0))
        if proposed < minPage {
            pageOffset = minPage - rubberBand(minPage - proposed)
        } else if proposed > maxPage {
            pageOffset = maxPage + rubberBand(proposed - maxPage)
        } else {
            pageOffset = proposed
        }
        scrollAccumulated += deltaPages
        pageVelocity = deltaPages / dt
        targetPage = pageOffset
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// End pan and snap to a page (velocity-biased).
    func endPagePan() {
        isPageGestureActive = false
        settlePage(withVelocity: pageVelocity)
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
        let primary = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
        guard abs(primary) > 0.01 else { return }

        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, min(now - lastScrollTime, 1.0 / 20.0))
        lastScrollTime = now

        // Convert pixel/line delta into fractional pages. Negative scroll = next page (content moves left).
        let unit = isPrecise ? pageScrollUnit : pageScrollUnit * 0.35
        let pageDelta = Double(-primary) / unit

        let began = phase.contains(.began)
            || (phase == [] && momentumPhase == [] && !isPageGestureActive && !isPrecise)
        let ended = phase.contains(.ended) || phase.contains(.cancelled)
        let momentumEnded = momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled)
        let inMomentum = momentumPhase.contains(.began) || momentumPhase.contains(.changed)
        let inGesture = phase.contains(.changed) || began || inMomentum || isPageGestureActive

        if began {
            isPageGestureActive = true
            scrollAccumulated = 0
            pageVelocity = 0
        }

        if inGesture || inMomentum {
            isPageGestureActive = true
            // Rubber-band past ends while the gesture is live.
            let proposed = pageOffset + pageDelta
            let minPage = 0.0
            let maxPage = Double(max(pageCount - 1, 0))
            if proposed < minPage {
                let overflow = minPage - proposed
                pageOffset = minPage - rubberBand(overflow)
            } else if proposed > maxPage {
                let overflow = proposed - maxPage
                pageOffset = maxPage + rubberBand(overflow)
            } else {
                pageOffset = proposed
            }
            scrollAccumulated += pageDelta
            pageVelocity = pageDelta / dt
            targetPage = pageOffset
        }

        // Mouse wheel (non-precise): snap after each notch.
        if !isPrecise && phase == [] && momentumPhase == [] {
            isPageGestureActive = false
            settlePage(withVelocity: pageDelta > 0 ? 1.2 : -1.2)
            NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
            return
        }

        if ended || momentumEnded {
            isPageGestureActive = false
            settlePage(withVelocity: pageVelocity)
        }

        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
    }

    /// Snap to nearest page, biased by flick velocity (Launchpad-style).
    /// Logical `pageOffset` jumps to the target; the Metal layer springs visually.
    func settlePage(withVelocity velocity: Double = 0) {
        let minPage = 0.0
        let maxPage = Double(max(pageCount - 1, 0))
        var page = pageOffset

        // Flick threshold ≈ 0.85 pages/sec.
        if velocity > 0.85 {
            page = floor(pageOffset + 0.08) + 1
        } else if velocity < -0.85 {
            page = ceil(pageOffset - 0.08) - 1
        } else {
            page = pageOffset.rounded()
        }

        targetPage = min(max(page, minPage), maxPage)
        pageOffset = targetPage
        pageVelocity = 0
        isPageGestureActive = false
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
        guard !isSearching,
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
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
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
        guard sourceID != targetID,
              let source = folders.first(where: { $0.id == sourceID }),
              let targetIndex = folders.firstIndex(where: { $0.id == targetID }) else {
            return false
        }

        var existing = Set(folders[targetIndex].appIDs)
        folders[targetIndex].appIDs.append(contentsOf: source.appIDs.filter { existing.insert($0).inserted })
        folders.removeAll { $0.id == sourceID }
        itemOrderIDs.removeAll { $0 == sourceID }
        if openedFolderID == sourceID { openedFolderID = nil }
        persistFolders()
        persistItemOrder()
        reconcileLaunchpadItems()
        NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: nil)
        return true
    }

    /// Replace a folder at its current root position with its member apps.
    @discardableResult
    func dissolveFolder(_ folderID: String) -> [String]? {
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        let members = folders[folderIndex].appIDs
        let rootIndex = itemOrderIDs.firstIndex(of: folderID)
            ?? launchpadItems.firstIndex(where: { $0.id == folderID })
            ?? itemOrderIDs.endIndex
        folders.remove(at: folderIndex)
        itemOrderIDs.removeAll { $0 == folderID || members.contains($0) }
        itemOrderIDs.insert(contentsOf: members, at: min(rootIndex, itemOrderIDs.endIndex))
        if openedFolderID == folderID { openedFolderID = nil }
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
        guard let targetIndex = folders.firstIndex(where: { $0.id == folderID }),
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
            self.openedFolderID = nil
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
        guard let folderIndex = folders.firstIndex(where: { $0.id == folderID }),
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
            if openedFolderID == folderID { openedFolderID = nil }
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
        guard !isSearching,
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
        openedFolderID = nil
        isDraggingFolderApp = false
        isFolderRemovalTargeted = false
        // Clear search when closed so next open shows full grid.
        if !searchText.isEmpty {
            updateSearch("")
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
                || (!compactQuery.isEmpty && app.pinyinFull.contains(compactQuery))
                || (!compactQuery.isEmpty && app.pinyinInitials.contains(compactQuery))
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

}
