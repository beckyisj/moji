import AppKit
import ApplicationServices

/// `open ~/Applications/Moji.app --args --selftest /path/out.txt` types test phrases into the
/// frontmost text field as real keystrokes (they go through Moji's own tap, unlike Inserter's
/// tagged events), reads the field back over Accessibility and writes pass/fail lines.
enum SelfTest {
    static let cases: [(input: String, expected: String)] = [
        ("hi :tada: x", "hi 🎉 x"),
        ("yo :yay{ret}", "yo 🎉"),
        (":thmbs{ret}", "👍"),
        ("at 10:30 ok", "at 10:30 ok"),
        ("see https://x.co", "see https://x.co"),
        (":lol{down}{ret}", "🤣"),
        (":heart{esc} done", ":heart done"),
        ("a:tada b", "a:tada b"),
        (":dog{bs}{bs}{bs}{bs}x", "x"),
        ("(:fire{tab})", "(🔥)"),
        ("ok :+1: yes", "ok 👍 yes"),
        (":doggo{ret}", "🐶"),
        (":D nice", ":D nice"),
        (":party_po{ret}", "🎉"),
    ]

    static let allowedTargets: Set<String> = ["com.apple.TextEdit", "com.apple.Safari", "com.google.Chrome"]

    static func run(output: String, controller: Controller) {
        DispatchQueue.global().async {
            sleep(2)
            var lines: [String] = []
            let excluded = DispatchQueue.main.sync { controller.frontmostIsExcluded() }
            lines.append("Moji off here (own picker): \(excluded)")
            var passed = 0
            for (input, expected) in cases {
                // Never type into anything but the test window (a chat box, a call…).
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                guard allowedTargets.contains(front) else {
                    lines.append("ABORTED: frontmost app is \(front), not a test target")
                    break
                }
                clear()
                type(input)
                usleep(600_000)
                let got = fieldValue() ?? "<no AX value>"
                let ok = got.replacingOccurrences(of: "\u{FE0F}", with: "") == expected  // 👍️ vs 👍
                if ok { passed += 1 }
                lines.append("\(ok ? "PASS" : "FAIL")  \(input)  →  \(got)\(ok ? "" : "   (expected \(expected))")")
            }
            DispatchQueue.main.sync {
                lines.append("caret: \(Caret.rect(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, primaryHeight: NSScreen.screens.first?.frame.maxY ?? 0).map { "\(NSStringFromRect($0.rect)) precise=\($0.precise)" } ?? "nil")")
            }
            lines.append("\(passed)/\(cases.count) passed")
            try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
        }
    }

    private static let source = CGEventSource(stateID: .hidSystemState)
    private static let specials: [String: CGKeyCode] = ["ret": 36, "tab": 48, "down": 125, "up": 126, "esc": 53, "bs": 51]

    private static func type(_ script: String) {
        var rest = Substring(script)
        while let c = rest.first {
            if c == "{", let end = rest.firstIndex(of: "}") {
                key(specials[String(rest[rest.index(after: rest.startIndex)..<end])]!)
                rest = rest[rest.index(after: end)...]
                usleep(250_000)
            } else {
                let utf16 = Array(String(c).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: c == ":" ? 41 : 0, keyDown: down)!
                    e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                    e.post(tap: .cghidEventTap)
                    usleep(15_000)
                }
                rest = rest.dropFirst()
                usleep(50_000)
            }
        }
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
            e.flags = flags
            e.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }

    private static func clear() {
        key(0, flags: .maskCommand)  // ⌘A
        usleep(100_000)
        key(51)
        usleep(200_000)
    }

    private static func fieldValue() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? String)?.trimmingCharacters(in: .newlines)
    }
}
