import SwiftUI
import AppKit

final class SQLEditorController: ObservableObject {
    fileprivate weak var coordinator: SQLEditor.Coordinator?

    func focus() { coordinator?.focusTextView() }
    func currentText() -> String? { coordinator?.currentText() }
    func attachedTextView() -> NSTextView? { coordinator?.textView }
}

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    @ObservedObject var controller: SQLEditorController
    var onTextChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView()
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView

        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        textView.setContentHuggingPriority(.init(1), for: .vertical)
        textView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        context.coordinator.textView = textView
        controller.coordinator = context.coordinator
        textView.string = text

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            context.coordinator.applyExternalChange(text)
        }
        if abs((textView.font?.pointSize ?? fontSize) - fontSize) > 0.1 {
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        weak var textView: NSTextView?
        var suppressTextDidChange = false

        init(parent: SQLEditor) { self.parent = parent }

        func focusTextView() {
            textView?.window?.makeFirstResponder(textView)
        }

        func currentText() -> String {
            guard let textView else { return parent.text }
            return textView.string
        }

        func applyExternalChange(_ newValue: String) {
            guard let textView else { return }
            suppressTextDidChange = true
            textView.string = newValue
            suppressTextDidChange = false
            LOG("SQL editor external change applied", ctx: [
                "length": "\(newValue.count)"
            ])
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressTextDidChange, let textView else { return }
            let current = textView.string
            parent.text = current
            parent.onTextChange?(current)
            var ctx: [String:String] = ["length": "\(current.count)"]
            if let event = NSApp.currentEvent, event.type == .keyDown {
                if let chars = event.charactersIgnoringModifiers {
                    ctx["event"] = chars
                }
                if event.modifierFlags.contains(.command) {
                    ctx["cmd"] = "1"
                }
            }
            LOG("SQL editor textDidChange", ctx: ctx)
        }
    }
}

private final class SQLTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        if let range = selectedRanges.first as? NSRange {
            applyReplacement(in: range, with: "\t")
        } else {
            super.insertTab(sender)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        guard let str = insertString as? String else { return }
        if str.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            breakUndoCoalescing()
        }
    }

    override func insertNewline(_ sender: Any?) {
        super.insertNewline(sender)
        breakUndoCoalescing()
    }

    private func applyReplacement(in range: NSRange, with string: String) {
        guard let textStorage else { return }
        let undo = undoManager
        undo?.beginUndoGrouping()
        if shouldChangeText(in: range, replacementString: string) {
            textStorage.replaceCharacters(in: range, with: string)
            didChangeText()
        }
        undo?.endUndoGrouping()
    }

}
