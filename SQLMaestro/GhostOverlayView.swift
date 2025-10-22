//
//  GhostOverlayView.swift
//  SQLMaestro
//
//  Ghost overlay comparison modal UI
//

import SwiftUI

struct GhostOverlayView: View {
    // File selection
    let availableFiles: [SessionSavedFile]
    @Binding var originalFile: SessionSavedFile?
    @Binding var ghostFile: SessionSavedFile?

    // Comparison state
    @State private var diffResult: DiffResult?
    @State private var currentDiffIndex: Int = 0

    // UI state
    @State private var expandedSections: Set<UUID> = []

    // Callbacks
    let onClose: () -> Void
    let onJumpToLine: (SessionSavedFile, Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // File selection
            fileSelectionView
                .padding()

            Divider()

            // Comparison view or empty state
            if let result = diffResult {
                comparisonView(result: result)
            } else {
                emptyStateView
            }

            Divider()

            // Footer with legend and close button
            footerView
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            print("🔍 GhostOverlayView.onAppear - originalFile: \(originalFile?.displayName ?? "nil"), ghostFile: \(ghostFile?.displayName ?? "nil")")
            updateComparison()
        }
        .onChange(of: originalFile) { _, _ in
            print("🔍 GhostOverlayView.onChange(originalFile) triggered")
            updateComparison()
        }
        .onChange(of: ghostFile) { _, _ in
            print("🔍 GhostOverlayView.onChange(ghostFile) triggered")
            updateComparison()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Ghost Overlay Comparison")
                .font(.headline)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - File Selection

    private var fileSelectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Original:")
                    .frame(width: 80, alignment: .leading)

                Picker("Original File", selection: $originalFile) {
                    Text("Select file...").tag(nil as SessionSavedFile?)
                    ForEach(availableFiles) { file in
                        Text(file.displayName).tag(file as SessionSavedFile?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
            }

            HStack {
                Text("Ghost:")
                    .frame(width: 80, alignment: .leading)

                Picker("Ghost File", selection: $ghostFile) {
                    Text("Select file...").tag(nil as SessionSavedFile?)
                    ForEach(availableFiles.filter { $0.id != originalFile?.id }) { file in
                        Text(file.displayName).tag(file as SessionSavedFile?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
            }

            // Difference counter and navigation
            if let result = diffResult, result.differenceCount > 0 {
                HStack(spacing: 16) {
                    Text("\(result.differenceCount) difference\(result.differenceCount == 1 ? "" : "s") found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: previousDifference) {
                        Label("Prev", systemImage: "chevron.left")
                    }
                    .disabled(result.differenceCount == 0)

                    Text("\(currentDiffIndex + 1) / \(result.differenceCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button(action: nextDifference) {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .disabled(result.differenceCount == 0)
                }
            }
        }
    }

    // MARK: - Comparison View

    private func comparisonView(result: DiffResult) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(result.diffLines.enumerated()), id: \.element.id) { index, line in
                        // Check if this line is in a collapsed section
                        if let section = result.collapsedSections.first(where: {
                            $0.startLine <= index && $0.endLine >= index
                        }) {
                            // Only show the section header once (at start)
                            if index == section.startLine {
                                collapsedSectionView(section: section)
                                    .id("section-\(section.id)")
                            }

                            // Show lines if expanded
                            if expandedSections.contains(section.id) {
                                diffLineView(line: line, index: index)
                                    .id("line-\(line.id)")
                            }
                        } else {
                            // Not in a collapsed section, always show
                            diffLineView(line: line, index: index)
                                .id("line-\(line.id)")
                        }
                    }
                }
                .padding()
            }
            .onChange(of: currentDiffIndex) { _, newIndex in
                // Scroll to current difference
                if let result = diffResult, !result.differenceIndices.isEmpty {
                    let lineIndex = result.differenceIndices[newIndex]
                    let line = result.diffLines[lineIndex]
                    withAnimation {
                        proxy.scrollTo("line-\(line.id)", anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Diff Line View

    private func diffLineView(line: DiffLine, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // For matches, show only one line
            if line.type == .match {
                singleLineView(
                    lineNumber: line.originalLineNumber,
                    content: line.originalContent ?? "",
                    label: nil,
                    color: .clear
                )
            }
            // For modifications, show both original and ghost stacked
            else if line.type == .modified {
                singleLineView(
                    lineNumber: line.originalLineNumber,
                    content: line.originalContent ?? "",
                    label: "Original",
                    color: Color.red.opacity(0.25)
                )
                singleLineView(
                    lineNumber: line.ghostLineNumber,
                    content: line.ghostContent ?? "",
                    label: "Ghost",
                    color: Color.green.opacity(0.25)
                )
                .padding(.top, 1)
            }
            // For lines only in original (deleted in ghost)
            else if line.type == .onlyInOriginal {
                singleLineView(
                    lineNumber: line.originalLineNumber,
                    content: line.originalContent ?? "",
                    label: "Original",
                    color: Color.red.opacity(0.25)
                )
            }
            // For lines only in ghost (added in ghost)
            else if line.type == .onlyInGhost {
                singleLineView(
                    lineNumber: line.ghostLineNumber,
                    content: line.ghostContent ?? "",
                    label: "Ghost",
                    color: Color.green.opacity(0.25)
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleLineTap(line: line)
        }
    }

    private func singleLineView(lineNumber: Int?, content: String, label: String?, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Line number
            if let lineNum = lineNumber {
                Text("\(lineNum + 1)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Text("")
                    .frame(width: 40)
            }

            // Marker
            Rectangle()
                .fill(color == .clear ? .clear : (label == "Original" ? Color.red : Color.green))
                .frame(width: 4)

            // Label (Original/Ghost) if present
            if let label = label {
                Text(label)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)
            }

            // Content
            Text(content)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(color)
    }

    // MARK: - Collapsed Section View

    private func collapsedSectionView(section: CollapsedSection) -> some View {
        Button(action: { toggleSection(section) }) {
            HStack {
                Image(systemName: expandedSections.contains(section.id) ? "chevron.down" : "chevron.right")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.displayText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if !section.preview.isEmpty {
                        Text(section.preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Select files to compare")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Choose an original file and a ghost file to see their differences")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Legend
            HStack(spacing: 24) {
                Text("Legend:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: 12, height: 12)
                    Text("In Original Only")
                        .font(.caption)
                }

                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 12, height: 12)
                    Text("In Ghost / Modified")
                        .font(.caption)
                }
            }

            Spacer()

            Button("Close", action: onClose)
        }
        .padding()
    }

    // MARK: - Helper Functions

    private func updateComparison() {
        print("🔍 GhostOverlayView.updateComparison called - originalFile: \(originalFile?.displayName ?? "nil"), ghostFile: \(ghostFile?.displayName ?? "nil")")

        guard let orig = originalFile, let ghost = ghostFile else {
            print("🔍 GhostOverlayView.updateComparison - Missing files, clearing diffResult")
            diffResult = nil
            return
        }

        print("🔍 GhostOverlayView.updateComparison - Comparing \(orig.displayName) vs \(ghost.displayName)")
        let result = GhostOverlayDiffEngine.compare(original: orig.content, ghost: ghost.content)
        print("🔍 GhostOverlayView.updateComparison - Found \(result.differenceCount) differences")
        diffResult = result
        currentDiffIndex = 0

        // Expand all sections by default (we can change this to collapsed if preferred)
        expandedSections = Set(result.collapsedSections.map { $0.id })
    }

    private func toggleSection(_ section: CollapsedSection) {
        if expandedSections.contains(section.id) {
            expandedSections.remove(section.id)
        } else {
            expandedSections.insert(section.id)
        }
    }

    private func previousDifference() {
        guard let result = diffResult, !result.differenceIndices.isEmpty else { return }
        currentDiffIndex = (currentDiffIndex - 1 + result.differenceCount) % result.differenceCount
    }

    private func nextDifference() {
        guard let result = diffResult, !result.differenceIndices.isEmpty else { return }
        currentDiffIndex = (currentDiffIndex + 1) % result.differenceCount
    }

    private func handleLineTap(line: DiffLine) {
        // Jump to this line in the ghost file editor
        guard let ghost = ghostFile, let lineNum = line.ghostLineNumber else { return }
        onJumpToLine(ghost, lineNum)
        onClose() // Close the comparison view
    }
}
