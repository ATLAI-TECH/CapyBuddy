import Foundation

/// Persisted defaults for the screenshot translation flow. Centralized so
/// the toolbar's in-place translator and the OCR result panel pick the
/// same target language without each having to invent its own key.
enum TranslationPrefs {

    // MARK: - Keys
    private static let defaults = UserDefaults.standard
    static let targetLanguageKey = "screenshot.translateTargetLanguage"
    static let hasPromptedForTargetKey = "screenshot.translateHasPromptedForTarget"

    // MARK: - Target language

    /// User's preferred target language for translation. The system auto-
    /// detects the source language, so we only persist the destination.
    /// Default mirrors the prior hardcoded value (`zh-Hans`) so existing
    /// installs keep their behaviour after an upgrade.
    static var targetLanguage: String {
        get { defaults.string(forKey: targetLanguageKey) ?? "zh-Hans" }
        set { defaults.set(newValue, forKey: targetLanguageKey) }
    }

    /// Has the user ever explicitly picked a target language? Until this
    /// flag flips true, the toolbar's Translate button shows a one-shot
    /// language-picker popover instead of immediately translating with
    /// the silent default. Lets new users learn the feature without
    /// being surprised by Chinese (or whatever the canned default is).
    static var hasPromptedForTarget: Bool {
        get { defaults.bool(forKey: hasPromptedForTargetKey) }
        set { defaults.set(newValue, forKey: hasPromptedForTargetKey) }
    }

    /// Clear the "first time" flag so the language-picker popover appears
    /// again on the next Translate click. Used by the "Reset first-time
    /// prompt" button in Screenshot settings — lets the user re-test the
    /// onboarding flow without nuking their other preferences.
    static func resetFirstTimePrompt() {
        defaults.removeObject(forKey: hasPromptedForTargetKey)
    }

    // MARK: - Supported languages
    //
    // Subset of macOS 26's full Translation roster — the languages
    // worldwide CapyBuddy users actually want as a target. Order matches
    // what we surface in the picker; the array is iterated as-is.
    struct SupportedLanguage: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let supportedLanguages: [SupportedLanguage] = [
        .init(code: "zh-Hans", name: "Chinese (Simplified)"),
        .init(code: "zh-Hant", name: "Chinese (Traditional)"),
        .init(code: "en-US",   name: "English"),
        .init(code: "ja-JP",   name: "Japanese"),
        .init(code: "ko-KR",   name: "Korean"),
        .init(code: "es-ES",   name: "Spanish"),
        .init(code: "fr-FR",   name: "French"),
        .init(code: "de-DE",   name: "German"),
        .init(code: "it-IT",   name: "Italian"),
        .init(code: "pt-BR",   name: "Portuguese"),
        .init(code: "ru-RU",   name: "Russian"),
        .init(code: "ar-SA",   name: "Arabic"),
    ]

    /// Convenience: pretty name for an arbitrary code. Falls back to the
    /// raw code if it's not in the curated list.
    static func displayName(for code: String) -> String {
        supportedLanguages.first(where: { $0.code == code })?.name ?? code
    }
}
