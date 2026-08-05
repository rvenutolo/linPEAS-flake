#!/usr/bin/env bash
# tests/check-freshness-hook-watches-modules.test.sh
#
# Spec-driven harness for scripts/check-freshness-hook-watches-modules.sh.
# Drives the guard against fixture trees via the ROOT_OVERRIDE env var,
# then asserts it holds on the live tree.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-freshness-hook-watches-modules.sh"

failures=0

# Declared top-level so the EXIT trap can reach across function boundaries.
work=''
function cleanup() {
  if [[ -n ${work:-} && -d ${work} ]]; then
    rm --recursive --force -- "${work}"
  fi
}
trap cleanup EXIT

function expect() {
  local -r name="$1" root="$2" want_exit="$3" want_msg="$4"
  local got_exit=0 got_stderr
  got_stderr="$(ROOT_OVERRIDE="${root}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${name}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'PASS: %s (exit %s)\n' "${name}" "${got_exit}"
}

# Build a miniature repo: a generator evaluating devTooling.<sys>.fixtureAttr,
# a module defining that attribute, a module transposing devTooling to the
# top level, and one hook whose files filter is the variable under test.
#
# ${1}=root, ${2}=files-filter value, ${3}=where the attribute is named in
# the transposing module ("comment" puts it behind a `#`, anything else
# leaves it out entirely — the transposer is required either way).
function write_tree() {
  local -r root="$1" files="$2" attr_placement="$3"
  mkdir --parents -- "${root}/scripts" "${root}/nix/hooks"

  cat >"${root}/scripts/refresh-fixture-doc.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
nix eval --json ".#devTooling.${sys}.fixtureAttr"
EOF

  cat >"${root}/nix/hooks/default.nix" <<'EOF'
{
  fixtureAttr = import ./members.nix;
}
EOF

  cat >"${root}/nix/hooks/members.nix" <<'EOF'
{
  a-hook = { enable = true; };
}
EOF

  if [[ ${attr_placement} == "comment" ]]; then
    cat >"${root}/nix/manifests.nix" <<'EOF'
{
  # Refresh scripts read devTooling.<system>.fixtureAttr via nix eval.
  config.flake.devTooling = { };
}
EOF
  else
    cat >"${root}/nix/manifests.nix" <<'EOF'
{
  config.flake.devTooling = { };
}
EOF
  fi

  cat >"${root}/nix/hooks/freshness.nix" <<EOF
{
  fixture-doc-fresh = {
    enable = true;
    name = "fixture-doc-fresh";
    description = "Fixture generated-doc freshness hook.";
    entry = "bash scripts/refresh-fixture-doc.sh --check";
    files = "${files}";
    pass_filenames = false;
    language = "system";
  };
}
EOF
}

function main() {
  work="$(mktemp --directory)"

  # (a) GOOD: a filter covering the definer, its import, and the transposer.
  write_tree "${work}/good" \
    '^(nix/hooks/.*\.nix|nix/manifests\.nix)$' plain
  expect 'good: filter covering every derived module passes' \
    "${work}/good" 0 ''

  # (b) BAD: the transposing module is not covered. This is the regression
  # the guard exists for — the module is load-bearing but easy to drop.
  write_tree "${work}/bad-manifest" \
    '^(nix/hooks/.*\.nix)$' plain
  expect 'bad: filter missing the transposing module fails' \
    "${work}/bad-manifest" 1 'nix/manifests.nix'

  # (c) BAD: the defining module is not covered.
  write_tree "${work}/bad-definer" \
    '^(nix/manifests\.nix)$' plain
  expect 'bad: filter missing the defining module fails' \
    "${work}/bad-definer" 1 'nix/hooks/default.nix'

  # (d) BAD: the transposing module names the attribute only in a comment.
  # It is still required, because the transposition — not the mention — is
  # what makes it load-bearing. A mention-derived guard passes here.
  write_tree "${work}/bad-comment-only" \
    '^(nix/hooks/.*\.nix)$' comment
  expect 'bad: comment-only mention does not excuse the transposer' \
    "${work}/bad-comment-only" 1 'nix/manifests.nix'

  # (e) EMPTY: no generator evaluates devTooling → guard-the-guard fires.
  mkdir --parents -- "${work}/empty/scripts" "${work}/empty/nix/hooks"
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\necho nothing\n' \
    >"${work}/empty/scripts/refresh-nothing.sh"
  printf '{\n  x = { enable = true; };\n}\n' \
    >"${work}/empty/nix/hooks/default.nix"
  expect 'empty: zero devTooling generators trips guard-the-guard' \
    "${work}/empty" 1 'no devTooling-evaluating generator'

  # (g) BAD: nix/manifests.nix transposes devTooling via an attribute-set
  # assignment (`config.flake = { devTooling = { }; };`) rather than the
  # direct `config.flake.devTooling = ...` form the fixed-string signal
  # matches. Zero modules then match the transposer signal tree-wide, and
  # the guard-the-guard must fail loud rather than let every required set
  # silently shrink to exclude the manifest module.
  write_tree "${work}/bad-attrset-transposer" \
    '^(nix/hooks/.*\.nix|nix/manifests\.nix)$' plain
  cat >"${work}/bad-attrset-transposer/nix/manifests.nix" <<'EOF'
{
  config.flake = { devTooling = { }; };
}
EOF
  expect 'bad: attrset-style transposition trips the transposer guard' \
    "${work}/bad-attrset-transposer" 1 'transposer signal broke'

  # (f) LIVE: the real tree must satisfy the guard.
  expect 'live: real tree passes' "${REPO_ROOT}" 0 ''

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
