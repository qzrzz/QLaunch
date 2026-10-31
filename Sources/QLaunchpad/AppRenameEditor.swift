import AppKit

/// Shared by the main grid, organizer, hidden-app shelf and folder menus.
@MainActor
final class AppRenameEditor: NSObject, NSTextFieldDelegate {
    private weak var store: AppStore?
    private var activeSheet: NSPanel?
    private var field: NSTextField?
    private var confirmButton: NSButton?
    private var originalName = ""

    init(store: AppStore) { self.store = store }

    func addMenuItem(to menu: NSMenu, app: AppInfo, window: NSWindow?) {
        let item = menu.addItem(withTitle: L10n.tr("common.rename"), action: #selector(rename(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Context(appID: app.id, window: window)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard activeSheet == nil,
              let context = sender.representedObject as? Context,
              let parent = context.window, parent.attachedSheet == nil,
              let app = store?.app(withID: context.appID) else { return }

        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 176),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = L10n.tr("common.rename")
        sheet.isReleasedWhenClosed = false
        guard let content = sheet.contentView else { return }
        let description = NSTextField(labelWithString: L10n.tr("appRename.description"))
        description.textColor = .secondaryLabelColor
        let field = NSTextField(string: app.name)
        field.placeholderString = app.appName.original
        field.setAccessibilityLabel(L10n.tr("appRename.name"))
        field.delegate = self
        let restore = NSButton(title: L10n.tr("appRename.defaultName"), target: self, action: #selector(restoreDefault))
        let cancel = NSButton(title: L10n.tr("common.cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: L10n.tr("appRename.confirm"), target: self, action: #selector(confirm))
        confirm.keyEquivalent = "\r"
        for button in [restore, cancel, confirm] { button.bezelStyle = .rounded }

        for view in [description, field, restore, cancel, confirm] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            description.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            description.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            field.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            field.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 12),
            field.heightAnchor.constraint(equalToConstant: 26),
            restore.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            restore.centerYAnchor.constraint(equalTo: confirm.centerYAnchor),
            restore.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -16),
            confirm.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            confirm.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            confirm.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            cancel.trailingAnchor.constraint(equalTo: confirm.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: confirm.centerYAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        sheet.initialFirstResponder = field
        sheet.defaultButtonCell = confirm.cell as? NSButtonCell
        self.field = field
        self.confirmButton = confirm
        originalName = app.appName.original
        activeSheet = sheet

        parent.beginSheet(sheet) { [weak self] response in
            guard let self else { return }
            if response == .OK { self.store?.setCustomName(field.stringValue, for: context.appID) }
            self.activeSheet = nil
            self.field = nil
            self.confirmButton = nil
            parent.makeKey()
        }
        DispatchQueue.main.async { [weak self, weak sheet] in
            guard let sheet, self?.activeSheet === sheet else { return }
            sheet.makeKeyAndOrderFront(nil)
            sheet.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    @objc private func restoreDefault() {
        field?.stringValue = originalName
        confirmButton?.isEnabled = true
        activeSheet?.makeFirstResponder(field)
        field?.selectText(nil)
    }

    @objc private func cancel() { finish(.cancel) }

    @objc private func confirm() {
        guard let field, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        finish(.OK)
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let activeSheet, let parent = activeSheet.sheetParent else { return }
        parent.endSheet(activeSheet, returnCode: response)
    }

    func controlTextDidChange(_ obj: Notification) {
        confirmButton?.isEnabled = !(field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private final class Context {
        let appID: String
        weak var window: NSWindow?
        init(appID: String, window: NSWindow?) {
            self.appID = appID
            self.window = window
        }
    }
}
