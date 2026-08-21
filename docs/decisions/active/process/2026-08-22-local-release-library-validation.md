# Decision: Local packages disable library validation and every package runs a dyld probe

Status: active
Area: release
Anchors:
- apps/AfterRay/Sources/AfterRayApp.swift @dec:local-release-library-validation
Supersedes: —
Superseded-by: —

## Problem

Hardened Runtime library validation requires a host and its non-platform
frameworks to share a signing Team ID. Ad-hoc signatures have no stable Team
ID, so an otherwise valid local app can pass recursive `codesign` verification
and still be killed by dyld before `main` while loading Sparkle. Static
signature verification does not exercise that runtime relationship.

## Decision

The explicitly unpublishable `--local` host keeps Hardened Runtime but carries
`com.apple.security.cs.disable-library-validation` so it can load its ad-hoc
signed Sparkle framework. Developer ID and production builds retain library
validation and fail packaging if that entitlement appears.

Every packaging mode executes the assembled, signed application with a private
dynamic-loader probe environment variable. The probe returns from `main`
before `NSApplication`, the daemon, logs, or user data are initialized. Failure
to reach that branch is a packaging failure.

Ad-hoc local packages are packaging checks, not installed-app test candidates:
their designated requirement differs from the published application and does
not inherit its TCC consent. Permission-sensitive test packages use the
unnotarized Developer ID mode and compare their designated requirement with an
explicit reference application before packaging.

## Alternatives considered

**Remove Hardened Runtime from local packages.** This avoids the Team-ID rule
but makes the local artifact a weaker approximation of the production bundle
and stops testing other runtime-signing constraints.

**Require Developer ID credentials for local packages.** This preserves
library validation but defeats the credential-free local packaging workflow
and duplicates the unnotarized Developer ID mode.

**Keep only static signature checks.** Recursive `codesign` verification passed
the broken package because it validates each nested signature independently;
it cannot replace a dyld load.

## Consequences

Local packages have a deliberately weaker nested-library boundary and remain
ineligible for publication or TCC-preserving handoff. Production and
unnotarized Developer ID artifacts keep the stronger boundary. The small
pre-main branch is present in every build, but it has no effect unless the
private packaging environment variable is explicitly set.
