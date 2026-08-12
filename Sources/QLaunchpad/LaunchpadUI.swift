import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let qlaunchpadStoreChanged = Notification.Name("QLaunchpadStoreChanged")
    static let qlaunchpadDismiss = Notification.Name("QLaunchpadDismiss")
    static let qlaunchpadPresentationChanged = Notification.Name("QLaunchpadPresentationChanged")
    static let qlaunchpadFocusSearch = Notification.Name("QLaunchpadFocusSearch")
    static let qlaunchpadGridLayoutChanged = Notification.Name("QLaunchpadGridLayoutChanged")
    static let qlaunchpadCacheClearRequested = Notification.Name("QLaunchpadCacheClearRequested")
}

/// Overlay hosting view that only intercepts hits in the search / chrome regions.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Top strip reserved for the search field (points from top of view).
    var interactiveTopHeight: CGFloat = 120
    /// Bottom strip reserved for page indicator.
    var interactiveBottomHeight: CGFloat = 80

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit: y=0 is bottom.
        let fromTop = bounds.height - point.y
        let fromBottom = point.y
        if fromTop <= interactiveTopHeight || fromBottom <= interactiveBottomHeight {
            return super.hitTest(point)
        }
        return nil
    }
}

@MainActor
final class LaunchpadContainerView: NSView {
    private let store: AppStore
    private let backgroundView: DesktopBackgroundView
    private let metalView: LaunchpadMetalView
    private let overlayView: PassthroughHostingView<LaunchpadOverlayView>
    private var cancellables = Set<AnyCancellable>()

    var metal: LaunchpadMetalView { metalView }
    var background: DesktopBackgroundView { backgroundView }

    init(store: AppStore) {
        self.store = store
        backgroundView = DesktopBackgroundView(screen: NSScreen.main)
        metalView = LaunchpadMetalView(store: store)
        overlayView = PassthroughHostingView(rootView: LaunchpadOverlayView(store: store))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(backgroundView)
        addSubview(metalView)
        addSubview(overlayView)

        // Overlay chrome fades with presentation progress.
        overlayView.alphaValue = 0

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.metalView.needsDisplay = true
                NotificationCenter.default.post(name: .qlaunchpadStoreChanged, object: self)
                self.syncOverlayAlpha()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presentationNote(_:)),
            name: .qlaunchpadPresentationChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cacheClearRequested),
            name: .qlaunchpadCacheClearRequested,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func presentationNote(_ note: Notification) {
        guard let showing = note.userInfo?["showing"] as? Bool else { return }
        let style = (note.userInfo?["animationStyle"] as? String)
            .flatMap(LaunchpadAnimationStyle.init(rawValue:))
            ?? LaunchpadAnimationStyle.current
        if showing {
            // The wallpaper is part of the immediately visible window. Only the
            // interactive overlay accompanies the Metal icon fade-in.
            backgroundView.alphaValue = 1
        }
        guard style != .none else {
            overlayView.alphaValue = showing ? 1 : 0
            if !showing { backgroundView.alphaValue = 0 }
            return
        }
        // Fade dismissal is performed on the containing NSPanel. Keeping these
        // child layers unchanged avoids multiplying two opacity animations.
        if !showing, style == .fade { return }
        let transitionDuration = showing ? style.duration : style.dismissalDuration
        let overlayDuration = min(transitionDuration, 0.32)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = overlayDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlayView.animator().alphaValue = showing ? 1 : 0
        }
        if !showing {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = style.dismissalDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                backgroundView.animator().alphaValue = 0
            }
        }
    }

    @objc private func cacheClearRequested() {
        backgroundView.clearCacheAndReload()
    }

    private func syncOverlayAlpha() {
        // Keep overlay in sync if presentationProgress is driven from Metal.
        if store.presentation == .visible {
            overlayView.alphaValue = 1
            backgroundView.alphaValue = 1
        }
    }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        metalView.frame = bounds
        overlayView.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc
        if event.keyCode == 53 {
            NotificationCenter.default.post(name: .qlaunchpadDismiss, object: nil)
            return
        }
        // Fallback keyboard navigation when the search field is not first responder.
        if event.keyCode == 123 {
            store.moveKeyboardFocus(.left)
            return
        }
        if event.keyCode == 124 {
            store.moveKeyboardFocus(.right)
            return
        }
        if event.keyCode == 125 {
            store.moveKeyboardFocus(.down)
            return
        }
        if event.keyCode == 126 {
            store.moveKeyboardFocus(.up)
            return
        }
        super.keyDown(with: event)
    }

    func prepareForShow(on screen: NSScreen) {
        backgroundView.alphaValue = 1
        // Hide any drawable retained from the previous presentation until Metal
        // confirms that the new animation's transparent start frame is ready.
        metalView.alphaValue = 0
        overlayView.alphaValue = 0
        backgroundView.prepare(for: screen)
        backgroundView.prepareForPresentation()
    }

    func revealPrimedMetalContent() {
        metalView.alphaValue = 1
    }

    func animateWallpaperIn() {
        backgroundView.animateWallpaperIn(duration: 0.5)
    }

    func showWallpaperImmediately() {
        backgroundView.showWallpaperImmediately()
    }
}

// MARK: - SwiftUI overlay

struct LaunchpadOverlayView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        GeometryReader { _ in
            ZStack {
                VStack(spacing: 0) {
                    Group {
                        if let folder = store.openedFolder {
                            FolderTitleField(store: store, folder: folder)
                        } else {
                            SearchField(store: store)
                        }
                    }
                    .padding(.top, 36)
                    Spacer(minLength: 0)
                    PageIndicator(store: store)
                        .padding(.bottom, 36)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if store.isDraggingFolderApp {
                    FolderRemovalDropZone(isTargeted: store.isFolderRemovalTargeted)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 76)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.18), value: store.isDraggingFolderApp)
            .animation(.easeOut(duration: 0.14), value: store.isFolderRemovalTargeted)
        }
        .ignoresSafeArea()
    }
}

private struct FolderRemovalDropZone: View {
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 16, weight: .semibold))
            Text("移出文件夹")
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(isTargeted ? 1 : 0.82))
        .frame(width: 240, height: 54)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(isTargeted ? 0.20 : 0.09))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(isTargeted ? 0.62 : 0.22), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .scaleEffect(isTargeted ? 1.06 : 1)
    }
}

// MARK: - Liquid glass search field

private struct FolderTitleField: View {
    @ObservedObject var store: AppStore
    let folder: AppFolder
    @State private var draftName: String
    @FocusState private var isFocused: Bool

    private let fieldWidth: CGFloat = 360
    private let fieldHeight: CGFloat = 44

    init(store: AppStore, folder: AppFolder) {
        self.store = store
        self.folder = folder
        _draftName = State(initialValue: folder.name)
    }

    var body: some View {
        TextField("文件夹", text: $draftName) {
            commitName()
        }
        .textFieldStyle(.plain)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white.opacity(0.94))
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .truncationMode(.middle)
        .focused($isFocused)
        .frame(width: fieldWidth, height: fieldHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder name")
        .onAppear {
            draftName = folder.name
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commitName()
            }
        }
    }

    private func commitName() {
        store.renameFolder(folder.id, to: draftName)
        if let currentName = store.folder(withID: folder.id)?.name {
            draftName = currentName
        }
    }
}

private struct SearchField: View {
    @ObservedObject var store: AppStore
    @State private var isFocused = false
    /// Bumped to request first-responder; survives overlay reuse across presentations.
    @State private var focusRequestID = 0

    private let fieldWidth: CGFloat = 360
    private let fieldHeight: CGFloat = 44
    private let cornerRadius: CGFloat = 22

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .symbolRenderingMode(.hierarchical)

            // AppKit field: custom placeholder color + native IME marked-text handling.
            // SwiftUI `prompt` color is unreliable; overlay placeholders cover preedit.
            AppKitSearchTextField(
                text: Binding(
                    get: { store.searchText },
                    set: { store.updateSearch($0) }
                ),
                isFocused: $isFocused,
                focusRequestID: focusRequestID,
                placeholder: "Search"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                DispatchQueue.main.async {
                    focusRequestID &+= 1
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .qlaunchpadFocusSearch)) { _ in
                // Overlay persists between presentations; re-focus on each open.
                focusRequestID &+= 1
            }

            Button {
                if !store.searchText.isEmpty {
                    store.updateSearch("")
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .frame(width: 16, height: 16)
            .opacity(store.searchText.isEmpty ? 0 : 1)
            .allowsHitTesting(!store.searchText.isEmpty)
            .accessibilityHidden(store.searchText.isEmpty)
            .help("Clear search")

            Button {
                NotificationCenter.default.post(name: .qlaunchpadOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
        }
        .padding(.horizontal, 16)
        .frame(width: fieldWidth, height: fieldHeight)
        .background { glassBackground }
        .overlay { glassStroke }
        // Soft, airy shadow — avoid heavy darkening under a clear glass field.
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search apps")
    }

    @ViewBuilder
    private var glassBackground: some View {
        if #available(macOS 26.0, *) {
            // Clear liquid glass — more translucent than `.regular`.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else if #available(macOS 15.0, *) {
            // Thin, highly transparent glass approximation.
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.55)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.14),
                                Color.white.opacity(0.04),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                // Specular rim (top) — light so it stays airy.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.45),
                                Color.white.opacity(0.06),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.5)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            }
        }
    }

    @ViewBuilder
    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isFocused ? 0.38 : 0.22),
                        Color.white.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
    }
}

// MARK: - AppKit search field (placeholder color + IME)

/// Native single-line `NSTextView` so the IME field editor can report marked text
/// directly. `NSTextField`'s shared field editor only reliably reports committed
/// text, which is too late for responsive pinyin search.
private struct AppKitSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var focusRequestID: Int
    var placeholder: String

    private static let textFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 16, weight: .medium)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: rounded, size: 16) ?? base
        }
        return base
    }()

    private static let textColor = NSColor.white.withAlphaComponent(0.95)
    private static let placeholderColor = NSColor.white.withAlphaComponent(0.55)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> IMESearchTextView {
        let view = IMESearchTextView(frame: .zero)
        view.setSearchText(text)
        view.placeholder = placeholder
        view.delegate = context.coordinator
        view.onTextChange = { [weak coordinator = context.coordinator] value in
            coordinator?.updateSearchText(value)
        }
        return view
    }

    func updateNSView(_ field: IMESearchTextView, context: Context) {
        context.coordinator.parent = self

        // Never replace the text while IME marked text is active.
        if !field.hasMarkedText(), field.string != text {
            field.setSearchText(text)
        }
        field.placeholder = placeholder
        field.needsDisplay = true

        if focusRequestID != context.coordinator.lastFocusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                if window.firstResponder !== field {
                    window.makeFirstResponder(field)
                }
                field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
                context.coordinator.parent.isFocused = true
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppKitSearchTextField
        var lastFocusRequestID = -1

        init(_ parent: AppKitSearchTextField) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            updateSearchText(editor.string)
        }

        fileprivate func updateSearchText(_ value: String) {
            if parent.text != value {
                parent.text = value
            }
        }
    }
}

private final class IMESearchTextView: NSTextView {
    var placeholder = "Search"
    var onTextChange: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureAppearance()
    }

    override init(frame frameRect: NSRect) {
        // Let AppKit create and connect the text storage, layout manager, and
        // container. A hand-built TextKit 1 stack can leave a lazy attribute
        // run in an invalid state on newer AppKit versions.
        super.init(frame: frameRect)
        configureAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureAppearance() {
        isRichText = false
        isEditable = true
        isSelectable = true
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        minSize = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainerInset = .zero
        font = NSFont.systemFont(ofSize: 16, weight: .medium)
        textColor = NSColor.white.withAlphaComponent(0.95)
        insertionPointColor = .white
        backgroundColor = .clear
        allowsUndo = true
        typingAttributes = [
            .font: font as Any,
            .foregroundColor: textColor as Any
        ]
    }

    func setSearchText(_ value: String) {
        guard !hasMarkedText() else { return }
        guard string != value else { return }

        // Replace the whole value with one fully attributed string. This keeps
        // externally synchronized values valid before AppKit lays them out,
        // without changing the storage during a draw pass.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: textColor as Any
        ]
        textStorage?.setAttributedString(
            NSAttributedString(string: value, attributes: attributes)
        )
        typingAttributes = attributes
    }

    override func layout() {
        super.layout()
        // NSTextView defaults to a top-aligned text container. Center the
        // single-line editor in the 44pt glass search field so the glyphs and
        // insertion caret align with the surrounding toolbar buttons.
        let lineHeight = max(font?.boundingRectForFont.height ?? 19, 1)
        textContainerInset = NSSize(
            width: 0,
            height: max(0, (bounds.height - lineHeight) * 0.5)
        )
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        onTextChange?(string)
        needsDisplay = true
    }

    override func setMarkedText(
        _ markedText: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            markedText,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        // NSTextView may not send textDidChange while composition is active.
        // Report the value only after AppKit has finished mutating its storage.
        onTextChange?(string)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Keep single-line container width in sync with the view.
        if let textContainer, textContainer.containerSize.width != newSize.width {
            textContainer.containerSize = NSSize(
                width: max(newSize.width, 1),
                height: textContainer.containerSize.height
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let size = placeholder.size(withAttributes: attributes)
        let y = max(0, (bounds.height - size.height) / 2)
        placeholder.draw(at: NSPoint(x: 0, y: y), withAttributes: attributes)
    }
}

// MARK: - Page indicator

private struct PageIndicator: View {
    @ObservedObject var store: AppStore

    var body: some View {
        // Hide when searching or single page.
        if store.pageCount > 1 && !store.isSearching {
            HStack(spacing: 8) {
                ForEach(0..<store.pageCount, id: \.self) { page in
                    Capsule(style: .continuous)
                        .fill(page == store.currentPage ? Color.white : Color.white.opacity(0.32))
                        .frame(
                            width: page == store.currentPage ? 20 : 7,
                            height: 7
                        )
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.currentPage)
                        .onTapGesture {
                            store.goToPage(page)
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if #available(macOS 26.0, *) {
                    Capsule(style: .continuous)
                        .fill(.clear)
                        .glassEffect(.clear, in: Capsule(style: .continuous))
                } else {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.55)
                        .overlay(Capsule(style: .continuous).fill(Color.white.opacity(0.04)))
                }
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }
}
