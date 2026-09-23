#!/usr/bin/env bash
# scripts/check-prose-ci-names.sh
#
# @description Lint: every CI job or required check named in prose must
# resolve to something that really runs. Prose that puts a backticked name
# immediately against the claim noun — either order, for both "job" and
# "required check" — is asserting that the name is a unit CI schedules.
# Two ways that assertion goes wrong, both invisible to a freshness gate
# because nothing generates the sentence:
#
#   ghost     the name exists in no workflow, no lint group and no harness
#             roster, so the sentence points at nothing.
#   mislabel  the name resolves, but not to the kind of thing the sentence
#             calls it. A lint-group member or harness-roster entry runs
#             inside a batched group job, so it is never a standalone job.
#             A whole workflow is a CI unit, so calling it a job is loose
#             rather than wrong — but a required-check context always names
#             a job, so a workflow under a check noun is still a mislabel.
#
# The valid-name set is derived, never listed: every workflow's `jobs:`
# keys, every workflow's own bare basename, every lint-group name and
# member in .github/lint-groups.yml, and the first pipe-delimited field of
# every entry in the harness roster. Job outranks workflow outranks member,
# so a name carried by more than one source is judged by the strongest.
#
# Only adjacency counts as a claim. A backticked name merely near the word
# "job" is usually a different noun entirely — one naming a list, or an
# artifact — so a proximity window flags those at a rate that makes the
# lint unusable. A comma-and-`and` list stands wherever a single name may,
# on either side of the noun, and the copula forms cover "is a job" and
# "are required checks". Two adjacency shapes are still not claims and are
# dropped: a filename-shaped name, which names the file a job lives in,
# and an adjectival use (job output, job inputs), which describes a job's
# field rather than naming a job, whether one name holds that position or
# several coordinated ones do.
#
# Fenced lines are skipped outright — they leave the prose tally as well as
# the scan — because a fence quoting workflow YAML is showing a name rather
# than claiming one. A fence closes only on a marker of the same character
# that is at least as long as the one that opened it, so a shorter or
# different marker quoted inside is content; an equal-or-longer one closes
# it even when it carries an info string, which this does not model.
# Blockquoted fences count. Indentation is uncapped, because this repo's
# list-item fences are indented past the CommonMark limit, so a document
# displaying a marker inside an indented block opens a fence the lint
# believes is real. A file ending with a fence still open is therefore a
# precondition failure rather than a clean file. Inline code spans are
# kept: they are what the lint reads.
#
# Exit codes:
#   0  every name claimed in prose resolves to something the sentence's own
#      claim noun admits
#   1  ghost or mislabel name(s) found (details printed to stderr)
#   2  the check could not run: a missing or empty name source, or a
#      producer that lists or reads the scanned files failed

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

# Env overrides (test-only):
#   WORKFLOWS_DIR_OVERRIDE  — alternate .github/workflows/ directory
#   LINT_GROUPS_OVERRIDE    — alternate .github/lint-groups.yml
#   HARNESS_ROSTER_OVERRIDE — file holding roster lines, in place of
#                             run-harness-group.sh --print-roster
#   SCAN_ROOT_OVERRIDE      — alternate root holding the prose to scan
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-${REPO_ROOT}/.github/workflows}"
readonly LINT_GROUPS="${LINT_GROUPS_OVERRIDE:-${REPO_ROOT}/.github/lint-groups.yml}"
readonly HARNESS_ROSTER="${HARNESS_ROSTER_OVERRIDE:-}"
readonly SCAN_ROOT="${SCAN_ROOT_OVERRIDE:-${REPO_ROOT}}"
readonly HARNESS_RUNNER="${REPO_ROOT}/scripts/run-harness-group.sh"

# @description Emit every `jobs:` key of every workflow file, one per line.
function job_names() {
  local f
  local -a workflow_files=()
  glob_into workflow_files 'workflow YAML' \
    "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
  # The `-f` gate stays: a directory named `foo.yml` matches the glob the
  # same way a file does.
  for f in "${workflow_files[@]}"; do
    [[ -f ${f} ]] || continue
    # A workflow with no `jobs:` block is a real shape (a reusable
    # fragment), so an empty key list is not a failure; an unparsable file
    # is, and yq exits non-zero for it.
    yq '.jobs // {} | keys | .[]' "${f}" || return 1
  done
}

# @description Emit every workflow's bare basename, one per line. A harness
#              roster entry often shares its name with a whole workflow; that
#              name is a CI unit of its own, so calling it a job is loose
#              rather than wrong and must not be reported as a mislabel.
function workflow_names() {
  local f base
  local -a workflow_files=()
  glob_into workflow_files 'workflow YAML' \
    "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
  for f in "${workflow_files[@]}"; do
    [[ -f ${f} ]] || continue
    base="$(basename "${f}")"
    base="${base%.yaml}"
    printf '%s\n' "${base%.yml}"
  done
}

# @description Emit every lint-group name and every group member, one per
#              line. Both are in the set: a group name is a real ci.yml job,
#              and a member is a unit that only ever runs inside one.
function lint_group_names() {
  yq '(keys | .[]), (.[] | select(type == "!!seq") | .[])' "${LINT_GROUPS}"
}

# @description Emit the first pipe-delimited field of every harness-roster
#              entry, one per line.
function harness_names() {
  local roster
  if [[ -n ${HARNESS_ROSTER} ]]; then
    roster="$(cat -- "${HARNESS_ROSTER}")" || return 1
  else
    roster="$("${HARNESS_RUNNER}" --print-roster)" || return 1
  fi
  [[ -n ${roster} ]] || return 1
  printf '%s\n' "${roster}" | cut -d'|' -f1
}

# @description Emit every scanned prose path under SCAN_ROOT, NUL-delimited
#              and sorted. The scan set is what a commit would carry —
#              tracked files plus not-yet-added ones, minus anything
#              gitignored. Tracked alone would leave this lint blind to a
#              doc and its fixtures on the very commit that adds them,
#              which is when a pre-commit hook has to see them; the whole
#              working tree would drag in ignored scratch nobody can fix by
#              editing the repo.
#
#              Every Markdown and YAML file, wherever it sits, minus the
#              trees that hold no claim about the live tree:
#              tests/fixtures/ exists to carry deliberate violations, the
#              Claude-behavior tree is almost entirely untracked, and
#              CHANGELOG.md and docs/releases.md are historical records
#              that must keep naming jobs as they stood at the time.
#
#              Paths come back relative to SCAN_ROOT, so the exclusions bite
#              only at a repo root: a fixture scenario rooted inside
#              tests/fixtures/ sees its own files as `docs/x.md` and is
#              scanned normally.
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function prose_scan() {
  local rel listing
  listing="$(make_temp)" || return 1
  # The listing lands in a file rather than a process substitution: a
  # producer inside one exits into its own subshell, so a git failure
  # would read here as an empty tree rather than as a broken scan.
  if ! git -C "${SCAN_ROOT}" ls-files -z --cached --others --exclude-standard \
    >"${listing}"; then
    rm --force -- "${listing}"
    return 1
  fi
  while IFS= read -r -d '' rel; do
    case "${rel}" in
    tests/fixtures/* | .claude/* | CHANGELOG.md | docs/releases.md) continue ;;
    *.md | *.yml | *.yaml) ;;
    *) continue ;;
    esac
    printf '%s\0' "${SCAN_ROOT}/${rel}"
  done <"${listing}" | sort --zero-terminated
  rm --force -- "${listing}"
}

function main() {
  local names_tmp
  names_tmp="$(make_temp)"
  # shellcheck disable=SC2064
  trap "rm --force -- '${names_tmp}'" EXIT

  [[ -d ${WORKFLOWS_DIR} ]] || {
    printf 'prose-ci-names: missing %s\n' "${WORKFLOWS_DIR}" >&2
    exit 2
  }
  [[ -f ${LINT_GROUPS} ]] || {
    printf 'prose-ci-names: missing %s\n' "${LINT_GROUPS}" >&2
    exit 2
  }

  local jobs_out groups_out harness_out workflows_out
  if ! jobs_out="$(job_names)"; then
    printf 'prose-ci-names: could not read workflow job names\n' >&2
    exit 2
  fi
  if ! workflows_out="$(workflow_names)"; then
    printf 'prose-ci-names: could not list workflow files\n' >&2
    exit 2
  fi
  if ! groups_out="$(lint_group_names)"; then
    printf 'prose-ci-names: could not read %s\n' "${LINT_GROUPS}" >&2
    exit 2
  fi
  if ! harness_out="$(harness_names)"; then
    printf 'prose-ci-names: could not read the harness roster\n' >&2
    exit 2
  fi

  # A name source that resolves to nothing cannot be distinguished from a
  # tree where every claim happens to be clean, so an empty one is a
  # precondition failure rather than a pass.
  [[ -n ${jobs_out} ]] || {
    printf 'prose-ci-names: no workflow job names under %s\n' "${WORKFLOWS_DIR}" >&2
    exit 2
  }
  [[ -n ${groups_out} ]] || {
    printf 'prose-ci-names: no lint-group names in %s\n' "${LINT_GROUPS}" >&2
    exit 2
  }

  # `job` outranks `member`: a name that is both a real job and a group
  # member is a job, and calling it one is correct. Sorting the job
  # records last lets the awk loader overwrite the member kind with it.
  {
    printf '%s\n' "${harness_out}" | sed -E 's/$/\tmember/'
    printf '%s\n' "${groups_out}" | sed -E 's/$/\tmember/'
    printf '%s\n' "${workflows_out}" | sed -E 's/$/\tworkflow/'
    printf '%s\n' "${jobs_out}" | sed -E 's/$/\tjob/'
  } | grep -E '^[^[:space:]]' >"${names_tmp}"

  local -a files=()
  enumerate_into files 'find prose' prose_scan

  # Counted off the resolved kind, not the raw records: a name that is both
  # a job and a group member is one job name, and counting records would
  # report it twice and overstate the set the scan was held against.
  local kinds
  kinds="$(
    awk -F'\t' '
      {
        if ($2 == "job") kind[$1] = "job"
        else if ($2 == "workflow" && kind[$1] != "job") kind[$1] = "workflow"
        else if (!($1 in kind)) kind[$1] = $2
      }
      END {
        for (n in kind) {
          if (kind[n] == "job") j++
          else if (kind[n] == "workflow") w++
          else m++
        }
        printf "%d\t%d\t%d\n", j, w, m
      }
    ' "$(awk_path "${names_tmp}")"
  )"
  local -i jobs_n workflows_n members_n
  IFS=$'\t' read -r jobs_n workflows_n members_n <<<"${kinds}"

  local report
  if ! report="$(
    awk -v names_file="$(awk_path "${names_tmp}")" '
      # @description Judge one name against the claim noun it was found
      #              under. A workflow basename is a CI unit, so calling it
      #              a job is loose rather than wrong — but a required-check
      #              context is always a job name, never a workflow, so the
      #              same name under a check noun is still a mislabel.
      # @arg n     the bare name
      # @arg noun  "job" or "check"
      function classify(n, noun,   k) {
        k = kind[n]
        if (k == "")                          return "ghost"
        if (k == "job")                       return "ok"
        if (k == "workflow" && noun == "job") return "ok"
        return "mislabel"
      }
      # @description Score one backticked name found inside a claim match.
      # @arg n         the bare name, backticks stripped
      # @arg rest      the text following the whole match, for the field test
      # @arg name_first whether the name stood before the claim noun
      # @arg solo      whether the matched name list held exactly one name
      # @description Score one name found inside a claim match.
      # @arg n          the bare name, backticks stripped
      # @arg rest       the text following the whole match, for the field test
      # @arg name_first whether the name stood before the claim noun
      # @arg noun       "job" or "check", the claim noun class
      function score(n, rest, name_first, noun,   v, key) {
        # Every tally is keyed the same way, so a drop count and a
        # claim-site count are the same unit and can be read side by side.
        key = FILENAME ":" FNR ":" n
        # A filename-shaped name says which file a job lives in, never a
        # job. This drop also swallows a genuine ghost that happens to look
        # like a filename, which is the accepted cost: nothing in the
        # grammar separates the two, and the shape occurs in live prose
        # while the ghost variant is hypothetical.
        if (n ~ /\.(yml|yaml|sh|json|nix|md|toml)$/) {
          if (!(key in seen_file)) { seen_file[key] = 1; dropped_file++ }
          return
        }
        # An adjectival use names a job field, with the job itself unnamed:
        # a conclusion value, an output id. A coordinated phrase is
        # adjectival the same way a single name is — "`a` and `b` job
        # outputs" names two outputs, not two jobs — so the test is on the
        # position, never on how many names share it. Only a name standing
        # before the noun can be adjectival; after it, the name sits where
        # the field word would go. Same accepted cost as above.
        if (name_first &&
            rest ~ /^[[:space:]]*(output|outputs|input|inputs|conclusion|status|key|keys|name|names|id|ids|matrix|level|result|results|step|steps|log|logs|summary|definition|label|labels|artifact|artifacts)([^A-Za-z0-9_-]|$)/) {
          if (!(key in seen_field)) { seen_field[key] = 1; dropped_field++ }
          return
        }
        # One sentence can satisfy two shapes at once, so a name already
        # scored at this line is not a second site.
        if (key in seen) return
        seen[key] = 1
        sites++
        v = classify(n, noun)
        if (v != "ok") {
          printf "%s:%d: %s: %s — %s\n", FILENAME, FNR, v, n, $0 > "/dev/stderr"
          found = 1
        }
      }
      # @description Find every claim of one shape on the line and score each
      #              name it carries. A trailing character class stands in
      #              for a word boundary, which POSIX ERE has no token for.
      function scan(line, re, name_first, noun,   s, m, rest, names, cnt, i) {
        s = line
        while (match(s, re)) {
          m = substr(s, RSTART, RLENGTH)
          rest = substr(s, RSTART + RLENGTH)
          cnt = 0
          # A shape may carry a list, so every name in the match is scored,
          # not just the first.
          while (match(m, /`[A-Za-z0-9][A-Za-z0-9._-]*`/)) {
            names[++cnt] = substr(m, RSTART + 1, RLENGTH - 2)
            m = substr(m, RSTART + RLENGTH)
          }
          for (i = 1; i <= cnt; i++) score(names[i], rest, name_first, noun)
          # Re-enter past the whole match. Re-entering one character in
          # instead lets the same claim match again from a later start and
          # reports one site as many.
          s = rest
        }
      }
      BEGIN {
        FS = "\t"
        while ((getline line < names_file) > 0) {
          split(line, f, "\t")
          if (f[1] == "") continue
          # Precedence job > workflow > member: a name that is a real job is
          # correctly called one, and a name that is a whole workflow is a
          # CI unit of its own even when a harness entry shares its name.
          if (f[2] == "job") kind[f[1]] = "job"
          else if (f[2] == "workflow" && kind[f[1]] != "job") kind[f[1]] = "workflow"
          else if (kind[f[1]] == "") kind[f[1]] = f[2]
        }
        close(names_file)
        NAME = "`[A-Za-z0-9][A-Za-z0-9._-]*`"
        SEP  = "([ \t]*,[ \t]*and[ \t]+|[ \t]*,[ \t]*|[ \t]+and[ \t]+)"
        LIST = "(" NAME SEP ")*" NAME
        # Mandatory, not optional: without a copula a name standing before
        # a plural check noun is attributive — "the `protect-main` required
        # status checks" are the checks belonging to that ruleset, not a
        # claim that it is one.
        COP  = "(is|was|as|remains|remained|stays|stayed|becomes|became)[ \t]+an?[ \t]+"
        # The plural copula takes no article, and an optional "the" covers
        # "are the required status checks".
        COPP = "(are|were|remain|remained|stay|stayed|become|became)[ \t]+(the[ \t]+)?"
        # Initial letters are matched in both cases: a claim noun opening a
        # sentence is the same claim as one mid-sentence, and a
        # lowercase-only pattern silently exempts every sentence that
        # starts with it.
        JOBS = "(CI[ \t]+)?(job|Job)s?([^A-Za-z0-9_-]|$)"
        # "required check", "status check" and "required status check" are
        # the three forms the tree uses for the same thing.
        CHKS = "((required|Required)|(status|Status))([ \t]+status)?[ \t]+checks?([^A-Za-z0-9_-]|$)"
        # The bare form stays singular. A bare plural is the attributive
        # reading the copula rule above exists to exclude.
        CHK1 = "((required|Required)|(status|Status))([ \t]+status)?[ \t]+check([^A-Za-z0-9_-]|$)"
        # A list standing before the claim noun, singular or plural.
        RA = LIST "[ \t]+" JOBS
        RD = LIST "[ \t]+" COP CHKS
        RG = LIST "[ \t]+" CHK1
        # The noun standing before the name. Singular only for "job": the
        # plural reads as an enumeration of a count ("the five jobs `X`
        # re-runs") far more often than as a claim, and admitting it flags
        # live prose that is telling the truth.
        RB = "(^|[^A-Za-z0-9_-])(CI[ \t]+)?(job|Job)[ \t]+" LIST
        RE = "(^|[^A-Za-z0-9_-])((required|Required)|(status|Status))([ \t]+status)?[ \t]+checks?[ \t]+" LIST
        # Explicit naming, and the appositive.
        RC = "(^|[^A-Za-z0-9_-])((job|Job)|(check|Check))[ \t]+(named|called)[ \t]+" LIST
        RF = LIST "[ \t]*,[ \t]*an?[ \t]+((required|Required)|(status|Status))([ \t]+status)?[ \t]+check([^A-Za-z0-9_-]|$)"
        # The copula forms for the job noun. Without these the most direct
        # phrasing of the claim this lint exists for — "`NAME` is a job" —
        # goes unread.
        RH = LIST "[ \t]+" COP JOBS
        RI = LIST "[ \t]+" COPP JOBS
        RJ = LIST "[ \t]+" COPP CHKS
      }
      FNR == 1 {
        # An unterminated fence in the file just closed hid every line after
        # its opener, so the clean verdict for that file rests on nothing.
        if (fence) { printf "unterminated fence opened in %s\n", fence_file > "/dev/stderr"; unterminated = 1 }
        fence = 0
      }
      # Marker-aware fencing: a fence closes only on a marker of the same
      # character that is at least as long as the one that opened it. A
      # naive parity toggle lets a marker quoted inside a fence close it,
      # which silently drops the rest of the file.
      match($0, /^[[:space:]]*(>[[:space:]]*)*(`{3,}|~{3,})/) {
        mk = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*(>[[:space:]]*)*/, "", mk)
        ch = substr(mk, 1, 1)
        if (!fence) { fence = 1; fch = ch; flen = length(mk); fence_file = FILENAME }
        else if (ch == fch && length(mk) >= flen) { fence = 0 }
        fenced++
        next
      }
      fence { fenced++; next }
      {
        lines++
        scan($0, RA, 1, "job");   scan($0, RB, 0, "job")
        scan($0, RC, 0, "job");   scan($0, RH, 1, "job")
        scan($0, RI, 1, "job")
        scan($0, RD, 1, "check"); scan($0, RE, 0, "check")
        scan($0, RF, 1, "check"); scan($0, RG, 1, "check")
        scan($0, RJ, 1, "check")
      }
      END {
        if (fence) { printf "unterminated fence opened in %s\n", fence_file > "/dev/stderr"; unterminated = 1 }
        printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\n", lines, sites, found, dropped_file, dropped_field, fenced, unterminated
      }
    ' "${files[@]}"
  )"; then
    printf 'prose-ci-names: scan failed\n' >&2
    exit 2
  fi

  local -i lines sites found dropped_file dropped_field fenced unterminated
  IFS=$'\t' read -r lines sites found dropped_file dropped_field fenced \
    unterminated <<<"${report}"

  # An unterminated fence hid every line after its opener, so a clean
  # verdict for that file rests on text nobody read. That is a precondition
  # failure, not a finding about the tree.
  if ((unterminated)); then
    printf 'prose-ci-names: a scanned file left a code fence open, so the rest of it went unread.\n' >&2
    exit 2
  fi

  if ((found)); then
    printf 'prose-ci-names: a name claimed as a CI job or required check does not resolve.\n' >&2
    printf '  ghost    — the name runs nowhere; fix the name or add the job.\n' >&2
    printf '  mislabel — the name resolves, but not to the kind of thing the\n' >&2
    printf '             sentence calls it: a group or roster member runs inside a\n' >&2
    printf '             batched group job, and a whole workflow is never a required\n' >&2
    printf '             status check, since a check context names a job. Name the\n' >&2
    printf '             job instead.\n' >&2
    exit 1
  fi

  # The drop tallies are what separate the clean scenarios. A run that
  # reports zero claim-sites proves nothing on its own: the adjacency test
  # may have matched nothing at all, or it may have matched and had every
  # hit discarded as a filename or a job field. Those are different
  # verdicts about the same tree, so the summary states which one it is.
  # The file count comes from the enumeration, not from awk: a zero-byte
  # file triggers no rule, so awk never sees it and would undercount the
  # breadth the verdict rests on.
  printf 'check-prose-ci-names: ok — scanned %d file(s), %d prose line(s) (%d fenced line(s) skipped), %d claim-site(s) against %d job name(s), %d workflow name(s) and %d member name(s); dropped %d filename-shaped and %d job-field adjacency match(es)\n' \
    "${#files[@]}" "${lines}" "${fenced}" "${sites}" "${jobs_n}" "${workflows_n}" \
    "${members_n}" "${dropped_file}" "${dropped_field}"
}

main "$@"
