#!/usr/bin/env bash
# E2E harness for the board automation (issue #10).
#
# Phases:
#   provision  create a throwaway board (createProjectV2) for user or org
#              owners, run setup.sh --dry-run first then live with the token
#              on stdin, and print the E2E_PROJECT_ID for the checks phase
#   checks     the eight ordered state machine checks plus the approved
#              review no-op, each writing a JSON evidence file under
#              tests/e2e/evidence/
#   nightly    delete one item and blank another's Status, run the nightly
#              workflow, and assert the backfill defaults plus no overwrite
#   reset      close the test issues and PRs and delete only their board items
#
# Environment:
#   E2E_TOKEN            the fine grained PAT; piped to setup.sh, never echoed
#   E2E_REPOS            space separated throwaway repo slugs (one for
#                        individual configs, several for the org config)
#   E2E_OWNER            the board owner (user login or org login)
#   E2E_PROJECT_ID       set by provision (or pass an existing board)
#   E2E_TOKEN_EXPIRY     the PAT expiry for setup (YYYY-MM-DD)
#   E2E_PLATFORM         platform slug for the helper pin, default
#                        stbensonimoh/github-board-automation
#
# The review pair (review requested, changes requested) and the approved
# no-op run through workflow_dispatch with synthetic inputs: a solo account
# cannot self request or self approve a review. The dispatch drives the real
# workflow end to end; every check produces its own Actions run URL.

set -euo pipefail

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PLATFORM_REPO="${E2E_PLATFORM:-stbensonimoh/github-board-automation}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$HARNESS_DIR/evidence}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
FIRST_CARD_BUDGET=90
DONE_BUDGET=60

REPO="${E2E_REPO:-}"
BOARD="${E2E_PROJECT_ID:-}"

ISSUE_NUMBERS=()
ISSUE_NODES=()
PR_NUMBERS=()
PR_NODES=()

# --- shared helpers (the bats suite stubs these) -------------------------------

# shellcheck source=scripts/board-lib.sh
source "$HARNESS_DIR/../../scripts/board-lib.sh"

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

# The newest caller workflow run that started AFTER the given run id, printed
# as "<url> <startedAt>". Polls until it appears: the just triggered run may
# still be queued, and the pre-trigger newest run would give wrong evidence.
# await_new_run WORKFLOW AFTER_ID: the newest run of that workflow started
# after the given run id, printed as "<id> <url> <startedAt>". Polls until it
# appears; the just triggered run may still be queued.
await_new_run() {
  local wf="$1" after="$2" tries="${3:-40}" line
  while [ "$tries" -gt 0 ]; do
    line=$(gh run list --repo "$REPO" --workflow "$wf" --limit 5 \
      --json databaseId,url,startedAt \
      --jq "[.[] | select(.databaseId > $after and .startedAt != null)][0] | \"\(.databaseId) \(.url) \(.startedAt)\"" 2>/dev/null || true)
    [ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
    sleep "$POLL_INTERVAL"
    tries=$((tries - 1))
  done
  echo "no new $wf run started after run $after" >&2
  return 1
}

newest_run_id() {
  gh run list --repo "$REPO" --workflow "$1" --limit 1 \
    --json databaseId --jq '.[0].databaseId'
}

# Wait until the given run reaches a completed state. The status readers
# must not run while the dispatched run is still executing.
await_run_completed() {
  local id="$1" tries="${2:-60}" status
  while [ "$tries" -gt 0 ]; do
    status=$(gh run view "$id" --repo "$REPO" --json status --jq .status 2>/dev/null || true)
    [ "$status" = "completed" ] && return 0
    sleep "$POLL_INTERVAL"
    tries=$((tries - 1))
  done
  echo "run $id did not complete in time" >&2
  return 1
}

dispatch() {
  gh workflow run "Board sync" --repo "$REPO" \
    -f event_name="$1" -f action="$2" -f number="$3" -f node_id="$4" \
    ${5:+-f review_state="$5"}
}

issue_node_for() { gh api "repos/$REPO/issues/$1" --jq .node_id; }
pr_node_for() { gh api "repos/$REPO/pulls/$1" --jq .node_id; }

record_issue() { # NUMBER NODE
  ISSUE_NUMBERS+=("$1")
  ISSUE_NODES+=("$2")
}

record_pr() { # NUMBER NODE
  PR_NUMBERS+=("$1")
  PR_NODES+=("$2")
}

# Wait for the triggered run to start AND complete, then poll the card.
# Prints the elapsed seconds from the run's first step start. Without the
# completion wait, a card already showing the wanted status would return
# before the run executed, making the check vacuous.
run_then_status() { # NODE WANT BUDGET BEFORE_RUN_ID
  local node="$1" want="$2" budget="$3" before="$4" line id url started
  line=$(await_new_run "Board sync" "$before")
  read -r id url started <<< "$line"
  await_run_completed "$id"
  await_status "$node" "$want" "$budget" "$started"
}

# --- live object helpers --------------------------------------------------------

open_test_issue() {
  local url num node
  url=$(gh issue create --repo "$REPO" --title "e2e: state row under test" \
    --body "throwaway issue for the e2e harness")
  num=${url##*/}
  node=$(issue_node_for "$num")
  record_issue "$num" "$node"
  printf '%s' "$num"
}

open_test_pr() { # ISSUE_NUMBER LABEL -> creates a branch with one commit
  local issue="$1" label="$2" branch
  branch="e2e/$label-$(date +%s)"
  gh api --method PUT "repos/$REPO/contents/.e2e-$label" \
    -f message="e2e: $label" \
    -f content="aGk=" \
    -f branch="$branch" > /dev/null
  local url num node
  url=$(gh pr create --repo "$REPO" --head "$branch" \
    --title "e2e: $label" --body "Closes #$issue")
  num=${url##*/}
  node=$(pr_node_for "$num")
  record_pr "$num" "$node"
  printf '%s' "$num"
}

# --- the checks -------------------------------------------------------------------

evfile() { echo "$EVIDENCE_DIR/check$1-$2.json"; }

# check1: open test issue, expect Backlog within 90 seconds
check1_open_issue() {
  local before url started elapsed
  before=$(newest_run_id "Board sync" || echo 0)
  open_test_issue
  sleep 5
  elapsed=$(run_then_status "${ISSUE_NODES[0]}" "Backlog" "$FIRST_CARD_BUDGET" "$before")
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 1 open-issue)" "issues/opened" "${ISSUE_NODES[0]}" "" "Backlog" "$url" "$started" "$elapsed"
  echo "check 1 ok: Backlog in ${elapsed}s"
}

# check2: close the issue, reopen it, expect Todo
check2_reopen_issue() {
  local n="${ISSUE_NUMBERS[0]}" before url started elapsed
  before=$(newest_run_id "Board sync")
  gh issue close "$n" --repo "$REPO"
  gh issue reopen "$n" --repo "$REPO"
  elapsed=$(run_then_status "${ISSUE_NODES[0]}" "Todo" "$FIRST_CARD_BUDGET" "$before")
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 2 reopen-issue)" "issues/reopened" "${ISSUE_NODES[0]}" "Backlog" "Todo" "$url" "$started" "$elapsed"
  echo "check 2 ok: Todo in ${elapsed}s"
}

# check3: open PR A closing the issue, expect the PR plus the issue In Progress
check3_open_pr_a() {
  local before url started elapsed_e elapsed_p
  before=$(newest_run_id)
  open_test_pr "${ISSUE_NUMBERS[0]}" "prA"
  elapsed_e=$(run_then_status "${ISSUE_NODES[0]}" "In Progress" "$FIRST_CARD_BUDGET" "$before")
  elapsed_p=$(run_then_status "${PR_NODES[0]}" "In Progress" "$FIRST_CARD_BUDGET" "$before")
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 3 open-pr)" "pull_request_target/opened" "${ISSUE_NODES[0]}" "Todo" "In Progress" "$url" "$started" "$elapsed_e"
  evidence "$(evfile 3b open-pr-prcard)" "pull_request_target/opened" "${PR_NODES[0]}" "" "In Progress" "$url" "$started" "$elapsed_p"
  echo "check 3 ok: issue ${elapsed_e}s, PR ${elapsed_p}s"
}

# check4: open PR B closing the same issue, close PR A unmerged,
# expect the issue to stay In Progress while B still closes it
check4_competing_pr() {
  local before url started elapsed
  before=$(newest_run_id)
  open_test_pr "${ISSUE_NUMBERS[0]}" "prB"
  gh pr close "${PR_NUMBERS[0]}" --repo "$REPO" --delete-branch
  elapsed=$(run_then_status "${ISSUE_NODES[0]}" "In Progress" "$FIRST_CARD_BUDGET" "$before")
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 4 competing-pr)" "pull_request_target/closed" "${ISSUE_NODES[0]}" "In Progress" "In Progress" "$url" "$started" "$elapsed"
  echo "check 4 ok: still In Progress in ${elapsed}s"
}

# check5: review requested on PR B (synthetic dispatch), expect In Review
check5_review_requested() {
  local before url started elapsed
  before=$(newest_run_id)
  dispatch "pull_request_target" "review_requested" "${PR_NUMBERS[1]}" "${PR_NODES[1]}"
  elapsed=$(run_then_status "${ISSUE_NODES[0]}" "In Review" "$FIRST_CARD_BUDGET" "$before")
  run_then_status "${PR_NODES[1]}" "In Review" "$FIRST_CARD_BUDGET" "$before" > /dev/null
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 5 review-requested)" "pull_request_target/review_requested" "${ISSUE_NODES[0]}" "In Progress" "In Review" "$url" "$started" "$elapsed"
  echo "check 5 ok: In Review in ${elapsed}s"
}

# check6: changes requested on PR B (synthetic dispatch), expect In Progress
check6_changes_requested() {
  local before url started elapsed
  before=$(newest_run_id)
  dispatch "pull_request_review" "submitted" "${PR_NUMBERS[1]}" "${PR_NODES[1]}" "changes_requested"
  elapsed=$(run_then_status "${ISSUE_NODES[0]}" "In Progress" "$FIRST_CARD_BUDGET" "$before")
  run_then_status "${PR_NODES[1]}" "In Progress" "$FIRST_CARD_BUDGET" "$before" > /dev/null
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 6 changes-requested)" "pull_request_review/submitted" "${ISSUE_NODES[0]}" "In Review" "In Progress" "$url" "$started" "$elapsed"
  echo "check 6 ok: In Progress in ${elapsed}s"
}

# check7: an approved review must leave the Status unchanged
check7_approved_noop() {
  local before_run before_status after_status url started
  before_run=$(newest_run_id)
  before_status=$(card_status "${ISSUE_NODES[0]}")
  dispatch "pull_request_review" "submitted" "${PR_NUMBERS[1]}" "${PR_NODES[1]}" "approved"
  run_then_status "${ISSUE_NODES[0]}" "$before_status" "$FIRST_CARD_BUDGET" "$before_run" > /dev/null
  after_status=$(card_status "${ISSUE_NODES[0]}")
  [ "$after_status" = "$before_status" ] || {
    echo "approved review moved the card: $before_status -> $after_status" >&2
    return 1
  }
  read -r url started <<< "$(await_new_run "$before_run" 1)"
  evidence "$(evfile 7 approved-noop)" "pull_request_review/submitted (approved)" "${ISSUE_NODES[0]}" "$before_status" "$after_status" "$url" "$started" "0"
  echo "check 7 ok: approved review was a no-op"
}

# check8: close PR B unmerged with no other open PR closing the issue,
# expect the issue back to Todo
check8_close_unmerged() {
  local before url started elapsed
  before=$(newest_run_id)
  gh pr close "${PR_NUMBERS[1]}" --repo "$REPO"
  elapsed=$(run_then_status "${ISSUE_NODES[0]}" "Todo" "$FIRST_CARD_BUDGET" "$before")
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 8 close-unmerged)" "pull_request_target/closed" "${ISSUE_NODES[0]}" "In Progress" "Todo" "$url" "$started" "$elapsed"
  echo "check 8 ok: Todo in ${elapsed}s"
}

# check9: reopen PR B (the PR plus the issue return to In Progress), merge,
# expect the issue closed and the card Done via the native Item closed workflow
check9_merge_done() {
  local before url started elapsed_e
  before=$(newest_run_id)
  gh pr reopen "${PR_NUMBERS[1]}" --repo "$REPO"
  elapsed_e=$(run_then_status "${ISSUE_NODES[0]}" "In Progress" "$FIRST_CARD_BUDGET" "$before")
  run_then_status "${PR_NODES[1]}" "In Progress" "$FIRST_CARD_BUDGET" "$before" > /dev/null
  read -r url started <<< "$(await_new_run "Board sync" "$before" 1)"
  evidence "$(evfile 9 reopen-pr)" "pull_request_target/reopened" "${ISSUE_NODES[0]}" "Todo" "In Progress" "$url" "$started" "$elapsed_e"
  evidence "$(evfile 9b reopen-pr-prcard)" "pull_request_target/reopened" "${PR_NODES[1]}" "Todo" "In Progress" "$url" "$started" "$elapsed_e"

  before=$(newest_run_id "Board sync")
  gh pr merge "${PR_NUMBERS[1]}" --repo "$REPO" --squash
  elapsed=$(run_then_status "${ISSUE_NODES[0]}" "Done" "$DONE_BUDGET" "$before")
  local merge_url merge_started
  read -r merge_url merge_started <<< "$(await_new_run "Board sync" "$before" 1)"
  local state
  state=$(gh api "repos/$REPO/issues/${ISSUE_NUMBERS[0]}" --jq .state)
  [ "$state" = "closed" ] || { echo "expected the issue closed after merge, got $state" >&2; return 1; }
  evidence "$(evfile 10 merge-done)" "pull_request_target/closed (merged)" "${ISSUE_NODES[0]}" "In Progress" "Done" "$merge_url" "$merge_started" "$elapsed"
  echo "check 9 ok: issue closed, card Done in ${elapsed}s (native Item closed workflow)"
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

# --- nightly backfill test -----------------------------------------------------

# Proves the nightly readds a deleted item and fills a blank Status with the
# default (Backlog for issues) without touching an existing Status.
nightly_test() {
  local before num_a node_a node_b items line_a line_b
  local item_a item_b fields elapsed elapsed_b control_status
  fields=$(fetch_fields "$BOARD")

  # two fresh issues: A gets deleted, B gets blanked; the Done card from the
  # checks phase is the untouched control
  num_a=$(open_test_issue)
  node_a="${ISSUE_NODES[$(( ${#ISSUE_NODES[@]} - 1 ))]}"
  open_test_issue
  node_b="${ISSUE_NODES[$(( ${#ISSUE_NODES[@]} - 1 ))]}"

  # reopen A through the real state row so its card is Todo, then blank it:
  # the nightly fills blanks with the default and never infers history
  before=$(newest_run_id)
  dispatch "issues" "reopened" "$num_a" "$node_a"
  run_then_status "$node_a" "Todo" "$FIRST_CARD_BUDGET" "$before" > /dev/null

  items=$(fetch_all_items "$BOARD")
  line_a=$(item_line "$items" "$node_a")
  line_b=$(item_line "$items" "$node_b")
  item_a=${line_a%%$'\t'*}
  item_b=${line_b%%$'\t'*}
  delete_item "$BOARD" "$item_a"
  clear_status "$BOARD" "$item_b" "$(printf '%s' "$fields" | field_id Status)"

  # run the nightly and poll: A reappears as Backlog, B fills Backlog
  before=$(newest_run_id "Board nightly sync")
  gh workflow run "Board nightly sync" --repo "$REPO"
  local line id nightly_url nightly_started
  line=$(await_new_run "Board nightly sync" "$before")
  read -r id nightly_url nightly_started <<< "$line"
  await_run_completed "$id"
  elapsed=$(await_status "$node_a" "Backlog" "$FIRST_CARD_BUDGET" "$nightly_started")
  elapsed_b=$(await_status "$node_b" "Backlog" "$FIRST_CARD_BUDGET" "$nightly_started")

  # the control: the merged PR's card stayed Done (no overwrite)
  control_status=$(card_status "${PR_NODES[1]}")
  [ "$control_status" = "Done" ] || {
    echo "nightly overwrote the control card: $control_status" >&2
    return 1
  }

  evidence "$(evfile nightly backfill)" "workflow_dispatch (nightly)" "$node_a" "" "Backlog" "$nightly_url" "$nightly_started" "$elapsed"
  evidence "$(evfile nightly-blank backfill)" "workflow_dispatch (nightly)" "$node_b" "Todo" "Backlog" "$nightly_url" "$nightly_started" "$elapsed_b"
  echo "nightly ok: readd ${elapsed}s, blank fill ${elapsed_b}s, control untouched"
}

# --- reset ---------------------------------------------------------------------

reset_board() {
  echo "resetting test state"
  local n items content item_id
  # bash 3.2 errors on expanding a declared empty array under set -u, so the
  # length guard comes first and the expansion stays quoted
  local failed=0
  if [ "${#PR_NUMBERS[@]}" -gt 0 ]; then
    for n in "${PR_NUMBERS[@]}"; do
      gh pr close "$n" --repo "$REPO" --delete-branch > /dev/null 2>&1 || { echo "pr close $n failed" >&2; failed=1; }
    done
  fi
  if [ "${#ISSUE_NUMBERS[@]}" -gt 0 ]; then
    for n in "${ISSUE_NUMBERS[@]}"; do
      gh issue close "$n" --repo "$REPO" > /dev/null 2>&1 || { echo "issue close $n failed" >&2; failed=1; }
    done
  fi
  # delete only the board items the harness created, identified by the
  # tracked content node ids
  items=$(fetch_all_items "$BOARD")
  local nodes="${ISSUE_NODES[*]:-} ${PR_NODES[*]:-}"
  local node tracked
  while IFS=$'\t' read -r _ content _; do
    [ -n "$content" ] || continue
    tracked=false
    for node in $nodes; do
      [ "$content" = "$node" ] && tracked=true
    done
    [ "$tracked" = "true" ] || continue
    item_id=$(item_line "$items" "$content" | cut -f1)
    if [ -n "$item_id" ] && ! delete_item "$BOARD" "$item_id" 2>/dev/null; then
      echo "delete $item_id failed" >&2
      failed=1
    fi
  done <<< "$items"
  [ "$failed" -eq 0 ] || { echo "reset incomplete" >&2; return 1; }
  echo "reset complete"
}

# --- provision ---------------------------------------------------------------------

# Creates the throwaway board and hands off to setup.sh: the board arrives
# with the default three Status options; setup appends Backlog and In Review
# and places the secrets and the caller. User owners branch on the account
# type exactly like setup does; org owners get one board for all repos.
provision() {
  local owner_type owner_id title proj number id
  owner_type=$(gh api "users/$E2E_OWNER" --jq .type)
  if [ "$owner_type" = "Organization" ]; then
    owner_id=$(gh api graphql -f query='
      query($login: String!) {
        organization(login: $login) { id }
      }' -f login="$E2E_OWNER" --jq '.data.organization.id')
  else
    owner_id=$(gh api graphql -f query='
      query($login: String!) {
        user(login: $login) { id }
      }' -f login="$E2E_OWNER" --jq '.data.user.id')
  fi
  title="e2e-throwaway-$(date +%s)"
  proj=$(gh api graphql -f query="
    mutation { createProjectV2(input: { ownerId: \"$owner_id\", title: \"$title\" }) { projectV2 { id number } } }" \
    --jq '.data.createProjectV2.projectV2')
  number=$(jq -r '.number' <<<"$proj")
  id=$(jq -r '.id' <<<"$proj")
  echo "throwaway board: #$number ($id)"

  # dry run first, then live, per the SPEC harness paragraph
  bash "$HARNESS_DIR/../../scripts/setup.sh" \
    --owner "$E2E_OWNER" --project-number "$number" --repos "$E2E_REPOS" \
    --token-expiry "${E2E_TOKEN_EXPIRY:?E2E_TOKEN_EXPIRY is required}" \
    --dry-run
  printf '%s\n' "$E2E_TOKEN" | bash "$HARNESS_DIR/../../scripts/setup.sh" \
    --owner "$E2E_OWNER" --project-number "$number" --repos "$E2E_REPOS" \
    --token-expiry "$E2E_TOKEN_EXPIRY" --individual-mode copy

  echo "export E2E_PROJECT_ID=$id for the checks phase"
}

# --- main -----------------------------------------------------------------------

usage() {
  echo "usage: harness.sh provision|checks|nightly|reset"
  echo "  provision  create the throwaway board and run setup.sh (needs E2E_TOKEN,"
  echo "             E2E_OWNER, E2E_REPOS, E2E_TOKEN_EXPIRY)"
  echo "  checks     the eight checks plus the no-op (needs E2E_REPO + E2E_PROJECT_ID)"
  echo "  nightly    the backfill test (needs E2E_REPO + E2E_PROJECT_ID)"
  echo "  reset      close test objects and delete their board items"
}

main() {
  local cmd="${1:-checks}"
  case "$cmd" in
    provision|checks|nightly|reset) ;;
    *) usage; exit 1 ;;
  esac
  # shellcheck disable=SC1091
  source "$HARNESS_DIR/../../scripts/board-lib.sh"
  case "$cmd" in
    provision)
      : "${E2E_TOKEN:?E2E_TOKEN is required}" "${E2E_OWNER:?E2E_OWNER is required}" \
        "${E2E_REPOS:?E2E_REPOS is required}" "${E2E_TOKEN_EXPIRY:?E2E_TOKEN_EXPIRY is required}"
      provision ;;
    checks|nightly|reset)
      : "${E2E_REPO:?E2E_REPO is required}" "${E2E_PROJECT_ID:?E2E_PROJECT_ID is required}"
      case "$cmd" in
        checks) checks ;;
        nightly) nightly_test ;;
        reset) reset_board ;;
      esac ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
