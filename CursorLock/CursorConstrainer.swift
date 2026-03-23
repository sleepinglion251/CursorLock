import AppKit
import ApplicationServices

// CGEventTap callback — must be a free C function. `userInfo` is an unretained
// pointer to the owning CursorConstrainer (whose lifetime exceeds the tap's).
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let constrainer = Unmanaged<CursorConstrainer>.fromOpaque(userInfo).takeUnretainedValue()
    return constrainer.handle(type: type, event: event)
}

class CursorConstrainer {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Read from the event-tap thread, written on the main thread.
    // Writes happen only before the tap is enabled or while the tap is paused,
    // so no synchronisation primitive is needed in practice.
    private var allowedRects: [CGRect] = []

    // Tracks the cursor's logical position after a CGWarpMouseCursorPosition call.
    // After a warp the hardware tracking position diverges from the visual cursor
    // position, so we can no longer trust event.location as an absolute position.
    // Instead we accumulate deltas from the last known warped position.
    // Written and read exclusively on the event-tap thread (except nil-reset in stop()).
    private var virtualCursorPosition: CGPoint?

    private(set) var isActive = false

    // MARK: - Public interface

    func start(blockedDisplayIDs: Set<CGDirectDisplayID>) {
        guard !isActive else { return }

        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        allowedRects = buildAllowedRects(blockedIDs: blockedDisplayIDs)

        let eventsOfInterest: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)        |
            (1 << CGEventType.leftMouseDragged.rawValue)  |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Use .cgSessionEventTap as it is generally more stable for logical cursor
        // constraints than .cghidEventTap, which is extremely raw.
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            showAccessibilityAlert()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        tap = newTap
        runLoopSource = source
        isActive = true
    }

    func stop() {
        guard isActive, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.tap = nil
        self.runLoopSource = nil
        isActive = false
        virtualCursorPosition = nil
    }

    func updateBlockedDisplays(_ ids: Set<CGDirectDisplayID>) {
        allowedRects = buildAllowedRects(blockedIDs: ids)
    }

    // MARK: - Callback handler (called from event-tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let rawLocation = event.location
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)

        // After CGWarpMouseCursorPosition the hardware tracking position diverges from
        // the visual cursor. Subsequent events report the hardware's absolute position,
        // NOT a position relative to where we warped to. We fix this by computing a
        // "logical" position by accumulating the hardware deltas from our last known
        // warped position, completely ignoring the hardware's absolute position.
        let logicalLocation: CGPoint
        if let vp = virtualCursorPosition {
            logicalLocation = CGPoint(x: vp.x + dx, y: vp.y + dy)
        } else {
            logicalLocation = rawLocation
        }

        // Fast path: logical position is already in an allowed rectangle.
        if allowedRects.contains(where: { $0.contains(logicalLocation) }) {
            if virtualCursorPosition != nil {
                if !allowedRects.contains(where: { $0.contains(rawLocation) }) {
                    // Hardware is still outside but logical position is inside.
                    // Correct the event so the cursor doesn't snap to the hardware position.
                    event.location = logicalLocation
                    CGWarpMouseCursorPosition(logicalLocation)
                    virtualCursorPosition = logicalLocation
                } else {
                    // Both logical and hardware positions are inside — discrepancy resolved.
                    // Stop tracking so we stop warping during normal in-bounds movement.
                    virtualCursorPosition = nil
                }
            }
            return Unmanaged.passRetained(event)
        }

        // Logical position is outside — clamp to the nearest allowed point.
        guard let nearest = findNearestAllowedPoint(to: logicalLocation) else {
            // All displays are blocked.
            return nil
        }

        // Hard stop: zero both delta axes on impact.
        // Preserving the Y delta when hitting a vertical barrier caused the cursor to
        // "hurl" toward the top/bottom when moving fast with any diagonal component.
        event.location = nearest
        event.setDoubleValueField(.mouseEventDeltaX, value: 0)
        event.setDoubleValueField(.mouseEventDeltaY, value: 0)
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)

        CGWarpMouseCursorPosition(nearest)
        virtualCursorPosition = nearest

        return Unmanaged.passRetained(event)
    }

    // MARK: - Helpers

    private func findNearestAllowedPoint(to point: CGPoint) -> CGPoint? {
        var minDistanceSq = CGFloat.infinity
        var nearest: CGPoint?

        for rect in allowedRects {
            // Clamp point to this rect's bounds.
            // Using 1.0pt padding ensures we are strictly inside the rectangle,
            // avoiding jitter at the exact mathematical boundary.
            let padding: CGFloat = 1.0
            let clampedX = max(rect.minX + padding, min(rect.maxX - padding, point.x))
            let clampedY = max(rect.minY + padding, min(rect.maxY - padding, point.y))
            let clamped = CGPoint(x: clampedX, y: clampedY)

            let dx = point.x - clamped.x
            let dy = point.y - clamped.y
            let distSq = dx * dx + dy * dy

            if distSq < minDistanceSq {
                minDistanceSq = distSq
                nearest = clamped
            }
        }
        return nearest
    }

    private func buildAllowedRects(blockedIDs: Set<CGDirectDisplayID>) -> [CGRect] {
        // Use CGDisplayBounds (CG coordinate space: origin top-left, Y downward)
        // to match CGEvent.location, which is also in CG coordinate space.
        // NSScreen.frame uses AppKit coordinates (origin bottom-left, Y upward)
        // and diverges from CG coords for displays with any vertical offset.
        var rects: [CGRect] = []
        for screen in NSScreen.screens {
            if !blockedIDs.contains(screen.displayID) {
                rects.append(CGDisplayBounds(screen.displayID))
            }
        }
        return rects
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
            CursorLock needs Accessibility access to constrain the mouse cursor.
            Please grant access in System Settings → Privacy & Security → Accessibility, \
            then relaunch the app.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
