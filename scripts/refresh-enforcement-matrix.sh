#!/usr/bin/env bash
# scripts/refresh-enforcement-matrix.sh
#
# Regenerate docs/security/enforcement-matrix.md from the inline
# `<!-- enforcer: ...; ci: ...; hook: ... -->` annotations on every
# bullet of docs/invariant-index.md. Cross-check that every referenced
# script, ci.yml job, and pre-commit hook actually exists; cross-check
# the reverse direction (no orphan scripts/jobs/hooks beyond an
# explicit EXEMPT list).
#
# Annotation format:
#   `;` separates the three top-level fields (enforcer:, ci:, hook:)
#   `,` separates multiple items WITHIN one field
#   Literal `-` is the explicit "no enforcer of this kind" sentinel
#   and is NOT cross-checked.
#
# Exit codes:
#   0 — matrix in sync, no drift, no gaps (gaps emit WARN to stderr).
#   1 — --check mode and the file would change.
#   2 — structural error: typoed reference, orphan enforcer, missing field.
#
# Env overrides (for tests):
#   INVARIANT_INDEX_OVERRIDE       alternate invariant-index.md path
#   MATRIX_OUTPUT_OVERRIDE         alternate output file path
#   SCRIPTS_DIR_OVERRIDE           alternate scripts/ root
#   CI_YML_OVERRIDE                alternate ci.yml path
#   PRECOMMIT_HOOK_NAMES_OVERRIDE  newline-separated hook list
#                                  (bypasses the slow `nix eval`)
#   SKIP_REVERSE_CHECK             if "1", skip orphan-script /
#                                  orphan-job / orphan-hook checks.
#                                  Used by the fixture round-trip
#                                  test where the index intentionally
#                                  references only a subset of real
#                                  enforcers.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'printf "[%s] %-5s line %s (exit %s): %s\n" \
  "$(date "+%Y-%m-%dT%H:%M:%S%z")" ERROR "${LINENO}" "$?" "${BASH_COMMAND}" >&2' ERR

function log() {
  printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
}
function log_info() { log INFO "$*"; }
function log_warn() { log WARN "$*"; }
function log_err() { log ERROR "$*"; }

function require_tool() {
  local -r tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log_err "missing required tool: ${tool}"
    exit 1
  fi
}

# Format-only / aggregate hooks that intentionally don't map to a
# specific invariant.
readonly HOOK_EXEMPT=(
  "actionlint"
  "ci-summary-fresh"
  "commitlint"
  "deadnix"
  "editorconfig-checker"
  "enforcement-matrix-fresh"
  "flake-show-fresh"
  "just-recipes-fresh"
  "markdownlint"
  "nixfmt"
  "precommit-table-fresh"
  "shellcheck"
  "shfmt"
  "statix"
  "treefmt"
  "typos"
  "yamllint"
  "zizmor"
  # Meta hooks about the lint/doc infrastructure itself.
  "check-doc-anchors"
  "check-jsonschema"
  "check-orphan-invariants"
  "pre-commit-hooks-sha-parity"
)

# CI jobs that don't enforce a documented invariant: build / matrix /
# format-only checks (counterparts to HOOK_EXEMPT linters), plus
# meta-infrastructure lints whose enforcer is on SCRIPT_EXEMPT.
readonly CI_EXEMPT_EXTRA=(
  "build-linpeas"
  "build-linpeas-arm64"
  "check-doc-anchors"
  "check-jsonschema"
  "check-orphan-invariants"
  "commitlint"
  "dashboard-data-tests"
  "editorconfig"
  "flake-check"
  "image-smoke"
  "image-smoke-arm64"
  "markdownlint"
  "pre-commit-hooks-sha-parity"
  "required-checks-no-paths"
  "smoke-test"
  "smoke-test-arm64"
  "typos"
)

# Auxiliary scripts that don't enforce a documented invariant.
readonly SCRIPT_EXEMPT=(
  "bump-linpeas"
  "check-doc-anchors"                 # meta: lints anchor links in docs
  "check-jsonschema"                  # wrapper around upstream tool
  "check-orphan-invariants"           # meta: lints the index itself
  "check-pre-commit-hooks-sha-parity" # meta: lints hook config
  "check-required-checks-no-paths"    # meta: lints CI config shape
  "check-script-has-test"             # meta: lints test pairing
  "gen-dashboard-data"
  "refresh-ci-summary"
  "refresh-enforcement-matrix"
  "refresh-flake-show"
  "refresh-just-recipes"
  "refresh-precommit-table"
)

function is_in_list() {
  local -r needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ ${item} == "${needle}" ]] && return 0
  done
  return 1
}

# Trim leading/trailing whitespace from a string.
function trim() {
  local s="$1"
  # shellcheck disable=SC2001
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# parse_index <index_file> <out_tsv>
#
# Emits one TSV row per bullet in <index_file>:
#   name<TAB>source_link<TAB>enforcer_csv<TAB>ci_csv<TAB>hook_csv
# enforcer_csv / ci_csv / hook_csv are comma-separated raw values
# (still including the literal `-` sentinel; not yet split).
# Exit 2 if any bullet's annotation is missing one of the three keys.
function parse_index() {
  local -r index_file="$1" out_tsv="$2"
  local -i failed=0
  local line name link body chunk key val
  : >"${out_tsv}"
  while IFS= read -r line; do
    # Bullet lines look like: `- **<name>** — <text> → [<link>](...) <!-- ... -->`.
    # The name may contain escaped `\*` (markdown), so `[^*]+` is too strict.
    # Match `- **` literally then extract via sed up to the first ` — ` or
    # the closing `**`.
    case "${line}" in
    "- **"*) ;;
    *) continue ;;
    esac
    name="$(printf '%s\n' "${line}" |
      sed -n 's/^- \*\*\(.*\)\*\* —.*/\1/p' | head -n1)"
    if [[ -z ${name} ]]; then
      name="$(printf '%s\n' "${line}" |
        sed -n 's/^- \*\*\(.*\)\*\*.*/\1/p' | head -n1)"
    fi
    [[ -z ${name} ]] && continue
    # Extract the markdown link target via sed (regex inside bash [[ =~ ]]
    # is brittle around parentheses across libc versions).
    link="$(printf '%s\n' "${line}" |
      sed -n 's/.*\[\([^]]*\)\](\([^)]*\)).*/\2/p' | head -n1)"
    # Extract HTML-comment body via sed.
    body="$(printf '%s\n' "${line}" |
      sed -n 's/.*<!--[[:space:]]*\(.*\)[[:space:]]*-->.*/\1/p' | head -n1)"
    if [[ -z ${body} ]]; then
      log_err "bullet ${name@Q}: missing <!-- enforcer:...; ci:...; hook:... --> annotation"
      failed=$((failed + 1))
      continue
    fi
    local enforcer="" ci="" hook=""
    local have_enforcer=0 have_ci=0 have_hook=0
    # Split body on ';'
    local IFS_BAK="${IFS}"
    IFS=';'
    # shellcheck disable=SC2206
    local chunks=(${body})
    IFS="${IFS_BAK}"
    for chunk in "${chunks[@]}"; do
      chunk="$(trim "${chunk}")"
      [[ -z ${chunk} ]] && continue
      if [[ ${chunk} =~ ^(enforcer|ci|hook):[[:space:]]*(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="$(trim "${BASH_REMATCH[2]}")"
        case "${key}" in
        enforcer)
          enforcer="${val}"
          have_enforcer=1
          ;;
        ci)
          ci="${val}"
          have_ci=1
          ;;
        hook)
          hook="${val}"
          have_hook=1
          ;;
        esac
      fi
    done
    if ((have_enforcer == 0)); then
      log_err "bullet ${name@Q}: annotation missing 'enforcer' field"
      failed=$((failed + 1))
      continue
    fi
    if ((have_ci == 0)); then
      log_err "bullet ${name@Q}: annotation missing 'ci' field"
      failed=$((failed + 1))
      continue
    fi
    if ((have_hook == 0)); then
      log_err "bullet ${name@Q}: annotation missing 'hook' field"
      failed=$((failed + 1))
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${name}" "${link}" "${enforcer}" "${ci}" "${hook}" >>"${out_tsv}"
  done <"${index_file}"
  if ((failed > 0)); then
    exit 2
  fi
}

# load_hook_names <out_file>
function load_hook_names() {
  local -r out_file="$1"
  if [[ -n ${PRECOMMIT_HOOK_NAMES_OVERRIDE:-} ]]; then
    printf '%s\n' "${PRECOMMIT_HOOK_NAMES_OVERRIDE}" | sort --unique >"${out_file}"
    return 0
  fi
  require_tool nix
  require_tool jq
  local sys
  sys="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
  nix eval --json ".#devTooling.${sys}.preCommitHooks" |
    jq --raw-output 'keys[]' | sort --unique >"${out_file}"
}

# load_ci_jobs <ci_yml> <out_file>
function load_ci_jobs() {
  local -r ci_yml="$1" out_file="$2"
  require_tool yq
  yq eval '.jobs | keys | .[]' "${ci_yml}" | sort --unique >"${out_file}"
}

# load_ci_jobs_exempt <out_file>
# Source the EXEMPT list at runtime from scripts/check-ci-job-in-summary.sh.
function load_ci_jobs_exempt() {
  local -r out_file="$1" sibling="$2"
  if [[ ! -f ${sibling} ]]; then
    : >"${out_file}"
    return 0
  fi
  awk '
    /^readonly EXEMPT=\(/ { in_block = 1; next }
    in_block && /^\)/ { exit }
    in_block {
      # Lines look like:  "name"   # comment
      if (match($0, /"[^"]+"/)) {
        token = substr($0, RSTART, RLENGTH)
        gsub(/"/, "", token)
        print token
      }
    }
  ' "${sibling}" | sort --unique >"${out_file}"
}

# cross_check_forward <tsv> <scripts_dir> <ci_jobs_file> <hook_names_file>
# Verify every parsed enforcer/ci/hook reference exists. Skip literal `-`.
function cross_check_forward() {
  local -r tsv="$1" scripts_dir="$2" ci_jobs_file="$3" hook_names_file="$4"
  local -i failed=0
  local name link enforcer ci hook item
  while IFS=$'\t' read -r name link enforcer ci hook; do
    # enforcer items are paths like scripts/check-foo.sh
    if [[ ${enforcer} != "-" ]]; then
      local IFS_BAK="${IFS}"
      IFS=','
      # shellcheck disable=SC2206
      local items=(${enforcer})
      IFS="${IFS_BAK}"
      for item in "${items[@]}"; do
        item="$(trim "${item}")"
        [[ -z ${item} || ${item} == "-" ]] && continue
        local basename="${item##*/}"
        if [[ ! -f "${scripts_dir}/${basename}" ]]; then
          log_err "bullet ${name@Q}: enforcer ${item@Q} not found in scripts dir"
          failed=$((failed + 1))
        fi
      done
    fi
    if [[ ${ci} != "-" ]]; then
      local IFS_BAK="${IFS}"
      IFS=','
      # shellcheck disable=SC2206
      local items=(${ci})
      IFS="${IFS_BAK}"
      for item in "${items[@]}"; do
        item="$(trim "${item}")"
        [[ -z ${item} || ${item} == "-" ]] && continue
        if ! grep --quiet --fixed-strings --line-regexp -- "${item}" "${ci_jobs_file}"; then
          log_err "bullet ${name@Q}: ci job ${item@Q} not found in ci.yml"
          failed=$((failed + 1))
        fi
      done
    fi
    if [[ ${hook} != "-" ]]; then
      local IFS_BAK="${IFS}"
      IFS=','
      # shellcheck disable=SC2206
      local items=(${hook})
      IFS="${IFS_BAK}"
      for item in "${items[@]}"; do
        item="$(trim "${item}")"
        [[ -z ${item} || ${item} == "-" ]] && continue
        if ! grep --quiet --fixed-strings --line-regexp -- "${item}" "${hook_names_file}"; then
          log_err "bullet ${name@Q}: pre-commit hook ${item@Q} not found in preCommitHooks"
          failed=$((failed + 1))
        fi
      done
    fi
  done <"${tsv}"
  if ((failed > 0)); then
    exit 2
  fi
}

# Collect a sorted-unique list of referenced items from a TSV column index.
# $1 = tsv path; $2 = field index (3=enforcer, 4=ci, 5=hook); $3 = out file
# $4 = basename-only ('1' to strip dir, '0' to keep)
function collect_referenced() {
  local -r tsv="$1" idx="$2" out="$3" basename_only="$4"
  awk -v IDX="${idx}" -F'\t' '{ print $IDX }' "${tsv}" |
    tr ',' '\n' |
    while IFS= read -r v; do
      v="$(trim "${v}")"
      [[ -z ${v} || ${v} == "-" ]] && continue
      if [[ ${basename_only} == "1" ]]; then
        v="${v##*/}"
        v="${v%.sh}"
      fi
      printf '%s\n' "${v}"
    done | sort --unique >"${out}"
}

# cross_check_reverse <tsv> <scripts_dir> <ci_jobs_file> <hook_names_file> <ci_yml_dir>
function cross_check_reverse() {
  local -r tsv="$1" scripts_dir="$2" ci_jobs_file="$3" hook_names_file="$4" sibling="$5"
  local -i failed=0
  local ref_scripts ref_jobs ref_hooks
  local real_scripts ci_exempt_file
  ref_scripts="$(mktemp)"
  ref_jobs="$(mktemp)"
  ref_hooks="$(mktemp)"
  real_scripts="$(mktemp)"
  ci_exempt_file="$(mktemp)"
  # collect_referenced runs in a subshell pipe; use a temp helper instead.
  # Build reference lists inline.
  awk -F'\t' '{ print $3 }' "${tsv}" | tr ',' '\n' |
    while IFS= read -r v; do
      v="$(trim "${v}")"
      [[ -z ${v} || ${v} == "-" ]] && continue
      v="${v##*/}"
      v="${v%.sh}"
      printf '%s\n' "${v}"
    done | sort --unique >"${ref_scripts}"
  awk -F'\t' '{ print $4 }' "${tsv}" | tr ',' '\n' |
    while IFS= read -r v; do
      v="$(trim "${v}")"
      [[ -z ${v} || ${v} == "-" ]] && continue
      printf '%s\n' "${v}"
    done | sort --unique >"${ref_jobs}"
  awk -F'\t' '{ print $5 }' "${tsv}" | tr ',' '\n' |
    while IFS= read -r v; do
      v="$(trim "${v}")"
      [[ -z ${v} || ${v} == "-" ]] && continue
      printf '%s\n' "${v}"
    done | sort --unique >"${ref_hooks}"

  # All real check-*.sh under scripts/, basename stem only.
  find "${scripts_dir}" -maxdepth 1 -type f -name 'check-*.sh' -printf '%f\n' |
    sed 's/\.sh$//' | sort --unique >"${real_scripts}"

  # Orphan scripts: in real, not in ref, not in SCRIPT_EXEMPT.
  local stem
  while IFS= read -r stem; do
    [[ -z ${stem} ]] && continue
    if grep --quiet --fixed-strings --line-regexp -- "${stem}" "${ref_scripts}"; then
      continue
    fi
    if is_in_list "${stem}" "${SCRIPT_EXEMPT[@]}"; then
      continue
    fi
    log_err "orphan script: ${stem}.sh has no enforcer: reference in invariant index"
    failed=$((failed + 1))
  done <"${real_scripts}"

  # Orphan ci jobs: real job not in ref, not in sibling EXEMPT list.
  load_ci_jobs_exempt "${ci_exempt_file}" "${sibling}"
  local job
  while IFS= read -r job; do
    [[ -z ${job} ]] && continue
    if grep --quiet --fixed-strings --line-regexp -- "${job}" "${ref_jobs}"; then
      continue
    fi
    if grep --quiet --fixed-strings --line-regexp -- "${job}" "${ci_exempt_file}"; then
      continue
    fi
    if is_in_list "${job}" "${CI_EXEMPT_EXTRA[@]}"; then
      continue
    fi
    log_err "orphan ci job: ${job} has no ci: reference in invariant index"
    failed=$((failed + 1))
  done <"${ci_jobs_file}"

  # Orphan hooks: real hook not in ref, not in HOOK_EXEMPT.
  local hook
  while IFS= read -r hook; do
    [[ -z ${hook} ]] && continue
    if grep --quiet --fixed-strings --line-regexp -- "${hook}" "${ref_hooks}"; then
      continue
    fi
    if is_in_list "${hook}" "${HOOK_EXEMPT[@]}"; then
      continue
    fi
    log_err "orphan hook: ${hook} has no hook: reference in invariant index"
    failed=$((failed + 1))
  done <"${hook_names_file}"

  rm --force -- "${ref_scripts}" "${ref_jobs}" "${ref_hooks}" \
    "${real_scripts}" "${ci_exempt_file}"
  if ((failed > 0)); then
    exit 2
  fi
}

# relativize_link <path>
#
# Translate a source-doc link path (written relative to docs/ root in
# the invariant-index annotations) into a path that mkdocs resolves
# correctly from docs/security/enforcement-matrix.md's perspective.
#
#   security/foo.md  -> foo.md          (same section)
#   development/x.md -> ../development/x.md   (cross section)
function relativize_link() {
  local -r path="$1"
  case "${path}" in
  security/*) printf '%s' "${path#security/}" ;;
  *) printf '../%s' "${path}" ;;
  esac
}

# render_cell <csv> -> formatted cell string
function render_cell() {
  local -r csv="$1"
  local out="" item
  if [[ -z ${csv} || ${csv} == "-" ]]; then
    printf '_(none)_'
    return 0
  fi
  local IFS_BAK="${IFS}"
  IFS=','
  # shellcheck disable=SC2206
  local items=(${csv})
  IFS="${IFS_BAK}"
  for item in "${items[@]}"; do
    item="$(trim "${item}")"
    [[ -z ${item} ]] && continue
    if [[ ${item} == "-" ]]; then
      continue
    fi
    if [[ -n ${out} ]]; then
      out+=", "
    fi
    out+="\`${item}\`"
  done
  if [[ -z ${out} ]]; then
    printf '_(none)_'
  else
    printf '%s' "${out}"
  fi
}

# render_matrix <tsv> <out_file>
function render_matrix() {
  local -r tsv="$1" out_file="$2"
  {
    printf '# Enforcement matrix\n'
    printf '\n'
    printf '<!--\n'
    printf '  This file is auto-generated by scripts/refresh-enforcement-matrix.sh.\n'
    printf '  Do not edit by hand. To update, edit docs/invariant-index.md\n'
    # shellcheck disable=SC2016
    printf '  annotations and run `just show-enforcement-matrix`.\n'
    printf '%s\n' '-->'
    printf '\n'
    printf '<!-- BEGIN enforcement-matrix -->\n'
    printf '\n'
    printf '| Invariant | Source doc | Enforcer script | CI job | Pre-commit hook |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    local name link enforcer ci hook
    while IFS=$'\t' read -r name link enforcer ci hook; do
      local link_cell rel_link
      if [[ -n ${link} ]]; then
        rel_link="$(relativize_link "${link}")"
        link_cell="[${rel_link}](${rel_link})"
      else
        link_cell="_(none)_"
      fi
      # Emit warnings for gap cells.
      if [[ -z ${enforcer} || ${enforcer} == "-" ]]; then
        log_warn "gap: ${name@Q} has no enforcer script"
      fi
      if [[ -z ${ci} || ${ci} == "-" ]]; then
        log_warn "gap: ${name@Q} has no ci job"
      fi
      if [[ -z ${hook} || ${hook} == "-" ]]; then
        log_warn "gap: ${name@Q} has no pre-commit hook"
      fi
      printf '| %s | %s | %s | %s | %s |\n' \
        "${name}" \
        "${link_cell}" \
        "$(render_cell "${enforcer}")" \
        "$(render_cell "${ci}")" \
        "$(render_cell "${hook}")"
    done <"${tsv}"
    printf '\n'
    printf '<!-- END enforcement-matrix -->\n'
  } >"${out_file}"
}

function parse_and_render() {
  local -r index_file="$1" output_file="$2" ci_yml="$3" scripts_dir="$4" check_only="$5"
  local tsv hook_names ci_jobs tmp_out sibling
  tsv="$(mktemp)"
  hook_names="$(mktemp)"
  ci_jobs="$(mktemp)"
  tmp_out="$(mktemp)"
  sibling="$(git rev-parse --show-toplevel)/scripts/check-ci-job-in-summary.sh"

  parse_index "${index_file}" "${tsv}"
  load_hook_names "${hook_names}"
  load_ci_jobs "${ci_yml}" "${ci_jobs}"
  cross_check_forward "${tsv}" "${scripts_dir}" "${ci_jobs}" "${hook_names}"
  if [[ ${SKIP_REVERSE_CHECK:-0} != "1" ]]; then
    cross_check_reverse "${tsv}" "${scripts_dir}" "${ci_jobs}" "${hook_names}" "${sibling}"
  fi
  render_matrix "${tsv}" "${tmp_out}"

  # Run treefmt over the regenerated doc so the comparison target
  # matches what the formatter chain (mdformat-gfm) would produce on
  # commit. Without this, mdformat's table-cell padding causes
  # persistent drift between the script output and the committed file.
  if command -v treefmt >/dev/null 2>&1; then
    local fmt_target fmt_root
    fmt_root="$(git rev-parse --show-toplevel)"
    fmt_target="$(mktemp "${fmt_root}/.refresh-enforcement-matrix-XXXXXX.md")"
    cp -- "${tmp_out}" "${fmt_target}"
    treefmt --no-cache --quiet -- "${fmt_target}" >/dev/null 2>&1 || true
    mv -- "${fmt_target}" "${tmp_out}"
  fi

  if [[ ${check_only} == 'true' ]]; then
    if [[ ! -f ${output_file} ]] || ! cmp --silent -- "${output_file}" "${tmp_out}"; then
      log_err "enforcement matrix in ${output_file} is stale. Run scripts/refresh-enforcement-matrix.sh and commit."
      rm --force -- "${tsv}" "${hook_names}" "${ci_jobs}" "${tmp_out}"
      exit 1
    fi
    log_info "enforcement matrix in ${output_file} is up to date"
    rm --force -- "${tsv}" "${hook_names}" "${ci_jobs}" "${tmp_out}"
    return 0
  fi

  # Ensure parent dir exists when writing.
  local parent_dir
  parent_dir="$(dirname -- "${output_file}")"
  mkdir -p -- "${parent_dir}"
  mv -- "${tmp_out}" "${output_file}"
  log_info "refreshed enforcement matrix in ${output_file}"
  rm --force -- "${tsv}" "${hook_names}" "${ci_jobs}"
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

  export LC_ALL=C
  require_tool git
  require_tool awk
  require_tool grep
  require_tool sed
  # treefmt is invoked on the rendered doc so the regenerated table
  # matches what the formatter (mdformat-gfm) emits at commit time.
  require_tool treefmt

  local repo_root index_file output_file ci_yml scripts_dir
  repo_root="$(git rev-parse --show-toplevel)"
  index_file="${INVARIANT_INDEX_OVERRIDE:-${repo_root}/docs/invariant-index.md}"
  output_file="${MATRIX_OUTPUT_OVERRIDE:-${repo_root}/docs/security/enforcement-matrix.md}"
  ci_yml="${CI_YML_OVERRIDE:-${repo_root}/.github/workflows/ci.yml}"
  scripts_dir="${SCRIPTS_DIR_OVERRIDE:-${repo_root}/scripts}"
  readonly repo_root index_file output_file ci_yml scripts_dir

  parse_and_render "${index_file}" "${output_file}" "${ci_yml}" \
    "${scripts_dir}" "${check_only}"
}

main "$@"
