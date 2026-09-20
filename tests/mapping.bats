#!/usr/bin/env bats

# The event to status mapping is SPEC-mandated to live in
# .github/workflows/board-automation.yml only. These tests extract the case
# block from the YAML and run it against stubs, so a wrong option in any arm
# fails CI without executing the workflow.

YML="$BATS_TEST_DIRNAME/../.github/workflows/board-automation.yml"

extract_mapping() {
  sed -n '/^          case "\$EVENT" in$/,/^          esac$/p' "$YML"
}

run_mapping() {
  local event="$1" action="$2" merged="$3" review="${4:-}"
  {
    echo 'set -euo pipefail'
    echo 'set_item_status() { echo "set:$2"; }'
    echo 'link_linked_issues() { echo "link:$1"; }'
    echo 'revert_linked_issues_to_todo() { echo "revert"; }'
    extract_mapping
  } > "$BATS_TEST_TMPDIR/mapping.sh"
  EVENT="$event/$action" REVIEW="$review" MERGED="$merged" \
    B=B T=T P=P R=R NODE=NODE NUMBER=1 \
    bash "$BATS_TEST_TMPDIR/mapping.sh"
}

@test "issues opened sets Backlog" {
  run run_mapping issues opened false
  [ "$output" = "set:B" ]
}

@test "issues reopened sets Todo" {
  run run_mapping issues reopened false
  [ "$output" = "set:T" ]
}

@test "PR opened sets In Progress and links" {
  run run_mapping pull_request_target opened false
  [ "$output" = $'set:P\nlink:P' ]
}

@test "PR reopened sets In Progress and links" {
  run run_mapping pull_request_target reopened false
  [ "$output" = $'set:P\nlink:P' ]
}

@test "review requested sets In Review and links" {
  run run_mapping pull_request_target review_requested false
  [ "$output" = $'set:R\nlink:R' ]
}

@test "changes requested returns to In Progress and links" {
  run run_mapping pull_request_review submitted false changes_requested
  [ "$output" = $'set:P\nlink:P' ]
}

@test "approved review is a no-op" {
  run run_mapping pull_request_review submitted false approved
  [ -z "$output" ]
}

@test "commented review is a no-op" {
  run run_mapping pull_request_review submitted false commented
  [ -z "$output" ]
}

@test "PR closed unmerged reverts linked issues to Todo" {
  run run_mapping pull_request_target closed false
  [ "$output" = "revert" ]
}

@test "PR merged is a no-op" {
  run run_mapping pull_request_target closed true
  [ -z "$output" ]
}

@test "option bindings resolve the right names at runtime" {
  {
    echo 'set -euo pipefail'
    echo 'fetch_fields() { echo "fields-json"; }'
    echo 'field_id() { echo "field:$1"; }'
    echo 'opt_id() { echo "opt:$1"; }'
    echo 'fetch_all_items() { echo "items-json"; }'
    sed -n '/^          fields=\$(fetch_fields "\$BOARD")$/,/^          items=\$(fetch_all_items "\$BOARD")$/p' "$YML"
    echo 'printf "%s\n%s\n%s\n%s\n%s\n" "$STATUS_FIELD" "$B" "$T" "$P" "$R"'
  } > "$BATS_TEST_TMPDIR/bindings.sh"
  run env BOARD=BOARD bash "$BATS_TEST_TMPDIR/bindings.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | sed -n 1p)" = "field:Status" ]
  [ "$(printf '%s' "$output" | sed -n 2p)" = "opt:Backlog" ]
  [ "$(printf '%s' "$output" | sed -n 3p)" = "opt:Todo" ]
  [ "$(printf '%s' "$output" | sed -n 4p)" = "opt:In Progress" ]
  [ "$(printf '%s' "$output" | sed -n 5p)" = "opt:In Review" ]
}

extract_revert() {
  sed -n '/^          revert_linked_issues_to_todo() {$/,/^          }$/p' "$YML"
}

@test "revert skips linked issues that are already closed" {
  {
    echo 'set -euo pipefail'
    echo 'REPO=octo-org/api'
    echo 'NUMBER=7'
    echo 'T=T'
    echo 'PARSER=scripts/parse-linked.sh'
    echo 'linked_issue_numbers() { printf "12\n"; }'
    echo 'fetch_all_open_prs_jsonl() { echo ""; }'
    # issue 12 is already closed; gh is called once per linked issue
    echo 'gh() { printf "%s" "{\"state\": \"closed\", \"node_id\": \"NODE_X\"}"; }'
    echo 'set_item_status() { echo "MOVED:$1"; }'
    sed -n '/^          revert_linked_issues_to_todo() {$/,/^          }$/p' "$YML"
  echo 'revert_linked_issues_to_todo'
  } > "$BATS_TEST_TMPDIR/revert.sh"
  run bash "$BATS_TEST_TMPDIR/revert.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "revert moves open linked issues to Todo" {
  {
    echo 'set -euo pipefail'
    echo 'REPO=octo-org/api'
    echo 'NUMBER=7'
    echo 'T=T'
    echo 'PARSER=scripts/parse-linked.sh'
    echo 'linked_issue_numbers() { printf "12\n"; }'
    echo 'fetch_all_open_prs_jsonl() { echo ""; }'
    echo 'gh() { printf "%s" "{\"state\": \"open\", \"node_id\": \"NODE_OPEN\"}"; }'
    echo 'set_item_status() { echo "MOVED:$1"; }'
    sed -n '/^          revert_linked_issues_to_todo() {$/,/^          }$/p' "$YML"
  echo 'revert_linked_issues_to_todo'
  } > "$BATS_TEST_TMPDIR/revert-open.sh"
  run bash "$BATS_TEST_TMPDIR/revert-open.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "MOVED:NODE_OPEN" ]
}
