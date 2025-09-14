// DBTablesCatalog.swift
import Foundation
import SwiftUI

/// Global catalog of all real DB tables, used for autosuggest.
/// Backed by a JSON file at: ~/Library/Containers/.../Application Support/SQLMaestro/db_tables_catalog.json
final class DBTablesCatalog: ObservableObject {
    static let shared = DBTablesCatalog()
    private init() {
        ensureAppSupport()
        load()
    }

    // MARK: - Published state

    @Published private(set) var allTables: [String] = []
    @Published private(set) var lastLoadedAt: Date? = nil

    // Lowercased copy for quick case-insensitive lookups
    private var allLower: [String] = []

    // MARK: - Public API

    func reload() {
        load()
    }

    /// Fuzzy subsequence suggest (top-N).
    /// Examples that should match: "pods" → "mcs_kubernetes_pods", "mcskub" → same, "kubpod" → same.
    func suggest(_ query: String, limit: Int = 15) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, !allTables.isEmpty else { return [] }

        // Score every candidate; keep the top N (700 is tiny, so full scan is fine)
        var scored: [(name: String, score: Int)] = []
        scored.reserveCapacity(min(allTables.count, 256))

        for (i, low) in allLower.enumerated() {
            if let s = fuzzyScore(haystack: low, original: allTables[i], needle: q) {
                scored.append((name: allTables[i], score: s))
            }
        }

        // Sort: highest score first; tiebreak by shorter name, then lexicographically
        scored.sort { (a, b) in
            if a.score != b.score { return a.score > b.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        // Return top-N
        let n = min(limit, scored.count)
        if n == 0 { return [] }
        return Array(scored.prefix(n).map { $0.name })
    }

    // MARK: - Loading

    private func load() {
        let url = Self.catalogURL()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                // supports either ["t1","t2"] or { "tables": ["t1","t2"] }
                if let arr = try? JSONDecoder().decode([String].self, from: data) {
                    applyTables(arr)
                } else {
                    struct Wrapper: Decodable { let tables: [String] }
                    let w = try JSONDecoder().decode(Wrapper.self, from: data)
                    applyTables(w.tables)
                }
                lastLoadedAt = Date()
                LOG("DB catalog loaded", ctx: ["count": "\(allTables.count)"])
            } else {
                allTables = []
                allLower = []
                LOG("DB catalog missing", ctx: ["path": url.path])
            }
        } catch {
            allTables = []
            allLower = []
            LOG("DB catalog load failed", ctx: ["error": error.localizedDescription])
        }
    }

    private func applyTables(_ raw: [String]) {
        // normalize (trim, validate charset, de-dup)
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(raw.count)
        for t in raw {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard isValidTableName(trimmed) else {
                LOG("Catalog: invalid name skipped", ctx: ["value": trimmed])
                continue
            }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                out.append(trimmed)
                seen.insert(key)
            }
        }
        allTables = out
        allLower = out.map { $0.lowercased() }
    }

    // MARK: - Fuzzy matcher

    /// Returns an integer score if `needle` is a subsequence of `haystack`; otherwise nil.
    /// Heuristics:
    /// - base point for each matched character
    /// - + bonuses for matches at start-of-string / after "_" (word boundary)
    /// - + bonuses for consecutive matches (contiguous run)
    /// - - small penalty for gaps across the span
    /// The exact weights are tuned for cases like "mcskub" → "mcs_kubernetes_pods" and "kubpod" → same.
    private func fuzzyScore(haystack: String, original: String, needle: String) -> Int? {
        // Quick fails
        guard !needle.isEmpty else { return 0 }
        // Must be subsequence
        var hIdx = haystack.startIndex
        var firstMatch: String.Index? = nil
        var lastMatch:  String.Index? = nil

        var score = 0
        var streak = 0

        // Iterate needle chars in order
        for ch in needle {
            var found = false
            while hIdx < haystack.endIndex {
                if haystack[hIdx] == ch {
                    // Base
                    var pts = 5

                    // Word boundary bonus (start-of-string or after a non-alnum or underscore)
                    if isBoundary(in: haystack, at: hIdx) {
                        pts += 12
                    }

                    // Start-of-string extra bonus
                    if hIdx == haystack.startIndex {
                        pts += 8
                    }

                    // Consecutive match bonus
                    if let last = lastMatch {
                        if haystack.index(after: last) == hIdx {
                            streak += 1
                            pts += 6 + min(streak * 2, 10) // growing, capped
                        } else {
                            streak = 0
                        }
                    } else {
                        streak = 0
                    }

                    score += pts
                    if firstMatch == nil { firstMatch = hIdx }
                    lastMatch = hIdx

                    hIdx = haystack.index(after: hIdx)
                    found = true
                    break
                } else {
                    hIdx = haystack.index(after: hIdx)
                }
            }
            if !found {
                return nil // not a subsequence
            }
        }

        // Gap penalty over the covered span (discourage huge spreads)
        if let f = firstMatch, let l = lastMatch {
            let span = haystack.distance(from: f, to: l) + 1
            let gaps = span - needle.count
            score -= max(0, gaps) // small penalty per gap
        }

        // Gentle bias toward shorter names
        score -= original.count / 8

        return score
    }

    /// Boundary if at start, or previous char is not alnum, or is underscore.
    /// This makes tokens like "mcs", "kubernetes", "pods" feel separate.
    private func isBoundary(in s: String, at idx: String.Index) -> Bool {
        if idx == s.startIndex { return true }
        let prev = s[s.index(before: idx)]
        if prev == "_" { return true }
        return !(prev.isLetter || prev.isNumber)
    }

    // MARK: - Paths

    static func catalogURL() -> URL {
        let app = appSupportDir()
            .appendingPathComponent("SQLMaestro", isDirectory: true)
            .appendingPathComponent("db_tables_catalog.json", isDirectory: false)
        return app
    }

    private static func appSupportDir() -> URL {
        // App sandbox will resolve to the containerized Application Support automatically.
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base
    }

    private func ensureAppSupport() {
        let dir = Self.appSupportDir().appendingPathComponent("SQLMaestro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Validation

    private func isValidTableName(_ s: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
