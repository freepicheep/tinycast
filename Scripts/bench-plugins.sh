#!/bin/bash
# Time, CPU and memory of the same commands under the Raycast JS runtime and the Scrift plugin
# runtime, measured by Tests/PluginHost's plugin-bench the way the palette runs a command: a fresh
# runtime per launch. Engines alternate process by process so network conditions even out.
#
#   Scripts/bench-plugins.sh [processes] [launches per process]
#
# The JS versions are installed store extensions: BENCH_JS_EXTENSIONS (default: the app's
# extensions folder) holds hacker-news and cleanshotx; BENCH_JS_GOOGLE_TRANSLATE points at a built
# google-translate, whose cases are skipped without it. Google Translate and Hacker News fetch live.

set -euo pipefail
cd "$(dirname "$0")/.."

PROCESSES=${1:-7}
LAUNCHES=${2:-6}
JS=${BENCH_JS_EXTENSIONS:-"$HOME/Library/Application Support/com.abueammar.tinycast/extensions"}
GT=${BENCH_JS_GOOGLE_TRANSLATE:-}
EXAMPLES=$PWD/Examples/Plugins
BUILD=${BENCH_BUILD:-"${TMPDIR:-/tmp}/tinycast-plugin-host"}
OUT="${TMPDIR:-/tmp}/tinycast-plugin-bench"
rm -rf "$OUT" && mkdir -p "$OUT/cache"

(cd Tests/PluginHost && swift build -c release --scratch-path "$BUILD" --product plugin-bench > "$OUT/build.log" 2>&1) \
    || { tail -20 "$OUT/build.log"; exit 1; }
BENCH="$BUILD/release/plugin-bench"

# name | JS directory | JS command | plugin | plugin command | goal
CASES=(
    "Hacker News (view)|$JS/hacker-news|frontpage|hacker-news|stories|BENCH_ITEMS=30"
    "CleanShot X capture-area (no-view)|$JS/cleanshotx|capture-area|cleanshot-x|capture-area|"
)
if [ -n "$GT" ]; then
    CASES=(
        "Google Translate (view)|$GT|translate|google-translate|translate|BENCH_NEEDLE=Guten Morgen"
        "Google Translate instant copy (no-view)|$GT|instant-translate-copy|google-translate|instant-translate-copy|"
        "${CASES[@]}"
    )
fi
export BENCH_PREFS='{"langFrom":"auto","lang1":"de","lang2":"fr","autoInput":true}'

for entry in "${CASES[@]}"; do
    IFS='|' read -r name js_dir js_command plugin plugin_command goal <<< "$entry"
    file="$OUT/$(echo "$plugin_command-$plugin" | tr ' ' '-').jsonl"
    echo "▶ $name"
    # A first launch ever: no compiled module on disk yet.
    for _ in $(seq "$PROCESSES"); do
        rm -rf "$OUT/cache-fresh"
        env ${goal:+"$goal"} "$BENCH" scrift "$EXAMPLES/$plugin" "$plugin_command" 1 "$OUT/cache-fresh" \
            | sed 's/"engine":"scrift"/"engine":"scrift-uncached"/' >> "$file"
    done
    # As the app has it after its first scan: the manifest's result and the modules on disk.
    env ${goal:+"$goal"} "$BENCH" scrift "$EXAMPLES/$plugin" "$plugin_command" 1 "$OUT/cache" > /dev/null
    for _ in $(seq "$PROCESSES"); do
        env ${goal:+"$goal"} "$BENCH" js "$js_dir" "$js_command" "$LAUNCHES" >> "$file"
        env ${goal:+"$goal"} "$BENCH" scrift "$EXAMPLES/$plugin" "$plugin_command" "$LAUNCHES" "$OUT/cache" >> "$file"
    done
done

python3 -I - "$OUT" <<'EOF'
import glob, json, os, statistics, sys

def median(values):
    return statistics.median(values) if values else float("nan")

def ms(value): return f"{value * 1000:7.1f}"
def mb(value): return f"{value / 1048576:6.1f}"

for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    rows = [json.loads(line) for line in open(path) if line.startswith("{")]
    launches = [r for r in rows if "iteration" in r]
    failed = [r for r in launches if not r["ok"]]
    print(f"\n## {os.path.basename(path)[:-6]}  ({len(launches)} launches, {len(failed)} failed)")
    for r in failed[:3]:
        print(f"   failed: {r['engine']} {r['failure'][:120]}")
    print(f"{'':28}{'first render':>13}{'done':>9}{'CPU':>9}{'Δ memory':>10}{'retained':>10}")
    for engine, label, cold in [("js", "JS, first in process", True), ("scrift", "Scrift, first in process", True),
                                ("scrift-uncached", "Scrift, never compiled", True),
                                ("js", "JS, warm", False), ("scrift", "Scrift, warm", False)]:
        picked = [r for r in launches if r["ok"] and r["engine"] == engine and (r["iteration"] == 0) == cold]
        if not picked: continue
        first = [r["first_render_s"] for r in picked if r["first_render_s"] >= 0]
        print(f"{label:28}{(ms(median(first)) + ' ms') if first else '        —':>13}"
              f"{ms(median([r['content_s'] for r in picked]))} ms{ms(median([r['cpu_s'] for r in picked]))} ms"
              f"{mb(median([r['footprint_during'] for r in picked]))} MB{mb(median([r['footprint_retained'] for r in picked]))} MB")
    for engine in ["js", "scrift"]:
        summaries = [r for r in rows if r.get("summary") and r["engine"] == engine]
        if not summaries: continue
        print(f"{engine:>6}: setup {ms(median([s['setup_cpu_s'] for s in summaries]))} ms CPU,"
              f"{mb(median([s['setup_footprint'] for s in summaries]))} MB;"
              f" peak over baseline{mb(median([s['peak_over_baseline'] for s in summaries]))} MB;"
              f" retained after all launches{mb(median([s['retained_after_all'] for s in summaries]))} MB;"
              f" max threads {int(median([s['max_threads'] for s in summaries]))}")
EOF
