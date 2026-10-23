import Foundation
import MojiCore

// Dev harness.
//   swift run moji-search tada yay thmbs          → local ranking per query
//   swift run moji-search --jev awkward ship_it   → local vs Jev side by side
//     (key from TYPESAFE_API_KEY, or the one saved in Moji's menu)
let engine = SearchEngine(emoji: EmojiData.load())
var args = Array(CommandLine.arguments.dropFirst())
let useJev = args.contains("--jev")
args.removeAll { $0 == "--jev" }

let defaults = ["tada", "yay", "lol", "thmbs", "celebrate", "sad", "+1", "heart", "ship", "doggo", "angry"]
let jevDefaults = ["awkward", "ship_it", "proud", "deadline", "nervous", "cozy", "facepalm", "spicy", "tired", "bye", "brainstorm", "wholesome"]
let queries = args.isEmpty ? (useJev ? jevDefaults : defaults) : args

func line(_ results: [SearchResult], count: Int = 5) -> String {
    results.prefix(count).map { r in "\(r.emoji.char) \(r.emoji.primaryShortcode)\(r.reason.map { " (\($0))" } ?? "")" }
        .joined(separator: "  ")
}

if !useJev {
    for query in queries {
        let start = Date()
        let results = engine.search(query, limit: 6)
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "%-10@ %5.1fms  ", query as NSString, ms) + line(results, count: 6))
    }
    exit(0)
}

guard let key = JevKeychain.read() else {
    print("No Jev key: set TYPESAFE_API_KEY or save one from Moji's menu (Jev → Set API Key…).")
    exit(1)
}
let client = JevClient(apiKey: key)
var totalTokens = 0
for query in queries {
    let local = engine.search(query, limit: 8)
    let candidates = engine.jevCandidates(query)
    do {
        let ranking = try await client.rank(query: query, candidates: candidates)
        totalTokens += ranking.inputTokens
        let merged = engine.merge(local: local, jev: ranking)
        print(":\(query)   (\(candidates.count) options, \(Int(ranking.latency * 1000))ms, confidence \(String(format: "%.2f", ranking.confidence)))")
        print("  local  " + (local.isEmpty ? "—" : line(local)))
        print("  jev    " + line(merged))
    } catch {
        print(":\(query)   error: \(error)")
    }
}
print(String(format: "\n%d input tokens ≈ $%.5f", totalTokens, Double(totalTokens) * 0.042 / 1_000_000))
