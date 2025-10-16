import SwiftUI

private struct StyledCodeView: View {
  let content: String
  let attributes: AttributeContainer

  var body: some View {
    Text(self.content)
      .font(self.font)
      .foregroundColor(self.foregroundColor)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(self.backgroundColor)
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(self.borderColor, lineWidth: 1)
      )
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[VerticalAlignment.firstTextBaseline]
      }
  }

  private var font: Font {
    if let fontProperties = self.attributes.fontProperties {
      return .withProperties(fontProperties)
    }
    return .system(size: FontProperties.defaultSize, design: .monospaced)
  }

  private var foregroundColor: Color {
    self.attributes.foregroundColor ?? .primary
  }

  private var backgroundColor: Color {
    self.attributes.backgroundColor ?? Color(white: 0.9)
  }

  private var borderColor: Color {
    if let background = self.attributes.backgroundColor {
      return background.opacity(0.35)
    }
    return Color.accentColor.opacity(0.2)
  }
}

struct InlineText: View {
  @Environment(\.inlineImageProvider) private var inlineImageProvider
  @Environment(\.baseURL) private var baseURL
  @Environment(\.imageBaseURL) private var imageBaseURL
  @Environment(\.softBreakMode) private var softBreakMode
  @Environment(\.theme) private var theme

  @State private var inlineImages: [String: Image] = [:]

  private let inlines: [InlineNode]

  init(_ inlines: [InlineNode]) {
    self.inlines = inlines
  }

  var body: some View {
    // Check if we have any styledCode nodes
    let hasStyledCode = inlines.contains { node in
      if case .styledCode = node { return true }
      return false
    }

    if hasStyledCode {
      styledInlineContent
        .task(id: self.inlines) {
          self.inlineImages = (try? await self.loadInlineImages()) ?? [:]
        }
    } else {
      defaultInlineContent
        .task(id: self.inlines) {
          self.inlineImages = (try? await self.loadInlineImages()) ?? [:]
        }
    }
  }

  @ViewBuilder
  private var styledInlineContent: some View {
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
      TextStyleAttributesReader { attributes in
        let codeAttributes = attributes.applying(self.theme.code)
        InlineFlowLayout(spacing: 0) {
          renderInlineSegments(attributes: attributes, codeAttributes: codeAttributes)
        }
      }
    } else {
      defaultInlineContent
    }
  }

  @ViewBuilder
  @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
  private func renderInlineSegments(
    attributes: AttributeContainer,
    codeAttributes: AttributeContainer
  ) -> some View {
    let groups = self.groupInlineNodes(inlines, softBreakMode: self.softBreakMode)

    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
      switch group {
      case .styled(let text):
        StyledCodeView(content: text, attributes: codeAttributes)
          .fixedSize()
      case .text(let nodes):
        nodes.renderText(
          baseURL: self.baseURL,
          textStyles: .init(
            code: self.theme.code,
            emphasis: self.theme.emphasis,
            strong: self.theme.strong,
            strikethrough: self.theme.strikethrough,
            link: self.theme.link
          ),
          images: self.inlineImages,
          softBreakMode: self.softBreakMode,
          attributes: attributes
        )
      case .softBreak(let needsExtraLine):
        if self.softBreakMode == .lineBreak {
          let height = needsExtraLine ? self.lineHeight(from: attributes) : 0
          LineBreakPlaceholder(height: height, mode: .soft)
        } else {
          Text(AttributedString(" ", attributes: attributes))
        }
      case .lineBreak(let needsExtraLine):
        let height = needsExtraLine ? self.lineHeight(from: attributes) : 0
        LineBreakPlaceholder(height: height, mode: .hard)
      }
    }
  }

  private var defaultInlineContent: some View {
    TextStyleAttributesReader { attributes in
      self.inlines.renderText(
        baseURL: self.baseURL,
        textStyles: .init(
          code: self.theme.code,
          emphasis: self.theme.emphasis,
          strong: self.theme.strong,
          strikethrough: self.theme.strikethrough,
          link: self.theme.link
        ),
        images: self.inlineImages,
        softBreakMode: self.softBreakMode,
        attributes: attributes
      )
    }
  }

  private enum InlineGroup {
    case text([InlineNode])
    case styled(String)
    case softBreak(needsExtraLine: Bool)
    case lineBreak(needsExtraLine: Bool)
  }

  private func groupInlineNodes(
    _ nodes: [InlineNode],
    softBreakMode: SoftBreak.Mode
  ) -> [InlineGroup] {
    var groups: [InlineGroup] = []
    var currentText: [InlineNode] = []
    var consecutiveBreaks = 0

    func flushText() {
      guard !currentText.isEmpty else { return }
      groups.append(.text(currentText))
      currentText.removeAll(keepingCapacity: true)
      consecutiveBreaks = 0
    }

    for node in nodes {
      switch node {
      case .styledCode(let text):
        flushText()
        groups.append(.styled(text))
        consecutiveBreaks = 0
      case .softBreak:
        if softBreakMode == .lineBreak {
          flushText()
          let needsExtraLine = consecutiveBreaks > 0
          groups.append(.softBreak(needsExtraLine: needsExtraLine))
          consecutiveBreaks += 1
        } else {
          currentText.append(node)
          consecutiveBreaks = 0
        }
      case .lineBreak:
        flushText()
        let needsExtraLine = consecutiveBreaks > 0
        groups.append(.lineBreak(needsExtraLine: needsExtraLine))
        consecutiveBreaks += 1
      default:
        currentText.append(node)
        consecutiveBreaks = 0
      }
    }

    flushText()
    return groups
  }

  private func lineHeight(from attributes: AttributeContainer) -> CGFloat {
    attributes.fontProperties?.scaledSize ?? FontProperties.defaultSize
  }

  private func loadInlineImages() async throws -> [String: Image] {
    let images = Set(self.inlines.compactMap(\.imageData))
    guard !images.isEmpty else { return [:] }

    return try await withThrowingTaskGroup(of: (String, Image).self) { taskGroup in
      for image in images {
        guard let url = URL(string: image.source, relativeTo: self.imageBaseURL) else {
          continue
        }

        taskGroup.addTask {
          (image.source, try await self.inlineImageProvider.image(with: url, label: image.alt))
        }
      }

      var inlineImages: [String: Image] = [:]

      for try await result in taskGroup {
        inlineImages[result.0] = result.1
      }

      return inlineImages
    }
  }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
private struct InlineFlowLayout: Layout {
  var spacing: CGFloat = 0

  struct LineMetrics {
    var items: [Item]
    var lineWidth: CGFloat
    var lineHeight: CGFloat
    var baseline: CGFloat
  }

  struct Item {
    let index: Int
    let size: CGSize
    let baseline: CGFloat?
    let isLineBreak: Bool
  }

  struct Cache {
    var lines: [LineMetrics] = []
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) -> CGSize {
    let lines = self.computeLines(for: subviews, proposal: proposal)
    cache.lines = lines

    let width = lines.map(\.lineWidth).max() ?? 0
    let height = lines.reduce(into: 0) { $0 += $1.lineHeight }

    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout Cache
  ) {
    let lines = cache.lines.isEmpty ? self.computeLines(for: subviews, proposal: proposal) : cache.lines

    var currentY = bounds.minY

    for line in lines {
      var currentX = bounds.minX

      for item in line.items {
        let subview = subviews[item.index]
        let itemProposal = ProposedViewSize(width: item.size.width, height: item.size.height)
        let baseline = item.baseline ?? item.size.height
        let yOffset = line.baseline - baseline

        subview.place(
          at: CGPoint(x: currentX, y: currentY + yOffset),
          proposal: itemProposal
        )

        if !item.isLineBreak {
          currentX += item.size.width + self.spacing
        }
      }

      currentY += line.lineHeight
    }
  }

  private func computeLines(for subviews: Subviews, proposal: ProposedViewSize) -> [LineMetrics] {
    let maxWidth = proposal.width ?? .infinity
    var lines: [LineMetrics] = []

    var currentItems: [Item] = []
    var currentWidth: CGFloat = 0
    var currentHeight: CGFloat = 0
    var currentBaseline: CGFloat = 0

    func flushLine() {
      guard !currentItems.isEmpty else { return }
      lines.append(
        LineMetrics(
          items: currentItems,
          lineWidth: currentWidth,
          lineHeight: currentHeight,
          baseline: currentBaseline
        )
      )
      currentItems.removeAll(keepingCapacity: true)
      currentWidth = 0
      currentHeight = 0
      currentBaseline = 0
    }

    for index in subviews.indices {
      if let breakInfo = subviews[index][LineBreakValueKey.self] {
        flushLine()
        let breakItem = Item(
          index: index,
          size: CGSize(width: 0, height: breakInfo.height),
          baseline: breakInfo.height,
          isLineBreak: true
        )
        lines.append(
          LineMetrics(
            items: [breakItem],
            lineWidth: 0,
            lineHeight: breakInfo.height,
            baseline: breakInfo.height
          )
        )
        continue
      }

      var spacingBefore = currentItems.isEmpty ? 0 : self.spacing
      if maxWidth.isFinite,
         currentWidth + spacingBefore >= maxWidth,
         !currentItems.isEmpty {
        flushLine()
        spacingBefore = 0
      }

      var availableWidth: CGFloat?
      if maxWidth.isFinite {
        availableWidth = max(maxWidth - currentWidth - spacingBefore, 0)
      }

      if let width = availableWidth, width == 0, !currentItems.isEmpty {
        flushLine()
        spacingBefore = 0
        availableWidth = maxWidth.isFinite ? maxWidth : nil
      }

      var proposalWidth = availableWidth
      if let width = proposalWidth, !width.isFinite {
        proposalWidth = nil
      }

      var dimensions = subviews[index].dimensions(
        in: ProposedViewSize(width: proposalWidth, height: nil)
      )

      if maxWidth.isFinite && !currentItems.isEmpty {
        let requiredWidth = currentWidth + spacingBefore + dimensions.width
        if requiredWidth - maxWidth > .ulpOfOne {
          flushLine()
          spacingBefore = 0
          dimensions = subviews[index].dimensions(
            in: ProposedViewSize(width: maxWidth, height: nil)
          )
        }
      }

      let size = CGSize(width: dimensions.width, height: dimensions.height)
      let baseline = dimensions[VerticalAlignment.firstTextBaseline]

      // Check if adding this item would leave insufficient space for continuation
      // If we have items on the line and adding this item would leave less than 20% of max width,
      // it's better to wrap to the next line
      let newWidth = currentWidth + spacingBefore + size.width
      let remainingWidth = maxWidth.isFinite ? maxWidth - newWidth : .infinity
      let minContinuationWidth = maxWidth.isFinite ? maxWidth * 0.2 : 0

      if maxWidth.isFinite && !currentItems.isEmpty &&
         remainingWidth < minContinuationWidth &&
         remainingWidth > 0 &&
         size.width < maxWidth * 0.8 {  // Only wrap if the item itself isn't too wide
        flushLine()
        spacingBefore = 0
        dimensions = subviews[index].dimensions(
          in: ProposedViewSize(width: maxWidth, height: nil)
        )
        let newSize = CGSize(width: dimensions.width, height: dimensions.height)
        currentItems.append(Item(index: index, size: newSize, baseline: baseline, isLineBreak: false))
        currentWidth = newSize.width
        currentHeight = max(currentHeight, newSize.height)
        currentBaseline = max(currentBaseline, baseline ?? newSize.height)
      } else {
        currentItems.append(Item(index: index, size: size, baseline: baseline, isLineBreak: false))
        currentWidth += spacingBefore + size.width
        currentHeight = max(currentHeight, size.height)
        currentBaseline = max(currentBaseline, baseline ?? size.height)
      }
    }

    flushLine()

    return lines
  }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
private struct LineBreakPlaceholder: View {
  enum Mode {
    case soft
    case hard
  }

  let height: CGFloat
  let mode: Mode

  var body: some View {
    Color.clear
      .frame(width: 0, height: self.height)
      .layoutValue(
        key: LineBreakValueKey.self,
        value: .init(mode: self.mode, height: max(self.height, 1))
      )
  }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
private struct LineBreakValue: Equatable {
  let mode: LineBreakPlaceholder.Mode
  let height: CGFloat
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
private struct LineBreakValueKey: LayoutValueKey {
  static let defaultValue: LineBreakValue? = nil
}

private extension AttributeContainer {
  func applying(_ textStyle: TextStyle) -> AttributeContainer {
    var container = self
    textStyle._collectAttributes(in: &container)
    return container
  }
}
