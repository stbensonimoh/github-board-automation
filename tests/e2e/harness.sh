#!/usr/bin/env bash
# E2E harness for the board automation (issue #10).
#
# Phases:
#   provision  create a throwaway board (createProjectV2), then run setup.sh
#              against it: dry run first, then live with the token on stdin
#   checks     the eight ordered state machine checks plus the no-op test,
#              each writing a JSON evidence file under tests/e2e/evidence/
#   reset      close the test issues and PRs and delete their board items
#
# Environment:
#   E2E_TOKEN            the fine grained PAT; piped to setup.sh, never echoed
#   E2E_REPO             the throwaway repo slug (owner/name)
#   E2E_OWNER            the board owner (user login or org login)
#   E2E_PROJECT_NUMBER   set by provision (or pass an existing board)
#   E2E_PROJECT_ID       the resolved PVT_ id (set by provision)
#   E2E_PLATFORM         platform slug for the helper pin, default
#                        stbensonimoh/github-board-automation
#
# The review pair (review requested, changes requested) and the approved
# no-op run through workflow_dispatch with synthetic inputs: a solo account
# cannot self request or self approve a review. The dispatch drives the real
# workflow end to end; every check produces its own Actions run URL.

set -euo pipefail

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# the lib helpers (item_line, fetch_all_items, delete_item) load in both
# execution and source mode so the bats suite can stub them
# shellcheck source=scripts/board-lib.sh
source "$HARNESS_DIR/../../scripts/board-lib.sh"
export PLATFORM_REPO="${E2E_PLATFORM:-stbensonimoh/github-board-automation}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$HARNESS_DIR/evidence}"
POLL_INTERVAL=5
FIRST_CARD_BUDGET=90
DONE_BUDGET=60

# respect already exported values (the bats suite stubs these); E2E_* env
# vars win for real runs
REPO="${E2E_REPO:-${REPO:-}}"
BOARD="${E2E_PROJECT_ID:-${BOARD:-}}"
ISSUES=()
PRS=()

# --- helpers the bats suite stubs ---------------------------------------------

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ISO 8601 to epoch, portable across BSD and GNU date
iso_to_epoch() {
  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s > /dev/null 2>&1; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s   # BSD
  else
    date -u -d "$1" +%s                            # GNU
  fi
}

card_status() {
  local items line
  items=$(fetch_all_items "$BOARD")
  line=$(item_line "$items" "$1")
  [ -n "$line" ] && printf '%s' "${line##*$'\t'}"
}

# Poll until the card for node_id shows the expected status. Prints the
# elapsed seconds from the workflow run's first step start and fails on
# timeout. SPEC: the first card must be visible within 90 seconds of the
# first workflow step; the Done poll is bounded at 60.
await_status() {
  local node="$1" want="$2" timeout="$3" first_step="$4" waited=0 got visible
  while :; do
    got=$(card_status "$node" || true)
    if [ -n "$got" ] && [ "$got" = "$want" ]; then
      visible=$(now_iso)
      echo $(( $(iso_to_epoch "$visible") - $(iso_to_epoch "$first_step") ))
      return 0
    fi
    [ "$waited" -ge "$timeout" ] && {
      echo "timeout after ${timeout}s: expected '$want', last '$got'" >&2
      return 1
    }
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
}

evidence() {
  # evidence FILE TRIGGER_NODE BEFORE AFTER RUN_URL FIRST_STEP ELAPSED
  jq -n \
    --arg trigger_event "$2" --arg item_node_id "$3" \
    --arg status_before "$4" --arg status_after "$5" \
    --arg run_url "$6" --arg first_step_started_at "$7" \
    --arg card_visible_at "$(now_iso)" --arg elapsed_seconds "$8" \
    '{trigger_event: $trigger_event, item_node_id: $item_node_id,
      status_before: $status_before, status_after: $status_after,
      run_url: $run_url, first_step_started_at: $first_step_started_at,
      card_visible_at: $card_visible_at, elapsed_seconds: ($elapsed_seconds | tonumber)}' \
    > "$1"
}

# The run URL and the first step start of the caller workflow's most recent
# run (the one this check just triggered); queue time is excluded per SPEC.
latest_run() {
  gh run list --repo "$REPO" --workflow "Board sync" --limit 1 \
    --json url,startedAt --jq '.[0] | "\(.url) \(.startedAt)"'
}

dispatch() {
  gh workflow run "Board sync" --repo "$REPO" \
    -f event_name="$1" -f action="$2" -f number="$3" -f node_id="$4" \
    ${5:+-f review_state="$5"}
}

# --- live object helpers --------------------------------------------------------

open_test_issue() {
  gh issue create --repo "$REPO" --title "e2e: state row under test" \
    --body "throwaway issue for the e2e harness"
}

open_test_pr() { # ISSUE_NUMBER LABEL -> creates a branch with one commit
  local issue="$1" label="$2" branch
  branch="e2e/$label-$(date +%s)"
  gh api --method PUT "repos/$REPO/contents/.e2e-$label" \
    -f message="e2e: $label" \
    -f content="aGk=" \
    -f branch="$branch" > /dev/null
  gh pr create --repo "$REPO" --head "$branch" \
    --title "e2e: $label" --body "Closes #$issue"
}

# --- the checks -------------------------------------------------------------------

# check N LABEL -> evidence file name
evfile() { echo "$EVIDENCE_DIR/check$1-$2.json"; }

# check1: open test issue, expect Backlog within 90 seconds
check1_open_issue() {
  local url started elapsed
  ISSUES+=("$(open_test_issue)")
  sleep 5
  read -r url started <<< "$(latest_run)"
  elapsed=$(await_status "${ISSUES[0]}" "Backlog" "$FIRST_CARD_BUDGET" "$started")
  evidence "$(evfile 1 open-issue)" "issues/opened" "${ISSUES[0]}" "" "Backlog" "$url" "$started" "$elapsed"
  echo "check 1 ok: Backlog in ${elapsed}s"
}

# check2: close the issue, reopen it, expect Todo
check2_reopen_issue() {
  local n="${ISSUES[0]}" url started elapsed
  gh issue close "$n" --repo "$REPO"
  gh issue reopen "$n" --repo "$REPO"
  sleep 5
  read -r url started <<< "$(latest_run)"
  elapsed=$(await_status "$n" "Todo" "$FIRST_CARD_BUDGET" "$started")
  evidence "$(evfile 2 reopen-issue)" "issues/reopened" "$n" "Backlog" "Todo" "$url" "$started" "$elapsed"
  echo "check 2 ok: Todo in ${elapsed}s"
}

# check3: open PR A closing the issue, expect PR plus issue In Progress
check3_open_pr_a() {
  local pr_url pr_num url started elapsed
  pr_url=$(open_test_pr "${ISSUES[0]}" "prA")
  pr_num=${pr_url##*/}
  PRS+=("$pr_num")
  sleep 5
  read -r url started <<< "$(latest_run)"
  elapsed=$(await_status "${ISSUES[0]}" "In Progress" "$FIRST_CARD_BUDGET" "$started")
  evidence "$(evfile 3 open-pr)" "pull_request_target/opened" "${ISSUES[0]}" "Todo" "In Progress" "$url" "$started" "$elapsed"
  echo "check 3 ok: In Progress in ${elapsed}s"
}

# check4: open PR B closing the same issue, close PR A unmerged,
# expect the issue to stay In Progress while B still closes it
check4_competing_pr() {
  local pr_url pr_num url started elapsed issue_node
  pr_url=$(open_test_pr "${ISSUES[0]}" "prB")
  pr_num=${pr_url##*/}
  PRS+=("$pr_num")
  gh pr close "${PRS[0]}" --repo "$REPO" --delete-branch
  sleep 5
  read -r url started <<< "$(latest_run)"
  issue_node=$(gh api "repos/$REPO/issues/${ISSUES[0]}" --jq .node_id)
  elapsed=$(await_status "$issue_node" "In Progress" "$FIRST_CARD_BUDGET" "$started")
  evidence "$(evfile 4 competing-pr)" "pull_request_target/closed" "$issue_node" "In Progress" "In Progress" "$url" "$started" "$elapsed"
  echo "check 4 ok: still In Progress in ${elapsed}s"
}

# check5: request review on PR B (synthetic dispatch), expect In Review
check5_review_requested() {
  local pr_num="${PRS[1]}" pr_node url started elapsed
  pr_node=$(gh api "repos/$REPO/pulls/$pr_num" --jq .node_id)
  dispatch "pull_request_target" "review_requested" "$pr_num" "$pr_node"
  sleep 5
  read -r url started <<< "$(latest_run)"
  elapsed=$(await_status "${ISSUES[0]}" "In Review" "$FIRST_CARD_BUDGET" "$started")
  evidence "$(evfile 5 review-requested)" "pull_request_target/review_requested" "${ISSUES[0]}" "In Progress" "In Review" "$url" "$started" "$elapsed"
  echo "check 5 ok: In Review in ${elapsed}s"
}

# check6: changes requested on PR B (synthetic dispatch), expect In Progress
check6_changes_requested() {
  local pr_num="${PRS[1]}" pr_node url started elapsed
  pr_node=$(gh api "repos/$REPO/pulls/$pr_num" --jq .node_id)
  dispatch "pull_request_review" "submitted" "$pr_num" "$pr_node" "changes_requested"
  sleep 5
  read -r url started <<< "$(latest_run)"
  elapsed=$(await_status "${ISSUES[0]}" "In Progress" "$FIRST_CARD_BUDGET" "$started")
  evidence "$(evfile 6 changes-requested)" "pull_request_review/submitted" "${ISSUES[0]}" "In Review" "In Progress" "$url" "$started" "$elapsed"
  echo "check 6 ok: In Progress in ${elapsed}s"
}

# no-op: an approved review must leave the Status unchanged
check7_approved_noop() {
  local pr_num="${PRS[1]}" pr_node before url started
  pr_node=$(gh api "repos/$REPO/pulls/$pr_num" --jq .node_id)
  before=$(card_status "${ISSUES[0]}")
  dispatch "pull_request_review" "submitted" "$pr_num" "$pr_node" "approved"
  sleep 5
  read -r url started <<< "$(latest_run)"
  evidence "$(evfile 7 approved-noop)" "pull_request_review/submitted (approved)" "${ISSUES[0]}" "$before" "$before" "$url" "$started" "0"
  echo "check 7 ok: approved review was a no-op"
}

# check8: close PR B unmerged, expect the issue back to Todo
check8_close_unmerged() {
  local pr_num="${PRS[1]}" url started elapsed
  gh pr close "$pr_num" --repo "$REPO"
  sleep 5
  read -r url started <<< "$(latest_run)"
  elapsed=$(await_status "${ISSUES[0]}" "Todo" "$FIRST_CARD_BUDGET" "$started")
  evidence "$(evfile 8 close-unmerged)" "pull_request_target/closed" "${ISSUES[0]}" "In Progress" "Todo" "$url" "$started" "$elapsed"
  echo "check 8 ok: Todo in ${elapsed}s"
}

# check9: reopen PR B, merge it, expect the issue closed and the card Done
check9_merge_done() {
  local pr_num="${PRS[1]}" url started elapsed
  gh pr reopen "$pr_num" --repo "$REPO"
  gh pr merge "$pr_num" --repo "$REPO" --squash
  sleep 5
  read -r url started <<< "$(latest_run)"
  elapsed=$(await_status "${ISSUES[0]}" "Done" "$DONE_BUDGET" "$started")
  evidence "$(evfile 9 merge-done)" "pull_request_target/closed (merged)" "${ISSUES[0]}" "Todo" "Done" "$url" "$started" "$elapsed"
  echo "check 9 ok: Done in ${elapsed}s (native Item closed workflow)"
}

checks() {
  mkdir -p "$EVIDENCE_DIR"
  check1_open_issue
  check2_reopen_issue
  check3_open_pr_a
  check4_competing_pr
  check5_review_requested
  check6_changes_requested
  check7_approved_noop
  check8_close_unmerged
  check9_merge_done
  echo "all checks passed; evidence in $EVIDENCE_DIR"
}

# --- reset ---------------------------------------------------------------------

reset_board() {
  echo "resetting test state"
  local n items content
  for n in "${PRS[@]}"; do gh pr close "$n" --repo "$REPO" --delete-branch > /dev/null 2>&1 || true; done
  for n in "${ISSUES[@]}"; do gh issue close "$n" --repo "$REPO" > /dev/null 2>&1 || true; done
  items=$(fetch_all_items "$BOARD")
  while IFS=$'\t' read -r _ content _; do
    [ -n "$content" ] || continue
    delete_item "$BOARD" "$(item_line "$items" "$content" | cut -f1)" 2>/dev/null || true
  done <<< "$items"
  echo "reset complete"
}

# --- provision ---------------------------------------------------------------------

# Creates the throwaway board and hands off to setup.sh: the board arrives
# with the default three Status options; setup appends Backlog and In Review
# and places the secrets and the caller.
provision() {
  local owner_id number title
  owner_id=$(gh api graphql -f query='
    query($login: String!) {
      user(login: $login) { id }
    }' -f login="${E2E_OWNER:?E2E_OWNER is required}" --jq '.data.user.id')
  title="e2e-throwaway-$(date +%s)"
  local proj number id
  proj=$(gh api graphql -f query="
    mutation { createProjectV2(input: { ownerId: \"$owner_id\", title: \"$title\" }) { projectV2 { id number } } }" \
    --jq '.data.createProjectV2.projectV2')
  number=$(jq -r '.number' <<<"$proj")
  id=$(jq -r '.id' <<<"$proj")
  echo "throwaway board: #$number ($id)"
  printf '%s\n' "$E2E_TOKEN" | bash "$HARNESS_DIR/../../scripts/setup.sh" \
    --owner "$E2E_OWNER" --project-number "$number" --repos "$REPO" \
    --individual-mode copy --token-expiry "${E2E_TOKEN_EXPIRY:?E2E_TOKEN_EXPIRY is required}"
  echo "export E2E_PROJECT_ID=$id for the checks phase"
}

# --- main -----------------------------------------------------------------------

usage() {
  echo "usage: e2e.sh provision|checks|reset"
  echo "  provision  create the throwaway board and run setup.sh (needs E2E_TOKEN)"
  echo "  checks     the eight checks plus the no-op (needs E2E_REPO + E2E_PROJECT_ID)"
  echo "  reset      close test objects and delete their board items"
}

main() {
  local cmd="${1:-checks}"
  : "${REPO:?E2E_REPO is required}"
  case "$cmd" in
    checks) checks ;;
    reset) reset_board ;;
    *) usage; exit 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
