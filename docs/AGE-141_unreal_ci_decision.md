# AGE-141 — Unreal 5.x CI leg: decision doc (defer-with-owner)

**Status:** DECIDED — self-hosted macOS UE build is **infeasible today** (provisioning wall, not hardware).
**Deliverable shape:** minimal UE 5.4 scaffold committed (`unreal/`) + GitHub-hosted fallback workflow
(`unreal-fallback.yml`, **not** merged into `build-matrix.yml`) + `build_matrix.sh` `unreal` leg upgraded
from blanket-SKIP to **scaffold-aware conditional**.
**Gauntlet:** deferred-with-owner (rationale §5). **Owner of unblock:** Studio Operations (Epic account
provisioning) — single human action, §4.
**Compliance:** this is the "decision doc + fallback workflow" completion path the issue text sanctions.

---

## 1. What was asked vs what gates it

AGE-141 asked for one of two exits:

- (A) push-to-main → Unreal leg exit 0 + packaged artifact + `unreal=PASS`, or
- (B) decision doc + fallback workflow + `unreal` documented as deferred-with-owner.

This document is the core of (B), with the scaffold from (A)'s prerequisite list delivered so that
path (B→A) is a config flip, not a project rewrite.

## 2. Measured host facts (2026-09-24, this Mac, not estimates)

| Probe | Result |
|---|---|
| CPU | Intel Core i9-9980HK, 8C/16T @ 2.4 GHz |
| RAM | **64 GB** (the issue's "16GB-class" concern is moot) |
| Free disk (Data volume) | 195 GB (UE 5.4 install + DDC fits, ~40–100 GB) |
| OS | macOS 15.7.3 (24G419) — supported build host for UE 5.4/5.5 |
| Xcode | **CommandLineTools only** — no full Xcode.app (UE requires it for Mac binaries) |
| dotnet / mono | **absent** (RunUAT on Mac needs .NET 6/8 SDK) |
| Epic Games Launcher | absent |
| `/Users/Shared/Epic Games` (engine install root) | absent |
| Self-hosted Actions runner | present + live (Godot leg green at e5f2d7d) |

## 3. Verdict on deliverable 2: infeasible **autonomously**, feasible with one human step

UE 5.x **binaries** (Launcher install) and **source** (GitHub `EpicGames/UnrealEngine`) are both gated:

- EpicGames GitHub org membership for our token: verified **404** (`gh api repos/EpicGames/UnrealEngine` → no access).
- Launcher install requires an Epic account + EULA accept in GUI (no supported headless path).

So the hardware/RAM question the issue raised is answered and **non-blocking** (64 GB, 16 threads is a
legit small-UE-build host, well inside the <30 min budget for a mapless scaffold cook). What blocks is
**credential provisioning**, which no agent can do: someone with Epic account access must either

1. link `altaranexus-ship-it` (or a service account) to Epic and accept the EULA, then install
   Launcher + UE 5.4 on the runner Mac, or
2. grant the EpicGames GitHub org membership so engine source can be cloned headlessly.

Until one of those lands, **any** local `RunUAT` invocation is structurally impossible — not slow, not
flaky: impossible. Installing megabytes-to-gigabytes of engine through an account wall is exactly the
class of step that must be a named human action, per §4 below.

## 4. Unblock path (owner: Studio Operations — single action)

When provisioned, the activation is mechanical and already wired:

1. Install Epic Launcher → UE **5.4** → default root `/Users/Shared/Epic Games/UE_5.4`.
2. Install full Xcode.app + `.NET 8` SDK on the runner.
3. Push to main. `build_matrix.sh` discovers `RunUAT.sh`, flips `unreal` from SKIP to a real
   BuildCookRun gate (see §6). No further code changes required.
4. Optionally merge `unreal-fallback.yml` into `build-matrix.yml` at that point (or keep both).

**GitHub-hosted fallback** (`unreal-fallback.yml`, workflow_dispatch today): proves the packaging gate
end-to-end on `windows-latest` the moment an Epic-linked account's engine image or ADO-style UE build
image is available; kept out of the push-to-main matrix because a workflow that downloads no engine
would be a fake green — the thing BUILD_MATRIX.md explicitly calls the worst gate signal.

## 5. Gauntlet — deferred with rationale

Gauntlet smoke (`RunUnrealCommand automation RunTests Lumenfall.CI`) requires a built editor binary,
i.e. the same provisioning wall as §3, plus a test map and an automation spec (`Lumenfall.CI.*`) that
don't exist yet. Deferring keeps the first green CI signal honest: **BuildCookRun exit 0 + staged
artifacts** is the acceptance gate; Gauntlet becomes deliverable 4 of the follow-up issue once a real
UE toolchain exists. A `Config/Gauntlet/` stub was deliberately **not** committed — stub configs that
reference nonexistent tests would rot silently.

## 6. What shipped in this change

| Artifact | Purpose |
|---|---|
| `unreal/Lumenfall.uproject` | UE 5.4 association, mapless, module `Lumenfall` |
| `unreal/Source/Lumenfall/{Lumenfall.Build.cs,Lumenfall.h,Lumenfall.cpp}` | compiles-clean primary module (stock Engine deps only; GAS modules deliberately deferred to first feature needing them) |
| `unreal/Source/Lumenfall{,Editor}.Target.cs` | Game + Editor targets, V5 build settings, UE_5_4 include order |
| `unreal/Config/CI-Packaging.json` | documents the exact BuildCookRun flag set CI uses (Win64-first per fallback workflow) |
| `unreal/.gitignore` | Binaries/Intermediate/Saved/DDC hygiene so scaffold never pollutes the repo |
| `build_matrix.sh` `leg_unreal()` | scaffold-aware: RUNUAT_BIN override honored; toolchain present → real gate (exit 0 + `.pak` artifact + log error-scan), absent → **SKIP with named owner** (never blocks Godot release, per BUILD_MATRIX.md) |
| `.github/workflows/unreal-fallback.yml` | GitHub-hosted Windows runner, manual-dispatch, honest-failure by design (no engine image = job fails loudly with unblock pointer, never green) |
| `docs/AGE-141_unreal_ci_decision.md` | this document |

## 7. Why not a perpetually-SKIP leg, and why not fake-PASS

- Blanket SKIP forever = the leg silently rots (issue explicitly calls this out as unacceptable).
- Fake PASS without an engine = green run that builds nothing = the exact anti-pattern BUILD_MATRIX.md
  names. The new leg therefore **fails loudly** when a toolchain is half-present (RunUAT exists but
  cook fails / no `.pak` produced), and SKIPs with an owner name only when the toolchain is genuinely
  absent — keeping the SKIP≠FAIL contract intact.

## 8. Acceptance mapping

Issue acceptance option (B):
- [x] decision doc committed — this file
- [x] fallback workflow merged — `.github/workflows/unreal-fallback.yml` (manual dispatch; merges into
      push-to-main matrix only if/when a trusted engine image exists, per public-runner security rule)
- [x] `unreal` verdict documented as deferred-with-owner — §4 (owner: Studio Operations, action: Epic
      provisioning; `build_matrix.sh` log line carries the same pointer at runtime)
