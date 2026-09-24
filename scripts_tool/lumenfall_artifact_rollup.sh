#!/usr/bin/env bash
# lumenfall_artifact_rollup.sh — promote `main` CI builds to a versioned store
# (AGE-143 deliverable 2).
#
# Why: GitHub Actions artifacts expire after 14 days (retention-days: 14), so
# release builds from main would be lost. This job archives every
# builds/lumenfall_main_* directory produced by the self-hosted runner.
#
# Architecture (TCC-aware):
#   1. MIRROR-FIRST: tar each lumenfall_main_* build into ONE tar.gz on the
#      internal mirror (~/.lumenfall-releases-mirror, keep last MIRROR_KEEP).
#      A launchd-spawned process may lack Removable-Volumes TCC permission, so
#      the mirror is the guaranteed capture target — an artifact is never lost
#      to expiry even if the external volume is unavailable.
#   2. BEST-EFFORT FLUSH: drain the mirror onto the versioned store on the
#      Backup Plus volume (/Volumes/Backup Plus/lumenfall-releases). Works when
#      the caller has volume access (user terminal sessions do); silently
#      retries next run otherwise. exFAT: archives are single files, never
#      raw trees (10k+ small files choke exFAT).
#
# Idempotent: a build name is archived exactly once; source dir is removed
# only after a verified archive exists in the mirror.
#
# launchd: com.prajwal.lumenfall-rollup (nightly 04:30 + RunAtLoad catch-up)
set -uo pipefail

REPO="${LUMENFALL_REPO:-$HOME/lumenfall}"
BUILDS="$REPO/builds"
VOL="${LUMENFALL_ROLLUP_VOL:-/Volumes/Backup Plus}"
STORE="$VOL/lumenfall-releases"
MIRROR="$HOME/.lumenfall-releases-mirror"
MIRROR_KEEP=10
LOG_TAG="[rollup]"

say() { printf '%s %s\n' "$LOG_TAG" "$*"; }

mkdir -p "$MIRROR"

rolled=0
skipped=0
failed=0

# ---- phase 1: archive new builds into the mirror -------------------------
shopt -s nullglob
for src in "$BUILDS"/lumenfall_main_*; do
  [ -d "$src" ] || continue
  name="$(basename "$src")"
  stamp="$(date -u +%Y-%m-%dT%H%M%SZ)"
  arc_name="${name}_${stamp}.tar.gz"

  # idempotency: skip if this build is already captured anywhere
  if compgen -G "$MIRROR/${name}_*.tar.gz" >/dev/null 2>&1 \
     || compgen -G "$STORE/${name}_*.tar.gz" >/dev/null 2>&1; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  say "archiving $name"
  tmp="$MIRROR/.${arc_name}.tmp"
  if ! tar -czf "$tmp" -C "$BUILDS" "$name" 2>/dev/null; then
    say "FAIL: tar failed for $name"
    rm -f "$tmp"
    failed=$(( failed + 1 ))
    continue
  fi

  # verify archive integrity + entry count before consuming the source
  entries="$(tar -tzf "$tmp" 2>/dev/null | grep -c -v '/$')"
  src_entries="$(find "$src" -type f | wc -l | tr -d ' ')"
  if [ "${entries:-0}" -lt 1 ] || [ "${entries:-0}" -ne "${src_entries:-0}" ]; then
    say "FAIL: entry count mismatch for $name (archive=$entries src=$src_entries) — source kept"
    rm -f "$tmp"
    failed=$(( failed + 1 ))
    continue
  fi

  mv "$tmp" "$MIRROR/$arc_name"
  say "mirrored: $MIRROR/$arc_name ($(du -h "$MIRROR/$arc_name" | cut -f1))"
  rm -rf "$src"
  rolled=$(( rolled + 1 ))
done

# ---- phase 2: best-effort flush mirror -> external versioned store -------
flushed=0
if [ -d "$VOL" ]; then
  if mkdir -p "$STORE" 2>/dev/null; then
    for arc in "$MIRROR"/*.tar.gz; do
      [ -f "$arc" ] || continue
      dest="$STORE/$(basename "$arc")"
      [ -f "$dest" ] && continue
      if cp "$arc" "$dest" 2>/dev/null; then
        # verify the copy landed
        if [ "$(stat -f %z "$dest" 2>/dev/null)" = "$(stat -f %z "$arc")" ]; then
          say "flushed to volume: $dest"
          flushed=$(( flushed + 1 ))
        else
          rm -f "$dest"
          say "WARN: flush verify failed for $(basename "$arc") (size mismatch)"
        fi
      else
        say "volume flush blocked this run (TCC/mount) — mirror retains everything"
        break
      fi
    done
  else
    say "volume store not writable this run (TCC/mount) — mirror retains everything"
  fi
else
  say "volume not mounted: $VOL — mirror retains everything"
fi

# ---- phase 3: mirror retention (keep newest MIRROR_KEEP) -----------------
# Only prune archives that are already flushed to the volume, so the internal
# mirror never drops the only copy.
if [ -d "$STORE" ] && [ -w "$STORE" ]; then
  n=0
  for arc in $(ls -t "$MIRROR"/*.tar.gz 2>/dev/null); do
    n=$(( n + 1 ))
    [ "$n" -le "$MIRROR_KEEP" ] && continue
    base="$(basename "$arc")"
    # strip timestamp suffix: name_<stamp>.tar.gz -> name_*.tar.gz
    prefix="${base%_*}"
    if compgen -G "$STORE/${prefix}_*.tar.gz" >/dev/null 2>&1; then
      rm -f "$arc"
      say "pruned flushed mirror archive: $base"
    fi
  done
fi

say "done: rolled=$rolled skipped=$skipped failed=$failed flushed=$flushed mirror=$MIRROR store=$STORE"
exit 0
