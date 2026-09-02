#!/usr/bin/env bash
# scripts/check-gh-attestation-repo.sh
#
# @description Lint: every `gh attestation verify` invocation across
# workflows, composite actions, scripts, nix modules, the justfile, and
# docs passes `--repo rvenutolo/linPEAS-flake` so verification is bound
# to this repository. Parsing lives in
# `scripts/_attestation_invocations.awk`; this script owns path
# selection and reporting.

# Lint: every `gh attestation verify` invocation across workflows,
# composite actions, scripts, nix modules, the justfile, and docs passes
# `--repo rvenutolo/linPEAS-flake`.
#
# `gh attestation verify` requires either `--owner` or `--repo`, so an
# unpinned invocation does not run at all. The bypass this lint
# forecloses is the `--owner`-only spelling: it binds verification to
# the account, so an attestation issued by any other repo under the
# same owner satisfies it. The `--repo` pin narrows that to this
# repository, so a bundle issued elsewhere fails the check.
#
# Detection is token-granular. Each runnable string is split into shell
# words, honouring single quotes, double quotes, and backslash escapes.
# A record runs from the `gh attestation verify` word triple to the next
# unquoted shell separator or comment, or to the end of the string. The
# pin must be a word `--repo` or `-R` whose next word is the slug, or a
# word `--repo=<slug>`, `-R=<slug>`, or `-R<slug>`. A quoted region in
# command position — the value of a key such as `run` or `entry`, an
# `eval` argument, a `-c` argument — is re-parsed as a command line
# rather than read as a single word.
#
# Binding the pin to a word position is what keeps text that merely sits
# near the command from vouching for it: a trailing comment, a chained
# command, and a slug inside a quoted argument all fail the check.
#
# Two sources feed the splitter. Runnable source lines, joined across
# backslash continuations and stripped of the code spans already
# accounted for. And the code spans themselves, where a record holding
# the bare command triple is a prose mention and is skipped.
#
# Parsing lives in scripts/_attestation_invocations.awk; this script owns
# path selection and reporting.
#
# See docs/security/verification.md.
#
# Honors PATHS_OVERRIDE for fixtures (newline-separated file list), and
# LINT_ALLOW_EMPTY_SCAN=1 to accept an empty scan set. REPO_SLUG_OVERRIDE
# swaps the required slug. AWK_LIB_OVERRIDE points at a different parser.
# Exits 0 on full coverage, 1 on any drift, 2 when the scan set could not
# be enumerated.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly DEFAULT_REPO_SLUG="rvenutolo/linPEAS-flake"
readonly REPO_SLUG="${REPO_SLUG_OVERRIDE:-${DEFAULT_REPO_SLUG}}"
readonly NEEDLE="--repo ${REPO_SLUG}"
readonly AWK_LIB="${AWK_LIB_OVERRIDE:-${REPO_ROOT}/scripts/_attestation_invocations.awk}"

# Every path class that can carry a runnable `gh attestation verify`
# invocation. Composite action `run:` blocks, justfile recipe bodies, and
# nix pre-commit `entry` strings are all shell; CHANGELOG.md is markdown
# excluded from mdformat, so shapes the formatter would normalize survive
# there. Root-level `flake.nix` and `treefmt.nix` are named explicitly
# because they sit outside the `nix/` pathspec and each carries shell
# inside `''…''` string blocks (formatter options, dev-shell hooks) the
# same way modules under `nix/` do. Kept as a named array between markers
# so tests/check-gh-attestation-repo.test.sh can parse it and assert the
# pre-commit hook's `files` filter covers everything selected here.
# BEGIN SCAN_GLOBS
readonly SCAN_GLOBS=(
  '.github/workflows/*.yml'
  '.github/workflows/*.yaml'
  '.github/actions/**/*.yml'
  '.github/actions/**/*.yaml'
  'scripts/*.sh'
  'docs/**/*.md'
  'docs/*.md'
  'README.md'
  'SECURITY.md'
  'CHANGELOG.md'
  'justfile'
  'nix/**/*.nix'
  'nix/*.nix'
  'flake.nix'
  'treefmt.nix'
)
# END SCAN_GLOBS

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  enumerate_into paths 'git ls-files' git ls-files -z -- "${SCAN_GLOBS[@]}"
fi

# Emits one line per invocation: `<status>\t<record>`, where status is
# `ok` when the record carries the pin and `bad` when it does not.
function extract_invocations() {
  local -r file="$1"
  local mode="other"
  case "${file}" in
  *.md) mode="md" ;;
  esac
  awk -v mode="${mode}" -v slug="${REPO_SLUG}" --file "${AWK_LIB}" "$(awk_path "${file}")"
}

failed=0
seen=0
for f in "${paths[@]}"; do
  [[ -f ${f} ]] || continue
  # Skip self, and check-egress-allowlist.sh: both scripts contain the
  # literal "gh attestation verify" as a `run:`-text match key rather
  # than an actual invocation, and would otherwise flag themselves.
  case "${f}" in
  */scripts/check-gh-attestation-repo.sh | scripts/check-gh-attestation-repo.sh | \
    */scripts/check-egress-allowlist.sh | scripts/check-egress-allowlist.sh)
    continue
    ;;
  esac
  # Capture the parser's output so its exit status is checked. Process
  # substitution hides a non-zero exit from both errexit and pipefail, so
  # a parser that died partway through this file would have its records
  # silently truncated — and the zero-records guard below would not fire,
  # because other files still contribute records.
  if ! records="$(extract_invocations "${f}")"; then
    printf '%s: parser failed\n' "${f}" >&2
    exit 1
  fi
  while IFS=$'\t' read -r status invocation; do
    [[ -z ${status} ]] && continue
    seen=$((seen + 1))
    [[ ${status} == "ok" ]] && continue
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: `gh attestation verify` missing `%s`; got: %s\n' \
      "${f}" "${NEEDLE}" "${invocation}" >&2
    failed=$((failed + 1))
  done <<<"${records}"
done

# Guard-the-guard: the tracked scan set yields 18 real invocation
# records, so extracting none means the parser broke rather than that the
# repo is clean. Fixtures legitimately yield zero, so this only applies
# to a real run.
if [[ -z ${PATHS_OVERRIDE:-} ]] && ((seen == 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf 'no `gh attestation verify` invocations found across %d files — parser likely broke\n' \
    "${#paths[@]}" >&2
  exit 1
fi

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d `gh attestation verify` invocation(s) missing --repo pin\n' "${failed}" >&2
  exit 1
fi
exit 0
