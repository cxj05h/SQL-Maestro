import SwiftUI
import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct LayoutFrame: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var minX: CGFloat { x }
    var midX: CGFloat { x + width / 2 }
    var maxX: CGFloat { x + width }
    var minY: CGFloat { y }
    var midY: CGFloat { y + height / 2 }
    var maxY: CGFloat { y + height }
    var area: CGFloat { width * height }

    func clamped(to bounds: CGRect) -> LayoutFrame {
        var newRect = rect.standardized
        if newRect.width < 1 { newRect.size.width = 1 }
        if newRect.height < 1 { newRect.size.height = 1 }
        if newRect.width > bounds.width { newRect.size.width = bounds.width }
        if newRect.height > bounds.height { newRect.size.height = bounds.height }
        if newRect.minX < bounds.minX { newRect.origin.x = bounds.minX }
        if newRect.minY < bounds.minY { newRect.origin.y = bounds.minY }
        if newRect.maxX > bounds.maxX { newRect.origin.x = bounds.maxX - newRect.width }
        if newRect.maxY > bounds.maxY { newRect.origin.y = bounds.maxY - newRect.height }
        return LayoutFrame(rect: newRect.standardized)
    }

    func offsetting(dx: CGFloat, dy: CGFloat) -> LayoutFrame {
        LayoutFrame(x: x + dx, y: y + dy, width: width, height: height)
    }

    func resizing(to size: CGSize) -> LayoutFrame {
        LayoutFrame(x: x, y: y, width: size.width, height: size.height)
    }
}

struct LayoutElementState: Identifiable, Equatable {
    let id: String
    var name: String
    var defaultFrame: LayoutFrame
    var overrideFrame: LayoutFrame?

    var actualFrame: LayoutFrame { overrideFrame ?? defaultFrame }
}

enum LayoutEditorSpace {
    static let workspace = "LayoutEditorWorkspace"
}

private struct LayoutEditingIsPrimaryKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var layoutEditingIsPrimary: Bool {
        get { self[LayoutEditingIsPrimaryKey.self] }
        set { self[LayoutEditingIsPrimaryKey.self] = newValue }
    }
}

enum LayoutIDs {
    enum Workspace {
        static let container = "layout.workspace.container"
    }

    enum SessionToolbar {
        static let container = "layout.sessionToolbar"
        static let actionStack = "layout.sessionToolbar.actions"
        static let populateButton = "layout.sessionToolbar.actions.populate"
        static let clearButton = "layout.sessionToolbar.actions.clear"
        static let secondaryStack = "layout.sessionToolbar.secondary"
        static let label = "layout.sessionToolbar.secondary.label"
        static let linkButton = "layout.sessionToolbar.secondary.link"
        static func sessionButton(_ index: Int) -> String {
            "layout.sessionToolbar.secondary.sessionButton.\(index)"
        }
    }

    enum Output {
        static let container = "layout.output.container"
        static let section = "layout.output.section"
        static let header = "layout.output.header"
        static let title = "layout.output.header.title"
        static let hideButton = "layout.output.header.hide"
        static let editor = "layout.output.editor"
    }

    enum BottomPane {
        static let container = "layout.bottomPane.container"
        static let header = "layout.bottomPane.header"
        static let title = "layout.bottomPane.header.title"
        static let toolbar = "layout.bottomPane.header.toolbar"
        static let actionPrimary = "layout.bottomPane.header.primaryAction"
        static let actionSecondary = "layout.bottomPane.header.secondaryAction"
        static let popOutButton = "layout.bottomPane.header.popout"
        static let body = "layout.bottomPane.body"
    }

    enum SavedFiles {
        static let toolbar = "layout.savedFiles.toolbar"
        static let searchRow = "layout.savedFiles.search"
        static let list = "layout.savedFiles.list"
        static let editor = "layout.savedFiles.editor"
        static let infoPanel = "layout.savedFiles.info"
    }
}

private struct LayoutOverridesPayload: Codable {
    var frames: [String: LayoutFrame]
}

final class LayoutOverrideManager: ObservableObject {
    @Published private(set) var isEditing: Bool = false
    @Published private(set) var elements: [String: LayoutElementState] = [:]
    @Published private(set) var overrides: [String: LayoutFrame] = [:]
    @Published private(set) var consoleLines: [String] = []
    @Published private(set) var workspaceBounds: LayoutFrame? = nil

    private let fileURL: URL
    private var preEditOverrides: [String: LayoutFrame] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logLimit = 150

    init(fileURL: URL = AppPaths.layoutOverrides) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadOverrides()
    }

    var orderedElements: [LayoutElementState] {
        elements.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var elementsArray: [LayoutElementState] {
        elements.values.sorted { $0.id < $1.id }
    }

    var overlayElements: [LayoutElementState] {
        elements.values.sorted { lhs, rhs in
            lhs.actualFrame.area > rhs.actualFrame.area
        }
    }

    func register(element id: String, name: String?, defaultFrame: CGRect, allowDefaultUpdate: Bool = true) {
        let frame = LayoutFrame(rect: defaultFrame.standardized)
        var state = elements[id] ?? LayoutElementState(id: id, name: name ?? id, defaultFrame: frame, overrideFrame: overrides[id])
        state.name = name ?? state.name
        if allowDefaultUpdate || elements[id] == nil {
            if !state.defaultFrame.rect.approximatelyEquals(frame.rect) {
                state.defaultFrame = frame
            }
        }
        state.overrideFrame = overrides[id]
        elements[id] = state
    }

    func updateOverride(for id: String, frame: LayoutFrame?) {
        let clampedFrame = frame.flatMap { clamp($0) }
        var updated = overrides
        if let clampedFrame {
            updated[id] = clampedFrame
        } else {
            updated.removeValue(forKey: id)
        }
        overrides = updated
        if var state = elements[id] {
            state.overrideFrame = clampedFrame
            elements[id] = state
        }
        if isEditing {
            logConsole("override.update", context: ["id": id, "frame": clampedFrame.map { $0.rect.debugDescription } ?? "nil"])
        }
    }

    func updateWorkspaceBounds(_ rect: CGRect) {
        let frame = LayoutFrame(rect: rect.standardized)
        workspaceBounds = frame
    }

    func actualFrame(for id: String) -> LayoutFrame? {
        elements[id]?.actualFrame
    }

    func beginEditing() {
        guard !isEditing else { return }
        preEditOverrides = overrides
        isEditing = true
        logConsole("edit.begin", context: ["count": "\(overrides.count)"])
    }

    func endEditing(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        if save {
            persist()
        } else {
            overrides = preEditOverrides
            for (key, var state) in elements {
                state.overrideFrame = preEditOverrides[key]
                elements[key] = state
            }
            logConsole("edit.cancelled")
        }
    }

    func resetOverrides() {
        overrides = [:]
        preEditOverrides = [:]
        for (key, var state) in elements {
            state.overrideFrame = nil
            elements[key] = state
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            logConsole("overrides.reset")
        } catch {
            logConsole("overrides.reset.error", context: ["error": error.localizedDescription])
        }
    }

    private func loadOverrides() {
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try decoder.decode(LayoutOverridesPayload.self, from: data)
            overrides = payload.frames
            logConsole("overrides.load", context: ["count": "\(payload.frames.count)"])
        } catch {
            overrides = [:]
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logConsole("overrides.load.error", context: ["error": error.localizedDescription])
            } else {
                logConsole("overrides.load.missing")
            }
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = LayoutOverridesPayload(frames: overrides)
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: [.atomic])
            logConsole("overrides.save", context: ["count": "\(overrides.count)"])
        } catch {
            logConsole("overrides.save.error", context: ["error": error.localizedDescription])
        }
    }

    private func logConsole(_ message: String, context: [String: String] = [:]) {
        let detail: String
        if context.isEmpty {
            detail = message
        } else {
            let pairs = context.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            detail = "\(message) [\(pairs)]"
        }
        DispatchQueue.main.async {
            var next = self.consoleLines
            next.append(detail)
            if next.count > self.logLimit {
                next.removeFirst(next.count - self.logLimit)
            }
            self.consoleLines = next
        }
        LOG("LayoutEditor: \(detail)")
    }

    private func clamp(_ frame: LayoutFrame) -> LayoutFrame {
        guard let bounds = workspaceBounds?.rect else { return frame }
        return frame.clamped(to: bounds)
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) <= epsilon &&
        abs(minY - other.minY) <= epsilon &&
        abs(width - other.width) <= epsilon &&
        abs(height - other.height) <= epsilon
    }
}

private struct LayoutElementPreference: Equatable {
    var id: String
    var name: String
    var frame: CGRect
}

private struct LayoutElementPreferenceKey: PreferenceKey {
    static var defaultValue: [LayoutElementPreference] = []

    static func reduce(value: inout [LayoutElementPreference], nextValue: () -> [LayoutElementPreference]) {
        value.append(contentsOf: nextValue())
    }
}

private struct LayoutEditableModifier: ViewModifier {
    @EnvironmentObject private var layoutManager: LayoutOverrideManager
    @Environment(\.layoutEditingIsPrimary) private var isPrimaryWorkspace
    let elementID: String
    let displayName: String

    @State private var baseFrame: LayoutFrame = LayoutFrame(x: 0, y: 0, width: 0, height: 0)

    func body(content: Content) -> some View {
        let overrideFrame = layoutManager.overrides[elementID]
        let hasBase = baseFrame.width > 0.5 && baseFrame.height > 0.5

        return content
            .background(
                GeometryReader { proxy in
                    let rect = proxy.frame(in: .named(LayoutEditorSpace.workspace))
                    Color.clear.preference(
                        key: LayoutElementPreferenceKey.self,
                        value: [LayoutElementPreference(id: elementID, name: displayName, frame: rect)]
                    )
                }
            )
            .onPreferenceChange(LayoutElementPreferenceKey.self) { values in
                guard let pref = values.last(where: { $0.id == elementID }) else { return }
                let standardized = pref.frame.standardized
                baseFrame = LayoutFrame(rect: standardized)
                layoutManager.register(element: pref.id, name: pref.name, defaultFrame: standardized, allowDefaultUpdate: isPrimaryWorkspace)
            }
            .frame(
                width: overrideFrame?.width,
                height: overrideFrame?.height,
                alignment: .topLeading
            )
            .offset(
                x: offsetDelta(for: overrideFrame, hasBase: hasBase, axis: .horizontal),
                y: offsetDelta(for: overrideFrame, hasBase: hasBase, axis: .vertical)
            )
    }

    private enum AxisOrientation {
        case horizontal
        case vertical
    }

    private func offsetDelta(for overrideFrame: LayoutFrame?, hasBase: Bool, axis: AxisOrientation) -> CGFloat {
        guard hasBase, let overrideFrame else { return 0 }
        let base = baseFrame.rect
        switch axis {
        case .horizontal:
            return overrideFrame.x - base.origin.x
        case .vertical:
            return overrideFrame.y - base.origin.y
        }
    }
}

extension View {
    func layoutEditable(_ id: String, name: String? = nil) -> some View {
        modifier(LayoutEditableModifier(elementID: id, displayName: name ?? id))
    }
}

struct LayoutWorkspace<Content: View>: View {
    @EnvironmentObject private var layoutManager: LayoutOverrideManager
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat
    private let content: () -> Content
    private let isPrimary: Bool

    init(alignment: HorizontalAlignment = .leading,
         spacing: CGFloat = 12,
         isPrimary: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
        self.isPrimary = isPrimary
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            content()
        }
        .allowsHitTesting(!(layoutManager.isEditing && isPrimary))
        .background(
            Group {
                if isPrimary {
                    GeometryReader { proxy in
                        let rect = proxy.frame(in: .local)
                        Color.clear
                            .onAppear {
                                layoutManager.updateWorkspaceBounds(rect)
                            }
                            .onChange(of: rect.size) { _ in
                                layoutManager.updateWorkspaceBounds(rect)
                            }
                    }
                }
            }
        )
        .coordinateSpace(name: LayoutEditorSpace.workspace)
        .overlay(alignment: .topLeading) {
            if isPrimary && layoutManager.isEditing {
                LayoutEditorOverlay()
            }
        }
        .environment(\.layoutEditingIsPrimary, isPrimary)
    }
}

private struct LayoutEditorOverlay: View {
    @EnvironmentObject private var layoutManager: LayoutOverrideManager
    @State private var activeGuides: [GuideLine] = []
    @State private var activeElementID: String? = nil

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .named(LayoutEditorSpace.workspace))
            Color.clear
                .onAppear {
                    layoutManager.updateWorkspaceBounds(bounds)
                }
                .onChange(of: bounds.size) { _ in
                    layoutManager.updateWorkspaceBounds(bounds)
                }

            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        activeElementID = nil
                        activeGuides = []
                    }

                ForEach(layoutManager.overlayElements) { element in
                    LayoutElementOverlay(
                        element: element,
                        bounds: bounds,
                        isActive: activeElementID == element.id,
                        snapCandidates: snapCandidates(for: element.id),
                        onBegin: {
                            activeElementID = element.id
                        },
                        onChange: { newFrame, guides in
                            layoutManager.updateOverride(for: element.id, frame: newFrame)
                            activeGuides = guides
                        },
                        onEnd: {
                            activeGuides = []
                            activeElementID = nil
                        }
                    )
                }

                GuidesView(guides: activeGuides, bounds: bounds)

                LayoutOverlayControls(
                    onFinish: { layoutManager.endEditing(save: true) },
                    onCancel: { layoutManager.endEditing(save: false) },
                    onReset: { layoutManager.resetOverrides() },
                    logs: layoutManager.consoleLines
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
                .allowsHitTesting(true)
            }
        }
    }

    private func snapCandidates(for id: String) -> SnapCandidates {
        var horizontal: [CGFloat] = []
        var vertical: [CGFloat] = []
        for element in layoutManager.elementsArray where element.id != id {
            let rect = element.actualFrame.rect
            horizontal.append(contentsOf: [rect.minX, rect.midX, rect.maxX])
            vertical.append(contentsOf: [rect.minY, rect.midY, rect.maxY])
        }
        if let bounds = layoutManager.workspaceBounds?.rect {
            horizontal.append(contentsOf: [bounds.minX, bounds.midX, bounds.maxX])
            vertical.append(contentsOf: [bounds.minY, bounds.midY, bounds.maxY])
        }
        let uniqueHorizontal = Array(Set(horizontal.filter { $0.isFinite })).sorted()
        let uniqueVertical = Array(Set(vertical.filter { $0.isFinite })).sorted()
        return SnapCandidates(horizontal: uniqueHorizontal, vertical: uniqueVertical)
    }
}

private struct LayoutElementOverlay: View {
    let element: LayoutElementState
    let bounds: CGRect
    let isActive: Bool
    let snapCandidates: SnapCandidates
    let onBegin: () -> Void
    let onChange: (LayoutFrame, [GuideLine]) -> Void
    let onEnd: () -> Void

    @State private var dragStartFrame: LayoutFrame? = nil

    private let snapThreshold: CGFloat = 8
    private let handleSize: CGFloat = 10
    private let minSize: CGFloat = 24

    var body: some View {
        let frame = element.actualFrame.rect

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isActive ? Color.blue.opacity(0.18) : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(Color.blue.opacity(isActive ? 0.9 : 0.18), style: StrokeStyle(lineWidth: isActive ? 2 : 1, dash: [4, 6]))
                )
                .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                .position(x: frame.midX, y: frame.midY)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isActive {
                        dragStartFrame = nil
                        onEnd()
                    } else {
                        dragStartFrame = nil
                        onBegin()
                    }
                }
                .gesture(dragGesture())
                .overlay(alignment: .topLeading) {
                    if isActive {
                        Text(element.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.9))
                            .clipShape(Capsule())
                            .padding(4)
                    }
                }
                .overlay {
                    if isActive {
                        handles(for: frame)
                    }
                }
        }
        .zIndex(isActive ? 10 : 1)
    }

    private func handles(for frame: CGRect) -> some View {
        ForEach(ResizeHandle.allCases, id: \.self) { handle in
            Rectangle()
                .fill(Color.white)
                .overlay(Rectangle().stroke(Color.blue, lineWidth: 1))
                .frame(width: handleSize, height: handleSize)
                .position(handle.position(in: frame.size, padding: handleSize / 2))
                .gesture(resizeGesture(handle: handle))
        }
    }

    private func dragGesture() -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = element.actualFrame
                    if !isActive { onBegin() }
                }
                guard let start = dragStartFrame else { return }
                var updated = start.offsetting(dx: value.translation.width, dy: value.translation.height)
                let snap = snapTranslation(updated)
                onChange(snap.frame, snap.guides)
            }
            .onEnded { _ in
                if dragStartFrame != nil {
                    dragStartFrame = nil
                    onEnd()
                }
            }
    }

    private func resizeGesture(handle: ResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = element.actualFrame
                    onBegin()
                }
                guard let start = dragStartFrame else { return }
                var updated = start
                switch handle {
                case .top:
                    let delta = value.translation.height
                    let newHeight = max(minSize, start.height - delta)
                    let newY = start.y + delta
                    updated = LayoutFrame(x: start.x, y: newY, width: start.width, height: newHeight)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.top])
                    onChange(snap.frame, snap.guides)
                case .bottom:
                    let delta = value.translation.height
                    let newHeight = max(minSize, start.height + delta)
                    updated = LayoutFrame(x: start.x, y: start.y, width: start.width, height: newHeight)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.bottom])
                    onChange(snap.frame, snap.guides)
                case .left:
                    let delta = value.translation.width
                    let newWidth = max(minSize, start.width - delta)
                    let newX = start.x + delta
                    updated = LayoutFrame(x: newX, y: start.y, width: newWidth, height: start.height)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.left])
                    onChange(snap.frame, snap.guides)
                case .right:
                    let delta = value.translation.width
                    let newWidth = max(minSize, start.width + delta)
                    updated = LayoutFrame(x: start.x, y: start.y, width: newWidth, height: start.height)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.right])
                    onChange(snap.frame, snap.guides)
                case .topLeft:
                    let deltaX = value.translation.width
                    let deltaY = value.translation.height
                    let newWidth = max(minSize, start.width - deltaX)
                    let newHeight = max(minSize, start.height - deltaY)
                    let newX = start.x + deltaX
                    let newY = start.y + deltaY
                    updated = LayoutFrame(x: newX, y: newY, width: newWidth, height: newHeight)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.left, .top])
                    onChange(snap.frame, snap.guides)
                case .topRight:
                    let deltaX = value.translation.width
                    let deltaY = value.translation.height
                    let newWidth = max(minSize, start.width + deltaX)
                    let newHeight = max(minSize, start.height - deltaY)
                    let newY = start.y + deltaY
                    updated = LayoutFrame(x: start.x, y: newY, width: newWidth, height: newHeight)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.right, .top])
                    onChange(snap.frame, snap.guides)
                case .bottomLeft:
                    let deltaX = value.translation.width
                    let deltaY = value.translation.height
                    let newWidth = max(minSize, start.width - deltaX)
                    let newHeight = max(minSize, start.height + deltaY)
                    let newX = start.x + deltaX
                    updated = LayoutFrame(x: newX, y: start.y, width: newWidth, height: newHeight)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.left, .bottom])
                    onChange(snap.frame, snap.guides)
                case .bottomRight:
                    let deltaX = value.translation.width
                    let deltaY = value.translation.height
                    let newWidth = max(minSize, start.width + deltaX)
                    let newHeight = max(minSize, start.height + deltaY)
                    updated = LayoutFrame(x: start.x, y: start.y, width: newWidth, height: newHeight)
                    updated = clamp(updated)
                    let snap = snapResize(updated, edges: [.right, .bottom])
                    onChange(snap.frame, snap.guides)
                }
            }
            .onEnded { _ in
                dragStartFrame = nil
                onEnd()
            }
    }

    private func clamp(_ frame: LayoutFrame) -> LayoutFrame {
        LayoutFrame(x: frame.x, y: frame.y, width: frame.width, height: frame.height).clamped(to: bounds)
    }

    private func snapTranslation(_ frame: LayoutFrame) -> SnapResult {
        var updated = frame
        var guides: [GuideLine] = []

        if !snapCandidates.horizontal.isEmpty {
            let edges = [frame.x, frame.midX, frame.maxX]
            if let result = nearest(value: edges, candidates: snapCandidates.horizontal) {
                let (edgeIndex, candidate) = result
                let delta = candidate - edges[edgeIndex]
                updated.x += delta
                guides.append(GuideLine(orientation: .vertical, position: candidate))
            }
        }

        if !snapCandidates.vertical.isEmpty {
            let edges = [frame.y, frame.midY, frame.maxY]
            if let result = nearest(value: edges, candidates: snapCandidates.vertical) {
                let (edgeIndex, candidate) = result
                let delta = candidate - edges[edgeIndex]
                updated.y += delta
                guides.append(GuideLine(orientation: .horizontal, position: candidate))
            }
        }

        updated = clamp(updated)
        return SnapResult(frame: updated, guides: guides)
    }

    private func snapResize(_ frame: LayoutFrame, edges: ResizableEdges) -> SnapResult {
        var updated = frame
        var guides: [GuideLine] = []

        if edges.contains(.left), !snapCandidates.horizontal.isEmpty {
            if let candidate = nearest(value: frame.x, candidates: snapCandidates.horizontal), candidate.delta < snapThreshold {
                let delta = candidate.value - frame.x
                updated.x += delta
                updated.width -= delta
                updated.width = max(updated.width, minSize)
                guides.append(GuideLine(orientation: .vertical, position: candidate.value))
            }
        }

        if edges.contains(.right), !snapCandidates.horizontal.isEmpty {
            if let candidate = nearest(value: frame.maxX, candidates: snapCandidates.horizontal) {
                if candidate.delta < snapThreshold {
                    let newWidth = max(minSize, candidate.value - updated.x)
                    updated.width = newWidth
                    guides.append(GuideLine(orientation: .vertical, position: candidate.value))
                }
            }
        }

        if edges.contains(.top), !snapCandidates.vertical.isEmpty {
            if let candidate = nearest(value: frame.y, candidates: snapCandidates.vertical) {
                if candidate.delta < snapThreshold {
                    let delta = candidate.value - frame.y
                    updated.y += delta
                    updated.height -= delta
                    updated.height = max(updated.height, minSize)
                    guides.append(GuideLine(orientation: .horizontal, position: candidate.value))
                }
            }
        }

        if edges.contains(.bottom), !snapCandidates.vertical.isEmpty {
            if let candidate = nearest(value: frame.maxY, candidates: snapCandidates.vertical), candidate.delta < snapThreshold {
                let newHeight = max(minSize, candidate.value - updated.y)
                updated.height = newHeight
                guides.append(GuideLine(orientation: .horizontal, position: candidate.value))
            }
        }

        updated = clamp(updated)
        return SnapResult(frame: updated, guides: guides)
    }

    private func nearest(value: [CGFloat], candidates: [CGFloat]) -> (Int, CGFloat)? {
        var best: (Int, CGFloat, CGFloat)? = nil
        for (index, v) in value.enumerated() {
            if let candidate = nearest(value: v, candidates: candidates) {
                if candidate.delta < snapThreshold {
                    if let currentBest = best {
                        if candidate.delta < currentBest.2 {
                            best = (index, candidate.value, candidate.delta)
                        }
                    } else {
                        best = (index, candidate.value, candidate.delta)
                    }
                }
            }
        }
        if let best {
            return (best.0, best.1)
        }
        return nil
    }

    private func nearest(value: CGFloat, candidates: [CGFloat]) -> (value: CGFloat, delta: CGFloat)? {
        guard let candidate = candidates.min(by: { abs($0 - value) < abs($1 - value) }) else {
            return nil
        }
        return (value: candidate, delta: abs(candidate - value))
    }
}

private struct GuidesView: View {
    let guides: [GuideLine]
    let bounds: CGRect

    var body: some View {
        ForEach(guides) { guide in
            Path { path in
                switch guide.orientation {
                case .vertical:
                    path.move(to: CGPoint(x: guide.position, y: bounds.minY))
                    path.addLine(to: CGPoint(x: guide.position, y: bounds.maxY))
                case .horizontal:
                    path.move(to: CGPoint(x: bounds.minX, y: guide.position))
                    path.addLine(to: CGPoint(x: bounds.maxX, y: guide.position))
                }
            }
            .stroke(Color.blue.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }
    }
}

private struct SnapCandidates {
    var horizontal: [CGFloat]
    var vertical: [CGFloat]
}

private struct GuideLine: Identifiable, Equatable {
    enum Orientation {
        case horizontal
        case vertical
    }

    let id = UUID()
    var orientation: Orientation
    var position: CGFloat
}

private struct SnapResult {
    var frame: LayoutFrame
    var guides: [GuideLine]
}

private struct ResizableEdges: OptionSet {
    let rawValue: Int

    static let left = ResizableEdges(rawValue: 1 << 0)
    static let right = ResizableEdges(rawValue: 1 << 1)
    static let top = ResizableEdges(rawValue: 1 << 2)
    static let bottom = ResizableEdges(rawValue: 1 << 3)
}

private struct LayoutOverlayControls: View {
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Finish Layout Edit") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                Button("Cancel Changes") { onCancel() }
                    .buttonStyle(.bordered)

                Button("Reset Overrides") { onReset() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }

            if !logs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Layout Logs")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.suffix(18).enumerated()), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 6)
    }
}

private enum ResizeHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    func position(in size: CGSize, padding: CGFloat) -> CGPoint {
        switch self {
        case .topLeft:
            return CGPoint(x: padding, y: padding)
        case .top:
            return CGPoint(x: size.width / 2, y: padding)
        case .topRight:
            return CGPoint(x: max(size.width - padding, padding), y: padding)
        case .right:
            return CGPoint(x: max(size.width - padding, padding), y: size.height / 2)
        case .bottomRight:
            return CGPoint(x: max(size.width - padding, padding), y: max(size.height - padding, padding))
        case .bottom:
            return CGPoint(x: size.width / 2, y: max(size.height - padding, padding))
        case .bottomLeft:
            return CGPoint(x: padding, y: max(size.height - padding, padding))
        case .left:
            return CGPoint(x: padding, y: size.height / 2)
        }
    }
}
