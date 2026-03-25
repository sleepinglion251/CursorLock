import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let constrainer = CursorConstrainer()
    private let displayManager = DisplayManager()
    private let hotkeyManager = HotkeyManager()

    private var enableBlockingMenuItem: NSMenuItem!

    // MARK: - Lifecycle

    private var wasActiveBeforeSleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        buildMenu()

        hotkeyManager.start(
            char: displayManager.hotkeyChar,
            modifiers: displayManager.hotkeyModifiers
        ) { [weak self] in
            self?.toggleBlocking()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        constrainer.stop()
        hotkeyManager.stop()
    }

    // MARK: - Sleep/Wake handling

    @objc private func willSleep() {
        wasActiveBeforeSleep = constrainer.isActive
        if wasActiveBeforeSleep {
            constrainer.stop()
        }
    }

    @objc private func didWake() {
        // Delay slightly to let the display system stabilize after wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.rebuildDisplaySection()
            if self.wasActiveBeforeSleep {
                self.constrainer.start(blockedDisplayIDs: self.displayManager.blockedDisplayIDs)
                self.updateStatusIcon()
                self.enableBlockingMenuItem.state = .on
            }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbolName = constrainer.isActive ? "lock" : "lock.open"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()

        let enableItem = NSMenuItem(
            title: "Enable Blocking",
            action: #selector(toggleBlocking),
            keyEquivalent: displayManager.hotkeyChar
        )
        enableItem.keyEquivalentModifierMask = displayManager.hotkeyModifiers
        enableItem.target = self
        enableItem.state = constrainer.isActive ? .on : .off
        enableBlockingMenuItem = enableItem
        menu.addItem(enableItem)

        let hotkeyItem = NSMenuItem(
            title: "Change Hotkey...",
            action: #selector(changeHotkey),
            keyEquivalent: ""
        )
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)

        menu.addItem(.separator())

        let headerItem = NSMenuItem(title: "Block these displays:", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        insertDisplayItems(into: menu, after: headerItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func insertDisplayItems(into menu: NSMenu, after header: NSMenuItem) {
        guard let headerIndex = menu.items.firstIndex(of: header) else { return }
        let blockedIDs = displayManager.blockedDisplayIDs
        for (offset, screen) in NSScreen.screens.enumerated() {
            let item = NSMenuItem(
                title: "  \(displayManager.label(for: screen))",
                action: #selector(toggleDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = screen.displayID as NSNumber
            item.state = blockedIDs.contains(screen.displayID) ? .on : .off
            menu.insertItem(item, at: headerIndex + 1 + offset)
        }
    }

    private func rebuildDisplaySection() {
        guard let menu = statusItem.menu,
              let header = menu.items.first(where: { $0.title == "Block these displays:" }),
              let headerIndex = menu.items.firstIndex(of: header) else { return }

        // Remove stale display items (everything between header and next separator)
        let i = headerIndex + 1
        while i < menu.items.count, !menu.items[i].isSeparatorItem {
            menu.removeItem(at: i)
        }

        insertDisplayItems(into: menu, after: header)
    }

    // MARK: - Actions

    @objc private func toggleBlocking() {
        if constrainer.isActive {
            constrainer.stop()
        } else {
            constrainer.start(blockedDisplayIDs: displayManager.blockedDisplayIDs)
        }
        enableBlockingMenuItem.state = constrainer.isActive ? .on : .off
        updateStatusIcon()
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let displayID = (sender.representedObject as? NSNumber)?.uint32Value else { return }

        var blocked = displayManager.blockedDisplayIDs
        if blocked.contains(displayID) {
            blocked.remove(displayID)
        } else {
            blocked.insert(displayID)
        }
        displayManager.blockedDisplayIDs = blocked
        sender.state = blocked.contains(displayID) ? .on : .off

        if constrainer.isActive {
            constrainer.updateBlockedDisplays(blocked)
        }
    }

    @objc private func screensDidChange() {
        rebuildDisplaySection()
        if constrainer.isActive {
            constrainer.updateBlockedDisplays(displayManager.blockedDisplayIDs)
        }
    }

    @objc private func changeHotkey() {
        let alert = NSAlert()
        alert.messageText = "Record New Hotkey"
        alert.informativeText = "Press the desired key combination. Press Esc to cancel."
        alert.addButton(withTitle: "Cancel")
        
        let recorder = HotkeyRecorderView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        alert.accessoryView = recorder
        
        // Focus the recorder
        DispatchQueue.main.async {
            recorder.window?.makeFirstResponder(recorder)
        }

        if alert.runModal() == .alertFirstButtonReturn {
            return
        }
        
        if let (char, modifiers) = recorder.recordedHotkey {
            displayManager.hotkeyChar = char
            displayManager.hotkeyModifiers = modifiers
            hotkeyManager.update(char: char, modifiers: modifiers)
            
            // Update menu item
            enableBlockingMenuItem.keyEquivalent = char
            enableBlockingMenuItem.keyEquivalentModifierMask = modifiers
        }
    }
}

// MARK: - Hotkey Recorder View

class HotkeyRecorderView: NSView {
    var recordedHotkey: (String, NSEvent.ModifierFlags)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return
        }
        
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let char = event.charactersIgnoringModifiers?.lowercased(), !modifiers.isEmpty {
            recordedHotkey = (char, modifiers)
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        path.stroke()
        
        let text = "Recording..."
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12)
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
