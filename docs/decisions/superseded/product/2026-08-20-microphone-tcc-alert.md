# Decision: Microphone consent is the system TCC alert, not a Settings guide

Status: superseded
Area: capture
Anchors: —
Supersedes: —
Superseded-by: ../../active/product/2026-08-21-explicit-optional-microphone-consent.md

## Problem

Screen Recording and Accessibility can only be granted in System Settings, so
the permission gate shows a floating card that looks like AfterRay with a
switch. Microphone is a different TCC family: macOS presents an Allow / Don't
Allow alert in place, and the app appears under Privacy → Microphone only after
that alert is answered. Applying the Settings card to the microphone makes
people try to grant on AfterRay's overlay — a row that is not a toggle — instead
of answering the system alert or opening the real Microphone pane.

## Decision

Microphone consent is `AVCaptureDevice.requestAccess(for: .audio)`. The
permission gate does not show the System Settings instructional card for the
microphone.

An unanswered (`.notDetermined`) prompt is the grant path; after the user
answers, the overlay returns. A declined microphone is an answer, not a missing
Settings toggle: capture proceeds with screen and system audio. If the user
asks again after a decline, the gate deep-links to the Microphone pane and does
not restack the instructional card.

Screen Recording and Accessibility still open System Settings with the drag
card. They have no in-place grant.

The app is listed in the Microphone pane only after the consent alert is
answered, so `.notDetermined` always re-asks and is never gated behind the
automatic-request ledger. Granting Screen Recording relaunches the app while
that alert can still be open.

## Alternatives considered

**Reuse the Screen Recording Settings overlay for the microphone.** The path
this record exists to end. The card's AfterRay row and "turn on the switch"
copy read as a grant control on AfterRay itself. Microphone cannot be added by
dragging, and the pane is empty until the system alert has been answered, so
the overlay sends people to the wrong surface at the wrong time.

**Skip System Settings even after a decline.** First-run is the native alert,
but a declined prompt cannot be re-asked in place. The only remaining grant
path is the Microphone pane, which does list AfterRay once the alert has been
answered. Dropping the deep-link would leave that recovery with no in-app
route.

**A custom pre-alert that looks like the system Allow / Don't Allow dialog.**
Rejected by Apple's privacy HIG: a custom screen must not mimic the system
request. The gate's row action triggers `requestAccess`; the system alert is
the choice.

## Consequences

**Bought:** first-run microphone is one system dialog. A decline is not a
blocker, and nobody is taught to toggle AfterRay on an overlay that cannot
grant.

**Cost:** a user who declined and later changes their mind lands in System
Settings without the drag/toggle tutorial. That is acceptable because the
Microphone pane is a list of apps with switches, which is the actual grant UI
after the alert has been answered.

**Do not "fix" this by showing the Settings card for the microphone.** The card
is the right tool for Screen Recording and Accessibility, and the wrong tool
for a TCC family that has an in-place alert.
