#!/usr/bin/env bats

# setup.sh part 2: secret and variable placement plus caller emit. The token
# travels by stdin, never in arguments or logs. Org installs place org scope
# secrets and the BOARD_REPOS org variable; individual installs use repo
# scope. The nightly is emitted only where the mode includes one.

SETUP="$BATS_TEST_DIRNAME/../scripts/setup.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
TOKEN="ghp_test_token_never_echo_12345"

setup() {
  MOCKLOG="$BATS_TEST_TMPDIR/mock.log"
  : > "$MOCKLOG"
  export MOCKLOG FIXTURES
  export WF_FIXTURE="workflows-enabled.json"
  export FIELDS_FIXTURE="fields-five.json"
  bats_require_minimum_version 1.5.0
}

teardown() {
  unset -f gh 2>/dev/null
  unset GH_SCOPES 2>/dev/null || true
}

# Full flow mock: every gh call is logged (args only, so the token on stdin
# never appears) and dispatches on the query shape.
mock_gh_full() {
  gh() {
    printf '%s\n' "$*" >> "$MOCKLOG"
    local jq_expr="" a prev="" out
    local -a rest=()
    for a in "$@"; do
      if [ "$prev" = "--jq" ]; then jq_expr="$a"
      elif [ "$a" != "--jq" ]; then rest+=("$a")
      fi
      prev="$a"
    done
    case "${rest[*]}" in
      *"updateProjectV2Field"* | *"updateProjectV2ItemFieldValue"* | *"addProjectV2ItemById"*)
        out='{"data":{"updateProjectV2Field":{"projectV2Field":{"options":[]}}}}'
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
      *"secret set"* | *"variable set"*)
        out=''
        ;;
      *"contents/"*)
        out='{"content":{"path":"emitted"}}'
        ;;
      *)
        if [[ "$*" == *"users/org-owner"* ]]; then
          out=$(cat "$FIXTURES/users-org.json")
        else
          out=$(cat "$FIXTURES/users-user.json")
        fi
        ;;
    esac
    # setup's scope pre-flight calls gh -i user; emulate the header block.
    # GH_SCOPES defaults to a token that has the workflow scope.
    local header_block=""
    for a in "$@"; do
      [ "$a" = "-i" ] && header_block="x-oauth-scopes: ${GH_SCOPES:-repo, workflow, project}\n\n"
    done
    if [ -n "$jq_expr" ]; then
      printf '%s' "$out" | jq -r "$jq_expr"
    else
      printf '%b' "$header_block"
      printf '%s' "$out"
    fi
  }
  export -f gh
}

# The -i pre-flight in setup.sh reads the token scope headers; the mock
# emits them with GH_SCOPES when -i is present.
SCOPE_HEADER_PREFIX="x-oauth-scopes:"

# every live call carries the expiry; the fail fast test omits it on purpose
run_setup() {
  run bash -c "printf '%s' '$TOKEN' | bash '$SETUP' --token-expiry 2027-03-01 $*"
}

@test "org install places org secrets, org variable, and callers in every repo" {
  mock_gh_full
  run_setup --owner org-owner --project-number 1 --repos "org-owner/api org-owner/web"
  [ "$status" -eq 0 ]
  grep -q 'secret set PROJECT_AUTOMATION_TOKEN --org org-owner' "$MOCKLOG"
  grep -q 'secret set PROJECT_BOARD_ID --org org-owner' "$MOCKLOG"
  grep -q 'variable set BOARD_REPOS --org org-owner' "$MOCKLOG"
  [ "$(grep -c 'contents/' "$MOCKLOG")" = "3" ]  # 2 callers + 1 nightly (first repo)
  grep -q 'repos/org-owner/api/contents/.github/workflows/board-nightly-sync.yml' "$MOCKLOG"
  [[ "$output" == *"nightly"* ]]
}

@test "the token never appears in logs or output" {
  mock_gh_full
  run_setup --owner some-user --project-number 1 --repos some-user/repo --individual-mode copy
  [ "$status" -eq 0 ]
  run ! grep -q "$TOKEN" "$MOCKLOG"
  [[ "$output" != *"$TOKEN"* ]]
}

@test "individual copy mode sets repo scope and copies the platform files" {
  mock_gh_full
  run_setup --owner some-user --project-number 1 --repos some-user/repo --individual-mode copy
  [ "$status" -eq 0 ]
  grep -q 'secret set PROJECT_AUTOMATION_TOKEN --repo some-user/repo' "$MOCKLOG"
  grep -q 'variable set BOARD_REPOS --repo some-user/repo' "$MOCKLOG"
  # platform files copied: reusable workflow plus both helpers
  grep -q 'repos/some-user/repo/contents/.github/workflows/board-automation.yml' "$MOCKLOG"
  grep -q 'repos/some-user/repo/contents/scripts/board-lib.sh' "$MOCKLOG"
  grep -q 'repos/some-user/repo/contents/scripts/parse-linked.sh' "$MOCKLOG"
  # caller uses the same repo reference and the nightly is included
  [ "$(grep -c 'contents/' "$MOCKLOG")" = "5" ]
  grep -q 'repos/some-user/repo/contents/.github/workflows/board-nightly-sync.yml' "$MOCKLOG"
}

@test "individual reference mode emits the caller only, pinned to v1, no nightly" {
  mock_gh_full
  run_setup --owner some-user --project-number 1 --repos some-user/repo --individual-mode reference
  [ "$status" -eq 0 ]
  [ "$(grep -c 'contents/' "$MOCKLOG")" = "1" ]
  grep -q 'repos/some-user/repo/contents/.github/workflows/board-sync.yml' "$MOCKLOG"
  run ! grep -q 'board-nightly-sync' "$MOCKLOG"
  run ! grep -q 'board-automation.yml' "$MOCKLOG"
}

@test "emitted callers point at the platform repo and pin v1" {
  mock_gh_full
  run_setup --owner some-user --project-number 1 --repos some-user/repo --individual-mode reference
  local put_line
  put_line=$(grep 'contents/.github/workflows/board-sync.yml' "$MOCKLOG" | tail -1)
  local b64
  b64=$(printf '%s' "$put_line" | sed 's/.*-f content=//')
  local decoded
  decoded=$(printf '%s' "$b64" | base64 -d)
  [[ "$decoded" == *'stbensonimoh/github-board-automation/.github/workflows/board-automation.yml@v1'* ]]
}

@test "a live run without token expiry fails fast before any write" {
  mock_gh_full
  run bash -c "printf '%s' '$TOKEN' | bash '$SETUP' --owner some-user --project-number 1 --repos some-user/repo --individual-mode copy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--token-expiry"* ]]
  run ! grep -q 'secret set' "$MOCKLOG"
}

@test "a dry run without token expiry passes and places nothing" {
  mock_gh_full
  run bash -c "printf '%s' '$TOKEN' | bash '$SETUP' --owner some-user --project-number 1 --repos some-user/repo --individual-mode copy --dry-run"
  [ "$status" -eq 0 ]
  run ! grep -q 'secret set' "$MOCKLOG"
  run ! grep -q 'contents/' "$MOCKLOG"
}

@test "a gh auth without the workflow scope fails with the remedy" {
  mock_gh_full
  export GH_SCOPES="repo, project, read:org"  # no workflow scope
  run_setup --owner some-user --project-number 1 --repos some-user/repo --individual-mode copy
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh auth refresh -s workflow"* ]]
}

@test "individual mode is required for user owners" {
  mock_gh_full
  run bash -c "printf '%s' '$TOKEN' | bash '$SETUP' --owner some-user --project-number 1 --repos some-user/repo --token-expiry 2027-03-01"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--individual-mode"* ]]
}
