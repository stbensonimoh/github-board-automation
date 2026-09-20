#!/usr/bin/env bash
# setup.sh: 1 minute installer for the board automation.
#
# Part 1 (this): board discovery and field assurance.
#   - resolve the PROJECT_BOARD_ID from owner plus project number (user and
#     org boards both supported; users never hand copy a GraphQL id)
#   - ensure the five Status options exist: fail naming any missing required
#     option (Todo, In Progress, Done), append missing Backlog and In Review
#     via updateProjectV2Field read modify write. The mutation REPLACES the
#     whole option list, so every existing option is echoed back by id, name,
#     color, and description; identity and existing item field values survive
#     only when the id is included. New options are submitted without ids
#   - verify the board native Item closed workflow is enabled; no API can
#     enable built in workflows, so a disabled one fails pointing at the
#     project settings UI
#
# All writes use the invoking user's gh auth. PROJECT_AUTOMATION_TOKEN is
# runtime only and must never be used here. Strict mode everywhere, no
# secret ever echoed (SPEC Secrets and Code Style).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
USAGE="usage: setup.sh --owner OWNER --project-number N --repos OWNER/REPO [OWNER/REPO ...]
       [--token-expiry YYYY-MM-DD] [--dry-run]

one command plus one merged caller file installs the automation on any
user or org ProjectV2 board. See README.md for the full walkthrough."

OWNER=""
PROJECT_NUMBER=""
REPOS=""
TOKEN_EXPIRY=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --project-number) PROJECT_NUMBER="$2"; shift 2 ;;
    --repos)
      shift
      [ $# -gt 0 ] || { echo "--repos needs at least one OWNER/REPO slug" >&2; exit 1; }
      while [ $# -gt 0 ] && [[ ! "$1" == --* ]]; do
        if [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
          REPOS="${REPOS:+$REPOS }$1"
        else
          echo "rejecting '$1': repos must be fully qualified OWNER/REPO slugs" >&2
          exit 1
        fi
        shift
      done ;;
    --token-expiry) TOKEN_EXPIRY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) printf '%s\n' "$USAGE"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; printf '%s\n' "$USAGE" >&2; exit 1 ;;
  esac
done

[ -n "$OWNER" ] || { echo "--owner is required" >&2; printf '%s\n' "$USAGE" >&2; exit 1; }
[ -n "$PROJECT_NUMBER" ] || { echo "--project-number is required" >&2; printf '%s\n' "$USAGE" >&2; exit 1; }
[ -n "$REPOS" ] || { echo "--repos is required (space separated OWNER/REPO slugs)" >&2; printf '%s\n' "$USAGE" >&2; exit 1; }

if [ -n "$TOKEN_EXPIRY" ]; then
  echo "token expiry: $TOKEN_EXPIRY. Add a calendar reminder before this date to rotate the PAT"
fi

# setup auth: the invoking user's gh auth only, never the runtime token
[ -z "${PROJECT_AUTOMATION_TOKEN:-}" ] || {
  echo "PROJECT_AUTOMATION_TOKEN is set; it is runtime only. Unset it and use your own gh auth for setup." >&2
  exit 1
}

# --- board discovery ---------------------------------------------------------

# opaque ProjectV2 node id from owner plus project number; user boards live
# under user(login:), org boards under organization(login:)
resolve_board_id() {
  local owner="$1" number="$2" kind
  kind=$(gh api "users/$owner" --jq .type)
  if [ "$kind" = "Organization" ]; then
    gh api graphql -f query='
      query($login: String!, $number: Int!) {
        organization(login: $login) { projectV2(number: $number) { id } }
      }' -f login="$owner" -F number="$number" --jq '.data.organization.projectV2.id'
  else
    gh api graphql -f query='
      query($login: String!, $number: Int!) {
        user(login: $login) { projectV2(number: $number) { id } }
      }' -f login="$owner" -F number="$number" --jq '.data.user.projectV2.id'
  fi
}

# --- field assurance ----------------------------------------------------------

# Read modify write with updateProjectV2Field: the mutation replaces the
# whole option list, so the complete list is submitted with every existing
# option echoed back unchanged (id, name, color, description) and only the
# missing optional options appended. Identity and existing item field values
# survive only when each existing option's id is included. Required options
# that are missing cannot be fixed by a field edit, so that fails loud.
ensure_status_options() {
  local fields="$1" dry_run="$2" name id fid options_json
  local -a need=()
  local -a missing_required=()
  for name in Todo "In Progress" Done; do
    id=$(printf '%s' "$fields" | opt_id "$name" 2>/dev/null || true)
    [ -n "$id" ] || missing_required+=("$name")
  done
  if [ ${#missing_required[@]} -gt 0 ]; then
    printf 'missing required Status option(s):%s\n' " ${missing_required[*]}" >&2
    echo "create them in the project settings UI, then rerun setup" >&2
    return 1
  fi

  for name in Backlog "In Review"; do
    id=$(printf '%s' "$fields" | opt_id "$name" 2>/dev/null || true)
    [ -n "$id" ] || need+=("$name")
  done
  if [ ${#need[@]} -eq 0 ]; then
    echo "all five Status options present, nothing to change"
    return 0
  fi
  echo "appending optional Status options: ${need[*]}"
  if [ "$dry_run" = "true" ]; then
    echo "dry run: skipping the mutation"
    return 0
  fi

  fid=$(printf '%s' "$fields" | field_id Status)
  # every existing option echoed back unchanged WITH its id: the schema docs
  # say option identity and existing item field values are only preserved
  # when the id is included. New options are submitted without ids. The ids
  # stay transient; they are never stored.
  options_json=$(printf '%s' "$fields" | jq -c '
    [.data.node.fields.nodes[] | select(.name == "Status") | .options[]
      | ({name, color: (.color // "GRAY"), description: (.description // "")}
         + (if .id then {id} else {} end))]')
  for name in "${need[@]}"; do
    options_json=$(jq -c --arg n "$name" '. + [{name: $n, color: "GRAY", description: ""}]' <<<"$options_json")
  done
  gh api graphql -f query="mutation { updateProjectV2Field(input: { fieldId: \"$fid\", singleSelectOptions: $options_json }) { field { ... on ProjectV2SingleSelectField { options { id name } } } } }" \
    | jq -r '.data.updateProjectV2Field.field.options | map(.name) | join(", ")' \
    | { read -r names; echo "Status options now: $names"; }
}

# --- Item closed workflow check ------------------------------------------------

# No API can enable built in workflows. A disabled one must fail here and
# point at the project settings UI; the install docs carry the manual step.
check_item_closed_workflow() {
  local workflows="$1" enabled
  # first() yields nothing when no node matches; do NOT add // empty, it
  # would catch an existing but disabled workflow and hide the UI message
  enabled=$(printf '%s' "$workflows" | jq -r 'first(.data.node.workflows.nodes[] | select(.name == "Item closed") | .enabled)')
  if [ -z "$enabled" ]; then
    echo "no 'Item closed' workflow found on this board; check the project settings" >&2
    return 1
  fi
  [ "$enabled" = "true" ] || {
    echo "the board's native 'Item closed' workflow is disabled: enable it in the project settings (workflows) so merged PRs land in Done" >&2
    return 1
  }
  echo "Item closed workflow enabled"
}

# --- main ----------------------------------------------------------------------

# sourceable for tests: functions only, main runs when executed directly
main() {
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/board-lib.sh"

  local board fields workflows
  board=$(resolve_board_id "$OWNER" "$PROJECT_NUMBER")
  if [ -z "$board" ] || [ "$board" = "null" ]; then
    echo "no project #$PROJECT_NUMBER found for $OWNER: check the owner login and the project number" >&2
    exit 1
  fi
  echo "board: $board"

  fields=$(fetch_fields "$board")
  ensure_status_options "$fields" "$DRY_RUN"

  workflows=$(gh api graphql -f query='
    query($project: ID!) {
      node(id: $project) { ... on ProjectV2 { workflows(first: 20) {
        nodes { name enabled }
      } } }
    }' -f project="$board")
  check_item_closed_workflow "$workflows"

  echo "board ready for automation"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
