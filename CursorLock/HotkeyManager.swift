import AppKit

class HotkeyManager {
    private var monitor: Any?

    private var currentKey: String = "k"
    private var currentModifiers: NSEvent.ModifierFlags = [.command, .shift]

    func start(char: String, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        self.currentKey = char.lowercased()
        self.currentModifiers = modifiers

        NSLog("CursorLock: HotkeyManager starting with mods:0x%08x key:%@", modifiers.rawValue, char)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()

            if flags == self.currentModifiers, key == self.currentKey {
                NSLog("CursorLock: Hotkey triggered!")
                handler()
            }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            
            if flags == self.currentModifiers, key == self.currentKey {
                handler()
                return nil
            }
            return event
        }
    }

    func update(char: String, modifiers: NSEvent.ModifierFlags) {
        self.currentKey = char.lowercased()
        self.currentModifiers = modifiers
        NSLog("CursorLock: Hotkey updated to mods:0x%08x key:%@", modifiers.rawValue, char)
    }

    func stop() {

        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
