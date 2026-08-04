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
# forward while the previous line ends with `\`, then splits the joined
# block into one record per occurrence of the command and checks each
# record for `--repo rvenutolo/linPEAS-flake` (or `--repo=<slug>`).
# Backtick-quoted spans: a span is split the same way, and a record
# carrying the command plus at least one further token is an invocation
# that must pass the pin; a record holding the bare command name is a
# prose mention and is ignored.
#
# Splitting per occurrence is what keeps one invocation from vouching
# for another: a pinned command earlier in the line no longer satisfies
# the check for an unpinned command beside it.
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

# Emits one record per `gh attestation verify` invocation, drawn from
# two sources: backslash-continued runnable lines, joined and then split
# at each occurrence of the command, and backtick spans split the same
# way. A record carrying the command plus at least one further token is
# an invocation; a record holding the bare command name is a prose
# mention and is skipped. A runnable line is stored with its spans
# removed, so a quoted occurrence is accounted for once, by the span
# scan.
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
    BEGIN { in_fence = 0; fence_lang = ""; CMD = "gh attestation verify" }

    # Split `s` into one record per occurrence of the command: record i
    # runs from occurrence i to just before occurrence i+1, or to the end
    # of the string for the last. Text before the first occurrence is
    # dropped. Returns the record count, with records in out[1..n].
    #
    # index() is a literal left-to-right scan, so a string repeating the
    # command name cannot re-anchor the split the way a greedy regex can,
    # and a pinned invocation cannot vouch for an unpinned neighbour.
    function split_invocations(s, out,   n, i, tail) {
      n = 0
      i = index(s, CMD)
      if (i == 0) return 0
      s = substr(s, i)
      while (1) {
        tail = substr(s, length(CMD) + 1)
        i = index(tail, CMD)
        if (i == 0) {
          out[++n] = s
          return n
        }
        out[++n] = substr(s, 1, length(CMD) + i - 1)
        s = substr(s, length(CMD) + i)
      }
    }

    # Emit every invocation carried by a backtick span on `s`: a record
    # holding the command plus at least one further non-space token. A
    # record holding the bare command name is a prose mention.
    function emit_inline_spans(s,   span, recs, n, k, rec, rest) {
      while (match(s, /`[^`]*`/)) {
        span = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
        n = split_invocations(span, recs)
        for (k = 1; k <= n; k++) {
          rec = recs[k]
          sub(/[[:space:]]+$/, "", rec)
          rest = substr(rec, length(CMD) + 1)
          sub(/^[[:space:]]+/, "", rest)
          if (rest == "") continue
          print rec
        }
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
        # line only if the command also appears unquoted, and keep it
        # with the spans removed so a pinned span cannot vouch for an
        # unpinned command beside it.
        stripped = line
        gsub(/`[^`]*`/, "", stripped)
        if (stripped !~ /gh attestation verify/) next
        line = stripped
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
        n = split_invocations(joined, recs)
        for (k = 1; k <= n; k++) {
          rec = recs[k]
          sub(/[[:space:]]+$/, "", rec)
          print rec
        }
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
