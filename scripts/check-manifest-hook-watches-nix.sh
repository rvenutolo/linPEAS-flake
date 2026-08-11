#!/usr/bin/env bash
# scripts/check-manifest-hook-watches-nix.sh
#
# @description Lint: every pre-commit hook whose entry runs a
# manifest-reading script (one referencing the flake hook manifest)
# includes `nix/hooks` in its `files` regex.

# Lint: a freshness/cross-check hook that regenerates or validates a
# doc by reading the Nix pre-commit hook manifest must watch
# `nix/hooks/**` in its pre-commit `files` filter. Otherwise a commit
# that edits only a hook definition under `nix/hooks/*.nix` changes the
# manifest yet never triggers the freshness hook on the per-changed-file
# `git commit` path, so a stale generated doc can slip through locally.
#
# The set of manifest-reading scripts is derived, not hardcoded: any
# `scripts/*.sh` whose body references the manifest (the `preCommitHooks`
# flake output or the `PRECOMMIT_HOOK_NAMES` env var). Hook blocks are
# source-parsed from `nix/hooks/*.nix` rather than `nix eval`-ed:
# `files` and `entry` are literal in source, and `nix eval` is the known
# local-commit-path long-pole — no reason to add another eval-bound hook.
#
# Guard-the-guard: if the parser finds zero hook blocks referencing a
# manifest script, it fails loud — we know at least one such hook exists,
# so an empty result means a reformat broke the block parser.
#
# Honors HOOKS_DIR_OVERRIDE + SCRIPTS_DIR_OVERRIDE for fixtures
# (default `nix/hooks`, `scripts`). Exits 0 on full coverage, 1 on drift,
# 2 if the hook-block parser could not run.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_HOOKS_DIR="nix/hooks"
readonly DEFAULT_SCRIPTS_DIR="scripts"
readonly HOOKS_DIR="${HOOKS_DIR_OVERRIDE:-${DEFAULT_HOOKS_DIR}}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${DEFAULT_SCRIPTS_DIR}}"

shopt -s nullglob

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
# its name, its `files = "...";` string, and every scripts/<name>.sh
# token referenced anywhere in the block (the entry). Emit one record per
# block, fields separated by an ASCII unit separator (octal \037):
#   <name>\037<files-string>\037<space-separated script basenames>
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
        next
      }
      # Block closes on "  };"
      in_block && /^  \};/ {
        printf "%s\037%s\037%s\n", name, files, scripts
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

failed=0
manifest_hook_blocks=0

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

while IFS=$'\037' read -r name files scripts; do
  [[ -n ${name} ]] || continue
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
  ((references_manifest)) || continue

  manifest_hook_blocks=$((manifest_hook_blocks + 1))

  if [[ ${files} != *"nix/hooks"* ]]; then
    printf 'hook %s: files filter missing nix/hooks\n' "${name}" >&2
    failed=$((failed + 1))
  fi
done <<<"${blocks}"

shopt -u nullglob

# Step 4 — guard-the-guard: zero manifest-reading hook blocks means the
# block parser broke (a reformat changed the block shape); fail loud.
if ((manifest_hook_blocks == 0)); then
  printf 'no manifest-reading hook blocks found in %s — block parser likely broke\n' \
    "${HOOKS_DIR}" >&2
  exit 1
fi

if ((failed > 0)); then
  printf '%d manifest-reading hook(s) missing nix/hooks in files filter\n' "${failed}" >&2
  exit 1
fi
exit 0
