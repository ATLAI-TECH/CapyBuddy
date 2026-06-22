import AppKit
import SwiftUI

/// What controls a given annotation type exposes in its floating config
/// popover. Computed from the tool kind.
enum ConfigSection: Hashable {
    case color       // 8 swatches
    case strokeWidth // S/M/L
    case textStyle   // B/I/U
}

extension AnnotationTool {
    /// Which controls the per-annotation popover should render for this
    /// annotation kind. Mosaic intentionally hides color (it samples from the
    /// base image); text adds B/I/U.
    var configSections: [ConfigSection] {
        switch self {
        case .rectangle, .rectangleDashed,
             .ellipse, .ellipseDashed,
             .arrow, .arrowLine, .arrowDashed, .line,
             .pen, .highlight:
            return [.color, .strokeWidth]
        case .mosaic:
            return [.strokeWidth]
        case .text:
            return [.color, .strokeWidth, .textStyle]
        }
    }
}

/// Observable state for the config popover. Mirrors the selected
/// annotation's color / stroke / style so the SwiftUI bindings have something
/// to write back to.
@MainActor
final class AnnotationConfigModel: ObservableObject {
    @Published var tool: AnnotationTool = .rectangle
    @Published var color: NSColor = .systemRed
    @Published var strokeWidth: StrokeWidth = .medium
    @Published var textStyle: TextStyle = .plain

    var onColorChange: ((NSColor) -> Void)?
    var onStrokeChange: ((StrokeWidth) -> Void)?
    var onTextStyleChange: ((TextStyle) -> Void)?

    /// Push `annotation`'s state into this model without firing the change
    /// callbacks (avoids feedback loops when the canvas tells us about a
    /// fresh selection).
    func loadFromAnnotation(_ annotation: Annotation) {
        tool = annotation.tool
        color = annotation.color
        strokeWidth = StrokeWidth(rawValue: annotation.strokeWidth) ?? .medium
        if case .text(_, _, let style) = annotation.geometry {
            textStyle = style
        } else {
            textStyle = .plain
        }
    }
}

/// Borderless floating panel for per-annotation config. Same window-level
/// trick as `AnnotationToolbarPanel` so it sits above the dim overlay and
/// doesn't steal key focus.
final class AnnotationConfigPanel: NSPanel {

    let model: AnnotationConfigModel

    init(model: AnnotationConfigModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isRestorable = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        // The panel must be ALLOWED to become key (otherwise the SwiftUI
        // hex `TextField` can never receive keystrokes — keyDown events
        // only flow to the key window). `becomesKeyOnlyIfNeeded` keeps
        // mouse clicks on swatches / stroke buttons from grabbing key
        // focus; the panel only goes key when a control that requires
        // keyboard input takes first responder (i.e. the hex field).
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false

        let host = FirstMouseHostingView(rootView: AnnotationConfigView(model: model))
        host.frame = self.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        self.contentView?.addSubview(host)
    }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        // Defensive — Cocoa restoration paths.
        self.model = AnnotationConfigModel()
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        self.isRestorable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Cached fitted size per tool, so re-positioning during a drag-end or
    /// edit doesn't keep re-running `invalidateIntrinsicContentSize +
    /// layoutSubtreeIfNeeded` (each pass costs ~1ms in SwiftUI material).
    private var fittedSizeByTool: [AnnotationTool: NSSize] = [:]

    /// Re-measure the SwiftUI content for the current tool's sections, then
    /// place the panel below the annotation's bbox (clamped to the screen).
    /// The annotation rect is in global AppKit coords (bottom-left origin).
    func position(adjacentTo annotationGlobalRect: NSRect, on screen: NSScreen) {
        let tool = model.tool
        let cachedSize = fittedSizeByTool[tool]

        if cachedSize == nil,
           let host = (self.contentView?.subviews.first as? NSHostingView<AnnotationConfigView>) {
            // First measurement for this tool — `fittingSize` returns stale
            // or zero values until the host has actually been measured, so
            // the first selection of a wider tool (e.g. Text adds B/I/U)
            // would otherwise leave the panel too narrow and clip the
            // leftmost swatch.
            host.invalidateIntrinsicContentSize()
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            let measured = NSSize(width: max(120, fitting.width),
                                  height: max(34, fitting.height))
            fittedSizeByTool[tool] = measured
            self.setContentSize(measured)
        } else if let cached = cachedSize, self.frame.size != cached {
            self.setContentSize(cached)
        }

        let panelSize = self.frame.size
        let gap: CGFloat = 8

        // Center the popover horizontally on the annotation; place it below
        // by default, fall back above, then docked inside if neither fits.
        var origin = NSPoint(
            x: annotationGlobalRect.midX - panelSize.width / 2,
            y: annotationGlobalRect.minY - panelSize.height - gap
        )

        if origin.y < screen.frame.minY + gap {
            // Try above.
            let aboveY = annotationGlobalRect.maxY + gap
            if aboveY + panelSize.height <= screen.frame.maxY - gap {
                origin.y = aboveY
            } else {
                origin.y = max(screen.frame.minY + gap, origin.y)
            }
        }

        let minX = screen.frame.minX + gap
        let maxX = screen.frame.maxX - panelSize.width - gap
        origin.x = max(minX, min(maxX, origin.x))

        self.setFrameOrigin(origin)
    }
}

// MARK: - SwiftUI content

private struct AnnotationConfigView: View {
    @ObservedObject var model: AnnotationConfigModel

    var body: some View {
        let sections = model.tool.configSections

        HStack(spacing: 6) {
            if sections.contains(.color) {
                ColorRow(model: model)
            }
            if sections.contains(.color) && sections.contains(.strokeWidth) {
                Divider().frame(height: 18)
            }
            if sections.contains(.strokeWidth) {
                StrokeRow(model: model)
            }
            if sections.contains(.textStyle) {
                Divider().frame(height: 18)
                TextStyleRow(model: model)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
    }
}

private struct ColorRow: View {
    @ObservedObject var model: AnnotationConfigModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ColorPalette.swatches.indices, id: \.self) { i in
                let color = ColorPalette.swatches[i]
                Swatch(color: color, isSelected: model.color == color) {
                    model.color = color
                    model.onColorChange?(color)
                }
            }
            HexField(model: model)
        }
    }
}

/// Tiny `#RRGGBB` text field. Pressing Return parses the value and pushes
/// it through the same `onColorChange` path the swatches use; invalid
/// input pulses the field red without committing.
private struct HexField: View {
    @ObservedObject var model: AnnotationConfigModel
    @State private var text: String = ""
    @State private var invalidPulse: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("#RRGGBB", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 64)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(invalidPulse ? Color.red.opacity(0.25) : Color.primary.opacity(0.06))
            )
            .focused($focused)
            .onAppear { text = Self.hex(from: model.color) }
            .onChange(of: model.color) { _, new in
                if !focused { text = Self.hex(from: new) }
            }
            .onChange(of: focused) { _, isFocused in
                // When the field loses focus (Return committed, click
                // outside, etc.) hand key state back to the screenshot
                // overlay so the canvas's ⌘C/⌘S/ESC shortcuts work
                // again. Otherwise this panel stays key with no first
                // responder, swallowing every keystroke.
                //
                // Deferred a runloop turn: makeKey() inside onChange runs
                // mid view-update, and the resulting first-responder churn
                // mutates SwiftUI focus state — the "Publishing changes
                // from within view updates" warning.
                if !isFocused {
                    DispatchQueue.main.async { Self.restoreOverlayKeyFocus() }
                }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        guard let color = Self.color(fromHex: text) else {
            withAnimation(.easeInOut(duration: 0.12)) { invalidPulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeInOut(duration: 0.2)) { invalidPulse = false }
            }
            return
        }
        model.color = color
        model.onColorChange?(color)
        text = Self.hex(from: color)
        focused = false
    }

    private static func restoreOverlayKeyFocus() {
        for window in NSApp.windows where window is SelectionOverlayWindow {
            window.makeKey()
            return
        }
    }

    static func hex(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }

    static func color(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
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

private struct Swatch: View {
    let color: NSColor
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(nsColor: color))
                if isSelected {
                    Circle()
                        .stroke(Color.primary, lineWidth: 2)
                        .padding(-2)
                }
                if color == .white {
                    Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
                }
            }
            .frame(width: 14, height: 14)
            .scaleEffect(isHovering ? 1.18 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct StrokeRow: View {
    @ObservedObject var model: AnnotationConfigModel

    var body: some View {
        HStack(spacing: 1) {
            ForEach(StrokeWidth.allCases) { width in
                Button {
                    model.strokeWidth = width
                    model.onStrokeChange?(width)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(model.strokeWidth == width
                                  ? Color.accentColor.opacity(0.28)
                                  : Color.clear)
                        Circle()
                            .fill(Color.primary)
                            .frame(width: width.dotSize, height: width.dotSize)
                    }
                    .frame(width: 26, height: 26)
                    // Without this the empty/clear background isn't hit-
                    // testable, so only a tap landing on the tiny dot
                    // counted — the small "S" dot was nearly impossible
                    // to click. contentShape forces the whole 26pt frame
                    // to be the tap target.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stroke \(width.label)")
            }
        }
    }
}

private struct TextStyleRow: View {
    @ObservedObject var model: AnnotationConfigModel

    var body: some View {
        HStack(spacing: 1) {
            toggle(systemName: "bold", help: "Bold", isOn: model.textStyle.bold) {
                model.textStyle.bold.toggle()
                model.onTextStyleChange?(model.textStyle)
            }
            toggle(systemName: "italic", help: "Italic", isOn: model.textStyle.italic) {
                model.textStyle.italic.toggle()
                model.onTextStyleChange?(model.textStyle)
            }
            toggle(systemName: "underline", help: "Underline", isOn: model.textStyle.underline) {
                model.textStyle.underline.toggle()
                model.onTextStyleChange?(model.textStyle)
            }
        }
    }

    @ViewBuilder
    private func toggle(systemName: String, help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor.opacity(0.28) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
