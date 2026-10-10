#!/usr/bin/env bats

# tests/attach-evidence.bats: the release snapshot helper for E2E evidence.
# gh is mocked with an exported shell function whose args are logged, so the
# suite never touches the network. The staged tarball is inspected from
# inside the mock, while the script's temp dir still exists, by caching
# `tar -tzf` output before the script's exit trap removes it.

bats_require_minimum_version 1.5.0

ATTACH="$BATS_TEST_DIRNAME/../scripts/attach-evidence.sh"

setup() {
  export BATS_TEST_TMPDIR
  export MOCKLOG="$BATS_TEST_TMPDIR/gh.log"
  export TARLOG="$BATS_TEST_TMPDIR/tar.log"
  : > "$MOCKLOG"
  : > "$TARLOG"
  export EVIDENCE_DIR="$BATS_TEST_TMPDIR/evidence"
}

teardown() {
  unset -f gh 2>/dev/null || true
}

# Mock gh: log every call; any .tar.gz argument is the staged snapshot, so
# list it now (the script deletes it on exit, after gh returns).
mock_gh() {
  gh() {
    printf '%s\n' "$*" >> "$MOCKLOG"
    local a
    for a in "$@"; do
      case "$a" in
        *.tar.gz) tar -tzf "$a" | sort > "$TARLOG" ;;
      esac
    done
  }
  export -f gh
}

write_evidence() {
  mkdir -p "$EVIDENCE_DIR/private"
  printf '{"trigger_event":"issues/opened"}\n' > "$EVIDENCE_DIR/private/check1-open-issue.json"
  printf '{"trigger_event":"pull_request_target/opened"}\n' > "$EVIDENCE_DIR/private/check3-open-pr.json"
}

@test "missing tag fails with usage" {
  run bash "$ATTACH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "empty tag fails with usage" {
  run bash "$ATTACH" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "no evidence directory fails with an actionable message and no gh call" {
  mock_gh
  run bash "$ATTACH" v1.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"no evidence"* ]]
  [[ "$output" == *"harness"* ]]
  [ ! -s "$MOCKLOG" ]
}

@test "empty evidence directory fails and attempts no upload" {
  mock_gh
  mkdir -p "$EVIDENCE_DIR"
  run bash "$ATTACH" v1.2.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"no evidence"* ]]
  [ ! -s "$MOCKLOG" ]
}

@test "success uploads exactly one dated snapshot for the release" {
  mock_gh
  write_evidence
  run bash "$ATTACH" v1.2.0
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$MOCKLOG")" -eq 1 ]
  [ "$(grep -c '\.tar\.gz' "$MOCKLOG")" -eq 1 ]
  grep -Eq '^release upload v1\.2\.0 .*/evidence-snapshot-v1\.2\.0-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz --clobber$' "$MOCKLOG"
  grep -q "evidence-snapshot-v1.2.0-$(date -u +%Y-%m-%d).tar.gz" "$MOCKLOG"
}

@test "snapshot tarball carries the nested evidence JSONs" {
  mock_gh
  write_evidence
  run bash "$ATTACH" v1.2.0
  [ "$status" -eq 0 ]
  grep -q 'private/check1-open-issue.json' "$TARLOG"
  grep -q 'private/check3-open-pr.json' "$TARLOG"
}

@test "success message names the asset and the release" {
  mock_gh
  write_evidence
  run bash "$ATTACH" v1.2.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"evidence-snapshot-v1.2.0-"* ]]
  [[ "$output" == *"release v1.2.0"* ]]
}
