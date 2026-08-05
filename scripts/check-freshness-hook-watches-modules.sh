#!/usr/bin/env bash
# scripts/check-freshness-hook-watches-modules.sh
#
# @description Lint: every pre-commit hook whose entry runs a generator
# that evaluates `devTooling.<system>.<attr>` names, in its `files`
# regex, every nix module that attribute is defined or transposed by.

# Lint: a freshness hook regenerates a doc from an evaluated flake
# attribute and refuses a stale commit. Its `files` regex decides which
# changed paths re-trigger it on the per-changed-file `git commit` path.
# A filter that misses a module the generator evaluates leaves the doc
# stale locally with the guard silent — CI's --all-files mirror still
# catches it, but the local fast-path defense is lost.
#
# The required module set is derived, not hardcoded:
#
#   - modules naming the evaluated attribute in non-comment nix source
#     (where it is defined), plus one level of their relative imports;
#   - modules assigning `flake.devTooling` in non-comment source (the
#     transposition every generator reads through).
#
# The second signal is why a module that merely mentions the attribute in
# a comment cannot be what makes it required: the transposition is
# structural, a comment is not.
#
# Source-parsed rather than `nix eval`-ed: `files` and `entry` are literal
# in source, and `nix eval` is the known local-commit-path long pole — no
# reason to add another eval-bound hook.
#
# Honors ROOT_OVERRIDE for fixtures (default: the repo root). Exits 0 on
# full coverage, 1 on any uncovered module.

set -Eeuo pipefail
IFS=$'\n\t'

root="${ROOT_OVERRIDE:-$(git rev-parse --show-toplevel)}"
readonly ROOT="${root}"

shopt -s nullglob

# Every tracked-shaped nix module under ROOT. Test fixtures are excluded:
# they contain deliberately malformed modules that would pollute the
# derivation.
nix_modules=()
while IFS= read -r m; do
  [[ -z ${m} ]] && continue
  nix_modules+=("${m}")
done < <(cd "${ROOT}" && find . -name '*.nix' \
  -not -path './tests/fixtures/*' -not -path './.git/*' -printf '%P\n' | sort)

# Nix source with comments removed. A `#` inside a string over-strips the
# rest of that line, which can only shrink the derived set; the
# guard-the-guard below is what catches a stripper that breaks outright.
function nix_source() {
  sed 's/#.*$//' -- "${ROOT}/$1"
}

# Every module the generator for `$1` depends on, one per line.
function required_modules() {
  local -r attr="$1"
  local -A mods=()
  local f
  for f in "${nix_modules[@]}"; do
    if nix_source "${f}" | grep --quiet --fixed-strings -- "${attr}"; then
      mods["${f}"]=1
    fi
    if nix_source "${f}" | grep --quiet --fixed-strings -- 'flake.devTooling'; then
      mods["${f}"]=1
    fi
  done
  # One level of relative imports. The expansion of "${!mods[@]}" is
  # evaluated once, so keys added inside the loop are not re-walked —
  # which is what makes this one level rather than a full closure.
  local m dir imp rel
  for m in "${!mods[@]}"; do
    dir="$(dirname -- "${m}")"
    while IFS= read -r imp; do
      [[ -z ${imp} ]] && continue
      rel="$(realpath --relative-to="${ROOT}" --canonicalize-missing \
        -- "${ROOT}/${dir}/${imp}")"
      if [[ -f ${ROOT}/${rel} ]]; then
        mods["${rel}"]=1
      fi
    done < <(grep --only-matching --extended-regexp \
      '\.\.?/[A-Za-z0-9._/-]+\.nix' -- "${ROOT}/${m}" || true)
  done
  printf '%s\n' "${!mods[@]}" | sort
}

# Step 1 — derive generator basename -> evaluated attribute.
declare -A generator_attr=()
for f in "${ROOT}"/scripts/*.sh; do
  [[ -f ${f} ]] || continue
  attr="$(grep --only-matching --extended-regexp \
    'devTooling\.\$\{sys\}\.[A-Za-z0-9_]+' -- "${f}" |
    head --lines=1 | sed 's/.*\.//' || true)"
  [[ -n ${attr} ]] || continue
  generator_attr["$(basename -- "${f}")"]="${attr}"
done

# Guard-the-guard: we know generators exist, so an empty map means the
# eval-shape grep broke rather than that nothing evaluates devTooling.
if ((${#generator_attr[@]} == 0)); then
  printf 'no devTooling-evaluating generator found in %s/scripts — derivation broke\n' \
    "${ROOT}" >&2
  exit 1
fi

# Guard-the-guard: the transposition is what makes the manifest module
# load-bearing for every generator, so a tree that evaluates devTooling yet has
# no module assigning `flake.devTooling` means the signal was renamed rather
# than that no module is required. Failing here beats silently shrinking every
# required set.
transposers=0
for f in "${nix_modules[@]}"; do
  if nix_source "${f}" | grep --quiet --fixed-strings -- 'flake.devTooling'; then
    transposers=$((transposers + 1))
  fi
done
if ((transposers == 0)); then
  printf 'no nix module assigns flake.devTooling in %s — transposer signal broke\n' \
    "${ROOT}" >&2
  exit 1
fi

# Step 2 — parse every hook block, emitting one record per block on its own
# line, fields separated by an ASCII unit separator (octal \037). A literal
# tab is unsafe here: an empty `files` value would put two delimiters back
# to back, and bash's `read` treats tab as IFS whitespace, which collapses
# adjacent delimiters and silently drops the empty field instead of
# preserving it — exactly the shape that would let Change 2 below never see
# an empty filter. \037 carries no such special casing and never appears in
# a `files` regex or a `scripts/*.sh` path.
#   <name>\037<files-string>\037<space-separated script basenames>
function parse_blocks() {
  local nix
  for nix in "${ROOT}"/nix/hooks/*.nix; do
    [[ -f ${nix} ]] || continue
    awk '
      /^  [A-Za-z0-9_-]+ = \{/ {
        name = $1
        in_block = 1
        files = ""
        scripts = ""
        next
      }
      in_block && /^  \};/ {
        printf "%s\037%s\037%s\n", name, files, scripts
        in_block = 0
        next
      }
      in_block {
        if (match($0, /files = "[^"]*"/)) {
          s = substr($0, RSTART, RLENGTH)
          sub(/^files = "/, "", s)
          sub(/"$/, "", s)
          files = s
        }
        line = $0
        while (match(line, /scripts\/[A-Za-z0-9._-]+\.sh/)) {
          tok = substr(line, RSTART, RLENGTH)
          sub(/^scripts\//, "", tok)
          scripts = (scripts == "" ? tok : scripts " " tok)
          line = substr(line, RSTART + RLENGTH)
        }
      }
    ' "${nix}"
  done
}

# Step 3 — assert each generator-running hook covers its module set.
failed=0
generator_hooks=0

while IFS=$'\037' read -r name files scripts; do
  [[ -n ${name} ]] || continue

  attr=''
  for s in ${scripts}; do
    if [[ -n ${generator_attr["${s}"]:-} ]]; then
      attr="${generator_attr["${s}"]}"
      break
    fi
  done
  [[ -n ${attr} ]] || continue

  generator_hooks=$((generator_hooks + 1))

  # An empty filter would become an empty ERE, which matches every path and
  # would report full coverage for a hook that watches nothing.
  if [[ -z ${files} ]]; then
    printf 'hook %s: empty files filter — nothing re-triggers it\n' "${name}" >&2
    failed=$((failed + 1))
    continue
  fi

  # Nix string literal: "\\." in source is the ERE "\.".
  ere="$(printf '%s' "${files}" | sed 's/\\\\/\\/g')"

  module_count=0
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    module_count=$((module_count + 1))
    if ! printf '%s\n' "${p}" | grep --quiet --extended-regexp -- "${ere}"; then
      printf 'hook %s: files filter does not cover %s (evaluates %s)\n' \
        "${name}" "${p}" "${attr}" >&2
      failed=$((failed + 1))
    fi
  done < <(required_modules "${attr}")

  # Guard-the-guard: an attribute with no defining module means the
  # comment-strip or the module walk broke. Fail loud, not vacuously.
  if ((module_count == 0)); then
    printf 'hook %s: no nix module defines %s — derivation broke\n' \
      "${name}" "${attr}" >&2
    failed=$((failed + 1))
  fi
done < <(parse_blocks)

shopt -u nullglob

# Guard-the-guard: zero generator-running hook blocks means the block
# parser broke (a reformat changed the block shape).
if ((generator_hooks == 0)); then
  printf 'no devTooling-evaluating hook blocks found in %s/nix/hooks — block parser likely broke\n' \
    "${ROOT}" >&2
  exit 1
fi

if ((failed > 0)); then
  printf '%d freshness hook filter gap(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
