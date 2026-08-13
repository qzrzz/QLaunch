import AppKit
import SwiftUI

struct ApplicationSourceItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let iconPath: String
    let isRemovable: Bool

    static func systemDefaults() -> [ApplicationSourceItem] {
        AppScanner.defaultRoots
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { item(at: $0, isRemovable: false) }
    }

    static func custom(paths: [String]) -> [ApplicationSourceItem] {
        let defaultIDs = Set(systemDefaults().map(\.id))
        return paths
            .filter { !defaultIDs.contains($0) }
            .map { item(at: URL(fileURLWithPath: $0).standardizedFileURL, isRemovable: true) }
    }

    private static func item(at url: URL, isRemovable: Bool) -> ApplicationSourceItem {
        let path = url.path
        return ApplicationSourceItem(
            id: path,
            title: FileManager.default.displayName(atPath: path),
            subtitle: (path as NSString).abbreviatingWithTildeInPath,
            iconPath: path,
            isRemovable: isRemovable
        )
    }
}

struct ApplicationSourceList: NSViewRepresentable {
    var items: [ApplicationSourceItem]
    @Binding var selection: String?
    var isLoading: Bool
    var onAdd: () -> Void
    var onRemove: () -> Void
    var onRescan: () -> Void
    var onReveal: (ApplicationSourceItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ApplicationSourceListNSView {
        let view = ApplicationSourceListNSView()
        view.delegate = context.coordinator
        context.coordinator.apply(self, to: view)
        return view
    }

    func updateNSView(_ view: ApplicationSourceListNSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(self, to: view)
    }

    final class Coordinator: NSObject, ApplicationSourceListNSViewDelegate {
        var parent: ApplicationSourceList

        init(_ parent: ApplicationSourceList) {
            self.parent = parent
        }

        func apply(_ parent: ApplicationSourceList, to view: ApplicationSourceListNSView) {
            self.parent = parent
            view.update(
                items: parent.items,
                selection: parent.selection,
                isLoading: parent.isLoading
            )
        }

        func sourceList(_ view: ApplicationSourceListNSView, didSelect id: String?) {
            if parent.selection != id {
                parent.selection = id
            }
        }

        func sourceListDidRequestAdd(_ view: ApplicationSourceListNSView) {
            parent.onAdd()
        }

        func sourceListDidRequestRemove(_ view: ApplicationSourceListNSView) {
            parent.onRemove()
        }

        func sourceListDidRequestRescan(_ view: ApplicationSourceListNSView) {
            parent.onRescan()
        }

        func sourceList(_ view: ApplicationSourceListNSView, didReveal item: ApplicationSourceItem) {
            parent.onReveal(item)
        }
    }
}

protocol ApplicationSourceListNSViewDelegate: AnyObject {
    func sourceList(_ view: ApplicationSourceListNSView, didSelect id: String?)
    func sourceListDidRequestAdd(_ view: ApplicationSourceListNSView)
    func sourceListDidRequestRemove(_ view: ApplicationSourceListNSView)
    func sourceListDidRequestRescan(_ view: ApplicationSourceListNSView)
    func sourceList(_ view: ApplicationSourceListNSView, didReveal item: ApplicationSourceItem)
}

final class ApplicationSourceListNSView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 40
    private static let buttonBarHeight: CGFloat = 34
    private static let minVisibleRows = 3
    private static let maxVisibleRows = 5
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("ApplicationSourceCell")

    weak var delegate: ApplicationSourceListNSViewDelegate?

    private var items: [ApplicationSourceItem] = []
    private var isApplyingSelection = false

    private let scrollView = NSScrollView()
    private let tableView = ApplicationSourceTableView()
    private let separator = NSBox()
    private let buttonBar = NSView()
    private let addRemoveControl = NSSegmentedControl()
    private let spinner = NSProgressIndicator()
    private let rescanButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        configureTable()
        configureButtonBar()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        tableView.sizeLastColumnToFit()
    }

    override var intrinsicContentSize: NSSize {
        let rows = min(max(items.count, Self.minVisibleRows), Self.maxVisibleRows)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: CGFloat(rows) * Self.rowHeight + Self.buttonBarHeight
        )
    }

    func update(items: [ApplicationSourceItem], selection: String?, isLoading: Bool) {
        let itemsChanged = self.items != items
        self.items = items
        if itemsChanged {
            tableView.reloadData()
            tableView.sizeLastColumnToFit()
            invalidateIntrinsicContentSize()
        }

        isApplyingSelection = true
        if let selection, let row = items.firstIndex(where: { $0.id == selection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isApplyingSelection = false

        let canRemove = items.first(where: { $0.id == selection })?.isRemovable == true
        addRemoveControl.setEnabled(canRemove, forSegment: 1)
        rescanButton.isEnabled = !isLoading
        if isLoading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask

        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.allowsTypeSelect = true
        tableView.doubleAction = #selector(revealSelected)
        tableView.target = self
        tableView.onDelete = { [weak self] in
            self?.removeSelected()
        }
        tableView.menuForRow = { [weak self] row in
            self?.contextMenu(for: row)
        }

        scrollView.documentView = tableView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.focusRingType = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureButtonBar() {
        separator.boxType = .separator
        separator.titlePosition = .noTitle
        separator.translatesAutoresizingMaskIntoConstraints = false

        let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加应用文件夹")
        let minus = NSImage(systemSymbolName: "minus", accessibilityDescription: "移除所选文件夹")
        addRemoveControl.segmentCount = 2
        addRemoveControl.trackingMode = .momentary
        addRemoveControl.segmentStyle = .smallSquare
        addRemoveControl.controlSize = .small
        addRemoveControl.setImage(plus, forSegment: 0)
        addRemoveControl.setImage(minus, forSegment: 1)
        addRemoveControl.setWidth(28, forSegment: 0)
        addRemoveControl.setWidth(28, forSegment: 1)
        addRemoveControl.setEnabled(false, forSegment: 1)
        addRemoveControl.target = self
        addRemoveControl.action = #selector(addRemoveClicked)
        addRemoveControl.setAccessibilityLabel("添加或移除应用文件夹")
        addRemoveControl.toolTip = "添加应用文件夹，或移除所选自定义文件夹"
        addRemoveControl.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        rescanButton.title = "重新扫描"
        rescanButton.bezelStyle = .recessed
        rescanButton.controlSize = .small
        rescanButton.isBordered = false
        rescanButton.target = self
        rescanButton.action = #selector(rescanClicked)
        rescanButton.setAccessibilityLabel("重新扫描应用来源")
        rescanButton.translatesAutoresizingMaskIntoConstraints = false

        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.addSubview(addRemoveControl)
        buttonBar.addSubview(spinner)
        buttonBar.addSubview(rescanButton)

        NSLayoutConstraint.activate([
            addRemoveControl.leadingAnchor.constraint(equalTo: buttonBar.leadingAnchor, constant: 6),
            addRemoveControl.topAnchor.constraint(equalTo: buttonBar.topAnchor, constant: 6),

            rescanButton.trailingAnchor.constraint(equalTo: buttonBar.trailingAnchor, constant: -8),
            rescanButton.centerYAnchor.constraint(equalTo: addRemoveControl.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: rescanButton.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: addRemoveControl.centerYAnchor)
        ])
    }

    private func configureLayout() {
        addSubview(scrollView)
        addSubview(separator)
        addSubview(buttonBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            buttonBar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            buttonBar.heightAnchor.constraint(equalToConstant: Self.buttonBarHeight)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ApplicationSourceRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? ApplicationSourceCellView
            ?? ApplicationSourceCellView()
        cell.identifier = Self.cellIdentifier
        cell.configure(items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = tableView.selectedRow
        let id = items.indices.contains(row) ? items[row].id : nil
        addRemoveControl.setEnabled(items.first(where: { $0.id == id })?.isRemovable == true, forSegment: 1)
        delegate?.sourceList(self, didSelect: id)
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard items.indices.contains(row) else { return nil }

        let menu = NSMenu()
        let reveal = NSMenuItem(
            title: "在 Finder 中显示",
            action: #selector(revealClickedRow),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

        if items[row].isRemovable {
            menu.addItem(.separator())
            let remove = NSMenuItem(
                title: "移除",
                action: #selector(removeClickedRow),
                keyEquivalent: ""
            )
            remove.target = self
            menu.addItem(remove)
        }
        return menu
    }

    @objc private func addRemoveClicked() {
        switch addRemoveControl.selectedSegment {
        case 0:
            delegate?.sourceListDidRequestAdd(self)
        case 1:
            removeSelected()
        default:
            break
        }
    }

    @objc private func rescanClicked() {
        delegate?.sourceListDidRequestRescan(self)
    }

    @objc private func revealSelected() {
        reveal(row: tableView.selectedRow)
    }

    @objc private func revealClickedRow() {
        reveal(row: tableView.clickedRow)
    }

    @objc private func removeClickedRow() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        isApplyingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
        delegate?.sourceList(self, didSelect: items[row].id)
        removeSelected()
    }

    private func removeSelected() {
        let row = tableView.selectedRow
        guard items.indices.contains(row), items[row].isRemovable else { return }
        delegate?.sourceListDidRequestRemove(self)
    }

    private func reveal(row: Int) {
        guard items.indices.contains(row) else { return }
        delegate?.sourceList(self, didReveal: items[row])
    }
}

private final class ApplicationSourceRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 2)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let color: NSColor = isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if !isSelected {
            super.drawBackground(in: dirtyRect)
        }
    }

    override func drawSeparator(in dirtyRect: NSRect) {}
}

private final class ApplicationSourceTableView: NSTableView {
    var onDelete: (() -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?

    override func deleteBackward(_ sender: Any?) {
        onDelete?()
    }

    override func deleteForward(_ sender: Any?) {
        onDelete?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return menuForRow?(row)
    }
}

private final class ApplicationSourceCellView: NSTableCellView {
    private let subtitleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        imageView = iconView

        let titleField = NSTextField(labelWithString: "")
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleField

        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleField, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setHuggingPriority(.defaultHigh, for: .vertical)

        let stack = NSStackView(views: [iconView, textStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            subtitleField.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    func configure(_ item: ApplicationSourceItem) {
        let icon = NSWorkspace.shared.icon(forFile: item.iconPath)
        icon.size = NSSize(width: 28, height: 28)
        imageView?.image = icon
        textField?.stringValue = item.title
        subtitleField.stringValue = item.subtitle
        toolTip = item.subtitle
    }
}
