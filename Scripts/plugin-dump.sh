#!/bin/bash
# Prints a plugin folder's manifest as JSON, after checking it as Tinycast would: Manifest.swift runs,
# and main.swift compiles with the permissions it declares and registers just the commands it declares.
#   Scripts/plugin-dump.sh Examples/Plugins/hacker-news
# Shares its build with Scripts/test-plugins.sh.

set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <plugin folder>" >&2; exit 1; }
FOLDER="$(cd "$1" && pwd)"
cd "$(dirname "$0")/../Tests/PluginHost"
BUILD="${TMPDIR:-/tmp}/tinycast-plugin-host"
swift build -c release --scratch-path "$BUILD" --product tinycast-plugin > "$BUILD.log" 2>&1 || {
    grep -E "error:" "$BUILD.log" | sort -u >&2
    exit 1
}
exec "$BUILD/release/tinycast-plugin" dump "$FOLDER"
