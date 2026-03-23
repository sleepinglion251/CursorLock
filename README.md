# CursorLock

**CursorLock** is a lightweight macOS menu bar application designed to prevent the mouse cursor from moving to user-selected displays. It is ideal for multi-monitor setups where you want to temporarily "lock" your cursor to specific screens (e.g., during gaming or focused work).

## Features

- **Menu Bar Only:** Runs entirely in the menu bar with no Dock icon or main window.
- **Per-Display Control:** Individually select which displays to block.
- **Global Toggle:** Quickly enable or disable cursor blocking via the menu or a global hotkey (**⇧⌘L**).
- **Native Integration:** Uses `CGEventTap` for high-performance, system-level cursor movement interception.
- **Adaptive UI:** Supports light and dark modes with SF Symbols.
- **Display Persistence:** Remembers your blocked display preferences across app launches.

## Requirements

- **macOS 12.0+**
- **Accessibility Permissions:** Required to intercept and constrain mouse movement. The app will prompt you to grant these permissions on first launch.
- **Non-Sandboxed:** To function correctly, the app runs outside the macOS sandbox.

## How It Works

CursorLock intercepts mouse events before they reach the window server. When blocking is enabled, it calculates an "allowed region" consisting of all unblocked displays. If the cursor attempts to leave this region, CursorLock instantly clamps it back to the nearest allowed point.

## Installation / Build

1. Open `CursorLock.xcodeproj` in Xcode.
2. Build and run the `CursorLock` target.
3. Grant Accessibility permissions when prompted.

## Project Structure

- `AppDelegate.swift`: Manages the menu bar icon, menu items, and app lifecycle.
- `CursorConstrainer.swift`: Contains the core `CGEventTap` logic for cursor movement interception.
- `DisplayManager.swift`: Handles screen enumeration and preference persistence.
- `HotkeyManager.swift`: Manages the global keyboard shortcut.
