#!/usr/bin/env bash
# tests/gitleaks-merge-diffs.test.sh
#
# Spec harness for scripts/gitleaks-merge-diffs.sh. Every fixture repo is
# built in a temp dir at run time, and the secret-shaped token is
# concatenated from parts there, so no secret-shaped literal exists in the
# tree for the repo's own scanners to flag.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/gitleaks-merge-diffs.sh"

failures=0
work=""

# shellcheck disable=SC2329 # invoked indirectly, by the EXIT trap
function cleanup() {
  if [[ -n ${work} ]]; then rm --recursive --force -- "${work}"; fi
}
trap cleanup EXIT

# @description Print a gitleaks github-pat shaped token. Assembled from
# parts so the harness source never holds the whole shape.
# @noargs
function fake_token() {
  local -r prefix='gh' kind='p_' half1='q8Rz3TkWm2Yv7Lp9' half2='Nx4Bc6HdJ0aGf5Wz1KsQ'
  printf '%s%s%s%s' "${prefix}" "${kind}" "${half1}" "${half2}"
}

# @description Run git in a fixture repo with a fixed identity and no
# signing, so the host's git config cannot change the fixture.
# @arg $1 repo dir  @arg $2... git arguments
function fgit() {
  local -r dir="$1"
  shift
  git -C "${dir}" -c user.name=harness -c user.email=harness@example.invalid \
    -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main \
    -c rerere.enabled=false "$@"
}

# @description Build a repo where only a conflict-resolving merge commit
# adds the token. Prints nothing; the dir layout is:
# base commit on main, one commit each on main and feature touching the
# same line, then `Merge branch 'main' into feature` whose resolution
# alone carries the token. Tags: `base`, `main-tip`, `feature-tip`.
# @arg $1 dir
function build_merge_token_repo() {
  local -r dir="$1"
  mkdir --parents -- "${dir}"
  fgit "${dir}" init --quiet
  printf 'value=base\n' >"${dir}/conf.txt"
  fgit "${dir}" add conf.txt
  fgit "${dir}" commit --quiet --message base
  fgit "${dir}" tag base
  fgit "${dir}" switch --quiet --create feature
  printf 'value=feature\n' >"${dir}/conf.txt"
  fgit "${dir}" commit --quiet --all --message feature
  fgit "${dir}" switch --quiet main
  printf 'value=main\n' >"${dir}/conf.txt"
  fgit "${dir}" commit --quiet --all --message main
  fgit "${dir}" tag main-tip
  fgit "${dir}" switch --quiet feature
  fgit "${dir}" merge --quiet main >/dev/null 2>&1 || true
  printf 'value=resolved\ntoken=%s\n' "$(fake_token)" >"${dir}/conf.txt"
  fgit "${dir}" add conf.txt
  fgit "${dir}" commit --quiet --no-edit
  fgit "${dir}" tag feature-tip
}

# @description Build a repo with a clean merge (no own changes) and no
# token anywhere. Tags: `main-tip`, `feature-tip`.
# @arg $1 dir
function build_clean_merge_repo() {
  local -r dir="$1"
  mkdir --parents -- "${dir}"
  fgit "${dir}" init --quiet
  printf 'a\n' >"${dir}/a.txt"
  fgit "${dir}" add a.txt
  fgit "${dir}" commit --quiet --message base
  fgit "${dir}" switch --quiet --create feature
  printf 'b\n' >"${dir}/b.txt"
  fgit "${dir}" add b.txt
  fgit "${dir}" commit --quiet --message feature
  fgit "${dir}" switch --quiet main
  printf 'c\n' >"${dir}/c.txt"
  fgit "${dir}" add c.txt
  fgit "${dir}" commit --quiet --message main
  fgit "${dir}" tag main-tip
  fgit "${dir}" switch --quiet feature
  fgit "${dir}" merge --quiet --no-edit main
  fgit "${dir}" tag feature-tip
}

# @description Resolve a tag in a fixture repo to its commit SHA.
# @arg $1 dir  @arg $2 tag
function sha_of() {
  git -C "$1" rev-parse --verify --quiet "$2^{commit}"
}

# @description Run the script with an env assignment list; assert exit
# code and a stdout-or-stderr substring.
# @arg $1 scenario name  @arg $2 expected exit  @arg $3 expected substring
# (searched in stdout then stderr)  @arg $4... `VAR=value` env entries,
# then `--` and the script's arguments
function run_scenario() {
  local -r name="$1" expected_exit="$2" expected="$3"
  shift 3
  local -a envs=()
  while (($# > 0)) && [[ $1 != -- ]]; do
    envs+=("$1")
    shift
  done
  if (($# > 0)); then shift; fi

  local out err outcome
  out="${work}/out" err="${work}/err" outcome="${work}/outcome"
  local actual_exit=0
  env --unset=BASH_ENV --unset=EVENT_NAME --unset=BASE_SHA --unset=HEAD_SHA \
    "${envs[@]}" "${SCRIPT}" "$@" >"${out}" 2>"${err}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome}"
  harness_assert_record "${name}" "${expected}" "${outcome}" "${out}" "${err}"

  local failed=0
  if ((actual_exit != expected_exit)); then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    failed=1
  fi
  if ! grep --fixed-strings --quiet -- "${expected}" "${out}" "${err}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected}" >&2
    failed=1
  fi
  if ((failed)); then
    printf -- '--- stdout\n' >&2
    cat -- "${out}" >&2
    printf -- '--- stderr\n' >&2
    cat -- "${err}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
}

# @description The fixture must reproduce the gap the script closes: the
# action-equivalent range scan (`--no-merges --first-parent`) misses the
# merge-only token. If it does not, every detection scenario below proves
# nothing about merge diffs.
# @arg $1 dir  @arg $2 base sha  @arg $3 head sha
function check_gap_control() {
  local -r dir="$1" base="$2" head="$3"
  local rc=0
  gitleaks git --no-banner --log-opts="--no-merges --first-parent ${base}^..${head}" \
    "${dir}" >/dev/null 2>&1 || rc=$?
  if ((rc != 0)); then
    printf 'FAIL: gap control — action-equivalent scan exited %d; fixture does not isolate a merge-only change\n' "${rc}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: gap control (action-equivalent scan misses the merge-only token)\n'
  fi
}

function main() {
  work="$(mktemp -d)"
  local -r tok="${work}/tok" clean="${work}/clean"
  build_merge_token_repo "${tok}"
  build_clean_merge_repo "${clean}"
  local tok_main tok_feature tok_base clean_main clean_feature
  tok_main="$(sha_of "${tok}" main-tip)"
  tok_feature="$(sha_of "${tok}" feature-tip)"
  tok_base="$(sha_of "${tok}" base)"
  clean_main="$(sha_of "${clean}" main-tip)"
  clean_feature="$(sha_of "${clean}" feature-tip)"
  local -r zero='0000000000000000000000000000000000000000'

  check_gap_control "${tok}" "${tok_main}" "${tok_feature}"

  run_scenario 'pull_request range: merge-only token detected' 1 \
    "event=pull_request range=${tok_main}..${tok_feature} merges=1" \
    EVENT_NAME=pull_request "BASE_SHA=${tok_main}" "HEAD_SHA=${tok_feature}" -- --source "${tok}"
  run_scenario 'a finding is reported with its count' 1 \
    "gitleaks found 1 secret(s) in merge commit diffs (event=push range=${tok_main}..${tok_feature})" \
    EVENT_NAME=push "BASE_SHA=${tok_main}" "HEAD_SHA=${tok_feature}" -- --source "${tok}"
  run_scenario 'pull_request range: clean merge passes' 0 'no leaks in merge diffs' \
    EVENT_NAME=pull_request "BASE_SHA=${clean_main}" "HEAD_SHA=${clean_feature}" -- --source "${clean}"
  run_scenario 'pull_request range with no merges passes' 0 \
    "range=${tok_base}..${tok_main} merges=0" \
    EVENT_NAME=pull_request "BASE_SHA=${tok_base}" "HEAD_SHA=${tok_main}" -- --source "${tok}"
  run_scenario 'merge older than the range base is not rescanned' 0 "range=${tok_feature}..${tok_feature}" \
    EVENT_NAME=push "BASE_SHA=${tok_feature}" "HEAD_SHA=${tok_feature}" -- --source "${tok}"
  run_scenario 'push with all-zero before scans full history' 1 'scanning full history: before SHA is all zeros' \
    EVENT_NAME=push "BASE_SHA=${zero}" "HEAD_SHA=${tok_feature}" -- --source "${tok}"
  run_scenario 'push with unresolvable before scans full history' 1 'scanning full history: before SHA not in this clone' \
    EVENT_NAME=push "BASE_SHA=1111111111111111111111111111111111111111" "HEAD_SHA=${tok_feature}" -- --source "${tok}"
  run_scenario 'push with empty before scans full history' 1 'scanning full history: before SHA is empty' \
    EVENT_NAME=push "HEAD_SHA=${tok_feature}" -- --source "${tok}"
  run_scenario 'head SHA absent from the clone is a setup failure' 2 'head SHA not in this clone' \
    EVENT_NAME=pull_request "BASE_SHA=${tok_main}" "HEAD_SHA=2222222222222222222222222222222222222222" -- --source "${tok}"
  run_scenario 'gitleaks failing without a finding is a setup failure' 2 'without a finding' \
    EVENT_NAME=push "BASE_SHA=${tok_base}" "HEAD_SHA=${tok_feature}" GITLEAKS_CONFIG=/nonexistent \
    -- --source "${tok}"
  run_scenario 'schedule scans full history' 1 'event=schedule range=HEAD' \
    EVENT_NAME=schedule -- --source "${tok}"
  run_scenario 'workflow_dispatch scans full history' 1 'event=workflow_dispatch range=HEAD' \
    EVENT_NAME=workflow_dispatch -- --source "${tok}"
  run_scenario 'pull_request with unresolvable base is a setup failure' 2 'base SHA not in this clone' \
    EVENT_NAME=pull_request "BASE_SHA=1111111111111111111111111111111111111111" "HEAD_SHA=${tok_feature}" -- --source "${tok}"
  run_scenario 'unknown event is a setup failure' 2 'unsupported EVENT_NAME' \
    EVENT_NAME=issues -- --source "${tok}"
  run_scenario 'missing EVENT_NAME is a setup failure' 2 'EVENT_NAME is required' \
    -- --source "${tok}"
  run_scenario 'pull_request without HEAD_SHA is a setup failure' 2 'HEAD_SHA is required' \
    EVENT_NAME=pull_request "BASE_SHA=${tok_main}" -- --source "${tok}"
  run_scenario 'unknown argument is a setup failure' 2 'unknown argument' \
    EVENT_NAME=schedule -- --bogus

  local no_gitleaks_path="" dir
  while IFS= read -r -d ':' dir || [[ -n ${dir} ]]; do
    [[ -x "${dir}/gitleaks" ]] || no_gitleaks_path="${no_gitleaks_path:+${no_gitleaks_path}:}${dir}"
  done <<<"${PATH}:"
  run_scenario 'missing gitleaks is a setup failure' 2 'missing required tool: gitleaks' \
    EVENT_NAME=schedule "PATH=${no_gitleaks_path}" -- --source "${tok}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
