#!/usr/bin/env bash
# Shared mechanical helpers for the board sync and nightly sync paths.
#
# This file is sourced by both workflows. It defines pagination, id
# resolution, add item, set Status, and the nightly conditional write. It
# MUST NOT define status transitions; the event to status mapping lives only
# in board-automation.yml (SPEC Project Structure).
#
# Contract (SPEC Code Style and Boundaries):
# - Field and option ids are resolved by name at runtime, never stored.
# - Mutations interpolate ids as inline literals; -f variables carry user
#   supplied values only (avoids the "Type mismatch on variable $o" failure).
# - Every list query paginates with pageInfo { hasNextPage endCursor }; the
#   v0 first: 100 single page behavior is superseded.
# - write_if_blank re-reads the item row from the current run's items before
#   writing and writes only when the item is missing or its Status is blank.
set -euo pipefail

# --- id resolution -----------------------------------------------------------

fetch_fields() {
  gh api graphql -f query='
    query($project: ID!) {
      node(id: $project) { ... on ProjectV2 { fields(first: 30) {
        nodes {
          ... on ProjectV2Field { id name }
          ... on ProjectV2SingleSelectField { id name options { id name color } }
        }
      } } }
    }' -f project="$1"
}

field_id() {
  jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name == $n) | .id' | head -1
}

opt_id() {
  jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $n) | .id'
}

# --- board items -------------------------------------------------------------

fetch_items_page() {
  local board="$1" cursor="$2"
  local args=(-f project="$board")
  [ -n "$cursor" ] && args+=(-f cursor="$cursor")
  gh api graphql -f query='
    query($project: ID!, $cursor: String) {
      node(id: $project) { ... on ProjectV2 { items(first: 100, after: $cursor) {
        nodes {
          id
          content { __typename ... on Issue { id } ... on PullRequest { id } }
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
        pageInfo { hasNextPage endCursor }
      } } }
    }' "${args[@]}"
}

# Emits one tsv row per item: item id, content node id, status (may be empty).
items_extract() {
  jq -r '.data.node.items.nodes[]
    | [.id, (.content.id // ""), ((.fieldValueByName.name // "") | gsub("\t"; " ")) ]
    | @tsv'
}

# Follows endCursor until hasNextPage is false; emits items_extract rows.
fetch_all_items() {
  local board="$1" cursor="" page
  while :; do
    page=$(fetch_items_page "$board" "$cursor")
    printf '%s' "$page" | items_extract
    [ "$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.endCursor')
  done
}

# Returns the tsv row for a content node id, or empty when the item is absent.
item_line() {
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$2 == n { print; exit }'
}

# --- mutations ----------------------------------------------------------------

add_item() {
  gh api graphql -f query="mutation { addProjectV2ItemById(input: { projectId: \"$1\", contentId: \"$2\" }) { item { id } } }" \
    | jq -r '.data.addProjectV2ItemById.item.id'
}

set_status() {
  gh api graphql -f query="mutation { updateProjectV2ItemFieldValue(input: { projectId: \"$1\", itemId: \"$2\", fieldId: \"$3\", value: { singleSelectOptionId: \"$4\" } }) { projectV2Item { id } } }" > /dev/null
}

# Nightly conditional write. Reads the item row from the caller's current
# items data, then: missing -> add and set; present and blank -> set; present
# with a Status -> skip, never overwrite. $1 board, $2 fields json, $3 item
# rows from fetch_all_items, $4 content node id, $5 default option id.
write_if_blank() {
  local line item_id status field_id_opt
  field_id_opt=$(printf '%s' "$2" | field_id Status)
  line=$(item_line "$3" "$4")
  if [ -z "$line" ]; then
    item_id=$(add_item "$1" "$4")
    set_status "$1" "$item_id" "$field_id_opt" "$5"
  else
    item_id=${line%%$'\t'*}
    status=${line##*$'\t'}
    if [ -z "$status" ]; then
      set_status "$1" "$item_id" "$field_id_opt" "$5"
    fi
  fi
}

# --- repo open issues and open PRs --------------------------------------------

fetch_open_issues_page() {
  local slug="$1" cursor="$2" owner name args
  owner=${slug%%/*}
  name=${slug##*/}
  args=(-f owner="$owner" -f name="$name")
  [ -n "$cursor" ] && args+=(-f cursor="$cursor")
  gh api graphql -f query='
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        issues(first: 100, after: $cursor, states: OPEN) {
          nodes { id number state }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' "${args[@]}"
}

fetch_open_prs_page() {
  local slug="$1" cursor="$2" owner name args
  owner=${slug%%/*}
  name=${slug##*/}
  args=(-f owner="$owner" -f name="$name")
  [ -n "$cursor" ] && args+=(-f cursor="$cursor")
  gh api graphql -f query='
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(first: 100, after: $cursor, states: OPEN) {
          nodes { id number state }
          pageInfo { hasNextPage endCursor }
        }
      }
    }' "${args[@]}"
}

issues_extract() {
  jq -r '.data.repository.issues.nodes[].id'
}

prs_extract() {
  jq -r '.data.repository.pullRequests.nodes[].id'
}

fetch_all_open_issues() {
  local slug="$1" cursor="" page
  while :; do
    page=$(fetch_open_issues_page "$slug" "$cursor")
    printf '%s' "$page" | issues_extract
    [ "$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.endCursor')
  done
}

fetch_all_open_prs() {
  local slug="$1" cursor="" page
  while :; do
    page=$(fetch_open_prs_page "$slug" "$cursor")
    printf '%s' "$page" | prs_extract
    [ "$(printf '%s' "$page" | jq -r '.data.repository.pullRequests.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(printf '%s' "$page" | jq -r '.data.repository.pullRequests.pageInfo.endCursor')
  done
}
