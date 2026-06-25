import AppKit
import AVFoundation
import SwiftUI

@MainActor
struct RecordingSettingsView: View {
    let feature: RecordingFeature

    @State private var frameRate: Int = RecordingPrefs.frameRate
    @State private var codec: RecordingPrefs.Codec = RecordingPrefs.codec
    @State private var fileFormat: RecordingPrefs.FileFormat = RecordingPrefs.fileFormat
    @State private var quality: RecordingPrefs.Quality = RecordingPrefs.quality
    @State private var captureSystemAudio: Bool = RecordingPrefs.captureSystemAudio
    @State private var captureMicrophone: Bool = RecordingPrefs.captureMicrophone
    @State private var showsCursor: Bool = RecordingPrefs.showsCursor
    @State private var highlightCursor: Bool = RecordingPrefs.highlightCursor
    @State private var countdownSeconds: Int = RecordingPrefs.countdownSeconds
    @State private var revealInFinder: Bool = RecordingPrefs.revealInFinder
    @State private var saveDirectory: URL = RecordingPrefs.saveDirectory
    @State private var screenRecordingGranted: Bool = PermissionChecker.isScreenRecordingGranted()
    @State private var accessibilityGranted: Bool = PermissionChecker.isAccessibilityGranted()
    @State private var microphoneGranted: Bool = PermissionChecker.isMicrophoneGranted()
    @State private var freeSpaceText: String = ""

    @ObservedObject private var hotkeyStore = RecordingHotkeyStore.shared
    @State private var capturingHotkey = false

    private let frameRateOptions = [15, 24, 30, 60]
    private let countdownOptions = [0, 3, 5, 10]

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    granted: screenRecordingGranted,
                    label: "Screen Recording",
                    detail: screenRecordingGranted
                        ? "Allowed - CapyBuddy can capture screens and windows."
                        : "Required to capture the screen.",
                    button: "Open Settings",
                    action: PermissionChecker.openScreenRecordingSettings
                )
                permissionRow(
                    granted: accessibilityGranted,
                    label: "Accessibility",
                    detail: accessibilityGranted
                        ? "Allowed - the global hotkey is active."
                        : "Required to listen for the global start/stop hotkey.",
                    button: "Open Settings",
                    action: PermissionChecker.openAccessibilitySettings
                )
                permissionRow(
                    granted: microphoneGranted,
                    label: "Microphone",
                    detail: microphoneGranted
                        ? "Allowed - microphone recordings include voice."
                        : "Only needed when the microphone toggle is on. Without this, mic capture is silently skipped.",
                    button: "Open Settings",
                    action: PermissionChecker.openMicrophoneSettings
                )
                HStack {
                    Button("Re-check") {
                        // `CGPreflightScreenCaptureAccess()` (what
                        // `isScreenRecordingGranted` calls) is cached for
                        // the lifetime of the process. After the user
                        // revokes the entry in System Settings, preflight
                        // keeps reporting "granted" — and we lie to the
                        // user. `CGRequestScreenCaptureAccess()` re-queries
                        // tccd, so it's the only honest check available.
                        screenRecordingGranted = PermissionChecker.requestScreenRecording()
                        accessibilityGranted = PermissionChecker.isAccessibilityGranted()
                        microphoneGranted = PermissionChecker.isMicrophoneGranted()
                    }
                    Spacer()
                    // Dev-friendly escape hatch — every Xcode rebuild can
                    // invalidate the TCC entry (code signature changes),
                    // and the "CapyBuddy Pro" row in Privacy → Screen
                    // Recording silently becomes a no-op. Resetting wipes
                    // the entry so the next start-record triggers a fresh
                    // system prompt.
                    Button("Reset Screen Recording Permission…") {
                        resetScreenRecordingPermission()
                    }
                    .help("Wipes the TCC entry for this build. Re-launch and re-grant on the next record.")
                }
            }

            Section("Hotkey") {
                HStack {
                    Text("Start / Stop")
                    Spacer()
                    Button(action: { capturingHotkey = true }) {
                        Text(capturingHotkey ? "Press a key…" : hotkeyStore.current.displayString)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    .background(HotkeyCaptureView(isCapturing: $capturingHotkey) { keyCode, flags in
                        let new = HotkeyConfig(keyCode: keyCode, flags: flags)
                        hotkeyStore.update(new)
                        _ = feature.restartHotkeyTap()
                        capturingHotkey = false
                    })
                }
                Text("From idle, the hotkey opens region selection. While recording, it stops and saves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Video") {
                Picker("Frame rate", selection: $frameRate) {
                    ForEach(frameRateOptions, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .onChange(of: frameRate) { _, new in RecordingPrefs.frameRate = new }

                Picker("Codec", selection: $codec) {
                    ForEach(RecordingPrefs.Codec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }
                .onChange(of: codec) { _, new in RecordingPrefs.codec = new }

                Picker("File format", selection: $fileFormat) {
                    ForEach(RecordingPrefs.FileFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .onChange(of: fileFormat) { _, new in RecordingPrefs.fileFormat = new }

                Picker("Quality", selection: $quality) {
                    ForEach(RecordingPrefs.Quality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .onChange(of: quality) { _, new in RecordingPrefs.quality = new }

                Toggle("Show mouse cursor", isOn: $showsCursor)
                    .onChange(of: showsCursor) { _, new in RecordingPrefs.showsCursor = new }

                Toggle("Highlight mouse clicks", isOn: $highlightCursor)
                    .onChange(of: highlightCursor) { _, new in RecordingPrefs.highlightCursor = new }
            }

            Section("Audio") {
                Toggle("Capture system audio", isOn: $captureSystemAudio)
                    .onChange(of: captureSystemAudio) { _, new in RecordingPrefs.captureSystemAudio = new }
                Toggle("Capture microphone", isOn: $captureMicrophone)
                    .onChange(of: captureMicrophone) { _, new in
                        // Mirror the toolbar's behaviour: flipping mic on
                        // demands a TCC grant. If macOS says no, snap the
                        // toggle back so the UI doesn't lie.
                        handleMicToggleFromSettings(newValue: new)
                    }
                Text("System audio and microphone are written as separate audio tracks. Most video editors will see both; QuickTime Player plays the first track only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Picker("Countdown before start", selection: $countdownSeconds) {
                    ForEach(countdownOptions, id: \.self) { s in
                        Text(s == 0 ? "Off" : "\(s) seconds").tag(s)
                    }
                }
                .onChange(of: countdownSeconds) { _, new in RecordingPrefs.countdownSeconds = new }

                Toggle("Reveal file in Finder when finished", isOn: $revealInFinder)
                    .onChange(of: revealInFinder) { _, new in RecordingPrefs.revealInFinder = new }
            }

            Section("Save to") {
                HStack {
                    Text(saveDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseSaveDirectory() }
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([saveDirectory])
                    }
                }
                if !freeSpaceText.isEmpty {
                    Text(freeSpaceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            screenRecordingGranted = PermissionChecker.isScreenRecordingGranted()
            accessibilityGranted = PermissionChecker.isAccessibilityGranted()
            microphoneGranted = PermissionChecker.isMicrophoneGranted()
            refreshFreeSpace()
        }
    }

    @ViewBuilder
    private func permissionRow(granted: Bool, label: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(button, action: action)
            }
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url
            RecordingPrefs.saveDirectory = url
            refreshFreeSpace()
        }
    }

    private func handleMicToggleFromSettings(newValue: Bool) {
        if !newValue {
            RecordingPrefs.captureMicrophone = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            RecordingPrefs.captureMicrophone = true
        case .notDetermined:
            PermissionChecker.requestMicrophone { granted in
                Task { @MainActor in
                    captureMicrophone = granted
                    RecordingPrefs.captureMicrophone = granted
                    microphoneGranted = granted
                    if !granted { presentMicDeniedAlert() }
                }
            }
        case .denied, .restricted:
            // Snap back — we cannot programmatically un-deny.
            captureMicrophone = false
            RecordingPrefs.captureMicrophone = false
            presentMicDeniedAlert()
        @unknown default:
            captureMicrophone = false
            RecordingPrefs.captureMicrophone = false
        }
    }

    private func presentMicDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone access required"
        alert.informativeText = "macOS hasn't allowed CapyBuddy to use the microphone. Grant access in System Settings → Privacy & Security → Microphone, then turn this on again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionChecker.openMicrophoneSettings()
        }
    }

    private func resetScreenRecordingPermission() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else { return }
        let process = Process()
        process.launchPath = "/usr/bin/tccutil"
        process.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[Recording] tccutil reset failed: \(error)")
        }
        // After the reset, the next attempt to start an SCStream will
        // re-prompt for permission. Tell the user that — and offer the
        // shortcut to System Settings since the prompt only appears once
        // we try to capture.
        let alert = NSAlert()
        alert.messageText = "Permission reset"
        alert.informativeText = "Quit and re-open CapyBuddy, then try recording. macOS will ask for Screen Recording access - grant it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        screenRecordingGranted = PermissionChecker.isScreenRecordingGranted()
    }

    private func refreshFreeSpace() {
        guard let bytes = RecordingPrefs.freeSpaceBytes() else {
            freeSpaceText = ""
            return
        }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB]
        fmt.countStyle = .file
        freeSpaceText = "\(fmt.string(fromByteCount: bytes)) free on this volume"
    }
}

/// NSViewRepresentable that captures the next keyDown while `isCapturing`
/// is true and reports it back. We intentionally don't use HotkeyTap here
/// (that's the global event tap — overkill for a settings UI), an
/// NSEvent local monitor is enough.
private struct HotkeyCaptureView: NSViewRepresentable {
    @Binding var isCapturing: Bool
    let onCapture: (UInt16, CGEventFlags) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isCapturing = isCapturing
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator {
        var isCapturing: Bool = false
        private let onCapture: (UInt16, CGEventFlags) -> Void
        private var monitor: Any?

        init(onCapture: @escaping (UInt16, CGEventFlags) -> Void) {
            self.onCapture = onCapture
        }

        func attach(to view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, self.isCapturing else { return event }
                let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                self.onCapture(event.keyCode, cgFlags)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
