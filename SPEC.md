# Spec: github-board-automation

## Objective

Turn the working RipplED board state machine into a reusable public project any GitHub user or org can install in about 1 minute.

Current state (source of truth in local `board-automation/` folder, built 2026-09-06 for `rippledcyeorg`):

* `board-automation.yml` holds all transition logic as a reusable workflow
* `board-sync.yml` is a thin per repo caller using `pull_request_target`
* `board-nightly-sync.yml` is a daily safety net that backfills missed items and blank statuses
* `README.md` documents manual setup for a new org or personal board

State machine to preserve:

| Event | Result |
| --- | --- |
| Issue opened | Add to board as Backlog |
| Issue reopened | Todo |
| PR opened or reopened | PR plus same repo close keyword issues (`Closes`, `Fixes`, `Resolves`, case insensitive) become In Progress |
| Review requested | PR plus linked issues become In Review |
| Review submitted with changes requested | PR plus linked issues return to In Progress |
| PR closed without merge | Linked issues return to Todo unless another open PR in the same repo still closes them |
| PR merged | No action. Merge closes issues and the board native Item closed workflow moves cards to Done |

Manual by design: Backlog to Todo triage and Blocked stay human actions.

Target users:

1. Individual with one private or public repo plus a user owned ProjectV2 board
2. Org with many repos plus an org owned ProjectV2 board

Success for v1: a stranger can go from project number plus repo list to working automation with one setup command plus one merged caller file, without hand editing GraphQL ids.

## Tech Stack

* GitHub Actions: reusable workflow (`workflow_call`) plus one Marketplace composite action wrapper around the same logic
* GitHub GraphQL ProjectsV2 API via `gh api graphql`
* Setup: POSIX shell plus `gh` CLI plus `jq`
* No npm package. The runtime is YAML plus shell. Npm would only distribute a scaffolder, which adds friction without value.
* GitHub App is explicitly deferred past v1. It gives zero file install but needs webhook hosting and review. Revisit only after the Action sees adoption.

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

Dev loop: use a throwaway test board (project number 99 or similar) plus a test repo. Never develop against a production board.

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

Caller stays thin on purpose. Logic edits happen once in `board-automation.yml` and ship via tag bump (`v1`, `v1.1`).

## Code Style

Bash is strict mode everywhere. No secrets echoed. Ids are resolved, never hardcoded.

```bash
set -euo pipefail

# resolve Status field and option ids by name at runtime
STATUS_FIELD="$(printf '%s' "$FIELDS" | jq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id')"
opt_id() {
  printf '%s' "$FIELDS" | jq -r --arg n "$1" '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $n) | .id'
}
```

Conventions:

* `workflow_call` inputs use snake case (`event_name`, `review_state`)
* Env names use upper snake case (`BOARD`, `REPO`, `NUMBER`)
* GraphQL mutations use inline literals for ids, keep `-f` variables for user supplied values only (avoids the known `Type mismatch on variable $o` failure)
* Close keyword grep stays case insensitive: `grep -oEi '(closes?|closed|fix(es|ed)?|resolves?|resolved)[[:space:]]+#[0-9]+'`
* `pull_request_target` for fork safety. Job never checks out code, only calls the API with event data.
* One `concurrency` group per repo plus number: `board-sync-${{ inputs.repository }}-${{ inputs.number }}`, `cancel-in-progress: false`

## Testing Strategy

No unit test framework for YAML. Strategy is lint plus script tests plus live E2E on a test board.

* `shellcheck` on all shell, `actionlint` on all workflows, `bats` on `setup.sh` option parsing, id resolution, and dry run output
* Fixture tests for `linked()` parsing: `Closes #12`, `fixes #3`, `Resolves #44`, bare `#7` must not match, cross repo `owner/repo#9` must not match
* Live E2E on throwaway board and repo, mirroring the old README first run test:
  1. Open test issue, expect Backlog within about a minute
  2. Open test PR with `Closes #N`, expect PR plus issue In Progress
  3. Request review, expect In Review
  4. Request changes, expect In Progress
  5. Close PR unmerged, expect issue Todo
  6. Reopen and merge path, expect Done via Item closed workflow
* Nightly sync test: delete one board item, blank one Status, run `workflow_dispatch`, expect readded with correct default (Backlog for issues, In Progress for PRs) and no overwrite of existing statuses
* Matrix: user owned board with private repo, user owned board with public repo, org owned board with multiple repos

## Boundaries

Always:

* Resolve `Status` field id and option ids at runtime by name
* Preserve existing option ids, names, and colors when ensuring `Backlog` and `In Review` during setup
* Use fully qualified `owner/repo` in repo lists and API paths
* Paginate board items and open PRs past 100
* Run `shellcheck`, `actionlint`, and `bats` before opening a PR
* Test against a throwaway board first

Ask first:

* Changing the state machine transitions
* Adding a dependency or a new required secret or var
* Changing CI, release tags, or Marketplace metadata
* Switching token strategy from fine grained PAT to GitHub App tokens

Never:

* Commit tokens, PATs, or board ids that grant write access. Field and option ids are constants and may live in logs, tokens never do.
* Hardcode `PVT_`, `PVTSSF_`, or option ids for a specific board
* Mutate the `Status` field definition inside the per event sync path. Field ensure belongs in setup only.
* Commit directly to `main`. Work on `type/short-description` branches and ship via reviewed PR.
* Use `@main` in documented `uses:` lines. Document versioned tags only.
* Deploy anything except merged `main` after explicit approval.

## Success Criteria

* Fresh personal board plus one repo: one setup command plus one merged caller file yields first card in Backlog in under 60 seconds of user active time (Actions run time excluded)
* Fresh org board plus three repos: same flow using org secrets and vars, no per repo secret setup
* Zero hand edits of GraphQL ids for either path
* Setup is idempotent: rerun adds missing `Backlog` and `In Review` options without clearing existing assignments and without duplicating options
* All seven transition rows verified on a test board with logs attached to the PR
* Nightly sync readds a removed open issue and fills a blank Status without changing any existing Status
* Private repo plus user board works with a PAT scoped to that repo plus Projects write. 403 and 404 paths are documented with fixes.
* Marketplace listing installs via a 10 line caller pinned to `v1`

## Open Questions

1. Token for v1: fine grained PAT documented with expiry, or `actions/create-github-app-token` from a pre registered app? Default is PAT for simplicity.
2. Custom Status names in v1 or fixed five (`Backlog`, `Todo`, `In Progress`, `In Review`, `Done`)? Default is fixed five with inputs reserved for later.
3. `Done` handling: keep relying on native Item closed workflow, or set Done explicitly on merge close? Default is keep native behavior and document it.
4. Setup distribution: standalone `scripts/setup.sh` only, or also `gh extension` wrapper? Default is script first.
5. Repo lists over 100 repos: file input, `vars.BOARD_REPOS`, or org wide auto discovery? Default is `vars.BOARD_REPOS` with pagination.

## Assumptions

1. Board layout is ProjectV2 with a single select field named `Status`
2. Close keyword linking stays same repo only for v1
3. `GITHUB_TOKEN` alone is insufficient because it lacks Projects write scope, so a PAT or App token is required
4. Public repo is required for Marketplace and public `uses:` reuse
