import AppKit
import ScreenCaptureKit
import SwiftUI
import UserNotifications

/// Top-level orchestrator for the Recording feature. Owns one engine, one
/// state object, one toolbar, and the current target picker (if any).
///
/// Flow: user picks a `RecordingMode` from the menu → manager presents the
/// matching target picker (display chooser / window list / region overlay) →
/// once the user commits a target, manager spins up the engine and shows
/// the floating toolbar with start/pause/stop/discard.
@MainActor
final class RecordingManager {

    let state = RecordingState()
    private let engine = RecordingEngine()
    private var toolbar: RecordingToolbarController?
    private let overlays = RecordingOverlayController()
    private var elapsedTimer: Timer?
    /// Active countdown task — held so we can cancel it from the toolbar's
    /// Discard button mid-countdown.
    private var countdownTask: Task<Void, Never>?
    private var pendingTarget: RecordingTarget?

    init() {
        engine.onFinish = { [weak self] result in
            self?.handleFinish(result)
        }
    }

    // MARK: - Mode entry point

    /// Called from the menu — opens the Zoom-style mode chooser, then runs
    /// the per-mode picker, then shows the toolbar.
    func beginRecording() {
        guard state.phase == .idle else { return }
        guard ensurePermission() else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let mode = await RecordingTargetPicker.chooseMode() else { return }
            await self.runPicker(mode: mode)
        }
    }

    /// Direct-mode entry point — used by the global hotkey to jump
    /// straight to region selection without going through the chooser.
    func beginRecording(mode: RecordingMode) {
        guard state.phase == .idle else { return }
        guard ensurePermission() else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.runPicker(mode: mode)
        }
    }

    private func runPicker(mode: RecordingMode) async {
        do {
            let target = try await RecordingTargetPicker.pick(mode: mode, manager: self)
            guard let target else { return } // user cancelled
            self.openToolbar(target: target)
        } catch {
            NSLog("[Recording] target pick failed: \(error)")
        }
    }

    private func ensurePermission() -> Bool {
        if !PermissionChecker.isScreenRecordingGranted() {
            _ = PermissionChecker.requestScreenRecording()
            if !PermissionChecker.isScreenRecordingGranted() {
                presentScreenRecordingDeniedAlert()
                return false
            }
        }
        return true
    }

    /// Called from the global hotkey. Behavior depends on current phase:
    /// recording → stops and saves; paused → resumes (a second hit then
    /// stops); counting → cancels. The hotkey is intentionally NOT a
    /// pause toggle — production recorders treat the hotkey as "make the
    /// recording stop existing as a recording", with pause as a
    /// menu/toolbar-only affordance.
    func toggleFromHotkey() {
        switch state.phase {
        case .recording: stopRecording()
        case .paused:    stopRecording()
        case .counting:  cancelCountdown(discardOutput: true)
        default:         break
        }
    }

    // MARK: - Menu-visible action surface

    func pauseCurrentRecording()   { pauseRecording() }
    func resumeCurrentRecording()  { resumeRecording() }
    func stopCurrentRecording()    { stopRecording() }
    func discardCurrentRecording() { discardRecording() }

    // MARK: - Toolbar lifecycle

    private func openToolbar(target: RecordingTarget) {
        pendingTarget = target
        state.activeTarget = target
        let actions = RecordingToolbarController.Actions(
            onStart:   { [weak self] in self?.startWithOptionalCountdown() },
            onPause:   { [weak self] in self?.pauseRecording() },
            onResume:  { [weak self] in self?.resumeRecording() },
            onStop:    { [weak self] in self?.stopRecording() },
            onDiscard: { [weak self] in self?.discardRecording() },
            onCancel:  { [weak self] in self?.cancelToolbar() }
        )
        let controller = RecordingToolbarController(state: state, actions: actions)
        controller.show(target: target)
        toolbar = controller
        // Show the capture-region frame as soon as the toolbar appears.
        // Users picking a region need to see "this is what's going to be
        // recorded" *before* they click Start, not only after countdown
        // begins — otherwise they're flying blind for the gap between
        // mouse-up on the region picker and clicking Start.
        overlays.showFrame(target: target, state: state)
    }

    private func cancelToolbar() {
        guard state.phase == .idle else { return }
        toolbar?.close()
        toolbar = nil
        overlays.hideFrame()
        overlays.hideCountdown()
        pendingTarget = nil
        state.activeTarget = nil
    }

    // MARK: - Engine drive

    private func startWithOptionalCountdown() {
        guard state.phase == .idle, let target = pendingTarget else { return }
        // Warn if the save volume is nearly full. Don't block — the user
        // might know what they're doing (recording short, or saving
        // elsewhere shortly). Threshold is loose: a 4K 30fps H.264
        // recording at Medium ≈ 100 MB/min, so 1 GB ≈ 10 minutes; less
        // than that is worth a confirm.
        if let bytes = RecordingPrefs.freeSpaceBytes(), bytes < 1_000_000_000 {
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useGB, .useMB]
            fmt.countStyle = .file
            let alert = NSAlert()
            alert.messageText = "Low disk space"
            alert.informativeText = "Only \(fmt.string(fromByteCount: bytes)) free on the save volume. Recording may stop early if it fills up."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Record Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn {
                cancelToolbar()
                return
            }
        }
        let seconds = max(0, RecordingPrefs.countdownSeconds)
        guard seconds > 0 else {
            startEngine(target: target)
            return
        }
        state.phase = .counting
        state.countdownRemaining = seconds
        // Frame is already showing (installed in openToolbar). Just add
        // the centered countdown disc; the frame color updates itself
        // via state.phase observation.
        overlays.showCountdown(state: state, total: seconds)
        countdownTask = Task { [weak self] in
            for s in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.state.countdownRemaining = s
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.state.countdownRemaining = 0
                self.overlays.hideCountdown()
                self.startEngine(target: target)
            }
        }
    }

    /// Mid-countdown abort. `discardOutput` is always true here — nothing
    /// has been written yet, but we still need to reset state.
    private func cancelCountdown(discardOutput: Bool) {
        countdownTask?.cancel()
        countdownTask = nil
        state.phase = .idle
        state.countdownRemaining = 0
        toolbar?.close()
        toolbar = nil
        overlays.hideCountdown()
        overlays.hideFrame()
        pendingTarget = nil
        state.activeTarget = nil
    }

    private func startEngine(target: RecordingTarget) {
        guard state.phase == .idle || state.phase == .counting else { return }
        state.phase = .preparing
        Task { [weak self] in
            guard let self else { return }
            do {
                let outputURL = try RecordingPrefs.makeOutputURL()
                // If the user wants mic capture but TCC hasn't granted it
                // yet, request now. Setting captureMicrophone=true on
                // SCStreamConfiguration without mic permission makes
                // SCK fail the entire capture with -3801 (which is
                // labelled as a screen-capture TCC denial — misleadingly).
                // So we gate explicitly.
                var micWanted = RecordingPrefs.captureMicrophone
                if micWanted && !PermissionChecker.isMicrophoneGranted() {
                    NSLog("[Recording] mic requested but not yet granted - prompting")
                    let granted = await self.requestMicAsync()
                    if !granted {
                        NSLog("[Recording] mic denied - dropping mic from this capture")
                        micWanted = false
                        await MainActor.run {
                            self.presentMicDeniedNotice()
                        }
                    }
                }
                NSLog("""
                [Recording] starting capture: target=\(target), \
                preflightScreen=\(PermissionChecker.isScreenRecordingGranted()), \
                mic=\(micWanted), sysAudio=\(RecordingPrefs.captureSystemAudio), \
                bundle=\(Bundle.main.bundlePath)
                """)
                let configuration = RecordingEngine.Configuration(
                    target: target,
                    frameRate: RecordingPrefs.frameRate,
                    codec: RecordingPrefs.codec,
                    quality: RecordingPrefs.quality,
                    fileFormat: RecordingPrefs.fileFormat,
                    capturesSystemAudio: RecordingPrefs.captureSystemAudio,
                    capturesMicrophone: micWanted,
                    showsCursor: RecordingPrefs.showsCursor,
                    highlightCursor: RecordingPrefs.highlightCursor,
                    outputURL: outputURL
                )
                try await self.engine.start(configuration: configuration)
                self.state.outputURL = outputURL
                self.state.startedAt = Date()
                self.state.pausedDuration = 0
                self.state.pauseStartedAt = nil
                self.state.phase = .recording
                self.startElapsedTicker()
            } catch {
                NSLog("[Recording] start failed: \(error)")
                self.state.reset()
                self.toolbar?.close()
                self.toolbar = nil
                self.pendingTarget = nil
                self.presentStartFailure(error: error)
            }
        }
    }

    private func pauseRecording() {
        guard state.phase == .recording else { return }
        engine.pause()
        state.phase = .paused
        state.pauseStartedAt = Date()
    }

    private func resumeRecording() {
        guard state.phase == .paused else { return }
        if let pauseStart = state.pauseStartedAt {
            state.pausedDuration += Date().timeIntervalSince(pauseStart)
        }
        state.pauseStartedAt = nil
        engine.resume()
        state.phase = .recording
    }

    private func stopRecording() {
        switch state.phase {
        case .counting:
            cancelCountdown(discardOutput: true)
            return
        case .recording, .paused:
            break
        default:
            return
        }
        if state.phase == .paused, let pauseStart = state.pauseStartedAt {
            state.pausedDuration += Date().timeIntervalSince(pauseStart)
            state.pauseStartedAt = nil
        }
        state.phase = .stopping
        engine.stop()
        stopElapsedTicker()
    }

    private func discardRecording() {
        switch state.phase {
        case .counting:
            cancelCountdown(discardOutput: true)
            return
        case .recording, .paused:
            break
        default:
            return
        }
        state.phase = .stopping
        engine.discard()
        stopElapsedTicker()
        // discard() doesn't call onFinish — close UI ourselves.
        toolbar?.close()
        toolbar = nil
        overlays.hideFrame()
        overlays.hideCountdown()
        pendingTarget = nil
        state.reset()
    }

    // MARK: - Finish

    private func handleFinish(_ result: Result<URL, Error>) {
        toolbar?.close()
        toolbar = nil
        overlays.hideFrame()
        overlays.hideCountdown()
        pendingTarget = nil
        stopElapsedTicker()
        switch result {
        case .success(let url):
            state.reset()
            postFinishedNotification(url: url)
            // Hand the fresh clip to the Video Editor when the user has opted
            // in (and the editor feature is enabled). No-op otherwise.
            VideoEditorFeature.openAfterRecording(url: url)
            if RecordingPrefs.revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failure(let error):
            NSLog("[Recording] finalize failed: \(error)")
            state.reset()
            presentFinishFailure(error: error)
        }
    }

    private func postFinishedNotification(url: URL) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Recording saved"
        content.body = url.lastPathComponent
        content.userInfo = ["path": url.path]
        // Custom category with a "Reveal in Finder" button — users who
        // want to jump to the file can click; users who don't are left
        // alone instead of having Finder steal focus every time.
        let revealAction = UNNotificationAction(
            identifier: "capybuddy.recording.reveal",
            title: "Show in Finder"
        )
        let category = UNNotificationCategory(
            identifier: "capybuddy.recording.finished",
            actions: [revealAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
        content.categoryIdentifier = "capybuddy.recording.finished"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    private func presentStartFailure(error: Error) {
        // SCK -3801 means "TCC said no" — which can happen even after our
        // CGPreflight check returns true (the OS preflight cache can lag
        // behind SCStream's own TCC lookup, especially for dev builds
        // whose code signature changes every rebuild). Give the user the
        // exact remediation steps instead of a raw error blob.
        if isScreenCaptureTCCDenied(error) {
            let alert = NSAlert()
            alert.messageText = "Screen recording was blocked by macOS"
            alert.informativeText = """
                SCK refused to start the capture. macOS's permission table is out of sync with the running binary — this is normal during development because every Xcode rebuild changes the code signature.

                One-click fix: Reset & Quit. Then re-launch CapyBuddy and try recording again — the system will prompt you fresh, click Allow.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reset & Quit")
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                resetTCCAndQuit()
            case .alertSecondButtonReturn:
                PermissionChecker.openScreenRecordingSettings()
            default:
                break
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Couldn't start recording"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func resetTCCAndQuit() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let bundlePath = Bundle.main.bundlePath
        if !bundleID.isEmpty {
            // Reset BOTH ScreenCapture and Microphone — -3801 fires when
            // either is denied while SCK was asked for both, and at this
            // point we don't know which of the two is the offender.
            for service in ["ScreenCapture", "Microphone"] {
                let p = Process()
                p.launchPath = "/usr/bin/tccutil"
                p.arguments = ["reset", service, bundleID]
                try? p.run()
                p.waitUntilExit()
            }
        }
        // Auto-relaunch instead of forcing the user to double-click the
        // .app again. We launch via /bin/sh so the open command outlives
        // our terminate.
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func isScreenCaptureTCCDenied(_ error: Error) -> Bool {
        // EngineError.captureStartFailed wraps the underlying NSError from
        // SCStream. Unwrap if needed before reading the code/domain.
        let underlying: Error
        if case RecordingEngine.EngineError.captureStartFailed(let inner) = error {
            underlying = inner
        } else {
            underlying = error
        }
        let ns = underlying as NSError
        return ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801
    }

    private func presentFinishFailure(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording finished with an error"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func requestMicAsync() async -> Bool {
        await withCheckedContinuation { cont in
            PermissionChecker.requestMicrophone { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func presentMicDeniedNotice() {
        let alert = NSAlert()
        alert.messageText = "Microphone not available"
        alert.informativeText = "Microphone capture is enabled in the toolbar but macOS denied access. Recording will continue without microphone. Grant access in System Settings → Privacy & Security → Microphone if you want it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            PermissionChecker.openMicrophoneSettings()
        }
    }

    private func presentScreenRecordingDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = "Grant CapyBuddy access to Screen Recording in System Settings, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionChecker.openScreenRecordingSettings()
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTicker() {
        stopElapsedTicker()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.state.tickCounter &+= 1 }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTicker() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
