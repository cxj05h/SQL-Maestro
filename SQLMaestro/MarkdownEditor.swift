import SwiftUI
import AppKit

/// Controller passed into `MarkdownEditor` to expose formatting actions to toolbars.
final class MarkdownEditorController: ObservableObject {
    fileprivate weak var coordinator: MarkdownEditor.Coordinator?

    func focus() {
        coordinator?.focusTextView()
    }

    func bold() { coordinator?.wrapSelection(prefix: "**", suffix: "**") }
    func italic() { coordinator?.wrapSelection(prefix: "*", suffix: "*") }
    func heading(level: Int) { coordinator?.applyHeading(level) }
    func bulletList() { coordinator?.applyList(prefix: "- ") }
    func numberedList() { coordinator?.applyNumberedList() }
    func inlineCode() { coordinator?.wrapSelection(prefix: "`", suffix: "`") }
    func codeBlock() { coordinator?.wrapSelection(prefix: "\n```\n", suffix: "\n```\n") }
    func blockQuote() { coordinator?.applyBlockQuote() }
    func horizontalRule() { coordinator?.insertHorizontalRule() }
    func link() { coordinator?.requestLinkInsertion(source: .toolbar) }
}

struct MarkdownEditor: NSViewRepresentable {
    struct LinkInsertion {
        let label: String
        let url: String
        let saveToTemplateLinks: Bool
    }

    enum LinkRequestSource {
        case keyboard
        case toolbar
    }

    @Binding var text: String
    var fontSize: CGFloat
    @ObservedObject var controller: MarkdownEditorController
    var onLinkRequested: ((_ selectedText: String, _ source: LinkRequestSource, _ completion: @escaping (LinkInsertion?) -> Void) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemTeal,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        context.coordinator.textView = textView
        controller.coordinator = context.coordinator
        textView.string = text
        context.coordinator.applyMarkdownStyles()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
            context.coordinator.applyMarkdownStyles()
        }
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
            context.coordinator.baseFont = NSFont.systemFont(ofSize: fontSize)
            context.coordinator.applyMarkdownStyles()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var suppressTextChangeCallback = false
        var baseFont: NSFont
        var currentSelection: NSRange = NSRange(location: 0, length: 0)

        private static let bulletRegex = try! NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+", options: [])
        private static let numberedRegex = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)([\\.)])\\s+", options: [])

        init(parent: MarkdownEditor) {
            self.parent = parent
            self.baseFont = NSFont.systemFont(ofSize: parent.fontSize)
        }

        func focusTextView() {
            textView?.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressTextChangeCallback else { return }
            guard let textView = textView else { return }
            currentSelection = textView.selectedRange()
            parent.text = textView.string
            applyMarkdownStyles()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if let event = NSApp.currentEvent,
               event.type == .keyDown,
               event.modifierFlags.contains(.command),
               let character = event.charactersIgnoringModifiers?.lowercased() {
                switch character {
                case "k":
                    requestLinkInsertion(source: .keyboard)
                    return true
                case "b":
                    wrapSelection(prefix: "**", suffix: "**")
                    return true
                case "i":
                    wrapSelection(prefix: "*", suffix: "*")
                    return true
                case "u":
                    wrapSelection(prefix: "<u>", suffix: "</u>")
                    return true
                default:
                    break
                }
            }
            switch commandSelector {
            case #selector(NSTextView.deleteForward(_:)),
                 #selector(NSTextView.deleteBackward(_:)):
                DispatchQueue.main.async { [weak self] in
                    self?.applyMarkdownStyles()
                }
                return false
            case #selector(NSTextView.insertNewline(_:)):
                if handleNewline(in: textView) {
                    return true
                }
                DispatchQueue.main.async { [weak self] in
                    self?.applyMarkdownStyles()
                }
                return false
            default:
                break
            }
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, tv == textView else { return }
            currentSelection = tv.selectedRange()
            applyMarkdownStyles()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let event = NSApp.currentEvent, event.modifierFlags.contains(.command) else {
                return false
            }
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            }
            if let string = link as? String, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let replacementString = replacementString,
               replacementString == "\u{0}" {
                return false
            }
            return true
        }

        func wrapSelection(prefix: String, suffix: String) {
            guard let textView = textView else { return }
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let safeLocation = max(0, min(selectedRange.location, nsString.length))
            let safeLength = max(0, min(selectedRange.length, nsString.length - safeLocation))
            let range = NSRange(location: safeLocation, length: safeLength)
            let selectedText = nsString.substring(with: range)
            let newString = (prefix + selectedText + suffix)

            let caret = prefix.count + selectedText.count
            replace(range: range, with: newString, caretPosition: range.location + caret)
        }

        private func handleNewline(in textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }
            let nsString = storage.string as NSString
            let selection = textView.selectedRange()
            var lineRange = nsString.lineRange(for: selection)
            if selection.location == nsString.length {
                // If cursor at end of document ensure range covers last line
                lineRange = NSRange(location: lineRange.location, length: nsString.length - lineRange.location)
            }
            var lineString = nsString.substring(with: lineRange)
            let hasTrailingNewline = lineString.hasSuffix("\n")
            if hasTrailingNewline { lineString.removeLast() }
            let lineNSString = lineString as NSString
            let caretInLine = selection.location - lineRange.location
            let caretAtLineEnd = caretInLine >= lineNSString.length

            func exitList(prefixLength: Int) {
                let prefixRangeInDoc = NSRange(location: lineRange.location, length: prefixLength)
                storage.replaceCharacters(in: prefixRangeInDoc, with: "")
                parent.text = storage.string
                let newLocation = max(selection.location - prefixLength, lineRange.location)
                textView.setSelectedRange(NSRange(location: newLocation, length: 0))
                currentSelection = textView.selectedRange()
                applyMarkdownStyles()
            }

            // Ordered lists
            if let match = Coordinator.numberedRegex.firstMatch(in: lineString, options: [], range: NSRange(location: 0, length: lineNSString.length)) {
                let prefixLength = match.range.length
                let numberString = lineNSString.substring(with: match.range(at: 2))
                let delimiter = lineNSString.substring(with: match.range(at: 3))
                let indent = lineNSString.substring(with: match.range(at: 1))
                let remainderRange = NSRange(location: prefixLength, length: max(0, lineNSString.length - prefixLength))
                let remainder = remainderRange.length > 0 ? lineNSString.substring(with: remainderRange).trimmingCharacters(in: .whitespaces) : ""

                if remainder.isEmpty && caretAtLineEnd {
                    exitList(prefixLength: prefixLength)
                    return false
                }

                let currentNumber = Int(numberString) ?? 0
                let nextNumber = max(currentNumber + 1, 1)
                let insertion = "\n" + indent + "\(nextNumber)\(delimiter) "
                replace(range: selection, with: insertion, caretPosition: selection.location + insertion.count)
                return true
            }

            // Bullet lists
            if let match = Coordinator.bulletRegex.firstMatch(in: lineString, options: [], range: NSRange(location: 0, length: lineNSString.length)) {
                let prefixLength = match.range.length
                let marker = lineNSString.substring(with: match.range(at: 2))
                let indent = lineNSString.substring(with: match.range(at: 1))
                let remainderRange = NSRange(location: prefixLength, length: max(0, lineNSString.length - prefixLength))
                let remainder = remainderRange.length > 0 ? lineNSString.substring(with: remainderRange).trimmingCharacters(in: .whitespaces) : ""

                if remainder.isEmpty && caretAtLineEnd {
                    exitList(prefixLength: prefixLength)
                    return false
                }

                let insertion = "\n" + indent + "\(marker) "
                replace(range: selection, with: insertion, caretPosition: selection.location + insertion.count)
                return true
            }

            return false
        }

        func applyHeading(_ level: Int) {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            var range = textView.selectedRange()
            if range.location == NSNotFound { range = NSRange(location: nsString.length, length: 0) }
            let lineRange = nsString.lineRange(for: range)
            let line = nsString.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = String(repeating: "#", count: max(1, min(6, level))) + " "
            let updatedLine: String
            if trimmed.hasPrefix("#") {
                let stripped = trimmed.drop(while: { $0 == "#" || $0 == " " })
                updatedLine = hashes + stripped
            } else {
                updatedLine = hashes + trimmed
            }
            let caret = lineRange.location + NSString(string: updatedLine).length
            replace(range: lineRange, with: updatedLine, caretPosition: caret)
        }

        func applyList(prefix: String) {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            var range = textView.selectedRange()
            if range.location == NSNotFound { range = NSRange(location: nsString.length, length: 0) }
            let lineRange = nsString.lineRange(for: range)
            let lines = nsString.substring(with: lineRange).components(separatedBy: "\n")
            let transformed = lines.map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return line }
                if trimmed.hasPrefix(prefix.trimmingCharacters(in: .whitespaces)) {
                    return line
                }
                return prefix + trimmed
            }.joined(separator: "\n")
            let caret = lineRange.location + NSString(string: transformed).length
            replace(range: lineRange, with: transformed, caretPosition: caret)
        }

        func applyNumberedList() {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            var range = textView.selectedRange()
            if range.location == NSNotFound { range = NSRange(location: nsString.length, length: 0) }
            let lineRange = nsString.lineRange(for: range)
            let lines = nsString.substring(with: lineRange).components(separatedBy: "\n")
            var index = 1
            let transformed = lines.map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                defer { index += 1 }
                guard !trimmed.isEmpty else { index -= 1; return line }
                if let match = trimmed.range(of: "^\\d+\\. ", options: .regularExpression), match.lowerBound == trimmed.startIndex {
                    return line
                }
                return "\(index). " + trimmed
            }.joined(separator: "\n")
            let caret = lineRange.location + NSString(string: transformed).length
            replace(range: lineRange, with: transformed, caretPosition: caret)
        }

        func applyBlockQuote() {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            var range = textView.selectedRange()
            if range.location == NSNotFound { range = NSRange(location: nsString.length, length: 0) }
            let lineRange = nsString.lineRange(for: range)
            let lines = nsString.substring(with: lineRange).components(separatedBy: "\n")
            let transformed = lines.map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return line }
                if trimmed.hasPrefix("> ") {
                    return line
                }
                return "> " + trimmed
            }.joined(separator: "\n")
            let caret = lineRange.location + NSString(string: transformed).length
            replace(range: lineRange, with: transformed, caretPosition: caret)
        }

        func insertHorizontalRule() {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            var range = textView.selectedRange()
            if range.location == NSNotFound { range = NSRange(location: nsString.length, length: 0) }
            let insertion = "\n---\n"
            replace(range: range, with: insertion, caretPosition: range.location + insertion.count)
        }

        func requestLinkInsertion(source: LinkRequestSource) {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            let range = textView.selectedRange()
            let selected = range.length > 0 ? nsString.substring(with: range) : ""
            guard let handler = parent.onLinkRequested else { return }
            handler(selected, source) { [weak self] insertion in
                guard let self else { return }
                guard let insertion else { return }
                let label = insertion.label.isEmpty ? insertion.url : insertion.label
                let markdown = "[\(label)](\(insertion.url))"
                let position = range.location + markdown.count
                self.replace(range: range, with: markdown, caretPosition: position)
                if let textView = self.textView {
                    textView.setSelectedRange(NSRange(location: position, length: 0))
                }
            }
        }

        private func replace(range: NSRange, with string: String, caretPosition: Int) {
            guard let textView = textView else { return }
            guard let storage = textView.textStorage else { return }
            suppressTextChangeCallback = true
            storage.replaceCharacters(in: range, with: string)
            suppressTextChangeCallback = false
            let newText = storage.string
            parent.text = newText
            textView.string = newText
            let safeCaret = max(0, min(caretPosition, newText.count))
            textView.setSelectedRange(NSRange(location: safeCaret, length: 0))
            currentSelection = textView.selectedRange()
            applyMarkdownStyles()
        }

        func applyMarkdownStyles() {
            guard let textView = textView, let storage = textView.textStorage else { return }
            currentSelection = textView.selectedRange()
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor
            ]
            storage.setAttributes(baseAttributes, range: fullRange)

            MarkdownStyler.apply(to: storage, baseFont: baseFont, selectedRange: currentSelection)
            storage.endEditing()
        }
    }
}

private enum MarkdownStyler {
    static func apply(to storage: NSTextStorage, baseFont: NSFont, selectedRange: NSRange) {
        let string = storage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)

        applyCodeBlocks(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)
        applyInlineCode(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)
        applyHeadings(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)
        applyBold(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)
        applyItalic(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)
        applyBlockQuotes(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)
        applyHorizontalRules(storage: storage, string: string, selectedRange: selectedRange)
        applyLists(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)

        // detect markdown links and underline them
        let pattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            regex.enumerateMatches(in: string as String, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                guard match.numberOfRanges >= 3 else { return }

                let labelRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                let urlString = string.substring(with: urlRange).trimmingCharacters(in: .whitespacesAndNewlines)

                if let url = URL(string: urlString) {
                    storage.addAttributes([
                        .link: url,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.systemBlue
                    ], range: labelRange)
                }

                let punctuationColor = NSColor.secondaryLabelColor

                if match.range.location < string.length {
                    storage.addAttribute(.foregroundColor, value: punctuationColor, range: NSRange(location: match.range.location, length: 1))
                }
                let closingBracketLocation = labelRange.location + labelRange.length
                if closingBracketLocation < string.length {
                    storage.addAttribute(.foregroundColor, value: punctuationColor, range: NSRange(location: closingBracketLocation, length: 1))
                }
                let openParenLocation = closingBracketLocation + 1
                if openParenLocation < string.length {
                    storage.addAttribute(.foregroundColor, value: punctuationColor, range: NSRange(location: openParenLocation, length: 1))
                }
                let closingParenLocation = match.range.location + match.range.length - 1
                if closingParenLocation < string.length {
                    storage.addAttribute(.foregroundColor, value: punctuationColor, range: NSRange(location: closingParenLocation, length: 1))
                }

                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: urlRange)
            }
        }
    }

    private static func applyCodeBlocks(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) {
        let pattern = "```(.*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
        let matches = regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length))
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let contentRange = match.range(at: 1)
            storage.addAttributes([
                .font: codeFont,
                .foregroundColor: NSColor.systemOrange,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.08)
            ], range: contentRange)

            let startMarker = NSRange(location: match.range.location, length: min(3, match.range.length))
            let endMarker = NSRange(location: max(match.range.location + match.range.length - 3, match.range.location), length: min(3, match.range.length))
            let reveal = intersects(contentRange, with: selectedRange) || intersects(startMarker, with: selectedRange) || intersects(endMarker, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: startMarker, reveal: reveal)
            setMarkerVisibility(storage: storage, markerRange: endMarker, reveal: reveal)
        }
    }

    private static func applyInlineCode(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) {
        let pattern = "`[^`]+`"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            guard match.range.length >= 2 else { continue }
            let contentRange = NSRange(location: match.range.location + 1, length: match.range.length - 2)
            storage.addAttributes([
                .font: codeFont,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12),
                .foregroundColor: NSColor.systemOrange
            ], range: contentRange)

            let startMarker = NSRange(location: match.range.location, length: 1)
            let endMarker = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            let reveal = intersects(contentRange, with: selectedRange) || intersects(startMarker, with: selectedRange) || intersects(endMarker, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: startMarker, reveal: reveal)
            setMarkerVisibility(storage: storage, markerRange: endMarker, reveal: reveal)
        }
    }

    private static func applyHeadings(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) {
        let pattern = "^(#{1,4})\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            let hashesRange = match.range(at: 1)
            let textRange = match.range(at: 2)
            let level = hashesRange.length
            let fontSize = baseFont.pointSize + CGFloat((5 - level) * 2)
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            storage.addAttributes([
                .font: font,
                .foregroundColor: NSColor.systemTeal
            ], range: textRange)

            let reveal = intersects(textRange, with: selectedRange) || intersects(hashesRange, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: hashesRange, reveal: reveal)
        }
    }

    private static func applyBold(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) {
        let pattern = "\\*\\*(.+?)\\*\\*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            guard match.range.length >= 4 else { continue }
            let contentRange = match.range(at: 1)
            let font = NSFont.boldSystemFont(ofSize: baseFont.pointSize)
            storage.addAttribute(.font, value: font, range: contentRange)

            let startMarker = NSRange(location: match.range.location, length: 2)
            let endMarker = NSRange(location: match.range.location + match.range.length - 2, length: 2)
            let reveal = intersects(contentRange, with: selectedRange) || intersects(startMarker, with: selectedRange) || intersects(endMarker, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: startMarker, reveal: reveal)
            setMarkerVisibility(storage: storage, markerRange: endMarker, reveal: reveal)
        }
    }

    private static func applyItalic(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) {
        let pattern = "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            guard match.range.length >= 3 else { continue }
            let contentRange = match.range(at: 1)
            let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italicFont, range: contentRange)

            let startMarker = NSRange(location: match.range.location, length: 1)
            let endMarker = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            let reveal = intersects(contentRange, with: selectedRange) || intersects(startMarker, with: selectedRange) || intersects(endMarker, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: startMarker, reveal: reveal)
            setMarkerVisibility(storage: storage, markerRange: endMarker, reveal: reveal)
        }
    }

    private static func applyBlockQuotes(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) {
        let pattern = "^>\\s?.*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            let lineRange = match.range
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = 24
            paragraphStyle.headIndent = 24
            paragraphStyle.paragraphSpacing = 6
            paragraphStyle.paragraphSpacingBefore = 4

            storage.addAttributes([
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.06)
            ], range: lineRange)

            // Hide leading '>' marker when not editing
            let lineString = string.substring(with: lineRange) as NSString
            let markerLength = lineString.length > 1 && lineString.character(at: 1) == 32 ? 2 : 1
            let markerRange = NSRange(location: lineRange.location, length: min(markerLength, lineRange.length))
            let contentRange = NSRange(location: markerRange.location + markerRange.length, length: max(0, lineRange.length - markerRange.length))
            let reveal = intersects(contentRange, with: selectedRange) || intersects(markerRange, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: markerRange, reveal: reveal)
        }
    }

    private static func applyHorizontalRules(storage: NSTextStorage, string: NSString, selectedRange: NSRange) {
        let pattern = "^---$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            let reveal = intersects(match.range, with: selectedRange)
            let color = NSColor.systemGray
            storage.addAttributes([
                .foregroundColor: reveal ? color : NSColor.clear,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color
            ], range: match.range)
        }
    }

    private static func applyLists(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) {
        let bulletPattern = "^(\\s*[-\\*+])(\\s+)"
        let numberPattern = "^(\\s*)(\\d+)([\\.)])(\\s+)"

        if let bulletRegex = try? NSRegularExpression(pattern: bulletPattern, options: [.anchorsMatchLines]) {
            bulletRegex.enumerateMatches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) { match, _, _ in
                guard let match else { return }
                let prefixRange = match.range(at: 1)
                let spacingRange = match.range(at: 2)
                let paragraphRange = string.paragraphRange(for: match.range)
                let list = NSTextList(markerFormat: .disc, options: 0)
                storage.addAttribute(.paragraphStyle, value: markdownParagraphStyle(indentation: 24, textList: list), range: paragraphRange)

                let contentStart = match.range.location + match.range.length
                let contentLength = max(0, paragraphRange.location + paragraphRange.length - contentStart)
                let contentRange = NSRange(location: contentStart, length: contentLength)
                let reveal = intersects(contentRange, with: selectedRange) || intersects(prefixRange, with: selectedRange) || intersects(spacingRange, with: selectedRange)
                setMarkerVisibility(storage: storage, markerRange: prefixRange, reveal: reveal)
                setMarkerVisibility(storage: storage, markerRange: spacingRange, reveal: reveal)
            }
        }

        if let numberRegex = try? NSRegularExpression(pattern: numberPattern, options: [.anchorsMatchLines]) {
            numberRegex.enumerateMatches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) { match, _, _ in
                guard let match else { return }
                let indentRange = match.range(at: 1)
                let numberRange = match.range(at: 2)
                let delimiterRange = match.range(at: 3)
                let spacingRange = match.range(at: 4)
                let paragraphRange = string.paragraphRange(for: match.range)
                let list = NSTextList(markerFormat: .decimal, options: 0)
                storage.addAttribute(.paragraphStyle, value: markdownParagraphStyle(indentation: 28, textList: list), range: paragraphRange)

                let contentStart = match.range.location + match.range.length
                let contentLength = max(0, paragraphRange.location + paragraphRange.length - contentStart)
                let contentRange = NSRange(location: contentStart, length: contentLength)
                let markersRange = NSRange(location: match.range.location, length: match.range.length - spacingRange.length)
                let reveal = intersects(contentRange, with: selectedRange) || intersects(markersRange, with: selectedRange)
                setMarkerVisibility(storage: storage, markerRange: indentRange, reveal: reveal)
                setMarkerVisibility(storage: storage, markerRange: numberRange, reveal: true)
                setMarkerVisibility(storage: storage, markerRange: delimiterRange, reveal: reveal)
                setMarkerVisibility(storage: storage, markerRange: spacingRange, reveal: reveal)
            }
        }
    }

    private static func markdownParagraphStyle(indentation: CGFloat, textList: NSTextList? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indentation
        style.headIndent = indentation
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 2
        if let list = textList {
            style.textLists = [list]
        }
        return style
    }

    private static func intersects(_ range: NSRange, with selection: NSRange) -> Bool {
        if range.length == 0 {
            return selection.length == 0 ? range.location == selection.location : NSLocationInRange(range.location, selection)
        }
        if selection.length == 0 {
            return NSLocationInRange(selection.location, range)
        }
        return NSIntersectionRange(range, selection).length > 0
    }

    private static func setMarkerVisibility(storage: NSTextStorage, markerRange: NSRange?, reveal: Bool) {
        guard let markerRange, markerRange.length > 0 else { return }
        let color = reveal ? NSColor.secondaryLabelColor : NSColor.clear
        storage.addAttribute(.foregroundColor, value: color, range: markerRange)
    }
}
