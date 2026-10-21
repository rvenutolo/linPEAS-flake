#!/usr/bin/env bash
# scripts/check-no-pipe-into-grep-quiet.sh
#
# @description Lint: no shell file and no workflow or composite-action
# `run:` block pipes into a quiet `grep` (`-q`, a bundled flag holding
# `q`, `--quiet`, or its alias `--silent`). A quiet `grep` exits at its
# first match. A producer still writing then takes SIGPIPE, and under
# `set -o pipefail` the pipeline's status is the producer's 141, so a
# match reads as a miss. Whether the producer is still writing depends on
# how much it writes and on scheduling, so the same line passes on an
# idle machine and fails under load. The rule bans every such pipe,
# whatever the producer: capture the producer's output into a variable,
# then match it with a here-string.
#
# The matcher is textual rather than a shell syntax tree, because the
# shape also lives inside strings a harness hands to `eval` as a real
# pipeline, which a parser reads as a plain word. It counts anywhere on a
# line that is not a comment, quoted text and heredoc bodies included;
# a comment-only line and a trailing comment (a `#` opening a word outside
# quotes, through the end of the line, heredoc bodies included) are
# exempt. `||` is not a pipe and `|&` is. A
# pipe that ends one line, with or without a trailing backslash, joins
# the next non-blank, non-comment line, and a hit there is reported at
# that next line.
#
# The matcher reads only what follows the pipe on one line: an `LC_ALL=`
# assignment word is the only thing that may sit between the pipe and
# `grep`, so `command grep`, `env ... grep`, `timeout ... grep` and
# `LANG=C grep` are not seen. The quiet flag must sit on the `grep`
# word's own line, and a `|`, `;` or `&` inside an earlier argument, as in
# `grep -E 'a|b' --quiet`, hides a flag that follows it.
#
# Workflow and composite-action YAML is matched on each step's extracted
# `run:` body, never on raw YAML: every `run: |` key line ends in a pipe,
# so a body opening with a quiet `grep` would read as a hit.
#
# The scan set is every tracked `*.sh` file, every tracked
# `.github/workflows/*.yml` (or `.yaml`) and every tracked
# `.github/actions/**/action.yml` (or `.yaml`), less any path with a
# `fixtures/` segment: fixture trees exist to hold violations.
#
# Honors SCAN_ROOT_OVERRIDE for fixtures: set, the scan set is globbed
# under that directory instead of listed by `git ls-files`, and paths are
# reported relative to it.
#
# Exits 0 when clean, 1 on any hit, 2 on operational error: a required
# tool is missing, the scan set is empty, a file cannot be read, or `yq`
# cannot read a workflow or one of its steps.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"

require_tool awk
require_tool yq

if [[ -n ${SCAN_ROOT_OVERRIDE:-} ]]; then
  readonly SCAN_ROOT="${SCAN_ROOT_OVERRIDE}"
  if [[ ! -d ${SCAN_ROOT} ]]; then
    printf 'scan root not found: %s\n' "${SCAN_ROOT}" >&2
    exit 2
  fi
else
  require_tool git
  SCAN_ROOT="$(repo_toplevel)"
  readonly SCAN_ROOT
fi

readonly HIT_DIAG='pipe into quiet grep (grep can exit before its producer finishes; under pipefail the SIGPIPE reads a match as a miss)'

# Prints the line number of every hit in its input. A trailing comment is
# cut from each line before either match below, so a pipe inside one is
# comment text. A line ending in a pipe (not `||`), optionally followed by
# a backslash, leaves `pending` set, and the next non-blank, non-comment
# line is matched with a pipe in front of it. The bracket escapes keep this file's own program text from
# matching itself. A flag ends at anything that cannot continue a flag
# word, so a quiet flag closing a quoted `eval` string still counts.
# shellcheck disable=SC2016 # awk program: its $0 is awk's, not the shell's
readonly HIT_PROGRAM='
  # Cuts a trailing comment: a `#` that opens a word outside quotes.
  # Quotes and backslash escapes are tracked on this line alone, so a
  # quoted string spanning lines leaves its later lines read as code.
  function code_part(s,   i, c, sq, dq, prev) {
    prev = " "
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "\\" && !sq) { i++; prev = "x"; continue }
      if (c == "\047" && !dq) sq = !sq
      else if (c == "\"" && !sq) dq = !dq
      else if (c == "#" && !sq && !dq && prev ~ /[[:space:]]/) return substr(s, 1, i - 1)
      prev = c
    }
    return s
  }
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    code = code_part($0)
    text = pending ? "| " code : code
    if (text ~ /(^|[^|])[|]&?[[:space:]]*(LC_ALL=[^[:space:]]+[[:space:]]+)?grep[[:space:]]+([^|;&]*[[:space:]])?(-[[:alpha:]]*q[[:alpha:]]*|--quiet|--silent)([^[:alnum:]_-]|$)/) {
      print NR
    }
    pending = (code ~ /(^|[^|])[|]&?[[:space:]]*[\\]?[[:space:]]*$/)
  }
'

# Emits one `<shape>|<document>|<job position>|<step index>` row per step
# carrying a `run:` key, from both `jobs.<id>.steps` (workflow) and
# `runs.steps` (composite action). The job position is empty for a
# composite. A row holds only numbers and words `yq` prints, never a job
# key: a key is free text and could hold the `|` separator.
# shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
readonly ROWS_QUERY="document_index as \$d | ((((${JOBS_NODE}) // {}) | to_entries | to_entries[] as \$j | (\$j.value.value.steps // []) | to_entries[] | select(.value.run != null) | \"job|\" + (\$d | tostring) + \"|\" + (\$j.key | tostring) + \"|\" + (.key | tostring)), ((.runs.steps // []) | to_entries[] | select(.value.run != null) | \"composite|\" + (\$d | tostring) + \"||\" + (.key | tostring)))"

declare -a candidates=()
if [[ -n ${SCAN_ROOT_OVERRIDE:-} ]]; then
  # dotglob so `**` reaches dot directories, as `git ls-files` does.
  shopt -s globstar dotglob
  glob_into candidates 'shell, workflow and composite-action files' \
    "${SCAN_ROOT}/**/*.sh" \
    "${SCAN_ROOT}/.github/workflows/*.yml" "${SCAN_ROOT}/.github/workflows/*.yaml" \
    "${SCAN_ROOT}/.github/actions/**/action.yml" "${SCAN_ROOT}/.github/actions/**/action.yaml"
  shopt -u globstar dotglob
else
  declare -a tracked=()
  enumerate_into tracked 'git ls-files' git -C "${SCAN_ROOT}" ls-files -z --cached
  for rel in "${tracked[@]}"; do
    candidates+=("${SCAN_ROOT}/${rel}")
  done
fi

declare -a shell_files=() yaml_files=()
for path in "${candidates[@]}"; do
  rel="${path#"${SCAN_ROOT}/"}"
  if [[ ${rel} == fixtures/* || ${rel} == */fixtures/* ]]; then
    continue
  fi
  if [[ ${rel} == *.sh ]]; then
    shell_files+=("${path}")
  elif [[ ${rel} == .github/workflows/*.yml || ${rel} == .github/workflows/*.yaml ]]; then
    # GitHub reads only the top level of the workflows directory.
    [[ ${rel#.github/workflows/} == */* ]] || yaml_files+=("${path}")
  elif [[ ${rel} == .github/actions/*/action.yml || ${rel} == .github/actions/*/action.yaml ||
    ${rel} == .github/actions/action.yml || ${rel} == .github/actions/action.yaml ]]; then
    yaml_files+=("${path}")
  fi
done

if ((${#shell_files[@]} + ${#yaml_files[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf '%s: no shell, workflow or composite-action file left to scan outside fixtures/ — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
    "${0##*/}" >&2
  exit 2
fi

failed=0
for path in ${shell_files+"${shell_files[@]}"}; do
  # A tracked file deleted from the work tree has nothing to scan.
  [[ -e ${path} ]] || continue
  rel="${path#"${SCAN_ROOT}/"}"
  if ! hits="$(awk "${HIT_PROGRAM}" "$(awk_path "${path}")")"; then
    printf 'could not scan %s for pipes into quiet grep\n' "${rel}" >&2
    exit 2
  fi
  while IFS= read -r n; do
    [[ -n ${n} ]] || continue
    printf '%s:%s: %s\n' "${rel}" "${n}" "${HIT_DIAG}" >&2
    failed=$((failed + 1))
  done <<<"${hits}"
done

run_blocks=0
for path in ${yaml_files+"${yaml_files[@]}"}; do
  [[ -e ${path} ]] || continue
  rel="${path#"${SCAN_ROOT}/"}"
  # A refused job key could shift the job positions the rows below name,
  # so the file is not read around it.
  if ! odd_key="$(first_odd_job_key "${path}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${rel}" >&2
    exit 2
  fi
  if [[ -n ${odd_key} ]]; then
    odd_job_key_message "${rel}" "${odd_key}" >&2
    exit 2
  fi
  if ! rows="$(yq eval "${YQ_MERGE_SPEC[@]}" "${ROWS_QUERY}" "${path}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${rel}" >&2
    exit 2
  fi
  while IFS='|' read -r shape doc jpos idx; do
    [[ -n ${shape} ]] || continue
    # The row numbers reach `yq` as data, through `env`.
    if [[ ${shape} == composite ]]; then
      if ! body="$(DOC="${doc}" IDX="${idx}" yq eval "${YQ_MERGE_SPEC[@]}" 'select(document_index == env(DOC)) | .runs.steps[env(IDX)].run' "${path}")"; then
        printf '%s: cannot read composite step[%s] run: block\n' "${rel}" "${idx}" >&2
        exit 2
      fi
      where="$(printf 'composite step[%s]' "${idx}")"
    else
      if ! job="$(DOC="${doc}" JPOS="${jpos}" yq eval "${YQ_MERGE_SPEC[@]}" 'select(document_index == env(DOC)) | '"${JOBS_NODE}"' | to_entries | .[env(JPOS)].key | explode(.)' "${path}")"; then
        printf '%s: cannot read the key of the job at position %s\n' "${rel}" "${jpos}" >&2
        exit 2
      fi
      if ! body="$(DOC="${doc}" JPOS="${jpos}" IDX="${idx}" yq eval "${YQ_MERGE_SPEC[@]}" 'select(document_index == env(DOC)) | '"${JOBS_NODE}"' | to_entries | .[env(JPOS)].value.steps[env(IDX)].run' "${path}")"; then
        printf '%s: cannot read job %q step[%s] run: block\n' "${rel}" "${job}" "${idx}" >&2
        exit 2
      fi
      where="$(printf 'job %q step[%s]' "${job}" "${idx}")"
    fi
    run_blocks=$((run_blocks + 1))
    if ! hits="$(awk "${HIT_PROGRAM}" <<<"${body}")"; then
      printf '%s: could not scan %s run: block for pipes into quiet grep\n' "${rel}" "${where}" >&2
      exit 2
    fi
    while IFS= read -r n; do
      [[ -n ${n} ]] || continue
      printf '%s: %s run: line %s: %s\n' "${rel}" "${where}" "${n}" "${HIT_DIAG}" >&2
      failed=$((failed + 1))
    done <<<"${hits}"
  done <<<"${rows}"
done

if ((failed > 0)); then
  printf '%d pipe(s) into quiet grep found\n' "${failed}" >&2
  exit 1
fi
printf 'no-pipe-into-grep-quiet: ok — scanned %d shell file(s) and %d run: block(s)\n' \
  "${#shell_files[@]}" "${run_blocks}"
exit 0
