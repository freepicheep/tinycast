#!/usr/bin/env bash
# Builds a plugin package into <destination>/plugin.wasm, ready to drop in the Plugins folder.
#   Scripts/build-plugin.sh Examples/Plugins/hacker-news ~/Library/Application\ Support/Tinycast\ Dev/Plugins/hacker-news
# Needs the Swift SDK for WebAssembly and the swift.org toolchain of the same version; Xcode's
# compiler can't link WebAssembly. TINYCAST_WASM_SDK picks an SDK when several are installed.
set -euo pipefail

package="${1:?usage: build-plugin.sh <package-dir> [destination-dir]}"
destination="${2:-$package/build}"

sdk="${TINYCAST_WASM_SDK:-$(swift sdk list 2>/dev/null | grep -E '_wasm$' | head -1)}"
if [[ -z "$sdk" ]]; then
    echo "No Swift SDK for WebAssembly is installed: see https://www.swift.org/documentation/articles/wasm-getting-started.html" >&2
    exit 1
fi
version="${sdk%_wasm}"
toolchain="$HOME/Library/Developer/Toolchains/$version.xctoolchain"
if [[ ! -d "$toolchain" ]]; then
    echo "The $sdk SDK needs the $version toolchain from swift.org in ~/Library/Developer/Toolchains." >&2
    exit 1
fi
TOOLCHAINS="$(plutil -extract CFBundleIdentifier raw "$toolchain/Info.plist")"
export TOOLCHAINS

swift build --package-path "$package" --swift-sdk "$sdk" -c release
products="$(swift build --package-path "$package" --swift-sdk "$sdk" -c release --show-bin-path)"
modules=("$products"/*.wasm)
if [[ ${#modules[@]} -ne 1 ]]; then
    echo "Expected one executable target in $package, found ${#modules[@]} modules." >&2
    exit 1
fi

mkdir -p "$destination"
if command -v wasm-opt >/dev/null; then
    # The SDK's features: Tinycast's JavaScriptCore runs all of them.
    wasm-opt -Os --strip-debug --enable-bulk-memory --enable-sign-ext --enable-mutable-globals \
        --enable-nontrapping-float-to-int --enable-reference-types --enable-multivalue \
        "${modules[0]}" -o "$destination/plugin.wasm"
else
    cp "${modules[0]}" "$destination/plugin.wasm"
fi
echo "$destination/plugin.wasm ($(du -h "$destination/plugin.wasm" | cut -f1))"
