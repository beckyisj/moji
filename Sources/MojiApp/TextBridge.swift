import AppKit
import ApplicationServices

/// Synthetic keystrokes we post carry this tag so our own event tap ignores them.
let mojiEventMarker: Int64 = 0x4D4F_4A49  // "MOJI"

enum Inserter {
    private static let queue = DispatchQueue(label: "moji.insert")

    /// Backspaces over the typed ":query", then types the emoji.
    static func replace(deleting count: Int, with text: String) {
        queue.async {
            let source = CGEventSource(stateID: .privateState)
            for _ in 0..<count {
                post(key: 51, source: source)
                usleep(1_500)  // some Electron apps drop back-to-back synthetic keys
            }
            usleep(3_000)
            let utf16 = Array(text.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.setIntegerValueField(.eventSourceUserData, value: mojiEventMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private static func post(key: CGKeyCode, source: CGEventSource?) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: mojiEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

enum Caret {
    /// The text caret's screen rect (Cocoa coordinates) in the focused app, via Accessibility.
    /// `precise` is false when only the text box's position was available.
    /// Safe off the main thread: pass the frontmost app's pid and the primary screen's height.
    static func rect(pid: pid_t, primaryHeight: CGFloat) -> (rect: NSRect, precise: Bool)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)

        // Electron apps (Notion, Linear, …) only expose text fields once asked.
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let element: AXUIElement = copy(system, kAXFocusedUIElementAttribute) else { return nil }

        if let rangeValue: AXValue = copy(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            AXValueGetValue(rangeValue, .cfRange, &range)
            var candidates = [range]
            if range.location > 0 { candidates.append(CFRange(location: range.location - 1, length: 1)) }
            if let caret = caretBounds(element, candidates, primaryHeight) { return (caret, true) }
        }

        // No caret bounds (Chrome before its AX tree is ready, some custom fields): use the text box itself.
        guard let position: AXValue = copy(element, kAXPositionAttribute),
              let sizeValue: AXValue = copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        // Anchor to the box's first line so tall editors don't push the popup to their bottom edge.
        return (flip(CGRect(x: origin.x + 6, y: origin.y, width: 1, height: min(size.height, 22)), primaryHeight), false)
    }

    private static func caretBounds(_ element: AXUIElement, _ candidates: [CFRange], _ primaryHeight: CGFloat) -> NSRect? {
        for candidate in candidates {
            var r = candidate
            guard let value = AXValueCreate(.cfRange, &r) else { continue }
            var bounds: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &bounds
            ) == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
            if rect.height > 0, rect.origin != .zero {
                return flip(rect, primaryHeight)
            }
        }
        return nil
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// AX uses a top-left origin on the primary screen; Cocoa uses bottom-left.
    private static func flip(_ rect: CGRect, _ primaryHeight: CGFloat) -> NSRect {
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: max(rect.width, 1), height: rect.height)
    }
}

enum BrowserTab {
    /// True when the focused browser tab is a web app with its own ":" picker (Slack, GitHub, …).
    static func hasOwnPicker(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        if let host = host(of: app) {
            return Settings.shared.excludedSite(covering: host) != nil
        }
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute),
              let title: String = attribute(window, kAXTitleAttribute) else { return false }
        let t = title.lowercased()
        return Settings.excludedTitleMarkers.contains { t.contains($0) }
    }

    /// The focused tab's host without "www.", e.g. "x.com". Nil when the browser doesn't expose the URL.
    static func currentHost(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        return host(of: app)
    }

    private static func host(of app: AXUIElement) -> String? {
        guard var host = focusedURL(app)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Walks up from the focused element to the web area, which carries the page URL.
    private static func focusedURL(_ app: AXUIElement) -> URL? {
        var element: AXUIElement? = attribute(app, kAXFocusedUIElementAttribute)
        for _ in 0..<40 {
            guard let current = element else { return nil }
            if let url: URL = attribute(current, "AXURL") { return url }
            if let s: String = attribute(current, "AXURL") { return URL(string: s) }
            element = attribute(current, kAXParentAttribute)
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
