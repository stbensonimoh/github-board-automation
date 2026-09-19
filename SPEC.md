# Spec: github-board-automation

Conformance language: The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Objective

Turn the working RipplED board state machine into a reusable public project any GitHub user or org can install in about 1 minute.

Current state (source of truth in local `board-automation/` folder, built 2026-09-06 for `rippledcyeorg`):

* `board-automation.yml` holds all transition logic as a reusable workflow
* `board-sync.yml` is a thin per repo caller using `pull_request_target`
* `board-nightly-sync.yml` is a daily safety net that backfills missed items and blank statuses
* `README.md` documents manual setup for a new org or personal board

State machine to preserve. Implementations MUST implement all rows:

| Event | Result |
| --- | --- |
| Issue opened | Add to board as Backlog |
| Issue reopened | Todo |
| PR opened or reopened | PR plus same repo close keyword issues (`Closes`, `Fixes`, `Resolves`, case insensitive) become In Progress |
| Review requested | PR plus linked issues become In Review |
| Review submitted with changes requested | PR plus linked issues return to In Progress |
| PR closed without merge | Linked issues return to Todo unless another open PR in the same repo still closes them |
| PR merged | No action. Merge closes issues and the board native Item closed workflow moves cards to Done |

Backlog to Todo triage and Blocked MUST remain manual human actions.

Target users:

1. Individual with one private or public repo plus a user owned ProjectV2 board
2. Org with many repos plus an org owned ProjectV2 board

Success for v1: a stranger MUST be able to go from project number plus repo list to working automation with one setup command plus one merged caller file, without hand editing GraphQL ids.

## Tech Stack

* GitHub Actions: reusable workflow (`workflow_call`) plus one Marketplace composite action wrapper around the same logic
* GitHub GraphQL ProjectsV2 API via `gh api graphql`
* Setup: POSIX shell plus `gh` CLI plus `jq`
* Implementations MUST NOT use an npm package for the runtime. The runtime is YAML plus shell. An npm wrapper would add friction without value.
* Implementations MUST NOT introduce GitHub App hosting in v1. The App gives zero file install but NEEDS webhook hosting and review. It MAY be revisited only after the Action sees adoption.

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

# E2E checks after install
gh workflow run "Board sync" --repo OWNER/REPO
gh issue create --repo OWNER/REPO --title "board test" --body "test"
```

Dev loop: developers MUST use a throwaway test board (project number 99 or similar) plus a test repo. Developers MUST NOT develop against a production board.

## Project Structure

```text
SPEC.md                          -> this file, living source of truth
README.md                        -> 1 minute quickstart plus org and individual paths
action.yml                       -> Marketplace composite action wrapper (same logic as reusable workflow)
.github/workflows/
  board-automation.yml           -> reusable workflow, all transition logic lives here only
  board-sync-template.yml        -> 10 line caller template users copy
  board-nightly-sync-template.yml -> safety net template with no hardcoded repos
scripts/
  setup.sh                       -> 1 minute installer: lookup ids, ensure options, set secrets and vars, emit caller
tests/
  setup.bats                     -> setup script unit tests
  fixtures/                      -> sample GraphQL responses for Status field and options
docs/
  install-org.md                 -> org path with org secrets
  install-individual.md          -> personal path with repo secrets
  troubleshooting.md             -> 403, 404, missed links, stale status
```

The caller MUST stay thin. All transition logic MUST live in `board-automation.yml` only. Logic changes MUST ship via versioned tag bump (`v1`, `v1.1`). Documented `uses:` lines MUST NOT reference `@main`.

## Code Style

Bash scripts MUST use strict mode everywhere. Code MUST NOT echo secrets. Implementations MUST resolve ids at runtime and MUST NOT hardcode board specific ids.

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
* Close keyword grep MUST stay case insensitive: `grep -oEi '(closes?|closed|fix(es|ed)?|resolves?|resolved)[[:space:]]+#[0-9]+'`
* Jobs MUST use `pull_request_target` for fork safety. Jobs MUST NOT check out code; they SHALL only call the API with event data.
* Workflows MUST define one `concurrency` group per repo plus number: `board-sync-${{ inputs.repository }}-${{ inputs.number }}` with `cancel-in-progress: false`

## Testing Strategy

The strategy is lint plus script tests plus live E2E on a test board. The following are REQUIRED:

* `shellcheck` on all shell, `actionlint` on all workflows, and `bats` on `setup.sh` option parsing, id resolution, and dry run output MUST all pass before a PR is opened.
* Fixture tests for `linked()` parsing MUST verify: `Closes #12`, `fixes #3`, and `Resolves #44` match; bare `#7` MUST NOT match; cross repo `owner/repo#9` MUST NOT match.
* Live E2E on a throwaway board and repo MUST verify, mirroring the old README first run test:
  1. Open test issue, expect Backlog within about a minute
  2. Open test PR with `Closes #N`, expect PR plus issue In Progress
  3. Request review, expect In Review
  4. Request changes, expect In Progress
  5. Close PR unmerged, expect issue Todo
  6. Reopen and merge path, expect Done via Item closed workflow
* Nightly sync test MUST verify: after deleting one board item and blanking one Status, a `workflow_dispatch` run readds the item with the correct default (Backlog for issues, In Progress for PRs) and MUST NOT change any existing Status.
* The test matrix MUST cover: user owned board with private repo, user owned board with public repo, and org owned board with multiple repos.

## Boundaries

Always (MUST):

* Implementations MUST resolve the `Status` field id and option ids at runtime by name.
* Setup MUST preserve existing option ids, names, and colors when ensuring `Backlog` and `In Review`.
* Implementations MUST use fully qualified `owner/repo` in repo lists and API paths.
* Implementations MUST paginate board items and open PRs past 100.
* Contributors MUST run `shellcheck`, `actionlint`, and `bats` before opening a PR.
* Contributors MUST test against a throwaway board first.

Ask first (MUST obtain human approval before):

* Contributors MUST NOT change the state machine transitions without human approval.
* Contributors MUST NOT add a dependency or a new REQUIRED secret or var without human approval.
* Contributors MUST NOT change CI, release tags, or Marketplace metadata without human approval.
* Contributors MUST NOT switch token strategy from fine grained PAT to GitHub App tokens without human approval.

Never (MUST NOT):

* Contributors MUST NOT commit tokens, PATs, or board ids that grant write access. Field and option ids are constants and MAY appear in logs; tokens MUST NOT.
* Implementations MUST NOT hardcode `PVT_`, `PVTSSF_`, or option ids for a specific board.
* Implementations MUST NOT mutate the `Status` field definition inside the per event sync path. Field ensure belongs in setup only.
* Contributors MUST NOT commit directly to `main`. Work SHALL use `type/short-description` branches and ship via reviewed PR.
* Documented `uses:` lines MUST NOT reference `@main`. They SHALL reference versioned tags only.
* Anything MUST NOT reach production except through merged `main` after explicit approval.

## Success Criteria

* Fresh personal board plus one repo: one setup command plus one merged caller file MUST yield the first card in Backlog in under 60 seconds of user active time (Actions run time excluded).
* Fresh org board plus three repos: the same flow using org secrets and vars MUST succeed with no per repo secret setup.
* Both paths MUST REQUIRE zero hand edits of GraphQL ids.
* Setup MUST be idempotent: reruns SHALL add missing `Backlog` and `In Review` options without clearing existing assignments and without duplicating options.
* All seven transition rows MUST be verified on a test board with logs attached to the PR.
* Nightly sync MUST readd a removed open issue and fill a blank Status without changing any existing Status.
* Private repo plus user board MUST work with a PAT scoped to that repo plus Projects write. The 403 and 404 paths MUST be documented with fixes.
* Marketplace listing MUST install via a 10 line caller pinned to `v1`.

## Open Questions

1. Token for v1: fine grained PAT documented with expiry, or `actions/create-github-app-token` from a pre registered app? Default is PAT for simplicity.
2. Custom Status names in v1 or fixed five (`Backlog`, `Todo`, `In Progress`, `In Review`, `Done`)? Default is fixed five with inputs reserved for later.
3. `Done` handling: keep relying on native Item closed workflow, or set Done explicitly on merge close? Default is keep native behavior and document it.
4. Setup distribution: standalone `scripts/setup.sh` only, or also `gh extension` wrapper? Default is script first.
5. Repo lists over 100 repos: file input, `vars.BOARD_REPOS`, or org wide auto discovery? Default is `vars.BOARD_REPOS` with pagination.

## Assumptions

1. Board layout is ProjectV2 with a single select field named `Status`
2. Close keyword linking stays same repo only for v1
3. `GITHUB_TOKEN` alone is insufficient because it lacks Projects write scope, so a PAT or App token is REQUIRED
4. Public repo is REQUIRED for Marketplace and public `uses:` reuse
