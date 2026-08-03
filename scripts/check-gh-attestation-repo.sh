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
# Detection has two shapes. Backslash-continued shell invocations:
# when a runnable line contains `gh attestation verify`, the lint walks
# forward while the previous line ends with `\`, then checks the joined
# block for `--repo rvenutolo/linPEAS-flake` (or `--repo=<slug>`).
# Backtick-quoted spans: a span carrying the command plus at least one
# further token is an invocation and must pass the pin; a span holding
# the bare command name is a prose mention and is ignored.
#
# Which lines are runnable depends on the file. In markdown, fenced
# `sh`/`bash`/`shell`/`console`/`text` (or unlabeled) blocks are shell
# source and prose lines contribute only their inline code spans;
# other fences are diagrams and are skipped entirely. In yml/sh, every
# non-comment line is shell source — the comment skip runs first so a
# backticked command with an elided argument inside a comment is not
# read as an invocation.
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

# Emits one logical line per `gh attestation verify` invocation, drawn
# from two sources: backslash-continued runnable lines, joined into a
# single string, and backtick spans that classify as invocations — a
# span carrying the command plus at least one further token. A span
# holding the bare command name is a prose mention and is skipped.
#
# Markdown prose lines contribute only their inline spans; markdown
# fences labeled sh/bash/shell/console/text (or unlabeled) are shell
# source and get the full treatment above, other fences are skipped
# entirely. In yml/sh, comment lines are skipped before the span scan
# runs.
extract_invocations() {
  local -r file="$1"
  local mode="other"
  case "${file}" in
  *.md) mode="md" ;;
  esac
  awk -v mode="${mode}" '
    BEGIN { in_fence = 0; fence_lang = "" }

    # Emit every backtick span on `s` that parses as an invocation: a
    # span holding the command plus at least one further non-space
    # token. A span holding the bare command name is a prose mention.
    function emit_inline_spans(s,   span, rest) {
      while (match(s, /`[^`]*`/)) {
        span = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
        if (span !~ /gh attestation verify/) continue
        rest = span
        sub(/^.*gh attestation verify/, "", rest)
        sub(/^[[:space:]]+/, "", rest)
        sub(/[[:space:]]+$/, "", rest)
        if (rest == "") continue
        print span
      }
    }

    {
      line = $0
      if (mode == "md") {
        # Track fenced-code state. Only sh/bash/shell/console/text
        # fences (or unlabeled ones) are runnable code; mermaid/dot
        # and friends are diagrams, not invocations.
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
        if (!in_fence) {
          # Markdown prose. An inline code span is the only runnable
          # shape here; the surrounding sentence is not shell source.
          emit_inline_spans(line)
          next
        }
        if (fence_lang != "" \
            && fence_lang != "sh" \
            && fence_lang != "bash" \
            && fence_lang != "shell" \
            && fence_lang != "console" \
            && fence_lang != "text") next
      } else {
        # yml/sh: a comment line is prose whatever it quotes. This skip
        # must precede the span scan — a comment can carry a backticked
        # command with an elided argument, which the span rule would
        # otherwise read as an invocation.
        if (line ~ /^[[:space:]]*#/) next
      }
      # Runnable source line: a markdown shell fence body, or a
      # non-comment yml/sh line. Backtick spans here are command
      # substitution and get the same treatment as markdown inline code.
      emit_inline_spans(line)
      if (line ~ /gh attestation verify/) {
        # The span scan already handled quoted occurrences. Keep the
        # line only if the command also appears unquoted.
        stripped = line
        gsub(/`[^`]*`/, "", stripped)
        if (stripped !~ /gh attestation verify/) next
      }
      lines[++count] = line
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
  # Skip self, and check-egress-allowlist.sh: both scripts contain the
  # literal "gh attestation verify" as a `run:`-text match key rather
  # than an actual invocation, and would otherwise flag themselves.
  case "${f}" in
  */scripts/check-gh-attestation-repo.sh | scripts/check-gh-attestation-repo.sh | \
    */scripts/check-egress-allowlist.sh | scripts/check-egress-allowlist.sh)
    continue
    ;;
  esac
  while IFS= read -r invocation; do
    [[ -z ${invocation} ]] && continue
    # Prose mentions were filtered during extraction; everything
    # reaching here is an invocation and must carry the slug.
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
