import AppKit

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineIndices: [Int] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)

        self.clientView = textView
        self.ruleThickness = 40
        self.reservedThicknessForMarkers = 0
        self.reservedThicknessForAccessoryView = 0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Observe bounds changes to redraw when scrolling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )

        calculateLineIndices()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textDidChange(_ notification: Notification) {
        calculateLineIndices()
        needsDisplay = true
    }

    @objc private func frameDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    private func calculateLineIndices() {
        guard let textView = textView else { return }
        let text = textView.string as NSString
        lineIndices = [0]

        var index = 0
        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            if lineRange.location != NSNotFound {
                index = NSMaxRange(lineRange)
                if index < text.length {
                    lineIndices.append(index)
                }
            } else {
                break
            }
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        // Background
        NSColor(calibratedWhite: 0.12, alpha: 1.0).setFill()
        bounds.fill()

        // Separator line on the right edge
        NSColor(calibratedWhite: 0.2, alpha: 1.0).setStroke()
        let separatorPath = NSBezierPath()
        separatorPath.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separatorPath.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separatorPath.lineWidth = 1
        separatorPath.stroke()

        let relativePoint = self.convert(NSZeroPoint, from: textView)
        let textInset = textView.textContainerInset

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Line number attributes
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1.0)
        ]

        var lineNumber = 1
        for index in lineIndices {
            if index > visibleCharRange.upperBound {
                break
            }

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

            // Calculate the baseline position for proper alignment
            let yPosition = relativePoint.y + lineRect.origin.y + textInset.height

            // Get the proper baseline offset for the font
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let baselineOffset = (lineRect.height - font.pointSize) / 2

            if yPosition + lineRect.height >= rect.minY && yPosition <= rect.maxY {
                let lineNumberString = "\(lineNumber)" as NSString
                let size = lineNumberString.size(withAttributes: attributes)
                let xPosition = bounds.width - size.width - 8
                let drawPoint = NSPoint(x: xPosition, y: yPosition + baselineOffset)

                lineNumberString.draw(at: drawPoint, withAttributes: attributes)
            }

            lineNumber += 1
        }
    }
}
