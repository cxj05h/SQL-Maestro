import SwiftUI
import AppKit
import Foundation

final class JSONEditorController: ObservableObject {
    fileprivate weak var coordinator: JSONEditor.Coordinator?

    func focus() {
        coordinator?.focus()
    }

    func focusAndSelectAll() {
        coordinator?.focus()
        coordinator?.selectAll()
    }

    @discardableResult
    func find(_ query: String, direction: JSONEditor.SearchDirection, wrap: Bool = true) -> Bool {
        coordinator?.find(query, direction: direction, wrap: wrap) ?? false
    }
}

struct JSONEditor: NSViewRepresentable {
    enum SearchDirection {
        case forward
        case backward
    }

    @Binding var text: String
    var fontSize: CGFloat
    var fileType: SavedFileFormat = .json
    var onFocusChanged: ((Bool) -> Void)?
    var controller: JSONEditorController? = nil
    var onFindCommand: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = JSONTextView()
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.onFocusChanged = { focused in
            context.coordinator.parent.onFocusChanged?(focused)
        }
        textView.onFindCommand = {
            context.coordinator.handleFindCommand()
        }

        let scrollView = NonBubblingNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        // Add line numbers BEFORE setting documentView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let lineNumberView = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = lineNumberView

        // Set documentView after ruler is configured
        scrollView.documentView = textView

        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        textView.setContentHuggingPriority(.init(1), for: .vertical)
        textView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        context.coordinator.textView = textView
        context.coordinator.attach(controller: controller)
        textView.string = text
        context.coordinator.applyHighlight()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        // Update parent and highlighter if file type changed
        if context.coordinator.parent.fileType != fileType {
            context.coordinator.updateParent(parent: self)
        }

        context.coordinator.attach(controller: controller)
        if textView.string != text {
            context.coordinator.suppressTextDidChange = true
            textView.string = text
            context.coordinator.suppressTextDidChange = false
            context.coordinator.applyHighlight()
        }
        let currentSize = textView.font?.pointSize ?? fontSize
        if abs(currentSize - fontSize) > 0.1 {
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            context.coordinator.applyHighlight()
        }
        textView.onFocusChanged = { focused in
            context.coordinator.parent.onFocusChanged?(focused)
        }
        textView.onFindCommand = {
            context.coordinator.handleFindCommand()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor
        fileprivate weak var textView: JSONTextView?
        var suppressTextDidChange = false
        private var highlighter: SyntaxHighlighter
        private weak var controller: JSONEditorController?

        init(parent: JSONEditor) {
            self.parent = parent
            self.highlighter = parent.fileType == .json ? JSONSyntaxHighlighter() : YAMLSyntaxHighlighter()
        }

        func attach(controller: JSONEditorController?) {
            self.controller = controller
            controller?.coordinator = self
        }

        func updateParent(parent: JSONEditor) {
            self.parent = parent
            self.highlighter = parent.fileType == .json ? JSONSyntaxHighlighter() : YAMLSyntaxHighlighter()
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressTextDidChange, let textView else { return }
            parent.text = textView.string
            applyHighlight()
        }

        func textViewDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged?(true)
        }

        func textViewDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged?(false)
        }

        func applyHighlight() {
            guard let textView else { return }
            highlighter.highlight(textView: textView)
        }

        func focus() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }

        func selectAll() {
            guard let textView else { return }
            textView.selectAll(nil)
        }

        func handleFindCommand() {
            if let onFind = parent.onFindCommand {
                onFind()
            } else {
                textView?.performFindPanelAction(nil)
            }
        }

        @discardableResult
        func find(_ query: String, direction: JSONEditor.SearchDirection, wrap: Bool) -> Bool {
            guard let textView, !query.isEmpty else { return false }
            let nsText = textView.string as NSString
            guard nsText.length > 0 else { return false }

            let selectedRange = textView.selectedRange()
            let selectionEnd = selectedRange.location + selectedRange.length
            var options: NSString.CompareOptions = [.caseInsensitive]
            if direction == .backward {
                options.insert(.backwards)
            }

            func apply(range: NSRange) -> Bool {
                guard range.location != NSNotFound else { return false }
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                if textView.responds(to: #selector(NSTextView.showFindIndicator(for:))) {
                    textView.showFindIndicator(for: range)
                }
                return true
            }

            let length = nsText.length
            switch direction {
            case .forward:
                let start = selectionEnd
                if start < length {
                    let range = nsText.range(of: query,
                                             options: options,
                                             range: NSRange(location: start, length: length - start))
                    if apply(range: range) { return true }
                }
                if wrap, start > 0 {
                    let range = nsText.range(of: query,
                                             options: options,
                                             range: NSRange(location: 0, length: start))
                    if apply(range: range) { return true }
                }
            case .backward:
                let end = selectedRange.location
                if end > 0 {
                    let range = nsText.range(of: query,
                                             options: options,
                                             range: NSRange(location: 0, length: end))
                    if apply(range: range) { return true }
                }
                if wrap, selectionEnd < length {
                    let range = nsText.range(of: query,
                                             options: options,
                                             range: NSRange(location: selectionEnd,
                                                            length: length - selectionEnd))
                    if apply(range: range) { return true }
                }
            }
            NSSound.beep()
            return false
        }
    }
}

private final class JSONTextView: NSTextView {
    var onFocusChanged: ((Bool) -> Void)?
    var onFindCommand: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChanged?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChanged?(false) }
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFindCommand?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Syntax Highlighter Protocol
private protocol SyntaxHighlighter {
    func highlight(textView: NSTextView)
}

// MARK: - JSON Syntax Highlighter
private final class JSONSyntaxHighlighter: SyntaxHighlighter {
    private let stringRegex = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", options: [])
    private let numberRegex = try! NSRegularExpression(pattern: "-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?", options: [])
    private let boolRegex = try! NSRegularExpression(pattern: "\\b(?:true|false|null)\\b", options: [])

    func highlight(textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let nsString = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(fontSize: textView.font?.pointSize ?? 13), range: fullRange)

        stringRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let color = self.isKey(matchRange: match.range, in: nsString) ? JSONEditorPalette.key : JSONEditorPalette.string
            textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
        }

        numberRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            if self.rangeIsWithinString(range, textStorage: textStorage) { return }
            textStorage.addAttribute(.foregroundColor, value: JSONEditorPalette.number, range: range)
        }

        boolRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            if self.rangeIsWithinString(range, textStorage: textStorage) { return }
            textStorage.addAttribute(.foregroundColor, value: JSONEditorPalette.bool, range: range)
        }

        textStorage.endEditing()
    }

    private func isKey(matchRange: NSRange, in string: NSString) -> Bool {
        var idx = matchRange.location + matchRange.length
        while idx < string.length {
            let char = string.character(at: idx)
            if let scalar = UnicodeScalar(char), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                idx += 1
                continue
            }
            return char == 58 // ':'
        }
        return false
    }

    private func rangeIsWithinString(_ range: NSRange, textStorage: NSTextStorage) -> Bool {
        guard range.location < textStorage.length else { return false }
        var effective = NSRange()
        let color = textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: &effective)
        if let nsColor = color as? NSColor {
            return nsColor == JSONEditorPalette.string || nsColor == JSONEditorPalette.key
        }
        return false
    }

    private func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return [
            .font: font,
            .foregroundColor: JSONEditorPalette.base
        ]
    }
}

private enum JSONEditorPalette {
    // Use white for base text (punctuation) since background is always dark (#2A2A35)
    static let base = NSColor.white
    static let key = NSColor(calibratedRed: 99/255.0, green: 102/255.0, blue: 241/255.0, alpha: 1)
    static let string = NSColor(calibratedRed: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1)
    static let number = NSColor(calibratedRed: 251/255.0, green: 191/255.0, blue: 36/255.0, alpha: 1)
    static let bool = NSColor(calibratedRed: 239/255.0, green: 68/255.0, blue: 192/255.0, alpha: 1)
}

// MARK: - YAML Syntax Highlighter
private final class YAMLSyntaxHighlighter: SyntaxHighlighter {
    // YAML syntax patterns
    private let keyRegex = try! NSRegularExpression(pattern: "^[ ]*([a-zA-Z_][a-zA-Z0-9_-]*)(?=:)", options: [.anchorsMatchLines])
    private let stringRegex = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\'|[^'])*'", options: [])
    private let numberRegex = try! NSRegularExpression(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", options: [])
    private let boolRegex = try! NSRegularExpression(pattern: "\\b(?:true|false|yes|no|on|off|null|~)\\b", options: [])
    private let commentRegex = try! NSRegularExpression(pattern: "#.*$", options: [.anchorsMatchLines])

    func highlight(textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let nsString = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(fontSize: textView.font?.pointSize ?? 13), range: fullRange)

        // Apply comments first (they take precedence)
        commentRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            textStorage.addAttribute(.foregroundColor, value: YAMLEditorPalette.comment, range: match.range)
        }

        // Apply keys
        keyRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let keyRange = match.range(at: 1)
            if !self.rangeIsWithinComment(keyRange, textStorage: textStorage) {
                textStorage.addAttribute(.foregroundColor, value: YAMLEditorPalette.key, range: keyRange)
            }
        }

        // Apply strings
        stringRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            if !self.rangeIsWithinComment(match.range, textStorage: textStorage) {
                textStorage.addAttribute(.foregroundColor, value: YAMLEditorPalette.string, range: match.range)
            }
        }

        // Apply numbers
        numberRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            if self.rangeIsWithinStringOrComment(range, textStorage: textStorage) { return }
            textStorage.addAttribute(.foregroundColor, value: YAMLEditorPalette.number, range: range)
        }

        // Apply booleans/null
        boolRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            if self.rangeIsWithinStringOrComment(range, textStorage: textStorage) { return }
            textStorage.addAttribute(.foregroundColor, value: YAMLEditorPalette.bool, range: range)
        }

        // Highlight unquoted string values after colons
        self.highlightUnquotedValues(in: textStorage, fullRange: fullRange)

        textStorage.endEditing()
    }

    private func highlightUnquotedValues(in textStorage: NSTextStorage, fullRange: NSRange) {
        let nsString = textStorage.string as NSString

        // Pattern to match unquoted values after colons
        // Matches: ": <whitespace> <value>" where value is not quoted, not a comment, and not special chars
        let unquotedValueRegex = try! NSRegularExpression(
            pattern: ":\\s+([^\\s\"'#][^\\r\\n]*?)(?=\\s*(?:#|$))",
            options: []
        )

        unquotedValueRegex.enumerateMatches(in: nsString as String, options: [], range: fullRange) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let valueRange = match.range(at: 1)

            // Don't highlight if already colored or within a comment
            if self.rangeIsWithinComment(valueRange, textStorage: textStorage) { return }

            // Check if this range has already been colored by number/bool regex
            var effective = NSRange()
            if valueRange.location < textStorage.length {
                let color = textStorage.attribute(.foregroundColor, at: valueRange.location, effectiveRange: &effective)
                if let nsColor = color as? NSColor {
                    // Only apply if it's still base color (white)
                    if nsColor == YAMLEditorPalette.base {
                        textStorage.addAttribute(.foregroundColor, value: YAMLEditorPalette.string, range: valueRange)
                    }
                }
            }
        }
    }

    private func rangeIsWithinComment(_ range: NSRange, textStorage: NSTextStorage) -> Bool {
        guard range.location < textStorage.length else { return false }
        var effective = NSRange()
        let color = textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: &effective)
        if let nsColor = color as? NSColor {
            return nsColor == YAMLEditorPalette.comment
        }
        return false
    }

    private func rangeIsWithinStringOrComment(_ range: NSRange, textStorage: NSTextStorage) -> Bool {
        guard range.location < textStorage.length else { return false }
        var effective = NSRange()
        let color = textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: &effective)
        if let nsColor = color as? NSColor {
            return nsColor == YAMLEditorPalette.string ||
                   nsColor == YAMLEditorPalette.comment ||
                   nsColor == YAMLEditorPalette.key
        }
        return false
    }

    private func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return [
            .font: font,
            .foregroundColor: YAMLEditorPalette.base
        ]
    }
}

private enum YAMLEditorPalette {
    // Use same colors as JSON for consistency with UI
    static let base = NSColor.white
    static let key = NSColor(calibratedRed: 99/255.0, green: 102/255.0, blue: 241/255.0, alpha: 1)
    static let string = NSColor(calibratedRed: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1)
    static let number = NSColor(calibratedRed: 251/255.0, green: 191/255.0, blue: 36/255.0, alpha: 1)
    static let bool = NSColor(calibratedRed: 239/255.0, green: 68/255.0, blue: 192/255.0, alpha: 1)
    static let comment = NSColor(calibratedRed: 128/255.0, green: 128/255.0, blue: 128/255.0, alpha: 0.8) // Grey for comments
}
