#!/usr/bin/env bash
# actions_runner_maint.sh — self-hosted runner maintenance (AGE-143 deliverable 3).
#
# 1. Rotates ~/actions-runner/_diag: deletes Runner_*/Worker_* logs older than
#    DIAG_KEEP_DAYS (default 7). The runner accumulates these unbounded.
# 2. Tightens sensitive file perms each pass (registration credentials must
#    never be group/world readable):
#      .credentials            600
#      .credentials_rsaparams  600
#      .runner                 600
# 3. Emits a one-line health snapshot (launchd label, service state, _diag size).
#
# launchd: com.prajwal.actions-runner-maint (daily 03:15)
set -uo pipefail

RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
DIAG_KEEP_DAYS="${DIAG_KEEP_DAYS:-7}"
LOG_TAG="[runner-maint]"

say() { printf '%s %s\n' "$LOG_TAG" "$*"; }

# --- 1) _diag rotation -----------------------------------------------------
diag="$RUNNER_DIR/_diag"
deleted=0
if [ -d "$diag" ]; then
  before="$(du -sk "$diag" 2>/dev/null | cut -f1)"
  while IFS= read -r f; do
    rm -f "$f" && deleted=$(( deleted + 1 ))
  done < <(find "$diag" -maxdepth 1 -type f \( -name 'Runner_*.log' -o -name 'Worker_*.log' \) -mtime +${DIAG_KEEP_DAYS} 2>/dev/null)
  after="$(du -sk "$diag" 2>/dev/null | cut -f1)"
  say "diag rotate: deleted=$deleted size ${before:-?}K -> ${after:-?}K (keep=${DIAG_KEEP_DAYS}d)"
else
  say "diag rotate: no _diag dir at $diag"
fi

# --- 2) credential perms ---------------------------------------------------
for f in .credentials .credentials_rsaparams .runner; do
  p="$RUNNER_DIR/$f"
  [ -f "$p" ] || continue
  cur="$(stat -f '%Lp' "$p" 2>/dev/null)"
  if [ "$cur" != "600" ]; then
    chmod 600 "$p" && say "perms: $f ${cur:-?} -> 600"
  fi
done

# --- 3) health snapshot ----------------------------------------------------
label=""
for p in "$HOME/Library/LaunchAgents"/actions.runner.*.plist; do
  [ -f "$p" ] && label="$(basename "$p" .plist)"
done
svc_state="unknown"
if [ -n "$label" ]; then
  svc_state="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk '/^[[:space:]]+state = /{print $3; exit}')"
fi
running="$(pgrep -f 'Runner.Listener run' >/dev/null 2>&1 && echo yes || echo no)"
diag_size="$(du -sh "$diag" 2>/dev/null | cut -f1)"
say "health: label=${label:-<none>} launchd_state=${svc_state:-unknown} listener_running=$running diag=${diag_size:-?}"
exit 0
