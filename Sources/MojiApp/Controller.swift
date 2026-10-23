import AppKit
import MojiCore

/// Watches keystrokes system-wide. After a ":" at a word boundary it collects the query,
/// shows the popup, and steals ↑ ↓ ↩ ⇥ esc only while the popup is up.
final class Controller {
    let engine: SearchEngine
    let usage = UsageStore()
    private let popup = PopupController()
    private var tap: CFMachPort?

    private var capturing = false
    private var query = ""
    private var lastChar: Character?
    private var anchor: (rect: NSRect, precise: Bool)?
    private var results: [SearchResult] = []
    private var selection = 0
    private var shownQuery = ""
    private var captureID = 0
    private var caretLookupInFlight = false
    /// True until the first caret/tab lookup lands; the popup waits so it never flashes on Slack web etc.
    private var lookupPending = false
    private let axQueue = DispatchQueue(label: "moji.ax")

    // Jev re-ranking: local results show instantly, Jev's order replaces them ~a beat later.
    private var jevClient: JevClient?
    private var jevCache: [String: JevRanking] = [:]
    private var jevWork: DispatchWorkItem?
    private var jevTask: Task<Void, Never>?
    private var localResults: [SearchResult] = []
    private var swallowedKeyUps = Set<Int64>()

    init(engine: SearchEngine) {
        self.engine = engine
        engine.usageBoost = { [usage] in usage.boost(for: $0) }
        reloadJev()
        popup.onPick = { [weak self] index in
            guard let self, index < self.results.count else { return }
            self.commit(self.results[index].emoji)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reset()
            self?.lastChar = nil
        }
    }

    var isRunning: Bool { tap != nil }

    /// Picks up a newly saved/removed key or the on/off toggle.
    func reloadJev() {
        jevCache = [:]
        if Settings.shared.jevEnabled, let key = JevKeychain.read() {
            jevClient = JevClient(apiKey: key)
        } else {
            jevClient = nil
        }
    }

    /// Needs Accessibility permission; returns false until it's granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let controller = Unmanaged<Controller>.fromOpaque(refcon!).takeUnretainedValue()
                return controller.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    // MARK: - Event handling

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseDown, .rightMouseDown:
            if popup.isVisible, popup.frame.contains(NSEvent.mouseLocation) { return pass }
            reset()
            lastChar = nil
            return pass
        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowedKeyUps.remove(keyCode) != nil ? nil : pass
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == mojiEventMarker { return pass }
            return handleKeyDown(event) ? nil : pass
        default:
            return pass
        }
    }

    /// Returns true when the key was consumed by the popup.
    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if !event.flags.isDisjoint(with: [.maskCommand, .maskControl]) {
            reset()
            lastChar = nil
            return false
        }

        let showing = popup.isVisible && !results.isEmpty
        switch keyCode {
        case 53:  // esc
            let consumed = capturing && popup.isVisible
            reset()
            return consumed ? swallow(keyCode) : false
        case 125, 126:  // ↓ ↑
            guard showing else { reset(); return false }
            selection = (selection + (keyCode == 125 ? 1 : -1) + results.count) % results.count
            popup.select(selection)
            return swallow(keyCode)
        case 36, 76, 48:  // return, enter, tab
            guard showing else { reset(); lastChar = "\n"; return false }
            commit(results[selection].emoji)
            return swallow(keyCode)
        case 51:  // delete
            if capturing {
                if query.isEmpty { reset() } else { query.removeLast(); refresh() }
            }
            lastChar = nil
            return false
        case 115, 116, 117, 119, 121, 123, 124:  // home, pgup, fwd-delete, end, pgdn, ← →
            reset()
            lastChar = nil
            return false
        default:
            break
        }

        guard let ch = characters(of: event) else {
            reset()
            return false
        }

        if capturing {
            if ch == ":" {
                // Closing colon on an exact shortcode (":tada:") replaces it straight away.
                if let exact = engine.exactShortcode(query) {
                    commit(exact)
                    return swallow(keyCode)
                }
                reset()
                lastChar = ch
                return false
            }
            if (ch.isLetter || ch.isNumber || "_+-".contains(ch)), query.count < 40 {
                query.append(ch)
                lastChar = ch
                refresh()
                return false
            }
            reset()
        }

        if ch == ":", isBoundary(lastChar), Settings.shared.enabled, !frontmostAppExcluded() {
            begin()
        }
        lastChar = ch
        return false
    }

    private func characters(of event: CGEvent) -> Character? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: buffer, count: length)
        return s.count == 1 ? s.first : nil
    }

    /// ":" only triggers after whitespace, punctuation or the start of a field (not "10:30" or "https:").
    private func isBoundary(_ previous: Character?) -> Bool {
        guard let previous else { return true }
        return !(previous.isLetter || previous.isNumber || previous == ":" || previous == "/")
    }

    /// Cheap bundle-ID check, safe inside the tap callback. Browser tabs are checked later, off the main thread.
    private func frontmostAppExcluded() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Settings.shared.excludedApps.contains(id)
    }

    /// Full check including the focused browser tab (blocking; for the self-test).
    func frontmostIsExcluded() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return false }
        if Settings.shared.excludedApps.contains(id) { return true }
        return Settings.browsers.contains(id) && BrowserTab.hasOwnPicker(pid: app.processIdentifier)
    }

    private func swallow(_ keyCode: Int64) -> Bool {
        swallowedKeyUps.insert(keyCode)
        return true
    }

    // MARK: - Capture lifecycle

    private func begin() {
        capturing = true
        query = ""
        anchor = nil
        lookupPending = true
        captureID += 1
        let id = captureID
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let isBrowser = app.bundleIdentifier.map(Settings.browsers.contains) ?? false
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        // Accessibility calls can block for a long time (Chrome's first answer especially). Doing them in the
        // tap callback gets the tap disabled by macOS, and keys like ↓ slip past, so they run off the main thread.
        axQueue.async { [weak self] in
            let excluded = isBrowser && BrowserTab.hasOwnPicker(pid: pid)
            let caret = excluded ? nil : Caret.rect(pid: pid, primaryHeight: primaryHeight)
            DispatchQueue.main.async {
                guard let self, self.capturing, self.captureID == id else { return }
                self.lookupPending = false
                if excluded { self.reset(); return }
                self.anchor = caret
                self.refresh()
            }
        }
    }

    /// Re-asks for the caret while we only have the text box position (Chrome warms up after a keystroke or two).
    private func retryCaret() {
        guard !caretLookupInFlight, anchor?.precise != true,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        caretLookupInFlight = true
        let id = captureID
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        axQueue.async { [weak self] in
            let caret = Caret.rect(pid: pid, primaryHeight: primaryHeight)
            DispatchQueue.main.async {
                guard let self else { return }
                self.caretLookupInFlight = false
                guard self.capturing, self.captureID == id, let caret, self.anchor?.precise != true else { return }
                self.anchor = caret
                if self.popup.isVisible { self.showPopup() }
            }
        }
    }

    private func refresh() {
        guard capturing, !lookupPending, query.count >= Settings.shared.minChars else {
            results = []
            popup.hide()
            return
        }
        if query != shownQuery { selection = 0 }
        shownQuery = query
        localResults = engine.search(query, limit: 8)
        results = jevCache[query].map { engine.merge(local: localResults, jev: $0) } ?? localResults
        selection = min(selection, max(results.count - 1, 0))
        scheduleJev()
        guard !results.isEmpty else {
            popup.hide()
            return
        }
        showPopup()
        retryCaret()
    }

    /// Asks Jev once typing pauses briefly; a newer keystroke cancels the pending or in-flight call.
    private func scheduleJev() {
        jevWork?.cancel()
        jevTask?.cancel()
        guard let client = jevClient, query.count >= 3, jevCache[query] == nil else { return }
        let q = query
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.capturing, self.query == q else { return }
            let candidates = self.engine.jevCandidates(q)
            self.jevTask = Task { @MainActor [weak self] in
                do {
                    let ranking = try await client.rank(query: q, candidates: candidates)
                    self?.applyJev(ranking, for: q)
                } catch is CancellationError {
                } catch let error as URLError where error.code == .cancelled {
                } catch {
                    mojiLog("jev: \(error)")
                }
            }
        }
        jevWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func applyJev(_ ranking: JevRanking, for q: String) {
        jevCache[q] = ranking
        if jevCache.count > 200 { jevCache.removeAll() }
        guard capturing, query == q, !localResults.isEmpty || !ranking.probabilities.isEmpty else { return }
        // Keep what the user arrowed to, if they already moved off the top row.
        let picked = selection > 0 && selection < results.count ? results[selection].emoji.char : nil
        results = engine.merge(local: localResults, jev: ranking)
        selection = picked.flatMap { char in results.firstIndex { $0.emoji.char == char } } ?? 0
        guard !results.isEmpty else { return }
        showPopup()
    }

    private func showPopup() {
        let mouse = NSEvent.mouseLocation
        let at = anchor?.rect ?? NSRect(x: mouse.x, y: mouse.y - 10, width: 1, height: 18)
        popup.show(results: results, selection: selection, tone: Settings.shared.skinTone, anchor: at)
    }

    private func commit(_ emoji: Emoji) {
        let deleteCount = query.count + 1  // the query plus its opening ":"
        let text = emoji.withTone(Settings.shared.skinTone)
        usage.record(emoji.char)
        reset()
        lastChar = text.last
        Inserter.replace(deleting: deleteCount, with: text)
    }

    func reset() {
        jevWork?.cancel()
        jevTask?.cancel()
        localResults = []
        capturing = false
        query = ""
        shownQuery = ""
        results = []
        selection = 0
        popup.hide()
    }
}
