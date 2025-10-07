# SQL Maestro Tabs Feature - Development Handoff

## Original Request

The user requested a **tabbing system** for SQL Maestro to allow working with multiple sets of ticket sessions simultaneously within a single app window.

### Key Requirements:
1. **Maximum 2 tabs** (changed from initial 3)
2. **Each tab = independent workspace** with its own 3 ticket sessions
3. **Tab colors**: Blue for Tab 1, Green for Tab 2
4. **Tab names**: "SQL Maestro 1", "SQL Maestro 2"
5. **Cmd+N** creates a new tab (up to 2 max)
6. **Close button (X)** on each tab when multiple tabs exist
7. **Tabs don't persist** across app restarts (temporary workspaces)
8. **All keyboard shortcuts work only on active tab**
9. **Template changes sync** across tabs when switching
10. **Tab placement**: Inside the title bar area (NOT between title bar and main content)

---

## What Was Implemented

### Files Created:

#### 1. **TabContext.swift**
- Represents a single tab instance
- Contains:
  - `id: UUID` - unique identifier for the tab
  - `sessionManager: SessionManager` - per-tab session manager (3 ticket sessions)
  - `lastTemplateReload: Date` - tracks when this tab last saw a template reload
  - `tabIdentifier: String` - short ID for file naming (first 8 chars of UUID)
  - `markTemplateReloadSeen()` - updates timestamp when tab sees template reload

- **Environment Keys**:
  - `TabIDKey` - passes tab identifier to ContentView
  - `IsActiveTabKey` - tells ContentView if it's the active tab
  - `TabContextKey` - passes entire TabContext to ContentView

#### 2. **TabManager.swift**
- Manages the collection of tabs
- Contains:
  - `maxTabs = 2` - maximum number of tabs allowed
  - `tabs: [TabContext]` - array of tab instances
  - `activeTabIndex: Int` - which tab is currently active
  - `lastTemplateReload: Date` - global timestamp of last template reload
  - `createNewTab()` - creates new tab if under limit
  - `switchToTab(at:)` - switches to specific tab
  - `closeTab(at:)` - closes tab and cleans up resources
  - `notifyTemplateReload()` - called when templates are edited/reloaded
  - `displayName(for:)` - returns "SQL Maestro 1" or "SQL Maestro 2"
  - `color(for:)` - returns .blue for tab 0, .green for tab 1

- **Cleanup Logic**:
  - When tab closes, deletes its session images from disk
  - Adjusts active index if needed

#### 3. **TabContainerView.swift**
- Main container that wraps ContentView
- Contains:
  - Tab bar UI at the top
  - ZStack with all ContentViews (all stay alive, only active visible)
  - "+" button to create new tab (if under limit)
  - Close "X" button on each tab (if more than 1 tab exists)

- **Tab UI**:
  - Colored background and border when active (blue or green)
  - Bold text when active
  - Opacity used to show/hide tabs without destroying them

- **ZStack Approach**:
  - All tabs' ContentViews exist simultaneously
  - Active tab: `opacity(1)` and `allowsHitTesting(true)`
  - Inactive tabs: `opacity(0)` and `allowsHitTesting(false)`
  - This preserves state when switching tabs

### Files Modified:

#### 1. **SQLMaestroApp.swift**
- Changed from displaying `ContentView` directly to `TabContainerView`
- Removed `@StateObject private var sessions = SessionManager()` (now per-tab)
- Kept `@StateObject private var templates = TemplateManager()` (shared across tabs)
- Removed `sessions` parameter from `AppMenuCommands`

#### 2. **MenuCommands.swift**
- Removed `@ObservedObject var sessions: SessionManager` (no longer needed)
- Menu commands now work via NotificationCenter, which is caught by active tab only

#### 3. **ContentView.swift**

**Added Environment Values:**
```swift
@Environment(\.tabID) var tabID
@Environment(\.isActiveTab) var isActiveTab
@Environment(\.tabContext) var tabContext
@EnvironmentObject var tabManager: TabManager
```

**Key Changes:**

1. **Session Image File Naming** (line ~2786):
   - Added tab prefix: `Tab{tabID}_Session1_001.png`
   - Prevents collision when multiple tabs save images

2. **Notification Guards** (lines ~1418-1444, ~8771-8817):
   - All notification handlers check `guard isActiveTab else { return }`
   - Prevents multiple tabs from responding to same menu command

3. **Keyboard Shortcuts** (lines ~1877, 1887, 1898, 1909, 1920):
   - Added `.disabled(!isActiveTab)` to all keyboard shortcut buttons
   - Ensures only active tab responds to Cmd+1, Cmd+2, Cmd+3, Cmd+T, Cmd+F

4. **Toolbar** (line ~1409):
   - Wrapped in `if isActiveTab` to prevent duplicate sidebar toggle icons

5. **Template Reload Detection** (lines ~1369-1391):
   - `onChange(of: isActiveTab)` handler
   - When tab becomes active, checks if templates were reloaded while inactive
   - If stale, refreshes `selectedTemplate` reference to point to new object

6. **Template Save Notification** (lines ~6707-6710):
   - Calls `tabManager.notifyTemplateReload()` when template is edited
   - Updates current tab's `lastTemplateReload` timestamp

7. **App Exit Dialog** (line ~8634-8642):
   - Shows which tab has unsaved changes
   - Warns user to check other tabs manually

---

## What's Working

✅ **Tab Creation/Switching/Closing** - works correctly
✅ **Independent Session Data** - each tab has own 3 ticket sessions
✅ **Session Image Naming** - no collisions with tab-specific prefixes
✅ **Tab Colors** - blue for tab 1, green for tab 2
✅ **State Persistence** - tabs maintain state when switching
✅ **Keyboard Shortcuts** - fixed to work only on active tab
✅ **Template Manager Shared** - all tabs see same query templates
✅ **Template Reload Sync** - tabs refresh when templates edited in other tab
✅ **Notification Isolation** - only active tab responds to menu commands
✅ **Guide Notes/Links/Tags** - shared via global singletons, visible across tabs
✅ **Share/Import Session** - works with active tab
✅ **Cmd+Shift+K** - clears only current session (not all 3)
✅ **Safety Checks** - includes unsaved links and DB tables

---

## Known Issues / Still Broken

### 🔴 CRITICAL: Tab Placement in UI

**Problem**: Tabs are currently sitting below the title bar and above the main content area. User wants them **inside** the title bar itself.

**Location**: The tabs should occupy the space in the native macOS title bar (the gray area with red/yellow/green traffic lights).

**Current Implementation**: `TabContainerView` has a `tabBar` view that sits at the top of a VStack.

**What Needs to Change**:
- Remove the tab bar from TabContainerView's VStack
- Integrate tabs into the native macOS title bar area
- This likely requires using `NSWindowController` or `NSWindow` customization
- See `MainWindowConfigurator` in `SQLMaestroApp.swift` (lines 100-184) - this already customizes the window

**Approach**:
1. Create a custom `NSView` or `NSHostingView` for the tab bar
2. Add it to `window.titlebarAccessoryViewController`
3. Or use `.toolbar(id:)` with a custom toolbar identifier
4. Remove existing `tabBar` from `TabContainerView`

**Reference**: User provided image showing red square where tabs should go (in title bar region)

---

### ⚠️ Potential Issues

#### 1. **App Exit Safety Check - Only Checks Active Tab**
**Current Behavior**: When quitting the app, only the active tab's unsaved changes are detected.

**Dialog Message**: "Unsaved changes detected in SQL Maestro 1/2 - Note: Only the active tab is checked. Please review other tabs before exiting."

**Ideal Solution**: Collect unsaved flags from ALL tabs and show consolidated dialog.

**Implementation Approach**:
- When `.attemptAppExit` notification fires, don't show dialog immediately
- Instead, collect `UnsavedFlags` from all tabs
- Coordinate via TabManager or a global coordinator
- Show single dialog listing all tabs with unsaved changes
- Allow user to review/save each tab or exit

**Challenge**: Each ContentView has its own state - hard to query from outside. Might need to:
- Add `currentUnsavedFlags()` method to TabContext
- Have TabContext expose this via TabManager
- Or use NotificationCenter request-reply pattern

---

#### 2. **Keyboard Shortcuts Might Still Have Edge Cases**
**What Was Fixed**: Added `.disabled(!isActiveTab)` to main keyboard shortcuts

**Potential Issue**: There might be OTHER keyboard shortcuts scattered throughout the codebase that weren't updated.

**To Verify**: Test ALL keyboard shortcuts with 2 tabs open:
- Cmd+F (search)
- Cmd+1, 2, 3 (panes)
- Cmd+T (sidebar)
- Cmd+E (toggle preview)
- Cmd+Shift+K (clear session)
- Cmd+S (save session)
- Cmd+L (load session)
- Cmd++ / Cmd+- (font size)
- Any others listed in keyboard shortcuts sheet

**Search Pattern**: Look for `.keyboardShortcut(` throughout ContentView.swift and ensure all have `.disabled(!isActiveTab)`

---

#### 3. **Performance with 2 Large ContentViews**
**Concern**: ContentView is massive (12,421 lines). Having 2 instances alive simultaneously might use significant memory.

**Monitor**:
- Memory usage with 1 vs 2 tabs
- Any UI lag when switching tabs
- First tab creation is instant, second might be slow

**If Performance Issues**:
- Consider lazy loading (only create ContentView when tab first activated)
- But this complicates state management
- Current approach (ZStack with all alive) is simplest and should be acceptable

---

#### 4. **Template Manager Shared - Race Conditions?**
**Current**: All tabs share same TemplateManager instance

**Scenario**:
1. Tab 1 is editing template
2. Tab 2 tries to select same template
3. Tab 1 saves, calls `templates.loadTemplates()`
4. Tab 2's `selectedTemplate` reference becomes stale

**Current Solution**: Tab 2 will refresh its `selectedTemplate` when it becomes active (if stale)

**Potential Issue**: What if Tab 2 is ACTIVE while Tab 1 saves in background?
- This can't happen with current UI (modal edit sheet blocks)
- But good to be aware of

**To Test**:
- Open template editor in Tab 1
- Try to interact with Tab 2 (should be blocked by modal sheet)

---

## Architecture Overview

```
SQLMaestroApp
  └── WindowGroup
      └── TabContainerView
          ├── Tab Bar (VStack)
          │   ├── Tab Buttons (blue/green)
          │   └── New Tab Button (+)
          │
          └── Content Area (ZStack)
              ├── ContentView #1 (Tab 1 - opacity 1 or 0)
              │   ├── TemplateManager (shared EnvironmentObject)
              │   ├── SessionManager #1 (per-tab EnvironmentObject)
              │   ├── TabManager (shared EnvironmentObject)
              │   ├── tabID: String (environment value)
              │   ├── isActiveTab: Bool (environment value)
              │   └── tabContext: TabContext #1 (environment value)
              │
              └── ContentView #2 (Tab 2 - opacity 1 or 0)
                  ├── TemplateManager (SAME shared instance)
                  ├── SessionManager #2 (different per-tab instance)
                  ├── TabManager (SAME shared instance)
                  ├── tabID: String (environment value)
                  ├── isActiveTab: Bool (environment value)
                  └── tabContext: TabContext #2 (environment value)
```

### Data Flow:

**Shared Across Tabs**:
- TemplateManager - query templates loaded from disk
- TemplateLinksStore.shared - template links
- TemplateTagsStore.shared - template tags
- TemplateGuideStore.shared - guide notes per template
- DBTablesStore.shared - database tables
- All other `.shared` singletons

**Per-Tab (Independent)**:
- SessionManager - 3 ticket sessions with dynamic fields, notes, images, etc.
- All @State variables in ContentView (selected template, SQL, UI state, etc.)

**Coordination**:
- TabManager tracks `lastTemplateReload` timestamp
- Each TabContext tracks its own `lastTemplateReload` timestamp
- When tab becomes active, compares timestamps to detect stale state
- If stale, refreshes `selectedTemplate` reference

---

## Testing Checklist

### Essential Tests:
- [ ] Create 2 tabs, verify they're independent
- [ ] Switch between tabs, verify state persists
- [ ] Close tab 2, verify tab 1 still works
- [ ] Test Cmd+1, 2, 3 on each tab independently
- [ ] Test Cmd+N creates new tab (stops at 2)
- [ ] Edit template in Tab 1, switch to Tab 2, verify it updates
- [ ] Add session image in each tab, verify no filename collisions
- [ ] Try to quit with unsaved changes, verify dialog shows
- [ ] Test Cmd+Shift+K clears only current session
- [ ] Test share/import session works on correct tab

### Keyboard Shortcuts (test on each tab):
- [ ] Cmd+F - search
- [ ] Cmd+1 - guide notes
- [ ] Cmd+2 - session notes
- [ ] Cmd+3 - saved files
- [ ] Cmd+T - toggle sidebar
- [ ] Cmd+E - toggle preview
- [ ] Cmd+Shift+K - clear session
- [ ] Cmd+S - save session
- [ ] Cmd+L - load session
- [ ] Cmd++ / Cmd+- - font size

### Edge Cases:
- [ ] Create tab 2, close tab 1, verify tab 2 becomes active
- [ ] Create tab 2, close tab 2, verify tab 1 stays active
- [ ] Switch tabs rapidly - any UI glitches?
- [ ] Heavy data in tab 1, create tab 2 - performance OK?

---

## Code Locations Reference

### Tab System Core:
- `TabContext.swift` - Tab model + environment keys
- `TabManager.swift` - Tab collection management
- `TabContainerView.swift` - Tab UI and switching

### ContentView Changes:
- Lines 1215-1219: Environment values added
- Lines 1369-1391: Template reload detection
- Lines 1409-1419: Toolbar conditional
- Lines 1877-1923: Keyboard shortcuts with isActiveTab guards
- Lines 1418-1444: Notification guards
- Lines 2786-2791: Session image file naming
- Lines 6707-6710: Template reload notification
- Lines 8634-8642: App exit dialog
- Lines 8764-8817: Notification bridge with guards

### App Structure:
- `SQLMaestroApp.swift` lines 203-206: Uses TabContainerView
- `MenuCommands.swift` line 6: Removed sessions parameter

---

## Next Steps for Implementation

### Priority 1: Move Tabs to Title Bar
This is the most critical remaining issue.

**Steps**:
1. Study `MainWindowConfigurator` in `SQLMaestroApp.swift`
2. Research `NSWindow.titlebarAccessoryViewController`
3. Create custom tab bar view as NSView or NSHostingView
4. Add to window's title bar area
5. Remove existing tab bar from TabContainerView
6. Test that tabs appear in title bar correctly
7. Ensure tab switching still works

**Resources**:
- Apple Docs: [NSWindow Title Bar Accessories](https://developer.apple.com/documentation/appkit/nswindow)
- Look at how other macOS apps (Safari, Xcode) implement tabs in title bar

### Priority 2: Comprehensive App Exit Check
Collect unsaved flags from all tabs before showing exit dialog.

**Approach**:
1. Add `getUnsavedFlags() -> UnsavedFlags` method to TabContext
2. Have TabManager collect from all tabs
3. Modify `attemptAppExit()` to use TabManager
4. Show which tabs have changes
5. Optionally allow switching to each tab to review

### Priority 3: Full Keyboard Shortcut Audit
Search entire ContentView.swift for `.keyboardShortcut(` and ensure all have proper guards.

---

## Final Notes

**State Management Philosophy**:
- Keep all tabs alive (ZStack) for simple state persistence
- Use environment values to tell each ContentView if it's active
- Disable interactions and shortcuts for inactive tabs
- Share read-only global data (templates, guides, tags, links)
- Keep mutable session data separate per tab

**Why ZStack Not TabView?**:
- SwiftUI's TabView would destroy/recreate views on switch
- ZStack keeps all views alive, just hides inactive ones
- Simpler state management, no need for state restoration

**Performance Considerations**:
- 2 ContentViews alive = 2x memory
- But ContentView is mostly UI code, not heavy data
- Data (templates, sessions) is minimal
- Should be acceptable for 2 tabs

---

## Questions for Future Developer

1. **Tab Persistence**: Should tabs eventually persist across app restarts?
   - Currently NO - fresh start each launch
   - If YES later: need to serialize tab state to disk

2. **Tab Limit**: Why 2 tabs max?
   - User wants 6 sessions total (2 tabs × 3 sessions)
   - Could make configurable in future

3. **Tab Colors**: Why blue/green specifically?
   - User preference from existing color palette
   - Could make customizable later

4. **Global vs Per-Tab**: What about other features?
   - Mapping (org/mysql) - currently global
   - User config (DB credentials) - currently global
   - Should any of these be per-tab?

---

## Contact / Questions

If you need clarification on any part of this handoff:
- User wants tabs in the title bar (see annotated image)
- All keyboard shortcuts must work per-tab
- Template changes should sync across tabs
- Each tab is completely independent otherwise

Good luck! 🚀
