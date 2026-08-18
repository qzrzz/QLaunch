import AppKit
import Carbon
import Combine

/// System-level hotkey via Carbon `RegisterEventHotKey`.
///
/// Unlike `NSEvent` monitors, this registers with the OS event dispatcher:
/// it works while QLaunch is in the background, does not require Accessibility,
/// and the key press is delivered as a hotkey event instead of a leaked keyDown.
@MainActor
final class LaunchpadHotKeyCenter: ObservableObject {
    static let shared = LaunchpadHotKeyCenter()

    var onPressed: (() -> Void)?

    @Published private(set) var isRegistered = false
    @Published private(set) var isSuspended = false
    @Published private(set) var lastStatus: OSStatus = noErr

    var showsRegistrationError: Bool {
        !isSuspended && !isRegistered && lastStatus != noErr
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func install() {
        installHandlerIfNeeded()
        if !isSuspended {
            registerFromPreferences()
        }
    }

    func uninstall() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            unregister()
        } else {
            registerFromPreferences()
        }
    }

    func registerFromPreferences() {
        register(
            keyCode: UInt32(LaunchpadHotKeyPreferences.keyCode),
            modifiers: LaunchpadHotKeyPreferences.modifiers
        )
    }

    nonisolated static func handleCarbonEvent(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let parameterError = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard parameterError == noErr,
              hotKeyID.signature == launchpadHotKeySignature,
              hotKeyID.id == launchpadHotKeyID,
              GetEventKind(event) == UInt32(kEventHotKeyPressed)
        else {
            return OSStatus(eventNotHandledErr)
        }

        DispatchQueue.main.async {
            LaunchpadHotKeyCenter.shared.handlePressed()
        }
        return noErr
    }

    private func handlePressed() {
        guard !isSuspended, isRegistered else { return }
        onPressed?()
    }

    private func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        unregister()

        let carbonModifiers = modifiers.launchpadCarbonFlags
        guard carbonModifiers != 0 else {
            lastStatus = OSStatus(paramErr)
            isRegistered = false
            return
        }
        guard let target = GetEventDispatcherTarget() else {
            lastStatus = OSStatus(eventInternalErr)
            isRegistered = false
            return
        }

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            EventHotKeyID(signature: launchpadHotKeySignature, id: launchpadHotKeyID),
            target,
            0,
            &ref
        )
        lastStatus = status
        if status == noErr, let ref {
            hotKeyRef = ref
            isRegistered = true
        } else {
            isRegistered = false
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        isRegistered = false
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil, let target = GetEventDispatcherTarget() else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            target,
            launchpadHotKeyEventHandler,
            1,
            &eventSpec,
            nil,
            &handler
        )
        if status == noErr {
            handlerRef = handler
        } else {
            lastStatus = status
        }
    }
}

private func launchpadHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    LaunchpadHotKeyCenter.handleCarbonEvent(event)
}

private let launchpadHotKeySignature = fourCharCode("QLHK")
private let launchpadHotKeyID: UInt32 = 1

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.utf16 {
        result = (result << 8) + FourCharCode(char)
    }
    return result
}

extension NSEvent.ModifierFlags {
    var launchpadCarbonFlags: UInt32 {
        var carbon: UInt32 = 0
        let flags = intersection(LaunchpadHotKeyPreferences.shortcutModifierMask)
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
