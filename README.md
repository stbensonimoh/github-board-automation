# github-board-automation
Reusable GitHub Project board automation with 1-minute install for any user or org board

## Development

Install the gates locally with `brew install shellcheck actionlint bats-core`, then run all three before opening a PR:

```bash
shellcheck scripts/*.sh
actionlint .github/workflows/*.yml
bats tests/
```

CI runs the same three checks with pinned tool versions on every PR. See `SPEC.md` for the full spec.
