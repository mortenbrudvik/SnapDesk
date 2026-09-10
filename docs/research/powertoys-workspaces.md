# PowerToys Workspaces, compared

What Microsoft's PowerToys Workspaces does that SnapDesk does not, what it does that macOS
cannot, and what neither does. Written 2026-09-10 against the documentation of that date and
against the module's source at `microsoft/PowerToys@main`.

The published developer docs for the module are placeholders — "TODO: Add implementation
details" — so the specifics below come from reading `src/modules/Workspaces`, chiefly
`WorkspacesLib/WorkspacesData.h`, `WorkspacesSnapshotTool/SnapshotUtils.cpp` and
`WorkspacesLauncher/AppLauncher.cpp`. Where a claim comes from the user documentation it is
quoted.

## What it stores

Per application:

```
id, name, title, path, packageFullName, appUserModelId, pwaAppId,
commandLineArgs, version, isElevated, canLaunchElevated,
isMinimized, isMaximized, position{x,y,width,height}, monitor
```

Per workspace:

```
id, name, creationTime, lastLaunchedTime, isShortcutNeeded,
moveExistingWindows, monitors[], apps[]
```

Per monitor: `id`, `instanceId`, `number`, `dpi`, and both a DPI-aware and a DPI-unaware rect.

SnapDesk's `SavedWindow` is `bundleIdentifier`, `bundlePath`, `name`, `title`, `displayId`,
`x`, `y`, `width`, `height`, `minimized`, `zoomed`, `arguments`; its `SavedDisplay` is `id`,
`name`, `frame`, `visibleFrame`, `scale`.

## Missing from SnapDesk

| Gap | Detail |
|---|---|
| **A workspace library** | Their editor lists every workspace and launches, edits, duplicates or deletes any of it. SnapDesk's editor sidebar lists *recents* — the twenty most recently opened — and selecting one opens it for editing rather than launching it. There is no view of every workspace you own, and no way to launch from that list in one click. |
| **Timestamps in the file** | They store `creationTime` and `lastLaunchedTime`, so a list can be ordered by what you actually use. SnapDesk orders recents by when the file was last opened, and stores nothing in the document, so that ordering is lost with the preferences. |
| **A pinnable launcher** | They generate a desktop shortcut, pinnable to the taskbar. A `.snapdesk` file is arguably better, being the workspace rather than a pointer to one, but macOS only allows a document in the Dock's document area — there is no one-click Dock item beside your apps for a given workspace. |

## Not applicable on macOS

**Elevation.** `isElevated` and `canLaunchElevated` have no analogue for GUI apps here. Their
documentation carries a standing known issue that elevated apps cannot be repositioned at all.

**Windows app identity.** `packageFullName` and `appUserModelId` solve an identity problem that
a bundle identifier already solves. `pwaAppId` handles progressive web apps, which on macOS are
ordinary app bundles — untested, but they should need no special case.

**DPI-aware and DPI-unaware rects.** A Windows coordinate-space problem. `backingScaleFactor`
plus frames relative to the visible frame covers the same ground.

## Where SnapDesk is ahead

- **Stacking order.** Their model has no field for it. SnapDesk records the CoreGraphics
  front-to-back order at capture and places back-to-front, so the frontmost window comes back
  frontmost.
- **Recapture keeps your work.** Their docs: "Capturing the adjusted workspace will perform a
  clean re-capture, and all previous CLI arguments and settings will be removed." SnapDesk
  merges and keeps arguments for windows it recognises.
- **Failure reporting.** They show launched, loading, or failed. SnapDesk distinguishes ten
  reasons, and says when a slot took a window it is not named after or landed on a substitute
  display.
- **The workspace is a document.** Portable, readable JSON that can live in a project or in
  version control. Theirs live together in one internal file.
- **Display re-matching.** Three rules in descending confidence, with the substitution reported
  to the user. Theirs matches on monitor number and rect.

## What neither does

**Automatic argument capture.** They have a `CommandLineArgsHelper` that can read a running
process's command line over WMI. Nothing calls it: `SnapshotUtils.cpp` writes
`commandLineArgs = L""` and the user types arguments in the editor, exactly as in SnapDesk.
Restoring a browser to a URL is a manual step in both.

**Virtual desktops**, which is Spaces here. An open request against their repo (issue #35327).

**Snapped or zoned layouts.** Their FAQ: PowerToys "uses publicly available APIs and the
FancyZones engine under the hood for positioning apps. Unfortunately, this does not include
snapping capabilities."

**Launching a window straight into position.** Their FAQ explains windows visibly jump after
launching because no API lets you launch to a position — which is why they added a status
dialog during launch, and why SnapDesk has a HUD.

## Sources

- <https://learn.microsoft.com/en-us/windows/powertoys/workspaces>
- <https://microsoft.github.io/PowerToys/modules/workspaces/> (placeholder module docs)
- <https://github.com/microsoft/PowerToys/tree/main/src/modules/Workspaces>
- <https://github.com/microsoft/PowerToys/issues/35327> (virtual desktops)
