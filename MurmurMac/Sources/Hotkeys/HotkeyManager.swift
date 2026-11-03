import MurmurCore
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
    
    private var targetKeyCode: UInt16 {
        let k = UInt16(SettingsManager.shared.settings.hotkeyKeyCode); return k == 0 ? 63 : k
    }
    
    private var targetModifiers: CGEventFlags {
        CGEventFlags(rawValue: UInt64(SettingsManager.shared.settings.hotkeyModifiers))
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
            NSLog("Murmur: event tap failed (trusted=\(AXIsProcessTrusted())), retrying in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.register() }
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Murmur: hotkey registered trusted=\(AXIsProcessTrusted()) key=\(targetKeyCode)")
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
            NSLog("Murmur: tap disabled, re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        
        if type == .flagsChanged {
            if keyCode == 63 && targetKeyCode == 63 {
                let fnPressed = event.flags.contains(.maskSecondaryFn)
                
                let now = Date()
                if fnPressed && !isHotkeyPressed {
                    isHotkeyPressed = true
                    fnDownAt = now
                    if handsFree {
                        handsFree = false
                        ignoreNextUp = true
                        NSLog("Murmur: hands-free stop")
                        DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
                    } else if let pending = pendingCancel {
                        pending.cancel(); pendingCancel = nil
                        handsFree = true
                        ignoreNextUp = true
                        NSLog("Murmur: hands-free start")
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.onHotkeyDown?() }
                    }
                } else if !fnPressed && isHotkeyPressed {
                    isHotkeyPressed = false
                    if ignoreNextUp { ignoreNextUp = false; return nil }
                    if now.timeIntervalSince(fnDownAt) < 0.3 {
                        let work = DispatchWorkItem { [weak self] in
                            self?.pendingCancel = nil
                            self?.onHotkeyCancel?()
                        }
                        pendingCancel = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.onHotkeyUp?() }
                    }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard keyCode == targetKeyCode else {
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
        switch keyCode {
        case 63: keyName = "Fn"
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
