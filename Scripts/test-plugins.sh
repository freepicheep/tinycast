#!/bin/bash
# Plugin sessions against real Stir: a SwiftPM package, since a lone swiftc harness can't link it.
# The first run builds Stir and swift-syntax (a few minutes); later runs reuse the build outside the repo.

set -euo pipefail
cd "$(dirname "$0")/../Tests/PluginHost"
BUILD="${TMPDIR:-/tmp}/tinycast-plugin-host"
swift build -c release --scratch-path "$BUILD" --product PluginHostTests > "$BUILD.log" 2>&1 || {
    grep -E "error:" "$BUILD.log" | sort -u
    exit 1
}
exec "$BUILD/release/PluginHostTests"
