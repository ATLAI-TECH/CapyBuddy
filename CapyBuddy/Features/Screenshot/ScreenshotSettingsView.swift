import SwiftUI
import Translation

struct ScreenshotSettingsView: View {

    let feature: ScreenshotFeature
    @ObservedObject private var hotkeyStore = HotkeyConfigStore.shared
    @State private var screenRecordingGranted = PermissionChecker.isScreenRecordingGranted()
    #if CAPYBUDDY_DIRECT
    @State private var accessibilityGranted = PermissionChecker.isAccessibilityGranted()
    #endif
    @AppStorage(TranslationPrefs.targetLanguageKey)
    private var translateTargetLanguage: String = TranslationPrefs.targetLanguage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Capture a region of your screen, annotate it, then pin / copy / save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !screenRecordingGranted {
                    screenRecordingBanner
                }
                #if CAPYBUDDY_DIRECT
                if !accessibilityGranted {
                    accessibilityBanner
                }
                #endif

                GroupBox("Trigger shortcut") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: selectedPresetBinding) {
                            ForEach(HotkeyConfig.presets) { preset in
                                VStack(alignment: .leading) {
                                    Text(preset.label)
                                        .font(.body)
                                    Text(preset.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(preset.id)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        Text("Press this combination anywhere to start a region capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Quick capture") {
                    HStack {
                        Text("Trigger a region capture now.")
                        Spacer()
                        Button {
                            feature.manager.captureRegion()
                        } label: {
                            Label("Capture Region", systemImage: "camera.viewfinder")
                        }
                    }
                    .padding(8)
                }

                GroupBox("After-capture controls") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• Drag inside the selection to annotate (only Rectangle in this build).").font(.callout)
                        Text("• ⎋ Cancel · ↩ Pin · ⌘C Copy · ⌘S Save · ⌘Z Undo").font(.callout)
                        Text("• Pinned windows: drag to move · double-click / ⎋ to close · right-click for Copy / Save As…").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .padding(8)
                }

                #if CAPYBUDDY_DIRECT
                GroupBox("Snap-to-element") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(accessibilityGranted ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(accessibilityGranted ? "Element-level snap is on." : "Element-level snap is off.")
                                .font(.callout)
                            Text(accessibilityGranted
                                 ? "Hover a button, text field, or sub-region to snap to its bounds. Click without dragging to capture; drag anywhere to override with a manual rect."
                                 : "Grant Accessibility permission to snap to UI elements (buttons, text fields, subviews). Falls back to whole-window snap when denied.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                #endif

                GroupBox("Translation") {
                    TranslationSettingsSection(targetLanguage: $translateTargetLanguage)
                        .padding(8)
                }
            }
            .padding(.bottom, 8)
        }
        .onAppear {
            screenRecordingGranted = PermissionChecker.isScreenRecordingGranted()
            #if CAPYBUDDY_DIRECT
            accessibilityGranted = PermissionChecker.isAccessibilityGranted()
            #endif
        }
    }

    // MARK: - Hotkey selection binding

    private var selectedPresetBinding: Binding<String> {
        Binding(
            get: {
                let current = hotkeyStore.current
                return HotkeyConfig.presets.first(where: { $0.config == current })?.id
                    ?? HotkeyConfig.presets[0].id
            },
            set: { newID in
                if let preset = HotkeyConfig.presets.first(where: { $0.id == newID }) {
                    hotkeyStore.update(preset.config)
                }
            }
        )
    }

    // MARK: - Permission banners

    private var screenRecordingBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Screen Recording permission required").bold()
                Text("Screenshot needs Screen Recording permission to capture pixels. Open System Settings, then return here.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") {
                        PermissionChecker.openScreenRecordingSettings()
                    }
                    Button("Recheck") {
                        screenRecordingGranted = PermissionChecker.isScreenRecordingGranted()
                    }
                }
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    #if CAPYBUDDY_DIRECT
    private var accessibilityBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility permission unlocks more").bold()
                Text("Without it, snap-to-element falls back to whole-window snap. The global trigger shortcut still works without it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Accessibility Settings") {
                        PermissionChecker.openAccessibilitySettings()
                    }
                    Button("Recheck") {
                        accessibilityGranted = PermissionChecker.isAccessibilityGranted()
                    }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
    #endif
}

// MARK: - Translation section
//
// Two halves:
//   1. **Default target language** — Picker bound to `TranslationPrefs.targetLanguageKey`
//      via @AppStorage. Changing it instantly affects the next translation.
//   2. **Language packs** — One row per supported language with a live
//      status badge (Ready / Download / Unsupported) and an inline
//      "Download" button. Tapping kicks off `TranslationSession.prepareTranslation()`
//      via a hidden `.translationTask` modifier; macOS shows its own
//      consent dialog and progress UI, then we re-query availability
//      to flip the badge to ✓ Ready.

private struct TranslationSettingsSection: View {

    @Binding var targetLanguage: String
    /// Bound to the same UserDefaults key as `TranslationPrefs.hasPromptedForTarget`
    /// so we can show / hide the Reset button reactively without polling.
    @AppStorage(TranslationPrefs.hasPromptedForTargetKey)
    private var hasPromptedForTarget: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Default target language:", selection: $targetLanguage) {
                    ForEach(TranslationPrefs.supportedLanguages) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360)
                .onChange(of: targetLanguage) { _, _ in
                    // Setting a default in Settings counts as the user
                    // making a choice — skip the first-time popover going
                    // forward.
                    hasPromptedForTarget = true
                }
                Spacer()
            }

            HStack(spacing: 6) {
                if hasPromptedForTarget {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("First-time prompt has fired. New screenshots translate directly to the language above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset first-time prompt") {
                        TranslationPrefs.resetFirstTimePrompt()
                    }
                    .controlSize(.small)
                    .help("Clear the flag so the next click on Translate shows the language picker again.")
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("First Translate click will pop up a language picker so you can confirm the target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Language packs")
                    .font(.subheadline.bold())
                Text("Pre-download the languages you'll need so translation works offline. macOS handles the actual download - first-time use of a missing pack triggers the system download prompt automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(TranslationPrefs.supportedLanguages) { lang in
                    LanguagePackRow(language: lang)
                    if lang.id != TranslationPrefs.supportedLanguages.last?.id {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

private struct LanguagePackRow: View {

    let language: TranslationPrefs.SupportedLanguage

    @State private var status: LanguageAvailability.Status?
    @State private var prepareConfig: TranslationSession.Configuration?
    @State private var isPreparing: Bool = false

    var body: some View {
        HStack {
            Text(language.name)
                .font(.callout)
            Spacer()
            statusView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .task(id: language.code) {
            await refreshStatus()
        }
        // Hidden translation host. When `prepareConfig` is set, macOS
        // hands us a fresh TranslationSession — we call
        // `prepareTranslation()` to fetch / install the pack, then
        // re-query availability to flip the badge.
        .translationTask(prepareConfig) { session in
            isPreparing = true
            do {
                try await session.prepareTranslation()
            } catch {
                NSLog("[CapyBuddy] prepareTranslation failed for \(language.code): \(error.localizedDescription)")
            }
            await refreshStatus()
            isPreparing = false
            // Reset the config so a future tap re-fires (translationTask
            // only runs again when this value changes).
            prepareConfig = nil
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if isPreparing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch status {
            case .installed:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.caption.weight(.medium))
            case .supported:
                Button("Download") {
                    prepareConfig = TranslationSession.Configuration(
                        source: nil,
                        target: Locale.Language(identifier: language.code)
                    )
                }
                .controlSize(.small)
            case .unsupported:
                Label("Unsupported", systemImage: "minus.circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .none:
                ProgressView().controlSize(.mini)
            @unknown default:
                EmptyView()
            }
        }
    }

    private func refreshStatus() async {
        let target = Locale.Language(identifier: language.code)
        let availability = LanguageAvailability()
        // `LanguageAvailability.status(from:to:)` requires a concrete
        // source language — there's no `nil` (auto-detect) overload like
        // the one we use at translation time. English is the closest
        // universal source: any target's "Ready" badge should at least
        // mean en→target is installed, which covers the vast majority of
        // screenshot text. Targets that are the same as the source short-
        // circuit to ".installed" implicitly.
        let englishSource = Locale.Language(identifier: "en-US")
        let probeSource = (target == englishSource)
            ? Locale.Language(identifier: "zh-Hans")
            : englishSource
        status = await availability.status(from: probeSource, to: target)
    }
}
