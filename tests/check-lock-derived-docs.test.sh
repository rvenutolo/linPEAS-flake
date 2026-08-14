#!/usr/bin/env bash
# tests/check-lock-derived-docs.test.sh
#
# Spec-driven harness for scripts/check-lock-derived-docs.sh.
# Drives the lint against fixture trees via the ROOT_OVERRIDE env var,
# then asserts it holds on the live tree.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-lock-derived-docs.sh"

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

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  ROOT_OVERRIDE="${root}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  local got_stderr
  got_stderr="$(cat -- "${stderr_file}")"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${name}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %s)\n' "${name}" "${got_exit}"
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

# Trigger regexes a fixture hook can carry, in the doubled-backslash form
# a nix string literal holds. The lint unescapes them to an ERE before
# matching `flake.lock` against them, so a fixture written with single
# backslashes would exercise a shape the real hook module never has.
readonly LOCK_ALPHA='^(flake\\.lock|docs/reference/alpha\\.md)$'
readonly NOLOCK_ALPHA='^(justfile|docs/reference/alpha\\.md)$'
readonly LOCK_BETA='^(flake\\.lock|docs/reference/beta\\.md)$'
readonly NOLOCK_BETA='^(justfile|docs/reference/beta\\.md)$'

# The two generators a fixture hook can run, both present and executable.
# A scenario that needs a listed-but-absent generator names a third path
# nothing writes.
# ${1}=root
function write_generators() {
  local -r root="$1"
  mkdir --parents -- "${root}/scripts"
  cat >"${root}/scripts/refresh-alpha.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'alpha\n'
EOF
  cat >"${root}/scripts/refresh-beta.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'beta\n'
EOF
  chmod +x -- "${root}/scripts/refresh-alpha.sh" "${root}/scripts/refresh-beta.sh"
}

# A freshness module carrying three hook blocks in the shape the real one
# uses: two whose trigger regex is the variable under test, and one that
# never names the lock and runs a generator no fixture writes — proof that
# a hook outside the lock-triggered set is neither required in the
# workflow list nor checked for an on-disk generator.
#
# alpha-fresh's entry line is a parameter so a scenario can give a
# lock-triggered hook a body that names no generator at all.
#
# ${1}=root  ${2}=alpha-fresh trigger regex  ${3}=beta-fresh trigger regex
# ${4}=alpha-fresh entry line (default: runs its own generator)
function write_hooks() {
  local -r root="$1" alpha_files="$2" beta_files="$3"
  local -r alpha_entry="${4:-exec bash scripts/refresh-alpha.sh --check}"
  mkdir --parents -- "${root}/nix/hooks"

  cat >"${root}/nix/hooks/freshness.nix" <<EOF
{
  alpha-fresh = {
    enable = true;
    name = "alpha-fresh";
    entry = "\${pkgs.writeShellScript "alpha-fresh" ''
      ${alpha_entry}
    ''}";
    files = "${alpha_files}";
    pass_filenames = false;
    language = "system";
  };
  beta-fresh = {
    enable = true;
    name = "beta-fresh";
    entry = "\${pkgs.writeShellScript "beta-fresh" ''
      exec bash scripts/refresh-beta.sh --check
    ''}";
    files = "${beta_files}";
    pass_filenames = false;
    language = "system";
  };
  gamma-fresh = {
    enable = true;
    name = "gamma-fresh";
    entry = "\${pkgs.writeShellScript "gamma-fresh" ''
      exec bash scripts/refresh-gamma.sh --check
    ''}";
    files = "^(justfile|docs/reference/gamma\\\\.md)\$";
    pass_filenames = false;
    language = "system";
  };
}
EOF
}

# A workflow the lint may discover. Both list bodies are whole indented
# YAML block-scalar bodies, so a scenario can hand either one an empty
# body; an empty body means the key is written with no entries. Passing
# the literal string 'omit' for a body leaves the key out entirely, which
# is a different shape from an empty one.
#
# ${1}=root  ${2}=workflow file name  ${3}=lock-writing (true|false)
# ${4}=LOCK_DERIVED_GENERATORS body   ${5}=COMMITTABLE_PATHS body
function write_workflow() {
  local -r root="$1" wf_name="$2" lock_writing="$3"
  local -r generators="$4" committable="$5"
  mkdir --parents -- "${root}/.github/workflows"

  local env_block=''
  if [[ ${generators} != 'omit' ]]; then
    env_block+="  LOCK_DERIVED_GENERATORS: |"$'\n'"${generators}"$'\n'
  fi
  if [[ ${committable} != 'omit' ]]; then
    env_block+="  COMMITTABLE_PATHS: |"$'\n'"${committable}"$'\n'
  fi
  if [[ -n ${env_block} ]]; then
    env_block="env:"$'\n'"${env_block}"
  fi

  local run_line='          true'
  if [[ ${lock_writing} == 'true' ]]; then
    run_line='          nix flake update'
  fi

  cat >"${root}/.github/workflows/${wf_name}" <<EOF
name: ${wf_name%.yml}
on:
  workflow_dispatch:
permissions: {}
${env_block}jobs:
  compute:
    runs-on: ubuntu-latest
    steps:
      - run: |
${run_line}
EOF
}

# A whole miniature repo: the generators, the freshness module, and the
# bump workflow the two must agree with. A scenario needing a second
# discovered subject calls `write_workflow` again on the same root.
#
# ${1}=root  ${2}=alpha-fresh regex  ${3}=beta-fresh regex
# ${4}=generator list body  ${5}=committable list body
# ${6}=alpha-fresh entry line (default: runs its own generator)
function write_tree() {
  local -r root="$1" alpha_files="$2" beta_files="$3"
  local -r generators="$4" committable="$5"
  local -r alpha_entry="${6:-exec bash scripts/refresh-alpha.sh --check}"
  write_generators "${root}"
  write_hooks "${root}" "${alpha_files}" "${beta_files}" "${alpha_entry}"
  write_workflow "${root}" 'update-flake-lock.yml' 'true' \
    "${generators}" "${committable}"
}

function main() {
  work="$(mktemp --directory)"

  # (a) GOOD: the one lock-triggered hook's generator is exactly what the
  # workflow runs, and the committable list carries the lock.
  write_tree "${work}/agree" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  expect 'agree: the lock-triggered generator set matches the workflow list' \
    "${work}/agree" 0 ''

  # (b) BAD: alpha-fresh declares flake.lock a trigger, so a bump can
  # staleness its doc, but the bumper never runs its generator. This is
  # the regression the lint exists for — the doc reaches the bump PR
  # stale and the required freshness gate then blocks a bot branch.
  # beta-fresh is lock-triggered too and its generator IS listed, so the
  # reverse direction stays silent and the reported gap is the real one.
  write_tree "${work}/missing-from-workflow" "${LOCK_ALPHA}" "${LOCK_BETA}" \
    '    scripts/refresh-beta.sh' \
    '    flake.lock'
  expect 'bad: a lock-triggered hook whose generator the bumper skips fails' \
    "${work}/missing-from-workflow" 1 \
    'scripts/refresh-alpha.sh is absent from LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml'

  # (c) BAD: the workflow runs a generator no lock-triggered hook backs.
  # The entry is stale — nothing declares its doc lock-derived — and the
  # bump spends its budget regenerating a doc no gate asks for.
  write_tree "${work}/stale-workflow-entry" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-beta.sh' \
    '    flake.lock'
  expect 'bad: a workflow entry no lock-triggered hook backs fails' \
    "${work}/stale-workflow-entry" 1 \
    'scripts/refresh-beta.sh is in LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml, but no lock-triggered hook runs it'

  # (d) BAD: a listed generator that is not on disk. The bump would fail
  # mid-run with no doc regenerated, so the path is asserted here rather
  # than discovered weekly at 05:00 UTC.
  write_tree "${work}/generator-absent" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-missing.sh' \
    '    flake.lock'
  expect 'bad: a listed generator missing from disk fails' \
    "${work}/generator-absent" 1 \
    'scripts/refresh-missing.sh is listed in LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml but is not an executable generator'

  # (e) BAD: the committable allowlist omits the one file the bump always
  # writes. The credentialed job commits nothing outside that list, so the
  # bump would regenerate docs and drop the lock they describe.
  write_tree "${work}/no-lock-in-committable" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    '    docs/reference/alpha.md'
  expect 'bad: a committable list without flake.lock fails' \
    "${work}/no-lock-in-committable" 1 \
    'COMMITTABLE_PATHS in .github/workflows/update-flake-lock.yml omits flake.lock'

  # (f) BAD: an empty committable allowlist. Distinct from (e) in that
  # nothing at all is committable, which would leave the bump opening a PR
  # with no commits on it rather than one missing the lock.
  write_tree "${work}/empty-committable" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    ''
  expect 'bad: an empty committable list fails' \
    "${work}/empty-committable" 1 \
    'COMMITTABLE_PATHS in .github/workflows/update-flake-lock.yml is empty'

  # (g) BAD: a hook declares flake.lock a trigger but its block names no
  # generator, so the two halves of one declaration disagree. Neither
  # direction of the set comparison can see such a hook — it contributes
  # no generator to require of the workflow, and requires none of it — so
  # left unreported it is a bump that regenerates nothing for a doc the
  # freshness gate will still hold to the new lock.
  write_tree "${work}/hook-without-generator" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '' \
    '    flake.lock' \
    'exec bash scripts/verify-alpha.sh --check'
  expect 'bad: a lock-triggered hook naming no generator fails' \
    "${work}/hook-without-generator" 1 \
    'hook alpha-fresh declares flake.lock a trigger but names no'

  # (h) TOOLING: no hook declares flake.lock a trigger at all. This repo
  # has lock-derived docs, so an empty match set means the block parser or
  # the regex unescape broke — and an empty-at-exit-0 producer reads
  # exactly like full agreement. The verdict must be could-not-run (2),
  # not a clean pass.
  write_tree "${work}/no-lock-triggered-hook" "${NOLOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    '    flake.lock'
  expect 'tooling: zero lock-triggered hooks is a could-not-run' \
    "${work}/no-lock-triggered-hook" 2 'no freshness hook declares'

  # (i) TOOLING: the freshness module is absent, so the hook side of the
  # comparison has no source. Reporting that as agreement would vouch for
  # a set nothing was read from.
  write_generators "${work}/freshness-absent"
  write_workflow "${work}/freshness-absent" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' '    flake.lock'
  expect 'tooling: an absent freshness module is a could-not-run' \
    "${work}/freshness-absent" 2 'nix/hooks/freshness.nix not found'

  # (j) TOOLING: no workflow files at all, so the workflow side of the
  # comparison has no source. glob_into owns this verdict.
  write_generators "${work}/workflow-absent"
  write_hooks "${work}/workflow-absent" "${LOCK_ALPHA}" "${NOLOCK_BETA}"
  expect 'tooling: an absent workflow directory is a could-not-run' \
    "${work}/workflow-absent" 2 'matched 0 files'

  # (k) TOOLING: the workflow exists but does not parse. An unparsable
  # file yields no list entries, which would otherwise score as a workflow
  # that runs no generator — a finding about content the lint never read.
  write_tree "${work}/workflow-unparsable" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    '    flake.lock'
  printf ': [ this is not yaml\n' \
    >"${work}/workflow-unparsable/.github/workflows/update-flake-lock.yml"
  expect 'tooling: an unparsable workflow is a could-not-run' \
    "${work}/workflow-unparsable" 2 \
    'could not parse .github/workflows/update-flake-lock.yml'

  # (l) LIVE: the real tree must satisfy the lint.
  expect 'live: real tree agrees' "${REPO_ROOT}" 0 ''

  # (m) GOOD: two lock-writing workflows, both agreeing. Proves a second
  # subject is discovered and checked rather than skipped once the first
  # one scores clean.
  write_tree "${work}/two-agree" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  write_workflow "${work}/two-agree" 'renovate-refresh.yml' 'true' \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  expect 'agree: two lock-writing workflows both matching the hook set' \
    "${work}/two-agree" 0 ''

  # (n) BAD: a second workflow writes a lock but declares no generator
  # list at all. This is the whole defect class — a lock-writing workflow
  # that never learned it owns the docs its lock derives.
  write_tree "${work}/sibling-undeclared" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  write_workflow "${work}/sibling-undeclared" 'renovate-refresh.yml' 'true' \
    'omit' 'omit'
  expect 'bad: a lock-writing workflow declaring no generator list fails' \
    "${work}/sibling-undeclared" 1 \
    '.github/workflows/renovate-refresh.yml writes flake.lock but declares no LOCK_DERIVED_GENERATORS'

  # (o) BAD: the first workflow agrees and the sibling omits a generator
  # the hooks require. Attribution must name the sibling; the compliant
  # workflow must not absorb the finding.
  write_tree "${work}/sibling-gap" "${LOCK_ALPHA}" "${LOCK_BETA}" \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-beta.sh' \
    '    flake.lock'
  write_workflow "${work}/sibling-gap" 'renovate-refresh.yml' 'true' \
    '    scripts/refresh-alpha.sh' \
    '    flake.lock'
  expect 'bad: a per-workflow generator gap names the offending workflow' \
    "${work}/sibling-gap" 1 \
    'scripts/refresh-beta.sh is absent from LOCK_DERIVED_GENERATORS in .github/workflows/renovate-refresh.yml'

  # (p) BAD: a workflow declares the lists but runs no lock update. Dead
  # config: the lists outlived the step they bounded, and nothing else in
  # the lint would ever look at them again.
  write_tree "${work}/dead-config" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  write_workflow "${work}/dead-config" 'stale-lists.yml' 'false' \
    '    scripts/refresh-alpha.sh' \
    '    flake.lock'
  expect 'bad: a workflow declaring the lists but writing no lock fails' \
    "${work}/dead-config" 1 \
    '.github/workflows/stale-lists.yml declares a lock-derived env list but runs no flake-lock update'

  # (q) TOOLING: workflows exist and none writes a lock. An empty subject
  # set reads exactly like full agreement, so the discovery expression
  # going blind must fail loud rather than vouch for a set nothing was
  # read from. Sibling of the zero-lock-triggered-hooks guard.
  write_generators "${work}/no-lock-writer"
  write_hooks "${work}/no-lock-writer" "${LOCK_ALPHA}" "${NOLOCK_BETA}"
  write_workflow "${work}/no-lock-writer" 'ci.yml' 'false' 'omit' 'omit'
  expect 'tooling: zero lock-writing workflows is a could-not-run' \
    "${work}/no-lock-writer" 2 'no workflow runs a flake-lock update'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
