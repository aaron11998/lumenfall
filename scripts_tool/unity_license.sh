#!/usr/bin/env bash
# Unity license helper for the self-hosted macOS runner (AGE-140).
#
# Personal / manual activation flow (no Hub GUI on this host):
#   1) scripts_tool/unity_license.sh request
#        -> writes Unity_v<version>.alf into the current directory
#   2) HUMAN STEP: upload the .alf at https://license.unity3d.com/manual,
#      choose Personal, download the returned .ulf license file
#   3) scripts_tool/unity_license.sh activate /path/to/Unity_v2022.x.ulf
#        -> installs the license for this machine
#   4) scripts_tool/unity_license.sh status
#
# CI fallback: export UNITY_LICENSE="<contents of the .ulf>" — build_matrix.sh
# wires it into -manualLicenseFile automatically.
set -uo pipefail

cmd="${1:-status}"
case "$cmd" in
  request|activate|status) ;;
  *) echo "usage: unity_license.sh request|activate <file.ulf>|status" >&2; exit 2;;
esac

# Same discovery order as build_matrix.sh leg_unity()
UNITY_BIN="${UNITY_BIN:-}"
if [ -z "$UNITY_BIN" ]; then
  for cand in \
    "$HOME"/Applications/Unity/Hub/Editor/2022.3*/Unity.app/Contents/MacOS/Unity \
    /Applications/Unity/Hub/Editor/2022.3*/Unity.app/Contents/MacOS/Unity \
    "/Applications/Unity/Unity.app/Contents/MacOS/Unity"; do
    if [ -x "$cand" ]; then UNITY_BIN="$cand"; break; fi
  done
fi
if [ ! -x "$UNITY_BIN" ]; then
  echo "FAIL: unity editor not found (install 2022.3 LTS or set UNITY_BIN)" >&2
  exit 1
fi
echo "editor: $UNITY_BIN ($("$UNITY_BIN" -version 2>/dev/null | tail -1))"

lic_present() {
  [ -f "/Library/Application Support/Unity/Unity_lic.ulf" ] && return 0
  [ -f "$HOME/Library/Application Support/Unity/Unity_lic.ulf" ] && return 0
  return 1
}

case "$cmd" in
  status)
    if lic_present; then
      echo "LICENSE=present"
      ls -la "/Library/Application Support/Unity/Unity_lic.ulf" \
             "$HOME/Library/Application Support/Unity/Unity_lic.ulf" 2>/dev/null | grep -v '^total'
      exit 0
    fi
    echo "LICENSE=absent"
    echo "unblock: run 'unity_license.sh request', upload the .alf at"
    echo "https://license.unity3d.com/manual (Personal), then"
    echo "'unity_license.sh activate <downloaded .ulf>'"
    exit 1
    ;;
  request)
    if lic_present; then echo "LICENSE already present; nothing to do"; exit 0; fi
    echo "generating manual activation file in CWD: $(pwd)"
    "$UNITY_BIN" -batchmode -nographics -quit -createManualActivationFile -logFile -
    rc=$?
    alf="$(ls -t "${TMPDIR:-/tmp}"/Unity_v*.alf 2>/dev/null | head -1)"
    # Unity writes the .alf to its own working dir; also check CWD.
    [ -z "$alf" ] && alf="$(ls -t Unity_v*.alf 2>/dev/null | head -1)"
    if [ "$rc" -ne 0 ] || [ -z "$alf" ]; then
      echo "FAIL: activation file generation failed (rc=$rc)" >&2
      exit 1
    fi
    cp -f "$alf" ./ 2>/dev/null || true
    alf_cwd="$(basename "$alf")"
    [ -f "$alf_cwd" ] && alf="$alf_cwd"
    echo "ACTIVATION_FILE=$alf"
    echo "next: upload it at https://license.unity3d.com/manual, download the .ulf, then:"
    echo "  $0 activate \"$alf\" -> replace with the downloaded .ulf path"
    ;;
  activate)
    ulf="${2:-}"
    if [ -z "$ulf" ] || [ ! -f "$ulf" ]; then
      echo "FAIL: provide the .ulf downloaded from license.unity3d.com/manual" >&2
      exit 2
    fi
    "$UNITY_BIN" -batchmode -nographics -quit -manualLicenseFile "$ulf" -logFile -
    rc=$?
    if [ "$rc" -ne 0 ] || ! lic_present; then
      echo "FAIL: activation failed (rc=$rc); see log output above" >&2
      exit 1
    fi
    echo "LICENSE activated OK"
    ;;
esac
