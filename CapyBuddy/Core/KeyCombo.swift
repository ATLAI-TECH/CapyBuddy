import AppKit
import Carbon.HIToolbox

struct KeyCombo: Codable, Hashable {
    /// Carbon virtual key code (e.g. kVK_ANSI_A = 0).
    var keyCode: UInt16
    /// Raw modifier flags from NSEvent (Cmd/Option/Ctrl/Shift).
    var modifierFlagsRawValue: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
            .intersection(.deviceIndependentFlagsMask)
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    var displayString: String {
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCombo.keyName(forKeyCode: keyCode))
        return parts.joined()
    }

    static func keyName(forKeyCode code: UInt16) -> String {
        if let printable = printableNames[Int(code)] {
            return printable
        }
        // Fallback: try to map via current keyboard layout.
        if let layoutData = currentKeyboardLayoutData() {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = layoutData.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return -1
                }
                return UCKeyTranslate(
                    base,
                    code,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys,
                    chars.count,
                    &length,
                    &chars
                )
            }
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "Key\(code)"
    }

    private static let printableNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func currentKeyboardLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        return cfData as Data
    }
}
