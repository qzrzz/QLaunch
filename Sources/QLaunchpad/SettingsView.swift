import AppKit
import QLaunchpadCore
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case applications = "应用程序"
    case ai = "AI 接口"
    case about = "关于"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .applications: "square.grid.2x2"
        case .ai: "sparkles"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.symbol)
                    .tag(tab)
                    .font(.body.weight(.medium))
                    .padding(.vertical, 5)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 28)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .frame(width: 140)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: selection.symbol)
                        .foregroundStyle(.secondary)
                    Text(selection.rawValue)
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 38)

                Divider()

                Group {
                    switch selection {
                    case .general:
                        GeneralSettingsView(store: store)
                    case .applications:
                        ApplicationSettingsView(store: store)
                    case .ai:
                        AISettingsView()
                    case .about:
                        AboutSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 530, minHeight: 550)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore
    @AppStorage(QLaunchpadPreferences.showMenuBarIconKey)
    private var showMenuBarIcon = QLaunchpadPreferences.defaultShowMenuBarIcon
    @AppStorage(QLaunchpadPreferences.showDockIconKey)
    private var showDockIcon = QLaunchpadPreferences.defaultShowDockIcon
    @AppStorage("showLabels") private var showLabels = true
    @AppStorage(GridLayoutPreset.defaultsKey)
    private var gridLayoutPreset = GridLayoutPreset.defaultPreset.rawValue
    @AppStorage(IconRenderQuality.defaultsKey)
    private var iconRenderQuality = IconRenderQuality.defaultQuality.rawValue
    @AppStorage(LaunchpadAnimationStyle.defaultsKey)
    private var presentationAnimationStyle = LaunchpadAnimationStyle.fly.rawValue
    @State private var launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
    @State private var launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
    @State private var didClearCache = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle(isOn: launchAtLoginBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时启动 QLaunch")
                        Text(
                            launchAtLoginNeedsApproval
                                ? "已请求登录项，请在系统设置中允许"
                                : "开机后启动"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $showDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("程序坞图标")
                        Text("程序坞中显示图标，以便从程序坞启动")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: showDockIcon) { _, _ in
                    notifyAppearanceChanged()
                }

                Toggle("菜单栏图标", isOn: $showMenuBarIcon)
                .toggleStyle(.switch)
                .onChange(of: showMenuBarIcon) { _, _ in
                    notifyAppearanceChanged()
                }
            }

            Section("显示") {
                Toggle("显示应用名称", isOn: $showLabels)
                Picker("布局", selection: $gridLayoutPreset) {
                    ForEach(GridLayoutPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: gridLayoutPreset) { _, _ in
                    NotificationCenter.default.post(name: .qlaunchpadGridLayoutChanged, object: nil)
                }

                Picker("渲染质量", selection: $iconRenderQuality) {
                    ForEach(IconRenderQuality.allCases) { quality in
                        Text(quality.title).tag(quality.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .disabled(store.isApplyingRenderQuality)
                .onChange(of: iconRenderQuality) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: IconRenderQuality.defaultsKey)
                    NotificationCenter.default.post(
                        name: .qlaunchpadRenderQualityChanged,
                        object: nil
                    )
                }
                if store.isApplyingRenderQuality {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在应用渲染质量…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let quality = IconRenderQuality(rawValue: iconRenderQuality) {
                    Text(quality.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("动画") {
                Picker("切换动画", selection: $presentationAnimationStyle) {
                    ForEach(LaunchpadAnimationStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                Text("页面显示/隐藏时图标的出入场动画。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("键盘") {
                HotKeyRecorderRow()
                LabeledContent("关闭", value: "Esc")
                LabeledContent("选择应用", value: "方向键")
                LabeledContent("打开应用", value: "Return")
            }

            Section("清除缓存") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清除缓存")
                        Text("清除图标、文字和壁纸缓存并重新构建")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清除") {
                        NotificationCenter.default.post(
                            name: .qlaunchpadCacheClearRequested,
                            object: nil
                        )
                        didClearCache = true
                    }
                    .buttonStyle(.bordered)
                }
                if didClearCache {
                    Text("缓存已清除，正在重新构建")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLaunchAtLogin)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLogin()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        )
    }

    private func refreshLaunchAtLogin() {
        launchAtLoginNeedsApproval = LaunchAtLogin.needsApproval
        launchAtLogin = LaunchAtLogin.isEnabled || launchAtLoginNeedsApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            refreshLaunchAtLogin()
            if enabled, LaunchAtLogin.needsApproval {
                NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
                LaunchAtLogin.openSystemSettings()
            }
        } catch {
            refreshLaunchAtLogin()
            presentLaunchAtLoginError(error)
        }
    }

    private func presentLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法更改登录项"
        alert.informativeText = """
        \(error.localizedDescription)

        请将 QLaunch 放到「应用程序」文件夹后再试。
        """
        alert.addButton(withTitle: "好")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func notifyAppearanceChanged() {
        NotificationCenter.default.post(name: .qlaunchpadAppearanceChanged, object: nil)
    }
}

private struct HotKeyRecorderRow: View {
    @AppStorage(LaunchpadHotKeyPreferences.keyCodeKey)
    private var keyCode = LaunchpadHotKeyPreferences.defaultKeyCode
    @AppStorage(LaunchpadHotKeyPreferences.modifiersKey)
    private var modifiers = LaunchpadHotKeyPreferences.defaultModifiers

    var body: some View {
        HStack {
            Text("打开 / 关闭")
            Spacer()
            HotKeyRecorder(
                keyCode: $keyCode,
                modifiers: $modifiers
            )
            .frame(width: 132, height: 26)
        }
    }
}

private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let view = HotKeyRecorderNSView()
        view.keyCode = UInt16(clamping: keyCode)
        view.modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        view.onChange = { keyCode, modifiers in
            self.keyCode = Int(keyCode)
            self.modifiers = Int(modifiers.rawValue)
        }
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderNSView, context: Context) {
        nsView.keyCode = UInt16(clamping: keyCode)
        nsView.modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        nsView.needsDisplay = true
    }
}

private final class HotKeyRecorderNSView: NSView {
    var keyCode: UInt16 = UInt16(LaunchpadHotKeyPreferences.defaultKeyCode)
    var modifiers = NSEvent.ModifierFlags(rawValue: UInt(LaunchpadHotKeyPreferences.defaultModifiers))
    var onChange: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
        NotificationCenter.default.post(
            name: .qlaunchpadHotKeyRecordingChanged,
            object: nil,
            userInfo: ["recording": true]
        )
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let shortcutModifiers = flags.intersection(supportedModifiers)
        guard !shortcutModifiers.isEmpty else { return }

        keyCode = event.keyCode
        modifiers = shortcutModifiers
        onChange?(keyCode, modifiers)
        isRecording = false
        NotificationCenter.default.post(
            name: .qlaunchpadHotKeyRecordingChanged,
            object: nil,
            userInfo: ["recording": false]
        )
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            NotificationCenter.default.post(
                name: .qlaunchpadHotKeyRecordingChanged,
                object: nil,
                userInfo: ["recording": false]
            )
        }
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let background = NSColor.controlBackgroundColor.withAlphaComponent(0.8)
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let border = isRecording ? NSColor.controlAccentColor : NSColor.separatorColor
        border.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let title = isRecording
            ? "按下快捷键"
            : LaunchpadHotKeyPreferences.displayName(keyCode: keyCode, modifiers: modifiers)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

private struct ApplicationSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selectedSource: String?
    @State private var importStatusMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("应用程序数量", value: "\(store.apps.count)")
            }

            Section("应用来源") {
                ApplicationSourceList(
                    items: sourceItems,
                    selection: $selectedSource,
                    isLoading: store.isLoading,
                    onAdd: addSource,
                    onRemove: removeSelectedSource,
                    onRescan: { store.load() },
                    onReveal: revealSource
                )
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("隐藏的应用") {
                Toggle("在搜索结果中显示隐藏应用", isOn: $store.showHiddenAppsInSearch)
            }

            Section {
                if store.hiddenApps.isEmpty {
                    VStack(spacing: 5) {
                        Text("暂无应用")
                            .font(.body.weight(.medium))
                        Text("右键点击应用即可隐藏")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 138)
                } else {
                    ForEach(store.hiddenApps) { app in
                        hiddenAppRow(app)
                    }
                }
            }

            Section("用户数据") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前布局文件")
                        Text("导出或导入当前排序和分组")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导出…") { exportLayoutFile() }
                        .buttonStyle(.bordered)
                        .disabled(store.isLoading || store.apps.isEmpty)
                    Button("导入…") { importLayoutFile() }
                        .buttonStyle(.bordered)
                        .disabled(store.isLoading || store.apps.isEmpty)
                }

                HStack(spacing: 8) {
                    LayoutProfilePopUp(
                        profiles: store.layoutProfiles,
                        selection: layoutSelectorSelection
                    )
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .disabled(store.isLoading || store.apps.isEmpty)

                    Button("新建") { promptCreateLayoutProfile() }
                        .buttonStyle(.bordered)
                        .disabled(store.isLoading)

                    Button("删除") { promptDeleteLayoutProfile() }
                        .buttonStyle(.bordered)
                        .disabled(
                            store.isLoading
                                || store.apps.isEmpty
                                || !store.canDeleteActiveLayoutProfile
                        )
                }

                if let importStatusMessage {
                    Text(importStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sourceItems: [ApplicationSourceItem] {
        ApplicationSourceItem.systemDefaults() + ApplicationSourceItem.custom(
            paths: store.customApplicationSourcePaths
        )
    }

    private func hiddenAppRow(_ app: AppInfo) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body.weight(.medium))
                Text(app.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("取消隐藏") { store.unhide(app) }
                .buttonStyle(.borderless)
        }
        .frame(minHeight: 44)
    }

    private func addSource() {
        let panel = NSOpenPanel()
        panel.title = "选择应用文件夹"
        panel.prompt = "添加"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.addApplicationSource(url)
            selectedSource = url.standardizedFileURL.path
        }
    }

    private var layoutSelectorSelection: Binding<String> {
        Binding(
            get: { store.layoutSelectorID },
            set: { newID in
                do {
                    try store.selectLayoutSelector(newID)
                } catch {
                    presentAlert(title: "无法切换布局", message: profileErrorMessage(error))
                }
            }
        )
    }

    private var layoutBackupDirectoryLabel: String {
        let domain = Bundle.main.bundleIdentifier ?? (kCFPreferencesCurrentApplication as String)
        let folderName = LaunchpadPreferenceStore.layoutBackupFileURL(domain: domain)
            .deletingLastPathComponent()
            .lastPathComponent
        return "应用程序支持/\(folderName)"
    }

    private func promptCreateLayoutProfile() {
        let alert = NSAlert()
        alert.messageText = "新建布局"
        alert.informativeText = "新布局会复制当前排序和分组。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: LaunchpadLayoutProfileStore.suggestedNewName(existing: store.layoutProfiles))
        field.placeholderString = "布局名称"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.isEditable = true
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try self.store.createLayoutProfile(named: field.stringValue)
            } catch {
                self.presentAlert(title: "无法创建布局", message: self.profileErrorMessage(error))
            }
        }
        presentAlert(alert, completion: complete)
        DispatchQueue.main.async {
            field.currentEditor()?.selectAll(nil)
        }
    }

    private func promptDeleteLayoutProfile() {
        guard store.canDeleteActiveLayoutProfile else { return }
        let alert = NSAlert()
        alert.messageText = "删除布局「\(store.activeLayoutProfileName)」？"
        alert.informativeText = "此操作无法撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        presentAlert(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try self.store.deleteLayoutProfile(self.store.activeLayoutProfileID)
            } catch {
                self.presentAlert(title: "无法删除布局", message: self.profileErrorMessage(error))
            }
        }
    }

    private func profileErrorMessage(_ error: Error) -> String {
        if let error = error as? LaunchpadLayoutProfileError {
            return error.errorDescription ?? error.localizedDescription
        }
        return layoutErrorMessage(error)
    }

    private func exportLayoutFile() {
        guard !store.isLoading, !store.apps.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "导出布局"
        panel.nameFieldStringValue = "QLaunch-layout.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try LaunchpadLayoutDocument.makeEncoder(pretty: true).encode(store.exportLayout())
            try data.write(to: url, options: .atomic)
        } catch {
            presentAlert(title: "无法导出布局", message: layoutErrorMessage(error))
        }
    }

    private func importLayoutFile() {
        guard !store.isLoading, !store.apps.isEmpty else { return }
        importStatusMessage = nil
        let panel = NSOpenPanel()
        panel.title = "导入布局"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document: LaunchpadLayoutDocument
        do {
            let data = try Data(contentsOf: url)
            try LaunchpadLayoutImporter.validateJSONSize(data)
            document = try LaunchpadLayoutDocument.makeDecoder().decode(
                LaunchpadLayoutDocument.self,
                from: data
            )
            try LaunchpadLayoutImporter.validate(document)
        } catch {
            presentAlert(title: "无法读取布局文件", message: layoutErrorMessage(error))
            return
        }

        let alert = NSAlert()
        alert.messageText = "导入布局？"
        alert.informativeText = """
        将按文件重排当前排序和分组。文件中未出现的应用会排到最后。隐藏列表仅在文件含 `hidden` 时整表替换；省略 `hidden` 时，写进文件的应用会取消隐藏，其余隐藏项保留。导入前会把当前布局备份到「\(layoutBackupDirectoryLabel)/layout.backup.json」，可再导入该文件恢复。
        """
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            self.applyImportedLayout(document)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(alert.runModal())
        }
    }

    private func applyImportedLayout(_ document: LaunchpadLayoutDocument) {
        do {
            let report = try store.applyLayout(document, mode: .merge)
            importStatusMessage = "已导入 \(report.importedRootItems) 项，跳过 \(report.skippedUnknown.count) 个未知应用，追加 \(report.appendedLeftover.count) 个新应用"
        } catch {
            importStatusMessage = nil
            presentAlert(title: "无法导入布局", message: layoutErrorMessage(error))
        }
    }

    private func layoutErrorMessage(_ error: Error) -> String {
        guard let error = error as? LaunchpadLayoutError else {
            return error.localizedDescription
        }
        switch error {
        case .invalidKind:
            return "不是 QLaunch 布局文件。"
        case .unsupportedSchemaVersion:
            return "不支持的布局文件版本。"
        case .malformed(let reason):
            if reason == "application catalog is empty" {
                return "应用列表尚未就绪，请等待扫描完成后再导入。"
            }
            return "布局文件格式无效。"
        case .limitExceeded(let limit):
            return limit == "json" ? "布局文件过大。" : "布局文件超出限制。"
        case .duplicateID:
            return "布局文件包含重复项。"
        case .nestedFolder:
            return "布局文件包含嵌套文件夹。"
        case .itemHiddenOverlap:
            return "应用不能同时出现在布局和隐藏列表中。"
        case .strictUnresolved:
            return "布局文件包含无法识别的应用。"
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        presentAlert(alert)
    }

    private func presentAlert(
        _ alert: NSAlert,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else if let completion {
            completion(alert.runModal())
        } else {
            alert.runModal()
        }
    }

    private func removeSelectedSource() {
        guard let selectedSource,
              sourceItems.first(where: { $0.id == selectedSource })?.isRemovable == true,
              let index = store.customApplicationSourcePaths.firstIndex(of: selectedSource) else { return }
        store.removeApplicationSource(at: IndexSet(integer: index))
        self.selectedSource = nil
    }

    private func revealSource(_ item: ApplicationSourceItem) {
        let url = URL(fileURLWithPath: item.iconPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct LayoutProfilePopUp: NSViewRepresentable {
    var profiles: [LaunchpadLayoutProfile]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        button.removeAllItems()
        if button.menu == nil {
            button.menu = NSMenu()
        }
        guard let menu = button.menu else { return }

        let userHeader = NSMenuItem(title: "用户布局", action: nil, keyEquivalent: "")
        userHeader.isEnabled = false
        menu.addItem(userHeader)
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = LaunchpadLayoutSelectorID.user(profile.id)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let autoHeader = NSMenuItem(title: "自动布局", action: nil, keyEquivalent: "")
        autoHeader.isEnabled = false
        menu.addItem(autoHeader)
        for kind in LaunchpadAutoLayoutKind.allCases {
            let item = NSMenuItem(title: kind.title, action: nil, keyEquivalent: "")
            item.representedObject = LaunchpadLayoutSelectorID.auto(kind)
            menu.addItem(item)
        }

        if let index = menu.items.firstIndex(where: { ($0.representedObject as? String) == selection }) {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            selection.wrappedValue = id
            if selection.wrappedValue != id,
               let index = sender.itemArray.firstIndex(where: {
                   ($0.representedObject as? String) == selection.wrappedValue
               }) {
                sender.selectItem(at: index)
            }
        }
    }
}

private struct AISettingsView: View {
    @State private var promptText = LayoutOrganizePrompt.make()
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("把下面的提示词复制给本地的 AI Agent，比如 Codex、Grok Build、Claude Code、Antigravity、Kimi Work 等")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(didCopy ? "已复制" : "复制提示词") {
                    copyPrompt()
                }
                .buttonStyle(.borderedProminent)
            }

            TextEditor(text: $promptText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            promptText = LayoutOrganizePrompt.make()
            didCopy = false
        }
        .onChange(of: promptText) { _, _ in
            didCopy = false
        }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(promptText, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

/// 关于页（参考 Qf `AboutSettingsView`：版本、作者与社区链接、版权）。
private struct AboutSettingsView: View {
    @ObservedObject private var updater = Updater.shared

    private static let githubURL = "https://github.com/qzrzz/QLaunch"
    private static let authorURL = "https://qzrzz.com/"
    private static let xURL = "https://x.com/qzrz256"
    private static let xiaohongshuURL = "https://www.xiaohongshu.com/"
    private static let bilibiliURL = "https://space.bilibili.com/3546636494047957"
    private static let emailAddress = "qlaunchpad@qzrzz.com"

    private var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(short) (\(build))"
    }

    /// Prefer the system-rendered app icon (Assets.car / icns → 投影与圆角).
    private var appIcon: NSImage {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let systemIcon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            if systemIcon.size.width > 0 {
                return systemIcon
            }
        }
        return QLaunchpadAppIcon.image ?? NSApplication.shared.applicationIconImage
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                versionCard
                authorAndCommunityCard
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                // Optical size: system icons already include margin + soft shadow.
                .frame(width: 96, height: 96)

            Text("QLaunch")
                .font(.title.weight(.bold))

            Text("高性能、原生 Metal 渲染的 macOS 应用启动器。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var versionCard: some View {
        aboutCard(header: "版本") {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 22)

                Text(versionLabel)
                    .font(.body)
                    .textSelection(.enabled)

                Spacer(minLength: 12)

                Button("检查更新") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!updater.isCheckEnabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var authorAndCommunityCard: some View {
        aboutCard(header: "关于作者与社区") {
            VStack(spacing: 0) {
                linkRow(
                    title: "作者",
                    subtitle: "Qzrzz · https://qzrzz.com/",
                    url: Self.authorURL,
                    icon: authorLogo
                )
                aboutDivider()
                linkRow(
                    title: "Github",
                    subtitle: Self.githubURL,
                    url: Self.githubURL,
                    icon: templateIcon("RemixGithub", systemFallback: "chevron.left.forwardslash.chevron.right", tint: .primary)
                )
                aboutDivider()
                linkRow(
                    title: "X（推特）",
                    subtitle: Self.xURL,
                    url: Self.xURL,
                    icon: templateIcon("RemixTwitterX", systemFallback: "at", tint: .primary)
                )
                aboutDivider()
                linkRow(
                    title: "小红书",
                    subtitle: Self.xiaohongshuURL,
                    url: Self.xiaohongshuURL,
                    icon: templateIcon("RemixXiaohongshu", systemFallback: "book", tint: .red)
                )
                aboutDivider()
                linkRow(
                    title: "哔哩哔哩",
                    subtitle: Self.bilibiliURL,
                    url: Self.bilibiliURL,
                    icon: templateIcon("RemixBilibili", systemFallback: "play.rectangle.fill", tint: .cyan)
                )
                aboutDivider()
                linkRow(
                    title: "Email",
                    subtitle: Self.emailAddress,
                    url: "mailto:\(Self.emailAddress)",
                    icon: templateIcon("RemixEmail", systemFallback: "envelope.fill", tint: .teal)
                )
            }
        }
    }

    private var authorLogo: some View {
        Group {
            if let logo = QLaunchpadAppIcon.resourceImage(named: "QzrzzLogo", pointSize: 22) {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func templateIcon(
        _ resourceName: String,
        systemFallback: String,
        tint: Color
    ) -> some View {
        Group {
            if let image = QLaunchpadAppIcon.resourceImage(
                named: resourceName,
                template: true,
                pointSize: 18
            ) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
            } else {
                Image(systemName: systemFallback)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func linkRow<Icon: View>(
        title: String,
        subtitle: String,
        url: String,
        icon: Icon
    ) -> some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                openURL(url)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("打开链接: \(url)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { openURL(url) }
    }

    private func aboutCard<Content: View>(
        header: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            content()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                )
        }
    }

    private func aboutDivider() -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(height: 1)
            .padding(.leading, 14 + 22 + 12)
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
        NSWorkspace.shared.open(url)
    }
}
