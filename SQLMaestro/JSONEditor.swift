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
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.onFocusChanged = { focused in
            context.coordinator.parent.onFocusChanged?(focused)
        }
        textView.onFindCommand = {
            context.coordinator.handleFindCommand()
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.attach(controller: controller)
        textView.string = text
        context.coordinator.applyHighlight()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
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
        private let highlighter = JSONSyntaxHighlighter()
        private weak var controller: JSONEditorController?

        init(parent: JSONEditor) {
            self.parent = parent
        }

        func attach(controller: JSONEditorController?) {
            self.controller = controller
            controller?.coordinator = self
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
