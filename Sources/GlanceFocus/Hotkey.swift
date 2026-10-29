import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's hot key API needs no special permission, and the app
/// is only told when this one key combination is pressed.
final class Hotkey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// `keyCode` is a `kVK_…` constant; `modifiers` combines `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue().action()
            return OSStatus(noErr)
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x474C_4E43), id: 1) // "GLNC"
        _ = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { _ = UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { _ = RemoveEventHandler(handlerRef) }
    }
}
