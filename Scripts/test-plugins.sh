#!/bin/bash
# Plugin sessions against real Scrift: a SwiftPM package, since a lone swiftc harness can't link it.
# The first run builds Scrift and swift-syntax (a few minutes); later runs reuse the build outside the repo.

set -euo pipefail
cd "$(dirname "$0")/../Tests/PluginHost"
BUILD="${TMPDIR:-/tmp}/tinycast-plugin-host"
swift build -c release --scratch-path "$BUILD" > "$BUILD.log" 2>&1 || {
    grep -E "error:" "$BUILD.log" | sort -u
    exit 1
}
"$BUILD/release/PluginHostTests"
# Every example must dump: its manifest runs and main.swift registers just what it declares.
for example in ../../Examples/Plugins/*/; do
    "$BUILD/release/tinycast-plugin" dump "$example" > /dev/null
    echo "PASS  tinycast-plugin dump $(basename "$example")"
done
