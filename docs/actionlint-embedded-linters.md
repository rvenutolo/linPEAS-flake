# actionlint embedded linters

actionlint can run two embedded linters against `run:` blocks in GitHub
Actions workflows:

- **shellcheck** — bash static analysis. Wired today.
- **pyflakes** — python static analysis. Not wired (no python `run:` exists).

## Why pinned

actionlint discovers embedded linters via `$PATH`. A pre-commit invocation
from a shell that has not entered the devShell (fresh checkout without
direnv, CI step that forgot `nix develop`) silently degrades: actionlint
exits 0 with embedded coverage disabled. To eliminate this, the actionlint
hook in `nix/hooks/linters.nix` is wrapped so the binary always receives an explicit
`-shellcheck=/nix/store/.../shellcheck` flag. Discovery is deterministic
at flake evaluation.

## Canary

`scripts/check-actionlint-shellcheck-active.sh` runs the wrapped actionlint
against `tests/fixtures/actionlint-shellcheck-smoke.yml`, a workflow with a
planted SC2086 violation. The script asserts SC2086 appears in actionlint
output. Wired as the `actionlint-shellcheck-active` pre-commit hook.

If the canary fails:

1. Confirm `command -v actionlint` resolves to the wrapper (a small shell
    script under `/nix/store/`, not the upstream actionlint binary).
1. `cat` the wrapper. Confirm `-shellcheck=...` is present.
1. Confirm the shellcheck path inside the wrapper still exists
    (`ls /nix/store/.../bin/shellcheck`). If garbage-collected, run
    `nix develop` to re-materialize.
1. Run the wrapper manually against the smoke fixture.

## Wiring pyflakes when python `run:` lands

Today the `check-run-block-pyflakes-required` pre-commit hook fails if any
workflow `run:` invokes `python`/`python3`/`pip` (also catches `pip3` and
`sudo`-prefixed forms). When that happens:

1. Add `pkgs.python3Packages.pyflakes` to the devShell package list in
    `nix/devshell.nix` (same scope as the existing `shellcheck` entry — grep
    `nix/devshell.nix` for the bare `shellcheck` package line).
1. Extend `actionlintWrapped` in `nix/wrappers.nix` (grep for `actionlintWrapped =`)
    to pass `-pyflakes=${pkgs.python3Packages.pyflakes}/bin/pyflakes` in
    addition to `-shellcheck=...`.
1. Add a python smoke fixture
    (`tests/fixtures/actionlint-pyflakes-smoke.yml`) containing a `run:`
    block with a deliberate pyflakes violation (e.g. `F401` unused import).
1. Extend `scripts/check-actionlint-shellcheck-active.sh` (or split into a
    `check-actionlint-pyflakes-active.sh` sibling) to assert the pyflakes
    code appears.
1. Remove `scripts/check-run-block-pyflakes-required.sh`, its test, its
    fixtures, and the hook registration — the canary now enforces what the
    guard was placeholding for.

## Related

In the `nix/` modules (grep anchors, since line numbers drift):

- `actionlint = {` in `nix/hooks/linters.nix` — actionlint pre-commit hook
    block (entry points at the wrapper).
- `actionlintWrapped =` in `nix/wrappers.nix` — wrapper derivation; the
    `-shellcheck=` pin lives here. This is the central artifact this runbook
    protects.
- `shellcheck = {` in `nix/hooks/linters.nix` — standalone shellcheck
    pre-commit hook (covers tracked `*.sh` files; complementary to
    actionlint's embedded coverage).
