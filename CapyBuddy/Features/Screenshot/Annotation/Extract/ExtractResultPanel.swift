import AppKit
import SwiftUI
import Translation

/// Floating panel for the **OCR** flow only. Shows the recognized text
/// and (on demand) a side-by-side translation that the user can copy as
/// plain text.
///
/// In-place image translation does NOT use this panel anymore — that
/// flow lives in the annotation toolbar and paints the translated
/// bitmap directly onto the screenshot canvas (Google-Lens style).
@MainActor
final class ExtractResultPanel: NSPanel {

    init(viewModel: ExtractResultViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = "Text"
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .visible
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = true
        self.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let host = NSHostingController(rootView: ExtractResultView(viewModel: viewModel))
        self.contentViewController = host
    }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        self.isRestorable = false
    }

    /// Position adjacent to the selection rect (right side preferred,
    /// then left, then center-on-screen as last resort).
    func position(adjacentTo selectionRect: NSRect, on screen: NSScreen) {
        let panelSize = self.frame.size
        let gap: CGFloat = 12

        let rightX = selectionRect.maxX + gap
        let leftX  = selectionRect.minX - panelSize.width - gap
        let canFitRight = rightX + panelSize.width <= screen.frame.maxX - gap
        let canFitLeft  = leftX >= screen.frame.minX + gap

        var origin = NSPoint(
            x: canFitRight ? rightX : (canFitLeft ? leftX : (screen.frame.midX - panelSize.width / 2)),
            y: max(screen.frame.minY + gap, selectionRect.midY - panelSize.height / 2)
        )
        let maxY = screen.frame.maxY - panelSize.height - gap
        origin.y = min(origin.y, maxY)
        origin.y = max(origin.y, screen.frame.minY + gap)
        self.setFrameOrigin(origin)
    }
}

@MainActor
final class ExtractResultViewModel: ObservableObject {

    enum LoadState: Equatable {
        case loading
        case ready(String)
        case failed(String)
    }

    @Published var ocrState: LoadState = .loading
    @Published var translatedText: String?
    @Published var translationError: String?
    @Published var isTranslatingText: Bool = false

    /// Configuration bound to `.translationTask`. Setting it spins up a
    /// fresh `TranslationSession`; nilling is a no-op.
    @Published var textTranslationConfig: TranslationSession.Configuration?
    @Published var targetLanguageCode: String

    private let runOCR: () async throws -> String

    init(targetLanguageCode: String = TranslationPrefs.targetLanguage,
         runOCR: @escaping () async throws -> String) {
        self.targetLanguageCode = targetLanguageCode
        self.runOCR = runOCR
    }

    func performOCR() async {
        ocrState = .loading
        do {
            let text = try await runOCR()
            ocrState = .ready(text)
        } catch {
            ocrState = .failed(error.localizedDescription)
        }
    }

    func startTextTranslation() {
        guard case .ready(let text) = ocrState, !text.isEmpty else { return }
        isTranslatingText = true
        translatedText = nil
        translationError = nil
        textTranslationConfig = TranslationSession.Configuration(
            source: nil,
            target: Locale.Language(identifier: targetLanguageCode)
        )
    }

    func runTextTranslation(_ session: TranslationSession) async {
        guard case .ready(let text) = ocrState else { return }
        do {
            let response = try await session.translate(text)
            translatedText = response.targetText
            translationError = nil
        } catch {
            translationError = error.localizedDescription
            translatedText = nil
        }
        isTranslatingText = false
    }
}

/// SwiftUI body of the OCR result panel.
struct ExtractResultView: View {

    @ObservedObject var viewModel: ExtractResultViewModel

    /// Source-of-truth for the target language picker. Shared with
    /// Screenshot Settings so the OCR panel and the in-place translator
    /// don't drift apart.
    private var languageOptions: [TranslationPrefs.SupportedLanguage] {
        TranslationPrefs.supportedLanguages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ocrSection
            Divider()
            translationSection
        }
        .frame(minWidth: 320, minHeight: 320)
        .translationTask(viewModel.textTranslationConfig) { session in
            await viewModel.runTextTranslation(session)
        }
        .task {
            await viewModel.performOCR()
        }
    }

    private var ocrSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Recognized text", systemImage: "text.viewfinder")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if case .ready(let text) = viewModel.ocrState {
                    Button {
                        copy(text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .help("Copy recognized text")
                    .buttonStyle(.borderless)
                }
            }
            ocrBody
        }
        .padding(12)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var ocrBody: some View {
        switch viewModel.ocrState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recognizing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .ready(let text):
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .default))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .failed(let msg):
            Text(msg)
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Translation", systemImage: "character.book.closed")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $viewModel.targetLanguageCode) {
                    ForEach(languageOptions) { opt in
                        Text(opt.name).tag(opt.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
                Button {
                    viewModel.startTextTranslation()
                } label: {
                    if viewModel.isTranslatingText {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Translate", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .controlSize(.small)
                .disabled({
                    if case .ready(let t) = viewModel.ocrState, !t.isEmpty {
                        return viewModel.isTranslatingText
                    }
                    return true
                }())
                if let translated = viewModel.translatedText {
                    Button {
                        copy(translated)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .help("Copy translated text")
                    .buttonStyle(.borderless)
                }
            }
            translationBody
        }
        .padding(12)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var translationBody: some View {
        if let translated = viewModel.translatedText {
            ScrollView {
                Text(translated)
                    .font(.system(.body, design: .default))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } else if let err = viewModel.translationError {
            Text(err)
                .foregroundStyle(.secondary)
                .italic()
        } else if viewModel.isTranslatingText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating…").foregroundStyle(.secondary)
            }
        } else {
            Text("Pick a target language and hit Translate.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
