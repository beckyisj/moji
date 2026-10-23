import Foundation
import NaturalLanguage

public struct SearchResult: Hashable, Sendable {
    public let emoji: Emoji
    public let score: Double
    /// Shown when the match wasn't literal, e.g. "≈ celebrate" for a semantic or typo match.
    public let reason: String?
}

/// Ranks emoji for a typed query. Layers, strongest first:
/// shortcodes → name words → keywords → chat slang → typo tolerance → on-device word embeddings,
/// plus a frecency boost so the emoji you actually use float up.
public final class SearchEngine {
    public let emoji: [Emoji]
    /// Extra score for an emoji character based on how often/recently it was used (0–60 is sensible).
    public var usageBoost: (String) -> Double = { _ in 0 }

    private struct Entry {
        let codes: [String]
        let codeTokens: Set<String>
        let nameFull: String
        let nameWords: [String]
        let keywords: Set<String>
        let key: String
        var allTokens: Set<String> { codeTokens.union(nameWords).union(keywords) }
    }

    private let entries: [Entry]
    private let vocabulary: [String]
    private let vocabularySet: Set<String>
    private let embedding = NLEmbedding.wordEmbedding(for: .english)
    private var semanticCache: [String: [(word: String, similarity: Double)]] = [:]
    private var fuzzyCache: [String: Set<String>] = [:]
    private let slang: [String: [String]]
    private let index: [String: [Int]]
    private let entriesByKey: [String: [Int]]
    private let popularity: [String: Double]

    public init(emoji: [Emoji]) {
        self.emoji = emoji
        entries = emoji.map { e in
            let codes = e.shortcodes.map { $0.lowercased() }
            return Entry(
                codes: codes,
                codeTokens: Set(codes + codes.flatMap(Self.tokenize)),
                nameFull: e.name.lowercased(),
                nameWords: Self.tokenize(e.name),
                keywords: Set(e.keywords.flatMap(Self.tokenize)),
                key: Self.normalize(e.char)
            )
        }
        var index: [String: [Int]] = [:]
        var byKey: [String: [Int]] = [:]
        for (i, entry) in entries.enumerated() {
            for token in entry.allTokens { index[token, default: []].append(i) }
            byKey[entry.key, default: []].append(i)
        }
        self.index = index
        entriesByKey = byKey
        vocabularySet = Set(index.keys)
        vocabulary = index.keys.sorted()
        slang = Slang.map.mapValues { $0.map(Self.normalize) }
        popularity = Dictionary(
            Popularity.ranked.enumerated().map { (Self.normalize($1), 45 * (1 - Double($0) / Double(Popularity.ranked.count))) },
            uniquingKeysWith: max
        )
    }

    public func search(_ rawQuery: String, limit: Int = 8) -> [SearchResult] {
        var query = rawQuery.lowercased()
        while true {
            let results = rank(query, limit: limit)
            // "doggo" → "dogg" → "dog": back off one letter at a time before giving up.
            if !results.isEmpty || query.count <= 3 { return results }
            query.removeLast()
        }
    }

    private func rank(_ query: String, limit: Int) -> [SearchResult] {
        let terms = Self.tokenize(query)
        guard !query.isEmpty else { return [] }
        let spaced = terms.joined(separator: " ")
        let underscored = terms.joined(separator: "_")

        // Candidates: entries where every term hits something (literally, or via a fallback layer),
        // plus anything whose full shortcode starts with the raw query.
        var fuzzyTerms = Set<String>(), semanticTerms = Set<String>()
        var candidates: Set<Int>?
        for term in terms {
            var hits = lexicalHits(term)
            let literal = hits.count
            for key in slang[term] ?? [] { hits.formUnion(entriesByKey[key] ?? []) }
            if literal < 3, term.count >= 4 {
                fuzzyTerms.insert(term)
                for word in fuzzyMatches(term) { hits.formUnion(index[word] ?? []) }
            }
            if literal < 8 {
                semanticTerms.insert(term)
                for (word, _) in semanticNeighbors(term) { hits.formUnion(index[word] ?? []) }
            }
            candidates = candidates.map { $0.intersection(hits) } ?? hits
        }
        var pool = candidates ?? []
        pool.formUnion(lexicalHits(query))
        if underscored != query { pool.formUnion(lexicalHits(underscored)) }
        for key in slang[query] ?? [] { pool.formUnion(entriesByKey[key] ?? []) }

        var results: [SearchResult] = []
        for i in pool {
            let entry = entries[i]
            var score = 0.0
            var reason: String?

            // Whole-query matches against full shortcodes, the full name and slang.
            for (rank, code) in entry.codes.enumerated() {
                if code == query || code == underscored {
                    score = max(score, 1000 - Double(rank) * 10)
                } else if code.hasPrefix(query) || code.hasPrefix(underscored) {
                    let coverage = Double(query.count) / Double(code.count)
                    score = max(score, 100 + 300 * coverage * coverage)
                }
            }
            if entry.nameFull == spaced {
                score = max(score, 900)
            } else if terms.count > 1, entry.nameFull.hasPrefix(spaced) {
                score = max(score, 380 + 200 * Double(spaced.count) / Double(entry.nameFull.count))
            }
            if let picks = slang[query], let idx = picks.firstIndex(of: entry.key) {
                score = max(score, 800 - Double(idx) * 20)
            }

            // Every term has to land somewhere for the per-term score to count.
            var termTotal = 0.0
            var allTermsMatched = !terms.isEmpty
            for term in terms {
                var best = 0.0
                var termReason: String?
                best = max(best, Self.match(term, in: entry.codeTokens, exact: 120, prefix: 60))
                for (w, word) in entry.nameWords.enumerated() {
                    best = max(best, Self.match(term, word: word, exact: w == 0 ? 110 : 100, prefix: 50))
                }
                best = max(best, Self.match(term, in: entry.keywords, exact: 80, prefix: 35))

                if let picks = slang[term], let idx = picks.firstIndex(of: entry.key) {
                    best = max(best, 140 - Double(idx) * 6)
                }
                if best == 0, fuzzyTerms.contains(term) {
                    let typos = fuzzyMatches(term)
                    if let typo = typos.first(where: { entry.codeTokens.contains($0) || entry.nameWords.contains($0) }) {
                        best = 45
                        termReason = "≈ \(typo)"
                    } else if let typo = typos.first(where: entry.keywords.contains) {
                        best = 30
                        termReason = "≈ \(typo)"
                    }
                }
                if best == 0, semanticTerms.contains(term) {
                    for (word, similarity) in semanticNeighbors(term) where entry.allTokens.contains(word) {
                        let s = 60 * similarity
                        if s > best { best = s; termReason = "≈ \(word)" }
                    }
                }
                if best == 0 { allTermsMatched = false; break }
                termTotal += best
                if reason == nil { reason = termReason }
            }

            if allTermsMatched { score += termTotal } else if score == 0 { continue }
            if score >= 300 { reason = nil }

            let e = emoji[i]
            score += popularity[entry.key] ?? max(0, 6 - Double(e.order) / 400)
            score -= Double(max(0, entry.nameWords.count - 2))  // prefer "fire" over "fire engine"
            score += usageBoost(e.char)
            results.append(SearchResult(emoji: e, score: score, reason: reason))
        }

        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.emoji.order < $1.emoji.order }
        // Fallback-layer matches are only worth showing when nothing literal is clearly better.
        let top = results.first?.score ?? 0
        results.removeAll { $0.score < top * 0.1 || ($0.reason != nil && $0.score < top * 0.45) }
        return Array(results.prefix(limit))
    }

    /// Entries with any token equal to or starting with `term` (binary search over the sorted vocabulary).
    private func lexicalHits(_ term: String) -> Set<Int> {
        var lo = 0, hi = vocabulary.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if vocabulary[mid] < term { lo = mid + 1 } else { hi = mid }
        }
        var hits = Set<Int>()
        while lo < vocabulary.count, vocabulary[lo].hasPrefix(term) {
            hits.formUnion(index[vocabulary[lo]] ?? [])
            lo += 1
        }
        return hits
    }

    /// The most-used emoji, most popular first.
    public var popularEmoji: [Emoji] {
        Popularity.ranked.compactMap { emoji(for: $0) }
    }

    public func emoji(for char: String) -> Emoji? {
        entriesByKey[Self.normalize(char)]?.first.map { emoji[$0] }
    }

    /// An exact shortcode hit, used when someone types the closing colon (":tada:").
    public func exactShortcode(_ query: String) -> Emoji? {
        let q = query.lowercased()
        return entries.firstIndex { $0.codes.contains(q) }.map { emoji[$0] }
    }

    // MARK: - Matching layers

    private static func match(_ term: String, in tokens: Set<String>, exact: Double, prefix: Double) -> Double {
        if tokens.contains(term) { return exact }
        var best = 0.0
        for t in tokens { best = max(best, match(term, word: t, exact: exact, prefix: prefix)) }
        return best
    }

    private static func match(_ term: String, word: String, exact: Double, prefix: Double) -> Double {
        if word == term { return exact }
        if word.hasPrefix(term) { return prefix + 40 * Double(term.count) / Double(word.count) }
        return 0
    }

    private func fuzzyMatches(_ term: String) -> Set<String> {
        if let cached = fuzzyCache[term] { return cached }
        let maxDistance = term.count >= 7 ? 2 : 1
        let t = Array(term)
        var found = Set<String>()
        for word in vocabulary where abs(word.count - term.count) <= maxDistance || word.count > term.count {
            let w = Array(word)
            // Compare against the whole word and against its same-length prefix (typo mid-typing).
            if Self.damerau(t, w, limit: maxDistance) <= maxDistance
                || (w.count > t.count && Self.damerau(t, Array(w.prefix(t.count)), limit: maxDistance) <= maxDistance) {
                found.insert(word)
            }
        }
        fuzzyCache[term] = found
        return found
    }

    private func semanticNeighbors(_ term: String) -> [(word: String, similarity: Double)] {
        if let cached = semanticCache[term] { return cached }
        var out: [(String, Double)] = []
        if term.count >= 3, let embedding, embedding.contains(term) {
            for (word, distance) in embedding.neighbors(for: term, maximumCount: 40)
            where distance < 0.95 && vocabularySet.contains(word) {
                out.append((word, max(0.2, 1 - distance / 1.3)))
            }
        }
        semanticCache[term] = out
        return out
    }

    // MARK: - Helpers

    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "+") }
            .map(String.init)
    }

    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{FE0F}", with: "")
    }

    /// Optimal-string-alignment distance with early exit once every cell in a row exceeds `limit`.
    static func damerau(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a == b { return 0 }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    cur[j] = min(cur[j], prev2[j - 2] + 1)
                }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }
}
