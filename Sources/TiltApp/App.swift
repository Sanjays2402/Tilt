import AppKit
import Combine
import CoreGraphics

@MainActor
final class App: NSObject, NSApplicationDelegate {

    private var controller: HingeController?
    private var menuBar: MenuBar?
    private var hotKeyCancellable: AnyCancellable?
    private var hotKeyBindingCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.geometry.notice("launched, screen recording granted: \(CGPreflightScreenCaptureAccess())")
        let preferences = Preferences.shared
        let controller = HingeController(preferences: preferences)
        self.controller = controller
        menuBar = MenuBar(controller: controller, preferences: preferences)
        controller.start()

        let hotKey = PreviewHotKey.shared
        hotKey.onPress = { [weak controller] in
            // Hop onto the main actor: the Carbon callback is not isolated.
            Task { @MainActor in controller?.togglePreview() }
        }
        // The stored binding first, so a custom one wins over the default.
        hotKey.setBinding(
            keyCode: UInt32(max(0, preferences.previewHotKeyKeyCode)),
            modifiers: UInt32(max(0, preferences.previewHotKeyModifiers))
        )
        hotKey.setEnabled(preferences.previewHotKeyEnabled)
        hotKeyCancellable = preferences.$previewHotKeyEnabled.sink { enabled in
            PreviewHotKey.shared.setEnabled(enabled)
        }
        hotKeyBindingCancellable = Publishers.CombineLatest(
            preferences.$previewHotKeyKeyCode,
            preferences.$previewHotKeyModifiers
        ).sink { keyCode, modifiers in
            PreviewHotKey.shared.setBinding(
                keyCode: UInt32(max(0, keyCode)),
                modifiers: UInt32(max(0, modifiers))
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
