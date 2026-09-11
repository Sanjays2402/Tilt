import CoreGraphics
import Foundation
import simd

// MARK: - Depth geometry

/// Where the picture lands on the glass.
///
/// The picture is a sheet hinged to the bottom edge of the screen, turned back
/// in world space by the angle the lid has travelled. The eye stays where it
/// is while the glass turns under it, so the projection takes both the current
/// lid angle and the eye position.
struct DepthGeometry {

    /// Past 90 degrees the picture turns its face away from the glass.
    var maxSeparationDegrees: Double = 88

    /// Bottom-left, bottom-right, top-right, top-left, in points.
    func corners(
        startAngle: Double,
        currentAngle: Double,
        viewingDistanceRatio: Double,
        recession: Double,
        screenSize: CGSize
    ) -> [CGPoint] {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let start = startAngle * .pi / 180
        let current = currentAngle * .pi / 180
        let travel = max(startAngle - currentAngle, 0)
        let separation = min(recession * travel, maxSeparationDegrees) * .pi / 180

        // The eye in world axes, hinge at the origin.
        let reach = height * viewingDistanceRatio + height / 2 * cos(start)
        let rise = height / 2 * sin(start)

        // The same eye, measured along the glass and away from it.
        let along = reach * cos(current) + rise * sin(current)
        let depth = max(reach * sin(current) - rise * cos(current), height / 10)

        let half = width / 2
        func project(_ x: Double, _ y: Double) -> CGPoint {
            let scale = depth / (depth + y * sin(separation))
            return CGPoint(
                x: half + (x - half) * scale,
                y: along + (y * cos(separation) - along) * scale
            )
        }
        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }
}

/// The settings that shape one frame.
struct DepthTuning {
    var viewingDistance: Double = 2.7
    var recession: Double = 2
    var blurEvenness: Double = 0.4
    var dimReach: Double = 0.7
    var maxBlurRadius: Double = 55
    var maxDim: Double = 0.4
}

// MARK: - Homography

/// Projective mapping of a rectangle onto an arbitrary quadrilateral.
enum Homography {

    /// Maps the rectangle from (0, 0) to (`width`, `height`) onto `corners`,
    /// listed bottom-left, bottom-right, top-right, top-left.
    ///
    /// Column-vector convention: `screen = matrix * (x, y, 1)`, divided by the
    /// third component.
    static func matrix(width: Double, height: Double, to corners: [SIMD2<Double>]) -> simd_double3x3 {
        precondition(corners.count == 4, "four corners expected")
        let (x0, y0) = (corners[0].x, corners[0].y)
        let (x1, y1) = (corners[1].x, corners[1].y)
        let (x2, y2) = (corners[2].x, corners[2].y)
        let (x3, y3) = (corners[3].x, corners[3].y)

        // Heckbert's square-to-quad solution on the unit square.
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var g = 0.0
        var h = 0.0
        if abs(dx3) > 1e-9 || abs(dy3) > 1e-9 {
            let determinant = dx1 * dy2 - dx2 * dy1
            if abs(determinant) > 1e-12 {
                g = (dx3 * dy2 - dx2 * dy3) / determinant
                h = (dx1 * dy3 - dx3 * dy1) / determinant
            }
        }
        let a = x1 - x0 + g * x1
        let b = x3 - x0 + h * x3
        let c = x0
        let d = y1 - y0 + g * y1
        let e = y3 - y0 + h * y3
        let f = y0

        // Fold in u = x / width and v = y / height.
        return simd_double3x3(columns: (
            SIMD3(a / width, d / width, g / width),
            SIMD3(b / height, e / height, h / height),
            SIMD3(c, f, 1)
        ))
    }
}

// MARK: - Spring

/// Turns the sensor's ~10 Hz steps into a value that changes smoothly at the
/// display refresh rate.
///
/// Semi-implicit Euler stays stable while `frequency * dt` is below 2. The
/// caller clamps `dt`.
struct CriticallyDampedSpring {
    var value: Double
    var velocity: Double = 0

    /// Radians per second. Higher follows the target faster and smooths less.
    var frequency: Double = 16

    init(value: Double = 0) {
        self.value = value
    }

    mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}

// MARK: - Blur gradient

/// How far out of focus the picture is at a given height, and how much light
/// it has lost. Height is 0 at the hinge edge and 1 at the far edge.
struct BlurGradient {

    /// Exponent on the closing travel. Values above 1 start slowly.
    var blurCurve: Double = 1.6

    /// Exponent on the closing travel for the dimming.
    var dimCurve: Double = 0.7

    /// Dimming at the hinge edge, as a fraction of the dimming at the far
    /// edge.
    var dimHingeFloor: Double = 0.2

    func blurStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), blurCurve)
    }

    func dimStrength(progress: Double) -> Double {
        pow(min(max(progress, 0), 1), dimCurve)
    }
}
