# MedPrep for macOS

This is a native AppKit/WKWebView source project, not a signed or tested release.
It uses the same shared identity, HTTPS routing and public-key pinning owners as
the iOS app. The deployment baseline is macOS 13; building requires Xcode with
the macOS 27 SDK for native App Attest support.

## Build and sign

Open `MedPrepMac.xcodeproj`, select the MedPrepMac scheme, set your Apple team and
registered bundle/signing identifier, and enable the required App Attest capability.
Debug uses development App Attest; Release uses production. The sandbox and
Hardened Runtime are enabled. Do not add debugger or disable-library-validation
entitlements to Release. Keep dSYM files privately for symbolication.

On a Mac with Xcode 27:

```sh
xcodebuild -project macos/MedPrepMac.xcodeproj -scheme MedPrepMac -configuration Debug -destination 'platform=macOS' test
xcodebuild -project macos/MedPrepMac.xcodeproj -scheme MedPrepMac -configuration Release -archivePath build/MedPrepMac.xcarchive archive
```

Resolve all compiler warnings/errors and run the acceptance tests below before
archiving. Export using your real distribution profile. For Developer ID,
notarize the exported archive with your own keychain profile, staple the result,
and run `python3 macos/scripts/verify-release.py /path/to/MedPrepMac.app`.
No signing, Apple account configuration, notarization or deployment happened here.

## Server setup

Install `Plugin/LockGuard_v3_11_0_apple.zip` on each Moodle origin, run the Moodle
upgrade, and configure `Plugin/source/devicelock/README-macOS.md`. Course delivery
is denied until the administrator explicitly enables an exact reviewed OS/build
policy. Existing iOS configuration remains separate.

macOS 27+ supported devices use Apple App Attest, including Mac key ACL and
signed validation-category/build checks. Older or unsupported Macs use a
per-origin P-256 signing key stored in the device-only data-protection Keychain.
The approval error displays the public SPKI SHA-256 enrollment fingerprint.
An administrator must verify that fingerprint out of band and grant specific
Moodle user IDs. No private key is displayed or sent. Removal of the grant
invalidates outstanding sessions immediately on their next server request.

This fallback uses a software Keychain key, not Secure Enclave, and cannot prove
app integrity, physical hardware identity or the claimed OS version. It is the
explicitly authorized compatibility policy. Apple verification errors on a
supported device never silently fall back. When a formerly unsupported Mac gains
App Attest support, it uses a new Apple identity; it may require administrator
registration under the existing device limit. Hardware UUID never auto-merges it.

## Identifiers and security

Hardware UUID is read from IOPlatformUUID when available and sent only inside a
signed proof. The plugin stores its SHA-256 digest. A separate Keychain UUID is
corroborating metadata. Native Mac does not invent IDFV or a DeviceCheck token.
The cryptographic key, rather than a UUID, defines the canonical device identity.
Normal updates retain locally stored keys; reinstall, Keychain deletion, hardware
replacement or loss of an Apple key can change identity. No identifier guarantees
persistence across every possible restore or repair.

The four Moodle hostnames have supplied current/backup leaf SPKI pins. Keep the
backup private key outside the app/repository and test its replacement certificate
before rotation. Native media must be hosted on the current verified Moodle
origin. Additional CDN origins are not configured.

## Features and validation

See [SECURITY-REPORT.md](SECURITY-REPORT.md) for the feature checklist, security
limits, verification evidence and capture acceptance tests. Course HTML is a
normal WKWebView and can remain capturable on macOS. Only submitted native media
pixels use AVSampleBufferDisplayLayer.preventsCapture. Audio recording cannot be
guaranteed blocked. Never advertise complete screenshot/recording prevention.
