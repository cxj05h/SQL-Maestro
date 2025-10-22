import SwiftUI

extension Sequence where Element == InlineNode {
  func renderText(
    baseURL: URL?,
    textStyles: InlineTextStyles,
    images: [String: Image],
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) -> Text {
    var renderer = TextInlineRenderer(
      baseURL: baseURL,
      textStyles: textStyles,
      images: images,
      softBreakMode: softBreakMode,
      attributes: attributes
    )
    renderer.render(self)
    return renderer.result
  }
}

private struct TextInlineRenderer {
  var result = Text("")

  private let baseURL: URL?
  private let textStyles: InlineTextStyles
  private let images: [String: Image]
  private let softBreakMode: SoftBreak.Mode
  private var attributes: AttributeContainer
  private var shouldSkipNextWhitespace = false
  private var highlightAttributeStack: [AttributeContainer] = []

  init(
    baseURL: URL?,
    textStyles: InlineTextStyles,
    images: [String: Image],
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) {
    self.baseURL = baseURL
    self.textStyles = textStyles
    self.images = images
    self.softBreakMode = softBreakMode
    self.attributes = attributes
  }

  mutating func render<S: Sequence>(_ inlines: S) where S.Element == InlineNode {
    for inline in inlines {
      self.render(inline)
    }
  }

  private mutating func render(_ inline: InlineNode) {
    switch inline {
    case .text(let content):
      self.renderText(content)
    case .softBreak:
      self.renderSoftBreak()
    case .html(let content):
      self.renderHTML(content)
    case .image(let source, _):
      self.renderImage(source)
    case .styledCode:
      // StyledCode will be handled separately in InlineText view
      self.defaultRender(inline)
    default:
      self.defaultRender(inline)
    }
  }

  private mutating func renderText(_ text: String) {
    var text = text

    if self.shouldSkipNextWhitespace {
      self.shouldSkipNextWhitespace = false
      text = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
    }

    self.defaultRender(.text(text))
  }

  private mutating func renderSoftBreak() {
    switch self.softBreakMode {
    case .space where self.shouldSkipNextWhitespace:
      self.shouldSkipNextWhitespace = false
    case .space:
      self.defaultRender(.softBreak)
    case .lineBreak:
      self.shouldSkipNextWhitespace = true
      self.defaultRender(.lineBreak)
    }
  }

  private mutating func renderHTML(_ html: String) {
    guard let tag = HTMLTag(html) else {
      self.defaultRender(.html(html))
      return
    }

    switch tag.name.lowercased() {
    case "br":
      self.defaultRender(.lineBreak)
      self.shouldSkipNextWhitespace = true
    case "mark":
      if tag.isClosing, !self.highlightAttributeStack.isEmpty {
        self.handleHighlightTag(
          tag: tag,
          background: .clear,
          foreground: .clear
        )
      } else if tag.raw.lowercased().contains("data-sqlmaestro=\"active\"") {
        self.handleHighlightTag(
          tag: tag,
          background: Color(red: 0.95, green: 0.78, blue: 0.96),
          foreground: Color.black
        )
      } else if tag.raw.lowercased().contains("data-sqlmaestro=\"match\"") {
        self.handleHighlightTag(
          tag: tag,
          background: Color(red: 1.0, green: 0.92, blue: 0.68),
          foreground: Color.black
        )
      } else {
        self.defaultRender(.html(tag.raw))
      }
    default:
      self.defaultRender(.html(html))
    }
  }

  private mutating func renderImage(_ source: String) {
    if let image = self.images[source] {
      self.result = self.result + Text(image)
    }
  }

  private mutating func defaultRender(_ inline: InlineNode) {
    self.result =
      self.result
      + Text(
        inline.renderAttributedString(
          baseURL: self.baseURL,
          textStyles: self.textStyles,
          softBreakMode: self.softBreakMode,
          attributes: self.attributes
        )
      )
  }

  private mutating func handleHighlightTag(
    tag: HTMLTag,
    background: Color,
    foreground: Color
  ) {
    if tag.isClosing {
      if let previous = self.highlightAttributeStack.popLast() {
        self.attributes = previous
      }
    } else {
      self.highlightAttributeStack.append(self.attributes)
      var updated = self.attributes
      updated.backgroundColor = background
      updated.foregroundColor = foreground
      self.attributes = updated
    }
  }
}
