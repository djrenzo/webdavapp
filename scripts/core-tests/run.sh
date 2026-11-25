#!/usr/bin/env bash
# Compile TorBoxLibraryManager/Core in Swift 6 strict mode (no Xcode needed; works on
# Linux) and check it against golden values produced by the Kodi addon's Python.
#
#   scripts/core-tests/run.sh
#
# To regenerate golden.json from the addon (keeps the two implementations in step):
#   python3 scripts/core-tests/golden.py ../kodi/addons/plugin.video.torbox > scripts/core-tests/golden.json
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/Core" "$work/Sources/CoreTests"
ln -s "$root"/TorBoxLibraryManager/Core/*.swift "$work/Sources/Core/"
ln -s "$here/main.swift" "$work/Sources/CoreTests/main.swift"
cat > "$work/Package.swift" <<'PKG'
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "Core",
    targets: [
        .target(name: "Core", path: "Sources/Core"),
        .executableTarget(name: "CoreTests", dependencies: ["Core"], path: "Sources/CoreTests"),
    ]
)
PKG
swift build --package-path "$work" -Xswiftc -warnings-as-errors 2>&1 | grep -v '^\[' || true
swift build --package-path "$work" -Xswiftc -warnings-as-errors >/dev/null
"$work/.build/debug/CoreTests" "$here/golden.json"
