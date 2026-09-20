# Setting up on an organization

This guide is for org owners who want one shared project board across several
repos. Setup takes about a minute once you have the pieces below.

## What you need

1. **The terminal tools.** How you install them depends on your computer:
   on a Mac, open Terminal and paste `brew install gh jq`; on Windows use WSL
   or Git Bash (`winget install GitHub.cli`, then jq from
   https://jqlang.github.io/jq/download); on Linux paste
   `sudo apt install gh jq` or `sudo dnf install gh jq`.
2. **Sign in to GitHub from the terminal:** `gh auth login`. Choose
   GitHub.com, HTTPS, and log in with your browser.
3. **A project board** created in your org, with at least the columns Todo,
   In Progress, and Done.
4. **A token.** On github.com click your profile picture, Settings, Developer
   settings (bottom of the sidebar), Personal access tokens, then
   Fine-grained tokens, and Generate new token:
   - Token name: something like board automation
   - Resource owner: your organization
   - Repository access: All repositories (or pick the ones going on the board)
   - Permissions: Organization permissions, set Projects to Read and write.
     Repository permissions: set Contents, Issues, Workflows, Secrets,
     Variables, and Pull requests to Read and write. Also set Issues to
     Read-only. The placed token never writes issues; it only reads them.
   - Expiration: pick a date and write it down
   - Generate the token and copy it (it starts with `github_pat_`)

## Run one command

```bash
printf '%s' "PASTE YOUR TOKEN HERE" | bash scripts/setup.sh \
  --owner YOUR-ORG --project-number BOARD_NUMBER \
  --repos YOUR-ORG/api YOUR-ORG/web YOUR-ORG/docs \
  --token-expiry 2027-06-01
```

Replace the capital letter parts: your org name, the board number, your repo
names, and the token expiry date you picked.

Setup takes care of everything else:

- Figures out your board's internal id (you never copy anything like that)
- Adds the Backlog and In Review columns to the board if they are missing,
  without touching your existing cards
- Checks that the board's built-in "close cards when an issue closes" rule is
  switched on
- Saves your token and board safely as org secrets, so every repo can use them
  and you never have to add them repo by repo
- Adds a small file to each repo that connects it to the board, and a daily
  cleanup job in the first repo

Setup commits those files directly. If your branch settings say no, add the
files by hand: copy `templates/board-sync.yml` from your copy of this repo
into `.github/workflows/` in each repo, and `templates/board-nightly-sync.yml`
into `.github/workflows/` of the first repo. Then open a pull request for
them.

## Test it

1. Open a test issue in one of the repos. Within about a minute, a card
   appears on the board.
2. Open a pull request whose description says `Closes #1` (that is your test
   issue's number). The pull request and the issue move to In Progress.
3. Ask for a review: In Review. Ask for changes: back to In Progress.
4. Close the pull request without merging: the issue goes back to Todo.
5. Merge the pull request: the issue closes and the card moves to Done.

If step 5 leaves the card in Todo, turn on the "Item closed" workflow in the
project's workflow settings, then close and reopen a pull request to test
again.

## Common questions

**Do I run setup once, or for every project?**
Once per project board, and once is enough for all your repos: list them all
in the command and every repo lands on the same board.

**We added repos since we set this up. How do we add them to the board?**
Run the same command again with the repo list expanded. Setup is safe to rerun:
it never duplicates columns, cards, or secrets.

**Do we clone this tool again for a new project?**
No. Open the `github-board-automation` folder in your terminal
(`cd github-board-automation`) and run the same command with the new project
number. If it has been a while, run `git pull` inside the folder first.

**What if we want to stop using it on a repo?**
Delete the `board-sync.yml` file from that repo's `.github/workflows/` folder
and remove the repo from the `BOARD_REPOS` list (run the setup command again
with the shorter list). The board keeps its other repos.

## Plan limitation: free organizations

On GitHub Free, organization secrets are not accessible by private
repositories; GitHub's docs state this directly. Setup handles this
automatically: on a free org with any private repo in the list, it places the
secrets in each repo instead of at org level (the install stays one command;
setup does the per repo work). On a free org with public repos only, the
secrets go to the org level. Orgs on Team or Enterprise always use org level.

`--secret-scope org|repo` overrides the detection: use it to force one
behavior. Forcing org scope on a free org with private repos recreates the
empty secret failure.

## When the token expires

Setup reminds you of the expiry date. Put it in your calendar. When it gets
close, make a new token and run the same command again.

## Something not working?

See docs/troubleshooting.md.
