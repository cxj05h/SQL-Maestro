import Foundation
@_implementationOnly import cmark_gfm
@_implementationOnly import cmark_gfm_extensions

private enum StyledCodeMarker {
  static let start = "⟪STYLED⟪"
  static let end = "⟫STYLED⟫"

  static func stripping(from content: String) -> String? {
    guard content.hasPrefix(self.start), content.hasSuffix(self.end) else {
      return nil
    }
    let startIndex = content.index(content.startIndex, offsetBy: self.start.count)
    let endIndex = content.index(content.endIndex, offsetBy: -self.end.count)
    return String(content[startIndex..<endIndex])
  }
}

extension Array where Element == BlockNode {
  init(markdown: String) {
    // Preprocess markdown to handle double backtick syntax for styled code
    let preprocessed = Self.preprocessStyledCode(markdown)
    let blocks = UnsafeNode.parseMarkdown(preprocessed) { document in
      document.children.compactMap(BlockNode.init(unsafeNode:))
    }
    self.init(blocks ?? .init())
  }

  private static func preprocessStyledCode(_ markdown: String) -> String {
    // Replace `code` with `⟪STYLED⟪code⟫STYLED⟫` to keep cmark from splitting on angle brackets
    // Using special Unicode characters that are unlikely to appear in normal text
    // This uses a negative lookbehind/lookahead to avoid matching code blocks (triple backticks)

    // First, find all code block regions (```...```) to exclude them from processing
    // Pattern matches: ``` followed by optional language, newline, any content (including backticks), then ```
    let codeBlockPattern = "```[^\\n]*\\n.*?```"
    guard let codeBlockRegex = try? NSRegularExpression(pattern: codeBlockPattern, options: [.dotMatchesLineSeparators]) else {
      return markdown
    }

    let nsMarkdown = markdown as NSString
    let fullRange = NSRange(location: 0, length: nsMarkdown.length)
    let codeBlockMatches = codeBlockRegex.matches(in: markdown, options: [], range: fullRange)

    // Build result by processing segments between code blocks
    var result = ""
    var currentIndex = 0

    for match in codeBlockMatches {
      // Process text before this code block
      if match.range.location > currentIndex {
        let beforeRange = NSRange(location: currentIndex, length: match.range.location - currentIndex)
        let beforeText = nsMarkdown.substring(with: beforeRange)
        result += processInlineBackticks(beforeText)
      }

      // Add the code block unchanged
      result += nsMarkdown.substring(with: match.range)
      currentIndex = match.range.location + match.range.length
    }

    // Process any remaining text after the last code block
    if currentIndex < nsMarkdown.length {
      let remainingRange = NSRange(location: currentIndex, length: nsMarkdown.length - currentIndex)
      let remainingText = nsMarkdown.substring(with: remainingRange)
      result += processInlineBackticks(remainingText)
    }

    return result
  }

  private static func processInlineBackticks(_ text: String) -> String {
    // Apply styled code markers only to inline backticks (not code blocks)
    let pattern = "(?<!`)`(?!`)([^`]+)`(?!`)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return text
    }
    let range = NSRange(text.startIndex..., in: text)
    let replacement = "`" + StyledCodeMarker.start + "$1" + StyledCodeMarker.end + "`"
    return regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: replacement
    )
  }

  func renderMarkdown() -> String {
    let markdown = UnsafeNode.makeDocument(self) { document in
      String(cString: cmark_render_commonmark(document, CMARK_OPT_DEFAULT, 0))
    } ?? ""
    return Self.postprocessStyledCode(markdown)
  }

  func renderPlainText() -> String {
    UnsafeNode.makeDocument(self) { document in
      String(cString: cmark_render_plaintext(document, CMARK_OPT_DEFAULT, 0))
    } ?? ""
  }

  func renderHTML() -> String {
    UnsafeNode.makeDocument(self) { document in
      String(cString: cmark_render_html(document, CMARK_OPT_DEFAULT, nil))
    } ?? ""
  }

  private static func postprocessStyledCode(_ markdown: String) -> String {
    let pattern = "`" + StyledCodeMarker.start + "(.*?)" + StyledCodeMarker.end + "`"
    guard
      let regex = try? NSRegularExpression(
        pattern: pattern,
        options: [.dotMatchesLineSeparators]
      )
    else {
      return markdown
    }
    let range = NSRange(markdown.startIndex..., in: markdown)
    return regex.stringByReplacingMatches(
      in: markdown,
      options: [],
      range: range,
      withTemplate: "`$1`"
    )
  }
}

extension BlockNode {
  fileprivate init?(unsafeNode: UnsafeNode) {
    switch unsafeNode.nodeType {
    case .blockquote:
      self = .blockquote(children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:)))
    case .list:
      if unsafeNode.children.contains(where: \.isTaskListItem) {
        self = .taskList(
          isTight: unsafeNode.isTightList,
          items: unsafeNode.children.map(RawTaskListItem.init(unsafeNode:))
        )
      } else {
        switch unsafeNode.listType {
        case CMARK_BULLET_LIST:
          self = .bulletedList(
            isTight: unsafeNode.isTightList,
            items: unsafeNode.children.map(RawListItem.init(unsafeNode:))
          )
        case CMARK_ORDERED_LIST:
          self = .numberedList(
            isTight: unsafeNode.isTightList,
            start: unsafeNode.listStart,
            items: unsafeNode.children.map(RawListItem.init(unsafeNode:))
          )
        default:
          fatalError("cmark reported a list node without a list type.")
        }
      }
    case .codeBlock:
      self = .codeBlock(fenceInfo: unsafeNode.fenceInfo, content: unsafeNode.literal ?? "")
    case .htmlBlock:
      self = .htmlBlock(content: unsafeNode.literal ?? "")
    case .paragraph:
      self = .paragraph(content: unsafeNode.children.flatMap(InlineNode.inlineNodes(from:)))
    case .heading:
      self = .heading(
        level: unsafeNode.headingLevel,
        content: unsafeNode.children.flatMap(InlineNode.inlineNodes(from:))
      )
    case .table:
      self = .table(
        columnAlignments: unsafeNode.tableAlignments,
        rows: unsafeNode.children.map(RawTableRow.init(unsafeNode:))
      )
    case .thematicBreak:
      self = .thematicBreak
    default:
      assertionFailure("Unhandled node type '\(unsafeNode.nodeType)' in BlockNode.")
      return nil
    }
  }
}

extension RawListItem {
  fileprivate init(unsafeNode: UnsafeNode) {
    guard unsafeNode.nodeType == .item else {
      fatalError("Expected a list item but got a '\(unsafeNode.nodeType)' instead.")
    }
    self.init(children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:)))
  }
}

extension RawTaskListItem {
  fileprivate init(unsafeNode: UnsafeNode) {
    guard unsafeNode.nodeType == .taskListItem || unsafeNode.nodeType == .item else {
      fatalError("Expected a list item but got a '\(unsafeNode.nodeType)' instead.")
    }
    self.init(
      isCompleted: unsafeNode.isTaskListItemChecked,
      children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:))
    )
  }
}

extension RawTableRow {
  fileprivate init(unsafeNode: UnsafeNode) {
    guard unsafeNode.nodeType == .tableRow || unsafeNode.nodeType == .tableHead else {
      fatalError("Expected a table row but got a '\(unsafeNode.nodeType)' instead.")
    }
    self.init(cells: unsafeNode.children.map(RawTableCell.init(unsafeNode:)))
  }
}

extension RawTableCell {
  fileprivate init(unsafeNode: UnsafeNode) {
    guard unsafeNode.nodeType == .tableCell else {
      fatalError("Expected a table cell but got a '\(unsafeNode.nodeType)' instead.")
    }
    self.init(content: unsafeNode.children.flatMap(InlineNode.inlineNodes(from:)))
  }
}

extension InlineNode {
  fileprivate static func inlineNodes(from unsafeNode: UnsafeNode) -> [InlineNode] {
    switch unsafeNode.nodeType {
    case .text:
      let text = unsafeNode.literal ?? ""
      return Self.splitStyledCodeSegments(from: text)
    case .softBreak:
      return [.softBreak]
    case .lineBreak:
      return [.lineBreak]
    case .code:
      let literal = unsafeNode.literal ?? ""
      if let styledContent = StyledCodeMarker.stripping(from: literal) {
        return [.styledCode(styledContent)]
      }
      return [.code(literal)]
    case .html:
      return [.html(unsafeNode.literal ?? "")]
    case .emphasis:
      let children = unsafeNode.children.flatMap(Self.inlineNodes(from:))
      return [.emphasis(children: children)]
    case .strong:
      let children = unsafeNode.children.flatMap(Self.inlineNodes(from:))
      return [.strong(children: children)]
    case .strikethrough:
      let children = unsafeNode.children.flatMap(Self.inlineNodes(from:))
      return [.strikethrough(children: children)]
    case .link:
      let children = unsafeNode.children.flatMap(Self.inlineNodes(from:))
      return [
        .link(
          destination: unsafeNode.url ?? "",
          children: children
        )
      ]
    case .image:
      let children = unsafeNode.children.flatMap(Self.inlineNodes(from:))
      return [
        .image(
          source: unsafeNode.url ?? "",
          children: children
        )
      ]
    default:
      assertionFailure("Unhandled node type '\(unsafeNode.nodeType)' in InlineNode.")
      return []
    }
  }

  private static func splitStyledCodeSegments(from text: String) -> [InlineNode] {
    let startMarker = StyledCodeMarker.start
    let endMarker = StyledCodeMarker.end

    guard text.contains(startMarker) else {
      return [.text(text)]
    }

    var nodes: [InlineNode] = []
    var searchStart = text.startIndex

    while let startRange = text.range(of: startMarker, range: searchStart..<text.endIndex) {
      if startRange.lowerBound > searchStart {
        let prefix = text[searchStart..<startRange.lowerBound]
        if !prefix.isEmpty {
          nodes.append(.text(String(prefix)))
        }
      }

      guard let endRange = text.range(of: endMarker, range: startRange.upperBound..<text.endIndex) else {
        // Unmatched start marker; treat the rest as plain text
        let remainder = text[startRange.lowerBound..<text.endIndex]
        if !remainder.isEmpty {
          nodes.append(.text(String(remainder)))
        }
        return nodes
      }

      let content = text[startRange.upperBound..<endRange.lowerBound]
      nodes.append(.styledCode(String(content)))

      searchStart = endRange.upperBound
    }

    if searchStart < text.endIndex {
      let suffix = text[searchStart..<text.endIndex]
      if !suffix.isEmpty {
        nodes.append(.text(String(suffix)))
      }
    }

    return nodes
  }
}

private typealias UnsafeNode = UnsafeMutablePointer<cmark_node>

extension UnsafeNode {
  fileprivate var nodeType: NodeType {
    let typeString = String(cString: cmark_node_get_type_string(self))
    guard let nodeType = NodeType(rawValue: typeString) else {
      fatalError("Unknown node type '\(typeString)' found.")
    }
    return nodeType
  }

  fileprivate var children: UnsafeNodeSequence {
    .init(cmark_node_first_child(self))
  }

  fileprivate var literal: String? {
    cmark_node_get_literal(self).map(String.init(cString:))
  }

  fileprivate var url: String? {
    cmark_node_get_url(self).map(String.init(cString:))
  }

  fileprivate var isTaskListItem: Bool {
    self.nodeType == .taskListItem
  }

  fileprivate var listType: cmark_list_type {
    cmark_node_get_list_type(self)
  }

  fileprivate var listStart: Int {
    Int(cmark_node_get_list_start(self))
  }

  fileprivate var isTaskListItemChecked: Bool {
    cmark_gfm_extensions_get_tasklist_item_checked(self)
  }

  fileprivate var isTightList: Bool {
    cmark_node_get_list_tight(self) != 0
  }

  fileprivate var fenceInfo: String? {
    cmark_node_get_fence_info(self).map(String.init(cString:))
  }

  fileprivate var headingLevel: Int {
    Int(cmark_node_get_heading_level(self))
  }

  fileprivate var tableColumns: Int {
    Int(cmark_gfm_extensions_get_table_columns(self))
  }

  fileprivate var tableAlignments: [RawTableColumnAlignment] {
    (0..<self.tableColumns).map { column in
      let ascii = cmark_gfm_extensions_get_table_alignments(self)[column]
      let scalar = UnicodeScalar(ascii)
      let character = Character(scalar)
      return .init(rawValue: character) ?? .none
    }
  }

  fileprivate static func parseMarkdown<ResultType>(
    _ markdown: String,
    body: (UnsafeNode) throws -> ResultType
  ) rethrows -> ResultType? {
    cmark_gfm_core_extensions_ensure_registered()

    // Create a Markdown parser and attach the GitHub syntax extensions

    let parser = cmark_parser_new(CMARK_OPT_DEFAULT)
    defer { cmark_parser_free(parser) }

    let extensionNames: Set<String>

    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
      extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]
    } else {
      extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist"]
    }

    for extensionName in extensionNames {
      guard let syntaxExtension = cmark_find_syntax_extension(extensionName) else {
        continue
      }
      cmark_parser_attach_syntax_extension(parser, syntaxExtension)
    }

    // Parse the Markdown document

    cmark_parser_feed(parser, markdown, markdown.utf8.count)

    guard let document = cmark_parser_finish(parser) else {
      return nil
    }

    defer { cmark_node_free(document) }
    return try body(document)
  }

  fileprivate static func makeDocument<ResultType>(
    _ blocks: [BlockNode],
    body: (UnsafeNode) throws -> ResultType
  ) rethrows -> ResultType? {
    cmark_gfm_core_extensions_ensure_registered()
    guard let document = cmark_node_new(CMARK_NODE_DOCUMENT) else { return nil }
    blocks.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(document, $0) }

    defer { cmark_node_free(document) }
    return try body(document)
  }

  fileprivate static func make(_ block: BlockNode) -> UnsafeNode? {
    switch block {
    case .blockquote(let children):
      guard let node = cmark_node_new(CMARK_NODE_BLOCK_QUOTE) else { return nil }
      children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .bulletedList(let isTight, let items):
      guard let node = cmark_node_new(CMARK_NODE_LIST) else { return nil }
      cmark_node_set_list_type(node, CMARK_BULLET_LIST)
      cmark_node_set_list_tight(node, isTight ? 1 : 0)
      items.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .numberedList(let isTight, let start, let items):
      guard let node = cmark_node_new(CMARK_NODE_LIST) else { return nil }
      cmark_node_set_list_type(node, CMARK_ORDERED_LIST)
      cmark_node_set_list_tight(node, isTight ? 1 : 0)
      cmark_node_set_list_start(node, Int32(start))
      items.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .taskList(let isTight, let items):
      guard let node = cmark_node_new(CMARK_NODE_LIST) else { return nil }
      cmark_node_set_list_type(node, CMARK_BULLET_LIST)
      cmark_node_set_list_tight(node, isTight ? 1 : 0)
      items.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .codeBlock(let fenceInfo, let content):
      guard let node = cmark_node_new(CMARK_NODE_CODE_BLOCK) else { return nil }
      if let fenceInfo {
        cmark_node_set_fence_info(node, fenceInfo)
      }
      cmark_node_set_literal(node, content)
      return node
    case .htmlBlock(let content):
      guard let node = cmark_node_new(CMARK_NODE_HTML_BLOCK) else { return nil }
      cmark_node_set_literal(node, content)
      return node
    case .paragraph(let content):
      guard let node = cmark_node_new(CMARK_NODE_PARAGRAPH) else { return nil }
      content.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .heading(let level, let content):
      guard let node = cmark_node_new(CMARK_NODE_HEADING) else { return nil }
      cmark_node_set_heading_level(node, Int32(level))
      content.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .table(let columnAlignments, let rows):
      guard let table = cmark_find_syntax_extension("table"),
        let node = cmark_node_new_with_ext(ExtensionNodeTypes.shared.CMARK_NODE_TABLE, table)
      else {
        return nil
      }
      cmark_gfm_extensions_set_table_columns(node, UInt16(columnAlignments.count))
      var alignments = columnAlignments.map { $0.rawValue.asciiValue! }
      cmark_gfm_extensions_set_table_alignments(node, UInt16(columnAlignments.count), &alignments)
      rows.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      if let header = cmark_node_first_child(node) {
        cmark_gfm_extensions_set_table_row_is_header(header, 1)
      }
      return node
    case .thematicBreak:
      guard let node = cmark_node_new(CMARK_NODE_THEMATIC_BREAK) else { return nil }
      return node
    }
  }

  fileprivate static func make(_ item: RawListItem) -> UnsafeNode? {
    guard let node = cmark_node_new(CMARK_NODE_ITEM) else { return nil }
    item.children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
    return node
  }

  fileprivate static func make(_ item: RawTaskListItem) -> UnsafeNode? {
    guard let tasklist = cmark_find_syntax_extension("tasklist"),
      let node = cmark_node_new_with_ext(CMARK_NODE_ITEM, tasklist)
    else {
      return nil
    }
    cmark_gfm_extensions_set_tasklist_item_checked(node, item.isCompleted)
    item.children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
    return node
  }

  fileprivate static func make(_ tableRow: RawTableRow) -> UnsafeNode? {
    guard let table = cmark_find_syntax_extension("table"),
      let node = cmark_node_new_with_ext(ExtensionNodeTypes.shared.CMARK_NODE_TABLE_ROW, table)
    else {
      return nil
    }
    tableRow.cells.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
    return node
  }

  fileprivate static func make(_ tableCell: RawTableCell) -> UnsafeNode? {
    guard let table = cmark_find_syntax_extension("table"),
      let node = cmark_node_new_with_ext(ExtensionNodeTypes.shared.CMARK_NODE_TABLE_CELL, table)
    else {
      return nil
    }
    tableCell.content.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
    return node
  }

  fileprivate static func make(_ inline: InlineNode) -> UnsafeNode? {
    switch inline {
    case .text(let content):
      guard let node = cmark_node_new(CMARK_NODE_TEXT) else { return nil }
      cmark_node_set_literal(node, content)
      return node
    case .softBreak:
      return cmark_node_new(CMARK_NODE_SOFTBREAK)
    case .lineBreak:
      return cmark_node_new(CMARK_NODE_LINEBREAK)
    case .code(let content):
      guard let node = cmark_node_new(CMARK_NODE_CODE) else { return nil }
      cmark_node_set_literal(node, content)
      return node
    case .styledCode(let content):
      guard let node = cmark_node_new(CMARK_NODE_CODE) else { return nil }
      cmark_node_set_literal(node, StyledCodeMarker.start + content + StyledCodeMarker.end)
      return node
    case .html(let content):
      guard let node = cmark_node_new(CMARK_NODE_HTML_INLINE) else { return nil }
      cmark_node_set_literal(node, content)
      return node
    case .emphasis(let children):
      guard let node = cmark_node_new(CMARK_NODE_EMPH) else { return nil }
      children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .strong(let children):
      guard let node = cmark_node_new(CMARK_NODE_STRONG) else { return nil }
      children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .strikethrough(let children):
      guard let strikethrough = cmark_find_syntax_extension("strikethrough"),
        let node = cmark_node_new_with_ext(
          ExtensionNodeTypes.shared.CMARK_NODE_STRIKETHROUGH, strikethrough)
      else {
        return nil
      }
      children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .link(let destination, let children):
      guard let node = cmark_node_new(CMARK_NODE_LINK) else { return nil }
      cmark_node_set_url(node, destination)
      children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    case .image(let source, let children):
      guard let node = cmark_node_new(CMARK_NODE_IMAGE) else { return nil }
      cmark_node_set_url(node, source)
      children.compactMap(UnsafeNode.make).forEach { cmark_node_append_child(node, $0) }
      return node
    }
  }
}

private enum NodeType: String {
  case document
  case blockquote = "block_quote"
  case list
  case item
  case codeBlock = "code_block"
  case htmlBlock = "html_block"
  case customBlock = "custom_block"
  case paragraph
  case heading
  case thematicBreak = "thematic_break"
  case text
  case softBreak = "softbreak"
  case lineBreak = "linebreak"
  case code
  case html = "html_inline"
  case customInline = "custom_inline"
  case emphasis = "emph"
  case strong
  case link
  case image
  case inlineAttributes = "attribute"
  case none = "NONE"
  case unknown = "<unknown>"

  // Extensions

  case strikethrough
  case table
  case tableHead = "table_header"
  case tableRow = "table_row"
  case tableCell = "table_cell"
  case taskListItem = "tasklist"
}

private struct UnsafeNodeSequence: Sequence {
  struct Iterator: IteratorProtocol {
    private var node: UnsafeNode?

    init(_ node: UnsafeNode?) {
      self.node = node
    }

    mutating func next() -> UnsafeNode? {
      guard let node else { return nil }
      defer { self.node = cmark_node_next(node) }
      return node
    }
  }

  private let node: UnsafeNode?

  init(_ node: UnsafeNode?) {
    self.node = node
  }

  func makeIterator() -> Iterator {
    .init(self.node)
  }
}

// Extension node types are not exported in `cmark_gfm_extensions`,
// so we need to look for them in the symbol table
private struct ExtensionNodeTypes {
  let CMARK_NODE_TABLE: cmark_node_type
  let CMARK_NODE_TABLE_ROW: cmark_node_type
  let CMARK_NODE_TABLE_CELL: cmark_node_type
  let CMARK_NODE_STRIKETHROUGH: cmark_node_type

  static let shared = ExtensionNodeTypes()

  private init() {
    func findNodeType(_ name: String, in handle: UnsafeMutableRawPointer!) -> cmark_node_type? {
      guard let symbol = dlsym(handle, name) else {
        return nil
      }
      return symbol.assumingMemoryBound(to: cmark_node_type.self).pointee
    }

    let handle = dlopen(nil, RTLD_LAZY)

    self.CMARK_NODE_TABLE = findNodeType("CMARK_NODE_TABLE", in: handle) ?? CMARK_NODE_NONE
    self.CMARK_NODE_TABLE_ROW = findNodeType("CMARK_NODE_TABLE_ROW", in: handle) ?? CMARK_NODE_NONE
    self.CMARK_NODE_TABLE_CELL =
      findNodeType("CMARK_NODE_TABLE_CELL", in: handle) ?? CMARK_NODE_NONE
    self.CMARK_NODE_STRIKETHROUGH =
      findNodeType("CMARK_NODE_STRIKETHROUGH", in: handle) ?? CMARK_NODE_NONE

    dlclose(handle)
  }
}
