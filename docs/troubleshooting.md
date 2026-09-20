# Troubleshooting

## 403 on the GraphQL calls

The token lacks Projects write access. Org boards: the fine grained PAT needs
Organization Projects read and write. User boards: fine grained PATs cannot
access projects owned by a user account at all; use a classic PAT with
`project` and `repo` scopes.

## 404 "Could not resolve to a node"

The token cannot see that owner, project, or issue. Causes: the resource
owner is wrong (a user board queried as an org board or the reverse), the
project number belongs to a different owner, or repository access does not
include the repo. Recreate the token with the right resource owner and
repository access.

## Linked issues never move

Close keyword matching. Only `close`, `closes`, `closed`, `fix`, `fixes`,
`fixed`, `resolve`, `resolves`, `resolved` followed by `#N` count, and only
in the same repo. `closes#1` without a space, `closing #10`, `fixes
owner/repo#9` (cross repo), and a bare `#7` mention never match. Colon forms
like `Fixes: #12` do match.

## Type mismatch on variable $o

GraphQL ids were passed as `-f` variables instead of inline literals in a
mutation. Keep ids inline; `-f` is for user supplied values only.

## Runs do not appear at all

The caller file is missing, its `uses:` line points at the wrong owner, repo,
or ref, or the secrets are missing in that repo. The caller must be at
`.github/workflows/board-sync.yml` with both
`PROJECT_AUTOMATION_TOKEN` and `PROJECT_BOARD_ID` mapped (org installs inherit
org secrets; individual installs need repo secrets).

## The merged card sticks in Todo

The native Item closed workflow is disabled. Setup stops the install and
places no secrets until you enable it in the project settings, then rerun
setup. GitHub provides no API to enable built in workflows.

## setup says rejecting 'x': repos must be fully qualified OWNER/REPO slugs

The `--repos` list contained a bare repo name or a malformed slug. Every entry
must be `owner/repo` with exactly one slash, letters, digits, dots,
underscores, or hyphens.

## setup says --token-expiry is required for live runs

Setup never places a token without an expiry: add `--token-expiry YYYY-MM-DD`.
Use `--dry-run` to preview without one.
