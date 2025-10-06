# Handoff: Styled Inline Code Implementation

## Context
User requested double-backtick markdown syntax (`` ``code`` ``) to render as "styled inline code" - essentially inline code with the same visual treatment as code blocks (padding, border, rounded corners) but shrink-wrapped around the text instead of full-width.

## What's Been Implemented

### 1. Parser Changes (MarkdownUI Library)
**File**: `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Parser/MarkdownParser.swift`

#### Preprocessing (Lines 15-35)
- Added `preprocessStyledCode()` function that converts `` ``code`` `` to `⟪STYLED⟪code⟫STYLED⟫` markers
- Uses regex pattern: `(?<!`)``(?!`)([^`]+)``(?!`)`
- Runs before cmark parsing
- **Note**: Currently has `[PREPROCESSING-RAN]` debug marker prepended (line 17) - REMOVE THIS

#### InlineNode Enum (Lines 3-14 in InlineNode.swift)
**File**: `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Parser/InlineNode.swift`
- Added new case: `.styledCode(String)` (line 8)

#### Text Node Detection (Lines 151-166 in MarkdownParser.swift)
- Modified `.text` case to detect `⟪STYLED⟪...⟫STYLED⟫` markers
- Uses `contains()` + `range(of:)` to find and extract content
- Converts to `.styledCode(content)` nodes
- **Works correctly** - markers ARE being detected and converted

#### Reverse Conversion (Lines 422-426)
- Added `.styledCode` case in `make(_ inline: InlineNode)` function
- Converts back to marker format for rendering markdown

### 2. Renderer Changes

#### AttributedStringInlineRenderer.swift (Lines 52-53)
**File**: `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Renderer/AttributedStringInlineRenderer.swift`
- Added case for `.styledCode` - renders as regular code in AttributedString

#### TextInlineRenderer.swift (Lines 63-65)
**File**: `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Renderer/TextInlineRenderer.swift`
- Added case for `.styledCode` - passes to default rendering

### 3. View Rendering (THE PROBLEM AREA)

#### InlineText.swift
**File**: `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Views/Inlines/InlineText.swift`

**What was added:**

**StyledCodeView** (Lines 3-20):
```swift
private struct StyledCodeView: View {
  let content: String
  let fontSize: CGFloat

  var body: some View {
    Text(content)
      .font(.system(size: fontSize, design: .monospaced))
      .foregroundColor(.black)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color(white: 0.85))
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.purple.opacity(0.2), lineWidth: 1)
      )
  }
}
```

**Modified body** (Lines 37-69):
- Detects if inlines contain `.styledCode` nodes
- If yes, uses `styledInlineContent` view
- If no, uses original text rendering

**styledInlineContent** (Lines 71-79):
- Uses `HStack` with grouped inline nodes
- Renders `.styledCode` as `StyledCodeView`
- Renders other nodes as `Text`

**Helper functions**:
- `renderInlineSegments()` (Lines 86-112)
- `groupInlineNodes()` (Lines 119-144)

### 4. Editor Changes

#### MarkdownEditor.swift
**File**: `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/MarkdownEditor.swift`

**Keyboard shortcut** (Line 474):
- Single backtick press wraps with ```` `` ````

**Toolbar button** (Line 15):
- `inlineCode()` function wraps with ```` `` ````

## Current Status

### ✅ What Works
1. Double backtick syntax is recognized and parsed
2. Markers are correctly converted to `.styledCode` nodes
3. Styled code boxes render with correct styling (padding, border, rounded corners)
4. Keyboard shortcut (single backtick) inserts double backticks
5. Toolbar button inserts double backticks

### ❌ What's Broken

**Critical Issue: Text Between Styled Code Disappears**

**Example:**
- **Editor**: `` ``test`` `` test `` ``test test`` `` test
- **Preview**: Shows styled boxes for "test" and "test test" but the plain text "test" between them is missing

**Root Cause**:
Using `HStack` to mix `StyledCodeView` (custom view with padding/border) and `Text` views breaks SwiftUI's natural text flow. The `HStack`:
- Doesn't understand baseline alignment for inline text
- Doesn't handle text wrapping properly
- Causes spacing/alignment issues
- Text segments get sized incorrectly or don't render

**Secondary Issue: Line Spacing**
- Lines are too close together
- Text overlaps vertically
- Lost the natural markdown text spacing

## The Fundamental Problem

**You cannot mix custom SwiftUI views (with padding/borders) and Text views while maintaining proper inline text flow.**

SwiftUI's `Text` has special layout behavior for inline rendering. Once you introduce custom views with `.padding()`, `.background()`, `.overlay()`, you break out of that text layout system.

## Attempted Solutions (All Failed)

1. **HStack with .fixedSize** - Text disappears
2. **ViewThatFits with HStack/VStack** - Requires macOS 13.0+, same layout issues
3. **Aggressive text node detection** - Detection works, rendering still broken
4. **Text concatenation with +** - Can't apply padding/background to Text and still concatenate

## Possible Solutions to Explore

### Option A: Abandon Custom Views, Use AttributedString
**Approach**: Style inline code using only `AttributeContainer` attributes (no custom views)
- ✅ Maintains text flow
- ❌ Can't add padding/borders/rounded corners (AttributedString doesn't support these)
- **Verdict**: Won't achieve the desired "shrink-wrapped code block" look

### Option B: Custom TextLayout with NSAttributedString
**Approach**: Use AppKit's `NSAttributedString` with custom attributes and render using `NSTextView`
- ✅ Full control over rendering
- ✅ Can add custom decorations
- ❌ Very complex implementation
- ❌ Have to replace entire InlineText rendering system
- **Verdict**: Possible but extremely complex, high risk

### Option C: Overlay-Based Approach
**Approach**: Render text normally, then overlay styled boxes on top of code segments
- Render all text as regular `Text` (maintains flow)
- Calculate positions of `.styledCode` segments
- Overlay boxes with `GeometryReader`
- ✅ Text flow preserved
- ❌ Very complex position calculation
- ❌ Fragile, breaks with font changes
- **Verdict**: Hacky but might work

### Option D: Accept Limitations and Use Simpler Styling
**Approach**: Give inline code a different background color and maybe bold font, but no padding/borders
- ✅ Easy to implement (just modify TextStyle)
- ✅ Maintains text flow perfectly
- ❌ Doesn't meet original requirement of "code block look"
- **Verdict**: Fallback option if others fail

### Option E: HTML/WebKit Rendering
**Approach**: Convert markdown to HTML and render in WKWebView
- ✅ Full CSS control (easy to style)
- ✅ Proper text flow
- ❌ Major architectural change
- ❌ Lose MarkdownUI integration
- **Verdict**: Too drastic

### Option F: Custom Layout Protocol (macOS 13.0+)
**Approach**: Implement custom `Layout` that understands inline text flow
- Create custom layout that positions views inline
- Handle wrapping, baseline alignment
- ✅ Proper control
- ❌ Complex implementation
- ❌ Requires macOS 13.0+
- **Verdict**: Most promising if macOS version requirement acceptable

## Recommended Next Steps

1. **Immediate**: Remove `[PREPROCESSING-RAN]` debug marker (line 17 in MarkdownParser.swift)

2. **Try Option F first** (if macOS 13.0+ acceptable):
   - Implement custom `Layout` protocol
   - Create inline text flow layout
   - Handle wrapped text properly
   - Keep `StyledCodeView` but use proper layout

3. **If Option F fails, try Option C**:
   - Revert to pure Text rendering
   - Add overlay system for styled boxes
   - Use GeometryReader for positioning

4. **Fallback to Option D** if all else fails:
   - Simple text styling, no padding/borders
   - At least it works and looks decent

## Code Locations Reference

### Files Modified
1. `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Parser/InlineNode.swift`
2. `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Parser/MarkdownParser.swift`
3. `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Renderer/AttributedStringInlineRenderer.swift`
4. `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Renderer/TextInlineRenderer.swift`
5. `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/ThirdParty/MarkdownUI/swift-markdown-ui-main/Sources/MarkdownUI/Views/Inlines/InlineText.swift`
6. `/Users/chrisjones/Documents/Projects/SQLMaestro/SQLMaestro/MarkdownEditor.swift`

### Key Code Patterns

**Marker Format**: `⟪STYLED⟪content⟫STYLED⟫`

**Detection Pattern**:
```swift
if text.contains("⟪STYLED⟪") && text.contains("⟫STYLED⟫") {
  if let startRange = text.range(of: "⟪STYLED⟪"),
     let endRange = text.range(of: "⟫STYLED⟫", range: startRange.upperBound..<text.endIndex) {
    let content = String(text[startRange.upperBound..<endRange.lowerBound])
    self = .styledCode(content)
  }
}
```

**Rendering Target**: Monospace font, 6px horizontal padding, 2px vertical padding, light gray background, 4px rounded corners, purple border

## Testing Notes

- Test with: `` ``test`` `` (single word)
- Test with: `` ``test test`` `` (multiple words)
- Test with: `` ``test`` `` some text `` ``more`` `` (mixed content) ← THIS BREAKS
- Triple backticks still work for code blocks
- Single backticks NOT used anymore (toolbar/keyboard insert double)

## Original Requirement

User wanted inline code to look like "code blocks but shrink-wrapped" - same styling (monospace, background, padding, border, rounded corners) but fitting tightly around the text instead of being full-width blocks.

## Token Usage
This handoff created at approximately 127K/200K tokens used.

---

Good luck! The hard part (parsing, detection) is done. The challenge is purely layout/rendering. Consider Option F (custom Layout) first if macOS version allows.
