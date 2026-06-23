import Foundation
import Combine

/// Shared, observable state surfaced by `SpaceShortcutFeature` for the chord HUD.
/// All mutations happen from the EventTap callback path on the main thread.
@MainActor
final class SpaceShortcutState: ObservableObject {
    @Published var chordModeActive: Bool = false
}
