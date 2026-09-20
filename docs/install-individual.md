# Installing for an individual (personal account)

One repo, one user owned ProjectV2 board. Two modes: copy makes the repo self
contained; reference pins everything to this platform repo's tag.

## Before you start

A clone of this platform repo (setup reads templates next to itself), `gh` CLI
logged in as the invoking user, and `jq` installed.

## Token requirements (read this first)

Fine grained PATs cannot access projects owned by a user account; GitHub lists
it as a known gap. A **classic PAT** with `project` and `repo` scopes is
required. Classic tokens can access every repo you can access, so scope the
rest of your usage carefully and set an expiry.

## Mode A: same repo copy (self contained)

Setup copies the reusable workflow, both helper scripts, the caller, and the
nightly into your repo, and places the secrets at repo scope.

```bash
printf '%s' "$CLASSIC_PAT" | bash scripts/setup.sh \
  --owner YOUR-LOGIN --project-number BOARD_NUMBER \
  --repos YOUR-LOGIN/YOUR-REPO \
  --individual-mode copy --token-expiry YYYY-MM-DD
```

After setup your repo contains:

- `.github/workflows/board-automation.yml` (the reusable workflow)
- `.github/workflows/board-sync.yml` (the caller, using `uses: ./...`)
- `.github/workflows/board-nightly-sync.yml` (the daily backfill, reading the
  `BOARD_REPOS` repo variable setup sets for you)
- `scripts/board-lib.sh` and `scripts/parse-linked.sh`

## Mode B: tag reference (thin)

Only the caller is copied, pinned to this platform repo's `v1` tag; helpers
are fetched from the immutable tag at runtime. No nightly in v1.

```bash
printf '%s' "$CLASSIC_PAT" | bash scripts/setup.sh \
  --owner YOUR-LOGIN --project-number BOARD_NUMBER \
  --repos YOUR-LOGIN/YOUR-REPO \
  --individual-mode reference --token-expiry YYYY-MM-DD
```

Private repos work in both modes with the same classic PAT.

## After setup

Same walkthrough as the org guide: open a test issue, open a PR with
`Closes #N`, watch the card move through Backlog, In Progress, In Review, and
Done. If the merged card sticks in Todo, enable the Item closed workflow in
the project settings.

## The calendar reminder

Setup prints the expiry date you passed with `--token-expiry`. Add a calendar
reminder before that date to rotate the classic PAT and rerun setup.
