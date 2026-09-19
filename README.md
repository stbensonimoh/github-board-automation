# github-board-automation
Reusable GitHub Project board automation with 1-minute install for any user or org board

## Development

Install `bats` locally with `brew install bats-core`; the two lint gates run in Docker, so no local install is needed. Run all three before opening a PR:

```bash
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb --severity=warning $(find scripts tests -name '*.sh' -type f)
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
bats tests/
```

Images are pinned by digest so local runs match CI exactly. The first command exits 3 with a "No files specified." usage message while the scaffold has no shell files; that is expected until #4 lands. CI runs the same three checks on every PR. See `SPEC.md` for the full spec.
