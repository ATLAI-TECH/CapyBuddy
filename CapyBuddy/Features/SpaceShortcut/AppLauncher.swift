import AppKit

struct AppBinding: Codable, Hashable {
    var bundlePath: String
    var displayName: String
}

@MainActor
enum AppLauncher {

    static func launchOrActivate(_ binding: AppBinding) {
        let url = URL(fileURLWithPath: binding.bundlePath)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Use openApplication unconditionally so a running-but-windowless app
        // (e.g., Obsidian after closing all windows) gets its main window reopened
        // — `NSRunningApplication.activate` would only bring it to the front.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error = error {
                NSLog("[CapyBuddy] Failed to launch %@: %@", binding.bundlePath, error.localizedDescription)
            }
        }
    }
}
