#!/usr/bin/env bash
# scripts/sbom-diff.sh
#
# Diff two SPDX-JSON SBOMs by package name + version, emit a
# collapsible markdown block suitable for embedding in a GitHub
# release body.
#
# Usage:
#   sbom-diff.sh <old-sbom.spdx.json> <new-sbom.spdx.json> [previous-tag]
#
# Reads `.packages[] | {name, versionInfo}` from each SBOM, then
# computes:
#   - added: name appears in new but not in old
#   - removed: name appears in old but not in new
#   - changed: name in both, versionInfo differs
#
# Output is a single markdown <details> block on stdout. Deterministic
# (sorted) so identical inputs produce byte-identical output.
#
# Exits 0 on success including the "no diff" case. Exits non-zero only
# on bad args or malformed input (jq failure).

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "error: line ${LINENO} (exit $?): ${BASH_COMMAND}" >&2' ERR

if (($# < 2 || $# > 3)); then
  printf 'usage: %s <old-sbom> <new-sbom> [previous-tag]\n' "$0" >&2
  exit 2
fi

readonly OLD_SBOM="$1"
readonly NEW_SBOM="$2"
readonly PREVIOUS_TAG="${3:-previous release}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq not on PATH\n' >&2
  exit 1
fi

if [[ ! -f ${OLD_SBOM} ]]; then
  printf 'old SBOM not found: %s\n' "${OLD_SBOM}" >&2
  exit 1
fi
if [[ ! -f ${NEW_SBOM} ]]; then
  printf 'new SBOM not found: %s\n' "${NEW_SBOM}" >&2
  exit 1
fi

# Extract `name<TAB>version` lines, sorted by name. NOASSERTION /
# missing versionInfo collapses to empty string.
readonly JQ_EXTRACT='
  .packages // []
  | map({
      name: (.name // ""),
      version: (
        if (.versionInfo // "NOASSERTION") == "NOASSERTION"
        then ""
        else .versionInfo
        end
      )
    })
  | map(select(.name != ""))
  | unique_by(.name)
  | sort_by(.name)
  | .[]
  | [.name, .version]
  | @tsv
'

old_tsv="$(mktemp)"
new_tsv="$(mktemp)"
trap 'rm --force -- "${old_tsv}" "${new_tsv}"' EXIT

jq --raw-output "${JQ_EXTRACT}" "${OLD_SBOM}" >"${old_tsv}"
jq --raw-output "${JQ_EXTRACT}" "${NEW_SBOM}" >"${new_tsv}"

# Build associative maps name -> version for both sides.
declare -A old_versions=()
declare -A new_versions=()

while IFS=$'\t' read -r name version; do
  [[ -z ${name} ]] && continue
  old_versions["${name}"]="${version}"
done <"${old_tsv}"

while IFS=$'\t' read -r name version; do
  [[ -z ${name} ]] && continue
  new_versions["${name}"]="${version}"
done <"${new_tsv}"

added_tmp="$(mktemp)"
removed_tmp="$(mktemp)"
changed_tmp="$(mktemp)"
trap 'rm --force -- "${old_tsv}" "${new_tsv}" "${added_tmp}" "${removed_tmp}" "${changed_tmp}"' EXIT

for name in "${!new_versions[@]}"; do
  if [[ -z ${old_versions["${name}"]+set} ]]; then
    printf '%s\t%s\n' "${name}" "${new_versions["${name}"]}" >>"${added_tmp}"
  elif [[ ${old_versions["${name}"]} != "${new_versions["${name}"]}" ]]; then
    printf '%s\t%s\t%s\n' \
      "${name}" "${old_versions["${name}"]}" "${new_versions["${name}"]}" \
      >>"${changed_tmp}"
  fi
done

for name in "${!old_versions[@]}"; do
  if [[ -z ${new_versions["${name}"]+set} ]]; then
    printf '%s\t%s\n' "${name}" "${old_versions["${name}"]}" >>"${removed_tmp}"
  fi
done

sort --output="${added_tmp}" "${added_tmp}"
sort --output="${removed_tmp}" "${removed_tmp}"
sort --output="${changed_tmp}" "${changed_tmp}"

added_count="$(wc --lines <"${added_tmp}")"
removed_count="$(wc --lines <"${removed_tmp}")"
changed_count="$(wc --lines <"${changed_tmp}")"
added_count=$((10#${added_count}))
removed_count=$((10#${removed_count}))
changed_count=$((10#${changed_count}))

printf '<details>\n'
printf '<summary>SBOM diff vs <code>%s</code> — +%d / -%d / ~%d</summary>\n\n' \
  "${PREVIOUS_TAG}" "${added_count}" "${removed_count}" "${changed_count}"

if ((added_count == 0 && removed_count == 0 && changed_count == 0)); then
  printf '_No package-set changes._\n\n'
else
  if ((added_count > 0)); then
    printf '**Added (%d)**\n\n' "${added_count}"
    while IFS=$'\t' read -r name version; do
      if [[ -n ${version} ]]; then
        # shellcheck disable=SC2016 # literal backticks for markdown code spans
        printf -- '- `%s` @ `%s`\n' "${name}" "${version}"
      else
        # shellcheck disable=SC2016 # literal backticks for markdown code spans
        printf -- '- `%s`\n' "${name}"
      fi
    done <"${added_tmp}"
    printf '\n'
  fi

  if ((removed_count > 0)); then
    printf '**Removed (%d)**\n\n' "${removed_count}"
    while IFS=$'\t' read -r name version; do
      if [[ -n ${version} ]]; then
        # shellcheck disable=SC2016 # literal backticks for markdown code spans
        printf -- '- `%s` @ `%s`\n' "${name}" "${version}"
      else
        # shellcheck disable=SC2016 # literal backticks for markdown code spans
        printf -- '- `%s`\n' "${name}"
      fi
    done <"${removed_tmp}"
    printf '\n'
  fi

  if ((changed_count > 0)); then
    printf '**Version-changed (%d)**\n\n' "${changed_count}"
    while IFS=$'\t' read -r name old_version new_version; do
      # shellcheck disable=SC2016 # literal backticks for markdown code spans
      printf -- '- `%s`: `%s` → `%s`\n' \
        "${name}" "${old_version:-?}" "${new_version:-?}"
    done <"${changed_tmp}"
    printf '\n'
  fi
fi

printf '</details>\n'
