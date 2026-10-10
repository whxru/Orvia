import AppKit
import ApplicationServices

// Runtime actions only: selecting an item in settings must never execute these.
enum InputActions {
    // Query the keyboard recipient when application activation differs. This
    // avoids equating an application-activation notification with input focus.
    static func keyboardFocusPID() -> pid_t? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.02)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeBitCast(raw, to: AXUIElement.self), &pid) == .success else { return nil }
        return pid
    }

    static func canClear(role: String, valueSettable: Bool, selectionSettable: Bool) -> Bool {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
            && (valueSettable || selectionSettable)
    }

    static func isTextInputFocused(in app: NSRunningApplication?) -> Bool {
        guard AXIsProcessTrusted(), let app,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let matches: Bool
        if let field = elementAttribute(application, kAXFocusedUIElementAttribute) {
            matches = isEditableText(field)
        } else if let window = elementAttribute(application, kAXFocusedWindowAttribute) {
            // Some web-backed native apps (including Codex) expose AXFocused on
            // the editor but return no application-level AXFocusedUIElement.
            // Search only the focused window, without reading any text values.
            AXUIElementSetMessagingTimeout(application, 0.02)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.12
            matches = containsFocusedText(in: window, children: {
                attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }, isFocusedText: {
                attribute($0, kAXFocusedAttribute) as? Bool == true && isEditableText($0)
            }, shouldContinue: { ProcessInfo.processInfo.systemUptime < deadline })
        } else {
            matches = false
        }
        return matches && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func isEditableText(_ field: AXUIElement) -> Bool {
        guard let role = attribute(field, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(field, kAXEnabledAttribute) as? Bool != false else { return false }
        var valueSettable = DarwinBoolean(false), selectionSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &valueSettable)
        AXUIElementIsAttributeSettable(field, kAXSelectedTextRangeAttribute as CFString, &selectionSettable)
        return canClear(role: role, valueSettable: valueSettable.boolValue, selectionSettable: selectionSettable.boolValue)
    }

    // Bound both traversal and queued nodes; unavailable or oversized trees
    // fail closed rather than blocking the gesture or guessing from visibility.
    static func containsFocusedText<Element>(in root: Element, children: (Element) -> [Element],
                                             isFocusedText: (Element) -> Bool,
                                             maximumElements: Int = 2048, maximumDepth: Int = 64,
                                             shouldContinue: () -> Bool = { true }) -> Bool {
        guard maximumElements > 0, maximumDepth >= 0 else { return false }
        var queue = [(root, 0)], index = 0
        while index < queue.count && shouldContinue() {
            let (element, depth) = queue[index]; index += 1
            if isFocusedText(element) { return shouldContinue() }
            guard depth < maximumDepth, queue.count < maximumElements, shouldContinue() else { continue }
            queue.append(contentsOf: children(element).prefix(maximumElements - queue.count).map { ($0, depth + 1) })
        }
        return false
    }

    @discardableResult
    static func clearFocusedText(using sender: KeySender) -> Bool {
        guard sender.available, isTextInputFocused(in: NSWorkspace.shared.frontmostApplication) else { return false }
        // Normal editing events retain app-specific undo and change notifications.
        // Never emit Select All/Delete for a file list or a non-editable view.
        sender.tap(KeyAction.find("selectAll"))
        sender.tap(KeyAction.find("delete"))
        return true
    }
}
