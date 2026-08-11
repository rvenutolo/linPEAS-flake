#!/usr/bin/env bash
# scripts/check-manifest-hook-watches-nix.sh
#
# @description Lint: every pre-commit hook that reaches the flake hook
# manifest — by running a manifest-reading script, or by building a flake
# attribute a manifest-reading module assigns — includes `nix/hooks` in
# its `files` regex.

# Lint: a freshness/cross-check hook that regenerates or validates a
# doc by reading the Nix pre-commit hook manifest must watch
# `nix/hooks/**` in its pre-commit `files` filter. Otherwise a commit
# that edits only a hook definition under `nix/hooks/*.nix` changes the
# manifest yet never triggers the freshness hook on the per-changed-file
# `git commit` path, so a stale generated doc can slip through locally.
#
# Two hook shapes reach the manifest, and both are subjects here.
#
# A hook whose entry runs a `scripts/*.sh` whose body references the
# manifest (the `preCommitHooks` flake output or the
# `PRECOMMIT_HOOK_NAMES` env var). That script set is derived, not
# hardcoded.
#
# A hook whose entry builds a flake attribute directly (`nix build
# ".#<ns>.${system}.<leaf>"`) carries no script token at all, so the
# script-keyed lookup skips it and its filter may omit `nix/hooks` while
# the manifest still decides what it builds. Such a hook reaches the
# manifest when a nix module that *assigns* the attribute references one
# of the manifest tokens. Assignment shape rather than a bare mention of
# the leaf: the hook block names the attribute in its own entry, and a
# hook is not a source of the attribute it builds.
#
# Hook blocks are source-parsed from `nix/hooks/*.nix` rather than
# `nix eval`-ed: `files` and `entry` are literal in source, and `nix eval`
# is the known local-commit-path long-pole — no reason to add another
# eval-bound hook.
#
# Guard-the-guard: if the parser finds no subject hook block of either
# class, it fails loud — we know at least one such hook exists, so an
# empty result means a reformat broke the block parser. A block whose
# entry names a flake attribute yet yields no attribute subject fails the
# same way, conditional on such a block existing so that a tree carrying
# no attribute-evaluating hook stays legitimate.
#
# Honors HOOKS_DIR_OVERRIDE + SCRIPTS_DIR_OVERRIDE for fixtures
# (default `nix/hooks`, `scripts`). Exits 0 on full coverage, 1 on drift,
# 2 when a producer the derivation depends on could not run.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_HOOKS_DIR="nix/hooks"
readonly DEFAULT_SCRIPTS_DIR="scripts"
readonly HOOKS_DIR="${HOOKS_DIR_OVERRIDE:-${DEFAULT_HOOKS_DIR}}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${DEFAULT_SCRIPTS_DIR}}"

shopt -s nullglob

# The tree the nix modules of an attribute-evaluating hook are searched
# in. The script dir sits directly under the tree it belongs to — in the
# repo and in every fixture tree the harness builds — so its parent is
# that tree's root, and rooting the scan there needs no third override.
module_root="$(dirname -- "${SCRIPTS_DIR}")"
readonly MODULE_ROOT="${module_root}"

# Every tracked-shaped nix module under MODULE_ROOT. Test fixtures are
# excluded: they contain deliberately malformed modules that would pollute
# the derived assigner set.
#
# The scan's status is checked before its output is consumed. A scan that
# never reaches the tree emits nothing, and an empty module list reads
# downstream as "no module assigns the attribute", which scores an
# attribute-evaluating hook as reaching no manifest at all.
if ! module_scan="$(cd "${MODULE_ROOT}" && find . -name '*.nix' \
  -not -path './tests/fixtures/*' -not -path './.git/*' -printf '%P\n' | sort)"; then
  printf 'manifest-hook-watches-nix: nix module scan under %s failed\n' \
    "${MODULE_ROOT}" >&2
  exit 2
fi

nix_modules=()
while IFS= read -r m; do
  [[ -z ${m} ]] && continue
  nix_modules+=("${m}")
done <<<"${module_scan}"

# Every module's comment-stripped source, read once up front and keyed by
# module path. Both attribute-class signals match against this map rather
# than re-reading through a `sed | grep` pipeline, because such a pipeline
# cannot report a read failure: under `pipefail` a failed `sed` alongside a
# `grep` that found nothing returns grep's 1, so a module the stripper
# could not read scores exactly like a module that does not mention the
# token. A path matching `*.nix` that is a directory or a dangling symlink
# is precisely that case.
#
# Comments are stripped because a module that only names the attribute or a
# manifest token in prose is not a source of either. A `#` inside a string
# over-strips the rest of that line, which can only shrink the derived set;
# the read guard is what catches a stripper that breaks outright.
declare -A nix_src=()
for m in "${nix_modules[@]}"; do
  if ! nix_src["${m}"]="$(sed 's/#.*$//' -- "${MODULE_ROOT}/${m}")"; then
    printf 'manifest-hook-watches-nix: comment-strip of %s failed — module unreadable\n' \
      "${m}" >&2
    exit 2
  fi
done

# Step 1 — derive the set of manifest-reading script basenames: any
# scripts/*.sh whose body references the flake hook manifest.
declare -A manifest_scripts=()
for f in "${SCRIPTS_DIR}"/*.sh; do
  [[ -f ${f} ]] || continue
  if grep --quiet --extended-regexp 'preCommitHooks|PRECOMMIT_HOOK_NAMES' -- "${f}"; then
    manifest_scripts["$(basename "${f}")"]=1
  fi
done

# Step 2/3 — parse every hook block in HOOKS_DIR. For each block capture
# its name, its `files = "...";` string, every scripts/<name>.sh token
# referenced anywhere in the block (the entry), and the flake attribute
# the entry names. Emit one record per block, fields separated by an ASCII
# unit separator (octal \037):
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
# A literal tab is unsafe as the field separator: a block whose `files`
# value is the empty string puts two delimiters back to back, and bash's
# `read` treats tab as IFS whitespace, collapsing adjacent delimiters. The
# script list would slide into the `files` field, the block would look
# like it references no manifest script, and it would be dropped from the
# coverage check with no output. \037 carries no such special casing and
# never appears in a `files` regex or a `scripts/*.sh` path.
#
# An `awk` fault is returned explicitly rather than left to errexit: the
# caller captures this function in a command substitution inside an `if`
# condition, and errexit is suppressed there, so a bare non-zero `awk`
# would leave the function returning 0 with a short block list.
parse_blocks() {
  local nix
  for nix in "${HOOKS_DIR}"/*.nix; do
    [[ -f ${nix} ]] || continue
    awk '
      # Block opens on the treefmt-stable 2-space shape: "  name = {"
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
      # Block closes on "  };"
      in_block && /^  \};/ {
        printf "%s\037%s\037%s\037%s\037%s\037%s\n", \
          name, files, scripts, attr_ns, attr_leaf, attr_seen
        in_block = 0
        next
      }
      in_block {
        # Capture the files filter string value.
        if (match($0, /files = "[^"]*"/)) {
          s = substr($0, RSTART, RLENGTH)
          sub(/^files = "/, "", s)
          sub(/"$/, "", s)
          files = s
        }
        # Capture the flake attrpath the entry names, and separately the
        # looser evidence that it names one at all.
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
        # Capture every scripts/<name>.sh token in the block.
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

# Every nix module that assigns the flake attribute `$1.$2` in non-comment
# source, one per line. Matched on the assignment shape rather than on a
# bare mention of the leaf: the hook block that evaluates the attribute
# names it in its own entry, and a hook is not a source of the attribute
# it builds.
function attr_assigners() {
  local -r ns="$1"
  local -r leaf="$2"
  local f
  for f in "${nix_modules[@]}"; do
    if grep --quiet --extended-regexp -- "${ns}\.${leaf}[[:space:]]*=" \
      <<<"${nix_src["${f}"]}"; then
      printf '%s\n' "${f}"
    fi
  done
}

# The first module in the newline-separated assigner list `$1` that
# references the flake hook manifest in non-comment source, or nothing.
# One such module is enough: it makes a manifest edit change what the
# attribute builds, which is exactly what the `nix/hooks` filter entry has
# to re-trigger on.
function manifest_reading_assigner() {
  local -r assigners="$1"
  local f
  while IFS= read -r f; do
    [[ -z ${f} ]] && continue
    if grep --quiet --extended-regexp 'preCommitHooks|PRECOMMIT_HOOK_NAMES' \
      <<<"${nix_src["${f}"]}"; then
      printf '%s' "${f}"
      return 0
    fi
  done <<<"${assigners}"
}

# Does a hook's `files` regex re-trigger it on a hook-definition edit?
# Asked by matching a representative `nix/hooks` path against the regex
# rather than by looking for that text inside it: a filter can cover the
# directory without naming it (`^(.*\.nix|scripts/.*\.sh)$`), and can name
# it while never matching it (`^docs/nix/hooks-notes\.md$`). An empty
# filter is an empty ERE, which matches every path, so it is rejected up
# front rather than being read as total coverage.
function filter_covers_hooks_dir() {
  local -r filter="$1"
  [[ -n ${filter} ]] || return 1
  # Nix string literal: "\\." in source is the ERE "\.".
  local ere
  ere="$(printf '%s' "${filter}" | sed 's/\\\\/\\/g')"
  printf '%s\n' "${DEFAULT_HOOKS_DIR}/example.nix" |
    grep --quiet --extended-regexp -- "${ere}"
}

failed=0
subject_blocks=0
attribute_blocks=0
attr_reference_blocks=0

# Capture the parser's records and check its status before consuming them:
# a producer whose exit status the loop never sees turns a broken parse
# into a smaller hook set, which reads as coverage rather than as a fault.
# No fixture drives this guard, because nothing the script can be handed
# makes the parser fail: only a regular file reaches `awk` (the `-f` test
# drops directories, dangling symlinks, and fifos named `*.nix`), and this
# awk program does no I/O of its own, so a readable regular file always
# parses. The guard exists so a future producer change cannot fail silently.
if ! blocks="$(parse_blocks)"; then
  printf 'manifest-hook-watches-nix: parse_blocks failed\n' >&2
  exit 2
fi

while IFS=$'\037' read -r name files scripts attr_ns attr_leaf attr_seen; do
  [[ -n ${name} ]] || continue

  if [[ ${attr_seen} == '1' ]]; then
    attr_reference_blocks=$((attr_reference_blocks + 1))
  fi

  # Does this block reference any manifest-reading script?
  references_manifest=0
  # Split on spaces explicitly: the global IFS is newline+tab, so a block
  # naming its script more than once (the house shape is a `[[ ! -f
  # scripts/foo.sh ]]` guard plus an `exec ... scripts/foo.sh` call) would
  # otherwise stay one unsplittable word, the manifest_scripts lookup
  # would miss it, and the hook would be skipped with no output.
  IFS=' ' read -r -a script_list <<<"${scripts}"
  for s in "${script_list[@]}"; do
    if [[ -n ${manifest_scripts["${s}"]:-} ]]; then
      references_manifest=1
      break
    fi
  done
  # Does this block build a flake attribute a manifest-reading module
  # assigns?
  manifest_assigner=''
  if [[ -n ${attr_leaf} ]]; then
    attribute_blocks=$((attribute_blocks + 1))

    # Capture the assigner scan and check its status before consuming it,
    # for the same reason the block parser is captured: an empty list is a
    # meaningful answer here, so a scan that gave up would read as one.
    if ! assigners="$(attr_assigners "${attr_ns}" "${attr_leaf}")"; then
      printf 'manifest-hook-watches-nix: assigner scan for %s.%s failed\n' \
        "${attr_ns}" "${attr_leaf}" >&2
      exit 2
    fi
    if ! manifest_assigner="$(manifest_reading_assigner "${assigners}")"; then
      printf 'manifest-hook-watches-nix: manifest-token scan of the modules assigning %s.%s failed\n' \
        "${attr_ns}" "${attr_leaf}" >&2
      exit 2
    fi
  fi

  # A block is a subject of either class, or of neither. The two are
  # checked independently rather than as an either/or, so a hook that both
  # runs a manifest-reading script and builds a manifest-derived attribute
  # is reported once per reason it must watch `nix/hooks`.
  if ((references_manifest)) || [[ -n ${attr_leaf} ]]; then
    subject_blocks=$((subject_blocks + 1))
  fi

  covers_hooks_dir=1
  filter_covers_hooks_dir "${files}" || covers_hooks_dir=0

  if ((references_manifest)) && ((!covers_hooks_dir)); then
    printf 'hook %s: files filter missing nix/hooks\n' "${name}" >&2
    failed=$((failed + 1))
  fi

  if [[ -n ${manifest_assigner} ]] && ((!covers_hooks_dir)); then
    printf 'hook %s: files filter missing nix/hooks (builds %s.%s, assigned by %s which reads the hook manifest)\n' \
      "${name}" "${attr_ns}" "${attr_leaf}" "${manifest_assigner}" >&2
    failed=$((failed + 1))
  fi
done <<<"${blocks}"

shopt -u nullglob

# Step 4 — guard-the-guard: zero subject hook blocks of either class means
# the block parser broke (a reformat changed the block shape); fail loud.
# Counting both classes keeps a tree whose only subject builds an attribute
# from tripping this, without demanding that every tree grow one.
if ((subject_blocks == 0)); then
  printf 'no manifest-reading or attribute-building hook blocks found in %s — block parser likely broke\n' \
    "${HOOKS_DIR}" >&2
  exit 1
fi

# Guard-the-guard: a block whose entry names a flake attribute must yield an
# attribute subject. Conditional on a block actually naming one, because a
# tree with no such hook is legitimate and a flat "at least one must exist"
# rule would make every fixture grow one. The loose reference flag and the
# precise attrpath extraction come from the same parse, so the two
# disagreeing is exactly the reformat that would otherwise drop the subject
# and report coverage for a filter nothing checked.
if ((attr_reference_blocks > 0 && attribute_blocks == 0)); then
  printf 'no attribute subject derived from a hook entry naming one in %s — attrpath parser likely broke\n' \
    "${HOOKS_DIR}" >&2
  exit 1
fi

if ((failed > 0)); then
  printf '%d manifest-reaching hook(s) missing nix/hooks in files filter\n' "${failed}" >&2
  exit 1
fi
exit 0
