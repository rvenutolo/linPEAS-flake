#!/usr/bin/env bash
# @subject mkdocs.yml
# tests/site-no-bytecode.test.sh — proves the Pages site build publishes no
# Python bytecode.
#
# mkdocs-macros imports `docs/_data/macros.py`, and Python writes
# `docs/_data/__pycache__/` beside it inside `docs_dir`; mkdocs copies every
# non-Markdown file under `docs_dir` into the site. Two builds of the same
# content then differ in the `.pyc` alone, and the site ships a compiled file
# nobody reads. `just site` builds from a `path:` source, which also carries
# whatever ignored `__pycache__/` a local checkout holds into `docs_dir`.
#
# Each scenario copies the tracked tree into a scratch directory, adds the
# fixture `dashboard.yml` (the real one is gitignored and generated), and
# runs `mkdocs build --strict` there with bytecode writing enabled. It
# requires a successful build, a rendered index page, and no `__pycache__`
# directory or `.pyc` file anywhere in the output.
#   - `build-writes-bytecode`: a clean tree; the build itself writes the
#     `.pyc` beside `macros.py`.
#   - `stale-bytecode-in-docs`: a `.pyc` already sits under `docs/_data/`, as
#     in a checkout that was built before.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly FIXTURE_DASHBOARD="${REPO_ROOT}/tests/fixtures/site-no-bytecode/dashboard.yml"

if ! command -v mkdocs >/dev/null; then
  printf 'site-no-bytecode: mkdocs is not on PATH (run inside the devShell)\n' >&2
  exit 2
fi

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# @description Copy the tracked tree, as it is on disk, into a fresh scratch
# directory and add the fixture dashboard data. A tracked file deleted in the
# working tree is skipped rather than failing the copy.
# @arg $1 destination directory
function stage_tree() {
  local -r dest="$1"
  mkdir --parents -- "${dest}"
  git -C "${REPO_ROOT}" ls-files -z --cached |
    tar --directory="${REPO_ROOT}" --null --files-from=- --ignore-failed-read --create |
    tar --directory="${dest}" --extract
  cp -- "${FIXTURE_DASHBOARD}" "${dest}/docs/_data/dashboard.yml"
}

# @description Build the site from a scratch copy and assert it holds no
# bytecode.
# @arg $1 scenario name  @arg $2 relative path of a `.pyc` to plant under the
# copy before the build ('' plants none)
function run_scenario() {
  local -r name="$1" planted="$2"
  local -r tree="${work}/${name}/tree"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r report="${work}/${name}.report"

  stage_tree "${tree}"
  if [[ -n ${planted} ]]; then
    mkdir --parents -- "$(dirname -- "${tree}/${planted}")"
    printf 'stale\n' >"${tree}/${planted}"
  fi

  local rc=0
  (
    cd -- "${tree}"
    env --unset=PYTHONDONTWRITEBYTECODE --unset=BASH_ENV \
      timeout 10m mkdocs build --strict --site-dir "${work}/${name}/site" \
      </dev/null >"${out}" 2>"${err}"
  ) || rc=$?

  local found=''
  if [[ -d ${work}/${name}/site ]]; then
    found="$(find "${work}/${name}/site" \( -name '__pycache__' -o -name '*.pyc' \) -printf '%P\n' | sort)"
  fi
  local rendered='no'
  [[ -s ${work}/${name}/site/index.html ]] && rendered='yes'
  {
    printf 'harness-assert-outcome: exit=%d\n' "${rc}"
    printf 'planted: %s\n' "${planted:-none}"
    printf 'index rendered: %s\n' "${rendered}"
    printf 'bytecode in site: %s\n' "${found:-none}"
  } >"${report}"

  if [[ ${rc} -ne 0 || ${rendered} != yes ]]; then
    printf 'FAIL: %s — the build did not complete (exit %d)\n' "${name}" "${rc}" >&2
    cat -- "${out}" "${err}" >&2
    failures=$((failures + 1))
  elif [[ -n ${found} ]]; then
    printf 'FAIL: %s — the site holds bytecode:\n%s\n' "${name}" "${found}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (no bytecode in the site)\n' "${name}"
  fi

  harness_assert_record "${name}" 'bytecode in site: none' "${report}"
}

run_scenario 'build-writes-bytecode' ''
run_scenario 'stale-bytecode-in-docs' 'docs/_data/__pycache__/stale.cpython-0.pyc'

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
