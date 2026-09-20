# Installing on an organization

Org installs share one ProjectV2 board across every participating repo. All
secrets and the repo list live at org scope, so participating repos need zero
per repo secret work.

## Before you start

1. A clone of this platform repo and a checkout: setup reads templates next to
   itself. `gh` CLI logged in as the invoking user and `jq` installed.
2. A fine grained PAT on your account with:
   - Resource owner: your org
   - Organization permissions: Projects, Secrets, and Variables, all read and
     write (setup places the org secrets and the repo list variable)
   - Repository access: every participating repo with Contents, Issues,
     Workflows, Secrets, Variables, and Pull requests, all read and write
     (the placed token reads issues and PRs at runtime; setup pushes the
     caller files)
   - An expiry date you will actually remember
3. The ProjectV2 board created in the org with the Status field showing at
   least the default `Todo`, `In Progress`, `Done`.
4. The org repos you want on the board, as fully qualified `owner/repo` slugs.

## The one command

```bash
printf '%s' "$FINE_GRAINED_PAT" | bash scripts/setup.sh \
  --owner YOUR-ORG --project-number BOARD_NUMBER \
  --repos YOUR-ORG/api YOUR-ORG/web YOUR-ORG/docs \
  --token-expiry YYYY-MM-DD
```

Setup then:

1. Resolves the board id (no GraphQL ids copied by hand)
2. Appends `Backlog` and `In Review` to the Status field if missing, echoing
   every existing option back unchanged
3. Checks the native Item closed workflow is enabled
4. Places `PROJECT_AUTOMATION_TOKEN` and `PROJECT_BOARD_ID` as org secrets and
   `BOARD_REPOS` as an org variable
5. Opens `board-sync.yml` in every repo in the list and the nightly in the
   first repo, pinned to the platform repo's `v1` tag

The PAT is read from stdin and never echoed.

## After setup

Setup commits the caller files directly. If your default branch rejects direct
commits, add the files setup would have written through a pull request
yourself: from `templates/` in your clone, `board-sync.yml` in every repo and
`board-nightly-sync.yml` in the first repo. Then run the walkthrough test:

1. Open a test issue in one repo: it lands on the board as Backlog
2. Open a PR whose body says `Closes #N` for that issue: the PR and the issue
   move to In Progress
3. Request a review: In Review. Request changes: back to In Progress
4. Close the PR without merging: the issue returns to Todo (unless another
   open PR still closes it)
5. Merge the PR: the issue closes and the native Item closed workflow moves
   the card to Done

If step 5 leaves the card in Todo, enable the Item closed workflow in the
project settings: GitHub provides no API to enable built in workflows.

## The calendar reminder

Setup prints the expiry date you passed with `--token-expiry`. Add a calendar
reminder before that date to rotate the PAT and rerun setup with the new
token.

## Troubleshooting

See docs/troubleshooting.md.
