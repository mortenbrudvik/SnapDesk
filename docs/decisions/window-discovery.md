# Window discovery and placement

Why restore polls for windows, settles for the wrong one on purpose, and then
corrects itself. All numbers below were measured on macOS 26.6.2 (25G83),
Xcode 26.6, against `c4d332d`. They are recorded here so nobody has to derive
them again — and because three of the four conclusions are counter-intuitive
enough that the code comments alone read as arbitrary.

## The problem

After launching an app, its windows appear over the next seconds. For each
saved slot, restore must choose between *keep waiting* — this slot's own window
has not vended yet — and *settle* for a window it is not named after. Settling
early puts a window at the wrong saved frame. Waiting stalls the restore, which
is the common case when the user simply renamed a window since capture, so no
exact title will ever match.

## 1. "This app has finished opening its windows" is not knowable

Every candidate signal reports something strictly earlier than the last window.

| Signal | Measurement |
|---|---|
| `NSRunningApplication.isFinishedLaunching` | True **before any window exists in 12/12 launches**, margin 11–658 ms |
| `AXFocusedWindow` settling | Focus lands on the *first* window; Preview's restored window arrived 2565 ms later |
| `openApplication` completion | Fired 121–3930 ms in, with no relation to windows |
| `CGWindowList` | No lead over AX (Preview: AX 664.4 ms vs CG 669.5 ms) |

What `isFinishedLaunching` actually marks, to within ~1 ms in 10/12 runs, is
"the app's AX server now answers". Useful for arming things; useless as *done*.

**The vend-gap distribution is bimodal with an empty middle.** Intra-batch gaps
are ≤19.1 ms (TextEdit: 4 windows in 0.6 ms; 6 windows in 10.2 ms; Brave: 3
session-restored windows in 37.6 ms total). The next mode is macOS window
restoration at **2565–3706 ms**. Nothing was ever observed between ~20 ms and
~2.5 s.

So a quiet-period threshold either sits below 2.5 s and misses the restoration
wave, or above 4 s and spends half the budget on the common rename case. There
is no N that does both — and in principle an app may open a window at any later
time, so no finite N is ever correct.

## 2. `AXWindowCreated` exists and works — and still cannot replace polling

The notification is real (`kAXWindowCreatedNotification`), registers with
`err=0` against live Safari, Notes, TextEdit and Finder, and post-arm was 100%
reliable across every probe, surviving a 12 s main-thread beachball and a 6.5 s
`SIGSTOP`. An earlier comment in this repo claiming AX has no such callback was
simply false.

It is still the wrong tool for *discovery*:

- **`kAXWindows` is always the earlier signal.** In 13/13 in-callback checks the
  window was *already* in `kAXWindows` when the notification fired. Never the
  reverse.
- **There is no replay.** Arming late delivers nothing for existing windows.
- **The observer cannot arm before the first window.**
  `AXObserverAddNotification` returns `-25204` from launch until
  `isFinishedLaunching` flips — which is within ~1 ms of the app answering, and
  the first window lands at essentially the same moment.
- **Some apps never emit for their launch window at all.** Calculator and
  Dictionary emitted nothing, with the observer attached 15–141 ms *before* the
  window appeared. Dictionary emitted normally for a window created later.

Polling is immune to that race. The mature window managers (yabai, Amethyst,
Hammerspoon) carry KVO gating and retry backoff purely to survive it. Against a
100 ms poll, events buy at most one poll interval — and were measured *lagging*
a 5 ms poll by 139 ms in one case.

## 3. No metadata identifies a start-page or transient window

Measured on live windows, a Safari start page and a Safari content window are
structurally identical: both `AXStandardWindow`, layer 0, alpha 1.0, all three
titlebar buttons, both with a real localized title.

`AXDocument` is not a discriminator — populated on only 4/13 live real windows
(TextEdit, Terminal, Brave) and **absent on Safari, Notes and Finder content
windows**, so keying on it misclassifies real windows as junk. `AXIdentifier` is
per-app (`FinderWindow`, `_NS:6`). Every `CGWindowList` numeric field is
byte-identical. Title-string matching is a non-starter: this machine is
Norwegian, so the start page is titled **"Startside"**.

Independent corroboration: AeroSpace ships 119 recorded AX dumps as golden
tests, and one *is* a Safari Start Page — `AXSubrole: AXStandardWindow`,
`AXDocument: null`, all four titlebar buttons enabled.

**Partial exception, and it is what `CaptureFilter` uses.** Open/Save panels and
modal galleries *are* identifiable: 13/13 real windows vend all three of
close/minimize/zoom; 3/3 cold-launched panels vend none. Both halves of the
conjunction in `CaptureFilter.isChromelessStandardWindow` are load-bearing:

| Window style | subrole | buttons | verdict |
|---|---|---|---|
| `NSOpenPanel` | AXStandardWindow | none | exclude |
| Borderless (Electron `frame: false`) | **AXDialog** | none | keep |
| `fullSizeContentView` + transparent titlebar (VS Code, Slack) | AXStandardWindow | **c m z** | keep |
| Buttons set `isHidden` | AXStandardWindow | **c m z** | keep |
| Safari / Notes / Finder / Brave | AXStandardWindow | c m z | keep |

Not tested: a genuinely frameless Electron app (none installed). Chromium
itself passes cleanly.

## 4. The AX messaging timeout

The documented "6 seconds" is wrong. Measured against a `SIGSTOP`ped process:
default **1514 ms**; `installMessagingTimeout(0.5)` → 504 ms; `(0.25)` → 254 ms.
A *dead* process returns `-25204` in ~1 ms, a *hung* one after the full timeout.

0.25 s was too tight: legitimate reads measured 257–261 ms while several apps
launch at once — exactly what a restore does — and 315 ms after a hang cleared.
A timed-out read returns `.cannotComplete`, **indistinguishable from "no windows
yet"**, so an over-tight timeout does not merely lose a value, it feeds the
wrong branch of the decision in §1. Hence 0.5 s. Do not tighten it.

## What was decided

Poll `kAXWindows` every 100 ms up to 8 s. Settle every exact title first, then
hand leftovers — early, only to apps that have vended as many windows as the
workspace expects (`finishedBundles`), decided **per app** so one app that never
vends cannot stall another's slots; once the budget is spent, to everything
still waiting.

Then make the guess **revocable**: `correctProvisionalClaims` watches for 4 s
(covering the 2565–3706 ms restoration wave) and swaps in the window a slot was
actually named after, if it turns up. This runs after placement and after
`activateFrontmost`, so it costs the visible restore nothing.

The failure it fixes is pinned by
`LaunchServiceTests.testStartPageIsTakenWhileTheRealWindowIsStillComing`, which
reproduced it before the fix: the start page took slot "Docs"'s saved frame and
the real Docs window was never placed at all.

## Rejected

- **Observer-based discovery** — §2. Strictly later and less complete.
- **A quiet period as the settle signal** — §1. No workable N.
- **Junk-window detection** — §3. No portable signal.
- **Waiting on titles** — costs the full 8 s whenever a user renamed a window,
  which is common.

## Known remaining failure cases

- A window arriving after the 4 s correction window is never swapped in.
- An app that vends an *extra* window early still causes a wrong settle; the
  correction fixes it only if the real window carries the saved title exactly.
- The guessed window keeps the frame it was given. Nothing knows where it
  belongs instead, and the correction lands on the same frame afterwards, so
  the right window ends up in front of it.
- A window whose title changed *and* whose app vended extra windows cannot be
  matched at all — no signal distinguishes it from a leftover.
