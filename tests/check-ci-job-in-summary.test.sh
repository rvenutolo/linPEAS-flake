#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-ci-job-in-summary.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/ci-job-in-summary"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  # Optional 4th/5th args override the lint-groups manifest + scripts dir
  # so the manifest-coverage assertion can be exercised against a fixture.
  # Optional 6th arg overrides the EXEMPT list. Only set when provided so
  # the script's own defaults apply otherwise.
  local -a env_overrides=(
    "WORKFLOWS_DIR_OVERRIDE=${FIXTURES}/${fixture}"
    "CI_WORKFLOW_OVERRIDE=${FIXTURES}/${fixture}/ci.yml"
    "CATEGORIES_FILE_OVERRIDE=${FIXTURES}/${fixture}/categories.yml"
  )
  [[ -n ${4:-} ]] && env_overrides+=("LINT_GROUPS_OVERRIDE=${4}")
  [[ -n ${5:-} ]] && env_overrides+=("SCRIPTS_DIR_OVERRIDE=${5}")
  [[ -n ${6:-} ]] && env_overrides+=("EXEMPT_OVERRIDE=${6}")
  local got_exit=0 got_stderr
  got_stderr="$(env "${env_overrides[@]}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good 0 ""
expect bad-missing-category 1 "EXEMPT"
expect bad-orphan-category 1 "does not match any job"
# Manifest coverage: a lint-groups basename with no real check script fails.
expect bad-missing-manifest-check 1 "lint-groups basename" \
  "${FIXTURES}/bad-missing-manifest-check/lint-groups.yml" \
  "${FIXTURES}/bad-missing-manifest-check/scripts"
# A missing manifest is a hard infrastructure error, not drift: nothing was
# cross-checked, so it carries the could-not-run code (exit 2).
expect good 2 "manifest not found" \
  "${FIXTURES}/bad-missing-manifest-check/does-not-exist.yml" \
  "${FIXTURES}/bad-missing-manifest-check/scripts"
# An unmapped auxiliary job with no EXEMPT entry fails — the exemption in
# the next scenario is load-bearing, not incidentally passing.
expect good-exempt 1 "EXEMPT"
# An EXEMPT entry naming a real, unmapped ci.yml job exempts it.
expect good-exempt 0 "" "" "" "aux"
# An EXEMPT entry that is not a ci.yml job exempts nothing.
expect good 1 "is not a job" "" "" "not-a-real-job"
# An EXEMPT entry that is already a category key exempts nothing — the
# forward loop matches the category map first and never reaches it.
expect good 1 "already a key" "" "" "foo"
# A lint-groups manifest yq cannot parse is a tooling error, not drift
# — it must fail loud (exit 2) rather than silently skip coverage.
expect good 2 "" "${FIXTURES}/bad-malformed-manifest/lint-groups.yml" ""

# The two files the cross-check reads are inputs, not findings: absent, the
# lint has compared nothing and must not report drift.
expect does-not-exist 2 "ci workflow not found"
# Present but unparsable is the same verdict as absent, and for the same
# reason: neither file was read, so nothing was cross-checked. Left to
# `set -e`, yq's own exit 1 reaches the caller as a job missing from the
# summary — drift found in a document this run never opened.
expect bad-malformed-ci 2 "cannot read job keys"
expect bad-malformed-categories 2 "cannot read category keys"

# @description Make a directory holding a `yq` that exits with a given
# status for every call whose arguments hold a given string and hands any
# other call to the real `yq`, and point STUB_DIR at it. A scenario puts
# the directory first on PATH for its own run only.
# @arg $1 argument text that marks the failing call
# @arg $2 exit status for that call
function yq_stub() {
  local real_yq
  real_yq="$(command -v yq)"
  STUB_DIR="$(mktemp --directory)"
  printf '#!/usr/bin/env bash\ncase "$*" in *%q*) exit %d ;; esac\nexec %q "$@"\n' \
    "$1" "$2" "${real_yq}" >"${STUB_DIR}/yq"
  chmod +x -- "${STUB_DIR}/yq"
}

# @description Run the lint over a workflows directory whose job keys one
# `yq` read cannot produce. The reverse check holds every category entry
# against the jobs of every workflow, so a workflow it could not read
# leaves that set short: the run must stop as a could-not-run, on a line
# naming the file, `yq` and its status, rather than report entries the
# unread file may hold, or pass without it.
# @arg $1 scenario label
# @arg $2 workflows directory (holding ci.yml and categories.yml)
# @arg $3 file the line must name
# @arg $4 status the line must carry
# @arg $5 argument text of the read to fail, or empty for the real `yq`,
#         whose own message must then sit above the line
function expect_unread_workflow() {
  local -r label="$1" dir="$2" file="$3" status="$4" pattern="$5"
  local -r want="cannot read job keys from ${file}: yq exited ${status}"
  local run_path="${PATH}" got_exit=0 got_stderr
  if [[ -n ${pattern} ]]; then
    yq_stub "${pattern}" "${status}"
    run_path="${STUB_DIR}:${PATH}"
  fi
  got_stderr="$(PATH="${run_path}" WORKFLOWS_DIR_OVERRIDE="${dir}" \
    CI_WORKFLOW_OVERRIDE="${dir}/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${dir}/categories.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ -n ${pattern} ]]; then rm --recursive --force -- "${STUB_DIR}"; fi
  if [[ ${got_exit} != 2 ]]; then
    printf 'FAIL %s: exit %s, want 2\n  stderr: %s\n' "${label}" "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  # The last line, so that `yq`'s own message above it is allowed and a
  # verdict printed after it is not.
  if [[ -z ${pattern} && ${got_stderr} != *$'\n'* ]]; then
    printf 'FAIL %s: nothing printed above the line\n  got: %s\n' "${label}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr##*$'\n'} != "${want}" ]]; then
    printf 'FAIL %s: last stderr line is not %q\n  got: %s\n' "${label}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

# The stub text ends in the file's path, which only the per-workflow read
# of that one file carries: the read of ci.yml's own job list has no
# `explode`.
expect_unread_workflow 'failed read of a workflow holding mapped jobs' \
  "${FIXTURES}/good" "${FIXTURES}/good/ci.yml" 7 \
  "explode(.) | keys | .[] ${FIXTURES}/good/ci.yml"
expect_unread_workflow 'failed read of a workflow holding no job' \
  "${FIXTURES}/good" "${FIXTURES}/good/categories.yml" 9 \
  "explode(.) | keys | .[] ${FIXTURES}/good/categories.yml"

# A workflow that does not parse, written at run time so no unparsable
# file sits in the tree for the formatters to refuse.
unparsable_dir="$(mktemp --directory)"
cp -- "${FIXTURES}/good/ci.yml" "${FIXTURES}/good/categories.yml" "${unparsable_dir}/"
printf 'on: [push\n' >"${unparsable_dir}/broken.yml"
expect_unread_workflow 'unparsable workflow beside ci.yml' \
  "${unparsable_dir}" "${unparsable_dir}/broken.yml" 1 ''
rm --recursive --force -- "${unparsable_dir}"

# A run that could not read a workflow has cross-checked nothing, so it
# prints no drift line either: the unmapped job beside the unparsable
# workflow is not reported under the could-not-run code.
drift_dir="$(mktemp --directory)"
cp -- "${FIXTURES}/bad-missing-category/ci.yml" "${FIXTURES}/bad-missing-category/categories.yml" "${drift_dir}/"
printf 'on: [push\n' >"${drift_dir}/broken.yml"
drift_exit=0
drift_stderr="$(WORKFLOWS_DIR_OVERRIDE="${drift_dir}" \
  CI_WORKFLOW_OVERRIDE="${drift_dir}/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${drift_dir}/categories.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || drift_exit=$?
rm --recursive --force -- "${drift_dir}"
if [[ ${drift_exit} != 2 || ${drift_stderr} == *'EXEMPT'* ||
  ${drift_stderr} != *"cannot read job keys from ${drift_dir}/broken.yml: yq exited 1" ]]; then
  printf 'FAIL drift beside an unparsable workflow: exit %s, want 2 and no drift line\n  stderr: %s\n' \
    "${drift_exit}" "${drift_stderr}" >&2
  exit 1
fi
printf 'OK   drift beside an unparsable workflow\n'

# A missing or unreadable lint-groups manifest stops the run before any
# check prints: beside an unmapped job, no drift line is reported under
# the could-not-run code.
manifest_dir="$(mktemp --directory)"
manifest_exit=0
manifest_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}/bad-missing-category" \
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/bad-missing-category/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${FIXTURES}/bad-missing-category/categories.yml" \
  LINT_GROUPS_OVERRIDE="${manifest_dir}/absent.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || manifest_exit=$?
if [[ ${manifest_exit} != 2 || ${manifest_stderr} != "lint-groups manifest not found: ${manifest_dir}/absent.yml" ]]; then
  printf 'FAIL drift beside a missing manifest: exit %s, want 2 and only the manifest line\n  stderr: %s\n' \
    "${manifest_exit}" "${manifest_stderr}" >&2
  exit 1
fi
printf 'OK   drift beside a missing manifest\n'
printf 'a: [\n' >"${manifest_dir}/broken.yml"
manifest_exit=0
manifest_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}/bad-missing-category" \
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/bad-missing-category/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${FIXTURES}/bad-missing-category/categories.yml" \
  LINT_GROUPS_OVERRIDE="${manifest_dir}/broken.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || manifest_exit=$?
rm --recursive --force -- "${manifest_dir}"
if [[ ${manifest_exit} != 2 || ${manifest_stderr} == *'EXEMPT'* ||
  ${manifest_stderr} != *$'\n'"${manifest_dir}/broken.yml: could not evaluate lint-groups manifest with yq (malformed?)" ]]; then
  printf 'FAIL drift beside an unparsable manifest: exit %s, want 2 and no drift line\n  stderr: %s\n' \
    "${manifest_exit}" "${manifest_stderr}" >&2
  exit 1
fi
printf 'OK   drift beside an unparsable manifest\n'

# A `jobs:` written as an alias stands for the map it names: its keys are
# job keys, and the category entry naming one of them resolves. Only
# `jobs:` is resolved: a merge key `yq` cannot resolve elsewhere in a
# workflow leaves its job keys readable.
alias_dir="$(mktemp --directory)"
cp -- "${FIXTURES}/good/ci.yml" "${alias_dir}/"
printf 'foo: Category-A\nbar: Category-B\nbaz: Category-C\n' >"${alias_dir}/categories.yml"
printf 'x: &j\n  baz:\n    runs-on: ubuntu-latest\njobs: *j\n' >"${alias_dir}/aliased.yml"
printf 'c: &c [x]\nenv:\n  <<: *c\njobs:\n  foo:\n    runs-on: ubuntu-latest\n' >"${alias_dir}/merge-elsewhere.yml"
alias_exit=0
alias_stderr="$(WORKFLOWS_DIR_OVERRIDE="${alias_dir}" \
  CI_WORKFLOW_OVERRIDE="${alias_dir}/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${alias_dir}/categories.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || alias_exit=$?
rm --recursive --force -- "${alias_dir}"
if [[ ${alias_exit} != 0 || -n ${alias_stderr} ]]; then
  printf 'FAIL jobs written as an alias: exit %s, want 0 and no output\n  stderr: %s\n' \
    "${alias_exit}" "${alias_stderr}" >&2
  exit 1
fi
printf 'OK   jobs written as an alias\n'

missing_categories_exit=0
missing_categories_stderr="$(env \
  "WORKFLOWS_DIR_OVERRIDE=${FIXTURES}/good" \
  "CI_WORKFLOW_OVERRIDE=${FIXTURES}/good/ci.yml" \
  "CATEGORIES_FILE_OVERRIDE=${FIXTURES}/good/does-not-exist.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || missing_categories_exit=$?
if [[ ${missing_categories_exit} != 2 ]]; then
  printf 'FAIL missing-categories: exit %s, want 2\n  stderr: %s\n' \
    "${missing_categories_exit}" "${missing_categories_stderr}" >&2
  exit 1
fi
if [[ ${missing_categories_stderr} != *"categories file not found"* ]]; then
  printf 'FAIL missing-categories: stderr missing %q\n  got: %s\n' \
    "categories file not found" "${missing_categories_stderr}" >&2
  exit 1
fi
printf 'OK   missing-categories\n'

# --print-exempt is the shared source of the ci-job exemption list for
# scripts/refresh-enforcement-matrix.sh. It must exit 0 and emit exactly
# the list — nothing at all when the list is empty, so that an empty
# stdout means "no exemptions" and a nonzero exit means "unreadable".
function expect_print_exempt() {
  local -r label="$1" override="$2" want="$3"
  local got exit_code=0
  if [[ -n ${override} ]]; then
    got="$(EXEMPT_OVERRIDE="${override}" "${SCRIPT}" --print-exempt)" || exit_code=$?
  else
    got="$("${SCRIPT}" --print-exempt)" || exit_code=$?
  fi
  if [[ ${exit_code} != 0 ]]; then
    printf 'FAIL %s: exit %s, want 0\n' "${label}" "${exit_code}" >&2
    return 1
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL %s: got %q, want %q\n' "${label}" "${got}" "${want}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

expect_print_exempt 'print-exempt: empty list prints nothing' "" ""
expect_print_exempt 'print-exempt: single entry' "aux-sandbox" "aux-sandbox"
expect_print_exempt 'print-exempt: multiple entries, one per line' \
  $'aux-one\naux-two' $'aux-one\naux-two'

# An unrecognized argument exits 2 so a caller that asks for a mode this
# script does not have fails loud instead of reading an empty list.
unknown_arg_exit=0
"${SCRIPT}" --not-a-mode >/dev/null 2>&1 || unknown_arg_exit=$?
if [[ ${unknown_arg_exit} != 2 ]]; then
  printf 'FAIL unknown-argument: exit %s, want 2\n' "${unknown_arg_exit}" >&2
  exit 1
fi
printf 'OK   unknown-argument\n'

printf 'all tests passed\n'
