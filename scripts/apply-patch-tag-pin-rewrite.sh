#!/usr/bin/env bash
# scripts/apply-patch-tag-pin-rewrite.sh
#
# @description Apply the patch-tag pin comment rewrite recorded in an
# inventory TSV produced by scripts/inventory-action-pin-tags.sh.
# Refuses to run if any recorded line content no longer matches the
# inventory (stale inventory protection) — aborts before mutating any
# file so the rewrite is all-or-nothing across the tree.
#
# OK rows have `target_comment` populated and are applied in place.
# NO_PATCH_TAG rows are skipped with a stderr warning.
# Any API_FAILURE row aborts the run before any mutation.
#
# Literal substring splicing via awk index/substr — no regex pitfalls
# on semver dots or path slashes.
#
# Default inventory path: ${TMPDIR:-/tmp}/action-pin-inventory.tsv
# Override with --inventory PATH.

set -Eeuo pipefail
IFS=$'\n\t'

INVENTORY="${TMPDIR:-/tmp}/action-pin-inventory.tsv"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --inventory)
    INVENTORY="$2"
    shift 2
    ;;
  *)
    printf 'unknown arg: %s\n' "$1" >&2
    exit 2
    ;;
  esac
done

[[ -f ${INVENTORY} ]] || {
  printf 'inventory not found: %s\n' "${INVENTORY}" >&2
  exit 1
}

# Pass 1: validate. Build a list of pending OK rewrites and reject up
# front on API_FAILURE, missing files, or stale line content. No file
# is mutated until every OK row has been validated, so a stale row in
# the middle of the inventory cannot leave the tree half-rewritten.

declare -a pending_files=()
declare -a pending_lines=()
declare -a pending_old=()
declare -a pending_new=()

applied=0
skipped=0

# `read` returns non-zero on a final line with no trailing newline, so the
# `[[ -n ]]` fallback is what keeps a truncated inventory's last row from
# being silently dropped — dropping it would apply the earlier OK rows and
# report success while skipping an unvalidated row or an API_FAILURE abort.
while IFS= read -r raw_line || [[ -n ${raw_line} ]]; do
  # `read` with IFS=$'\t' collapses consecutive tabs (tab is whitespace
  # in IFS), so an empty `target_comment` would merge with `status`.
  # Split manually via parameter expansion to preserve empty fields.
  file="${raw_line%%	*}"
  rest="${raw_line#*	}"
  line="${rest%%	*}"
  rest="${rest#*	}"
  ref="${rest%%	*}"
  rest="${rest#*	}"
  sha="${rest%%	*}"
  rest="${rest#*	}"
  current="${rest%%	*}"
  rest="${rest#*	}"
  target="${rest%%	*}"
  status="${rest#*	}"
  case "${status}" in
  OK) ;;
  NO_PATCH_TAG)
    printf 'skip (no patch tag): %s:%s %s\n' "${file}" "${line}" "${ref}" >&2
    skipped=$((skipped + 1))
    continue
    ;;
  API_FAILURE)
    printf 'abort (api failure in inventory): %s:%s %s\n' \
      "${file}" "${line}" "${ref}" >&2
    exit 1
    ;;
  *)
    printf 'abort (unknown status %s): %s:%s %s\n' \
      "${status}" "${file}" "${line}" "${ref}" >&2
    exit 1
    ;;
  esac

  [[ -f ${file} ]] || {
    printf 'abort (file missing): %s\n' "${file}" >&2
    exit 1
  }

  expected_substr="${ref}@${sha} # ${current}"
  new_substr="${ref}@${sha} # ${target}"

  # Verify the recorded line still contains the expected substring.
  if ! awk -v ln="${line}" -v old="${expected_substr}" '
    NR==ln {
      if (index($0, old) == 0) { exit 1 }
      exit 0
    }
    END { if (NR < ln) { exit 1 } }
  ' "${file}"; then
    printf "abort (stale inventory at %s:%s): expected '%s' on line\n" \
      "${file}" "${line}" "${expected_substr}" >&2
    exit 1
  fi

  pending_files+=("${file}")
  pending_lines+=("${line}")
  pending_old+=("${expected_substr}")
  pending_new+=("${new_substr}")
done < <(tail --lines=+2 "${INVENTORY}")

# Pass 2: apply. Validation already passed for every entry, so the awk
# splice cannot legitimately fail; treat any failure here as a hard
# error.
for i in "${!pending_files[@]}"; do
  file="${pending_files[${i}]}"
  line="${pending_lines[${i}]}"
  old="${pending_old[${i}]}"
  new="${pending_new[${i}]}"

  tmp="$(mktemp)"
  if ! awk -v ln="${line}" -v old="${old}" -v new="${new}" '
    NR==ln {
      pos = index($0, old)
      if (pos == 0) { exit 1 }
      print substr($0, 1, pos-1) new substr($0, pos+length(old))
      next
    }
    { print }
  ' "${file}" >"${tmp}"; then
    rm --force "${tmp}"
    printf 'abort (rewrite failed at %s:%s)\n' "${file}" "${line}" >&2
    exit 1
  fi
  mv "${tmp}" "${file}"
  applied=$((applied + 1))
done

printf 'done: %d applied, %d skipped\n' "${applied}" "${skipped}"
