import SwiftUI
import AppKit
import Foundation

struct JSONEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onFocusChanged: ((Bool) -> Void)?

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
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.onFocusChanged = { focused in
            context.coordinator.parent.onFocusChanged?(focused)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.applyHighlight()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor
        fileprivate weak var textView: JSONTextView?
        var suppressTextDidChange = false
        private let highlighter = JSONSyntaxHighlighter()

        init(parent: JSONEditor) {
            self.parent = parent
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
    }
}

private final class JSONTextView: NSTextView {
    var onFocusChanged: ((Bool) -> Void)?

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
            self.performFindPanelAction(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class JSONSyntaxHighlighter {
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
    static let base = NSColor.labelColor
    static let key = NSColor(calibratedRed: 99/255.0, green: 102/255.0, blue: 241/255.0, alpha: 1)
    static let string = NSColor(calibratedRed: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1)
    static let number = NSColor(calibratedRed: 251/255.0, green: 191/255.0, blue: 36/255.0, alpha: 1)
    static let bool = NSColor(calibratedRed: 239/255.0, green: 68/255.0, blue: 192/255.0, alpha: 1)
}
