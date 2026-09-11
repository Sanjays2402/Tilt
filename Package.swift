// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tilt",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TiltSensor",
            path: "Sources/TiltSensor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Tilt",
            dependencies: ["TiltSensor"],
            path: "Sources/TiltApp",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TiltProbe",
            dependencies: ["TiltSensor"],
            path: "Sources/TiltProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
