import AppKit
import CoreGraphics

/// Snipaste-style "hover a window, snap to its bounds" hit testing.
///
/// Strategy:
///   - Take a one-shot snapshot of every on-screen normal-layer window via
///     `CGWindowListCopyWindowInfo`. Synchronous, ~1ms even on busy systems —
///     avoids the async fetch overhead of `SCShareableContent` for every
///     mouseMoved tick.
///   - Filter out our own process (so the overlay/toolbar/pinned windows
///     don't get hit-tested into themselves) plus the dock + menu bar.
///   - Pre-convert each window's CG global rect to AppKit global coords so
///     hit-testing in the steady-state `mouseMoved` path is just a
///     `NSRect.contains(point)` walk over a tiny array.
///
/// The list is intentionally a frozen snapshot. If the user arranges
/// windows mid-capture (rare — they'd have to alt-tab during the capture
/// session) the hover hits go stale, but the manual drag path is
/// unchanged. Mature screenshot tools (Snipaste, CleanShot) accept the
/// same trade.
struct SnappableWindow: Sendable {
    let id: CGWindowID
    /// Bounds in global AppKit coordinates (y-up, origin at primary
    /// screen's bottom-left).
    let appKitGlobalRect: NSRect
    /// PID of the owning process. Kept around for diagnostic logging only.
    let ownerPID: pid_t
}

enum WindowHitTester {

    /// Capture every on-screen normal-layer window owned by another
    /// process. Returned in front-to-back order, matching CGWindowList's
    /// native order — so the first hit during a hit-test walk is the
    /// topmost window, exactly what the user expects to snap to.
    static func snapshot(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [SnappableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = primaryScreenHeight()
        return raw.compactMap { dict in
            guard
                let id = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                pid != excludingPID,
                // Layer 0 == regular app windows. Higher layers are dock,
                // menu bar, screen savers, etc. — all things the user
                // doesn't want to snap to.
                let layer = dict[kCGWindowLayer as String] as? Int,
                layer == 0,
                let alpha = dict[kCGWindowAlpha as String] as? Double,
                alpha > 0.05,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }

            // Skip "windows" smaller than a thumbnail — those are usually
            // helper sublayers (status item droplets, transparent click
            // targets) that cause the hover highlight to flicker.
            guard cgRect.width >= 30, cgRect.height >= 30 else { return nil }

            let appKitRect = appKitGlobalRect(fromCG: cgRect, primaryHeight: primaryHeight)
            return SnappableWindow(id: id, appKitGlobalRect: appKitRect, ownerPID: pid)
        }
    }

    /// Topmost window containing `appKitGlobalPoint`, or nil if the cursor
    /// isn't over any snappable window.
    static func topMost(at appKitGlobalPoint: NSPoint, in windows: [SnappableWindow]) -> SnappableWindow? {
        for w in windows where w.appKitGlobalRect.contains(appKitGlobalPoint) {
            return w
        }
        return nil
    }

    // MARK: - Coord conversion

    /// Convert a CGWindowList rectangle (y-down, origin at primary
    /// screen's top-left) to AppKit global coords (y-up). The conversion
    /// only depends on the primary screen's height — multi-monitor setups
    /// place additional screens around the primary, but the global y axis
    /// is anchored to the primary either way.
    static func appKitGlobalRect(fromCG cgRect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    private static func primaryScreenHeight() -> CGFloat {
        // Primary screen is the one with origin at (0, 0) in AppKit. On
        // single-monitor setups that's identical to NSScreen.main.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        return primary?.frame.height ?? 0
    }
}
