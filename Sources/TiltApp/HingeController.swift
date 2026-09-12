import AppKit
import Combine
import QuartzCore
import TiltSensor

/// Watches the hinge angle and drives the depth effect.
///
/// A timer polls the sensor, and a display link advances a spring at the
/// screen refresh rate so the ramp stays smooth between readings.

/// Identity of the built-in display. `NSApplication` posts a screen change for
/// a backlight change too, and this tells the two apart.
struct Layout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?
}

@MainActor
final class HingeController: ObservableObject {

    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isActive = false

    let capture = CaptureEngine()

    private let preferences: Preferences
    private let sensor = HingeSensor()
    private let stage = DepthStage()
    private let powerMonitor = PowerMonitor()

    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPublishTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    /// Degrees per second, negative while the lid closes.
    private var angularVelocity: Double = 0
    private var lastChangedAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0
    private var lastClosingTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var visualAngle = CriticallyDampedSpring()
    private var consecutiveFailedReads = 0
    private var startedAt: CFTimeInterval = 0
    private var preview: PreviewRun?
    private var isSuspended = false
    private var isCapturePending = false
    private var lastMovedDownTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var builtInLayout = Layout()
    private var idleGlassTimer: Timer?
    /// Idle glass has fired and the user has not come back yet.
    private var idleGlassFired = false

    private static let idlePollInterval: TimeInterval = 1.0 / 8
    private static let activePollInterval: TimeInterval = 1.0 / 30
    private static let fadeInDuration: TimeInterval = 0.07
    /// Degrees above the pre-warm zone at which polling speeds up.
    private static let fastPollMargin: Double = 20

    /// Closing speed that counts as a deliberate close, in degrees per second.
    /// A still lid reads under 0.5.
    private static let triggerClosingSpeed: Double = 2

    /// How long after the lid last moved down the effect may still start.
    private static let closingMemory: TimeInterval = 1.5

    private static let predictionSpeedFloor: Double = 40

    /// Sensor latency the prediction adds on top of the reading's own age.
    private static let predictionLatency: TimeInterval = 0.04

    /// The overlay stays up at least this long. A prediction can fire while the
    /// last reading is still above the release angle.
    private static let minimumEffectDuration: TimeInterval = 0.35

    /// A scripted angle sweep, so the settings panel can show the effect
    /// without the lid moving. It feeds the same path the sensor feeds.
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        let closing: CFTimeInterval = 1.4
        let hold: CFTimeInterval = 0.8
        let opening: CFTimeInterval = 0.6

        /// `nil` once the run is over.
        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
            if elapsed < closing + hold { return shut }
            if elapsed < closing + hold + opening {
                return shut + (open - shut) * ((elapsed - closing - hold) / opening)
            }
            return nil
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        guard isSensorAvailable else { return }

        if let angle = sensor.angle() {
            rawAngle = angle
            currentAngle = angle
            visualAngle.reset(to: angle)
        }
        setPollInterval(Self.idlePollInterval)
        builtInLayout = Layout(displayID: NSScreen.builtIn?.displayID, frame: NSScreen.builtIn?.frame)
        observeSystemEvents()
        startIdleGlassTimer()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.sanjays2402.Tilt.preview"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        stage.warmUp()
        Task {
            await capture.warmFilter()
            // After the stage has put its presence window up, so the filter
            // can name this app and leave the stage out of the picture.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await capture.warmFilter()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        idleGlassTimer?.invalidate()
        idleGlassTimer = nil
        stopDisplayLink()
        stage.dismiss(animated: false)
        capture.endPrewarm()
        capture.stopStream()
        stage.discardLive()
        isActive = false
    }

    /// Plays the effect once on the current screen contents.
    func runPreview() {
        guard preview == nil, !isActive else { return }
        // Well above the trigger angle, so the sweep runs the pre-warm the way
        // a real close does.
        preview = PreviewRun(
            startedAt: CACurrentMediaTime(),
            open: min(preferences.thresholdAngle + 35, 130),
            shut: max(preferences.thresholdAngle - preferences.blurSpan * 1.15, 5)
        )
        setPollInterval(Self.activePollInterval)
    }

    /// Toggles the scripted preview, for the hotkey and the menu. While the
    /// lid itself holds the effect, the toggle leaves it alone.
    func togglePreview() {
        if preview != nil {
            preview = nil
        } else {
            runPreview()
        }
    }

    // MARK: - Idle glass

    /// Checks every 30 seconds whether the Mac has sat untouched long
    /// enough to play the effect once, screensaver-style.
    private func startIdleGlassTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdleGlass() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleGlassTimer = timer
    }

    private func checkIdleGlass() {
        guard preferences.idleGlassEnabled,
              isSensorAvailable,
              preferences.isEnabled,
              !isActive,
              preview == nil else {
            return
        }
        let idle = Self.idleSeconds()
        if idleGlassFired {
            // The user has to come back before it can fire again.
            if idle < 30 { idleGlassFired = false }
            return
        }
        let threshold = max(60, preferences.idleGlassMinutes * 60)
        guard idle >= threshold else { return }
        idleGlassFired = true
        Log.hinge.notice(
            "idle glass: idle \(idle, format: .fixed(precision: 0))s, playing preview"
        )
        runPreview()
    }

    /// Seconds since the last keyboard or mouse activity, via public Quartz
    /// API. The minimum of the two covers typing and mousing alike.
    private static func idleSeconds() -> TimeInterval {
        let state = CGEventSourceStateID.combinedSessionState
        let keys = CGEventSource.secondsSinceLastEventType(state, .keyDown)
        let mouse = CGEventSource.secondsSinceLastEventType(state, .mouseMoved)
        return min(keys, mouse)
    }

    // MARK: - Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isSuspended else { return }

        let angle: Double
        if let run = preview {
            guard let scripted = run.angle(at: CACurrentMediaTime()) else {
                preview = nil
                return
            }
            angle = scripted
        } else {
            guard let read = sensor.angle() else {
                consecutiveFailedReads += 1
                if consecutiveFailedReads > 30, isActive {
                    Log.hinge.notice(
                        """
                        release: sensor read failed \(self.consecutiveFailedReads) times in a row, \
                        last angle \(self.rawAngle, format: .fixed(precision: 2))
                        """
                    )
                    setActive(false)
                }
                return
            }
            if consecutiveFailedReads > 0 {
                Log.hinge.notice(
                    "sensor recovered after \(self.consecutiveFailedReads) failed reads, angle \(read, format: .fixed(precision: 2))"
                )
            }
            consecutiveFailedReads = 0
            angle = read
        }

        rawAngle = angle
        updateVelocity(with: angle)
        publish(angle: angle)

        reconcile(angle: angle)

        let prewarmZone = preferences.thresholdAngle + preferences.prewarmCeiling
        let wantsFastPolling = preview != nil || isActive || angle <= prewarmZone + Self.fastPollMargin
        setPollInterval(wantsFastPolling ? Self.activePollInterval : Self.idlePollInterval)
    }

    /// Whether the picture belongs on screen for this angle. It widens the
    /// angle for release and keeps a lid held below the angle showing.
    private func wantsEffect(angle: Double) -> Bool {
        guard preferences.isEnabled else { return false }
        let threshold = preferences.thresholdAngle
        if isActive {
            guard CACurrentMediaTime() - startedAt > Self.minimumEffectDuration else { return true }
            return angle < threshold + preferences.hysteresis
        }
        // A lid resting below the angle must not start by itself.
        let closing = CACurrentMediaTime() - lastMovedDownTime < Self.closingMemory
        return closing && predictedAngle() <= threshold
    }

    /// Brings the screen in line with `wantsEffect` on every sample. A run
    /// whose screenshot failed is retried here.
    private func reconcile(angle: Double) {
        let wanted = wantsEffect(angle: angle)
        if wanted != isActive {
            Log.hinge.notice(
                """
                \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
                predicted \(self.predictedAngle(), format: .fixed(precision: 2)) \
                velocity \(self.angularVelocity, format: .fixed(precision: 1)) deg/s \
                snapshot \(self.capture.latestImage != nil)
                """
            )
            setActive(wanted)
            return
        }
        if isActive {
            if !stage.isVisible, !isCapturePending { presentPicture() }
            // A visible stage with no link would sit at its first frame.
            if stage.isVisible, displayLink == nil { startDisplayLink() }
        } else {
            updatePrewarm(angle: angle, ceiling: preferences.thresholdAngle + preferences.prewarmCeiling)
        }
    }

    private func updateVelocity(with angle: Double) {
        let now = CACurrentMediaTime()
        guard let last = lastChangedAngle else {
            lastChangedAngle = angle
            lastChangeTime = now
            return
        }
        if angle != last {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                angularVelocity = 0.5 * instant + 0.5 * angularVelocity
            }
            lastChangedAngle = angle
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            angularVelocity = 0
        }
        if angularVelocity <= -Self.triggerClosingSpeed {
            lastMovedDownTime = now
        }
        if angularVelocity <= -preferences.closingSpeed {
            lastClosingTime = now
        }
    }

    /// Live picture, unless battery saver is holding the frame on battery
    /// power. Read at each decision point so a mid-effect power change
    /// takes effect on the next one.
    private var effectiveLivePicture: Bool {
        preferences.isLivePicture && !(preferences.batterySaverEnabled && powerMonitor.isOnBattery)
    }

    /// Runs only while the lid is closing, so holding it still does not leave
    /// a capture loop running.
    private func updatePrewarm(angle: Double, ceiling: Double) {
        let closingRecently = CACurrentMediaTime() - lastClosingTime < preferences.prewarmLinger
        guard angle <= ceiling, closingRecently else {
            capture.endPrewarm()
            capture.stopStream()
            stage.discardLive()
            return
        }
        guard effectiveLivePicture else {
            capture.stopStream()
            stage.discardLive()
            capture.beginPrewarm(interval: preferences.prewarmInterval)
            return
        }
        // Only the stream. Asking ScreenCaptureKit for a screenshot at the
        // same time makes it serve neither quickly.
        capture.endPrewarm()
        capture.startStream()
    }

    /// A reading can be a full sensor refresh old, so a fast close works from
    /// where the lid is heading rather than the last reading.
    private func predictedAngle() -> Double {
        guard angularVelocity < -Self.predictionSpeedFloor else { return rawAngle }
        let staleness = min(CACurrentMediaTime() - lastChangeTime, 0.12)
        return rawAngle + angularVelocity * (staleness + Self.predictionLatency)
    }

    private func publish(angle: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.08 else { return }
        lastPublishTime = now
        if abs(currentAngle - angle) > 0.001 { currentAngle = angle }
    }

    // MARK: - Depth effect

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            startedAt = CACurrentMediaTime()
            visualAngle.reset(to: rawAngle)
            capture.endPrewarm()
            setPollInterval(Self.activePollInterval)
            presentPicture()
        } else {
            stopDisplayLink()
            stage.dismiss(animated: true)
            capture.discardSnapshot()
        }
    }

    /// Shows the held screenshot, or waits for one. A pre-warm capture that is
    /// already running counts as that wait.
    private func presentPicture() {
        if effectiveLivePicture, let screen = NSScreen.builtIn,
           stage.showLive(
               on: screen,
               startAngle: preferences.thresholdAngle,
               tuning: tuning,
               fadeIn: Self.fadeInDuration
           ) {
            startDisplayLink()
            if let frame = capture.nextFrame() {
                Log.hinge.notice("present: live, a stream frame was ready")
                stage.absorb(frame)
                return
            }
            // A fast close can reach the trigger angle before the stream has a
            // frame. One screenshot starts the picture off.
            if let image = capture.latestImage {
                Log.hinge.notice("present: live, seeding from the pre-warm screenshot")
                stage.seed(image: image)
                return
            }
            Log.hinge.notice("present: live, no picture yet, asking for a screenshot")
            requestSeed()
            return
        }

        if let image = capture.latestImage, let screen = capture.latestScreen {
            show(image: image, on: screen)
            return
        }
        isCapturePending = true
        Task { [weak self] in
            guard let self else { return }
            await self.capture.captureOnce()
            self.isCapturePending = false
            Log.hinge.notice(
                """
                capture landed: image \(self.capture.latestImage != nil) \
                on \(self.isActive) stage \(self.stage.isVisible)
                """
            )
            guard self.isActive, !self.stage.isVisible,
                  let image = self.capture.latestImage,
                  let screen = self.capture.latestScreen else { return }
            self.show(image: image, on: screen)
        }
    }

    /// Takes one screenshot to start a live stage that has nothing to show
    /// yet. A stream frame that lands first makes it unnecessary.
    private func requestSeed() {
        isCapturePending = true
        let started = CACurrentMediaTime()
        Task { [weak self] in
            guard let self else { return }
            await self.capture.captureOnce()
            self.isCapturePending = false
            Log.hinge.notice(
                """
                seed capture landed after \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms: \
                image \(self.capture.latestImage != nil) on \(self.isActive) \
                ready \(self.stage.isPictureReady)
                """
            )
            guard self.isActive, !self.stage.isPictureReady,
                  let image = self.capture.latestImage else { return }
            self.stage.seed(image: image)
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        stage.show(
            image: image,
            on: screen,
            startAngle: preferences.thresholdAngle,
            tuning: tuning,
            fadeIn: Self.fadeInDuration
        )
        // The link belongs to the stage window.
        startDisplayLink()
    }

    private func blurProgress(for angle: Double) -> Double {
        let span = max(preferences.blurSpan, 1)
        return min(max((preferences.thresholdAngle - angle) / span, 0), 1)
    }

    // MARK: - Animation

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = stage.hostWindow else {
            Log.hinge.notice("display link skipped, no stage window")
            return
        }
        Log.hinge.notice("display link started")
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawInterval = now - lastFrameTime
        let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now
        if let frame = capture.nextFrame() {
            stage.absorb(frame)
        }
        visualAngle.advance(to: rawAngle, dt: dt)
        applyVisual(angle: visualAngle.value)
    }

    /// The geometry takes the lid angle itself, so only the blur saturates.
    private func applyVisual(angle: Double) {
        let progress = blurProgress(for: angle)
        stage.update(progress: progress, currentAngle: angle, tuning: tuning)
    }

    private var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: preferences.viewingDistance,
            recession: preferences.recession,
            blurEvenness: preferences.blurEvenness,
            dimReach: preferences.dimReach,
            maxBlurRadius: preferences.maxBlurRadius,
            maxDim: preferences.maxDim
        )
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // macOS posts this for backlight and colour changes too.
                let screen = NSScreen.builtIn
                let layout = Layout(displayID: screen?.displayID, frame: screen?.frame)
                guard layout != self.builtInLayout else {
                    Log.hinge.notice("screen parameters changed, layout unchanged")
                    return
                }
                Log.hinge.notice(
                    "screen parameters changed, layout now \(String(describing: layout), privacy: .public)"
                )
                self.builtInLayout = layout
                if self.isActive { self.setActive(false) }
                self.capture.stopStream()
                self.capture.invalidateFilter()
                Task { await self.capture.warmFilter() }
                self.stage.discardLive()
                self.capture.discardSnapshot()
            }
        }
    }

    private func suspend() {
        Log.hinge.notice("suspend")
        isSuspended = true
        stopDisplayLink()
        stage.dismiss(animated: false)
        capture.endPrewarm()
        capture.discardSnapshot()
        capture.stopStream()
        stage.discardLive()
        preview = nil
        isActive = false
        isCapturePending = false
    }

    private func resume() {
        Log.hinge.notice("resume")
        isSuspended = false
        // A fresh baseline, so waking with a nearly shut lid does not read as
        // closing movement.
        lastChangedAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        lastMovedDownTime = -.greatestFiniteMagnitude
        if let angle = sensor.angle() {
            rawAngle = angle
            visualAngle.reset(to: angle)
        }
        setPollInterval(Self.idlePollInterval)
    }
}
