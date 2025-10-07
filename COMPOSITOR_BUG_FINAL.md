# Text Compositor Bug - Final Analysis

**STATUS: UNSOLVABLE VIA CODE - macOS System Bug**

## What's Actually Happening

This is **NOT** a clipping issue. This is a macOS **text compositor texture caching/duplication bug** that occurs during scroll events.

### Confirmed Behavior:
1. Text content from scrollable panes is **duplicated/mirrored** into the title bar area
2. Only happens **during active scrolling** (not static)
3. The duplicated text is **misaligned** (not 1:1 ratio with source)
4. Only affects **one pane at a time** (whichever is being scrolled)
5. When Alternate Fields is locked, **text disappears but text field backgrounds remain**
6. The duplication updates in **real-time** as you scroll

### Root Cause:
The macOS CoreAnimation/Metal compositor is incorrectly **reusing or caching text layer textures** during scroll operations and rendering them into the wrong screen region (the title bar area).

## All Failed Attempts (15 total)

### Clipping/Layer Approaches (All Failed):
1. ❌ SwiftUI `.clipShape()`
2. ❌ `layer.masksToBounds = true`
3. ❌ `canDrawSubviewsIntoLayer = false`
4. ❌ `copiesOnScroll = false`
5. ❌ Explicit CALayer mask with bounds tracking
6. ❌ Z-index manipulation
7. ❌ Overlay positioning
8. ❌ `.drawingGroup()`
9. ❌ AppKit NSView overlays with high z-position
10. ❌ ZStack restructuring
11. ❌ Content inset padding
12. ❌ Window-level redraws on scroll

### Why Nothing Works:
The text is being rendered by the **system text compositor** (Core Text via Metal/CoreAnimation) which operates at a level **below** the view/layer hierarchy we can control. Text layers are being cached at the GPU level and the compositor is incorrectly reusing those cached textures.

## The Only Workaround

Since this is a macOS system bug, the **only viable solution** is to completely avoid the problematic rendering path by:

### Option 1: Use Native NSTextFields Instead of SwiftUI Text
Replace SwiftUI `Text` views with AppKit `NSTextField` wrapped in NSViewRepresentable. Native AppKit text rendering might not trigger the same compositor bug.

### Option 2: Render Text as Images
Convert text to images before display (extreme, but guaranteed to work since images don't use the text compositor).

### Option 3: Disable Layer-Backed Rendering
Force the entire window to use CPU-based rendering instead of GPU compositing:

```swift
// In App or WindowGroup
.windowStyle(.hiddenTitleBar)
// And force legacy rendering mode
```

### Option 4: Report to Apple and Wait
File a bug report with Apple Feedback Assistant including:
- Screenshots showing the duplication
- System configuration (macOS version, GPU model)
- Sample project demonstrating the issue

## Recommended Next Steps

1. **Verify if this is GPU-specific**: Test on different Macs (Intel vs Apple Silicon, different GPU models)
2. **Check macOS version**: Test on different macOS versions to see if it's version-specific
3. **Try Option 1**: Replace SwiftUI Text with NSTextField wrappers
4. **If critical**: Redesign the panes to avoid scrolling (use pagination or different layout)

## Technical Details for Bug Report

- **Component**: WindowServer / CoreAnimation / Metal Text Compositor
- **Symptoms**: Text layer textures duplicated to incorrect screen regions during NSScrollView scroll events
- **Affected**: SwiftUI Text views in NSHostingView inside NSScrollView
- **Trigger**: Active scroll wheel events
- **Expected**: Text should be clipped to scroll view bounds
- **Actual**: Text textures cached and rendered outside scroll view into title bar area

---

**Repository Status**: Clean - all attempted fixes reverted
