import Foundation
import os

/// Read with:
///
///     log show --last 5m --predicate 'subsystem == "com.sanjays2402.Tilt"'
///
/// Notice level, not info: info level lives only in memory, and `log show`
/// reads the on-disk store.
enum Log {
    static let geometry = Logger(subsystem: "com.sanjays2402.Tilt", category: "geometry")
    static let hinge = Logger(subsystem: "com.sanjays2402.Tilt", category: "hinge")
}
