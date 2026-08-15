#!/usr/bin/env bash
# scripts/inventory-action-pin-tags.sh
#
# @description Enumerate every SHA-pinned `uses:` in
# .github/workflows/*.yml|*.yaml and .github/actions/**/action.yml
# (or action.yaml), resolve each pinned SHA to its exact patch tag via
# `gh api .../tags`, and emit a TSV mapping pin -> patch tag for
# downstream rewrite tooling.

# Comments today name floating major tags (e.g. `# v3`); upstream
# publishers force-move those tags on every release, which fires the
# ratchet-pin-audit workflow on benign retags. Rewriting comments to
# the exact immutable patch tag turns audit drift back into a real
# signal. This script builds the inventory the rewrite consumes.
#
# Output TSV columns:
#   file  line  ref  pinned_sha  current_comment  target_comment  status
#
# Status values:
#   OK             — patch tag resolved cleanly
#   NO_PATCH_TAG   — no semver patch tag points at this SHA
#   API_FAILURE    — `gh api` call to list tags failed
#
# Honors INVENTORY_PATHS_OVERRIDE (newline-separated paths) for
# fixture-driven tests, and LINT_ALLOW_EMPTY_SCAN=1 to accept an empty scan
# set. Default scan: .github/workflows + .github/actions.
# Exits 0 if every row is OK / NO_PATCH_TAG; exits 1 on any API_FAILURE;
# exits 2 when the scan set could not be enumerated or came back empty.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"

OUTPUT="${TMPDIR:-/tmp}/action-pin-inventory.tsv"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --output)
    OUTPUT="$2"
    shift 2
    ;;
  *)
    printf 'unknown arg: %s\n' "$1" >&2
    exit 2
    ;;
  esac
done

mkdir -p "$(dirname "${OUTPUT}")"

paths=()
if [[ -n ${INVENTORY_PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -n ${p} ]] && paths+=("${p}")
  done <<<"${INVENTORY_PATHS_OVERRIDE}"
else
  # Each root is scanned only when it is there, because a repo may carry
  # workflows and no composite actions (or the reverse). Both roots yielding
  # nothing is the fault worth catching: the run still writes a header-only
  # TSV at exit 0, which the rewrite tool downstream reads as "no pins to
  # rewrite" rather than as an inventory that was never taken.
  # LINT_ALLOW_EMPTY_SCAN is forced on each per-root call below so that one
  # root being present-but-empty does not itself abort the run; the breadth
  # check after the loop is what still catches BOTH roots yielding nothing.
  if [[ -d .github/workflows ]]; then
    workflow_paths=()
    LINT_ALLOW_EMPTY_SCAN=1 enumerate_into workflow_paths 'find .github/workflows' \
      find .github/workflows -maxdepth 1 -type f \
      \( -name '*.yml' -o -name '*.yaml' \) -print0
    paths+=(${workflow_paths+"${workflow_paths[@]}"})
  fi
  if [[ -d .github/actions ]]; then
    action_paths=()
    LINT_ALLOW_EMPTY_SCAN=1 enumerate_into action_paths 'find .github/actions' \
      find .github/actions -type f \
      \( -name 'action.yml' -o -name 'action.yaml' \) -print0
    paths+=(${action_paths+"${action_paths[@]}"})
  fi
  if ((${#paths[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf '%s: enumerated 0 workflow / composite-action file(s) under .github — an inventory with no rows cannot be told apart from a tree with no pins; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" >&2
    exit 2
  fi
fi

declare -A tag_cache

# resolve_patch_tag <owner/repo> <40-hex sha>
# Echoes a patch tag (vX.Y.Z[-suffix]), or API_FAILURE / NO_PATCH_TAG.
resolve_patch_tag() {
  local -r owner_repo="$1"
  local -r sha="$2"
  local payload
  # If INVENTORY_TAG_FIXTURE_DIR is set, read tag data from
  # "${INVENTORY_TAG_FIXTURE_DIR}/<owner>__<repo>.tsv" instead of calling
  # gh api. File format: one tag per line, `<tag>\t<sha>`. Missing file =
  # empty payload = NO_PATCH_TAG. Use [[ -v ... ]] presence check so an
  # empty payload doesn't trigger a re-query on subsequent calls.
  if [[ -n ${INVENTORY_TAG_FIXTURE_DIR:-} ]]; then
    if [[ ! -v tag_cache[${owner_repo}] ]]; then
      local fixture_file="${INVENTORY_TAG_FIXTURE_DIR}/${owner_repo//\//__}.tsv"
      if [[ -f ${fixture_file} ]]; then
        tag_cache[${owner_repo}]=$(cat "${fixture_file}")
      else
        tag_cache[${owner_repo}]=""
      fi
    fi
  elif [[ ! -v tag_cache[${owner_repo}] ]]; then
    if ! payload=$(gh api --paginate "repos/${owner_repo}/tags" \
      --jq '.[] | [.name, .commit.sha] | @tsv' 2>/dev/null); then
      tag_cache[${owner_repo}]="__API_FAIL__"
    else
      tag_cache[${owner_repo}]="${payload}"
    fi
  fi
  local cached="${tag_cache[${owner_repo}]}"
  if [[ ${cached} == "__API_FAIL__" ]]; then
    printf 'API_FAILURE\n'
    return
  fi
  local match
  match=$(awk -F'\t' -v s="${sha}" '$2==s {print $1}' <<<"${cached}" |
    grep --extended-regexp '^v[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?$' |
    sort --version-sort |
    tail -1)
  if [[ -z ${match} ]]; then
    printf 'NO_PATCH_TAG\n'
  else
    printf '%s\n' "${match}"
  fi
}

printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n' >"${OUTPUT}"

# Match:  [- ] uses: <owner/repo[/path]>@<40-hex> # <tag>
# Note: quoted `uses:` forms (e.g. uses: "actions/checkout@..." ) are not
# supported; the convention in this repo is unquoted.
re='^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*([^@[:space:]]+)@([0-9a-fA-F]{40})[[:space:]]*#[[:space:]]*([^[:space:]]+)'

for file in "${paths[@]}"; do
  [[ -f ${file} ]] || continue
  ln=0
  while IFS= read -r line || [[ -n ${line} ]]; do
    ln=$((ln + 1))
    [[ ${line} =~ ${re} ]] || continue
    ref="${BASH_REMATCH[1]}"
    sha="${BASH_REMATCH[2]}"
    current="${BASH_REMATCH[3]}"
    owner_repo="$(awk -F/ '{print $1"/"$2}' <<<"${ref}")"
    resolved="$(resolve_patch_tag "${owner_repo}" "${sha}")"
    case "${resolved}" in
    API_FAILURE)
      printf '%s\t%d\t%s\t%s\t%s\t\tAPI_FAILURE\n' \
        "${file}" "${ln}" "${ref}" "${sha}" "${current}" >>"${OUTPUT}"
      ;;
    NO_PATCH_TAG)
      printf '%s\t%d\t%s\t%s\t%s\t\tNO_PATCH_TAG\n' \
        "${file}" "${ln}" "${ref}" "${sha}" "${current}" >>"${OUTPUT}"
      ;;
    *)
      printf '%s\t%d\t%s\t%s\t%s\t%s\tOK\n' \
        "${file}" "${ln}" "${ref}" "${sha}" "${current}" "${resolved}" >>"${OUTPUT}"
      ;;
    esac
  done <"${file}"
done

if awk -F'\t' 'NR>1 && $7=="API_FAILURE" {found=1} END {exit !found}' "$(awk_path "${OUTPUT}")"; then
  printf 'inventory: one or more API failures; see %s\n' "${OUTPUT}" >&2
  exit 1
fi
