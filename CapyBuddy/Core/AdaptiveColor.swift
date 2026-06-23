import AppKit
import SwiftUI

extension Color {
    /// A dynamic color that resolves per appearance at draw time, so the
    /// feature palettes can keep their designed light values while staying
    /// legible in Dark Mode (hardcoded light backgrounds otherwise collide
    /// with system controls, which follow the effective appearance).
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
