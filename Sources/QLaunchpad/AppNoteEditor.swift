import AppKit

/// One editor shared by all application menus, including the organizer.
@MainActor
final class AppNoteEditor: NSObject {
    private weak var store: AppStore?
    private var activeAlert: NSAlert?

    init(store: AppStore) {
        self.store = store
    }

    func addMenuItem(to menu: NSMenu, app: AppInfo, window: NSWindow?) {
        let item = menu.addItem(
            withTitle: L10n.tr("context.appNote"),
            action: #selector(editNote(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = Context(appID: app.id, window: window)
    }

    @objc private func editNote(_ sender: NSMenuItem) {
        guard activeAlert == nil,
              let store,
              let context = sender.representedObject as? Context,
              let parent = context.window,
              parent.attachedSheet == nil else { return }

        let alert = NSAlert()
        alert.messageText = L10n.tr("context.appNote")
        alert.informativeText = L10n.tr("appNote.description")
        alert.addButton(withTitle: L10n.tr("common.save"))
        let cancel = alert.addButton(withTitle: L10n.tr("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"
        let field = NSTextField(string: store.note(for: context.appID))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        field.setAccessibilityLabel(L10n.tr("context.appNote"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        activeAlert = alert

        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self else { return }
            self.activeAlert = nil
            if response == .alertFirstButtonReturn {
                self.store?.setNote(field.stringValue, for: context.appID)
            }
            parent.makeKey()
        }

        // Menu tracking and sheet presentation must finish before taking focus.
        DispatchQueue.main.async { [weak self, weak alert] in
            guard let alert, self?.activeAlert === alert else { return }
            alert.window.makeKeyAndOrderFront(nil)
            alert.window.makeFirstResponder(field)
            field.selectText(nil)
        }
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
