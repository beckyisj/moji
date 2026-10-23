import Foundation

public struct Emoji: Decodable, Hashable, Sendable {
    /// The emoji itself, e.g. "🎉".
    public let char: String
    /// CLDR label, e.g. "party popper".
    public let name: String
    /// Slack + GitHub shortcodes, e.g. ["tada"].
    public let shortcodes: [String]
    /// CLDR + GitHub keywords, e.g. ["celebrate", "hooray", ...].
    public let keywords: [String]
    /// Position in the standard emoji ordering (smileys first).
    public let order: Int
    /// Five skin-tone variants, light to dark, when the emoji supports them.
    public let skins: [String]?

    enum CodingKeys: String, CodingKey {
        case char = "e", name = "n", shortcodes = "s", keywords = "k", order = "o", skins = "t"
    }

    public var primaryShortcode: String {
        shortcodes.first ?? name.replacingOccurrences(of: " ", with: "_")
    }

    /// `tone` is 0 for the default yellow, 1–5 for light → dark.
    public func withTone(_ tone: Int) -> String {
        guard tone > 0, let skins, skins.count == 5 else { return char }
        return skins[tone - 1]
    }
}

public enum EmojiData {
    /// Loads emoji.json from the app bundle, or from the repo's Resources folder when run via `swift run`.
    public static func load() -> [Emoji] {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "emoji", withExtension: "json"),
            ProcessInfo.processInfo.environment["MOJI_DATA"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/emoji.json"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let emoji = try? JSONDecoder().decode([Emoji].self, from: data) {
                return emoji
            }
        }
        return []
    }
}
