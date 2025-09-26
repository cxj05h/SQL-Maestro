import SwiftUI
import AppKit
import cmark_gfm

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
        textView.allowsUndo = false
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
        context.coordinator.installUndoMonitorIfNeeded(for: textView)
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
        private var undoStack: [(text: String, selection: NSRange)] = []
        private var undoMonitor: Any?

        private static let bulletRegex = try! NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+", options: [])
        private static let numberedRegex = try! NSRegularExpression(pattern: "^(\\s*)(\\d+)([\\.)])\\s+", options: [])
        private static let bulletSanitizeRegex = try! NSRegularExpression(pattern: "^(\\s*)•\\s+", options: [.anchorsMatchLines])

        init(parent: MarkdownEditor) {
            self.parent = parent
            self.baseFont = NSFont.systemFont(ofSize: parent.fontSize)
        }

        deinit {
            removeUndoMonitor()
        }

        func focusTextView() {
            textView?.window?.makeFirstResponder(textView)
        }

        func installUndoMonitorIfNeeded(for textView: NSTextView) {
            removeUndoMonitor()
            undoMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.type == .keyDown,
                      event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers?.lowercased() == "z",
                      NSApp.keyWindow?.firstResponder === textView else {
                    return event
                }
                guard !self.undoStack.isEmpty else {
                    return event
                }
                self.performUndo()
                return nil
            }
        }

        private func removeUndoMonitor() {
            if let monitor = undoMonitor {
                NSEvent.removeMonitor(monitor)
                undoMonitor = nil
            }
        }

        private func performUndo() {
            guard let textView = textView else { return }
            if let previous = undoStack.popLast() {
                LOG("Markdown undo", ctx: ["prevLength": "\(previous.text.count)"])
                let nsText = previous.text as NSString
                suppressTextChangeCallback = true
                textView.string = previous.text
                suppressTextChangeCallback = false
                parent.text = previous.text
                let clampedLocation = min(previous.selection.location, nsText.length)
                let clampedLength = min(previous.selection.length, max(0, nsText.length - clampedLocation))
                let selection = NSRange(location: clampedLocation, length: clampedLength)
                textView.setSelectedRange(selection)
                currentSelection = selection
                applyMarkdownStyles()
                textView.scrollRangeToVisible(selection)
            } else {
                NSSound.beep()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressTextChangeCallback else { return }
            guard let textView = textView else { return }
            let selection = textView.selectedRange()
            let sanitized = sanitizeMarkdown(textView.string)
            if sanitized != textView.string {
                suppressTextChangeCallback = true
                textView.string = sanitized
                textView.setSelectedRange(selection)
                suppressTextChangeCallback = false
            }
            parent.text = sanitized
            currentSelection = textView.selectedRange()
            applyMarkdownStyles()
            textView.scrollRangeToVisible(currentSelection)
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
            case Selector(("undo:")):
                performUndo()
                return true
            case #selector(NSStandardKeyBindingResponding.moveWordRightAndModifySelection(_:)),
                 #selector(NSStandardKeyBindingResponding.moveWordLeftAndModifySelection(_:)):
                LOG("MarkdownEditor word selection", ctx: ["selector": NSStringFromSelector(commandSelector)])
                return false
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

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange, toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
            guard newSelectedCharRange.location != NSNotFound, newSelectedCharRange.length > 0 else {
                return newSelectedCharRange
            }
            let nsString = textView.string as NSString
            guard NSMaxRange(newSelectedCharRange) <= nsString.length else { return newSelectedCharRange }
            let substring = nsString.substring(with: newSelectedCharRange)
            if substring.hasSuffix("\n") {
                let trimmed = substring.dropLast()
                if !trimmed.contains("\n") {
                    return NSRange(location: newSelectedCharRange.location, length: max(0, newSelectedCharRange.length - 1))
                }
            }
            return newSelectedCharRange
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
            if let tv = textView as NSTextView? {
                let current = tv.string
                let selection = tv.selectedRange()
                if undoStack.last?.text != current {
                    undoStack.append((current, selection))
                    if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
                }
            }
            return true
        }

        func wrapSelection(prefix: String, suffix: String) {
            guard let textView = textView else { return }
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let safeLocation = max(0, min(selectedRange.location, nsString.length))
            let safeLength = max(0, min(selectedRange.length, nsString.length - safeLocation))
            let originalRange = NSRange(location: safeLocation, length: safeLength)
            var coreRange = originalRange

            var newlineScalars: [UnicodeScalar] = []
            while coreRange.length > 0 {
                let lastIndex = coreRange.location + coreRange.length - 1
                let char = nsString.character(at: lastIndex)
                guard let scalar = UnicodeScalar(char), CharacterSet.newlines.contains(scalar) else { break }
                newlineScalars.append(scalar)
                coreRange.length -= 1
            }

            let trailingNewlines = String(newlineScalars.reversed().map(Character.init))
            let coreText = coreRange.length > 0 ? nsString.substring(with: coreRange) : ""
            let prefixLength = (prefix as NSString).length
            let suffixLength = (suffix as NSString).length

            func replaceWith(range: NSRange, text: String, caretOffset: Int) {
                replace(range: range, with: text + trailingNewlines, caretPosition: range.location + caretOffset)
                LOG("Markdown wrap", ctx: [
                    "prefix": prefix,
                    "suffix": suffix,
                    "selection": "\(range.location):\(range.length)",
                    "resultLength": "\(text.count + trailingNewlines.count)"
                ])
            }

            if originalRange.length > 0 {
                let nsLength = nsString.length
                var prefixRange: NSRange?
                var suffixRange: NSRange?

                if coreRange.length >= prefixLength + suffixLength,
                   coreRange.length >= prefixLength,
                   nsString.substring(with: NSRange(location: coreRange.location, length: prefixLength)) == prefix,
                   nsString.substring(with: NSRange(location: coreRange.location + coreRange.length - suffixLength, length: suffixLength)) == suffix {
                    prefixRange = NSRange(location: coreRange.location, length: prefixLength)
                    suffixRange = NSRange(location: coreRange.location + coreRange.length - suffixLength, length: suffixLength)
                } else {
                    let prefixCandidate = coreRange.location - prefixLength
                    if prefixCandidate >= 0,
                       prefixCandidate + prefixLength <= nsLength {
                        let candidate = nsString.substring(with: NSRange(location: prefixCandidate, length: prefixLength))
                        if candidate == prefix {
                            prefixRange = NSRange(location: prefixCandidate, length: prefixLength)
                        }
                    }

                    let suffixCandidate = coreRange.location + coreRange.length
                    if suffixCandidate + suffixLength <= nsLength {
                        let candidate = nsString.substring(with: NSRange(location: suffixCandidate, length: suffixLength))
                        if candidate == suffix {
                            suffixRange = NSRange(location: suffixCandidate, length: suffixLength)
                        }
                    }
                }

                if let prefixRange, let suffixRange {
                    var innerStart = coreRange.location
                    var innerLength = coreRange.length
                    if prefixRange.location == coreRange.location {
                        innerStart += prefixLength
                        innerLength = max(0, innerLength - prefixLength)
                    }
                    if suffixRange.location + suffixRange.length == coreRange.location + coreRange.length {
                        innerLength = max(0, innerLength - suffixLength)
                    }

                    let innerRange = innerLength > 0 ? NSRange(location: innerStart, length: innerLength) : NSRange(location: innerStart, length: 0)
                    let innerText = innerLength > 0 ? nsString.substring(with: innerRange) : ""

                    var unionStart = originalRange.location
                    var unionEnd = originalRange.location + originalRange.length
                    unionStart = min(unionStart, prefixRange.location)
                    unionEnd = max(unionEnd, suffixRange.location + suffixRange.length)
                    let rangeToReplace = NSRange(location: unionStart, length: max(0, unionEnd - unionStart))
                    let caretOffset = (innerText as NSString).length
                    replaceWith(range: rangeToReplace, text: innerText, caretOffset: caretOffset)
                    return
                }
            }

            let newCore = coreText
            let wrapped = prefix + newCore + suffix
            let caret = (prefix as NSString).length + (newCore as NSString).length + (suffix as NSString).length
            replaceWith(range: originalRange, text: wrapped, caretOffset: caret)
        }

        private func sanitizeMarkdown(_ string: String) -> String {
            let range = NSRange(location: 0, length: (string as NSString).length)
            let sanitized = Coordinator.bulletSanitizeRegex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: "$1- ")
            if sanitized != string {
                LOG("Markdown sanitize applied", ctx: ["before": "\(string.prefix(40))", "after": "\(sanitized.prefix(40))"])
            }
            return sanitized
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
                let sanitized = sanitizeMarkdown(storage.string)
                parent.text = sanitized
                textView.string = sanitized
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
                let indent = lineNSString.substring(with: match.range(at: 1))
                let remainderRange = NSRange(location: prefixLength, length: max(0, lineNSString.length - prefixLength))
                let remainder = remainderRange.length > 0 ? lineNSString.substring(with: remainderRange).trimmingCharacters(in: .whitespaces) : ""

                if remainder.isEmpty && caretAtLineEnd {
                    exitList(prefixLength: prefixLength)
                    return false
                }

                let insertion = "\n" + indent + "• "
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
                let leading = line.prefix { $0.isWhitespace }
                var remainder = String(line.drop { $0.isWhitespace })
                guard !remainder.isEmpty else { return line }
                if remainder.hasPrefix(prefix) {
                    remainder.removeFirst(prefix.count)
                    return String(leading) + remainder
                }
                if remainder.hasPrefix("• ") {
                    remainder.removeFirst(2)
                    return String(leading) + remainder
                }
                let content = remainder.trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else { return line }
                return String(leading) + prefix + content
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
            var nextNumber = 1
            let transformed = lines.map { line -> String in
                let leading = line.prefix { $0.isWhitespace }
                var remainder = String(line.drop { $0.isWhitespace })
                guard !remainder.isEmpty else { return line }
                if let match = remainder.range(of: "^\\d+[\\.)]\\s*", options: .regularExpression) {
                    remainder.removeSubrange(match)
                    return String(leading) + remainder
                }
                let content = remainder.trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else { return line }
                let numbered = "\(nextNumber). " + content
                nextNumber += 1
                return String(leading) + numbered
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
            let displayText = storage.string
            let sanitized = sanitizeMarkdown(displayText)
            parent.text = sanitized
            textView.string = sanitized
            let safeCaret = max(0, min(caretPosition, sanitized.count))
            textView.setSelectedRange(NSRange(location: safeCaret, length: 0))
            currentSelection = textView.selectedRange()
            applyMarkdownStyles()
            textView.scrollRangeToVisible(currentSelection)
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

            MarkdownStyler.apply(to: storage, baseFont: baseFont, selectedRange: currentSelection, isPreview: false)
            storage.endEditing()
            textView.scrollRangeToVisible(currentSelection)
        }
    }

    static func renderPreview(markdown: String, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: fontSize)
        return MarkdownStyler.render(markdown: markdown, baseFont: font)
    }
}

enum MarkdownStyler {
    static func render(markdown: String, baseFont: NSFont) -> NSAttributedString {
        let storage = NSTextStorage(string: markdown)
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ], range: fullRange)
        apply(to: storage, baseFont: baseFont, selectedRange: NSRange(location: NSNotFound, length: 0), isPreview: true)
        return storage.copy() as? NSAttributedString ?? NSAttributedString(string: markdown)
    }

    static func apply(to storage: NSTextStorage, baseFont: NSFont, selectedRange: NSRange, isPreview: Bool) {
        var string = storage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)

        let codeBlocks = applyCodeBlocks(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange)
        string = storage.string as NSString
        applyInlineCode(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange, codeBlocks: codeBlocks)
        string = storage.string as NSString
        applyHeadings(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange, codeBlocks: codeBlocks)
        string = storage.string as NSString
        applyBold(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange, codeBlocks: codeBlocks)
        string = storage.string as NSString
        applyItalic(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange, codeBlocks: codeBlocks)
        string = storage.string as NSString
        applyHorizontalRules(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange, isPreview: isPreview, codeBlocks: codeBlocks)
        string = storage.string as NSString
        applyLists(storage: storage, string: string, baseFont: baseFont, selectedRange: selectedRange, isPreview: isPreview, codeBlocks: codeBlocks)

        // Reapply base attributes to any characters inserted during transforms (e.g. preview attachments)
        let currentLength = storage.length
        if currentLength != fullRange.length {
            storage.addAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor
            ], range: NSRange(location: 0, length: currentLength))
        }

        // detect markdown links and underline them
        let pattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let finalString = storage.string as NSString
            regex.enumerateMatches(in: finalString as String, options: [], range: NSRange(location: 0, length: finalString.length)) { match, _, _ in
                guard let match else { return }
                guard match.numberOfRanges >= 3 else { return }

                let labelRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                let urlString = finalString.substring(with: urlRange).trimmingCharacters(in: .whitespacesAndNewlines)

                if let url = URL(string: urlString) {
                    storage.addAttributes([
                        .link: url,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.systemBlue
                    ], range: labelRange)
                }

                let openBracketRange = NSRange(location: match.range.location, length: 1)
                let closeBracketRange = NSRange(location: labelRange.location + labelRange.length, length: 1)
                let openParenRange = NSRange(location: closeBracketRange.location + closeBracketRange.length, length: 1)
                let closeParenRange = NSRange(location: match.range.location + match.range.length - 1, length: 1)

                let revealMarkers = intersects(labelRange, with: selectedRange) || intersects(urlRange, with: selectedRange) || intersects(openBracketRange, with: selectedRange) || intersects(openParenRange, with: selectedRange)
                setMarkerVisibility(storage: storage, markerRange: openBracketRange, reveal: revealMarkers, baseFont: baseFont)
                setMarkerVisibility(storage: storage, markerRange: closeBracketRange, reveal: revealMarkers, baseFont: baseFont)
                setMarkerVisibility(storage: storage, markerRange: openParenRange, reveal: revealMarkers, baseFont: baseFont)
                setMarkerVisibility(storage: storage, markerRange: closeParenRange, reveal: revealMarkers, baseFont: baseFont)

                let revealURL = intersects(urlRange, with: selectedRange)
                setMarkerVisibility(storage: storage, markerRange: urlRange, reveal: revealURL, baseFont: baseFont)
            }
        }
    }

    private struct CodeBlock {
        let blockRange: NSRange
        let contentRange: NSRange
        let openingFenceRange: NSRange
        let closingFenceRange: NSRange
    }

    private struct Utf8ToUtf16Map {
        private let mapping: [Int]

        init(_ string: String) {
            var map = [Int](repeating: 0, count: string.utf8.count + 1)
            var utf8Offset = 0
            var utf16Offset = 0

            for scalar in string.unicodeScalars {
                let utf8Length = scalar.utf8.count
                for i in 0..<utf8Length {
                    map[utf8Offset + i] = utf16Offset
                }
                utf8Offset += utf8Length
                utf16Offset += scalar.utf16.count
            }

            map[utf8Offset] = utf16Offset
            self.mapping = map
        }

        func range(start: Int, end: Int, in string: NSString) -> NSRange? {
            guard start >= 0, end >= start, end < mapping.count else { return nil }
            let location = mapping[start]
            let length = mapping[end] - mapping[start]
            guard location + length <= string.length else { return nil }
            return NSRange(location: location, length: length)
        }
    }

    private enum MarkdownParserHelper {
        static func makeDocument(for text: String) -> UnsafeMutablePointer<cmark_node>? {
            cmark_gfm_core_extensions_ensure_registered()
            guard let parser = cmark_parser_new(Int32(CMARK_OPT_DEFAULT)) else { return nil }
            defer { cmark_parser_free(parser) }

            let extensionNames: [String]
            if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
                extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]
            } else {
                extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist"]
            }

            for name in extensionNames {
                guard let ext = cmark_find_syntax_extension(name) else { continue }
                cmark_parser_attach_syntax_extension(parser, ext)
            }

            text.withCString { pointer in
                cmark_parser_feed(parser, pointer, text.utf8.count)
            }

            guard let document = cmark_parser_finish(parser) else { return nil }
            return document
        }
    }

    private static func applyCodeBlocks(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange) -> [CodeBlock] {
        let text = string as String
        guard let document = MarkdownParserHelper.makeDocument(for: text) else { return [] }
        defer { cmark_node_free(document) }

        let mapper = Utf8ToUtf16Map(text)
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.95, weight: .regular)
        var blocks: [CodeBlock] = []

        func isFenceLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { return false }
            if trimmed.hasPrefix("```") { return true }
            if trimmed.hasPrefix("~~~") { return true }
            return false
        }

        func visit(_ node: UnsafeMutablePointer<cmark_node>?) {
            guard let node else { return }

            if cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK {
                let start = Int(cmark_node_get_start_offset(node))
                let end = Int(cmark_node_get_end_offset(node))

                guard let blockRange = mapper.range(start: start, end: end, in: string) else {
                    return
                }

                let blockStart = blockRange.location
                let blockEnd = NSMaxRange(blockRange)

                var openingFenceRange = NSRange(location: blockStart, length: 0)
                var closingFenceRange = NSRange(location: blockEnd, length: 0)
                var contentRange = blockRange

                if blockRange.length > 0 {
                    var firstNewlineIndex: Int?
                    var cursor = blockStart
                    while cursor < blockEnd {
                        if string.character(at: cursor) == 10 {
                            firstNewlineIndex = cursor
                            break
                        }
                        cursor += 1
                    }

                    if let newlineIndex = firstNewlineIndex {
                        let candidateRange = NSRange(location: blockStart, length: newlineIndex - blockStart + 1)
                        let candidateLine = string.substring(with: candidateRange)
                        if isFenceLine(candidateLine) {
                            openingFenceRange = candidateRange
                        }
                    }

                    if openingFenceRange.length > 0 {
                        var searchEnd = blockEnd
                        while searchEnd > blockStart {
                            let value = string.character(at: searchEnd - 1)
                            if let scalar = UnicodeScalar(value), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                                searchEnd -= 1
                            } else {
                                break
                            }
                        }

                        var closingStart = searchEnd
                        var scan = searchEnd - 1
                        while scan >= blockStart {
                            if string.character(at: scan) == 10 {
                                closingStart = scan + 1
                                break
                            }
                            scan -= 1
                        }

                        let candidateLength = max(0, searchEnd - closingStart)
                        if candidateLength > 0 {
                            let candidateRange = NSRange(location: closingStart, length: candidateLength)
                            let candidateLine = string.substring(with: candidateRange)
                            if isFenceLine(candidateLine) {
                                let trailing = blockEnd - searchEnd
                                closingFenceRange = NSRange(location: closingStart, length: candidateLength + trailing)
                            }
                        }
                    }
                }

                let contentStart = openingFenceRange.location + openingFenceRange.length
                let contentEnd = closingFenceRange.length > 0 ? closingFenceRange.location : blockEnd
                if contentEnd >= contentStart {
                    contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)
                } else {
                    contentRange = NSRange(location: contentStart, length: 0)
                }

                if contentRange.length > 0 {
                    storage.addAttributes([
                        .font: codeFont,
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.08)
                    ], range: contentRange)
                }

                let isPreviewContext = selectedRange.location == NSNotFound
                let revealOpen = intersects(contentRange, with: selectedRange) || intersects(openingFenceRange, with: selectedRange)
                let revealClose = intersects(contentRange, with: selectedRange) || intersects(closingFenceRange, with: selectedRange)
                let tickColor = isPreviewContext ? nil : NSColor.systemOrange.withAlphaComponent(0.75)
                let compress = isPreviewContext

                if openingFenceRange.length > 0 {
                    setMarkerVisibility(storage: storage, markerRange: openingFenceRange, reveal: revealOpen, baseFont: baseFont, hiddenColor: tickColor, compressWidth: compress)
                }

                if closingFenceRange.length > 0 {
                    setMarkerVisibility(storage: storage, markerRange: closingFenceRange, reveal: revealClose, baseFont: baseFont, hiddenColor: tickColor, compressWidth: compress)
                }

                blocks.append(CodeBlock(blockRange: blockRange, contentRange: contentRange, openingFenceRange: openingFenceRange, closingFenceRange: closingFenceRange))
            }

            var child = cmark_node_first_child(node)
            while child != nil {
                visit(child)
                child = cmark_node_next(child)
            }
        }

        visit(document)
        return blocks
    }

    private static func applyInlineCode(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange, codeBlocks: [CodeBlock]) {
        let pattern = "`[^`]+`"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            if range(match.range, isInsideAnyOf: codeBlocks) {
                continue
            }
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
            let isPreviewContext = selectedRange.location == NSNotFound
            let tickColor = isPreviewContext ? nil : NSColor.systemOrange.withAlphaComponent(0.75)
            let compress = isPreviewContext
            setMarkerVisibility(storage: storage, markerRange: startMarker, reveal: reveal, baseFont: baseFont, hiddenColor: tickColor, compressWidth: compress)
            setMarkerVisibility(storage: storage, markerRange: endMarker, reveal: reveal, baseFont: baseFont, hiddenColor: tickColor, compressWidth: compress)
        }
    }

    private static func applyHeadings(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange, codeBlocks: [CodeBlock]) {
        let pattern = "^(#{1,4})\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            if range(match.range, isInsideAnyOf: codeBlocks) {
                continue
            }
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
            setMarkerVisibility(storage: storage, markerRange: hashesRange, reveal: reveal, baseFont: baseFont)
        }
    }

    private static func applyBold(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange, codeBlocks: [CodeBlock]) {
        let pattern = "\\*\\*(.+?)\\*\\*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            if range(match.range, isInsideAnyOf: codeBlocks) {
                continue
            }
            guard match.range.length >= 4 else { continue }
            let contentRange = match.range(at: 1)
            let font = NSFont.boldSystemFont(ofSize: baseFont.pointSize)
            storage.addAttribute(.font, value: font, range: contentRange)

            let startMarker = NSRange(location: match.range.location, length: 2)
            let endMarker = NSRange(location: match.range.location + match.range.length - 2, length: 2)
            let reveal = intersects(contentRange, with: selectedRange) || intersects(startMarker, with: selectedRange) || intersects(endMarker, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: startMarker, reveal: reveal, baseFont: baseFont)
            setMarkerVisibility(storage: storage, markerRange: endMarker, reveal: reveal, baseFont: baseFont)
        }
    }

    private static func applyItalic(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange, codeBlocks: [CodeBlock]) {
        let pattern = "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        for match in regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length)) {
            if range(match.range, isInsideAnyOf: codeBlocks) {
                continue
            }
            guard match.range.length >= 3 else { continue }
            let contentRange = match.range(at: 1)
            let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italicFont, range: contentRange)

            let startMarker = NSRange(location: match.range.location, length: 1)
            let endMarker = NSRange(location: match.range.location + match.range.length - 1, length: 1)
            let reveal = intersects(contentRange, with: selectedRange) || intersects(startMarker, with: selectedRange) || intersects(endMarker, with: selectedRange)
            setMarkerVisibility(storage: storage, markerRange: startMarker, reveal: reveal, baseFont: baseFont)
            setMarkerVisibility(storage: storage, markerRange: endMarker, reveal: reveal, baseFont: baseFont)
        }
    }

    private static func applyHorizontalRules(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange, isPreview: Bool, codeBlocks: [CodeBlock]) {
        let pattern = "^---$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let matches = regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length))

        if isPreview {
            guard !matches.isEmpty else { return }
            LOG("Markdown hr preview", ctx: ["count": "\(matches.count)"])
            guard let snapshot = storage.copy() as? NSAttributedString else {
                LOG("Markdown hr preview snapshot copy failed")
                return
            }
            let snapshotString = snapshot.string as NSString
            let rebuilt = NSMutableAttributedString()
            var cursor = 0

            for match in matches {
                if match.range.location > cursor {
                    let leadingRange = NSRange(location: cursor, length: match.range.location - cursor)
                    rebuilt.append(snapshot.attributedSubstring(from: leadingRange))
                }

                if range(match.range, isInsideAnyOf: codeBlocks) {
                    rebuilt.append(snapshot.attributedSubstring(from: match.range))
                    cursor = match.range.location + match.range.length
                    continue
                }

                let attachment = HorizontalRuleAttachment(thickness: 1.0, color: .systemGray)
                rebuilt.append(NSAttributedString(attachment: attachment))

                let lineEnd = match.range.location + match.range.length
                let hasTrailingNewline = lineEnd < snapshotString.length && snapshotString.character(at: lineEnd) == 10
                if !hasTrailingNewline {
                    rebuilt.append(NSAttributedString(string: "\n", attributes: [
                        .font: baseFont,
                        .foregroundColor: NSColor.labelColor
                    ]))
                }

                cursor = lineEnd
            }

            if cursor < snapshotString.length {
                let trailingRange = NSRange(location: cursor, length: snapshotString.length - cursor)
                rebuilt.append(snapshot.attributedSubstring(from: trailingRange))
            }

            storage.setAttributedString(rebuilt)
            return
        }

        for match in matches {
            if range(match.range, isInsideAnyOf: codeBlocks) {
                continue
            }
            let reveal = intersects(match.range, with: selectedRange)
            let color = NSColor.systemGray
            var attributes: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color
            ]

            if reveal {
                attributes[.foregroundColor] = color
            } else {
                attributes[.foregroundColor] = color.withAlphaComponent(0.6)
                attributes[.font] = NSFont.systemFont(ofSize: baseFont.pointSize * 0.95)
                attributes[.baselineOffset] = -1
            }

            storage.addAttributes(attributes, range: match.range)
        }
    }

    private static func applyLists(storage: NSTextStorage, string: NSString, baseFont: NSFont, selectedRange: NSRange, isPreview: Bool, codeBlocks: [CodeBlock]) {
        let bulletPattern = "^(\\s*[-\\*+])(\\s+)"
        let numberPattern = "^(\\s*)(\\d+)([\\.)])(\\s+)"

        if let bulletRegex = try? NSRegularExpression(pattern: bulletPattern, options: [.anchorsMatchLines]) {
            let matches = bulletRegex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length))
            for match in matches.reversed() {
                if range(match.range, isInsideAnyOf: codeBlocks) {
                    continue
                }
                let prefixRange = match.range(at: 1)
                let spacingRange = match.range(at: 2)
                let paragraphRange = string.paragraphRange(for: match.range)
                let list = NSTextList(markerFormat: .disc, options: 0)
                storage.addAttribute(.paragraphStyle, value: markdownParagraphStyle(indentation: 24, textList: list), range: paragraphRange)

                let contentStart = match.range.location + match.range.length
                let contentLength = max(0, paragraphRange.location + paragraphRange.length - contentStart)
                let contentRange = NSRange(location: contentStart, length: contentLength)
                let reveal = intersects(contentRange, with: selectedRange) || intersects(prefixRange, with: selectedRange)
                let mutable = storage.mutableString
                let prefixString = string.substring(with: prefixRange)
                let indentPrefix = prefixString.prefix { $0.isWhitespace }
                let markerCharacter = prefixString.drop { $0.isWhitespace }.first ?? "-"
                let indent = String(indentPrefix)
                let originalMarkerString = indent + String(markerCharacter)
                let bulletString = indent + "•"

                if reveal && !isPreview {
                    if mutable.substring(with: prefixRange) != originalMarkerString {
                        mutable.replaceCharacters(in: prefixRange, with: originalMarkerString)
                    }
                    storage.removeAttribute(.foregroundColor, range: prefixRange)
                } else {
                    if mutable.substring(with: prefixRange) != bulletString {
                        mutable.replaceCharacters(in: prefixRange, with: bulletString)
                    }
                    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: prefixRange)
                }
                setMarkerVisibility(storage: storage, markerRange: spacingRange, reveal: true, baseFont: baseFont)
            }
        }

        if let numberRegex = try? NSRegularExpression(pattern: numberPattern, options: [.anchorsMatchLines]) {
            let matches = numberRegex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length))
            for match in matches.reversed() {
                if range(match.range, isInsideAnyOf: codeBlocks) {
                    continue
                }
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
                let reveal = intersects(contentRange, with: selectedRange) || intersects(numberRange, with: selectedRange)
                setMarkerVisibility(storage: storage, markerRange: indentRange, reveal: true, baseFont: baseFont)
                setMarkerVisibility(storage: storage, markerRange: numberRange, reveal: true, baseFont: baseFont, compressWidth: false)
                setMarkerVisibility(storage: storage, markerRange: delimiterRange, reveal: true, baseFont: baseFont, compressWidth: false)
                setMarkerVisibility(storage: storage, markerRange: spacingRange, reveal: true, baseFont: baseFont)
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
        if selection.location == NSNotFound {
            return false
        }
        if selection.length == 0 {
            return NSLocationInRange(selection.location, range)
        }
        return NSIntersectionRange(range, selection).length > 0
    }

    private static func setMarkerVisibility(storage: NSTextStorage, markerRange: NSRange?, reveal: Bool, baseFont: NSFont, hiddenColor: NSColor? = nil, compressWidth: Bool = true) {
        guard let markerRange, markerRange.length > 0 else { return }
        if reveal {
            storage.removeAttribute(.foregroundColor, range: markerRange)
            storage.removeAttribute(.font, range: markerRange)
            storage.removeAttribute(.kern, range: markerRange)
            storage.removeAttribute(.baselineOffset, range: markerRange)
            storage.removeAttribute(.backgroundColor, range: markerRange)
        } else {
            var attributes: [NSAttributedString.Key: Any] = [:]
            attributes[.foregroundColor] = hiddenColor ?? .clear
            storage.removeAttribute(.baselineOffset, range: markerRange)
            storage.removeAttribute(.backgroundColor, range: markerRange)
            if compressWidth {
                let hiddenFont = NSFont.systemFont(ofSize: max(0.1, baseFont.pointSize * 0.05))
                attributes[.font] = hiddenFont
                attributes[.kern] = -baseFont.pointSize * 0.65
            } else {
                storage.removeAttribute(.font, range: markerRange)
                storage.removeAttribute(.kern, range: markerRange)
            }
            storage.addAttributes(attributes, range: markerRange)
        }
    }

    private static func range(_ range: NSRange, isInsideAnyOf blocks: [CodeBlock]) -> Bool {
        guard range.length > 0 else { return false }
        let end = range.location + range.length - 1
        for block in blocks {
            if NSLocationInRange(range.location, block.blockRange) && NSLocationInRange(end, block.blockRange) {
                return true
            }
        }
        return false
    }
}

private final class HorizontalRuleAttachment: NSTextAttachment {
    init(thickness: CGFloat, color: NSColor) {
        super.init(data: nil, ofType: nil)
        attachmentCell = HorizontalRuleAttachmentCell(thickness: thickness, color: color)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

private final class HorizontalRuleAttachmentCell: NSTextAttachmentCell {
    private let thickness: CGFloat
    private let color: NSColor

    init(thickness: CGFloat, color: NSColor) {
        self.thickness = max(1.0, thickness)
        self.color = color
        super.init()
    }

    required init(coder: NSCoder) {
        self.thickness = 1.0
        self.color = .systemGray
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize {
        NSSize(width: 1, height: max(12, thickness + 6))
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: lineFrag.minX, y: lineFrag.midY - thickness / 2, width: lineFrag.width, height: max(lineFrag.height, thickness + 6))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let lineRect = NSInsetRect(cellFrame, 0, (cellFrame.height - thickness) / 2.0)
        color.set()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: lineRect.minX, y: lineRect.midY))
        path.line(to: NSPoint(x: lineRect.maxX, y: lineRect.midY))
        path.lineWidth = thickness
        path.stroke()
    }
}
