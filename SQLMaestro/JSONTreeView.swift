import SwiftUI
import Foundation
import AppKit

struct JSONTreePreview: View {
    let fileName: String
    let content: String

    @State private var treeRoot: JSONTreeGraphNode?
    @State private var parseError: Error?
    @State private var layout = JSONTreeLayout()
    @State private var zoomScale: CGFloat = 1.0
    @State private var treeScrollView: NSScrollView?
    @State private var scrollEventMonitor: Any?
    @State private var searchQuery: String = ""
    @State private var searchMatches: [UUID] = []
    @State private var currentMatchIndex: Int = 0
    @State private var highlightedNodeID: UUID?
    @State private var lastSubmittedQuery: String = ""

    private let zoomRange: ClosedRange<CGFloat> = 0.4...3.0
    private let searchFocusZoom: CGFloat = 1.2
    private let canvasInnerPadding: CGFloat = 60
    private let canvasOuterPadding: CGFloat = 28
    private var canvasContentInset: CGFloat { canvasInnerPadding + canvasOuterPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            installScrollMonitor()
        }
        .onChange(of: content) { _ in
            parseContent()
        }
        .onChange(of: searchQuery) { _ in
            lastSubmittedQuery = ""
            refreshMatches(resetIndex: true)
        }
        .onChange(of: highlightedNodeID) { _ in
            scrollToHighlightedNode()
        }
        .onChange(of: treeScrollView) { _ in
            scrollToHighlightedNode()
        }
        .onDisappear {
            removeScrollMonitor()
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text(fileName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.purple)
                Spacer()
                Text("\(Int(zoomScale * 100))%")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if treeRoot != nil {
                searchControls
            }
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

            Spacer()
        }
    }

    @ViewBuilder
    private func treeView(for root: JSONTreeGraphNode) -> some View {
        let highlighted = highlightedNodeID.map { Set([$0]) } ?? []

        ScrollView([.horizontal, .vertical]) {
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
        }
        .background(
            ScrollViewIntrospector { scrollView in
                if treeScrollView !== scrollView {
                    treeScrollView = scrollView
                    scrollView.allowsMagnification = true
                    scrollView.minMagnification = zoomRange.lowerBound
                    scrollView.maxMagnification = zoomRange.upperBound
                    zoomScale = scrollView.magnification
                }
            }
        )
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.08, blue: 0.16),
                    Color(red: 0.03, green: 0.03, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
        )
    }

    private func errorView(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unable to parse JSON")
                .font(.headline)
                .foregroundStyle(.red)
            Text(error.localizedDescription)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        }
    }

    private func parseContent() {
        let result = JSONTreeParser.parse(content: content, rootName: fileName)
        switch result {
        case .success(let root):
            treeRoot = root
            parseError = nil
            layout.performLayout(root: root)
            refreshMatches(resetIndex: true)
        case .failure(let error):
            treeRoot = nil
            parseError = error
            searchMatches = []
            highlightedNodeID = nil
            currentMatchIndex = 0
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
            return
        }
        let matches = collectMatches(in: root, query: trimmed)
        searchMatches = matches
        guard !matches.isEmpty else {
            highlightedNodeID = nil
            currentMatchIndex = 0
            return
        }
        if resetIndex || currentMatchIndex >= matches.count {
            currentMatchIndex = 0
        }
        highlightedNodeID = matches[currentMatchIndex]
        dispatchScrollToHighlight()
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
        dispatchScrollToHighlight()
    }

    private func dispatchScrollToHighlight() {
        DispatchQueue.main.async {
            scrollToHighlightedNode()
        }
    }

    private func scrollToHighlightedNode(animated: Bool = true) {
        guard let scrollView = treeScrollView,
              let id = highlightedNodeID,
              let point = layout.position(for: id) else { return }

        let initialDocPoint = documentPoint(fromLayoutPoint: point, in: scrollView)
        ensureSearchZoomIfNeeded(targetDocPoint: initialDocPoint, in: scrollView, animated: animated)

        let refreshedDocPoint = documentPoint(fromLayoutPoint: point, in: scrollView)
        centerDocument(on: refreshedDocPoint, in: scrollView, animated: animated)
    }

    private func ensureSearchZoomIfNeeded(targetDocPoint point: NSPoint, in scrollView: NSScrollView, animated: Bool) {
        guard !searchMatches.isEmpty else { return }
        let current = scrollView.magnification
        let desired = max(current, searchFocusZoom)
        guard abs(desired - current) > 0.0001 else { return }
        updateZoom(to: desired, centeredAt: point, in: scrollView, animated: animated)
    }

    private func installScrollMonitor() {
        guard scrollEventMonitor == nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard let scrollView = treeScrollView else { return event }
            guard let window = scrollView.window, event.window == window else { return event }

            switch event.type {
            case .magnify:
                let increment = event.magnification
                guard abs(increment) > 0.0001 else { return nil }
                let factor = 1.0 + increment
                let center = self.documentPoint(fromWindowLocation: event.locationInWindow, in: scrollView)
                let proposed = scrollView.magnification * factor
                self.updateZoom(to: proposed, centeredAt: center, in: scrollView, animated: false)
                dispatchScrollToHighlight()
                return nil

            case .scrollWheel:
                guard event.modifierFlags.contains(.command) else { return event }
                let center = self.documentPoint(fromWindowLocation: event.locationInWindow, in: scrollView)
                let deltaY = event.scrollingDeltaY
                guard abs(deltaY) > 0.0001 else { return nil }
                let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 0.04 : 0.18
                let proposed = scrollView.magnification - (deltaY * direction * multiplier)
                self.updateZoom(to: proposed, centeredAt: center, in: scrollView, animated: false)
                dispatchScrollToHighlight()
                return nil

            default:
                return event
            }
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    private func updateZoom(to newValue: CGFloat, centeredAt docPoint: NSPoint, in scrollView: NSScrollView, animated: Bool) {
        let clamped = clampZoom(newValue)
        guard abs(clamped - scrollView.magnification) > 0.0001 else { return }
        let focusPoint = sanitizedDocumentPoint(docPoint, in: scrollView)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                scrollView.animator().setMagnification(clamped, centeredAt: focusPoint)
            }
        } else {
            scrollView.setMagnification(clamped, centeredAt: focusPoint)
        }
        zoomScale = clamped
    }

    private func centerDocument(on docPoint: NSPoint, in scrollView: NSScrollView, animated: Bool) {
        guard let docView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let clipSize = clipView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }

        let focusPoint = sanitizedDocumentPoint(docPoint, in: scrollView)

        var targetOrigin = NSPoint(
            x: focusPoint.x - clipSize.width / 2,
            y: focusPoint.y - clipSize.height / 2
        )

        let maxX = max(docView.bounds.width - clipSize.width, 0)
        let maxY = max(docView.bounds.height - clipSize.height, 0)
        targetOrigin.x = min(max(targetOrigin.x, 0), maxX)
        targetOrigin.y = min(max(targetOrigin.y, 0), maxY)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                clipView.animator().setBoundsOrigin(targetOrigin)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clipView)
            }
        } else {
            clipView.scroll(to: targetOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func sanitizedDocumentPoint(_ point: NSPoint, in scrollView: NSScrollView) -> NSPoint {
        guard let docView = scrollView.documentView else { return point }
        let x = min(max(point.x, 0), docView.bounds.width)
        let y = min(max(point.y, 0), docView.bounds.height)
        return NSPoint(x: x, y: y)
    }

    private func documentPoint(fromWindowLocation location: CGPoint, in scrollView: NSScrollView) -> NSPoint {
        guard let docView = scrollView.documentView else {
            return scrollView.documentVisibleRect.center
        }
        var converted = docView.convert(location, from: nil)
        if !converted.x.isFinite || !converted.y.isFinite {
            converted = scrollView.documentVisibleRect.center
        }
        return converted
    }

    private func documentPoint(fromLayoutPoint point: CGPoint, in scrollView: NSScrollView) -> NSPoint {
        guard let docView = scrollView.documentView else {
            return NSPoint(x: point.x + canvasContentInset, y: point.y + canvasContentInset)
        }
        let yBase: CGFloat
        if docView.isFlipped {
            yBase = point.y + canvasContentInset
        } else {
            let baseHeight = docView.bounds.height
            yBase = baseHeight - (point.y + canvasContentInset)
        }
        let x = min(max(point.x + canvasContentInset, 0), docView.bounds.width)
        let y = min(max(yBase, 0), docView.bounds.height)
        return NSPoint(x: x, y: y)
    }

    private struct ScrollViewIntrospector: NSViewRepresentable {
        let onUpdate: (NSScrollView) -> Void

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async {
                if let scroll = view.enclosingScrollView {
                    onUpdate(scroll)
                }
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                if let scroll = nsView.enclosingScrollView {
                    onUpdate(scroll)
                }
            }
        }
    }
}



private enum JSONTreeParser {
    static func parse(content: String, rootName: String) -> Result<JSONTreeGraphNode, Error> {
        guard let data = content.data(using: .utf8) else {
            return .failure(NSError(domain: "JSONTree", code: 1, userInfo: [NSLocalizedDescriptionKey: "Content is not UTF-8 encodable"]))
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let node = buildNode(name: rootName.isEmpty ? "ROOT" : rootName, value: json)
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
                var valueText = AttributedString(value)
                valueText.font = .system(size: 12, weight: .regular, design: .monospaced)
                valueText.foregroundColor = (isHighlighted ? Theme.gold : node.valueColor).opacity(0.9)
                let valuePoint = CGPoint(x: point.x + 22, y: point.y + 14)
                context.draw(Text(valueText), at: valuePoint, anchor: .leading)
            }
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
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
