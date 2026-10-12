#!/usr/bin/env python3
"""Run on macOS against the signed exported app, before distribution."""
import base64
import pathlib
import plistlib
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: verify-release.py /path/to/MedPrepMac.app")
app = pathlib.Path(sys.argv[1]).resolve()
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
entitlements = plistlib.loads(subprocess.run(
    ["codesign", "-d", "--entitlements", "-", str(app)], check=True, capture_output=True).stdout)
signing = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], check=True, capture_output=True).stderr.decode()
if "runtime" not in signing:
    raise SystemExit("Hardened Runtime required")
for key in ["get-task-allow", "com.apple.security.get-task-allow",
            "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.allow-unsigned-executable-memory"]:
    if entitlements.get(key) is True:
        raise SystemExit("Forbidden Release entitlement: " + key)
if entitlements.get("com.apple.security.app-sandbox") is not True:
    raise SystemExit("App Sandbox required")
if entitlements.get("com.apple.developer.devicecheck.appattest-environment") != "production":
    raise SystemExit("Production App Attest entitlement required")
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
if info.get("AppAttestEnvironment") != "production":
    raise SystemExit("App Attest configuration mismatch")
ats = info["NSAppTransportSecurity"]
if ats.get("NSAllowsArbitraryLoads") or ats.get("NSAllowsArbitraryLoadsInWebContent"):
    raise SystemExit("ATS exceptions forbidden")
for host in ["new.medpreparation.com", "med.medpreparation.com", "test.medpreparation.com", "moodle.cooky.theworkpc.com"]:
    pins = {entry["SPKI-SHA256-BASE64"] for entry in ats["NSPinnedDomains"][host]["NSPinnedLeafIdentities"]}
    if len(pins) < 2 or any(len(base64.b64decode(pin, validate=True)) != 32 for pin in pins):
        raise SystemExit("Current and backup SPKI pins required: " + host)
for pattern in ["*.dSYM", "*.swift", "*.p8", "*.key"]:
    if list(app.rglob(pattern)):
        raise SystemExit("Forbidden distributed artifact: " + pattern)
subprocess.run(["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)], check=True)
print("Signed-app checks passed. Real Apple/Moodle and physical capture tests remain required.")
