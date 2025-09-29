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

    private let zoomRange: ClosedRange<CGFloat> = 0.4...3.0

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
                TextField("Search keys or values", text: $searchQuery, onCommit: {
                    refreshMatches(resetIndex: true)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
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
                highlightedNodes: highlighted
            )
            .padding(24)
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
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private func scrollToHighlightedNode() {
        guard let scrollView = treeScrollView,
              let id = highlightedNodeID,
              let point = layout.position(for: id) else { return }
        let size = layout.size
        let padding: CGFloat = 160
        let rect = NSRect(
            x: max(point.x - padding, 0),
            y: max(point.y - padding, 0),
            width: min(padding * 2, size.width),
            height: min(padding * 2, size.height)
        )
        scrollView.contentView.scrollToVisible(rect)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func installScrollMonitor() {
        guard scrollEventMonitor == nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let scrollView = treeScrollView else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift])
            guard !modifiers.isEmpty else { return event }
            guard let window = scrollView.window, event.window == window else { return event }
            let center = scrollView.contentView.convert(event.locationInWindow, from: nil)
            let delta = event.scrollingDeltaY
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 0.02 : 0.1
            let proposed = scrollView.magnification - delta * multiplier
            let clamped = min(max(proposed, zoomRange.lowerBound), zoomRange.upperBound)
            guard clamped != scrollView.magnification else { return nil }
            scrollView.setMagnification(clamped, centeredAt: center)
            zoomScale = clamped
            dispatchScrollToHighlight()
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
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

    var body: some View {
        let size = layout.size
        Canvas { context, _ in
            drawConnections(context: &context)
            drawNodes(context: &context)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drawConnections(context: inout GraphicsContext) {
        let radius: CGFloat = 6
        let branchOffset: CGFloat = 22
        let columnPadding: CGFloat = 36
        for positioned in layout.positionedNodes {
            guard !positioned.node.children.isEmpty else { continue }
            let startPoint = CGPoint(x: positioned.position.x - radius, y: positioned.position.y)
            for child in positioned.node.children {
                guard let childPointRaw = layout.position(for: child.id) else { continue }
                let endPoint = CGPoint(x: childPointRaw.x - radius, y: childPointRaw.y)
                var path = Path()
                path.move(to: startPoint)
                let columnXBase = min(startPoint.x, endPoint.x) - columnPadding
                let columnX = max(columnXBase, 8)
                let horizontalApproach = endPoint.x - columnPadding
                let approachX = max(min(horizontalApproach, endPoint.x - 12), columnX + 8)
                let approachY = endPoint.y - branchOffset
                path.addLine(to: CGPoint(x: columnX, y: startPoint.y))
                path.addLine(to: CGPoint(x: columnX, y: approachY))
                path.addLine(to: CGPoint(x: approachX, y: approachY))
                path.addLine(to: CGPoint(x: approachX, y: endPoint.y))
                path.addLine(to: endPoint)
                context.stroke(path, with: .color(Theme.aqua), lineWidth: 1.0)
            }
        }
    }

    private func drawNodes(context: inout GraphicsContext) {
        for positioned in layout.positionedNodes {
            let point = positioned.position
            let node = positioned.node

            let circleRect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            if highlightedNodes.contains(node.id) {
                context.fill(Path(ellipseIn: circleRect), with: .color(Theme.gold.opacity(0.8)))
                context.stroke(Path(ellipseIn: circleRect), with: .color(Theme.gold), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: circleRect), with: .color(Theme.aquaLt))
                context.stroke(Path(ellipseIn: circleRect), with: .color(Theme.aqua), lineWidth: 1)
            }

            var keyText = AttributedString(node.name)
            keyText.font = .system(size: 12, weight: .semibold)
            keyText.foregroundColor = Theme.purple

            let keyPoint = CGPoint(x: point.x + 12, y: point.y)
            context.draw(Text(keyText), at: keyPoint, anchor: .leading)

            if let value = node.valueDescription {
                var valueText = AttributedString(value)
                valueText.font = .system(size: 12, weight: .regular, design: .monospaced)
                valueText.foregroundColor = highlightedNodes.contains(node.id) ? Theme.gold : node.valueColor
                let valuePoint = CGPoint(x: point.x + 120, y: point.y)
                context.draw(Text(valueText), at: valuePoint, anchor: .leading)
            }
        }
    }
}

private final class JSONTreeLayout {
    private(set) var positionedNodes: [PositionedNode] = []
    private(set) var size: CGSize = .zero
    private var positions: [UUID: CGPoint] = [:]

    private let horizontalSpacing: CGFloat = 220
    private let verticalSpacing: CGFloat = 120
    private let padding: CGFloat = 80
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
