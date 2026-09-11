import AppKit

@main
@MainActor
enum TiltEntry {
    /// `NSApplication.delegate` is weak, so the delegate needs an owner that
    /// outlives the launch scope.
    private static var delegate: App?

    static func main() {
        let application = NSApplication.shared
        let delegate = App()
        Self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
