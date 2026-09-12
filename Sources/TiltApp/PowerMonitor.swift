import Combine
import Foundation
import IOKit.ps

/// Reports whether the Mac is currently on battery power, using the public
/// IOKit power-sources API. Polled every few seconds: cheap, stateless, and
/// free of the unsafe-pointer dance a run-loop notification source needs.
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var isOnBattery = false

    private var timer: Timer?

    init() {
        refresh()
        // Matches the timer pattern in MenuBar: a plain repeating timer on
        // the main run loop, hopping onto the actor explicitly.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        let onBattery = Self.isOnBatteryNow()
        if onBattery != isOnBattery {
            Log.hinge.notice("power source changed, on battery: \(onBattery, privacy: .public)")
        }
        isOnBattery = onBattery
    }

    private static func isOnBatteryNow() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let source = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
        else { return false }
        return source == (kIOPSBatteryPowerValue as String)
    }
}
