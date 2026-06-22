import AppKit

/// Persists the last-used annotation tool, colour, and stroke width so they
/// survive across capture sessions (and app launches).
///
/// All getters/setters operate on an in-memory mirror that's the source of
/// truth in-process. Writes to `UserDefaults` are debounced (200ms) onto a
/// background queue so rapid color/stroke clicks during a capture session
/// never block the main thread on disk I/O.
@MainActor
final class AnnotationPrefsStore {

    static let shared = AnnotationPrefsStore()

    private let toolKey   = "CapyBuddy.Screenshot.tool"
    private let colorKey  = "CapyBuddy.Screenshot.colorHex"
    private let strokeKey = "CapyBuddy.Screenshot.strokeWidth"
    private let groupPickKeyPrefix = "CapyBuddy.Screenshot.groupPick."
    private let textStyleKey = "CapyBuddy.Screenshot.textStyle"

    /// Pending writes — key → value-encoder closure. Flushed on the
    /// background queue 200ms after the last set.
    private var pendingWrites: [String: () -> Void] = [:]
    private var flushWorkItem: DispatchWorkItem?
    private static let flushQueue = DispatchQueue(label: "CapyBuddy.AnnotationPrefsStore.flush", qos: .utility)

    // In-memory mirror, lazily populated from UserDefaults on first access.
    private lazy var _tool: AnnotationTool = {
        guard let raw = UserDefaults.standard.string(forKey: toolKey),
              let t = AnnotationTool(rawValue: raw) else { return .rectangle }
        return t
    }()
    private lazy var _color: NSColor = {
        guard let hex = UserDefaults.standard.string(forKey: colorKey),
              let c = Self.color(fromHex: hex) else { return .systemRed }
        return c
    }()
    private lazy var _strokeWidth: StrokeWidth = {
        let raw = UserDefaults.standard.double(forKey: strokeKey)
        return StrokeWidth(rawValue: CGFloat(raw)) ?? .medium
    }()
    private lazy var _textStyle: TextStyle = {
        let mask = UserDefaults.standard.integer(forKey: textStyleKey)
        return TextStyle(
            bold:      (mask & 0b001) != 0,
            italic:    (mask & 0b010) != 0,
            underline: (mask & 0b100) != 0
        )
    }()
    private var _lastByGroupCache: [ToolGroup: AnnotationTool] = [:]

    private init() {
        runMigrations()
    }

    /// One-shot fix-ups for prefs that older builds wrote in a way users now
    /// find surprising. Each migration must be idempotent.
    private func runMigrations() {
        let brushKey = groupPickKeyPrefix + ToolGroup.brush.rawValue
        if UserDefaults.standard.string(forKey: brushKey) == AnnotationTool.mosaic.rawValue {
            UserDefaults.standard.removeObject(forKey: brushKey)
        }
        if UserDefaults.standard.string(forKey: toolKey) == AnnotationTool.mosaic.rawValue {
            UserDefaults.standard.set(AnnotationTool.pen.rawValue, forKey: toolKey)
        }
    }

    var tool: AnnotationTool {
        get { _tool }
        set {
            _tool = newValue
            schedule(toolKey) { [val = newValue.rawValue, key = toolKey] in
                UserDefaults.standard.set(val, forKey: key)
            }
        }
    }

    var color: NSColor {
        get { _color }
        set {
            _color = newValue
            if let hex = Self.hex(from: newValue) {
                schedule(colorKey) { [hex, key = colorKey] in
                    UserDefaults.standard.set(hex, forKey: key)
                }
            }
        }
    }

    var strokeWidth: StrokeWidth {
        get { _strokeWidth }
        set {
            _strokeWidth = newValue
            schedule(strokeKey) { [val = Double(newValue.rawValue), key = strokeKey] in
                UserDefaults.standard.set(val, forKey: key)
            }
        }
    }

    /// Last-used sub-tool per group, e.g. `shape → .ellipse` so re-clicking
    /// the Shape group icon picks ellipse again.
    func lastTool(in group: ToolGroup) -> AnnotationTool {
        if let cached = _lastByGroupCache[group] { return cached }
        let key = groupPickKeyPrefix + group.rawValue
        let resolved: AnnotationTool
        if let raw = UserDefaults.standard.string(forKey: key),
           let t = AnnotationTool(rawValue: raw),
           t.group == group {
            resolved = t
        } else {
            resolved = group.members.first!
        }
        _lastByGroupCache[group] = resolved
        return resolved
    }

    func setLastTool(_ tool: AnnotationTool, in group: ToolGroup) {
        _lastByGroupCache[group] = tool
        let key = groupPickKeyPrefix + group.rawValue
        schedule(key) { [val = tool.rawValue, key] in
            UserDefaults.standard.set(val, forKey: key)
        }
    }

    var textStyle: TextStyle {
        get { _textStyle }
        set {
            _textStyle = newValue
            var mask = 0
            if newValue.bold      { mask |= 0b001 }
            if newValue.italic    { mask |= 0b010 }
            if newValue.underline { mask |= 0b100 }
            schedule(textStyleKey) { [mask, key = textStyleKey] in
                UserDefaults.standard.set(mask, forKey: key)
            }
        }
    }

    // MARK: - Debounced flush

    private func schedule(_ key: String, _ apply: @escaping () -> Void) {
        pendingWrites[key] = apply
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Hop to the main actor to drain the buffer, then dispatch to
            // background for the actual UserDefaults writes.
            Task { @MainActor in
                let drained = self.pendingWrites
                self.pendingWrites.removeAll()
                Self.flushQueue.async {
                    for (_, apply) in drained { apply() }
                }
            }
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    // MARK: - Color <-> hex

    /// Round-trip via sRGB so we can recover the same NSColor next launch
    /// even if the user picked a system colour.
    private static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func color(fromHex hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8)  & 0xFF) / 255,
            blue:  CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
