#!/usr/bin/env bash
# tests/check-prose-ci-names.test.sh
#
# Failure-mode harness for scripts/check-prose-ci-names.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-prose-ci-names.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-prose-ci-names"

failures=0

# The stderr of the most recent scenario, kept so `also_expect` can assert
# against it. `harness_assert_also` checks presence only at
# `harness_assert_verify`, against every stream the record holds; this
# pins the finding to stderr and names the scenario where it happens.
LAST_STDERR=''
LAST_NAME=''

# @description Run the script against a fixture scenario; assert exit code,
# stderr, and — on the clean path — the summary line.
#
# The summary carries the drop tallies, not just a claim-site count, because
# the negative scenarios all pass with zero findings and would otherwise be
# indistinguishable. A run that reports no claim-sites has not said whether
# the adjacency test matched nothing or matched and discarded every hit, and
# those are different statements about the fixture.
#
# @arg $1 scenario directory name under FIXTURES/
# @arg $2 expected exit code (0, 1, or 2)
# @arg $3 expected stderr substring (empty string skips the check)
# @arg $4 expected stdout substring (empty string skips the check)
# @arg $5 workflows dir override (defaults to the scenario's own)
# @arg $6 scenario root override (defaults to FIXTURES/<name>)
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  local -r expected_stderr="$3"
  local -r expected_stdout="${4:-}"
  local -r root="${6:-${FIXTURES}/${name}}"
  local -r workflows="${5:-${root}/workflows}"
  # A scratch root holds no name sources of its own, so they fall back to
  # the workflows directory's own scenario.
  local lint_groups="${root}/lint-groups.yml"
  local roster="${root}/roster.txt"
  if [[ ! -f ${lint_groups} ]]; then
    lint_groups="${workflows%/workflows}/lint-groups.yml"
    roster="${workflows%/workflows}/roster.txt"
  fi

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${workflows}" \
    LINT_GROUPS_OVERRIDE="${lint_groups}" \
    HARNESS_ROSTER_OVERRIDE="${roster}" \
    SCAN_ROOT_OVERRIDE="${root}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  rm --force -- "${outcome_file}" "${stdout_file}" "${LAST_STDERR}"
  LAST_STDERR="${stderr_file}"
  LAST_NAME="${name}"
}

# @description Assert one more substring appears in the last scenario's
# stderr, and register it for the discrimination check. A scenario whose
# point is that several names are reported needs every one of them
# asserted on stderr, where the lint reports them.
# @arg $1 expected stderr substring
function also_expect() {
  local -r substring="$1"
  if ! grep --fixed-strings --quiet -- "${substring}" "${LAST_STDERR}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${LAST_NAME}" "${substring}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${LAST_STDERR}" >&2
    failures=$((failures + 1))
  fi
  harness_assert_also "${substring}"
}

function main() {
  # --- the two failure shapes this lint exists for ---

  # The whole diagnostic is asserted, not the name alone: a reader given
  # only the name has to grep the tree to act on the report, so the file
  # and line are part of what this scenario proves.
  run_scenario 'ghost-fails' 1 'docs/x.md:1: ghost: totally-made-up-gate'

  # A lint-group member runs inside a batched group job, so calling it a
  # job of its own is wrong even though the name resolves. This is the
  # half a set-membership test alone would pass.
  run_scenario 'mislabel-job-fails' 1 'mislabel: doc-anchors'

  run_scenario 'mislabel-check-fails' 1 'mislabel: ephemeral-refs'

  # --- claim shapes beyond the bare singular adjacency ---
  #
  # A matcher that reads only `NAME` job leaves most of the claim surface
  # unchecked. Each scenario below is a phrasing the live tree uses, with
  # every name in it scored, not just the first.

  # An enumeration carries as many claims as it has names, and the real
  # ones in the same list stay silent.
  run_scenario 'enumeration-fails' 1 'ghost: ghost-one'
  also_expect 'ghost: ghost-two'

  run_scenario 'named-and-appositive-fails' 1 'ghost: ghost-named'
  also_expect 'ghost: ghost-appos'

  run_scenario 'status-check-fails' 1 'ghost: ghost-status'
  also_expect 'ghost: ghost-tri'

  # A claim noun opening a sentence is the same claim as one mid-sentence.
  # Lowercase-only patterns exempt every sentence that starts with one.
  run_scenario 'capitalized-noun-fails' 1 'ghost: ghost-cap3'
  also_expect 'ghost: ghost-cap2'

  # --- the clean path ---

  run_scenario 'clean-passes' 0 '' \
    '2 claim-site(s) against 2 job name(s), 1 workflow name(s) and 3 member name(s); dropped 0 filename-shaped and 0 job-field adjacency match(es)'

  # --- negative fixtures: input the rule must still reject ---
  #
  # Each of these is a sentence that sits adjacent to the claim noun and is
  # nonetheless not a claim. Reverting the exclusion that covers one turns
  # it into a reported finding against a true sentence, which is the
  # failure mode that makes a prose lint unusable.

  # `ci.yml` names the file a job lives in, never a job. Revert the
  # filename filter and both lines below are reported.
  run_scenario 'filename-shaped-passes' 0 '' \
    '0 claim-site(s) against 2 job name(s), 1 workflow name(s) and 3 member name(s); dropped 1 filename-shaped and 0 job-field adjacency match(es)'

  # `cancelled` job conclusion, `has-finding` job output, `matrix-leg` job
  # name: the backticked token is the value or the field, and the job is
  # unnamed. Revert the job-field filter and all three are reported.
  run_scenario 'adjectival-passes' 0 '' \
    '0 claim-site(s) against 2 job name(s), 1 workflow name(s) and 3 member name(s); dropped 0 filename-shaped and 3 job-field adjacency match(es)'

  # A fence quoting workflow YAML shows a name rather than claiming one.
  # The ghost inside the fence is unreachable; the one real claim outside
  # it still is.
  run_scenario 'fenced-block-passes' 0 '' \
    '(6 fenced line(s) skipped), 1 claim-site(s)'

  # The shape that sank the proximity matcher this lint replaced: a
  # backticked noun in the same clause as the word "job", naming a list
  # and a mode rather than a job. Neither reaches the name test at all, so
  # both drop tallies stay zero — the distinction from the two scenarios
  # above.
  run_scenario 'proximity-passes' 0 '' \
    '17 prose line(s) (0 fenced line(s) skipped), 0 claim-site(s) against 2 job name(s), 1 workflow name(s) and 3 member name(s); dropped 0 filename-shaped and 0 job-field adjacency match(es)'

  # Without a copula, a name before a plural check noun is attributive:
  # the checks belong to the ruleset rather than the ruleset being one.
  # The mirror case is the noun-first plural, which counts jobs rather
  # than naming one. Revert either number rule and both lines report.
  run_scenario 'attributive-plural-passes' 0 '' \
    '25 prose line(s) (0 fenced line(s) skipped), 0 claim-site(s)'

  # A roster entry that shares its name with a whole workflow names a CI
  # unit of its own, so calling it a job is loose rather than wrong. Drop
  # the workflow kind and this reports a mislabel against a true sentence.
  run_scenario 'roster-workflow-passes' 0 '' \
    '1 claim-site(s) against 3 job name(s), 2 workflow name(s) and 2 member name(s)'

  # A coordinated phrase is adjectival the same way a single name is:
  # "`a` and `b` job outputs" names two outputs, not two jobs. Gate the
  # drop on the name standing alone and both lines report true sentences.
  run_scenario 'coordinated-field-passes' 0 '' \
    '0 claim-site(s) against 2 job name(s), 1 workflow name(s) and 3 member name(s); dropped 0 filename-shaped and 4 job-field adjacency match(es)'

  # A required-check context always names a job, so a whole workflow under
  # a check noun is a mislabel even though the same name under "job" is
  # accepted. Apply the workflow exemption to both nouns and this passes.
  run_scenario 'workflow-check-mislabel-fails' 1 'mislabel: ratchet-pin-audit'

  # The most direct phrasing of the claim, and its plural.
  run_scenario 'copula-job-fails' 1 'ghost: ghost-isjob'
  also_expect 'ghost: ghost-q'

  # A list may stand wherever a single name may, including after the noun.
  run_scenario 'list-after-noun-fails' 1 'ghost: ghost-l2'
  also_expect 'ghost: ghost-l4'

  # A shorter marker inside a longer fence is content, not a closer. This
  # is the run-length half of the fence rule; the quoted-marker scenario
  # covers the marker-character half.
  run_scenario 'nested-fence-passes' 0 '' \
    '19 prose line(s) (5 fenced line(s) skipped), 1 claim-site(s)'

  # A fence inside a blockquote is still a fence.
  run_scenario 'blockquote-fence-passes' 0 '' \
    '19 prose line(s) (3 fenced line(s) skipped), 1 claim-site(s)'

  # --- preconditions ---
  #
  # A name source that resolves to nothing is indistinguishable from a tree
  # whose every claim happens to be clean, so it must be loud rather than
  # scored as a pass.

  run_scenario 'empty-roster-exits-2' 2 'could not read the harness roster'

  run_scenario 'missing-workflows-exits-2' 2 'missing' '' \
    '/nonexistent/workflows'

  # A file that ends with its fence still open hid every line after the
  # opener, so a clean verdict for it would rest on text nobody read.
  #
  # Built at run time rather than checked in: mdformat closes an unbalanced
  # fence, so a tracked fixture carrying one is repaired by the formatter
  # before the harness ever reads it, and the scenario silently passes for
  # the wrong reason. The scan set comes from git, so the scratch root is
  # its own repository.
  local fence_root
  fence_root="$(mktemp --directory)"
  mkdir --parents "${fence_root}/docs" "${fence_root}/workflows"
  git -C "${fence_root}" init --quiet
  cp -- "${FIXTURES}/clean-passes/workflows/ci.yml" "${fence_root}/workflows/ci.yml"
  cp -- "${FIXTURES}/clean-passes/lint-groups.yml" "${fence_root}/lint-groups.yml"
  cp -- "${FIXTURES}/clean-passes/roster.txt" "${fence_root}/roster.txt"
  # Backticks are written as \x60 so the format string carries none. A
  # literal backtick reads as a command substitution, and the quoting
  # needed to keep one is rejected by the shell linter.
  printf 'Intro.\n\n\x60\x60\x60yaml\njobs: {}\n\nThe \x60ghost-hidden\x60 job is required.\n' \
    >"${fence_root}/docs/x.md"
  run_scenario 'unterminated-fence-exits-2' 2 'left a code fence open' '' \
    "${fence_root}/workflows" "${fence_root}"
  rm --recursive --force -- "${fence_root}"

  # A marker quoted inside a fence is fence content, not a fence. A parity
  # toggle that cannot tell them apart closes early and silently drops the
  # rest of the file, taking this ghost with it.
  run_scenario 'quoted-marker-fence-fails' 1 'ghost: ghost-after-marker'

  rm --force -- "${LAST_STDERR}"

  # A lint group is read by its kind, so a member of a list carrying a
  # tag of its own is a member: the name resolves, and a job claim on it
  # is a mislabel rather than a ghost. A group written as a scalar or a
  # map lists no member, so a claim on its value is a ghost.
  local tag_root bt
  bt=$'\x60'
  for shape in 'tagged-list:!x [tagged-member]' 'scalar-group:scalar-member' 'map-group:{k: map-member}'; do
    tag_root="$(mktemp --directory)"
    mkdir --parents "${tag_root}/docs" "${tag_root}/workflows"
    git -C "${tag_root}" init --quiet
    cp -- "${FIXTURES}/clean-passes/workflows/ci.yml" "${tag_root}/workflows/ci.yml"
    cp -- "${FIXTURES}/clean-passes/roster.txt" "${tag_root}/roster.txt"
    printf 'lint-doc-invariants: %s\n' "${shape#*:}" >"${tag_root}/lint-groups.yml"
    local member
    case "${shape%%:*}" in
    tagged-list) member=tagged-member ;;
    scalar-group) member=scalar-member ;;
    *) member=map-member ;;
    esac
    printf 'The \x60%s\x60 job runs in a group.\n' "${member}" >"${tag_root}/docs/x.md"
    case "${shape%%:*}" in
    tagged-list)
      run_scenario 'tagged-list-member-is-a-mislabel' 1 \
        "docs/x.md:1: mislabel: tagged-member — The ${bt}tagged-member${bt} job runs in a group." '' \
        "${tag_root}/workflows" "${tag_root}"
      ;;
    scalar-group)
      run_scenario 'scalar-group-member-is-a-ghost' 1 \
        "docs/x.md:1: ghost: scalar-member — The ${bt}scalar-member${bt} job runs in a group." '' \
        "${tag_root}/workflows" "${tag_root}"
      ;;
    *)
      run_scenario 'map-group-value-is-a-ghost' 1 \
        "docs/x.md:1: ghost: map-member — The ${bt}map-member${bt} job runs in a group." '' \
        "${tag_root}/workflows" "${tag_root}"
      ;;
    esac
    rm --recursive --force -- "${tag_root}"
  done

  # A job key the job list cannot carry is a finding naming the file and
  # the key. A line-break key must not resolve as the two names it spells
  # (the sentence below would pass), and a merge key must not hide the job
  # it brings in (the sentence names a real job and must stay silent).
  local odd_root odd_refused
  odd_refused='jobs: holds a job key that is empty, holds a line break or a tab, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read'
  odd_root="$(mktemp --directory)"
  mkdir --parents "${odd_root}/docs" "${odd_root}/workflows"
  git -C "${odd_root}" init --quiet
  cp -- "${FIXTURES}/clean-passes/lint-groups.yml" "${FIXTURES}/clean-passes/roster.txt" "${odd_root}/"
  printf 'The %sa%s job runs on every PR.\n' "${bt}" "${bt}" >"${odd_root}/docs/x.md"
  printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n  "a\\nb":\n    runs-on: ubuntu-latest\n' \
    >"${odd_root}/workflows/ci.yml"
  run_scenario 'job-key-line-break-is-refused' 1 \
    "${odd_root}/workflows/ci.yml: ${odd_refused} (first: \"a\\nb\")" '' \
    "${odd_root}/workflows" "${odd_root}"
  also_expect 'docs/x.md:1: ghost: a'
  printf 'The %sfoo%s job runs on every PR.\n' "${bt}" "${bt}" >"${odd_root}/docs/x.md"
  printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n  "":\n    runs-on: ubuntu-latest\n' \
    >"${odd_root}/workflows/ci.yml"
  run_scenario 'job-key-empty-is-refused' 1 \
    "${odd_root}/workflows/ci.yml: ${odd_refused} (first: \"\")" '' \
    "${odd_root}/workflows" "${odd_root}"
  printf 'The %sj%s job runs on every PR.\n' "${bt}" "${bt}" >"${odd_root}/docs/x.md"
  printf 'x: &m\n  j:\n    runs-on: ubuntu-latest\njobs:\n  <<: *m\n  foo:\n    runs-on: ubuntu-latest\n' \
    >"${odd_root}/workflows/ci.yml"
  run_scenario 'job-key-merge-key-is-refused' 1 \
    "${odd_root}/workflows/ci.yml: ${odd_refused} (first: \"<<\")" '' \
    "${odd_root}/workflows" "${odd_root}"
  if grep --fixed-strings --quiet -- 'ghost: j' "${LAST_STDERR}"; then
    printf 'FAIL: %s — the merged job j is reported as a ghost\n' "${LAST_NAME}" >&2
    failures=$((failures + 1))
  fi
  # A tab, a carriage return or a NUL in a key must not leave a readable
  # name behind either: the name records are tab-split, and a NUL is
  # dropped from the listing, so each would otherwise make the prose name
  # `a` resolve.
  printf 'The %sa%s job runs on every PR.\n' "${bt}" "${bt}" >"${odd_root}/docs/x.md"
  local odd_key odd_json
  for odd_key in 'a\tb' 'a\rb' 'a\0'; do
    odd_json="${odd_key}"
    if [[ ${odd_key} == 'a\0' ]]; then odd_json='a\u0000'; fi
    printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n  "%s":\n    runs-on: ubuntu-latest\n' "${odd_key}" \
      >"${odd_root}/workflows/ci.yml"
    run_scenario "job-key-${odd_key//\\/}-is-refused" 1 \
      "${odd_root}/workflows/ci.yml: ${odd_refused} (first: \"${odd_json}\")" '' \
      "${odd_root}/workflows" "${odd_root}"
    also_expect 'docs/x.md:1: ghost: a'
  done
  # A key YAML types as an int, bool or null is a scalar and reads as its
  # text; a sequence key is not a scalar and is refused.
  printf 'The %sfoo%s job runs on every PR.\n' "${bt}" "${bt}" >"${odd_root}/docs/x.md"
  printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n  1:\n    runs-on: ubuntu-latest\n' \
    >"${odd_root}/workflows/ci.yml"
  run_scenario 'job-key-int-is-read' 0 '' '' \
    "${odd_root}/workflows" "${odd_root}"
  printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n  ? [seq, key]\n  : runs-on: ubuntu-latest\n' \
    >"${odd_root}/workflows/ci.yml"
  run_scenario 'job-key-sequence-is-refused' 1 \
    "${odd_root}/workflows/ci.yml: ${odd_refused} (first: \"[seq, key]\")" '' \
    "${odd_root}/workflows" "${odd_root}"
  # A merge key whose value is not a mapping cannot be resolved, so the
  # file's jobs are not read; the refusal is the verdict, beside an
  # ordinary workflow and as the only workflow alike.
  printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n' >"${odd_root}/workflows/ci.yml"
  printf 's: &s 5\njobs:\n  <<: *s\n  z:\n    runs-on: ubuntu-latest\n' >"${odd_root}/workflows/scalar-merge.yml"
  run_scenario 'job-key-scalar-merge-key-is-refused' 1 \
    "${odd_root}/workflows/scalar-merge.yml: ${odd_refused} (first: \"<<\")" '' \
    "${odd_root}/workflows" "${odd_root}"
  # The read that fails on the refused file's own shape is not echoed
  # beside the finding.
  if grep --fixed-strings --quiet -- 'merge anchors' "${LAST_STDERR}"; then
    printf 'FAIL: %s — yq message printed beside the finding\n' "${LAST_NAME}" >&2
    failures=$((failures + 1))
  fi
  rm --force -- "${odd_root}/workflows/scalar-merge.yml" "${odd_root}/workflows/ci.yml"
  mkdir --parents "${odd_root}/solo"
  printf 's: &s 5\njobs:\n  <<: *s\n  z:\n    runs-on: ubuntu-latest\n' >"${odd_root}/solo/only-scalar-merge.yml"
  run_scenario 'job-key-scalar-merge-key-sole-workflow-is-refused' 1 \
    "${odd_root}/solo/only-scalar-merge.yml: ${odd_refused} (first: \"<<\")" '' \
    "${odd_root}/solo" "${odd_root}"
  rm --force -- "${odd_root}/solo/only-scalar-merge.yml"
  # Every workflow refused still reports the refusal, not an empty name set.
  printf 'on: push\njobs:\n  ? [a, b]\n  : {runs-on: x}\n' >"${odd_root}/solo/only-seq-key.yml"
  run_scenario 'job-key-sole-workflow-all-refused-is-refused' 1 \
    "${odd_root}/solo/only-seq-key.yml: ${odd_refused} (first: \"[a, b]\")" '' \
    "${odd_root}/solo" "${odd_root}"
  rm --force -- "${odd_root}/solo/only-seq-key.yml"
  # A merge list inside a job is read first mapping wins, which also keeps
  # `yq` from printing its warning about the default order.
  printf 'Nothing here names a job.\n' >"${odd_root}/docs/x.md"
  printf 'p: &p\n  runs-on: a\nq: &q\n  runs-on: b\njobs:\n  foo:\n    <<: [*p, *q]\n' \
    >"${odd_root}/workflows/ci.yml"
  run_scenario 'job-merge-list-is-silent' 0 '' '' \
    "${odd_root}/workflows" "${odd_root}"
  if grep --fixed-strings --quiet -- 'WARN' "${LAST_STDERR}"; then
    printf 'FAIL: %s — yq warned about the merge order\n' "${LAST_NAME}" >&2
    failures=$((failures + 1))
  fi
  # A directory named like a workflow matches the glob and is not read.
  rm --force -- "${odd_root}/workflows/ci.yml"
  printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n' >"${odd_root}/workflows/real.yml"
  mkdir --parents "${odd_root}/workflows/dir.yml"
  run_scenario 'job-key-directory-named-yml-is-skipped' 0 '' '' \
    "${odd_root}/workflows" "${odd_root}"
  rm --recursive --force -- "${odd_root}"

  # A scan root git cannot enumerate must be loud. Reading the listing
  # through a process substitution instead would lose git's exit status to
  # its subshell, and the run would report a clean tree it never read.
  local nonrepo_root
  nonrepo_root="$(mktemp --directory)"
  mkdir --parents "${nonrepo_root}/docs"
  run_scenario 'non-repo-scan-root-exits-2' 2 'failed enumerating the scan set' '' \
    "${FIXTURES}/clean-passes/workflows" "${nonrepo_root}"
  rm --recursive --force -- "${nonrepo_root}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
