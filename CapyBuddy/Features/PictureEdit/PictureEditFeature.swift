// Picture Editor disabled — feature is not mature yet.
#if false
import AppKit
import SwiftUI

/// Drag-an-image editor: crop, rotate, resize, filter, watermark, and
/// background removal (Vision-powered). Lives behind a menu-bar item;
/// the dropdown row IS "open the editor" — no separate enabled toggle.
@MainActor
final class PictureEditFeature: NSObject, Feature {

    let id = "pictureEdit"
    let displayName = String(localized: "Picture Editor")
    let iconSystemName = "wand.and.stars.inverse"
    let summary = String(localized: "Drop an image to crop, rotate, resize, recolor, watermark, or remove the background.")

    /// Mirror PictureConvert: the dropdown IS the entry point, so a
    /// secondary on/off toggle would be redundant.
    var hasEnabledToggleInMenu: Bool { false }

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true

    let model = PictureEditModel()
    private(set) var window: PictureEditWindow?

    func start() {
        guard window == nil else { return }
        window = PictureEditWindow(model: model)
    }

    func stop() {
        window?.close()
        window = nil
    }

    func makeMenuBarItems() -> [NSMenuItem] {
        let item = NSMenuItem(
            title: String(localized: "Open Editor…"),
            action: #selector(openWindowAction),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(
            systemSymbolName: "macwindow.badge.plus",
            accessibilityDescription: nil
        )
        return [item]
    }

    func makeSettingsView() -> AnyView {
        AnyView(PictureEditSettingsView(feature: self))
    }

    @objc func openWindowAction() {
        window?.show()
    }
}

private struct PictureEditSettingsView: View {

    let feature: PictureEditFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Open") {
                HStack {
                    Text("Drop an image into the editor for quick edits.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Editor") {
                        feature.openWindowAction()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(10)
            }

            GroupBox("What's inside") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Crop, rotate, flip, resize", systemImage: "crop")
                    Label("Color filters & adjustments", systemImage: "wand.and.stars")
                    Label("Text watermark", systemImage: "textformat")
                    Label("Background removal (Vision)", systemImage: "person.crop.rectangle.badge.xmark")
                    Label("Export to any supported picture format", systemImage: "square.and.arrow.down")
                }
                .foregroundStyle(.secondary)
                .padding(10)
            }
        }
    }
}

#endif
