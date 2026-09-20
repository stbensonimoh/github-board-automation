# Setting up for your personal account

This guide is for one person with one repo and one project board. Setup takes
about a minute once you have the pieces below.

## What you need

1. **The terminal tools.** Open a terminal, then paste:
   ```
   brew install gh jq
   ```
2. **Sign in to GitHub from the terminal:** `gh auth login`. Choose
   GitHub.com, HTTPS, and log in with your browser.
3. **A project board** on your personal account with at least the columns
   Todo, In Progress, and Done.
4. **A classic token.** Important: personal boards only work with the classic
   kind of token. On github.com click your profile picture, Settings,
   Developer settings (bottom of the sidebar), Personal access tokens, then
   **Tokens (classic)**, and Generate new token (classic):
   - Token name: something like board automation
   - Expiration: pick a date and write it down
   - Tick the checkbox called `repo` and the one called `project`
   - Generate the token and copy it (it starts with `ghp_`)

The newer fine-grained tokens cannot reach personal boards; GitHub says so on
their token page. Use the classic kind for this.

## Choose how you want it installed

Setup can set things up two ways. Both work the same once running:

- **Copy (recommended).** Everything the automation needs is copied into your
  repo. Your repo works on its own. A daily tidy-up job keeps the board
  honest. This is the one most people want.
- **Reference.** Only a tiny file is added to your repo, and it points at this
  tool's shared home. Simpler, but no daily tidy-up job.

## Run one command

For the copy way:

```bash
printf '%s' "PASTE YOUR TOKEN HERE" | bash scripts/setup.sh \
  --owner YOUR-NAME --project-number BOARD_NUMBER \
  --repos YOUR-NAME/YOUR-REPO \
  --individual-mode copy --token-expiry 2027-06-01
```

For the reference way, change `copy` to `reference` in the same command.

Replace the capital letter parts: your GitHub name, your project number, your
repo, and the token expiry date you picked.

Setup takes care of everything else:

- Figures out your board's internal id (you never copy anything like that)
- Adds the Backlog and In Review columns to the board if they are missing,
  without touching your existing cards
- Checks that the board's built-in "close cards when an issue closes" rule is
  switched on
- Saves your token and board safely as repo secrets
- Adds a small file to your repo that connects it to the board (and, in copy
  mode, the daily tidy-up job plus the two helper files)

## Test it

1. Open a test issue in your repo. Within about a minute, a card appears on
   the board.
2. Open a pull request whose description says `Closes #1` (that is your test
   issue's number). The pull request and the issue move to In Progress.
3. Ask for a review: In Review. Ask for changes: back to In Progress.
4. Close the pull request without merging: the issue goes back to Todo.
5. Merge the pull request: the issue closes and the card moves to Done.

If step 5 leaves the card in Todo, turn on the "Item closed" workflow in the
project's workflow settings, then close and reopen a pull request to test
again.

## When the token expires

Setup reminds you of the expiry date. Put it in your calendar. When it gets
close, make a new token and run the same command again.

## Common questions

**Do I run setup once, or for every project?**
Once per project board. Each board needs its own run of the command. Your
other boards keep working while you add a new one.

**I want a second project board. Do I clone this tool again?**
No. You only ever clone it once. Open the `github-board-automation` folder in
your terminal again (`cd github-board-automation`) and run the same command
with the new project number. If it has been a while, run `git pull` inside the
folder first to pick up updates.

**What if I have several repos and want them all on one board?**
Personal setups cover one repo per run. Run the command again with the same
project number and the next repo: every repo you connect ends up on the same
board. (Organizations get this in one command; see docs/install-org.md.)

**What if I want to stop using it on a repo?**
Delete the `board-sync.yml` file from the repo's `.github/workflows/` folder
and delete the two secrets from the repo settings. The board itself keeps any
cards it has.

## Something not working?

See docs/troubleshooting.md.
