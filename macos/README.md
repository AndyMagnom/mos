# MedPrep for macOS — Xcode 26.2

Native AppKit/WKWebView source targeting macOS 13 and later. Native Mac App Attest
is excluded at compilation; the Mac entitlement and SDK 27 dependency are removed.
Administrator-approved enrollment is removed. iOS retains its own App Attest and
DeviceCheck implementation.

This source has not been compiled on a Mac here. See [BUILD-SIGNED-RELEASE.md](BUILD-SIGNED-RELEASE.md)
for the exact build, signing, export and notarization procedure. No signed binary
or production deployment has been produced. XCTest uses a separate Testing
configuration; normal Debug and Release retain hardening.

## Device identity and backend

Install `Plugin/LockGuard_v3_11_1_apple.zip` and follow
`Plugin/source/devicelock/README-macOS.md` on each Moodle origin. The server must
explicitly enable automatic Mac device keys and a reviewed OS/build policy.

The Mac signs fresh server challenges with a per-origin P-256 software key in the
device-only data-protection Keychain. New keys enroll automatically; no approval
queue, Apple attestation service or Apple server private key is required for Mac.
Existing account/device limits, bans, suspension checks and session binding still
apply. Public-key possession is **not app-integrity attestation**. A modified
client with its own key can reproduce the protocol; Hardware UUID and claimed
OS/build are not independently certified. Do not present this as equivalent to
App Attest.

Hardware UUID (when available) and Keychain UUID are signature-bound metadata;
the plugin stores their hashes. The signing key defines the canonical device,
not either UUID. Keep signing team, app identifier and Keychain namespace stable
across updates. The previous per-origin Keychain account name is retained for
migration; old bearer/challenge sessions are invalidated by the plugin upgrade.
Erase, hardware replacement or Keychain loss can require a new registration.
Migrating an old App Attest identity without an existing software key also creates
a new registration; existing device limits may require administrator recovery.

## Added Mac features

- Original two-cube chase animation on verification/loading covers; Reduce Motion
  stops the animation.
- Previous-crash notice using OS MetricKit diagnostics on macOS 26+. Older Macs
  use a one-time unclean-run notice, which can also reflect force-quit/power loss.
- Optional native security banners: choose **MedPrep > Enable Security Notifications**.
  Permission denial does not disable enforcement. Banners describe this app's
  detected policy failures; they do not detect screenshots or hidden recordings.
- Built-in-only display policy: Release requires exactly one online built-in
  display, without detected mirroring. All external monitors are refused,
  including on Mac mini/Studio, and in MacBook clamshell mode.
- Default-on VM heuristics, debugger/injected-library checks, periodic executable
  and resource signature validation, compiled signing-team/bundle requirement,
  Hardened Runtime and library validation.
- Selected detection strings and expected signing identity are AES-GCM encoded
  per build. The embedded key can be recovered. Release uses whole-module
  optimization, dead-code removal and symbol stripping; no commercial obfuscator
  or guarantee against reverse engineering is included.

## VM testing — Debug only

VM checks start enabled. Build/run the **Debug** scheme without a debugger or
Main Thread Checker injection. In the MedPrep app menu:

1. Uncheck **Detect Virtual Machines (Debug)**.
2. Check **Allow VM Display (Debug)** if the VM has no built-in display.
3. Retry after the local cover clears; enable the exact test OS/build on staging.

The display exception is allowed only for a detected VM, with VM detection
explicitly disabled, and only one non-mirrored display. Other integrity checks
remain active. These two settings persist for Debug, but Release ignores them
and contains no toggle actions. Re-enable detection and disable the display
exception after testing. Unknown VMs can evade the heuristic; a Debug exception
may also fail to recognize a particular VM. Do not ship a Debug build.

## Capture limits

AVSampleBufferDisplayLayer.preventsCapture protects only submitted native media
pixels. Ordinary course HTML and inline image/video posters remain potentially
capturable. NSWindow.sharingType is only a deterrent. System audio capture and
unknown screen-recording tools cannot be universally detected or prevented.
A normal notification banner cannot provide a missing capture-event API.

Read [SECURITY-REPORT.md](SECURITY-REPORT.md) for the complete feature checklist,
verification evidence and physical-device release acceptance tests.
