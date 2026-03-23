# CursorLock — Claude Code Build Spec

## Overview

Build a macOS menu bar app called **CursorLock** that prevents the mouse cursor from moving to user-selected displays. The app lives entirely in the menu bar (no Dock icon, no main window). It uses a `CGEventTap` to intercept and rewrite mouse events before they reach the window server.

---

## Project Setup

- **App name:** CursorLock
- **Bundle ID:** com.yourname.CursorLock (replace `yourname` as appropriate)
- **Deployment target:** macOS 12.0
- **Language:** Swift 5.9+
- **UI framework:** AppKit only (no SwiftUI)
- **No sandbox** — the App Sandbox must be disabled. `CGEventTap` at `.cghidEventTap` requires Accessibility permission and does not work reliably under sandbox restrictions.
- **Xcode project** — create a standard macOS App target, then remove the default window/storyboard boilerplate (see below)

### Storyboard / Window cleanup

Delete or disable everything that creates a window at launch:
1. Delete `Main.storyboard` (or `MainMenu.xib`) and remove the `NSMainStoryboardFile` / `NSMainNibFile` key from `Info.plist`
2. In `AppDelegate`, do **not** create any `NSWindow`
3. Set `LSUIElement = YES` in `Info.plist` to suppress the Dock icon

---

## File Structure

```
CursorLock/
├── AppDelegate.swift        # Entry point, owns NSStatusItem and NSMenu
├── CursorConstrainer.swift  # CGEventTap logic
├── DisplayManager.swift     # NSScreen/CGDisplay helpers + UserDefaults persistence
├── HotkeyManager.swift      # Global keyboard shortcut
└── Info.plist               # LSUIElement, NSAccessibilityUsageDescription
```

---

## Info.plist Keys

```xml
<key>LSUIElement</key>
<true/>

<key>NSAccessibilityUsageDescription</key>
<string>CursorLock needs Accessibility access to constrain the mouse cursor to selected displays.</string>
```

---

## AppDelegate.swift

Responsibilities:
- Create and own the `NSStatusItem` with a variable-length menu bar button
- Build and update the `NSMenu`
- Own instances of `CursorConstrainer`, `DisplayManager`, and `HotkeyManager`
- Handle display configuration changes via `NSApplicationDidChangeScreenParametersNotification`

### Menu bar icon

Use SF Symbols via `NSImage(systemSymbolName:accessibilityDescription:)`:
- **Inactive:** `"lock.open"` 
- **Active (blocking enabled):** `"lock"` (filled)

Set the image as a template image so it adapts to light/dark menu bar:
```swift
image.isTemplate = true
statusItem.button?.image = image
```

### Menu layout

```
[lock icon in menu bar]
───────────────────────────
✓ Enable Blocking    ⇧⌘L      ← NSMenuItem, checkmark reflects active state
───────────────────────────
  Block these displays:        ← NSMenuItem, disabled, acts as section header
    ☐ LG UltraFine (2560×1440) ← one NSMenuItem per display, checkmark = blocked
    ☐ Built-in Retina (3024×1964)
───────────────────────────
Quit                           ← NSMenuItem → NSApp.terminate
```

Rules:
- "Block these displays:" is a disabled, non-selectable section header (indent with leading spaces or a small left margin)
- Each display item has a checkmark (`.state = .on`) when it is in the blocked set
- Clicking a display item toggles it in/out of the blocked set, saves to `UserDefaults`, and calls `CursorConstrainer.updateBlockedDisplays()`
- If blocking is **enabled** and a display item is toggled, update the constrainer immediately without toggling blocking off
- Rebuild the display list section whenever `NSApplicationDidChangeScreenParametersNotification` fires

### Keyboard shortcut on "Enable Blocking" menu item

```swift
menuItem.keyEquivalent = "l"
menuItem.keyEquivalentModifierMask = [.command, .shift]
```

---

## DisplayManager.swift

Responsibilities:
- Enumerate connected displays using `NSScreen.screens`
- Provide display label strings formatted as `"<name> (<width>×<height>)"`
  - Name comes from `NSScreen.localizedName` (available macOS 10.15+)
  - Resolution comes from `NSScreen.frame` (use `Int` values, no decimals)
  - Example: `"LG UltraFine (2560×1440)"`
- Map each `NSScreen` to its `CGDirectDisplayID` via `NSScreen.deviceDescription`
- Persist and restore the set of blocked display IDs using `UserDefaults`

### UserDefaults key

```swift
static let blockedDisplayIDsKey = "blockedDisplayIDs"
// Store as [UInt32] → cast to [Int] for UserDefaults compatibility
```

### NSScreen → CGDirectDisplayID helper

```swift
extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    }
}
```

### Display label helper

```swift
func label(for screen: NSScreen) -> String {
    let w = Int(screen.frame.width)
    let h = Int(screen.frame.height)
    return "\(screen.localizedName) (\(w)×\(h))"
}
```

---

## CursorConstrainer.swift

This is the core logic. It installs a `CGEventTap` at `.cghidEventTap` / `.headInsertEventTap` that intercepts mouse movement events and rewrites their location if the cursor has left the allowed region.

### Key design points

- The **allowed region** is the set of `CGRect` frames of all displays that are **not** blocked.
- `CGDisplayBounds(displayID)` and `CGEvent.location` share the same coordinate space on macOS (origin at top-left of the primary display) — use these for all coordinate checks.
- The tap callback must be a free C function (not a closure/method) — use `Unmanaged` to pass `self` as `userInfo`.
- Handle `.tapDisabledByTimeout` and `.tapDisabledByUserInput` by re-enabling the tap immediately.
- Keep the callback fast — no allocations, no locks, just a bounds check and a clamp to the nearest allowed rect.

### Events to intercept

```swift
let eventsOfInterest: CGEventMask =
    (1 << CGEventType.mouseMoved.rawValue)         |
    (1 << CGEventType.leftMouseDragged.rawValue)   |
    (1 << CGEventType.rightMouseDragged.rawValue)  |
    (1 << CGEventType.otherMouseDragged.rawValue)
```

### Clamping logic

```swift
// Inside the tap callback, if location is not inside ANY allowed rect:
// 1. Find the nearest point among all allowed rects.
// 2. Call CGWarpMouseCursorPosition to update the system position.
// 3. Update the event's location (for drag events) or return nil (for pure moves).
```

### Allowed region calculation

```swift
func buildAllowedRects(blockedIDs: Set<CGDirectDisplayID>) -> [CGRect] {
    var rects: [CGRect] = []
    for screen in NSScreen.screens {
        if !blockedIDs.contains(screen.displayID) {
            rects.append(CGDisplayBounds(screen.displayID))
        }
    }
    return rects
}
```

### Run loop setup

```swift
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
```

### Accessibility check

Before creating the tap, check for permission and bail gracefully if not granted:
```swift
guard AXIsProcessTrusted() else {
    // Prompt the user
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
    return
}
```

### Public interface

```swift
class CursorConstrainer {
    func start(blockedDisplayIDs: Set<CGDirectDisplayID>)
    func stop()
    func updateBlockedDisplays(_ ids: Set<CGDirectDisplayID>)
    var isActive: Bool { get }
}
```

---

## HotkeyManager.swift

Register a global hotkey (`⇧⌘L`) using `NSEvent.addGlobalMonitorForEvents(matching:handler:)`.

```swift
class HotkeyManager {
    private var monitor: Any?

    func start(handler: @escaping () -> Void) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // ⇧⌘L
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers == "l" {
                handler()
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
```

Note: `addGlobalMonitorForEvents` also requires Accessibility permission on macOS 10.15+. This is covered by the same permission request in `CursorConstrainer`.

---

## Persistence Behavior

- On launch: load blocked display IDs from `UserDefaults`. Do **not** restore active/inactive state — always launch inactive (blocking off).
- On display item toggle: immediately save updated set to `UserDefaults`.
- Display IDs are hardware-persistent across reboots for the same physical display. If a saved ID doesn't match any current screen, it is silently ignored (it will re-appear if the display is reconnected).

---

## Display Change Handling

When `NSApplicationDidChangeScreenParametersNotification` fires:
1. Rebuild the display list section of the menu
2. If blocking is currently active, call `constrainer.updateBlockedDisplays()` with the current blocked set — this recalculates the allowed region against the new screen layout
3. Blocked IDs that no longer correspond to connected displays are kept in `UserDefaults` but have no effect

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| Blocking enabled, all displays blocked | Cursor is clamped to a 1×1 point at `CGRect.null` boundary — effectively stuck. Don't prevent this; it's the user's choice. |
| Blocking enabled, no displays blocked | Allowed region = union of all screens = no constraint. Tap runs but never clamps. |
| Only one display connected | All displays can still be "blocked" in the UI, but with one display the tap will always clamp back, so the cursor barely moves. |
| Tap creation fails (no Accessibility permission) | Show an `NSAlert` explaining that Accessibility access is required, with a button to open System Settings → Privacy & Security → Accessibility. |
| App is quit while blocking active | `applicationWillTerminate` calls `constrainer.stop()` to cleanly remove the tap and run loop source. |

---

## Accessibility Permission Alert

If `CGEvent.tapCreate` returns `nil`, show:

```
Title:   "Accessibility Access Required"
Message: "CursorLock needs Accessibility access to constrain the mouse cursor.
          Please grant access in System Settings → Privacy & Security → Accessibility,
          then relaunch the app."
Button:  "Open System Settings"  → NSWorkspace.shared.open(URL for x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility)
Button:  "Cancel"
```

---

## What NOT to Build

- No preferences window
- No onboarding UI beyond the Accessibility alert
- No auto-launch at login (can be added later)
- No Dock icon or app switcher presence
- No SwiftUI
