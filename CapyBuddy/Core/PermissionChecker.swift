import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum PermissionChecker {

    // MARK: - Accessibility (Pro-only)
    //
    // The MAS build of CapyBuddy uses Carbon `RegisterEventHotKey` for its
    // global hotkey (no permission needed) and does not call any AX APIs.
    // Accessibility is only requested in the Pro target — for SpaceShortcut's
    // CGEventTap-based chord listener and for the snap-to-element overlay in
    // Screenshot — both of which the App Store reviewer would reject under
    // guideline 2.4.5. Gating these helpers behind `CAPYBUDDY_DIRECT` keeps the
    // MAS binary from referencing AX entirely.

    #if CAPYBUDDY_DIRECT
    static func isAccessibilityGranted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    #endif

    // MARK: - Screen Recording

    static func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone

    /// True if the user has granted microphone access to this app. This is
    /// queried via AVCaptureDevice, which does NOT cache across the
    /// process lifetime — it re-reads TCC each call (unlike
    /// CGPreflightScreenCaptureAccess which infamously caches).
    static func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Request microphone access. If status is `.notDetermined`, this
    /// triggers the system prompt. Completion fires on whatever queue the
    /// AV machinery feels like — caller is responsible for hopping back to
    /// MainActor.
    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
