# SnapDesk — Apple Intelligence

Optional intelligence layer for SnapDesk. Not part of v1. The v1 product remains a mechanical capture/launch app; this document describes how Apple Intelligence sits on top of that without touching the restore hot path.

Companion to [`2026-09-09-snapdesk-design.md`](2026-09-09-snapdesk-design.md). Where the two conflict, v1 wins until this work is scheduled.

## Problem

SnapDesk already does the hard Mac work: Accessibility frames, bundle identity, display remap, launch planning. After capture, the remaining work is editorial — naming the desk, trimming slots, and pushing rectangles around. That work is tedious and is exactly the kind of structured-text task the on-device Apple Foundation Model is good at.

The on-device model is **not** a general assistant and **not** a window manager. Using it to invent bundle paths, guess missing apps, or place windows at launch time would make restore less reliable than v1.

## Goals

- After Capture, suggest a workspace `name` from the snapshot (apps, titles, display layout).
- In the editor, accept a natural-language arrange request and mutate the open document through the same editor session the UI already uses.
- Expose Capture, Launch, and Editor to Siri / Shortcuts via App Intents, using Recents and the `.snapdesk` file as the source of truth.
- Keep Apple Intelligence **optional**. macOS 14 devices, Intel is already out of v1, and Apple Intelligence-ineligible Apple silicon Macs must keep a complete non-AI editor.
- Never send workspace contents to a third-party cloud by default. On-device `SystemLanguageModel` is the default model.

## Non-goals

- A menu-bar chatbot, free-form “ask SnapDesk” panel, or world-knowledge Q&A.
- AI in `CaptureService` or `LaunchService`. Capture is a snapshot. Launch is a plan + AX writes. Failures beep, log, and mark the HUD slot Failed.
- Generating a `.snapdesk` file from a sentence with no live snapshot (the model does not know bundle paths, display UUIDs, or real frames).
- Image Playground, Genmoji, Writing Tools as a product surface (the name field may inherit system Writing Tools for free; we do not build a feature around them).
- Visual Intelligence, camera, or screenshot-to-workspace.
- Replacing display remap, window matching, or coordinate restore with model judgment.
- Requiring Apple Intelligence, Private Cloud Compute, or a network for any v1 path.
- Changing the `.snapdesk` schema. Intelligence writes the same v1 fields the editor already writes (`name`, frames, flags, `arguments`).
- Sandbox / App Store. Distribution stays GitHub zip + Homebrew, same as v1.
- Training adapters, Core AI custom models, or third-party `LanguageModel` providers (Claude, Gemini) in the first cut.

## Product decisions

| Decision | Choice |
|---|---|
| Where intelligence lives | Editor assistant, plus App Intents at the system edge. Not capture. Not launch. |
| Default model | On-device `SystemLanguageModel.default`. |
| How the model changes the desk | Tool calls into `EditorSession`. Not a raw JSON rewrite of the document. |
| Source of geometry | Live or saved snapshot already in the document. The model proposes mutations; Core still owns coordinates, clamp, and display map. |
| Availability | Feature-detect at runtime. Hide AI chrome when the model is unavailable. |
| Deployment target | Unchanged: macOS 14.0+, arm64. AI types are `@available(macOS 26.0, *)`. |
| Cloud | Not in the first cut. PCC is a later, explicit opt-in if on-device arrange quality is insufficient. |
| App Intents vs Foundation Models | Independent. Intents ship even on Macs without Apple Intelligence. |

## Relationship to v1

```
Capture  →  .snapdesk  →  Launch
                ↑
              Editor  ←  WorkspaceIntelligence (optional)
```

v1 three-path architecture is unchanged. Intelligence is a fourth, optional arrow into the editor.

| v1 type | This work |
|---|---|
| `CaptureService` | Unchanged. After a successful snapshot, the editor may ask intelligence for a name. |
| `LaunchService` | Unchanged. No model, no tools, no “fix this frame”. |
| `WorkspaceDocument` | Unchanged schema. Intelligence mutates the in-memory editor document, then the user Save / Save As as today. |
| `EditorSession` | Gains a small command surface the UI and the tools both call. |
| `DisplayMap` / `FramePlacement` | Unchanged. After a tool proposes a frame, placement still scales and clamps. |
| Recents | Unchanged bookmarks. App Intents resolve names against Recents, then the file. |

The product promise stays: double-click a `.snapdesk` file, windows land. Intelligence is how you *author* that file faster.

## Platform and availability

Foundation Models requires Apple Intelligence: a supported Apple silicon Mac, a supported region/language, and Apple Intelligence turned on. The framework’s on-device model has shipped as part of macOS 26 and been revised in 26.4 and 27.

SnapDesk v1 is macOS 14+. Do not raise the deployment target.

```swift
import FoundationModels

let model = SystemLanguageModel.default
switch model.availability {
case .available:
    // Show auto-name and Arrange field.
case .unavailable(.deviceNotEligible):
    // Hide AI chrome. Editor is unchanged.
case .unavailable(.appleIntelligenceNotEnabled):
    // Hide AI chrome. Do not block first-run; Accessibility is the only required prompt.
case .unavailable(.modelNotReady):
    // Hide or disable with “Apple Intelligence is still downloading.”
case .unavailable(let other):
    // Hide AI chrome.
}
```

Rules:

- Check availability on the main actor before creating a `LanguageModelSession`.
- Do not prompt the user to enable Apple Intelligence on first launch. First-run remains the Accessibility alert.
- If the model becomes unavailable mid-session (rare), cancel the in-flight request, leave the document as it was, and disable the Arrange control.
- App Intents do not use this check. Shortcuts/Siri calling Launch/Capture must work on macOS 14 as long as Accessibility is trusted.

## Architecture

New types live under `SnapDesk/Intelligence/`, compiled only where needed, with availability annotations. Core and launch stay ignorant of Foundation Models.

```
SnapDesk/
  Core/            unchanged
  UI/              editor gains optional AI chrome
  Intelligence/
    WorkspaceIntelligence.swift    façade; availability + use cases
    WorkspaceNameSuggestion.swift  @Generable result for auto-name
    ArrangeTools.swift             Tool implementations
    ArrangeInstructions.swift      session instructions (versioned strings)
  Intents/
    LaunchWorkspaceIntent.swift
    CaptureDeskIntent.swift
    OpenEditorIntent.swift
```

`WorkspaceIntelligence` is the only type UI talks to.

| Method | Job |
|---|---|
| `availability` | Mirror `SystemLanguageModel.availability`. |
| `suggestName(document:)` | One-shot session, guided generation, returns a name. Does not write the document. |
| `arrange(document:session:prompt:)` | Multi-turn session with tools bound to that `EditorSession`. Applies mutations immediately as tools run, so the schematic preview updates live. |

Seams for tests: inject a `WorkspaceArranging` protocol in place of the real session so XCTest can drive tools without the on-device model. Production default is `LanguageModelSession`.

Concurrency: same as v1. UI and `EditorSession` are `@MainActor`. Model `respond` is async; hop back to the main actor before applying tool effects. Cancel outstanding tasks when the editor document is replaced (Recapture, Open, Close).

### Why tools, not JSON rewrite

A `@Generable` full `WorkspaceDocument` would let the model invent `bundlePath`, drop `displayId`, scramble z-order, or emit frames in the wrong coordinate space. v1 decode is permissive on unknown keys and strict on `version`; a model-authored file is the wrong layer.

Tools can only do what the editor can do:

- rename
- set a slot’s frame
- move a slot to a display (by display id already in the document)
- toggle minimized / zoomed
- set `arguments`
- remove a slot

They cannot add apps (no snapshot), cannot change bundle identity, cannot set `version`, cannot rewrite `displays`.

After each tool call, `EditorSession` marks the document dirty and the schematic preview redraws. Save remains explicit.

## Feature 1 — Auto-name

**When.** Capture opens the editor on an unsaved document, or Recapture replaces `displays` / `windows`. If the current `name` is empty or still the default untitled label, request a suggestion. If the user has already edited `name`, do not overwrite.

**What the model sees.** Compact text, not the raw file:

- workspace `moveExistingWindows`
- each display: `id`, `name`, `visibleFrame` size
- each window in list order: index, `name`, `bundleIdentifier`, `title`, display name, x/y/width/height, minimized, zoomed

Omit `bundlePath`. Omit Recents. Omit arguments unless we later use them for naming (we do not in v1 of this feature).

**Output.** Guided generation:

```swift
@Generable
struct WorkspaceNameSuggestion {
    @Guide(description: "Short workspace name, at most 40 characters, no trailing punctuation.")
    var name: String
}
```

The UI writes `suggestion.name` into the name field as a suggestion (selected, so typing replaces it). It does not auto-Save.

**Session.** New `LanguageModelSession` per request. No tools. Instructions: propose a label a person would pick in Recents; prefer task over app dump (`"Coding"` not `"Xcode Safari Terminal"`); use English unless titles are clearly another language; never invent apps that are not in the list.

**Failure.** If the model is unavailable, errors, or returns an empty/too-long name, leave the field as it is (untitled). No alert. Log at info.

**Cost / privacy.** On-device, offline, no token billing. Titles stay on the Mac.

## Feature 2 — Arrange with AI

The main intelligence surface.

### UI

In the editor detail, below the schematic preview (or above the app rows if the preview is collapsed):

- A single-line prompt field, placeholder *Describe a layout…*
- Submit (Return). Disabled while a request is running, or when availability ≠ `.available`, or when `windows` is empty.
- A small status: idle / thinking / applied N changes / failed.
- No chat transcript in the first cut. One prompt, one arrangement. The field clears on success; the user can submit again.

Examples the placeholder and a one-line help hint can show:

- “Xcode on the left half, Safari on the right”
- “Terminal along the bottom of the built-in display”
- “All windows on the external display, stacked”
- “Remove Mail from this workspace”

The schematic preview is the feedback. Click-to-select rows still works. Manual frame fields still work and win if the user edits after.

### Session

One `LanguageModelSession` per open editor document, created when the user first submits an arrange prompt, discarded when the document is closed, recaptured, or replaced.

```swift
let session = LanguageModelSession(
    model: SystemLanguageModel.default,
    tools: [
        SetFrameTool(session: editorSession),
        MoveToDisplayTool(session: editorSession),
        SetMinimizedTool(session: editorSession),
        SetZoomedTool(session: editorSession),
        SetArgumentsTool(session: editorSession),
        RemoveSlotTool(session: editorSession),
        SetWorkspaceNameTool(session: editorSession)
    ],
    instructions: ArrangeInstructions.current
)
```

Reuse the session across prompts in the same document so “now make Terminal taller” can refer to the previous layout. If `isResponding` is true, ignore a second submit.

If the session approaches the on-device context limit (instructions + tool schemas + transcript + compact document dump), start a fresh session and pass a fresh compact snapshot in the next prompt. Do not try to summarize the transcript with the model in the first cut.

### Prompt body

Each user submit sends:

1. The user’s sentence.
2. A compact snapshot of the **current** editor document (same shape as auto-name, plus `arguments` per slot). Always include current state so the model does not rely only on transcript.

The snapshot is the ground truth. If transcript and snapshot disagree, instructions say to trust the snapshot.

### Tools

All tools are `@MainActor`. Arguments use guided generation. Slot identity is the **current list index** in `windows` (0 = frontmost in the document, same as v1). Display identity is `displays[].id` or the display `name` if the id is omitted; resolution is exact id, then exact localized name, else the tool returns an error string to the model and does not mutate.

**`setFrame`**

| Argument | Meaning |
|---|---|
| `slot` | Int index into `windows` |
| `x`, `y`, `width`, `height` | Points, origin = that slot’s display `visibleFrame` origin, Cocoa y-up. Same space as the file. |

Behaviour: write the four fields on that slot. Then run the v1 clamp/scale **as if placing on the saved display’s `visibleFrame`** so a model that asks for a 5000 pt window cannot store a frame the launch path would have to rescue. Do not run `DisplayMap` against live screens here; the editor edits the saved document.

**`moveToDisplay`**

| Argument | Meaning |
|---|---|
| `slot` | Index |
| `displayId` | `displays[].id` or name |

Behaviour: set `displayId` on the slot. Keep x/y/width/height unless the frame now sits fully outside that display’s visible frame, in which case clamp as v1 step 5.

**`setMinimized` / `setZoomed`**

Boolean on a slot. Same meaning as the editor checkboxes.

**`setArguments`**

Replaces the slot’s `arguments` string. The tool does not tokenize; launch still tokenizes as v1.

**`removeSlot`**

Removes that index. Later indices shift. The model must use the snapshot from the **next** prompt to see new indices. Instructions: prefer not to remove unless the user asked.

**`setWorkspaceName`**

Same as typing in the name field. Used when the user says “call this Coding” during arrange. Auto-name does not use this tool.

Tool results returned to the model: short confirmations (`"slot 0 frame 0,0,800,900 on Built-in"` ) or errors (`"slot 4 out of range"`). Never return the full document from a tool.

### Instructions (normative intent)

Version the instruction string (`ArrangeInstructions.v1`) so we can retune when Apple ships a new on-device model (macOS 26 / 26.4 / 27 change model behaviour).

The model must:

- Only arrange windows listed in the snapshot. Never invent apps, bundle IDs, or displays.
- Use tools for every mutation. Do not describe a layout in prose as a substitute for tool calls.
- Treat `(x, y, width, height)` as relative to that display’s visible frame, y-up, points.
- Keep windows inside the visible frame. Prefer simple splits (halves, thirds, leftover) over pixel-perfect guessing.
- Not change `moveExistingWindows` unless the user asked (no tool for it in the first cut — omit on purpose).
- Not reorder z-order (no tool). Array order stays capture/frontmost order unless the user removes slots.
- If the request is ambiguous (“make them nicer”), pick a conventional tiled layout on the displays they already occupy and apply it.
- If the request is impossible (“put this on a display that is not in the document”), return a short explanation and call no tools.

The session’s generated *text* after tools is unused in the UI except as the failure string when no tool ran.

### Geometry helpers the model should not reinvent

Optional, later: a `proposeSplit` tool that takes a display id and a list of slots and writes even columns/rows using `FramePlacement`. First cut does not include it; `setFrame` is enough and is testable. If quality is poor on “left half / right half”, add `proposeSplit` rather than switching to PCC.

### Failure

| Situation | Behaviour |
|---|---|
| Model unavailable | Arrange field hidden or disabled. |
| Guardrail / refusal | Status “Couldn’t apply that.” Document unchanged. |
| Tool index/display error | Model may retry in the same `respond`. If the session ends with no successful mutation, status failed, document unchanged from before this prompt (see transactions). |
| Timeout / `GenerationError` | Cancel, status failed, log error. |
| User edits a field while thinking | Allowed. Snapshot at submit is what the model was given; tools apply to current indices. If the user recaptures, cancel the task. |

**Transaction per prompt.** Snapshot the `WorkspaceDocument` (value type) at submit. If the respond throws or completes with zero successful tool mutations, restore that snapshot. If at least one tool succeeded, keep the mutations (partial arrange is OK; the user can undo by reverting the file or by a follow-up prompt). No multi-step undo stack in the first cut.

## Feature 3 — App Intents

This is Apple Intelligence at the *system* edge (Siri, Shortcuts, Spotlight later). It does not require Foundation Models.

Adopt App Intents against existing services. Do not add a parallel launch path.

| Intent | Parameters | Effect |
|---|---|---|
| Launch Workspace | Workspace (AppEntity from Recents, or file URL) | Same as Recents / double-click: `LaunchService` + HUD. |
| Capture Desk | Optional name | Same as menu Capture: snapshot, open editor. If name provided, set `document.name` (and skip auto-name). |
| Open Editor | Optional workspace | Same as menu Editor / Open for edit. |

App Entities:

- `WorkspaceEntity`: id = bookmark or file path, display `name` + filename. Query from `RecentsStore`.
- Missing Recents files stay listed (v1). Launching one fails with “File not found”, same as the menu.

Siri / Apple Intelligence schemas: use the closest system schema that fits (document / file / open, plus custom app intents). Do not block on Visual Intelligence or on-screen awareness.

Shortcuts should be able to run Launch without bringing the editor forward. HUD still shows. Accessibility untrusted: the intent returns a failure that tells the person to enable Accessibility; it does not launch slots.

First cut does not add a “launch last workspace” hotkey (v1 non-goal). A Shortcut the user builds themselves is allowed because it lives outside the app.

## Explicitly rejected

| Idea | Why |
|---|---|
| Menu-bar chatbot | Wrong model size; fights the menu extra; no source of truth. |
| Model in launch hot path | Restore must be deterministic. AX refusals are beeps, not retries by an LLM. |
| Generate `.snapdesk` from a prompt only | No live AX → fake bundle paths and frames. Capture then arrange is the correct pipeline. |
| Image Playground / Genmoji | No job in a workspace launcher. |
| Screenshot of the desk as multimodal input | Capture already has AX frames. A picture is worse geometry. Reconsider only if we ever lack AX. |
| Default to `PrivateCloudComputeLanguageModel` | Workspace titles can include mail subjects, URLs, document names. Stay on-device until a measured quality gap exists. |
| Third-party Claude/Gemini via `LanguageModel` | Billing, keys, and data leaving the device. Out of scope. |
| Core AI / custom weights | Overkill for naming and splitting rectangles. |
| Writing Tools productization | System may already offer them on the name field; we do not add UI. |
| Auto-fill `arguments` from window title | Tempting (open this repo), but arguments are a user-owned gun. Only `setArguments` when the user asked. |

## Data the model is allowed to see

Allowed: workspace name, `moveExistingWindows`, display names/ids/sizes, per-slot app name, bundle id, window title, relative frame, minimized, zoomed, arguments, display assignment.

Not sent: `bundlePath`, file URL of the `.snapdesk`, Recents bookmarks, other documents, screenshots, live AX trees, user account, clipboard.

Logging: do not log titles or arguments at info. Log “auto-name requested, 6 slots” and “arrange tools: setFrame×3”. Error logs may include tool error strings (indices, display ids), not window titles.

## UI summary

| Surface | AI chrome |
|---|---|
| Menu extra | None. |
| Launch HUD | None. |
| Settings | None in the first cut (no “use cloud model” toggle). |
| Editor name field | Suggested name after capture when available; user can edit. |
| Editor detail | Arrange field + status, only if `availability == .available`. |
| First-run Accessibility alert | Unchanged. |

If the model is unavailable, the editor is exactly v1.

## Error handling

Follow v1 style: partial failure does not abort the app.

| Situation | Behaviour |
|---|---|
| Apple Intelligence off / ineligible | Hide AI chrome. |
| Model downloading | Disable Arrange; optional one-line status. |
| Auto-name fails | Untitled stays. |
| Arrange throws | Restore document snapshot for that prompt if no tool succeeded; status failed. |
| Arrange partial tools | Keep mutations; status “Applied n changes”. |
| Intent launch, AX untrusted | Fail the intent; show the existing Accessibility prompt if the app is foregrounded. |
| Intent unknown workspace name | Fail with “No workspace named …”. Do not invent a capture. |

Subsystem remains `com.brudvik.snapdesk`. Add `Log.intelligence` and `Log.intents`.

## Testing

v1 test-host rules still apply (`XCTestConfigurationFilePath` short-circuits `applicationDidFinishLaunching`).

On-device generation is **not** a unit-test dependency. Tests pin:

| Area | Pins |
|---|---|
| Availability gating | Editor hides Arrange when a stub reports unavailable; shows when available. |
| Auto-name apply | Suggestion writes name only when current name is untitled; never Save. |
| Auto-name skip | User-edited name is not overwritten on recapture. |
| Tools | `setFrame` clamp; bad index error; `moveToDisplay` by id then name; `removeSlot` shifts indices; `setArguments` round-trip. |
| Transaction | Thrown `respond` restores snapshot; one successful tool keeps mutations. |
| Compact snapshot | Encoder omits `bundlePath`; includes titles and frames. |
| Intents | Launch entity from Recents calls `LaunchService` (faked); missing file fails; Capture with name sets `name`. |
| Cancellation | Recapture cancels in-flight arrange. |

Hosted UI tests may call real `SystemLanguageModel` only behind an explicit scheme/env flag (`SNAPDESK_FM_SMOKE=1`) and must skip when `availability != .available`. Those tests are smoke, not CI-gating on Intel-in-CI or VMs without Apple Intelligence.

## Phasing

v1 of SnapDesk ships with **zero** of this. Do not block capture/launch on intelligence work.

| Slice | What | Depends on |
|---|---|---|
| **A — Auto-name** | `WorkspaceIntelligence.suggestName`, editor fill-in, availability hide | Editor + document. Smallest FM proof. |
| **B — Arrange** | Prompt field, tools, transactions, compact snapshot | A’s façade and availability. EditorSession command surface. |
| **C — App Intents** | Launch / Capture / Open Editor | Recents + LaunchService + Capture. **Can ship in parallel with A/B**, including on macOS 14. |

Recommended order: **C when convenient**, **A next**, **B when A’s plumbing exists**. A proves the framework and availability UI without teaching the model geometry. B is the product-visible intelligence.

Not in these slices: PCC, `proposeSplit`, chat transcript, undo stack, “launch last”, multimodal screenshots.

### Later, only if measured

- `proposeSplit` tool if halves/thirds come out ragged.
- `PrivateCloudComputeLanguageModel` behind a settings toggle if on-device tool calling is unreliable on dense desks. Default remains on-device.
- Evaluations framework prompts per OS model version (26 / 26.4 / 27).

## Source layout (additions)

```
SnapDesk/Intelligence/
  WorkspaceIntelligence.swift
  WorkspaceNameSuggestion.swift
  ArrangeInstructions.swift
  ArrangeTools.swift
  CompactSnapshot.swift
SnapDesk/Intents/
  LaunchWorkspaceIntent.swift
  CaptureDeskIntent.swift
  OpenEditorIntent.swift
  WorkspaceEntity.swift
SnapDeskTests/Intelligence/
  ArrangeToolsTests.swift
  AutoNamePolicyTests.swift
  CompactSnapshotTests.swift
SnapDeskTests/Intents/
  LaunchWorkspaceIntentTests.swift
```

`project.yml` gains the new files via the existing `SnapDesk` source glob. Link `AppIntents.framework`. Foundation Models is a system framework; no Swift package. Deployment target stays 14.0; wrap FM types in `@available(macOS 26.0, *)` or a type-erased façade so the app links on 14.

## Key decisions

1. **Editor, not launch** — Reliability is the product. The model authors the document; Core restores it.
2. **Tools against `EditorSession`, not generated JSON** — Mutations are the same operations a person has in the UI, so clamp, dirty-state, and preview stay honest.
3. **On-device default** — Titles and arguments never leave the Mac unless we later add an explicit PCC opt-in.
4. **macOS 14 deployment target stays** — Intelligence is runtime-optional chrome, not a new baseline.
5. **No schema change** — `.snapdesk` v1 remains the file. No `ai:` keys, no stored transcripts.
6. **App Intents are separate** — They make Recents speakable and are useful without Apple Intelligence.
7. **Do not generate desks from a sentence** — Capture is the only way apps enter a workspace.
8. **No first-run Apple Intelligence nag** — Accessibility is the only blocking permission.

## Open questions

None that block writing this down. Deferred product choices, not spec holes:

- Whether the Arrange field is a single line or a small multi-line box (start single-line).
- Whether auto-name runs on every recapture when the name is still a previous suggestion (v1 of this spec: only if the name is still untitled / default).
- Whether slice C uses a system App Intent schema or only custom intents (pick whatever Shortcuts records cleanly; behaviour is as specified).

Those can be decided in the implementation slice without changing architecture.
