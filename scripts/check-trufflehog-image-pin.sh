#!/usr/bin/env bash
# scripts/check-trufflehog-image-pin.sh
#
# @description Lint: every `trufflesecurity/trufflehog` step in
# `.github/workflows/*.yml` (or `.yaml`) passes
# `version: ${{ steps.trufflehog-image.outputs.version }}`, and
# `.github/trufflehog-image` holds one line `X.Y.Z@sha256:<64 hex>` whose
# `X.Y.Z` is the version in each such step's `# vX.Y.Z` pin comment.

# The action is a composite that runs `docker run "${IMAGE}:${VERSION}"`,
# and `version` defaults to `latest`. The SHA pin on `uses:` therefore
# fixes only the wrapper script; without the input, every run executes
# whatever image `latest` names at that moment. The image ref lives in its
# own file, which a `trufflehog-image` step reads and hands to the action:
# a tag+digest value makes the reference immutable, and tying the tag to
# the pin comment keeps the image and the wrapper on one release. A
# Renovate bump of the action leaves the file naming the old release, so
# this lint keeps that PR red until `renovate-flake-lock-refresh.yml`
# commits the file `scripts/refresh-trufflehog-image.sh` resolves for the
# new pin.
#
# The owner and repository match with each ASCII letter in either case,
# because GitHub resolves them however they are cased. A `version:`
# written as a YAML alias is read as its anchored text. The image file is
# read only when some step names the action, since nothing else reads it.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures, and
# TRUFFLEHOG_IMAGE_FILE_OVERRIDE for the image file's path.
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set.
# Exits 0 when every TruffleHog step reads its image from the file and the
# file names its action pin's release by digest, 1 on any step that does
# not, has no pin comment, or sits in a file yq cannot parse, and on an
# image file that is missing or not that one line, 2 when the lint could
# not run: yq or jq is absent, the globs match no file, or
# WORKFLOW_FILE_FILTER selects none of them.

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
readonly IMAGE_FILE="${TRUFFLEHOG_IMAGE_FILE_OVERRIDE:-.github/trufflehog-image}"

ACTION_RE="^$(ascii_fold_regex 'trufflesecurity/trufflehog')@"
readonly ACTION_RE
readonly COMMENT_RE='^v([0-9]+\.[0-9]+\.[0-9]+)$'
# The whole file, final newline included: one line and nothing after it.
readonly IMAGE_RE=$'^([0-9]+\\.[0-9]+\\.[0-9]+)@sha256:[0-9a-f]{64}\n$'
# shellcheck disable=SC2016 # a GitHub Actions expression, not a shell one
readonly WANT_VERSION='${{ steps.trufflehog-image.outputs.version }}'

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

# The image file's release, read once, on the first step that needs it.
# `image_state` is `unread`, `ok` or `bad`; a bad file is reported once.
image_state='unread'
image_tag=''

# @description Read and shape-check the image file, once. Sets
# `image_state` and `image_tag`, and counts a bad file as one finding.
function read_image_file() {
  [[ ${image_state} == 'unread' ]] || return 0
  local content=''
  image_state='bad'
  if [[ ! -f ${IMAGE_FILE} || ! -r ${IMAGE_FILE} ]]; then
    printf '%s: missing or unreadable; the trufflehog-image step reads the image ref from it\n' \
      "${IMAGE_FILE}" >&2
    failed=$((failed + 1))
    return 0
  fi
  # `read -d ''` keeps every byte up to EOF, trailing newlines included,
  # and reports EOF as status 1. Status 0 means it stopped at a NUL, so
  # the bytes it read are not the whole file.
  if IFS= read -r -d '' content <"${IMAGE_FILE}"; then
    printf '%s: holds a NUL byte; want one line X.Y.Z@sha256:<64 hex>\n' \
      "${IMAGE_FILE}" >&2
    failed=$((failed + 1))
    return 0
  fi
  if ! ascii_match "${content}" "${IMAGE_RE}"; then
    printf '%s: holds %q; want one line X.Y.Z@sha256:<64 hex>\n' \
      "${IMAGE_FILE}" "${content}" >&2
    failed=$((failed + 1))
    return 0
  fi
  image_tag="${content%%@*}"
  image_state='ok'
}

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
    if [[ ${version} != "${WANT_VERSION}" ]]; then
      printf '%s: trufflesecurity/trufflehog step passes version %q; want %s\n' \
        "${f}" "${version}" "${WANT_VERSION}" >&2
      failed=$((failed + 1))
    fi
    if ! ascii_match "${comment}" "${COMMENT_RE}"; then
      printf '%s: trufflesecurity/trufflehog step has no # vX.Y.Z pin comment, so its image version cannot be checked\n' "${f}" >&2
      failed=$((failed + 1))
      continue
    fi
    read_image_file
    [[ ${image_state} == 'ok' ]] || continue
    pinned="${comment#v}"
    if [[ ${image_tag} != "${pinned}" ]]; then
      printf '%s: trufflesecurity/trufflehog pinned at v%s, but %s names release %s\n' \
        "${f}" "${pinned}" "${IMAGE_FILE}" "${image_tag}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${steps}"
done

if ((failed > 0)); then
  printf '%d trufflehog image pin finding(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
