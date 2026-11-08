## What does this change?

<!-- Briefly describe the fix or feature. -->

## Why?

<!-- What problem does this solve, or what game/setup prompted it? -->

## Testing

<!-- How did you verify this? Which game(s)/launcher(s) did you test against?
     `bash -n dist/eax-restore-linux.sh` alone is not sufficient for behavioral changes. -->

- [ ] Ran `./build.sh && bash -n dist/eax-restore-linux.sh` (syntax check)
- [ ] Ran `bats tests/unit tests/integration`
- [ ] If `data/` changed: ran `tools/format-game-database.sh --check` and `tools/build-game-database.sh --check`
- [ ] Tested against a real game install
