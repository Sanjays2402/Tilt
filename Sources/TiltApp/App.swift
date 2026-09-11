import AppKit
import CoreGraphics

@MainActor
final class App: NSObject, NSApplicationDelegate {

    private var controller: HingeController?
    private var menuBar: MenuBar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.geometry.notice("launched, screen recording granted: \(CGPreflightScreenCaptureAccess())")
        let preferences = Preferences.shared
        let controller = HingeController(preferences: preferences)
        self.controller = controller
        menuBar = MenuBar(controller: controller, preferences: preferences)
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
