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
# Detection works on backslash-continued shell invocations: when a
# line contains `gh attestation verify`, the lint walks forward while
# the previous line ends with `\`, then checks the joined block for
# `--repo rvenutolo/linPEAS-flake` (or `--repo=<slug>`).
#
# Documentation prose that *mentions* the command in backticks but
# isn't an actual invocation (no leading shell context) still gets
# scanned. Markdown fenced code blocks are the canonical place a
# bare invocation could land; the lint catches those.
#
# See docs/security/verification.md.
#
# Honors PATHS_OVERRIDE for fixtures (newline-separated file list).
# REPO_SLUG_OVERRIDE swaps the required slug.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_REPO_SLUG="rvenutolo/linPEAS-flake"
readonly REPO_SLUG="${REPO_SLUG_OVERRIDE:-${DEFAULT_REPO_SLUG}}"
readonly NEEDLE="--repo ${REPO_SLUG}"
readonly NEEDLE_EQ="--repo=${REPO_SLUG}"

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

# Join backslash-continued lines starting at the line that contains
# `gh attestation verify`. Returns one logical-line per occurrence.
#
# Filters out:
#   - shell/yaml comment lines (leading optional ws + `#`)
#   - markdown prose: for .md files, only lines INSIDE a fenced
#     ``` code block are considered
#   - inline mentions wrapped in backticks (line where the verify
#     command appears only inside `...` backticks)
extract_invocations() {
  local -r file="$1"
  local mode="other"
  case "${file}" in
  *.md) mode="md" ;;
  esac
  awk -v mode="${mode}" '
    BEGIN { in_fence = 0; fence_lang = "" }
    {
      line = $0
      # Track fenced-code state for markdown. Only treat sh/bash/
      # console/text fences (or unlabeled fences) as runnable code;
      # mermaid/dot/etc. are diagrams, not invocations.
      if (mode == "md") {
        if (line ~ /^[[:space:]]*```/) {
          if (in_fence) {
            in_fence = 0
            fence_lang = ""
          } else {
            in_fence = 1
            tmp = line
            sub(/^[[:space:]]*```/, "", tmp)
            sub(/[[:space:]].*$/, "", tmp)
            fence_lang = tmp
          }
          next
        }
        if (!in_fence) next
        if (fence_lang != "" \
            && fence_lang != "sh" \
            && fence_lang != "bash" \
            && fence_lang != "shell" \
            && fence_lang != "console" \
            && fence_lang != "text") next
      }
      # Skip comment lines for non-md sources (yml/sh).
      if (mode != "md" && line ~ /^[[:space:]]*#/) next
      # Skip backtick-only mentions (no shell context).
      # If `gh attestation verify` appears only between paired backticks
      # on this line and there are no unquoted occurrences, it is prose.
      if (line ~ /gh attestation verify/) {
        # crude check: strip backtick-quoted spans, then see if the
        # command still appears.
        stripped = line
        gsub(/`[^`]*`/, "", stripped)
        if (stripped !~ /gh attestation verify/) next
      }
      lines[++count] = line
      orig_nr[count] = NR
    }
    END {
      for (i = 1; i <= count; i++) {
        if (lines[i] !~ /gh attestation verify/) continue
        joined = lines[i]
        j = i
        while (j <= count && lines[j] ~ /\\[[:space:]]*$/) {
          j++
          if (j <= count) {
            line = lines[j]
            sub(/\\[[:space:]]*$/, "", joined)
            joined = joined " " line
          }
        }
        sub(/^[[:space:]]+/, "", joined)
        print joined
      }
    }
  ' "${file}"
}

failed=0
for f in "${paths[@]}"; do
  [[ -f ${f} ]] || continue
  # Skip self: this script contains literal "gh attestation verify"
  # in its detection regex and would otherwise flag itself.
  case "${f}" in
  */scripts/check-gh-attestation-repo.sh | scripts/check-gh-attestation-repo.sh)
    continue
    ;;
  esac
  while IFS= read -r invocation; do
    [[ -z ${invocation} ]] && continue
    # Skip prose: backticks-only mentions, comments-with-no-real-cmd.
    # Heuristic: if the invocation, after stripping, starts with a
    # backtick or a single word ending in a closing backtick AND has
    # no continuation actually firing the command, treat as prose.
    # For safety we instead REQUIRE the slug; prose mentions almost
    # always omit it. False positives are easy to silence by adding
    # the slug.
    if [[ ${invocation} == *"${NEEDLE}"* || ${invocation} == *"${NEEDLE_EQ}"* ]]; then
      continue
    fi
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: `gh attestation verify` missing `%s`; got: %s\n' \
      "${f}" "${NEEDLE}" "${invocation}" >&2
    failed=$((failed + 1))
  done < <(extract_invocations "${f}")
done

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d `gh attestation verify` invocation(s) missing --repo pin\n' "${failed}" >&2
  exit 1
fi
exit 0
