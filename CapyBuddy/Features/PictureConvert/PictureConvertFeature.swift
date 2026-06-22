import AppKit
import SwiftUI

@MainActor
final class PictureConvertFeature: NSObject, Feature {

    let id = "pictureConvert"
    let displayName = String(localized: "Picture Converter")
    let iconSystemName = "photo.on.rectangle.angled"
    let summary = String(localized: "Drag-and-drop converter between common picture formats (PNG, JPEG, HEIC, TIFF, GIF, AVIF, ICO, BMP, ICNS, JP2).")

    /// Direct action: clicking the dropdown row opens the converter
    /// directly. No submenu, no Settings tab — nothing to configure
    /// outside the window itself.
    var isDirectAction: Bool { true }

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    let queue = ConversionQueue()
    private(set) var window: PictureConvertWindow?

    func start() {
        guard window == nil else { return }
        window = PictureConvertWindow(queue: queue)
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
