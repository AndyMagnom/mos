# Build a signed MedPrep Mac release with Xcode 26.2

This procedure produces a Developer ID-signed, notarized app for direct Mac
distribution. It does not publish to the Mac App Store. The native project has
not been compiled in this Linux environment: resolve compiler/runtime failures
and complete physical testing before distributing.

## 1. Prepare the Mac and signing account

1. Install Xcode 26.2 on a supported macOS version and launch it once to install
   components. Choose that installation under Xcode Settings > Locations >
   Command Line Tools.
2. Use a paid Apple Developer Program account for Developer ID distribution.
   Add it in Xcode Settings > Accounts. Obtain a **Developer ID Application**
   certificate under Manage Certificates. Keep its private key protected.
3. Copy the entire MedPrep workspace, including `shared`, `ios`, `macos` and
   `Plugin`, to the Mac. Do not copy only the `.xcodeproj`.
4. Use a MacBook/iMac with its built-in display. Disconnect external monitors,
   turn off display mirroring/AirPlay/Sidecar and close recognized recorder apps.
   The selected Release policy blocks Mac mini/Studio and clamshell-only display
   setups. VM exceptions exist only in Debug.

## 2. Set the project signing identity

1. Open `macos/MedPrepMac.xcodeproj` in Xcode 26.2.
2. Select the **MedPrepMac** target > Signing & Capabilities. Enable Automatically
   manage signing and choose your team. Keep bundle ID `com.med.prep.mac` if you
   own it, otherwise use an explicit identifier registered to your team.
3. Set the same team on **MedPrepMacTests** and adjust its test bundle identifier
   to match your namespace if needed. Keep team/bundle identifiers stable later
   so Keychain identity remains accessible across updates.
4. Leave **App Sandbox** and **Hardened Runtime** enabled. Keep outgoing network
   connections and user-selected read-only files. Do not add App Attest, disable
   library validation, unsigned-memory, DYLD-environment or debugger entitlements.
5. Build number is currently **2**. Increment it for later releases and update
   the backend minimum-build policy appropriately.
6. The generator embeds your selected team/bundle ID into encoded compile-time
   constants. A Release build with no valid team fails intentionally. Do not
   edit generated `R7.swift` or remove the generation phase.

## 3. Configure staging Moodle

Install `Plugin/LockGuard_v3_11_1_apple.zip` through Moodle's plugin upgrade process.
Back up the database/plugin/config first. Configure every Moodle origin using
`Plugin/source/devicelock/README-macOS.md`. The minimum Mac build is 2.

Automatic enrollment needs `$CFG->auth_devicelock_macos_device_keys['enabled']`
set to the actual Boolean `true`. No per-device administrator grant or Mac App
Attest certificate is required. Enable only your exact staging test OS versions
for testing; leave production policy disabled until acceptance review.

`sw_vers -productVersion` identifies the host OS. Normalize it to three numeric
components: `26.2` becomes `26.2.0`. The app uses the running OS version, not the
Xcode/SDK version. Keep Moodle device/app-only restrictions enabled.

## 4. Build and test Debug

Select **MedPrepMac**, destination **My Mac**, then Product > Build. The shared
Run scheme disables debugger attachment and Main Thread Checker. Keep those
disabled when testing content; injected debugging tools cause a security cover.

Run Product > Test (Command-U) for routing, range, display and generated-string
unit tests. The shared Test action uses a dedicated **Testing** configuration:
its host permits debugger injection and disables Hardened Runtime solely so
XCTest can load. The app's runtime gate rejects those unsafe conditions and does
not serve protected content. Normal Debug and Release retain hardening. Never
export/distribute Testing; the release audit rejects it. These unit tests do not
bypass or prove protected course delivery. Run the app separately for
course/media workflows. For VM testing, use the two Debug menu switches described
in `README.md`; the final Release will ignore them.

Test login/logout, site switching, themes, uploads/dialogs, cube animation,
crash/unclean-run notices, notification permission denial/approval, native media
seek/EOF, renewal, blocked displays/VMs, altered resources/signatures, and the
capture cases in `SECURITY-REPORT.md`. Native HTML/audio capture remains a known
limit, regardless of test results.

## 5. Archive Release

In Xcode choose Product > Scheme > Edit Scheme > Archive and confirm **Release**.
Choose a Mac destination, then Product > Archive. Keep the archive and its dSYM
privately. Never distribute the Debug build.

Command-line alternative, run from the workspace root after setting the team:

```sh
xcodebuild -project macos/MedPrepMac.xcodeproj -scheme MedPrepMac \
  -configuration Release -archivePath build/MedPrepMac.xcarchive \
  -allowProvisioningUpdates archive
```

Do not fix signing failures by disabling security entitlements or switching to
ad-hoc signing. Correct team, certificate, identifier and provisioning settings.
The exported app must retain a valid `com.apple.application-identifier` for the
data-protection Keychain; the release audit checks it.

## 6. Export with Developer ID

Open Window > Organizer > Archives, select the archive and choose Distribute App.
Choose the Developer ID/direct-distribution workflow (under Custom if that Xcode
screen groups the options). Use **Developer ID Application**, automatic signing
and the same team. You may use Xcode's Upload/notarization flow and export again
after it staples the accepted ticket.

For an explicit local export followed by command-line notarization:

```sh
xcodebuild -exportArchive -archivePath build/MedPrepMac.xcarchive \
  -exportOptionsPlist macos/ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
```

Do not modify files inside the exported `.app`, or re-sign it with another team.

## 7. Notarize and staple

If Xcode already completed notarization and stapling, skip the upload here and
validate the exported ticket. Otherwise create a notary Keychain profile with
interactive prompts; use an app-specific password, not your normal password.
Do not put credentials in the project or scripts.

```sh
xcrun notarytool store-credentials "MedPrepNotary"
ditto -c -k --keepParent "build/export/MedPrepMac.app" "build/MedPrepMac-notary.zip"
xcrun notarytool submit "build/MedPrepMac-notary.zip" \
  --keychain-profile "MedPrepNotary" --wait
```

Continue only when Apple reports **Accepted**. For a rejection, read its log and
fix the actual issue. Then:

```sh
xcrun stapler staple "build/export/MedPrepMac.app"
xcrun stapler validate "build/export/MedPrepMac.app"
python3 macos/scripts/verify-release.py "build/export/MedPrepMac.app"
```

The audit checks strict signing, Hardened Runtime, sandbox, forbidden entitlements,
Keychain application ID, absence of Mac App Attest configuration, built-in-only
policy, current/backup pins and absence of bundled source/private keys/dSYM. It
also runs Gatekeeper assessment. It does not prove runtime hook/capture resistance.

## 8. Test the exact exported app and distribute

Launch the exported app on a separate supported physical Mac with its built-in
screen. Test the exact signed build/OS combinations before enabling production
policy. Test TLS pins and backup-certificate rotation against staging. Confirm
Release ignores old Debug VM preferences and cannot enable the virtual display
exception. Verify own-team/resource checks with controlled negative test copies.

After successful review, package the stapled app:

```sh
ditto -c -k --keepParent "build/export/MedPrepMac.app" "build/MedPrepMac-release.zip"
```

Distribute this final ZIP, not the earlier pre-stapling upload ZIP. Keep private
keys, notary credentials, source, archives and dSYM outside the release package.
Do not claim universal screenshot, audio-capture or reverse-engineering prevention.

Apple references:
[Developer ID](https://developer.apple.com/developer-id/),
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Keychain application identifiers](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).
