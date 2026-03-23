import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
    }
}

class DisplayManager {
    static let blockedDisplayIDsKey = "blockedDisplayIDs"
    static let hotkeyCharKey = "hotkeyChar"
    static let hotkeyModifiersKey = "hotkeyModifiers"

    var blockedDisplayIDs: Set<CGDirectDisplayID> {
        get {
            let saved = UserDefaults.standard.array(forKey: DisplayManager.blockedDisplayIDsKey) as? [Int] ?? []
            return Set(saved.map { CGDirectDisplayID($0) })
        }
        set {
            let toSave = newValue.map { Int($0) }
            UserDefaults.standard.set(toSave, forKey: DisplayManager.blockedDisplayIDsKey)
        }
    }

    var hotkeyChar: String {
        get { UserDefaults.standard.string(forKey: DisplayManager.hotkeyCharKey) ?? "k" }
        set { UserDefaults.standard.set(newValue, forKey: DisplayManager.hotkeyCharKey) }
    }

    var hotkeyModifiers: NSEvent.ModifierFlags {
        get {
            let raw = UserDefaults.standard.integer(forKey: DisplayManager.hotkeyModifiersKey)
            // Default to Cmd+Shift if never set
            return raw == 0 ? [.command, .shift] : NSEvent.ModifierFlags(rawValue: UInt(raw))
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: DisplayManager.hotkeyModifiersKey) }
    }

    func label(for screen: NSScreen) -> String {
        let w = Int(screen.frame.width)
        let h = Int(screen.frame.height)
        return "\(screen.localizedName) (\(w)×\(h))"
    }
}
