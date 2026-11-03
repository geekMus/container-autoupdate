# Release process (maintainers)

> Language: [English](releasing.en.md) | [中文](releasing.md)

> For user-facing documentation see [README](../README.en.md). This page only covers **how to publish a new release**.

## In one sentence

Change `VERSION` in the script → commit to `main` → everything else is automatic.

## Step by step

1. Edit `container-autoupdate.sh` and change the version number:

   ```sh
   VERSION="1.2.3"    # change to the new version, e.g. "1.2.4"
   ```

2. Commit and push to `main`:

   ```sh
   git add container-autoupdate.sh
   git commit -m "feat: ..."
   git push origin main
   ```

3. GitHub Actions runs automatically (`.github/workflows/release.yml`):

   | Step | What it does |
   |---|---|
   | Check out the code | `fetch-depth: 0`, so that historical tags are fetched as well |
   | Validate the scripts | `sh -n` syntax check, CRLF line-ending check, and the mode in git must be `100755` (executable) |
   | Read VERSION | Reads `VERSION="x.y.z"` out of the script and checks that it contains digits and dots only |
   | Decide whether a release is needed | If the tag `vx.y.z` already exists, the whole job is skipped (idempotent) |
   | Find the previous release tag | Takes "the largest tag smaller than the current version", comparing the three numeric segments with awk (does not depend on `sort -V`) |
   | Generate the release notes | `scripts/gen-release-notes.sh` → positioning sentence + this release's breaking changes + commit list + download commands + sha256 |
   | Create the tag | Creates the tag `vx.y.z` if it does not exist (annotated, **the message is the release notes**) |
   | Publish the Release | Creates it if it does not exist, uses the release notes as the body, and **uploads both assets**: `container-autoupdate.sh` and `scripts/ct-stale-lock-check.sh` |

   Afterwards, `releases/latest/download/container-autoupdate.sh` and `.../ct-stale-lock-check.sh` both point to the new version.

   > Both assets must be uploaded. Upload only one and the matching `releases/latest/download/...` is a 404.

   > There is no bootstrapper (`ct-bootstrap.sh`) any more as of v3.0.0: the workflow keeps a `test ! -e ct-bootstrap.sh` guard, so the file reappearing in the repository fails the run.

   > The release notes are generated automatically; there is nothing to write by hand. `git show vx.y.z` also shows what changed (the tag message is the release notes).

## Version number rules

Semantic versioning, three numeric segments:

| Scenario | Example |
|---|---|
| Fix bugs, change wording, add logs (does not affect how it is invoked) | `1.2.3` → `1.2.4` |
| Add parameters or capabilities, behavior stays backward compatible | `1.2.4` → `1.3.0` |
| Default behavior changed, users have to adjust their configuration | `1.3.0` → `2.0.0` |

**If this change makes the user's existing invocation invalid** (a renamed parameter, a renamed environment variable, a changed default behavior), two things are required:

1. Register the change in the script's `BREAKING_TABLE` (see the comments inside the script for the format);
2. Bump to the version segment that matches the breaking change, per the table above.

Once it is registered, users running with `latest` get the script to stop on its own and print the migration path (exit code `3`), or to stop hard when they declared a verified range with `--compat`. An unregistered breaking change is completely silent for users — this is the easiest mistake to make.

`VERSION` may contain digits and dots only; otherwise the workflow reports an error and aborts (it never publishes a half-finished release).

## Idempotency

The workflow is idempotent; running it repeatedly causes no problem:

- the tag already exists → skip creating the tag;
- the Release already exists → skip publishing.

So "I only changed the docs and pushed to main as well" does not produce an extra version; only a real change to `VERSION` produces a new tag.

## Branch restrictions

Releases run **only on `main`**:

- the trigger of `release.yml` is a `push` to `main`;
- the job also has a second guard `if: github.ref == 'refs/heads/main'`, so a manual run (`workflow_dispatch`) that selects another branch is skipped outright.

Other branches and PRs go through `.github/workflows/ci.yml`, which only validates (syntax, line endings, `--help` works) and does not publish.

## Troubleshooting

1. Open the **Actions** page of the repository and read the log of the most recent `Release` run; the step that went red prints `::error::` with the reason.
2. Common causes:
   - **VERSION format is invalid** — letters and a `v` prefix are both rejected; write `1.2.3`, not `v1.2.3`.
   - **The script has CRLF line endings** — the validation step stops it. Using `.gitattributes` locally (already configured with `*.sh text eol=lf`) avoids this.
   - **`sh -n` syntax error** — run it locally once before committing.
3. To republish a given version: set `VERSION` back to the old value (or to some new value), then push `main` once more. If both the tag and the Release already exist, the workflow skips everything and changes nothing.
4. If you really need to delete a certain Release: delete the Release and the tag on the GitHub page, then change `VERSION` to another value and push once, or trigger the workflow manually.

## Why Release assets instead of raw links

`raw.githubusercontent.com/<owner>/<repo>/<ref>/<file>` often fails to connect in some network environments (measured: repeated 8-second timeouts), and a ref such as `/main/` makes users run whatever **unreleased** intermediate state the branch holds.

Benefits of Release assets plus `releases/latest/download/`:

- the URL **contains no version number**, so users paste it once and never have to change it;
- it points only at **officially released** versions, so nobody gets a half-finished build;
- acceleration services (the self-hosted `github.mus.pp.ua`, the public `gh-proxy.com`, `ghproxy.net`) can all proxy Release assets; measured: a 15MB file finished downloading in 5.9 seconds. The default source order is **self-hosted first, public as the fallback** (measured 2026-11-03: the self-hosted one forwards Release assets correctly but occasionally times out after 40 seconds, while the public one succeeded 5 out of 5 times in about 1 second).
