#!/usr/bin/env bats

# The caller template is the only file users copy; its shape is the install
# UX. These tests lock the SPEC pinned contract: triggers, dispatch inputs,
# explicit secrets, the 40 line cap, and the nightly's variable handling.

SYNC="$BATS_TEST_DIRNAME/../.github/workflows/board-sync-template.yml"
NIGHTLY="$BATS_TEST_DIRNAME/../.github/workflows/board-nightly-sync-template.yml"

@test "caller is at most 40 lines" {
  [ "$(wc -l < "$SYNC" | tr -d ' ')" -le 40 ]
}

@test "caller declares the exact event triggers" {
  grep -q '  issues:' "$SYNC"
  grep -q '    types: \[opened, reopened\]' "$SYNC"
  grep -q '  pull_request_target:' "$SYNC"
  grep -q '    types: \[opened, reopened, closed, review_requested\]' "$SYNC"
  grep -q '  pull_request_review:' "$SYNC"
  grep -q '    types: \[submitted\]' "$SYNC"
}

@test "caller declares workflow_dispatch with all five manual inputs" {
  grep -q '  workflow_dispatch:' "$SYNC"
  for input in event_name action number node_id review_state; do
    grep -q "      $input: { required" "$SYNC"
  done
  # node_id must be required (the reusable workflow guards on it)
  grep -q '      node_id: { required: true, type: string }' "$SYNC"
}

@test "caller maps every input with an explicit event fallback" {
  grep -q 'event_name: ${{ inputs.event_name || github.event_name }}' "$SYNC"
  grep -q 'action: ${{ inputs.action || github.event.action }}' "$SYNC"
  grep -q 'number: ${{ inputs.number || github.event.issue.number || github.event.pull_request.number }}' "$SYNC"
  grep -q 'node_id: ${{ inputs.node_id || github.event.issue.node_id || github.event.pull_request.node_id }}' "$SYNC"
  grep -q 'repository: ${{ github.repository }}' "$SYNC"
  grep -q 'merged: ${{ github.event.pull_request.merged == true }}' "$SYNC"
  grep -q 'review_state: ${{ inputs.review_state || github.event.review.state }}' "$SYNC"
}

@test "caller maps both secrets explicitly and never uses inherit" {
  grep -q 'PROJECT_AUTOMATION_TOKEN: ${{ secrets.PROJECT_AUTOMATION_TOKEN }}' "$SYNC"
  grep -q 'PROJECT_BOARD_ID: ${{ secrets.PROJECT_BOARD_ID }}' "$SYNC"
  # the jobs section must not use inherit; the header comment mentions it as
  # an option for same org callers, so scope this check to jobs:
  run bash -c "sed -n '/^jobs:/,\$p' '$SYNC' | grep -q 'secrets: inherit'"
  [ "$status" -ne 0 ]
}

@test "caller pins the reusable workflow to the v1 tag" {
  grep -qE 'uses: stbensonimoh/github-board-automation/\.github/workflows/board-automation\.yml@v1$' "$SYNC"
  ! grep -q '@main' "$SYNC"
}

@test "caller is named Board sync" {
  [ "$(head -1 "$SYNC")" = "name: Board sync" ]
}

@test "nightly is named Board nightly sync with the daily cron" {
  [ "$(head -1 "$NIGHTLY")" = "name: Board nightly sync" ]
  grep -q "  schedule:" "$NIGHTLY"
  grep -q "  - cron: '0 6 \* \* \*'" "$NIGHTLY"
  grep -q '  workflow_dispatch: {}' "$NIGHTLY"
}

@test "nightly reads BOARD_REPOS and rejects bare repo names" {
  grep -q 'BOARD_REPOS: ${{ vars.BOARD_REPOS }}' "$NIGHTLY"
  grep -q "rejecting bare repo name" "$NIGHTLY"
}

@test "nightly fills blanks through the conditional writer only" {
  # no direct set_status calls: the conditional write path owns nightly writes
  run ! grep -q 'set_status ' "$NIGHTLY"
  grep -q 'write_if_blank' "$NIGHTLY"
  # backfill only open issues and open PRs; the items snapshot is read only
  grep -q 'fetch_all_open_issues' "$NIGHTLY"
  grep -q 'fetch_all_open_prs' "$NIGHTLY"
  grep -q 'items=\$(fetch_all_items' "$NIGHTLY"
}

@test "both workflows use the shared repo wide concurrency group" {
  # the reusable workflow and the nightly standalone need their own group;
  # the thin caller delegates and inherits the reusable workflow's group
  for f in "$NIGHTLY" "$BATS_TEST_DIRNAME/../.github/workflows/board-automation.yml"; do
    grep -q '^concurrency:' "$f" || { echo "missing concurrency in $f"; return 1; }
    grep -q 'group: board-\${{ github.repository }}' "$f" || { echo "wrong group in $f"; return 1; }
    grep -q 'cancel-in-progress: false' "$f" || { echo "cancel-in-progress must be false in $f"; return 1; }
  done
}

@test "nightly loop wiring pairs issues with B and PRs with P and rejects bare slugs" {
  block=$(sed -n '/for slug in \$BOARD_REPOS/,/^          done$/p' "$NIGHTLY")
  stub='set -euo pipefail
fetch_all_open_issues() { echo I_1; }
fetch_all_open_prs() { echo PR_1; }
write_if_blank() { echo "write:$4:$5"; }'
  run env BOARD_REPOS="o/r" BOARD=b fields=f items=i B=B P=P bash -c "$stub
$block"
  [ "$status" -eq 0 ]
  [[ "$output" == *"write:I_1:B"* ]]
  [[ "$output" == *"write:PR_1:P"* ]]
  run env BOARD_REPOS=bare BOARD=b fields=f items=i B=B P=P bash -c "$stub
$block"
  [ "$status" -ne 0 ]
}

@test "nightly loop fails loud when an issue fetch fails" {
  block=$(sed -n '/for slug in \$BOARD_REPOS/,/^          done$/p' "$NIGHTLY")
  stub='set -euo pipefail
fetch_all_open_issues() { return 1; }
fetch_all_open_prs() { echo PR_1; }
write_if_blank() { echo "write:$4:$5"; }'
  run env BOARD_REPOS="o/r" BOARD=b fields=f items=i B=B P=P bash -c "$stub
$block"
  [ "$status" -ne 0 ]
}

@test "nightly loop fails loud when a PR fetch fails" {
  block=$(sed -n '/for slug in \$BOARD_REPOS/,/^          done$/p' "$NIGHTLY")
  stub='set -euo pipefail
fetch_all_open_issues() { echo I_1; }
fetch_all_open_prs() { return 1; }
write_if_blank() { echo "write:$4:$5"; }'
  run env BOARD_REPOS="o/r" BOARD=b fields=f items=i B=B P=P bash -c "$stub
$block"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to fetch open PRs"* ]]
}

@test "nightly pins the helper fetch to the same ref as the reusable workflow" {
  nref=$(sed -n 's/^[[:space:]]*ref:[[:space:]]*//p' "$NIGHTLY")
  rref=$(sed -n 's/^[[:space:]]*ref:[[:space:]]*//p' "$BATS_TEST_DIRNAME/../.github/workflows/board-automation.yml")
  [ "$nref" = "$rref" ] || { echo "refs differ: nightly '$nref' vs reusable '$rref'"; return 1; }
  [[ "$nref" =~ ^([0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "ref '$nref' is not an immutable SHA or vX.Y.Z tag"; return 1; }
  run ! grep -q '@main' "$NIGHTLY"
}
