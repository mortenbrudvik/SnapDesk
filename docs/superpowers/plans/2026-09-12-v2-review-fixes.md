# v2 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is being executed inline by the session that wrote it; each task is red → green → refactor with the commands below.

**Goal:** Resolve every finding of the 2026-09-12 six-agent review of `feat/snapdesk-v2-features` — five must-fix items, the fifteen important ones, and the suggestions that are well-defined — without changing the `.snapdesk` schema.

**Architecture:** Fixes land in the existing types. `WorkspaceBookmark.resolve` returns the bookmark to persist instead of an `inout` flag, so no caller can forget the rewrite; a `BookmarkedURLSetting` owns the startup-workspace and folder settings; `WorkspaceBookmark.list/store` own the two-parallel-arrays shape. Restore keeps `LaunchAction` but gains `openRequest` so the service stops flattening by hand. The editor's folder panel goes through `EditorPrompting` like the other modals. Documents that a running browser opens as tabs are recorded as a measured fact and the claims around them corrected.

**Tech Stack:** Swift 6 (strict concurrency), AppKit + SwiftUI, XCTest under `TEST_HOST`, XcodeGen.

**Spec:** the review summary in this session (recorded in project memory `pr-v2-review-findings-2026-09-12`); the feature plan stays `docs/superpowers/plans/2026-09-10-snapdesk-v2-features.md`.

## Global Constraints

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`; everything with state is `@MainActor`.
- `.snapdesk` schema version stays 1; no field renames; every new field `Optional` and additive.
- Tests: `xcodebuild -scheme SnapDesk -destination 'platform=macOS' -derivedDataPath <scratch>/DerivedData test -only-testing:SnapDeskTests/<Class>`; final run with `SNAPDESK_REQUIRE_AX=1 TEST_RUNNER_SNAPDESK_REQUIRE_AX=1`.
- On-disk `UserDefaults` keys of every store stay as they are (`recentsBookmarks/recentsPaths` must stay readable by earlier builds).
- After adding or removing any source/test file: `xcodegen generate`. This plan adds none.
- No commits unless the user asks.

---

## Phase A — Critical

### Task 1: The folder panel goes through the prompt guard, via `EditorPrompting`
- Files: `SnapDesk/UI/EditorWindow.swift` (`EditorPrompting.chooseFolder(message:)`, `AppKitEditorPrompt`, `chooseWorkspaceFolder` under `presenting`), `SnapDeskTests/EditorWindowTests.swift` (`FakePrompt.chooseFolder`).
- [x] Test: `testACaptureArrivingWhileTheFolderPanelIsUpIsRefused` — `FakePrompt.chooseFolder` re-enters `controller.open(captured:)`; the capture is refused (beep, session unchanged); the folder is stored and `host.hasWorkspaceFolder` is true afterwards.
- [x] Test: `testStopListingFolderReturnsTheSidebarToRecents` — with a folder listed, `clearWorkspaceFolder()` leaves `library.folder == nil`, `hasWorkspaceFolder == false`, and only recents in `host.recents`.
- [x] Red, then: add `func chooseFolder(message: String) -> URL?` to `EditorPrompting`; `AppKitEditorPrompt` builds the `NSOpenPanel`; `chooseWorkspaceFolder` calls `presenting { prompt.chooseFolder(message:) }`.
- [x] Green.

### Task 2: A workspace in the Trash is gone, everywhere
- Files: `SnapDesk/Support/WorkspaceBookmark.swift` (`resolve` refuses a URL under the volume's Trash), `SnapDesk/Support/AppSettings.swift` (`WorkspaceShortcuts.forget(_:)`), `SnapDesk/Support/WorkspaceLibrary.swift` (`forget(_:)`), `SnapDesk/App/AppDelegate.swift` (`Dependencies.forgetStartupWorkspace`, `forget(_:)`), `SnapDesk/UI/EditorWindow.swift` (`forgetWorkspace` closure called from `moveToTrash`; alert text), tests `AppSettingsTests`, `WorkspaceLibraryTests`, `AppDelegateTests`, `EditorWindowTests`.
- [x] Test: `AppSettingsTests.testAWorkspaceMovedToTheTrashIsReportedMissingRatherThanFound` — assign, `trashItem`, `workspace(for:)` answers a URL whose file does not exist (the original path), never one under `~/.Trash`; teardown removes the trashed item.
- [x] Test: `AppSettingsTests.testAStartupWorkspaceMovedToTheTrashIsNotFound` — same through `AppSettings.startupWorkspace`.
- [x] Test: `AppDelegateTests.testAWorkspaceHotkeyWhoseFileWasTrashedReportsIt` — alert detail is `WorkspaceOpener.missingFileDetail`, nothing restored.
- [x] Test: `AppDelegateTests.testForgettingAWorkspaceClearsItsHotkeyStartupAndLibraryEntries` — `delegate.forget(url)` clears the slot, calls `forgetStartupWorkspace`, and removes the library date.
- [x] Test: `EditorWindowTests.testMovingToTrashForgetsTheWorkspaceEverywhere` — the trash path calls the injected `forgetWorkspace` closure with the file.
- [x] Red, then implement: in `resolve`, a resolved URL inside `FileManager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: resolved, create: false)` is treated as not resolving (log at notice, fall through to the path). `WorkspaceShortcuts.forget` clears every slot whose resolved URL is the same file; `WorkspaceLibrary.forget` drops the entry; `AppDelegate.forget` composes the three; the editor's alert says the hotkey and startup bindings go too.
- [x] Green.

### Task 3: A recapture keeps a hand-typed document
- Files: `SnapDesk/Core/Recapture.swift`, `SnapDeskTests/RecaptureTests.swift`.
- [x] Test: `testARecaptureKeepsTheOldDocumentWhenTheNewCaptureHasNone` and `testARecaptureTakesTheDocumentTheAppVendsNow`.
- [x] Red, then: `if result.document == nil { result.document = old.document }` beside the `arguments` carry-over.
- [x] Green.

### Task 4: `WorkspaceBookmark.resolve` returns what to persist
- Files: `SnapDesk/Support/WorkspaceBookmark.swift` (`struct Resolution { url; bookmark }`, `func resolve() -> Resolution?`), callers in `RecentsStore.swift`, `AppSettings.swift`, `WorkspaceLibrary.swift`; tests `WorkspaceLibraryTests`, `AppSettingsTests`, `RecentsStoreTests` (unchanged behaviour).
- [x] Test: `WorkspaceLibraryTests.testARenamedWorkspaceHasItsNewPathPersistedAfterAReload` — rename, reload, assert `defaults.array(forKey: "libraryPaths")` names the new file and the date survives a second rename.
- [x] Test: `AppSettingsTests.testARenamedWorkspaceHasItsNewPathPersistedInItsSlot` — assert `workspaceShortcutPaths[1]` after rename + reload + read.
- [x] Red, then: `resolve()` re-makes the bookmark when macOS reports it stale *or* the resolved location differs from the stored path (compared with symlinks resolved); every caller persists `resolution.bookmark`; `WorkspaceLibrary.Entry.reference` is the resolution's bookmark.
- [x] Green; `RecentsStoreTests` still green.

### Task 5: Measure what a running browser does with an open, and say so
- Files: `SnapDesk/Core/DocumentOpening.swift` (doc comment), `SnapDesk/UI/HelpContent.swift` ("Document or URL"), `CLAUDE.md` (the "Opening a document" invariant), `docs/superpowers/plans/2026-09-10-snapdesk-v2-features.md` (measured table), `SnapDeskTests/LaunchServiceTests.swift`.
- [x] Measure (done by probe, recorded in the table): `NSWorkspace.open` of a second local file into a running Safari and Brave; Chromium `--new-window` handoff through a new-instance launch.
- [x] Test: `testADocumentOpenThatAddsNoWindowFailsTheSlotAsNoWindow` — two document slots, one pre-existing window, the opener adds nothing → the second slot is `.failed(.noWindow)` after the budget. Pins what the user sees for a browser that opens a tab.
- [x] Rewrite the three texts to what was measured; the help says whether a page comes back as a window or a tab is the app's choice.

### Task 5b: Chromium browsers get a window, through the seam
- Measured on this machine: `NSWorkspace.open` of a second file into a running Safari (3 windows) and Brave (1 window) changed neither count — both open a tab. A new-instance launch of Brave with `--new-window <file>` raised the running instance's count from 1 to 2: Chromium's process singleton hands the arguments to the running process, which opens a window. Brave's Info.plist carries `CrProductDirName`; Safari's does not.
- Files: `SnapDesk/Core/DocumentOpening.swift` (`ChromiumHandoff.isChromiumApp(infoPlist:)`, `NSWorkspaceDocumentOpener` chooses the hand-off for such apps), `SnapDesk/UI/HelpContent.swift`, `CLAUDE.md`, `SnapDeskTests/LaunchServiceTests.swift` or a small `DocumentOpeningTests` section in an existing file.
- [x] Test: `testAnAppWithACrProductDirNameIsAChromiumBrowser` / `testAnAppWithoutItIsNot` (pure function over an Info.plist dictionary); `testTheHandoffArgumentsPutNewWindowBeforeTheDocument` (pure function building the argument list from a URL and slot arguments).
- [x] Red, then: the production opener reads the app bundle's Info.plist once per call; for a Chromium app it launches a new instance with `["--new-window", url.absoluteString] + arguments`, otherwise `NSWorkspace.open` as now. `LaunchService` and the planner are unchanged.
- [x] Green; help says Chromium-based browsers open the page in a new window and Safari in a tab of the frontmost window.

## Phase B — Restore path

### Task 6: Document slots and the running-instance rule
- Files: `SnapDesk/Core/LaunchPlanner.swift`, `SnapDeskTests/LaunchPlannerTests.swift`.
- [x] Tests: `testEveryDocumentSlotOfARunningAppAsksForANewInstanceWhenExistingWindowsAreOffLimits` (`moveExistingWindows: false`, app running → `[true, true]`); `testAMixedGroupUnderMoveExistingOpensTheDocumentAndReusesTheRest`; `testASingleInstanceAppOpensEveryDocumentWithoutAskingForANewInstance` (prohibits closure → all `newInstance: false`); `testAnAbsolutePathDocumentIsPlannedAsAFileURL`.
- [x] Red, then: `newInstance: !moveExisting && (offset == 0 || isRunning)`; the fallback for an unusable document logs at error; comments updated.
- [x] Green.

### Task 7: Failure texts that name every state they cover
- Files: `SnapDesk/Core/LaunchService.swift` (`SlotFailure.stateNotRestored.displayText`, `.documentFailed` comment), `SnapDesk/UI/HelpContent.swift` (stateNotRestored, launchTimedOut, documentFailed entries), `SnapDeskTests/HelpContentTests.swift`, `SnapDeskTests/LaunchHUDTests.swift` if it names the string.
- [x] Test: `HelpContentTests.testTheStateFailureEntryCoversFullscreen` — the troubleshooting entry for `SlotFailure.stateNotRestored.displayText` mentions "fullscreen".
- [x] Red, then: "Zoom, fullscreen or minimize failed"; help entries reworded ("usually the app is fine", "the app or its document").
- [x] Green.

### Task 8: The document open under timeout and Cancel, and `LaunchAction.openRequest`
- Files: `SnapDesk/Core/LaunchPlanner.swift` (`LaunchAction.OpenRequest`, `openRequest`), `SnapDesk/Core/LaunchService.swift` (`launch` loop, `init` without a default opener), `SnapDeskTests/LaunchServiceTests.swift` (`FakeDocumentOpener.hangDocuments`, `neverReturnDocuments`).
- [x] Tests: `testADocumentOpenThatHangsTimesOutRatherThanBlamingTheDocument` → `.failed(.launchTimedOut)`; `testCancelDuringADocumentOpenEndsTheRestoreAsCancelled`; `testTheFirstDocumentSlotOfAGroupLaunchesAFreshInstanceAndTheRestJoinIt` (opener configurations `[true, false]`); `testASlotsArgumentsReachTheDocumentOpen`.
- [x] Red, then: `OpenRequest { document: URL?; arguments; newInstance }`, `guard let request = action.openRequest else { continue }`; the log prints `absoluteString`; the reason is an if/else chain; `///` on the local becomes `//`; `documentOpener` has no default.
- [x] Green.

### Task 9: Fullscreen edge cases
- Files: `SnapDesk/Core/LaunchService.swift` (`WindowPlacement.apply`, `ensureFullScreen`), `SnapDeskTests/LaunchServiceTests.swift`.
- [x] Tests: `testAFullscreenWriteThatIsRefusedFailsAtOnceWithoutTheTwoSecondWait` (`fullscreenResult = .attributeUnsupported`, saved true → `.stateNotRestored`, frame written, `sleeps == 0`); `testARefusedLeaveOfFullscreenIsReportedWithoutWaiting` (saved false, `isFullscreen: true`, refused → `.refused`, no frame write, `sleeps == 0`); `testAnUnknownFullscreenStateDoesNotPressTheZoomButton` (`isZoomed: true, isFullscreen: true`, saved fullscreen nil → no zoom press); `testASlotSavedMinimizedAndFullscreenIsMinimizedWithoutEnteringFullscreen`.
- [x] Red, then: gate the un-zoom press on `ax.fullscreenState != true`; skip entering fullscreen when `minimized`; log the nil-read cases (leave precondition and the read-back).
- [x] Green; the two test comments about Activity Monitor attribute accept-and-ignore to the mid-transition measurement.

### Task 10: The editor row is honest about what it stores
- Files: `SnapDesk/UI/EditorView.swift` (`WindowDocumentField.notice(for:)`, `WindowStateToggles` bindings, caption, tooltips), `SnapDesk/UI/HelpContent.swift`, `SnapDeskTests/EditorWindowTests.swift`, `SnapDeskTests/HelpContentTests.swift`.
- [x] Tests: `testTheDocumentFieldSaysWhenTypedTextIsNotStored` (`notice(for: "not a url")` is non-nil, nil for "" and for a URL); `testTurningFullscreenOnTurnsMinimizedOffAndViceVersa`; help mentions that unstorable text is flagged.
- [x] Red, then implement; the two Launch buttons get `.help` tooltips that say which document each restores.
- [x] Green.

### Task 11: The sidebar says what it lists, in the order it lists it
- Files: `SnapDesk/Support/WorkspaceLibrary.swift` (`FolderAvailability`, `folderAvailability()`, comments, prune logs, `filter` dedupe, variadic `min`, no `Identifiable`), `SnapDesk/UI/EditorWindow.swift` (`EditorHost.folderNotice`, `refreshRecents`, `RecentNameCache` comment), `SnapDesk/UI/EditorView.swift` (notice caption), tests `WorkspaceLibraryTests`, `EditorWindowTests`.
- [x] Tests: `WorkspaceLibraryTests.testAFolderThatCannotBeReadIsReportedAsUnavailable`; `EditorWindowTests.testAnUnreadableFolderShowsANoticeInTheSidebar`; `EditorWindowTests.testWithNoFolderTheSidebarHoldsTheRecentsOrderedByLastRestore` (two recents, the restored one first); `WorkspaceLibraryTests.testWithNoFolderTheListingIsTheRecentsOrderedForTheSidebar` (two elements).
- [x] Red, then implement; comments say the set is the recents list and the order is the library's, and that the sidebar caches decoded names per modification date.
- [x] Green.

### Task 12: Capture stores the trimmed document and says what it dropped
- Files: `SnapDesk/Core/CaptureService.swift`, `SnapDeskTests/CaptureServiceTests.swift`, `SnapDeskTests/WorkspaceDocumentTests.swift` (forward-compat decode).
- [x] Tests: `testACapturedDocumentIsStoredTrimmed`; `WorkspaceDocumentTests.testAFileWrittenByThisBuildDecodesWithThePreFeatureWindowShape` (a private `LegacySavedWindow` without the two fields decodes this build's encoding).
- [x] Red, then: store the trimmed value; log at info when a vended document is dropped.
- [x] Green.

## Phase C — Preferences

### Task 13: One bookmarked setting, one array codec
- Files: `SnapDesk/Support/WorkspaceBookmark.swift` (`BookmarkedURLSetting`, `WorkspaceBookmark.list(in:bookmarks:paths:count:)`, `store(_:in:bookmarks:paths:)`), `SnapDesk/Support/AppSettings.swift`, `SnapDesk/Support/WorkspaceLibrary.swift`, `SnapDesk/Support/RecentsStore.swift`, tests `AppSettingsTests`, `WorkspaceLibraryTests`.
- [x] Tests: `AppSettingsTests.testTheStartupWorkspaceSurvivesAReloadAndClearsToNil`; `testARenamedStartupWorkspaceHasItsNewPathPersisted` (`startupWorkspacePath`); `WorkspaceLibraryTests.testARenamedFolderHasItsNewPathPersisted` (`libraryFolderPath`); `testRaggedArraysInDefaultsLoadAsTheEntriesTheyAgreeOnAndAreRewritten`; `testPruningIsWrittenBack` (`libraryPaths`/`libraryDates` counts); `AppSettingsTests.testAShortSlotArrayFromAnOlderBuildStillLoadsFiveSlots`.
- [x] Red, then implement the two helpers and route the three stores through them; keys unchanged.
- [x] Green; `RecentsStoreTests` green.

### Task 14: Slots, names and log levels agree
- Files: `SnapDesk/Support/AppSettings.swift` (`slotCount` derived; comments; out-of-range logs), `SnapDesk/Input/HotkeyCenter.swift` (class doc; warning for Capture/Editor, info for slots), `SnapDeskTests/HotkeyNameTests.swift`.
- [x] Test: `HotkeyNameTests.testEveryWorkspaceNameHasASlotInTheStore` — `workspaceSlots.count == WorkspaceShortcuts.slotCount`.
- [x] Implement; green.

### Task 15: No production defaults on the new seams; Settings rows
- Files: `SnapDesk/Core/LaunchService.swift` (`documentOpener` required), `SnapDesk/UI/EditorWindow.swift` (`library`, `forgetWorkspace` required), `SnapDesk/UI/SettingsWindow.swift` (`shortcuts` required; `WorkspaceChoiceRow`; "(missing)" label), `SnapDeskTests/SettingsWindowTests.swift` (scratch stores).
- [x] Tests: `SettingsWindowTests` construct with `WorkspaceShortcuts(defaults: scratch)` and `AppSettings(loginItems:defaults: scratch)`; `AppSettingsTests.testAMissingWorkspaceIsLabelledMissing` via `WorkspaceChoiceRow.label(for:)` pure helper.
- [x] Implement; green.

## Phase D — App

### Task 16: Startup, hotkeys and the launch date
- Files: `SnapDesk/App/AppDelegate.swift` (skip the startup workspace when a pending open names the same file; `Dependencies.beep`; record the launch after a restore that placed something), `SnapDesk/Support/AccessibilityAuth.swift` (no second relaunch alert while one is on screen), tests `AppDelegateTests`, `AccessibilityAuthTests`.
- [x] Tests: `testAStartupWorkspaceThatWasAlsoDoubleClickedIsRestoredOnce`; `testAnUnassignedWorkspaceHotkeyBeepsButShowsNoAlert`; `testACancelledRestoreIsNotRecordedAsALaunch`; `AccessibilityAuthTests.testTheRelaunchAlertIsNotShownTwiceWhileItIsOnScreen`.
- [x] Implement; green.

## Phase E — Docs and comments

### Task 17: CLAUDE.md, the plan, and the comments that drifted
- Files: `CLAUDE.md`, `docs/superpowers/plans/2026-09-10-snapdesk-v2-features.md`, `SnapDesk/Support/WorkspaceLibrary.swift`, `SnapDeskTests/EditorWindowTests.swift`, `SnapDeskTests/HelpContentTests.swift`, `SnapDesk/Core/LaunchService.swift` (`bounded` comment, "would otherwise look like"), `SnapDesk/Core/LaunchPlanner.swift`, `SnapDesk/UI/SettingsWindow.swift`, `SnapDesk/UI/HelpContent.swift` (wording).
- [x] CLAUDE.md: apply ordering with both fullscreen steps; `HotkeyCenter` bullet; four stores; `Dependencies` and `SlotFailure` lists; "four places"; forward-compat test named; the Trash rule; `resolve` returning the bookmark; the measured browser fact; the trust model of a workspace file.
- [x] Plan Outcome: thirteen commits; the folder is chosen from the editor sidebar; measured table row for the browser open.
- [x] Three detached doc comments moved back; rationale duplicates trimmed to a pointer; help wording ("refuses it", the Safari sentence, "Settings…", file-name order).

### Task 18: Help tests that cannot pass vacuously
- Files: `SnapDeskTests/HelpContentTests.swift`.
- [x] `allHelpText()` / `text(of:)` helpers; "folder" → the "The Workspaces list" entry mentions "Choose Folder"; "twice" → the "Document or URL" entry says "opens the same page twice"; startup → the Settings topic entry mentions "login".

## Phase F — Verification
- [x] `SNAPDESK_REQUIRE_AX=1 TEST_RUNNER_SNAPDESK_REQUIRE_AX=1 xcodebuild … test` — 0 failures, 0 skipped.
- [x] Release build: 0 warnings.
- [x] Mutation checks: remove `presenting` around the folder panel; remove the Trash check; remove the `document` carry-over; persist the stale reference; revert the planner rule; remove the un-zoom gate — each fails its named test.

---

## Outcome

Every task above is done, with the deviations below. 460 tests are in the suite; the full run
with `TEST_RUNNER_SNAPDESK_REQUIRE_AX=1` passed everywhere except `AXWindowTests`, which failed
with "not vended" while TCC reported trusted because the screen was locked at the time — the
cause is now recorded in CLAUDE.md. Re-run from the unlocked session on 2026-09-14, that class
passed too: 27 tests, 0 failures, 0 unreachable.
The Release build has no warnings. Mutation-checked: the folder-panel guard, the Trash rule, the
recapture carry-over, the library's persisted rewrite, the planner's running-instance rule, the
un-zoom gate, the startup dedupe and the post-placement launch record each fail their named test
when reverted.

- **Task 5b was not in the review's findings.** The measurement it rests on was, and it made
  the feature work for the browser that vends `AXDocument`; it is confined to the seam's
  production conformance and a pure `ChromiumHandoff`, and is the one deliberate scope addition.
- **Task 14's test is not there** because `slotCount` is now derived from the names, which made
  the assertion tautological.
- **Task 15's label helper is `WorkspaceChoice.text(for:empty:)`**, not `WorkspaceChoiceRow.label(for:)`.
- **Left out, on purpose:** claiming a window after a failed document open (a change to what a
  failed slot may take from the pool); a typed `DocumentReference` in place of `String?`; a
  `WindowState` struct for `WindowPlacing.place`; a single-key `Codable` encoding for the two new
  stores; a registration seam on `HotkeyCenter`; a confirmation for workspace files this machine
  did not write (the trust model is recorded in CLAUDE.md instead). Each is a design decision
  rather than a fix, and belongs to the maintainer.
- **Verified not an issue:** the relaunch alert cannot appear twice at startup — `runAlert`
  refuses a request while one is on screen — and the test now pins it.

