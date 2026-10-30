import Foundation

/// Preferences, persisted in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Apps with their own ":" emoji picker, or where ":" is code.
    static let defaultExcluded: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
        "com.figma.Desktop",
        "com.roam-research.desktop-app",
        "com.microsoft.teams2",
        "com.linear",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "org.python.IDLE",
        "com.1password.1password",
        "net.matthewpalmer.Rocket",
    ]

    /// Web apps with their own picker; matched against the focused browser tab's URL host.
    static let excludedSites = [
        "slack.com", "discord.com", "github.com", "x.com", "twitter.com", "linear.app", "notion.so", "notion.com", "notion.site",
        "web.whatsapp.com", "web.telegram.org", "chat.google.com", "teams.microsoft.com",
        "teams.live.com", "figma.com", "roamresearch.com", "app.asana.com",
    ]

    /// Fallback when a browser doesn't expose the URL: tab-title suffixes those sites use.
    static let excludedTitleMarkers = [
        "- slack", "| slack", "discord", "· github", "- github", "linear", "| notion", "- notion",
        " / x", "whatsapp", "telegram", "google chat", "microsoft teams", "– figma", "- figma",
    ]

    static let browsers: Set<String> = [
        "com.google.Chrome", "company.thebrowser.Browser", "company.thebrowser.dia", "com.apple.Safari",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
    ]

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// 0 = default yellow, 1–5 = light → dark.
    var skinTone: Int {
        get { defaults.integer(forKey: "skinTone") }
        set { defaults.set(newValue, forKey: "skinTone") }
    }

    /// Re-rank suggestions with Jev when an API key is saved.
    var jevEnabled: Bool {
        get { defaults.object(forKey: "jevEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "jevEnabled") }
    }

    /// Letters to type after ":" before the popup appears.
    var minChars: Int {
        get { defaults.object(forKey: "minChars") as? Int ?? 2 }
        set { defaults.set(newValue, forKey: "minChars") }
    }

    /// Defaults plus the user's own toggles, stored as overrides so new defaults still apply.
    var excludedApps: Set<String> {
        Self.defaultExcluded.union(set("userExcluded")).subtracting(set("userIncluded"))
    }

    func setExcluded(_ id: String, _ excluded: Bool) {
        var add = set("userExcluded"), remove = set("userIncluded")
        if excluded { add.insert(id); remove.remove(id) } else { add.remove(id); remove.insert(id) }
        defaults.set(Array(add).sorted(), forKey: "userExcluded")
        defaults.set(Array(remove).sorted(), forKey: "userIncluded")
    }

    /// Sites where Moji stays off: defaults plus the user's own toggles (same override scheme as apps).
    var excludedSites: Set<String> {
        Set(Self.excludedSites).union(set("userExcludedSites")).subtracting(set("userIncludedSites"))
    }

    /// The list entry covering `host` ("github.com" covers "gist.github.com"), if any.
    func excludedSite(covering host: String) -> String? {
        excludedSites.first { host == $0 || host.hasSuffix("." + $0) }
    }

    func setSiteExcluded(_ site: String, _ excluded: Bool) {
        var add = set("userExcludedSites"), remove = set("userIncludedSites")
        if excluded { add.insert(site); remove.remove(site) } else { add.remove(site); remove.insert(site) }
        defaults.set(Array(add).sorted(), forKey: "userExcludedSites")
        defaults.set(Array(remove).sorted(), forKey: "userIncludedSites")
    }

    private func set(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}

/// Frecency: how often and how recently each emoji was picked. Feeds the search ranking.
final class UsageStore {
    private let key = "usage"
    private var usage: [String: [Double]]  // char → [count, lastUsed]

    init() {
        usage = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }

    func record(_ char: String) {
        let count = (usage[char]?.first ?? 0) + 1
        usage[char] = [count, Date().timeIntervalSince1970]
        UserDefaults.standard.set(usage, forKey: key)
    }

    func boost(for char: String) -> Double {
        guard let entry = usage[char], entry.count == 2 else { return 0 }
        let days = (Date().timeIntervalSince1970 - entry[1]) / 86_400
        let recency = pow(0.5, days / 30)  // halves every month unused
        return min(60, 22 * log2(1 + entry[0])) * (0.4 + 0.6 * recency)
    }
}
