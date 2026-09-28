#!/usr/bin/env bash
# LUMENFALL build & release matrix — stopgap local runner (AGE-46).
# Implements Studio Pipeline Standard v1.0 §2.2/§2.3 for the Godot leg.
# Unity/Unreal/Roblox legs report SKIP until their toolchains land
# (AGE-10 CI runners + engine specialist scaffolds). Same script runs
# on CI runners unchanged: set GODOT_BIN / CI_COMMIT_REF_NAME / CI_PIPELINE_IID.
#
# Verdicts per leg: PASS | FAIL | SKIP.  Any FAIL => exit 1 (release blocked).
# Artifact naming (LOCKED — see BUILD_MATRIX.md):
#   builds/lumenfall_${CI_COMMIT_REF_NAME:-local}_${CI_PIPELINE_IID:-<utcstamp>}/
#
# Environment overrides:
#   GODOT_BIN              engine binary (must pair with installed export templates)
#   LUMENFALL_BUILD_ROOT   output root (default: <repo>/builds)
#   CI_COMMIT_REF_NAME     branch or tag (default: local)
#   CI_PIPELINE_IID        build number (default: UTC stamp)
#   WEB_BUDGET_MB          Q-16 payload budget (default: 60)
#   LUMENFALL_CACHE_ROOT   import/tool cache root (default: ~/.cache/lumenfall-ci)
#   CACHE_ENTRIES_MAX      import-cache entries retained (default: 5)
#   SKIP_TOKEN_GATE        set non-empty to skip the design-token CI gate
#   LEGS                   comma list filter (AGE-140): e.g. LEGS=unity runs
#                          ONLY the unity leg; LEGS=godot skips unity/unreal/
#                          roblox. Unset = all legs (default, unchanged).
#   UNITY_LICENSE          personal-license .ulf contents for headless CI
#   UNITY_BIN              explicit Unity editor binary override
#
# Cache (AGE-143): .godot/ import cache is restored from/stored to
# $CACHE_ROOT/import/<proj_hash>.tgz, keyed on a content hash of
# import-relevant tracked+untracked files plus the engine version. Hit/miss
# accounting lands in $CACHE_ROOT/stats/hits.jsonl; per-leg timings land in
# <out>/build_metrics.json. Parent gate (AGE-89): >60% hit rate across runs.
set -uo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
# Binary discovery (ordered): explicit GODOT_BIN > legacy raw-universal layout
# > app-bundle layouts under ~/tools/godot-4.*. Do NOT hard-code a single path —
# the tools dir layout has drifted before (raw binary -> Godot.app bundle).
GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
  for cand in \
    "$HOME/tools/godot-4.5.1/Godot_v4.5.1-stable_macos.universal/Godot_v4.5.1-stable_macos.universal" \
    "$HOME/tools/godot-4.5.1/Godot.app/Contents/MacOS/Godot" \
    "$HOME"/tools/godot-4.*/Godot.app/Contents/MacOS/Godot; do
    if [ -x "$cand" ]; then GODOT="$cand"; break; fi
  done
fi
GODOT_REQUIRED="${GODOT_REQUIRED:-1}"   # missing godot binary = FAIL (release gate), not SKIP
REF_NAME="${CI_COMMIT_REF_NAME:-local}"
BUILDNUM="${CI_PIPELINE_IID:-$(date -u +%Y%m%d.%H%M%S)}"
BUILD_ROOT="${LUMENFALL_BUILD_ROOT:-$PROJ/builds}"
OUT="$BUILD_ROOT/lumenfall_${REF_NAME}_${BUILDNUM}"
LOGS="$OUT/logs"
WEB_BUDGET_MB="${WEB_BUDGET_MB:-60}"   # Q-16: web payload <= 60 MB

VERDICTS=()
overall=0

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- metrics (AGE-143)
METRICS_JSON="$OUT/build_metrics.json"
CACHE_ROOT="${LUMENFALL_CACHE_ROOT:-$HOME/.cache/lumenfall-ci}"
CACHE_ENTRIES_MAX="${CACHE_ENTRIES_MAX:-5}"
PHASE_T0=""
phase_start() { PHASE_T0="$(date +%s.%N)"; }
phase_end() { # phase_end <name>  -> appends ms timing to metrics stream
  [ -z "$PHASE_T0" ] && return 0
  local now end_ms name="$1"
  now="$(date +%s.%N)"
  end_ms="$(awk -v a="$PHASE_T0" -v b="$now" 'BEGIN{printf "%d", (b-a)*1000}')"
  printf '%s\n' "{\"phase\":\"$name\",\"ms\":$end_ms}" >>"$OUT/.timings.jsonl"
  PHASE_T0=""
}

timings_to_json() { # fold .timings.jsonl into build_metrics.json at summary time
  [ -f "$OUT/.timings.jsonl" ] || printf '' >"$OUT/.timings.jsonl"
  python3 - "$OUT" "$CACHE_ROOT" "$METRICS_JSON" <<'PY'
import json, sys
out, cache_root, metrics = sys.argv[1:4]
timings = {}
for line in open(f"{out}/.timings.jsonl"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    timings[rec["phase"]] = rec["ms"]
stats = {"hits": 0, "misses": 0}
try:
    for line in open(f"{cache_root}/stats/hits.jsonl"):
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("event") == "hit":
            stats["hits"] += 1
        elif rec.get("event") == "miss":
            stats["misses"] += 1
except FileNotFoundError:
    pass
total = stats["hits"] + stats["misses"]
rate = round(100 * stats["hits"] / total, 1) if total else None
json.dump({"timingsMs": timings,
           "cache": {**stats, "hitRatePct": rate,
                     "gate": "pass" if (rate or 0) > 60 else "not-yet/insufficient-runs"}},
          open(metrics, "w"), indent=2)
PY
}

# ---------------------------------------------------------------- cache (AGE-143)
proj_cache_key() { # content hash of import-relevant inputs + engine version
  local engine_ver
  engine_ver="$("$GODOT" --version 2>/dev/null | tail -1 || echo noengine)"
  {
    printf 'engine:%s\n' "$engine_ver"
    # tracked + untracked-but-not-ignored files that can change import output
    git -C "$PROJ" ls-files --cached --others --exclude-standard -- \
      '*.gd' '*.tscn' '*.tres' '*.godot' '*.import' '*.cfg' '*.svg' \
      '*.png' '*.jpg' '*.jpeg' '*.webp' '*.wav' '*.ogg' '*.mp3' '*.glb' '*.gltf' \
      'project.godot' 'export_presets.cfg' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        [ -f "$PROJ/$f" ] && { stat -f '%m %z' "$PROJ/$f"; printf '%s\n' "$f"; }
      done
  } | shasum -a 256 | cut -d' ' -f1
}

cache_record() { # cache_record <hit|miss> <key> <note>
  mkdir -p "$CACHE_ROOT/stats"
  printf '{"ts":"%s","event":"%s","key":"%s","note":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >>"$CACHE_ROOT/stats/hits.jsonl"
}

cache_restore_import() {
  local key
  key="$(proj_cache_key)"
  say "  cache: project hash ${key:0:12}"
  if [ -f "$CACHE_ROOT/import/$key.tgz" ]; then
    if tar -xzf "$CACHE_ROOT/import/$key.tgz" -C "$PROJ" 2>>"$LOGS/cache.log"; then
      say "  cache: HIT — .godot/ restored from $CACHE_ROOT/import/$key.tgz"
      cache_record hit "$key" "restored import cache"
      return 0
    fi
    say "  cache: stored blob corrupt (see cache.log); treating as miss"
  fi
  cache_record miss "$key" "no blob for key"
  return 1
}

cache_store_import() {
  local key
  key="$(proj_cache_key)"
  if ! tar -czf "$CACHE_ROOT/import/$key.tgz.tmp" -C "$PROJ" .godot 2>>"$LOGS/cache.log"; then
    say "  cache: store failed (non-fatal; see cache.log)"
    rm -f "$CACHE_ROOT/import/$key.tgz.tmp"
    return 0
  fi
  mv "$CACHE_ROOT/import/$key.tgz.tmp" "$CACHE_ROOT/import/$key.tgz"
  printf '%s\n' "$key" >"$CACHE_ROOT/import/$key.key"   # provenance stamp
  say "  cache: stored .godot/ -> $CACHE_ROOT/import/$key.tgz ($(du -h "$CACHE_ROOT/import/$key.tgz" | cut -f1))"
  # LRU trim
  ls -t "$CACHE_ROOT/import"/*.tgz 2>/dev/null | tail -n +$(( CACHE_ENTRIES_MAX + 1 )) | while IFS= read -r old; do
    rm -f "$old" "${old%.tgz}.key"
  done
}

# tool cache: engine binaries under ~/tools are immutable once installed; the
# cache layer just records presence so hit-rate reporting reflects the tool leg
# honestly (a present tool = a restored dependency, no re-download needed).
cache_tool_leg() {
  local tools=("$GODOT" "$HOME/Library/Application Support/Godot/export_templates/4.5.1.stable")
  local ok=1 t
  for t in "${tools[@]}"; do
    if [ -e "$t" ]; then
      cache_record hit "tool:$(basename "$t")" "tool present: $t"
    else
      cache_record miss "tool:$(basename "$t")" "tool absent: $t"
      ok=0
    fi
  done
  return $(( 1 - ok ))
}

verdict() { # verdict <leg> <PASS|FAIL|SKIP>
  VERDICTS+=("$1=$2")
  if [ "$2" = "FAIL" ]; then overall=1; fi
  return 0
}

run_logged() { # run_logged <timeout_s> <logfile> <cmd...>  -> exit code of cmd
  local t="$1" log="$2"
  shift 2
  perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed\n"' "$t" "$@" >"$log" 2>&1
}

has_err() { grep -Eq '^(ERROR|SCRIPT ERROR)' "$1"; }

inject_tips_widget() { # add the Cookie Crumbs on-chain tip widget to the exported web shell
  # Idempotent: skips if the marker is already present. Non-fatal on failure —
  # the tip widget is a revenue surface, not a release gate.
  local html="$OUT/web/index.html" marker="cookie-crumbs/embed.js"
  if [ ! -f "$html" ]; then return 0; fi
  if grep -q "$marker" "$html"; then
    say "  web: tips widget already present (skipping injection)"
    return 0
  fi
  if ! perl -0pi -e 's|\t</body>|\t<div style="position:fixed;left:12px;bottom:12px;z-index:9999">\n\t\t<script src="https://aaron11998.github.io/cookie-crumbs/embed.js" data-label="Tip the devs 🍪"></script>\n\t</div>\n\t</body>|' "$html"; then
    say "  web: tips widget injection failed (non-fatal)"
    return 0
  fi
  if grep -q "$marker" "$html"; then
    say "  web: Cookie Crumbs tips widget injected (CLAW-72)"
  else
    say "  web: tips widget injection produced no change (non-fatal)"
  fi
  return 0
}

gate_fail() { # gate_fail <leg> <msg>
  say "  FAIL: $2"
  verdict "$1" FAIL
}

# ---------------------------------------------------------------- godot preflight
godot_preflight() {
  say "== [godot] preflight: import + smoke =="
  if [ ! -x "$GODOT" ]; then
    if [ "$GODOT_REQUIRED" = "1" ]; then
      # Release gate contract: godot legs are REQUIRED. A missing engine binary
      # must FAIL the matrix (exit 1), not SKIP green — a green run that builds
      # nothing is the worst possible gate signal.
      gate_fail godot_web "godot binary missing or not executable: ${GODOT:-<none found>} (set GODOT_BIN; see header)"
      verdict godot_macos FAIL
    else
      say "  SKIP: godot binary missing (${GODOT:-<none found>}); GODOT_REQUIRED=0"
      verdict godot_web SKIP; verdict godot_macos SKIP
    fi
    return 1
  fi
  say "  engine: $("$GODOT" --version 2>/dev/null | tail -1)"

  # 0) cache restore (AGE-143): try content-keyed .godot/ import cache first
  mkdir -p "$CACHE_ROOT/import"
  cache_tool_leg || true
  cache_restored=0
  if cache_restore_import; then
    # restored: run a reconcile import so Godot picks up any timestamp drift;
    # warm reconcile is seconds vs minutes cold. Errors here => fall back cold.
    phase_start
    run_logged 180 "$LOGS/import_reconcile.log" "$GODOT" --headless --path "$PROJ" --import || true
    phase_end "import_reconcile_warm"
    if has_err "$LOGS/import_reconcile.log"; then
      say "  cache: reconcile import flagged errors — falling back to cold import"
      grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/import_reconcile.log" | head -3 | while IFS= read -r l; do say "    $l"; done
      cache_record miss "$(proj_cache_key)" "reconcile failed -> cold import"
      rm -rf "$PROJ/.godot"
    else
      cache_restored=1
    fi
  fi

  if [ "$cache_restored" = "1" ]; then
    say "  import: restored from cache + reconcile clean"
  else
    phase_start
    # 1) headless import (cold runs can take minutes; warm ~20 s)
    if ! run_logged 420 "$LOGS/import.log" "$GODOT" --headless --path "$PROJ" --import; then
      gate_fail godot_web "import timed out or crashed ($LOGS/import.log)"
      verdict godot_macos FAIL
      return 1
    fi
    phase_end "import_cold"
    if has_err "$LOGS/import.log"; then
      gate_fail godot_web "import log has errors:"
      grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/import.log" | head -5 | while IFS= read -r l; do say "    $l"; done
      verdict godot_macos FAIL
      return 1
    fi
    say "  import: clean"
    cache_store_import   # store for future runs (non-fatal on failure)
  fi

  # Q-17: stamp commit + build id into build/build_info.json (surfaced in-game by debug overlay)
  bash "$PROJ/scripts_tool/stamp_build.sh" "$PROJ" >"$LOGS/stamp.log" 2>&1 || true

  # 2) smoke gate — content, not exit codes: require the PASS marker line
  phase_start
  if ! run_logged 240 "$LOGS/smoke.log" "$GODOT" --headless --path "$PROJ" "res://tests/smoke_test.tscn"; then
    gate_fail godot_web "smoke scene exited nonzero / timed out ($LOGS/smoke.log)"
    verdict godot_macos FAIL
    return 1
  fi
  phase_end "smoke"
  if ! grep -q '^SMOKE_RESULT=PASS' "$LOGS/smoke.log"; then
    gate_fail godot_web "smoke gate: no SMOKE_RESULT=PASS marker"
    grep '^SMOKE_RESULT' "$LOGS/smoke.log" | head -3 | while IFS= read -r l; do say "    $l"; done
    verdict godot_macos FAIL
    return 1
  fi
  say "  smoke: $(grep '^SMOKE_RESULT' "$LOGS/smoke.log" | tail -1)"
  return 0
}

# ---------------------------------------------------------------- godot web leg
leg_godot_web() {
  say "== [godot] leg: Web export (release) =="
  mkdir -p "$OUT/web"
  if ! run_logged 300 "$LOGS/export_web.log" "$GODOT" --headless --path "$PROJ" --export-release "Web" "$OUT/web/index.html"; then
    gate_fail godot_web "export-release Web failed ($LOGS/export_web.log)"; return
  fi
  if [ ! -f "$OUT/web/index.html" ] || [ ! -f "$OUT/web/index.pck" ]; then
    gate_fail godot_web "web artifacts missing (index.html / index.pck)"; return
  fi
  if has_err "$LOGS/export_web.log"; then
    gate_fail godot_web "export log has errors:"
    grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/export_web.log" | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  inject_tips_widget
  kb="$(du -sk "$OUT/web" | cut -f1)"
  mb=$(( kb / 1024 ))
  if [ "$kb" -gt $(( WEB_BUDGET_MB * 1024 )) ]; then
    gate_fail godot_web "web payload ${mb} MB exceeds ${WEB_BUDGET_MB} MB (Q-16)"; return
  fi
  say "  web: payload ${mb} MB <= ${WEB_BUDGET_MB} MB (Q-16); files: $(ls "$OUT/web" | tr '\n' ' ')"
  verdict godot_web PASS
}

# ---------------------------------------------------------------- godot macos leg
leg_godot_macos() {
  say "== [godot] leg: macOS export (release) =="
  mkdir -p "$OUT/macos"
  if ! run_logged 300 "$LOGS/export_macos.log" "$GODOT" --headless --path "$PROJ" --export-release "macOS" "$OUT/macos/LUMENFALL.zip"; then
    gate_fail godot_macos "export-release macOS failed ($LOGS/export_macos.log)"; return
  fi
  if [ ! -f "$OUT/macos/LUMENFALL.zip" ]; then
    gate_fail godot_macos "macOS artifact missing (LUMENFALL.zip)"; return
  fi
  # NOTE: no `grep -q` here — under `set -o pipefail` grep -q early-exits after the
  # first match, unzip dies with SIGPIPE (141), and the pipeline reports failure on a
  # perfectly valid zip. `grep -c >/dev/null` consumes all input, no SIGPIPE.
  if [ "$(unzip -l "$OUT/macos/LUMENFALL.zip" 2>/dev/null | grep -c '\.app/Contents/MacOS/')" -eq 0 ]; then
    gate_fail godot_macos "zip does not contain LUMENFALL.app bundle"; return
  fi
  if has_err "$LOGS/export_macos.log"; then
    gate_fail godot_macos "export log has errors:"
    grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/export_macos.log" | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  say "  macos: $(du -h "$OUT/macos/LUMENFALL.zip" | cut -f1) zip contains LUMENFALL.app"
  verdict godot_macos PASS
}

# ------------------------------------------------------- other-engine legs (§2.3)
# Unity leg discovery (ordered): explicit UNITY_BIN > Hub layout > /Applications.
# Matches build_matrix.sh binary-discovery convention for godot (no hard-coded
# single path). License: manual .alf/.ulf flow on this host — see scripts_tool/
# unity_license.sh for activation + UNITY_LICENSE env fallback in CI.
leg_unity() {
  say "== [unity] leg =="
  local unity=""
  local cand
  for cand in \
    "${UNITY_BIN:-}" \
    "$HOME"/Applications/Unity/Hub/Editor/2022.3*/Unity.app/Contents/MacOS/Unity \
    /Applications/Unity/Hub/Editor/2022.3*/Unity.app/Contents/MacOS/Unity \
    "/Applications/Unity/Unity.app/Contents/MacOS/Unity"; do
    [ -n "$cand" ] || continue
    if [ -x "$cand" ]; then unity="$cand"; break; fi
  done
  if [ -z "$unity" ]; then
    say "  SKIP: unity 2022.3 toolchain absent (unblock: install Unity 2022.3 LTS / set UNITY_BIN)"
    verdict unity SKIP
    return 0
  fi

  # Missing toolchain = SKIP (BUILD_MATRIX.md), and on this host a Personal
  # license IS part of the toolchain: without .ulf activation batchmode cannot
  # run at all. No UNITY_LICENSE env and no installed license => SKIP with a
  # named unblock, never FAIL (SKIP != FAIL contract).
  if [ -z "${UNITY_LICENSE:-}" ] \
     && [ ! -f "/Library/Application Support/Unity/Unity_lic.ulf" ] \
     && [ ! -f "$HOME/Library/Application Support/Unity/Unity_lic.ulf" ]; then
    say "  SKIP: unity license absent (unblock: scripts_tool/unity_license.sh — .alf/.ulf manual activation, or set UNITY_LICENSE)"
    verdict unity SKIP
    return 0
  fi

  local uout="$OUT/unity"
  local ulog="$LOGS/unity_build.log"
  local utests="$LOGS/unity_tests.xml"
  local utestlog="$LOGS/unity_tests.log"
  mkdir -p "$uout"

  say "  engine: $("$unity" -version 2>/dev/null | tail -1)"

  # License: UNITY_LICENSE env (personal .ulf contents) wins; otherwise assume
  # machine-activated license already present (scripts_tool/unity_license.sh).
  local lic_args=()
  if [ -n "${UNITY_LICENSE:-}" ]; then
    local ulf="$LOGS/Unity_lic.ulf"
    printf '%s' "$UNITY_LICENSE" > "$ulf"
    lic_args=(-manualLicenseFile "$ulf")
  fi

  # 1) EditMode tests via Unity Test Runner CLI (gate: rc 0, i.e. all green)
  if [ ! -f "$PROJ/unity/Assets/Tests/EditMode/Lumenfall.Tests.asmdef" ]; then
    gate_fail unity "EditMode test asmdef missing (unity/Assets/Tests/EditMode/)"
    return
  fi
  say "  running EditMode tests..."
  if ! run_logged 600 "$utestlog" "$unity" -batchmode -nographics \
      "${lic_args[@]}" \
      -projectPath "$PROJ/unity" \
      -runTests -testPlatform EditMode \
      -testResults "$utests"; then
    gate_fail unity "EditMode tests failed or timed out ($utestlog)"
    grep -E '<test-case|result="Failed"' "$utests" 2>/dev/null | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  if ! grep -q 'result="Passed"' "$utests" 2>/dev/null; then
    gate_fail unity "EditMode tests: results XML has no Passed outcome ($utests)"
    return
  fi
  say "  EditMode tests: $(grep -o 'result="Passed"' "$utests" | wc -l | tr -d ' ') passed"

  # 2) Batchmode build (gate: exit 0 + zero compiler errors + artifact exists)
  say "  building macOS player (batchmode, nographics)..."
  UNITY_BUILD_OUT="$uout/LUMENFALL.app" \
  run_logged 900 "$ulog" "$unity" -batchmode -nographics \
      "${lic_args[@]}" \
      -projectPath "$PROJ/unity" \
      -executeMethod Lumenfall.EditorTools.AABuild.Build
  local brc=$?
  if [ "$brc" -ne 0 ]; then
    gate_fail unity "batch build exited $brc ($ulog)"
    grep -E 'error CS|Error building|Aborting batchmode|exit( [0-9]+)?' "$ulog" | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  if grep -q 'scriptCompilationFailed\|error CS[0-9]' "$ulog"; then
    gate_fail unity "compiler errors in build log:"
    grep -E 'error CS[0-9]+|scriptCompilationFailed' "$ulog" | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  if [ ! -d "$uout/LUMENFALL.app" ]; then
    gate_fail unity "build artifact missing (LUMENFALL.app)"
    return
  fi
  say "  unity: artifact $(du -sh "$uout/LUMENFALL.app" | cut -f1) — $(ls "$uout/LUMENFALL.app/Contents/MacOS/" 2>/dev/null | tr '\n' ' ')"
  verdict unity PASS
}


leg_unreal() {
  # AGE-141: scaffold-aware Unreal leg. Env contract extension (BUILD_MATRIX.md):
  #   RUNUAT_BIN  explicit RunUAT.sh override (same pattern as GODOT_BIN)
  # Discovered paths checked in order: RUNUAT_BIN > /Users/Shared/Epic Games/UE_5.4 (Launcher default).
  # Toolchain absent  => SKIP with named owner (never blocks Godot release; SKIP != FAIL).
  # Toolchain present => real gate: BuildCookRun exit 0 + staged .pak + ^ERROR-free log => PASS,
  #                      anything else => FAIL. A half-present toolchain fails loudly; it never
  #                      silently SKIPs, and a green run that builds nothing is structurally
  #                      impossible (docs/AGE-141_unreal_ci_decision.md §7).
  say "== [unreal] leg =="
  local uat
  uat="${RUNUAT_BIN:-/Users/Shared/Epic Games/UE_5.4/Engine/Build/BatchFiles/RunUAT.sh}"
  if [ ! -f "$uat" ]; then
    say "  SKIP: UE 5.4 toolchain absent (unblock: Studio Operations — Epic account provisioning; see docs/AGE-141_unreal_ci_decision.md)"
    verdict unreal SKIP
    return 0
  fi
  mkdir -p "$OUT/unreal"
  # Mapless scaffold: package the default startup map ( proves cook+stage+archive end-to-end ).
  if ! run_logged 1500 "$LOGS/unreal_buildcookrun.log" \
      "$uat" BuildCookRun -project="$PROJ/unreal/Lumenfall.uproject" -noP4 -noturnkey \
        -platform=Win64 -clientconfig=Development -build -cook -stage -package \
        -archive -archivedirectory="$OUT/unreal" -utf8output; then
    gate_fail unreal "RunUAT BuildCookRun failed/timed out ($LOGS/unreal_buildcookrun.log)"; return
  fi
  if [ -z "$(find "$OUT/unreal" -name '*.pak' -print -quit 2>/dev/null)" ]; then
    gate_fail unreal "BuildCookRun exited 0 but no staged .pak artifact ($OUT/unreal)"; return
  fi
  if has_err "$LOGS/unreal_buildcookrun.log"; then
    gate_fail unreal "BuildCookRun log has errors:"
    grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/unreal_buildcookrun.log" | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  say "  unreal: packaged $(find "$OUT/unreal" -name '*.pak' | wc -l | tr -d ' ') .pak, $(du -sh "$OUT/unreal" | cut -f1)"
  verdict unreal PASS
}

leg_roblox() {
  say "== [roblox] leg =="
  # Scaffold + toolchain live in scripts_tool/roblox_ci (AGE-142). Lockstep
  # installer fetches pinned rojo/lune/luau-lsp if absent (SKIP vs FAIL
  # discipline: missing toolchain on a runner = SKIP, red step = FAIL).
  if [ ! -f "$PROJ/scripts_tool/roblox_ci/roblox_leg.sh" ]; then
    say "  SKIP: roblox leg driver missing (unblock: Roblox Systems Scripter)"
    verdict roblox SKIP
    return
  fi
  if [ ! -x "$PROJ/scripts_tool/roblox_ci/tools/rojo" ]; then
    # Attempt lockstep install once; if the network is unavailable we SKIP.
    if ! bash "$PROJ/scripts_tool/roblox_ci/toolchain_lockstep.sh" >"$LOGS/roblox_lockstep.log" 2>&1; then
      say "  SKIP: toolchain absent and lockstep install failed ($LOGS/roblox_lockstep.log)"
      verdict roblox SKIP
      return
    fi
  fi
  phase_start
  if ROBLOX_OUT_DIR="$OUT/roblox" \
     ROBLOX_LOGS_DIR="$LOGS" \
     ROBLOX_REF="$REF_NAME" \
     ROBLOX_BUILDNUM="$BUILDNUM" \
     bash "$PROJ/scripts_tool/roblox_ci/roblox_leg.sh" >>"$LOGS/roblox_leg.log" 2>&1; then
    phase_end "roblox_leg"
    local place
    place="$(find "$OUT/roblox" -name '*.rbxlx' -print -quit 2>/dev/null)"
    say "  roblox: place $(basename "${place:-<none>}") built; type-check clean; TestEZ PASS"
    verdict roblox PASS
  else
    phase_end "roblox_leg"
    gate_fail roblox "roblox leg failed (rojo build / luau analyze / TestEZ — $LOGS/roblox_leg.log):"
    grep -E 'FAIL|TypeError|TESTEZ_RESULT|error' "$LOGS/roblox_leg.log" | head -6 | while IFS= read -r l; do say "    $l"; done
  fi
}

# ---------------------------------------------------------------- summary
summary() {
  timings_to_json   # fold per-phase timings + cache stats into build_metrics.json
  say ""
  say "== BUILD MATRIX VERDICTS (stamp: lumenfall_${REF_NAME}_${BUILDNUM}) =="
  local v
  for v in "${VERDICTS[@]}"; do say "  $v"; done
  if [ -f "$METRICS_JSON" ]; then
    say "metrics: $(python3 -c "
import json
m = json.load(open('$METRICS_JSON'))
t = m.get('timingsMs', {})
c = m.get('cache', {})
total_ms = sum(t.values())
print(f\"phases: {', '.join(f'{k}={v/1000:.1f}s' for k, v in sorted(t.items()))} | total={total_ms/1000:.1f}s | cache: {c.get('hits',0)}H/{c.get('misses',0)}M rate={c.get('hitRatePct')}% gate={c.get('gate')}\")" 2>/dev/null || sed -n '1,20p' "$METRICS_JSON")"
  fi
  if [ "$overall" -eq 0 ]; then
    say "BUILD_MATRIX_RESULT=OK"
    say "artifacts: $OUT"
  else
    say "BUILD_MATRIX_RESULT=FAIL (logs: $LOGS)"
  fi
  return "$overall"
}

# ---------------------------------------------------------------- asset linter gate (§2.2)
# Validates committed glTF-export snapshots via the division asset linter v1
# (docs/art_pipeline/AA-ARTPIPE-1, §8): python3 scripts_tool/aa_asset_linter.py
# <snapshot.json ...>. Exit 0 clean/warnings-only, 1 errors, 2 usage.
# No snapshots committed yet => SKIP (greybox slice; assets flow at D4 lock).
asset_lint_gate() {
  say "== [assets] preflight: aa_asset_linter v1 (§2.2 gate) =="
  local snapdir="$PROJ/docs/art_pipeline/snapshots"
  local py
  py="$(command -v python3 || true)"
  if [ -z "$py" ]; then
    say "  SKIP: python3 not on PATH"
    verdict asset_lint SKIP
    return 0
  fi
  local snaps=()
  local f
  if [ -d "$snapdir" ]; then
    for f in "$snapdir"/*.json; do [ -f "$f" ] && snaps+=("$f"); done
  fi
  if [ "${#snaps[@]}" -eq 0 ]; then
    say "  SKIP: no committed snapshots in docs/art_pipeline/snapshots/ yet"
    verdict asset_lint SKIP
    return 0
  fi
  say "  linting ${#snaps[@]} snapshot(s): $(printf '%s ' "${snaps[@]##*/}")"
  if "$py" "$PROJ/scripts_tool/aa_asset_linter.py" "${snaps[@]}" >"$LOGS/lint.log" 2>&1; then
    say "  asset linter: clean (warnings only, if any) — $(grep -c '\[L-' "$LOGS/lint.log" 2>/dev/null || echo 0) finding line(s)"
    verdict asset_lint PASS
    return 0
  else
    local rc=$?
    if [ "$rc" -eq 2 ]; then
      gate_fail asset_lint "linter usage error (rc=2) — check snapshot args ($LOGS/lint.log)"
    else
      gate_fail asset_lint "asset linter errors (rc=$rc):"
      grep '\[L-' "$LOGS/lint.log" | head -8 | while IFS= read -r l; do say "    $l"; done
    fi
    return 1
  fi
}

# ---------------------------------------------------------------- token gate (AGE-143, AGE-59 handoff)
# Design System token consumption: validates tokens/v1/tokens.json (reference
# resolution + light/dark parity + WCAG contrast) and enforces the hardcoded
# Color() drift guard against .token_drift_baseline. Exports CSS vars + Godot
# tokens script into build/tokens/ (shipped inside web/macos bundles). Exit 1 = FAIL.
token_gate() {
  say "== [tokens] gate: design-token pipeline (AGE-59 handoff) =="
  local py
  py="$(command -v python3 || true)"
  if [ -z "$py" ]; then
    say "  SKIP: python3 not on PATH"
    verdict tokens SKIP
    return 0
  fi
  if [ -n "${SKIP_TOKEN_GATE:-}" ]; then
    say "  SKIP: SKIP_TOKEN_GATE set"
    verdict tokens SKIP
    return 0
  fi
  phase_start
  if "$py" "$PROJ/scripts_tool/tokens_pipeline.py" --project "$PROJ" >"$LOGS/tokens.log" 2>&1; then
    phase_end "token_gate"
    grep -E '^  (note|contrast|exports):' "$LOGS/tokens.log" | head -4 | while IFS= read -r l; do say "$l"; done
    say "  tokens: PASS (machine-checked handoff: CSS vars + Godot tokens exported)"
    verdict tokens PASS
    return 0
  fi
  phase_end "token_gate"
  gate_fail tokens "design-token gate failed (see $LOGS/tokens.log):"
  grep -E 'ERROR|^TOKENS_RESULT' "$LOGS/tokens.log" | head -6 | while IFS= read -r l; do say "    $l"; done
  return 1
}

# ---------------------------------------------------------------- main
mkdir -p "$OUT" "$LOGS"
mkdir -p "$BUILD_ROOT"
touch "$BUILD_ROOT/.gdignore"   # keep build output out of Godot's next export scan (pck self-inflation)

say "LUMENFALL build & release matrix — Studio Pipeline Standard v1.0 §2.2/§2.3"
say "project: $PROJ"

# AGE-140: LEGS= comma filter — split into a helper so per-engine invocation
# (LEGS=unity from the CI unity job, LEGS=godot from the godot job) is a
# one-word change, and `unset` = all legs exactly as before.
leg_selected() { # leg_selected <name> -> 0 if this leg should run
  [ -z "${LEGS:-}" ] && return 0
  case ",$LEGS," in *",$1,"*) return 0;; esac
  return 1
}

if leg_selected token_gate; then token_gate || true; fi
if leg_selected godot; then
  if asset_lint_gate; then
    if godot_preflight; then
      phase_start; leg_godot_web;  phase_end "export_web"
      phase_start; leg_godot_macos; phase_end "export_macos"
    fi
  fi
fi
if leg_selected unity;  then leg_unity;  fi
if leg_selected unreal; then leg_unreal; fi
if leg_selected roblox; then leg_roblox; fi
summary
