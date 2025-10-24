import SwiftUI
import Foundation
import AppKit
import Yams

struct JSONTreePreview: View {
    let fileName: String
    let content: String
    let format: SavedFileFormat

    @State private var treeRoot: JSONTreeGraphNode?
    @State private var parseError: Error?
    @State private var layout = JSONTreeLayout()
    @State private var zoomScale: CGFloat = 1.0
    @State private var viewportSize: CGSize = .zero
    @State private var contentOffset: CGSize = .zero
    @State private var searchQuery: String = ""
    @State private var searchMatches: [UUID] = []
    @State private var currentMatchIndex: Int = 0
    @State private var highlightedNodeID: UUID?
    @State private var lastSubmittedQuery: String = ""
    @State private var shouldCenterTree: Bool = true
    @State private var panStartOffset: CGSize = .zero
    @State private var minimapNeedsUpdate: Bool = false
    @State private var lastMinimapUpdate: Date = .distantPast
    // Dynamic zoom limits based on viewport and canvas size
    private var dynamicMinimumZoomScale: CGFloat {
        guard viewportSize.width > 0, viewportSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else {
            return 0.05 // absolute floor for edge cases
        }

        // Calculate zoom where entire structure fits in viewport
        let zoomToFitWidth = viewportSize.width / canvasSize.width
        let zoomToFitHeight = viewportSize.height / canvasSize.height

        let fitZoom = min(zoomToFitWidth, zoomToFitHeight)

        // Apply 0.95 multiplier to add slight padding around edges
        return max(fitZoom * 0.95, 0.05)
    }

    private var dynamicMaximumZoomScale: CGFloat {
        guard viewportSize.width > 0, canvasSize.width > 0 else {
            return 6.0 // fallback
        }

        // Maximum zoom shows only 1.5% of structure width in viewport (deeper zoom for readability)
        let viewportCoveragePercent: CGFloat = 0.015
        let maxZoomByViewport = viewportSize.width / (canvasSize.width * viewportCoveragePercent)

        // Cap practical maximum zoom to avoid extreme values on tiny files
        let practicalCap: CGFloat = 12.0
        let unclamped = max(maxZoomByViewport, dynamicMinimumZoomScale)
        return min(unclamped, practicalCap)
    }
    private let searchFocusZoom: CGFloat = 1.2
    private let contentSpacing: CGFloat = 12

    // Dynamic padding based on layout size to avoid hitting Metal limits on large files
    private var canvasInnerPadding: CGFloat {
        let layoutHeight = layout.size.height
        if layoutHeight > 20000 {
            return 20  // Minimal padding for very large files
        } else if layoutHeight > 10000 {
            return 40  // Reduced padding for large files
        } else {
            return 60  // Full padding for normal files
        }
    }

    private var canvasOuterPadding: CGFloat {
        let layoutHeight = layout.size.height
        if layoutHeight > 20000 {
            return 10  // Minimal padding for very large files
        } else if layoutHeight > 10000 {
            return 20  // Reduced padding for large files
        } else {
            return 28  // Full padding for normal files
        }
    }

    private var canvasContentInset: CGFloat { canvasInnerPadding + canvasOuterPadding }
    private var canvasSize: CGSize {
        CGSize(width: layout.size.width + canvasContentInset * 2,
               height: layout.size.height + canvasContentInset * 2)
    }
    private var canvasBounds: CGRect {
        CGRect(origin: .zero, size: canvasSize)
    }

    private func visibleCanvasRect(for viewport: CGSize, zoomScale: CGFloat) -> CGRect {
        guard viewport.width > 0, viewport.height > 0, zoomScale > 0 else {
            return .zero
        }

        var rect = CGRect(
            x: -contentOffset.width / zoomScale,
            y: -contentOffset.height / zoomScale,
            width: viewport.width / zoomScale,
            height: viewport.height / zoomScale
        )

        rect = rect.intersection(canvasBounds)
        if rect.isNull {
            return .zero
        }
        return rect
    }

    private func bufferedVisibleRect(for rect: CGRect,
                                     multiplier: CGFloat = 1.5,
                                     minimumHorizontalBuffer: CGFloat = 800,
                                     minimumVerticalBuffer: CGFloat = 600) -> CGRect {
        guard !rect.isEmpty else { return rect }

        let horizontalExpansion = max(rect.width * (multiplier - 1), minimumHorizontalBuffer)
        let verticalExpansion = max(rect.height * (multiplier - 1), minimumVerticalBuffer)

        var buffered = rect.insetBy(dx: -horizontalExpansion / 2, dy: -verticalExpansion / 2)
        buffered = buffered.intersection(canvasBounds)
        if buffered.isNull {
            return rect
        }
        return buffered
    }

    private var effectiveZoomScale: CGFloat { zoomScale }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            headerView

            if let error = parseError {
                errorView(error)
            } else if let root = treeRoot {
                treeView(for: root)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
        .background(Theme.grayBG.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            parseContent()
        }
        .onChange(of: content) { _ in
            parseContent()
        }
        .onChange(of: searchQuery) { _ in
            lastSubmittedQuery = ""
            refreshMatches(resetIndex: true)
        }
        .onChange(of: highlightedNodeID) { _ in
            focusOnHighlightedNode(animated: true)
        }
    }

    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(fileName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.purple)
            Spacer()
            Text("\(Int(zoomScale * 100))%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                TextField("Search keys or values", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .onSubmit {
                    handleSearchSubmit()
                }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Theme.grayBG.opacity(0.35))
            )
            .overlay(
                Capsule().stroke(Theme.purple.opacity(0.3), lineWidth: 1)
            )
            .frame(maxWidth: 280)

            Button {
                advanceMatch(step: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(searchMatches.isEmpty)

            Button {
                advanceMatch(step: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Theme.purple)
            .disabled(searchMatches.isEmpty)

            if !searchMatches.isEmpty {
                Text("\(currentMatchIndex + 1) / \(searchMatches.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if !searchQuery.isEmpty {
                Text("No matches")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private func treeView(for root: JSONTreeGraphNode) -> some View {
        let highlighted = highlightedNodeID.map { Set([$0]) } ?? []

        GeometryReader { proxy in
            let viewport = proxy.size
            let renderingZoom = max(effectiveZoomScale, dynamicMinimumZoomScale)
            let visibleRect = visibleCanvasRect(for: viewport, zoomScale: renderingZoom)
            let bufferedRect = bufferedVisibleRect(for: visibleRect)

            ZStack(alignment: .topLeading) {
                // Main canvas area
                ZStack(alignment: .topLeading) {
                    JSONTreeCanvas(
                        layout: layout,
                        highlightedNodes: highlighted,
                        contentInset: canvasContentInset,
                        zoomScale: renderingZoom,
                        contentOffset: contentOffset,
                        viewportSize: viewport,
                        canvasSize: canvasSize,
                        bufferedVisibleRect: bufferedRect
                    )
                    .frame(width: viewport.width, height: viewport.height)
                    .clipped()

                    ZoomEventCatcher(
                        topHitTestInset: 0,
                        onCommandScroll: { payload in
                            handleCommandScroll(deltaY: payload.deltaY,
                                                precise: payload.precise,
                                                inverted: payload.inverted,
                                                location: payload.location)
                        },
                        onMagnify: { payload in
                            handleMagnification(delta: payload.delta, location: payload.location)
                        },
                        onPanBegan: { location in
                            handlePanBegan(at: location)
                        },
                        onPanChanged: { translation in
                            handlePanChanged(translation: translation)
                        },
                        onPanEnded: {
                            handlePanEnded()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(true)
                    .accessibilityHidden(true)

                    // Search controls overlay (inside clipped area)
                    searchControls
                        .padding(.top, 18)
                        .padding(.leading, 18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
                )

                // Minimap overlay - OUTSIDE clipped area, at top-right
                minimap(viewport: viewport)
            }
            .onAppear {
                handleViewportChange(viewport)
            }
            .onChange(of: viewport) { newValue in
                handleViewportChange(newValue)
            }
        }
    }

    private func errorView(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unable to parse \(format.rawValue.uppercased())")
                .font(.headline)
                .foregroundStyle(.red)
            Text(error.localizedDescription)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        }
    }

    @ViewBuilder
    private func minimap(viewport: CGSize) -> some View {
        // Only show minimap if tree exists and is large enough to benefit from it
        // Also check that zoom scale is reasonable
        if let root = treeRoot,
           layout.size.width > 0,
           layout.size.height > 0,
           zoomScale >= dynamicMinimumZoomScale,  // Show minimap at any zoom level
           (canvasSize.width > viewport.width * 1.2 || canvasSize.height > viewport.height * 1.2),  // Lowered from 1.5 to 1.2
           canvasSize.width > 1,  // Safety check: ensure canvasSize is not too small
           canvasSize.height > 1 {

            let minimapWidth: CGFloat = 120
            let maximumMinimapHeight: CGFloat = min(viewport.height * 0.7, 400)

            // Calculate scale to fit within minimap width, but also respect max height
            let scaleByWidth = minimapWidth / canvasSize.width
            let scaleByHeight = maximumMinimapHeight / canvasSize.height
            let minimapScale = min(scaleByWidth, scaleByHeight)

            // Clamp minimap scale to reasonable values
            let clampedScale = max(min(minimapScale, 1.0), 0.01)

            // Calculate actual minimap content size
            let contentWidth = canvasSize.width * clampedScale
            let contentHeight = canvasSize.height * clampedScale

        ZStack(alignment: .topLeading) {
            // Minimap content - simplified rendering
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: contentWidth, height: contentHeight)

            // Viewport indicator rectangle
            if viewport.width > 0, viewport.height > 0 {
                let visibleRect = calculateVisibleRect(viewport: viewport, minimapScale: clampedScale)
                Rectangle()
                    .stroke(Theme.purple, lineWidth: 2)
                    .fill(Theme.purple.opacity(0.15))
                    .frame(width: max(visibleRect.width, 2), height: max(visibleRect.height, 2))
                    .offset(x: visibleRect.minX, y: visibleRect.minY)
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.purple.opacity(0.5), lineWidth: 2)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    handleMinimapDrag(at: value.location, minimapScale: clampedScale, viewport: viewport)
                }
        )
        .offset(
            x: viewport.width - contentWidth - 18,
            y: 18
        )
        .allowsHitTesting(true)
        .zIndex(1000)  // Ensure minimap is above other layers
        }
    }

    private func calculateVisibleRect(viewport: CGSize, minimapScale: CGFloat) -> CGRect {
        let safeZoomScale = max(effectiveZoomScale, dynamicMinimumZoomScale)
        let rect = visibleCanvasRect(for: viewport, zoomScale: safeZoomScale)
        guard rect.width > 0, rect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 2, height: 2)
        }

        return CGRect(
            x: rect.minX * minimapScale,
            y: rect.minY * minimapScale,
            width: max(rect.width * minimapScale, 2),
            height: max(rect.height * minimapScale, 2)
        )
    }

    private func handleMinimapDrag(at location: CGPoint, minimapScale: CGFloat, viewport: CGSize) {
        // Safety check: prevent division by very small numbers
        guard minimapScale > 0.001 else {
            print("⚠️ Minimap scale too small: \(minimapScale)")
            return
        }

        print("🖱️ === MINIMAP DRAG START ===")
        print("🖱️ Click location: \(location)")
        print("🖱️ Minimap scale: \(minimapScale)")
        print("🖱️ Current zoom: \(zoomScale)")
        print("🖱️ Canvas size: \(canvasSize)")
        print("🖱️ Viewport size: \(viewport)")
        print("🖱️ Current offset: \(contentOffset)")

        // Convert minimap coordinates to canvas coordinates
        let canvasX = location.x / minimapScale
        let canvasY = location.y / minimapScale

        print("🖱️ Canvas coords (raw): x=\(canvasX), y=\(canvasY)")

        let clampedCanvasX = max(0, min(canvasX, canvasSize.width))
        let clampedCanvasY = max(0, min(canvasY, canvasSize.height))

        print("🖱️ Canvas coords (clamped): x=\(clampedCanvasX), y=\(clampedCanvasY)")

        // Center the viewport on this point (use effectiveZoomScale for consistency)
        let newOffsetX = -(clampedCanvasX * effectiveZoomScale) + viewport.width / 2
        let newOffsetY = -(clampedCanvasY * effectiveZoomScale) + viewport.height / 2

        print("🖱️ New offset: x=\(newOffsetX), y=\(newOffsetY)")

        let proposedOffset = CGSize(width: newOffsetX, height: newOffsetY)
        let clampedOffset = clampOffset(proposedOffset, forZoom: effectiveZoomScale)

        print("🖱️ Clamped offset: x=\(clampedOffset.width), y=\(clampedOffset.height)")
        print("🖱️ === MINIMAP DRAG END ===")

        shouldCenterTree = false
        contentOffset = clampedOffset
    }

    private func parseContent() {
        let result = JSONTreeParser.parse(content: content, rootName: fileName, format: format)
        switch result {
        case .success(let root):
            treeRoot = root
            parseError = nil
            layout.performLayout(root: root)
            zoomScale = 1.0
            contentOffset = .zero
            shouldCenterTree = true
            refreshMatches(resetIndex: true)
            DispatchQueue.main.async {
                if highlightedNodeID == nil {
                    alignContentToCenter(animated: false)
                } else {
                    focusOnHighlightedNode(animated: false)
                }
            }
        case .failure(let error):
            treeRoot = nil
            parseError = error
            searchMatches = []
            highlightedNodeID = nil
            currentMatchIndex = 0
            shouldCenterTree = true
        }
    }

    private func refreshMatches(resetIndex: Bool) {
        guard let root = treeRoot else {
            searchMatches = []
            highlightedNodeID = nil
            currentMatchIndex = 0
            return
        }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchMatches = []
            highlightedNodeID = nil
            currentMatchIndex = 0
            shouldCenterTree = true
            alignContentToCenter(animated: false)
            return
        }
        let matches = collectMatches(in: root, query: trimmed)
        searchMatches = matches
        guard !matches.isEmpty else {
            highlightedNodeID = nil
            currentMatchIndex = 0
            shouldCenterTree = true
            alignContentToCenter(animated: false)
            return
        }
        if resetIndex || currentMatchIndex >= matches.count {
            currentMatchIndex = 0
        }
        highlightedNodeID = matches[currentMatchIndex]
        focusOnHighlightedNode(animated: false)
    }

    private func handleSearchSubmit() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastSubmittedQuery = ""
            refreshMatches(resetIndex: true)
            return
        }
        if trimmed == lastSubmittedQuery, !searchMatches.isEmpty {
            advanceMatch(step: 1)
        } else {
            lastSubmittedQuery = trimmed
            refreshMatches(resetIndex: true)
        }
    }

    private func collectMatches(in node: JSONTreeGraphNode, query: String) -> [UUID] {
        var results: [UUID] = []
        let needle = query.lowercased()
        func walk(_ current: JSONTreeGraphNode) {
            let nameMatch = current.name.lowercased().contains(needle)
            let valueMatch = current.valueDescription?.lowercased().contains(needle) ?? false
            if nameMatch || valueMatch {
                results.append(current.id)
            }
            for child in current.children {
                walk(child)
            }
        }
        walk(node)
        return results
    }

    private func advanceMatch(step: Int) {
        guard !searchMatches.isEmpty else { return }
        var newIndex = currentMatchIndex + step
        if newIndex < 0 {
            newIndex = searchMatches.count - 1
        } else if newIndex >= searchMatches.count {
            newIndex = 0
        }
        currentMatchIndex = newIndex
        highlightedNodeID = searchMatches[newIndex]
        shouldCenterTree = false
        focusOnHighlightedNode(animated: true)
    }

    private func handleViewportChange(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        viewportSize = newSize
        if highlightedNodeID != nil {
            focusOnHighlightedNode(animated: false)
        } else if shouldCenterTree {
            alignContentToCenter(animated: false)
        }
    }

    private func handleMagnification(delta: CGFloat, location: CGPoint) {
        guard abs(delta) > 0.0001 else { return }
        let factor = 1.0 + delta
        guard abs(factor - 1.0) > 0.0001 else { return }
        let proposed = zoomScale * factor
        let contentPoint = contentPoint(at: location)
        shouldCenterTree = false
        applyZoom(to: proposed, focusContentPoint: contentPoint, focusScreenPoint: location, animated: false)
    }

    private func handleCommandScroll(deltaY: CGFloat, precise: Bool, inverted: Bool, location: CGPoint) {
        guard abs(deltaY) > 0.0001 else { return }
        let direction: CGFloat = inverted ? -1 : 1
        let multiplier: CGFloat = precise ? 0.005 : 0.025
        let delta = -(deltaY * direction) * multiplier
        let proposed = zoomScale + delta
        let contentPoint = contentPoint(at: location)
        shouldCenterTree = false
        applyZoom(to: proposed, focusContentPoint: contentPoint, focusScreenPoint: location, animated: false)
    }

    private func handlePanBegan(at _: CGPoint) {
        shouldCenterTree = false
        panStartOffset = contentOffset
    }

    private func handlePanChanged(translation: CGSize) {
        let proposedOffset = CGSize(
            width: panStartOffset.width + translation.width,
            height: panStartOffset.height + translation.height
        )
        contentOffset = clampOffset(proposedOffset, forZoom: effectiveZoomScale)
    }

    private func handlePanEnded() {
        panStartOffset = contentOffset
    }

    private func focusOnHighlightedNode(animated: Bool) {
        guard let id = highlightedNodeID,
              let layoutPoint = layout.position(for: id),
              viewportSize.width > 0 else {
            if shouldCenterTree {
                alignContentToCenter(animated: animated)
            }
            return
        }

        let contentPoint = CGPoint(
            x: layoutPoint.x + canvasContentInset,
            y: layoutPoint.y + canvasContentInset
        )
        let screenPoint = viewportCenterPoint()
        let targetScale = max(zoomScale, searchFocusZoom)
        shouldCenterTree = false
        applyZoom(to: targetScale,
                  focusContentPoint: contentPoint,
                  focusScreenPoint: screenPoint,
                  animated: animated)
    }

    private func alignContentToCenter(animated: Bool) {
        guard viewportSize.width > 0 else { return }
        let proposedOffset = centeredOffset(for: zoomScale)
        let targetOffset = clampOffset(proposedOffset, forZoom: effectiveZoomScale)
        if animated {
            withAnimation(.easeInOut(duration: 0.24)) {
                contentOffset = targetOffset
            }
        } else {
            contentOffset = targetOffset
        }
    }

    private func applyZoom(to newScale: CGFloat,
                           focusContentPoint: CGPoint?,
                           focusScreenPoint: CGPoint?,
                           animated: Bool) {
        let clamped = clampZoom(newScale)
        guard viewportSize.width > 0 else {
            zoomScale = clamped
            return
        }

        let proposedOffset: CGSize
        if let contentPoint = focusContentPoint, let screenPoint = focusScreenPoint {
            proposedOffset = CGSize(
                width: screenPoint.x - contentPoint.x * clamped,
                height: screenPoint.y - contentPoint.y * clamped
            )
        } else {
            proposedOffset = centeredOffset(for: clamped)
        }

        // Clamp offset to prevent panning beyond bounds
        let targetOffset = clampOffset(proposedOffset, forZoom: clamped)

        if animated {
            withAnimation(.easeInOut(duration: 0.24)) {
                zoomScale = clamped
                contentOffset = targetOffset
            }
        } else {
            zoomScale = clamped
            contentOffset = targetOffset
        }
    }

    private func centeredOffset(for scale: CGFloat) -> CGSize {
        let scaledWidth = canvasSize.width * scale
        let scaledHeight = canvasSize.height * scale
        let offsetX = (viewportSize.width - scaledWidth) / 2
        let offsetY = (viewportSize.height - scaledHeight) / 2
        return CGSize(width: offsetX, height: offsetY)
    }

    private func contentPoint(at screenPoint: CGPoint) -> CGPoint {
        guard viewportSize.width > 0 else {
            return CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        }
        // Use effectiveZoomScale for consistency with actual rendering
        let safeScale = max(effectiveZoomScale, dynamicMinimumZoomScale)
        let rawX = (screenPoint.x - contentOffset.width) / safeScale
        let rawY = (screenPoint.y - contentOffset.height) / safeScale
        let x = min(max(rawX, 0), canvasSize.width)
        let y = min(max(rawY, 0), canvasSize.height)
        return CGPoint(x: x, y: y)
    }

    private func viewportCenterPoint() -> CGPoint? {
        guard viewportSize.width > 0 else { return nil }
        return CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        let upperBounded = min(value, dynamicMaximumZoomScale)
        return max(upperBounded, dynamicMinimumZoomScale)
    }

    private func clampOffset(_ offset: CGSize, forZoom scale: CGFloat) -> CGSize {
        let scaledWidth = canvasSize.width * scale
        let scaledHeight = canvasSize.height * scale

        var clampedX = offset.width
        var clampedY = offset.height

        // If content is smaller than viewport, keep it centered
        if scaledWidth <= viewportSize.width {
            clampedX = (viewportSize.width - scaledWidth) / 2
        } else {
            // Content is larger - prevent panning beyond edges
            // Max offset is 0 (content's left edge at viewport's left edge)
            // Min offset is viewport.width - scaledWidth (content's right edge at viewport's right edge)
            let minX = viewportSize.width - scaledWidth
            let maxX: CGFloat = 0
            clampedX = min(max(offset.width, minX), maxX)
        }

        if scaledHeight <= viewportSize.height {
            clampedY = (viewportSize.height - scaledHeight) / 2
        } else {
            let minY = viewportSize.height - scaledHeight
            let maxY: CGFloat = 0
            clampedY = min(max(offset.height, minY), maxY)
        }

        return CGSize(width: clampedX, height: clampedY)
    }
}



private enum JSONTreeParser {
    static func parse(content: String, rootName: String, format: SavedFileFormat = .json) -> Result<JSONTreeGraphNode, Error> {
        guard let data = content.data(using: .utf8) else {
            return .failure(NSError(domain: "JSONTree", code: 1, userInfo: [NSLocalizedDescriptionKey: "Content is not UTF-8 encodable"]))
        }

        let parsedObject: Any
        do {
            switch format {
            case .json:
                parsedObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            case .yaml:
                parsedObject = try Yams.load(yaml: content) ?? NSNull()
            }

            let node = buildNode(name: rootName.isEmpty ? "ROOT" : rootName, value: parsedObject)
            return .success(node)
        } catch {
            return .failure(error)
        }
    }

    /// Extracts a meaningful display name for an array item
    /// Shows dash prefix and identifier from the dictionary if available
    /// Returns the identifier key that was used, so it can be excluded from children
    private static func extractArrayItemName(item: Any, index: Int) -> (displayName: String, usedKey: String?) {
        // For dictionaries/objects in arrays, try to show a meaningful identifier
        if let dict = item as? [String: Any], !dict.isEmpty {
            // Prioritize common identifier keys
            let priorityKeys = ["name", "id", "key", "title", "label", "type"]

            // First, check if any priority key exists
            for priorityKey in priorityKeys {
                if let value = dict[priorityKey] {
                    let valueStr = formatValueForDisplay(value)
                    return ("- \(priorityKey): \(valueStr)", priorityKey)
                }
            }

            // No identifier found, just show index
            return ("- [\(index)]", nil)
        }

        // For primitive values in arrays, show them directly with dash prefix and index
        if let string = item as? String {
            return ("- [\(index)] \"\(string)\"", nil)
        }
        if let number = item as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return ("- [\(index)] \(number.boolValue ? "true" : "false")", nil)
            }
            return ("- [\(index)] \(number.stringValue)", nil)
        }
        if item is NSNull {
            return ("- [\(index)] null", nil)
        }

        // Fallback to index notation only (for nested arrays, etc.)
        return ("- [\(index)]", nil)
    }

    /// Formats a value for compact display in the array item name
    private static func formatValueForDisplay(_ value: Any) -> String {
        if let string = value as? String {
            // For strings, show them in quotes but truncate if too long
            let maxLength = 30
            if string.count > maxLength {
                return "\"\(string.prefix(maxLength))...\""
            }
            return "\"\(string)\""
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if value is NSNull {
            return "null"
        }
        if value is [String: Any] {
            return "{...}"
        }
        if value is [Any] {
            return "[...]"
        }
        return String(describing: value)
    }

    private static func buildNode(name: String, value: Any, isArrayItem: Bool = false, excludeKey: String? = nil) -> JSONTreeGraphNode {
        switch value {
        case let dict as [String: Any]:
            // Filter out the key that was used in the array item name
            let keysToShow = dict.keys.filter { $0 != excludeKey }.sorted()
            let children = keysToShow.map { key in
                buildNode(name: key, value: dict[key] ?? NSNull())
            }
            return JSONTreeGraphNode(name: name, kind: .object(children))
        case let array as [Any]:
            let children = array.enumerated().map { index, item in
                let (displayName, usedKey) = extractArrayItemName(item: item, index: index)
                return buildNode(name: displayName, value: item, isArrayItem: true, excludeKey: usedKey)
            }
            return JSONTreeGraphNode(name: name, kind: .array(children))
        default:
            // For primitive values that are direct array items, don't duplicate the value
            // since it's already included in the display name
            if isArrayItem {
                // Check if this is a primitive value (not an object or array)
                let isPrimitive = !(value is [String: Any]) && !(value is [Any])
                if isPrimitive {
                    // Return a node without a value description to avoid duplication
                    return JSONTreeGraphNode(name: name, kind: .object([]))
                }
            }

            if value is NSNull {
                return JSONTreeGraphNode(name: name, kind: .null)
            }
            if let string = value as? String {
                return JSONTreeGraphNode(name: name, kind: .string(string))
            }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return JSONTreeGraphNode(name: name, kind: .bool(number.boolValue))
                }
                return JSONTreeGraphNode(name: name, kind: .number(number.stringValue))
            }
            return JSONTreeGraphNode(name: name, kind: .string(String(describing: value)))
        }
    }
}

private struct JSONTreeGraphNode: Identifiable {
    enum Kind {
        case object([JSONTreeGraphNode])
        case array([JSONTreeGraphNode])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    let id = UUID()
    let name: String
    let kind: Kind

    var children: [JSONTreeGraphNode] {
        switch kind {
        case .object(let children): return children
        case .array(let children): return children
        default: return []
        }
    }

    var valueDescription: String? {
        switch kind {
        case .object, .array: return nil
        case .string(let value): return "\"\(value)\""
        case .number(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    var valueColor: Color {
        switch kind {
        case .string: return Theme.accent
        case .number: return Theme.gold
        case .bool: return Theme.pink
        case .null: return .secondary
        case .object, .array: return Theme.purple
        }
    }
}

private struct ZoomEventCatcher: NSViewRepresentable {
    struct ScrollPayload {
        let deltaY: CGFloat
        let precise: Bool
        let inverted: Bool
        let location: CGPoint
    }

    struct MagnifyPayload {
        let delta: CGFloat
        let location: CGPoint
    }

    let topHitTestInset: CGFloat
    let onCommandScroll: (ScrollPayload) -> Void
    let onMagnify: (MagnifyPayload) -> Void
    let onPanBegan: (CGPoint) -> Void
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: () -> Void

    func makeNSView(context: Context) -> ZoomEventView {
        let view = ZoomEventView()
        view.topHitTestInset = topHitTestInset
        view.onCommandScroll = onCommandScroll
        view.onMagnify = onMagnify
        view.onPanBegan = onPanBegan
        view.onPanChanged = onPanChanged
        view.onPanEnded = onPanEnded
        return view
    }

    func updateNSView(_ nsView: ZoomEventView, context: Context) {
        nsView.topHitTestInset = topHitTestInset
        nsView.onCommandScroll = onCommandScroll
        nsView.onMagnify = onMagnify
        nsView.onPanBegan = onPanBegan
        nsView.onPanChanged = onPanChanged
        nsView.onPanEnded = onPanEnded
    }

    final class ZoomEventView: NSView {
        var topHitTestInset: CGFloat = 0
        var onCommandScroll: ((ScrollPayload) -> Void)?
        var onMagnify: ((MagnifyPayload) -> Void)?
        var onPanBegan: ((CGPoint) -> Void)?
        var onPanChanged: ((CGSize) -> Void)?
        var onPanEnded: (() -> Void)?
        private var panStartPoint: CGPoint?

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local: NSPoint
            if let superview = superview {
                local = convert(point, from: superview)
            } else {
                local = point
            }

            guard bounds.contains(local) else { return nil }
            let effectiveInset = min(max(0, topHitTestInset), bounds.height)
            if effectiveInset > 0, local.y < effectiveInset {
                return nil
            }
            return self
        }

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.command) {
                let location = convert(event.locationInWindow, from: nil)
                let payload = ScrollPayload(
                    deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas,
                    inverted: event.isDirectionInvertedFromDevice,
                    location: location
                )
                onCommandScroll?(payload)
            } else {
                super.scrollWheel(with: event)
            }
        }

        override func magnify(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            let payload = MagnifyPayload(delta: event.magnification, location: location)
            onMagnify?(payload)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.type == .leftMouseDown else {
                super.mouseDown(with: event)
                return
            }
            window?.makeFirstResponder(self)
            let location = convert(event.locationInWindow, from: nil)
            panStartPoint = location
            onPanBegan?(location)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = panStartPoint else {
                super.mouseDragged(with: event)
                return
            }
            let location = convert(event.locationInWindow, from: nil)
            let translation = CGSize(width: location.x - start.x,
                                     height: location.y - start.y)
            onPanChanged?(translation)
        }

        override func mouseUp(with event: NSEvent) {
            defer { panStartPoint = nil }
            guard panStartPoint != nil else {
                super.mouseUp(with: event)
                return
            }
            onPanEnded?()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}

private struct JSONTreeCanvas: View {
    let layout: JSONTreeLayout
    let highlightedNodes: Set<UUID>
    let contentInset: CGFloat
    let zoomScale: CGFloat
    let contentOffset: CGSize
    let viewportSize: CGSize
    let canvasSize: CGSize
    let bufferedVisibleRect: CGRect

    private var canvasBounds: CGRect {
        CGRect(origin: .zero, size: canvasSize)
    }

    private var effectiveBufferedRect: CGRect {
        let rect = bufferedVisibleRect.isEmpty ? canvasBounds : bufferedVisibleRect
        return rect.isNull ? canvasBounds : rect
    }

    var body: some View {
        Canvas { context, _ in
            let nodesInBuffer = filteredNodes()
            let visibleNodeIDs = Set(nodesInBuffer.map { $0.node.id })

            context.drawLayer { layer in
                layer.translateBy(x: contentOffset.width, y: contentOffset.height)
                layer.scaleBy(x: zoomScale, y: zoomScale)

                drawBackground(context: &layer)

                layer.translateBy(x: contentInset, y: contentInset)

                drawConnections(context: &layer, visibleNodeIDs: visibleNodeIDs)
                drawNodes(context: &layer, nodes: nodesInBuffer)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .drawingGroup(opaque: false, colorMode: .nonLinear)
    }

    private func filteredNodes() -> [JSONTreeLayout.PositionedNode] {
        let rect = effectiveBufferedRect
        return layout.positionedNodes.filter { positioned in
            let point = nodeCanvasPoint(for: positioned)
            return rect.contains(point)
        }
    }

    private func nodeCanvasPoint(for positioned: JSONTreeLayout.PositionedNode) -> CGPoint {
        CGPoint(
            x: positioned.position.x + contentInset,
            y: positioned.position.y + contentInset
        )
    }

    private func drawBackground(context: inout GraphicsContext) {
        let backgroundRect = canvasBounds
        let backgroundPath = Path(roundedRect: backgroundRect, cornerRadius: 32)
        let gradient = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                Color(red: 0.08, green: 0.09, blue: 0.18),
                Color(red: 0.04, green: 0.05, blue: 0.12)
            ]),
            startPoint: CGPoint(x: backgroundRect.minX, y: backgroundRect.minY),
            endPoint: CGPoint(x: backgroundRect.maxX, y: backgroundRect.maxY)
        )

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: Theme.purple.opacity(0.25), radius: 22, x: 0, y: 18))
            layer.fill(backgroundPath, with: gradient)
        }

        context.stroke(
            backgroundPath,
            with: .color(Theme.purple.opacity(0.18)),
            style: StrokeStyle(lineWidth: 1.1)
        )

        if backgroundRect.width > 8, backgroundRect.height > 8 {
            context.stroke(
                Path(roundedRect: backgroundRect.insetBy(dx: 4, dy: 4), cornerRadius: 28),
                with: .color(Color.white.opacity(0.06)),
                style: StrokeStyle(lineWidth: 0.6)
            )
        }
    }

    private func drawConnections(context: inout GraphicsContext, visibleNodeIDs: Set<UUID>) {
        let rect = effectiveBufferedRect

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: Theme.aqua.opacity(0.25), radius: 12, x: 0, y: 6))
            for positioned in layout.positionedNodes {
                guard !positioned.node.children.isEmpty else { continue }

                let startPoint = positioned.position
                let startCanvasPoint = nodeCanvasPoint(for: positioned)

                for child in positioned.node.children {
                    guard let childPoint = layout.position(for: child.id) else { continue }
                    let childCanvasPoint = CGPoint(
                        x: childPoint.x + contentInset,
                        y: childPoint.y + contentInset
                    )

                    guard shouldRenderConnection(
                        startCanvasPoint: startCanvasPoint,
                        endCanvasPoint: childCanvasPoint,
                        startID: positioned.node.id,
                        childID: child.id,
                        visibleNodeIDs: visibleNodeIDs,
                        rect: rect
                    ) else {
                        continue
                    }

                    var path = Path()
                    let start = startPoint
                    path.move(to: start)

                    let distanceX = max(childPoint.x - startPoint.x, 160)
                    let controlOffset = distanceX * 0.45
                    let verticalDelta = childPoint.y - startPoint.y
                    let end = childPoint
                    let control1 = CGPoint(
                        x: start.x + controlOffset,
                        y: start.y + verticalDelta * 0.18
                    )
                    let control2 = CGPoint(
                        x: end.x - controlOffset,
                        y: end.y - verticalDelta * 0.18
                    )
                    path.addCurve(to: end, control1: control1, control2: control2)

                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [
                            Theme.aqua.opacity(0.7),
                            Theme.gold.opacity(0.45)
                        ]),
                        startPoint: start,
                        endPoint: end
                    )
                    layer.stroke(
                        path,
                        with: shading,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    private func shouldRenderConnection(startCanvasPoint: CGPoint,
                                        endCanvasPoint: CGPoint,
                                        startID: UUID,
                                        childID: UUID,
                                        visibleNodeIDs: Set<UUID>,
                                        rect: CGRect) -> Bool {
        if visibleNodeIDs.contains(startID) || visibleNodeIDs.contains(childID) {
            return true
        }

        let connectionBounds = CGRect(
            x: min(startCanvasPoint.x, endCanvasPoint.x),
            y: min(startCanvasPoint.y, endCanvasPoint.y),
            width: abs(startCanvasPoint.x - endCanvasPoint.x),
            height: abs(startCanvasPoint.y - endCanvasPoint.y)
        ).insetBy(dx: -40, dy: -40)

        return rect.intersects(connectionBounds)
    }

    private func drawNodes(context: inout GraphicsContext, nodes: [JSONTreeLayout.PositionedNode]) {
        for positioned in nodes {
            let point = positioned.position
            let node = positioned.node

            let isHighlighted = highlightedNodes.contains(node.id)
            let radius: CGFloat = isHighlighted ? 8 : 7
            let circleRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

            context.drawLayer { layer in
                let gradient = GraphicsContext.Shading.radialGradient(
                    Gradient(
                        colors: isHighlighted
                            ? [Theme.gold, Theme.gold.opacity(0.25)]
                            : [Theme.aquaLt, Theme.aqua.opacity(0.35)]
                    ),
                    center: CGPoint(x: circleRect.midX, y: circleRect.midY),
                    startRadius: 0,
                    endRadius: radius * 1.8
                )
                layer.addFilter(.shadow(color: (isHighlighted ? Theme.gold : Theme.aqua).opacity(0.4), radius: isHighlighted ? 14 : 10, x: 0, y: 0))
                layer.fill(Path(ellipseIn: circleRect), with: gradient)
                layer.stroke(
                    Path(ellipseIn: circleRect),
                    with: .color(isHighlighted ? Theme.gold : Theme.aqua),
                    style: StrokeStyle(lineWidth: isHighlighted ? 2.2 : 1.4)
                )
            }

            var keyText = AttributedString(node.name)
            keyText.font = .system(size: 12, weight: .semibold, design: .rounded)
            keyText.foregroundColor = isHighlighted ? Theme.gold : Theme.purple

            let keyPoint = CGPoint(x: point.x + 22, y: point.y - 8)
            context.draw(Text(keyText), at: keyPoint, anchor: .leading)

            if let value = node.valueDescription {
                let isLightMode = context.environment.colorScheme == .light
                let valueOpacity: Double = isLightMode ? 1.0 : 0.9
                let baseColor = isHighlighted ? Theme.gold : node.valueColor

                if case .string(let stringValue) = node.kind, isLightMode {
                    let valuePoint = CGPoint(x: point.x + 22, y: point.y + 14)

                    var openQuote = AttributedString("\"")
                    openQuote.font = .system(size: 12, weight: .regular, design: .monospaced)
                    openQuote.foregroundColor = .white
                    context.draw(Text(openQuote), at: valuePoint, anchor: .leading)

                    var stringText = AttributedString(stringValue)
                    stringText.font = .system(size: 12, weight: .regular, design: .monospaced)
                    stringText.foregroundColor = baseColor.opacity(valueOpacity)
                    let stringPoint = CGPoint(x: valuePoint.x + 7, y: valuePoint.y)
                    context.draw(Text(stringText), at: stringPoint, anchor: .leading)

                    var closeQuote = AttributedString("\"")
                    closeQuote.font = .system(size: 12, weight: .regular, design: .monospaced)
                    closeQuote.foregroundColor = .white
                    let quoteOffset = CGFloat(stringValue.count * 7 + 7)
                    let closePoint = CGPoint(x: valuePoint.x + quoteOffset, y: valuePoint.y)
                    context.draw(Text(closeQuote), at: closePoint, anchor: .leading)
                } else {
                    var valueText = AttributedString(value)
                    valueText.font = .system(size: 12, weight: .regular, design: .monospaced)
                    valueText.foregroundColor = baseColor.opacity(valueOpacity)
                    let valuePoint = CGPoint(x: point.x + 22, y: point.y + 14)
                    context.draw(Text(valueText), at: valuePoint, anchor: .leading)
                }
            }
        }
    }
}

private final class JSONTreeLayout {
    private(set) var positionedNodes: [PositionedNode] = []
    private(set) var size: CGSize = .zero
    private var positions: [UUID: CGPoint] = [:]

    private let horizontalSpacing: CGFloat = 340
    private let verticalSpacing: CGFloat = 140
    private let padding: CGFloat = 160
    private var nextY: CGFloat = 0

    struct PositionedNode {
        let node: JSONTreeGraphNode
        let position: CGPoint
    }

    func performLayout(root: JSONTreeGraphNode) {
        positions.removeAll()
        positionedNodes.removeAll()
        nextY = padding
        let centerY = assignPosition(node: root, depth: 0)
        positions[root.id] = CGPoint(x: padding, y: centerY)
        collectNodes(root)
        let maxX = positions.values.map { $0.x }.max() ?? 0
        let maxY = positions.values.map { $0.y }.max() ?? 0
        size = CGSize(width: maxX + padding, height: maxY + padding)
    }

    func position(for id: UUID) -> CGPoint? {
        positions[id]
    }

    private func assignPosition(node: JSONTreeGraphNode, depth: Int) -> CGFloat {
        let x = padding + CGFloat(depth) * horizontalSpacing
        if node.children.isEmpty {
            let y = nextY
            nextY += verticalSpacing
            let point = CGPoint(x: x, y: y)
            positions[node.id] = point
            return y
        }

        let childCenters = node.children.map { assignPosition(node: $0, depth: depth + 1) }
        let minY = childCenters.min() ?? nextY
        let maxY = childCenters.max() ?? nextY
        let center = (minY + maxY) / 2
        let point = CGPoint(x: x, y: center)
        positions[node.id] = point
        return center
    }

    private func collectNodes(_ node: JSONTreeGraphNode) {
        if let point = positions[node.id] {
            positionedNodes.append(PositionedNode(node: node, position: point))
        }
        for child in node.children {
            collectNodes(child)
        }
    }
}
