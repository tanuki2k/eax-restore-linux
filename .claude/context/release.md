# Releases and branches

Moved out of CLAUDE.md so it isn't loaded into every session; CLAUDE.md says when to read it.

End users get the script from a **GitHub Release asset**, not the repo directly —
`README.md`'s `curl` command and `eax-restore-linux.desktop`'s launcher both fetch
`.../releases/latest/download/eax-restore-linux.sh`. Cutting the **stable** release:
bump `SCRIPT_VERSION` in `src/globals.sh` (on `dev`), get it onto `main` (the stable,
LTS-style branch: it takes fixes and game data that went through `dev` first, never
new features), and push a `vX.Y` tag (or `vX.Y.Z` for a patch, e.g. `v0.29.1`) on the
`main` commit. `.github/workflows/release.yml` then runs the test suite, refuses a tag
that isn't on `main` or doesn't match `SCRIPT_VERSION`, builds (a stable build: no
`-dev`, `DATA_BRANCH="main"`), writes `eax-restore-linux.sh.sha256` (bare file name, so
`sha256sum -c` works as in README's "Verifying the download") and creates the release
with the script, the checksum and `eax-restore-linux.desktop` attached, marked Latest
so the `releases/latest/download/` URLs resolve to it. The TUI is not released. `main`
also carries a small `eax-restore-linux.sh` stub that fetches the latest release, for
launchers and `curl` lines saved from 0.28.x that point at the raw `main` file; keep it
out of `dev` (`dist/` is where the real script is built). `SCRIPT_DATE` is **not**
bumped by hand: `build.sh` derives it from the HEAD commit date (`git show -s
--format=%cs`) at build time — a plain `vX.Y[.Z]` checkout gets that tag's commit date.
The `SCRIPT_DATE="..."` literal in `src/globals.sh` is only the fallback for a build
with no git available (e.g. a source tarball); refresh it opportunistically so
those stay roughly current. Game data reaches `main` by cherry-picking the
`data/games/**` source files and re-running `tools/build-game-database.sh`, not the
generated `game-database.json`.

Every push to `dev` (and manual `workflow_dispatch`) instead auto-publishes a rolling
**`dev` prerelease** via `.github/workflows/dev-release.yml`: `build.sh` itself
stamps the version `<base>-dev` (base from `src/globals.sh`, triggered by
`GITHUB_REF_NAME=dev`) and puts the commit date + short SHA in the date field, then
the workflow updates the single `dev`-tagged release in place
with `dist/eax-restore-linux.sh` and its `.sha256` attached, but only after `bash -n`,
`shellcheck --severity=error`, the bats suites, the profiler's Python tests and
`jq empty game-database.json` pass. It's marked `--prerelease` so
`releases/latest` keeps resolving to the stable `vX.Y`, and the workflow fails if that
ever stops holding. The `dev` prerelease never carries the `.desktop` launcher (the
launcher hardcodes `releases/latest`).
