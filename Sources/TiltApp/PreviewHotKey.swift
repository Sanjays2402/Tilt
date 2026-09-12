import AppKit
import Carbon.HIToolbox

/// A single global hotkey that toggles the effect preview.
///
/// Registered through Carbon so it works without Accessibility permission.
/// Everything here runs on the main thread.
final class PreviewHotKey: @unchecked Sendable {
    static let shared = PreviewHotKey()

    /// Called on the main thread when the hotkey fires.
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var installed = false
    /// A kVK_ANSI_* virtual key code. The default is ⌥⌘T.
    private var keyCode = UInt32(kVK_ANSI_T)
    /// Carbon modifier flags (cmdKey | optionKey | ...). The default is ⌥⌘T.
    private var modifiers = UInt32(1 << 8 | 1 << 11)

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { uninstall() }
    }

    /// Changes the binding, re-registering when the hotkey is installed.
    /// When it is not installed, the binding is just stored for later.
    func setBinding(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        guard installed else { return }
        uninstall()
        install()
    }

    private func install() {
        guard !installed else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Only one hotkey is ever registered, so any press is ours: no need
        // to read the hotkey ID back out of the event.
        let handler: EventHandlerUPP? = { _, _, userData in
            if let userData {
                let manager = Unmanaged<PreviewHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onPress?() }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        // Signature "TILT", id 1. Modifier bits are written out numerically
        // (cmdKey = 1 << 8, ...), so this does not depend on Carbon's
        // constant types.
        var hotKeyID = EventHotKeyID(signature: OSType(0x54494C54), id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        installed = status == noErr
    }

    private func uninstall() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        self.hotKey = nil
        installed = false
    }

    deinit { uninstall() }
}
