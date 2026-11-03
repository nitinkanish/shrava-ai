import Foundation
import AppKit
import ApplicationServices

final class TextInserter {
    
    @discardableResult
    static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }
        
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        
        let appRef = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard result == .success, let element = focusedElement else {
            return false
        }
        
        let axElement = element as! AXUIElement
        
        var selectedTextRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedTextRange)
        
        if rangeResult == .success {
            let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            return setResult == .success
        }
        
        var currentValue: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
        
        if valueResult == .success, let currentString = currentValue as? String {
            let newValue = currentString + text
            let setResult = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newValue as CFTypeRef)
            return setResult == .success
        }
        
        return false
    }
    
    static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }
            return itemData.isEmpty ? nil : itemData
        }
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
            
            cmdDown?.flags = .maskCommand
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            
            cmdDown?.post(tap: .cghidEventTap)
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            cmdUp?.post(tap: .cghidEventTap)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let previous = previousContents, !previous.isEmpty {
                    pasteboard.clearContents()
                    for itemData in previous {
                        let item = NSPasteboardItem()
                        for (type, data) in itemData {
                            item.setData(data, forType: type)
                        }
                        pasteboard.writeObjects([item])
                    }
                }
            }
        }
    }
}
