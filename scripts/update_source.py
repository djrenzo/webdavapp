#!/usr/bin/env python3
"""Add a release to the AltStore/SideStore/LiveContainer source JSON.

Usage: update_source.py SOURCE_JSON IPA_PATH VERSION BUILD DOWNLOAD_URL
Optional env: APP_NAME, BUNDLE_ID, MIN_OS_VERSION, RELEASE_NOTES
"""
import json
import os
import sys
from datetime import datetime, timezone

source_path, ipa_path, version, build, download_url = sys.argv[1:6]

with open(source_path) as f:
    source = json.load(f)

app = source["apps"][0]
if os.environ.get("APP_NAME"):
    app["name"] = os.environ["APP_NAME"]
if os.environ.get("BUNDLE_ID"):
    app["bundleIdentifier"] = os.environ["BUNDLE_ID"]

entry = {
    "version": version,
    "buildVersion": build,
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": os.environ.get("RELEASE_NOTES") or f"{app['name']} {version}",
    "downloadURL": download_url,
    "size": os.path.getsize(ipa_path),
    "minOSVersion": os.environ.get("MIN_OS_VERSION", "17.0"),
}

# Newest first; re-running the same version replaces its entry.
app["versions"] = [entry] + [v for v in app.get("versions", []) if v.get("version") != version]

# Legacy top-level fields still read by older AltStore/SideStore/LiveContainer builds.
for key in ("version", "downloadURL", "size"):
    app[key] = entry[key]
app["versionDate"] = entry["date"]
app["versionDescription"] = entry["localizedDescription"]

with open(source_path, "w") as f:
    json.dump(source, f, indent=2)
    f.write("\n")

print(f"Added {app['name']} {version} ({build}) -> {download_url}")
