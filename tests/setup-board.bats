#!/usr/bin/env bats

# setup.sh part 1: board discovery and field assurance. The mutation replaces
# the whole option list, so these fixtures pin the read modify write contract:
# fail on missing required options, append only missing optional ones, echo
# every existing option back unchanged.

bats_require_minimum_version 1.5.0

SETUP="$BATS_TEST_DIRNAME/../scripts/setup.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

setup() {
  MOCKLOG="$BATS_TEST_TMPDIR/mock.log"
  : > "$MOCKLOG"
  WF_FIXTURE="workflows-enabled.json"
  export MOCKLOG FIXTURES WF_FIXTURE
}

# Mock gh that dispatches on the query shape. WF_FIXTURE picks the workflows
# response; OWNER_TYPE picks the REST user lookup result.
mock_gh_board() {
  # setup.sh runs as a child bash, so the mock must cross the process edge:
  # the fixture pickers are exported here because an env prefix on this
  # function call would otherwise die before the child gh reads them. It
  # honors --jq like the real gh does.
  export WF_FIXTURE="${WF_FIXTURE:-workflows-enabled.json}"
  export FIELDS_FIXTURE="${FIELDS_FIXTURE:-fields-five.json}"
  gh() {
    local jq_expr="" a prev="" out
    local -a rest=()
    for a in "$@"; do
      if [ "$prev" = "--jq" ]; then jq_expr="$a"
      elif [ "$a" != "--jq" ]; then rest+=("$a")
      fi
      prev="$a"
    done
    printf '%s
' "$*" >> "$MOCKLOG"
    case "${rest[*]}" in
      *"updateProjectV2Field"* | *"updateProjectV2ItemFieldValue"* | *"addProjectV2ItemById"*)
        out='{"data":{"updateProjectV2Field":{"field":{"options":[]}}}}'
        ;;
      *"workflows"*)
        out=$(cat "$FIXTURES/$WF_FIXTURE")
        ;;
      *"fields"*)
        out=$(cat "$FIXTURES/${FIELDS_FIXTURE:-fields-five.json}")
        ;;
      *"projectV2"*)
        if printf '%s' "${rest[*]}" | grep -q 'organization('; then
          out=$(cat "$FIXTURES/board-org.json")
        else
          out=$(cat "$FIXTURES/board-user.json")
        fi
        ;;
      *)
        if printf '%s' "${rest[*]}" | grep -q 'org-owner'; then
          out=$(cat "$FIXTURES/users-org.json")
        else
          out=$(cat "$FIXTURES/users-user.json")
        fi
        ;;
    esac
    if [ -n "$jq_expr" ]; then
      printf '%s' "$out" | jq -r "$jq_expr"
    else
      printf '%s' "$out"
    fi
  }
  export -f gh
}

@test "--help prints usage and exits zero" {
  run bash "$SETUP" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--owner"* ]]
  [[ "$output" == *"--project-number"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

@test "board id resolves for org owned boards" {
  mock_gh_board
  run bash "$SETUP" --owner org-owner --project-number 1 --repos org-owner/repo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PVT_orgBoard0000000"* ]]
}

@test "board id resolves for user owned boards" {
  mock_gh_board
  run bash "$SETUP" --owner some-user --project-number 1 --repos some-user/repo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PVT_userBoard0000000"* ]]
}

@test "all five options present means no mutation (idempotent rerun)" {
  mock_gh_board
  run bash -c "printf '%s' 'ghp_tok_77' | bash '$SETUP' --owner some-user --project-number 1 --repos some-user/repo --token-expiry 2027-03-01 --individual-mode copy"
  [ "$status" -eq 0 ]
  run ! grep -q 'updateProjectV2Field' "$MOCKLOG"
}

@test "missing optional options are appended with every existing option echoed back" {
  # plain assignments, not env prefixes: a prefix on a function call would be
  # restored (to empty) after the call while the export attribute remains
  FIELDS_FIXTURE="fields-three.json"
  mock_gh_board
  run bash -c "printf '%s' 'ghp_tok_78' | bash '$SETUP' --owner some-user --project-number 1 --repos some-user/repo --token-expiry 2027-03-01 --individual-mode copy"
  [ "$status" -eq 0 ]
  local mutation
  mutation=$(grep 'updateProjectV2Field' "$MOCKLOG" | tail -1)
  [ -n "$mutation" ]
  # every existing option is echoed back by name WITH its id, color, and
  # description, so GitHub preserves option identity and item field values
  local name
  for name in Todo "In Progress" Done Backlog "In Review"; do
    [[ "$mutation" == *"$name"* ]] || { echo "mutation missing option: $name"; return 1; }
  done
  for id in id_todo id_inprogress id_done; do
    [[ "$mutation" == *"$id"* ]] || { echo "mutation dropped existing option id: $id"; return 1; }
  done
  [[ "$mutation" == *'ready to start'* ]] || { echo "description lost"; return 1; }
  [[ "$mutation" == *'"color":"GREEN"'* ]] || { echo "color lost"; return 1; }
  # the field id is an inline literal
  [[ "$mutation" == *'fieldId: "PVTSSF_lADOstatus00000"'* ]]
}

@test "--repos accepts multiple slugs and rejects bare names" {
  mock_gh_board
  run bash "$SETUP" --owner some-user --project-number 1 --repos some-user/repo org-owner/other --dry-run
  [ "$status" -eq 0 ]
  run bash "$SETUP" --owner some-user --project-number 1 --repos bare-repo --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"bare-repo"* ]]
  run bash "$SETUP" --owner some-user --project-number 1 --repos owner/repo/extra --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner/repo/extra"* ]]
}

@test "a null board id fails fast naming the owner and number" {
  mock_gh_board
  # simulate a mistyped project number: projectV2 is null
  gh() {
    local jq_expr="" a prev="" out
    local -a rest=()
    for a in "$@"; do
      if [ "$prev" = "--jq" ]; then jq_expr="$a"
      elif [ "$a" != "--jq" ]; then rest+=("$a")
      fi
      prev="$a"
    done
    case "${rest[*]}" in
      *"projectV2"*) out='{"data":{"user":{"projectV2":null}}}' ;;
      *) out='{"type": "User"}' ;;
    esac
    if [ -n "$jq_expr" ]; then printf '%s' "$out" | jq -r "$jq_expr"; else printf '%s' "$out"; fi
  }
  export -f gh
  run bash "$SETUP" --owner some-user --project-number 99 --repos some-user/repo --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"some-user"* ]]
  [[ "$output" == *"99"* ]]
}

@test "missing required options fail naming them" {
  mock_gh_board
  # the default mock serves the five option fixture; swap fields for the
  # fixture that lacks In Progress
  gh() {
    case "$*" in
      *"fields"*) cat "$FIXTURES/fields-missing-required.json" ;;
      *"workflows"*) cat "$FIXTURES/workflows-enabled.json" ;;
      *"projectV2"*) cat "$FIXTURES/board-user.json" ;;
      *) cat "$FIXTURES/users-user.json" ;;
    esac
  }
  run bash "$SETUP" --owner some-user --project-number 1 --repos some-user/repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"In Progress"* ]]
}

@test "dry run prints the plan and never mutates" {
  mock_gh_board
  run bash "$SETUP" --owner some-user --project-number 1 --repos some-user/repo --dry-run
  [ "$status" -eq 0 ]
  run ! grep -q 'updateProjectV2Field' "$MOCKLOG"
}

@test "disabled Item closed workflow fails with the UI message" {
  WF_FIXTURE="workflows-disabled.json"
  mock_gh_board
  run bash "$SETUP" --owner some-user --project-number 1 --repos some-user/repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"Item closed"* ]]
  [[ "$output" == *"enable it in the project settings"* ]]
}

@test "enabled Item closed workflow passes" {
  mock_gh_board
  run bash -c "printf '%s' 'ghp_tok_84' | bash '$SETUP' --owner some-user --project-number 1 --repos some-user/repo --token-expiry 2027-03-01 --individual-mode copy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Item closed workflow enabled"* ]]
}
