import SwiftUI

private struct StyledCodeView: View {
  let content: String
  let fontSize: CGFloat

  var body: some View {
    Text(content)
      .font(.system(size: fontSize, design: .monospaced))
      .foregroundColor(.black)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color(white: 0.85))
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.purple.opacity(0.2), lineWidth: 1)
      )
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
      .task(id: self.inlines) {
        self.inlineImages = (try? await self.loadInlineImages()) ?? [:]
      }
    }
  }

  @ViewBuilder
  private var styledInlineContent: some View {
    TextStyleAttributesReader { attributes in
      // Group consecutive non-styledCode nodes together for proper text rendering
      let groups = groupInlineNodes(inlines)

      HStack(spacing: 0) {
        ForEach(0..<groups.count, id: \.self) { index in
          let group = groups[index]
          if group.isStyledCode, case .styledCode(let content) = group.nodes.first {
            StyledCodeView(content: content, fontSize: 14)
          } else {
            group.nodes.renderText(
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
      }
    }
  }

  private struct InlineGroup {
    let nodes: [InlineNode]
    let isStyledCode: Bool
  }

  private func groupInlineNodes(_ nodes: [InlineNode]) -> [InlineGroup] {
    var groups: [InlineGroup] = []
    var currentGroup: [InlineNode] = []
    var isCurrentStyledCode = false

    for node in nodes {
      if case .styledCode = node {
        // Flush current group if exists
        if !currentGroup.isEmpty {
          groups.append(InlineGroup(nodes: currentGroup, isStyledCode: isCurrentStyledCode))
          currentGroup = []
        }
        // Add styledCode as its own group
        groups.append(InlineGroup(nodes: [node], isStyledCode: true))
        isCurrentStyledCode = false
      } else {
        // Add to current group
        currentGroup.append(node)
        isCurrentStyledCode = false
      }
    }

    // Flush remaining group
    if !currentGroup.isEmpty {
      groups.append(InlineGroup(nodes: currentGroup, isStyledCode: isCurrentStyledCode))
    }

    return groups
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
