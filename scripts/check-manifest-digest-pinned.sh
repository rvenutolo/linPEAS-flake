#!/usr/bin/env bash
# scripts/check-manifest-digest-pinned.sh
#
# @description Lint: every multi-arch manifest-creating docker command
# references its SOURCE images by immutable digest, never by a mutable
# tag.

# Lint: every `docker buildx imagetools create`, `docker manifest
# create`, and `docker manifest annotate` invocation across workflows,
# composite actions, scripts, and shell-fenced markdown references its
# source images by immutable digest — an `@sha256:` literal or an
# `@${…DIGEST}` expansion.
#
# Tags can be rewritten between the per-arch push and manifest creation
# (registry incident, credential compromise, manual re-run race);
# digests cannot. A manifest assembled from tags reopens that window: an
# attacker who rewrites a per-arch tag poisons the published index while
# the per-arch attestations still verify against the original digests.
#
# Target list names are exempt because they are tags by necessity:
# `imagetools create` names its target with `--tag`, and both `manifest
# create LIST SRC…` and `manifest annotate LIST SRC` take the list being
# built as their first positional. Only source refs are checked.
#
# Detection joins backslash-continued shell invocations; ignores prose
# in backticks and command names quoted inside message strings; for
# markdown, only considers fenced blocks tagged
# sh/bash/shell/console/text (or unlabeled). Skips this script.
#
# See docs/install/docker.md.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

# Whitespace is matched as [[:space:]]+ rather than a literal space so
# the pattern survives an shfmt reflow of a scanned script.
readonly CMD_REGEX='docker[[:space:]]+(buildx[[:space:]]+imagetools[[:space:]]+create|manifest[[:space:]]+(create|annotate))([[:space:]]|$)'

# Flags that consume the following token as their value. Their values
# are targets or settings, never source refs. This is the complete
# value-taking set across the three matched commands: `imagetools
# create` (--tag/-t, --file/-f, --annotation, --builder, --progress),
# `manifest annotate` (--arch, --os, --os-features, --os-version,
# --variant), and `manifest create` (whose --amend and --insecure are
# booleans). Every other flag on those commands is a boolean.
#
# An unrecognized flag deliberately does NOT consume the next token: its
# value then surfaces as a loud "not digest-pinned" false positive
# instead of silently swallowing whatever follows it. Swallowing would
# let a real unpinned source ref sitting after an unknown flag pass
# unseen, so this fails closed on purpose — a new flag is a reviewed
# edit to this list, not a silent hole.
readonly VALUE_FLAGS='--tag --file --annotation --builder --progress --platform --arch --os --os-features --os-version --variant -t -f'

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
    '.github/actions/*.yml' '.github/actions/*.yaml' \
    '.github/actions/**/*.yml' '.github/actions/**/*.yaml' \
    'scripts/*.sh' \
    'docs/**/*.md' \
    'docs/*.md' \
    'README.md' 2>/dev/null || true)
fi

extract_invocations() {
  local -r file="$1"
  local mode="other"
  case "${file}" in
  *.md) mode="md" ;;
  esac
  awk -v mode="${mode}" -v rx="${CMD_REGEX}" -v sq="'" '
    BEGIN { in_fence = 0; fence_lang = "" }
    {
      line = $0
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
      if (mode != "md" && line ~ /^[[:space:]]*#/) next
      # Skip yaml step-name lines that happen to mention the command.
      if (mode != "md" && line ~ /^[[:space:]]*-?[[:space:]]*(name|description):/) next
      # A match inside backticks or inside a shell string literal is
      # data, not a command: markdown prose in the first case, a printf
      # or echo message that merely names the command in the second.
      # Only a match that survives stripping both is an invocation.
      if (line ~ rx) {
        stripped = line
        gsub(/`[^`]*`/, "", stripped)
        gsub(sq "[^" sq "]*" sq, "", stripped)
        gsub(/"[^"]*"/, "", stripped)
        if (stripped !~ rx) next
      }
      lines[++count] = line
    }
    END {
      for (i = 1; i <= count; i++) {
        if (lines[i] !~ rx) continue
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

# Reduce a joined invocation to its source refs and report any that is
# not digest-pinned. Echoes one message per violation; returns the
# violation count via the global `failed`.
check_invocation() {
  local -r file="$1"
  local invocation="$2"
  # Collapse whitespace runs so a reflowed `docker  manifest   create`
  # tokenizes identically to the canonical spelling.
  invocation="$(printf '%s' "${invocation}" | tr '\t' ' ' | tr --squeeze-repeats ' ')"

  local rest skip_first=0
  case "${invocation}" in
  *"docker buildx imagetools create"*)
    rest="${invocation#*docker buildx imagetools create}"
    ;;
  *"docker manifest create"*)
    rest="${invocation#*docker manifest create}"
    skip_first=1
    ;;
  *"docker manifest annotate"*)
    rest="${invocation#*docker manifest annotate}"
    skip_first=1
    ;;
  *)
    return 0
    ;;
  esac

  local -a tokens=()
  IFS=' ' read -r -a tokens <<<"${rest}"

  local -a refs=()
  local i=0 tok
  while ((i < ${#tokens[@]})); do
    tok="${tokens[i]}"
    case "${tok}" in
    '&&' | '||' | ';' | '|' | '>' | '>>' | '2>' | '2>&1')
      # A shell operator ends this command; later tokens belong to another.
      break
      ;;
    --*=*) ;;
    -*)
      if [[ " ${VALUE_FLAGS} " == *" ${tok} "* ]]; then
        i=$((i + 1))
      fi
      ;;
    *)
      refs+=("${tok}")
      ;;
    esac
    i=$((i + 1))
  done

  # `manifest create` / `manifest annotate` name the list being built as
  # their first positional; that is a tag by necessity, not a source.
  if ((skip_first == 1 && ${#refs[@]} > 0)); then
    refs=("${refs[@]:1}")
  fi

  local ref var
  for ref in "${refs[@]:-}"; do
    [[ -z ${ref} ]] && continue
    ref="${ref%\"}"
    ref="${ref#\"}"
    ref="${ref%\'}"
    ref="${ref#\'}"
    if [[ ${ref} == *"@sha256:"* ]]; then
      continue
    fi
    if [[ ${ref} =~ @\$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]]; then
      var="${BASH_REMATCH[1]}"
      if [[ ${var^^} == *DIGEST* ]]; then
        continue
      fi
    fi
    printf '%s: manifest source ref not digest-pinned: %s; in: %s\n' \
      "${file}" "${ref}" "${invocation}" >&2
    failed=$((failed + 1))
  done
}

failed=0
for f in "${paths[@]}"; do
  [[ -f ${f} ]] || continue
  case "${f}" in
  */scripts/check-manifest-digest-pinned.sh | scripts/check-manifest-digest-pinned.sh)
    continue
    ;;
  esac
  # Capture-then-check so an `awk` failure is a loud tooling fault rather
  # than an empty read that scores the file clean. No input this script
  # can receive reaches that branch: the `-f` gate above rejects
  # directories, symlinks to directories, and missing paths — the only
  # `PATHS_OVERRIDE` entries that could upset the producer — and gawk,
  # which the hook puts on PATH, treats a directory argument as a warning
  # and exits 0 regardless. The guard covers whatever the producer comes
  # to run, so it stays.
  if ! out="$(extract_invocations "${f}")"; then
    printf 'manifest-digest-pinned: extract_invocations failed for %s\n' "${f}" >&2
    exit 2
  fi
  while IFS= read -r invocation; do
    [[ -z ${invocation} ]] && continue
    check_invocation "${f}" "${invocation}"
  done <<<"${out}"
done

if ((failed > 0)); then
  printf '%d manifest source ref(s) not digest-pinned\n' "${failed}" >&2
  exit 1
fi
exit 0
