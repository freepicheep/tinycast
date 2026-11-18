#!/bin/bash
# WebAssembly plugins end to end: builds the kitchen fixture and every example with the Swift SDK
# for WebAssembly, then drives them through the shipped runtime. See docs/features/plugins.md.

set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${TMPDIR:-/tmp}/tinycast-plugins"
PLUGINS="$BIN/Plugins"
[ -n "${SKIP_PLUGIN_BUILD:-}" ] || rm -rf "$PLUGINS"
mkdir -p "$PLUGINS"

[ -n "${SKIP_PLUGIN_BUILD:-}" ] || for package in Tests/PluginFixtures/*/ Examples/Plugins/*/; do
    name=$(grep -o 'name: "[a-z0-9-]*"' "$package"/Sources/*/*.swift | head -1 | sed 's/.*"\(.*\)"/\1/')
    Scripts/build-plugin.sh "$package" "$PLUGINS/$name" > "$BIN/build-$name.log" 2>&1 || {
        grep -E "error:" "$BIN/build-$name.log" | sort -u
        echo "FAIL  building $package"
        exit 1
    }
    echo "built $name ($(du -h "$PLUGINS/$name/plugin.wasm" | cut -f1))"
done

E=Tinycast/Features/Extensions
P=Tinycast/Features/Plugins
swiftc -swift-version 6 -Onone -parse-as-library Tests/WasmPluginTests.swift \
    $P/Model/*.swift $P/Service/WasmInstance.swift $P/Service/WasmPluginRuntime.swift $P/Service/PluginCatalog.swift \
    $E/Model/ExtensionManifest.swift $E/Model/ExtensionEngine.swift $E/Model/ExtensionRefreshPolicy.swift \
    $E/Model/ExtensionRefreshState.swift $E/Model/ExtensionJSON.swift $E/Model/RenderNode.swift \
    $E/Model/ExtensionBootConfig.swift $E/Model/ExtensionLaunchType.swift $E/Model/ExtensionLaunchError.swift \
    $E/Model/ExtensionHostError.swift $E/Service/ExtensionCommandRuntime.swift $E/Service/ExtensionCatalog.swift \
    Tinycast/Platform/AppDisplayName.swift Tinycast/Platform/AppPaths.swift \
    -o "$BIN/WasmPluginTests" > "$BIN/compile.log" 2>&1 || {
    grep -E "error:" "$BIN/compile.log" | sort -u
    exit 1
}
"$BIN/WasmPluginTests" "$PLUGINS"
