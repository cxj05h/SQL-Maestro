//
//  GhostOverlayComparison.swift
//  SQLMaestro
//
//  Ghost overlay comparison for JSON/YAML files
//

import Foundation

// MARK: - Diff Line Types

enum DiffLineType: Equatable {
    case match                  // Line exists in both, identical
    case onlyInOriginal        // Line in original, not in ghost (RED)
    case onlyInGhost           // Line in ghost, not in original (GREEN)
    case modified              // Line exists in both but different (GREEN in ghost, RED in original)
}

// MARK: - Diff Line

struct DiffLine: Identifiable, Equatable {
    let id = UUID()
    let originalLineNumber: Int?    // nil if only in ghost
    let ghostLineNumber: Int?       // nil if only in original
    let originalContent: String?
    let ghostContent: String?
    let type: DiffLineType

    var isMatch: Bool {
        type == .match
    }

    var isDifference: Bool {
        !isMatch
    }
}

// MARK: - Collapsed Section

struct CollapsedSection: Identifiable, Equatable {
    let id = UUID()
    let startLine: Int              // Index in diffLines array
    let endLine: Int                // Index in diffLines array (inclusive)
    let lineCount: Int
    let preview: String             // Mini preview of content
    var isExpanded: Bool = false

    var displayText: String {
        "Lines \(startLine + 1)-\(endLine + 1) match (\(lineCount) lines)"
    }
}

// MARK: - Diff Result

struct DiffResult {
    let diffLines: [DiffLine]
    var collapsedSections: [CollapsedSection]

    var differenceCount: Int {
        diffLines.filter { $0.isDifference }.count
    }

    var differenceIndices: [Int] {
        diffLines.enumerated()
            .filter { $0.element.isDifference }
            .map { $0.offset }
    }
}

// MARK: - Ghost Overlay Diff Engine

class GhostOverlayDiffEngine {

    // MARK: - Public Interface

    /// Compares two files and returns diff result with smart alignment
    static func compare(original: String, ghost: String) -> DiffResult {
        let originalLines = original.components(separatedBy: .newlines)
        let ghostLines = ghost.components(separatedBy: .newlines)

        // Perform smart key-based alignment
        let alignedDiff = performSmartAlignment(original: originalLines, ghost: ghostLines)

        // Filter out false positives (same content, different line positions)
        let filteredDiff = filterFalsePositiveDifferences(from: alignedDiff)

        // Create collapsed sections for matching blocks
        let collapsedSections = createCollapsedSections(from: filteredDiff)

        return DiffResult(diffLines: filteredDiff, collapsedSections: collapsedSections)
    }

    // MARK: - Smart Alignment Algorithm

    private static func performSmartAlignment(original: [String], ghost: [String]) -> [DiffLine] {
        var result: [DiffLine] = []
        var originalIndex = 0
        var ghostIndex = 0

        while originalIndex < original.count || ghostIndex < ghost.count {
            let origLine = originalIndex < original.count ? original[originalIndex] : nil
            let ghostLine = ghostIndex < ghost.count ? ghost[ghostIndex] : nil

            // Both exhausted
            guard origLine != nil || ghostLine != nil else { break }

            // Only original remaining
            if ghostLine == nil {
                result.append(DiffLine(
                    originalLineNumber: originalIndex,
                    ghostLineNumber: nil,
                    originalContent: origLine,
                    ghostContent: nil,
                    type: .onlyInOriginal
                ))
                originalIndex += 1
                continue
            }

            // Only ghost remaining
            if origLine == nil {
                result.append(DiffLine(
                    originalLineNumber: nil,
                    ghostLineNumber: ghostIndex,
                    originalContent: nil,
                    ghostContent: ghostLine,
                    type: .onlyInGhost
                ))
                ghostIndex += 1
                continue
            }

            // Both have content - compare
            let trimmedOrig = origLine!.trimmingCharacters(in: .whitespaces)
            let trimmedGhost = ghostLine!.trimmingCharacters(in: .whitespaces)

            if trimmedOrig == trimmedGhost {
                // Exact match
                result.append(DiffLine(
                    originalLineNumber: originalIndex,
                    ghostLineNumber: ghostIndex,
                    originalContent: origLine,
                    ghostContent: ghostLine,
                    type: .match
                ))
                originalIndex += 1
                ghostIndex += 1
            } else {
                // Different content - try to determine if it's a modification or insertion/deletion
                let origKey = extractKey(from: trimmedOrig)
                let ghostKey = extractKey(from: trimmedGhost)

                if let ok = origKey, let gk = ghostKey, ok == gk {
                    // Same key, different value = modification
                    result.append(DiffLine(
                        originalLineNumber: originalIndex,
                        ghostLineNumber: ghostIndex,
                        originalContent: origLine,
                        ghostContent: ghostLine,
                        type: .modified
                    ))
                    originalIndex += 1
                    ghostIndex += 1
                } else {
                    // Different keys - need to look ahead to decide
                    let (matchInGhost, ghostOffset) = findMatchingLine(
                        target: trimmedOrig,
                        in: Array(ghost[ghostIndex...]),
                        maxLookAhead: 5
                    )

                    let (matchInOriginal, origOffset) = findMatchingLine(
                        target: trimmedGhost,
                        in: Array(original[originalIndex...]),
                        maxLookAhead: 5
                    )

                    if matchInGhost && (!matchInOriginal || ghostOffset <= origOffset) {
                        // Ghost has insertion(s) before this original line
                        result.append(DiffLine(
                            originalLineNumber: nil,
                            ghostLineNumber: ghostIndex,
                            originalContent: nil,
                            ghostContent: ghostLine,
                            type: .onlyInGhost
                        ))
                        ghostIndex += 1
                    } else if matchInOriginal {
                        // Original has line that ghost deleted
                        result.append(DiffLine(
                            originalLineNumber: originalIndex,
                            ghostLineNumber: nil,
                            originalContent: origLine,
                            ghostContent: nil,
                            type: .onlyInOriginal
                        ))
                        originalIndex += 1
                    } else {
                        // No match found in lookahead - treat as modification
                        result.append(DiffLine(
                            originalLineNumber: originalIndex,
                            ghostLineNumber: ghostIndex,
                            originalContent: origLine,
                            ghostContent: ghostLine,
                            type: .modified
                        ))
                        originalIndex += 1
                        ghostIndex += 1
                    }
                }
            }
        }

        return result
    }

    // MARK: - False Positive Filtering

    /// Filters out false positive differences where content is identical but appears on different lines
    private static func filterFalsePositiveDifferences(from diffLines: [DiffLine]) -> [DiffLine] {
        var result: [DiffLine] = []
        var onlyInOriginalLines: [(index: Int, line: DiffLine)] = []
        var onlyInGhostLines: [(index: Int, line: DiffLine)] = []

        // Collect all "only in" lines
        for (index, line) in diffLines.enumerated() {
            switch line.type {
            case .onlyInOriginal:
                onlyInOriginalLines.append((index, line))
            case .onlyInGhost:
                onlyInGhostLines.append((index, line))
            default:
                break
            }
        }

        // Track indices to skip (false positives that matched)
        var indicesToSkip: Set<Int> = []

        // Find matching content between original and ghost "only in" lines
        for origPair in onlyInOriginalLines {
            guard !indicesToSkip.contains(origPair.index) else { continue }

            let origContent = origPair.line.originalContent?.trimmingCharacters(in: .whitespaces) ?? ""

            // Look for matching content in ghost lines
            for ghostPair in onlyInGhostLines {
                guard !indicesToSkip.contains(ghostPair.index) else { continue }

                let ghostContent = ghostPair.line.ghostContent?.trimmingCharacters(in: .whitespaces) ?? ""

                // If content matches exactly, mark both as false positives
                if origContent == ghostContent && !origContent.isEmpty {
                    indicesToSkip.insert(origPair.index)
                    indicesToSkip.insert(ghostPair.index)
                    break // Found a match, move to next original line
                }
            }
        }

        // Build result array, excluding false positive matches
        for (index, line) in diffLines.enumerated() {
            if !indicesToSkip.contains(index) {
                result.append(line)
            }
        }

        return result
    }

    // MARK: - Helper Functions

    /// Extracts the key from a JSON/YAML line (e.g., "key": value -> "key")
    private static func extractKey(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // JSON style: "key":
        if let range = trimmed.range(of: #"^\s*"([^"]+)"\s*:"#, options: .regularExpression) {
            let key = trimmed[range].replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            return key
        }

        // YAML style: key:
        if let range = trimmed.range(of: #"^\s*([^:]+):"#, options: .regularExpression) {
            let key = trimmed[range].replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            return key
        }

        return nil
    }

    /// Searches for a matching line within a limited lookahead window
    private static func findMatchingLine(target: String, in lines: [String], maxLookAhead: Int) -> (found: Bool, offset: Int) {
        let searchRange = min(maxLookAhead, lines.count)
        for i in 0..<searchRange {
            if lines[i].trimmingCharacters(in: .whitespaces) == target {
                return (true, i)
            }
        }
        return (false, -1)
    }

    // MARK: - Collapsed Sections

    private static func createCollapsedSections(from diffLines: [DiffLine]) -> [CollapsedSection] {
        var sections: [CollapsedSection] = []
        var matchStart: Int?

        for (index, line) in diffLines.enumerated() {
            if line.isMatch {
                if matchStart == nil {
                    matchStart = index
                }
            } else {
                // Hit a difference - close any open match section
                if let start = matchStart {
                    let lineCount = index - start
                    if lineCount >= 3 { // Only collapse if 3+ matching lines
                        let preview = createPreview(from: diffLines, start: start, end: index - 1)
                        sections.append(CollapsedSection(
                            startLine: start,
                            endLine: index - 1,
                            lineCount: lineCount,
                            preview: preview
                        ))
                    }
                    matchStart = nil
                }
            }
        }

        // Handle final match section
        if let start = matchStart {
            let lineCount = diffLines.count - start
            if lineCount >= 3 {
                let preview = createPreview(from: diffLines, start: start, end: diffLines.count - 1)
                sections.append(CollapsedSection(
                    startLine: start,
                    endLine: diffLines.count - 1,
                    lineCount: lineCount,
                    preview: preview
                ))
            }
        }

        return sections
    }

    private static func createPreview(from diffLines: [DiffLine], start: Int, end: Int) -> String {
        // Show first 2 lines of the collapsed section as preview
        let previewLines = diffLines[start...min(start + 1, end)]
            .compactMap { $0.originalContent }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        let truncated = previewLines.prefix(60)
        return truncated.count < previewLines.count ? String(truncated) + "..." : String(truncated)
    }
}
