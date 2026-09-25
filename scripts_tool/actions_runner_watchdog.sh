#!/usr/bin/env bash
# actions_runner_watchdog.sh — CI runner-queue watchdog (AGE-161).
#
# launchd: com.prajwal.runner-watchdog (every 600s, RunAtLoad).
#
# Detects (2026-09-25 incident class: listener online but polling a dead
# altaranexus-ship-it pool while aaron11998/lumenfall had zero registered
# runners — build-matrix jobs sat Queued ~6h unnoticed):
#   A. zero-runners : repos/aaron11998/lumenfall/actions/runners total_count == 0
#   B. reg-state    : ~/actions-runner/.runner gitHubUrl != expected repo
#                     (wrong-pool registration; restart will NOT heal this)
#   C. queue-jam    : any queued workflow run older than QUEUE_JAM_SECS (900s)
#   D. listener-down: launchd label loaded but no Runner.Listener process
#
# Alerts: line appended to ~/.cache/lumenfall-rollup.log + macOS
# notification (same osascript pattern as the deadline alerts). Same
# condition re-alerts at most once per ALERT_REFRACT (3600s).
#
# Safe self-heal (condition D only): bootout+bootstrap restart exactly as
# RUNNER_PLAYBOOK.md "Service control" — max MAX_RESTARTS per 30 min.
# NEVER auto-runs config.sh: re-registration needs a fresh token and is
# manual-only (playbook "Registration" section).
#
# Constraints honored: read-only gh calls (GET only); never touches
# .credentials / .credentials_rsaparams; own log self-caps at ~256K.
set -uo pipefail

# launchd runs with a minimal PATH; gh lives in /usr/local/bin.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

REPO="${REPO:-aaron11998/lumenfall}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
QUEUE_JAM_SECS="${QUEUE_JAM_SECS:-900}"
ALERT_REFRACT="${ALERT_REFRACT:-3600}"
ROLLUP_LOG="${ROLLUP_LOG:-$HOME/.cache/lumenfall-rollup.log}"
WATCH_LOG="${WATCH_LOG:-$HOME/.cache/runner-watchdog.log}"
STATE_FILE="${STATE_FILE:-$HOME/.cache/runner-watchdog.state}"
RESTART_ENABLED="${RESTART_ENABLED:-1}"
MAX_RESTARTS="${MAX_RESTARTS:-3}"
GH_FAIL_ALERT_AFTER="${GH_FAIL_ALERT_AFTER:-3}"

# --- test hooks (AGE-161 verification only; empty = live checks) -----------
FORCE_RUNNER_COUNT="${FORCE_RUNNER_COUNT:-}"
FORCE_QUEUED_JSON="${FORCE_QUEUED_JSON:-}"

LOG_TAG="[runner-watchdog]"
PY=/usr/bin/python3

exec 2>>"$WATCH_LOG"

say()        { printf '%s %s\n' "$LOG_TAG" "$*"; }
log_rollup() { printf '%s %s\n' "$LOG_TAG" "$*" >>"$ROLLUP_LOG" 2>/dev/null; }
notify() { # $1 subtitle, $2 message
  osascript -e "display notification \"$2\" with title \"LUMENFALL runner watchdog\" subtitle \"$1\" sound name \"Basso\"" >/dev/null 2>&1 || true
}

cap_log() {
  [ -f "$WATCH_LOG" ] || return 0
  local sz; sz="$(stat -f '%z' "$WATCH_LOG" 2>/dev/null || echo 0)"
  if [ "${sz:-0}" -gt 262144 ]; then
    tail -n 2000 "$WATCH_LOG" >"$WATCH_LOG.tmp" && mv "$WATCH_LOG.tmp" "$WATCH_LOG"
  fi
}

# --- state file: "<key> <epoch>" lines; pruned to last 24h each pass --------
prune_state() {
  [ -f "$STATE_FILE" ] || return 0
  local cutoff=$(( $(date +%s) - 86400 ))
  local tmp="$STATE_FILE.tmp"
  awk -v c="$cutoff" '$2 ~ /^[0-9]+$/ && $2 >= c {print}' "$STATE_FILE" >"$tmp" 2>/dev/null \
    && mv "$tmp" "$STATE_FILE"
}

sig_line()  { awk -v s="$1" '$1 == s {l=$0} END {print l}' "$STATE_FILE" 2>/dev/null; }
sig_seen_age() { awk -v s="$1" '$1 == s {e=$2} END {print e}' "$STATE_FILE" 2>/dev/null; }
set_sig() { # $1 sig, $2 optional extra: replace (not append) so refractory math stays scalar
  if [ -f "$STATE_FILE" ]; then
    awk -v s="$1" '$1 != s' "$STATE_FILE" >"$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE"
  fi
  printf '%s %s %s\n' "$1" "$(date +%s)" "${2:-}" >>"$STATE_FILE"
}
mark_sig() { set_sig "$1"; }

bump_counter() { # $1 sig, $2 window_secs -> prints new consecutive count, stores it
  local ep n now_s c
  now_s="$(date +%s)"
  ep="$(sig_seen_age "$1")"; n="$(sig_line "$1" | awk '{print $3}')"
  c=$(( ${n:-0} + 1 ))
  if [ -z "$ep" ] || [ $(( now_s - ep )) -gt "$2" ]; then c=1; fi
  set_sig "$1" "$c"
  printf '%s' "$c"
}

peek_counter() { # $1 sig, $2 window_secs -> prints count within window (0 if stale/absent)
  local ep n now_s
  now_s="$(date +%s)"
  ep="$(sig_seen_age "$1")"; n="$(sig_line "$1" | awk '{print $3}')"
  if [ -n "$ep" ] && [ $(( now_s - ep )) -le "$2" ]; then printf '%s' "${n:-0}"; else printf '0'; fi
}
clear_sig() { # drop sig so a future recurrence alerts immediately
  [ -f "$STATE_FILE" ] || return 0
  awk -v s="$1" '$1 != s' "$STATE_FILE" >"$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

ALERTS=0
fire_alert() { # $1 sig, $2 subtitle, $3 detail
  local sig="$1" sub="$2" det="$3" last now
  now="$(date +%s)"
  last="$(sig_seen_age "$sig")"
  if [ -n "$last" ] && [ $(( now - last )) -lt "$ALERT_REFRACT" ]; then
    say "ALERT[$sig] suppressed (refractory ${ALERT_REFRACT}s): $det"
    return 0
  fi
  mark_sig "$sig"
  ALERTS=$(( ALERTS + 1 ))
  say "ALERT[$sig]: $det"
  log_rollup "ALERT[$sig]: $det"
  notify "$sub" "$det"
}

# --- A) zero registered runners ---------------------------------------------
runner_count="$( [ -n "$FORCE_RUNNER_COUNT" ] && echo "$FORCE_RUNNER_COUNT" || \
  gh api "repos/$REPO/actions/runners" --jq '.total_count' 2>/dev/null )"

# --- B) registration repo ----------------------------------------------------
expected_url="https://github.com/$REPO"
runner_file="$RUNNER_DIR/.runner"
reg_url=""
if [ -f "$runner_file" ]; then
  reg_url="$(sed -n 's/.*"gitHubUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$runner_file" 2>/dev/null | head -1)"
fi

# --- C) queued runs older than QUEUE_JAM_SECS --------------------------------
queued_json=""
if [ -n "$FORCE_QUEUED_JSON" ]; then
  queued_json="$FORCE_QUEUED_JSON"
else
  queued_json="$(gh api "repos/$REPO/actions/runs?status=queued&per_page=30" 2>/dev/null)" || queued_json=""
fi
jammed=""
if [ -n "$queued_json" ]; then
  jammed="$(printf '%s' "$queued_json" | "$PY" -c '
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
now = datetime.now(timezone.utc).timestamp()
for r in d.get("workflow_runs", []):
    c = (r.get("created_at") or "").replace("Z", "+00:00")
    try:
        age = now - datetime.fromisoformat(c).timestamp()
    except Exception:
        continue
    if age > int(sys.argv[1]):
        print("%s #%s queued %dmin %s" % (r.get("name"), r.get("run_number"), age // 60, r.get("html_url")))
' "$QUEUE_JAM_SECS" 2>/dev/null)"
fi

# --- D) listener state -------------------------------------------------------
label=""
for p in "$HOME/Library/LaunchAgents"/actions.runner.*.plist; do
  [ -f "$p" ] && label="$(basename "$p" .plist)"
done
uid_n="$(id -u)"
svc_state=""
[ -n "$label" ] && svc_state="$(launchctl print "gui/$uid_n/$label" 2>/dev/null | awk '/^[[:space:]]+state = /{print $3; exit}')"
listener_pid="$(pgrep -f 'Runner.Listener run' 2>/dev/null | head -1)"

# --- self-heal (condition D only) --------------------------------------------
may_restart() {
  [ "$RESTART_ENABLED" = "1" ] || return 1
  [ "$(peek_counter restart 1800)" -lt "$MAX_RESTARTS" ]
}

do_restart() { # playbook "Service control" canonical restart
  bump_counter restart 1800 >/dev/null
  say "self-heal: bootout+bootstrap $label (playbook Service control)"
  launchctl bootout "gui/$uid_n/$label" 2>/dev/null
  sleep 2
  launchctl bootstrap "gui/$uid_n" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null
  sleep 8
  listener_pid="$(pgrep -f 'Runner.Listener run' 2>/dev/null | head -1)"
  [ -n "$listener_pid" ]
}

# --- evaluate -----------------------------------------------------------------
prune_state

# A
if [ -z "$runner_count" ]; then
  nf="$(bump_counter ghfail 1200)"
  if [ "${nf:-1}" -ge "$GH_FAIL_ALERT_AFTER" ]; then
    fire_alert gh-fail "runner checks unverifiable" \
      "gh api for $REPO failed $nf consecutive watchdog passes — cannot verify runner count/queue. Check gh auth (keyring) and network."
  fi
  say "warn: runner-count check failed this pass (consecutive=$nf)"
elif [ "$runner_count" -eq 0 ]; then
  fire_alert zero-runners "repo has ZERO registered runners" \
    "gh reports total_count=0 on $REPO — jobs will queue forever. Re-registration is MANUAL-ONLY (RUNNER_PLAYBOOK.md Registration)."
else
  clear_sig ghfail
  clear_sig gh-fail
  say "ok: registered runners total_count=$runner_count"
fi

# B
if [ ! -f "$runner_file" ]; then
  fire_alert reg-state "runner registration state missing" \
    ".runner not found at $runner_file — runner unconfigured; re-registration manual-only (playbook Registration)."
elif [ "$reg_url" = "$expected_url" ]; then
  clear_sig reg-state
  say "ok: registration points at $expected_url"
else
  fire_alert reg-state "WRONG-POOL registration" \
    "$runner_file gitHubUrl='${reg_url:-<none>}' != expected '$expected_url' — listener may be polling a dead pool (2026-09-25 incident). svc.sh restart will NOT heal; re-register manually per playbook."
fi

# C
if [ -n "$queued_json" ]; then
  if [ -n "$jammed" ]; then
    fire_alert queue-jam "build runs stuck QUEUED >$(( QUEUE_JAM_SECS / 60 ))min" \
      "$jammed || check runs-on labels vs runner labels, and registration (see alerts above)"
  else
    clear_sig queue-jam
    say "ok: no queued runs older than ${QUEUE_JAM_SECS}s"
  fi
else
  say "warn: queued-runs check failed this pass"
fi

# D
if [ -z "$label" ]; then
  fire_alert no-label "runner launchd label missing" "no actions.runner.*.plist in ~/Library/LaunchAgents — reinstall service per playbook."
elif [ -z "$svc_state" ]; then
  fire_alert label-down "runner launchd label not loaded" \
    "launchctl print gui/$uid_n/$label failed — bootstrap per RUNNER_PLAYBOOK.md Service control (manual: not auto-bootstrapped)."
elif [ -n "$listener_pid" ] && [ "$svc_state" = "running" ]; then
  clear_sig listener-down
  clear_sig label-down
  clear_sig no-label
  say "ok: listener running (pid=$listener_pid, launchd=$svc_state)"
else
  if [ "$svc_state" != "running" ] && may_restart && do_restart; then
    clear_sig listener-down
    say "ok: self-heal restart brought listener back (pid=$(pgrep -f 'Runner.Listener run' | head -1))"
  else
    fire_alert listener-down "Runner.Listener not running" \
      "launchd state='$svc_state' listener_pid='${listener_pid:-none}' — restart per playbook Service control; if recurring, check _diag/Runner_*.log."
  fi
fi

say "pass done: alerts_fired=$ALERTS"
cap_log
exit 0
