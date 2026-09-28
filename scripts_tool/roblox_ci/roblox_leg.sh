#!/usr/bin/env bash
# Roblox CI leg driver (AGE-142). Called by build_matrix.sh leg_roblox() and
# by the GitHub Actions roblox job. Runs from the repo root.
#
# Steps:
#   1. lockstep toolchain (pinned rojo/lune/luau-lsp; skip-download in CI cache hit)
#   2. rojo build default.project.json -> place file (.rbxlx, versioned name)
#   3. luau-lsp analyze (strict, roblox globalTypes + rojo sourcemap) — exit 0 gate
#   4. lune TestEZ suite — TESTEZ_RESULT=PASS marker gate
#
# Verdict contract (BUILD_MATRIX.md): exit 0 = leg PASS; nonzero = FAIL.
# Place file lands in $OUT_DIR (default builds/<stamp>/roblox).
#
# Env:
#   ROBLOX_OUT_DIR   output dir for place file (default builds/roblox_local)
#   ROBLOX_REF       CI_COMMIT_REF_NAME equivalent (default local)
#   ROBLOX_BUILDNUM  CI_PIPELINE_IID equivalent (default UTC stamp)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
cd "$REPO"

REF_NAME="${ROBLOX_REF:-${CI_COMMIT_REF_NAME:-local}}"
BUILDNUM="${ROBLOX_BUILDNUM:-${CI_PIPELINE_IID:-$(date -u +%Y%m%d.%H%M%S)}}"
OUT_DIR="${ROBLOX_OUT_DIR:-$REPO/builds/lumenfall_${REF_NAME}_${BUILDNUM}/roblox}"
LOGS_DIR="${ROBLOX_LOGS_DIR:-$(dirname "$OUT_DIR")/logs}"
mkdir -p "$OUT_DIR" "$LOGS_DIR"

TOOLS="$DIR/tools"

echo "== [roblox] step 1/4: toolchain lockstep ="
ROBLOX_CI_SKIP_DOWNLOAD=1 "$DIR/toolchain_lockstep.sh"
ROJO="$TOOLS/rojo"
LUNE="$TOOLS/lune"
LUALSP="$TOOLS/luau-lsp"

echo "== [roblox] step 2/4: rojo build ="
PLACE_FILE="$OUT_DIR/lumenfall_${REF_NAME}_${BUILDNUM}.rbxlx"
"$ROJO" build "$REPO/default.project.json" -o "$PLACE_FILE" 2>&1 | tee "$LOGS_DIR/rojo_build.log"
[ -f "$PLACE_FILE" ] || { echo "FAIL: place file missing: $PLACE_FILE"; exit 1; }
echo "  place: $PLACE_FILE ($(du -h "$PLACE_FILE" | cut -f1))"

echo "== [roblox] step 3/4: luau-lsp analyze (strict) ="
# Roblox global type definitions are pinned next to the toolchain (see
# docs/ROBLOX_CI.md); sourcemap lets analyze resolve instance requires.
DEFS="$DIR/roblox_globalTypes.d.luau"
TESTEZ_DEFS="$DIR/testez_types.d.luau"
"$ROJO" sourcemap "$REPO/default.project.json" -o "$OUT_DIR/sourcemap.json"
# shellcheck disable=SC2086
"$LUALSP" analyze \
  --platform=roblox \
  --definitions="$DEFS" \
  --definitions="$TESTEZ_DEFS" \
  --sourcemap="$OUT_DIR/sourcemap.json" \
  roblox/src/shared/Tokens.luau \
  roblox/src/server/init.server.luau \
  roblox/src/client/init.client.luau \
  roblox/tests/tokens_spec.luau \
  >"$LOGS_DIR/luau_analyze.log" 2>&1
echo "  analyze: clean (0 type errors, 0 lint errors)"

echo "== [roblox] step 4/4: TestEZ suite (lune) ="
"$LUNE" run "$DIR/run_tests.luau" 2>&1 | tee "$LOGS_DIR/testez.log"
if ! grep -q '^TESTEZ_RESULT=PASS' "$LOGS_DIR/testez.log"; then
  echo "FAIL: TestEZ suite did not report PASS"
  exit 1
fi

echo "roblox_leg=PASS"
