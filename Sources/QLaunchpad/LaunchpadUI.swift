import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let qlaunchpadStoreChanged = Notification.Name("QLaunchpadStoreChanged")
    static let qlaunchpadDismiss = Notification.Name("QLaunchpadDismiss")
    static let qlaunchpadPresentationChanged = Notification.Name("QLaunchpadPresentationChanged")
    static let qlaunchpadFocusSearch = Notification.Name("QLaunchpadFocusSearch")
    static let qlaunchpadGridLayoutChanged = Notification.Name("QLaunchpadGridLayoutChanged")
    static let qlaunchpadIconCacheClearRequested = Notification.Name("QLaunchpadIconCacheClearRequested")
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
            VStack(spacing: 0) {
                SearchField(store: store)
                    .padding(.top, 36)
                Spacer(minLength: 0)
                PageIndicator(store: store)
                    .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid glass search field

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

/// Native `NSTextField` so placeholder color works and IME preedit (marked text)
/// is not covered or clobbered. AppKit hides `placeholderAttributedString` while
/// composing; `updateNSView` must not rewrite `stringValue` during composition.
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

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = Self.textFont
        field.textColor = Self.textColor
        field.allowsEditingTextAttributes = false
        field.isAutomaticTextCompletionEnabled = false
        field.lineBreakMode = .byTruncatingTail
        field.refusesFirstResponder = false
        field.stringValue = text
        field.placeholderAttributedString = Self.makePlaceholder(placeholder)
        field.delegate = context.coordinator
        if let cell = field.cell as? NSTextFieldCell {
            cell.isScrollable = true
            cell.wraps = false
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byTruncatingTail
            cell.placeholderAttributedString = Self.makePlaceholder(placeholder)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self

        // Critical for IME: never replace stringValue while marked text is active.
        let isComposing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !isComposing, field.stringValue != text {
            field.stringValue = text
        }

        // Re-apply attributed placeholder each update — AppKit may reset styling.
        let placeholderAttr = Self.makePlaceholder(placeholder)
        field.placeholderAttributedString = placeholderAttr
        (field.cell as? NSTextFieldCell)?.placeholderAttributedString = placeholderAttr
        field.font = Self.textFont
        field.textColor = Self.textColor

        if focusRequestID != context.coordinator.lastFocusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                // Prefer the field editor when already editing; otherwise make field first responder.
                if window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                }
                // AppKit selects the entire value when an NSTextField becomes
                // first responder programmatically. Continue typing at the end
                // instead, so the first search character we committed is kept.
                if let editor = field.currentEditor() as? NSTextView {
                    editor.setSelectedRange(NSRange(location: field.stringValue.utf16.count, length: 0))
                }
                context.coordinator.parent.isFocused = true
            }
        }
    }

    private static func makePlaceholder(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: textFont,
            .foregroundColor: placeholderColor
        ])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitSearchTextField
        var lastFocusRequestID = -1

        init(_ parent: AppKitSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // During IME composition, stringValue stays at last committed text until insert.
            // AppKit still shows marked text in the field editor and hides the placeholder.
            let value = field.stringValue
            if parent.text != value {
                parent.text = value
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused = false
        }

        /// Keep Escape / navigation available to the panel; do not swallow unhandled commands.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // Return false so AppKit / local monitors can handle Esc, etc.
            false
        }
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
