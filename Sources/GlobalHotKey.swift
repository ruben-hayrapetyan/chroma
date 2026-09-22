import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor
/// on purpose: the Carbon call needs no Accessibility permission, so the app can
/// claim a shortcut without asking to observe every keystroke on the machine.
final class GlobalHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?

    /// `keyCode` is a virtual key code (`kVK_ANSI_N` and friends); `modifiers`
    /// is a Carbon mask (`cmdKey`, `optionKey`, …).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x43414C52), id: id)  // 'CALR'
        var created: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &created)
        guard status == noErr, let created else {
            Self.actions[id] = nil
            return nil
        }
        ref = created
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &pressed)
            guard status == noErr else { return status }
            DispatchQueue.main.async { GlobalHotKey.actions[pressed.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
