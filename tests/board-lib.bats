#!/usr/bin/env bats

# Fixture suite for scripts/board-lib.sh per SPEC Boundaries and Project
# Structure. The lib is a mechanical helper: pagination, id resolution, add
# item, set Status, and the nightly conditional write. Zero status transitions.

bats_require_minimum_version 1.5.0

LIB="$BATS_TEST_DIRNAME/../scripts/board-lib.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

setup() {
  MOCKLOG="$BATS_TEST_TMPDIR/mock.log"
  : > "$MOCKLOG"
}

teardown() {
  unset -f gh fetch_items_page fetch_open_issues_page fetch_open_prs_page 2>/dev/null
}

# The lib sources in strict mode; it defines only functions.
load_lib() {
  source "$LIB"
}

# Mock gh: log every argument, print the fixture file's content.
mock_gh() {
  GH_FIXTURE="$1"
  gh() {
    printf '%s\n' "$*" >> "$MOCKLOG"
    cat "$GH_FIXTURE"
  }
}

mock_response() {
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/resp.json"
  mock_gh "$BATS_TEST_TMPDIR/resp.json"
}

# Mock gh whose item status read fails like a 403 or timeout would.
mock_gh_read_fails() {
  ADD_RESP="$1"
  gh() {
    printf '%s\n' "$*" >> "$MOCKLOG"
    if [[ "$*" == *addProjectV2ItemById* ]]; then printf '%s' "$ADD_RESP"; return 0; fi
    return 1
  }
}

# Mock gh that answers per query shape: $1 for add mutations, $2 for reads.
mock_gh_seq() {
  ADD_RESP="$1"
  READ_RESP="$2"
  gh() {
    printf '%s\n' "$*" >> "$MOCKLOG"
    if [[ "$*" == *addProjectV2ItemById* ]]; then printf '%s' "$ADD_RESP"; else printf '%s' "$READ_RESP"; fi
  }
}

# --- id resolution ---------------------------------------------------------

@test "field_id resolves the Status field id by name" {
  load_lib
  mock_gh "$FIXTURES/fields.json"
  out="$(fetch_fields PVT_board0000000 | field_id Status)"
  [ "$out" = "PVTSSF_lADOstatus00000" ]
}

@test "opt_id resolves each of the fixed five by name" {
  load_lib
  mock_gh "$FIXTURES/fields.json"
  local fields
  fields="$(fetch_fields PVT_board0000000)"
  [ "$(printf '%s' "$fields" | opt_id Backlog)" = "0a6e581e" ]
  [ "$(printf '%s' "$fields" | opt_id Todo)" = "f75ad846" ]
  [ "$(printf '%s' "$fields" | opt_id "In Progress")" = "47fc9ee4" ]
  [ "$(printf '%s' "$fields" | opt_id "In Review")" = "f4b3cd98" ]
  [ "$(printf '%s' "$fields" | opt_id Done)" = "98236657" ]
}

@test "opt_id fails loudly for an unknown option name" {
  load_lib
  opt_fail() {
    local fields
    fields="$(cat "$FIXTURES/fields.json")"
    printf '%s' "$fields" | opt_id Blocked
  }
  run --separate-stderr opt_fail
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Blocked"* ]]
}

@test "field_id fails loudly for an unknown field name" {
  load_lib
  field_fail() {
    local fields
    fields="$(cat "$FIXTURES/fields.json")"
    printf '%s' "$fields" | field_id Assignee
  }
  run --separate-stderr field_fail
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Assignee"* ]]
}

# --- board items pagination ------------------------------------------------

@test "items_extract emits item id, content node id, status as tsv" {
  load_lib
  out="$(items_extract < "$FIXTURES/items-page1.json")"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
  [ "$(printf '%s' "$out" | head -1)" = "$(printf 'PVTI_itemOne000000\tI_issueNode0000001\tTodo')" ]
  [ "$(printf '%s' "$out" | sed -n 2p)" = "$(printf 'PVTI_itemTwo000000\tPR_pullNode0000001\t')" ]
}

@test "fetch_all_items follows the cursor across pages" {
  load_lib
  fetch_items_page() {
    if [ -z "$2" ]; then cat "$FIXTURES/items-page1.json"; else cat "$FIXTURES/items-page2.json"; fi
  }
  out="$(fetch_all_items PVT_board0000000)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3" ]
  [ "$(printf '%s' "$out" | tail -1)" = "$(printf 'PVTI_itemThree0000\tI_issueNode0000002\t')" ]
}

@test "fetch_items_page passes the cursor only when set" {
  load_lib
  mock_gh "$FIXTURES/items-page2.json"
  fetch_items_page PVT_board0000000 "" > /dev/null
  run ! grep -q 'cursor=' "$MOCKLOG"
  : > "$MOCKLOG"
  fetch_items_page PVT_board0000000 "CUR1" > /dev/null
  grep -q 'cursor=CUR1' "$MOCKLOG"
}

# --- item lookup and conditional write --------------------------------------

@test "item_line finds the row for a content node id" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  [ "$(item_line "$lines" I_issueNode0000001)" = "$(printf 'PVTI_itemOne000000\tI_issueNode0000001\tTodo')" ]
}

@test "item_line returns empty for an unknown content node id" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  [ -z "$(item_line "$lines" I_unknownNode00001)" ]
}

@test "write_if_blank adds missing items with the default option" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  mock_gh_seq '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_newItem000000"}}}}' '{"data":{"node":{"fieldValueByName":{"name":null}}}}'
  write_if_blank PVT_board0000000 "$fields" "$lines" I_brandNewNode0001 0a6e581e
  grep -q 'addProjectV2ItemById' "$MOCKLOG"
  grep -q 'updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank re-reads after add: GitHub may return an item that already has a status" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  # the item was missing from the snapshot, but add returns an item whose live status is Todo
  mock_gh_seq '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_existingItem00"}}}}' '{"data":{"node":{"fieldValueByName":{"name":"Todo"}}}}'
  write_if_blank PVT_board0000000 "$fields" "$lines" I_racedInNode000001 0a6e581e
  grep -q 'addProjectV2ItemById' "$MOCKLOG"
  grep -q 'item=PVTI_existingItem00' "$MOCKLOG"
  run ! grep -q 'updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank fills blank statuses without adding" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  mock_response '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_itemTwo000000"}}}}'
  write_if_blank PVT_board0000000 "$fields" "$lines" PR_pullNode0000001 47fc9ee4
  run ! grep -q 'addProjectV2ItemById' "$MOCKLOG"
  grep -q 'updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank skips items whose live status is set" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  mock_response '{"data":{"node":{"fieldValueByName":{"name":"Todo"}}}}'
  write_if_blank PVT_board0000000 "$fields" "$lines" I_issueNode0000001 0a6e581e
  run ! grep -qE 'addProjectV2ItemById|updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank aborts when the status read fails and never mutates" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  mock_gh_read_fails '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_newItem000000"}}}}'
  run --separate-stderr write_if_blank PVT_board0000000 "$fields" "$lines" PR_pullNode0000001 47fc9ee4
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"PVTI_itemTwo000000"* ]]
  run ! grep -qE 'addProjectV2ItemById|updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank aborts when the add branch status read fails" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  mock_gh_read_fails '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_newItem000000"}}}}'
  run --separate-stderr write_if_blank PVT_board0000000 "$fields" "$lines" I_brandNewNode0001 0a6e581e
  [ "$status" -ne 0 ]
  grep -q 'addProjectV2ItemById' "$MOCKLOG"
  grep -q 'item=PVTI_newItem000000' "$MOCKLOG"
  run ! grep -q 'updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank re-reads the live status and skips a status set after the snapshot" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  # the snapshot shows PR_pullNode0000001 blank, but the by id re-read finds a status
  mock_response '{"data":{"node":{"fieldValueByName":{"name":"In Review"}}}}'
  write_if_blank PVT_board0000000 "$fields" "$lines" PR_pullNode0000001 47fc9ee4
  grep -q 'item=PVTI_itemTwo000000' "$MOCKLOG"
  run ! grep -qE 'addProjectV2ItemById|updateProjectV2ItemFieldValue' "$MOCKLOG"
}

# --- mutations use inline literals -------------------------------------------

@test "add_item interpolates ids as inline literals and prints the item id" {
  load_lib
  mock_response '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_newItem000000"}}}}'
  out="$(add_item PVT_board0000000 I_issueNode0000099)"
  [ "$out" = "PVTI_newItem000000" ]
  grep -q 'mutation { addProjectV2ItemById(input: { projectId: "PVT_board0000000", contentId: "I_issueNode0000099" })' "$MOCKLOG"
}

@test "set_status interpolates ids as inline literals" {
  load_lib
  mock_response '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_x"}}}}'
  set_status PVT_board0000000 PVTI_itemOne000000 PVTSSF_lADOstatus00000 f75ad846
  grep -q 'updateProjectV2ItemFieldValue(input: { projectId: "PVT_board0000000", itemId: "PVTI_itemOne000000", fieldId: "PVTSSF_lADOstatus00000", value: { singleSelectOptionId: "f75ad846" } })' "$MOCKLOG"
}

# --- repo open issues and PRs pagination --------------------------------------

@test "issues_extract emits open issue node ids" {
  load_lib
  out="$(issues_extract < "$FIXTURES/issues-page1.json")"
  [ "$out" = "$(printf 'I_issueNode0000009\nI_issueNode0000010')" ]
}

@test "prs_extract emits open PR node ids" {
  load_lib
  out="$(prs_extract < "$FIXTURES/prs-page1.json")"
  [ "$out" = "$(printf 'PR_pullNode0000009\nPR_pullNode0000010')" ]
}

@test "fetch_all_open_issues follows the cursor across pages" {
  load_lib
  fetch_open_issues_page() {
    if [ -z "$2" ]; then cat "$FIXTURES/issues-page1.json"; else cat "$FIXTURES/issues-page2.json"; fi
  }
  out="$(fetch_all_open_issues octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3" ]
}

@test "fetch_all_open_prs follows the cursor across pages" {
  load_lib
  fetch_open_prs_page() {
    if [ -z "$2" ]; then cat "$FIXTURES/prs-page1.json"; else cat "$FIXTURES/prs-page2.json"; fi
  }
  out="$(fetch_all_open_prs octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3" ]
  [ "$(printf '%s' "$out" | tail -1)" = "PR_pullNode0000011" ]
}

@test "pagination terminates when hasNextPage is true but endCursor is null" {
  load_lib
  fetch_items_page() { cat "$FIXTURES/items-nullcursor.json"; }
  out="$(fetch_all_items PVT_board0000000)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ]
}

@test "delete_item and clear_status use inline literal ids" {
  load_lib
  mock_response '{"data":{"deleteProjectV2ItemById":{"deletedItemId":"PVTI_x"}}}'
  delete_item PVT_board0000000 PVTI_itemOne000000
  grep -q 'deleteProjectV2ItemById(input: { projectId: "PVT_board0000000", itemId: "PVTI_itemOne000000" })' "$MOCKLOG"
  mock_response '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_x"}}}}'
  clear_status PVT_board0000000 PVTI_itemOne000000 PVTSSF_lADOstatus00000
  grep -q 'singleSelectOptionId: null' "$MOCKLOG"
}

# --- the single home rule -----------------------------------------------------

@test "issues pagination terminates when hasNextPage is true but endCursor is null" {
  load_lib
  fetch_open_issues_page() { cat "$FIXTURES/issues-nullcursor.json"; }
  out="$(fetch_all_open_issues octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
}

@test "prs pagination terminates when hasNextPage is true but endCursor is null" {
  load_lib
  fetch_open_prs_page() { cat "$FIXTURES/prs-nullcursor.json"; }
  out="$(fetch_all_open_prs octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
}

@test "items pagination terminates when the API repeats the same cursor" {
  load_lib
  { fetch_items_page() {
      printf 'x\n' >> "$BATS_TEST_TMPDIR/fetches"
      [ "$(wc -l < "$BATS_TEST_TMPDIR/fetches")" -le 3 ] || return 1
      cat "$FIXTURES/items-repeatcursor.json"
    }; }
  out="$(fetch_all_items PVT_board0000000)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
}

@test "issues pagination terminates when the API repeats the same cursor" {
  load_lib
  { fetch_open_issues_page() {
      printf 'x\n' >> "$BATS_TEST_TMPDIR/fetches"
      [ "$(wc -l < "$BATS_TEST_TMPDIR/fetches")" -le 3 ] || return 1
      cat "$FIXTURES/issues-repeatcursor.json"
    }; }
  out="$(fetch_all_open_issues octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
}

@test "prs pagination terminates when the API repeats the same cursor" {
  load_lib
  { fetch_open_prs_page() {
      printf 'x\n' >> "$BATS_TEST_TMPDIR/fetches"
      [ "$(wc -l < "$BATS_TEST_TMPDIR/fetches")" -le 3 ] || return 1
      cat "$FIXTURES/prs-repeatcursor.json"
    }; }
  out="$(fetch_all_open_prs octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
}

@test "jsonl pr pagination terminates when hasNextPage is true but endCursor is null" {
  load_lib
  fetch_open_prs_page() { cat "$FIXTURES/prs-nullcursor.json"; }
  out="$(fetch_all_open_prs_jsonl octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
}

@test "jsonl pr pagination terminates when the API repeats the same cursor" {
  load_lib
  bounded() { printf 'x\n' >> "$BATS_TEST_TMPDIR/jsonlfetches"; [ "$(wc -l < "$BATS_TEST_TMPDIR/jsonlfetches")" -le 3 ] || return 1; cat "$FIXTURES/prs-repeatcursor.json"; }
  fetch_open_prs_page() { bounded; }
  out="$(fetch_all_open_prs_jsonl octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
}

# --- PR bodies for the sync path close ref check ------------------------------

@test "prs_extract_jsonl emits one compact json object per open PR" {
  load_lib
  out="$(prs_extract_jsonl < "$FIXTURES/prs-bodies-page1.json")"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ]
  first="$(printf '%s' "$out" | head -1)"
  [ "$(jq -r .number <<<"$first")" = "4" ]
  [ "$(jq -r .body <<<"$first")" = "Fixes: #12 and closes #13" ]
  [ "$(jq -r '.body' <<<"$(printf '%s' "$out" | sed -n 2p)")" = "" ]
  # jq -c escapes embedded newlines so one object is always one line
  nl='{"data":{"repository":{"pullRequests":{"nodes":[{"number":7,"body":"one\ntwo"}]}}}}'
  [ "$(printf '%s' "$nl" | prs_extract_jsonl | wc -l | tr -d ' ')" = "1" ]
}

@test "fetch_all_open_prs_jsonl follows the cursor across pages" {
  load_lib
  fetch_open_prs_page() {
    if [ -z "$2" ]; then cat "$FIXTURES/prs-bodies-page1.json"; else cat "$FIXTURES/prs-bodies-page2.json"; fi
  }
  out="$(fetch_all_open_prs_jsonl octo-org/api)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3" ]
  [ "$(jq -r .number <<<"$(printf '%s' "$out" | tail -1)")" = "6" ]
}

@test "the helper defines no status transitions" {
  run ! grep -qE 'issues/(opened|reopened)|pull_request_target/|pull_request_review' "$LIB"
  run ! grep -nE 'Backlog|Todo|In Progress|In Review|Done|review_requested|changes_requested' "$LIB"
}
