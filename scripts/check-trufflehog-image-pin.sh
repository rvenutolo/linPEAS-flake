#!/usr/bin/env bash
# scripts/check-trufflehog-image-pin.sh
#
# @description Lint: every `trufflesecurity/trufflehog` step in
# `.github/workflows/*.yml` (or `.yaml`) passes a `version:` input of
# `X.Y.Z@sha256:<64 hex>`, where `X.Y.Z` is the version in the step's
# `# vX.Y.Z` pin comment.

# The action is a composite that runs `docker run "${IMAGE}:${VERSION}"`,
# and `version` defaults to `latest`. The SHA pin on `uses:` therefore
# fixes only the wrapper script; without the input, every run executes
# whatever image `latest` names at that moment. A tag+digest value makes
# the reference immutable, and tying the tag to the pin comment keeps the
# image and the wrapper on one release: Renovate moves both in one
# grouped update, and a half-applied update fails here until the other
# half lands.
#
# The owner and repository match with each ASCII letter in either case,
# because GitHub resolves them however they are cased. A `version:`
# written as a YAML alias is read as its anchored text.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set.
# Exits 0 when every TruffleHog step pins its image to its action pin's
# version, 1 on any step that does not, has no pin comment, or sits in a
# file yq cannot parse, 2 when the lint could not run: yq or jq is
# absent, the globs match no file, or WORKFLOW_FILE_FILTER selects none
# of them.

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
require_tool jq

readonly DEFAULT_DIR=.github/workflows
readonly SCAN_DIR="${WORKFLOWS_DIR_OVERRIDE:-${DEFAULT_DIR}}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"

ACTION_RE="^$(ascii_fold_regex 'trufflesecurity/trufflehog')@"
readonly ACTION_RE
readonly COMMENT_RE='^v([0-9]+\.[0-9]+\.[0-9]+)$'

# One JSON array per step map that carries `uses:`: the alias-resolved
# reference, the reference's line comment, and the alias-resolved
# `with.version` (empty when absent).
readonly STEPS_QUERY='.. | select(kind == "map") | select(has("uses")) | [(.uses | explode(.)), (.uses | line_comment), ((.with.version // "") | explode(.))]'

failed=0
shopt -s nullglob
declare -a all_files=()
if [[ -d ${SCAN_DIR} ]]; then
  glob_into all_files "workflow YAML under ${SCAN_DIR}" \
    "${SCAN_DIR}/*.yml" "${SCAN_DIR}/*.yaml"
fi
shopt -u nullglob

declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" \
  ${all_files+"${all_files[@]}"}

for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue
  steps=''
  yq_rc=0
  steps="$(yq "${YQ_MERGE_SPEC[@]}" -o=json -I=0 "${STEPS_QUERY}" "${f}" 2>/dev/null)" || yq_rc=$?
  if ((yq_rc != 0)); then
    printf '%s: yq parse failed; trufflehog image pins cannot be verified\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS= read -r record; do
    [[ -z ${record} ]] && continue
    ref="$(jq --raw-output '.[0] | tostring' <<<"${record}")"
    ascii_match "${ref}" "${ACTION_RE}" || continue
    comment="$(jq --raw-output '.[1] | tostring' <<<"${record}")"
    version="$(jq --raw-output '.[2] | tostring' <<<"${record}")"
    if ! ascii_match "${comment}" "${COMMENT_RE}"; then
      printf '%s: trufflesecurity/trufflehog step has no # vX.Y.Z pin comment, so its image version cannot be checked\n' "${f}" >&2
      failed=$((failed + 1))
      continue
    fi
    pinned="${comment#v}"
    if ! ascii_match "${version}" "^${pinned//./\\.}@sha256:[0-9a-f]{64}\$"; then
      printf '%s: trufflesecurity/trufflehog pinned at v%s runs image version %q; want %s@sha256:<digest>\n' \
        "${f}" "${pinned}" "${version}" "${pinned}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${steps}"
done

if ((failed > 0)); then
  printf '%d trufflehog image pin finding(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
