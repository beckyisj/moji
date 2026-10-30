import AppKit
import MojiCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: Controller!
    private var permissionTimer: Timer?
    /// The app that was in front when the menu opened (menu-bar clicks don't activate Moji).
    private var targetApp: NSRunningApplication?
    /// The site to toggle: the list entry covering the tab ("github.com") or the tab's host itself.
    private var targetSite: String?

    private let tones = ["✋ Default", "✋🏻 Light", "✋🏼 Medium-light", "✋🏽 Medium", "✋🏾 Medium-dark", "✋🏿 Dark"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = Controller(engine: SearchEngine(emoji: EmojiData.load()))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        mojiLog("launch trusted=\(trusted) args=\(CommandLine.arguments.dropFirst())")
        if trusted {
            mojiLog("tap started=\(controller.start())")
            updateIcon()
            let args = CommandLine.arguments
            if args.contains("--host-probe") {
                // Logs which site Moji sees in the front browser tab. Reads only; types nothing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let app = NSWorkspace.shared.frontmostApplication
                    let host = app.flatMap { BrowserTab.currentHost(pid: $0.processIdentifier) }
                    mojiLog("host-probe app=\(app?.bundleIdentifier ?? "?") host=\(host ?? "nil") off=\(self.controller.frontmostIsExcluded())")
                }
            }
            if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
                SelfTest.run(output: args[i + 1], controller: controller)
            }
        } else {
            // Poll until the user flips the switch in System Settings → Privacy → Accessibility.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted(), let self else { return }
                if self.controller.start() {
                    timer.invalidate()
                    self.updateIcon()
                }
            }
        }
    }

    private func updateIcon() {
        let ready = controller.isRunning && Settings.shared.enabled
        // Template symbol so it matches the other menu bar icons in light and dark mode.
        let image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Moji")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.appearsDisabled = !ready  // dimmed when off or missing Accessibility
        statusItem.button?.toolTip = controller.isRunning ? "Moji" : "Moji needs Accessibility access"
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        targetApp = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()

        if !controller.isRunning {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        let enabled = item("Enabled", #selector(toggleEnabled))
        enabled.state = Settings.shared.enabled ? .on : .off
        menu.addItem(enabled)

        if let app = targetApp, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let off = item("Off in \(app.localizedName ?? id)", #selector(toggleApp))
            off.state = Settings.shared.excludedApps.contains(id) ? .on : .off
            menu.addItem(off)

            // In a browser, also offer the current website ("Off on x.com").
            targetSite = nil
            if Settings.browsers.contains(id), let host = BrowserTab.currentHost(pid: app.processIdentifier) {
                let covering = Settings.shared.excludedSite(covering: host)
                targetSite = covering ?? host
                let site = item("Off on \(covering ?? host)", #selector(toggleSite))
                site.state = covering != nil ? .on : .off
                menu.addItem(site)
            }
        }
        menu.addItem(.separator())

        let toneMenu = NSMenu()
        for (i, label) in tones.enumerated() {
            let t = item(label, #selector(setTone(_:)))
            t.tag = i
            t.state = Settings.shared.skinTone == i ? .on : .off
            toneMenu.addItem(t)
        }
        let toneItem = NSMenuItem(title: "Skin Tone", action: nil, keyEquivalent: "")
        toneItem.submenu = toneMenu
        menu.addItem(toneItem)

        let triggerMenu = NSMenu()
        for n in 1...3 {
            let t = item("After \(n) letter\(n == 1 ? "" : "s")", #selector(setMinChars(_:)))
            t.tag = n
            t.state = Settings.shared.minChars == n ? .on : .off
            triggerMenu.addItem(t)
        }
        let triggerItem = NSMenuItem(title: "Show Suggestions", action: nil, keyEquivalent: "")
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        let jevMenu = NSMenu()
        let hasKey = JevKeychain.read() != nil
        let jevOn = item("Smart Ranking with Jev", #selector(toggleJev))
        jevOn.state = hasKey && Settings.shared.jevEnabled ? .on : .off
        jevOn.isEnabled = hasKey
        jevMenu.addItem(jevOn)
        jevMenu.addItem(.separator())
        jevMenu.addItem(item(hasKey ? "Replace API Key…" : "Set API Key…", #selector(setJevKey)))
        if hasKey { jevMenu.addItem(item("Remove API Key", #selector(removeJevKey))) }
        let jevItem = NSMenuItem(title: "Jev", action: nil, keyEquivalent: "")
        jevItem.submenu = jevMenu
        menu.addItem(jevItem)

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Moji", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        controller.reset()
        updateIcon()
    }

    @objc private func toggleSite() {
        guard let site = targetSite else { return }
        Settings.shared.setSiteExcluded(site, Settings.shared.excludedSite(covering: site) == nil)
    }

    @objc private func toggleApp() {
        guard let id = targetApp?.bundleIdentifier else { return }
        Settings.shared.setExcluded(id, !Settings.shared.excludedApps.contains(id))
    }

    @objc private func setTone(_ sender: NSMenuItem) { Settings.shared.skinTone = sender.tag }
    @objc private func setMinChars(_ sender: NSMenuItem) { Settings.shared.minChars = sender.tag }

    @objc private func toggleJev() {
        Settings.shared.jevEnabled.toggle()
        controller.reloadJev()
    }

    /// The key is typed here by the user and goes straight into the Keychain.
    @objc private func setJevKey() {
        let alert = NSAlert()
        alert.messageText = "TypeSafe API key for Jev"
        alert.informativeText = "Moji sends only the letters you type after \":\" to Jev to rank emoji. "
            + "The key is stored in your login Keychain. Get one at console.typesafe.ai."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "API key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if JevKeychain.save(key) {
            Settings.shared.jevEnabled = true
            controller.reloadJev()
        } else {
            let failed = NSAlert()
            failed.messageText = "Couldn't save the key to the Keychain"
            failed.runModal()
        }
    }

    @objc private func removeJevKey() {
        JevKeychain.delete()
        controller.reloadJev()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Moji: login item change failed: \(error)")
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// Appends to ~/Library/Logs/Moji.log (permission and tap state, for debugging).
func mojiLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Moji.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
