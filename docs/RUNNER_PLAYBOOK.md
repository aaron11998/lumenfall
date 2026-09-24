# Self-Hosted Runner Playbook — prajwal-mac-selfhosted

Operational runbook for the LUMENFALL GitHub Actions self-hosted runner on the
Intel Mac (AGE-143 deliverable 3). Verified 2026-09-24.

## Identity

| What | Value |
|---|---|
| Runner name | `prajwal-mac-selfhosted` |
| LaunchAgent label | `actions.runner.altaranexus-ship-it-lumenfall.prajwal-mac-selfhosted` |
| Plist | `~/Library/LaunchAgents/actions.runner.altaranexus-ship-it-lumenfall.prajwal-mac-selfhosted.plist` |
| Runner home | `~/actions-runner/` |
| Repo | `altaranexus-ship-it/lumenfall` (PUBLIC — see Security) |
| Labels | `self-hosted`, `macOS`, `X64`, `intel-mac`, `amd-gpu`, `godot` |
| Workflow | `.github/workflows/build-matrix.yml` (push-to-main + dispatch only) |
| Engine | Godot 4.5.1.stable at `~/tools/godot-4.5.1/Godot.app/Contents/MacOS/Godot` |
| Templates | `~/Library/Application Support/Godot/export_templates/4.5.1.stable` |

## Service control

```bash
LABEL=actions.runner.altaranexus-ship-it-lumenfall.prajwal-mac-selfhosted
UID_N=$(id -u)

# status
launchctl print gui/$UID_N/$LABEL | grep -E 'state|pid|last exit'

# stop
launchctl bootout gui/$UID_N/$LABEL

# start (reload from plist)
launchctl bootstrap gui/$UID_N ~/Library/LaunchAgents/$LABEL.plist

# restart (canonical)
launchctl bootout gui/$UID_N/$LABEL 2>/dev/null
sleep 2
launchctl bootstrap gui/$UID_N ~/Library/LaunchAgents/$LABEL.plist
```

Verify alive: `pgrep -f 'Runner.Listener run'` should return a PID, and
`gh api repos/altaranexus-ship-it/lumenfall/actions/runners --jq '.runners[0].status'`
should return `online`.

## Logs and diagnostics

| Item | Path |
|---|---|
| launchd stdout/stderr | `~/actions-runner/_diag/Runner_*.log`, `Worker_*.log` |
| Job-level run logs | GitHub Actions run page (runner emits to `_diag` too) |
| Maintenance log | `~/.cache/actions-runner-maint.log` |
| Rollup log | `~/.cache/lumenfall-rollup.log` |

`_diag` grows unbounded; `com.prajwal.actions-runner-maint` (launchd, daily
03:15) deletes Runner_*/Worker_* logs older than 7 days and re-tightens
credential perms. Run it manually:

```bash
~/lumenfall/scripts_tool/actions_runner_maint.sh
```

## Failure playbook

1. **Runner offline in GitHub** (`status != online`):
   - `launchctl print` the label — if `state = not running`, bootstrap it (above).
   - Check `_diag/Runner_<latest>.log` for registration/permission errors.
   - After reboot the LaunchAgent should auto-start (`RunAtLoad`); if the
     Mac was renamed or the home path moved, re-run config: see Registration.

2. **Jobs stuck "Queued"**:
   - Listener running but not picking jobs => check `~/actions-runner/.runner`
     (pool/registration intact), then restart the service.
   - Check workflow `runs-on: [self-hosted, macOS, X64]` still matches labels.

3. **Build matrix failing on runner but green locally**:
   - Runner runs with the GUI session env; compare `GODOT_BIN` resolution and
     `~/Library/Application Support/Godot/export_templates/` presence.
   - Inspect `<builds dir>/lumenfall_main_<n>/logs/*.log` from the artifact or
     local `~/lumenfall/builds/`.

4. **Disk pressure**: `~/lumenfall/builds/` and `~/.cache/lumenfall-ci/import/`
   are the growth points. Rollup (`com.prajwal.lumenfall-rollup`, nightly 04:30)
   archives `lumenfall_main_*` dirs to `~/.lumenfall-releases-mirror` (and
   flushes to `/Volumes/Backup Plus/lumenfall-releases`); cache LRU keeps 5
   import blobs.

## Registration (re-config, destructive)

Only if the runner shows `offline` permanently or the pool was removed:

```bash
launchctl bootout gui/$(id -u)/actions.runner.altaranexus-ship-it-lumenfall.prajwal-mac-selfhosted
cd ~/actions-runner
./config.sh remove --token <REMOVE_TOKEN>       # token from repo Settings → Actions → Runners
./config.sh --url https://github.com/altaranexus-ship-it/lumenfall \
  --token <REG_TOKEN> --name prajwal-mac-selfhosted \
  --labels self-hosted,macOS,X64,intel-mac,amd-gpu,godot --unattended
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/actions.runner.altaranexus-ship-it-lumenfall.prajwal-mac-selfhosted.plist
```

## Security posture (do not regress)

- Repo is **PUBLIC**: the workflow must never gain `pull_request` triggers
  (untrusted PR code would execute on this machine). Push-to-main +
  `workflow_dispatch` only; `permissions: contents: read`.
- Runner runs as user `prajwalmendonca` (GUI session). Treat runner-home files
  as sensitive: `.credentials`, `.credentials_rsaparams`, `.runner` are chmod
  600 (enforced daily by the maintenance job).
- AMD GPU (Radeon Pro 5600M) is available for accelerated steps but no leg
  requires it — capability-preserving by contract.
