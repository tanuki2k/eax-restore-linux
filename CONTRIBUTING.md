# Contributing

Thanks for taking an interest in this project! It's a single Bash script maintained as a hobby project, so contributions are welcome but the process is kept lightweight.

## Reporting Bugs

Please [open an issue](../../issues/new) and include:

* The game and launcher (Steam/Proton or Heroic/Wine) you were using
* The exact error message or unexpected behavior
* If possible, the relevant section of the script's console output

## Suggesting Enhancements

Open an issue describing the use case. If it's specific to a particular game or engine build quirk, mention that too — it helps prioritize.

## Pull Requests

1. Fork the repo and create a branch from `main`.
2. Keep changes focused — one fix or feature per PR is easier to review than a bundle of unrelated changes.
3. Test your change against a real game install where possible; this script has a lot of environment-dependent branches (Steam vs. Heroic, 32-bit vs. 64-bit, Proton vs. native Wine) that are hard to catch with a syntax check alone.
4. Run `bash -n eax-restore-linux.sh` at minimum to confirm the script still parses.
5. Describe what you tested in the PR description.

## Style

* Match the existing script's conventions: `UPPER_CASE` for variables that persist across functions, `snake_case` for function-local variables, and the existing color/echo helpers for output.
* Avoid adding new external dependencies unless there's no reasonable way around it — the script currently only requires `curl`, `unzip`, `file`, `grep`, and `awk`, plus `protontricks`/`winetricks` depending on launcher.
