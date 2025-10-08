import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Controller passed into `MarkdownEditor` to expose formatting actions to toolbars.
final class MarkdownEditorController: ObservableObject {
    fileprivate weak var coordinator: MarkdownEditor.Coordinator?

    func focus() { coordinator?.focusTextView() }
    func bold() { coordinator?.wrapSelection(prefix: "**", suffix: "**") }
    func italic() { coordinator?.wrapSelection(prefix: "*", suffix: "*") }
    func heading(level: Int) { coordinator?.applyHeading(level) }
    func bulletList() { coordinator?.toggleBulletList() }
    func numberedList() { coordinator?.toggleNumberedList() }
    func inlineCode() { coordinator?.wrapSelection(prefix: "``", suffix: "``") }
    func codeBlock() { coordinator?.wrapSelection(prefix: "\n```\n", suffix: "\n```\n") }
    func link() { coordinator?.requestLinkInsertion(source: .toolbar) }

    /// Returns the editor's current plain-text contents if the view is active.
    /// Falls back to the last bound value when the editor is not mounted (e.g. preview mode).
    func currentText() -> String? {
        coordinator?.currentText()
    }

    /// Find and highlight a keyword in the markdown editor
    @discardableResult
    func find(_ query: String) -> Bool {
        coordinator?.find(query) ?? false
    }
}

struct MarkdownEditor: NSViewRepresentable {
    struct LinkInsertion {
        let label: String
        let url: String
        let saveToTemplateLinks: Bool
    }

    struct ImageDropInfo {
        enum Source {
            case paste
            case drop
        }

        let data: Data
        let filename: String?
        let source: Source
    }

    struct ImageInsertion {
        let markdown: String
    }

    enum LinkRequestSource {
        case keyboard
        case toolbar
    }

    @Binding var text: String
    var fontSize: CGFloat
    @ObservedObject var controller: MarkdownEditorController
    var onLinkRequested: ((_ selectedText: String, _ source: LinkRequestSource, _ completion: @escaping (LinkInsertion?) -> Void) -> Void)?
    var onImageAttachment: ((ImageDropInfo) -> ImageInsertion?)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView()
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 2)

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 8, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = .white // Force white text for both dark and light mode on dark background
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.registerForDraggedTypes([
            .fileURL,
            .png,
            .tiff,
            .init("public.jpeg"),
            .init("public.heic")
        ])

        // Allow the editor to expand to the height dictated by SwiftUI layouts.
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        textView.setContentHuggingPriority(.init(1), for: .vertical)
        textView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let coordinator = context.coordinator
        textView.handlePaste = { [weak coordinator] pasteboard in
            guard let coordinator else { return false }
            return coordinator.handleImageAttachment(from: pasteboard, source: .paste)
        }

        textView.canAcceptDrag = { [weak coordinator] pasteboard in
            guard let coordinator else { return false }
            return coordinator.containsImage(in: pasteboard)
        }

        textView.handleDrop = { [weak coordinator] pasteboard, location in
            guard let coordinator else { return false }
            return coordinator.handleDrop(pasteboard: pasteboard, at: location)
        }

        context.coordinator.textView = textView
        controller.coordinator = context.coordinator
        textView.coordinator = context.coordinator
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

        // Backtick tracking for inline code / code block
        private var backtickCount = 0
        private var backtickTimer: Timer?
        private let backtickTimeWindow: TimeInterval = 0.5 // Time window for multiple presses

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

        func currentText() -> String {
            guard let textView else { return parent.text }
            return sanitizeMarkdown(textView.string)
        }

        func applyExternalTextChange(_ newValue: String) {
            guard let textView else { return }
            let sanitized = sanitizeMarkdown(newValue)
            replaceEntireText(with: sanitized)
        }

        @discardableResult
        func find(_ query: String) -> Bool {
            guard let textView, !query.isEmpty else { return false }
            let nsText = textView.string as NSString
            guard nsText.length > 0 else { return false }

            let options: NSString.CompareOptions = [.caseInsensitive]
            let range = nsText.range(of: query, options: options)

            guard range.location != NSNotFound else {
                NSSound.beep()
                return false
            }

            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            if textView.responds(to: #selector(NSTextView.showFindIndicator(for:))) {
                textView.showFindIndicator(for: range)
            }
            return true
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

        // MARK: Image handling

        func containsImage(in pasteboard: NSPasteboard) -> Bool {
            if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
                return true
            }
            if pasteboard.types?.contains(.fileURL) == true {
                if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                    return urls.contains { $0.isFileURL && $0.isImageFile }
                }
            }
            return false
        }

        func handleDrop(pasteboard: NSPasteboard, at location: NSPoint) -> Bool {
            guard let textView else { return false }
            let localPoint = textView.convert(location, from: nil)
            let caretIndex = textView.characterIndexForInsertion(at: localPoint)
            textView.setSelectedRange(NSRange(location: caretIndex, length: 0))
            return handleImageAttachment(from: pasteboard, source: .drop)
        }

        func handleImageAttachment(from pasteboard: NSPasteboard, source: MarkdownEditor.ImageDropInfo.Source) -> Bool {
            guard let (data, filename) = extractImageData(from: pasteboard) else { return false }
            guard let handler = parent.onImageAttachment else { return false }
            guard let insertion = handler(MarkdownEditor.ImageDropInfo(data: data, filename: filename, source: source)) else { return false }

            guard let textView else { return true }
            let range = textView.selectedRange()
            let markdown = insertion.markdown
            replace(range: range, with: markdown, newSelection: NSRange(location: range.location + markdown.utf16.count, length: 0))
            return true
        }

        private func extractImageData(from pasteboard: NSPasteboard) -> (Data, String?)? {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                for url in urls where url.isFileURL && url.isImageFile {
                    if let data = try? Data(contentsOf: url), let png = data.normalizedPNGData {
                        return (png, url.lastPathComponent)
                    }
                }
            }

            if let items = pasteboard.pasteboardItems {
                for item in items {
                    for type in item.types {
                        if let data = item.data(forType: type), let png = data.normalizedPNGData {
                            return (png, nil)
                        }
                    }
                }
            }
            return nil
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
            let prefixLength = (prefix as NSString).length
            let suffixLength = (suffix as NSString).length

            let inlineFormatting = prefix.rangeOfCharacter(from: .newlines) == nil &&
                                   suffix.rangeOfCharacter(from: .newlines) == nil

            var effectiveRange = coreRange
            var trailingWhitespace = ""

            if inlineFormatting, effectiveRange.length > 0 {
                let whitespaceSet = CharacterSet.whitespacesAndNewlines
                let selectedFull = ns.substring(with: effectiveRange) as NSString
                var trimCount = 0
                var index = selectedFull.length - 1

                while index >= 0 {
                    let unicodeValue = UnicodeScalar(UInt32(selectedFull.character(at: index)))
                    guard let unicodeValue, whitespaceSet.contains(unicodeValue) else { break }
                    trimCount += 1
                    index -= 1
                }

                if trimCount > 0 {
                    trailingWhitespace = selectedFull.substring(from: selectedFull.length - trimCount)
                    let newLength = max(0, effectiveRange.length - trimCount)
                    effectiveRange = NSRange(location: effectiveRange.location, length: newLength)
                }
            }

            let selected = effectiveRange.length > 0 ? ns.substring(with: effectiveRange) : ""
            let selectedNSString = selected as NSString

            if effectiveRange.length >= prefixLength + suffixLength {
                let startRange = NSRange(location: effectiveRange.location, length: prefixLength)
                let endRange = NSRange(location: effectiveRange.location + effectiveRange.length - suffixLength, length: suffixLength)
                let hasInlineWrapper = ns.substring(with: startRange) == prefix && ns.substring(with: endRange) == suffix

                if hasInlineWrapper {
                    let innerLocation = effectiveRange.location + prefixLength
                    let innerLength = effectiveRange.length - prefixLength - suffixLength
                    let innerRange = NSRange(location: innerLocation, length: innerLength)
                    let innerText = innerLength > 0 ? ns.substring(with: innerRange) : ""
                    let innerNSString = innerText as NSString
                    let replacement = innerText + trailingWhitespace
                    replace(range: coreRange,
                            with: replacement,
                            newSelection: NSRange(location: coreRange.location, length: innerNSString.length))
                    return
                }
            }

            if prefixLength > 0, suffixLength > 0,
               effectiveRange.location >= prefixLength,
               effectiveRange.location + effectiveRange.length + suffixLength <= ns.length {
                let prefixRange = NSRange(location: effectiveRange.location - prefixLength, length: prefixLength)
                let suffixRange = NSRange(location: effectiveRange.location + effectiveRange.length, length: suffixLength)
                let hasExternalWrapper = ns.substring(with: prefixRange) == prefix && ns.substring(with: suffixRange) == suffix

                if hasExternalWrapper {
                    let totalRange = NSRange(location: prefixRange.location,
                                             length: prefixLength + effectiveRange.length + suffixLength)
                    replace(range: totalRange,
                            with: selected,
                            newSelection: NSRange(location: prefixRange.location, length: selectedNSString.length))
                    return
                }
            }

            let wrapped = prefix + selected + suffix
            let replacement = wrapped + trailingWhitespace
            let caretLocation = coreRange.location + prefixLength
            let caretLength = selectedNSString.length
            replace(range: coreRange,
                    with: replacement,
                    newSelection: NSRange(location: caretLocation, length: caretLength))
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

        // MARK: - Backtick handling

        func handleBacktickPress() -> Bool {
            guard let textView else { return false }
            let range = textView.selectedRange()

            // Only handle if there's a selection
            guard range.length > 0 else { return false }

            backtickTimer?.invalidate()
            backtickCount += 1

            backtickTimer = Timer.scheduledTimer(withTimeInterval: backtickTimeWindow, repeats: false) { [weak self] _ in
                self?.applyBacktickFormatting()
            }

            // Prevent default backtick insertion
            return true
        }

        private func applyBacktickFormatting() {
            guard let textView else { return }

            if backtickCount == 1 {
                // Single backtick = styled inline code (double backticks)
                wrapSelection(prefix: "``", suffix: "``")
            } else if backtickCount == 3 {
                // Triple backtick = code block
                wrapSelection(prefix: "\n```\n", suffix: "\n```\n")
            }
            // Two backticks do nothing (as per requirements)

            backtickCount = 0
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
            defer { suppressTextDidChange = false }

            guard textView.shouldChangeText(in: range, replacementString: string) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: string)
            textView.didChangeText()
            textView.setSelectedRange(newSelection)

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
            defer { suppressTextDidChange = false }

            let currentSelection = selection ?? textView.selectedRange()
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)

            if textView.shouldChangeText(in: fullRange, replacementString: string) {
                textView.textStorage?.replaceCharacters(in: fullRange, with: string)
                textView.didChangeText()
            }

            let nsString = string as NSString
            let safeLocation = min(currentSelection.location, nsString.length)
            let safeLength = min(currentSelection.length, max(0, nsString.length - safeLocation))
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
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

private extension Data {
    var normalizedPNGData: Data? {
        if isPNG { return self }
        guard let image = NSImage(data: self),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    private var isPNG: Bool {
        guard count >= 4 else { return false }
        let first = self[startIndex]
        let secondIndex = self.index(after: startIndex)
        let second = self[secondIndex]
        let thirdIndex = self.index(secondIndex, offsetBy: 1)
        let third = self[thirdIndex]
        let fourthIndex = self.index(thirdIndex, offsetBy: 1)
        let fourth = self[fourthIndex]
        return first == 0x89 && second == 0x50 && third == 0x4E && fourth == 0x47
    }
}

private extension URL {
    var isImageFile: Bool {
        if #available(macOS 11.0, *), let type = try? resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        let ext = pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"].contains(ext)
    }
}

private final class MarkdownLayoutManager: NSLayoutManager {
        private static let trimmingSet = CharacterSet.whitespacesAndNewlines

        override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>,
                                              count rectCount: Int,
                                              forCharacterRange charRange: NSRange,
                                              color: NSColor) {
            guard let textContainer = textContainers.first,
                  let textView = textContainer.textView,
                  let textStorage = textStorage else {
                super.fillBackgroundRectArray(rectArray,
                                               count: rectCount,
                                               forCharacterRange: charRange,
                                               color: color)
                return
            }

            let selectedRanges = textView.selectedRanges.map { $0.rangeValue }
            var intersectionFound = false
            var trimmedRects: [NSRect] = []

            for selection in selectedRanges {
                let intersection = NSIntersectionRange(selection, charRange)
                guard intersection.length > 0 else { continue }
                intersectionFound = true
                trimmedRects.append(contentsOf: makeTrimmedRects(for: intersection,
                                                                  textStorage: textStorage,
                                                                  textContainer: textContainer))
            }

            guard intersectionFound else {
                super.fillBackgroundRectArray(rectArray,
                                               count: rectCount,
                                               forCharacterRange: charRange,
                                               color: color)
                return
            }

            guard !trimmedRects.isEmpty else {
                return
            }

            let origin = textView.textContainerOrigin
            color.setFill()
            for rect in trimmedRects {
                let adjusted = NSRect(x: rect.origin.x + origin.x,
                                      y: rect.origin.y + origin.y,
                                      width: rect.width,
                                      height: rect.height)
                NSBezierPath(rect: adjusted).fill()
            }
        }

        private func makeTrimmedRects(for characterRange: NSRange,
                                      textStorage: NSTextStorage,
                                      textContainer: NSTextContainer) -> [NSRect] {
            guard characterRange.length > 0 else { return [] }

            let nsString = textStorage.string as NSString
            var rects: [NSRect] = []
            var cursor = characterRange.location
            let upperBound = characterRange.location + characterRange.length

            while cursor < upperBound {
                var lineStart = 0
                var lineEnd = 0
                var contentsEnd = 0
                nsString.getLineStart(&lineStart,
                                      end: &lineEnd,
                                      contentsEnd: &contentsEnd,
                                      for: NSRange(location: cursor, length: 0))

                let segmentStart = max(cursor, lineStart)
                let segmentEnd = min(upperBound, lineEnd)

                if segmentStart < segmentEnd {
                    var visibleEnd = contentsEnd
                    while visibleEnd > lineStart,
                          let scalar = UnicodeScalar(UInt32(nsString.character(at: visibleEnd - 1))),
                          MarkdownLayoutManager.trimmingSet.contains(scalar) {
                        visibleEnd -= 1
                    }

                    let clampedEnd = min(segmentEnd, visibleEnd)
                    if clampedEnd > segmentStart {
                        let trimmedRange = NSRange(location: segmentStart,
                                                   length: clampedEnd - segmentStart)
                        let glyphRange = glyphRange(forCharacterRange: trimmedRange,
                                                    actualCharacterRange: nil)

                        if glyphRange.length > 0 {
                            enumerateEnclosingRects(forGlyphRange: glyphRange,
                                                    withinSelectedGlyphRange: glyphRange,
                                                    in: textContainer) { rect, _ in
                                rects.append(rect)
                            }
                        }
                    }
                }

                if segmentEnd < lineEnd, segmentEnd < upperBound {
                    cursor = segmentEnd
                } else {
                    cursor = lineEnd
                }
            }

            return rects
        }

    }

    final class MarkdownTextView: NSTextView {
        weak var coordinator: MarkdownEditor.Coordinator?

        convenience init() {
            self.init(frame: .zero, textContainer: nil)
        }

        override init(frame frameRect: NSRect, textContainer: NSTextContainer?) {
            if let container = textContainer {
                super.init(frame: frameRect, textContainer: container)
            } else {
                let storage = NSTextStorage()
                let layoutManager = MarkdownLayoutManager()
                let container = NSTextContainer()
                layoutManager.addTextContainer(container)
                storage.addLayoutManager(layoutManager)
                super.init(frame: frameRect, textContainer: container)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        var handlePaste: ((NSPasteboard) -> Bool)?
        var canAcceptDrag: ((NSPasteboard) -> Bool)?
        var handleDrop: ((NSPasteboard, NSPoint) -> Bool)?

        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            if handlePaste?(pasteboard) == true { return }
            super.paste(sender)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            if let canAccept = canAcceptDrag, canAccept(sender.draggingPasteboard) {
                return .copy
            }
            return super.draggingEntered(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let canAccept = canAcceptDrag, canAccept(sender.draggingPasteboard) {
                return true
            }
            return super.prepareForDragOperation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let handler = handleDrop, handler(sender.draggingPasteboard, sender.draggingLocation) {
                return true
            }
            return super.performDragOperation(sender)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                clearUndoRegistrations()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            if newSuperview == nil {
                clearUndoRegistrations()
            }
            super.viewWillMove(toSuperview: newSuperview)
        }

        private func clearUndoRegistrations() {
            var seenManagers: Set<ObjectIdentifier> = []
            let managers = [undoManager, window?.undoManager].compactMap { $0 }

            for manager in managers {
                let identifier = ObjectIdentifier(manager)
                if seenManagers.contains(identifier) { continue }
                seenManagers.insert(identifier)

                manager.removeAllActions(withTarget: self)
                if let storage = textStorage {
                    manager.removeAllActions(withTarget: storage)
                }
            }
        }

        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            // Prevent undo/redo crashes when the stack is empty
            let undoSelector = NSSelectorFromString("undo:")
            let redoSelector = NSSelectorFromString("redo:")

            if item.action == undoSelector {
                return undoManager?.canUndo ?? false
            }
            if item.action == redoSelector {
                return undoManager?.canRedo ?? false
            }
            return super.validateUserInterfaceItem(item)
        }

        override func keyDown(with event: NSEvent) {
            // Handle backtick for inline code / code block formatting
            if let characters = event.characters,
               characters == "`",
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               !event.modifierFlags.contains(.option) {
                if coordinator?.handleBacktickPress() == true {
                    return
                }
            }

            // Handle Option+Arrow keys for word/paragraph navigation
            if event.modifierFlags.contains(.option) {
                let shift = event.modifierFlags.contains(.shift)

                switch Int(event.keyCode) {
                case 123: // Left arrow
                    if shift {
                        moveWordBackwardAndModifySelection(nil)
                    } else {
                        moveWordBackward(nil)
                    }
                    return
                case 124: // Right arrow
                    if shift {
                        moveWordForwardAndModifySelection(nil)
                    } else {
                        moveWordForward(nil)
                    }
                    return
                case 125: // Down arrow
                    if shift {
                        moveToEndOfParagraphAndModifySelection(nil)
                    } else {
                        moveToEndOfParagraph(nil)
                    }
                    return
                case 126: // Up arrow
                    if shift {
                        moveToBeginningOfParagraphAndModifySelection(nil)
                    } else {
                        moveToBeginningOfParagraph(nil)
                    }
                    return
                default:
                    break
                }
            }

            super.keyDown(with: event)
        }

    }
