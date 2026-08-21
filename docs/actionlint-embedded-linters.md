# actionlint embedded linters

actionlint runs two embedded linters against `run:` blocks in GitHub
Actions workflows:

- **shellcheck** — bash static analysis, against shell `run:` blocks.
- **pyflakes** — python static analysis, against `shell: python` blocks.

Both are wired. No python `run:` block exists in this repo today, so the
pyflakes half currently has nothing to lint — but it is live, and the day
a python block lands it reports without any further wiring.

## Why pinned

actionlint discovers its embedded linters via `$PATH`, and which binaries
land there is nixpkgs' packaging decision rather than this repo's: the
nixpkgs `actionlint` is itself a wrapper that prepends its own
`shellcheck` and `pyflakes` to `PATH` before exec'ing the real binary.
That already makes discovery deterministic, so the failure mode is not a
shell that forgot `nix develop` — it is nixpkgs quietly changing which
binaries it bundles, which would take embedded coverage with it and
surface as nothing at all.

`nix/wrappers.nix` therefore names both paths explicitly:

```nix
actionlintWrapped = pkgs-unstable.writeShellScriptBin "actionlint" ''
  exec ${pkgs-unstable.actionlint}/bin/actionlint \
    -shellcheck=${pkgs-unstable.shellcheck}/bin/shellcheck \
    -pyflakes=${pkgs-unstable.python3Packages.pyflakes}/bin/pyflakes \
    "$@"
'';
```

The pairing is then this repo's, pinned at flake evaluation, and a
canary can assert it.

## Canaries

One per linter, each running the wrapped actionlint against a fixture
carrying a planted finding and asserting the code appears:

| Canary                                          | Fixture                                          | Asserts      |
| ----------------------------------------------- | ------------------------------------------------ | ------------ |
| `scripts/check-actionlint-shellcheck-active.sh` | `tests/fixtures/actionlint-shellcheck-smoke.yml` | `SC2086`     |
| `scripts/check-actionlint-pyflakes-active.sh`   | `tests/fixtures/actionlint-pyflakes-smoke.yml`   | `[pyflakes]` |

Each is wired as a pre-commit hook (`actionlint-shellcheck-active`,
`actionlint-pyflakes-active`) whose `files` filter watches the wrapper,
the fixture, and the canary itself. Both harnesses run in `harness-group`.

Each exits 0 when the linter reached the block, 1 when the integration
has gone quiet, and 2 when the canary could not run at all — a missing
fixture, or no `actionlint` on `PATH`. A canary that never ran says
nothing about the integration, so it does not borrow the failure code.

Do not "fix" the planted findings in either fixture. They exist to be
reported.

### If a canary fails

1. Run the hook rather than a bare binary:
    `pre-commit run actionlint-shellcheck-active` (or
    `actionlint-pyflakes-active`). Only the hook puts the wrapper on
    `PATH`; a bare `command -v actionlint` in the devShell resolves to
    the unwrapped nixpkgs `actionlint`, which is itself a `/nix/store/`
    shell script and so looks like the wrapper without being it.
1. Read the hook entry in `nix/hooks/workflow-security.nix` and confirm
    it still prepends `${actionlintWrapped}/bin` to `PATH`.
1. Read `actionlintWrapped` in `nix/wrappers.nix` and confirm the
    relevant `-shellcheck=` / `-pyflakes=` flag is still present.
1. Confirm the pinned binary still exists
    (`ls /nix/store/.../bin/shellcheck`). If garbage-collected, run
    `nix develop` to re-materialize.
1. Run the wrapper by hand against the fixture.

## Related

In the `nix/` modules (grep anchors, since line numbers drift):

- `actionlintWrapped =` in `nix/wrappers.nix` — wrapper derivation; both
    `-shellcheck=` and `-pyflakes=` pins live here. This is the central
    artifact the canaries protect.
- `actionlint = {` in `nix/hooks/linters.nix` — actionlint pre-commit hook
    block (entry points at the wrapper).
- `actionlint-shellcheck-active = {` and `actionlint-pyflakes-active = {`
    in `nix/hooks/workflow-security.nix` — the two canary hooks.
- `shellcheck = {` in `nix/hooks/linters.nix` — standalone shellcheck
    pre-commit hook (covers tracked `*.sh` files; complementary to
    actionlint's embedded coverage).
