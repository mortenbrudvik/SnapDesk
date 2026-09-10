# PR #1 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is being executed inline by the session that wrote it; each task is red → green → refactor with the commands below.

**Goal:** Resolve every finding of the 2026-09-10 six-agent review of PR #1 (`feat/snapdesk-v1`) — three critical defects, the important restore/app/docs items, the test gaps, and the suggestions — without changing the `.snapdesk` schema.

**Architecture:** Fixes land in the existing seams (`WindowCatalog`, `WindowPlacing`, `RunningApplicationQuerying`, `AXCapturing`, `EditorPrompting`) and add two small ones (`WorkspaceRestoring`, `LaunchHUDPresenting`) so `AppDelegate` becomes constructible in tests. Restore reports outcomes as values (`PlacementOutcome`, `SlotStatus.placed(PlacementNote)`, new `SlotFailure` cases) instead of `Bool`/silence; capture returns a `CaptureOutcome` carrying a `CaptureReport` the editor shows.

**Tech Stack:** Swift 6 (strict concurrency), AppKit + SwiftUI, XCTest under `TEST_HOST`, XcodeGen.

**Spec:** the review summary in this session (recorded in project memory `pr1-review-findings-2026-09-10`); the design spec stays `docs/superpowers/specs/2026-09-09-snapdesk-design.md`.

## Global Constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`; everything with state is `@MainActor`.
- `.snapdesk` schema version stays 1; no field renames.
- Tests: `xcodebuild -project SnapDesk.xcodeproj -scheme SnapDesk -destination 'platform=macOS' -derivedDataPath <scratch>/DerivedData test -only-testing:SnapDeskTests/<Class>`; final run with `TEST_RUNNER_SNAPDESK_REQUIRE_AX=1`.
- After adding or removing any source/test file: `xcodegen generate`.
- No commits unless the user asks.

---

## Phase A — Critical

### Task 1: Restore-side eligibility passes the title-bar-button flag
- Files: `SnapDesk/Core/CaptureCandidate.swift` (remove default), `SnapDesk/Core/LaunchService.swift` (`isStandard`, `AXWindowCatalog`), `SnapDeskTests/AXWindowTests.swift`, `SnapDeskTests/CaptureFilterTests.swift`.
- [x] Test: `AXWindowTests.testTheRestoreCatalogListsARealWindowButNotAChromelessOne` — a `.titled`-only window (no buttons) is absent from `AXWindowCatalog().standardWindows(bundleIdentifier: Bundle.main.bundleIdentifier!)`, a normal window is present.
- [x] Red, then: pass `hasTitleBarButtons: window.hasTitleBarButtons`; drop the default on `CaptureCandidate.hasTitleBarButtons`; drop dead candidate fields (`role`, `isMinimized`, `cgWindowID`, `bundleIdentifier`); read `identity` once per window in the catalog.
- [x] Green; CaptureFilterTests: add `AXUnknown`, `AXSystemDialog`, and the 8pt boundary.

### Task 2: Editor commands refuse while a prompt is up
- Files: `SnapDesk/UI/EditorWindow.swift`, `SnapDeskTests/EditorWindowTests.swift`.
- [x] Test: `testACaptureArrivingWhileTheClosePromptIsUpIsRefusedAndTheAnswerAppliesToTheOriginalSession` — FakePrompt re-enters `controller.open(captured:)` from `saveChoice`; the outer Discard reverts the original; the capture is not applied; a beep was requested.
- [x] Red, then: `isPresentingPrompt` set around every modal (`saveChoice`, `saveDestination`, `report`, trash alert, open panel); `open(captured:)`/`recapture()` guard on it.
- [x] Green.

### Task 3: Capture reports what it could not read
- Files: `SnapDesk/Core/AXWindow.swift` (`windows(pid:) throws`), `SnapDesk/Core/CaptureService.swift` (`AXCapturing.windows(pid:) throws`, raw `AXWindowSnapshot` with optional frame/minimized, `CaptureOutcome`, `CaptureReport`), `SnapDesk/UI/EditorWindow.swift` (show the report), `SnapDesk/App/AppDelegate.swift`, tests `CaptureServiceTests`, `EditorWindowTests`, `AXWindowTests`.
- [x] Tests: app whose list throws → excluded, `report.unreadableApps == ["Safari"]`; window with `minimized: nil` → skipped and counted; zoom inferred in the service against the captured displays; app with empty bundle id → skipped and reported (Task 9 shares this).
- [x] Red, then implement; editor shows "Some windows were not captured" naming the apps; recapture explains an empty capture truthfully.
- [x] Green.

## Phase B — Restore path

### Task 4: Outcomes instead of Bool, notes on placed slots
- `PlacementOutcome { placed, stateNotRestored, windowGone, refused }`; `WindowPlacing.place` returns it; `SlotFailure` gains `stateNotRestored`, `windowGone`, `windowsUnreadable`; `SlotStatus.placed(PlacementNote)` with `isGuess` and `substituteDisplay`; HUD text derives from the status; `LaunchHUD.Row` carries the `SlotStatus`.
- [x] Tests (LaunchServiceTests/LaunchHUDTests): refused zoom → `.failed(.stateNotRestored)`; placer `.windowGone` → `.failed(.windowGone)`; leftover settle → `.placed(isGuess: true)` and cleared on correction; missing display → `substituteDisplay` set; HUD texts.
- [x] Red → green, tests updated for `.placed(.clean)`.

### Task 5: Launch timeout bounds the wait
- [x] Test: a launcher parked on a gate that is never released, `launchTimeout: 50ms` → the restore finishes within 2s with `.launchTimedOut`.
- [x] Red, then: race an unstructured launch `Task` against the timeout through a resume-once continuation; cancel the orphan.

### Task 6: Wall-clock ceiling on the window wait (`RestoreClock.now`)
- [x] Rename `Clock` → `RestoreClock` with `now: ContinuousClock.Instant`; `ScriptedClock` advances virtual time per sleep and via `advance(by:)`.
- [x] Test: a catalog read that costs 500ms of virtual time per poll ends the wait after the 8s deadline (≈16 polls), not 80.
- [x] Also: `Task.isCancelled` counts as a cancel (test: cancel the surrounding task at poll 2 → `.cancelled`).

### Task 7: New-instance restores ignore the pre-existing instance
- [x] `MatchableWindow.pid`; `RunningApplicationQuerying.runningPIDs(bundleIdentifier:)` and `activate(bundleIdentifier:pid:)`; the service snapshots pids before a new-instance open and filters that bundle's pool.
- [x] Test: Safari running (pid 100) with "GitHub"; new instance (pid 200) vends later → the old window is never claimed or moved; `finishedBundles` ignores it.
- [x] Reuse-path test: running app, moveExisting on → no open, `unhidden == [safariID]`, both placed.

### Task 8: Cancel, corrections, unreadable windows
- [x] Test: cancel during placement → `.cancelled`, one placement, `apps.activated.isEmpty` (activateFrontmost moves inside `!stopped`).
- [x] Test: correction placement refused → pending kept, a later window still corrects; correction window upper bound (40 sleeps; vend at 41 not placed).
- [x] Test: catalog throws for a bundle on every poll → `.failed(.windowsUnreadable)`; logged once per bundle.
- [x] `WindowCatalog.standardWindows` throws; `LaunchGate.release` guards on `isHeld` and exposes `waiterCount` (the queued-cancel test spins on it).

### Task 9: Empty bundle id is rejected
- [x] Tests: `validate()` rejects an empty `bundleIdentifier`; capture skips and reports an app without one.
- [x] `LaunchAction.launch` drops unused payload; `SlotPlan` becomes `[LaunchAction]` (planner tests updated).

### Task 10: `ValidatedWorkspace`
- [x] `WorkspaceDocument.validated() throws -> ValidatedWorkspace`; `LaunchService.launch(_: ValidatedWorkspace)`; `WorkspaceOpener.validated(_:) -> Result`; test helpers return the wrapper.

## Phase C — App and UI

### Task 11: Testable `AppDelegate`
- [x] `WorkspaceRestoring`, `LaunchHUDPresenting`; `AppDelegate.init(dependencies:)` + `convenience override init()`; delete `hudPresenter`.
- [x] Tests (new `AppDelegateTests.swift`): chained launches present once and a Cancel abandons the queued one; `launch(url:)` refuses untrusted, adds to recents only after a successful load; alerts carry the filename and cause; an empty workspace alerts instead of flashing the HUD; opens before launch are buffered and drained by `completeLaunch()`.
- [x] `UserAlerting.show(title:detail:)`; `WorkspaceDocumentError.detail`; StatusItemController "File not found" gets the filename.

### Task 12: Settings refresh and window position
- [x] Test: `AppSettings.refresh()` re-reads status without registering; Settings window keeps its frame across `showWindow`.

### Task 13: Relaunch helper only after termination proceeds
- [x] `AccessibilityAuth.relaunch(terminate:)` sets `relaunchPending`; `startRelaunchHelperIfPending()` from `applicationWillTerminate`; `alertPresenter` seam for tests.
- [x] Tests: vetoed quit leaves nothing armed; a proceeding quit spawns once.

### Task 14: Recents
- [x] `RecentEntry` replaces the parallel arrays; `load` dedupes by identity and rewrites; unresolvable bookmark logged; test: a renamed file is still found via its bookmark (drop the claim if `.minimalBookmark` does not follow renames).
- [x] `RecentNameCache` keyed on path + modification date; test: unchanged file not reloaded.

## Phase D — Suggestions

### Task 15: Small fixes with tests
- [x] ArgumentTokenizer: unterminated quote literal; `""` yields an empty argument.
- [x] `validate()` bounds window geometry (`1e300` rejected).
- [x] Delete `ScreenGeometry.axPoint(fromCocoa:)` and its test.
- [x] `LiveDisplay` logs a missing UUID once per identity (`shouldLogFallback`).
- [x] `setMinimized(true)` is read back under the deminiaturize timeout; FakeAXWindow flips minimize via the clock.
- [x] `EditorSession` regenerates `rowIDs` when the window count changes behind its back.
- [x] `WorkspaceFileType` centralises the UTI (`com.brudvik.snapdesk.workspace`) with one logged fallback.
- [x] `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` moves to Release with a comment; Debug keeps `get-task-allow` (verify with `codesign -d --entitlements`).
- [x] `MainActorDelay` does not run work when cancelled; `unhide`/`activate` refusals logged; capture's off-display fallback logged; `.stateUnknown` expiry logged.
- [x] AppIcon asset catalog generated (placeholder), `xcodegen generate`.

### Task 16: Test quality
- [x] EditorWindowTests use `FakePrompt` everywhere and close windows in teardown; LaunchHUDTests dismiss the panel; DisplayMap closest-size test made unambiguous; AXWindowTests `axWindow(for:)` fails (not skips) when the raw read vends the window but the wrapper does not.

## Phase E — Docs and comments

### Task 17
- [x] Spec: 0.5s timeout; filter rules; placement short-circuit. Plan: 0.5s. CLAUDE.md: numbers removed, pin wording, observer timing, new outcomes/seams. Decision record: "an earlier draft", `installMessagingTimeout()` takes no argument, dead-process error code hedged.
- [x] Code comments: stranded zoom doc moved; auth ad-hoc wording; "Matching" → "Launching"; zoomTimeout example; EditorWindow empty-capture wording; WorkspaceDocument displayId wording; docs for `LaunchPlanner.plan`, `CaptureFilter` subroles/8pt, `FramePlacement.restore`, `expectedWindows`.

### Task 18: Verification
- [x] Full suite with `TEST_RUNNER_SNAPDESK_REQUIRE_AX=1`, 0 failures, 0 skips, 0 warnings.
- [x] code-simplifier pass, then `/pr-review-toolkit:review-pr code errors tests` re-run and fix.
