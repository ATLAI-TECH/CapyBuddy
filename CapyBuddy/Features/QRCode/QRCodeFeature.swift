import AppKit
import SwiftUI

@MainActor
final class QRCodeFeature: NSObject, Feature {

    let id = "qrCode"
    let displayName = String(localized: "QR Code")
    let iconSystemName = "qrcode"
    let summary = String(localized: "Generate QR codes - colors, dot/eye shapes, embedded logo, save or copy.")

    /// Direct action: clicking the dropdown row opens the generator
    /// directly. No submenu, no Settings tab — there's nothing to
    /// configure separately from the window itself.
    var isDirectAction: Bool { true }

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    private(set) var window: QRCodeWindow?

    func start() {
        guard window == nil else { return }
        window = QRCodeWindow()
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
