#!/usr/bin/env bash
# [STALE since 2026-08-25 standalone move] Publish helper kept for reference.
# Publish SciGPU working repo -> IP_dev GitHub repo under scigpu/
# Usage: tools/publish_to_ipdev.sh [commit-message]
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST="/home/peter/Desktop/IP_dev/ipdev-remote"
MSG="${1:-SciGPU update}"

[ -d "$DST/.git" ] || { echo "IP_dev clone missing at $DST"; exit 1; }

mkdir -p "$DST/scigpu"
rsync -a --delete \
  --exclude '.git' --exclude '__pycache__' --exclude '*.pyc' \
  --exclude 'build' --exclude '__pycache__/' \
  "$SRC/" "$DST/scigpu/"

# prune bulk per-seed artifacts (keep 25 samples; reproducible from manifests)
for d in "$DST/scigpu/reports/evidence/m3/random" \
         "$DST/scigpu/reports/evidence/m2/random" ; do
  [ -d "$d" ] && ls "$d" | grep '^seed' | sort | tail -n +26 | \
    while read s; do rm -rf "$d/$s"; done || true
done

cd "$DST"
if git status --porcelain -- scigpu | grep -q .; then
  git add -A scigpu
  git commit -m "SciGPU update: $MSG

Repo state: $(cd "$SRC" && git rev-parse --short HEAD) ($(cd "$SRC" && git describe --tags --always))"
else
  echo "No changes to publish."; exit 0
fi
GIT_TERMINAL_PROMPT=0 git push origin main
echo "PUBLISHED: $MSG"
