# macOS feature checklist and security release report

## Status

Native AppKit/WKWebView source, shared Apple security owners, Moodle backend and
installable plugin package are implemented. This environment has no Xcode,
Apple SDK, physical Mac or live Moodle installation. The native code is **not
compiled or proven working**. The checklist records implementation and available
evidence rather than labeling untested features successfully ported.

## Feature checklist

| Feature from Android / addition | macOS implementation | Evidence / remaining check |
| --- | --- | --- |
| Moodle login, courses, quizzes, forums and server themes | WKWebView uses the original Moodle pages | Implemented; real account/course/theme workflows untested |
| Main/junior, senior and two test Moodle sites | Four supplied HTTPS hosts, site picker and validated dynamic registry | Shared routing logic; native site-switch tests required |
| Remember last site | Shared SiteRegistry remembers validated HTTPS destinations | Source present; persistence test on Mac required |
| Back, forward and refresh | Native toolbar and WebKit history gestures | Native UI test required; refresh replaces touch pull-to-refresh |
| Animated branding splash | Original splash HTML/CSS/JS/assets | Resources and project references validated; rendering untested |
| Dark shell and Moodle themes | Dark AppKit window, original server theme CSS | Source present; visual parity untested |
| Offline/server error and retry | Opaque failure cover with retry and branding logo | Native errors untested; Android cube/morph animations are not reproduced |
| Privacy link and contact URLs | Privacy opens externally; explicit mail/tel/sms links | Source present; OS-handler tests required |
| Attachments/forms | User-selected file upload panel, native JS alert/confirm/prompt | Untested; camera/microphone web capture intentionally denied |
| Fullscreen media | Separate native protected media window | Window-recreation/fullscreen tests required |
| Protected images | Decode bounded images into protected sample buffers | Public preventsCapture API used; real capture tests required |
| Protected PDFs | PDFKit page rasterization into protected sample buffers | Page controls implemented; text search/selection not provided |
| Protected progressive video/audio | Pinned, authenticated 256 KiB range loader; video output to protected buffers | Parser XCTest source; decoding/seek/playback untested; HLS/DRM not implemented |
| Screenshot/recording resistance | preventsCapture for submitted media pixels; sharingType deterrence per window | **Not guaranteed**, especially for ordinary HTML or audio |
| Per-window protection reasons | Counted independent reasons; reapply on focus/fullscreen | Source inspected; no sharingType getter used as proof |
| Recognized recorder policy | Running QuickTime/OBS/ScreenFlow/Loom detection | Capability heuristic only; renamed/unknown tools evade it |
| Playback preflight and pause | Refuse unsafe playback; clear native pixels/pause on inactivity or failed gates | Real timing/audio tests required; no native screenshot notification |
| Background privacy | Hide WebView, clear media pixels, invalidate session on inactivity/sleep | OS snapshots and display timing untested |
| Watermark | Repeated account/device/time overlay | Visible attribution; experimental low-bit image marker is not robust forensic watermarking |
| Copy/drag/context menu/share/print/download | DOM restrictions, native menu/keyboard interception and download policy | UI deterrence; accessibility/page code are not DRM boundaries |
| Clipboard | Never writes course text; clears on inactivity/logout/purge | Clears user's existing clipboard too; real workflows required |
| Content caching | Nonpersistent WebKit and ephemeral URLSession; no offline content bundle | No application offline cache; OS/WebKit storage forensics required |
| Purge/revocation/logout | Clear page/store/cookies/media/pasteboard; server checks current account/device | Backend double tests pass; real Moodle integration required |
| ATS and SPKI pinning | Supplied current/backup leaf pins; normal CA/hostname/expiry checks retained | Config validated; live certificate/rotation checks not performed here |
| Hardware UUID | Optional IOPlatformUUID, signed metadata; server stores SHA-256 digest | Native access/persistence untested; never authenticates or auto-merges devices |
| Keychain UUID | Device-only, WhenUnlocked, non-synchronizing Keychain | Native Keychain tests required; can change after erase/key loss |
| Mac App Attest | macOS 27+ supported devices; Apple chain/nonce/key/ACL/category/build/counter validation | Synthetic cryptographic tests pass; real Apple certificates/assertions required |
| Unsupported-Mac enrollment | Per-origin P-256 software Keychain key, explicit admin user grants | Real signatures tested with Moodle doubles; weaker than App Attest |
| Device/account limits | Native fingerprint namespaces, grant checks at registration/binding/session checks | Enforcement tests pass; distributed DB/lock integration required |
| Exact OS/build kill switch | Separate Mac server policy, disabled by default | Policy tests pass; claimed OS is not independently certified in fallback |
| Session renewal | Five-minute bearer, fresh proof after four minutes, retired previous bearers | Backend tests; native cookie/renewal races require integration tests |
| Local integrity heuristics | Darwin debugger flag, suspicious environment/Frida dylibs, own signature checks | Cached every 0.5 s; bypassable and may have false positives |
| Hardened Runtime/sandbox/release stripping | Release project settings, restrictive entitlements, signed-app audit | Project/plists checked; actual signed binaries unaudited |
| App-store unavailable platforms | Separate native Mac app; original iOS runtime exclusions remain | App Store Connect iOS Mac/Vision availability is still an operator action |
| Additional CDN delivery, signed expiring URLs | No controlled CDN hosts supplied | Not configured; static/CDN URLs require separate server controls |
| Per-request App Attest, encrypted offline cache, assessment mode, commercial RASP | Not added | Current WebKit uses short-lived sessions; no offline feature or commercial service |

## Capture boundaries

Apple documents AVSampleBufferDisplayLayer.preventsCapture as capture protection
for the layer's submitted pixels. It does not protect arbitrary NSViews or the
WKWebView. NSWindow.sharingType = .none is a deterrent and cannot establish that a
ScreenCaptureKit recorder sees black pixels. Native macOS has no supported
universal screenshot/recording notification comparable to UIKit. Known process
checks are not recording detection and can block a non-recording QuickTime user.

Audio may be captured before a heuristic pauses playback, or by an unrecognized
recorder throughout playback. There is no universal native audio exclusion here.
There is no promise against external cameras, compromised Macs or extracted
non-DRM media. No private Telegram source was copied. Public APIs were implemented
independently, avoiding integration of the GPL Telegram codebases.

HTML course content remains a weaker path than protected native media. Inline
images/video posters may be visible in the page before the user opens the native
viewer. Restricting capture of every Moodle page would require a different
rendering/interaction architecture or an approved assessment mode; the current
app cannot truthfully advertise that capability.

## Available verification

- Apple cryptographic/parser suite: 35 passing synthetic certificate/CBOR checks.
- OS/build capture policy: 23 passing checks.
- Moodle bootstrap gate: 10 passing isolated-process checks.
- Identity/enforcement: 57 passing checks, included in the enrollment test run.
- Mac enrollment: 17 additional checks with real P-256 signatures and in-memory
  Moodle storage/locks: unapproved keys, cross-platform challenge, approved and
  wrong accounts, binding, signature tampering, origin mismatch, replay, exact OS
  denial, removal of account/key grants, malformed config and lock release.
- Total: **142 distinct backend checks**. These do not replace Moodle integration.
- Both Xcode project structures/references, XML property lists and shared schemes
  validated. Native XCTest source is present but has not run.
- No native build, signed-binary audit, Apple service exchange or capture test ran.

## Physical-Mac release acceptance

For **each exact OS/build allowed by the server**, record device model, OS patch,
app build/signing channel and capture output. Keep policy disabled until review.

1. Build Debug and Release, run XCTest; verify sandbox entitlements, Hardened
   Runtime, production App Attest and normal certificate trust with the release
   audit. Test both Intel/Apple Silicon where supported.
2. Verify real App Attest attestation/assertion/counter behavior on macOS 27,
   signed category/build mismatches, Apple outages, restored/lost keys and
   unsupported-client grants. Do not treat successful local API calls as server
   verification. Test Hardware UUID access in the signed sandboxed app.
3. Test QuickTime and ScreenCaptureKit recordings, system screenshot shortcuts,
   `screencapture`, OBS, renamed/custom recorders, full-display/window capture and
   remote/mirrored displays. Confirm protected native images/PDF/video pixels are
   omitted and attribution remains. Record actual HTML and audio leakage.
4. Start recording before launch, during playback, in the background and while
   changing fullscreen/displays. Check first frames and audio timing. Test camera
   filming separately; no software exclusion is expected.
5. Test login/logout, courses/quizzes/forms/themes, attachments, dialogs, navigation,
   site switching and refresh. Verify native media playback, audio-only files,
   seek/EOF, denied/malformed ranges and network errors.
6. Renew sessions during playback/forms. Revoke the account, device and enrollment
   grant during playback; test resumed/background sessions and rapid concurrent
   renewals under real Moodle distributed locks. No stale key/token may regain access.
7. Test wrong/expired certificates and both current/backup pins. Test redirect and
   cross-origin refusal. Verify private media cannot be fetched anonymously via
   static URLs, alternative clients or CDN origins.
8. Inspect app-switcher previews and local WebKit/cache/temp/log/crash/backup data.
   Inspect accessibility exposure. Decide whether residual OS-managed storage and
   unprotected HTML/audio meet the product's actual security requirements.

## References

- [Apple capture layer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture)
- [Apple App Attest validation](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
- [Native Mac App Attest presentation](https://developer.apple.com/videos/play/wwdc2026/201/)
- [Apple capture/audio guidance](https://developer.apple.com/library/archive/qa/qa1970/_index.html)
- [TelegramSwift gallery](https://github.com/overtake/TelegramSwift/blob/master/Telegram-Mac/MGalleryItem.swift)
- [Telegram Desktop macOS implementation](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/platform/mac/specific_mac.mm)
