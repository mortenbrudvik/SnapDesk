# SnapDesk v2 Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Four features that close the gap with PowerToys Workspaces and fix SnapDesk's own biggest limitation — restore documents and URLs, restore fullscreen windows, launch a workspace from a hotkey or at startup, and browse every workspace you own.

**Architecture:** Each feature extends what is already there rather than adding a layer. Two optional fields join `SavedWindow` (`document`, `fullscreen`), which stay backward and forward compatible because Swift's synthesised Codable omits nil and ignores unknown keys — no schema version bump. Restore gains one step before placement (open the document) and one after (apply fullscreen). Quick launch and the library are `AppSettings` plus UI; neither touches the restore engine.

**Tech Stack:** Swift 6 strict concurrency, AppKit + SwiftUI, Accessibility, XCTest under `TEST_HOST`, XcodeGen.

**Spec:** this plan carries its own design; the competitive analysis behind it is `docs/research/powertoys-workspaces.md`. The v1 design is `docs/superpowers/specs/2026-09-09-snapdesk-design.md`, whose non-goal "Capturing open documents, URLs, or Finder folders" Phase B deliberately reverses.

## Global Constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`; everything with state is `@MainActor`.
- `.snapdesk` stays schema version 1. New fields are `Optional` and additive only.
- A restore must never write to the workspace file. Anything that changes per launch lives in `UserDefaults`.
- After adding or removing any file: `xcodegen generate`.
- Test with `SNAPDESK_REQUIRE_AX=1 TEST_RUNNER_SNAPDESK_REQUIRE_AX=1 xcodebuild -scheme SnapDesk -destination 'platform=macOS' test`. A plain run hides a missing Accessibility grant.
- Every behaviour change is written test-first, and verified by reverting the behaviour and confirming a named test fails.

## Measured, before planning

Probed on 2026-09-10 against the machine's running apps, from inside the app so the Accessibility grant applied. These decide Phases A and B.

| App | `AXFullScreen` present | settable | `AXDocument` |
|---|---|---|---|
| Finder, Notes, Passwords, Safari | yes | yes | empty |
| Brave Browser | yes | yes | the page URL |
| Terminal | yes | yes | the working directory |
| TextEdit | yes | yes | the open file |
| Activity Monitor, System Settings | yes | **no** | empty |
| Cursor, Claude, Magnetar | yes | yes | a non-URL string |

Three conclusions the plan depends on:

1. `AXFullScreen` exists on every window tested and is settable on most. Fixed-size utility windows refuse it, exactly as they refuse zoom, so it needs the same read-back discipline `WindowPlacement.ensureZoomed` uses.
2. `AXDocument` is on the **window** — no tree walk. It is populated for a useful subset and empty for Safari, which exposes neither `AXDocument` nor `AXURL` to an ordinary client.
3. `AXDocument` can hold a string that is not a URL at all, so every read must be validated before it reaches the document.

## Where each phase comes from

Two of these close a gap with PowerToys; two go past it. Worth keeping straight, because the second pair has no reference implementation to check against.

| Phase | Origin |
|---|---|
| A — Fullscreen | Past parity. They store `isMaximized`, which is SnapDesk's `zoomed`. True fullscreen is a macOS concept with no Windows counterpart, and nothing currently records it. |
| B — Documents and URLs | Past parity. The research doc's own line: "Restoring a browser to a URL is a manual step in both." Their `CommandLineArgsHelper` can read a running process's command line and nothing calls it. This is the feature that makes a cold start reproduce every window. |
| C — Quick launch | Answers the "pinnable launcher" gap, differently. macOS has no one-click Dock item beside your apps for a document, so the equivalents are a hotkey and a workspace that opens when SnapDesk starts. |
| D — Workspace library | Answers the "workspace library" and "timestamps" gaps directly, the second by storing the date outside the file. |

Left where it was: their windows visibly jump after launching because no API launches a window into position. SnapDesk has the same constraint and already answers it the same way, with a HUD.

## File Structure

| File | Responsibility |
|---|---|
| `SnapDesk/Core/WorkspaceDocument.swift` | gains `SavedWindow.document` and `.fullscreen`, and validation for both |
| `SnapDesk/Core/AXWindow.swift` | gains `documentURL` and `fullscreenState` / `setFullScreen` |
| `SnapDesk/Core/CaptureService.swift` | records both new fields |
| `SnapDesk/Core/LaunchService.swift` | opens documents before claiming; applies fullscreen in `WindowPlacement.apply` |
| `SnapDesk/Core/DocumentOpening.swift` | **new** — the seam for `NSWorkspace.open(urls:withApplicationAt:)` |
| `SnapDesk/Support/AppSettings.swift` | startup workspace, workspace hotkey bindings |
| `SnapDesk/Support/WorkspaceLibrary.swift` | **new** — folder scan, last-launched dates, ordering |
| `SnapDesk/Input/HotkeyName.swift` | five assignable workspace shortcut names |
| `SnapDesk/UI/EditorView.swift` | document field per row; library sidebar |
| `SnapDesk/UI/SettingsWindow.swift` | startup workspace and shortcut assignment |
| `SnapDesk/UI/HelpContent.swift` | a topic per feature; troubleshooting entries for the new failures |

---

## Phase A — Fullscreen windows

Smallest of the four, and it establishes the optional-field pattern Phase B reuses.

### Task A1: `SavedWindow.fullscreen`

**Files:** Modify `SnapDesk/Core/WorkspaceDocument.swift`; Test `SnapDeskTests/WorkspaceDocumentTests.swift`

**Interfaces:** Produces `SavedWindow.fullscreen: Bool?` — nil means "not recorded", which is what every existing file says.

- [x] **Step 1: Write the failing test**

```swift
/// The field is optional so that every file written before it existed still opens, and a file
/// written now still opens in a build that has never heard of it — Swift's synthesised Codable
/// omits a nil and ignores a key it does not know.
func testFullscreenIsOptionalInBothDirections() throws {
    let old = try WorkspaceDocument.decode(Data(specJSON.utf8))
    XCTAssertNil(old.windows[0].fullscreen, "a file without the key must decode")

    var updated = old
    updated.windows[0].fullscreen = true
    let text = try XCTUnwrap(String(data: updated.encoded(), encoding: .utf8))
    XCTAssertTrue(text.contains("\"fullscreen\" : true"))

    XCTAssertEqual(try WorkspaceDocument.decode(updated.encoded()).windows[0].fullscreen, true)
}

/// And a nil is absent rather than null, so a workspace that records nothing new is byte-identical
/// to what the previous build wrote.
func testAWindowWithNoFullscreenStateWritesNoKey() throws {
    let document = try WorkspaceDocument.decode(Data(specJSON.utf8))
    let text = try XCTUnwrap(String(data: document.encoded(), encoding: .utf8))
    XCTAssertFalse(text.contains("fullscreen"))
}
```

- [x] **Step 2: Run and watch it fail**

Run: `xcodebuild … test -only-testing:SnapDeskTests/WorkspaceDocumentTests`
Expected: FAIL, `value of type 'SavedWindow' has no member 'fullscreen'`

- [x] **Step 3: Add the field**

```swift
struct SavedWindow: Codable, Equatable, Sendable {
    // … existing fields …
    /// Whether the window was in true fullscreen. Nil in every file written before this existed,
    /// which is not the same as false: a window recorded before the field was added should be
    /// left alone rather than forced out of fullscreen on restore.
    var fullscreen: Bool?
}
```

- [x] **Step 4: Run and watch it pass**
- [x] **Step 5: Commit** — `git commit -m "feat: record whether a window was fullscreen"`

### Task A2: Reading and writing fullscreen over Accessibility

**Files:** Modify `SnapDesk/Core/AXWindow.swift`; Test `SnapDeskTests/AXWindowTests.swift`

**Interfaces:** Produces `AXWindow.fullscreenState: Bool?` and `setFullScreen(_:) -> AXError`.

- [x] **Step 1: Write the failing test** (needs the Accessibility grant, like the rest of that file)

```swift
/// Unlike zoom, fullscreen *is* a real attribute — measured present on every window tested, and
/// settable on all but fixed-size utility windows. So it is read, not inferred.
func testFullscreenRoundTripsOnOurWindow() throws {
    let policy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.regular)
    addTeardownBlock { @MainActor in NSApp.setActivationPolicy(policy) }

    let window = makeWindow()
    let ax = try axWindow(for: window)
    XCTAssertEqual(ax.fullscreenState, false)

    XCTAssertEqual(ax.setFullScreen(true), .success)
    waitUntil("the window to enter fullscreen") { ax.fullscreenState == true }

    XCTAssertEqual(ax.setFullScreen(false), .success)
    waitUntil("the window to leave fullscreen") { ax.fullscreenState == false }
}

/// A read that failed is nil, never false — the same rule `minimizedState` follows, and for the
/// same reason: this value goes to disk.
func testFullscreenIsNilForAWindowThatCannotBeRead() throws {
    let window = makeWindow()
    let ax = try axWindow(for: window)
    window.close()
    XCTAssertNil(ax.fullscreenState)
}
```

- [x] **Step 2: Run and watch it fail** — no member `fullscreenState`
- [x] **Step 3: Implement**

```swift
/// macOS *does* vend this one, unlike zoom: "AXFullScreen" is present on every window measured
/// and settable on all but fixed-size windows. The SDK declares no constant for it, so the string
/// is a literal here for the same reason `AXEnhancedUserInterface` is.
private static let fullScreenAttribute = "AXFullScreen"

var fullscreenState: Bool? {
    boolValue(element, Self.fullScreenAttribute)
}

@discardableResult
func setFullScreen(_ fullscreen: Bool) -> AXError {
    let result = setBool(Self.fullScreenAttribute, fullscreen)
    if result != .success {
        Log.ax.notice("could not set AXFullScreen=\(fullscreen) (AXError \(result.rawValue))")
    }
    return result
}
```

- [x] **Step 4: Run and watch it pass**, with `TEST_RUNNER_SNAPDESK_REQUIRE_AX=1`
- [x] **Step 5: Commit**

### Task A3: Capture and restore it

**Files:** Modify `SnapDesk/Core/CaptureService.swift`, `SnapDesk/Core/LaunchService.swift`; Test `SnapDeskTests/CaptureServiceTests.swift`, `SnapDeskTests/LaunchServiceTests.swift`

**Interfaces:** Consumes A1 and A2. `AXWindowSnapshot` gains `fullscreen: Bool?`; `PlaceableWindow` gains `fullscreenState` and `setFullScreen`.

- [x] **Step 1: Write the failing capture test**

```swift
func testFullscreenIsRecordedFromTheSnapshot() {
    let full = snapshot(cgWindowID: 10, title: "Docs", cocoaFrame: display.visibleFrame, fullscreen: true)
    let service = CaptureService(
        apps: FakeApps(running: [safari]),
        ax: FakeAX(windowsByPid: [safari.pid: [full]]),
        order: FakeOrder(ids: [10]),
        displays: FakeDisplays(live: [display])
    )

    XCTAssertEqual(service.capture().document.windows.map(\.fullscreen), [true])
}
```

- [x] **Step 2: Write the failing placement tests**

```swift
/// Fullscreen is applied last, after the frame — entering it replaces the frame entirely, so
/// writing the frame afterwards would be undone by the window server.
func testASlotSavedFullscreenEntersFullscreenAfterTheFrameIsWritten() async {
    let window = FakeAXWindow()
    let clock = ScriptedClock()
    clock.onSleep = { poll in if poll == 2 { window.fullscreenState = true } }
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

    let outcome = await WindowPlacement.apply(
        to: window, cocoaFrame: frame, minimized: false, zoomed: false, fullscreen: true,
        bundleIdentifier: safariID, clock: clock
    )

    XCTAssertEqual(outcome, .placed)
    XCTAssertEqual(window.frameWrites, [frame])
    XCTAssertEqual(window.fullscreenAtFrameWrite, [false], "the frame must be written before fullscreen")
}

/// A window that refuses fullscreen — Activity Monitor and System Settings both do — is on its
/// frame, so it reports the same partial success a refused zoom does.
func testAFullscreenThatNeverTakesIsReportedAsStateNotRestored() async {
    let window = FakeAXWindow()
    let clock = ScriptedClock()

    let outcome = await WindowPlacement.apply(
        to: window, cocoaFrame: CGRect(x: 10, y: 20, width: 300, height: 200),
        minimized: false, zoomed: false, fullscreen: true,
        bundleIdentifier: safariID, clock: clock
    )

    XCTAssertEqual(outcome, .stateNotRestored)
    XCTAssertEqual(clock.sleeps, 40, "bounded like every other state wait")
}

/// A workspace written before the field existed says nothing about fullscreen, and must not drag
/// a window out of it.
func testANilFullscreenLeavesTheWindowAlone() async {
    let window = FakeAXWindow()
    window.fullscreenState = true

    _ = await WindowPlacement.apply(
        to: window, cocoaFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
        minimized: false, zoomed: false, fullscreen: nil,
        bundleIdentifier: safariID, clock: ScriptedClock()
    )

    XCTAssertEqual(window.fullscreenState, true)
    XCTAssertEqual(window.fullscreenWrites, 0)
}
```

- [x] **Step 3: Run both and watch them fail**
- [x] **Step 4: Implement**

Fullscreen needs a new field on `AXWindowSnapshot`, and zoom is the reason it is worth saying why. Zoom is never read — `CaptureService` infers it with `AXWindow.isZoomed(frame:on:)` by comparing the frame to the display, because macOS vends no zoom attribute. Fullscreen does have one, so it is read from the window and carried like `minimized`.

- `AXWindowSnapshot` gains `fullscreen: Bool?`, filled by the real `AXCapturing` implementation from `AXWindow.fullscreenState`.
- The `snapshot(...)` helper in `CaptureServiceTests` gains a `fullscreen: Bool? = false` parameter, so the existing call sites keep compiling.
- `CaptureService.capture(name:)` carries it into `SavedWindow`.
- `WindowPlacing.place` and `WindowPlacement.apply` gain `fullscreen: Bool?`, applied after the frame under a bounded read-back:

```swift
if let fullscreen {
    restoredState = await ensureFullScreen(ax, wanted: fullscreen, id: id, clock: clock) && restoredState
}
```

- [x] **Step 5: Run, watch pass, then mutation-check** — revert the ordering so fullscreen is applied before the frame and confirm `testASlotSavedFullscreenEntersFullscreenAfterTheFrameIsWritten` fails.
- [x] **Step 6: Editor row + help** — a Fullscreen toggle beside Minimized and Zoomed in `WindowSlotRow`, and a `HelpContent` line saying a fullscreen window returns to its own Space, which macOS chooses.
- [x] **Step 7: Commit**

---

## Phase B — Documents and URLs

The feature that fixes "a cold start often yields one window where you saved three": opening a document creates the window, rather than hoping the app restores its own session.

### Task B1: `SavedWindow.document`

**Files:** Modify `SnapDesk/Core/WorkspaceDocument.swift`; Test `SnapDeskTests/WorkspaceDocumentTests.swift`

- [x] **Step 1: Write the failing tests**

```swift
func testDocumentIsOptionalAndRoundTrips() throws {
    var document = try WorkspaceDocument.decode(Data(specJSON.utf8))
    XCTAssertNil(document.windows[0].document)

    document.windows[0].document = "https://github.com/mortenbrudvik/SnapDesk"
    XCTAssertEqual(try WorkspaceDocument.decode(document.encoded()).windows[0].document,
                   "https://github.com/mortenbrudvik/SnapDesk")
}

/// `AXDocument` can hold a string that is not a URL at all — measured on three apps. A value that
/// cannot be opened must not reach the restore path, where it would be handed to LaunchServices.
func testADocumentThatIsNotAUsableURLIsRejected() throws {
    var document = try WorkspaceDocument.decode(Data(specJSON.utf8))
    for bad in ["", "   ", "not a url", "javascript:alert(1)"] {
        document.windows[0].document = bad
        XCTAssertThrowsError(try document.validate(), "accepted \(bad)")
    }
    for good in ["https://example.com", "file:///Users/me/notes.txt", "/Users/me/notes.txt"] {
        document.windows[0].document = good
        XCTAssertNoThrow(try document.validate(), "rejected \(good)")
    }
}
```

- [x] **Step 2: Run and watch it fail**
- [x] **Step 3: Add the field and `validate()` rule** — accept `http`, `https`, `file`, or an absolute path; reject everything else, naming the window in the message the way the other rules do.
- [x] **Step 4: Run and watch it pass**
- [x] **Step 5: Commit**

### Task B2: Capturing a document

**Files:** Modify `SnapDesk/Core/AXWindow.swift`, `SnapDesk/Core/CaptureService.swift`; Test `SnapDeskTests/AXWindowTests.swift`, `SnapDeskTests/CaptureServiceTests.swift`

**Interfaces:** Produces `AXWindow.documentURL: String?`, read from `AXDocument` on the window itself.

- [x] **Step 1: Write the failing tests**

```swift
/// Measured: `AXDocument` sits on the window, not deep in the tree — Brave puts the page URL
/// there, Terminal its working directory, TextEdit the open file. Safari puts nothing.
func testDocumentURLComesFromTheWindow() throws {
    let window = makeWindow()
    let ax = try axWindow(for: window)
    XCTAssertNil(ax.documentURL, "a plain NSWindow has no document")
}
```

```swift
func testACapturedDocumentIsRecordedAndAnUnusableOneIsNot() {
    let withURL = snapshot(cgWindowID: 10, title: "Docs", cocoaFrame: someFrame, document: "https://example.com")
    let withJunk = snapshot(cgWindowID: 11, title: "Junk", cocoaFrame: someFrame, document: "Untitled 3")
    // … capture …
    XCTAssertEqual(doc.windows.map(\.document), ["https://example.com", nil])
}
```

- [x] **Step 2: Run and watch them fail**
- [x] **Step 3: Implement** — `documentURL` reads `kAXDocumentAttribute` through the existing `stringValue` path; `AXWindowSnapshot` gains `document: String?` and the test helper a matching defaulted parameter; `CaptureService` keeps the value only when it passes the same check `validate()` applies, so a capture can never produce a document the loader would reject (the invariant `testCaptureNeverRecordsAWindowValidationWouldReject` already pins for sizes).
- [x] **Step 4: Run and watch pass**
- [x] **Step 5: Commit**

### Task B3: Opening the document on restore

**Files:** Create `SnapDesk/Core/DocumentOpening.swift`; Modify `SnapDesk/Core/LaunchService.swift`, `SnapDesk/Core/LaunchPlanner.swift`; Test `SnapDeskTests/LaunchServiceTests.swift`

**Interfaces:** Produces the seam over the one AppKit call that can put a document into an app that is *already running* — which is the whole reason this works where arguments do not:

```swift
@MainActor
protocol DocumentOpening {
    func open(_ url: URL, withApplicationAt app: URL, configuration: NSWorkspace.OpenConfiguration) async throws
}
```

`NSWorkspaceDocumentOpener` wraps `NSWorkspace.shared.open(_:withApplicationAt:configuration:)` in production; `FakeDocumentOpener` records calls in tests.

- [x] **Step 1: Write the failing tests**

```swift
/// The point of the whole phase. Arguments only reach a *new* instance, so a running app ignores
/// them; opening a document works either way, which is what makes a cold start reproduce every
/// window instead of one.
func testASlotWithADocumentOpensItRatherThanRelyingOnTheAppsOwnSession() async {
    let launcher = FakeLauncher()
    launcher.urls = [safariID: URL(fileURLWithPath: safariPath)]
    let opener = FakeDocumentOpener()
    let windows = FakeWindows(windowsByBundle: [:])
    let clock = ScriptedClock()
    windows.vend(docsWindow, afterPolls: 2, on: clock)
    let service = makeService(launcher: launcher, opener: opener, windows: windows, clock: clock)

    let result = await service.launch(
        makeDocument(moveExistingWindows: true, windows: [safariSlot(title: "Docs", document: "https://example.com/docs")])
    ) { _ in }

    XCTAssertEqual(result.map(\.status), [.placed(.clean)])
    XCTAssertEqual(opener.opened.map(\.url.absoluteString), ["https://example.com/docs"])
    XCTAssertTrue(launcher.opens.isEmpty, "opening a document launches the app; a second open is wasted work")
}

/// Two slots of one app with two documents open two documents, which is exactly the case a cold
/// start could not reproduce before.
func testEverySlotWithADocumentGetsItsOwnOpen() async { /* … two slots, assert two opens … */ }

/// A slot with no document behaves exactly as it does today.
func testASlotWithNoDocumentStillLaunchesTheAppNormally() async { /* … assert opener untouched … */ }

/// A refused open is a slot failure the user can act on, not a silent fallthrough into the
/// window wait.
func testADocumentThatCannotBeOpenedFailsTheSlot() async {
    // opener throws → .failed(.documentFailed)
}
```

- [x] **Step 2: Run and watch them fail**
- [x] **Step 3: Implement**
  - `LaunchAction` gains `.openDocument(url: URL, arguments: [String], newInstance: Bool)`, chosen by `LaunchPlanner` whenever a slot has a document. A document slot always opens on its own, even under `moveExistingWindows`, because that is how the second window comes into being.
  - `SlotFailure` gains `.documentFailed` with display text "Could not open document", which `HelpContent` must then explain or `testTroubleshootingExplainsEveryFailureTheHUDCanShow` fails.
  - `LaunchService` calls the opener in the launch loop, under the same `open(at:)` timeout treatment so a hung LaunchServices cannot stall the restore.
- [x] **Step 4: Run and watch pass**
- [x] **Step 5: Mutation-check** — make `LaunchPlanner` ignore `document` and confirm the first test fails.
- [x] **Step 6: Commit**

### Task B4: The editor field, and being honest about repeats

**Files:** Modify `SnapDesk/UI/EditorView.swift`, `SnapDesk/UI/HelpContent.swift`; Test `SnapDeskTests/EditorWindowTests.swift`, `SnapDeskTests/HelpContentTests.swift`

- [x] **Step 1: Write the failing tests** — a Document field on each row commits through a binding that rejects a value `validate()` would refuse, the way `WindowSizeField` already clamps sizes; and the help explains that restoring twice may leave a browser with the page open twice.
- [x] **Step 2: Run and watch fail**
- [x] **Step 3: Implement** the field and the help entry.
- [x] **Step 4: Run and watch pass**
- [x] **Step 5: Commit**

---

## Phase C — Quick launch

No schema change; `AppSettings` and `HotkeyCenter` already carry everything needed.

### Task C1: Five assignable workspace shortcuts

**Files:** Modify `SnapDesk/Input/HotkeyName.swift`, `SnapDesk/Input/HotkeyCenter.swift`, `SnapDesk/Support/AppSettings.swift`; Test `SnapDeskTests/HotkeyNameTests.swift`, `SnapDeskTests/AppSettingsTests.swift`

**Design:** five fixed names (`workspace1` … `workspace5`), each optionally bound to a workspace by bookmark in `UserDefaults`. Fixed rather than one-per-workspace because `KeyboardShortcuts.Name` is a persisted identity, and minting one per file would leak a binding every time a workspace is deleted.

- [x] **Step 1: Write the failing tests** — the five names have distinct raw values and no default shortcut; assigning a workspace stores a bookmark that survives a reload; clearing it removes the binding; a shortcut whose workspace file is gone reports the same "could not be found" alert as a stale recent.
- [x] **Step 2: Run and watch fail**
- [x] **Step 3: Implement** — `WorkspaceShortcuts` in `AppSettings`, storing a bookmark per slot. `RecentsStore` already has this logic in `StoredRecent`, `persist()` and `load(from:)`, keyed by `Key.bookmarks` and `Key.paths`. Extract it into one bookmark helper both call rather than writing it twice — a second copy of stale-bookmark handling is a second thing to get wrong.
- [x] **Step 4: Run and watch pass**
- [x] **Step 5: Commit**

### Task C2: Restore a workspace at startup

**Files:** Modify `SnapDesk/Support/AppSettings.swift`, `SnapDesk/App/AppDelegate.swift`, `SnapDesk/UI/SettingsWindow.swift`; Test `SnapDeskTests/AppDelegateTests.swift`

**Design:** "Restore this workspace when SnapDesk starts", not "at login". SnapDesk cannot reliably tell a login launch from any other, and a setting that means what it says is better than one that guesses.

- [x] **Step 1: Write the failing test**

```swift
/// Drains through the same buffer a double-clicked file uses, so a startup restore cannot begin
/// before the status item and hot keys exist.
func testAStartupWorkspaceIsRestoredOnceLaunchCompletes() async throws {
    let url = try writeWorkspace(makeDocument(name: "Coding"))
    let fixture = makeFixture(startupWorkspace: url)

    XCTAssertTrue(fixture.restorer.launched.isEmpty, "not before the app is wired")
    fixture.delegate.completeLaunch()
    await fixture.delegate.launchChain?.value

    XCTAssertEqual(fixture.restorer.launched.map(\.document.name), ["Coding"])
}

func testNoStartupWorkspaceRestoresNothing() async { /* … */ }
```

- [x] **Step 2: Run and watch fail**
`makeFixture` gains `startupWorkspace: URL? = nil`, threaded into `AppDelegate.Dependencies` as a `() -> URL?`, because that is how every other environment dependency in this delegate is injected.

- [x] **Step 3: Implement** — `completeLaunch()` enqueues the startup workspace after draining `pendingOpens`, so a double-clicked file wins over the startup default.
- [x] **Step 4: Run and watch pass**
- [x] **Step 5: Settings UI + help topic**
- [x] **Step 6: Commit**

---

## Phase D — Workspace library

### Task D1: Last-launched dates, outside the file

**Files:** Create `SnapDesk/Support/WorkspaceLibrary.swift`; Test `SnapDeskTests/WorkspaceLibraryTests.swift`

**Design:** the date lives in `UserDefaults`, keyed by resolved path — deliberately unlike PowerToys, which writes `lastLaunchedTime` into the workspace. A restore that rewrites your file dirties version control, breaks a read-only file, and changes a document you did not edit.

- [x] **Step 1: Write the failing tests** — recording a launch stores a date; the date survives a reload; a file renamed on disk keeps its date through its bookmark; entries for files that no longer exist are pruned on load.
- [x] **Step 2: Run and watch fail**
- [x] **Step 3: Implement**
- [x] **Step 4: Run and watch pass**
- [x] **Step 5: Commit**

### Task D2: A folder of workspaces

**Files:** Modify `SnapDesk/Support/WorkspaceLibrary.swift`, `SnapDesk/UI/EditorView.swift`, `SnapDesk/UI/EditorWindow.swift`; Test `SnapDeskTests/WorkspaceLibraryTests.swift`, `SnapDeskTests/EditorWindowTests.swift`

- [x] **Step 1: Write the failing tests** — scanning a folder lists every `.snapdesk` in it and no other file; the list merges the folder with recents without duplicating a file present in both; ordering is most-recently-launched first with never-launched last, by name; a folder the user has not chosen yields recents alone, exactly as today.
- [x] **Step 2: Run and watch fail**
- [x] **Step 3: Implement** — a security-scoped bookmark for the folder, chosen in Settings; the scan is `contentsOfDirectory` filtered on `WorkspaceFileType.fileExtension` rather than a bare `"snapdesk"` literal. Never decode a file just to list it: the display name comes from `RecentNameCache` (in `EditorWindow.swift`), which already caches on modification date.
- [x] **Step 4: Run and watch pass**
- [x] **Step 5: Sidebar** — the existing Recents list becomes a Workspaces list with a Launch button per row, keeping select-to-edit as it is.
- [x] **Step 6: Commit**

---

## Verification, before calling any phase done

- [x] `SNAPDESK_REQUIRE_AX=1 TEST_RUNNER_SNAPDESK_REQUIRE_AX=1 xcodebuild … test` — 0 failures, 0 skipped, 0 warnings.
- [x] Each new behaviour mutation-checked: revert it, confirm a named test fails, restore.
- [x] `HelpContent` covers every new `SlotFailure`, which its own test enforces.
- [x] CLAUDE.md updated for any new invariant, above all the measured Accessibility facts in this plan.
- [x] A workspace written by the new build opens in the previous build, and vice versa.

## Deliberately not in this plan

- **Spaces.** No public API places a window on a Space. It needs private window-server calls, and a fullscreen window already gets its own Space that macOS chooses. PowerToys does not support virtual desktops either.
- **Automatic arguments.** Measured: GUI apps are launched by Finder with no arguments at all, so there is nothing to capture. PowerToys writes an empty string too.
- **Safari URLs without typing.** Safari exposes neither `AXDocument` nor `AXURL` to an ordinary client. Apple Events would work, at the cost of a per-browser Automation prompt, and belong in their own slice if wanted.
- **Snapping to zones.** Neither tool does it, and macOS has no public API for it.

---

## Outcome

Implemented on `feat/snapdesk-v2-features`, twelve commits, 408 tests passing with
0 skipped and 0 warnings in both Debug and Release. Every step above is done. Four
things turned out differently from the plan, each because the code or a measurement
said so:

- **Fullscreen is applied on *both* sides of the frame write, not only after it.**
  The plan had one step after the frame. Entering fullscreen does belong last, since
  the transition replaces the frame — but *leaving* it is a precondition, because a
  fullscreen window swallows a frame write and answers `.success` for it exactly as a
  minimized one does. Both halves are mutation-tested.
- **A fullscreen write that lands mid-transition is accepted and does nothing.**
  Measured while writing the round-trip test, which timed out at 20s with the window
  still fullscreen until it waited for the animation. `ensureFullScreen` reads the
  state back over a 2s bound rather than trusting the write, and the fact is now in
  CLAUDE.md.
- **The editor's document field keeps typed text in the view, not in a binding.**
  The plan said "a binding that rejects a value `validate()` would refuse". A text
  field passes through every prefix of what is being typed, and `h`, `ht`, `htt` are
  each unopenable, so a rejecting binding would erase characters as they were typed.
  The view holds the text; the document takes only what can be opened.
- **A plain bookmark for the nominated folder, not a security-scoped one.** SnapDesk
  cannot be sandboxed — the App Sandbox blocks the Accessibility calls it exists for
  — so there is no scope to reclaim and the start/stop dance would do nothing.

Forward compatibility was verified rather than assumed: a standalone decode against
the pre-feature `SavedWindow` shape confirms an older build reads a file this one
writes, with the schema version still 1.

One thing outside the code: the Accessibility grant for the test host lapsed
mid-session into the "trusted but not applying" state CLAUDE.md describes, which
blocked `AXWindowTests` for part of Phase B. It returned on its own, and the whole
suite including that file has since passed.
