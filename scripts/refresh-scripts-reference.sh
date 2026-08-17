#!/usr/bin/env bash
# scripts/refresh-scripts-reference.sh
#
# @description Regenerate the scripts-reference managed block in
# docs/reference/scripts.md from in-script shdoc-style annotations
# parsed by scripts/_script_docs.awk. Groups entries by basename
# prefix into Check / Refresh / Other sections.
# @generates docs/reference/scripts.md
# @option --check exit 1 if drift; exit 2 if the doc or the awk parser is
# missing; do not mutate the working tree

# Env overrides (test-only):
#   SCRIPTS_DIR_OVERRIDE — alternate scripts/ root (for fixture tests)

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
install_err_trap

# Temp files removed by the EXIT trap. Declared at script scope, not main-local:
# the EXIT trap fires after main() returns and its locals leave scope, so a
# main-local would read as empty at trap time and the in-repo .md temp would
# leak on an abnormal exit.
repo_root=''
block_file=''
doc_new=''
check_bucket=''
refresh_bucket=''
other_bucket=''
fmt_target=''

function cleanup() {
  rm --force -- "${block_file}" "${doc_new}" "${check_bucket}" "${refresh_bucket}" "${other_bucket}" "${fmt_target}"
  if [[ -n ${repo_root} ]]; then
    local stray
    shopt -s nullglob
    # glob-exempt: a leftover in-repo temp file is normally absent, so an empty match is this loop's expected state
    for stray in "${repo_root}"/.refresh-scripts-reference-*.md; do
      rm --force -- "${stray}"
    done
  fi
}

# @description Emit a single script's markdown entry to stdout.
# @arg $1 script basename (e.g. check-foo.sh)
# @arg $2 JSON blob from _script_docs.awk
function emit_entry() {
  local -r name="$1"
  local -r json="$2"
  local description args_len options_len example
  description="$(jq --raw-output '.description' <<<"${json}")"
  args_len="$(jq --raw-output '.args | length' <<<"${json}")"
  options_len="$(jq --raw-output '.options | length' <<<"${json}")"
  example="$(jq --raw-output '.example' <<<"${json}")"

  printf '### scripts/%s\n\n' "${name}"
  printf '%s\n\n' "${description}"

  if [[ ${args_len} -gt 0 ]]; then
    printf '**Args:**\n\n'
    local i arg_name arg_text
    for ((i = 0; i < args_len; i++)); do
      arg_name="$(jq --raw-output ".args[${i}].name" <<<"${json}")"
      arg_text="$(jq --raw-output ".args[${i}].text" <<<"${json}")"
      # shellcheck disable=SC2016 # literal backticks in markdown output
      printf -- '- `%s` — %s\n' "${arg_name}" "${arg_text}"
    done
    printf '\n'
  fi

  if [[ ${options_len} -gt 0 ]]; then
    printf '**Options:**\n\n'
    local i opt_flag opt_text
    for ((i = 0; i < options_len; i++)); do
      opt_flag="$(jq --raw-output ".options[${i}].flag" <<<"${json}")"
      opt_text="$(jq --raw-output ".options[${i}].text" <<<"${json}")"
      # shellcheck disable=SC2016 # literal backticks in markdown output
      printf -- '- `%s` — %s\n' "${opt_flag}" "${opt_text}"
    done
    printf '\n'
  fi

  if [[ -n ${example} ]]; then
    # shellcheck disable=SC2016 # literal backticks in markdown fence
    printf '```bash\n%s\n```\n\n' "${example}"
  fi
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
  require_tool awk
  require_tool jq
  require_tool cmp
  # treefmt is invoked on the rendered doc so the spliced output
  # matches what the formatter (mdformat-gfm) emits at commit time.
  require_tool treefmt

  local scripts_dir doc awk_parser
  repo_root="$(git rev-parse --show-toplevel)"
  readonly repo_root
  scripts_dir="${SCRIPTS_DIR_OVERRIDE:-${repo_root}/scripts}"
  doc="${repo_root}/docs/reference/scripts.md"
  awk_parser="${repo_root}/scripts/_script_docs.awk"
  readonly scripts_dir doc awk_parser

  # An absent input is a could-not-run condition, not drift: exit 2 so the
  # caller sends the operator to the missing file rather than to a
  # regenerate-and-commit that has nothing to read.
  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found; run without --check to bootstrap (after creating the skeleton)"
    exit 2
  fi
  if ! grep --quiet '^<!-- BEGIN scripts-reference -->$' "${doc}"; then
    log_err 'BEGIN marker missing from docs/reference/scripts.md'
    exit 1
  fi
  if ! grep --quiet '^<!-- END scripts-reference -->$' "${doc}"; then
    log_err 'END marker missing from docs/reference/scripts.md'
    exit 1
  fi
  if [[ ! -f ${awk_parser} ]]; then
    log_err "${awk_parser} not found"
    exit 2
  fi

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  block_file="$(make_temp)"
  doc_new="$(make_temp)"
  check_bucket="$(make_temp)"
  refresh_bucket="$(make_temp)"
  other_bucket="$(make_temp)"

  # Walk scripts in sorted order, skipping `_*.sh` helpers. The match set is
  # asserted non-empty rather than iterated as-is: a scripts root that exists
  # and holds nothing would otherwise rewrite the tracked 1300-line reference
  # down to an empty managed block while the run reports success.
  local script name json bucket
  local -a scripts
  glob_into scripts 'scripts directory' "${scripts_dir}/*.sh"
  # Sort by basename for deterministic output. The sort is captured with
  # its status checked rather than piped into `mapfile` through a process
  # substitution, whose subshell would hide a failed sort behind an empty
  # list and regenerate the reference with every script missing from it.
  # `LC_ALL=C` makes the order byte-deterministic: a dev locale such as
  # en_US.UTF-8 ignores the hyphen of `check-pr-workflows-no-secrets.sh` at
  # the primary collation level and files it after `check-protect-main.sh`,
  # while a C-locale CI runner sorts it ahead — the same tree rendering two
  # different documents, and --check red on whichever one is not committed.
  local -a sorted
  local sorted_out
  if ! sorted_out="$(printf '%s\n' "${scripts[@]}" | LC_ALL=C sort)"; then
    log_err "could not sort the script list under ${scripts_dir}"
    exit 2
  fi
  mapfile -t sorted <<<"${sorted_out}"

  for script in "${sorted[@]}"; do
    name="$(basename -- "${script}")"
    if [[ ${name} == _* ]]; then
      continue
    fi
    if ! json="$(awk -f "${awk_parser}" <"${script}" 2>/dev/null)"; then
      log_err "parse failure (missing @description?) in ${script}"
      exit 2
    fi
    case "${name}" in
    check-*) bucket="${check_bucket}" ;;
    refresh-*) bucket="${refresh_bucket}" ;;
    *) bucket="${other_bucket}" ;;
    esac
    emit_entry "${name}" "${json}" >>"${bucket}"
  done

  {
    printf '<!-- BEGIN scripts-reference -->\n'
    # Wrap body in a Jinja raw block so mkdocs-macros does not try to
    # interpret literal `${{ ... }}` expressions copied verbatim from
    # GitHub Actions snippets in script @description text.
    printf '{%% raw %%}\n\n'
    if [[ -s ${check_bucket} ]]; then
      printf '## Check scripts\n\n'
      cat -- "${check_bucket}"
    fi
    if [[ -s ${refresh_bucket} ]]; then
      printf '## Refresh scripts\n\n'
      cat -- "${refresh_bucket}"
    fi
    if [[ -s ${other_bucket} ]]; then
      printf '## Other\n\n'
      cat -- "${other_bucket}"
    fi
    printf '{%% endraw %%}\n'
    printf '<!-- END scripts-reference -->\n'
  } >"${block_file}"

  # Splice into doc between markers (inclusive).
  awk -v rep="${block_file}" '
    /^<!-- BEGIN scripts-reference -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^<!-- END scripts-reference -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "$(awk_path "${doc}")" >"${doc_new}"

  # Run treefmt over the regenerated doc so the comparison target
  # matches what the formatter chain (mdformat-gfm) produces on commit.
  # treefmt needs flake.nix as project root, so the temp must live in-repo.
  fmt_target="$(make_temp "${repo_root}/.refresh-scripts-reference-XXXXXX.md")"
  cp -- "${doc_new}" "${fmt_target}"
  # No `|| true`: a treefmt/mdformat failure must abort under set -e before the
  # unformatted splice is moved into place, matching the sibling generators
  # (refresh-precommit-table / refresh-treefmt-config). Swallowing it wrote an
  # unformatted doc to the tracked file while the script exited 0 "refreshed".
  treefmt --no-cache --quiet -- "${fmt_target}" >/dev/null
  mv -- "${fmt_target}" "${doc_new}"

  if [[ ${check_only} == 'true' ]]; then
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err 'docs/reference/scripts.md drift — run scripts/refresh-scripts-reference.sh and commit'
      exit 1
    fi
    log_info 'docs/reference/scripts.md is up to date'
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  log_info 'refreshed docs/reference/scripts.md'
}

main "$@"
