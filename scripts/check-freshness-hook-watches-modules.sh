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
# Two hook shapes reach a flake attribute, and both are subjects here.
#
# A hook whose entry runs a `scripts/*.sh` generator: the required module
# set is derived, not hardcoded:
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
# A hook whose entry evaluates a flake attribute directly (`nix build
# ".#<ns>.${system}.<leaf>"`) carries no generator token at all, so the
# script-keyed lookup skips it and its filter may omit every source the
# attribute reads. Its required set is the flake expression and its lock,
# every nix module that *assigns* the attribute, and one level of the
# relative path references out of those modules. A bare mention of the
# leaf is deliberately not enough — the hook block naming the attribute in
# its own entry is not a source of it — and the reference walk is not
# restricted to `*.nix`, because a module that embeds a script by path
# depends on that script's contents.
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
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

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
#
# The `cd` is what makes the emitted paths relative to ROOT, so it is kept
# inside this same-file wrapper rather than folded into the `find`
# invocation directly: a function invoked as a command is not a process
# substitution feeding a redirection, which is the shape
# check-no-opaque-procsub.sh bans.
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function freshness_module_scan() {
  (cd "${ROOT}" && find . -name '*.nix' \
    -not -path './tests/fixtures/*' -not -path './.git/*' -printf '%P\0') |
    sort --zero-terminated
}

nix_modules=()
enumerate_into nix_modules "nix module scan under ${ROOT}" freshness_module_scan

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

# Fill the array named `$1` with the keys of the associative array named
# `$2`, sorted. Sorted through a NUL-delimited temp file rather than a
# newline-joined `sort` pipe: a key here is a module or source path threaded
# in from `enumerate_into`, so it may carry an embedded newline, and joining
# it into text to sort it would fracture it right back into two paths
# neither `assert_filter_covers` nor a human reader could attribute to the
# real file. The temp file (not a `< <(…)` process substitution) is what
# `check-no-opaque-procsub.sh` requires: that lint bans a process
# substitution feeding a redirection outright.
function sorted_keys_into() {
  local -n __sk_out="$1"
  local -n __sk_map="$2"
  local tmp p
  tmp="$(mktemp)" || return 1
  printf '%s\0' "${!__sk_map[@]}" | sort --zero-terminated >"${tmp}"
  __sk_out=()
  while IFS= read -r -d '' p || [[ -n ${p} ]]; do
    [[ -n ${p} ]] || continue
    __sk_out+=("${p}")
  done <"${tmp}"
  rm --force -- "${tmp}"
}

# Fill the array named `$1` with every module the generator for `$2`
# depends on.
function required_modules() {
  local -r out_name="$1"
  local -r attr="$2"
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
  sorted_keys_into "${out_name}" mods
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
#   <name>\037<files-string>\037<space-separated script basenames>\037
#   <attr-namespace>\037<attr-leaf>\037<attr-reference-seen>
#
# The attrpath a hook entry names carries a `${…system…}` interpolation
# mid-path, so its namespace is the first dot-separated component and its
# leaf is the last. The trailing flag is set by a deliberately looser
# pattern — any `.#` followed by an interpolation — so a reformat that
# defeats the precise extraction still reports the block as naming an
# attribute, which is what lets the caller tell a broken parser apart from
# a tree that simply has no attribute-evaluating hook.
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
        attr_ns = ""
        attr_leaf = ""
        attr_seen = ""
        next
      }
      in_block && /^  \};/ {
        printf "%s\037%s\037%s\037%s\037%s\037%s\n", \
          name, files, scripts, attr_ns, attr_leaf, attr_seen
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
        if (attr_leaf == "" &&
            match($0, /\.#[A-Za-z0-9_-]+\.\$\{[^}]*system[^}]*\}\.[A-Za-z0-9_-]+/)) {
          ref = substr($0, RSTART, RLENGTH)
          sub(/^\.#/, "", ref)
          attr_ns = ref
          sub(/\..*$/, "", attr_ns)
          attr_leaf = ref
          sub(/^.*\./, "", attr_leaf)
        }
        if (match($0, /\.#[^" \t]*\$\{/)) {
          attr_seen = "1"
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

# Fill the array named `$1` with every nix module that assigns the flake
# attribute `$2.$3` in non-comment source. Matched on the assignment shape
# rather than on a bare mention of the leaf: the hook block that evaluates
# the attribute names it in its own entry, and a hook is not a source of
# the attribute it builds.
#
# The result is written into a caller-named array, not printed and
# recaptured through a newline-joined string: a module path carrying an
# embedded newline is one element in `nix_modules` (courtesy of
# `enumerate_into`), and joining it into text for a caller to re-split
# would fracture it right back into two nonexistent lookup keys into
# `nix_src` — the exact bug this conversion exists to close.
function attr_assigners() {
  local -n __attr_assigners_out="$1"
  local -r ns="$2"
  local -r leaf="$3"
  __attr_assigners_out=()
  local f
  for f in "${nix_modules[@]}"; do
    if grep --quiet --extended-regexp -- "${ns}\.${leaf}[[:space:]]*=" \
      <<<"${nix_src["${f}"]}"; then
      __attr_assigners_out+=("${f}")
    fi
  done
  return 0
}

# Fill the array named `$1` with every file a directly-evaluated flake
# attribute is built from, given its assigning modules as the array named
# `$2`.
#
# `flake.nix` and `flake.lock` are unconditional: every flake evaluation
# reads the expression and its lock, and a lock bump changes the packages
# the attribute resolves to without touching a single module.
#
# The reference walk accepts any extension, not just `.nix`. A module that
# embeds a script with `${../scripts/foo.sh}` depends on that script's
# contents exactly as much as on an imported module, and a `.nix`-only
# walk would drop it from the required set.
function attr_source_paths() {
  local -r out_name="$1"
  local -n __asp_assigners="$2"
  # shellcheck disable=SC2034 # read via sorted_keys_into's nameref, not a direct expansion here
  local -A paths=()
  paths['flake.nix']=1
  paths['flake.lock']=1
  local m dir ref rel refs status
  for m in "${__asp_assigners[@]}"; do
    paths["${m}"]=1
    dir="$(dirname -- "${m}")"
    status=0
    refs="$(grep --only-matching --extended-regexp \
      '\.\.?/[A-Za-z0-9._/-]+' <<<"${nix_src["${m}"]}")" || status=$?
    # A module with no relative references is ordinary and grep reports it
    # as status 1, so only a higher status is a scan that broke rather than
    # one that found nothing. No fixture drives this branch: grep reads a
    # here-string built from memory against a literal pattern, so it has no
    # I/O or compile error left to hit.
    if ((status > 1)); then
      printf 'freshness-hook-watches-modules: path-reference scan of %s failed\n' \
        "${m}" >&2
      return 1
    fi
    while IFS= read -r ref; do
      [[ -z ${ref} ]] && continue
      rel="$(realpath --relative-to="${ROOT}" --canonicalize-missing \
        -- "${ROOT}/${dir}/${ref}")"
      if [[ -f ${ROOT}/${rel} ]]; then
        # shellcheck disable=SC2034 # read via sorted_keys_into's nameref, not a direct expansion here
        paths["${rel}"]=1
      fi
    done <<<"${refs}"
  done
  sorted_keys_into "${out_name}" paths
}

# Report every path in the derived set named `$4` that the hook's `files`
# value `$2` fails to match, naming the hook `$1` and what makes the path
# required (`$3`). Increments the shared failure count.
function assert_filter_covers() {
  local -r name="$1"
  local -r files="$2"
  local -r subject="$3"
  local -n __afc_derived="$4"
  # Nix string literal: "\\." in source is the ERE "\.".
  local ere p
  ere="$(printf '%s' "${files}" | sed 's/\\\\/\\/g')"
  for p in "${__afc_derived[@]}"; do
    if ! printf '%s\n' "${p}" | grep --quiet --extended-regexp -- "${ere}"; then
      printf 'hook %s: files filter does not cover %s (%s)\n' \
        "${name}" "${p}" "${subject}" >&2
      failed=$((failed + 1))
    fi
  done
}

# Step 3 — assert each subject hook covers the source set it depends on.
failed=0
total_blocks=0
generator_hooks=0
attribute_hooks=0
attr_reference_blocks=0
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

while IFS=$'\037' read -r name files scripts attr_ns attr_leaf attr_seen; do
  [[ -n ${name} ]] || continue
  total_blocks=$((total_blocks + 1))

  if [[ ${attr_seen} == '1' ]]; then
    attr_reference_blocks=$((attr_reference_blocks + 1))
  fi

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

  # A block is a subject of either class, or of neither. The two are
  # checked independently rather than as an either/or, so a hook that both
  # runs a generator and builds an attribute answers for both source sets.
  [[ -n ${attr} || -n ${attr_leaf} ]] || continue

  assigners=()
  if [[ -n ${attr} ]]; then
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
  fi

  if [[ -n ${attr_leaf} ]]; then
    attribute_hooks=$((attribute_hooks + 1))

    # The assigner list is threaded through as an array, not printed and
    # recaptured through a command substitution: an empty or
    # every-element-unmatched result is a meaningful answer here (not a
    # scan that gave up), and `attr_assigners` always returns 0, so there
    # is no producer status left to lose by calling it directly.
    attr_assigners assigners "${attr_ns}" "${attr_leaf}"

    # Guard-the-guard: a hook builds an attribute something must assign, so
    # zero assigning modules means the assignment-shape match stopped
    # matching rather than that the attribute has no nix source. Left
    # unguarded the required set would shrink to the two flake files, which
    # every plausible filter already covers.
    if ((${#assigners[@]} == 0)); then
      printf 'hook %s: no nix module assigns %s.%s — assigner scan broke\n' \
        "${name}" "${attr_ns}" "${attr_leaf}" >&2
      failed=$((failed + 1))
    fi
  fi

  # An empty filter would become an empty ERE, which matches every path and
  # would report full coverage for a hook that watches nothing.
  if [[ -z ${files} ]]; then
    printf 'hook %s: empty files filter — nothing re-triggers it\n' "${name}" >&2
    failed=$((failed + 1))
    continue
  fi

  if [[ -n ${attr} ]]; then
    # Fill the derived set as an array and check the producer's status
    # before consuming it: a derivation that gives up part way emits
    # nothing, and an empty set reads as a hook whose filter already covers
    # every module it must. No fixture drives this guard, because every
    # producer inside `required_modules` reads memory rather than the tree
    # — each module's source is read and status-checked up front — so the
    # only status it can return is the one its own inner guard raises (or a
    # `mktemp` failure inside the NUL-sort helper).
    # shellcheck disable=SC2034 # written by required_modules' nameref, read via assert_filter_covers' nameref, not a direct expansion here
    required=()
    if ! required_modules required "${attr}"; then
      printf 'freshness-hook-watches-modules: required-module derivation for %s failed\n' \
        "${attr}" >&2
      exit 2
    fi
    assert_filter_covers "${name}" "${files}" "evaluates ${attr}" required
  fi

  if [[ -n ${attr_leaf} ]]; then
    # Same capture-then-check shape: the source set for a directly-built
    # attribute is never legitimately empty, so a producer that gave up
    # would otherwise report full coverage.
    # shellcheck disable=SC2034 # written by attr_source_paths' nameref, read via assert_filter_covers' nameref, not a direct expansion here
    required=()
    if ! attr_source_paths required assigners; then
      printf 'freshness-hook-watches-modules: source derivation for %s.%s failed\n' \
        "${attr_ns}" "${attr_leaf}" >&2
      exit 2
    fi
    assert_filter_covers "${name}" "${files}" \
      "builds ${attr_ns}.${attr_leaf}" required
  fi
done <<<"${blocks}"

shopt -u nullglob

# Guard-the-guard: zero generator-running hook blocks means the block
# parser broke (a reformat changed the block shape).
if ((generator_hooks == 0)); then
  printf 'no devTooling-evaluating hook blocks found in %s/nix/hooks — block parser likely broke\n' \
    "${ROOT}" >&2
  exit 1
fi

# Guard-the-guard: a block whose entry names a flake attribute must yield an
# attribute subject. Conditional on a block actually naming one, because a
# tree with no such hook is legitimate and a flat "at least one must exist"
# rule would make every fixture grow one. The loose reference flag and the
# precise attrpath extraction come from the same parse, so the two
# disagreeing is exactly the reformat that would otherwise drop the subject
# and report coverage for a filter nothing checked.
if ((attr_reference_blocks > 0 && attribute_hooks == 0)); then
  printf 'no attribute subject derived from a hook entry naming one in %s/nix/hooks — attrpath parser likely broke\n' \
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

# A clean run is otherwise silent about how much it checked, which reads
# identically whether it verified a generator-running hook, an
# attribute-building one, or nothing at all. State the breadth covered:
# hook blocks parsed (and how many were generator-running vs.
# attribute-building subjects), and nix modules scanned to resolve them.
printf 'freshness-hook-watches-modules: ok — %d hook block(s) scanned (%d generator-running, %d attribute-building), %d nix module(s) scanned\n' \
  "${total_blocks}" "${generator_hooks}" "${attribute_hooks}" "${#nix_modules[@]}"
exit 0
