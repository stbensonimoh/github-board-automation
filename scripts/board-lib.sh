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
# - write_if_blank re-reads the item Status by id immediately before writing
#   (both the present branch and the add branch) and never overwrites a live
#   Status; the caller's item rows are only used to detect missing items.
set -euo pipefail

# --- id resolution -----------------------------------------------------------

fetch_fields() {
  gh api graphql -f query='
    query($project: ID!) {
      node(id: $project) { ... on ProjectV2 { fields(first: 50) {
        nodes {
          ... on ProjectV2Field { id name }
          ... on ProjectV2SingleSelectField { id name options { id name color } }
        }
      } } }
    }' -f project="$1"
}

field_id() {
  local id
  id=$(jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name == $n) | .id' | head -1)
  [ -n "$id" ] || { printf 'field not found: %s\n' "$1" >&2; return 1; }
  printf '%s\n' "$id"
}

opt_id() {
  local id
  id=$(jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $n) | .id')
  [ -n "$id" ] || { printf 'option not found: %s\n' "$1" >&2; return 1; }
  printf '%s\n' "$id"
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
# All three list loops share one termination contract: stop when the page has
# no next, when the next cursor is empty, or when the next cursor equals the
# one just sent (a non advancing API). A repeated cursor costs one duplicate
# fetch; every downstream write is conditional, so that is harmless.
fetch_all_items() {
  local board="$1" cursor="" next page
  while :; do
    page=$(fetch_items_page "$board" "$cursor")
    printf '%s' "$page" | items_extract
    [ "$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')" = "true" ] || break
    next=$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.endCursor // empty')
    [ -n "$next" ] || break
    [ "$next" != "$cursor" ] || break
    cursor=$next
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

fetch_item_status() {
  gh api graphql -f query='
    query($item: ID!) {
      node(id: $item) { ... on ProjectV2Item {
        fieldValueByName(name: "Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name }
        }
      } }
    }' -f item="$1" | jq -r '.data.node.fieldValueByName.name // ""'
}

# Nightly conditional write. Missing -> add and set. Present: re-read the
# item Status by id immediately before writing (not from the caller's
# snapshot) and set only when still blank, skip otherwise. Never overwrite.
# $1 board, $2 fields json, $3 item rows from fetch_all_items, $4 content
# node id, $5 default option id.
write_if_blank() {
  local line item_id field_id_opt live
  field_id_opt=$(printf '%s' "$2" | field_id Status)
  line=$(item_line "$3" "$4")
  if [ -z "$line" ]; then
    item_id=$(add_item "$1" "$4")
  else
    item_id=${line%%$'\t'*}
  fi
  # Re-read the Status by id immediately before writing in every branch:
  # addProjectV2ItemById returns the existing item when the content is
  # already on the board, so the live status can be anything. A failed read
  # must abort, never count as blank, or the update would overwrite.
  if ! live=$(fetch_item_status "$item_id"); then
    printf 'status read failed for item %s\n' "$item_id" >&2
    return 1
  fi
  if [ -z "$live" ]; then
    set_status "$1" "$item_id" "$field_id_opt" "$5"
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
  local slug="$1" cursor="" next page
  while :; do
    page=$(fetch_open_issues_page "$slug" "$cursor")
    printf '%s' "$page" | issues_extract
    [ "$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.hasNextPage')" = "true" ] || break
    next=$(printf '%s' "$page" | jq -r '.data.repository.issues.pageInfo.endCursor // empty')
    [ -n "$next" ] || break
    [ "$next" != "$cursor" ] || break
    cursor=$next
  done
}

fetch_all_open_prs() {
  local slug="$1" cursor="" next page
  while :; do
    page=$(fetch_open_prs_page "$slug" "$cursor")
    printf '%s' "$page" | prs_extract
    [ "$(printf '%s' "$page" | jq -r '.data.repository.pullRequests.pageInfo.hasNextPage')" = "true" ] || break
    next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequests.pageInfo.endCursor // empty')
    [ -n "$next" ] || break
    [ "$next" != "$cursor" ] || break
    cursor=$next
  done
}
