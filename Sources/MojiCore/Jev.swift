import Foundation
import Security

/// Optional re-ranking with TypeSafe's Jev (https://docs.typesafe.ai): one Choice question
/// "which of these emoji does the person mean?" over ~200 candidates, answered with a probability each.
/// Only the typed query leaves the Mac.
public struct JevRanking: Sendable {
    /// Candidate emoji characters → probability, summing to ~1.
    public let probabilities: [String: Double]
    public let confidence: Double
    public let latency: TimeInterval
    public let inputTokens: Int
}

public enum JevError: Error, CustomStringConvertible {
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case let .http(code, body): return "Jev HTTP \(code): \(body.prefix(200))"
        case .badResponse: return "Jev returned an unexpected response"
        }
    }
}

public final class JevClient: @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "jev-latest") {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        session = URLSession(configuration: config)
    }

    public func rank(query: String, candidates: [Emoji]) async throws -> JevRanking {
        // Option names must be unique; shortcodes are, but guard anyway.
        var criteria: [String: String] = [:]
        var charForOption: [String: String] = [:]
        for e in candidates {
            var name = e.primaryShortcode
            if criteria[name] != nil { name += "_\(e.order)" }
            let hints = e.keywords.prefix(4).joined(separator: ", ")
            criteria[name] = hints.isEmpty ? "\(e.char) \(e.name)" : "\(e.char) \(e.name): \(hints)"
            charForOption[name] = e.char
        }
        let body: [String: Any] = [
            "model": model,
            "state": ["typed": query],
            "questions": [
                "emoji": [
                    "type": "choice",
                    "instructions": "`typed` is what a person typed after a colon to insert an emoji while writing. "
                        + "It may be an emoji shortcode, a partial word, chat slang, a typo, or a short description "
                        + "of a feeling or thing. Choose the emoji they most likely want to insert.",
                    "criteria": criteria,
                ],
            ],
        ]

        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, response) = try await session.data(for: request)
        let latency = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else { throw JevError.badResponse }
        guard http.statusCode == 200 else {
            throw JevError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let answer = answers["emoji"] as? [String: Any],
              let probabilities = answer["probabilities"] as? [String: Double]
        else { throw JevError.badResponse }

        var byChar: [String: Double] = [:]
        for (option, p) in probabilities {
            if let char = charForOption[option] { byChar[char, default: 0] += p }
        }
        let usage = json["usage"] as? [String: Any]
        return JevRanking(
            probabilities: byChar,
            confidence: answer["confidence"] as? Double ?? 0,
            latency: latency,
            inputTokens: usage?["input_tokens"] as? Int ?? 0
        )
    }
}

extension SearchEngine {
    /// What Jev chooses from: the local matches (per term too) plus the most-used emoji,
    /// in standard emoji order so the option list doesn't hint at the local ranking.
    public func jevCandidates(_ query: String, limit: Int = 220) -> [Emoji] {
        var seen = Set<String>()
        var picked: [Emoji] = []
        func add(_ e: Emoji) {
            if picked.count < limit, seen.insert(e.char).inserted { picked.append(e) }
        }
        search(query, limit: 60).forEach { add($0.emoji) }
        let terms = Self.tokenize(query)
        if terms.count > 1 { for term in terms { search(term, limit: 20).forEach { add($0.emoji) } } }
        popularEmoji.forEach(add)
        return picked.sorted { $0.order < $1.order }
    }

    /// Blends Jev's probabilities with the local ranking. An exact shortcode hit stays on top;
    /// rows Jev lifted above their local position get a "✦ Jev" note.
    public func merge(local: [SearchResult], jev: JevRanking, limit: Int = 8) -> [SearchResult] {
        let localRank = Dictionary(local.enumerated().map { ($1.emoji.char, $0) }, uniquingKeysWith: min)
        var pool: [String: (emoji: Emoji, localReason: String?)] = [:]
        for r in local { pool[r.emoji.char] = (r.emoji, r.reason) }

        // Literal local matches (shortcode/name/keyword/slang) keep real weight; typo and
        // look-alike guesses ("wholesome" ≈ hole) barely count once Jev has an opinion.
        let literal = Set(local.filter { $0.reason == nil }.map(\.emoji.char))
        func blended(_ char: String) -> Double {
            let p = jev.probabilities[char] ?? 0
            guard let rank = localRank[char] else { return p }
            return p + (literal.contains(char) ? 0.25 : 0.02) / Double(rank + 1)
        }

        var chars = Set(local.map(\.emoji.char))
        chars.formUnion(jev.probabilities.filter { $0.value >= 0.03 }.keys)  // ignore near-zero long-tail picks
        var ranked = chars.sorted { blended($0) > blended($1) }
        if let exact = local.first, exact.score >= 1000, let i = ranked.firstIndex(of: exact.emoji.char) {
            ranked.insert(ranked.remove(at: i), at: 0)
        }

        return ranked.prefix(limit).enumerated().compactMap { position, char in
            guard let emoji = pool[char]?.emoji ?? self.emoji(for: char) else { return nil }
            let lifted = position < (localRank[char] ?? Int.max)
            let reason = lifted && (jev.probabilities[char] ?? 0) >= 0.05 ? "✦ Jev" : pool[char]?.localReason
            return SearchResult(emoji: emoji, score: blended(char), reason: reason)
        }
    }
}

/// Stores the TypeSafe API key in the login Keychain. The key is typed into the app by the user.
public enum JevKeychain {
    static let service = "com.beckyisj.moji.jev"
    static let account = "typesafe-api-key"

    public static func read() -> String? {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Moji – TypeSafe (Jev) API key",
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
