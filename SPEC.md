# Spec: github-board-automation

Conformance language: The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Objective

Turn the working RipplED board state machine into a reusable public project any GitHub user or org can install quickly.

Current state (source of truth in local `board-automation/` folder, built 2026-09-06 for `rippledcyeorg`):

* `board-automation.yml` holds all transition logic as a reusable workflow
* `board-sync.yml` is a thin per repo caller using `pull_request_target` for pull request events and `pull_request_review` for review events
* `board-nightly-sync.yml` is a daily safety net that backfills missed items and blank statuses
* `README.md` documents manual setup for a new org or personal board

State machine to preserve. Implementations MUST implement all rows. The close keyword set is fixed and normative: `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`, followed by `#N`, case insensitive, same repo only:

| Event | Result |
| --- | --- |
| Issue opened | Add to board as Backlog |
| Issue reopened | Todo |
| PR opened | PR plus linked issues become In Progress |
| PR reopened | PR plus linked issues become In Progress |
| Review requested | PR plus linked issues become In Review |
| Review submitted with changes requested | PR plus linked issues return to In Progress |
| PR closed without merge | Linked issues return to Todo unless another open PR in the same repo still closes them |
| PR merged | No action. Merge closes issues and the board native Item closed workflow moves cards to Done |

Backlog to Todo triage MUST remain a manual human action. Blocked is not a Status option in v1; teams MUST track it with a label. Code MUST NOT treat Blocked as a board Status value.

Target users:

1. Individual with one private or public repo plus a user owned ProjectV2 board
2. Org with many repos plus an org owned ProjectV2 board

Success for v1: a stranger MUST be able to go from project number plus repo list to working automation with one setup command plus merged caller files, without hand editing GraphQL ids.

Install timing budget: the setup script MUST complete in under 60 seconds on a normal broadband connection excluding time waiting for the user to paste a token. The first card MUST appear on the board within 90 seconds of opening a test issue, measured from the triggering event timestamp to the card visible via the API.

Artifact set and placement. Setup MUST place exactly these files and MUST NOT require any other file copies:

* Org path: `board-automation.yml` lives once in the platform repo at `.github/workflows/board-automation.yml`. Every participating repo gets `board-sync.yml` at `.github/workflows/board-sync.yml` pointing at the platform repo tag. One repo additionally gets the nightly workflow. Secrets and vars are set once at org scope.
* Individual path: the same two files live in the single repo itself, with the caller using a same repo `uses: ./.github/workflows/board-automation.yml` reference or a tag reference to this public repo. Secrets are set at repo scope.

## Tech Stack

* GitHub Actions reusable workflow (`workflow_call`) as the single distribution path for v1. All transition logic MUST live in `board-automation.yml` only.
* GitHub GraphQL ProjectsV2 API via `gh api graphql`.
* Setup: POSIX shell plus `gh` CLI plus `jq`.
* Implementations MUST NOT use an npm package for the runtime. The runtime is YAML plus shell.
* Implementations MUST NOT introduce a Marketplace composite action wrapper around the sync logic in v1. A composite action cannot invoke a reusable workflow, so such a wrapper would duplicate transition logic and violate the single home rule. Marketplace listing is deferred to post v1. An `action.yml` in v1, if present, MUST be setup only and MUST NOT contain transition logic.
* Implementations MUST NOT introduce GitHub App webhook hosting in v1. App webhook hosting needs a server, request handling, and installation storage, so it is out of scope. Minting an App token via `actions/create-github-app-token` needs no webhook hosting and MAY be offered as a token option. The v1 ban applies to hosting only, not to token minting.

## Secrets

The reusable workflow has exactly two REQUIRED secrets:

* `PROJECT_AUTOMATION_TOKEN`: a fine grained PAT with Projects read and write plus read access to every participating repo, or an App token with equivalent scope. Setup MUST document PAT as the default and MUST set an expiry reminder. Code MUST NOT echo the token.
* `PROJECT_BOARD_ID`: the opaque ProjectV2 node id starting with `PVT_`. Setup MUST resolve it from owner plus project number and store it. Users MUST NOT hand look it up.

Scope rule: org installs MUST set both values as org secrets so participating repos inherit them with zero per repo secret work, and MUST set the repo list as the `BOARD_REPOS` org variable. Individual installs MUST set both values as repo secrets in the single repo. `PROJECT_BOARD_ID` is the only board derived value that MAY be stored. Field ids starting with `PVTSSF_` or `PVTF_` and single select option ids MUST NOT be stored, configured, or documented as setup outputs. They MAY appear transiently in debug logs as runtime values but MUST NOT be treated as configuration. Setup MUST print the PAT expiry date it was told and the install docs MUST instruct the user to add a calendar reminder before that date.

## Commands

```bash
# scaffold and setup
./scripts/setup.sh --help
./scripts/setup.sh --owner stbensonimoh --project-number 1 --repos stbensonimoh/my-repo

# lint
shellcheck scripts/setup.sh
actionlint .github/workflows/*.yml

# test setup script
bats tests/setup.bats

# dry run setup against a test board
./scripts/setup.sh --owner TEST-OWNER --project-number 99 --repos TEST-OWNER/test-repo --dry-run

# E2E checks after install (caller template declares workflow_dispatch with manual inputs)
gh workflow run "Board sync" --repo OWNER/REPO -f event_name=pull_request_target -f action=opened -f number=1
gh workflow run "Board nightly sync" --repo OWNER/REPO
gh issue create --repo OWNER/REPO --title "board test" --body "test"
```

The caller template MUST declare `workflow_dispatch` with manual inputs `event_name`, `action`, `number`, and `node_id` in addition to its event triggers, and MUST map each input with `${{ inputs.X || github.event... }}` fallback so a dispatch run supplies the values a push event normally provides. The nightly template MUST declare both `schedule` and `workflow_dispatch`.

Dev loop: developers MUST use a throwaway test board (project number 99 or similar) plus a test repo. Developers MUST NOT develop against a production board.

## Project Structure

```text
SPEC.md                          -> this file, living source of truth
README.md                        -> quickstart plus org and individual paths
.github/workflows/
  board-automation.yml           -> reusable workflow, all transition logic lives here only
  board-sync-template.yml        -> caller template users copy, declares workflow_dispatch with manual inputs
  board-nightly-sync-template.yml -> safety net template, reads vars.BOARD_REPOS, no hardcoded repos
scripts/
  setup.sh                       -> installer: lookup ids, ensure options, check Item-closed workflow, set secrets and vars, emit caller
  parse-linked.sh                -> pure close keyword parser taking PR body on stdin or as argument, no network calls
tests/
  setup.bats                     -> setup script unit tests
  parse.bats                     -> close keyword parser unit tests sourcing scripts/parse-linked.sh with PR body fixtures
  fixtures/                      -> sample GraphQL responses for Status field and options
docs/
  install-org.md                 -> org path with org secrets
  install-individual.md          -> personal path with repo secrets
  troubleshooting.md             -> 403, 404, missed links, stale status
```

There is no `action.yml` sync wrapper in v1. The caller MUST stay thin. All transition logic MUST live in `board-automation.yml` only, with two explicit exemptions: the pure keyword parser in `scripts/parse-linked.sh` is shared parsing help, not transition logic, and the nightly safety net MAY reuse the add item plus set Status helpers with the fixed defaults only and MUST NOT define new transitions.

Release tag policy: minor tags such as `v1.1.0` are immutable once pushed. The major tag `v1` moves to the latest `v1.x.y` on every release. Release steps: tag the minor, move the major tag to the same commit, push both. Documented `uses:` lines SHALL reference the moving major tag `v1`. They MUST NOT reference `@main`.

Example caller reference:

```yaml
uses: stbensonimoh/github-board-automation/.github/workflows/board-automation.yml@v1
```

## Code Style

Bash scripts MUST use strict mode everywhere. Code MUST NOT echo secrets. Implementations MUST resolve field and option ids at runtime by name on every run and MUST NOT read them from stored configuration.

```bash
set -euo pipefail

# resolve Status field and option ids by name at runtime
STATUS_FIELD="$(printf '%s' "$FIELDS" | jq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id')"
opt_id() {
  printf '%s' "$FIELDS" | jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $n) | .id'
}
```

Conventions:

* `workflow_call` inputs MUST use snake case (`event_name`, `review_state`)
* Env names MUST use upper snake case (`BOARD`, `REPO`, `NUMBER`)
* GraphQL mutations MUST use inline literals for ids and MUST keep `-f` variables for user supplied values only. This avoids the known `Type mismatch on variable $o` failure.
* The close keyword matcher MUST be case insensitive over the exact set `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`, each followed by `#[0-9]+` with a non digit terminator `([^0-9]|$)`: `grep -oEi '(closes?|closed|fix(es|ed)?|resolves?|resolved)[[:space:]]+#[0-9]+([^0-9]|$)'`
* The keyword parser MUST live in `scripts/parse-linked.sh`, MUST take the PR body as an input argument or stdin, and MUST perform zero network calls so it is unit testable. Both the reusable workflow and `tests/parse.bats` MUST source or call that file. Implementations MUST NOT require a live API call to test keyword parsing.
* Pull request events MUST use `pull_request_target` for fork safety. Review events MUST use `pull_request_review` because GitHub does not deliver review activity through `pull_request_target`. Both paths MUST NOT check out code; they SHALL only call the API with event data.
* Workflows MUST define one `concurrency` group per repo plus number: `board-sync-${{ inputs.repository }}-${{ inputs.number }}` with `cancel-in-progress: false`

## Testing Strategy

The strategy is lint plus script tests plus live E2E on a test board. The following are REQUIRED:

* `shellcheck` on all shell, `actionlint` on all workflows, and `bats` on `setup.sh` option parsing, id resolution, and dry run output MUST all pass before a PR is opened.
* Fixture tests for keyword parsing MUST verify every form in the normative set: `close #1`, `closes #12`, `closed #13`, `fix #2`, `fixes #3`, `fixed #4`, `resolve #5`, `resolves #44`, `Resolved #45`, plus case variants such as `CLOSES #6`. Bare `#7` MUST NOT match. Cross repo `owner/repo#9` MUST NOT match. `closing #10` MUST NOT match.
* Live E2E on a throwaway board and repo MUST verify these eight checks in order, mirroring the old README first run test:
  1. Open test issue, expect Backlog within 90 seconds
  2. Reopen a closed test issue, expect Todo
  3. Open test PR A with `Closes #N`, expect PR plus issue In Progress
  4. Open test PR B closing the same issue, then close PR A unmerged, expect issue stays In Progress while PR B still closes it
  5. Request review on PR B, expect PR plus issue In Review
  6. Submit changes requested on PR B, expect PR plus issue In Progress
  7. Close PR B unmerged with no other open PR closing the issue, expect issue Todo
  8. Reopen PR B, merge it, expect the linked issue closed and its card Done via the native Item closed workflow
* Nightly sync test MUST verify: after deleting one board item and blanking one Status, a `workflow_dispatch` run readds the item with the correct default (Backlog for issues, In Progress for PRs) and MUST NOT change any existing Status.
* Test harness: each E2E run MUST provision a throwaway board with the fixed five options, run setup with `--dry-run` first, then live. Between runs the harness MUST close all test issues and PRs and remove test board items so reruns start clean. Evidence per run MUST be a linked Actions run URL plus a JSON evidence file recording trigger event, item node id, status before, and status after. A PR claiming E2E success MUST link both.
* The test matrix MUST cover three configurations, each with its own board plus token: user owned board with private repo, user owned board with public repo, and org owned board with multiple repos. The PR evidence MUST show one passing E2E set per configuration.

## Boundaries

Always (contributors MUST do all of the following):

* Implementations MUST resolve the `Status` field id and option ids at runtime by name on every sync run.
* Setup MUST ensure `Backlog` and `In Review` exist via a read modify write using the `updateProjectV2Field` mutation: first query all existing options with id, name, and color, then submit the complete list with every existing option echoed back unchanged plus the missing options appended. Setup MUST NOT submit a partial list. A rerun MUST assert existing assignments survive and MUST NOT duplicate options.
* Setup MUST query the board `workflows` connection and verify the native Item closed workflow that moves closed issues to Done is enabled. GitHub provides no API to enable built in workflows, so if it is disabled setup MUST fail with an actionable message telling the user to enable it in the project UI. The install docs MUST include that manual step. The zero hand edit claim covers GraphQL ids only, not this UI toggle.
* Implementations MUST use fully qualified `owner/repo` slugs in repo lists and API paths. The repo list source defaults to the `BOARD_REPOS` var as a space separated list, for example `REPOS="octo-org/api octo-org/web"`. Bare repo names without an owner MUST NOT be accepted.
* Implementations MUST paginate both the board items query and the open PRs query with cursor pagination using `pageInfo { hasNextPage endCursor }`. The v0 `first: 100` single page behavior is superseded and MUST NOT be treated as a cap.
* Contributors MUST run `shellcheck`, `actionlint`, and `bats` before opening a PR.
* Contributors MUST test against a throwaway board first.

Ask first (contributors MUST obtain human approval before doing any of the following):

* Contributors MUST obtain human approval before changing the state machine transitions.
* Contributors MUST obtain human approval before adding a dependency or a new REQUIRED secret or variable.
* Contributors MUST obtain human approval before changing CI, release tags, or Marketplace metadata.
* Contributors MUST obtain human approval before switching the default token strategy from fine grained PAT to GitHub App token minting.

Never (MUST NOT):

* Contributors MUST NOT commit tokens, PATs, or `PROJECT_BOARD_ID` values. Field and option ids MUST NOT be stored as configuration; they MAY appear transiently in debug logs as runtime values.
* Implementations MUST NOT hardcode `PVT_`, `PVTSSF_`, `PVTF_`, or option ids for a specific board. The single exception is `PROJECT_BOARD_ID`, which MUST be supplied via secrets as defined above.
* Implementations MUST NOT mutate the `Status` field definition inside the per event sync path. Field ensure belongs in setup only.
* Contributors MUST NOT commit directly to `main`. Work SHALL use `type/short-description` branches and ship via reviewed PR.
* Documented `uses:` lines MUST NOT reference `@main`. They SHALL reference the versioned `v1` tag.
* Changes SHALL reach production only through merged `main` after explicit approval.

## Success Criteria

* Fresh personal board plus one repo: one setup command plus one merged caller file MUST yield the first card in Backlog within 90 seconds of opening a test issue.
* Fresh org board plus three repos: the same flow using org secrets and vars MUST succeed with no per repo secret setup.
* Both paths MUST need zero hand edits of GraphQL ids. Setup performs all lookups; the user copies no ids.
* Setup MUST be idempotent: reruns SHALL add missing `Backlog` and `In Review` options without clearing existing assignments and without duplicating options. The rerun test MUST assert pre existing card statuses are unchanged.
* All eight state machine rows MUST be verified by the eight E2E checks on a test board, with an Actions run URL plus JSON evidence file linked in the PR for each matrix configuration.
* Nightly sync MUST readd a removed open issue and fill a blank Status without changing any existing Status.
* Private repo plus user board MUST work with a PAT scoped to that repo plus Projects write. The 403 and 404 paths MUST be documented with fixes.
* v1 installation MUST use a caller of at most 15 lines pinned to `v1`. Marketplace listing is explicitly out of scope for v1 success.

## Open Questions

1. Default token for v1: fine grained PAT documented with expiry, or `actions/create-github-app-token` from a pre registered app with no hosting? Default is PAT for simplicity, with App token minting as an allowed option.
2. Setup distribution: standalone `scripts/setup.sh` only, or also a `gh` extension wrapper? Default is script first.
3. Repo lists over 100 repos: keep `vars.BOARD_REPOS` with pagination, or add org wide auto discovery? Default is `vars.BOARD_REPOS` with pagination.

## Post v1

* Marketplace listing with a setup only action.
* Custom Status names beyond the fixed five.
* Explicit Done transition instead of native Item closed workflow.
* Org wide repo auto discovery.

## Assumptions

1. Board layout is ProjectV2 with a single select field named `Status`.
2. The fixed five options for v1 are `Backlog`, `Todo`, `In Progress`, `In Review`, and `Done`. Custom names are post v1.
3. `Done` is handled by the native Item closed workflow, which setup checks and the install docs cover as a manual UI step if disabled.
4. Close keyword linking stays same repo only for v1.
5. `GITHUB_TOKEN` alone is insufficient because it lacks Projects write scope, so a PAT or App token is REQUIRED.
6. Public repo is REQUIRED for public `uses:` reuse.
