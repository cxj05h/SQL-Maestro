# Title Bar Content Bleed - Final Status

**STATUS: UNSOLVED AFTER 11 ATTEMPTS**

## The Problem

Text content from scrollable panes bleeds through **two separate title bars**:

1. **Hard Stop Title Row** - The topmost dark bar (where sidebar toggle button sits)
2. **Session/Template Title Bar** - The purple-bordered bar below showing Session/Company/Active Template

### What Bleeds Through:
- ✅ **Alternate Fields Pane**: Field names and values (text only)
- ✅ **Session & Template Pane**: Link URLs, image filenames (text only)
- ❌ **Does NOT bleed**: Pane backgrounds, borders, titles, buttons, tab selectors

### Root Cause:
SwiftUI Text views inside NSHostingView (within NSScrollView) render in sublayers that escape ALL clipping attempts - both SwiftUI `.clipShape()` and AppKit `layer.masksToBounds`.

## Code Locations

- **Hard Stop Row**: `ContentView.swift:1662-1666` (`hardStopTitleRow`)
- **Session/Template Bar**: `ContentView.swift:1729-1785` (ZStack in `mainDetailContent`)
- **Alternate Fields Pane**: `ContentView.swift:4580-4663` (uses `NonBubblingScrollView`)
- **Session & Template Pane**: `ContentView.swift:4666-4706` (uses `ScrollView`)
- **NonBubblingScrollView**: `ContentView.swift:971-1053`

## All Failed Attempts

### Session 1 Attempts (Initial Agent):
1. ❌ Added `.background(Theme.grayBG)` and `.zIndex(1)` to session/template bar
2. ❌ Added `layer.masksToBounds = true` to NonBubblingScrollView, clip view, and hosting view
3. ❌ Added `.clipShape(RoundedRectangle)` to both panes
4. ❌ Moved session/template bar to overlay with `titleBarOverlay` and spacer
5. ❌ Added `.drawingGroup()` to all scrollable content VStacks/LazyVStacks

### Session 2 Attempts (Current Agent):
6. ❌ Restructured `detailContent` to use ZStack with hard stop row overlaid on top
7. ❌ Changed hard stop row from `Color.clear.background()` to `Rectangle().fill()`
8. ❌ Created `OpaqueBarOverlay` NSViewRepresentable with `zPosition = 1000`
9. ❌ Added `viewDidMoveToSuperview()` to NonBubblingNSScrollView to force layer clipping
10. ❌ Added transparent AppKit blocker layer at title bar positions
11. ❌ (All layer manipulation attempts in AppKit and SwiftUI)

## Why Nothing Works

The fundamental issue is **text rendering bypasses layer clipping**:

1. SwiftUI Text views render via Core Text
2. Core Text can render in sublayers that have different clipping contexts
3. When NSHostingView hosts SwiftUI content in NSScrollView, text sublayers escape the scroll view's clip bounds
4. Neither SwiftUI `.clipShape()` nor AppKit `layer.masksToBounds` affect these sublayers
5. Z-positioning doesn't work because the text is rendering **on top of** the layer where we set z-position

## Potential Solutions (Untested)

### Option A: Prevent Scrolling Into Top Region
Instead of trying to clip or layer, prevent panes from scrolling content into the bleed zone:

```swift
// In NonBubblingNSScrollView
override var documentVisibleRect: NSRect {
    var rect = super.documentVisibleRect
    let minY: CGFloat = 150  // Height of both title bars
    if rect.origin.y < minY {
        rect.origin.y = minY
    }
    return rect
}
```

###Option B: Solid Background Rectangles in Scroll Content
Add opaque backgrounds at the top of each scrollable pane's content:

```swift
// Inside NonBubblingScrollView content
VStack {
    Rectangle()
        .fill(Theme.grayBG)
        .frame(height: 150)  // Covers title bar area

    // Actual content...
}
```

### Option C: Use CALayer Masking Directly
Override the layer rendering for the hosting view:

```swift
// In NonBubblingScrollView makeNSView
hosting.layer = CALayer()
hosting.layer?.mask = CAShapeLayer()  // with appropriate bounds
```

### Option D: Replace NonBubblingScrollView with Custom Solution
Build a completely custom scroll view that doesn't use NSHostingView, avoiding the layer mixing entirely.

### Option E: Move Panes Lower
Simplest non-technical solution - add padding to push panes down so they never scroll high enough to bleed through title bars:

```swift
// In alternateFieldsPane and sessionAndTemplatePane
VStack {
    // content
}
.padding(.top, 200)  // Prevent scrolling into title bar zone
```

## Recommendation

Try **Option E** first (add top padding) as it's the simplest and most likely to work immediately. If that's acceptable visually, it solves the problem without fighting the rendering engine.

If that's not acceptable, try **Option A** (prevent scrolling into top region) to maintain current layout while blocking the bleed programmatically.

## Current State

Repository is **clean** - all attempts have been reverted.
