import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case applications = "应用程序"
    case about = "关于"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .applications: "square.grid.2x2"
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
                        GeneralSettingsView()
                    case .applications:
                        ApplicationSettingsView(store: store)
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
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage(QLaunchpadPreferences.showMenuBarIconKey)
    private var showMenuBarIcon = QLaunchpadPreferences.defaultShowMenuBarIcon
    @AppStorage(QLaunchpadPreferences.showDockIconKey)
    private var showDockIcon = QLaunchpadPreferences.defaultShowDockIcon
    @AppStorage("showLabels") private var showLabels = true
    @AppStorage(GridLayoutPreset.defaultsKey)
    private var gridLayoutPreset = GridLayoutPreset.defaultPreset.rawValue
    @AppStorage(LaunchpadAnimationStyle.defaultsKey)
    private var presentationAnimationStyle = LaunchpadAnimationStyle.fly.rawValue
    @State private var didClearIconCache = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 QLaunchpad", isOn: $launchAtLogin)
                    .disabled(true)

                Toggle(isOn: $showDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示程序坞图标")
                        Text("将 QLaunchpad 保留在程序坞中，以便从程序坞启动")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: showDockIcon) { _, _ in
                    notifyAppearanceChanged()
                }
            }

            Section("显示") {
                Toggle("显示菜单栏图标", isOn: $showMenuBarIcon)
                    .toggleStyle(.switch)
                    .onChange(of: showMenuBarIcon) { _, _ in
                        notifyAppearanceChanged()
                    }
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
            }

            Section("缓存") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("图标缓存")
                        Text("删除已缓存的图标并重新加载")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("删除") {
                        NotificationCenter.default.post(
                            name: .qlaunchpadIconCacheClearRequested,
                            object: nil
                        )
                        didClearIconCache = true
                    }
                    .buttonStyle(.bordered)
                }
                if didClearIconCache {
                    Text("图标缓存已删除，正在重新加载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("动画") {
                Picker("切换动画", selection: $presentationAnimationStyle) {
                    ForEach(LaunchpadAnimationStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                Text("隐藏窗口时会自动播放所选进入动画的反向效果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("键盘") {
                HotKeyRecorderRow()
                LabeledContent("关闭", value: "Esc")
                LabeledContent("选择应用", value: "方向键")
                LabeledContent("打开应用", value: "Return")
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        Form {
            Section("应用来源") {
                sourceRow(
                    title: "应用程序",
                    subtitle: "默认路径",
                    path: nil,
                    selected: selectedSource == nil
                )

                ForEach(store.customApplicationSourcePaths, id: \.self) { path in
                    sourceRow(
                        title: URL(fileURLWithPath: path).lastPathComponent,
                        subtitle: path,
                        path: path,
                        selected: selectedSource == path
                    )
                }

                HStack(spacing: 0) {
                    Button(action: addSource) {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("添加应用文件夹")

                    Divider().frame(height: 18)

                    Button(action: removeSelectedSource) {
                        Image(systemName: "minus")
                            .frame(width: 28, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedSource == nil)
                    .help("移除所选文件夹")

                    Spacer()

                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button("重新扫描") { store.load() }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
    }

    private func sourceRow(
        title: String,
        subtitle: String,
        path: String?,
        selected: Bool
    ) -> some View {
        Button {
            selectedSource = path
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.cyan.gradient)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .frame(minHeight: 46)
            .background(selected && path != nil ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func removeSelectedSource() {
        guard let selectedSource,
              let index = store.customApplicationSourcePaths.firstIndex(of: selectedSource) else { return }
        store.removeApplicationSource(at: IndexSet(integer: index))
        self.selectedSource = nil
    }
}

private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
            Text("QLaunchpad")
                .font(.largeTitle.weight(.semibold))
            Text("版本 \(version)")
                .foregroundStyle(.secondary)
            Text("高性能、原生 Metal 渲染的 macOS 应用启动器。")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
