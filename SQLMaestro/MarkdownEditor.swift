import SwiftUI
import AppKit

/// Controller passed into `MarkdownEditor` to expose formatting actions to toolbars.
final class MarkdownEditorController: ObservableObject {
    fileprivate weak var coordinator: MarkdownEditor.Coordinator?

    func focus() { coordinator?.focusTextView() }
    func bold() { coordinator?.wrapSelection(prefix: "**", suffix: "**") }
    func italic() { coordinator?.wrapSelection(prefix: "*", suffix: "*") }
    func heading(level: Int) { coordinator?.applyHeading(level) }
    func bulletList() { coordinator?.toggleBulletList() }
    func numberedList() { coordinator?.toggleNumberedList() }
    func inlineCode() { coordinator?.wrapSelection(prefix: "`", suffix: "`") }
    func codeBlock() { coordinator?.wrapSelection(prefix: "\n```\n", suffix: "\n```\n") }
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
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        context.coordinator.textView = textView
        controller.coordinator = context.coordinator
        textView.string = text

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            context.coordinator.applyExternalTextChange(text)
        }
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var suppressTextDidChange = false

        private static let bulletRegex = try! NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+", options: [.anchorsMatchLines])
        private static let numberedRegex = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)([\\.)])\\s+", options: [.anchorsMatchLines])
        private static let bulletSanitizeRegex = try! NSRegularExpression(pattern: "^(\\s*)•\\s+", options: [.anchorsMatchLines])
        private static let blockquoteSanitizeRegex = try! NSRegularExpression(pattern: "^(\\s*)>\\s?", options: [.anchorsMatchLines])

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        func focusTextView() {
            textView?.window?.makeFirstResponder(textView)
        }

        func applyExternalTextChange(_ newValue: String) {
            guard let textView else { return }
            let sanitized = sanitizeMarkdown(newValue)
            replaceEntireText(with: sanitized)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !suppressTextDidChange, let textView else { return }
            let sanitized = sanitizeMarkdown(textView.string)
            if sanitized != textView.string {
                replaceEntireText(with: sanitized)
            } else {
                parent.text = sanitized
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if let event = NSApp.currentEvent,
               event.type == .keyDown,
               event.modifierFlags.contains(.command),
               let character = event.charactersIgnoringModifiers?.lowercased() {
                switch character {
                case "k":
                    if !event.modifierFlags.contains(.shift) {
                        requestLinkInsertion(source: .keyboard)
                        return true
                    }
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
            case #selector(NSTextView.insertNewline(_:)):
                if handleNewline(in: textView) { return true }
            default:
                break
            }
            return false
        }

        // MARK: Formatting helpers

        func wrapSelection(prefix: String, suffix: String) {
            guard let textView else { return }
            var range = textView.selectedRange()
            let ns = textView.string as NSString
            if range.location == NSNotFound {
                range = NSRange(location: ns.length, length: 0)
            }
            let safeLocation = max(0, min(range.location, ns.length))
            let safeLength = max(0, min(range.length, ns.length - safeLocation))
            let coreRange = NSRange(location: safeLocation, length: safeLength)
            let selected = coreRange.length > 0 ? ns.substring(with: coreRange) : ""
            let wrapped = prefix + selected + suffix
            let caretLocation = coreRange.location + (prefix as NSString).length
            let caretLength = selected.utf16.count
            replace(range: coreRange, with: wrapped, newSelection: NSRange(location: caretLocation, length: caretLength))
        }

        func applyHeading(_ level: Int) {
            guard let textView else { return }
            var range = textView.selectedRange()
            let ns = textView.string as NSString
            if range.location == NSNotFound {
                range = NSRange(location: ns.length, length: 0)
            }
            let lineRange = ns.lineRange(for: range)
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = String(repeating: "#", count: max(1, min(6, level))) + " "
            let updated: String
            if trimmed.hasPrefix("#") {
                let stripped = trimmed.drop(while: { $0 == "#" || $0 == " " })
                updated = hashes + stripped
            } else {
                updated = hashes + trimmed
            }
            replace(range: lineRange, with: updated, newSelection: NSRange(location: lineRange.location + updated.utf16.count, length: 0))
        }

        func toggleBulletList() {
            guard let textView else { return }
            applyList(using: "- ", numbering: false)
        }

        func toggleNumberedList() {
            guard let textView else { return }
            applyList(using: "1. ", numbering: true)
        }

        private func applyList(using prefix: String, numbering: Bool) {
            guard let textView else { return }
            var range = textView.selectedRange()
            let ns = textView.string as NSString
            if range.location == NSNotFound {
                range = NSRange(location: ns.length, length: 0)
            }
            let lineRange = ns.lineRange(for: range)
           let lines = ns.substring(with: lineRange).components(separatedBy: "\n")
            var number = 1
            let transformed: [String] = lines.map { line in
                let leading = line.prefix { $0.isWhitespace }
                let body = line.drop { $0.isWhitespace }
                guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                var content = String(body).stripListPrefix()
                if numbering {
                    let formatted = "\(number). \(content)"
                    number += 1
                    return leading + formatted
                } else {
                    content = content.isEmpty ? "" : content
                    return leading + "- \(content)"
                }
            }
            let joined = transformed.joined(separator: "\n")
            replace(range: lineRange, with: joined, newSelection: NSRange(location: lineRange.location, length: joined.utf16.count))
        }

        func requestLinkInsertion(source: LinkRequestSource) {
            guard let textView else { return }
            guard let handler = parent.onLinkRequested else { return }
            let ns = textView.string as NSString
            let range = textView.selectedRange()
            let selected = range.length > 0 ? ns.substring(with: range) : ""
            handler(selected, source) { [weak self] insertion in
                guard let self, let insertion else { return }
                let label = insertion.label.isEmpty ? insertion.url : insertion.label
                let markdown = "[\(label)](\(insertion.url))"
                self.replace(range: range, with: markdown, newSelection: NSRange(location: range.location + markdown.utf16.count, length: 0))
            }
        }

        // MARK: - Text operations

       private func insert(text: String) {
           guard let textView else { return }
           let range = textView.selectedRange()
           replace(range: range, with: text, newSelection: NSRange(location: range.location + text.utf16.count, length: 0))
       }

        private func replace(range: NSRange, with string: String, newSelection: NSRange) {
            guard let textView else { return }
            suppressTextDidChange = true
            textView.textStorage?.replaceCharacters(in: range, with: string)
            textView.setSelectedRange(newSelection)
            suppressTextDidChange = false
            let sanitized = sanitizeMarkdown(textView.string)
            if sanitized != textView.string {
                replaceEntireText(with: sanitized, selection: newSelection)
            } else {
                parent.text = sanitized
            }
        }

        private func replaceEntireText(with string: String, selection: NSRange? = nil) {
            guard let textView else { return }
            suppressTextDidChange = true
            let currentSelection = selection ?? textView.selectedRange()
            textView.string = string
            let nsString = string as NSString
            let safeLocation = min(currentSelection.location, nsString.length)
            let safeLength = min(currentSelection.length, max(0, nsString.length - safeLocation))
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            suppressTextDidChange = false
            parent.text = string
        }

        // MARK: - Formatting logic

        private func handleNewline(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let line = ns.substring(with: lineRange)
            let lineNSString = line as NSString
            let caretInLine = selection.location - lineRange.location
            let caretAtLineEnd = caretInLine >= lineNSString.length

            // Ordered lists
            if let match = Coordinator.numberedRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: lineNSString.length)) {
                let prefixLength = match.range.length
                let indent = lineNSString.substring(with: match.range(at: 1))
                let numberString = lineNSString.substring(with: match.range(at: 2))
                let delimiter = lineNSString.substring(with: match.range(at: 3))
                let remainderRange = NSRange(location: prefixLength, length: max(0, lineNSString.length - prefixLength))
                let remainder = remainderRange.length > 0 ? lineNSString.substring(with: remainderRange).trimmingCharacters(in: .whitespaces) : ""
                let prefixRangeInDoc = NSRange(location: lineRange.location, length: prefixLength)

                if remainder.isEmpty && caretAtLineEnd {
                    replace(range: prefixRangeInDoc, with: "", newSelection: NSRange(location: prefixRangeInDoc.location, length: 0))
                    insert(text: "\n")
                    return true
                }

                let currentNumber = Int(numberString) ?? 0
                let nextNumber = max(currentNumber + 1, 1)
                let insertion = "\n" + indent + "\(nextNumber)\(delimiter) "
                insert(text: insertion)
                return true
            }

            // Bulleted lists
            if let match = Coordinator.bulletRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: lineNSString.length)) {
                let prefixLength = match.range.length
                let indent = lineNSString.substring(with: match.range(at: 1))
                let remainderRange = NSRange(location: prefixLength, length: max(0, lineNSString.length - prefixLength))
                let remainder = remainderRange.length > 0 ? lineNSString.substring(with: remainderRange).trimmingCharacters(in: .whitespaces) : ""
                let prefixRangeInDoc = NSRange(location: lineRange.location, length: prefixLength)

                if remainder.isEmpty && caretAtLineEnd {
                    replace(range: prefixRangeInDoc, with: "", newSelection: NSRange(location: prefixRangeInDoc.location, length: 0))
                    insert(text: "\n")
                    return true
                }

                let insertion = "\n" + indent + "- "
                insert(text: insertion)
                return true
            }

            return false
        }

        private func sanitizeMarkdown(_ string: String) -> String {
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            var sanitized = Coordinator.bulletSanitizeRegex.stringByReplacingMatches(in: string, options: [], range: fullRange, withTemplate: "$1- ")
            let updatedRange = NSRange(location: 0, length: (sanitized as NSString).length)
            sanitized = Coordinator.blockquoteSanitizeRegex.stringByReplacingMatches(in: sanitized, options: [], range: updatedRange, withTemplate: "$1")
            return sanitized
        }
    }
}

private extension String {
    func stripListPrefix() -> String {
        var result = self
        if result.hasPrefix("- ") { result.removeFirst(2) }
        else if result.hasPrefix("* ") { result.removeFirst(2) }
        else if result.hasPrefix("+ ") { result.removeFirst(2) }
        else if let match = result.firstIndex(of: "."), result[..<match].allSatisfy({ $0.isNumber }) {
            let after = result.index(after: match)
            result = String(result[after...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
