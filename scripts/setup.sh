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
       [--token-expiry YYYY-MM-DD] [--individual-mode copy|reference]
       [--platform-repo OWNER/REPO] [--dry-run]

one command plus one merged caller file installs the automation on any
user or org ProjectV2 board. The PAT for the runtime secret is read from
stdin (input hidden). Individual (user) owners choose a mode: copy makes
the repo self contained (workflow plus helpers copied in, nightly
included); reference emits only the caller pinned to the platform repo's
v1 tag. See README.md for the full walkthrough."

OWNER=""
PROJECT_NUMBER=""
REPOS=""
TOKEN_EXPIRY=""
DRY_RUN=false
INDIVIDUAL_MODE=""
PLATFORM_REPO="stbensonimoh/github-board-automation"

while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --project-number) PROJECT_NUMBER="$2"; shift 2 ;;
    --repos)
      shift
      [ $# -gt 0 ] || { echo "--repos needs at least one OWNER/REPO slug" >&2; exit 1; }
      # accept both a quoted "a/b c/d" list and separate slugs; the strict
      # per slug validation runs after parsing
      while [ $# -gt 0 ] && [[ ! "$1" == --* ]]; do
        REPOS="${REPOS:+$REPOS }$1"
        shift
      done ;;
    --token-expiry) TOKEN_EXPIRY="$2"; shift 2 ;;
    --individual-mode) INDIVIDUAL_MODE="$2"; shift 2 ;;
    --platform-repo) PLATFORM_REPO="$2"; shift 2 ;;
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
# under user(login:), org boards under organization(login:). Stashes the
# owner kind in KIND for the install mode decision.
# Prints "<owner-kind> <board-id>" on one line. Command substitutions run in
# a subshell, so a global set inside would never reach the caller; the caller
# reads both fields with `read` (bash manual: read assigns the input line's
# fields to the named variables in order, splitting on IFS).
resolve_board_id() {
  local owner="$1" number="$2" kind id
  kind=$(gh api "users/$owner" --jq .type)
  if [ "$kind" = "Organization" ]; then
    id=$(gh api graphql -f query='
      query($login: String!, $number: Int!) {
        organization(login: $login) { projectV2(number: $number) { id } }
      }' -f login="$owner" -F number="$number" --jq '.data.organization.projectV2.id')
  else
    id=$(gh api graphql -f query='
      query($login: String!, $number: Int!) {
        user(login: $login) { projectV2(number: $number) { id } }
      }' -f login="$owner" -F number="$number" --jq '.data.user.projectV2.id')
  fi
  printf '%s %s\n' "$kind" "$id"
}

# --- field assurance ----------------------------------------------------------

# Read modify write with updateProjectV2Field: the mutation replaces the
# whole option list, so the complete list is submitted with every existing
# option echoed back unchanged (id, name, color, description) and only the
# missing optional options appended. Identity and existing item field values
# survive only when each existing option's id is included. Required options
# that are missing cannot be fixed by a field edit, so that fails loud.
ensure_status_options() {
  local fields="$1" dry_run="$2" name id fid options_gql
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
  # GraphQL object literals are not JSON: keys stay unquoted and only the
  # values are quoted strings, so each object is assembled with tojson
  # escaping (safe for any name with quotes or backslashes).
  options_gql=$(printf '%s' "$fields" | jq -r '
    [.data.node.fields.nodes[] | select(.name == "Status") | .options[]
      | (if .id then "id: \(.id | tojson), " else "" end)
      + "name: \(.name | tojson), color: \(.color // "GRAY" | tojson), description: \(.description // "" | tojson)"]
    | join(", ")')
  for name in "${need[@]}"; do
    options_gql="$options_gql, name: $(printf '%s' "$name" | jq -Rr .), color: \"GRAY\", description: \"\""
  done
  gh api graphql -f query="mutation { updateProjectV2Field(input: { fieldId: \"$fid\", singleSelectOptions: [$options_gql] }) { field { ... on ProjectV2SingleSelectField { options { id name } } } } }" \
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

# --- part 2: placement and emit -------------------------------------------------

# Org installs place org scope secrets and the BOARD_REPOS org variable so
# every participating repo inherits them with zero per repo work. Individual
# installs place repo scope in the single repo.
place_secrets_and_vars() {
  local mode="$1" token="$2" scope_args
  case "$mode" in
    org) scope_args=(--org "$OWNER") ;;
    *) scope_args=(--repo "$REPOS") ;;
  esac
  printf '%s' "$token" | gh secret set PROJECT_AUTOMATION_TOKEN "${scope_args[@]}"
  printf '%s' "$BOARD" | gh secret set PROJECT_BOARD_ID "${scope_args[@]}"
  printf '%s' "$REPOS" | gh variable set BOARD_REPOS "${scope_args[@]}"
  echo "secrets and BOARD_REPOS placed at ${scope_args[1]} scope"
}

# put_file REPO PATH CONTENT MESSAGE: the contents API call with the content
# base64 encoded and the commit message plain
put_file() {
  gh api --method PUT "repos/$1/contents/$2" \
    -f message="$4" \
    -f content="$(printf '%s' "$3" | base64 | tr -d '\n')" > /dev/null
}

# The caller's uses line points at the platform repo's v1 tag; copy mode
# instead references the same repo. The copied workflow still fetches its
# helpers from the platform pinned SHA, which keeps one source of truth.
build_caller() {
  local mode="$1" content
  content=$(cat "$SCRIPT_DIR/../templates/board-sync.yml")
  if [ "$mode" = "copy" ]; then
    printf '%s' "$content" | sed "s|uses: stbensonimoh/github-board-automation/\(.*\)@v1|uses: ./\1|"
  else
    printf '%s' "$content" | sed "s|stbensonimoh/github-board-automation|$PLATFORM_REPO|"
  fi
}

emit_nightly() {
  local content
  content=$(cat "$SCRIPT_DIR/../templates/board-nightly-sync.yml")
  content=$(printf '%s' "$content" | sed "s|stbensonimoh/github-board-automation|$PLATFORM_REPO|")
  put_file "$1" ".github/workflows/board-nightly-sync.yml" "$content" "add board nightly sync"
  echo "nightly emitted: $1"
}

copy_platform_files() {
  put_file "$REPOS" ".github/workflows/board-automation.yml" "$(cat "$SCRIPT_DIR/../.github/workflows/board-automation.yml")" "add reusable board automation"
  put_file "$REPOS" "scripts/board-lib.sh" "$(cat "$SCRIPT_DIR/board-lib.sh")" "add board lib"
  put_file "$REPOS" "scripts/parse-linked.sh" "$(cat "$SCRIPT_DIR/parse-linked.sh")" "add close keyword parser"
}

emit_callers() {
  local mode="$1" slug
  for slug in $REPOS; do
    put_file "$slug" ".github/workflows/board-sync.yml" "$(build_caller "$mode")" "add board sync automation"
    echo "caller emitted: $slug"
  done
  case "$mode" in
    org) emit_nightly "${REPOS%% *}" ;;  # org installs host the nightly in one repo
    copy) emit_nightly "$REPOS"; copy_platform_files ;;
    reference) ;;  # mode B has no nightly in v1
  esac
}

# --- main ----------------------------------------------------------------------

# sourceable for tests: functions only, main runs when executed directly
main() {
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/board-lib.sh"

  local fields workflows token mode
  # validate and normalize the repo list: fully qualified slugs only
  local -a slugs=()
  local slug
  for slug in $REPOS; do
    if [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      slugs+=("$slug")
    else
      echo "rejecting '$slug': repos must be fully qualified OWNER/REPO slugs" >&2
      exit 1
    fi
  done
  REPOS="${slugs[*]}"

  # the resolve prints "<kind> <board id>"; read happens in this shell so
  # KIND survives the command substitution subshell
  read -r KIND BOARD <<< "$(resolve_board_id "$OWNER" "$PROJECT_NUMBER")"
  if [ -z "$BOARD" ] || [ "$BOARD" = "null" ]; then
    echo "no project #$PROJECT_NUMBER found for $OWNER: check the owner login and the project number" >&2
    exit 1
  fi
  echo "board: $BOARD"

  fields=$(fetch_fields "$BOARD")
  ensure_status_options "$fields" "$DRY_RUN"

  workflows=$(gh api graphql -f query='
    query($project: ID!) {
      node(id: $project) { ... on ProjectV2 { workflows(first: 20) {
        nodes { name enabled }
      } } }
    }' -f project="$BOARD")
  check_item_closed_workflow "$workflows"
  echo "board ready for automation"

  if [ "$DRY_RUN" = "true" ]; then
    echo "dry run complete: secret placement and caller emit skipped"
    return 0
  fi

  # live runs must carry an expiry so the PAT gets rotated
  [ -n "$TOKEN_EXPIRY" ] || {
    echo "--token-expiry YYYY-MM-DD is required for live runs (use --dry-run to preview)" >&2
    exit 1
  }
  echo "token expiry: $TOKEN_EXPIRY. Add a calendar reminder before this date to rotate the PAT"

  case "$KIND" in
    Organization) mode="org" ;;
    *)
      case "$INDIVIDUAL_MODE" in
        copy|reference) mode="$INDIVIDUAL_MODE" ;;
        *) echo "--individual-mode copy|reference is required for user owned boards" >&2
           printf '%s\n' "$USAGE" >&2
           exit 1 ;;
      esac
      [ "${REPOS#* }" = "$REPOS" ] || { echo "individual installs support exactly one repo" >&2; exit 1; }
      ;;
  esac

  # the runtime token travels by stdin and is never echoed or logged; cat
  # handles both a piped token (no trailing newline) and a hidden TTY paste
  if [ -t 0 ]; then
    printf 'paste the PAT (input hidden; user boards need a classic PAT with project and repo scopes): ' >&2
    read -rs token
  else
    token=$(cat)
  fi
  [ -n "$token" ] || { echo "no token on stdin" >&2; exit 1; }

  place_secrets_and_vars "$mode" "$token"
  emit_callers "$mode"
  echo "setup complete"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
