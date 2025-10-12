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
    private let maximumZoomScale: CGFloat = 3.0
    private let minimumZoomScale: CGFloat = 0.0001
    private let searchFocusZoom: CGFloat = 1.2
    private let canvasInnerPadding: CGFloat = 60
    private let canvasOuterPadding: CGFloat = 28
    private let contentSpacing: CGFloat = 12
    private var canvasContentInset: CGFloat { canvasInnerPadding + canvasOuterPadding }
    private var canvasSize: CGSize {
        CGSize(width: layout.size.width + canvasContentInset * 2,
               height: layout.size.height + canvasContentInset * 2)
    }

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

            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.08, blue: 0.16),
                        Color(red: 0.03, green: 0.03, blue: 0.09)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                JSONTreeCanvas(
                    root: root,
                    layout: layout,
                    highlightedNodes: highlighted,
                    contentInset: canvasContentInset
                )
                .padding(canvasInnerPadding)
                .background(
                    RoundedRectangle(cornerRadius: 32)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.08, green: 0.09, blue: 0.18),
                                    Color(red: 0.04, green: 0.05, blue: 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 32)
                                .stroke(Theme.purple.opacity(0.18), lineWidth: 1.1)
                        )
                        .shadow(color: Theme.purple.opacity(0.25), radius: 22, x: 0, y: 18)
                )
                .padding(canvasOuterPadding)
                .scaleEffect(zoomScale, anchor: .topLeading)
                .offset(x: contentOffset.width, y: contentOffset.height)
                .animation(nil, value: zoomScale)
                .animation(nil, value: contentOffset)

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

                searchControls
                    .padding(.top, 18)
                    .padding(.leading, 18)
                    .padding(.trailing, 18)
                    .allowsHitTesting(true)

                // Minimap overlay - temporarily disabled due to performance issues
                // minimap(viewport: viewport)
                //     .padding(.trailing, 18)
                //     .padding(.top, 18)
                //     .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                //     .allowsHitTesting(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
            )
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
        if let root = treeRoot,
           layout.size.width > 0,
           layout.size.height > 0,
           (canvasSize.width > viewport.width * 1.5 || canvasSize.height > viewport.height * 1.5) {

            let minimapWidth: CGFloat = 120
            let minimapHeight: CGFloat = min(viewport.height * 0.7, 400)
            let minimapScale = min(minimapWidth / canvasSize.width, minimapHeight / canvasSize.height)

        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Minimap content - simplified rendering
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: canvasSize.width * minimapScale, height: canvasSize.height * minimapScale)

                // Viewport indicator rectangle
                if viewport.width > 0, viewport.height > 0 {
                    let visibleRect = calculateVisibleRect(viewport: viewport, minimapScale: minimapScale)
                    Rectangle()
                        .stroke(Theme.purple, lineWidth: 2)
                        .fill(Theme.purple.opacity(0.15))
                        .frame(width: visibleRect.width, height: visibleRect.height)
                        .offset(x: visibleRect.minX, y: visibleRect.minY)
                }
            }
            .frame(width: minimapWidth, height: minimapHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.purple.opacity(0.3), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleMinimapDrag(at: value.location, minimapScale: minimapScale, viewport: viewport)
                    }
            )
        }
        }
    }

    private func calculateVisibleRect(viewport: CGSize, minimapScale: CGFloat) -> CGRect {
        let scaledCanvasWidth = canvasSize.width * zoomScale
        let scaledCanvasHeight = canvasSize.height * zoomScale

        // Calculate what portion of the canvas is visible in the viewport
        let visibleX = -contentOffset.width / zoomScale
        let visibleY = -contentOffset.height / zoomScale
        let visibleWidth = viewport.width / zoomScale
        let visibleHeight = viewport.height / zoomScale

        // Scale these coordinates to minimap space
        return CGRect(
            x: visibleX * minimapScale,
            y: visibleY * minimapScale,
            width: visibleWidth * minimapScale,
            height: visibleHeight * minimapScale
        )
    }

    private func handleMinimapDrag(at location: CGPoint, minimapScale: CGFloat, viewport: CGSize) {
        // Convert minimap coordinates to canvas coordinates
        let canvasX = location.x / minimapScale
        let canvasY = location.y / minimapScale

        // Center the viewport on this point
        let newOffsetX = -(canvasX * zoomScale) + viewport.width / 2
        let newOffsetY = -(canvasY * zoomScale) + viewport.height / 2

        shouldCenterTree = false
        contentOffset = CGSize(width: newOffsetX, height: newOffsetY)
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
        contentOffset = CGSize(
            width: panStartOffset.width + translation.width,
            height: panStartOffset.height + translation.height
        )
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
        let targetOffset = centeredOffset(for: zoomScale)
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

        let targetOffset: CGSize
        if let contentPoint = focusContentPoint, let screenPoint = focusScreenPoint {
            targetOffset = CGSize(
                width: screenPoint.x - contentPoint.x * clamped,
                height: screenPoint.y - contentPoint.y * clamped
            )
        } else {
            targetOffset = centeredOffset(for: clamped)
        }

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
        let safeScale = max(zoomScale, minimumZoomScale)
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
        let upperBounded = min(value, maximumZoomScale)
        return max(upperBounded, minimumZoomScale)
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

    private static func buildNode(name: String, value: Any) -> JSONTreeGraphNode {
        switch value {
        case let dict as [String: Any]:
            let children = dict.keys.sorted().map { key in
                buildNode(name: key, value: dict[key] ?? NSNull())
            }
            return JSONTreeGraphNode(name: name, kind: .object(children))
        case let array as [Any]:
            let children = array.enumerated().map { index, item in
                buildNode(name: "[\(index)]", value: item)
            }
            return JSONTreeGraphNode(name: name, kind: .array(children))
        default:
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
    let root: JSONTreeGraphNode
    let layout: JSONTreeLayout
    let highlightedNodes: Set<UUID>
    let contentInset: CGFloat

    var body: some View {
        let size = layout.size
        Canvas { context, _ in
            drawConnections(context: &context)
            drawNodes(context: &context)
        }
        .frame(width: size.width + contentInset * 2,
               height: size.height + contentInset * 2)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.11, blue: 0.23),
                    Color(red: 0.06, green: 0.07, blue: 0.17)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
        )
    }

    private func drawConnections(context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: Theme.aqua.opacity(0.25), radius: 12, x: 0, y: 6))
            for positioned in layout.positionedNodes {
                guard !positioned.node.children.isEmpty else { continue }
                let startPoint = positioned.position
                for child in positioned.node.children {
                    guard let childPoint = layout.position(for: child.id) else { continue }
                    var path = Path()
                    let start = CGPoint(x: startPoint.x + contentInset,
                                        y: startPoint.y + contentInset)
                    path.move(to: start)

                    let distanceX = max(childPoint.x - startPoint.x, 160)
                    let controlOffset = distanceX * 0.45
                    let verticalDelta = childPoint.y - startPoint.y
                    let end = CGPoint(x: childPoint.x + contentInset,
                                      y: childPoint.y + contentInset)
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

    private func drawNodes(context: inout GraphicsContext) {
        for positioned in layout.positionedNodes {
            let point = CGPoint(x: positioned.position.x + contentInset,
                                y: positioned.position.y + contentInset)
            let node = positioned.node

            let isHighlighted = highlightedNodes.contains(node.id)
            let radius: CGFloat = isHighlighted ? 8 : 7
            let circleRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

            context.drawLayer { layer in
                let gradient = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: isHighlighted ? [Theme.gold, Theme.gold.opacity(0.25)] : [Theme.aquaLt, Theme.aqua.opacity(0.35)]),
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

                // For strings, render quotes separately in white for light mode
                if case .string(let stringValue) = node.kind, isLightMode {
                    let valuePoint = CGPoint(x: point.x + 22, y: point.y + 14)

                    // Opening quote in white
                    var openQuote = AttributedString("\"")
                    openQuote.font = .system(size: 12, weight: .regular, design: .monospaced)
                    openQuote.foregroundColor = .white
                    context.draw(Text(openQuote), at: valuePoint, anchor: .leading)

                    // String content in color
                    var stringText = AttributedString(stringValue)
                    stringText.font = .system(size: 12, weight: .regular, design: .monospaced)
                    stringText.foregroundColor = baseColor.opacity(valueOpacity)
                    let stringPoint = CGPoint(x: valuePoint.x + 7, y: valuePoint.y)
                    context.draw(Text(stringText), at: stringPoint, anchor: .leading)

                    // Closing quote in white
                    var closeQuote = AttributedString("\"")
                    closeQuote.font = .system(size: 12, weight: .regular, design: .monospaced)
                    closeQuote.foregroundColor = .white
                    let quoteOffset = CGFloat(stringValue.count * 7 + 7)
                    let closePoint = CGPoint(x: valuePoint.x + quoteOffset, y: valuePoint.y)
                    context.draw(Text(closeQuote), at: closePoint, anchor: .leading)
                } else {
                    // For non-strings or dark mode, render as before
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
