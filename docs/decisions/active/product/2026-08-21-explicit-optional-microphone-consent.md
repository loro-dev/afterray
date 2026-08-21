# Decision: Microphone consent is explicit and optional

Status: active
Area: capture
Anchors:
- apps/AfterRay/Sources/AfterRayApp.swift @dec:explicit-optional-microphone-consent
- apps/AfterRay/Sources/SystemPermissionCoordinator.swift @dec:explicit-optional-microphone-consent
Supersedes: ../../superseded/product/2026-08-20-microphone-tcc-alert.md
Superseded-by: —

## Problem

Microphone uses a native in-place TCC alert, but presenting it automatically
after onboarding takes the choice away from the permission row the user can
see. Screen Recording and Accessibility are different: capture cannot operate
without them, and their grant path lives in System Settings.

The Settings guide also watched permission changes in isolation. When its poll
observed a grant, it hid itself without refreshing the shared permission model
or resuming capture. The user could therefore grant a required permission and
still see stale state, with no visible next step.

## Decision

First-launch bootstrap may request Screen Recording and Accessibility. It does
not request Microphone. When Microphone is `.notDetermined`, the visible
permission-row action directly calls `AVCaptureDevice.requestAccess(for:
.audio)` and the system presents the Allow / Don't Allow alert. Turning audio
on later is also an explicit action and may make the same request.

The gate waits for the microphone question to be answered, not for it to be
granted. Allow enables microphone capture. Don't Allow proceeds with screen and
system audio; the capture shim omits the microphone stream. A later recovery
action deep-links to the Microphone pane without the Screen Recording drag
guide.

Screen Recording and Accessibility remain required. Their Settings guide may
poll the system permission, but a detected grant must refresh
`SystemPermissionCoordinator`, restore the AfterRay overlay, and reconcile
capture startup. App activation, the manual refresh button, guide completion,
and the native microphone result converge on that same reconciliation path.

## Alternatives considered

**Request Microphone automatically during bootstrap.** This can produce a
native alert before the user acts on the visible microphone row and makes an
optional permission feel mandatory. It also couples the microphone prompt to
Screen Recording's relaunch behavior.

**Require a microphone grant.** Rejected because system audio and screen
capture remain useful without the user's voice. A refusal is a valid product
choice, not an incomplete setup.

**Let the Settings guide hide without publishing the grant.** This preserves
stale coordinator state and recreates the reported dead end. The poll is only
useful if its result reaches the state that owns the gate.

**Poll from the SwiftUI permission panel.** The overlay is ordered out rather
than destroyed, so a view-owned task can keep running while invisible. The
short-lived Settings guide already owns the grant poll and is the bounded
lifecycle for it.

## Consequences

**Bought:** the microphone prompt follows an explicit click, refusing it does
not block capture, and required System Settings grants advance the same state
the main permission gate renders.

**Cost:** an unanswered microphone prompt still holds first-run completion
until the user chooses Allow or Don't Allow. This makes the optional choice
explicit without silently deciding it for the user.

**Constraint:** do not reintroduce an automatic bootstrap microphone request
or a microphone Settings drag card. Do not add another permission-state owner;
new completion paths must call the shared reconciliation path.
