# Spec: github-board-automation

Conformance language: The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Objective

Turn the working RipplED board state machine into a reusable public project any GitHub user or org can install quickly.

Current state (source of truth in local `board-automation/` folder, built 2026-09-06 for `rippledcyeorg`):

* `board-automation.yml` holds all transition logic as a reusable workflow
* `board-sync.yml` is a thin per repo caller using `pull_request_target` for pull request events and `pull_request_review` for review events
* `board-nightly-sync.yml` is a daily safety net that backfills missed items and blank statuses
* `README.md` documents manual setup for a new org or personal board

Scope note: the local `board-automation/` folder is reference v0. It is not REQUIRED to conform to this SPEC. Conformance applies to new code built in this repo from the task list onward.

State machine to preserve. Implementations MUST implement all rows. The close keyword set is fixed and normative: `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`, each preceded by a leading boundary and followed by an optional colon then one or more whitespace characters then `#[0-9]+`, case insensitive, same repo only:

| Event | Result |
| --- | --- |
| Issue opened | Add to board as Backlog |
| Issue reopened | Todo |
| PR opened | PR plus linked issues become In Progress |
| PR reopened | PR plus linked issues become In Progress |
| Review requested | PR plus linked issues become In Review |
| Review submitted with changes requested | PR plus linked issues return to In Progress |
| Review submitted with any other state (approved, commented) | No-op. The workflow MUST ignore it and MUST NOT change any Status |
| PR closed without merge | Linked issues that are still open return to Todo unless another open PR in the same repo still closes them; already closed issues keep their card |
| PR merged | No action. Merge closes issues and the board native Item closed workflow moves cards to Done |

Backlog to Todo triage MUST remain a manual human action. Blocked is not a Status option in v1; teams SHOULD track it with a label as a convention. Code MUST NOT treat Blocked as a board Status value.

Target users:

1. Individual with one private or public repo plus a user owned ProjectV2 board
2. Org with many repos plus an org owned ProjectV2 board

Success for v1: a stranger MUST be able to go from project number plus repo list to working automation with one setup command plus merged caller files, without hand editing GraphQL ids.

Install timing target: the setup script SHOULD complete in under 60 seconds measured from process start to process exit on an Ubuntu runner with network access, excluding time waiting for the user to paste a token. The first card MUST appear on the board within 90 seconds measured from the first workflow step start to the card visible via the API. Runner queue time before the first step starts is explicitly out of scope.

Artifact set and placement. Setup MUST emit exactly these installed workflow files and MUST NOT require any other installed file copies:

* Org path: `board-automation.yml` lives once in the platform repo at `.github/workflows/board-automation.yml` plus `scripts/parse-linked.sh` and `scripts/board-lib.sh` at the same tag. The platform repo is this public repo for individual and small org installs, or the org own infra repo copy for large orgs that vendor it. Every participating repo gets `board-sync.yml` at `.github/workflows/board-sync.yml` pointing at the chosen platform repo tag. One repo additionally gets the nightly workflow. Secrets and vars are set once at org scope.
* Individual mode A same repo copy: setup copies `board-automation.yml` to `.github/workflows/board-automation.yml` plus both helper scripts to `scripts/` in the single repo, and the caller uses `uses: ./.github/workflows/board-automation.yml`. Mode A MAY check out the caller repo base branch solely to read its local helper scripts; it MUST NOT check out the PR head or execute any code from it. Individual mode A gets the nightly workflow in the same repo reading the `BOARD_REPOS` repo variable, which setup MUST set to the single `owner/repo` slug.
* Individual mode B tag reference: only the caller is copied, pinned to `v1` per the tag policy below, and helpers are fetched from the immutable tag at runtime. Individual mode B MUST NOT install a nightly in v1; the nightly REQUIREMENT is scoped to org installs and mode A only.

Setup auth rule: all setup write operations MUST use the invoking user's `gh` auth, never `PROJECT_AUTOMATION_TOKEN`. For classic PATs that auth MUST have `repo` plus `project` plus `workflow` plus `admin:org` for org secret and variable writes. For fine grained PATs it MUST have contents read and write plus secrets read and write plus variables read and write plus Projects read and write plus Workflows read and write plus Pull requests read and write on every target repo, plus secrets and variables read and write at org scope for org installs. Fine grained Projects access is org only. `PROJECT_AUTOMATION_TOKEN` is runtime only and MUST NOT be used for setup writes. Setup MAY open caller files as PRs for the user to merge instead of pushing directly, which requires the Pull requests permission above.

## Tech Stack

* GitHub Actions reusable workflow (`workflow_call`) as the single distribution path for v1. The event to status mapping MUST live in `board-automation.yml` only, with the parser and mechanical helper exemptions defined below.
* GitHub GraphQL ProjectsV2 API via `gh api graphql`.
* Setup: POSIX shell plus `gh` CLI plus `jq`.
* Implementations MUST NOT use an npm package for the runtime. The runtime is YAML plus shell.
* Implementations MUST NOT introduce a Marketplace composite action wrapper around the sync logic in v1. A composite action cannot invoke a reusable workflow, so such a wrapper would duplicate transition logic and violate the single home rule. Marketplace listing is deferred to post v1. An `action.yml` in v1, if present, MUST be setup only and MUST NOT contain transition logic.
* Implementations MUST NOT introduce GitHub App webhook hosting or App tokens in v1. App webhook hosting needs a server, request handling, and installation storage, and installation tokens expire after about one hour, so a stored App token silently dies after install. App support including in workflow minting is post v1. v1 is PAT only.

## Secrets

The reusable workflow has exactly two REQUIRED secrets:

* `PROJECT_AUTOMATION_TOKEN`: for org owned boards a fine grained PAT with Organization Projects read and write plus read access to every participating repo. For user owned boards a classic PAT with `project` plus `repo` scopes is REQUIRED because fine grained PATs cannot access user level ProjectsV2. Setup MUST accept `--token-expiry YYYY-MM-DD`, which is REQUIRED for live runs and OPTIONAL for `--dry-run`. Setup MUST print the expiry date plus an instruction to add a calendar reminder before that date. Code MUST NOT echo the token.
* `PROJECT_BOARD_ID`: the opaque ProjectV2 node id starting with `PVT_`. Setup MUST resolve it from owner plus project number and store it. Users MUST NOT hand look it up.

Scope rule: org installs MUST set both values as org secrets so participating repos inherit them with zero per repo secret work, and MUST set the repo list as the `BOARD_REPOS` org variable. Individual installs MUST set both values as repo secrets in the single repo. Setup MUST print the `--token-expiry` date it was given plus an instruction to add a calendar reminder before that date, and the install docs MUST repeat that instruction. A PAT live run without `--token-expiry` MUST fail fast. `PROJECT_BOARD_ID` is the only board derived value that MAY be stored. Field ids starting with `PVTSSF_` or `PVTF_` and single select option ids MUST NOT be stored, configured, or documented as setup outputs. They MAY appear transiently in debug logs as runtime values but MUST NOT be treated as configuration.

## Commands

```bash
# scaffold and setup
./scripts/setup.sh --help
./scripts/setup.sh --owner stbensonimoh --project-number 1 --repos stbensonimoh/my-repo --token-expiry 2027-03-01

# lint
shellcheck scripts/setup.sh
actionlint .github/workflows/*.yml

# test setup script
bats tests/setup.bats

# dry run setup against a test board
./scripts/setup.sh --owner TEST-OWNER --project-number 99 --repos TEST-OWNER/test-repo --dry-run

# E2E checks after install (caller template declares workflow_dispatch with manual inputs)
gh workflow run "Board sync" --repo OWNER/REPO -f event_name=pull_request_target -f action=opened -f number=1 -f node_id=PR_kwXXX
gh workflow run "Board nightly sync" --repo OWNER/REPO
gh issue create --repo OWNER/REPO --title "board test" --body "test"
```

Setup MUST document how to obtain `node_id` for manual runs via `gh api repos/OWNER/REPO/issues/NUMBER --jq .node_id`. The `workflow_dispatch` `node_id` input MUST be marked `required: true`. The reusable workflow MUST include a first guard step that exits non-zero with a clear message when `node_id` is empty, because a `workflow_call` REQUIRED input does not fail on an empty expression value. A dispatch run without `node_id` MUST fail fast with that message.

The caller template MUST declare event triggers `issues: types: [opened, reopened]`, `pull_request_target: types: [opened, reopened, closed, review_requested]`, and `pull_request_review: types: [submitted]`, plus `workflow_dispatch` with manual inputs `event_name`, `action`, `number`, `node_id`, and `review_state`. It MUST map each input with an explicit fallback: `event_name: ${{ inputs.event_name || github.event_name }}`, `action: ${{ inputs.action || github.event.action }}`, `number: ${{ inputs.number || github.event.issue.number || github.event.pull_request.number }}`, `node_id: ${{ inputs.node_id || github.event.issue.node_id || github.event.pull_request.node_id }}`, `review_state: ${{ inputs.review_state || github.event.review.state }}`. The caller MUST pass `PROJECT_AUTOMATION_TOKEN` and `PROJECT_BOARD_ID` explicitly under the `uses:` job, except that same-org callers MAY use `secrets: inherit` instead; individual and cross owner callers MUST map both explicitly. The nightly template MUST declare `schedule: - cron: '0 6 * * *'` plus `workflow_dispatch`. The caller MUST fit in at most 40 lines including the secrets mapping; the guard step lives in the reusable workflow, not the caller.

Dev loop: developers MUST use a throwaway test board (project number 99 or similar) plus a test repo. Developers MUST NOT develop against a production board.

## Project Structure

```text
SPEC.md                          -> this file, living source of truth
README.md                        -> quickstart plus org and individual paths
.github/workflows/
  board-automation.yml           -> reusable workflow, all transition logic lives here only
  ci.yml                         -> lint and test gates
templates/
  board-sync.yml                 -> caller template users copy, declares workflow_dispatch with manual inputs
  board-nightly-sync.yml         -> safety net template, reads vars.BOARD_REPOS, no hardcoded repos
NOTE: templates MUST live outside .github/workflows/ because GitHub runs
every file in that directory; a template there fires on real events and
fails on the not yet existing v1 tag. Setup copies them into place.
scripts/
  setup.sh                       -> installer: lookup ids, ensure options, check Item-closed workflow, set secrets and vars, emit caller
  parse-linked.sh                -> pure close keyword parser taking PR body on stdin or as argument, no network calls
  board-lib.sh                   -> shared helpers: paginated items query, add item, set Status; sourced by both sync and nightly paths
tests/
  setup.bats                     -> setup script unit tests
  parse.bats                     -> close keyword parser unit tests calling scripts/parse-linked.sh with PR body fixtures
  fixtures/                      -> sample GraphQL responses for Status field and options
docs/
  install-org.md                 -> org path with org secrets
  install-individual.md          -> personal path with repo secrets
  troubleshooting.md             -> 403, 404, missed links, stale status
```

There is no `action.yml` sync wrapper in v1. The caller MUST stay thin. The event to status mapping MUST live in `board-automation.yml` only, with two explicit exemptions: the pure keyword parser in `scripts/parse-linked.sh` is shared parsing help, and the mechanical API helpers in `scripts/board-lib.sh` (paginated items query, add item, set Status) MAY be sourced by both the sync path and the nightly path. Helper files MUST NOT define status transitions. Setup MUST copy each template that applies to the chosen mode from `templates/` to its deployed path: `templates/board-sync.yml` becomes `.github/workflows/board-sync.yml` and, where the mode includes a nightly, `templates/board-nightly-sync.yml` becomes `.github/workflows/board-nightly-sync.yml`. Mode B has no nightly in v1. The exact files rule in Success Criteria applies to installed workflow files only, not to tests and docs.

Release tag policy: minor tags such as `v1.1.0` are immutable once pushed. The major tag `v1` moves to the latest `v1.x.y` on every release. Release steps SHALL: update the helper fetch ref in `board-automation.yml` to the new immutable `v1.x.y`, tag the minor, move the major tag to the same commit, push both. Documented `uses:` lines SHALL reference the moving major tag `v1`. Helper fetch lines SHALL reference the immutable `v1.x.y` tag. A commit SHA MAY be used only when it is the SHA of a prior commit that already contains the helper scripts, never the SHA of the commit being created. They MUST NOT reference `@main`.

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
* The close keyword matcher MUST be case insensitive over the exact set `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`, each preceded by a leading boundary `(^|[^[:alnum:]_])` and followed by an optional colon `:?` (GitHub documents the `Closes: #10` form) then one or more whitespace characters then `#[0-9]+` for containment: `LC_ALL=C.UTF-8 grep -oEi '(^|[^[:alnum:]_])(closes?|closed|fix(es|ed)?|resolves?|resolved):?[[:space:]]+#[0-9]+'`. The locale is pinned so the non ASCII boundary behaves identically everywhere. The trailing terminator is intentionally omitted because `[0-9]+` is greedy and consuming the separator drops a second reference on the same line. For extraction the parser MUST then recover digits only, for example piping through `grep -oE '[0-9]+'`.
* The keyword parser MUST live in `scripts/parse-linked.sh`, MUST take the PR body as an input argument or stdin, and MUST perform zero network calls so it is unit testable. Both the reusable workflow and `tests/parse.bats` MUST call that file. Workflows MAY fetch these trusted helper scripts from the platform repo at the immutable `v1.x.y` tag or commit SHA without checking out the triggering repo. Workflows MUST NOT check out the triggering repo code; they SHALL only call the API with event data. Checking out the trusted platform repo at an immutable tag for helpers only is allowed because it never executes untrusted PR code.
* Pull request activity including review requests MUST use `pull_request_target` for fork safety with explicit types `types: [opened, reopened, closed, review_requested]`. Submitted reviews MUST use `pull_request_review` with `types: [submitted]` because that event only fires there. Issue events MUST declare `issues: types: [opened, reopened]`. No path MUST check out the PR head or any untrusted ref; paths SHALL only call the API with event data. The exceptions are fetching trusted helper scripts from the platform repo at an immutable tag, and mode A reading its local helper scripts from the caller repo base branch only.
* Both the sync workflow and the nightly workflow MUST use one shared concurrency group per repo: `board-${{ github.repository }}` with `cancel-in-progress: false`. The `repository` value MUST come from the `github` context. GitHub serializes the two workflows on the same repo through this shared group. Nightly MUST additionally re-read each item's Status immediately before writing, MUST write only when the item is missing or still blank, and MUST NOT touch any item that already has a Status value.

## Testing Strategy

The strategy is lint plus script tests plus live E2E on a test board. The following are REQUIRED:

* `shellcheck` on all shell, `actionlint` on all workflows, and `bats` on `setup.sh` option parsing, id resolution, and dry run output MUST all pass before a PR is opened.
* Fixture tests for keyword parsing MUST verify every form in the normative set: `close #1`, `closes #12`, `closed #13`, `fix #2`, `fixes #3`, `fixed #4`, `resolve #5`, `resolves #44`, `Resolved #45`, plus case variants such as `CLOSES #6` and the GitHub documented colon forms such as `Fixes: #12`, plus multiple references on one line such as `closes #1 fixes #2 resolves #3` yielding one number per line in order. Bare `#7` MUST NOT match. `closes#1` MUST NOT match. `closes owner/repo#9` MUST NOT match. `fixes owner/repo#9 #12` MUST NOT match: the keyword is consumed by the cross repo ref, and the trailing bare `#12` is a mention, not a close ref. `closing #10` MUST NOT match. `prefix #7` MUST NOT match. `unfixed #4` MUST NOT match. No match cases MUST exit zero so a body without close refs never fails the workflow step.
* Live E2E on a throwaway board and repo MUST verify these eight checks in order, mirroring the old README first run test:
  1. Open test issue, expect Backlog within 90 seconds
  2. Reopen a closed test issue, expect Todo
  3. Open test PR A with `Closes #N`, expect PR plus issue In Progress
  4. Open test PR B closing the same issue, then close PR A unmerged, expect issue stays In Progress while PR B still closes it
  5. Request review on PR B, expect PR plus issue In Review
  6. Submit changes requested on PR B, expect PR plus issue In Progress
  7. Close PR B unmerged with no other open PR closing the issue, expect issue Todo
  8. Reopen PR B, assert the PR and linked issues return to In Progress, then merge it, expect the linked issue closed and its card Done via the native Item closed workflow
* Nightly sync test MUST verify: after deleting one board item and blanking one Status, a `workflow_dispatch` run readds the item with the correct default (Backlog for issues, In Progress for PRs) and MUST NOT change any existing Status. Precedence rule: nightly backfill MUST NOT infer reopen history. A reopened issue whose card is missing is readded as Backlog; the Todo state applies only to live reopen events.
* Test harness: each E2E run MUST provision a throwaway board with the fixed five options, run setup with `--dry-run` first, then live. Between runs the harness MUST close all test issues and PRs and remove test board items so reruns start clean. Evidence per run MUST be a linked Actions run URL plus a JSON evidence file recording trigger event, item node id, status before, status after, `first_step_started_at`, `card_visible_at`, and `elapsed_seconds`. For the merge to Done check the harness MUST poll the board API for the Done status with a bounded timeout of 60 seconds before capturing evidence, because the native workflow runs asynchronously. A PR claiming E2E success MUST link both. A test that an approved review leaves the Status unchanged is REQUIRED as proof that non `changes_requested` reviews are a no-op.
* The test matrix MUST cover three configurations, each with its own board plus token: user owned board with private repo, user owned board with public repo, and org owned board with multiple repos. The PR evidence MUST show one passing E2E set per configuration.

## Boundaries

Always (contributors MUST do all of the following):

* Implementations MUST resolve the `Status` field id and option ids at runtime by name on every sync run.
* Setup MUST ensure `Backlog` and `In Review` exist via a read modify write using the `updateProjectV2Field` mutation: first query all existing options with id, name, color, and description, verify `Todo`, `In Progress`, and `Done` exist and fail with an actionable message naming any missing one of those three, then append `Backlog` and `In Review` when absent and submit the complete list resubmitted by name, color, and description with every existing option echoed back unchanged. GitHub matches existing options by name, so the queried ids MUST be used only for verification and MUST NOT be sent as submission fields. Setup MUST NOT submit a partial list. A rerun MUST assert existing assignments survive and MUST NOT duplicate options.
* Setup MUST query the board `workflows` connection and verify the native Item closed workflow that moves closed issues to Done is enabled. GitHub provides no API to enable built in workflows, so if it is disabled setup MUST fail with an actionable message telling the user to enable it in the project UI. The install docs MUST include that manual step. The zero hand edit claim covers GraphQL ids only, not this UI toggle.
* Implementations MUST use fully qualified `owner/repo` slugs in repo lists and API paths. The repo list source defaults to the `BOARD_REPOS` var as a space separated list, for example `REPOS="octo-org/api octo-org/web"`. Bare repo names without an owner MUST NOT be accepted.
* Implementations MUST paginate the board items query, the open PRs query, and the per repo open issues query with cursor pagination using `pageInfo { hasNextPage endCursor }`. The nightly MUST consider only open issues so closed items are never readded. The v0 `first: 100` single page behavior is superseded and MUST NOT be treated as a cap.
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
* Documented remote `uses:` lines MUST NOT reference `@main`. They SHALL reference the versioned `v1` tag. Mode A same repo callers using `uses: ./.github/workflows/board-automation.yml` are the explicit exception.
* Changes SHALL reach production only through merged `main` after explicit approval.

## Success Criteria

* Fresh personal board plus one repo: one setup command plus one merged caller file MUST yield the first card in Backlog within 90 seconds measured from first workflow step start, with runner queue time out of scope.
* Fresh org board plus three repos: the same flow using org secrets and vars MUST succeed with no per repo secret setup.
* Both paths MUST need zero hand edits of GraphQL ids. Setup performs all lookups; the user copies no ids.
* Setup MUST be idempotent: reruns SHALL add missing `Backlog` and `In Review` options without clearing existing assignments and without duplicating options. The rerun test MUST assert pre existing card statuses are unchanged.
* All nine state machine rows MUST be verified on a test board: the eight E2E checks plus the approved review no-op test, which is the check for the Review submitted with any other state row. Each matrix configuration MUST link an Actions run URL plus JSON evidence file in the PR.
* Nightly sync MUST readd a removed open issue and fill a blank Status without changing any existing Status. The nightly REQUIREMENT is scoped to org installs and individual mode A; mode B has no nightly in v1.
* Private repo plus user board MUST work with a classic PAT with `project` plus `repo` scopes. The 403 and 404 paths MUST be documented with fixes.
* v1 installation MUST use a caller of at most 40 lines pinned to `v1`. Marketplace listing is explicitly out of scope for v1 success.

## Open Questions

1. Default token for v1: fine grained PAT documented with expiry for org boards, classic PAT with `project` plus `repo` for user boards. App support is post v1.
2. Setup distribution: standalone `scripts/setup.sh` only, or also a `gh` extension wrapper? Default is script first.
3. Repo lists over 100 repos: keep `vars.BOARD_REPOS` with pagination, or add org wide auto discovery? Default is `vars.BOARD_REPOS` with pagination.

## Post v1

* Marketplace listing with a setup only action.
* In workflow App token minting via `actions/create-github-app-token`.
* Custom Status names beyond the fixed five.
* Explicit Done transition instead of native Item closed workflow.
* Org wide repo auto discovery.

## Assumptions

1. Board layout is ProjectV2 with a single select field named `Status`.
2. The fixed five options for v1 are `Backlog`, `Todo`, `In Progress`, `In Review`, and `Done`. Custom names are post v1.
3. `Done` is handled by the native Item closed workflow, which setup checks and the install docs cover as a manual UI step if disabled.
4. Close keyword linking stays same repo only for v1.
5. `GITHUB_TOKEN` alone is insufficient because it lacks Projects write scope, so a PAT is REQUIRED on all boards.
6. Public repo is REQUIRED for public `uses:` reuse.
