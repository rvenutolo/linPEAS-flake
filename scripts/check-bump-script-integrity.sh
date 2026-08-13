#!/usr/bin/env bash
# scripts/check-bump-script-integrity.sh
#
# @description Lint: scripts/bump-linpeas.sh retains its three
# supply-chain integrity guards — asset-URL prefix, `.digest`
# cross-check, and atomic (mktemp + mv) pin write.

# Lint: assert scripts/bump-linpeas.sh still carries the three
# hard-fail integrity guards the "Bump-script integrity" invariant
# claims. Regex-presence only: the threat model is a refactor that
# silently drops a guard, and presence checks catch removal without a
# full behavioral harness. Guard 4 (the X-GitHub-Api-Version header)
# is covered by scripts/check-gh-api-version-header.sh, which is
# cross-cutting over every gh-api caller in scripts/.
#
# Honors BUMP_SCRIPT_OVERRIDE for the test harness (defaults to
# scripts/bump-linpeas.sh, repo-relative).
#
# Exits 0 when every guard is present, 1 when one is missing, 2 when the
# bump script itself cannot be read. An unreadable input was never
# scanned, so reporting it as a dropped guard sends a maintainer to
# re-add code that is still there.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly BUMP_SCRIPT="${BUMP_SCRIPT_OVERRIDE:-${REPO_ROOT}/scripts/bump-linpeas.sh}"

if [[ ! -f ${BUMP_SCRIPT} ]]; then
  printf 'bump script not found: %s\n' "${BUMP_SCRIPT}" >&2
  exit 2
fi

failed=0
declare -a matched=()

# @description Emit a guard failure and set the failure flag.
# @arg $1 guard label (the test asserts on a substring of this).
function fail_guard() {
  printf '%s: missing guard: %s\n' "${BUMP_SCRIPT}" "$1" >&2
  failed=1
}

# These presence checks are coupled to the exact local-variable names
# and token shape used in scripts/bump-linpeas.sh (expected_url_prefix,
# pin_tmp, pin_file, the `mv --` rename). The coupling is fail-closed:
# a behavior-preserving rename or reflow in the bump script false-trips
# this lint (a blocked PR) but can never let a dropped guard pass. Keep
# the two files in step when either changes.

# Guard 1 — asset URL prefix. Require both the canonical upstream
# release-download prefix literal and a comparison that rejects any
# asset_url outside it.
readonly URL_PREFIX_LITERAL='https://github.com/peass-ng/PEASS-ng/releases/download/'
# shellcheck disable=SC2016 # literal grep pattern, not shell expansion
readonly URL_PREFIX_COMPARE='!= "${expected_url_prefix}"'

if ! grep --fixed-strings --quiet -- "${URL_PREFIX_LITERAL}" "${BUMP_SCRIPT}" ||
  ! grep --fixed-strings --quiet -- "${URL_PREFIX_COMPARE}" "${BUMP_SCRIPT}"; then
  fail_guard 'asset url prefix'
else
  matched+=('asset url prefix')
fi

# Guard 2 — .digest cross-check. Require the sha256: digest-prefix
# check and the sha256sum recomputation that compares against it.
if ! grep --fixed-strings --quiet 'sha256:' "${BUMP_SCRIPT}" ||
  ! grep --fixed-strings --quiet 'sha256sum' "${BUMP_SCRIPT}"; then
  fail_guard 'digest cross-check'
else
  matched+=('digest cross-check')
fi

# Guard 3 — atomic pin write. Require the guarded temp-file helper
# `make_temp` + an mv rename into the pin file, and reject a truncating
# redirect into the pin file. The helper is the required token rather
# than a bare `mktemp`, because an unguarded `mktemp` that cannot write
# kills the bump mid-flight with the status a caller reads as a finding,
# and the helper's name is the only thing in source that tells the two
# apart.
#
# The three search patterns below are assembled from parts, with
# names that avoid the substring "pin_file"/"PIN_FILE", rather than
# written as single-line literals: a `mv`/`>` token sharing a source
# line with a `${pin_file}`-shaped reference is exactly the heuristic
# scripts/check-pin-diff-isolated.sh uses to detect a
# linpeas-pin.json writer, and this checker's own source text would
# otherwise trip it as a false "second writer" — it only greps for
# the pattern, it never writes the file.
gt='>'
dq='"'
target_name='pin_file'
target_ref="\${${target_name}}"
guard3_mv_pattern="mv -- \"\${pin_tmp}\" ${dq}${target_ref}${dq}"
guard3_truncating_no_space="${gt}${dq}${target_ref}${dq}"
guard3_truncating_with_space="${gt} ${dq}${target_ref}${dq}"
readonly gt dq target_name target_ref guard3_mv_pattern \
  guard3_truncating_no_space guard3_truncating_with_space

guard3_ok=1
if ! grep --fixed-strings --quiet 'make_temp' "${BUMP_SCRIPT}" ||
  ! grep --fixed-strings --quiet -- "${guard3_mv_pattern}" "${BUMP_SCRIPT}"; then
  fail_guard 'atomic pin write'
  guard3_ok=0
fi
if grep --fixed-strings --quiet -- "${guard3_truncating_no_space}" "${BUMP_SCRIPT}" ||
  grep --fixed-strings --quiet -- "${guard3_truncating_with_space}" "${BUMP_SCRIPT}"; then
  fail_guard 'atomic pin write (truncating redirect into pin file)'
  guard3_ok=0
fi
if ((guard3_ok == 1)); then
  matched+=('atomic pin write')
fi

if ((failed > 0)); then
  printf '\nscripts/bump-linpeas.sh is missing a Bump-script integrity guard (see docs/security/verification.md).\n' >&2
  exit 1
fi

# A pass says which file was read and which guards were found in it. The
# override that lets the harness point this lint at a stand-in also lets
# a misconfigured caller verify the wrong file and still report success,
# so the scanned path belongs in the verdict alongside the guard set.
guard_desc=''
for guard in ${matched[@]+"${matched[@]}"}; do
  guard_desc+="${guard_desc:+, }${guard}"
done
printf '%s: %s — guards matched: %s\n' \
  'bump-script-integrity' "${BUMP_SCRIPT#"${REPO_ROOT}"/}" "${guard_desc}"
exit 0
