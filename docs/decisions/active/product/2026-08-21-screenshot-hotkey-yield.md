# Decision: Carbon ⇧⌘Space yields to macOS screenshots

Status: active
Area: recall-ui
Anchors:
- swift/AfterRayRecall/Sources/RecallHotKey.swift @dec:screenshot-hotkey-yield
- apps/AfterRay/Sources/AfterRayApp.swift @dec:screenshot-hotkey-yield
Supersedes: —
Superseded-by: —

## Problem

AfterRay's default global shortcut is ⇧⌘Space, registered with
`RegisterEventHotKey`. That API consumes the chord before any other process
sees it. macOS window screenshot is a two-step sequence: ⇧⌘4, then Space
while ⇧⌘ is often still held. The second press is AfterRay's hotkey, so the
screenshot never enters window mode and AfterRay opens instead. The same
collision is why ⇧⌘4 can look "stolen" when AfterRay is already covering
the screen: Space after the crosshair appears is how people finish the
gesture they think of as the screenshot shortcut.

The capture shim's listen-only `CGEventTap` does not consume keys. A
callback after the hotkey has fired cannot give Space back.

## Decision

The default shortcut stays ⇧⌘Space. On ⇧⌘3 / ⇧⌘4 / ⇧⌘5 / ⇧⌘6 the overlay
controller unregisters the Carbon hotkey and dismisses the overlay *before*
Space can arrive, then re-registers after the Screenshot UI process
terminates. If Screenshot never launches, releasing ⇧ or ⌘ is enough to
re-arm.

Binding AfterRay itself to a screenshot number is warned, not refused —
same policy as ⌘Space / ⌃Space. That binding does not yield the number it
owns, because Carbon already took it.

## Alternatives considered

**Change the default away from ⇧⌘Space.** Would avoid the collision for new
installs, at the cost of one-handed reach and of surprising everyone who
already learned the shortcut. ⌥⌘Space is Finder search; ⌃⌘Space is the
character viewer. The yield keeps the default and still lets the screenshot
sequence through.

**Pass the chord through from the hotkey handler when Screenshot is
frontmost.** Too late: `RegisterEventHotKey` has already consumed Space.
The handler can choose not to open AfterRay, but window-screenshot mode
still never sees the key.

**Refuse ⇧⌘3–5 in the recorder and leave the default as-is.** That would
not fix the default shortcut colliding with the Space follow-up.

## Consequences

**Bought:** ⇧⌘4 then Space reaches Screenshot. AfterRay covering the
screen does not sit in front of an in-progress capture.

**Cost:** a ⇧⌘3 of the overlay itself can lose AfterRay, because the
overlay is ordered out on the number's key-down before the capture lands.
Screenshot of AfterRay has to wait until AfterRay is visible and the
shortcut is not a stock screenshot chord.

**Do not "fix" this by making the hotkey handler ignore Space.** The event
is gone. Do not "fix" it by changing the default without a product decision
that names a free one-handed replacement.
