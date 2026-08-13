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
#
# Honors LINT_ALLOW_EMPTY_SCAN=1 to accept an inventory carrying no rows.
#
# Exits 0 on a completed run, 1 when the inventory is rejected (API
# failure row, unknown status, stale line content), 2 when a file the run
# needs is not there to read — an unknown argument, an inventory file
# that is absent or unreadable, an inventory with no rows in it, or a
# recorded target file that is absent. Nothing was inspected in those
# cases, so the rejection code would misreport an unread file as a
# rejected one; a stale line, by contrast, is read before it is judged.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"

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
  exit 2
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

# The rows are captured with their status checked instead of being piped in
# from a substitution, whose status this shell never sees. `[[ -f ]]` above
# answers whether the inventory exists, not whether it can be read, so a
# readable-bit failure leaves `tail` exiting non-zero with nothing on stdout
# — and an inventory that produces no rows completes as `done: 0 applied, 0
# skipped` at exit 0, the same report a genuinely empty inventory earns. An
# API_FAILURE row that would have aborted the run at exit 1 disappears that
# way. Both the failed read and the empty result are could-not-run.
if ! inventory_rows="$(tail --lines=+2 -- "${INVENTORY}")"; then
  printf 'inventory not readable: %s\n' "${INVENTORY}" >&2
  exit 2
fi
if [[ -z ${inventory_rows} ]] && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf 'inventory carries no rows: %s; set LINT_ALLOW_EMPTY_SCAN=1 if an empty inventory is deliberate\n' \
    "${INVENTORY}" >&2
  exit 2
fi

# `read` returns non-zero on a final line with no trailing newline, so the
# `[[ -n ]]` fallback is what keeps a truncated inventory's last row from
# being silently dropped — dropping it would apply the earlier OK rows and
# report success while skipping an unvalidated row or an API_FAILURE abort.
while IFS= read -r raw_line || [[ -n ${raw_line} ]]; do
  # A capture read by `<<<` still yields one line when it is empty, and an
  # empty line parses into an empty status that no case arm should judge.
  [[ -z ${raw_line} ]] && continue
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
    exit 2
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
  ' "$(awk_path "${file}")"; then
    printf "abort (stale inventory at %s:%s): expected '%s' on line\n" \
      "${file}" "${line}" "${expected_substr}" >&2
    exit 1
  fi

  pending_files+=("${file}")
  pending_lines+=("${line}")
  pending_old+=("${expected_substr}")
  pending_new+=("${new_substr}")
done <<<"${inventory_rows}"

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
  ' "$(awk_path "${file}")" >"${tmp}"; then
    rm --force "${tmp}"
    printf 'abort (rewrite failed at %s:%s)\n' "${file}" "${line}" >&2
    exit 1
  fi
  mv "${tmp}" "${file}"
  applied=$((applied + 1))
done

printf 'done: %d applied, %d skipped\n' "${applied}" "${skipped}"
