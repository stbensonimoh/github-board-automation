#!/usr/bin/env bats

# Harness unit tests: the polling loop, the evidence shape, and the reset
# path, all against stubbed board reads. The live phase (#10's evidence) runs
# the real flow separately.

bats_require_minimum_version 1.5.0

HARNESS="$BATS_TEST_DIRNAME/e2e/harness.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

setup() {
  export MOCKLOG="$BATS_TEST_TMPDIR/mock.log"
  : > "$MOCKLOG"
  export EVIDENCE_DIR="$BATS_TEST_TMPDIR/evidence"
  mkdir -p "$EVIDENCE_DIR"
  export POLL_INTERVAL=0
  # E2E_* env vars are how real runs configure the harness; the harness
  # resolves REPO and BOARD from them at load time, so they must be set
  # before the harness is sourced
  export E2E_REPO="o/r"
  export E2E_PROJECT_ID="PVT_test00000000"
}

load_harness() {
  source "$HARNESS"
}

# --- polling ----------------------------------------------------------------

@test "await_status returns the elapsed seconds when the status arrives" {
  load_harness
  # the stub flips on the second poll; the counter lives in a file because
  # each poll runs inside a command substitution subshell
  echo 0 > "$BATS_TEST_TMPDIR/polls"
  fetch_all_items() {
    local c
    c=$(cat "$BATS_TEST_TMPDIR/polls")
    echo $((c + 1)) > "$BATS_TEST_TMPDIR/polls"
    if [ "$c" = "0" ]; then printf 'PVTI_x\tNODE_1\tTodo'; else printf 'PVTI_x\tNODE_1\tIn Progress'; fi
  }
  out=$(await_status NODE_1 "In Progress" 90 "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  # POLL_INTERVAL=0 means the second poll is immediate: elapsed 0 is correct
  [ "$out" -ge 0 ]
}

@test "await_status times out bounded when the status never arrives" {
  load_harness
  fetch_all_items() { printf 'PVTI_x\tNODE_1\tTodo'; }
  run --separate-stderr await_status NODE_1 "Done" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"timeout"* ]]
}

@test "await_status treats a missing card as not yet arrived" {
  load_harness
  fetch_all_items() { printf ''; }
  run await_status NODE_MISSING "Backlog" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "$status" -ne 0 ]
}

# --- evidence ----------------------------------------------------------------

@test "evidence writes the SPEC required JSON shape" {
  load_harness
  evidence "$EVIDENCE_DIR/e1.json" "issues/opened" "I_1" "Todo" "In Progress" \
    "https://github.com/x/actions/runs/1" "2026-09-20T10:00:00Z" "40"
  local j
  j=$(cat "$EVIDENCE_DIR/e1.json")
  [ "$(jq -r .trigger_event <<<"$j")" = "issues/opened" ]
  [ "$(jq -r .item_node_id <<<"$j")" = "I_1" ]
  [ "$(jq -r .status_before <<<"$j")" = "Todo" ]
  [ "$(jq -r .status_after <<<"$j")" = "In Progress" ]
  [ "$(jq -r .run_url <<<"$j")" = "https://github.com/x/actions/runs/1" ]
  [ "$(jq -r .first_step_started_at <<<"$j")" = "2026-09-20T10:00:00Z" ]
  [ "$(jq -r .card_visible_at <<<"$j")" != "" ]
  [ "$(jq -r .elapsed_seconds <<<"$j")" = "40" ]
}

@test "iso_to_epoch parses an ISO timestamp into a sane epoch" {
  load_harness
  local e
  e=$(iso_to_epoch 2026-09-20T10:00:00Z)
  [ "$e" -gt 1789000000 ]
  [ "$e" -lt 1900000000 ]
}

# --- reset --------------------------------------------------------------------

@test "reset closes test objects and deletes only their board items" {
  load_harness
  PR_NUMBERS=(4 5)
  ISSUE_NUMBERS=(12)
  ISSUE_NODES=(NODE_A)
  PR_NODES=(NODE_B)
  # stub: two tracked items plus one untracked item that must survive
  fetch_all_items() { printf 'PVTI_1\tNODE_A\tTodo\nPVTI_2\tNODE_B\t\nPVTI_3\tNODE_OTHER\tDone'; }
  gh() {
    printf '%s\n' "$*" >> "$MOCKLOG"
    case "$*" in
      *"deleteProjectV2Item"*) printf '%s' '{"data":{}}' ;;
      *) printf '%s' '' ;;
    esac
  }
  reset_board
  grep -q 'pr close 4' "$MOCKLOG"
  grep -q 'pr close 5' "$MOCKLOG"
  grep -q 'issue close 12' "$MOCKLOG"
  grep -q 'deleteProjectV2Item(input: { projectId: "PVT_test00000000", itemId: "PVTI_1" })' "$MOCKLOG"
  grep -q 'deleteProjectV2Item(input: { projectId: "PVT_test00000000", itemId: "PVTI_2" })' "$MOCKLOG"
  # the untracked item is never deleted
  run ! grep -q 'itemId: "PVTI_3"' "$MOCKLOG"
}
