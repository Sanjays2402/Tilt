import AppKit

/// Records one key-down as the preview hotkey binding.
///
/// A bare key with no modifier is ignored, so typing can never set the
/// binding. The keystroke that sets it is swallowed, so it does not leak
/// into whatever the user was doing.
final class HotKeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    /// Called on the main actor with the recorded key code (a kVK_ANSI_*
    /// value) and Carbon modifier flags.
    var onRecord: (@MainActor (Int, Int) -> Void)?

    private var monitor: Any?

    /// Starts listening for the next modified key-down.
    func start() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = HotKeyRecorder.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else { return event }
            let keyCode = Int(event.keyCode)
            // The monitor fires on the main thread; the state update hops
            // onto the main actor explicitly, mirroring App's hotkey path.
            Task { @MainActor [weak self] in
                self?.finish(keyCode: keyCode, modifiers: modifiers)
            }
            return nil
        }
    }

    /// Stops listening without recording. Safe to call when idle.
    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    @MainActor
    private func finish(keyCode: Int, modifiers: Int) {
        cancel()
        onRecord?(keyCode, modifiers)
    }

    /// NSEvent modifier flags to Carbon hotkey modifier bits.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var out = 0
        if flags.contains(.command) { out |= 1 << 8 }
        if flags.contains(.shift) { out |= 1 << 9 }
        if flags.contains(.option) { out |= 1 << 11 }
        if flags.contains(.control) { out |= 1 << 12 }
        return out
    }
}

/// Human-readable names for hotkey bindings, e.g. "⌥⌘T".
enum HotKeyBinding {
    /// Carbon modifier bits in the order macOS menus show them.
    static func name(keyCode: Int, modifiers: Int) -> String {
        var text = ""
        if modifiers & (1 << 12) != 0 { text += "⌃" }
        if modifiers & (1 << 11) != 0 { text += "⌥" }
        if modifiers & (1 << 9) != 0 { text += "⇧" }
        if modifiers & (1 << 8) != 0 { text += "⌘" }
        return text + keyName(keyCode: keyCode)
    }

    /// kVK_ANSI_* virtual key codes from Carbon HIToolbox.
    private static func keyName(keyCode: Int) -> String {
        switch keyCode {
        case 0x00: return "A"
        case 0x0B: return "B"
        case 0x08: return "C"
        case 0x02: return "D"
        case 0x0E: return "E"
        case 0x03: return "F"
        case 0x05: return "G"
        case 0x04: return "H"
        case 0x22: return "I"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x25: return "L"
        case 0x2E: return "M"
        case 0x2D: return "N"
        case 0x1F: return "O"
        case 0x23: return "P"
        case 0x0C: return "Q"
        case 0x0F: return "R"
        case 0x01: return "S"
        case 0x11: return "T"
        case 0x20: return "U"
        case 0x09: return "V"
        case 0x0D: return "W"
        case 0x07: return "X"
        case 0x10: return "Y"
        case 0x06: return "Z"
        case 0x1D: return "0"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x17: return "5"
        case 0x16: return "6"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x19: return "9"
        case 0x31: return "Space"
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x33: return "⌫"
        case 0x35: return "⎋"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        default: return "key 0x\(String(keyCode, radix: 16).uppercased())"
        }
    }
}
