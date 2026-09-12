import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: HingeController

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @State private var settingsOpenFailed = false
    @StateObject private var hotKeyRecorder = HotKeyRecorder()

    var onQuit: () -> Void

    private static let width: CGFloat = 320
    private static let inset: CGFloat = 14
    private static let bodyHeight: CGFloat = 430
    private static let makerURL = URL(string: "https://github.com/Sanjays2402")!
    private static let upstreamURL = URL(string: "https://github.com/sumimakito/Mac-Duo")!
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.inset)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            if controller.isSensorAvailable {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        gaugeSection
                        effectGroup
                        if !hasScreenPermission {
                            permissionNotice
                        }
                        lookGroup
                        motionGroup
                        idleGroup
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 12)
                }
                .frame(height: Self.bodyHeight)
            } else {
                unavailableNotice
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 12)
            }
            Divider()
            appGroup
                .padding(.horizontal, Self.inset)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .tint(.indigo)
        .onAppear { hasScreenPermission = CGPreflightScreenCaptureAccess() }
        .onDisappear { hotKeyRecorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenPermission = CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tilt")
                    .font(.title2.weight(.bold))
                Text("Depth for your lid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// The live lid angle as an arc gauge. The needle eases toward each new
    /// reading instead of stepping.
    private var gaugeSection: some View {
        HStack {
            Spacer()
            AngleGauge(angle: controller.currentAngle)
                .opacity(controller.isSensorAvailable ? 1 : 0.35)
            Spacer()
        }
        .padding(.top, 2)
    }

    private var unavailableNotice: some View {
        Text("This Mac has no lid angle sensor. Only some MacBook models have one.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sections

    private var effectGroup: some View {
        group("Effect", disabled: false) {
            // The master switch lives outside the disabled subtree on
            // purpose: disabling it with the group would lock it off.
            toggleRow(
                "Depth effect",
                isOn: $preferences.isEnabled,
                help: "Leans the screen away as the lid closes."
            )
            toggleRow(
                "Live rendering",
                isOn: $preferences.isLivePicture,
                help: "Off holds the frame from when the effect started."
            )
            .disabled(!preferences.isEnabled)
            toggleRow(
                "Battery saver",
                isOn: $preferences.batterySaverEnabled,
                help: "On battery power, holds the frame instead of streaming live video."
            )
            .disabled(!preferences.isEnabled)
        }
    }

    private var lookGroup: some View {
        group("Look") {
            HStack(spacing: 8) {
                ForEach(LookPreset.allCases) { preset in
                    presetCard(preset)
                }
            }
            slider(
                "Blur", value: $preferences.maxBlurRadius, in: 10...160, format: "%.0f pt",
                help: "Blur radius at the far edge."
            )
            slider(
                "Blur spread", value: $preferences.blurEvenness, in: 0...1, format: "%.0f%%", scale: 100,
                help: "0 blurs the far edge only, 100 the whole picture."
            )
            slider(
                "Dimming", value: $preferences.maxDim, in: 0...1, format: "%.0f%%", scale: 100,
                help: "How dark the far edge goes."
            )
            slider(
                "Dimming spread", value: $preferences.dimReach, in: 0.2...1, format: "%.0f%%", scale: 100,
                help: "Everything above this height goes fully dark."
            )
        }
    }

    private var motionGroup: some View {
        group("Motion") {
            slider(
                "Start angle", value: $preferences.thresholdAngle, in: 5...130, format: "%.0f°",
                help: "The effect starts at this angle."
            )
            slider(
                "Full effect after", value: $preferences.blurSpan, in: 5...60, format: "%.0f°",
                help: "Degrees of further closing to reach full strength."
            )
            slider(
                "Lean back", value: $preferences.recession, in: 0...3, format: "%.1f×",
                help: "Degrees of lean per degree of closing. 1 holds it still."
            )
            slider(
                "Perspective", value: perspective, in: 0...1, format: "%.0f%%", scale: 100,
                help: "0 keeps the sides parallel, 100 converges sharply."
            )
        }
    }

    private var idleGroup: some View {
        group("Idle glass") {
            toggleRow(
                "Idle glass",
                isOn: $preferences.idleGlassEnabled,
                help: "Plays the effect once after the Mac sits untouched."
            )
            slider(
                "Idle minutes", value: $preferences.idleGlassMinutes, in: 1...60, format: "%.0f min",
                help: "How long without input before it plays."
            )
        }
    }

    private var appGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow("Show angle in menu bar", isOn: $preferences.showsAngleInMenuBar, help: nil)
            hotKeyRow
            toggleRow("Launch at login", isOn: $launchesAtLogin, help: nil)
                .onChange(of: launchesAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }
            HStack {
                Button("Reset") { preferences.resetToDefaults() }
                Spacer()
                Button("Quit", action: onQuit)
            }
            .controlSize(.small)
            .padding(.top, 2)
            HStack(spacing: 0) {
                Text("Crafted by ").foregroundStyle(.secondary)
                Link("Sanjay", destination: Self.makerURL)
                    .pointingHand()
                Spacer()
                Text("Inspired by ").foregroundStyle(.secondary)
                Link("Mac Duo", destination: Self.upstreamURL)
                    .pointingHand()
                Text(" by Makito").foregroundStyle(.secondary)
            }
            .font(.caption2)
            .padding(.top, 2)
        }
    }

    // MARK: - Hotkey recording

    private var hotKeyRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Preview hotkey")
                Spacer()
                Text(HotKeyBinding.name(
                    keyCode: preferences.previewHotKeyKeyCode,
                    modifiers: preferences.previewHotKeyModifiers
                ))
                .foregroundStyle(.secondary)
                Toggle("", isOn: $preferences.previewHotKeyEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Preview hotkey")
                Button(hotKeyRecorder.isRecording ? "Press keys…" : "Change") {
                    hotKeyRecorder.onRecord = { [weak preferences] keyCode, modifiers in
                        preferences?.previewHotKeyKeyCode = keyCode
                        preferences?.previewHotKeyModifiers = modifiers
                    }
                    hotKeyRecorder.start()
                }
                .controlSize(.small)
                .disabled(hotKeyRecorder.isRecording)
            }
            description("Toggles the effect preview from anywhere.")
        }
    }

    // MARK: - Preset cards

    private func presetCard(_ preset: LookPreset) -> some View {
        let active = preferences.activeLookPreset == preset
        return Button {
            preferences.animatePreset(to: preset)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(active ? .primary : .secondary)
                Text(preset.blurb)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? Color.indigo.opacity(0.14) : Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? Color.indigo : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title) look")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Controls

    private func toggleRow(_ title: String, isOn: Binding<Bool>, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(title)
            }
            description(help)
        }
    }

    @ViewBuilder
    private func description(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var perspective: Binding<Double> {
        Binding(
            get: { (Preferences.farthestEye - preferences.viewingDistance) / Preferences.eyeRange },
            set: { preferences.viewingDistance = Preferences.farthestEye - $0 * Preferences.eyeRange }
        )
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Recording permission is required to show the depth effect.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                openScreenRecordingSettings()
            }
            .controlSize(.small)
            if settingsOpenFailed {
                Text("Could not open System Settings. Open it manually and enable screen recording for Tilt under Privacy & Security.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openScreenRecordingSettings() {
        settingsOpenFailed = false
        Task { @MainActor in
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open(Self.screenRecordingSettingsURL, configuration: configuration)
            } catch {
                settingsOpenFailed = true
            }
        }
    }

    private func group<Content: View>(
        _ title: String,
        disabled: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .disabled(disabled && !preferences.isEnabled)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        scale: Double = 1,
        help: String? = nil
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(reading)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
            description(help)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private extension View {
    func pointingHand() -> some View {
        modifier(PointingHand())
    }
}

private struct PointingHand: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

/// An arc gauge for the live lid angle, 0° on the left to 135° on the right.
/// The needle eases toward each new reading on a spring, so it sweeps instead
/// of stepping between the sensor's ~10 Hz updates.
private struct AngleGauge: View {
    var angle: Double

    @State private var smooth: Double

    init(angle: Double) {
        self.angle = angle
        _smooth = State(initialValue: angle)
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let fraction = min(1, max(0, smooth / 135))
                let center = CGPoint(x: size.width / 2, y: size.height - 8)
                let radius = min(size.width / 2, size.height - 8) - 10

                // Lid angle to a point on the arc, drawn explicitly so there
                // is no ambiguity about arc direction.
                func point(for value: Double, at r: CGFloat) -> CGPoint {
                    let a = (180 + 180 * value / 135) * .pi / 180
                    return CGPoint(x: center.x + r * cos(a), y: center.y - r * sin(a))
                }

                func arc(from: Double, to: Double) -> Path {
                    var path = Path()
                    for i in 0...64 {
                        let v = from + (to - from) * Double(i) / 64
                        let pt = point(for: v, at: radius)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    return path
                }

                let trackStyle = StrokeStyle(lineWidth: 7, lineCap: .round)
                context.stroke(
                    arc(from: 0, to: 135),
                    with: .color(.secondary.opacity(0.25)),
                    style: trackStyle
                )
                if fraction > 0.002 {
                    context.stroke(
                        arc(from: 0, to: 135 * fraction),
                        with: .color(.accentColor),
                        style: trackStyle
                    )
                }
                for tick in [0.0, 45, 90, 135] {
                    var line = Path()
                    line.move(to: point(for: tick, at: radius - 8))
                    line.addLine(to: point(for: tick, at: radius + 8))
                    context.stroke(
                        line,
                        with: .color(.secondary.opacity(0.6)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                }
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: point(for: 135 * fraction, at: radius - 13))
                context.stroke(
                    needle,
                    with: .color(.primary),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                    with: .color(.primary)
                )
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("\(Int(smooth.rounded()))°")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("lid angle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)
        }
        .frame(width: 148, height: 88)
        .onChange(of: angle) { _, newValue in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                smooth = newValue
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lid angle")
        .accessibilityValue("\(Int(angle.rounded())) degrees")
    }
}
