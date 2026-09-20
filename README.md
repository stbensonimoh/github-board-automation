# github-board-automation

Reusable GitHub Project board automation with a 1 minute install for any user
or org board.

## Quickstart

One setup command plus merged caller files puts any ProjectV2 board to work:
issues land on the board as Backlog, PRs and their linked issues move through
In Progress and In Review, closed without merge they return to Todo, and a
merge hands the card to the board's native Item closed workflow for Done.

```bash
git clone https://github.com/stbensonimoh/github-board-automation.git
cd github-board-automation
printf '%s' "$TOKEN" | bash scripts/setup.sh \
  --owner YOUR-OWNER --project-number BOARD_NUMBER \
  --repos YOUR-OWNER/YOUR-REPO \
  --individual-mode copy --token-expiry YYYY-MM-DD
```

Prerequisites: a clone of this repo (the script reads templates next to
itself), `gh` CLI logged in, `jq` installed, and a token per the guides below.

Which guide to read:

- Own an org with several repos? See docs/install-org.md. Fine grained PAT
  with Organization Projects read and write.
- Personal repo on a personal board? See docs/install-individual.md. A
  classic PAT with `project` and `repo` scopes is required: fine grained PATs
  cannot access user owned projects.
- Something broke? See docs/troubleshooting.md.

## How it works

The board is a state machine:

| Event | Result |
| --- | --- |
| Issue opened | Backlog |
| Issue reopened | Todo |
| PR opened or reopened | PR plus linked issues (same repo close keywords) In Progress |
| Review requested | In Review |
| Review approved or commented | no change (no-op) |
| Changes requested | back to In Progress |
| PR closed unmerged | linked issues back to Todo unless another open PR still closes them |
| PR merged | the issue closes and the board's native Item closed workflow moves the card to Done |

Backlog to Todo triage stays manual. `Closes #N` style keywords link PRs to
issues, same repo only, case insensitive.

## Development

`bats` installs locally with `brew install bats-core`; the two lint gates run
in Docker, so no local install is needed. Run all three before opening a PR:

```bash
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb --severity=warning $(find scripts tests -name '*.sh' -type f)
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color .github/workflows/*.yml templates/*.yml
bats tests/
```

Images are pinned by digest so local runs match CI exactly. CI runs the same
three checks on every PR. `SPEC.md` is the full spec; docs/ carries the
install guides and troubleshooting.
