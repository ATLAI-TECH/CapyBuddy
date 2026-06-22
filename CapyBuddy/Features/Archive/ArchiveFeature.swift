import AppKit
import SwiftUI

@MainActor
final class ArchiveFeature: NSObject, Feature {

    let id = "archive"
    let displayName = String(localized: "Compressor")
    let iconSystemName = "archivebox"
    let summary = String(localized: "Compress and extract zip, tar, tar.gz, and gz archives.")

    /// Direct action: clicking the menu row opens the window. No submenu,
    /// no Settings tab — like PictureConverter.
    var isDirectAction: Bool { true }

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    let queue = ArchiveQueue()
    private(set) var window: ArchiveWindow?

    func start() {
        guard window == nil else { return }
        window = ArchiveWindow(queue: queue)
    }

    func stop() {
        window?.close()
        window = nil
    }

    func performMenuBarAction() {
        window?.show()
    }

    func makeSettingsView() -> AnyView {
        AnyView(EmptyView())
    }
}
