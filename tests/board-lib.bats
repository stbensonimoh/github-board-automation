#!/usr/bin/env bats

# Fixture suite for scripts/board-lib.sh per SPEC Boundaries and Project
# Structure. The lib is a mechanical helper: pagination, id resolution, add
# item, set Status, and the nightly conditional write. Zero status transitions.

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

@test "opt_id returns empty for an unknown option name" {
  load_lib
  mock_gh "$FIXTURES/fields.json"
  local fields
  fields="$(fetch_fields PVT_board0000000)"
  [ -z "$(printf '%s' "$fields" | opt_id Blocked)" ]
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
  ! grep -q 'cursor=' "$MOCKLOG"
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
  mock_response '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_newItem000000"}}}}'
  write_if_blank PVT_board0000000 "$fields" "$lines" I_brandNewNode0001 0a6e581e
  grep -q 'addProjectV2ItemById' "$MOCKLOG"
  grep -q 'updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank fills blank statuses without adding" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  mock_response '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_itemTwo000000"}}}}'
  write_if_blank PVT_board0000000 "$fields" "$lines" PR_pullNode0000001 47fc9ee4
  ! grep -q 'addProjectV2ItemById' "$MOCKLOG"
  grep -q 'updateProjectV2ItemFieldValue' "$MOCKLOG"
}

@test "write_if_blank skips items that already have a status" {
  load_lib
  lines="$(items_extract < "$FIXTURES/items-page1.json")"
  fields="$(cat "$FIXTURES/fields.json")"
  mock_response '{}'
  write_if_blank PVT_board0000000 "$fields" "$lines" I_issueNode0000001 0a6e581e
  [ ! -s "$MOCKLOG" ]
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

@test "fetch_all_open_prs returns one node id per open PR" {
  load_lib
  mock_gh "$FIXTURES/prs-page1.json"
  out="$(fetch_all_open_prs octo-org/api)"
  [ "$out" = "$(printf 'PR_pullNode0000009\nPR_pullNode0000010')" ]
}

# --- the single home rule -----------------------------------------------------

@test "the helper defines no status transitions" {
  ! grep -qE 'issues/(opened|reopened)|pull_request_target/|pull_request_review' "$LIB"
}
