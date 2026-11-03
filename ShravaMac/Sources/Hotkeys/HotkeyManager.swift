import ShravaCore
import Foundation
import Carbon
import AppKit

final class HotkeyManager {
    static let shared = HotkeyManager()
    
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onHotkeyCancel: (() -> Void)?
    private var handsFree = false
    private var ignoreNextUp = false
    private var fnDownAt = Date()
    private var pendingCancel: DispatchWorkItem?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHotkeyPressed = false
    
    /// Modifier-only preset (Control+Option) uses keyCode 0 with non-zero modifiers.
    private var isModifierCombo: Bool {
        SettingsManager.shared.settings.hotkeyKeyCode == 0 && SettingsManager.shared.settings.hotkeyModifiers != 0
    }

    private var targetKeyCode: UInt16 {
        let k = UInt16(SettingsManager.shared.settings.hotkeyKeyCode)
        if isModifierCombo { return 0 }
        return k == 0 ? 63 : k
    }
    
    private var targetModifiers: CGEventFlags {
        CGEventFlags(rawValue: UInt64(SettingsManager.shared.settings.hotkeyModifiers))
    }

    private var handsFreeAllowed: Bool {
        SettingsManager.shared.settings.handsFreeEnabled
    }

    /// Modifier keys that arrive via flagsChanged (Fn / Right Option / Right Command).
    private var isFlagsHotkey: Bool {
        let k = targetKeyCode
        return k == 63 || k == 61 || k == 54
    }

    private func isFlagsKeyPressed(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 63: return flags.contains(.maskSecondaryFn)
        case 61: return flags.contains(.maskAlternate) // Right Option also sets maskAlternate
        case 54: return flags.contains(.maskCommand)
        default: return false
        }
    }
    
    private init() {}
    
    func register() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(proxy: proxy, type: type, event: event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            let trusted = AXIsProcessTrusted()
            NSLog("Shrava: event tap failed (trusted=\(trusted)), retrying in 2s")
            writeLaunchStatus(trusted: trusted, note: "event_tap_failed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.register() }
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let trusted = AXIsProcessTrusted()
        NSLog("Shrava: hotkey registered trusted=\(trusted) key=\(targetKeyCode)")
        writeLaunchStatus(trusted: trusted, note: "hotkey_registered")
    }
    

    private func writeLaunchStatus(trusted: Bool, note: String) {
        let statusURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shrava/launch-status.txt")
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "trusted=\(trusted)\nnote=\(note)\nkey=\(targetKeyCode)\n".write(to: statusURL, atomically: true, encoding: .utf8)
    }

    func unregister() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("Shrava: tap disabled, re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        
        // Esc cancels an in-progress hold while waiting / recording start
        if type == .keyDown && keyCode == 53 && isHotkeyPressed && !handsFree {
            isHotkeyPressed = false
            DispatchQueue.main.async { [weak self] in self?.onHotkeyCancel?() }
            return nil
        }

        if type == .flagsChanged {
            // Control+Option combo: both modifiers held
            if isModifierCombo {
                let relevant = event.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
                let comboDown = relevant.contains(.maskControl) && relevant.contains(.maskAlternate)
                let now = Date()
                if comboDown && !isHotkeyPressed {
                    isHotkeyPressed = true
                    fnDownAt = now
                    DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
                    return nil
                } else if !comboDown && isHotkeyPressed {
                    isHotkeyPressed = false
                    DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            if isFlagsHotkey && keyCode == targetKeyCode {
                let pressed = isFlagsKeyPressed(keyCode: keyCode, flags: event.flags)
                let now = Date()
                if pressed && !isHotkeyPressed {
                    isHotkeyPressed = true
                    fnDownAt = now
                    if handsFree {
                        handsFree = false
                        ignoreNextUp = true
                        NSLog("Shrava: hands-free stop")
                        DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
                    } else if handsFreeAllowed, let pending = pendingCancel {
                        pending.cancel(); pendingCancel = nil
                        handsFree = true
                        ignoreNextUp = true
                        NSLog("Shrava: hands-free start")
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
                    }
                } else if !pressed && isHotkeyPressed {
                    isHotkeyPressed = false
                    if ignoreNextUp { ignoreNextUp = false; return nil }
                    if now.timeIntervalSince(fnDownAt) < 0.3 {
                        if handsFreeAllowed {
                            let work = DispatchWorkItem { [weak self] in
                                self?.pendingCancel = nil
                                self?.onHotkeyCancel?()
                            }
                            pendingCancel = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
                        } else {
                            DispatchQueue.main.async { [weak self] in self?.onHotkeyCancel?() }
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
                    }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard !isModifierCombo, !isFlagsHotkey, keyCode == targetKeyCode else {
            return Unmanaged.passUnretained(event)
        }
        
        if targetModifiers.rawValue != 0 {
            let relevantFlags = event.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            guard relevantFlags.rawValue == targetModifiers.rawValue else {
                return Unmanaged.passUnretained(event)
            }
        }
        
        if type == .keyDown && !isHotkeyPressed {
            isHotkeyPressed = true
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyDown?()
            }
            return nil
        } else if type == .keyUp && isHotkeyPressed {
            isHotkeyPressed = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyUp?()
            }
            return nil
        }
        
        return Unmanaged.passUnretained(event)
    }
    
    func setHotkey(keyCode: UInt16, modifiers: CGEventFlags) {
        unregister()
        SettingsManager.shared.settings.hotkeyKeyCode = keyCode
        SettingsManager.shared.settings.hotkeyModifiers = UInt(modifiers.rawValue)
        register()
    }
    
    static func hotkeyDescription(keyCode: UInt16, modifiers: UInt) -> String {
        var parts: [String] = []
        
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        
        let keyName: String
        if keyCode == 0 && modifiers != 0 {
            // Modifier-only combo already listed above
            return parts.isEmpty ? "Modifiers" : parts.joined(separator: "")
        }

        switch keyCode {
        case 63: keyName = "Fn"
        case 61: keyName = "Right ⌥"
        case 54: keyName = "Right ⌘"
        case 36: keyName = "Return"
        case 49: keyName = "Space"
        case 51: keyName = "Delete"
        case 53: keyName = "Escape"
        default:
            if let char = keyCodeToCharacter(keyCode) {
                keyName = char.uppercased()
            } else {
                keyName = "Key \(keyCode)"
            }
        }
        
        parts.append(keyName)
        return parts.joined()
    }
    
    private static func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
        let keyMap: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
            38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "n", 46: "m", 47: "."
        ]
        return keyMap[keyCode]
    }
}
