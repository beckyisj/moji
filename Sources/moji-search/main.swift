import Foundation
import MojiCore

// Dev harness: `swift run moji-search tada yay thmbs celebrate` prints the top results per query.
let engine = SearchEngine(emoji: EmojiData.load())
let queries = CommandLine.arguments.dropFirst()
for query in queries.isEmpty ? ["tada", "yay", "lol", "thmbs", "celebrate", "sad", "+1", "heart", "fi", "ship", "doggo", "angry"] : Array(queries) {
    let start = Date()
    let results = engine.search(query, limit: 6)
    let ms = Date().timeIntervalSince(start) * 1000
    let line = results.map { r in "\(r.emoji.char) \(r.emoji.primaryShortcode)\(r.reason.map { " (\($0))" } ?? "")" }
    print(String(format: "%-10@ %5.1fms  ", query as NSString, ms) + line.joined(separator: "  "))
}
