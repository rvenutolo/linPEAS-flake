#!/usr/bin/env bash
# scripts/check-gh-attestation-repo.sh
#
# @description Lint: every `gh attestation verify` invocation across
# workflows, scripts, and docs passes `--repo rvenutolo/linPEAS-flake`
# so verification is bound to this repository.

# Lint: every `gh attestation verify` invocation across workflows,
# scripts, and docs passes `--repo rvenutolo/linPEAS-flake`.
#
# Without `--repo`, the verifier accepts any attestation Sigstore
# can find for the artifact digest — including one issued from a
# different repo. The `--repo` pin binds the verification to this
# repository, so an attestation forged elsewhere fails the check.
#
# Detection is token-granular. Each runnable string is split into shell
# words, honouring single quotes, double quotes, and backslash escapes.
# A record runs from the `gh attestation verify` word triple to the next
# unquoted shell separator or comment, or to the end of the string. The
# pin must be a word `--repo` whose next word is the slug, or a word
# `--repo=<slug>`.
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
# Honors PATHS_OVERRIDE for fixtures (newline-separated file list).
# REPO_SLUG_OVERRIDE swaps the required slug. AWK_LIB_OVERRIDE points at
# a different parser.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_REPO_SLUG="rvenutolo/linPEAS-flake"
readonly REPO_SLUG="${REPO_SLUG_OVERRIDE:-${DEFAULT_REPO_SLUG}}"
readonly NEEDLE="--repo ${REPO_SLUG}"
readonly AWK_LIB="${AWK_LIB_OVERRIDE:-scripts/_attestation_invocations.awk}"

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  while IFS= read -r p; do
    paths+=("${p}")
  done < <(git ls-files \
    '.github/workflows/*.yml' '.github/workflows/*.yaml' \
    'scripts/*.sh' \
    'docs/**/*.md' \
    'docs/*.md' \
    'README.md' 'SECURITY.md' 2>/dev/null || true)
fi

# Emits one line per invocation: `<status>\t<record>`, where status is
# `ok` when the record carries the pin and `bad` when it does not.
function extract_invocations() {
  local -r file="$1"
  local mode="other"
  case "${file}" in
  *.md) mode="md" ;;
  esac
  awk -v mode="${mode}" -v slug="${REPO_SLUG}" --file "${AWK_LIB}" "${file}"
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
  while IFS=$'\t' read -r status invocation; do
    [[ -z ${status} ]] && continue
    seen=$((seen + 1))
    [[ ${status} == "ok" ]] && continue
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: `gh attestation verify` missing `%s`; got: %s\n' \
      "${f}" "${NEEDLE}" "${invocation}" >&2
    failed=$((failed + 1))
  done < <(extract_invocations "${f}")
done

# Guard-the-guard: the tracked scan set yields 17 real invocation
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
