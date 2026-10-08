#!/usr/bin/env python3
"""Apply retained App Store profiles only to the five iOS shipping targets."""

import argparse
import json
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--project", default="sing-box.xcodeproj/project.pbxproj")
parser.add_argument("--receipt", default="build/signing/receipt.json")
args = parser.parse_args()
project_path = Path(args.project)
project = json.loads(subprocess.check_output([
    "plutil", "-convert", "json", "-o", "-", str(project_path)
]))
profiles = json.loads(Path(args.receipt).read_text())["profiles"]
profile_by_identifier = {profile["identifier"]: profile["name"] for profile in profiles}
targets = {
    "SFI": "",
    "Extension": ".extension",
    "FileProviderExtension": ".fileprovider",
    "IntentsExtension": ".intents",
    "WidgetExtension": ".widget",
}
base = next(identifier for identifier in profile_by_identifier
            if all(identifier + suffix in profile_by_identifier for suffix in targets.values()))
objects = project["objects"]
configured = set()
for target in objects.values():
    if target.get("isa") != "PBXNativeTarget" or target.get("name") not in targets:
        continue
    name = target["name"]
    identifier = base + targets[name]
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    for configuration_id in configurations:
        settings = objects[configuration_id]["buildSettings"]
        settings["CODE_SIGN_STYLE[sdk=iphoneos*]"] = "Manual"
        settings["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = "Apple Distribution"
        settings["PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]"] = profile_by_identifier[identifier]
    configured.add(name)
    print(f"Configured {name}: {profile_by_identifier[identifier]}")
assert configured == set(targets), f"Missing shipping targets: {set(targets) - configured}"
project_path.write_bytes(plistlib.dumps(project, sort_keys=False))
