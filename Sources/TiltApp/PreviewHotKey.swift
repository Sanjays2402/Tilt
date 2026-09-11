import AppKit
import Carbon.HIToolbox

/// A single global hotkey (⌥⌘T) that toggles the effect preview.
///
/// Registered through Carbon so it works without Accessibility permission.
/// Everything here runs on the main thread.
final class PreviewHotKey: @unchecked Sendable {
    static let shared = PreviewHotKey()

    /// Called on the main thread when the hotkey fires.
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var installed = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { uninstall() }
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
        // Signature "TILT", id 1. Modifiers are cmdKey | optionKey written
        // out, so this does not depend on Carbon's constant types.
        var hotKeyID = EventHotKeyID(signature: OSType(0x54494C54), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(1 << 8 | 1 << 11),
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
