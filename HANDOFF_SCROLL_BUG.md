# Handoff: Codeblock Scroll Bug in Popout Windows

## Current Issue
When markdown is rendered in **popout windows** (GNP/SNP/SFP), hovering the mouse over codeblocks prevents vertical scrolling. This bug does NOT occur in the attached pane view - only in popouts.

### What Works
- ✅ Vertical scrolling works in attached pane view (non-popout)
- ✅ Vertical scrolling works in popout when mouse is NOT over codeblocks
- ✅ Horizontal scrolling works in both pane and popout views (when not using overlay fix)
- ✅ Text selection works in both pane and popout views (when not using overlay fix)

### What's Broken (Current State)
- ❌ Vertical scrolling over codeblocks in popout view was broken
- ⚠️ Current fix (ScrollInterceptorOverlay) restores vertical scrolling BUT breaks:
  - ❌ Horizontal scrolling in codeblocks
  - ❌ Double-click to select words in codeblocks
  - ❌ Other text interactions

## Root Cause Analysis

### Key Finding
SwiftUI's `ScrollView(.horizontal)` used in codeblocks **completely blocks scroll events** from reaching the parent `NonBubblingNSScrollView` when the mouse hovers over it. This happens **only in popout windows**, not in the main pane.

### Responder Chain Difference
The issue stems from how SwiftUI's `ScrollView` handles events differently in sheet/popout windows vs embedded views. In popout windows created via `SheetWindowConfigurator` (see `ContentView.swift:15649`), the event handling chain is isolated differently.

### Logging Evidence
When scrolling over codeblocks in popout:
```
🔵 NonBubblingNSScrollView scrollWheel: deltaY=-21.0, decision=handle, currentY=642.0
🔵 After scroll - newY: 642.0, delta applied: 0.0
```

Events reach `NonBubblingNSScrollView` but `delta applied: 0.0` - scroll happens elsewhere but not when cursor is over codeblock.

## Code Locations

### Codeblock Rendering
**File:** `ContentView.swift:1131-1160`
```swift
private func codeBlock(_ configuration: CodeBlockConfiguration, fill: Color) -> some View {
    ScrollView(.horizontal) {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            // ... markdown styling ...
            .padding(16)
    }
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .overlay(ScrollInterceptorOverlay())  // <-- Current fix attempt
    .markdownMargin(top: 0, bottom: 16)
}
```

### Current Fix Implementation
**File:** `ContentView.swift:1349-1422`

**ScrollInterceptorView** - An invisible overlay that intercepts scroll events:
- Returns `self` from `hitTest()` to receive scroll events
- Overrides `scrollWheel()` to forward vertical scrolls to parent
- Overrides `mouseDown/mouseUp/mouseDragged` to pass through clicks

**Problem:** Returning `self` from `hitTest()` makes it capture ALL events, blocking the underlying ScrollView from receiving mouse events it needs for horizontal scrolling and text selection.

### Parent Scroll View
**File:** `ContentView.swift:1422-1478`

**NonBubblingNSScrollView** - Custom vertical scroll view that:
- Handles vertical scrolling with non-bubbling behavior
- Used for markdown preview in both pane and popout views
- Has sophisticated `scrollDecision()` logic to prevent event bubbling

### Popout Windows
**File:** `ContentView.swift:15660-15730`

**PanePopoutSheet** - Creates the popout window
- Uses `SheetWindowConfigurator` at line 15649
- Creates an isolated window context with separate event handling

## Attempted Solutions (All Failed)

### Attempt 1: `.scrollDisabled(false)`
**Result:** No effect. SwiftUI ScrollView still captured events.

### Attempt 2: `.simultaneousGesture(DragGesture())`
**Result:** No effect. SwiftUI gesture layer didn't help.

### Attempt 3: `.allowsHitTesting(false)`
**Result:** Fixed scrolling BUT:
- ❌ Broke horizontal scrolling completely
- ❌ Broke text selection completely
- ❌ Crashed the app on horizontal scroll attempt

### Attempt 4: Custom `HorizontalOnlyNSScrollView` with `NSViewRepresentable`
**Approach:** Replace SwiftUI ScrollView with custom NSScrollView that intelligently passes vertical events.

**Result:**
- ❌ Codeblocks didn't render at all in preview mode
- The NSViewRepresentable broke the MarkdownUI rendering

### Attempt 5: Custom `CodeBlockNSScrollView` with better implementation
**Similar approach to #4 with improved rendering logic**

**Result:**
- ❌ Same issue - codeblocks didn't render in preview

### Attempt 6: `ScrollInterceptorOverlay` with `hitTest() -> nil`
**Approach:** Transparent overlay that intercepts scroll events

**Result:**
- ❌ Overlay never received scroll events because `hitTest` returning `nil` makes view invisible to ALL events

### Attempt 7 (CURRENT): `ScrollInterceptorOverlay` with `hitTest() -> self`
**Approach:** Overlay returns `self` from hitTest, passes through mouse events manually

**Result:**
- ✅ Vertical scrolling over codeblocks works!
- ❌ Horizontal scrolling broken (overlay intercepts horizontal scroll wheel events)
- ❌ Double-click word selection broken (overlay intercepts double-click)
- ❌ Text selection interactions broken

## What We Know

1. **The fundamental issue:** SwiftUI's `ScrollView` operates at a different layer than AppKit's responder chain
2. **Popout vs Pane difference:** Sheet windows have isolated event handling that behaves differently
3. **NSViewRepresentable breaks rendering:** Replacing SwiftUI ScrollView with NSScrollView breaks MarkdownUI codeblock rendering
4. **hitTest dilemma:**
   - Return `nil`: No events reach overlay (including scroll)
   - Return `self`: All events blocked from underlying views

## Potential Solutions to Explore

### Option A: Selective hitTest
Modify `ScrollInterceptorView.hitTest()` to:
- Return `self` only when the event is a scroll event
- Return `nil` for all other events
- **Challenge:** `hitTest()` doesn't receive event info, only a point

### Option B: Event monitoring at window level
Install a local event monitor on the popout window that intercepts scroll events before they reach the view hierarchy.
- See: `NSEvent.addLocalMonitorForEvents(matching:handler:)`
- Forward vertical scrolls to the parent scroll view
- Let everything else pass through normally

### Option C: Fix the SwiftUI ScrollView directly
Use private APIs or swizzling to modify how SwiftUI's ScrollView handles scroll events in sheet windows.
- **Challenge:** Fragile, may break with SwiftUI updates

### Option D: Different overlay approach
Instead of an NSView overlay, use a gesture recognizer or other mechanism that can distinguish between scroll events and other mouse events.

### Option E: Accept horizontal scrolling limitation
Make codeblocks wrap instead of scroll horizontally, eliminating the need for horizontal scrolling.
- Use `.lineLimit(nil)` or similar
- **Challenge:** May break code formatting readability

### Option F: Investigate responder chain manipulation
When mouse enters codeblock overlay, programmatically modify the responder chain to insert the parent scroll view before the SwiftUI ScrollView.

## Recommended Next Steps

1. **Try Option B first** - Window-level event monitoring is the cleanest approach that doesn't interfere with view hierarchy
2. **If Option B fails, try Option F** - Responder chain manipulation
3. **Last resort: Option E** - Disable horizontal scrolling and wrap codeblocks

## Code References

- **Codeblock rendering:** `ContentView.swift:1131-1160`
- **ScrollInterceptorView:** `ContentView.swift:1349-1422`
- **NonBubblingNSScrollView:** `ContentView.swift:1422-1478`
- **PanePopoutSheet:** `ContentView.swift:15660+`
- **MarkdownPreviewView:** `ContentView.swift:1004-1167`

## Testing Instructions

1. Open app and create/open markdown with codeblocks in GNP or SNP
2. Pop out the pane (click popout icon or use keyboard shortcut)
3. In popout window, hover over a codeblock
4. Test:
   - Vertical scroll (mouse wheel up/down)
   - Horizontal scroll (shift + mouse wheel, or trackpad swipe)
   - Double-click on a word in the codeblock
   - Click and drag to select text

## Glossary (from CLAUDE.md)

- **GNP** = Guide Notes Pane
- **SNP** = Session Notes Pane
- **SFP** = Saved Files Pane
- **POGN** = Popout Guide Notes
- **POSN** = Popout Session Notes
- **POSF** = Popout Saved Files

## Current State

The overlay fix is in place at `ContentView.swift:1158`. To revert it and start fresh:

```swift
// Remove this line:
.overlay(ScrollInterceptorOverlay())

// And remove the classes at lines 1349-1431
```

Good luck! The user needs:
1. Vertical scrolling over codeblocks in popout ✅ (currently working)
2. Horizontal scrolling in codeblocks ❌ (currently broken)
3. Text selection/double-click in codeblocks ❌ (currently broken)
