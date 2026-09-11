import AppKit
import Combine
import CoreGraphics

@MainActor
final class App: NSObject, NSApplicationDelegate {

    private var controller: HingeController?
    private var menuBar: MenuBar?
    private var hotKeyCancellable: AnyCancellable?

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
        hotKey.setEnabled(preferences.previewHotKeyEnabled)
        hotKeyCancellable = preferences.$previewHotKeyEnabled.sink { enabled in
            PreviewHotKey.shared.setEnabled(enabled)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
