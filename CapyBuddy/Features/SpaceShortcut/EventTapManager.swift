import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Listens globally for "Space-as-leader" chord input.
///
/// Behavior (modelled after SpaceLauncher):
/// - On a Space keyDown we hold it back from the system and start a hold timer
///   (default 200ms). What happens next depends on what the user does:
///     * Releases Space within the timer  → emit a synthetic Space tap (down+up).
///       Net effect: a single space character, identical to a normal Space tap.
///     * Types another key while still inside the timer → user is typing through
///       Space, not chording. Emit the buffered Space keyDown (real keyUp will
///       follow naturally), then let the typed key through. Net effect: a normal
///       "_X" sequence.
///     * Holds past the timer → enter chord mode (HUD callback fires). From this
///       point, Space autorepeats are swallowed, and any chord-bound key will
///       launch its app and be swallowed. Pressing an *unbound* key in chord
///       mode also exits chord mode and emits the buffered Space, then passes
///       the typed key through (graceful fallback for typos).
///     * Releases Space while in chord mode without firing a chord → emit a
///       synthetic Space tap so the keystroke isn't completely lost.
/// - Space combined with any modifier (Cmd/Opt/Ctrl/Shift) bypasses the entire
///   state machine and passes through untouched, so Cmd+Space etc. keep working.
///
/// All synthetic events we post are tagged with an event-source-userData marker
/// so the tap recognises and skips them on the way back through, avoiding loops.
@MainActor
final class EventTapManager {

    typealias ChordHandler = (UInt16) -> Bool          // returns true if launch fired
    typealias ChordModeCallback = (Bool) -> Void

    private enum SpaceState {
        case idle
        case buffering         // Space pressed, < threshold, undecided
        case chordMode         // ≥ threshold, listening for chord
        case spaceDelivered    // Synthetic Space keyDown already sent — treat as normal hold
        case chordFired        // Chord launched; just waiting for Space release
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var spaceState: SpaceState = .idle
    private var spaceDownAt: Date? = nil
    private var pendingTimer: DispatchWorkItem? = nil
    private var firedChordKeys: Set<UInt16> = []

    /// How long Space must be held before chord mode activates.
    var holdThreshold: TimeInterval = 0.2

    var chordHandler: ChordHandler?
    var chordModeDidChange: ChordModeCallback?

    var isActive: Bool { eventTap != nil }

    private static let syntheticMarker: Int64 = 0x4D43_4255_4444_5953  // "MCBUDDYS"

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: EventTapManager.callback,
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        cancelTimer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        if spaceState == .chordMode {
            chordModeDidChange?(false)
        }
        spaceState = .idle
        spaceDownAt = nil
        firedChordKeys.removeAll()
    }

    deinit {
        // We can't access main-actor-isolated stop() from deinit, so do the
        // minimal teardown directly.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

    // MARK: - Callback

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
        return MainActor.assumeIsolated {
            manager.handle(type: type, event: event)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if the system disabled it. While disabled we miss
        // events — most importantly any Space keyUp that landed during the
        // outage. If we were mid-chord, the HUD would otherwise stay glued to
        // the screen until the next Space press. Reset the state machine and
        // notify the HUD to hide.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if spaceState == .chordMode {
                chordModeDidChange?(false)
            }
            resetSpaceState()
            return Unmanaged.passUnretained(event)
        }

        // Pass through any of our own synthetic events untouched.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        let hasModifier = flags.contains(.maskCommand)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)
            || flags.contains(.maskShift)

        if keyCode == UInt16(kVK_Space) {
            return handleSpace(type: type, event: event, isAutoRepeat: isAutoRepeat, hasModifier: hasModifier)
        }
        return handleNonSpace(type: type, event: event, keyCode: keyCode, hasModifier: hasModifier)
    }

    // MARK: - Space handling

    private func handleSpace(type: CGEventType, event: CGEvent, isAutoRepeat: Bool, hasModifier: Bool) -> Unmanaged<CGEvent>? {

        // Cmd/Opt/Ctrl/Shift + Space: bypass entirely.
        if hasModifier {
            if spaceState != .idle {
                cancelTimer()
                if spaceState == .chordMode { chordModeDidChange?(false) }
                resetSpaceState()
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            if !isAutoRepeat {
                // Initial press: start buffering.
                resetSpaceState()
                spaceDownAt = Date()
                spaceState = .buffering
                scheduleChordTimer()
                return nil  // hold back the original keyDown
            }
            // Autorepeat
            switch spaceState {
            case .spaceDelivered:
                return Unmanaged.passUnretained(event)
            case .buffering, .chordMode, .chordFired, .idle:
                return nil
            }
        }

        // keyUp
        let prev = spaceState
        cancelTimer()
        switch prev {
        case .buffering:
            // Quick tap → emit a normal Space tap.
            sendSyntheticSpaceTap()
        case .chordMode:
            // Held into chord mode but user never pressed a chord. Treat as a tap.
            chordModeDidChange?(false)
            sendSyntheticSpaceTap()
        case .spaceDelivered:
            // Synthetic keyDown was already sent; pair it with a synthetic keyUp.
            sendSyntheticSpace(keyDown: false)
        case .chordFired:
            // Chord fired → no Space typed. Just clean up and hide HUD.
            chordModeDidChange?(false)
        case .idle:
            // Real keyUp without a tracked press (e.g. tap was bypassed). Pass it.
            resetSpaceState()
            return Unmanaged.passUnretained(event)
        }
        resetSpaceState()
        return nil
    }

    // MARK: - Non-Space handling

    private func handleNonSpace(type: CGEventType, event: CGEvent, keyCode: UInt16, hasModifier: Bool) -> Unmanaged<CGEvent>? {

        if type == .keyDown {
            switch spaceState {
            case .buffering:
                // User started typing inside the buffer window — definitely not chording.
                cancelTimer()
                sendSyntheticSpace(keyDown: true)
                resendAsSynthetic(event)
                spaceState = .spaceDelivered
                return nil

            case .chordMode:
                // Modifier+key inside chord mode is normal typing, not a chord.
                if hasModifier {
                    chordModeDidChange?(false)
                    sendSyntheticSpace(keyDown: true)
                    resendAsSynthetic(event)
                    spaceState = .spaceDelivered
                    return nil
                }
                // Already-fired chord key autorepeating — swallow the noise.
                if firedChordKeys.contains(keyCode) {
                    return nil
                }
                let handled = chordHandler?(keyCode) ?? false
                if handled {
                    firedChordKeys.insert(keyCode)
                    spaceState = .chordFired
                    // Hide the HUD immediately — the launch already happened, and
                    // if the launched app installs a full-screen overlay (e.g. the
                    // screenshot selection window) we may never see the Space keyUp
                    // that would otherwise dismiss it.
                    chordModeDidChange?(false)
                    return nil
                }
                // Unbound key in chord mode → graceful fallback to typing.
                chordModeDidChange?(false)
                sendSyntheticSpace(keyDown: true)
                resendAsSynthetic(event)
                spaceState = .spaceDelivered
                return nil

            case .chordFired, .spaceDelivered, .idle:
                return Unmanaged.passUnretained(event)
            }
        }

        // keyUp on a chord key — allow re-firing with a future press.
        if firedChordKeys.contains(keyCode) {
            firedChordKeys.remove(keyCode)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Timer

    private func scheduleChordTimer() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.activateChordMode() }
        }
        pendingTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private func cancelTimer() {
        pendingTimer?.cancel()
        pendingTimer = nil
    }

    private func activateChordMode() {
        guard spaceState == .buffering else { return }
        spaceState = .chordMode
        chordModeDidChange?(true)
    }

    private func resetSpaceState() {
        spaceState = .idle
        spaceDownAt = nil
        firedChordKeys.removeAll()
        cancelTimer()
    }

    // MARK: - Synthetic event posting

    private func sendSyntheticSpaceTap() {
        sendSyntheticSpace(keyDown: true)
        sendSyntheticSpace(keyDown: false)
    }

    private func sendSyntheticSpace(keyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Space),
            keyDown: keyDown
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    /// Re-post the original event as synthetic so it lands AFTER the synthetic Space we
    /// just enqueued. Returning passUnretained instead would let it leapfrog the queued
    /// Space and arrive first (e.g. typing "ls -lsht" landed as "ls- lsht").
    private func resendAsSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}
