#!/usr/bin/env bash
# tests/refresh-ci-summary.test.sh
#
# Round-trip + drift harness for scripts/refresh-ci-summary.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# The harness rewrites generated docs and fixture modes, so it runs in a
# scratch copy of the tree and leaves this checkout untouched.
# shellcheck source=scripts/lib/scratch-tree.sh
source "${REPO_ROOT}/scripts/lib/scratch-tree.sh"
reexec_in_scratch_tree "$@"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-ci-summary.sh"
readonly DOC="${REPO_ROOT}/README.md"
readonly CAT_MAP="${REPO_ROOT}/docs/_data/ci-check-categories.yml"
readonly REQ_DOC="${REPO_ROOT}/docs/security/required-checks.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Declared at top-level so the EXIT trap can reference it across function
# boundaries (mirrors tests/refresh-just-recipes.test.sh).
backup=''
map_backup=''
req_backup=''

# @description Run the generator once with the given category map (and,
# when the rows are non-empty, a required-checks doc holding only those
# rows), capturing its exit code, output and the README it writes, then
# restore every input. Prints nothing.
# @arg $1 work dir  @arg $2 run name  @arg $3 category map  @arg $4 rows ('' keeps the doc)
function summary_run() {
  local -r work="$1" run="$2" map="$3" rows="$4"
  local run_rc=0
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  map_backup="$(mktemp)"
  cp -- "${CAT_MAP}" "${map_backup}"
  req_backup="$(mktemp)"
  cp -- "${REQ_DOC}" "${req_backup}"
  cp -- "${map}" "${work}/${run}.map"
  cp -- "${work}/${run}.map" "${CAT_MAP}"
  if [[ -n ${rows} ]]; then
    printf '%s' "${rows}" >"${REQ_DOC}"
  fi
  "${SCRIPT}" >"${work}/${run}.out" 2>"${work}/${run}.err" || run_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${run_rc}" >"${work}/${run}.outcome"
  cp -- "${DOC}" "${work}/${run}.md"
  cp -- "${backup}" "${DOC}"
  cp -- "${map_backup}" "${CAT_MAP}"
  cp -- "${req_backup}" "${REQ_DOC}"
  rm --force -- "${backup}" "${map_backup}" "${req_backup}"
  backup=''
  map_backup=''
  req_backup=''
}

# @description Require an aliased category map to render the README its
# inline twin renders, byte for byte, with exit 0 and the one log line.
# @arg $1 work dir  @arg $2 scenario name  @arg $3 aliased map
# @arg $4 inline map  @arg $5 required-checks rows ('' keeps the doc)
function summary_alias_case() {
  local -r work="$1" name="$2" aliased="$3" inline="$4" rows="$5"
  summary_run "${work}" aliased "${aliased}" "${rows}"
  summary_run "${work}" inline "${inline}" "${rows}"
  harness_assert_record "${name}" '' \
    "${work}/aliased.outcome" "${work}/aliased.md" "${work}/aliased.out" "${work}/aliased.err" \
    "${work}/inline.outcome" "${work}/inline.md" "${work}/inline.out" "${work}/inline.err"
  if [[ $(<"${work}/inline.outcome") == 'harness-assert-outcome: exit=0' ]] &&
    [[ $(<"${work}/aliased.outcome") == 'harness-assert-outcome: exit=0' ]] &&
    [[ $(<"${work}/aliased.err") =~ ^\[[^]]*\]\ INFO\ \ refreshed\ CI\ summary\ block\ in\ README\.md$ ]] &&
    [[ ! -s ${work}/aliased.out ]] &&
    cmp --silent -- "${work}/aliased.md" "${work}/inline.md"; then
    pass "${name} renders the inline block"
  else
    fail "${name}: aliased $(<"${work}/aliased.outcome"), inline $(<"${work}/inline.outcome"); want both exit 0, one log line and the same README"
    cat -- "${work}/aliased.err" >&2
    diff -u -- "${work}/inline.md" "${work}/aliased.md" >&2 || true
  fi
}

function main() {
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated block'
  else
    fail '--check failed right after generate'
  fi

  # Assertion 2: the regenerated block is exhaustive — contains required
  # contexts that were missing from the old curated summary.
  if grep --quiet 'gitleaks' "${DOC}" &&
    grep --quiet 'required-checks-no-paths' "${DOC}"; then
    pass 'block is exhaustive (contains gitleaks and required-checks-no-paths)'
  else
    fail 'block missing exhaustive contexts (gitleaks and/or required-checks-no-paths)'
  fi

  # Assertion 3: in-block drift makes --check exit non-zero.
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  trap 'if [[ -n "${backup:-}" && -f "${backup}" ]]; then cp -- "${backup}" "${DOC}" 2>/dev/null || true; rm --force -- "${backup}"; fi
        if [[ -n "${map_backup:-}" && -f "${map_backup}" ]]; then cp -- "${map_backup}" "${CAT_MAP}" 2>/dev/null || true; rm --force -- "${map_backup}"; fi
        if [[ -n "${req_backup:-}" && -f "${req_backup}" ]]; then cp -- "${req_backup}" "${REQ_DOC}" 2>/dev/null || true; rm --force -- "${req_backup}"; fi' EXIT
  awk '
    { print }
    /^<!-- BEGIN ci-summary -->$/ { print "- **Drift**: `bogus-context`." }
  ' "${DOC}" >"${DOC}.tmp"
  mv -- "${DOC}.tmp" "${DOC}"
  local rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc} -ne 0 ]]; then
    pass '--check fails on in-block drift'
  else
    fail '--check passed despite in-block drift'
  fi

  # Assertion 4: generator fails if a required context has no category-map entry.
  map_backup="$(mktemp)"
  cp -- "${CAT_MAP}" "${map_backup}"
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  # Remove the gitleaks mapping line from the category map.
  grep --invert-match '^gitleaks:' "${CAT_MAP}" >"${CAT_MAP}.tmp"
  mv -- "${CAT_MAP}.tmp" "${CAT_MAP}"
  local rc2=0
  "${SCRIPT}" --check || rc2=$?
  cp -- "${map_backup}" "${CAT_MAP}"
  rm --force -- "${map_backup}"
  map_backup=''
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc2} -ne 0 ]]; then
    pass '--check fails when required context has no category-map entry'
  else
    fail '--check passed despite missing category-map entry for gitleaks'
  fi

  # Assertion 5: generator fails when a category-map key has no
  # required-checks entry (divergence direction 2: map key not in
  # required contexts).
  req_backup="$(mktemp)"
  cp -- "${REQ_DOC}" "${req_backup}"
  # Orphan gitleaks: drop its required-checks row, leaving gitleaks: in the map.
  grep --invert-match --extended-regexp '^\| *gitleaks *\|' "${REQ_DOC}" >"${REQ_DOC}.tmp"
  mv -- "${REQ_DOC}.tmp" "${REQ_DOC}"
  local rc3=0
  "${SCRIPT}" --check || rc3=$?
  cp -- "${req_backup}" "${REQ_DOC}"
  rm --force -- "${req_backup}"
  req_backup=''
  if [[ ${rc3} -ne 0 ]]; then
    pass '--check fails when category-map key has no required-checks entry'
  else
    fail '--check passed despite orphaned category-map key gitleaks'
  fi

  # Assertion 6: markers the anchored awk splice cannot match (trailing
  # whitespace on both markers) must be rejected by the guard, not silently
  # emitted unchanged. An unanchored guard grep false-greens here; the
  # anchored guard fails closed with a marker-missing message.
  backup="$(mktemp)"
  ws_err="$(mktemp)"
  ws_out="$(mktemp)"
  ws_outcome="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  sed -e 's/^<!-- BEGIN ci-summary -->$/<!-- BEGIN ci-summary --> /' \
    -e 's/^<!-- END ci-summary -->$/<!-- END ci-summary --> /' \
    "${backup}" >"${DOC}"
  local rc4=0
  "${SCRIPT}" --check >"${ws_out}" 2>"${ws_err}" || rc4=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  # The record is the whole observable outcome — exit code, stdout, stderr —
  # so a scenario that differs from a sibling only in how it ended still
  # reads as a distinct observation.
  printf 'harness-assert-outcome: exit=%d\n' "${rc4}" >"${ws_outcome}"
  harness_assert_record 'whitespace-perturbed markers rejected' \
    'marker missing' "${ws_outcome}" "${ws_out}" "${ws_err}"
  if [[ ${rc4} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'marker missing' "${ws_err}"; then
    pass 'whitespace-perturbed markers rejected (fail-closed, not false-green)'
  else
    fail "whitespace marker guard: expected exit 1 + 'marker missing', got exit ${rc4}"
    cat -- "${ws_err}" >&2
  fi
  rm --force -- "${ws_err}" "${ws_out}" "${ws_outcome}"

  # A category map written with aliases renders the block the same map
  # written inline renders, byte for byte: a category value written as an
  # alias in the real map, a context key written as an alias, and a value
  # nesting aliases three deep. Each pair is recorded as one scenario:
  # the aliased and inline runs are meant to emit the same output.
  local alias_work
  alias_work="$(mktemp --directory)"
  sed --expression='0,/: Build + smoke$/s//: \&bs Build + smoke/' \
    --expression='s/: Build + smoke$/: *bs/' \
    "${CAT_MAP}" >"${alias_work}/value-alias.yml"
  summary_alias_case "${alias_work}" 'a category value written as an alias' \
    "${alias_work}/value-alias.yml" "${CAT_MAP}" ''
  local key_rows=$'| alpha | x |\n| beta | x |\n| smoke | x |\n'
  printf 'alpha: smoke\nbeta: smoke\nsmoke: Build + smoke\n' >"${alias_work}/key-inline.yml"
  printf 'alpha: &s smoke\nbeta: *s\n*s : Build + smoke\n' >"${alias_work}/key-alias.yml"
  summary_alias_case "${alias_work}" 'a context key written as an alias' \
    "${alias_work}/key-alias.yml" "${alias_work}/key-inline.yml" "${key_rows}"
  local deep_rows=$'| alpha | x |\n| beta | x |\n| gamma | x |\n| delta | x |\n'
  printf 'alpha: smoke\nbeta: [smoke]\ngamma: [[smoke]]\ndelta: [[[smoke]]]\n' >"${alias_work}/deep-inline.yml"
  printf 'alpha: &s smoke\nbeta: &l1 [*s]\ngamma: &l2 [*l1]\ndelta: [*l2]\n' >"${alias_work}/deep-alias.yml"
  summary_alias_case "${alias_work}" 'a category value nesting aliases three deep' \
    "${alias_work}/deep-alias.yml" "${alias_work}/deep-inline.yml" "${deep_rows}"
  rm --recursive --force -- "${alias_work}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
