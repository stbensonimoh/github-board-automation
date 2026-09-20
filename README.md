# github-board-automation
Reusable GitHub Project board automation with 1-minute install for any user or org board

## Development

Install `bats` locally with `brew install bats-core`; the two lint gates run in Docker, so no local install is needed. Run all three before opening a PR:

```bash
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb --severity=warning $(find scripts tests -name '*.sh' -type f)
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
bats tests/
```

Images are pinned by digest so local runs match CI exactly. The shellcheck and actionlint gates exit non zero on any violation, and `bats tests/` prints a line per test. See `SPEC.md` for the full spec.
