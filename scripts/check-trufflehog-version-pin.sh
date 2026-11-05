#!/usr/bin/env bash
# scripts/check-trufflehog-version-pin.sh
#
# @description Lint: TruffleHog runs only as the signed release binary
# pinned in `.github/trufflehog-version`. The file holds one `X.Y.Z` line,
# no workflow or composite action `uses:` the
# `trufflesecurity/trufflehog` action, and
# `.github/workflows/trufflehog.yml` runs `scripts/trufflehog-release.sh`
# in both its `verify` and its `scan` form. A `uses:` naming the action
# through a subpath, or a `docker://` reference to upstream's image on any
# registry, counts as naming it.

# The upstream action is a composite that runs `docker run` on an image
# whose `version` input defaults to `latest`, and that image carries no
# signature, attestation or provenance, so nothing can tell a re-pushed
# tag from a tampered one. The release's checksums file is keyless-signed
# by upstream's release workflow, so `trufflehog-release.sh verify` checks
# that signature and `scan` runs only a tarball matching it. This lint
# keeps the action from coming back and keeps both halves wired; the
# version file's shape is the one `trufflehog-release.sh` accepts.
#
# The action's owner and repository match with each ASCII letter in either
# case, because GitHub resolves them however they are cased, when followed
# by `/`, `@` or the end of the value. A `docker://` reference matches the
# image `trufflesecurity/trufflehog` with or without one registry host in
# front, followed by a tag, a digest or nothing. A `uses:`
# value or key written as a YAML alias is read as its anchored text. A
# `run:` line whose first non-blank character is `#` is a shell comment
# and runs nothing, so it does not count as an invocation.
#
# Scans `.github/workflows/**/*.yml` and `.github/actions/**/*.yml` (and
# `.yaml`). Honors WORKFLOWS_DIR_OVERRIDE, which replaces both scan roots
# and is where `trufflehog.yml` is looked for, and
# TRUFFLEHOG_VERSION_FILE_OVERRIDE for the version file's path.
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set.
# A scanned file yq cannot parse is a finding and the scan goes on: its
# references cannot be verified, and a malformed workflow is a fact about
# the repository, not about the lint.
# Exits 0 when every rule holds, 1 on any violation (one line per
# violation, an unparsable scanned file included), 2 when the lint could
# not run: yq or jq is absent, the version file or trufflehog.yml is
# missing, a file that parsed cannot then be read, or the globs match no
# file.

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

readonly DEFAULT_DIRS=(.github/workflows .github/actions)
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly VERSION_FILE="${TRUFFLEHOG_VERSION_FILE_OVERRIDE:-.github/trufflehog-version}"
readonly WORKFLOW="${OVERRIDE:-.github/workflows}/trufflehog.yml"
readonly RELEASE_SCRIPT='scripts/trufflehog-release.sh'

ACTION_RE="^$(ascii_fold_regex 'trufflesecurity/trufflehog')(/|@|$)"
readonly ACTION_RE
IMAGE_RE="^$(ascii_fold_regex 'docker')://([^/]+/)?$(ascii_fold_regex 'trufflesecurity/trufflehog')([:@]|$)"
readonly IMAGE_RE
# The whole file, final newline included: one line and nothing after it.
readonly VERSION_RE=$'^[0-9]+\\.[0-9]+\\.[0-9]+\n$'

# Every `uses:` value, alias-resolved, as in check-uses-sha-pinned.sh: a
# map is read only for its own entries, so a merged-in step is read once.
readonly USES_QUERY='[.. | select(kind == "map") | to_entries[] | select((.key | explode(.)) == "uses") | .value | explode(.) | select(tag == "!!str")]'
# Every `run:` string in the workflow, alias-resolved.
readonly RUNS_QUERY='[.. | select(kind == "map") | to_entries[] | select((.key | explode(.)) == "run") | .value | explode(.) | select(tag == "!!str")]'

failed=0
workflow_unparsable=0

if [[ -n ${OVERRIDE} ]]; then
  scan_dirs=("${OVERRIDE}")
else
  scan_dirs=("${DEFAULT_DIRS[@]}")
fi
declare -a patterns=()
for dir in "${scan_dirs[@]}"; do
  patterns+=("${dir}/**/*.yml" "${dir}/**/*.yaml")
done
shopt -s nullglob globstar
declare -a scan_files=()
glob_into scan_files 'workflow and composite-action YAML' "${patterns[@]}"
shopt -u nullglob globstar

# Rule 1: the version file is one X.Y.Z line.
if [[ ! -f ${VERSION_FILE} || ! -r ${VERSION_FILE} ]]; then
  printf '%s: missing or unreadable; %s reads the pinned version from it\n' \
    "${VERSION_FILE}" "${RELEASE_SCRIPT}" >&2
  exit 2
fi
content=''
# `read -d ''` keeps every byte up to EOF and reports EOF as status 1.
# Status 0 means it stopped at a NUL, so more bytes follow.
if IFS= read -r -d '' content <"${VERSION_FILE}"; then
  printf '%s: holds a NUL byte; want one line X.Y.Z\n' "${VERSION_FILE}" >&2
  failed=$((failed + 1))
elif ! ascii_match "${content}" "${VERSION_RE}"; then
  printf '%s: holds %q; want one line X.Y.Z\n' "${VERSION_FILE}" "${content}" >&2
  failed=$((failed + 1))
fi

# Rule 2: no `uses:` names the upstream action.
for f in "${scan_files[@]}"; do
  [[ -f ${f} ]] || continue
  refs=''
  if ! refs="$(yq "${YQ_MERGE_SPEC[@]}" -o=json -I=0 "${USES_QUERY}" "${f}" 2>/dev/null)"; then
    printf '%s: yq parse failed; the TruffleHog version pin cannot be verified\n' "${f}" >&2
    failed=$((failed + 1))
    if [[ ${f} == "${WORKFLOW}" ]]; then workflow_unparsable=1; fi
    continue
  fi
  ref_lines=''
  if ! ref_lines="$(jq --raw-output '.[]' <<<"${refs}")"; then
    printf '%s: could not read its uses: values\n' "${f}" >&2
    exit 2
  fi
  while IFS= read -r ref; do
    [[ -n ${ref} ]] || continue
    ascii_match "${ref}" "${ACTION_RE}" || ascii_match "${ref}" "${IMAGE_RE}" || continue
    printf '%s: uses %q; run the signed release binary through %s instead\n' \
      "${f}" "${ref}" "${RELEASE_SCRIPT}" >&2
    failed=$((failed + 1))
  done <<<"${ref_lines}"
done

# Rule 3: trufflehog.yml runs the release script in both forms.
if [[ ! -f ${WORKFLOW} ]]; then
  printf '%s: missing; it runs the TruffleHog scan\n' "${WORKFLOW}" >&2
  exit 2
fi
# An unparsable trufflehog.yml was already counted by the scan above, so
# its invocations are not checked. Otherwise it parsed there, and a read
# failing behind that gate is a fault in this lint, not in the file.
if ((workflow_unparsable == 0)); then
  runs=''
  if ! runs="$(yq "${YQ_MERGE_SPEC[@]}" -o=json -I=0 "${RUNS_QUERY}" "${WORKFLOW}" 2>/dev/null)"; then
    printf '%s: could not read its run: scripts\n' "${WORKFLOW}" >&2
    exit 2
  fi
  run_lines=''
  if ! run_lines="$(jq --raw-output '.[]' <<<"${runs}")"; then
    printf '%s: could not read its run: scripts\n' "${WORKFLOW}" >&2
    exit 2
  fi
  has_verify=0
  has_scan=0
  invocation_re='(^|[[:space:]])(\./)?scripts/trufflehog-release\.sh[[:space:]]+(verify|scan)([[:space:]]|$)'
  while IFS= read -r line; do
    [[ ${line} =~ ^[[:space:]]*# ]] && continue
    [[ ${line} =~ ${invocation_re} ]] || continue
    case "${BASH_REMATCH[3]}" in
    verify) has_verify=1 ;;
    scan) has_scan=1 ;;
    esac
  done <<<"${run_lines}"
  if ((has_verify == 0)); then
    printf '%s: no step runs %s verify\n' "${WORKFLOW}" "${RELEASE_SCRIPT}" >&2
    failed=$((failed + 1))
  fi
  if ((has_scan == 0)); then
    printf '%s: no step runs %s scan\n' "${WORKFLOW}" "${RELEASE_SCRIPT}" >&2
    failed=$((failed + 1))
  fi
fi

if ((failed > 0)); then
  printf '%d trufflehog version pin finding(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
