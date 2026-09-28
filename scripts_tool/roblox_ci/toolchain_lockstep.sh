#!/usr/bin/env bash
# Roblox CI toolchain lockstep installer (AGE-142).
#
# Downloads PINNED versions of rojo + lune + luau-lsp into
# <repo>/scripts_tool/roblox_ci/tools/ (x86_64 macOS; matches the
# self-hosted intel-mac runner). CI runs this before the roblox leg, so
# the leg is SKIP (toolchain absent) rather than FAIL on a fresh runner.
#
# Lockstep discipline: bumping a version means editing the PINNED_* vars
# below AND docs/ROBLOX_CI.md (versions table) in the SAME commit.
#
# Env:
#   ROBLOX_CI_SKIP_DOWNLOAD=1  use existing tools/, never hit the network
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$DIR/tools"
mkdir -p "$TOOLS"

# ---- pinned versions (see docs/ROBLOX_CI.md) -------------------------------
PINNED_ROJO_VER="7.7.0"        # github.com/rojo-rbx/rojo
PINNED_LUNE_VER="0.10.5"       # github.com/lune-org/lune
PINNED_LUAULSP_VER="1.70.0"    # github.com/JohnnyMorganz/luau-lsp
# ----------------------------------------------------------------------------

MACARCH="$(uname -m)"
case "$MACARCH" in
  x86_64) ROJO_ARCH="x86_64"; LUNE_ARCH="x86_64" ;;
  arm64)  ROJO_ARCH="aarch64"; LUNE_ARCH="aarch64" ;;
  *) echo "lockstep: unsupported arch $MACARCH"; exit 1 ;;
esac

have() { [ -x "$TOOLS/$1" ]; }

if [ -n "${ROBLOX_CI_SKIP_DOWNLOAD:-}" ]; then
  for b in rojo lune luau-lsp; do
    have "$b" || { echo "lockstep: ROBLOX_CI_SKIP_DOWNLOAD set but $b missing"; exit 1; }
  done
  echo "lockstep: using existing pinned toolchain (skip download)"
  exit 0
fi

fetch() { # fetch <url> <out.zip>
  local url="$1" out="$2"
  echo "lockstep: downloading $(basename "$url")"
  curl -sSL --max-time 300 -o "$out" "$url"
}

if ! have rojo; then
  fetch "https://github.com/rojo-rbx/rojo/releases/download/v${PINNED_ROJO_VER}/rojo-${PINNED_ROJO_VER}-macos-${ROJO_ARCH}.zip" "$DIR/rojo.zip"
  unzip -oq "$DIR/rojo.zip" -d "$TOOLS"
  rm -f "$DIR/rojo.zip"
fi

if ! have lune; then
  fetch "https://github.com/lune-org/lune/releases/download/v${PINNED_LUNE_VER}/lune-${PINNED_LUNE_VER}-macos-${LUNE_ARCH}.zip" "$DIR/lune.zip"
  unzip -oq "$DIR/lune.zip" -d "$TOOLS"
  rm -f "$DIR/lune.zip"
fi

if ! have luau-lsp; then
  # luau-lsp ships a universal macos zip (x86_64 + arm64 in one)
  fetch "https://github.com/JohnnyMorganz/luau-lsp/releases/download/${PINNED_LUAULSP_VER}/luau-lsp-macos.zip" "$DIR/luaulsp.zip"
  unzip -oq "$DIR/luaulsp.zip" -d "$TOOLS"
  rm -f "$DIR/luaulsp.zip"
fi

# Defuse Gatekeeper quarantine on downloaded binaries (self-hosted runner).
xattr -dr com.apple.quarantine "$TOOLS" 2>/dev/null || true

# Version assertions — lockstep fails loudly if a pinned URL 404s into an
# HTML error page or a re-tagged release drifts from the recorded version.
assert_ver() { # assert_ver <bin> <expected-substring>
  local got
  got="$("$TOOLS/$1" --version 2>&1 | head -1)"
  case "$got" in
    *"$2"*) echo "lockstep: $1 $2 OK" ;;
    *) echo "lockstep: $1 version mismatch: got '$got', want *$2*"; exit 1 ;;
  esac
}
assert_ver rojo "$PINNED_ROJO_VER"
assert_ver lune "$PINNED_LUNE_VER"
assert_ver luau-lsp "$PINNED_LUAULSP_VER"

echo "lockstep: toolchain ready at $TOOLS"
