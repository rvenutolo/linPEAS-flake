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
# full coverage, 1 on any uncovered module, 2 when a producer the
# derivation depends on could not run.

set -Eeuo pipefail
IFS=$'\n\t'

root="${ROOT_OVERRIDE:-$(git rev-parse --show-toplevel)}"
readonly ROOT="${root}"

shopt -s nullglob

# Every tracked-shaped nix module under ROOT. Test fixtures are excluded:
# they contain deliberately malformed modules that would pollute the
# derivation.
#
# The scan's status is checked before its output is consumed. A scan that
# never reaches the tree — ROOT is absent, or is not a directory — emits
# nothing, and an empty module list reads downstream as "no module assigns
# flake.devTooling", reporting a broken transposer signal for a tree that
# is simply not there.
if ! module_scan="$(cd "${ROOT}" && find . -name '*.nix' \
  -not -path './tests/fixtures/*' -not -path './.git/*' -printf '%P\n' | sort)"; then
  printf 'freshness-hook-watches-modules: nix module scan under %s failed\n' \
    "${ROOT}" >&2
  exit 2
fi

nix_modules=()
while IFS= read -r m; do
  [[ -z ${m} ]] && continue
  nix_modules+=("${m}")
done <<<"${module_scan}"

# Nix source with comments removed. A `#` inside a string over-strips the
# rest of that line, which can only shrink the derived set; the read guard
# below is what catches a stripper that breaks outright.
function nix_source() {
  sed 's/#.*$//' -- "${ROOT}/$1"
}

# Every module's comment-stripped source, read once up front and keyed by
# module path. Every signal below matches against this map rather than
# re-reading through a `nix_source | grep` pipeline, because such a
# pipeline cannot report a read failure: under `pipefail` a failed `sed`
# alongside a `grep` that found nothing returns grep's 1, so a module the
# stripper could not read scores exactly like a module that does not
# mention the token. A path matching `*.nix` that is a directory or a
# dangling symlink is precisely that case, and it would shrink every
# derived set with no output at all.
declare -A nix_src=()
for m in "${nix_modules[@]}"; do
  if ! nix_src["${m}"]="$(nix_source "${m}")"; then
    printf 'freshness-hook-watches-modules: comment-strip of %s failed — module unreadable\n' \
      "${m}" >&2
    exit 2
  fi
done

# Every module the generator for `$1` depends on, one per line.
function required_modules() {
  local -r attr="$1"
  local -A mods=()
  local f
  for f in "${nix_modules[@]}"; do
    if grep --quiet --fixed-strings -- "${attr}" <<<"${nix_src["${f}"]}"; then
      mods["${f}"]=1
    fi
    if grep --quiet --fixed-strings -- 'flake.devTooling' <<<"${nix_src["${f}"]}"; then
      mods["${f}"]=1
    fi
  done
  # One level of relative imports. Walks the comment-stripped source rather
  # than the raw file, consistent with every other signal in this function,
  # so a commented-out import cannot join the required set. The expansion of
  # "${!mods[@]}" is evaluated once, so keys added inside the loop are not
  # re-walked — which is what makes this one level rather than a full
  # closure, and which is also why every key here is still a module the
  # read loop above has already stored.
  local m dir imp rel imports status
  for m in "${!mods[@]}"; do
    dir="$(dirname -- "${m}")"
    status=0
    imports="$(grep --only-matching --extended-regexp \
      '\.\.?/[A-Za-z0-9._/-]+\.nix' <<<"${nix_src["${m}"]}")" || status=$?
    # A module with no imports is the common case and grep reports it as
    # status 1, so only a higher status is a scan that broke rather than
    # one that found nothing. Returning here rather than swallowing the
    # status keeps a broken scan from quietly shrinking the required set.
    # No fixture drives this branch: grep reads a here-string built from
    # memory against a literal pattern, so it has no I/O or compile error
    # left to hit.
    if ((status > 1)); then
      printf 'freshness-hook-watches-modules: import scan of %s failed\n' \
        "${m}" >&2
      return 1
    fi
    while IFS= read -r imp; do
      [[ -z ${imp} ]] && continue
      rel="$(realpath --relative-to="${ROOT}" --canonicalize-missing \
        -- "${ROOT}/${dir}/${imp}")"
      if [[ -f ${ROOT}/${rel} ]]; then
        mods["${rel}"]=1
      fi
    done <<<"${imports}"
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
  if grep --quiet --fixed-strings -- 'flake.devTooling' <<<"${nix_src["${f}"]}"; then
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
# preserving it — exactly the shape that would let the empty-filter guard
# below never see an empty filter. \037 carries no such special casing and
# never appears in a `files` regex or a `scripts/*.sh` path.
#   <name>\037<files-string>\037<space-separated script basenames>
#
# An `awk` fault is returned explicitly rather than left to errexit: the
# caller captures this function in a command substitution inside an `if`
# condition, where errexit is suppressed, so a bare non-zero `awk` would
# leave the function returning 0 with a short block list.
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
    ' "${nix}" || return 1
  done
}

# Count of nix modules that textually name $1 in non-comment source,
# ignoring the `flake.devTooling` transposer signal. Used to guard against
# an attribute the module walk never actually finds, which the transposer
# signal alone would otherwise mask: `required_modules` always includes
# every transposer-matching module regardless of `$1`, so its output is
# never empty once the transposers guard above has already passed.
function attr_definer_count() {
  local -r attr="$1"
  local n=0 f
  for f in "${nix_modules[@]}"; do
    if grep --quiet --fixed-strings -- "${attr}" <<<"${nix_src["${f}"]}"; then
      n=$((n + 1))
    fi
  done
  printf '%s' "${n}"
}

# Step 3 — assert each generator-running hook covers its module set.
failed=0
generator_hooks=0
declare -A claimed_generators=()

# Capture the parser's records and check its status before consuming them:
# a producer whose status the loop never sees turns a broken parse into a
# smaller hook set, which reads as coverage rather than as a fault. No
# fixture drives this guard, because nothing the script can be handed makes
# the parser fail: only a regular file reaches `awk` (the `-f` test drops
# directories, dangling symlinks, and fifos named `*.nix`), and this awk
# program does no I/O of its own, so a readable regular file always parses.
# The guard exists so a future producer change cannot fail silently.
if ! blocks="$(parse_blocks)"; then
  printf 'freshness-hook-watches-modules: hook block parse failed\n' >&2
  exit 2
fi

while IFS=$'\037' read -r name files scripts; do
  [[ -n ${name} ]] || continue

  attr=''
  # Split on spaces explicitly: the global IFS is newline+tab, so a block
  # naming its script more than once (the house shape is a `[[ ! -f
  # scripts/foo.sh ]]` guard plus an `exec ... scripts/foo.sh` call) would
  # otherwise stay one unsplittable word, the generator_attr lookup would
  # miss it, and the hook would be skipped with no output.
  IFS=' ' read -r -a script_list <<<"${scripts}"
  for s in "${script_list[@]}"; do
    if [[ -n ${generator_attr["${s}"]:-} ]]; then
      attr="${generator_attr["${s}"]}"
      claimed_generators["${s}"]=1
      break
    fi
  done
  [[ -n ${attr} ]] || continue

  generator_hooks=$((generator_hooks + 1))

  # Guard-the-guard: an attribute matched by zero modules means the
  # comment-strip or the module walk broke. Fail loud, not vacuously.
  # Checked independently of the files filter below, since the module
  # walk itself is what could be broken.
  if (($(attr_definer_count "${attr}") == 0)); then
    printf 'hook %s: no nix module defines %s — derivation broke\n' \
      "${name}" "${attr}" >&2
    failed=$((failed + 1))
  fi

  # An empty filter would become an empty ERE, which matches every path and
  # would report full coverage for a hook that watches nothing.
  if [[ -z ${files} ]]; then
    printf 'hook %s: empty files filter — nothing re-triggers it\n' "${name}" >&2
    failed=$((failed + 1))
    continue
  fi

  # Nix string literal: "\\." in source is the ERE "\.".
  ere="$(printf '%s' "${files}" | sed 's/\\\\/\\/g')"

  # Capture the derived set and check its status before consuming it: a
  # derivation that gives up part way emits nothing, and an empty set reads
  # as a hook whose filter already covers every module it must. No fixture
  # drives this guard, because every producer inside `required_modules`
  # reads memory rather than the tree — each module's source is read and
  # status-checked up front — so the only status it can return is the one
  # its own inner guard raises.
  if ! required="$(required_modules "${attr}")"; then
    printf 'freshness-hook-watches-modules: required-module derivation for %s failed\n' \
      "${attr}" >&2
    exit 2
  fi

  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    if ! printf '%s\n' "${p}" | grep --quiet --extended-regexp -- "${ere}"; then
      printf 'hook %s: files filter does not cover %s (evaluates %s)\n' \
        "${name}" "${p}" "${attr}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${required}"
done <<<"${blocks}"

shopt -u nullglob

# Guard-the-guard: zero generator-running hook blocks means the block
# parser broke (a reformat changed the block shape).
if ((generator_hooks == 0)); then
  printf 'no devTooling-evaluating hook blocks found in %s/nix/hooks — block parser likely broke\n' \
    "${ROOT}" >&2
  exit 1
fi

# Guard-the-guard: a generator basename that never got claimed by any hook
# block means the block parser's script-list split missed it — the lookup
# above silently returns empty and the hook is skipped with no output.
for s in "${!generator_attr[@]}"; do
  if [[ -z ${claimed_generators["${s}"]:-} ]]; then
    printf 'generator %s (evaluates %s) claimed by no hook block\n' \
      "${s}" "${generator_attr["${s}"]}" >&2
    failed=$((failed + 1))
  fi
done

if ((failed > 0)); then
  printf '%d freshness hook filter gap(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
