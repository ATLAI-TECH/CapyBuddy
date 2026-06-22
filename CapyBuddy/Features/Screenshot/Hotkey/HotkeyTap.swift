import AppKit
import Carbon.HIToolbox

/// Global hotkey registration via Apple's official Carbon `RegisterEventHotKey`
/// API. Does NOT require Accessibility permission (compare CGEventTap, which
/// would). When the configured key combo is pressed anywhere on the system,
/// `onTrigger` fires on the main thread.
///
/// Limitations vs. the old CGEventTap design:
///   - Carbon hotkeys only support the four standard modifier bits
///     (cmd / shift / option / control). The `fn` modifier and modifier-less
///     bindings aren't supported and won't register.
///   - macOS owns conflict resolution: if the user's combo is already
///     claimed by the system (e.g. Spotlight on ⌘Space), registration
///     simply fails and `start()` returns false.
@MainActor
final class HotkeyTap {

    typealias TriggerHandler = () -> Void

    // Shared registry: the Carbon event handler is a single C function;
    // it routes incoming presses to the right instance by `EventHotKeyID.id`.
    private static var nextID: UInt32 = 1
    private static var liveTaps: [UInt32: HotkeyTap] = [:]
    private static var sharedHandlerInstalled = false

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyID: UInt32 = 0

    /// Mutable so callers can swap the shortcut at runtime. If the tap is
    /// already active, the didSet re-registers transparently.
    var config: HotkeyConfig {
        didSet {
            guard isActive, oldValue != config else { return }
            stop()
            _ = start()
        }
    }

    var onTrigger: TriggerHandler?

    init(config: HotkeyConfig) {
        self.config = config
    }

    var isActive: Bool { hotKeyRef != nil }

    @discardableResult
    func start() -> Bool {
        guard hotKeyRef == nil else { return true }
        let mods = Self.carbonModifiers(from: config.flags)
        // Carbon refuses bindings with no modifiers; bail early so callers
        // can surface a clearer error than a generic OSStatus.
        guard mods != 0 else { return false }

        Self.installSharedHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID &+= 1
        let hotID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            mods,
            hotID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        self.hotKeyRef = ref
        self.hotKeyID = id
        Self.liveTaps[id] = self
        return true
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        Self.liveTaps.removeValue(forKey: hotKeyID)
        hotKeyRef = nil
        hotKeyID = 0
    }

    deinit {
        // Safety-net unregister; the live-taps dictionary holds a strong
        // ref to self, so deinit only fires after `stop()` already cleared
        // both the dict entry and `hotKeyRef`. We deliberately don't touch
        // the dict here — its mutator is @MainActor-isolated and deinit
        // isn't, so any cleanup must happen via the explicit `stop()`.
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }

    // MARK: - Shared Carbon event handler

    // 'CBUY' — four-char identifier for our hotkey signature. Carbon doesn't
    // care what we use as long as it's stable across registrations.
    private static let signature: OSType = 0x43425559

    private static func installSharedHandlerIfNeeded() {
        guard !sharedHandlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard err == noErr else { return err }
                let routedID = receivedID.id
                MainActor.assumeIsolated {
                    HotkeyTap.liveTaps[routedID]?.onTrigger?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
        sharedHandlerInstalled = true
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskCommand)   { mods |= UInt32(cmdKey) }
        if flags.contains(.maskShift)     { mods |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskControl)   { mods |= UInt32(controlKey) }
        return mods
    }
}
