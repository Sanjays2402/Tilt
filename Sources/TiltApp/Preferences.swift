import Combine
import Foundation

/// One-tap looks for the depth effect. Each preset is a bundle of the
/// fine-tune sliders below it; picking one just sets those values.
enum LookPreset: String, CaseIterable, Identifiable {
    case frosted
    case noir
    case breeze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frosted: return "Frosted"
        case .noir: return "Noir"
        case .breeze: return "Breeze"
        }
    }

    var blurb: String {
        switch self {
        case .frosted: return "Milky glass, the classic look."
        case .noir: return "Deep blur that falls to black."
        case .breeze: return "A whisper of depth, barely there."
        }
    }

    var thresholdAngle: Double {
        switch self {
        case .frosted: return 90
        case .noir: return 100
        case .breeze: return 80
        }
    }

    var blurSpan: Double {
        switch self {
        case .frosted: return 60
        case .noir: return 45
        case .breeze: return 60
        }
    }

    var maxBlurRadius: Double {
        switch self {
        case .frosted: return 135
        case .noir: return 160
        case .breeze: return 60
        }
    }

    var blurEvenness: Double {
        switch self {
        case .frosted: return 0
        case .noir: return 0.35
        case .breeze: return 0
        }
    }

    var maxDim: Double {
        switch self {
        case .frosted: return 1
        case .noir: return 1
        case .breeze: return 0.55
        }
    }

    var dimReach: Double {
        switch self {
        case .frosted: return 0.5
        case .noir: return 0.75
        case .breeze: return 0.35
        }
    }

    var viewingDistance: Double {
        switch self {
        case .frosted: return 6
        case .noir: return 4.5
        case .breeze: return 6
        }
    }

    var recession: Double {
        switch self {
        case .frosted: return 1
        case .noir: return 1.2
        case .breeze: return 0.8
        }
    }

    /// The preset whose values the preferences currently match, if any.
    /// Dragging a slider away from a preset leaves no preset active.
    @MainActor static func matching(_ preferences: Preferences) -> LookPreset? {
        allCases.first { $0.matches(preferences) }
    }

    @MainActor private func matches(_ p: Preferences) -> Bool {
        p.thresholdAngle == thresholdAngle
            && p.blurSpan == blurSpan
            && p.maxBlurRadius == maxBlurRadius
            && p.blurEvenness == blurEvenness
            && p.maxDim == maxDim
            && p.dimReach == dimReach
            && p.viewingDistance == viewingDistance
            && p.recession == recession
    }
}

/// User settings, backed by `UserDefaults`.
///
/// The keys predate the Tilt name on purpose: upgrading keeps every setting
/// where it was.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let thresholdAngle = "thresholdAngle"
        static let blurSpan = "blurSpan"
        static let maxBlurRadius = "maxBlurRadius"
        static let maxDim = "maxDim"
        static let viewingDistance = "viewingDistance"
        static let recession = "recession"
        static let blurEvenness = "blurEvenness"
        static let dimReach = "dimReach"
        static let showsAngleInMenuBar = "showsAngleInMenuBar"
        static let isLivePicture = "isLivePicture"

        static let all = [
            isEnabled, thresholdAngle, blurSpan, maxBlurRadius,
            maxDim, viewingDistance, recession, blurEvenness, dimReach,
            showsAngleInMenuBar, isLivePicture,
        ]
    }

    private static let factory: [String: Any] = [
        Key.isEnabled: true,
        Key.thresholdAngle: 90.0,
        Key.blurSpan: 60.0,
        Key.maxBlurRadius: 135.0,
        Key.maxDim: 1.0,
        Key.viewingDistance: 6.0,
        Key.recession: 1.0,
        Key.blurEvenness: 0.0,
        Key.dimReach: 0.5,
        Key.showsAngleInMenuBar: false,
        Key.isLivePicture: true,
    ]

    /// Master switch for the depth effect.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// Closing past this angle starts the depth effect. Degrees.
    @Published var thresholdAngle: Double {
        didSet { defaults.set(thresholdAngle, forKey: Key.thresholdAngle) }
    }

    /// How many degrees below the threshold the blur takes to reach maximum.
    @Published var blurSpan: Double {
        didSet { defaults.set(blurSpan, forKey: Key.blurSpan) }
    }

    /// Gaussian blur radius at full effect, in points.
    @Published var maxBlurRadius: Double {
        didSet { defaults.set(maxBlurRadius, forKey: Key.maxBlurRadius) }
    }

    /// Black overlay opacity where the blur is at full strength, 0...1.
    @Published var maxDim: Double {
        didSet { defaults.set(maxDim, forKey: Key.maxDim) }
    }

    /// Distance from the eye to the middle of the screen, as a multiple of
    /// the screen height.
    @Published var viewingDistance: Double {
        didSet { defaults.set(viewingDistance, forKey: Key.viewingDistance) }
    }

    /// Degrees the picture turns away from the glass for each degree the lid
    /// closes. One holds the picture still in the room.
    @Published var recession: Double {
        didSet { defaults.set(recession, forKey: Key.recession) }
    }

    /// Blur at the hinge edge as a fraction of the blur at the far edge. One
    /// blurs the whole picture by the same amount.
    @Published var blurEvenness: Double {
        didSet { defaults.set(blurEvenness, forKey: Key.blurEvenness) }
    }

    /// Height at which the dimming reaches full strength, as a fraction of
    /// the screen height.
    @Published var dimReach: Double {
        didSet { defaults.set(dimReach, forKey: Key.dimReach) }
    }

    /// Draw the live angle next to the menu bar icon.
    @Published var showsAngleInMenuBar: Bool {
        didSet { defaults.set(showsAngleInMenuBar, forKey: Key.showsAngleInMenuBar) }
    }

    /// Keep the picture under the effect updating, instead of holding the one
    /// frame that was on screen at the trigger angle.
    @Published var isLivePicture: Bool {
        didSet { defaults.set(isLivePicture, forKey: Key.isLivePicture) }
    }

    /// Eye distance in screen heights, at the two ends of the perspective
    /// slider. The panel offers the strength, which runs the other way.
    static let farthestEye: Double = 6
    static let nearestEye: Double = 1
    static let eyeRange: Double = farthestEye - nearestEye

    /// Highest angle above the threshold at which the pre-warm may run.
    let prewarmCeiling: Double = 70

    /// Closing speed in degrees per second that starts the pre-warm.
    let closingSpeed: Double = 8

    /// How long the pre-warm runs after the lid stops moving.
    let prewarmLinger: TimeInterval = 2

    /// Seconds between pre-warm screenshots.
    let prewarmInterval: TimeInterval = 0.25

    /// Degrees above the threshold before the overlay is released.
    let hysteresis: Double = 4

    /// Settings from earlier versions, removed at launch.
    private static let retired = [
        "blurFrontWidth", "maxTilt", "tiltDegrees", "tiltRatio", "dimEvenness",
    ]

    private let defaults = UserDefaults.standard

    // No inline values on purpose. Swift skips property observers for the
    // assignment that initialises a property.
    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.factory)
        for key in Self.retired { defaults.removeObject(forKey: key) }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
    }

    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        blurSpan = defaults.double(forKey: Key.blurSpan)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        maxDim = defaults.double(forKey: Key.maxDim)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        blurEvenness = defaults.double(forKey: Key.blurEvenness)
        dimReach = defaults.double(forKey: Key.dimReach)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
    }

    /// Applies a look preset. Each assignment persists through its own
    /// property observer, so there is nothing else to save.
    func applyPreset(_ preset: LookPreset) {
        thresholdAngle = preset.thresholdAngle
        blurSpan = preset.blurSpan
        maxBlurRadius = preset.maxBlurRadius
        blurEvenness = preset.blurEvenness
        maxDim = preset.maxDim
        dimReach = preset.dimReach
        viewingDistance = preset.viewingDistance
        recession = preset.recession
    }

    /// The preset the current values match, or nil after fine-tuning.
    var activeLookPreset: LookPreset? {
        LookPreset.matching(self)
    }
}
