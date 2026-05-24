#!/usr/bin/env bash
# scripts/refresh-scripts-reference.sh
#
# @description Regenerate the scripts-reference managed block in
# docs/reference/scripts.md from in-script shdoc-style annotations
# parsed by scripts/_script_docs.awk. Groups entries by basename
# prefix into Check / Refresh / Other sections.
# @option --check exit 1 if drift; do not mutate the working tree

# Env overrides (test-only):
#   SCRIPTS_DIR_OVERRIDE — alternate scripts/ root (for fixture tests)

set -Eeuo pipefail
IFS=$'\n\t'
trap 'printf "[%s] %-5s line %s (exit %s): %s\n" \
  "$(date "+%Y-%m-%dT%H:%M:%S%z")" ERROR "${LINENO}" "$?" "${BASH_COMMAND}" >&2' ERR

function log() {
  printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
}
function log_info() { log INFO "$*"; }
function log_err() { log ERROR "$*"; }

# @description Verify a required CLI tool is on PATH; exit 1 if missing.
# @arg $1 tool name
function require_tool() {
  local -r tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log_err "missing required tool: ${tool}"
    exit 1
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

  local repo_root scripts_dir doc awk_parser
  repo_root="$(git rev-parse --show-toplevel)"
  scripts_dir="${SCRIPTS_DIR_OVERRIDE:-${repo_root}/scripts}"
  doc="${repo_root}/docs/reference/scripts.md"
  awk_parser="${repo_root}/scripts/_script_docs.awk"
  readonly repo_root scripts_dir doc awk_parser

  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found; run without --check to bootstrap (after creating the skeleton)"
    exit 1
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
    exit 1
  fi

  local block_file doc_new check_bucket refresh_bucket other_bucket
  block_file="$(mktemp)"
  doc_new="$(mktemp)"
  check_bucket="$(mktemp)"
  refresh_bucket="$(mktemp)"
  other_bucket="$(mktemp)"
  trap 'rm --force -- "${block_file:-}" "${doc_new:-}" "${check_bucket:-}" "${refresh_bucket:-}" "${other_bucket:-}"' EXIT

  # Walk scripts in sorted order, skipping `_*.sh` helpers.
  local script name json bucket
  shopt -s nullglob
  local -a scripts
  scripts=("${scripts_dir}"/*.sh)
  shopt -u nullglob
  # Sort by basename for deterministic output.
  local -a sorted
  if [[ ${#scripts[@]} -gt 0 ]]; then
    mapfile -t sorted < <(printf '%s\n' "${scripts[@]}" | sort)
  else
    sorted=()
  fi

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
  ' "${doc}" >"${doc_new}"

  # Run treefmt over the regenerated doc so the comparison target
  # matches what the formatter chain (mdformat-gfm) produces on commit.
  local fmt_target fmt_root
  fmt_root="$(git rev-parse --show-toplevel)"
  fmt_target="$(mktemp "${fmt_root}/.refresh-scripts-reference-XXXXXX.md")"
  trap 'rm --force -- "${block_file:-}" "${doc_new:-}" "${check_bucket:-}" "${refresh_bucket:-}" "${other_bucket:-}" "${fmt_target:-}"' EXIT
  cp -- "${doc_new}" "${fmt_target}"
  treefmt --no-cache --quiet -- "${fmt_target}" >/dev/null 2>&1 || true
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
