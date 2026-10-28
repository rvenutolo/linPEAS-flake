#!/usr/bin/env bash
# scripts/check-uses-no-self-reference.sh
#
# @description Lint: no `uses:` in `.github/workflows/*.yml` (or
# `.yaml`) or `.github/actions/**/*.yml` (or `.yaml`) names this
# repository by its owner/repo slug. This repository's own actions and
# reusable workflows are reached by the path-relative `./` form.

# A slug reference (`<owner>/<repo>/.github/actions/<name>@<ref>`, or a
# reusable workflow at `<owner>/<repo>/.github/workflows/<file>@<ref>`)
# runs the copy at that ref, not the copy in the checkout. Pinned to a
# SHA, it freezes the caller on an old revision of a file this repo keeps
# changing, and nothing moves the pin: Renovate does not detect a
# self-reference with no version comment, so the caller silently misses
# every later fix. The `./` form runs the checked-out copy, which on
# `main` is `main`'s.
#
# The slug is `GITHUB_REPOSITORY`, defaulting to this repository's, and
# it matches with each ASCII letter in either case, because GitHub
# resolves an owner and repository name however it is cased. A reference
# matches only when the slug is followed by `/` or `@`, so a repository
# whose name merely starts with this one's is another repository.
#
# `uses:` values are read with the same yq query as
# `check-uses-sha-pinned.sh`: block and flow style alike, with a value or
# key written as a YAML alias read as its anchored text, and each
# reference read once, where it is written.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set.
# Exits 0 when no `uses:` names this repository, 1 on any that does or on
# a file yq cannot parse, 2 when the lint could not run: yq is absent,
# the slug is not an owner/repo of ASCII letters, digits, `-` and `_`,
# the globs match no file, or WORKFLOW_FILE_FILTER selects none of them.

set -Eeuo pipefail
IFS=$'\n\t'

_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/ascii-match.sh
source "${_lib_dir}/lib/ascii-match.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"

require_tool yq

readonly DEFAULT_DIRS=(.github/workflows .github/actions)
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly SELF_REPO="${GITHUB_REPOSITORY:-rvenutolo/linPEAS-flake}"

if ! ascii_match "${SELF_REPO}" '^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$'; then
  printf 'check-uses-no-self-reference: GITHUB_REPOSITORY %q is not an owner/repo slug of ASCII letters, digits, - and _\n' "${SELF_REPO}" >&2
  exit 2
fi
SELF_RE="^$(ascii_fold_regex "${SELF_REPO,,}")[/@]"
readonly SELF_RE

# The same query as check-uses-sha-pinned.sh: every `uses:` value in the
# document, alias-resolved, each read once at the map that writes it.
readonly USES_QUERY='.. | select(kind == "map") | to_entries[] | select((.key | explode(.)) == "uses") | .value | explode(.)'

if [[ -n ${OVERRIDE} ]]; then
  scan_dirs=("${OVERRIDE}")
else
  scan_dirs=("${DEFAULT_DIRS[@]}")
fi

failed=0
shopt -s nullglob globstar
declare -a all_files=()
for dir in "${scan_dirs[@]}"; do
  [[ -d ${dir} ]] || continue
  # `**` also matches zero segments, so this one glob pair covers the
  # top level as well; a separate `*.yml` would scan each file twice.
  declare -a dir_files=()
  glob_into dir_files "workflow and composite-action YAML under ${dir}" \
    "${dir}/**/*.yml" "${dir}/**/*.yaml"
  all_files+=("${dir_files[@]}")
done
shopt -u nullglob globstar

declare -a selected_files=()
filter_into selected_files 'workflow and composite-action YAML' "${FILE_FILTER}" \
  ${all_files+"${all_files[@]}"}

for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue
  uses_output=''
  yq_rc=0
  uses_output="$(yq "${YQ_MERGE_SPEC[@]}" "${USES_QUERY}" "${f}" 2>/dev/null)" || yq_rc=$?
  if ((yq_rc != 0)); then
    printf '%s: yq parse failed; uses: references cannot be verified\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS= read -r ref; do
    [[ -z ${ref} ]] && continue
    if ascii_match "${ref}" "${SELF_RE}"; then
      printf '%s: %q names this repository (%s); use the ./ path instead\n' "${f}" "${ref}" "${SELF_REPO}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${uses_output}"
done

if ((failed > 0)); then
  printf '%d self-reference uses: finding(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
