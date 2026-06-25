import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Owns the supplementary on-screen affordances that live alongside the
/// toolbar: the big centered 3-2-1 countdown, and the colored frame
/// showing what's being captured. Both are passive overlays — they
/// `ignoresMouseEvents`, never steal focus, and (because they belong to
/// CapyBuddy's bundle, which `RecordingEngine.makeFilter` excludes for
/// display/region targets and which an application-mode `including:`
/// filter implicitly omits) they do not appear in the recording.
@MainActor
final class RecordingOverlayController {
    private var countdownPanel: NSPanel?
    private var framePanels: [NSPanel] = []

    /// Show the big countdown overlay on every screen. Driven externally
    /// by `RecordingState.countdownRemaining`; we just position the panel
    /// and the SwiftUI inside reads the binding.
    func showCountdown(state: RecordingState, total: Int) {
        hideCountdown()
        guard let screen = screenForTarget(state.activeTarget) ?? NSScreen.main else { return }
        let size = NSSize(width: 260, height: 260)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width, height: size.height
        )
        let view = RecordingCountdownView(state: state, total: total)
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        countdownPanel = panel
    }

    func hideCountdown() {
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
    }

    /// Frame around the active recording region. One panel per affected
    /// screen — for `.display`/`.application` modes that's one full-screen
    /// frame per attached display the target uses; for `.region` it's a
    /// single panel hugging the region rect.
    func showFrame(target: RecordingTarget, state: RecordingState) {
        hideFrame()
        switch target {
        case .region(_, let rect):
            guard let screen = screenForTarget(target) else { return }
            let global = NSRect(
                x: screen.frame.origin.x + rect.origin.x,
                y: screen.frame.origin.y + rect.origin.y,
                width: rect.width,
                height: rect.height
            )
            framePanels.append(framePanel(frame: global, state: state, label: nil, inset: false))
        case .display:
            guard let screen = screenForTarget(target) else { return }
            framePanels.append(framePanel(frame: screen.frame, state: state, label: nil, inset: true))
        case .application(_, let app, let rect):
            // Draw the frame around the app's window union (same rect the
            // engine crops to), not the entire display. AppKit-local rect
            // → global by adding the screen's origin.
            guard let screen = screenForTarget(target) else { return }
            let global = NSRect(
                x: screen.frame.origin.x + rect.origin.x,
                y: screen.frame.origin.y + rect.origin.y,
                width: rect.width,
                height: rect.height
            )
            framePanels.append(framePanel(frame: global, state: state, label: app.applicationName, inset: false))
        }
    }

    func hideFrame() {
        for panel in framePanels { panel.orderOut(nil) }
        framePanels.removeAll()
    }

    private func framePanel(frame: NSRect, state: RecordingState, label: String?, inset: Bool) -> NSPanel {
        // For full-screen targets we inset the panel by 1pt so the border
        // sits inside the screen edge instead of being clipped off-screen.
        let actualFrame = inset
            ? frame.insetBy(dx: 1, dy: 1)
            : frame
        let view = RecordingFrameView(state: state, label: label)
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(origin: .zero, size: actualFrame.size)
        let panel = NSPanel(
            contentRect: actualFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        return panel
    }

    private func screenForTarget(_ target: RecordingTarget?) -> NSScreen? {
        guard let target else { return nil }
        let displayID: CGDirectDisplayID
        switch target {
        case .display(let d):              displayID = d.displayID
        case .application(let d, _, _):    displayID = d.displayID
        case .region(let d, _):            displayID = d.displayID
        }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

/// Countdown overlay: large ring + scaling digit. Reads
/// `state.countdownRemaining` so its lifetime is the SwiftUI binding's,
/// not a hard-coded animation timer that could de-sync from the engine.
private struct RecordingCountdownView: View {
    @Bindable var state: RecordingState
    let total: Int

    @State private var pop = false

    var body: some View {
        ZStack {
            // Translucent grey disc — matches macOS's own countdown style
            // (Screenshot Tool, Screen Recording). No progress ring; the
            // ring's partial arc visually read as a "rectangle wedge"
            // at 1/3 and 2/3, which looked terrible. Just the number
            // popping is more legible and more elegant.
            Circle()
                .fill(Color(white: 0.0).opacity(0.55))
                .shadow(color: .black.opacity(0.30), radius: 24, x: 0, y: 6)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )

            Text(state.countdownRemaining > 0 ? "\(state.countdownRemaining)" : "GO")
                .font(.system(size: 92, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                // Bouncy scale-pop on each number change — pattern lifted
                // from https://yyokii.medium.com/swiftui-simple-countdown-315eae794b23
                .scaleEffect(pop ? 1.0 : 0.78)
                .opacity(pop ? 1.0 : 0.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.55), value: pop)
                .animation(.spring(response: 0.35, dampingFraction: 0.55), value: state.countdownRemaining)
                .id(state.countdownRemaining)
        }
        .frame(width: 180, height: 180)
        .padding(8)
        .onAppear { pop = true }
        .onChange(of: state.countdownRemaining) { _, _ in
            // Re-trigger the pop animation: snap small + invisible, then
            // animate to the full state next frame. The `.id(...)` above
            // forces SwiftUI to treat the Text as a brand-new view each
            // tick, so transitions don't get reused.
            pop = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                pop = true
            }
        }
    }
}

/// Frame around the recorded region. Animates a subtle pulse so the user
/// keeps registering "still recording" without it being distracting.
/// During pause we lose the animation and switch to orange — paused
/// frames don't go to the writer, so the user needs an unambiguous
/// "not actively writing" cue.
private struct RecordingFrameView: View {
    @Bindable var state: RecordingState
    let label: String?
    @State private var pulse = false

    /// Warm tan pulled off the TermBuddy capybara mascot — used during
    /// pre-record phases (counting / preparing) so the yellow-on-screen
    /// blare goes away. Red is reserved for actively-writing-frames.
    private static let capybara = Color(red: 0.92, green: 0.62, blue: 0.27)

    private var borderColor: Color {
        switch state.phase {
        // Toolbar-shown-but-not-yet-recording: warm capybara so the user
        // sees the capture area *previewed* in a calm color before
        // committing. Yellow blasted too aggressively when used here.
        case .idle, .counting, .preparing: return Self.capybara
        case .paused:                      return .orange
        case .stopping:                    return .gray
        case .recording:                   return .red
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Border-only — the panel fills with clear so clicks pass
            // through to whatever's actually behind it.
            Rectangle()
                .strokeBorder(borderColor, lineWidth: 3)
                .opacity(state.phase == .paused ? 0.7 : (pulse ? 1.0 : 0.65))
                .animation(
                    state.phase == .recording
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )

            // Optional corner label — used for application mode where the
            // border alone doesn't tell the user WHICH app is being
            // captured (it's the whole display rect, but only that app's
            // windows make it into the file).
            if let label {
                HStack(spacing: 6) {
                    Circle().fill(borderColor).frame(width: 8, height: 8)
                    Text("Recording \(label)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.6))
                )
                .padding(12)
            }
        }
        .onAppear { pulse = true }
    }
}

/// Floating toolbar shown for the duration of a recording session.
///
/// States the buttons cycle through, driven by `RecordingState.phase`:
///   - `.idle` / `.preparing` → big red **Start** button + Cancel
///   - `.counting`            → giant 3 / 2 / 1 label + Cancel
///   - `.recording`           → **Pause** + **Stop** + **Discard**
///   - `.paused`              → **Resume** + **Stop** + **Discard**
/// The elapsed time label updates twice per second via the manager's ticker.
@MainActor
final class RecordingToolbarController {

    struct Actions {
        var onStart:   () -> Void
        var onPause:   () -> Void
        var onResume:  () -> Void
        var onStop:    () -> Void
        var onDiscard: () -> Void
        var onCancel:  () -> Void
    }

    private let panel: RecordingToolbarPanel

    init(state: RecordingState, actions: Actions) {
        let view = RecordingToolbarView(state: state, actions: actions)
        self.panel = RecordingToolbarPanel(rootView: view)
    }

    func show(target: RecordingTarget) {
        positionPanel(forTarget: target)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Positions the toolbar so it doesn't sit inside the recorded region.
    /// We default to bottom-center of the screen containing the target; if
    /// the target IS the entire screen, we move the toolbar 4 pt above the
    /// dock (full-screen capture still includes the toolbar pixels inside
    /// the screen rect, but ScreenCaptureKit's per-app exclusion filter
    /// keeps it out of the actual frame data — see `RecordingEngine.makeFilter`).
    private func positionPanel(forTarget target: RecordingTarget) {
        let frame = panel.frame
        let placement: NSRect

        switch target {
        case .region(_, let rect):
            // Try to dock just below the selected region; fall back to
            // above if there's no room (region grabs the bottom of the
            // screen). Use the screen the region lives on.
            let screen = screenContaining(point: NSPoint(x: rect.midX, y: rect.midY)) ?? NSScreen.main
            guard let screen else {
                panel.center()
                return
            }
            let belowY = rect.minY - frame.height - 12
            let aboveY = rect.maxY + 12
            let y: CGFloat
            if belowY >= screen.visibleFrame.minY + 8 {
                y = belowY
            } else if aboveY + frame.height <= screen.visibleFrame.maxY - 8 {
                y = aboveY
            } else {
                y = screen.visibleFrame.minY + 12
            }
            let x = min(max(rect.midX - frame.width / 2,
                            screen.visibleFrame.minX + 8),
                        screen.visibleFrame.maxX - frame.width - 8)
            placement = NSRect(x: x, y: y, width: frame.width, height: frame.height)
        case .application(let display, _, let appRect):
            // Application capture is cropped to the window union — try to
            // dock the toolbar below it (so it doesn't sit on top of the
            // recorded app), falling back to above or to the bottom of
            // the display.
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            } ?? NSScreen.main
            guard let screen else { panel.center(); return }
            let globalRect = NSRect(
                x: screen.frame.origin.x + appRect.origin.x,
                y: screen.frame.origin.y + appRect.origin.y,
                width: appRect.width, height: appRect.height
            )
            let belowY = globalRect.minY - frame.height - 12
            let aboveY = globalRect.maxY + 12
            let y: CGFloat
            if belowY >= screen.visibleFrame.minY + 8 {
                y = belowY
            } else if aboveY + frame.height <= screen.visibleFrame.maxY - 8 {
                y = aboveY
            } else {
                y = screen.visibleFrame.minY + 12
            }
            let x = min(max(globalRect.midX - frame.width / 2,
                            screen.visibleFrame.minX + 8),
                        screen.visibleFrame.maxX - frame.width - 8)
            placement = NSRect(x: x, y: y, width: frame.width, height: frame.height)
        case .display(let display):
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            } ?? NSScreen.main
            guard let screen else { panel.center(); return }
            let x = screen.visibleFrame.midX - frame.width / 2
            let y = screen.visibleFrame.minY + 24
            placement = NSRect(x: x, y: y, width: frame.width, height: frame.height)
        }
        panel.setFrame(placement, display: true)
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

final class RecordingToolbarPanel: NSPanel {
    init<V: View>(rootView: V) {
        let host = NSHostingController(rootView: rootView)
        host.view.frame = NSRect(x: 0, y: 0, width: 380, height: 64)
        super.init(
            contentRect: host.view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = host
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { true }
}

@MainActor
private struct RecordingToolbarView: View {
    @Bindable var state: RecordingState
    let actions: RecordingToolbarController.Actions
    /// Pre-record toggles. Read once at view init from `RecordingPrefs` —
    /// the engine reads these defaults at start time, so flipping during
    /// `.idle` affects the upcoming recording. We don't expose them
    /// during `.recording`/`.paused` because changing them mid-write
    /// would mean adding/removing audio inputs on a live AVAssetWriter,
    /// which AVFoundation doesn't allow.
    @State private var micOn: Bool = RecordingPrefs.captureMicrophone
    @State private var audioOn: Bool = RecordingPrefs.captureSystemAudio
    @State private var cursorOn: Bool = RecordingPrefs.showsCursor

    /// Width swells in pre-record so the toggles have room, then shrinks
    /// once we're recording (no toggles, fewer buttons).
    private var preRecord: Bool {
        state.phase == .idle || state.phase == .preparing
    }
    private var width: CGFloat {
        if state.phase == .counting { return 380 }
        return preRecord ? 480 : 380
    }

    var body: some View {
        Group {
            if state.phase == .counting {
                countdown
            } else {
                HStack(spacing: 10) {
                    elapsed
                    if preRecord { Divider().frame(height: 22); toggles }
                    Spacer(minLength: 4)
                    buttons
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .frame(width: width, height: 64)
        .animation(.easeInOut(duration: 0.15), value: width)
    }

    private var toggles: some View {
        HStack(spacing: 6) {
            toggleButton(
                on: micOn,
                onSymbol: "mic.fill",
                offSymbol: "mic.slash.fill",
                tint: .blue,
                help: micOn ? "Microphone on - click to disable" : "Microphone off - click to enable"
            ) {
                handleMicToggle()
            }
            toggleButton(
                on: audioOn,
                onSymbol: "speaker.wave.2.fill",
                offSymbol: "speaker.slash.fill",
                tint: .blue,
                help: audioOn ? "System audio on - click to disable" : "System audio off - click to enable"
            ) {
                audioOn.toggle()
                RecordingPrefs.captureSystemAudio = audioOn
            }
            toggleButton(
                on: cursorOn,
                onSymbol: "cursorarrow",
                offSymbol: "cursorarrow.slash",
                tint: .blue,
                help: cursorOn ? "Cursor visible - click to hide" : "Cursor hidden - click to show"
            ) {
                cursorOn.toggle()
                RecordingPrefs.showsCursor = cursorOn
            }
        }
        .onAppear {
            // The toolbar's persisted `micOn` can outlive a TCC revocation —
            // if the user disabled mic in System Settings since last
            // recording, we shouldn't keep showing the toggle as "on".
            // Reconcile state here so the UI stops lying.
            if micOn && !PermissionChecker.isMicrophoneGranted() {
                micOn = false
                RecordingPrefs.captureMicrophone = false
            }
        }
    }

    /// Runs `tccutil reset <service> <bundle>` for each named service,
    /// then re-launches CapyBuddy after a 200ms delay (long enough for our
    /// own `NSApp.terminate` to begin tearing down). Saves the user from
    /// the "quit yourself, then please double-click the .app again" dance
    /// that an explicit Quit button would force.
    private func relaunchAfterTCCReset(services: [String]) {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let bundlePath = Bundle.main.bundlePath
        guard !bundleID.isEmpty else { return }
        for service in services {
            let p = Process()
            p.launchPath = "/usr/bin/tccutil"
            p.arguments = ["reset", service, bundleID]
            try? p.run()
            p.waitUntilExit()
        }
        // Schedule a relaunch via /usr/bin/open from a detached process so
        // it survives our own termination. NSWorkspace.openApplication
        // would race with terminate().
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Turning mic ON triggers the system permission prompt right now,
    /// instead of deferring it to the moment the user hits Start (which
    /// previously caused SCK to fail with -3801 if the user enabled mic
    /// without ever granting TCC access). Turning off is unconditional.
    private func handleMicToggle() {
        if micOn {
            micOn = false
            RecordingPrefs.captureMicrophone = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micOn = true
            RecordingPrefs.captureMicrophone = true
        case .notDetermined:
            // First-time prompt — `requestAccess` will pop the system
            // dialog. Stay off optimistically and flip on only if the
            // user clicks Allow.
            PermissionChecker.requestMicrophone { granted in
                Task { @MainActor in
                    micOn = granted
                    RecordingPrefs.captureMicrophone = granted
                    if !granted { presentMicDeniedAlert() }
                }
            }
        case .denied, .restricted:
            // User said no in the past — `requestAccess` won't re-prompt;
            // surface the recovery path instead.
            presentMicDeniedAlert()
        @unknown default:
            break
        }
    }

    private func presentMicDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone access blocked"
        alert.informativeText = """
            macOS has the microphone TCC for CapyBuddy set to denied — and if CapyBuddy isn't in the Microphone list yet, it's a "silent deny" state left over from an earlier SCK probe.

            Reset clears the TCC entry and quits CapyBuddy. Relaunch and click the mic toggle again — this time you'll see the system's real "Allow microphone access?" dialog.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resetMicTCCAndQuit()
        case .alertSecondButtonReturn:
            PermissionChecker.openMicrophoneSettings()
        default:
            break
        }
    }

    private func resetMicTCCAndQuit() {
        relaunchAfterTCCReset(services: ["Microphone"])
    }

    private func toggleButton(
        on: Bool,
        onSymbol: String,
        offSymbol: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? tint : Color.secondary.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var countdown: some View {
        HStack(spacing: 10) {
            // The big number lives in the centered overlay panel; the
            // toolbar just shows a tiny status pill so users glancing
            // here still see the count without two giant red numbers
            // competing on screen.
            Circle()
                .fill(.yellow)
                .frame(width: 8, height: 8)
            Text("Starts in \(max(1, state.countdownRemaining))s")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.countdownRemaining)
            Spacer(minLength: 4)
            Button(action: actions.onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .help("Cancel")
        }
    }

    private var elapsed: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
                .opacity(state.phase == .paused ? 0.4 : 1.0)
            Text(RecordingState.formatElapsed(state.elapsedSeconds))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .monospacedDigit()
        }
    }

    private var indicatorColor: Color {
        switch state.phase {
        case .recording: return .red
        case .paused:    return .orange
        case .preparing: return .yellow
        case .stopping:  return .gray
        case .counting:  return .yellow
        case .idle:      return .secondary
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch state.phase {
        case .idle, .preparing:
            colorButton(
                tint: .green,
                symbol: "record.circle.fill",
                label: "Start",
                help: "Start recording",
                disabled: state.phase == .preparing,
                action: actions.onStart
            )
            colorButton(
                tint: .secondary,
                symbol: "xmark",
                help: "Cancel",
                style: .neutral,
                action: actions.onCancel
            )

        case .recording:
            colorButton(tint: .orange, symbol: "pause.fill", help: "Pause", action: actions.onPause)
            colorButton(tint: .red,    symbol: "stop.fill",  help: "Stop and save", action: actions.onStop)
            colorButton(tint: .secondary, symbol: "trash",   help: "Discard", style: .neutral, action: actions.onDiscard)

        case .paused:
            colorButton(tint: .green, symbol: "play.fill", help: "Resume", action: actions.onResume)
            colorButton(tint: .red,   symbol: "stop.fill", help: "Stop and save", action: actions.onStop)
            colorButton(tint: .secondary, symbol: "trash",  help: "Discard", style: .neutral, action: actions.onDiscard)

        case .stopping:
            ProgressView()
                .controlSize(.small)

        case .counting:
            EmptyView()
        }
    }

    /// Visual styles for `colorButton`.
    private enum ColorButtonStyle { case prominent, neutral }

    /// Hand-painted button — `.borderedProminent + .tint(.green)` renders
    /// as a barely-tinted grey on the toolbar's `.ultraThickMaterial`
    /// backdrop because macOS prefers the system accent over our hint.
    /// Rendering the background ourselves gives us a saturated, opaque
    /// green/orange/red that actually reads.
    @ViewBuilder
    private func colorButton(
        tint: Color,
        symbol: String,
        label: String? = nil,
        help: String,
        style: ColorButtonStyle = .prominent,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if let label {
                    Text(label).fontWeight(.semibold)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(style == .prominent ? Color.white : Color.primary)
            .padding(.horizontal, label != nil ? 12 : 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(style == .prominent
                          ? tint.opacity(disabled ? 0.45 : 1.0)
                          : Color.primary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        style == .prominent
                            ? Color.black.opacity(0.10)
                            : Color.primary.opacity(0.15),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
