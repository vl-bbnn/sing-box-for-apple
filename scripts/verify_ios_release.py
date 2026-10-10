#!/usr/bin/env python3
"""Verify exported release identity and core/application version agreement."""

import hashlib
import json
import os
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def inspect(path):
    core = os.environ['RELEASE_CORE_VERSION']
    version = os.environ['RELEASE_VERSION']
    number = os.environ['RELEASE_BUILD_NUMBER']
    bundle = os.environ['OVERLAY_BASE_PACKAGE_IDENTIFIER']
    if version != core.split('-', 1)[0]:
        raise ValueError('Application version differs from core base version')
    provenance = Path('build/libbox/ordinary/Libbox.xcframework')
    actual_core = (provenance / '.libbox-version').read_text().strip()
    source = (provenance / '.libbox-source-ref').read_text().strip()
    if source != os.environ['SING_BOX_REPO_REF']:
        raise ValueError('Core source differs from release pin')
    if not re.fullmatch(re.escape(core) + r'-[0-9a-f]{7,40}', actual_core):
        raise ValueError(f'Unexpected core version: {actual_core}')
    expected_ids = {bundle + suffix for suffix in (
        '', '.extension', '.fileprovider', '.intents', '.widget', '.share', '.action'
    )}
    bundles = []
    with zipfile.ZipFile(path) as archive:
        core_binaries = [name for name in archive.namelist() if re.fullmatch(
            r'Payload/[^/]+\.app/Frameworks/Library\.framework/Library', name
        )]
        if len(core_binaries) != 1 or actual_core.encode() not in archive.read(core_binaries[0]):
            raise ValueError('Expected core version is absent from the shared Library framework')
        for name in archive.namelist():
            if not re.fullmatch(r'Payload/[^/]+\.app/(?:[^/]+/[^/]+\.appex/)?Info\.plist', name):
                continue
            info = plistlib.loads(archive.read(name))
            identifier = info['CFBundleIdentifier']
            if info['CFBundleShortVersionString'] != version or info['CFBundleVersion'] != number:
                raise ValueError(f'Version mismatch in {identifier}')
            if identifier == bundle and info['CFBundleDisplayName'] != 'bbnn-vpn':
                raise ValueError('Unexpected application name')
            bundles.append({key: info[key] for key in (
                'CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'
            )})
    if len(bundles) != len(expected_ids) or {p['CFBundleIdentifier'] for p in bundles} != expected_ids:
        raise ValueError(f'Unexpected application/extension set: {bundles}')
    with Path(path).open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'sha256': digest, 'core_version': actual_core, 'core_source': source, 'bundles': bundles}


if __name__ == '__main__':
    print(json.dumps(inspect(sys.argv[1]), indent=2))
