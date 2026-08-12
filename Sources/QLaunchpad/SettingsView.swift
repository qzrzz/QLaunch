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
    @AppStorage(IconRenderQuality.defaultsKey)
    private var iconRenderQuality = IconRenderQuality.defaultQuality.rawValue
    @AppStorage(LaunchpadAnimationStyle.defaultsKey)
    private var presentationAnimationStyle = LaunchpadAnimationStyle.fly.rawValue
    @State private var didClearCache = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 QLaunch", isOn: $launchAtLogin)
                    .disabled(true)

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
                .onChange(of: iconRenderQuality) { _, newValue in
                    // Explicit notification so Metal rebuilds immediately;
                    // UserDefaults.didChangeNotification alone can lag behind
                    // @AppStorage or coalesce with other preference writes.
                    UserDefaults.standard.set(newValue, forKey: IconRenderQuality.defaultsKey)
                    NotificationCenter.default.post(
                        name: .qlaunchpadRenderQualityChanged,
                        object: nil
                    )
                }
                if let quality = IconRenderQuality(rawValue: iconRenderQuality) {
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

/// 关于页（参考 Qf `AboutSettingsView`：版本、作者与社区链接、版权）。
private struct AboutSettingsView: View {
    private static let githubURL = "https://github.com/qzrzz/QLaunch"
    private static let releasesURL = "https://github.com/qzrzz/QLaunch/releases"
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
                    openURL(Self.releasesURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
        NSWorkspace.shared.open(url)
    }
}
