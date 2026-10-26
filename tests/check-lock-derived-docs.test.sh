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
# The exempt set a fixture scenario runs with; see expect.
exempt_override=''

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

  # A fixture module carries the real exempt hook only when a scenario
  # says so, so fixtures run with the exempt set the scenario names
  # (default: none). The live tree runs with the lint's own set.
  local -a exempt_env=("LOCK_TRIGGER_EXEMPT_OVERRIDE=${exempt_override}")
  if [[ ${root} == "${REPO_ROOT}" ]]; then
    exempt_env=()
  fi
  local got_exit=0
  env ${exempt_env+"${exempt_env[@]}"} ROOT_OVERRIDE="${root}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  # The asserted substring may sit on either stream: a finding is on
  # stderr, and the breadth summary a clean run prints is on stdout.
  local got_stderr got_stdout
  got_stderr="$(cat -- "${stderr_file}")"
  got_stdout="$(cat -- "${stdout_file}")"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} && ${got_stderr}${got_stdout} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: output missing %q\n  stderr: %s\n  stdout: %s\n' \
      "${name}" "${want_msg}" "${got_stderr}" "${got_stdout}" >&2
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
# delta-fresh's trigger, which names `.github/workflows/ci.yml` or not.
# The workflow-derived rule matches that path against the unescaped
# regex, so these carry the same doubled backslashes the real hook does.
readonly CI_DELTA='^(\\.github/workflows/ci\\.yml|docs/reference/delta\\.md|docs/reference/epsilon\\.md|scripts/refresh-delta\\.sh)$'
readonly NOCI_DELTA='^(justfile|docs/reference/delta\\.md|docs/reference/epsilon\\.md|scripts/refresh-delta\\.sh)$'

# Python-`re`-only trigger shapes, the kind pre-commit evaluates and
# POSIX ERE cannot: a negative lookahead that admits flake.lock, one that
# rules it out, and a variable-width look-behind that does not compile.
readonly LOOKAHEAD_LOCK_BETA='^((?!docs/|\\.claude/)(?!.*\\.(md|sh)$).*|docs/reference/beta\\.md)$'
readonly LOOKAHEAD_NOLOCK_BETA='^((?!flake\\.lock$)[^/]*\\.lock|docs/reference/beta\\.md)$'
readonly UNCOMPILABLE_BETA='^(flake\\.lock|(?<=a+)docs/reference/beta\\.md)$'
# Triggers for the hook the lint exempts from the generator list, one
# naming the lock and one not.
readonly EXEMPT_LOCK_FILES='^(flake\\.lock|docs/development/linting\\.md)$'
readonly EXEMPT_NOLOCK_FILES='^(justfile|docs/development/linting\\.md)$'

# The hook block the lint exempts, under its real name, running a
# generator no fixture writes or lists.
# ${1}=trigger regex
function exempt_block() {
  cat <<EOF
  ephemeral-refs-gap-fresh = {
    enable = true;
    name = "ephemeral-refs-gap-fresh";
    entry = "\${pkgs.writeShellScript "ephemeral-refs-gap-fresh" ''
      exec bash scripts/refresh-ephemeral-refs-gap.sh --check
    ''}";
    files = "$1";
    pass_filenames = false;
    language = "system";
  };
EOF
}

# The three generators a fixture hook can run, all present and
# executable. A scenario that needs a listed-but-absent generator names a
# path nothing writes. delta is the workflow-derived one: it splices
# blocks into two docs, the shape the runner-label generator has.
#
# Each carries the output declaration the real generators carry, in the
# header position the annotation parser reads, so a fixture generator
# states what it writes the way every generator in this repo does.
#
# alpha's declaration line is a parameter so a scenario can hand it a
# different annotation kind or no annotation at all; passing the empty
# string leaves alpha declaring nothing. Calling this again on a root the
# tree writer already populated rewrites both generators, which is how a
# scenario overrides the declaration after `write_tree`.
#
# ${1}=root  ${2}=alpha declaration line (default: @generates its doc)
function write_generators() {
  local -r root="$1"
  local -r alpha_declaration="${2-# @generates docs/reference/alpha.md}"
  mkdir --parents -- "${root}/scripts"
  cat >"${root}/scripts/refresh-alpha.sh" <<EOF
#!/usr/bin/env bash
# scripts/refresh-alpha.sh
${alpha_declaration}
set -Eeuo pipefail
printf 'alpha\n'
EOF
  cat >"${root}/scripts/refresh-beta.sh" <<'EOF'
#!/usr/bin/env bash
# scripts/refresh-beta.sh
# @generates docs/reference/beta.md
set -Eeuo pipefail
printf 'beta\n'
EOF
  cat >"${root}/scripts/refresh-delta.sh" <<'EOF'
#!/usr/bin/env bash
# scripts/refresh-delta.sh
# @generates-block docs/reference/delta.md
# @generates-block docs/reference/epsilon.md
set -Eeuo pipefail
printf 'delta\n'
EOF
  chmod +x -- "${root}/scripts/refresh-alpha.sh" "${root}/scripts/refresh-beta.sh" \
    "${root}/scripts/refresh-delta.sh"
}

# A freshness module carrying four hook blocks in the shape the real one
# uses: two whose trigger regex is the variable under test, one that
# never names the lock and runs a generator no fixture writes — proof that
# a hook outside the lock-triggered set is neither required in the
# workflow list nor checked for an on-disk generator — and delta-fresh,
# which never names the lock and by default names
# `.github/workflows/ci.yml`. A hook naming ci.yml is never required of a
# workflow, so delta-fresh is inert unless a workflow lists its generator.
#
# alpha-fresh's entry line is a parameter so a scenario can give a
# lock-triggered hook a body that names no generator at all. beta-fresh
# can carry extra attribute lines (an `excludes` list), and whole extra
# hook blocks can follow delta-fresh.
#
# ${1}=root  ${2}=alpha-fresh trigger regex  ${3}=beta-fresh trigger regex
# ${4}=alpha-fresh entry line (default: runs its own generator)
# ${5}=delta-fresh trigger regex (default: names ci.yml)
# ${6}=extra beta-fresh attribute lines (default: none)
# ${7}=extra hook blocks appended to the module (default: none)
function write_hooks() {
  local -r root="$1" alpha_files="$2" beta_files="$3"
  local -r alpha_entry="${4:-exec bash scripts/refresh-alpha.sh --check}"
  local -r delta_files="${5:-${CI_DELTA}}"
  local -r beta_extra="${6:-}" extra_blocks="${7:-}"
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
${beta_extra}
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
  delta-fresh = {
    enable = true;
    name = "delta-fresh";
    entry = "\${pkgs.writeShellScript "delta-fresh" ''
      exec bash scripts/refresh-delta.sh --check
    ''}";
    files = "${delta_files}";
    pass_filenames = false;
    language = "system";
  };
${extra_blocks}
}
EOF
}

# A workflow the lint may discover. Every list body is a whole indented
# YAML block-scalar body, so a scenario can hand any one an empty body;
# an empty body means the key is written with no entries. Passing the
# literal string 'omit' for a body leaves the key out entirely, which is
# a different shape from an empty one.
#
# A lock-writing workflow also carries the compute job's upload-artifact
# step, whose `path:` list the lint requires to equal COMMITTABLE_PATHS.
# By default that list mirrors the committable body, so a scenario about
# another rule is not also scored on the upload. `none` writes no upload
# step, `twice` writes the mirrored step twice, and any other value is
# the upload list body itself, re-indented under `path: |`.
#
# ${1}=root  ${2}=workflow file name  ${3}=lock-writing (true|false)
# ${4}=LOCK_DERIVED_GENERATORS body   ${5}=COMMITTABLE_PATHS body
# ${6}=WORKFLOW_DERIVED_GENERATORS body (default: omit)
# ${7}=upload path list body, or mirror|none|twice (default: mirror)
function write_workflow() {
  local -r root="$1" wf_name="$2" lock_writing="$3"
  local -r generators="$4" committable="$5"
  local -r workflow_generators="${6:-omit}"
  local -r upload="${7:-mirror}"
  mkdir --parents -- "${root}/.github/workflows"

  local env_block=''
  if [[ ${generators} != 'omit' ]]; then
    env_block+="  LOCK_DERIVED_GENERATORS: |"$'\n'"${generators}"$'\n'
  fi
  if [[ ${workflow_generators} != 'omit' ]]; then
    env_block+="  WORKFLOW_DERIVED_GENERATORS: |"$'\n'"${workflow_generators}"$'\n'
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

  local upload_body="${upload}"
  if [[ ${upload} == 'mirror' || ${upload} == 'twice' ]]; then
    upload_body="${committable}"
  fi
  local upload_step=''
  if [[ ${lock_writing} == 'true' && ${upload} != 'none' &&
    ${upload_body} != 'omit' && -n ${upload_body} ]]; then
    upload_step="      - uses: actions/upload-artifact@v7"$'\n'
    upload_step+="        with:"$'\n'
    upload_step+="          name: result"$'\n'
    upload_step+="          path: |"$'\n'
    upload_step+="$(sed --expression='s/^[[:space:]]*\(.\)/            \1/' <<<"${upload_body}")"$'\n'
    if [[ ${upload} == 'twice' ]]; then
      upload_step+="${upload_step}"
    fi
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
  printf '%s' "${upload_step}" >>"${root}/.github/workflows/${wf_name}"
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
    $'    flake.lock\n    docs/reference/beta.md'
  expect 'bad: a lock-triggered hook whose generator the bumper skips fails' \
    "${work}/missing-from-workflow" 1 \
    'scripts/refresh-alpha.sh is absent from LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml'

  # (c) BAD: the workflow runs a generator no lock-triggered hook backs.
  # The entry is stale — nothing declares its doc lock-derived — and the
  # bump spends its budget regenerating a doc no gate asks for.
  write_tree "${work}/stale-workflow-entry" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-beta.sh' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/beta.md'
  expect 'bad: a workflow entry no lock-triggered hook backs fails' \
    "${work}/stale-workflow-entry" 1 \
    'scripts/refresh-beta.sh is in LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml, but no lock-triggered hook runs it'

  # (d) BAD: a listed generator that is not on disk. The bump would fail
  # mid-run with no doc regenerated, so the path is asserted here rather
  # than discovered weekly at 05:00 UTC.
  write_tree "${work}/generator-absent" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-missing.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
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
    $'    flake.lock\n    docs/reference/alpha.md'
  expect 'tooling: zero lock-triggered hooks is a could-not-run' \
    "${work}/no-lock-triggered-hook" 2 'no freshness hook declares'

  # (i) TOOLING: the freshness module is absent, so the hook side of the
  # comparison has no source. Reporting that as agreement would vouch for
  # a set nothing was read from.
  write_generators "${work}/freshness-absent"
  write_workflow "${work}/freshness-absent" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
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
    $'    flake.lock\n    docs/reference/alpha.md'
  printf ': [ this is not yaml\n' \
    >"${work}/workflow-unparsable/.github/workflows/update-flake-lock.yml"
  expect 'tooling: an unparsable workflow is a could-not-run' \
    "${work}/workflow-unparsable" 2 \
    'could not parse .github/workflows/update-flake-lock.yml'

  # (k2) GOOD: a root key written as an alias of `env` or `jobs` is that
  # key, as GitHub Actions reads it, so the lists and the lock update under
  # it are read. One given twice, plain and as an alias, is a workflow the
  # lint cannot read. Each case scans its own count of workflows, and a
  # given-twice workflow carries its case's name, so no two outputs match.
  local alias_case alias_key alias_extra alias_wf
  for alias_case in env-alias env-twice jobs-alias jobs-twice; do
    alias_key="${alias_case%%-*}"
    alias_extra=''
    write_tree "${work}/${alias_case}" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
      '    scripts/refresh-alpha.sh' \
      $'    flake.lock\n    docs/reference/alpha.md'
    case "${alias_case}" in
    jobs-alias)
      write_workflow "${work}/${alias_case}" 'idle-three.yml' 'false' 'omit' 'omit'
      ;&
    env-alias)
      write_workflow "${work}/${alias_case}" 'idle-two.yml' 'false' 'omit' 'omit'
      write_workflow "${work}/${alias_case}" 'idle-one.yml' 'false' 'omit' 'omit'
      ;;
    *) alias_extra="${alias_key}: {}" ;;
    esac
    alias_wf="${work}/${alias_case}/.github/workflows/${alias_case}.yml"
    mv -- "${work}/${alias_case}/.github/workflows/update-flake-lock.yml" "${alias_wf}"
    sed --in-place \
      --expression="s/^permissions: {}$/permissions: {}\nx-key: \&k ${alias_key}\n${alias_extra}/" \
      --expression="s/^${alias_key}:$/*k :/" \
      -- "${alias_wf}"
  done
  expect 'agree: an env key written as an alias is read' "${work}/env-alias" 0 ''
  expect 'agree: a jobs key written as an alias is read' "${work}/jobs-alias" 0 ''
  expect 'tooling: an env key given twice is a could-not-run' "${work}/env-twice" 2 \
    'Error: env: is given more than once'
  expect 'tooling: a jobs key given twice is a could-not-run' "${work}/jobs-twice" 2 \
    'Error: jobs: is given more than once'

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
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/beta.md'
  write_workflow "${work}/sibling-gap" 'renovate-refresh.yml' 'true' \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
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
    $'    flake.lock\n    docs/reference/alpha.md'
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

  # (r) BAD: a listed generator writes a doc the credentialed job may not
  # commit. The bump regenerates it and then drops it, so the doc reaches
  # the PR exactly as stale as if the generator had never run — and the
  # freshness gate blocks a branch no human is meant to touch.
  #
  # Written as the two-subject attribution case, and it is the only
  # scenario the forward rule owns: the compliant workflow sorts first in
  # the discovery glob, so a diagnostic that named the wrong subject would
  # name `renovate-refresh.yml` and this assertion would miss.
  write_tree "${work}/declared-not-committable" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    '    flake.lock'
  write_workflow "${work}/declared-not-committable" 'renovate-refresh.yml' 'true' \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  expect 'bad: a declared output missing from the committable list names its workflow' \
    "${work}/declared-not-committable" 1 \
    'scripts/refresh-alpha.sh declares docs/reference/alpha.md, which is absent from COMMITTABLE_PATHS in .github/workflows/update-flake-lock.yml'

  # (s) BAD: a listed generator that declares no output at all. Nothing
  # binds what it writes to the committable set, so the forward rule is
  # vacuous for it and the whole binding would pass in silence for the one
  # generator it covers least.
  write_tree "${work}/declares-nothing" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    '    flake.lock'
  write_generators "${work}/declares-nothing" ''
  expect 'bad: a listed generator declaring no output fails' \
    "${work}/declares-nothing" 1 \
    'scripts/refresh-alpha.sh is listed in LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml but declares no @generates or @generates-block path'

  # (t) BAD: a committable entry no listed generator writes. The list
  # outlived its generator, so it widens what a credentialed job may
  # commit past anything the bump regenerates.
  write_tree "${work}/committable-orphan" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/orphan.md'
  expect 'bad: a committable path no listed generator declares fails' \
    "${work}/committable-orphan" 1 \
    'docs/reference/orphan.md is in COMMITTABLE_PATHS in .github/workflows/update-flake-lock.yml, but no listed generator declares it'

  # (u) GOOD: both annotation kinds mean "this generator writes here", so
  # a `@generates-block` output is bound to the committable set the same
  # way a whole-file `@generates` output is. Alpha declares its doc as a
  # block and beta declares its own whole-file, in one tree.
  #
  # FALSE-POSITIVE GUARD: this scenario passes against a lint carrying
  # none of the three rules, so it proves nothing on its own — it exists
  # to catch a forward or reverse rule that reads only one of the two
  # kinds and then reports a compliant tree as drift.
  write_tree "${work}/block-declaration" "${LOCK_ALPHA}" "${LOCK_BETA}" \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-beta.sh' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/beta.md'
  write_generators "${work}/block-declaration" '# @generates-block docs/reference/alpha.md'
  expect 'agree: a @generates-block output counts as a declared output' \
    "${work}/block-declaration" 0 ''

  # (v) A merge list inside a job is read first mapping wins, as the YAML
  # merge specification says: with the lock-writing mapping first, the job
  # writes flake.lock, so the workflow must declare its generators; with
  # the benign mapping first it writes nothing. Read last mapping wins,
  # the two orders would swap verdicts.
  local merge_name merge_list
  for merge_name in 'writer-first' 'benign-first'; do
    merge_list='*P, *Q'
    if [[ ${merge_name} == 'benign-first' ]]; then merge_list='*Q, *P'; fi
    write_tree "${work}/merge-${merge_name}" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
      '    scripts/refresh-alpha.sh' \
      $'    flake.lock\n    docs/reference/alpha.md'
    cat >"${work}/merge-${merge_name}/.github/workflows/zz.yml" <<EOF
name: zz
on:
  workflow_dispatch:
permissions: {}
x-writer: &P
  steps:
    - run: nix flake update
x-benign: &Q
  steps:
    - run: echo benign
jobs:
  a:
    runs-on: ubuntu-latest
    <<: [${merge_list}]
EOF
  done
  expect 'bad: a merge list whose first mapping writes flake.lock is a lock-writing workflow' \
    "${work}/merge-writer-first" 1 \
    'zz.yml writes flake.lock but declares no LOCK_DERIVED_GENERATORS'
  expect 'agree: a merge list whose first mapping is benign writes no lock' \
    "${work}/merge-benign-first" 0 ''

  # (vi) The workflow-level env is a merge list too, and its lists are read
  # first mapping wins: the first mapping names alpha's generator, which the
  # lock-triggered hook backs, and beta's, which no hook backs; the second
  # names alpha's alone. Read last mapping wins, the run would pass.
  write_tree "${work}/env-merge-list" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  cat >"${work}/env-merge-list/.github/workflows/update-flake-lock.yml" <<'EOF'
name: update-flake-lock
on:
  workflow_dispatch:
permissions: {}
x-first: &First
  LOCK_DERIVED_GENERATORS: |
    scripts/refresh-alpha.sh
    scripts/refresh-beta.sh
  COMMITTABLE_PATHS: |
    flake.lock
    docs/reference/alpha.md
    docs/reference/beta.md
    docs/reference/gamma.md
x-second: &Second
  LOCK_DERIVED_GENERATORS: |
    scripts/refresh-alpha.sh
  COMMITTABLE_PATHS: |
    flake.lock
    docs/reference/alpha.md
env:
  <<: [*First, *Second]
jobs:
  compute:
    runs-on: ubuntu-latest
    steps:
      - run: |
          nix flake update
      - uses: actions/upload-artifact@v7
        with:
          name: result
          path: |
            flake.lock
            docs/reference/alpha.md
            docs/reference/beta.md
            docs/reference/gamma.md
EOF
  expect 'bad: an env merge list is read first mapping wins' \
    "${work}/env-merge-list" 1 \
    'scripts/refresh-beta.sh is in LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml, but no lock-triggered hook runs it'

  # (w) Workflow-derived generators. A workflow may also list, in
  # WORKFLOW_DERIVED_GENERATORS, generators whose docs derive from
  # .github/workflows/ci.yml rather than from the lock. Each must be run by
  # a freshness hook whose `files` names ci.yml, and its declared outputs
  # join the committable bound alongside the lock-derived ones.
  local -r lock_and_delta=$'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/delta.md\n    docs/reference/epsilon.md'

  # (w1) GOOD: delta is listed, run by a ci.yml-triggered hook, and both
  # docs it splices are committable.
  write_tree "${work}/workflow-list-agrees" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${lock_and_delta}"
  write_workflow "${work}/workflow-list-agrees" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${lock_and_delta}" '    scripts/refresh-delta.sh'
  expect 'agree: a workflow-derived generator a ci.yml hook runs, outputs committable' \
    "${work}/workflow-list-agrees" 0 ''

  # (w2) BAD: delta's hook never names ci.yml, so nothing declares its
  # docs derive from the workflow the refresh exists to follow.
  write_tree "${work}/workflow-gen-not-ci-triggered" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${lock_and_delta}"
  write_hooks "${work}/workflow-gen-not-ci-triggered" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    'exec bash scripts/refresh-alpha.sh --check' "${NOCI_DELTA}"
  write_workflow "${work}/workflow-gen-not-ci-triggered" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${lock_and_delta}" '    scripts/refresh-delta.sh'
  expect 'bad: a workflow-derived generator no ci.yml-triggered hook runs fails' \
    "${work}/workflow-gen-not-ci-triggered" 1 \
    'scripts/refresh-delta.sh is in WORKFLOW_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml, but no freshness hook whose files names .github/workflows/ci.yml runs it'

  # (w3) BAD: one of the two docs delta splices is not committable, so the
  # credentialed job would drop it.
  write_tree "${work}/workflow-gen-output-missing" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/delta.md'
  write_workflow "${work}/workflow-gen-output-missing" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/delta.md' \
    '    scripts/refresh-delta.sh'
  expect 'bad: a workflow-derived output missing from the committable list fails' \
    "${work}/workflow-gen-output-missing" 1 \
    'scripts/refresh-delta.sh declares docs/reference/epsilon.md, which is absent from COMMITTABLE_PATHS'

  # (w4) BAD: the committable list carries delta's docs while no list names
  # delta — the shape of widening COMMITTABLE_PATHS without declaring the
  # generator that writes the new paths.
  write_tree "${work}/committable-without-workflow-list" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${lock_and_delta}"
  expect 'bad: committable workflow-derived docs with no workflow list fail' \
    "${work}/committable-without-workflow-list" 1 \
    'docs/reference/delta.md is in COMMITTABLE_PATHS in .github/workflows/update-flake-lock.yml, but no listed generator declares it'

  # (w5) BAD: one generator in both lists. Each list states a different
  # trigger for the same docs, and one of the two statements is false.
  write_tree "${work}/generator-in-both-lists" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md'
  write_workflow "${work}/generator-in-both-lists" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md' \
    '    scripts/refresh-alpha.sh'
  expect 'bad: a generator in both lists fails' \
    "${work}/generator-in-both-lists" 1 \
    'scripts/refresh-alpha.sh is in both LOCK_DERIVED_GENERATORS and WORKFLOW_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml'

  # (w6) BAD: a listed workflow-derived generator not on disk.
  write_tree "${work}/workflow-gen-absent" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md'
  write_workflow "${work}/workflow-gen-absent" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md' \
    '    scripts/refresh-missing.sh'
  expect 'bad: a listed workflow-derived generator missing from disk fails' \
    "${work}/workflow-gen-absent" 1 \
    'scripts/refresh-missing.sh is listed in WORKFLOW_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml but is not an executable generator'

  # (w7) BAD: a listed workflow-derived generator declaring no output.
  # Named in the message by the list it came from.
  write_tree "${work}/workflow-gen-declares-nothing" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md'
  sed --in-place --expression='/@generates-block/d' \
    -- "${work}/workflow-gen-declares-nothing/scripts/refresh-delta.sh"
  write_workflow "${work}/workflow-gen-declares-nothing" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md' \
    '    scripts/refresh-delta.sh'
  expect 'bad: a listed workflow-derived generator declaring no output fails' \
    "${work}/workflow-gen-declares-nothing" 1 \
    'scripts/refresh-delta.sh is listed in WORKFLOW_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml but declares no @generates or @generates-block path'

  # (w8) GOOD: the list is optional. A sibling workflow without it is
  # still scored on the lock-derived bound alone, and does not inherit the
  # first subject's workflow-derived outputs: renovate-refresh.yml sorts
  # first and carries the list, so a map carried over would score
  # update-flake-lock.yml as omitting delta's docs.
  write_tree "${work}/workflow-list-absent-unchanged" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md'
  write_workflow "${work}/workflow-list-absent-unchanged" 'renovate-refresh.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${lock_and_delta}" '    scripts/refresh-delta.sh'
  expect 'agree: a workflow without the workflow-derived list keeps the lock-only bound' \
    "${work}/workflow-list-absent-unchanged" 0 ''

  # (w9) BAD: the workflow-derived list on a workflow that writes no lock
  # is unread config, the same as the lock-derived lists there.
  write_tree "${work}/workflow-list-dead" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' $'    flake.lock\n    docs/reference/alpha.md'
  write_workflow "${work}/workflow-list-dead" 'idle-refresh.yml' 'false' \
    'omit' 'omit' '    scripts/refresh-delta.sh'
  expect 'bad: a workflow-derived list on a workflow writing no lock fails' \
    "${work}/workflow-list-dead" 1 \
    '.github/workflows/idle-refresh.yml declares a lock-derived env list but runs no flake-lock update'

  # (x) The compute job's upload-artifact `path:` list, as a set, equals
  # COMMITTABLE_PATHS. The upload cannot read the env list (octoscan
  # flags an `env.*` expression in a `with:` value), so the two are
  # written twice and this rule is what keeps them one list.
  local -r alpha_committable=$'    flake.lock\n    docs/reference/alpha.md'

  # (x1) GOOD: the same set in another order, with a blank line and a
  # comment line the upload action skips, beside two sibling workflows so
  # the breadth line differs from every other passing scenario. An upload
  # step in a job that writes no lock is not a candidate.
  write_tree "${work}/upload-agrees" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  write_workflow "${work}/upload-agrees" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${alpha_committable}" 'omit' \
    $'    docs/reference/alpha.md\n\n    # the lock\n    flake.lock'
  write_workflow "${work}/upload-agrees" 'renovate-refresh.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  write_workflow "${work}/upload-agrees" 'third-refresh.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  cat >>"${work}/upload-agrees/.github/workflows/renovate-refresh.yml" <<'EOF'
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v7
        with:
          name: other
          path: unrelated.txt
EOF
  expect 'agree: an upload list equal to COMMITTABLE_PATHS as a set' \
    "${work}/upload-agrees" 0 ''

  # (x2) BAD: a committable path the upload omits. The push job would
  # abort on the path missing from the artifact.
  write_tree "${work}/upload-missing" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  write_workflow "${work}/upload-missing" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${alpha_committable}" 'omit' '    flake.lock'
  expect 'bad: a committable path missing from the upload list fails' \
    "${work}/upload-missing" 1 \
    'docs/reference/alpha.md is in COMMITTABLE_PATHS in .github/workflows/update-flake-lock.yml but missing from its upload-artifact path list'

  # (x3) BAD: an uploaded path nothing may commit.
  write_tree "${work}/upload-extra" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  write_workflow "${work}/upload-extra" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${alpha_committable}" 'omit' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/zeta.md'
  expect 'bad: an uploaded path absent from COMMITTABLE_PATHS fails' \
    "${work}/upload-extra" 1 \
    'docs/reference/zeta.md is in the upload-artifact path list in .github/workflows/update-flake-lock.yml but not in COMMITTABLE_PATHS'

  # (x4) BAD: no upload step in the lock-writing job, so there is no list
  # to compare and nothing would reach the push job.
  write_tree "${work}/upload-none" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  write_workflow "${work}/upload-none" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${alpha_committable}" 'omit' 'none'
  expect 'bad: a lock-writing job with no upload-artifact step fails' \
    "${work}/upload-none" 1 \
    '.github/workflows/update-flake-lock.yml has no actions/upload-artifact step in a job that runs the flake-lock update'

  # (x5) BAD: two candidate upload steps. Which one carries the committed
  # files is a guess, so neither is compared.
  write_tree "${work}/upload-twice" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  write_workflow "${work}/upload-twice" 'update-flake-lock.yml' 'true' \
    '    scripts/refresh-alpha.sh' "${alpha_committable}" 'omit' 'twice'
  expect 'bad: two candidate upload-artifact steps fail' \
    "${work}/upload-twice" 1 \
    '.github/workflows/update-flake-lock.yml has 2 actions/upload-artifact steps in jobs that run the flake-lock update; want exactly one'

  # (y) A run: body written as an alias is the anchored text the runner
  # executes, so a step written `run: *body` over `nix flake update`
  # makes its workflow lock-writing and its job the upload candidate.
  # (y1) BAD: the aliased writer declares nothing.
  write_tree "${work}/alias-run-writer" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  cat >"${work}/alias-run-writer/.github/workflows/aliased-run.yml" <<'EOF'
name: aliased-run
on:
  workflow_dispatch:
permissions: {}
x-body: &body |
  nix flake update
jobs:
  compute:
    runs-on: ubuntu-latest
    steps:
      - run: *body
EOF
  expect 'bad: an aliased run: body updating the lock is a lock-writing workflow' \
    "${work}/alias-run-writer" 1 \
    'aliased-run.yml writes flake.lock but declares no LOCK_DERIVED_GENERATORS'

  # (y2) BAD: the aliased writer's job is the upload candidate, and it
  # uploads less than it may commit.
  write_tree "${work}/alias-run-upload" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${alpha_committable}"
  cat >"${work}/alias-run-upload/.github/workflows/aliased-bump.yml" <<'EOF'
name: aliased-bump
on:
  workflow_dispatch:
permissions: {}
env:
  LOCK_DERIVED_GENERATORS: |
    scripts/refresh-alpha.sh
  COMMITTABLE_PATHS: |
    flake.lock
    docs/reference/alpha.md
x-body: &body |
  nix flake update
jobs:
  compute:
    runs-on: ubuntu-latest
    steps:
      - run: *body
      - uses: actions/upload-artifact@v7
        with:
          name: result
          path: |
            flake.lock
EOF
  expect 'bad: an aliased writer job uploading less than it commits fails' \
    "${work}/alias-run-upload" 1 \
    'docs/reference/alpha.md is in COMMITTABLE_PATHS in .github/workflows/aliased-bump.yml but missing from its upload-artifact path list'

  # (z) An env list written as an alias is the anchored text GitHub
  # Actions hands the steps, so it is read as that text.
  # (z1) GOOD: the three lists, each an alias, agree as the inline lists
  # of (w1) do. An env value holding aliases the lint never reads changes
  # nothing. A sibling workflow keeps the breadth line apart from (w1).
  write_tree "${work}/alias-lists-agree" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' "${lock_and_delta}"
  write_workflow "${work}/alias-lists-agree" 'idle-sibling.yml' 'false' 'omit' 'omit'
  cat >"${work}/alias-lists-agree/.github/workflows/update-flake-lock.yml" <<'EOF'
name: update-flake-lock
on:
  workflow_dispatch:
permissions: {}
x-generators: &generators |
  scripts/refresh-alpha.sh
x-workflow-generators: &workflow_generators |
  scripts/refresh-delta.sh
x-committable: &committable |
  flake.lock
  docs/reference/alpha.md
  docs/reference/delta.md
  docs/reference/epsilon.md
x-word: &word unread
x-words: &words [*word]
env:
  LOCK_DERIVED_GENERATORS: *generators
  WORKFLOW_DERIVED_GENERATORS: *workflow_generators
  COMMITTABLE_PATHS: *committable
  UNREAD: *words
jobs:
  compute:
    runs-on: ubuntu-latest
    steps:
      - run: |
          nix flake update
      - uses: actions/upload-artifact@v7
        with:
          name: result
          path: |
            flake.lock
            docs/reference/alpha.md
            docs/reference/delta.md
            docs/reference/epsilon.md
EOF
  expect 'agree: env lists written as aliases are read as their text' \
    "${work}/alias-lists-agree" 0 ''

  # (z2) BAD: an aliased committable list carrying a path nothing
  # declares names that path, as the inline list of (t) does.
  write_generators "${work}/alias-committable-extra"
  write_hooks "${work}/alias-committable-extra" "${LOCK_ALPHA}" "${NOLOCK_BETA}"
  mkdir --parents -- "${work}/alias-committable-extra/.github/workflows"
  cat >"${work}/alias-committable-extra/.github/workflows/aliased-committable.yml" <<'EOF'
name: aliased-committable
on:
  workflow_dispatch:
permissions: {}
x-committable: &committable |
  flake.lock
  docs/reference/alpha.md
  docs/reference/orphan.md
env:
  LOCK_DERIVED_GENERATORS: |
    scripts/refresh-alpha.sh
  COMMITTABLE_PATHS: *committable
jobs:
  compute:
    runs-on: ubuntu-latest
    steps:
      - run: |
          nix flake update
      - uses: actions/upload-artifact@v7
        with:
          name: result
          path: |
            flake.lock
            docs/reference/alpha.md
            docs/reference/orphan.md
EOF
  expect 'bad: an aliased committable path no listed generator declares fails' \
    "${work}/alias-committable-extra" 1 \
    'docs/reference/orphan.md is in COMMITTABLE_PATHS in .github/workflows/aliased-committable.yml, but no listed generator declares it'

  # (z3) GOOD: a workflow writing no lock whose lists are empty, written
  # inline or as aliases of an empty string and of null, declares no list.
  # Siblings give each tree a count of workflows no other scenario scans,
  # so their breadth lines differ from every other passing run.
  local empty_case sibling
  for empty_case in inline alias; do
    write_tree "${work}/empty-lists-${empty_case}" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
      '    scripts/refresh-alpha.sh' "${alpha_committable}"
    for sibling in one two three four; do
      write_workflow "${work}/empty-lists-${empty_case}" "idle-${sibling}.yml" 'false' 'omit' 'omit'
    done
  done
  write_workflow "${work}/empty-lists-alias" 'idle-five.yml' 'false' 'omit' 'omit'
  cat >"${work}/empty-lists-inline/.github/workflows/idle-lists.yml" <<'EOF'
name: idle-lists
on:
  workflow_dispatch:
permissions: {}
env:
  LOCK_DERIVED_GENERATORS: ""
  WORKFLOW_DERIVED_GENERATORS: ""
  COMMITTABLE_PATHS:
jobs:
  idle:
    runs-on: ubuntu-latest
    steps:
      - run: echo PAYLOAD_RAN
EOF
  cat >"${work}/empty-lists-alias/.github/workflows/idle-lists.yml" <<'EOF'
name: idle-lists
on:
  workflow_dispatch:
permissions: {}
x-empty: &empty ""
x-none: &none
env:
  LOCK_DERIVED_GENERATORS: *empty
  WORKFLOW_DERIVED_GENERATORS: *empty
  COMMITTABLE_PATHS: *none
jobs:
  idle:
    runs-on: ubuntu-latest
    steps:
      - run: echo PAYLOAD_RAN
EOF
  expect 'agree: empty inline lists on a workflow writing no lock declare nothing' \
    "${work}/empty-lists-inline" 0 ''
  expect 'agree: lists aliased to empty on a workflow writing no lock declare nothing' \
    "${work}/empty-lists-alias" 0 ''

  # (z4) TOOLING: each resolving pass reads one level of an alias chain,
  # so a list value holding an alias of its own is text the lint cannot
  # read, and the run stops rather than score the alias marker as a path.
  write_generators "${work}/alias-list-residual"
  write_hooks "${work}/alias-list-residual" "${LOCK_ALPHA}" "${NOLOCK_BETA}"
  mkdir --parents -- "${work}/alias-list-residual/.github/workflows"
  cat >"${work}/alias-list-residual/.github/workflows/update-flake-lock.yml" <<'EOF'
name: update-flake-lock
on:
  workflow_dispatch:
permissions: {}
x-lock: &lock flake.lock
x-committable: &committable [*lock]
env:
  LOCK_DERIVED_GENERATORS: |
    scripts/refresh-alpha.sh
  COMMITTABLE_PATHS: *committable
jobs:
  compute:
    runs-on: ubuntu-latest
    steps:
      - run: |
          nix flake update
EOF
  expect 'tooling: a committable list still holding an alias after resolving is a could-not-run' \
    "${work}/alias-list-residual" 2 \
    'lock-derived-docs: .github/workflows/update-flake-lock.yml: env.COMMITTABLE_PATHS still holds a YAML alias after resolving; cannot read it'

  # (ac) BAD: beta-fresh's trigger uses negative lookaheads, the shape
  # pre-commit evaluates with Python `re`. Under that engine it matches
  # flake.lock, so the hook is lock-triggered and the bumper that skips
  # its generator has a gap. POSIX ERE has no lookahead, so a matcher
  # built on it reads this pattern as matching nothing and passes.
  write_tree "${work}/lookahead-lock" "${LOCK_ALPHA}" "${LOOKAHEAD_LOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  expect 'bad: a lookahead trigger matching flake.lock is lock-triggered' \
    "${work}/lookahead-lock" 1 \
    'hook beta-fresh declares flake.lock a trigger, but scripts/refresh-beta.sh is absent from LOCK_DERIVED_GENERATORS in .github/workflows/update-flake-lock.yml'

  # (ad) BAD: beta-fresh's lookahead rules flake.lock out, so the hook is
  # not lock-triggered and a workflow listing its generator lists one no
  # lock-triggered hook runs. The workflow name keeps this output apart
  # from the plain-ERE scenario with the same finding.
  write_generators "${work}/lookahead-nolock"
  write_hooks "${work}/lookahead-nolock" "${LOCK_ALPHA}" "${LOOKAHEAD_NOLOCK_BETA}"
  write_workflow "${work}/lookahead-nolock" 'lookahead-bump.yml' 'true' \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-beta.sh' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/beta.md'
  expect 'bad: a lookahead trigger excluding flake.lock is not lock-triggered' \
    "${work}/lookahead-nolock" 1 \
    'scripts/refresh-beta.sh is in LOCK_DERIVED_GENERATORS in .github/workflows/lookahead-bump.yml, but no lock-triggered hook runs it'

  # (ae) BAD: beta-fresh's `files` names flake.lock, but its `excludes`
  # list drops it again. pre-commit runs a hook on a path only when
  # `files` matches and `exclude` does not, so the hook is not
  # lock-triggered. The list is written across lines, as the real modules
  # write a long one, and the lock is its second entry, so every entry is
  # read rather than the first.
  write_generators "${work}/exclude-lock"
  write_hooks "${work}/exclude-lock" "${LOCK_ALPHA}" "${LOCK_BETA}" '' '' \
    $'    excludes = [\n      "^justfile$"\n      "^flake\\\\.lock$"\n    ];'
  write_workflow "${work}/exclude-lock" 'exclude-bump.yml' 'true' \
    $'    scripts/refresh-alpha.sh\n    scripts/refresh-beta.sh' \
    $'    flake.lock\n    docs/reference/alpha.md\n    docs/reference/beta.md'
  expect 'bad: a trigger whose excludes drop flake.lock is not lock-triggered' \
    "${work}/exclude-lock" 1 \
    'scripts/refresh-beta.sh is in LOCK_DERIVED_GENERATORS in .github/workflows/exclude-bump.yml, but no lock-triggered hook runs it'

  # (af) TOOLING: beta-fresh's trigger does not compile under Python `re`
  # (a variable-width look-behind). pre-commit cannot run such a hook, and
  # any verdict about whether it names the lock would be a guess.
  write_tree "${work}/files-uncompilable" "${LOCK_ALPHA}" "${UNCOMPILABLE_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  expect 'tooling: a files pattern that does not compile is a could-not-run' \
    "${work}/files-uncompilable" 2 \
    'hook beta-fresh: its files pattern does not compile under Python re'

  # (ag) TOOLING: the same for the merged `excludes` pattern.
  write_tree "${work}/exclude-uncompilable" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  write_hooks "${work}/exclude-uncompilable" "${LOCK_ALPHA}" "${NOLOCK_BETA}" '' '' \
    '    excludes = [ "^(unclosed" ];'
  expect 'tooling: an exclude pattern that does not compile is a could-not-run' \
    "${work}/exclude-uncompilable" 2 \
    'hook beta-fresh: its exclude pattern does not compile under Python re'

  # (ah) GOOD: ephemeral-refs-gap-fresh is lock-triggered but exempt — its
  # generator's output does not depend on lock content — so a workflow
  # that does not run it has no gap. The summary counts it apart from the
  # bound hooks.
  write_tree "${work}/exempt-hook" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  write_hooks "${work}/exempt-hook" "${LOCK_ALPHA}" "${NOLOCK_BETA}" '' '' '' \
    "$(exempt_block "${EXEMPT_LOCK_FILES}")"
  exempt_override='ephemeral-refs-gap-fresh'
  expect 'agree: an exempt lock-triggered hook needs no generator in the workflow' \
    "${work}/exempt-hook" 0 '2 lock-triggered (1 exempt)'

  # (ai) BAD: the exempt hook no longer declares flake.lock a trigger, so
  # its exemption excuses nothing and would silently excuse the next
  # trigger change instead.
  write_tree "${work}/exempt-stale" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  write_hooks "${work}/exempt-stale" "${LOCK_ALPHA}" "${NOLOCK_BETA}" '' '' '' \
    "$(exempt_block "${EXEMPT_NOLOCK_FILES}")"
  expect 'bad: an exemption for a hook not lock-triggered fails' \
    "${work}/exempt-stale" 1 \
    'hook ephemeral-refs-gap-fresh is exempt from LOCK_DERIVED_GENERATORS but does not declare flake.lock a trigger'

  # (aj) BAD: the exemption names a hook the module no longer has, so it
  # excuses nothing today and would excuse the next hook given that name.
  write_tree "${work}/exempt-absent" "${LOCK_ALPHA}" "${NOLOCK_BETA}" \
    '    scripts/refresh-alpha.sh' \
    $'    flake.lock\n    docs/reference/alpha.md'
  expect 'bad: an exemption naming no hook block fails' \
    "${work}/exempt-absent" 1 \
    'hook ephemeral-refs-gap-fresh is exempt from LOCK_DERIVED_GENERATORS but no hook block in nix/hooks/freshness.nix has that name'
  exempt_override=''

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
