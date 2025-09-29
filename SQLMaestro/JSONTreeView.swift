import SwiftUI
import Foundation

struct JSONTreePreview: View {
    let fileName: String
    let content: String

    private var parseResult: Result<JSONTreeGraphNode, Error> {
        JSONTreeParser.parse(content: content, rootName: fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(fileName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.purple)

            switch parseResult {
            case .success(let root):
                ScrollView([.horizontal, .vertical]) {
                    JSONTreeCanvas(root: root)
                        .padding(24)
                }
                .background(Theme.grayBG.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            case .failure(let error):
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

            Spacer()
        }
        .padding(20)
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
    private let layout = JSONTreeLayout()

    init(root: JSONTreeGraphNode) {
        self.root = root
        layout.performLayout(root: root)
    }

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
        for positioned in layout.positionedNodes {
            guard !positioned.node.children.isEmpty else { continue }
            let start = positioned.position
            for child in positioned.node.children {
                guard let childPoint = layout.position(for: child.id) else { continue }
                var path = Path()
                path.move(to: start)
                let midX = (start.x + childPoint.x) / 2
                path.addCurve(to: childPoint,
                              control1: CGPoint(x: midX, y: start.y),
                              control2: CGPoint(x: midX, y: childPoint.y))
                context.stroke(path, with: .color(Theme.aqua), lineWidth: 1.0)
            }
        }
    }

    private func drawNodes(context: inout GraphicsContext) {
        for positioned in layout.positionedNodes {
            let point = positioned.position
            let node = positioned.node

            let circleRect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: circleRect), with: .color(Theme.aquaLt))
            context.stroke(Path(ellipseIn: circleRect), with: .color(Theme.aqua), lineWidth: 1)

            var keyText = AttributedString(node.name)
            keyText.font = .system(size: 12, weight: .semibold)
            keyText.foregroundColor = Theme.purple

            let keyPoint = CGPoint(x: point.x + 12, y: point.y)
            context.draw(Text(keyText), at: keyPoint, anchor: .leading)

            if let value = node.valueDescription {
                var valueText = AttributedString(value)
                valueText.font = .system(size: 12, weight: .regular, design: .monospaced)
                valueText.foregroundColor = node.valueColor
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

    private let horizontalSpacing: CGFloat = 160
    private let verticalSpacing: CGFloat = 80
    private let padding: CGFloat = 60
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
