import Foundation
import SwiftUI

extension InlineNode {
  func renderAttributedString(
    baseURL: URL?,
    textStyles: InlineTextStyles,
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) -> AttributedString {
    var renderer = AttributedStringInlineRenderer(
      baseURL: baseURL,
      textStyles: textStyles,
      softBreakMode: softBreakMode,
      attributes: attributes
    )
    renderer.render(self)
    return renderer.result.resolvingFonts()
  }
}

private struct AttributedStringInlineRenderer {
  var result = AttributedString()

  private let baseURL: URL?
  private let textStyles: InlineTextStyles
  private let softBreakMode: SoftBreak.Mode
  private var attributes: AttributeContainer
  private var shouldSkipNextWhitespace = false
  private var highlightAttributeStack: [AttributeContainer] = []

  init(
    baseURL: URL?,
    textStyles: InlineTextStyles,
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) {
    self.baseURL = baseURL
    self.textStyles = textStyles
    self.softBreakMode = softBreakMode
    self.attributes = attributes
  }

  mutating func render(_ inline: InlineNode) {
    switch inline {
    case .text(let content):
      self.renderText(content)
    case .softBreak:
      self.renderSoftBreak()
    case .lineBreak:
      self.renderLineBreak()
    case .code(let content):
      self.renderCode(content)
    case .styledCode(let content):
      self.renderCode(content) // For now, render same as code in AttributedString
    case .html(let content):
      self.renderHTML(content)
    case .emphasis(let children):
      self.renderEmphasis(children: children)
    case .strong(let children):
      self.renderStrong(children: children)
    case .strikethrough(let children):
      self.renderStrikethrough(children: children)
    case .link(let destination, let children):
      self.renderLink(destination: destination, children: children)
    case .image(let source, let children):
      self.renderImage(source: source, children: children)
    }
  }

  private mutating func renderText(_ text: String) {
    var text = text

    if self.shouldSkipNextWhitespace {
      self.shouldSkipNextWhitespace = false
      text = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
    }

    self.result += .init(text, attributes: self.attributes)
  }

  private mutating func renderSoftBreak() {
    switch softBreakMode {
    case .space where self.shouldSkipNextWhitespace:
      self.shouldSkipNextWhitespace = false
    case .space:
      self.result += .init(" ", attributes: self.attributes)
    case .lineBreak:
      self.renderLineBreak()
    }
  }

  private mutating func renderLineBreak() {
    self.result += .init("\n", attributes: self.attributes)
  }

  private mutating func renderCode(_ code: String) {
    self.result += .init(code, attributes: self.textStyles.code.mergingAttributes(self.attributes))
  }

  private mutating func renderHTML(_ html: String) {
    guard let tag = HTMLTag(html) else {
      self.renderText(html)
      return
    }

    switch tag.name.lowercased() {
    case "br":
      self.renderLineBreak()
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
        self.renderText(html)
      }
    default:
      self.renderText(html)
    }
  }

  private mutating func renderEmphasis(children: [InlineNode]) {
    let savedAttributes = self.attributes
    self.attributes = self.textStyles.emphasis.mergingAttributes(self.attributes)

    for child in children {
      self.render(child)
    }

    self.attributes = savedAttributes
  }

  private mutating func renderStrong(children: [InlineNode]) {
    let savedAttributes = self.attributes
    self.attributes = self.textStyles.strong.mergingAttributes(self.attributes)

    for child in children {
      self.render(child)
    }

    self.attributes = savedAttributes
  }

  private mutating func renderStrikethrough(children: [InlineNode]) {
    let savedAttributes = self.attributes
    self.attributes = self.textStyles.strikethrough.mergingAttributes(self.attributes)

    for child in children {
      self.render(child)
    }

    self.attributes = savedAttributes
  }

  private mutating func renderLink(destination: String, children: [InlineNode]) {
    let savedAttributes = self.attributes
    self.attributes = self.textStyles.link.mergingAttributes(self.attributes)
    self.attributes.link = URL(string: destination, relativeTo: self.baseURL)

    // Apply conditional coloring based on URL extension
    let lowercaseDestination = destination.lowercased()
    if lowercaseDestination.hasSuffix(".png") {
      // Pink color for image links (#EF44C0)
      self.attributes.foregroundColor = Color(red: 0xEF/255.0, green: 0x44/255.0, blue: 0xC0/255.0)
    } else {
      // Aqua color for regular links (#7DD3C0)
      self.attributes.foregroundColor = Color(red: 0x7D/255.0, green: 0xD3/255.0, blue: 0xC0/255.0)
    }

    for child in children {
      self.render(child)
    }

    self.attributes = savedAttributes
  }

  private mutating func renderImage(source: String, children: [InlineNode]) {
    // AttributedString does not support images
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

extension TextStyle {
  fileprivate func mergingAttributes(_ attributes: AttributeContainer) -> AttributeContainer {
    var newAttributes = attributes
    self._collectAttributes(in: &newAttributes)
    return newAttributes
  }
}
