#!/usr/bin/env bash
# scripts/refresh-test-harnesses.sh
#
# @description Regenerate docs/reference/test-harnesses.md, the census of
# every tests/*.test.sh harness: the file or file set it exercises and the
# directories under tests/fixtures/ it reads. A harness names its subject
# either by a SCRIPT= assignment pointing into scripts/ or by a
# `# @subject` header annotation, and never by both, so the census can
# neither render an unknown subject nor silently follow the stale one of
# two disagreeing declarations. A fixture directory no harness names is
# refused as well: a census that omitted it would describe a smaller tree
# than the one on disk.
# @generates docs/reference/test-harnesses.md
# @option --check exit 1 if drift; exit 2 if the doc is missing, a harness
# declares no subject or two, or a fixture directory is named by no
# harness; do not mutate the working tree

# Env overrides (test-only):
#   TESTS_DIR_OVERRIDE — alternate tests/ scan root (for fixture tests)
#   DOC_OVERRIDE — alternate output path (for fixture tests)

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
install_err_trap

# Temp files removed by the EXIT trap. Declared at script scope, not
# main-local: the EXIT trap fires after main() returns and its locals leave
# scope, so a main-local would read as empty at trap time and the in-repo
# .md temp would leak on an abnormal exit.
repo_root=''
doc_new=''
check_bucket=''
lib_bucket=''
refresh_bucket=''
other_bucket=''
fmt_target=''

# Set by parse_harness for the harness it just read.
parse_assignment=''
parse_annotation=''
parse_fixtures=''

function cleanup() {
  rm --force -- "${doc_new}" "${check_bucket}" "${lib_bucket}" \
    "${refresh_bucket}" "${other_bucket}" "${fmt_target}"
  if [[ -n ${repo_root} ]]; then
    local stray
    shopt -s nullglob
    # glob-exempt: a leftover in-repo temp file is normally absent, so an empty match is this loop's expected state
    for stray in "${repo_root}"/.refresh-test-harnesses-*.md; do
      rm --force -- "${stray}"
    done
  fi
}

# @description Read one harness and report every declaration it carries.
# Results land in `parse_assignment`, `parse_annotation` and
# `parse_fixtures` (newline-terminated fixture directory names, unsorted
# and possibly repeated) rather than on stdout, because a command
# substitution would fork a subshell and three separate parses of a
# hundred files is three times the work for one file's worth of answer.
#
# Annotations count only inside the header comment block — the run of
# comment and blank lines before the first line that is neither — the same
# boundary the `@generates` convention uses. An annotation sitting beside
# the code is prose about a path, not a declaration about the file.
#
# The `@fixtures` line is excluded from the path-literal sweep that
# follows it. The annotation exists for a directory reached only by
# pointing an override at it, so letting the sweep read the annotation's
# own text would make the annotation rule redundant with the literal rule
# and leave it dead. Keeping the two sources disjoint also means a
# mistyped annotation renders nothing and leaves the directory it meant to
# name unreferenced, which the orphan check then reports.
# @arg $1 harness path
function parse_harness() {
  local -r file="$1"
  parse_assignment=''
  parse_annotation=''
  parse_fixtures=''

  local line rest name
  local in_header=1
  # `|| [[ -n ... ]]` keeps a final line with no trailing newline, which
  # read reports as a failure even after populating the variable.
  while IFS= read -r line || [[ -n ${line} ]]; do
    if ((in_header == 1)) &&
      [[ ! ${line} =~ ^[[:space:]]*$ ]] && [[ ${line} != '#'* ]]; then
      in_header=0
    fi
    if ((in_header == 1)); then
      if [[ ${line} =~ ^#[[:space:]]+@subject[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
        if [[ -z ${parse_annotation} ]]; then
          parse_annotation="${BASH_REMATCH[1]}"
        fi
        continue
      fi
      # The annotation must spell the full `tests/fixtures/<name>` path so
      # the census renders exactly what it read. A value in any other
      # shape is not recognized here, which leaves the directory it meant
      # to name unreferenced rather than rendering a path that resolves to
      # nothing.
      if [[ ${line} =~ ^#[[:space:]]+@fixtures[[:space:]]+tests/fixtures/([A-Za-z0-9_][A-Za-z0-9._-]*)[[:space:]]*$ ]]; then
        parse_fixtures+="${BASH_REMATCH[1]}"$'\n'
        continue
      fi
    fi
    # Only the first assignment counts, and only one naming a scripts/
    # path: a harness whose subject is not a script keeps `SCRIPT` free
    # for its own use, and the both-declared error then fires on a real
    # collision rather than on a variable name.
    if [[ -z ${parse_assignment} ]] &&
      [[ ${line} =~ ^(readonly[[:space:]]+)?SCRIPT=\"\$\{(REPO_ROOT|repo_root)\}/(scripts/[^\"]+)\" ]]; then
      parse_assignment="${BASH_REMATCH[3]}"
    fi
    # A leading dot is excluded so `tests/fixtures/.` — which `[[ -d ]]`
    # would accept — and an elided path written `tests/fixtures/...` in
    # prose are not read as directory names.
    rest="${line}"
    while [[ ${rest} =~ tests/fixtures/([A-Za-z0-9_][A-Za-z0-9._-]*) ]]; do
      name="${BASH_REMATCH[1]}"
      parse_fixtures+="${name}"$'\n'
      rest="${rest#*"tests/fixtures/${name}"}"
    done
  done <"${file}"
}

# @description Emit one section's heading and table header. The caller
# appends the rows and the trailing blank line, because a read whose path
# arrives as a parameter cannot be traced back to the `make_temp` that
# created it — the payload-read gate reads such a `cat` as a hand-rolled
# read of an outside file. Keeping the read in `main`, beside the
# assignment, is what makes the scratch file visibly this script's own.
# @arg $1 section heading
function emit_section_header() {
  local -r heading="$1"
  printf '## %s\n\n' "${heading}"
  printf '| Harness | Subject | Fixtures |\n'
  printf '| --- | --- | --- |\n'
}

function main() {
  local check_only='false'
  if [[ ${1:-} == '--check' ]]; then
    check_only='true'
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  readonly check_only

  require_tool git
  require_tool sort
  require_tool cmp
  # treefmt is invoked on the rendered doc so the generated file matches
  # what the formatter (mdformat-gfm) emits at commit time; without it the
  # commit-time formatter would rewrite the doc into drift.
  require_tool treefmt

  local tests_dir doc fixtures_root
  repo_root="$(git rev-parse --show-toplevel)"
  readonly repo_root
  tests_dir="${TESTS_DIR_OVERRIDE:-${repo_root}/tests}"
  doc="${DOC_OVERRIDE:-${repo_root}/docs/reference/test-harnesses.md}"
  fixtures_root="${tests_dir}/fixtures"
  readonly tests_dir doc fixtures_root

  # An absent doc is a could-not-run, not drift: exit 1 would send the
  # operator to regenerate-and-commit a file that was never there.
  if [[ ${check_only} == 'true' && ! -f ${doc} ]]; then
    log_err "${doc} not found; run without --check to bootstrap"
    exit 2
  fi

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  doc_new="$(make_temp)"
  check_bucket="$(make_temp)"
  lib_bucket="$(make_temp)"
  refresh_bucket="$(make_temp)"
  other_bucket="$(make_temp)"

  local -a harness_paths=()
  glob_into harness_paths 'test harnesses' "${tests_dir}/*.test.sh"

  # Sort by basename so the census order does not depend on where the scan
  # root lives. The sort's status is checked rather than piped into
  # `mapfile` through a process substitution, whose subshell would hide a
  # failed sort behind an empty list and render a census missing rows.
  # `LC_ALL=C` makes the order byte-deterministic: a dev locale such as
  # en_US.UTF-8 ignores the leading underscore of `_script_docs.test.sh`
  # at the primary collation level and files it among the `s` names, while
  # a C-locale CI runner sorts it ahead of every letter — the same tree
  # rendering two different documents, and --check red on one of them.
  local -a basenames=()
  local path
  for path in "${harness_paths[@]}"; do
    basenames+=("${path##*/}")
  done
  local sorted_out
  if ! sorted_out="$(printf '%s\n' "${basenames[@]}" | LC_ALL=C sort)"; then
    log_err "could not sort the harness list under ${tests_dir}"
    exit 2
  fi
  local -a names=()
  mapfile -t names <<<"${sorted_out}"

  local -A referenced=()
  local -i assignment_count=0 annotation_count=0 with_fixtures=0
  local name rel subject bucket cell fixture_list fixture_name
  local -a fixture_names=()

  for name in "${names[@]}"; do
    rel="tests/${name}"
    parse_harness "${tests_dir}/${name}"

    if [[ -n ${parse_assignment} && -n ${parse_annotation} ]]; then
      log_err "${rel} declares a subject twice: the SCRIPT= assignment names ${parse_assignment} and the # @subject annotation names ${parse_annotation} — a harness declares exactly one"
      exit 2
    fi
    if [[ -z ${parse_assignment} && -z ${parse_annotation} ]]; then
      log_err "${rel} declares no subject: give it a SCRIPT= assignment naming a scripts/ path, or a # @subject header annotation naming the file or file set it exercises"
      exit 2
    fi
    if [[ -n ${parse_assignment} ]]; then
      subject="${parse_assignment}"
      assignment_count=$((assignment_count + 1))
    else
      subject="${parse_annotation}"
      annotation_count=$((annotation_count + 1))
    fi

    # Both sources feed one set, sorted and de-duplicated, and every name
    # is held to existing as a directory under the scan root's fixtures/.
    # A name that resolves to nothing is dropped rather than rendered, so
    # the census never points at a directory that is not there — and the
    # orphan check below still reports whatever real directory the dropped
    # name was meant to reach.
    fixture_names=()
    if [[ -n ${parse_fixtures} ]]; then
      if ! fixture_list="$(printf '%s' "${parse_fixtures}" | LC_ALL=C sort --unique)"; then
        log_err "could not sort the fixture references in ${rel}"
        exit 2
      fi
      mapfile -t fixture_names <<<"${fixture_list}"
    fi
    cell='—'
    local -a kept=()
    for fixture_name in ${fixture_names+"${fixture_names[@]}"}; do
      [[ -n ${fixture_name} ]] || continue
      [[ -d "${fixtures_root}/${fixture_name}" ]] || continue
      kept+=("${fixture_name}")
      referenced["${fixture_name}"]=1
    done
    if ((${#kept[@]} > 0)); then
      with_fixtures=$((with_fixtures + 1))
      cell=''
      for fixture_name in "${kept[@]}"; do
        cell+="${cell:+, }"'`'"tests/fixtures/${fixture_name}"'`'
      done
    fi

    case "${name}" in
    check-*) bucket="${check_bucket}" ;;
    lib-*) bucket="${lib_bucket}" ;;
    refresh-*) bucket="${refresh_bucket}" ;;
    *) bucket="${other_bucket}" ;;
    esac
    # shellcheck disable=SC2016 # literal backticks in markdown output
    printf '| `%s` | `%s` | %s |\n' "${rel}" "${subject}" "${cell}" >>"${bucket}"
  done

  # A fixture directory nothing names is either a harness that lost its
  # reference or a tree nothing reads any more. Both are states the census
  # cannot describe, so refuse rather than render a doc that accounts for
  # less than the repo holds.
  local -a fixture_dirs=()
  shopt -s nullglob
  fixture_dirs=("${fixtures_root}"/*/)
  shopt -u nullglob
  local fixture_dir orphan_name
  for fixture_dir in ${fixture_dirs+"${fixture_dirs[@]}"}; do
    orphan_name="${fixture_dir%/}"
    orphan_name="${orphan_name##*/}"
    if [[ -z ${referenced[${orphan_name}]:-} ]]; then
      log_err "tests/fixtures/${orphan_name} is named by no harness: reference it from the harness that reads it, or declare it with a # @fixtures tests/fixtures/${orphan_name} header annotation when only an override reaches it"
      exit 2
    fi
  done

  # The preamble is a quoted here-doc: it is markdown prose carrying
  # backticks and asterisks, and nothing in it is meant to expand.
  {
    cat <<'MARKDOWN'
# Test harnesses

<!-- Generated by scripts/refresh-test-harnesses.sh — do not hand-edit. -->

Every `tests/*.test.sh` harness in the repo. **Subject** is the file or
file set the harness exercises, taken from the harness's `SCRIPT`
assignment or its `# @subject` annotation. **Fixtures** lists the
directories under `tests/fixtures/` the harness reads; an em dash means
the harness builds its tree at runtime rather than reading a committed
fixture.

Regenerate with `scripts/refresh-test-harnesses.sh`.

MARKDOWN
    # A section with no members is omitted outright: an empty table would
    # claim the repo has a class of harness it does not have.
    if [[ -s ${check_bucket} ]]; then
      emit_section_header 'Check harnesses'
      cat -- "${check_bucket}"
      printf '\n'
    fi
    if [[ -s ${lib_bucket} ]]; then
      emit_section_header 'Library harnesses'
      cat -- "${lib_bucket}"
      printf '\n'
    fi
    if [[ -s ${refresh_bucket} ]]; then
      emit_section_header 'Refresh harnesses'
      cat -- "${refresh_bucket}"
      printf '\n'
    fi
    if [[ -s ${other_bucket} ]]; then
      emit_section_header 'Other harnesses'
      cat -- "${other_bucket}"
      printf '\n'
    fi
  } >"${doc_new}"

  # Run treefmt over the rendered doc so the comparison target matches what
  # the formatter chain (mdformat-gfm) produces on commit. treefmt needs
  # flake.nix as its project root, so the temp must live in-repo.
  fmt_target="$(make_temp "${repo_root}/.refresh-test-harnesses-XXXXXX.md")"
  cp -- "${doc_new}" "${fmt_target}"
  # No `|| true`: a treefmt/mdformat failure must abort under set -e before
  # an unformatted census is moved into place, which would otherwise be
  # written to the tracked file while this script exited 0 "refreshed".
  treefmt --no-cache --quiet -- "${fmt_target}" >/dev/null
  mv -- "${fmt_target}" "${doc_new}"

  local census
  printf -v census \
    'test-harnesses: ok — %d harness(es), %d with a declared subject (%d assignment, %d annotation), %d with fixture directories, %d fixture directory(ies) referenced' \
    "${#names[@]}" "$((assignment_count + annotation_count))" \
    "${assignment_count}" "${annotation_count}" \
    "${with_fixtures}" "${#referenced[@]}"

  if [[ ${check_only} == 'true' ]]; then
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err "${doc} drift — run scripts/refresh-test-harnesses.sh and commit"
      exit 1
    fi
    printf '%s\n' "${census}"
    log_info "${doc} is up to date"
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  printf '%s\n' "${census}"
  log_info "refreshed ${doc}"
}

main "$@"
