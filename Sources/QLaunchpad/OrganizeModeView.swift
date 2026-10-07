import AppKit
import QuartzCore

private enum OrganizerColor {
    static let background = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
    static let card = NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.22, alpha: 1.0)
    static let cardBorder = NSColor.white.withAlphaComponent(0.18)
    static let stroke = NSColor.white.withAlphaComponent(0.12)
    static let primary = NSColor.white
    static let secondary = NSColor(calibratedWhite: 0.78, alpha: 1.0)
    static let accent = NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.94, alpha: 1)
    static let folderPlate = NSColor(calibratedRed: 0.22, green: 0.25, blue: 0.31, alpha: 1.0)
    static let folderPlateBorder = NSColor.white.withAlphaComponent(0.24)
    static let danger = NSColor(calibratedRed: 0.92, green: 0.35, blue: 0.35, alpha: 1)
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        guard let tinted = copy() as? NSImage else { return self }
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}

@MainActor
private final class OrganizerIconCache {
    private var images: [String: NSImage] = [:]

    func image(for app: AppInfo, requester: NSView? = nil) -> NSImage? {
        let key = app.url.path
        if let image = images[key] { return image }
        let source = NSWorkspace.shared.icon(forFile: key)
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 128, height: 128)
        image.isTemplate = false
        images[key] = image
        return image
    }
}

/// Full-screen page overview shown above the normal Metal launchpad.
@MainActor
final class OrganizeModeView: NSView {
    private let title = NSTextField(labelWithString: L10n.tr("organize.title"))
    private let hint = NSTextField(labelWithString: L10n.tr("organize.hint"))
    private let freePlacementToggle = NSButton(
        title: L10n.tr("settings.freePlacement"),
        target: nil,
        action: nil
    )
    private let done = NSButton(title: L10n.tr("organize.done"), target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let iconCache = OrganizerIconCache()
    private let canvas: OrganizeCanvasView
    private let bottomPanel: OrganizeBottomHiddenPanel
    private let dragOverlay: OrganizeDragOverlayView
    private let store: AppStore
    private let onClose: () -> Void
    private var folderModal: OrganizeFolderModalView?

    init(store: AppStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        canvas = OrganizeCanvasView(store: store, iconCache: iconCache)
        bottomPanel = OrganizeBottomHiddenPanel(store: store, iconCache: iconCache)
        dragOverlay = OrganizeDragOverlayView(store: store, iconCache: iconCache)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = OrganizerColor.primary
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = OrganizerColor.secondary
        freePlacementToggle.setButtonType(.switch)
        freePlacementToggle.controlSize = .large
        freePlacementToggle.font = .systemFont(ofSize: 13, weight: .medium)
        freePlacementToggle.state = UserDefaults.standard.bool(forKey: AppStore.freePlacementEnabledKey) ? .on : .off
        freePlacementToggle.target = self
        freePlacementToggle.action = #selector(toggleFreePlacement)
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.font = .systemFont(ofSize: 14, weight: .medium)
        done.contentTintColor = OrganizerColor.primary
        done.target = self
        done.action = #selector(close)
        scrollView.wantsLayer = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = OrganizerColor.background
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = OrganizerColor.background
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.backgroundColor = OrganizerColor.background.cgColor
        scrollView.contentView.layer?.isOpaque = true
        scrollView.layer?.backgroundColor = OrganizerColor.background.cgColor
        scrollView.layer?.isOpaque = true
        scrollView.layer?.masksToBounds = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        addSubview(scrollView)
        bottomPanel.layer?.masksToBounds = true
        addSubview(bottomPanel)
        addSubview(dragOverlay)
        addSubview(title)
        addSubview(hint)
        addSubview(freePlacementToggle)
        addSubview(done)
        updateBackground()

        canvas.onOpenFolder = { [weak self] folder in
            self?.openFolderManager(folder)
        }
        canvas.onClose = { [weak self] in
            self?.close()
        }

        canvas.isPointOverHideAction = { [weak self] pointInWindow in
            self?.bottomPanel.isPointInPanel(pointInWindow) ?? false
        }

        canvas.onHoverHideActionChanged = { [weak self] hovered in
            self?.bottomPanel.isDropTargetActive = hovered
        }

        canvas.onHideItems = { [weak self] items in
            self?.store.organizeHideItems(items)
            self?.bottomPanel.refreshState()
        }

        canvas.onDragUpdate = { [weak self] isDragging, items, loc, isOverHide in
            if isDragging {
                self?.dragOverlay.updateDrag(items: items, locationInWindow: loc, isOverHideAction: isOverHide)
            } else {
                self?.dragOverlay.clearDrag()
            }
        }

        bottomPanel.onHideAll = { [weak self] in
            guard let self else { return }
            self.closeFolderManager()
            let allItemIDs = Set(self.store.launchpadItems.map(\.id))
            let allVisibleAppIDs = Set(self.store.apps.map(\.id)).subtracting(self.store.hiddenAppIDs)
            self.store.organizeHideItems(allItemIDs.union(allVisibleAppIDs))
            self.bottomPanel.refreshState()
            self.canvas.clearSelection()
            self.canvas.resize(to: self.scrollView.contentSize)
            self.canvas.needsDisplay = true
        }

        bottomPanel.onUnhideAll = { [weak self] in
            guard let self else { return }
            self.closeFolderManager()
            self.store.organizeUnhideItems(Array(self.store.hiddenAppIDs))
            self.bottomPanel.refreshState()
            self.canvas.clearSelection()
            self.canvas.resize(to: self.scrollView.contentSize)
            self.canvas.needsDisplay = true
        }

        bottomPanel.onUnhideSingle = { [weak self] appID in
            guard let self else { return }
            self.store.organizeUnhideItems([appID])
            self.bottomPanel.refreshState()
            self.canvas.resize(to: self.scrollView.contentSize)
            self.canvas.needsDisplay = true
        }

        bottomPanel.onDragItemsFromShelf = { [weak self] appIDs, loc in
            guard let self else { return }
            let apps = appIDs.compactMap { id in self.store.apps.first(where: { $0.id == id }) }
            guard !apps.isEmpty else { return }
            let items = apps.map { LaunchpadItem.app($0) }
            self.dragOverlay.updateDrag(items: items, locationInWindow: loc, isOverHideAction: false)
            self.canvas.showExternalDrag(apps: apps, locationInWindow: loc)
        }

        bottomPanel.onDragUpdateFromShelf = { [weak self] loc in
            guard let self else { return }
            self.dragOverlay.updateLocation(locationInWindow: loc)
            self.canvas.updateExternalDrag(locationInWindow: loc)
        }

        bottomPanel.onEndDragFromShelf = { [weak self] loc in
            guard let self else { return }
            self.dragOverlay.clearDrag()
            if let result = self.canvas.endExternalDrag(locationInWindow: loc) {
                switch result {
                case .addToFolder(let appIDs, let folderID):
                    self.store.organizeUnhideItemsIntoFolder(appIDs, folderID: folderID)
                case .createFolder(let appIDs, let targetAppID):
                    self.store.organizeUnhideItemsCreatingFolder(appIDs, targetAppID: targetAppID)
                case .placeIntoSlot(let appIDs, let slot, let isInsertion):
                    self.store.organizeUnhideItems(appIDs, toSlot: slot, isInsertion: isInsertion)
                }
            }
            self.bottomPanel.refreshState()
            self.canvas.resize(to: self.scrollView.contentSize)
            self.canvas.needsDisplay = true
        }

        bottomPanel.onExternalDragCancel = { [weak self] in
            guard let self else { return }
            self.dragOverlay.clearDrag()
            self.canvas.cancelExternalDrag()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutChanged),
            name: .qlaunchpadStoreChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutChanged),
            name: .qlaunchpadGridLayoutChanged,
            object: nil
        )

        bottomPanel.refreshState()
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let folderModal, !folderModal.isHidden {
            return folderModal.hitTest(point)
        }
        if done.frame.contains(local) {
            return done.hitTest(point)
        }
        if freePlacementToggle.frame.contains(local) {
            return freePlacementToggle.hitTest(point)
        }
        if bottomPanel.frame.contains(local) {
            return bottomPanel.hitTest(point)
        }
        if scrollView.frame.contains(local) {
            return scrollView.hitTest(point)
        }
        return super.hitTest(point)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            if let folderModal, !folderModal.isHidden {
                closeFolderManager()
                return
            }
            if !canvas.selectedIDs.isEmpty {
                canvas.clearSelection()
                return
            }
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 88
        let bottomPanelHeight: CGFloat = 116
        let headerCenterY = bounds.height - headerHeight / 2
        let doneWidth: CGFloat = 100
        let doneHeight: CGFloat = 36
        let doneX = bounds.width - 32 - doneWidth
        freePlacementToggle.frame = CGRect(
            x: doneX - 16 - 240,
            y: headerCenterY - 18,
            width: 240,
            height: 36
        )
        let titleWidth = max(140, freePlacementToggle.frame.minX - 52)
        title.frame = CGRect(x: 32, y: bounds.height - 47, width: titleWidth, height: 32)
        hint.frame = CGRect(x: 33, y: bounds.height - 68, width: titleWidth, height: 18)
        done.frame = CGRect(x: doneX, y: headerCenterY - doneHeight / 2, width: doneWidth, height: doneHeight)

        bottomPanel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bottomPanelHeight)
        scrollView.frame = CGRect(
            x: 0,
            y: bottomPanelHeight,
            width: bounds.width,
            height: max(0, bounds.height - headerHeight - bottomPanelHeight)
        )
        canvas.resize(to: scrollView.contentSize)
        dragOverlay.frame = bounds
        folderModal?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: 0, y: bounds.height - 88))
        separator.line(to: CGPoint(x: bounds.width, y: bounds.height - 88))
        OrganizerColor.stroke.setStroke()
        separator.lineWidth = 1
        separator.stroke()
    }

    @objc private func close() { onClose() }

    @objc private func toggleFreePlacement() {
        UserDefaults.standard.set(
            freePlacementToggle.state == .on,
            forKey: AppStore.freePlacementEnabledKey
        )
        if freePlacementToggle.state == .on {
            store.enableFreePlacementForOrganizing()
        } else {
            NotificationCenter.default.post(name: .qlaunchpadGridLayoutChanged, object: nil)
        }
    }

    @objc private func layoutChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.freePlacementToggle.state = UserDefaults.standard.bool(forKey: AppStore.freePlacementEnabledKey) ? .on : .off
            self.canvas.resize(to: self.scrollView.contentSize)
            self.canvas.needsDisplay = true
            self.bottomPanel.refreshState()
            self.folderModal?.refreshFromStore()
        }
    }

    private func updateBackground() {
        layer?.backgroundColor = OrganizerColor.background.cgColor
        layer?.isOpaque = true
        layer?.masksToBounds = true
    }

    private func openFolderManager(_ folder: AppFolder) {
        folderModal?.removeFromSuperview()
        let modal = OrganizeFolderModalView(
            folder: folder,
            store: store,
            iconCache: iconCache
        ) { [weak self] in
            self?.closeFolderManager()
        }
        modal.frame = bounds
        modal.autoresizingMask = [.width, .height]
        addSubview(modal)
        folderModal = modal
        window?.makeFirstResponder(modal)
    }

    private func closeFolderManager() {
        folderModal?.removeFromSuperview()
        folderModal = nil
        canvas.needsDisplay = true
    }
}

// MARK: - Bottom Hidden Panel & Shelf

@MainActor
private final class OrganizeBottomHiddenPanel: NSView {
    private let store: AppStore
    private let iconCache: OrganizerIconCache

    private let titleIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: L10n.tr("organize.action.hide"))
    private let countBadge = NSTextField(labelWithString: "")
    private let hideAllButton = NSButton()
    private let unhideAllButton = NSButton()

    private let emptyDropZone = OrganizeEmptyDropZone()
    private let scrollView = NSScrollView()
    private let shelfGridView: HiddenShelfGridView

    var onHideAll: (() -> Void)?
    var onUnhideAll: (() -> Void)?
    var onUnhideSingle: ((String) -> Void)?
    var onDragItemsFromShelf: ((_ appIDs: [String], _ locationInWindow: CGPoint) -> Void)?
    var onDragUpdateFromShelf: ((_ locationInWindow: CGPoint) -> Void)?
    var onEndDragFromShelf: ((_ locationInWindow: CGPoint) -> Void)?
    var onExternalDragCancel: (() -> Void)?

    var isDropTargetActive: Bool = false {
        didSet {
            if oldValue != isDropTargetActive {
                emptyDropZone.isDropTargetActive = isDropTargetActive
                shelfGridView.isDropTargetActive = isDropTargetActive
                needsDisplay = true
            }
        }
    }

    init(store: AppStore, iconCache: OrganizerIconCache) {
        self.store = store
        self.iconCache = iconCache
        self.shelfGridView = HiddenShelfGridView(store: store, iconCache: iconCache)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.058, blue: 0.072, alpha: 0.98).cgColor
        layer?.masksToBounds = true

        setupUI()
    }

    required init?(coder: NSCoder) { nil }

    private func setupUI() {
        if let sym = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil) {
            titleIcon.image = sym.tinted(with: OrganizerColor.primary.withAlphaComponent(0.85))
        }
        addSubview(titleIcon)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = OrganizerColor.primary
        addSubview(titleLabel)

        countBadge.font = .systemFont(ofSize: 11, weight: .bold)
        countBadge.textColor = OrganizerColor.secondary
        addSubview(countBadge)

        hideAllButton.title = L10n.tr("organize.action.hide.hideAll")
        hideAllButton.bezelStyle = .inline
        hideAllButton.isBordered = false
        hideAllButton.contentTintColor = OrganizerColor.secondary
        hideAllButton.font = .systemFont(ofSize: 12, weight: .medium)
        hideAllButton.target = self
        hideAllButton.action = #selector(handleHideAll)
        addSubview(hideAllButton)

        unhideAllButton.title = L10n.tr("organize.action.hide.unhideAll")
        unhideAllButton.bezelStyle = .inline
        unhideAllButton.isBordered = false
        unhideAllButton.contentTintColor = OrganizerColor.accent
        unhideAllButton.font = .systemFont(ofSize: 12, weight: .medium)
        unhideAllButton.target = self
        unhideAllButton.action = #selector(handleUnhideAll)
        addSubview(unhideAllButton)

        addSubview(emptyDropZone)

        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = shelfGridView
        addSubview(scrollView)

        shelfGridView.isPointInPanel = { [weak self] loc in
            self?.isPointInPanel(loc) ?? false
        }

        shelfGridView.onUnhide = { [weak self] appID in
            self?.onUnhideSingle?(appID)
        }

        shelfGridView.onDragItemsFromShelf = { [weak self] appIDs, loc in
            self?.onDragItemsFromShelf?(appIDs, loc)
        }
        shelfGridView.onDragUpdateFromShelf = { [weak self] loc in
            self?.onDragUpdateFromShelf?(loc)
        }
        shelfGridView.onEndDragFromShelf = { [weak self] loc in
            self?.onEndDragFromShelf?(loc)
        }
        shelfGridView.onExternalDragCancel = { [weak self] in
            self?.onExternalDragCancel?()
        }
    }

    func isPointInPanel(_ pointInWindow: NSPoint) -> Bool {
        let local = convert(pointInWindow, from: nil)
        return bounds.contains(local)
    }

    func refreshState() {
        let hiddenIDs = store.hiddenAppIDs
        let count = hiddenIDs.count
        let visibleCount = store.apps.filter { !hiddenIDs.contains($0.id) }.count
        countBadge.stringValue = "(\(count))"
        unhideAllButton.isHidden = (count == 0)
        hideAllButton.isHidden = (visibleCount == 0)

        if count == 0 {
            emptyDropZone.isHidden = false
            scrollView.isHidden = true
            emptyDropZone.refreshState()
        } else {
            emptyDropZone.isHidden = true
            scrollView.isHidden = false
            shelfGridView.update(appIDs: store.orderedHiddenApps.map(\.id))
        }
        needsLayout = true
        needsDisplay = true
    }

    @objc private func handleHideAll() {
        onHideAll?()
    }

    @objc private func handleUnhideAll() {
        onUnhideAll?()
    }

    override func layout() {
        super.layout()
        let padX: CGFloat = 24
        let headerY = bounds.height - 24
        titleIcon.frame = CGRect(x: padX, y: headerY + 1, width: 14, height: 14)
        titleLabel.frame = CGRect(x: padX + 20, y: headerY, width: 90, height: 16)
        countBadge.frame = CGRect(x: padX + 112, y: headerY, width: 40, height: 16)

        let spacing: CGFloat = 14
        var currentRight = bounds.width - padX

        if !unhideAllButton.isHidden {
            let unhideW = max(64, unhideAllButton.intrinsicContentSize.width + 8)
            unhideAllButton.frame = CGRect(x: currentRight - unhideW, y: headerY - 2, width: unhideW, height: 20)
            currentRight -= (unhideW + spacing)
        }

        if !hideAllButton.isHidden {
            let hideW = max(64, hideAllButton.intrinsicContentSize.width + 8)
            hideAllButton.frame = CGRect(x: currentRight - hideW, y: headerY - 2, width: hideW, height: 20)
            currentRight -= (hideW + spacing)
        }

        let contentRect = CGRect(x: padX, y: 8, width: bounds.width - padX * 2, height: bounds.height - 36)
        emptyDropZone.frame = contentRect
        scrollView.frame = contentRect
        shelfGridView.updateHeight(contentRect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: 0, y: bounds.height - 0.5))
        separator.line(to: CGPoint(x: bounds.width, y: bounds.height - 0.5))
        OrganizerColor.stroke.setStroke()
        separator.lineWidth = 1
        separator.stroke()
    }
}

// MARK: - Empty Drop Zone

@MainActor
private final class OrganizeEmptyDropZone: NSView {
    var isDropTargetActive: Bool = false {
        didSet {
            if oldValue != isDropTargetActive {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }

    func refreshState() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)

        if isDropTargetActive {
            OrganizerColor.danger.withAlphaComponent(0.18).setFill()
            path.fill()
            OrganizerColor.danger.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.035).setFill()
            path.fill()
            OrganizerColor.stroke.setStroke()
            path.lineWidth = 1
            let dashes: [CGFloat] = [6, 4]
            path.setLineDash(dashes, count: dashes.count, phase: 0)
            path.stroke()
        }

        let hintText = isDropTargetActive ? L10n.tr("organize.action.hide.dropHint") : L10n.tr("organize.action.hide.hint")
        let color = isDropTargetActive ? OrganizerColor.danger : OrganizerColor.secondary

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let textSize = (hintText as NSString).size(withAttributes: attr)

        let iconSize: CGFloat = 18
        let totalW = iconSize + 8 + textSize.width
        let startX = (bounds.width - totalW) / 2
        let centerY = bounds.height / 2

        let iconRect = CGRect(x: startX, y: centerY - iconSize / 2, width: iconSize, height: iconSize)
        if let icon = NSImage(systemSymbolName: isDropTargetActive ? "eye.slash.fill" : "eye.slash", accessibilityDescription: nil) {
            let tinted = icon.tinted(with: color)
            tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let textPoint = CGPoint(x: startX + iconSize + 8, y: centerY - textSize.height / 2)
        (hintText as NSString).draw(at: textPoint, withAttributes: attr)
    }
}

// MARK: - Hidden Shelf Grid

@MainActor
private final class HiddenShelfGridView: NSView {
    private var appIDs: [String] = []
    private let store: AppStore
    private let iconCache: OrganizerIconCache

    var onUnhide: ((String) -> Void)?
    var onDragItemsFromShelf: ((_ appIDs: [String], _ locationInWindow: CGPoint) -> Void)?
    var onDragUpdateFromShelf: ((_ locationInWindow: CGPoint) -> Void)?
    var onEndDragFromShelf: ((_ locationInWindow: CGPoint) -> Void)?
    var onExternalDragCancel: (() -> Void)?
    var isPointInPanel: ((NSPoint) -> Bool)?

    var isDropTargetActive: Bool = false {
        didSet {
            if oldValue != isDropTargetActive {
                needsDisplay = true
            }
        }
    }

    private let cellWidth: CGFloat = 68
    private var cellHeight: CGFloat = 76

    private var selectedIDs = Set<String>()
    private var clickedIndex: Int?
    private var dragStartPoint: CGPoint = .zero
    private var didDrag = false
    private var isExternalDragging = false
    private var dropInsertIndex: Int?

    private var isMarqueeSelecting = false
    private var marqueeStart: CGPoint = .zero
    private var marqueeCurrent: CGPoint = .zero
    private var marqueeBaseSelection = Set<String>()

    private var hoveredIndex: Int?

    init(store: AppStore, iconCache: OrganizerIconCache) {
        self.store = store
        self.iconCache = iconCache
        super.init(frame: .zero)
        wantsLayer = true
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateHeight(_ height: CGFloat) {
        self.cellHeight = height
        updateSize()
    }

    func update(appIDs: [String]) {
        self.appIDs = appIDs
        selectedIDs = selectedIDs.filter { appIDs.contains($0) }
        updateSize()
        needsDisplay = true
    }

    private func updateSize() {
        let width = max(CGFloat(appIDs.count) * cellWidth + 16, 1)
        if frame.size != CGSize(width: width, height: cellHeight) {
            frame.size = CGSize(width: width, height: cellHeight)
        }
    }

    private func cellRect(for index: Int) -> CGRect {
        CGRect(
            x: 8 + CGFloat(index) * cellWidth,
            y: 0,
            width: cellWidth,
            height: cellHeight
        )
    }

    private func iconRect(in cell: CGRect) -> CGRect {
        let size: CGFloat = 40
        return CGRect(
            x: cell.midX - size / 2,
            y: 4,
            width: size,
            height: size
        )
    }

    private func unhideButtonRect(in cell: CGRect) -> CGRect {
        let icon = iconRect(in: cell)
        return CGRect(
            x: icon.maxX - 8,
            y: icon.minY - 4,
            width: 18,
            height: 18
        )
    }

    private func itemIndex(at point: CGPoint) -> Int? {
        for (i, _) in appIDs.enumerated() {
            if cellRect(for: i).contains(point) {
                return i
            }
        }
        return nil
    }

    private func selectionRect(from start: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func insertionIndex(at x: CGFloat) -> Int {
        guard !appIDs.isEmpty else { return 0 }
        for i in 0..<appIDs.count {
            let cell = cellRect(for: i)
            if x < cell.midX {
                return i
            }
        }
        return appIDs.count
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHovered = itemIndex(at: point)
        if newHovered != hoveredIndex {
            hoveredIndex = newHovered
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil {
            hoveredIndex = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        didDrag = false
        isExternalDragging = false
        dropInsertIndex = nil
        clickedIndex = nil

        for (i, id) in appIDs.enumerated() {
            let cell = cellRect(for: i)
            if unhideButtonRect(in: cell).contains(point) {
                onUnhide?(id)
                return
            }
        }

        let hasModifiers = !event.modifierFlags.intersection([.command, .shift]).isEmpty

        if let idx = itemIndex(at: point) {
            clickedIndex = idx
            dragStartPoint = point
            let appID = appIDs[idx]
            if hasModifiers {
                if selectedIDs.contains(appID) {
                    selectedIDs.remove(appID)
                } else {
                    selectedIDs.insert(appID)
                }
            } else {
                if !selectedIDs.contains(appID) {
                    selectedIDs = [appID]
                }
            }
        } else {
            clickedIndex = nil
            isMarqueeSelecting = true
            marqueeStart = point
            marqueeCurrent = point
            marqueeBaseSelection = hasModifiers ? selectedIDs : []
            selectedIDs = marqueeBaseSelection
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isMarqueeSelecting {
            if !didDrag && hypot(point.x - marqueeStart.x, point.y - marqueeStart.y) > 4 {
                didDrag = true
            }
            marqueeCurrent = point
            if didDrag {
                let rect = selectionRect(from: marqueeStart, to: marqueeCurrent)
                var newSelection = marqueeBaseSelection
                for (i, id) in appIDs.enumerated() {
                    let cell = cellRect(for: i)
                    if cell.intersects(rect) {
                        newSelection.insert(id)
                    }
                }
                selectedIDs = newSelection
            }
            needsDisplay = true
            return
        }

        guard let _ = clickedIndex else { return }
        if !didDrag && hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y) > 4 {
            didDrag = true
        }
        guard didDrag else { return }

        let inPanel = isPointInPanel?(event.locationInWindow) ?? false
        if inPanel {
            if isExternalDragging {
                isExternalDragging = false
                onExternalDragCancel?()
            }
            dropInsertIndex = insertionIndex(at: point.x)
        } else {
            dropInsertIndex = nil
            let movingIDs = appIDs.filter { selectedIDs.contains($0) }
            let itemsToDrag = movingIDs.isEmpty ? (clickedIndex.map { [appIDs[$0]] } ?? []) : movingIDs
            if !isExternalDragging {
                isExternalDragging = true
                onDragItemsFromShelf?(itemsToDrag, event.locationInWindow)
            } else {
                onDragUpdateFromShelf?(event.locationInWindow)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isMarqueeSelecting {
            isMarqueeSelecting = false
            didDrag = false
            needsDisplay = true
            return
        }

        let inPanel = isPointInPanel?(event.locationInWindow) ?? false
        if didDrag {
            if inPanel, let insertIdx = dropInsertIndex {
                let movingIDs = appIDs.filter { selectedIDs.contains($0) }
                if !movingIDs.isEmpty {
                    var remaining = appIDs.filter { !selectedIDs.contains($0) }
                    let targetPos = min(insertIdx, appIDs.count)
                    let actualInsertIndex = appIDs.prefix(targetPos).filter { !selectedIDs.contains($0) }.count
                    remaining.insert(contentsOf: movingIDs, at: min(actualInsertIndex, remaining.count))
                    self.appIDs = remaining
                    self.store.reorderHiddenApps(remaining)
                }
            } else if isExternalDragging || !inPanel {
                onEndDragFromShelf?(event.locationInWindow)
                selectedIDs.removeAll()
            }
        } else {
            if let idx = clickedIndex, event.modifierFlags.intersection([.command, .shift]).isEmpty {
                selectedIDs = [appIDs[idx]]
            }
        }

        didDrag = false
        isExternalDragging = false
        dropInsertIndex = nil
        clickedIndex = nil
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = itemIndex(at: point), appIDs.indices.contains(idx) else { return nil }
        let appID = appIDs[idx]
        guard let app = store.app(withID: appID) else { return nil }

        let menu = NSMenu(title: app.name)
        let unhideItem = menu.addItem(
            withTitle: L10n.tr("organize.action.hide.unhide"),
            action: #selector(handleMenuUnhide(_:)),
            keyEquivalent: ""
        )
        unhideItem.representedObject = appID
        unhideItem.target = self

        menu.addItem(.separator())

        let openItem = menu.addItem(
            withTitle: L10n.tr("common.open"),
            action: #selector(handleMenuOpen(_:)),
            keyEquivalent: ""
        )
        openItem.representedObject = app
        openItem.target = self

        let revealItem = menu.addItem(
            withTitle: L10n.tr("common.revealInFinder"),
            action: #selector(handleMenuReveal(_:)),
            keyEquivalent: ""
        )
        revealItem.representedObject = app
        revealItem.target = self

        let infoItem = menu.addItem(
            withTitle: L10n.tr("context.showInfo"),
            action: #selector(handleMenuShowInfo(_:)),
            keyEquivalent: ""
        )
        infoItem.representedObject = app
        infoItem.target = self

        menu.addItem(.separator())

        let iconImageItem = NSMenuItem(title: L10n.tr("context.iconImage"), action: nil, keyEquivalent: "")
        let iconImageMenu = NSMenu(title: L10n.tr("context.iconImage"))
        let currentSizeItem = NSMenuItem(
            title: L10n.tr("context.downloadCurrentIcon"),
            action: #selector(handleMenuDownloadCurrentIcon(_:)),
            keyEquivalent: ""
        )
        currentSizeItem.target = self
        currentSizeItem.representedObject = app
        iconImageMenu.addItem(currentSizeItem)

        let maximumSizeItem = NSMenuItem(
            title: L10n.tr("context.downloadMaximumIcon"),
            action: #selector(handleMenuDownloadMaximumIcon(_:)),
            keyEquivalent: ""
        )
        maximumSizeItem.target = self
        maximumSizeItem.representedObject = app
        iconImageMenu.addItem(maximumSizeItem)
        iconImageItem.submenu = iconImageMenu
        menu.addItem(iconImageItem)

        return menu
    }

    @objc private func handleMenuUnhide(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? String else { return }
        onUnhide?(appID)
    }

    @objc private func handleMenuOpen(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        NotificationCenter.default.post(
            name: .qlaunchpadDismiss,
            object: nil,
            userInfo: ["openingAppID": app.id]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            QLaunchAppLauncher.open(app)
        }
        store.recordAppLaunch(app)
    }

    @objc private func handleMenuReveal(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    @objc private func handleMenuShowInfo(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        let bundle = Bundle(url: app.url)
        let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? L10n.tr("common.unknown")
        let alert = NSAlert()
        alert.messageText = app.name
        alert.informativeText = L10n.tr("context.appInfo", version, app.bundleIdentifier, app.url.path)
        alert.icon = NSWorkspace.shared.icon(forFile: app.url.path)
        alert.addButton(withTitle: L10n.tr("common.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func handleMenuDownloadCurrentIcon(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        exportAppIcon(for: app, pixelSize: AppIconExporter.currentPixelSize)
    }

    @objc private func handleMenuDownloadMaximumIcon(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        exportAppIcon(for: app, pixelSize: AppIconExporter.maximumPixelSize(for: app))
    }

    private func exportAppIcon(for app: AppInfo, pixelSize: Int) {
        do {
            _ = try AppIconExporter.exportPNG(for: app, pixelSize: pixelSize)
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.tr("error.icon.download")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.tr("common.ok"))
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isDropTargetActive {
            let activeRect = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: activeRect, xRadius: 8, yRadius: 8)
            OrganizerColor.danger.withAlphaComponent(0.12).setFill()
            path.fill()
            OrganizerColor.danger.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        for (i, id) in appIDs.enumerated() {
            guard let app = store.apps.first(where: { $0.id == id }) else { continue }
            let cell = cellRect(for: i)
            guard cell.intersects(dirtyRect) else { continue }

            let isSelected = selectedIDs.contains(id)
            if isSelected {
                let selRect = cell.insetBy(dx: 2, dy: 2)
                let selPath = NSBezierPath(roundedRect: selRect, xRadius: 8, yRadius: 8)
                OrganizerColor.accent.withAlphaComponent(0.24).setFill()
                selPath.fill()
                OrganizerColor.accent.setStroke()
                selPath.lineWidth = 1.5
                selPath.stroke()
            }

            let icon = iconRect(in: cell)
            let isBeingDraggedOut = isExternalDragging && isSelected
            let alpha: CGFloat = isBeingDraggedOut ? 0.25 : 1.0

            let iconImg = iconCache.image(for: app, requester: self)
            iconImg?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)

            let labelRect = CGRect(x: cell.minX + 2, y: icon.maxY + 3, width: cell.width - 4, height: 22)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            (app.name as NSString).draw(in: labelRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: OrganizerColor.primary.withAlphaComponent(alpha * 0.9),
                .paragraphStyle: paragraph
            ])

            if !isBeingDraggedOut {
                let btnRect = unhideButtonRect(in: cell)
                let isHovered = hoveredIndex == i
                let btnAlpha: CGFloat = isHovered ? 1.0 : 0.6
                if let plusImg = NSImage(systemSymbolName: "arrow.uturn.backward.circle.fill", accessibilityDescription: nil) {
                    let tinted = plusImg.tinted(with: OrganizerColor.accent)
                    tinted.draw(in: btnRect, from: .zero, operation: .sourceOver, fraction: btnAlpha, respectFlipped: true, hints: nil)
                }
            }
        }

        if let insertIdx = dropInsertIndex {
            let insertX: CGFloat = {
                if insertIdx <= 0 {
                    return 8
                } else if insertIdx >= appIDs.count {
                    return cellRect(for: appIDs.count - 1).maxX + 4
                } else {
                    return cellRect(for: insertIdx).minX - 1
                }
            }()
            let barRect = CGRect(x: insertX - 1.5, y: 6, width: 3, height: cellHeight - 12)
            let bar = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            OrganizerColor.accent.setFill()
            bar.fill()

            let topDot = NSBezierPath(ovalIn: CGRect(x: insertX - 3.5, y: 3, width: 7, height: 7))
            let botDot = NSBezierPath(ovalIn: CGRect(x: insertX - 3.5, y: cellHeight - 10, width: 7, height: 7))
            topDot.fill()
            botDot.fill()
        }

        if isMarqueeSelecting && didDrag {
            let rect = selectionRect(from: marqueeStart, to: marqueeCurrent)
            OrganizerColor.accent.withAlphaComponent(0.12).setFill()
            rect.fill()
            OrganizerColor.accent.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Drag Overlay

@MainActor
private final class OrganizeDragOverlayView: NSView {
    private let store: AppStore
    private let iconCache: OrganizerIconCache
    private var items: [LaunchpadItem] = []
    private var dragLocation: CGPoint = .zero
    private var isOverHideAction: Bool = false

    init(store: AppStore, iconCache: OrganizerIconCache) {
        self.store = store
        self.iconCache = iconCache
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    func updateDrag(items: [LaunchpadItem], locationInWindow: CGPoint, isOverHideAction: Bool) {
        self.items = items
        self.dragLocation = convert(locationInWindow, from: nil)
        self.isOverHideAction = isOverHideAction
        self.isHidden = items.isEmpty
        needsDisplay = true
    }

    func updateLocation(locationInWindow: CGPoint) {
        self.dragLocation = convert(locationInWindow, from: nil)
        needsDisplay = true
    }

    func clearDrag() {
        self.items = []
        self.isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !items.isEmpty else { return }

        let iconSize: CGFloat = 56
        let center = dragLocation

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.set()

        let count = items.count
        let stackCount = min(count, 3)
        for i in (0..<stackCount).reversed() {
            let offset = CGFloat(i) * 4
            let rect = CGRect(
                x: center.x - iconSize / 2 + offset,
                y: center.y - iconSize / 2 - offset,
                width: iconSize,
                height: iconSize
            )
            let item = items[i]
            if case .folder(let folder) = item {
                drawFolderIcon(folder: folder, in: rect)
            } else if case .app(let app) = item, let img = iconCache.image(for: app, requester: self) {
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.95, respectFlipped: false, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        if isOverHideAction {
            let badgeSize: CGFloat = 24
            let badgeRect = CGRect(
                x: center.x + iconSize / 2 - 8,
                y: center.y + iconSize / 2 - 12,
                width: badgeSize,
                height: badgeSize
            )
            let badgeBg = NSBezierPath(ovalIn: badgeRect)
            OrganizerColor.danger.setFill()
            badgeBg.fill()
            NSColor.white.setStroke()
            badgeBg.lineWidth = 1.5
            badgeBg.stroke()

            if let eye = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil) {
                let tinted = eye.tinted(with: .white)
                tinted.draw(in: badgeRect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        } else if count > 1 {
            let countText = "\(count)"
            let font = NSFont.systemFont(ofSize: 11, weight: .bold)
            let textSize = (countText as NSString).size(withAttributes: [.font: font])
            let badgeW = max(20, textSize.width + 8)
            let badgeH: CGFloat = 18
            let badgeRect = CGRect(
                x: center.x + iconSize / 2 - badgeW / 2,
                y: center.y + iconSize / 2 - badgeH / 2,
                width: badgeW,
                height: badgeH
            )
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeH / 2, yRadius: badgeH / 2)
            OrganizerColor.accent.setFill()
            badgePath.fill()
            NSColor.white.setStroke()
            badgePath.lineWidth = 1
            badgePath.stroke()

            let textRect = CGRect(
                x: badgeRect.minX + (badgeW - textSize.width) / 2,
                y: badgeRect.minY + (badgeH - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (countText as NSString).draw(in: textRect, withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white
            ])
        }
    }

    private func drawFolderIcon(folder: AppFolder, in rect: CGRect) {
        let plate = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        OrganizerColor.folderPlate.setFill()
        plate.fill()
        OrganizerColor.folderPlateBorder.setStroke()
        plate.lineWidth = 1
        plate.stroke()

        if let sym = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
            let tinted = sym.tinted(with: OrganizerColor.primary)
            tinted.draw(in: rect.insetBy(dx: 10, dy: 10), from: .zero, operation: .sourceOver, fraction: 0.8, respectFlipped: false, hints: nil)
        }
    }
}

// MARK: - Drag Target Definitions

private enum DragHoverTarget: Equatable {
    case slot(Int)
    case insertion(targetSlot: Int, after: Bool)
    case folderGroup(targetID: String, targetSlot: Int, isFolder: Bool)
    case hideAction
}

@MainActor
private final class OrganizeCanvasView: NSView {
    private enum DragState {
        case idle
        case marquee(start: CGPoint, current: CGPoint, baseSelection: Set<String>)
        case draggingIcons(anchorID: String, start: CGPoint, current: CGPoint, hoverTarget: DragHoverTarget?)
        case draggingPage(sourcePage: Int, start: CGPoint, current: CGPoint, targetSlot: Int)
    }

    private let store: AppStore
    private let iconCache: OrganizerIconCache
    var onOpenFolder: ((AppFolder) -> Void)?
    var onDragUpdate: ((_ isDragging: Bool, _ items: [LaunchpadItem], _ pointInWindow: CGPoint, _ isOverHideAction: Bool) -> Void)?
    var onHideItems: ((Set<String>) -> Void)?
    var isPointOverHideAction: ((NSPoint) -> Bool)?
    var onHoverHideActionChanged: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private var externalDragItems: [AppInfo] = []
    private var externalDragHoverTarget: DragHoverTarget?

    var selectedIDs = Set<String>()
    private var dragState: DragState = .idle
    private var didDrag = false
    private var initialClickItem: LaunchpadItem?
    private var activeRenameAlert: NSAlert?

    func clearSelection() {
        selectedIDs.removeAll()
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            if !selectedIDs.isEmpty {
                clearSelection()
                return
            }
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

    private struct Motion {
        let from: CGRect
        let to: CGRect
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }
    private var iconMotions: [String: Motion] = [:]
    private var pageMotions: [Int: Motion] = [:]
    private var animationTimer: Timer?

    private let outerMargin: CGFloat = 36
    private let cardWidth: CGFloat = 500
    private let cardHeight: CGFloat = 400
    private let gap: CGFloat = 28
    private let pageHeaderHeight: CGFloat = 40

    init(store: AppStore, iconCache: OrganizerIconCache) {
        self.store = store
        self.iconCache = iconCache
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = OrganizerColor.background.cgColor
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    deinit { animationTimer?.invalidate() }

    private var pageCount: Int { max(store.pageCount, 1) }
    private var cardCount: Int {
        pageCount + (GridLayoutPreset.current.isInfiniteCanvas ? 0 : 1)
    }
    private var columns: Int {
        max(1, Int((bounds.width - outerMargin * 2 + gap) / (cardWidth + gap)))
    }

    func resize(to viewport: CGSize) {
        let width = max(viewport.width, 1)
        let cols = max(1, Int((width - outerMargin * 2 + gap) / (cardWidth + gap)))
        let rows = Int(ceil(Double(cardCount) / Double(cols)))
        let height = max(viewport.height, outerMargin * 2 + CGFloat(rows) * cardHeight
            + CGFloat(max(rows - 1, 0)) * gap)
        if frame.size != CGSize(width: width, height: height) {
            frame.size = CGSize(width: width, height: height)
        }
        needsDisplay = true
    }

    // MARK: - External Drag Handling (from bottom shelf)

    enum ExternalDropResult {
        case addToFolder(appIDs: [String], folderID: String)
        case createFolder(appIDs: [String], targetAppID: String)
        case placeIntoSlot(appIDs: [String], slot: Int, isInsertion: Bool)
    }

    func showExternalDrag(apps: [AppInfo], locationInWindow: CGPoint) {
        externalDragItems = apps
        updateExternalDrag(locationInWindow: locationInWindow)
    }

    func updateExternalDrag(locationInWindow: CGPoint) {
        let point = convert(locationInWindow, from: nil)
        if let groupTarget = groupingTarget(at: point, excluding: []) {
            externalDragHoverTarget = .folderGroup(targetID: groupTarget.item.id, targetSlot: groupTarget.slot, isFolder: groupTarget.isFolder)
        } else if let target = dropTarget(at: point, excluding: []) {
            externalDragHoverTarget = target
        } else {
            externalDragHoverTarget = nil
        }
        needsDisplay = true
    }

    func endExternalDrag(locationInWindow: CGPoint) -> ExternalDropResult? {
        guard !externalDragItems.isEmpty else {
            cancelExternalDrag()
            return nil
        }
        let ids = externalDragItems.map(\.id)
        defer { cancelExternalDrag() }
        let point = convert(locationInWindow, from: nil)

        if let groupTarget = groupingTarget(at: point, excluding: []) {
            if groupTarget.isFolder {
                return .addToFolder(appIDs: ids, folderID: groupTarget.item.id)
            } else {
                return .createFolder(appIDs: ids, targetAppID: groupTarget.item.id)
            }
        }

        guard let target = dropTarget(at: point, excluding: []) else { return nil }
        switch target {
        case .slot(let slot):
            return .placeIntoSlot(appIDs: ids, slot: slot, isInsertion: false)
        case .insertion(let slot, let after):
            return .placeIntoSlot(appIDs: ids, slot: slot + (after ? 1 : 0), isInsertion: true)
        case .folderGroup(let targetID, _, let isFolder):
            if isFolder {
                return .addToFolder(appIDs: ids, folderID: targetID)
            } else {
                return .createFolder(appIDs: ids, targetAppID: targetID)
            }
        case .hideAction:
            return nil
        }
    }

    func cancelExternalDrag() {
        externalDragItems = []
        externalDragHoverTarget = nil
        needsDisplay = true
    }

    // MARK: - Stable Coordinate Computations

    private func baseCardRect(_ slotIndex: Int) -> CGRect {
        let cols = columns
        let row = slotIndex / cols
        let column = slotIndex % cols
        let totalWidth = CGFloat(cols) * cardWidth + CGFloat(cols - 1) * gap
        let left = max(outerMargin, (bounds.width - totalWidth) / 2)
        return CGRect(
            x: left + CGFloat(column) * (cardWidth + gap),
            y: outerMargin + CGFloat(row) * (cardHeight + gap),
            width: cardWidth,
            height: cardHeight
        )
    }

    private func visualCardRect(_ page: Int) -> CGRect {
        if case .draggingPage(let source, let start, let current, let destination) = dragState {
            if source == page {
                let offset = CGPoint(x: current.x - start.x, y: current.y - start.y)
                return baseCardRect(page).offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -4, dy: -3)
            }
            return baseCardRect(pageTargetPosition(for: page, source: source, destination: destination))
        }
        if let motion = pageMotions[page] {
            return interpolatedRect(motion)
        }
        return baseCardRect(page)
    }

    private func headerRect(forCardRect card: CGRect) -> CGRect {
        CGRect(x: card.minX, y: card.minY, width: card.width, height: pageHeaderHeight)
    }

    private func gridRect(forCardRect card: CGRect) -> CGRect {
        let sideMargin: CGFloat = 16
        let topMargin: CGFloat = pageHeaderHeight + 4
        let bottomMargin: CGFloat = 12
        return CGRect(
            x: card.minX + sideMargin,
            y: card.minY + topMargin,
            width: max(1, card.width - sideMargin * 2),
            height: max(1, card.height - topMargin - bottomMargin)
        )
    }

    private var gridColumns: Int { GridLayoutPreset.current.columns }
    private var gridRows: Int {
        GridLayoutPreset.current.exportedRows(itemCount: store.launchpadItems.count)
    }

    private func iconRect(slot: Int, card: CGRect? = nil) -> CGRect {
        let capacity = max(store.pageCapacity, 1)
        let page = slot / capacity
        let local = slot % capacity
        let cardFrame = card ?? visualCardRect(page)
        let grid = gridRect(forCardRect: cardFrame)
        let cellWidth = grid.width / CGFloat(max(gridColumns, 1))
        let cellHeight = grid.height / CGFloat(max(gridRows, 1))
        let labelHeight = min(14, max(9, cellHeight * 0.23))
        let iconSize = max(6, min(56, cellWidth * 0.76, cellHeight - labelHeight - 5))
        let groupHeight = iconSize + labelHeight + 2
        return CGRect(
            x: grid.minX + CGFloat(local % gridColumns) * cellWidth + (cellWidth - iconSize) / 2,
            y: grid.minY + CGFloat(local / gridColumns) * cellHeight + (cellHeight - groupHeight) / 2,
            width: iconSize,
            height: iconSize
        )
    }

    private func labelRect(slot: Int, card: CGRect? = nil) -> CGRect {
        let icon = iconRect(slot: slot, card: card)
        let page = slot / max(store.pageCapacity, 1)
        let cardFrame = card ?? visualCardRect(page)
        let grid = gridRect(forCardRect: cardFrame)
        let cellWidth = grid.width / CGFloat(max(gridColumns, 1))
        let cellHeight = grid.height / CGFloat(max(gridRows, 1))
        return CGRect(
            x: icon.midX - cellWidth * 0.49,
            y: icon.maxY + 2,
            width: cellWidth * 0.98,
            height: min(15, max(8, cellHeight * 0.24))
        )
    }

    private func iconHitRect(slot: Int, card: CGRect? = nil) -> CGRect {
        iconRect(slot: slot, card: card).insetBy(dx: -1, dy: -1)
    }

    // MARK: - Hit Testing & Target Slot Computation

    private func itemAndHitSlot(at point: CGPoint) -> (item: LaunchpadItem, slot: Int)? {
        for (index, item) in store.launchpadItems.enumerated() {
            let slot = store.slot(for: item, fallback: index)
            let page = slot / max(store.pageCapacity, 1)
            guard page < cardCount else { continue }
            let card = visualCardRect(page)
            if iconHitRect(slot: slot, card: card).contains(point) {
                return (item, slot)
            }
        }
        return nil
    }

    private func groupingTarget(at point: CGPoint, excluding: Set<String>) -> (item: LaunchpadItem, slot: Int, isFolder: Bool)? {
        let isAnchorFolder: Bool = {
            if let firstID = excluding.first,
               let item = store.launchpadItems.first(where: { $0.id == firstID }),
               case .folder = item {
                return true
            }
            return false
        }()

        for (index, item) in store.launchpadItems.enumerated() {
            guard !excluding.contains(item.id) else { continue }
            let itemSlot = store.slot(for: item, fallback: index)
            let page = itemSlot / max(store.pageCapacity, 1)
            guard page < cardCount else { continue }
            let card = visualCardRect(page)
            let icon = iconRect(slot: itemSlot, card: card)
            if icon.contains(point) {
                switch item {
                case .folder:
                    return (item, itemSlot, true)
                case .app:
                    if isAnchorFolder { return nil }
                    return (item, itemSlot, false)
                }
            }
        }
        return nil
    }

    private func pageTargetSlot(for center: CGPoint) -> Int {
        var bestSlot = 0
        var bestDist = CGFloat.infinity
        for p in 0..<pageCount {
            let base = baseCardRect(p)
            let dist = hypot(center.x - base.midX, center.y - base.midY)
            if dist < bestDist {
                bestDist = dist
                bestSlot = p
            }
        }
        return bestSlot
    }

    private func pageTargetPosition(for page: Int, source: Int, destination: Int) -> Int {
        guard destination != source else { return page }
        if source < destination && page > source && page <= destination { return page - 1 }
        if destination < source && page >= destination && page < source { return page + 1 }
        return page
    }

    private func dropTarget(at point: CGPoint, excluding selectedIDs: Set<String>) -> DragHoverTarget? {
        var bestPage: Int?
        var bestDist = CGFloat.infinity
        for p in 0..<cardCount {
            let rect = baseCardRect(p)
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let dist = hypot(dx, dy)
            if dist < bestDist {
                bestDist = dist
                bestPage = p
            }
        }
        guard let page = bestPage, bestDist <= 120 else { return nil }
        let grid = gridRect(forCardRect: baseCardRect(page))
        let clampedX = min(max(point.x, grid.minX), grid.maxX - 0.01)
        let clampedY = min(max(point.y, grid.minY), grid.maxY - 0.01)
        let col = min(gridColumns - 1, max(0, Int((clampedX - grid.minX) / grid.width * CGFloat(gridColumns))))
        let row = min(gridRows - 1, max(0, Int((clampedY - grid.minY) / grid.height * CGFloat(gridRows))))
        let slot = page * store.pageCapacity + row * gridColumns + col

        guard let target = store.launchpadItems.enumerated().first(where: { index, item in
            !selectedIDs.contains(item.id) && store.slot(for: item, fallback: index) == slot
        }) else {
            return .slot(slot)
        }

        let targetSlot = store.slot(for: target.element, fallback: target.offset)
        let card = baseCardRect(page)
        let group = iconRect(slot: targetSlot, card: card).union(labelRect(slot: targetSlot, card: card))
        let cellWidth = grid.width / CGFloat(max(gridColumns, 1))
        let cellHeight = grid.height / CGFloat(max(gridRows, 1))
        let dx = point.x - group.midX
        let dy = point.y - group.midY
        let horizontalDistance = abs(dx) / cellWidth
        let verticalDistance = abs(dy) / cellHeight
        let after = horizontalDistance >= verticalDistance ? dx >= 0 : dy >= 0
        return .insertion(targetSlot: targetSlot, after: after)
    }

    // MARK: - Animations

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, target: self,
                          selector: #selector(tickAnimation), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    @objc private func tickAnimation() {
        let now = CACurrentMediaTime()
        iconMotions = iconMotions.filter { now - $0.value.start < $0.value.duration }
        pageMotions = pageMotions.filter { now - $0.value.start < $0.value.duration }
        let isAutoScrolling = autoScrollIfNeeded()
        needsDisplay = true
        if iconMotions.isEmpty && pageMotions.isEmpty && !isAutoScrolling && !didDrag {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func interpolatedRect(_ motion: Motion) -> CGRect {
        let t = CGFloat(min(max((CACurrentMediaTime() - motion.start) / motion.duration, 0), 1))
        let ease = 1 - pow(1 - t, 3)
        return CGRect(
            x: motion.from.origin.x + (motion.to.origin.x - motion.from.origin.x) * ease,
            y: motion.from.origin.y + (motion.to.origin.y - motion.from.origin.y) * ease,
            width: motion.from.size.width + (motion.to.size.width - motion.from.size.width) * ease,
            height: motion.from.size.height + (motion.to.size.height - motion.from.size.height) * ease
        )
    }

    private func autoScrollIfNeeded() -> Bool {
        guard didDrag, let scroll = enclosingScrollView else {
            return false
        }
        let clip = scroll.contentView
        let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? .zero
        let mouseInScroll = scroll.convert(mouseInWindow, from: nil)
        guard scroll.bounds.contains(mouseInScroll) else { return false }
        if isPointOverHideAction?(mouseInWindow) == true {
            return false
        }
        let edgeZone: CGFloat = 60
        let visible = clip.documentVisibleRect
        var delta: CGFloat = 0
        if mouseInScroll.y > scroll.bounds.maxY - edgeZone {
            delta = -(mouseInScroll.y - (scroll.bounds.maxY - edgeZone)) * 0.4
        } else if mouseInScroll.y < scroll.bounds.minY + edgeZone {
            delta = (scroll.bounds.minY + edgeZone - mouseInScroll.y) * 0.4
        }
        guard delta != 0 else { return false }
        let newY = min(max(visible.origin.y + delta, 0), bounds.height - visible.height)
        guard newY != visible.origin.y else { return false }
        clip.scroll(to: CGPoint(x: visible.minX, y: newY))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        iconMotions.removeAll()
        pageMotions.removeAll()
        onHoverHideActionChanged?(false)
        onDragUpdate?(false, [], .zero, false)
        let point = convert(event.locationInWindow, from: nil)
        didDrag = false
        initialClickItem = nil

        // 1. Check card header drag
        for page in 0..<pageCount {
            let card = baseCardRect(page)
            if headerRect(forCardRect: card).contains(point) {
                dragState = .draggingPage(sourcePage: page, start: point, current: point, targetSlot: page)
                needsDisplay = true
                return
            }
        }

        // 2. Check icon or label click
        if let hit = itemAndHitSlot(at: point) {
            initialClickItem = hit.item
            let hasModifiers = !event.modifierFlags.intersection([.command, .shift]).isEmpty
            if hasModifiers {
                if selectedIDs.contains(hit.item.id) {
                    selectedIDs.remove(hit.item.id)
                } else {
                    selectedIDs.insert(hit.item.id)
                }
            } else {
                if !selectedIDs.contains(hit.item.id) {
                    selectedIDs = [hit.item.id]
                }
            }
            if selectedIDs.contains(hit.item.id) {
                dragState = .draggingIcons(anchorID: hit.item.id, start: point, current: point, hoverTarget: nil)
            } else {
                dragState = .idle
            }
        } else {
            // 3. Blank canvas: marquee selection
            let hasModifiers = !event.modifierFlags.intersection([.command, .shift]).isEmpty
            let base = hasModifiers ? selectedIDs : []
            selectedIDs = base
            dragState = .marquee(start: point, current: point, baseSelection: base)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch dragState {
        case .idle:
            break

        case .marquee(let start, _, let base):
            if !didDrag && hypot(point.x - start.x, point.y - start.y) > 4 { didDrag = true }
            dragState = .marquee(start: start, current: point, baseSelection: base)
            if didDrag {
                let rect = selectionRect(from: start, to: point)
                var newSelection = base
                for (index, item) in store.launchpadItems.enumerated() {
                    let slot = store.slot(for: item, fallback: index)
                    let page = slot / max(store.pageCapacity, 1)
                    guard page < cardCount else { continue }
                    let card = visualCardRect(page)
                    if iconHitRect(slot: slot, card: card).intersects(rect) {
                        newSelection.insert(item.id)
                    }
                }
                selectedIDs = newSelection
            }

        case .draggingIcons(let anchorID, let start, _, _):
            if !didDrag && hypot(point.x - start.x, point.y - start.y) > 4 { didDrag = true }
            let hoverTarget: DragHoverTarget?
            let windowPoint = event.locationInWindow
            let isOverHide = isPointOverHideAction?(windowPoint) ?? false
            if didDrag {
                if isOverHide {
                    hoverTarget = .hideAction
                } else if let groupTarget = groupingTarget(at: point, excluding: selectedIDs) {
                    hoverTarget = .folderGroup(targetID: groupTarget.item.id, targetSlot: groupTarget.slot, isFolder: groupTarget.isFolder)
                } else if let target = dropTarget(at: point, excluding: selectedIDs) {
                    hoverTarget = target
                } else {
                    hoverTarget = nil
                }
            } else {
                hoverTarget = nil
            }
            dragState = .draggingIcons(anchorID: anchorID, start: start, current: point, hoverTarget: hoverTarget)
            onHoverHideActionChanged?(hoverTarget == .hideAction)
            if didDrag {
                let draggedItems = store.launchpadItems.filter { selectedIDs.contains($0.id) }
                onDragUpdate?(true, draggedItems, windowPoint, hoverTarget == .hideAction)
            }

        case .draggingPage(let source, let start, _, _):
            if !didDrag && hypot(point.x - start.x, point.y - start.y) > 4 { didDrag = true }
            let draggedCenter = baseCardRect(source).offsetBy(
                dx: point.x - start.x,
                dy: point.y - start.y
            ).center
            let targetSlot = pageTargetSlot(for: draggedCenter)
            dragState = .draggingPage(sourcePage: source, start: start, current: point, targetSlot: targetSlot)
        }

        if didDrag {
            startAnimationTimer()
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if !didDrag {
            if let clicked = initialClickItem {
                if case .folder(let folder) = clicked {
                    onOpenFolder?(folder)
                    initialClickItem = nil
                    dragState = .idle
                    return
                }
                if event.modifierFlags.intersection([.command, .shift]).isEmpty {
                    selectedIDs = [clicked.id]
                }
            }
        } else {
            switch dragState {
            case .draggingIcons(let anchorID, let start, _, let hoverTarget):
                onHoverHideActionChanged?(false)
                onDragUpdate?(false, [], .zero, false)
                switch hoverTarget {
                case .hideAction:
                    let itemsToHide = selectedIDs
                    selectedIDs.removeAll()
                    onHideItems?(itemsToHide)
                    resize(to: enclosingScrollView?.contentSize ?? bounds.size)
                    needsDisplay = true

                case .folderGroup(let targetID, _, let isFolder):
                    let isAnchorFolder: Bool = {
                        if let item = store.launchpadItems.first(where: { $0.id == anchorID }),
                           case .folder = item { return true }
                        return false
                    }()
                    if isFolder && isAnchorFolder {
                        store.mergeFolder(sourceID: anchorID, into: targetID)
                    } else if isFolder {
                        for id in selectedIDs {
                            store.organizeMoveAppIntoFolder(appID: id, folderID: targetID)
                        }
                    } else {
                        if selectedIDs.count > 1 {
                            store.organizeCreateFolder(with: Array(selectedIDs), targetID: targetID)
                        } else {
                            store.organizeCreateFolder(draggedID: anchorID, targetID: targetID)
                        }
                    }
                    selectedIDs.removeAll()
                    resize(to: enclosingScrollView?.contentSize ?? bounds.size)
                    needsDisplay = true

                case .slot(let destination):
                    animateIconDrop(anchorID: anchorID, start: start, current: point, destination: destination)

                case .insertion(let targetSlot, let after):
                    animateIconDrop(
                        anchorID: anchorID,
                        start: start,
                        current: point,
                        destination: targetSlot + (after ? 1 : 0)
                    )

                case nil:
                    animateIconReturn(start: start, current: point)
                }

            case .draggingPage(let source, let start, _, _):
                let draggedCenter = baseCardRect(source).offsetBy(
                    dx: point.x - start.x,
                    dy: point.y - start.y
                ).center
                let destination = pageTargetSlot(for: draggedCenter)
                dragState = .draggingPage(
                    sourcePage: source,
                    start: start,
                    current: point,
                    targetSlot: destination
                )
                animatePageDrop(source: source, destination: destination)

            case .marquee, .idle:
                break
            }
        }

        onHoverHideActionChanged?(false)
        onDragUpdate?(false, [], .zero, false)
        dragState = .idle
        didDrag = false
        initialClickItem = nil
        resize(to: enclosingScrollView?.contentSize ?? bounds.size)
        needsDisplay = true
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = itemAndHitSlot(at: point) else { return nil }

        if !selectedIDs.contains(hit.item.id) {
            selectedIDs = [hit.item.id]
            needsDisplay = true
        }

        if selectedIDs.count > 1 {
            return makeSelectionContextMenu(selectedIDs: selectedIDs)
        }

        switch hit.item {
        case .folder(let folder):
            return makeFolderContextMenu(for: folder)
        case .app(let app):
            return makeAppContextMenu(for: app)
        }
    }

    private func makeAppContextMenu(for app: AppInfo) -> NSMenu {
        let menu = NSMenu(title: app.name)

        let openItem = menu.addItem(
            withTitle: L10n.tr("common.open"),
            action: #selector(contextOpenApp(_:)),
            keyEquivalent: ""
        )
        openItem.representedObject = app
        openItem.target = self

        let revealItem = menu.addItem(
            withTitle: L10n.tr("common.revealInFinder"),
            action: #selector(contextRevealApp(_:)),
            keyEquivalent: ""
        )
        revealItem.representedObject = app
        revealItem.target = self

        let infoItem = menu.addItem(
            withTitle: L10n.tr("context.showInfo"),
            action: #selector(contextShowAppInfo(_:)),
            keyEquivalent: ""
        )
        infoItem.representedObject = app
        infoItem.target = self

        menu.addItem(.separator())

        let iconImageItem = NSMenuItem(title: L10n.tr("context.iconImage"), action: nil, keyEquivalent: "")
        let iconImageMenu = NSMenu(title: L10n.tr("context.iconImage"))
        let currentSizeItem = NSMenuItem(
            title: L10n.tr("context.downloadCurrentIcon"),
            action: #selector(contextDownloadAppIconCurrentSize(_:)),
            keyEquivalent: ""
        )
        currentSizeItem.target = self
        currentSizeItem.representedObject = app
        iconImageMenu.addItem(currentSizeItem)

        let maximumSizeItem = NSMenuItem(
            title: L10n.tr("context.downloadMaximumIcon"),
            action: #selector(contextDownloadAppIconMaximumSize(_:)),
            keyEquivalent: ""
        )
        maximumSizeItem.target = self
        maximumSizeItem.representedObject = app
        iconImageMenu.addItem(maximumSizeItem)
        iconImageItem.submenu = iconImageMenu
        menu.addItem(iconImageItem)

        menu.addItem(.separator())

        let currentFolderID = store.folderContaining(appID: app.id)?.id
        let moveToFolderItem = NSMenuItem(title: L10n.tr("context.moveToFolder"), action: nil, keyEquivalent: "")
        let folderSubmenu = NSMenu(title: L10n.tr("context.moveToFolder"))
        for folder in store.orderedFolders {
            let item = NSMenuItem(
                title: folder.name,
                action: #selector(contextMoveAppToFolder(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = (appID: app.id, folderID: folder.id)
            item.isEnabled = folder.id != currentFolderID
            folderSubmenu.addItem(item)
        }
        moveToFolderItem.submenu = folderSubmenu
        moveToFolderItem.isEnabled = store.allowsUserLayoutEditing && !store.orderedFolders.isEmpty
        menu.addItem(moveToFolderItem)

        if currentFolderID != nil {
            let removeItem = menu.addItem(
                withTitle: L10n.tr("context.removeFromFolder"),
                action: #selector(contextRemoveAppFromFolder(_:)),
                keyEquivalent: ""
            )
            removeItem.target = self
            removeItem.representedObject = app
            removeItem.isEnabled = store.allowsUserLayoutEditing
        }

        menu.addItem(.separator())

        let hideItem = menu.addItem(
            withTitle: L10n.tr("common.hide"),
            action: #selector(contextHideApp(_:)),
            keyEquivalent: ""
        )
        hideItem.target = self
        hideItem.representedObject = app
        hideItem.isEnabled = !store.hiddenAppIDs.contains(app.id)

        return menu
    }

    private func makeFolderContextMenu(for folder: AppFolder) -> NSMenu {
        let menu = NSMenu(title: folder.name)

        let openItem = menu.addItem(
            withTitle: L10n.tr("launchpad.folder"),
            action: #selector(contextOpenFolder(_:)),
            keyEquivalent: ""
        )
        openItem.representedObject = folder
        openItem.target = self

        let renameItem = menu.addItem(
            withTitle: L10n.tr("common.rename"),
            action: #selector(contextRenameFolder(_:)),
            keyEquivalent: ""
        )
        renameItem.representedObject = folder
        renameItem.target = self

        let mergeItem = NSMenuItem(title: L10n.tr("context.mergeIntoFolder"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.tr("context.mergeIntoFolder"))
        for target in store.orderedFolders where target.id != folder.id {
            let item = NSMenuItem(
                title: target.name,
                action: #selector(contextMergeFolder(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = (sourceID: folder.id, targetID: target.id)
            submenu.addItem(item)
        }
        mergeItem.submenu = submenu
        mergeItem.isEnabled = !submenu.items.isEmpty
        menu.addItem(mergeItem)

        menu.addItem(.separator())

        let dissolveItem = menu.addItem(
            withTitle: L10n.tr("context.dissolveFolder"),
            action: #selector(contextDissolveFolder(_:)),
            keyEquivalent: ""
        )
        dissolveItem.representedObject = folder
        dissolveItem.target = self

        return menu
    }

    private func makeSelectionContextMenu(selectedIDs: Set<String>) -> NSMenu {
        let menu = NSMenu(title: "")
        let canEdit = store.allowsUserLayoutEditing

        let create = menu.addItem(
            withTitle: L10n.tr("context.createFolder"),
            action: #selector(contextCreateFolderFromSelection),
            keyEquivalent: ""
        )
        create.target = self
        create.isEnabled = canEdit

        let move = NSMenuItem(title: L10n.tr("context.moveToFolder"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.tr("context.moveToFolder"))
        for folder in store.orderedFolders {
            let item = NSMenuItem(
                title: folder.name,
                action: #selector(contextMoveSelectionToFolder(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = folder.id
            submenu.addItem(item)
        }
        move.submenu = submenu
        move.isEnabled = canEdit && !submenu.items.isEmpty
        menu.addItem(move)

        menu.addItem(.separator())

        let hideItem = menu.addItem(
            withTitle: L10n.tr("common.hide"),
            action: #selector(contextHideSelection),
            keyEquivalent: ""
        )
        hideItem.target = self
        hideItem.isEnabled = canEdit

        return menu
    }

    @objc private func contextOpenApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        NotificationCenter.default.post(
            name: .qlaunchpadDismiss,
            object: nil,
            userInfo: ["openingAppID": app.id]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            QLaunchAppLauncher.open(app)
        }
        store.recordAppLaunch(app)
    }

    @objc private func contextRevealApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    @objc private func contextShowAppInfo(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        let bundle = Bundle(url: app.url)
        let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? L10n.tr("common.unknown")
        let alert = NSAlert()
        alert.messageText = app.name
        alert.informativeText = L10n.tr("context.appInfo", version, app.bundleIdentifier, app.url.path)
        alert.icon = NSWorkspace.shared.icon(forFile: app.url.path)
        alert.addButton(withTitle: L10n.tr("common.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static var didShowIconDownloadHint = false

    @objc private func contextDownloadAppIconCurrentSize(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        exportAppIcon(for: app, pixelSize: AppIconExporter.currentPixelSize)
    }

    @objc private func contextDownloadAppIconMaximumSize(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        exportAppIcon(for: app, pixelSize: AppIconExporter.maximumPixelSize(for: app))
    }

    private func exportAppIcon(for app: AppInfo, pixelSize: Int) {
        do {
            _ = try AppIconExporter.exportPNG(for: app, pixelSize: pixelSize)
            presentFirstIconDownloadHintIfNeeded()
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.tr("error.icon.download")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.tr("common.ok"))
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func presentFirstIconDownloadHintIfNeeded() {
        guard !Self.didShowIconDownloadHint else { return }
        Self.didShowIconDownloadHint = true
        let alert = NSAlert()
        alert.messageText = L10n.tr("context.iconDownloaded")
        alert.addButton(withTitle: L10n.tr("common.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func contextMoveAppToFolder(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? (appID: String, folderID: String) else { return }
        store.organizeMoveAppIntoFolder(appID: data.appID, folderID: data.folderID)
        needsDisplay = true
    }

    @objc private func contextRemoveAppFromFolder(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo,
              let folderID = store.folderContaining(appID: app.id)?.id else { return }
        _ = store.removeAppFromFolder(appID: app.id, folderID: folderID)
        needsDisplay = true
    }

    @objc private func contextHideApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        onHideItems?([app.id])
        needsDisplay = true
    }

    @objc private func contextOpenFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? AppFolder else { return }
        onOpenFolder?(folder)
    }

    @objc private func contextRenameFolder(_ sender: NSMenuItem) {
        guard activeRenameAlert == nil,
              let folder = sender.representedObject as? AppFolder,
              let parentWindow = window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("context.renameFolder")
        alert.addButton(withTitle: L10n.tr("common.save"))
        alert.addButton(withTitle: L10n.tr("common.cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = folder.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        activeRenameAlert = alert
        alert.beginSheetModal(for: parentWindow) { [weak self] response in
            defer { self?.activeRenameAlert = nil }
            guard response == .alertFirstButtonReturn else { return }
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                self?.store.renameFolder(folder.id, to: newName)
            }
        }
        DispatchQueue.main.async { [weak self, weak alert] in
            guard let self, let alert, self.activeRenameAlert === alert else { return }
            alert.window.makeFirstResponder(input)
            if let editor = alert.window.fieldEditor(false, for: input) {
                editor.selectedRange = NSRange(location: 0, length: (input.stringValue as NSString).length)
            }
        }
    }

    @objc private func contextMergeFolder(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? (sourceID: String, targetID: String) else { return }
        store.mergeFolder(sourceID: data.sourceID, into: data.targetID)
        needsDisplay = true
    }

    @objc private func contextDissolveFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? AppFolder else { return }
        store.organizeDissolveFolder(folder.id)
    }

    @objc private func contextCreateFolderFromSelection() {
        guard !selectedIDs.isEmpty else { return }
        if selectedIDs.count > 1, let firstID = selectedIDs.first {
            store.organizeCreateFolder(with: Array(selectedIDs), targetID: firstID)
        }
        selectedIDs.removeAll()
        needsDisplay = true
    }

    @objc private func contextMoveSelectionToFolder(_ sender: NSMenuItem) {
        guard let folderID = sender.representedObject as? String, !selectedIDs.isEmpty else { return }
        for id in selectedIDs {
            store.organizeMoveAppIntoFolder(appID: id, folderID: folderID)
        }
        selectedIDs.removeAll()
        needsDisplay = true
    }

    @objc private func contextHideSelection() {
        guard !selectedIDs.isEmpty else { return }
        let itemsToHide = selectedIDs
        selectedIDs.removeAll()
        onHideItems?(itemsToHide)
        needsDisplay = true
    }

    // MARK: - Drop Animations

    private func animatePageDrop(source: Int, destination: Int) {
        let oldFrames = (0..<pageCount).map(visualCardRect)
        pageMotions.removeAll()
        if source != destination {
            store.organizeMovePage(from: source, to: destination)
        }
        resize(to: enclosingScrollView?.contentSize ?? bounds.size)
        let now = CACurrentMediaTime()
        for p in 0..<pageCount {
            let target = baseCardRect(p)
            let priorIndex: Int
            if p == destination {
                priorIndex = source
            } else if source < destination && p >= source && p < destination {
                priorIndex = p + 1
            } else if destination < source && p > destination && p <= source {
                priorIndex = p - 1
            } else {
                priorIndex = p
            }
            let from = oldFrames[priorIndex]
            if hypot(from.midX - target.midX, from.midY - target.midY) > 0.5 || abs(from.width - target.width) > 0.5 {
                pageMotions[p] = Motion(from: from, to: target, start: now, duration: 0.38)
            }
        }
        if !pageMotions.isEmpty { startAnimationTimer() }
    }

    private func animateIconDrop(anchorID: String, start: CGPoint, current: CGPoint, destination: Int) {
        let oldRects = Dictionary(uniqueKeysWithValues: store.launchpadItems.enumerated().map {
            ($0.element.id, iconRect(slot: store.slot(for: $0.element, fallback: $0.offset)))
        })
        let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
        store.organizeMoveItems(selectedIDs, anchorID: anchorID, toSlot: destination)
        resize(to: enclosingScrollView?.contentSize ?? bounds.size)
        let now = CACurrentMediaTime()
        for (index, item) in store.launchpadItems.enumerated() {
            guard let old = oldRects[item.id] else { continue }
            let target = iconRect(slot: store.slot(for: item, fallback: index))
            let from = selectedIDs.contains(item.id)
                ? old.offsetBy(dx: delta.width, dy: delta.height).insetBy(dx: -2, dy: -2)
                : old
            if hypot(from.midX - target.midX, from.midY - target.midY) > 0.5 || abs(from.width - target.width) > 0.5 {
                iconMotions[item.id] = Motion(from: from, to: target, start: now, duration: 0.32)
            }
        }
        if !iconMotions.isEmpty { startAnimationTimer() }
    }

    private func animateIconReturn(start: CGPoint, current: CGPoint) {
        let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
        let now = CACurrentMediaTime()
        for (index, item) in store.launchpadItems.enumerated() where selectedIDs.contains(item.id) {
            let target = iconRect(slot: store.slot(for: item, fallback: index))
            iconMotions[item.id] = Motion(
                from: target.offsetBy(dx: delta.width, dy: delta.height).insetBy(dx: -2, dy: -2),
                to: target,
                start: now,
                duration: 0.28
            )
        }
        if !iconMotions.isEmpty { startAnimationTimer() }
    }

    // MARK: - Drawing

    private func selectionRect(from start: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        OrganizerColor.background.setFill()
        dirtyRect.fill()

        let isDraggingIcons: Bool = if didDrag, case .draggingIcons = dragState { true } else { false }
        let isDraggingPage: Bool = if didDrag, case .draggingPage = dragState { true } else { false }
        let occupiedSlots = Set(store.launchpadItems.enumerated().map {
            store.slot(for: $0.element, fallback: $0.offset)
        })

        // Draw page cards
        var drawingOrder = Array(0..<cardCount)
        if case .draggingPage(let source, _, _, _) = dragState {
            drawingOrder.removeAll { $0 == source }
            drawingOrder.append(source)
        }

        for page in drawingOrder {
            let isNewPage = page >= pageCount
            let card = visualCardRect(page)
            guard card.insetBy(dx: -20, dy: -20).intersects(dirtyRect) else { continue }
            let isDraggedCard: Bool = {
                if isDraggingPage, case .draggingPage(let src, _, _, _) = dragState, src == page {
                    return true
                }
                return false
            }()

            // Card shadow if dragging
            if isDraggedCard {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = 14
                shadow.shadowOffset = CGSize(width: 0, height: -6)
                shadow.set()
                let cardPath = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
                OrganizerColor.card.setFill()
                cardPath.fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Card body
            let cardPath = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
            (isNewPage ? OrganizerColor.card.withAlphaComponent(0.45) : OrganizerColor.card).setFill()
            cardPath.fill()
            OrganizerColor.cardBorder.setStroke()
            cardPath.lineWidth = 1
            cardPath.stroke()

            // Page label
            let pageTitle = isNewPage
                ? L10n.tr("organize.newPage")
                : String(format: L10n.tr("organize.page"), page + 1)
            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: isNewPage ? OrganizerColor.secondary : OrganizerColor.primary
            ]
            let titleSize = (pageTitle as NSString).size(withAttributes: titleAttr)
            let titlePoint = CGPoint(
                x: card.minX + 16,
                y: card.minY + (pageHeaderHeight - titleSize.height) / 2
            )
            (pageTitle as NSString).draw(at: titlePoint, withAttributes: titleAttr)

            if !isNewPage,
               let grip = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) {
                grip.draw(
                    in: CGRect(x: card.maxX - 30, y: card.minY + 12, width: 14, height: 14),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 0.65,
                    respectFlipped: true,
                    hints: nil
                )
            }

            // Grid placeholders
            let capacity = max(store.pageCapacity, 1)
            for local in 0..<capacity {
                let slot = page * capacity + local
                guard !occupiedSlots.contains(slot) else { continue }
                let placeholder = iconRect(slot: slot, card: card).insetBy(dx: 2, dy: 2)
                let tile = NSBezierPath(roundedRect: placeholder, xRadius: 7, yRadius: 7)
                NSColor.white.withAlphaComponent(0.04).setFill()
                tile.fill()
                NSColor.white.withAlphaComponent(0.08).setStroke()
                tile.lineWidth = 0.75
                tile.stroke()
            }

            if isNewPage { continue }

            // Icons on this page
            for (index, item) in store.launchpadItems.enumerated() {
                let itemSlot = store.slot(for: item, fallback: index)
                guard itemSlot / capacity == page else { continue }
                let rect = iconMotions[item.id].map(interpolatedRect) ?? iconRect(slot: itemSlot, card: card)
                let isItemSelected = selectedIDs.contains(item.id)
                let isDraggingThisIcon = isDraggingIcons && isItemSelected

                if isItemSelected {
                    let selection = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 7, yRadius: 7)
                    OrganizerColor.accent.withAlphaComponent(0.24).setFill()
                    selection.fill()
                    OrganizerColor.accent.setStroke()
                    selection.lineWidth = 1.5
                    selection.stroke()
                }

                let label = labelRect(slot: itemSlot, card: card)
                let presentedLabel: CGRect
                if let motion = iconMotions[item.id] {
                    let current = interpolatedRect(motion)
                    presentedLabel = label.offsetBy(dx: current.midX - motion.to.midX, dy: current.minY - motion.to.minY)
                } else {
                    presentedLabel = label
                }

                let alpha: CGFloat = isDraggingThisIcon ? 0.25 : 1
                if case .folder(let folder) = item {
                    drawFolderIcon(folder: folder, in: rect, alpha: alpha)
                } else {
                    image(for: item)?.draw(
                        in: rect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: alpha,
                        respectFlipped: true,
                        hints: nil
                    )
                }
                drawLabel(for: item, in: presentedLabel, alpha: alpha)
            }
        }

        // Draw hover target indicator during icon drag (internal or from bottom shelf)
        let activeHoverTarget: DragHoverTarget? = {
            if didDrag, case .draggingIcons(_, _, _, let ht) = dragState {
                return ht
            }
            return externalDragHoverTarget
        }()
        if let target = activeHoverTarget {
            switch target {
            case .slot(let slot):
                let rect = iconRect(slot: slot).insetBy(dx: -3, dy: -3)
                let marker = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                OrganizerColor.accent.setStroke()
                marker.lineWidth = 2
                marker.stroke()

            case .insertion(let slot, let after):
                let icon = iconRect(slot: slot)
                let label = labelRect(slot: slot)
                let group = icon.union(label)
                let x = after ? group.maxX + 4 : group.minX - 4
                let marker = NSBezierPath()
                marker.move(to: CGPoint(x: x, y: group.minY - 3))
                marker.line(to: CGPoint(x: x, y: group.maxY + 3))
                OrganizerColor.accent.setStroke()
                marker.lineWidth = 3
                marker.lineCapStyle = .round
                marker.stroke()

            case .folderGroup(_, let slot, let isFolder):
                let rect = iconRect(slot: slot).insetBy(dx: -5, dy: -5)
                let marker = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
                OrganizerColor.accent.withAlphaComponent(0.32).setFill()
                marker.fill()
                OrganizerColor.accent.setStroke()
                marker.lineWidth = 2.5
                marker.stroke()

                // Floating pill badge
                let text = isFolder ? L10n.tr("context.moveToFolder") : L10n.tr("context.createFolder")
                let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
                let textSize = (text as NSString).size(withAttributes: [.font: font])
                let pillW = textSize.width + 16
                let pillH: CGFloat = 20
                let pillRect = CGRect(
                    x: rect.midX - pillW / 2,
                    y: rect.minY - pillH - 4,
                    width: pillW,
                    height: pillH
                )
                let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 10, yRadius: 10)
                NSColor(calibratedRed: 0.1, green: 0.12, blue: 0.16, alpha: 0.95).setFill()
                pillPath.fill()
                OrganizerColor.accent.setStroke()
                pillPath.lineWidth = 1
                pillPath.stroke()

                let textDrawRect = CGRect(
                    x: pillRect.minX + 8,
                    y: pillRect.minY + (pillH - textSize.height) / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                (text as NSString).draw(in: textDrawRect, withAttributes: [
                    .font: font,
                    .foregroundColor: OrganizerColor.primary
                ])

            case .hideAction:
                break
            }
        }

        // Draw marquee rectangle
        if didDrag, case .marquee(let start, let current, _) = dragState {
            let rect = selectionRect(from: start, to: current)
            OrganizerColor.accent.withAlphaComponent(0.15).setFill()
            NSBezierPath(rect: rect).fill()
            OrganizerColor.accent.setStroke()
            NSBezierPath(rect: rect).stroke()
        }

        // Draw floating dragged icons
        if onDragUpdate == nil, didDrag, case .draggingIcons(_, let start, let current, _) = dragState {
            let delta = CGSize(width: current.x - start.x, height: current.y - start.y)
            for (index, item) in store.launchpadItems.enumerated() where selectedIDs.contains(item.id) {
                let slot = store.slot(for: item, fallback: index)
                let rect = iconRect(slot: slot).offsetBy(dx: delta.width, dy: delta.height).insetBy(dx: -2, dy: -2)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                shadow.shadowBlurRadius = 8
                shadow.shadowOffset = CGSize(width: 0, height: -3)
                shadow.set()
                if case .folder(let folder) = item {
                    drawFolderIcon(folder: folder, in: rect, alpha: 0.95)
                } else {
                    image(for: item)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.95, respectFlipped: true, hints: nil)
                }
                drawLabel(for: item, in: labelRect(slot: slot).offsetBy(dx: delta.width, dy: delta.height), alpha: 0.95)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func drawFolderIcon(folder: AppFolder, in rect: CGRect, alpha: CGFloat) {
        let plate = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        OrganizerColor.folderPlate.setFill()
        plate.fill()
        OrganizerColor.folderPlateBorder.setStroke()
        plate.lineWidth = 1
        plate.stroke()

        let miniCount = min(folder.appIDs.count, 4)
        if miniCount > 0 {
            let pad: CGFloat = 3
            let miniSize = max(4, (rect.width - pad * 3) / 2)
            for i in 0..<miniCount {
                let row = i / 2
                let col = i % 2
                let miniRect = CGRect(
                    x: rect.minX + pad + CGFloat(col) * (miniSize + pad),
                    y: rect.minY + pad + CGFloat(row) * (miniSize + pad),
                    width: miniSize,
                    height: miniSize
                )
                let appID = folder.appIDs[i]
                if let app = store.app(withID: appID), let icon = image(for: .app(app)) {
                    icon.draw(in: miniRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                }
            }
        } else if let sym = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
            sym.draw(in: rect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver, fraction: alpha * 0.7, respectFlipped: true, hints: nil)
        }
    }

    private func image(for item: LaunchpadItem) -> NSImage? {
        switch item {
        case .app(let app):
            return iconCache.image(for: app, requester: self)
        case .folder:
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        }
    }

    private func drawLabel(for item: LaunchpadItem, in rect: CGRect, alpha: CGFloat) {
        let name: String
        switch item {
        case .app(let app): name = app.name
        case .folder(let folder): name = folder.name
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let fontSize = min(11, max(8, rect.height * 0.72))
        (name as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: OrganizerColor.primary.withAlphaComponent(alpha * 0.92),
            .paragraphStyle: paragraph
        ])
    }
}

// MARK: - Folder Management Modal

@MainActor
private final class OrganizerFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class FolderGridView: NSView {
    var appIDs: [String]
    private let store: AppStore
    private let iconCache: OrganizerIconCache
    private let onRemove: (String) -> Void
    private let onReorder: (Int, Int) -> Void

    private var dragSourceIndex: Int?
    private var dragCurrentPoint: CGPoint = .zero
    private var isDragging = false
    private var hoveredDropIndex: Int?

    private let cols = 4
    private let cellWidth: CGFloat = 104
    private let cellHeight: CGFloat = 90
    private let padX: CGFloat = 24
    private let padY: CGFloat = 14

    init(
        appIDs: [String],
        store: AppStore,
        iconCache: OrganizerIconCache,
        onRemove: @escaping (String) -> Void,
        onReorder: @escaping (Int, Int) -> Void
    ) {
        self.appIDs = appIDs
        self.store = store
        self.iconCache = iconCache
        self.onRemove = onRemove
        self.onReorder = onReorder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = OrganizerColor.card.cgColor
        layer?.isOpaque = true
        updateSize()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(appIDs: [String]) {
        self.appIDs = appIDs
        updateSize()
        needsDisplay = true
    }

    private func updateSize() {
        let rows = max(1, Int(ceil(Double(appIDs.count) / Double(cols))))
        let width = CGFloat(cols) * cellWidth + padX * 2
        let height = CGFloat(rows) * cellHeight + padY * 2
        frame.size = CGSize(width: width, height: height)
    }

    private func cellRect(for index: Int) -> CGRect {
        let row = index / cols
        let col = index % cols
        return CGRect(
            x: padX + CGFloat(col) * cellWidth,
            y: padY + CGFloat(row) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    private func iconRect(in cell: CGRect) -> CGRect {
        let size: CGFloat = 48
        return CGRect(
            x: cell.midX - size / 2,
            y: cell.minY + 6,
            width: size,
            height: size
        )
    }

    private func removeButtonRect(in cell: CGRect) -> CGRect {
        let icon = iconRect(in: cell)
        return CGRect(
            x: icon.maxX - 10,
            y: icon.minY - 6,
            width: 20,
            height: 20
        )
    }

    private func itemIndex(at point: CGPoint) -> Int? {
        for (i, _) in appIDs.enumerated() {
            if cellRect(for: i).contains(point) {
                return i
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (i, id) in appIDs.enumerated() {
            let cell = cellRect(for: i)
            if removeButtonRect(in: cell).contains(point) {
                onRemove(id)
                return
            }
        }
        if let idx = itemIndex(at: point) {
            dragSourceIndex = idx
            dragCurrentPoint = point
            isDragging = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragSourceIndex != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !isDragging && hypot(point.x - dragCurrentPoint.x, point.y - dragCurrentPoint.y) > 4 {
            isDragging = true
        }
        dragCurrentPoint = point
        if isDragging {
            hoveredDropIndex = itemIndex(at: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging, let source = dragSourceIndex, let dest = hoveredDropIndex, source != dest {
            onReorder(source, dest)
        }
        dragSourceIndex = nil
        hoveredDropIndex = nil
        isDragging = false
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = itemIndex(at: point), appIDs.indices.contains(idx) else { return nil }
        let appID = appIDs[idx]
        guard let app = store.app(withID: appID) else { return nil }

        let menu = NSMenu()
        let openItem = menu.addItem(
            withTitle: L10n.tr("common.open"),
            action: #selector(contextOpenApp(_:)),
            keyEquivalent: ""
        )
        openItem.representedObject = app
        openItem.target = self

        let revealItem = menu.addItem(
            withTitle: L10n.tr("common.revealInFinder"),
            action: #selector(contextRevealApp(_:)),
            keyEquivalent: ""
        )
        revealItem.representedObject = app
        revealItem.target = self

        let infoItem = menu.addItem(
            withTitle: L10n.tr("context.showInfo"),
            action: #selector(contextShowAppInfo(_:)),
            keyEquivalent: ""
        )
        infoItem.representedObject = app
        infoItem.target = self

        let iconItem = NSMenuItem(title: L10n.tr("context.iconImage"), action: nil, keyEquivalent: "")
        let iconSubmenu = NSMenu(title: L10n.tr("context.iconImage"))
        let dlCurrent = iconSubmenu.addItem(
            withTitle: L10n.tr("context.downloadCurrentIcon"),
            action: #selector(contextDownloadIconCurrent(_:)),
            keyEquivalent: ""
        )
        dlCurrent.representedObject = app
        dlCurrent.target = self

        let dlMax = iconSubmenu.addItem(
            withTitle: L10n.tr("context.downloadMaximumIcon"),
            action: #selector(contextDownloadIconMax(_:)),
            keyEquivalent: ""
        )
        dlMax.representedObject = app
        dlMax.target = self
        iconItem.submenu = iconSubmenu
        menu.addItem(iconItem)

        menu.addItem(NSMenuItem.separator())

        let remove = menu.addItem(
            withTitle: L10n.tr("context.removeFromFolder"),
            action: #selector(contextRemoveApp(_:)),
            keyEquivalent: ""
        )
        remove.representedObject = appID
        remove.target = self
        return menu
    }

    @objc private func contextOpenApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        NotificationCenter.default.post(
            name: .qlaunchpadDismiss,
            object: nil,
            userInfo: ["openingAppID": app.id]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            QLaunchAppLauncher.open(app)
        }
        store.recordAppLaunch(app)
    }

    @objc private func contextRevealApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    @objc private func contextShowAppInfo(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        let bundle = Bundle(url: app.url)
        let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? L10n.tr("common.unknown")
        let alert = NSAlert()
        alert.messageText = app.name
        alert.informativeText = L10n.tr("context.appInfo", version, app.bundleIdentifier, app.url.path)
        alert.icon = NSWorkspace.shared.icon(forFile: app.url.path)
        alert.addButton(withTitle: L10n.tr("common.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func contextDownloadIconCurrent(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        exportAppIcon(for: app, pixelSize: AppIconExporter.currentPixelSize)
    }

    @objc private func contextDownloadIconMax(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        exportAppIcon(for: app, pixelSize: AppIconExporter.maximumPixelSize(for: app))
    }

    private static var didShowIconDownloadHint = false

    private func exportAppIcon(for app: AppInfo, pixelSize: Int) {
        do {
            _ = try AppIconExporter.exportPNG(for: app, pixelSize: pixelSize)
            presentFirstIconDownloadHintIfNeeded()
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.tr("error.icon.download")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.tr("common.ok"))
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func presentFirstIconDownloadHintIfNeeded() {
        guard !Self.didShowIconDownloadHint else { return }
        Self.didShowIconDownloadHint = true
        let alert = NSAlert()
        alert.messageText = L10n.tr("context.iconDownloaded")
        alert.addButton(withTitle: L10n.tr("common.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func contextRemoveApp(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? String else { return }
        onRemove(appID)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        OrganizerColor.card.setFill()
        dirtyRect.fill()
        for (i, id) in appIDs.enumerated() {
            guard let app = store.app(withID: id) else { continue }
            let cell = cellRect(for: i)
            let icon = iconRect(in: cell)

            let isBeingDragged = isDragging && dragSourceIndex == i

            if isDragging, hoveredDropIndex == i, dragSourceIndex != i {
                let marker = NSBezierPath(roundedRect: cell.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
                OrganizerColor.accent.withAlphaComponent(0.25).setFill()
                marker.fill()
                OrganizerColor.accent.setStroke()
                marker.lineWidth = 1.5
                marker.stroke()
            }

            let alpha: CGFloat = isBeingDragged ? 0.25 : 1.0

            let iconImg = image(for: app)
            iconImg?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)

            let labelRect = CGRect(x: cell.minX + 2, y: icon.maxY + 4, width: cell.width - 4, height: 24)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            (app.name as NSString).draw(in: labelRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: OrganizerColor.primary.withAlphaComponent(alpha),
                .paragraphStyle: paragraph
            ])

            if !isBeingDragged {
                let btnRect = removeButtonRect(in: cell)
                if let minusImg = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil) {
                    let tinted = minusImg.tinted(with: NSColor.white.withAlphaComponent(0.85))
                    tinted.draw(
                        in: btnRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 0.9,
                        respectFlipped: true,
                        hints: nil
                    )
                }
            }
        }

        if isDragging, let source = dragSourceIndex, appIDs.indices.contains(source),
           let app = store.app(withID: appIDs[source]) {
            let floatSize: CGFloat = 52
            let floatRect = CGRect(
                x: dragCurrentPoint.x - floatSize / 2,
                y: dragCurrentPoint.y - floatSize / 2,
                width: floatSize,
                height: floatSize
            )
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = CGSize(width: 0, height: -3)
            shadow.set()
            image(for: app)?.draw(in: floatRect, from: .zero, operation: .sourceOver, fraction: 0.95, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func image(for app: AppInfo) -> NSImage? {
        iconCache.image(for: app, requester: self)
    }
}

@MainActor
private final class OrganizeFolderModalView: NSView, NSTextFieldDelegate {
    private let folderID: String
    private let store: AppStore
    private let iconCache: OrganizerIconCache
    private let onClose: () -> Void
    private var folder: AppFolder?

    private let cardShadowView = NSView()
    private let cardView = OrganizerFlippedView()
    private let titleField = NSTextField()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let dissolveButton = NSButton()
    private let closeButton = NSButton()
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private var gridView: FolderGridView!

    init(
        folder: AppFolder,
        store: AppStore,
        iconCache: OrganizerIconCache,
        onClose: @escaping () -> Void
    ) {
        self.folderID = folder.id
        self.store = store
        self.iconCache = iconCache
        self.onClose = onClose
        self.folder = folder
        super.init(frame: .zero)
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupUI() {
        guard let folder else { return }

        cardShadowView.wantsLayer = true
        cardShadowView.layer?.shadowColor = NSColor.black.cgColor
        cardShadowView.layer?.shadowOpacity = 0.55
        cardShadowView.layer?.shadowRadius = 28
        cardShadowView.layer?.shadowOffset = CGSize(width: 0, height: -10)
        cardShadowView.layer?.masksToBounds = false
        addSubview(cardShadowView)

        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = OrganizerColor.card.cgColor
        cardView.layer?.cornerRadius = 16
        cardView.layer?.borderColor = OrganizerColor.cardBorder.cgColor
        cardView.layer?.borderWidth = 1
        cardView.layer?.masksToBounds = true
        cardShadowView.addSubview(cardView)

        titleField.stringValue = folder.name
        titleField.placeholderString = L10n.tr("launchpad.folder")
        titleField.font = .systemFont(ofSize: 18, weight: .bold)
        titleField.textColor = OrganizerColor.primary
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.target = self
        titleField.action = #selector(titleEdited)
        titleField.delegate = self
        cardView.addSubview(titleField)

        updateSubtitle(count: folder.appIDs.count)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = OrganizerColor.secondary
        cardView.addSubview(subtitleLabel)

        dissolveButton.title = L10n.tr("context.dissolveFolder")
        dissolveButton.bezelStyle = .regularSquare
        dissolveButton.isBordered = false
        dissolveButton.wantsLayer = true
        dissolveButton.layer?.cornerRadius = 7
        dissolveButton.layer?.backgroundColor = OrganizerColor.danger.withAlphaComponent(0.16).cgColor
        dissolveButton.contentTintColor = OrganizerColor.danger
        dissolveButton.font = .systemFont(ofSize: 12, weight: .medium)
        dissolveButton.target = self
        dissolveButton.action = #selector(handleDissolve)
        cardView.addSubview(dissolveButton)

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 14
        closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(config)
        closeButton.contentTintColor = OrganizerColor.secondary
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        cardView.addSubview(closeButton)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = OrganizerColor.stroke.cgColor
        cardView.addSubview(separator)

        gridView = FolderGridView(
            appIDs: folder.appIDs,
            store: store,
            iconCache: iconCache,
            onRemove: { [weak self] appID in
                self?.removeApp(appID)
            },
            onReorder: { [weak self] src, dst in
                self?.reorderApps(from: src, to: dst)
            }
        )
        scrollView.wantsLayer = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = OrganizerColor.card
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = gridView
        cardView.addSubview(scrollView)
    }

    private func updateSubtitle(count: Int) {
        if LocalizationManager.shared.effectiveLanguage == .english && count == 1 {
            subtitleLabel.stringValue = "1 app"
        } else {
            subtitleLabel.stringValue = L10n.tr("organize.folder.appCount", count)
        }
    }

    override func layout() {
        super.layout()
        let cardWidth: CGFloat = 464
        let headerH: CGFloat = 64
        let count = folder?.appIDs.count ?? 0
        let rows = max(1, Int(ceil(Double(count) / 4.0)))
        let gridDesiredH = CGFloat(rows) * 90 + 14 * 2
        let minCardH: CGFloat = 196
        let maxCardH: CGFloat = min(bounds.height - 80, 440)
        let cardHeight: CGFloat = min(maxCardH, max(minCardH, headerH + gridDesiredH))
        let cardX = max(16, (bounds.width - cardWidth) / 2)
        let cardY = max(16, (bounds.height - cardHeight) / 2)

        cardShadowView.frame = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        cardView.frame = cardShadowView.bounds

        titleField.frame = CGRect(x: 22, y: 14, width: cardWidth - 180, height: 22)
        subtitleLabel.frame = CGRect(x: 22, y: 38, width: cardWidth - 180, height: 16)

        dissolveButton.frame = CGRect(x: cardWidth - 138, y: 18, width: 88, height: 28)
        closeButton.frame = CGRect(x: cardWidth - 42, y: 18, width: 28, height: 28)
        separator.frame = CGRect(x: 0, y: headerH - 1, width: cardWidth, height: 1)

        scrollView.frame = CGRect(x: 0, y: headerH, width: cardWidth, height: cardHeight - headerH)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.6).setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !cardShadowView.frame.contains(point) {
            onClose()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onClose()
            return
        }
        super.keyDown(with: event)
    }

    @objc private func handleClose() {
        onClose()
    }

    @objc private func handleDissolve() {
        store.organizeDissolveFolder(folderID)
        onClose()
    }

    @objc private func titleEdited() {
        let newName = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty {
            store.renameFolder(folderID, to: newName)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        titleEdited()
    }

    private func removeApp(_ appID: String) {
        store.organizeRemoveAppFromFolder(appID: appID, folderID: folderID)
        refreshFromStore()
    }

    private func reorderApps(from src: Int, to dst: Int) {
        store.moveAppInsideFolder(folderID: folderID, from: src, to: dst)
        refreshFromStore()
    }

    func refreshFromStore() {
        guard let current = store.folder(withID: folderID), current.appIDs.count > 1 else {
            if let current = store.folder(withID: folderID) {
                store.organizeDissolveFolder(current.id)
            }
            onClose()
            return
        }
        folder = current
        titleField.stringValue = current.name
        updateSubtitle(count: current.appIDs.count)
        gridView.update(appIDs: current.appIDs)
        needsLayout = true
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
