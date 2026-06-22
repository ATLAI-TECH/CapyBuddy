import AppKit
import CoreImage
import NaturalLanguage
import SwiftUI
import Translation

/// Bridges SwiftUI toolbar interactions to the AppKit-side ScreenshotManager.
///
/// As of the post-popover refactor the main toolbar carries only tool-group
/// buttons + global actions (undo/cancel/save/copy/pin). Color, stroke, and
/// text-style controls live in the per-annotation `AnnotationConfigPanel`
/// that floats next to the selected annotation.
@MainActor
final class AnnotationToolbarModel: ObservableObject {
    @Published var currentTool: AnnotationTool = .rectangle
    @Published var currentColor: NSColor = .systemRed
    @Published var currentStrokeWidth: StrokeWidth = .medium
    @Published var textStyle: TextStyle = .plain

    /// Most-recently used sub-tool per group, so re-clicking a group icon
    /// restores the last variant the user picked.
    @Published var lastByGroup: [ToolGroup: AnnotationTool] = [
        .shape: .rectangle,
        .arrow: .arrow,
        .brush: .pen,
        .text:  .text,
    ]

    var onToolChange: ((AnnotationTool) -> Void)?
    var onColorChange: ((NSColor) -> Void)?
    var onStrokeWidthChange: ((StrokeWidth) -> Void)?
    var onTextStyleChange: ((TextStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    /// Triggered by the toolbar's "OCR" button. The handler is expected to
    /// render the current canvas and present the extract result panel.
    var onOCR: (() -> Void)?
    /// Triggered by the toolbar's "Translate" button. Kicks off the
    /// in-place image-translation pipeline directly — no separate panel.
    var onTranslate: (() -> Void)?

    // MARK: - In-place translation pipeline

    /// Source bitmap the translation pipeline runs against. Set by
    /// ScreenshotManager every time it presents the toolbar (and refreshed
    /// whenever the user resizes the selection).
    var sourceCGImage: CGImage?

    /// Target language for the in-place translation. Defaults to whatever
    /// the user picked in Screenshot settings (`TranslationPrefs.targetLanguage`).
    /// Captured at init so each capture session starts with the latest
    /// persisted value but a per-session change doesn't leak back.
    @Published var translateTargetLanguage: String = TranslationPrefs.targetLanguage

    /// Set non-nil to spin up a `TranslationSession` via the toolbar's
    /// `.translationTask` modifier. The published value is read by the
    /// SwiftUI view; bumping it kicks off `runInPlaceTranslation`.
    @Published var translationConfig: TranslationSession.Configuration?

    /// 0...1 progress while the pipeline iterates over OCR fragments.
    /// Nil when idle. The toolbar paints a thin progress strip over the
    /// Translate button so the user knows something is happening without
    /// stealing the canvas.
    @Published var translateProgress: Double?

    /// Last error from the translation pipeline. Surfaced inline next to
    /// the Translate button. Cleared on the next attempt.
    @Published var translateError: String?

    /// Called when the on-image translation finishes. Wired by
    /// ScreenshotManager to swap the canvas's base image to the rendered
    /// translated bitmap.
    var onTranslatedImageReady: ((CGImage) -> Void)?

    /// OCR fragments collected by `startInPlaceTranslation`, consumed by
    /// `runInPlaceTranslation` once the session spins up — recognition only
    /// runs once per attempt.
    private var pendingBoxes: [OCRService.OCRBox] = []

    /// Kick off the pipeline: OCR first, detect the dominant source
    /// language, then mutate `translationConfig` — the `.translationTask`
    /// modifier in `AnnotationToolbarView` watches this value and creates
    /// a fresh session every time it's reset.
    ///
    /// Detecting the source up front fixes two failure modes seen in the
    /// wild: (1) `source: nil` made the session auto-detect per fragment,
    /// which fails on short fragments ("OK", bare numbers) and used to
    /// kill entire runs; (2) text already in the target language produced
    /// an unsupported same-language pairing (TranslationErrorDomain
    /// Code=11) for every fragment with no explanation.
    func startInPlaceTranslation() {
        guard let cgImage = sourceCGImage else {
            translateError = String(localized: "Nothing to translate yet.")
            return
        }
        guard translateProgress == nil else { return }  // already running
        translateError = nil
        translateProgress = 0
        Task { @MainActor in
            let boxes = (try? await OCRService.recognizeBoxes(in: cgImage)) ?? []
            guard !boxes.isEmpty else {
                translateProgress = nil
                translateError = String(localized: "No text found in the image.")
                return
            }
            let target = Locale.Language(identifier: translateTargetLanguage)
            let source = Self.detectLanguage(in: boxes.map(\.text).joined(separator: "\n"))
            if let source, source.languageCode == target.languageCode {
                translateProgress = nil
                let name = TranslationPrefs.displayName(for: translateTargetLanguage)
                translateError = String(
                    localized: "This text is already in \(name) — pick a different target language."
                )
                return
            }
            pendingBoxes = boxes
            translationConfig = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Dominant language of the OCR text, in the Translation framework's
    /// `Locale.Language` space. Nil when detection is unsure — the session
    /// then falls back to its own detection.
    private static func detectLanguage(in text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: lang.rawValue)
    }

    /// Body of the SwiftUI `.translationTask` closure. Translates the
    /// fragments collected by `startInPlaceTranslation`, then composites
    /// the translated bitmap and hands it to `onTranslatedImageReady`.
    func runInPlaceTranslation(_ session: TranslationSession) async {
        guard let cgImage = sourceCGImage else {
            translateProgress = nil
            translateError = String(localized: "Nothing to translate.")
            return
        }
        let boxes = pendingBoxes
        pendingBoxes = []
        guard !boxes.isEmpty else {
            translateProgress = nil
            translateError = String(localized: "No text found in the image.")
            return
        }
        // Surface missing language assets as ONE clear failure instead of
        // N identical per-fragment errors. The capture overlay blocks the
        // system's download sheet from presenting properly, so on failure
        // we point at Settings — its Translation section hosts the
        // download UI in a regular window where the sheet works.
        do {
            try await session.prepareTranslation()
        } catch {
            translateProgress = nil
            translateError = String(
                localized: "Translation languages aren't downloaded yet. Open Settings → Screenshot → Translation to download them, then try again."
            )
            return
        }
        var replacements: [TranslatedImageRenderer.Replacement] = []
        replacements.reserveCapacity(boxes.count)
        var firstError: String?
        for (i, box) in boxes.enumerated() {
            do {
                let response = try await session.translate(box.text)
                replacements.append(.init(
                    normalizedBox: box.normalizedBox,
                    translatedText: response.targetText
                ))
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
                NSLog("[CapyBuddy] Translate-on-image fragment failed: \(error.localizedDescription)")
            }
            translateProgress = Double(i + 1) / Double(boxes.count)
        }
        guard !replacements.isEmpty else {
            translateProgress = nil
            translateError = firstError ?? String(localized: "Translation failed.")
            return
        }
        if let rendered = TranslatedImageRenderer.render(source: cgImage, replacements: replacements) {
            onTranslatedImageReady?(rendered)
            translateProgress = nil
            translateError = nil
        } else {
            translateProgress = nil
            translateError = String(localized: "Couldn't render the translated image.")
        }
    }

    /// Activate a tool and remember it as the group's last-used variant.
    func selectTool(_ tool: AnnotationTool) {
        lastByGroup[tool.group] = tool
        currentTool = tool
        onToolChange?(tool)
    }
}

enum StrokeWidth: CGFloat, CaseIterable, Identifiable {
    case small = 2
    case medium = 4
    case large = 7

    var id: CGFloat { rawValue }
    var label: String {
        switch self {
        case .small:  return "S"
        case .medium: return "M"
        case .large:  return "L"
        }
    }
    /// Diameter shown in the segmented selector.
    var dotSize: CGFloat {
        switch self {
        case .small:  return 5
        case .medium: return 8
        case .large:  return 12
        }
    }
}

/// The 8 quick-pick colors. Picked to be visible on most photo/UI screenshots.
enum ColorPalette {
    static let swatches: [NSColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemBlue,
        .systemPurple,
        .white,
        .black,
    ]
}

/// Floating panel that hosts the SwiftUI annotation toolbar adjacent to the
/// active selection. Borderless, non-activating so the overlay window keeps
/// keyboard focus.
final class AnnotationToolbarPanel: NSPanel {

    private static let defaultSize = NSSize(width: 480, height: 44)

    init(model: AnnotationToolbarModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isRestorable = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        // Must sit ABOVE the SelectionOverlayWindow (which uses .screenSaver),
        // otherwise the overlay's dim layer covers the toolbar visually AND
        // swallows mouse events on the buttons.
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false

        let host = FirstMouseHostingView(rootView: AnnotationToolbarView(model: model))
        host.frame = self.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        self.contentView?.addSubview(host)

        // Resize the panel to whatever the SwiftUI content actually wants —
        // the explicit `defaultSize` above is just a starting frame so the
        // host has something to lay out into.
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            self.setContentSize(fitting)
        }
    }

    /// Defensive override — see SelectionOverlayWindow.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        self.isRestorable = false
    }

    // Must be able to become key: `FirstMouseHostingView.mouseDown` makes
    // the panel key for the duration of a click so SwiftUI's gesture
    // recogniser doesn't drop the event (it ignores mouseDown in non-key
    // windows), then hands key back to the overlay. With this returning
    // false, makeKey() was a no-op and the first toolbar clicks after a
    // selection went nowhere. `becomesKeyOnlyIfNeeded` (set in init) keeps
    // the panel from grabbing key on its own — same setup as
    // AnnotationConfigPanel.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Place the toolbar below the selection by default, right-aligned to its
    /// right edge. Falls back to above if there's no room below, or docks
    /// inside the selection's bottom-right corner if neither side fits.
    func position(adjacentTo selectionRect: NSRect, on screen: NSScreen) {
        let panelSize = self.frame.size
        let gap: CGFloat = 8

        let belowY = selectionRect.minY - panelSize.height - gap
        let aboveY = selectionRect.maxY + gap

        let canFitBelow = belowY >= screen.frame.minY + gap
        let canFitAbove = aboveY + panelSize.height <= screen.frame.maxY - gap

        var origin = NSPoint(
            x: selectionRect.maxX - panelSize.width,
            y: belowY
        )

        if !canFitBelow {
            if canFitAbove {
                origin.y = aboveY
            } else {
                origin.x = selectionRect.maxX - panelSize.width - gap
                origin.y = selectionRect.minY + gap
            }
        }

        let minX = screen.frame.minX + gap
        let maxX = screen.frame.maxX - panelSize.width - gap
        origin.x = max(minX, min(maxX, origin.x))

        self.setFrameOrigin(origin)
    }
}

/// NSHostingView subclass that guarantees button clicks register on the first
/// try even when the panel is not the key window.
///
/// Two problems to fix:
/// 1. `acceptsFirstMouse = true` — without this, a click on a non-key panel
///    is consumed to "activate" the window instead of firing the button.
/// 2. SwiftUI's gesture recogniser silently drops mouseDown when its window
///    is not key (observed in macOS 14/15 with nonactivatingPanel). Making
///    the window key just for the duration of mouseDown/Up processing ensures
///    the gesture fires, then the previous key window regains focus.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window, !panel.isKeyWindow else {
            super.mouseDown(with: event)
            return
        }
        let previousKey = NSApp.keyWindow
        panel.makeKey()
        super.mouseDown(with: event)
        previousKey?.makeKey()
    }
}

// MARK: - Button styles

private struct ToolbarIconButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var width: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: width, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(background(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed { return Color.primary.opacity(0.22) }
        if isSelected { return Color.accentColor.opacity(0.28) }
        return .clear
    }
}

/// Wraps an icon button and exposes a hover-driven background tint without
/// going through a custom NSView.
private struct HoverableIconButton<Label: View>: View {
    let action: () -> Void
    let isSelected: Bool
    let help: String
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(ToolbarIconButtonStyle(isSelected: isSelected))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering && !isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .onHover { isHovering = $0 }
            .help(help)
    }
}

// MARK: - Group split-button (icon click activates last variant; chevron opens menu)

/// Snipaste-style split button. Icon area = primaryAction (activate last
/// variant). The hairline chevron opens the variant picker. We render the
/// chevron ourselves and hide SwiftUI's default menu indicator so it stays
/// small + refined.
private struct ToolGroupButton: View {
    @ObservedObject var model: AnnotationToolbarModel
    let group: ToolGroup

    @State private var isHovering = false

    private var currentMember: AnnotationTool {
        model.lastByGroup[group] ?? group.members.first!
    }

    private var isGroupActive: Bool { model.currentTool.group == group }

    var body: some View {
        if group.members.count == 1 {
            // No chevron — single-member groups (Text) act like a plain button.
            HoverableIconButton(
                action: { model.selectTool(currentMember) },
                isSelected: isGroupActive,
                help: currentMember.tooltip
            ) {
                Image(systemName: currentMember.iconSystemName)
            }
        } else {
            multiMember
        }
    }

    private var multiMember: some View {
        HStack(spacing: 0) {
            Button {
                model.selectTool(currentMember)
            } label: {
                Image(systemName: currentMember.iconSystemName)
            }
            .buttonStyle(ToolbarIconButtonStyle(isSelected: isGroupActive, width: 26))
            // Tooltip reflects the CURRENT variant, not just the group, so
            // hovering tells the user exactly which tool will activate.
            .help(currentMember.tooltip)

            Menu {
                ForEach(group.members) { member in
                    Button {
                        model.selectTool(member)
                    } label: {
                        Label(member.menuLabel, systemImage: member.iconSystemName)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.55))
                    .frame(width: 12, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.plain)
            .help("More \(group.help.lowercased()) styles")
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering && !isGroupActive ? Color.primary.opacity(0.08) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}

private struct AnnotationToolbarView: View {

    @ObservedObject var model: AnnotationToolbarModel
    /// Tracks whether the one-shot first-time language picker is open.
    /// SwiftUI-state because `.popover` needs a binding; drives the
    /// pop-up that appears when the user clicks Translate before they've
    /// ever explicitly chosen a target language.
    @State private var showingLanguagePicker: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ToolGroup.allCases) { group in
                ToolGroupButton(model: model, group: group)
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            HoverableIconButton(
                action: { model.onUndo?() },
                isSelected: false,
                help: "Undo (⌘Z)"
            ) {
                Image(systemName: "arrow.uturn.backward")
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            // OCR + Translate sit on their own subgroup. They don't switch
            // the active drawing tool — clicking immediately runs the
            // operation against the current canvas image and pops a result
            // panel without dismissing the capture session.
            HoverableIconButton(
                action: { model.onOCR?() },
                isSelected: false,
                help: "Extract text (OCR)"
            ) {
                Image(systemName: "text.viewfinder")
            }
            // Translate button doubles as a progress strip while the
            // pipeline is running — saves a row of UI without hiding state.
            ZStack(alignment: .bottom) {
                HoverableIconButton(
                    action: handleTranslateClick,
                    isSelected: model.translateProgress != nil,
                    help: "Translate text on image"
                ) {
                    if model.translateProgress != nil {
                        Image(systemName: "character.book.closed.fill")
                    } else {
                        Image(systemName: "character.book.closed")
                    }
                }
                if let progress = model.translateProgress {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(2, geo.size.width * progress), height: 2)
                            .animation(.linear(duration: 0.15), value: progress)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 3)
                    .allowsHitTesting(false)
                }
            }
            .popover(isPresented: $showingLanguagePicker, arrowEdge: .top) {
                FirstTimeLanguagePicker(
                    initialCode: TranslationPrefs.targetLanguage,
                    onConfirm: { code in
                        TranslationPrefs.targetLanguage = code
                        TranslationPrefs.hasPromptedForTarget = true
                        model.translateTargetLanguage = code
                        showingLanguagePicker = false
                        // Fire the same path a returning user takes.
                        model.onTranslate?()
                    },
                    onCancel: {
                        showingLanguagePicker = false
                    }
                )
            }
            // Translation failures used to die silently (`translateError`
            // had no UI at all) — surface them right where the user clicked.
            .popover(
                isPresented: Binding(
                    get: { model.translateError != nil },
                    set: { if !$0 { model.translateError = nil } }
                ),
                arrowEdge: .top
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(model.translateError ?? "")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: 300, alignment: .leading)
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            // Save / Pin / Copy all use the same icon-button chrome so the
            // toolbar reads as a uniform row of tools. Copy is anchored at
            // the rightmost slot — that's where Cancel used to live, and
            // muscle-memory reach kept landing on it expecting Copy. The
            // Cancel action moved to a small ✕ button on the top-right
            // corner of the selection rectangle.
            HoverableIconButton(
                action: { model.onSave?() },
                isSelected: false,
                help: "Save… (⌘S)"
            ) {
                Image(systemName: "square.and.arrow.down")
            }

            HoverableIconButton(
                action: { model.onPin?() },
                isSelected: false,
                help: "Pin (↩)"
            ) {
                Image(systemName: "pin.fill")
            }

            HoverableIconButton(
                action: { model.onCopy?() },
                isSelected: false,
                help: "Copy (⌘C)"
            ) {
                Image(systemName: "doc.on.doc")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        // Hidden Translation host. The toolbar HAS to be a SwiftUI view
        // for the translation API to attach (no programmatic init for
        // TranslationSession exists), so we piggyback on the toolbar's
        // existing SwiftUI host instead of adding a second NSPanel just
        // to hold this modifier.
        .translationTask(model.translationConfig) { session in
            await model.runInPlaceTranslation(session)
        }
    }

    /// Decides whether the Translate button fires a translation directly
    /// or shows the one-shot first-time language picker. The branch flips
    /// permanently the moment the user picks (or after they manually set
    /// a target via Settings).
    private func handleTranslateClick() {
        if TranslationPrefs.hasPromptedForTarget {
            model.onTranslate?()
        } else {
            showingLanguagePicker = true
        }
    }
}

/// First-time popover anchored to the Translate button. Lists the
/// curated supported languages, lets the user pick one, and fires the
/// translation as soon as Confirm is tapped. After this runs once the
/// popover disappears for good (until the user resets it from Settings).
private struct FirstTimeLanguagePicker: View {

    let initialCode: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedCode: String

    init(initialCode: String, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialCode = initialCode
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selectedCode = State(initialValue: initialCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Translate text into…")
                    .font(.headline)
                Text("Pick the language you'd like the screenshot's text to be translated into. You can change this anytime in Settings → Screenshot → Translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(TranslationPrefs.supportedLanguages) { lang in
                        Button {
                            selectedCode = lang.code
                        } label: {
                            HStack {
                                Text(lang.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if selectedCode == lang.code {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(
                                selectedCode == lang.code
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Translate") {
                    onConfirm(selectedCode)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
