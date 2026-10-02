#!/usr/bin/env bash
# tests/check-required-checks-no-paths.test.sh
# @subject scripts/check-required-checks-no-paths.sh
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
fixtures="${REPO_ROOT}/tests/fixtures/required-checks"
script="${REPO_ROOT}/scripts/check-required-checks-no-paths.sh"

failures=0

run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"

  local -r tmpdir="$(mktemp -d)"
  trap 'rm -rf -- "${tmpdir}"' RETURN

  # Build a fake repo layout: docs/security/required-checks.md + the fixture workflow.
  mkdir -p "${tmpdir}/docs/security" "${tmpdir}/.github/workflows"
  sed "s|__SCENARIO__|${fixture}|g" \
    "${fixtures}/required-checks.md" >"${tmpdir}/docs/security/required-checks.md"
  cp "${fixtures}/${fixture}" "${tmpdir}/.github/workflows/${fixture}"

  # The script resolves workflow paths relative to its own CWD. cd into the fake repo.
  local actual_exit=0
  (cd "${tmpdir}" && "${script}" >/dev/null 2>&1) || actual_exit=$?

  if [[ ${actual_exit} -eq ${expected_exit} ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  else
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    failures=$((failures + 1))
  fi
}

run_scenario 'ok fixture passes' 'ok.yml' 0
run_scenario 'paths: fixture fails' 'bad-paths.yml' 1
run_scenario 'paths-ignore: fixture fails' 'bad-paths-ignore.yml' 1

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

# @description Run the lint over workflows written at run time, each
# listed in a doc built beside them, and compare its exit code and its
# stderr. Bodies are written here rather than kept as fixtures so an
# unparsable one never sits in the tree for the formatters to refuse.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $3 `exact` to compare the whole of stderr, `holds` to look for each
#         line of the expected text in it, `under` to compare its last
#         line and require at least one line above that
# @arg $4 expected stderr text
# @arg $5 argument text of a `yq` read to fail, or empty for the real `yq`
# @arg $6 status the stub exits with
# @arg $@ workflow file name and body, alternating
function run_built_scenario() {
  local -r name="$1" expected_exit="$2" mode="$3" want="$4" pattern="$5" status="$6"
  shift 6

  local -r tmpdir="$(mktemp --directory)"
  mkdir --parents "${tmpdir}/docs/security" "${tmpdir}/.github/workflows"
  printf '| Context | Source workflow | Source file |\n| --- | --- | --- |\n' \
    >"${tmpdir}/docs/security/required-checks.md"
  while (($#)); do
    printf '%s' "$2" >"${tmpdir}/.github/workflows/$1"
    printf '| %s | built | .github/workflows/%s |\n' "${1%.yml}" "$1" \
      >>"${tmpdir}/docs/security/required-checks.md"
    shift 2
  done

  local run_path="${PATH}"
  if [[ -n ${pattern} ]]; then
    yq_stub "${pattern}" "${status}"
    run_path="${STUB_DIR}:${PATH}"
  fi
  local actual_exit=0 actual_stderr
  actual_stderr="$(cd "${tmpdir}" && PATH="${run_path}" "${script}" 2>&1 >/dev/null)" || actual_exit=$?
  rm --recursive --force -- "${tmpdir}"
  if [[ -n ${pattern} ]]; then rm --recursive --force -- "${STUB_DIR}"; fi

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n  stderr: %s\n' \
      "${name}" "${expected_exit}" "${actual_exit}" "${actual_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  local line missing=''
  if [[ ${mode} == exact ]]; then
    [[ ${actual_stderr} == "${want}" ]] || missing="${want}"
  elif [[ ${mode} == under ]]; then
    [[ ${actual_stderr} == *$'\n'"${want}" ]] || missing="${want}"
  else
    while IFS= read -r line; do
      [[ ${actual_stderr} == *"${line}"* ]] || missing="${line}"
    done <<<"${want}"
  fi
  if [[ -n ${missing} ]]; then
    printf 'FAIL: %s — stderr (%s) lacks %q\n  got: %s\n' \
      "${name}" "${mode}" "${missing}" "${actual_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
}

readonly PATHS_BODY=$'on:\n  pull_request:\n    paths: [a]\njobs: {}\n'
readonly PATHS_FINDING='declares paths/paths-ignore under pull_request'
readonly UNREAD='could not evaluate workflow with yq (malformed?): yq exited'
readonly LINT='required-checks-no-paths lint:'

# A failed read is not an answer about the workflow: with the one read
# failing, a workflow that declares `paths:` is counted, on a line naming
# `yq` and its status, and never scored clean.
run_built_scenario 'a failed yq read of a paths workflow is a finding' 1 exact \
  "${LINT} .github/workflows/w.yml: ${UNREAD} 7" \
  'has("paths")' 7 \
  w.yml "${PATHS_BODY}"

# A listed workflow that does not parse is a fact about this repo, so it
# is counted the same way, under `yq`'s own message.
run_built_scenario 'an unparsable workflow is a finding' 1 under \
  "${LINT} .github/workflows/broken.yml: ${UNREAD} 1" \
  '' 0 \
  broken.yml $'on: [push\n'

# The scan goes on past a workflow it could not read: the one listed
# after it is still held to the rule.
run_built_scenario 'the scan continues past an unparsable workflow' 1 holds \
  "${LINT} .github/workflows/a.yml: ${UNREAD} 1"$'\n'"${LINT} .github/workflows/b.yml ${PATHS_FINDING}" \
  '' 0 \
  a.yml $'on: [push\n' \
  b.yml "${PATHS_BODY}"

# Every shape of `on:` that carries no filter is read as clean, with no
# line of its own: the one finding is the workflow that declares one.
run_built_scenario 'filterless shapes of on: are clean beside a finding' 1 exact \
  "${LINT} .github/workflows/z-paths.yml ${PATHS_FINDING}" \
  '' 0 \
  on-string.yml $'on: pull_request\njobs: {}\n' \
  on-list.yml $'on: [push, pull_request]\njobs: {}\n' \
  no-pull-request.yml $'on:\n  push:\n    branches: [main]\njobs: {}\n' \
  null-pull-request.yml $'on:\n  pull_request:\njobs: {}\n' \
  branches-only.yml $'on:\n  pull_request:\n    branches: [main]\njobs: {}\n' \
  z-paths.yml "${PATHS_BODY}"

# An alias stands for the map it names: an `on:` and a `pull_request:`
# written through an anchor are read as that map. The clean workflow
# beside them keeps a reader that names every aliased file out.
run_built_scenario 'a filter reached through an alias is named' 1 exact \
  "${LINT} .github/workflows/on-alias.yml ${PATHS_FINDING}"$'\n'"${LINT} .github/workflows/pr-alias.yml ${PATHS_FINDING}" \
  '' 0 \
  on-alias.yml $'x: &t\n  pull_request:\n    paths: [a]\non: *t\njobs: {}\n' \
  clean-alias.yml $'x: &t\n  pull_request:\n    branches: [main]\non: *t\njobs: {}\n' \
  pr-alias.yml $'x: &t\n  paths: [a]\non:\n  pull_request: *t\njobs: {}\n'

# An `on:` map carrying a tag of its own is still a map.
run_built_scenario 'a filter under a tagged on: map is named' 1 exact \
  "${LINT} .github/workflows/tagged.yml ${PATHS_FINDING}" \
  '' 0 \
  tagged.yml $'on: !custom\n  pull_request:\n    paths: [a]\njobs: {}\n'

# A file holding two documents prints one answer per document; a filter
# in either is the finding.
run_built_scenario 'a filter in the second document is named' 1 exact \
  "${LINT} .github/workflows/two-docs.yml ${PATHS_FINDING}" \
  '' 0 \
  two-docs.yml $'on:\n  pull_request:\n    branches: [main]\n---\non:\n  pull_request:\n    paths: [a]\n'

run_built_scenario 'a paths-ignore filter is named' 1 exact \
  "${LINT} .github/workflows/ignore.yml ${PATHS_FINDING}" \
  '' 0 \
  ignore.yml $'on:\n  pull_request:\n    paths-ignore: [docs/**]\njobs: {}\n'

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
