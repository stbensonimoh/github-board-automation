#!/usr/bin/env bash
# Attach a dated E2E evidence snapshot to a GitHub release.
#
# Usage: ./scripts/attach-evidence.sh RELEASE_TAG
#
# The harness writes per run evidence under tests/e2e/evidence/ (gitignored;
# EVIDENCE_DIR overrides it). SPEC.md requires a dated snapshot of that
# evidence on every release: this stages one tarball from the JSONs and
# uploads it with --clobber, so a rerun replaces the asset instead of failing.
# Needs gh with release write access.
set -euo pipefail

usage() {
  printf 'usage: %s RELEASE_TAG (example: %s v1.2.0)\n' "${0##*/}" "${0##*/}" >&2
  exit 2
}

[ $# -eq 1 ] || usage
TAG="$1"
[ -n "$TAG" ] || usage

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/tests/e2e/evidence}"

JSON_COUNT=$(find "$EVIDENCE_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ' || true)
if [ "$JSON_COUNT" -eq 0 ]; then
  printf 'no evidence JSON files under %s\n' "$EVIDENCE_DIR" >&2
  printf 'run the harness first: bash tests/e2e/harness.sh, then retry\n' >&2
  exit 1
fi

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT

STAMP=$(date -u +%Y-%m-%d)
TARBALL="$STAGE_DIR/evidence-snapshot-$TAG-$STAMP.tar.gz"

# archive relative paths so the snapshot keeps its config subdirectories
( cd "$EVIDENCE_DIR" && find . -type f -name '*.json' -print | sort | tar -czf "$TARBALL" -T - )

printf 'attaching %s (%s evidence files) to release %s\n' "${TARBALL##*/}" "$JSON_COUNT" "$TAG"
gh release upload "$TAG" "$TARBALL" --clobber
