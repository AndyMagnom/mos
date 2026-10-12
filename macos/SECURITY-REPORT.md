# macOS feature checklist and security release report

## Status

Xcode 26.2 AppKit/WKWebView source, shared Apple security owners, Moodle backend and
installable plugin package are implemented. This environment has no Xcode,
Apple SDK, physical Mac or live Moodle installation. The native code is **not
compiled or proven working**. The checklist records implementation and available
evidence rather than labeling untested features successfully ported.

The current Mac build excludes App Attest and administrator-approved enrollment.
Automatic software-key enrollment is explicitly enabled by server configuration.
iOS retains App Attest/DeviceCheck. Mac runtime integrity is a bypassable local
control; the backend cannot certify that a self-enrolled client is genuine.

## Feature checklist

| Feature from Android / addition | macOS implementation | Evidence / remaining check |
| --- | --- | --- |
| Moodle login, courses, quizzes, forums and server themes | WKWebView uses the original Moodle pages | Implemented; real account/course/theme workflows untested |
| Main/junior, senior and two test Moodle sites | Four supplied HTTPS hosts, site picker and validated dynamic registry | Shared routing logic; native site-switch tests required |
| Remember last site | Shared SiteRegistry remembers validated HTTPS destinations | Source present; persistence test on Mac required |
| Back, forward and refresh | Native toolbar and WebKit history gestures | Native UI test required; refresh replaces touch pull-to-refresh |
| Animated branding splash | Original splash HTML/CSS/JS/assets | Resources and project references validated; rendering untested |
| Dark shell and Moodle themes | Dark AppKit window, original server theme CSS | Source present; visual parity untested |
| Offline/server error and retry | Opaque failure cover with retry and branding logo | Native errors untested; Android morph animation is not reproduced |
| Two-cube loading animation | Native AppKit/Core Animation version of the 1.8 s chase | Source implemented; Reduce Motion stops animation; rendering untested |
| Previous-crash notice | MetricKit diagnostic timestamp on macOS 26+; unclean-run fallback on older systems | OS callbacks untested; fallback also detects force-quit/power loss |
| Native security notifications | Opt-in UserNotifications banners with generic policy-failure text | Permission/UI untested; banners do not detect capture events |
| External displays and mirroring | Exactly one online built-in display, no detected mirror set | All external displays denied in Release; Mac mini/Studio/clamshell blocked; real display tests required |
| VM detection and testing switch | Hypervisor/model heuristics enabled by default; Debug-only VM/virtual-display switches | Release forces detection on and exception off; unknown VMs can evade checks |
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
| Background privacy | Hide WebView, clear media pixels, invalidate session on inactivity/sleep | OS snapshots and display timing untested; display callbacks/polls can race initial frames |
| Watermark | Repeated account/device/time overlay | Visible attribution; experimental low-bit image marker is not robust forensic watermarking |
| Copy/drag/context menu/share/print/download | DOM restrictions, native menu/keyboard interception and download policy | UI deterrence; accessibility/page code are not DRM boundaries |
| Clipboard | Never writes course text; clears on inactivity/logout/purge | Clears user's existing clipboard too; real workflows required |
| Content caching | Nonpersistent WebKit and ephemeral URLSession; no offline content bundle | No application offline cache; OS/WebKit storage forensics required |
| Purge/revocation/logout | Clear page/store/cookies/media/pasteboard; server checks current account/device | Backend double tests pass; real Moodle integration required |
| ATS and SPKI pinning | Supplied current/backup leaf pins; normal CA/hostname/expiry checks retained | Config validated; live certificate/rotation checks not performed here |
| Hardware UUID | Optional IOPlatformUUID, signed metadata; server stores SHA-256 digest | Native access/persistence untested; never authenticates or auto-merges devices |
| Keychain UUID | Device-only, WhenUnlocked, non-synchronizing Keychain | Native Keychain tests required; can change after erase/key loss |
| Mac App Attest | Excluded from compilation and removed from Mac entitlements | Portable source checks pass; iOS and historical backend verification retained |
| Automatic Mac enrollment | Per-origin P-256 software Keychain key; no individual admin grant | Real signatures tested with Moodle doubles; key possession does not prove app integrity |
| Device/account limits | Native fingerprint namespaces, account-bound bearer checks at registration/binding/session use | Enforcement tests pass; distributed DB/lock integration required |
| Exact OS/build kill switch | Separate Mac server policy, disabled by default | Policy tests pass; claimed OS is not independently certified in automatic-key mode |
| Session renewal | Five-minute bearer, fresh proof after four minutes, retired previous bearers | Backend tests; native cookie/renewal races require integration tests |
| Local integrity/anti-hook checks | Debugger state, injected environment, known instrumentation-library substrings, compiled team/bundle signing requirement and unsafe-entitlement rejection | Process checks cached 0.5 s; signature/resource checks every 30 s; bypassable and may have false positives |
| Executable/resource tamper checks | Dynamic code and static all-architecture/nested-resource signature validation | Correct signing required; signed binary and controlled tamper tests unperformed |
| String encoding/obfuscation | Per-build AES-GCM encoding of selected detection strings/signing identity; whole-module optimization/dead-code/symbol stripping | Embedded decryption key is recoverable; no whole-program/commercial obfuscator or anti-decompilation guarantee |
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

- Apple cryptographic/parser suite: 35 passing synthetic certificate/CBOR checks
  for the retained iOS/historical Apple verifier.
- OS/build policy: 23 passing checks.
- Moodle bootstrap gate: 10 passing isolated-process checks.
- Identity/enforcement: 57 passing checks, included in the Mac enrollment run.
- Automatic Mac enrollment: 24 additional checks using real P-256 signatures with
  in-memory Moodle storage/locks. They cover disabled/default/malformed policy,
  platform separation, no-admin enrollment, non-attested metadata, account binding,
  registration/rebinding denial, signature/SPKI/hardware/origin tampering, replay,
  mixed Apple proof rejection, OS policy, stable identity after an allowed update,
  bearer retirement, delayed old-proof ordering, immediate policy denial and retired-grant migration rejection.
- Total: **149 distinct backend checks**; real Moodle DB/lock/upgrade tests remain.
- Portable project checks validate both projects' references, plists and schemes,
  compiled Mac SDK-27 API exclusions, Release VM/display-toggle exclusions, pins
  and release-audit Python syntax. They are not a Swift compiler.
- A separate non-distributable Testing configuration allows XCTest injection;
  the app runtime gate rejects that host for protected delivery. Normal Debug/
  Release retain hardening. Native XCTest source includes range/routing/policy/signal tests and new built-in
  display/decryption boundary tests; none have run here.
- No Xcode build, generated-string script execution, signed binary audit, MetricKit
  delivery, notification permission or physical capture/display/VM test ran here.

## Physical-Mac release acceptance

For each exact OS/build permitted by the server, record device model, OS patch,
app build/signing channel and capture output. Use staging for initial evaluation
and keep production policy disabled until review. Follow BUILD-SIGNED-RELEASE.md.

1. Build/test with Xcode 26.2, then archive/export Release. Verify generated-string
   decryption, compiled team/bundle requirement, sandbox/Keychain identifier,
   Hardened Runtime and absent forbidden/App Attest entitlements.
2. Test real Keychain enrollment/renewal, lost keys, OS updates, account/device
   limits/bans and server policy denial under Moodle DB/distributed locks. Normal
   UUID changes must never select another device. No Apple integrity is claimed.
3. Test built-in-only display enforcement: connect HDMI/USB/Thunderbolt monitors,
   AirPlay/Sidecar/mirror sets, clamshell mode and virtual/remote displays. Only
   the built-in single-display setup may show content in Release. Document cases
   Quartz does not expose; no guarantee against hidden capture or remote software.
4. Test default VM denial, Debug toggles, staging access, and real Release ignoring
   saved Debug preferences. The virtual-display exception must require detected
   virtualization, disabled VM detection and a single non-mirrored display.
5. Test QuickTime/ScreenCaptureKit/system screenshots/OBS/renamed or unknown tools,
   whole-display/window recording and app inactivity. Confirm actual native media
   pixel omission, logo/watermark visibility and documented HTML/audio leakage.
6. Test two-cube animation and Reduce Motion changes. Exercise actual MetricKit
   crash delivery plus force-quit/unclean-run fallback; generic notices must not
   be mislabeled confirmed crashes. Test permission-approved/denied notifications
   without revealing account IDs/tokens/content or weakening enforcement.
7. Test altered executable/resource copies, another-team/ad-hoc signing, injected
   libraries/debuggers and forbidden entitlements. Local tests only raise attacker
   cost; patched checks and self-enrolled clients remain possible without attestation.
8. Test login/logout, all themes/courses/quizzes/forms, attachments/dialogs and
   navigation; media seek/EOF/malformed ranges and network errors; four-minute
   renewal with in-flight cookies/ranges and paused/background sessions.
9. Test current/backup TLS pins, expiry/hostname failures, redirects, static/CDN
   bypass paths and certificate rotation. Inspect WebKit/temp/cache/log/crash/
   backup/accessibility exposure. Decide whether residual HTML/audio/storage
   exposure meets the actual security requirements before release.

## References

- [Apple capture layer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture)
- [Apple App Attest validation](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
- [Historical Mac App Attest presentation (excluded from this client)](https://developer.apple.com/videos/play/wwdc2026/201/)
- [Apple capture/audio guidance](https://developer.apple.com/library/archive/qa/qa1970/_index.html)
- [TelegramSwift gallery](https://github.com/overtake/TelegramSwift/blob/master/Telegram-Mac/MGalleryItem.swift)
- [Telegram Desktop macOS implementation](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/platform/mac/specific_mac.mm)

- [Apple UserNotifications permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [Apple built-in display detection](https://developer.apple.com/documentation/coregraphics/cgdisplayisbuiltin(_:))
- [Apple library validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
- [Apple MetricKit](https://developer.apple.com/documentation/metrickit/mxmetricmanager)
