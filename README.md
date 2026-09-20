# github-board-automation

Keep your GitHub project board up to date automatically. When your team opens
issues and pull requests, the right card appears in the right column. When
work moves, the card moves. Nobody drags cards by hand.

Setup takes about a minute.

## What it does

| What happens | Where the card goes |
| --- | --- |
| Someone opens an issue | A card appears in Backlog |
| Someone reopens an issue | Back to Todo |
| Someone opens a pull request that fixes an issue | The pull request and the issue move to In Progress |
| Someone asks for a review | In Review |
| A reviewer asks for changes | Back to In Progress |
| Someone approves the review | Nothing changes (that is on purpose) |
| The pull request is closed without merging | The issue goes back to Todo |
| The pull request is merged | The issue closes and the card moves to Done |

Moving an issue from Backlog to Todo stays a human decision: that is triage.

## How to set it up

### Step 1. Install two free tools

Open the Terminal app on your Mac (or the terminal on Linux). Paste these two
commands, one at a time, pressing Enter after each:

```
brew install gh jq
```

If `brew` is not recognized, install Homebrew first by following the
instructions at https://brew.sh (one copy-paste command on that page).

### Step 2. Sign in to GitHub from the terminal

```
gh auth login
```

Answer the questions it asks. Choose GitHub.com, HTTPS, and log in with your
browser.

### Step 3. Get your project board ready

On github.com, go to your profile or organization page, click Projects, and
create a new project (Table or Board view both work). Give it the columns
Backlog, Todo, In Progress, In Review, and Done. New boards start with only
Todo, In Progress, and Done, so add Backlog and In Review by clicking the plus
sign at the right end of the board.

The board's address looks like
`https://github.com/users/YOUR-NAME/projects/3`. That last number (here, 3) is
your **project number**. Write it down.

### Step 4. Get your access token

A token is a long password that lets the automation touch your board.

1. On github.com, click your profile picture, then Settings
2. Scroll to the bottom of the left sidebar and click Developer settings
3. Click Personal access tokens, then Tokens (classic)
4. Click Generate new token (classic)
5. Give it a name like board automation, pick an expiration date
6. Tick the checkboxes called `repo` and `project`
7. Click Generate new token and copy the long token it shows (it starts with
   `ghp_`)

Personal boards need this classic token. (Fine-grained tokens, the newer kind,
cannot touch personal boards. Org boards can use either.)

### Step 5. Download this tool and run one command

```
git clone https://github.com/stbensonimoh/github-board-automation.git
cd github-board-automation
printf '%s' "PASTE YOUR TOKEN HERE" | bash scripts/setup.sh   --owner YOUR-NAME --project-number YOUR-NUMBER   --repos YOUR-NAME/YOUR-REPO   --individual-mode copy --token-expiry 2027-06-01
```

Replace the parts in capital letters: your GitHub name, your project number,
your repo, and a date about six months out (the tool reminds you when the
token expires). Paste your token where it says PASTE YOUR TOKEN HERE.

Running organizations: use docs/install-org.md. Anything else: see
docs/install-individual.md and docs/troubleshooting.md.

### Step 6. Watch it work

Open a test issue in your repo. Within about a minute, a card appears on your
board in Backlog. Open a pull request that says `Closes #1` in its
description, and watch it move.

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

## Questions people ask

- **Does this run once, or for every project?** Once per project board. Each
  board needs its own run of the command.
- **Several repos, one board?** Yes. Orgs list them all in one command.
  Personal accounts: run the command again with the same project number and
  the next repo.
- **Do I clone this tool again for a new project?** No. Open the folder you
  cloned (`cd github-board-automation`) and run the command again with the new
  project number.
- **Want to stop using it on a repo?** Remove the `board-sync.yml` file from
  the repo and delete the two secrets. Both guides cover this at the bottom.

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

## More detail

- docs/install-org.md: the org walkthrough
- docs/install-individual.md: the personal walkthrough, both install styles
- docs/troubleshooting.md: what to do when something fails
