#!/usr/bin/env python3
"""Portable source/project checks. These are not a Swift compiler or device test."""
import ast
import json
import pathlib
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOKEN = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', re.S)

def project(path):
    tokens = [m.group() for m in TOKEN.finditer(path.read_text())
              if not (m.group().isspace() or m.group().startswith(('//', '/*')))]
    offset = 0
    def value():
        nonlocal offset
        token = tokens[offset]; offset += 1
        if token == '{':
            result = {}
            while tokens[offset] != '}':
                key = value(); assert tokens[offset] == '='; offset += 1
                result[key] = value(); assert tokens[offset] == ';'; offset += 1
            offset += 1
            return result
        if token == '(':
            result = []
            while tokens[offset] != ')':
                result.append(value())
                if tokens[offset] == ',': offset += 1
            offset += 1
            return result
        return json.loads(token) if token.startswith('"') else token
    result = value()
    assert offset == len(tokens)
    return result

def mac_source(path, debug):
    # Evaluate only the conditional directives used by these task-owned files.
    result = []; stack = []; active = True
    for line in path.read_text().splitlines():
        text = line.strip()
        if text.startswith('#if '):
            conditions = {'os(macOS)': True, '!os(macOS)': False, 'DEBUG': debug}
            condition = conditions[text[4:]]
            stack.append((active, condition)); active = active and condition
        elif text == '#else':
            parent, condition = stack[-1]; active = parent and not condition
        elif text == '#endif':
            active, _ = stack.pop()
        elif active: result.append(line)
    assert not stack
    return '\n'.join(result)

for platform, name in [('ios', 'MedPrep'), ('macos', 'MedPrepMac')]:
    base = ROOT / platform
    parsed = project(base / f'{name}.xcodeproj/project.pbxproj')
    objects = parsed['objects']; assert parsed['rootObject'] in objects
    for identity, obj in objects.items():
        for field in ['fileRef', 'mainGroup', 'productReference', 'containerPortal', 'target', 'targetProxy', 'buildConfigurationList']:
            if field in obj: assert obj[field] in objects, (platform, identity, field)
        for field in ['children', 'files', 'buildPhases', 'targets', 'buildConfigurations', 'dependencies']:
            for ref in obj.get(field, []): assert ref in objects, (platform, identity, field, ref)
        if obj['isa'] == 'PBXFileReference' and obj.get('lastKnownFileType') == 'sourcecode.swift':
            if obj.get('sourceTree') == 'DERIVED_FILE_DIR':
                assert platform == 'macos' and obj['path'] == 'R7.swift'
                assert any('$(DERIVED_FILE_DIR)/R7.swift' in phase.get('outputPaths', []) for phase in objects.values())
            else:
                assert (base / obj['path']).is_file(), obj['path']
    for p in (base / name).rglob('*'):
        if p.suffix in ['.plist', '.entitlements', '.xcprivacy']: plistlib.loads(p.read_bytes())
    scheme = ET.parse(base / f'{name}.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme')
    if platform == 'macos':
        assert scheme.getroot().find('TestAction').get('buildConfiguration') == 'Testing'
        assert scheme.getroot().find('ArchiveAction').get('buildConfiguration') == 'Release'
        for obj in objects.values():
            if obj['isa'] == 'XCBuildConfiguration':
                assert 'APP_ATTEST_ENVIRONMENT' not in obj['buildSettings']
                if obj['buildSettings'].get('PRODUCT_BUNDLE_IDENTIFIER') == 'com.med.prep.mac':
                    expected = 'NO' if obj['name'] == 'Testing' else 'YES'
                    assert obj['buildSettings']['ENABLE_HARDENED_RUNTIME'] == expected
                if obj['name'] == 'Release':
                    assert 'DEBUG' not in obj['buildSettings'].get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '')
    print(platform + ': project references, plists and scheme checked')

for debug in [True, False]:
    active = mac_source(ROOT / 'shared/DeviceIdentity.swift', debug)
    assert 'DCAppAttestService' not in active and 'import DeviceCheck' not in active
    assert 'mac_device_challenge' in active and 'verifyDeviceKey' in active
    gate = mac_source(ROOT / 'macos/MedPrepMac/SecurityGate.swift', debug)
    delegate = mac_source(ROOT / 'macos/MedPrepMac/AppDelegate.swift', debug)
    if not debug:
        assert 'toggleVirtualMachines' not in gate and 'toggleVirtualDisplay' not in delegate
        assert 'return true' in gate.split('static var detectVirtualMachines: Bool {')[1].split('}')[0]
        assert 'return false' in gate.split('static var allowVirtualTestDisplay: Bool {')[1].split('}')[0]
print('Mac SDK-27 API exclusions and Release VM/display switch exclusions checked')
mac = plistlib.loads((ROOT / 'macos/MedPrepMac/Info.plist').read_bytes())
ios = plistlib.loads((ROOT / 'ios/MedPrep/Info.plist').read_bytes())
assert mac['NSAppTransportSecurity']['NSPinnedDomains'] == ios['NSAppTransportSecurity']['NSPinnedDomains']
assert mac['MedPrepDisplayPolicy'] == 'builtin' and mac['MedPrepVMDetectionRequired'] is True
assert 'AppAttestEnvironment' not in mac
entitlements = plistlib.loads((ROOT / 'macos/MedPrepMac/MedPrepMac.entitlements').read_bytes())
assert 'com.apple.developer.devicecheck.appattest-environment' not in entitlements
ast.parse((ROOT / 'macos/scripts/verify-release.py').read_text())
print('Pins, built-in-only policy and release audit syntax checked; native build/device tests still required')
