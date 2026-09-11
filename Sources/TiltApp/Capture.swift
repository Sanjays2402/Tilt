import AppKit
import CoreGraphics
import CoreVideo
import Metal
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The built-in display, or `nil` when only external displays are
    /// attached.
    static var builtIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

/// One engine for both pictures of the built-in display: the live stream and
/// the still screenshots.
///
/// Both need the same `SCContentFilter`, and building one enumerates every
/// on-screen window (~70 ms), so the filter is built once, cached, and shared.
@MainActor
final class CaptureEngine {

    // MARK: - Live stream

    /// Display P3 carries the same transfer function as sRGB, so the shader's
    /// sRGB pixel format decodes it correctly.
    static let colourSpaceName = CGColorSpace.displayP3

    /// Frames arrive on the stream's own queue. The newest one is kept under a
    /// lock and picked up on the main thread; the texture cache is only ever
    /// touched from the stream queue.
    private final class FrameReceiver: NSObject, SCStreamOutput {
        private let cache: CVMetalTextureCache
        private let lock = NSLock()
        private var newest: CVMetalTexture?
        private var newestID: UInt64 = 0

        init?(device: MTLDevice) {
            var made: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &made) == kCVReturnSuccess,
                  let made else { return nil }
            cache = made
            super.init()
        }

        /// The newest frame and its number, or `nil` before the first one.
        func latest() -> (texture: MTLTexture, id: UInt64)? {
            lock.lock()
            defer { lock.unlock() }
            guard let newest, let texture = CVMetalTextureGetTexture(newest) else { return nil }
            return (texture, newestID)
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen,
                  CMSampleBufferIsValid(sampleBuffer),
                  let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // Lets go of the surfaces nothing holds, so the pool keeps recycling.
            CVMetalTextureCacheFlush(cache, 0)

            var wrapped: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixels,
                nil,
                .bgra8Unorm_srgb,
                CVPixelBufferGetWidth(pixels),
                CVPixelBufferGetHeight(pixels),
                0,
                &wrapped
            )
            guard result == kCVReturnSuccess, let wrapped else { return }

            lock.lock()
            newest = wrapped
            newestID &+= 1
            lock.unlock()
        }
    }

    private let device: MTLDevice?
    private var stream: SCStream?
    private var receiver: FrameReceiver?
    private var startTask: Task<Void, Never>?
    private var consumedFrameID: UInt64 = 0
    private var lastHandOver: CFTimeInterval = 0

    /// Frames are handed over no faster than this. A starting stream delivers
    /// a burst well above its asked for rate.
    private static let minimumHandOverInterval: TimeInterval = 1.0 / 32

    private(set) var isStreaming = false

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
    }

    /// Begins capturing, or does nothing if it is already running.
    ///
    /// `startCapture` takes long enough that the stream has to be started
    /// while the lid is still closing rather than at the trigger angle.
    func startStream() {
        guard !isStreaming, startTask == nil, device != nil else { return }
        guard let target = NSScreen.builtIn, let displayID = target.displayID else { return }
        isStreaming = true
        startTask = Task { [weak self] in
            await self?.beginStream(displayID: displayID)
            self?.startTask = nil
        }
    }

    func stopStream() {
        guard isStreaming || stream != nil else { return }
        isStreaming = false
        startTask?.cancel()
        startTask = nil
        let closing = stream
        stream = nil
        receiver = nil
        consumedFrameID = 0
        lastHandOver = 0
        Log.geometry.notice("stream stopped")
        guard let closing else { return }
        Task { try? await closing.stopCapture() }
    }

    /// The newest frame, but only once. `nil` when nothing new has arrived
    /// since the last call.
    func nextFrame() -> MTLTexture? {
        let now = CACurrentMediaTime()
        guard now - lastHandOver >= Self.minimumHandOverInterval else { return nil }
        guard let latest = receiver?.latest(), latest.id != consumedFrameID else { return nil }
        consumedFrameID = latest.id
        lastHandOver = now
        return latest.texture
    }

    private func beginStream(displayID: CGDirectDisplayID) async {
        guard let device, let receiver = FrameReceiver(device: device) else {
            isStreaming = false
            return
        }
        do {
            try await ensureFilter(displayID: displayID)
            guard isStreaming, let activeFilter = filter else { return }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(activeFilter.contentRect.width * CGFloat(activeFilter.pointPixelScale))
            configuration.height = Int(activeFilter.contentRect.height * CGFloat(activeFilter.pointPixelScale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = Self.colourSpaceName
            configuration.showsCursor = false
            configuration.queueDepth = 5
            configuration.scalesToFit = false

            let fresh = SCStream(filter: activeFilter, configuration: configuration, delegate: nil)
            try fresh.addStreamOutput(
                receiver,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "Tilt.frames", qos: .userInteractive)
            )
            let started = CFAbsoluteTimeGetCurrent()
            try await fresh.startCapture()
            guard isStreaming else {
                try? await fresh.stopCapture()
                return
            }
            self.receiver = receiver
            self.stream = fresh
            Log.geometry.notice(
                """
                stream started \(configuration.width)x\(configuration.height) px in \
                \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms
                """
            )
        } catch {
            Log.geometry.error("stream failed: \(String(describing: error), privacy: .public)")
            invalidateFilter()
            isStreaming = false
        }
    }

    // MARK: - Still snapshots

    private(set) var latestImage: CGImage?
    private(set) var latestScreen: NSScreen?

    private var prewarmTimer: Timer?
    private var inFlight: Task<Void, Never>?
    private var lastLoggedGeometry: String?

    var isPrewarming: Bool { prewarmTimer != nil }

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func beginPrewarm(interval: TimeInterval = 0.2) {
        guard prewarmTimer == nil else { return }
        capture()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        prewarmTimer = timer
    }

    func endPrewarm() {
        prewarmTimer?.invalidate()
        prewarmTimer = nil
    }

    /// Drops the held screenshot.
    func discardSnapshot() {
        latestImage = nil
        latestScreen = nil
    }

    /// Waits for a screenshot. A pre-warm capture already running counts.
    func captureOnce() async {
        await startCapture().value
    }

    private func capture() {
        startCapture()
    }

    @discardableResult
    private func startCapture() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            await self?.performCapture()
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    private func performCapture() async {
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { return }
        do {
            try await ensureFilter(displayID: displayID)
        } catch {
            return
        }
        guard let activeFilter = filter else { return }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(activeFilter.contentRect.width * CGFloat(activeFilter.pointPixelScale))
        configuration.height = Int(activeFilter.contentRect.height * CGFloat(activeFilter.pointPixelScale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        do {
            let started = CFAbsoluteTimeGetCurrent()
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: activeFilter,
                configuration: configuration
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            latestImage = image
            latestScreen = screen
            Log.geometry.debug("captureImage took \(elapsed, format: .fixed(precision: 1)) ms")
            let geometry = String(
                format: "screen %.0fx%.0f pt at (%.0f, %.0f), backingScale %.2f, contentRect %.0fx%.0f, pointPixelScale %.2f, requested %dx%d px, got %dx%d px",
                screen.frame.width, screen.frame.height,
                screen.frame.origin.x, screen.frame.origin.y,
                screen.backingScaleFactor,
                activeFilter.contentRect.width, activeFilter.contentRect.height,
                CGFloat(activeFilter.pointPixelScale),
                configuration.width, configuration.height,
                image.width, image.height
            )
            if geometry != lastLoggedGeometry {
                lastLoggedGeometry = geometry
                Log.geometry.notice("capture: \(geometry, privacy: .public)")
            }
        } catch {
            invalidateFilter()
        }
    }

    // MARK: - Shared filter

    /// Enumerating every on-screen window costs about 70 ms, so the filter is
    /// kept between runs and rebuilt only when the display changes.
    private var filter: SCContentFilter?
    private var filterDisplayID: CGDirectDisplayID?

    /// Builds the capture filter without starting anything.
    func warmFilter() async {
        guard let displayID = NSScreen.builtIn?.displayID else { return }
        try? await ensureFilter(displayID: displayID)
    }

    /// Drops the cached filter, so the next use enumerates the windows again.
    func invalidateFilter() {
        filter = nil
        filterDisplayID = nil
    }

    private func ensureFilter(displayID: CGDirectDisplayID) async throws {
        guard filter == nil || filterDisplayID != displayID else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        Log.geometry.notice(
            "SCShareableContent took \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms"
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            invalidateFilter()
            throw CaptureError.noSuchDisplay
        }
        // Exclude ourselves, or the overlay feeds back into its own picture.
        let bundleID = Bundle.main.bundleIdentifier
        let ownApplications = content.applications.filter { $0.bundleIdentifier == bundleID }
        if ownApplications.isEmpty {
            Log.geometry.error("capture cannot exclude this app: it owns no window yet")
        }
        filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        filterDisplayID = displayID
    }
}

enum CaptureError: Error {
    case noSuchDisplay
}
