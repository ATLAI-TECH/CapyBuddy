#if CAPYBUDDY_DIRECT
// Element-level snap uses the Accessibility API (AXUIElementCopyElementAtPosition),
// which the App Store reviewer flags under guideline 2.4.5 if shipped in the MAS
// build. We restrict it to the Pro (Developer ID) target, where the user can
// grant Accessibility explicitly and the unlocked UX justifies the permission.
import AppKit
import ApplicationServices

/// Snipaste-style "snap to UI element" hit testing via the macOS
/// Accessibility API. Returns the bounds of the *finest* AX element under
/// the cursor — a button, text field, sub-view — instead of just the
/// owning window.
///
/// Permission gate:
///   - Requires Accessibility permission. If denied, every call returns
///     nil and the caller is expected to fall back to the window-level
///     `WindowHitTester`.
///   - The same permission is already requested for the global capture
///     hotkey, so most users will already have it granted.
///
/// Cost note:
///   - `AXUIElementCopyElementAtPosition` is a cross-process round trip.
///     On a fresh element it can take several milliseconds; on a hot
///     element it's submillisecond.
///   - We throttle by suppressing queries when the cursor moved less
///     than `coordTolerance` pixels since the last call. The cached rect
///     is good enough between samples.
@MainActor
final class UIElementHitTester {

    private let systemWide = AXUIElementCreateSystemWide()
    private let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    private let coordTolerance: CGFloat = 3

    private var lastQueryPoint: CGPoint?
    private var lastResult: NSRect?

    /// Look up the element at the given AppKit-global cursor location and
    /// return its bounds in AppKit-global coords (y-up). nil if:
    ///   - Accessibility is denied
    ///   - The element belongs to our own process
    ///   - AX returned no element / no usable frame
    ///   - The element covers an entire screen (i.e. the desktop or a
    ///     full-screen catch-all overlay we couldn't filter out)
    func elementRect(atAppKitGlobalPoint point: NSPoint, primaryHeight: CGFloat) -> NSRect? {
        guard PermissionChecker.isAccessibilityGranted() else { return nil }

        // Convert AppKit global → CG global (y-down) for AX.
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        // Throttle: re-use the cached result if the cursor barely moved.
        if let last = lastQueryPoint,
           abs(last.x - cgPoint.x) < coordTolerance,
           abs(last.y - cgPoint.y) < coordTolerance {
            return lastResult
        }
        lastQueryPoint = cgPoint

        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(cgPoint.x),
            Float(cgPoint.y),
            &element
        )
        guard err == .success, let element else {
            lastResult = nil
            return nil
        }

        // Skip our own process — otherwise the overlay panel itself is the
        // top-most AX element under the cursor and the result is useless.
        var elementPID: pid_t = 0
        if AXUIElementGetPid(element, &elementPID) == .success, elementPID == ownPID {
            lastResult = nil
            return nil
        }

        // Try the modern unified `AXFrame` attribute first — it's a single
        // CGRect and matches what's drawn on screen. Older / weird elements
        // may only expose `AXPosition` + `AXSize` separately, which we fall
        // back to.
        let cgRect: CGRect? = readFrame(of: element) ?? readPositionAndSize(of: element)
        guard let cgRect else {
            lastResult = nil
            return nil
        }

        // Drop "whole screen" hits — typically these are the desktop, the
        // wallpaper layer, or another full-screen catcher we don't want
        // the user snapping to.
        if isFullScreenLike(cgRect) {
            lastResult = nil
            return nil
        }

        let appKitRect = WindowHitTester.appKitGlobalRect(fromCG: cgRect, primaryHeight: primaryHeight)
        lastResult = appKitRect
        return appKitRect
    }

    // MARK: - AX attribute helpers

    private func readFrame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        let ok = AXValueGetValue((raw as! AXValue), .cgRect, &rect)
        return ok ? rect : nil
    }

    private func readPositionAndSize(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let p = posValue, CFGetTypeID(p) == AXValueGetTypeID(),
              let s = sizeValue, CFGetTypeID(s) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let okP = AXValueGetValue((p as! AXValue), .cgPoint, &origin)
        let okS = AXValueGetValue((s as! AXValue), .cgSize, &size)
        guard okP, okS else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func isFullScreenLike(_ cgRect: CGRect) -> Bool {
        for screen in NSScreen.screens {
            // Screen frames in AppKit; CG screen frames are y-flipped, but
            // the *size* matches and that's all we need for the heuristic.
            let s = screen.frame.size
            // 16px slack for menu-bar / dock chrome that may be subtracted
            // from the AX-reported frame on some apps.
            if abs(cgRect.width - s.width) < 16, abs(cgRect.height - s.height) < 16 {
                return true
            }
        }
        return false
    }

    /// Reset the throttle cache. Called when the user moves between
    /// monitors or starts a fresh capture session.
    func reset() {
        lastQueryPoint = nil
        lastResult = nil
    }
}

#endif // CAPYBUDDY_DIRECT
