# SnapDesk

macOS workspace launcher: capture a desk of app windows, save it as a double-clickable `.snapdesk` file, restore apps to those displays and frames.

Sibling to [Loadstone](https://github.com/mortenbrudvik/loadstone) (snap/tiling). Independent app and repo. Same craft: Swift 6, AppKit, Accessibility, menu bar, not sandboxed.

## Problem

PowerToys Workspaces (Windows) captures running apps and window rectangles, then launches and places them in one click. After a reboot or a context switch, the desk comes back without manual arranging.

macOS has no equivalent. It can do the job more reliably than Windows if we store **bundle ID + app path** and place windows through Accessibility.

## Goals (v1)

- Capture the current desk into an unsaved workspace, then Save As a `.snapdesk` file.
- The file is the workspace. Double-click restores it.
- Editor to name the workspace, trim apps, edit frames, set CLI arguments, toggle “move existing windows.”
- Menu bar extra: Capture, Recents (launch), Editor, Open…
- Launch HUD with per-app status; partial failure does not abort the rest.
- Multi-display, including display remap when a screen is missing or resized.
- Accessibility required; prompt like Loadstone when untrusted.

## Non-goals (v1)

- Mission Control Spaces, Stage Manager, true fullscreen spaces
- Capturing open documents, URLs, or Finder folders
- Launch as admin
- `NSDocument`, iCloud, Versions
- Shared Swift package with Loadstone
- PowerToys-style capture overlay (red screen border)
- App Store / sandbox
- Intel
- Window thumbnails, Raycast/Alfred, sync
- Hotkey to “launch last workspace”

## Product decisions

| Decision | Choice |
|---|---|
| Relation to Loadstone | Sibling app, independent codebase. Copy AX patterns; do not extract a package. |
| v1 scope | PowerToys parity + Mac app identity (bundle ID + path). |
| Workspace storage | The `.snapdesk` file is the source of truth. Recents are bookmarks, not a library of copies. |
| App presence | Menu-bar agent (`LSUIElement`). Editor and launch HUD on demand. |
| Implementation | Loadstone-shaped: Swift 6, AppKit shell, XcodeGen, Accessibility, not sandboxed. JSON document, not `NSDocument`. |

## Architecture

Three paths share one document type.

```
Capture  →  .snapdesk  →  Launch
                ↑
              Editor
```

| Piece | Job |
|---|---|
| Status item | Capture, Recents, Editor, Open…, Accessibility, Settings, Quit |
| `WorkspaceDocument` | Versioned JSON on disk. Codable. Not `NSDocument`. |
| `CaptureService` | Running apps + AX windows + `CGWindowList` z-order + display UUID |
| `LaunchService` | Resolve apps, launch or reuse, wait, place, report status |
| `AXWindow` | Frame read/write. Cocoa coordinates outside this type. AX origin stays inside. |
| `DisplayMap` | Saved displays → current `NSScreen`s |
| Editor window | On demand, SwiftUI hosted in an AppKit window |
| Launch HUD | Floating panel only while a restore is running |
| Recents | `NSURL` bookmarks in UserDefaults |

**Data flow**

- **Capture.** Menu/hotkey → snapshot → editor on an unsaved document → Save As writes `.snapdesk` and adds Recents.
- **Launch.** Double-click / Recents / Editor Launch → HUD → resolve/launch/place per slot → HUD dismisses.
- **Edit.** Recents (via Editor, not the menu extra) or Open in the editor. Save writes the same file. Save As writes a new one.

Double-click is handled as an `open` Apple Event on the agent app. Restore runs even if the editor is closed. The HUD is the only required UI.

## Document: `.snapdesk`

Pretty-printed JSON. UTF-8. `JSONEncoder` with `.prettyPrinted` and `.sortedKeys`.

UTI `com.brudvik.snapdesk`, extension `snapdesk`, role Editor, `LSHandlerRank` Owner. App bundle ID `com.brudvik.snapdesk`.

### Schema (version 1)

```json
{
  "version": 1,
  "name": "Coding",
  "moveExistingWindows": true,
  "displays": [
    {
      "id": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
      "name": "Built-in Retina Display",
      "frame": { "x": 0, "y": 0, "width": 1512, "height": 982 },
      "visibleFrame": { "x": 0, "y": 38, "width": 1512, "height": 916 },
      "scale": 2
    }
  ],
  "windows": [
    {
      "bundleIdentifier": "com.apple.Safari",
      "bundlePath": "/System/Cryptexes/App/System/Applications/Safari.app",
      "name": "Safari",
      "title": "GitHub",
      "displayId": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
      "x": 0,
      "y": 0,
      "width": 800,
      "height": 900,
      "minimized": false,
      "zoomed": false,
      "arguments": ""
    }
  ]
}
```

Unknown keys are ignored on decode so a future field does not break v1 readers. A `version` greater than 1 that v1 cannot read fails open with a clear error (HUD / alert: “This workspace was saved with a newer SnapDesk”).

### Workspace fields

| Field | Type | Meaning |
|---|---|---|
| `version` | Int | Schema version. v1 writes `1`. |
| `name` | String | Label in the editor and Recents. Independent of filename. |
| `moveExistingWindows` | Bool | If true, place already-open windows. If false, request a new instance. |
| `displays` | Array | Desk at capture time, for remap. |
| `windows` | Array | One slot per captured window. **Index 0 is frontmost.** |

### Display fields

| Field | Meaning |
|---|---|
| `id` | `CGDisplayCreateUUIDFromDisplayID` string. Primary match key. |
| `name` | `NSScreen.localizedName`. Fallback match. |
| `frame` | `NSScreen.frame` in Cocoa global coordinates (points). |
| `visibleFrame` | `NSScreen.visibleFrame` (Dock and menu bar excluded). |
| `scale` | `backingScaleFactor`. Diagnostic; placement uses points. |

### Window fields

| Field | Meaning |
|---|---|
| `bundleIdentifier` | Primary launch key. Empty only if the app has none (slot will fail on restore unless `bundlePath` still launches). |
| `bundlePath` | `NSRunningApplication.bundleURL` path. Fallback if Launch Services misses the ID. |
| `name` | Localized app name for UI. |
| `title` | Window title at capture. Matching hint, not identity. |
| `displayId` | `displays[].id` for the screen containing the window’s centre. |
| `x, y, width, height` | Frame in **points**, origin = that display’s `visibleFrame` origin, Cocoa y-up. |
| `minimized` | `AXMinimized`. |
| `zoomed` | `AXZoomed` (green-button zoom). Not Mission Control fullscreen. |
| `arguments` | CLI string, user-edited. Split on shell-style tokens when launching (see Launch). Empty by default. |

`arguments` is a single string in the file so the editor is one field. At launch, tokenize without a shell: split on ASCII whitespace; substrings in `"` or `'` stay one token; no `\` escapes; no `~` or `$` expansion. Empty string → no arguments array.

### Coordinate restore

Saved `(x, y, width, height)` is relative to the **saved** `visibleFrame`.

1. Map `displayId` to a live screen: UUID, then equal `name`, then closest `visibleFrame.size` (Euclidean on width/height).
2. If the live `visibleFrame.size` matches saved (both edges within 1 pt), place as `liveVisible.origin + (x, y)` with saved size.
3. If size differs, scale `x,width` by `liveWidth/savedWidth` and `y,height` by `liveHeight/savedHeight`.
4. If no screen matches (empty `displays` or all gone), use the main screen’s `visibleFrame` and step 3.
5. Clamp: if the frame is larger than the visible frame, shrink to fit. If it sits fully outside, shift origin so at least 80 pt of the title bar (top of the Cocoa frame) stays inside the visible frame.

### What is not in the file

Launch as admin, Spaces, Stage Manager, documents/URLs, thumbnails, z-order beyond array order.

## Capture

Snapshot of the desk as it is. No overlay. User arranges, then Capture.

### Window set

1. `NSWorkspace.shared.runningApplications` where `activationPolicy == .regular`.
2. Skip SnapDesk (`com.brudvik.snapdesk`), Dock, Finder desktop/wallpaper windows, menu extras, and any app with no usable AX application element.
3. For each remaining app, `AXWindows`. Keep elements whose role is `AXWindow` and subrole is `AXStandardWindow` (or missing subrole but looks like a normal window: has `AXTitle` and a non-empty frame). Skip `AXUnknown`, `AXFloatingWindow`, `AXSystemDialog`, sheets, and frames with width or height under 8 pt.
4. Include minimized windows (`AXMinimized`).
5. Include hidden apps (⌘H). Restore will unhide.

### Z-order

`CGWindowListCopyWindowInfo(.optionOnScreenOnly + .optionExcludeDesktopElements, kCGNullWindowID)` is front-to-back.

- Visible captured windows: sort to that order. Index 0 = frontmost.
- Minimized (and any standard window not in the on-screen list): append after visible windows, grouped by app, in AX list order.

Match CG windows to AX windows by pid + `CGWindowNumber` via `_AXUIElementGetWindow` (`dlsym`, same fallback as Loadstone: title if the SPI is missing).

### Per-window record

- `bundleIdentifier` / `bundlePath` / `name` from `NSRunningApplication`.
- `title` from `AXTitle` (empty string if missing).
- Frame: AX → Cocoa (Loadstone’s conversion; `AXWindow` is the only type that sees AX top-left). Convert to relative coords using the display under the **window centre**.
- Display `id` from that screen’s `CGDisplay` UUID. If the centre is off every screen, use the screen with the largest intersection; if none, main screen.
- `minimized` / `zoomed` from AX.
- `arguments` empty.

Capture of an empty desk (no eligible windows) still opens the editor with zero rows. Save is allowed; launch is a no-op success.

### Re-capture

From the editor, **Launch & Edit** launches the current document, then the user rearranges and hits Capture. The new snapshot **replaces** `displays` and `windows`, and **keeps `arguments`** when a new window matches an old slot:

1. bundle ID + exact title, unused old slot
2. bundle ID only, unused old slot

Greedy, one old slot per new window. Unmatched new windows get empty `arguments`. Unmatched old slots disappear. `name` and `moveExistingWindows` are unchanged. Untitled documents recapture in place the same way.

## Launch

Triggers: double-click, menu Recents, menu Open…, Editor → Launch.

If Accessibility is not effectively trusted, prompt (Loadstone’s probe, not only `AXIsProcessTrusted`) and **do not** launch any slot.

### App URL

For each slot:

1. `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` if the ID is non-empty.
2. Else `bundlePath` if it exists on disk and is an app bundle.
3. Else the slot fails: “App not found.”

### Move existing **on**

- Group slots by bundle ID (or path if ID is empty).
- If that app is not running, launch **once**. Use the first slot’s `arguments` if any; otherwise launch with none. Do **not** request a new instance.
- If it is running, do not launch. Unhide if hidden.
- Assign windows to slots in **back-to-front place order** (last index first):
  - Unclaimed standard window with exact `title`
  - Else first unclaimed standard window of that app
- Claim by pid + window number. A claimed window is never reused.
- If no window appears within the wait budget, that slot fails. Other slots continue.

Single-instance apps (System Settings, etc.) always take this path even if the document says move existing off.

### Move existing **off**

Each slot launches with `NSWorkspace.OpenConfiguration`:

- `createsNewApplicationInstance = true`
- `arguments` from the parsed CLI string
- `activates = false` until the final frontmost activation

Wait for a window that is **not** already claimed. If the app ignores new-instance and only one window exists, the first slot claims it; later slots of that app fail with “No extra window.”

### Waiting

- Launch timeout: **10 s** per `openApplication` call.
- Window timeout: **8 s** after launch (or immediately if already running), polling AX on the main actor about every 0.1 s.
- AX messaging timeout: **0.25 s**, installed at app launch (Loadstone).

### Placement (per slot, back → front)

1. Unminimize if we will not leave it minimized (`AXMinimized = false`) so the frame write sticks. Always unminimize before writing a frame.
2. If `zoomed`, set `AXZoomed = false` first so the frame is not ignored.
3. Map display and compute Cocoa frame (Coordinate restore).
4. Write AX **size → position → size**, with `AXEnhancedUserInterface` save-disable-restore around the write (Loadstone).
5. If `zoomed`, set `AXZoomed = true`.
6. If `minimized`, set `AXMinimized = true` **after** the frame so unminimize later lands correctly.
7. After all slots, activate the running app for `windows[0]` (frontmost). If that slot failed, activate the first successful slot in list order.

### HUD

Floating, non-activating panel. One row per slot: app icon, `name`, status.

| Status | When |
|---|---|
| Pending | Not started |
| Launching | `openApplication` / waiting for a window |
| Placed | Frame write accepted (or minimized/zoomed set) |
| Failed | Missing app, timeout, no window, AX refused |

- **Dismiss** hides the HUD; launch continues.
- **Cancel** stops slots that have not started placing. In-flight launches are not killed. Already-placed windows stay.
- Auto-dismiss ~0.6 s after every slot is Placed or Failed.

AX refuse: beep, unified log (`subsystem == "com.brudvik.snapdesk"`), slot Failed. Do not abort the workspace.

## UI

### Menu extra

- **Capture** — snapshot, open editor on unsaved document
- **Recents** — each item **launches** (does not open the editor). Missing files stay listed until removed; choosing one fails with “File not found” and stays in the list
- **Editor**
- **Open…** — `NSOpenPanel` for `.snapdesk`, then **launch** (same as Recents, not edit)
- Accessibility row: trusted / open System Settings / Relaunch
- **Settings…**
- Quit

Default shortcuts (KeyboardShortcuts, user-editable):

- Capture: `⌃⌥⌘C`
- Editor: `⌃⌥⌘E`

No Dock icon at idle (`LSUIElement`). Launching via double-click may flash activation; do not keep a Dock icon for the editor unless macOS shows one for the window (acceptable).

### Editor

One window.

**Sidebar / list**

- Recents (display `name` + filename)
- Capture (new untitled)
- Open… — `NSOpenPanel`, **edit** that file (does not launch)
- Remove from Recents
- Reveal in Finder
- Move to Trash (explicit; confirmation). Trashing also removes from Recents.

**Detail**

- Name field
- Move existing windows checkbox
- App rows: icon (`NSWorkspace` icon for bundle), name, title, display name, x/y/width/height, minimized, zoomed, arguments, remove
- Schematic preview: saved `displays` as rectangles, window rects inside them labeled with app `name`. Click a rect to select the row. Not live AX.
- Launch / Launch & Edit / Save / Save As

Untitled documents have no Recents entry until Save As succeeds. Save on a document that already has a URL overwrites that file. Close with unsaved changes: standard save/don’t/cancel.

### Settings

- Shortcuts (the two bindings)
- Launch at login (`SMAppService`, same `requiresApproval` handling as Loadstone)

### First run

On launch, if not effectively trusted, show the Accessibility alert (remove old entry, add `/Applications/SnapDesk.app`, enable, Relaunch). Capture and Launch beep and no-op until trusted.

## Platform

- macOS 14+, Apple Silicon only
- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `@MainActor` for anything with UI or AX state
- Not sandboxed. Hardened runtime on Release. Developer ID signing like Loadstone (`3GS65HFAFH`)
- XcodeGen `project.yml`; `xcodebuild -scheme SnapDesk` for build and test
- Distribution: GitHub zip + Homebrew cask, not App Store (v1 may ship unsigned locally until release machinery is copied)

## Source layout

```
SnapDesk/
  App/           LoadstoneApp-style + AppDelegate, Info.plist, entitlements
  Core/
    WorkspaceDocument.swift
    CaptureService.swift
    LaunchService.swift
    DisplayMap.swift
    AXWindow.swift
    WindowIdentity.swift
  UI/
    StatusItemController.swift
    EditorWindow.swift
    LaunchHUD.swift
    SettingsWindow.swift
  Support/
    AccessibilityAuth.swift
    RecentsStore.swift
    AppSettings.swift
    Log.swift
SnapDeskTests/
project.yml
```

Seams (production defaults, inject in tests): `CaptureService` window/app sources, `LaunchService` workspace/open/wait, `DisplayMap` screen list, `RecentsStore` bookmark storage, `AppSettings` defaults + login items.

## Testing

Host: `TEST_HOST` the app. `applicationDidFinishLaunching` returns early when `XCTestConfigurationFilePath` is set so tests do not rewrite Recents or prompt TCC.

| Area | Pins |
|---|---|
| Document | Encode/decode v1, unknown keys ignored, newer `version` errors, sorted pretty JSON round-trip |
| Geometry | Relative frame; scale on size change; clamp when off-screen; shrink when larger than visible frame |
| Display map | UUID wins, then name, then similar size |
| Matching | Exact title, then leftover; claimed window not reused |
| Recapture | Arguments kept on bundle ID+title, then bundle ID |
| Capture filter | Regular apps only; skip SnapDesk, palettes, tiny frames; minimized included |
| Launch plan | Move-existing: one launch per bundle ID; move-existing off: new instance per slot; place back → front |
| Recents | Bookmark round-trip; missing file still listed |

AX read/write tests use windows **owned by the test host** (no TCC). `NSWorkspace.openApplication` and waiting on other apps are faked behind protocols.

## Error handling

| Situation | Behaviour |
|---|---|
| Accessibility untrusted | Prompt; capture/launch no-op + beep |
| App missing | Slot Failed; continue |
| Launch timeout / no window | Slot Failed; continue |
| AX frame refused | Beep, log, slot Failed; continue |
| Display gone | Main (or best) screen + scale/clamp |
| File missing from Recents | Alert on choose; leave in list |
| Newer schema | Do not launch; explain |
| Corrupt JSON | Do not launch; explain |
| Empty windows array | Success, nothing to do |
| Untitled close dirty | Save / don’t / cancel |

Subsystem: `com.brudvik.snapdesk`. Info-level: capture counts, launch plan, shortcut bindings. Error-level: AX refusals, missing apps, decode failures.

## Known limits (accepted)

- Several windows of one app restore well when those windows already exist. From a cold start, many apps open one window unless `arguments` or the app’s own session restore create the rest. Same class of limit as PowerToys.
- `createsNewApplicationInstance` is a request. Single-instance apps still expose one window.
- Some apps refuse AX frames (Loadstone already beeps). SnapDesk fails that slot and continues.
- True fullscreen (its own Space) is not captured as fullscreen; a fullscreen window may appear as a large zoomed/standard frame or be skipped if it is not an `AXStandardWindow`.

## Key decisions

1. **File is the workspace** — portable, double-clickable, git-friendly. Recents are an index, not a second copy.
2. **Menu-bar agent, not a Dock document app** — restore is the frequent path; editing is occasional.
3. **Bundle ID + path, not app name** — Launch Services identity is the Mac advantage over PowerToys.
4. **Frames relative to visible frame, in points** — Dock/menu bar and Retina are first-class. UUID identifies the display.
5. **Snapshot capture, not overlay mode** — less chrome; Launch & Edit covers iteration. Recapture preserves CLI args (PowerToys does not).
6. **Independent from Loadstone** — copy AX size→position→size, identity SPI, TCC probe, test-host guard. Do not couple releases.
7. **No admin, no Spaces in v1** — no good Mac stand-in for UAC-per-app; Spaces need private APIs.

## Open questions

None. Resolved in the design conversation: sibling app named SnapDesk; v1 parity + identity; `.snapdesk` as source of truth; menu bar + editor; architecture, schema, capture/launch, UI, tests and cuts as above.
