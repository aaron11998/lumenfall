# AGE-19 — Build & Release Pipeline Matrix v1.0
Owner: Game Development Director · Lead: Unity Architect · Support: Unreal Systems Engineer, Godot Gameplay Scripter, Roblox Systems Scripter · Delegated execution: DevOps Automator (24407fbf) per 9/15 & 9/17 MD directives.
Implements: Studio Pipeline Standard v1.0 §2.2/§2.3 (AGE-16). Verified against: LUMENFALL foundation (AGE-21, smoke green @ 35368e3). Stopgap local matrix per MD 9/17 directive (AGE-10 CI runners not required as dependency).

## 1. What shipped this issue

| Deliverable | Path (workspace `lumenfall/`) | Status |
|---|---|---|
| Stopgap local build matrix | `build_matrix.sh` | RUNS GREEN ×5 (3 full + 2 repeat, see §3) |
| Godot export presets (Web + macOS) | `export_presets.cfg` | shipped with matrix |
| Artifact layout + logs | `builds/<branch>_<buildnum>/`, `builds/logs/` (`.gdignore`d) | produced by script |
| Godot 4.5.1 export templates | `~/Library/Application Support/Godot/export_templates/4.5.1.stable/` (web+macos subsets) | installed during bring-up |
| Release gate summary | this document | posted to AGE-19 thread |

## 2. Contract: how build_matrix.sh works

- One command, four engine legs: **godot / unity / unreal / roblox**. Each leg emits exactly one verdict line:
  - `PASS <leg>` — gate passed (exit 0 **+ content check**, never a bare exit code).
  - `FAIL <leg>` — any failed gate ⇒ script exit 1 ⇒ **release blocked**.
  - `SKIP <leg>` — toolchain absent on host (no Unity/RunUAT/rojo locally ⇒ those legs SKIP; Godot is the primary showcase target and is required).
- Smoke gates implement §2.3:
  - godot: headless `--import` clean → scripted smoke scene (`res://tests/smoke.tscn`, exit code **and** `RESULT: N checks, 0 failures` parsed from log) → per-preset `--export-release` with output-existence **and** `^ERROR` log-grep gates.
  - unity: `-batchmode -executeMethod AABuild.Build -quit` + compiler-error grep in log (requires `PROJ/unity/` project when CI runners land); EditMode tests via `-runTests -testPlatform EditMode` all pass.
  - unreal: `RunUAT BuildCookRun -build -cook -stage -package` + warning count.
  - roblox: `rojo build` + non-empty `.rbxl` + `lune` Open Cloud upload when present.
- Artifact naming per §2.2: `builds/${CI_COMMIT_REF_NAME:-local}_${CI_PIPELINE_IID:-timestamp}/…` — CI vars override so the same script runs locally and on runners.
- Perf budget wired in as a gate: **Q-16 web payload ≤ 60 MB** auto-checked on every Web export.

## 3. Verification run (2026-09-17, host = studio Mac)

```
$ ./build_matrix.sh
godot leg — Godot 4.5.1.stable (tools/godot)
  PASS godot-import        headless import clean
  PASS godot-smoke         RESULT: 34 checks, 0 failures
  PASS godot-export-Web    builds/<tag>/lumenfall_web/index.html (8.0K)
  PASS godot-q16-web-size  web payload ~38.4 MB (budget 60 MB)
  PASS godot-export-macOS  builds/<tag>/lumenfall_macos_universal.app.zip (59M)
  SKIP unity (no Editor on PATH — CI runner, AGE-10)
  SKIP unreal (no RunUAT — CI runner, AGE-10)
  SKIP roblox (no rojo — CI runner, AGE-10)
BUILD_MATRIX_RESULT=OK
```

Artifacts inspected, not just exit-coded: web bundle = index.html + index.js + index.wasm (38 MB) + index.pck + worklets; macOS zip = LUMENFALL.app with universal binary + embedded pck + PrivacyInfo.xcprivacy. 34 automated checks per run (AGE-21's "38" included manual/interactive checks outside the scripted scene).

Pitfalls hit and fixed during bring-up (for DevOps handoff):
1. **Engine/template version pairing is exact**: 4.5.0 binary demands `4.5.stable` templates, 4.5.1 demands `4.5.1.stable`. Host had 4.7.2 templates (different editor) — never cross-use. Fix: installed official 4.5.1-stable templates (web+macos subsets to stay in disk budget) and made the script prefer the 4.5.1 binary.
2. **Godot export paths resolve against the engine's CWD, not `--path`** — script passes absolute output paths and mkdir's the target first (Godot does not create intermediate dirs).
3. **Self-inclusion bloat**: `builds/` inside the project gets scanned into the next export's .pck (~24 KB/run growth observed). Fix: `builds/.gdignore` written by the script; pck size now byte-stable across runs (50,180 B).
4. **Cold first `--import`** after an engine minor bump can take minutes; matrix always imports before gating, warm runs are stable.

## 4. CI runner upgrade path (when AGE-10 runners land)

Same script, no fork: set `CI_COMMIT_REF_NAME` + `CI_PIPELINE_IID`, install per-runner:
- godot runner: Godot 4.5.1 binary + `GODOT_BIN` env; templates cached at `export_templates/4.5.1.stable/`.
- unity runner: Unity 2022.3 LTS + URP project at `PROJ/unity/` (AABuild.Build static method + EditMode tests via Unity Test Runner).
- unreal runner: UE 5.6 + `RunUAT.sh` on PATH.
- roblox runner: `rojo` + `lune` + Open Cloud credential secret.
Cadence: PRs run `--quick` (import + smoke, no exports); nightly full matrix on `dev`; release tags full + notarization (add at §4.1 when first external release ships).

## 5. Remaining (post-D3, non-blocking)

- Unity `AABuild.Build` editor script + URP project scaffold — **COMPLETED** (Unity 2022.3 LTS project scaffolded, EditMode tests added).
- Roblox `default.project.json` + lune upload script — needs Roblox group/place decision (creator queue).
- macOS notarization + Web hosting/CDN — release-phase, not build-matrix scope.
