#!/usr/bin/env bats

# setup.sh part 2: secret and variable placement plus caller emit. The token
# travels by stdin, never in arguments or logs. Org installs place org scope
# secrets and the BOARD_REPOS org variable; individual installs use repo
# scope. The nightly is emitted only where the mode includes one.

SETUP="$BATS_TEST_DIRNAME/../scripts/setup.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
TOKEN="ghp_test_token_never_echo_12345"

setup() {
  export BATS_TEST_TMPDIR
  export MOCKLOG="$BATS_TEST_TMPDIR/mock.log"
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
      *"contents/"*)
        # a PUT marks the path as existing (a marker file, not log grepping);
        # a later GET for a marked path returns the sha, an unmarked one 404s.
        # the marker keys on the path after contents/ so the GET and the PUT
        # of the same file compute the same name
        marker="$BATS_TEST_TMPDIR/put-$(printf '%s' "${rest[*]}" | sed 's|.*contents/||; s| -f .*||' | cksum | cut -d' ' -f1)"
        if printf '%s' "${rest[*]}" | grep -q -- "--method PUT"; then
          mkdir -p "$BATS_TEST_TMPDIR/puts"
          touch "$marker"
          out='{"content":{"path":"emitted"}}'
        elif [ -f "$marker" ]; then
          out='{"sha":"existing_sha_123","content":{}}'
        else
          out='{"message":"Not Found"}'
        fi
        ;;
      *"updateProjectV2Field"* | *"updateProjectV2ItemFieldValue"* | *"addProjectV2ItemById"*)
        out='{"data":{"updateProjectV2Field":{"projectV2Field":{"options":[]}}}}'
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
      *"orgs/"*)
        out=$(cat "$FIXTURES/org-plan-${ORG_PLAN:-free}.json")
        ;;
      *"repos/"*)
        out=$(cat "$FIXTURES/${REPO_VISIBILITY:-repo-private}.json")
        ;;
      *"workflows"*)
        out=$(cat "$FIXTURES/$WF_FIXTURE")
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
    # GH_SCOPES defaults to a token that has the workflow scope. The if form
    # is required: a failing [ ] && assignment list inside a for loop under
    # set -e kills the function (the bash set -e rule) and the mock serves
    # nothing.
    local header_block=""
    for a in "$@"; do
      if [ "$a" = "-i" ]; then
        header_block="x-oauth-scopes: ${GH_SCOPES:-repo, workflow, project}\n\n"
      fi
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
  # a paid org keeps the org scope default; the free plan plus private repos
  # flips to repo scope (the dedicated tests below)
  export ORG_PLAN="team"
  mock_gh_full
  run_setup --owner org-owner --project-number 1 --repos "org-owner/api org-owner/web"
  [ "$status" -eq 0 ]
  grep -q 'secret set PROJECT_AUTOMATION_TOKEN --org org-owner' "$MOCKLOG"
  grep -q 'secret set PROJECT_BOARD_ID --org org-owner' "$MOCKLOG"
  grep -q 'variable set BOARD_REPOS --org org-owner' "$MOCKLOG"
  [ "$(grep -c 'method PUT.*contents/' "$MOCKLOG")" = "3" ]  # 2 callers + 1 nightly (first repo)
  grep -q 'repos/org-owner/api/contents/.github/workflows/board-nightly-sync.yml' "$MOCKLOG"
  [[ "$output" == *"nightly"* ]]
}

@test "the token never appears in logs or output" {
  mock_gh_full
  run_setup --owner some-user --project-number 1 --repos some-user/repo --individual-mode copy
  { echo "STATUS: $status"; printf '%s\n' "$output" | tail -4; } > /tmp/t2-debug.txt
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
  [ "$(grep -c 'method PUT.*contents/' "$MOCKLOG")" = "5" ]
  grep -q 'repos/some-user/repo/contents/.github/workflows/board-nightly-sync.yml' "$MOCKLOG"
}

@test "individual reference mode emits the caller only, pinned to v1, no nightly" {
  mock_gh_full
  run_setup --owner some-user --project-number 1 --repos some-user/repo --individual-mode reference
  [ "$status" -eq 0 ]
  [ "$(grep -c 'method PUT.*contents/' "$MOCKLOG")" = "1" ]
  grep -q 'repos/some-user/repo/contents/.github/workflows/board-sync.yml' "$MOCKLOG"
  run ! grep -q 'board-nightly-sync' "$MOCKLOG"
  run ! grep -q 'board-automation.yml' "$MOCKLOG"
}

@test "put_file sends the sha when updating an existing file" {
  source "$SETUP"
  mock_gh_full
  # first PUT creates (no sha known); the mock answers GETs with 404 until then
  put_file some-user/repo .github/workflows/board-sync.yml "content" "msg"
  local first
  first=$(grep 'method PUT.*board-sync.yml' "$MOCKLOG" | head -1)
  [[ "$first" != *'-f sha='* ]] || { echo "created with a sha?"; return 1; }
  # the file now exists: the second PUT must carry the existing sha
  put_file some-user/repo .github/workflows/board-sync.yml "content2" "msg2"
  local second
  second=$(grep 'method PUT.*board-sync.yml' "$MOCKLOG" | tail -1)
  [[ "$second" == *'-f sha=existing_sha_123'* ]] || { echo "update missing the sha"; return 1; }
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

@test "org with a private repo on the free plan defaults to repo scope secrets" {
  mock_gh_full
  export ORG_PLAN="free" REPO_VISIBILITY="repo-private"
  run_setup --owner org-owner --project-number 1 --repos "org-owner/api" --token-expiry 2027-03-01
  [ "$status" -eq 0 ]
  grep -q 'secret set PROJECT_AUTOMATION_TOKEN --repo org-owner/api' "$MOCKLOG"
  grep -q 'variable set BOARD_REPOS --repo org-owner/api' "$MOCKLOG"
  run ! grep -q -- '--org org-owner' "$MOCKLOG"
}

@test "org with all public repos defaults to org scope secrets" {
  mock_gh_full
  export ORG_PLAN="free" REPO_VISIBILITY="repo-public"
  run_setup --owner org-owner --project-number 1 --repos "org-owner/api" --token-expiry 2027-03-01
  [ "$status" -eq 0 ]
  grep -q 'secret set PROJECT_AUTOMATION_TOKEN --org org-owner --visibility all' "$MOCKLOG"
  run ! grep -q -- '--repo org-owner/api' "$MOCKLOG"
}

@test "org on a paid plan defaults to org scope secrets even with private repos" {
  mock_gh_full
  export ORG_PLAN="team" REPO_VISIBILITY="repo-private"
  run_setup --owner org-owner --project-number 1 --repos "org-owner/api" --token-expiry 2027-03-01
  [ "$status" -eq 0 ]
  grep -q 'secret set PROJECT_AUTOMATION_TOKEN --org org-owner --visibility all' "$MOCKLOG"
  run ! grep -q -- '--repo org-owner/api' "$MOCKLOG"
}

@test "secret scope flag overrides the plan based auto detection" {
  mock_gh_full
  export ORG_PLAN="free" REPO_VISIBILITY="repo-private"
  run_setup --owner org-owner --project-number 1 --repos "org-owner/api" --token-expiry 2027-03-01 --secret-scope org
  [ "$status" -eq 0 ]
  grep -q 'secret set PROJECT_AUTOMATION_TOKEN --org org-owner --visibility all' "$MOCKLOG"
  run ! grep -q -- '--repo org-owner/api' "$MOCKLOG"
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
