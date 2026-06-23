#if CAPYBUDDY_DIRECT

import AppKit
#if canImport(Sparkle)
import Sparkle

@MainActor
final class UpdaterController {

    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        // `startingUpdater: true` kicks off Sparkle's background poll loop
        // immediately, using SUFeedURL from Info.plist. Delegates are nil
        // for now — the standard controller already shows the default
        // update UI; we only need a custom delegate if we want to gate
        // updates on license state, beta channel selection, etc.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

#else

// Sparkle SwiftPM package not added yet — keep call sites compiling.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()
    private init() {}
    func checkForUpdates() {
        NSLog("[CapyBuddy] UpdaterController: Sparkle package not linked; skipping update check.")
    }
}

#endif

#endif
