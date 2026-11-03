# Release process (maintainers)

> Language: [English](releasing.en.md) | [中文](releasing.md)

## Release steps

1. Change the script → bump `VERSION` (the single line inside `container-autoupdate.sh`).
2. Check locally: `sh -n container-autoupdate.sh`, `python3 scripts/check-docs.py .`, `sh container-autoupdate.sh --version`.
3. Commit and push to `main` → GitHub Actions tags `v$VERSION` and publishes the Release.
4. The workflow is idempotent: an existing tag or Release is skipped.

Changing the script without bumping `VERSION` means `releases/latest/download/` keeps serving the old code.

## Assets

Two assets are uploaded by the workflow:

| Asset | Purpose |
|---|---|
| `container-autoupdate.sh` | The script — the only thing you need |
| `ct-stale-lock-check.sh` | Read-only inspection tool |

The workflow contains a `test ! -e ct-bootstrap.sh` guard: there is no bootstrapper since v3.0.0, so the file reappearing fails the build.

## After releasing

The three sha256 values must match: the local file, `git show HEAD:container-autoupdate.sh`, and the online `releases/latest/download/container-autoupdate.sh`. Then run `sh <downloaded file> --version` to confirm the version.
