# scripts/lib/harness-assert.sh
#
# @description Cross-scenario discrimination gate for test harnesses.
# A harness asserts behavior by grepping a scenario's captured output for
# a substring. If that substring also appears in a sibling scenario's
# output, the assertion passes whether or not the asserted behavior
# exists — green while verifying nothing. Record each scenario here and
# call `harness_assert_verify` at the end of the run to fail on any such
# substring, and on any two scenarios whose whole observable outcome is
# the same — a pair that verifies one thing between them however each is
# named. Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

# shellcheck source=scripts/lib/temp.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/temp.sh"

HARNESS_ASSERT_POOL=""
HARNESS_ASSERT_COUNT=0
declare -a HARNESS_ASSERT_EXEMPTIONS=()
declare -a HARNESS_ASSERT_PARITY_EXEMPTIONS=()

# @description Register a substring as legitimately shared with one named
# scenario, or with every scenario when the second argument is `*`. Use the
# wildcard for a global banner a script prints on every run of a whole
# outcome class: such a substring still separates that class from its
# opposite, which is the axis the assertion is about. Use the named form
# when one failure path emits no token another lacks. The rationale is
# mandatory so the weakening is reviewable.
# @arg $1 substring  @arg $2 other scenario name or `*`  @arg $3 rationale
function harness_assert_exempt() {
  local -r substring="$1" other="$2" rationale="$3"
  if [[ -z ${rationale} ]]; then
    printf 'harness-assert: exemption for %s needs a rationale\n' "${substring@Q}" >&2
    return 1
  fi
  HARNESS_ASSERT_EXEMPTIONS+=("${substring}"$'\037'"${other}")
}

# @description Register two scenarios as legitimately producing one
# observable outcome. Two scenarios the gate cannot tell apart verify one
# thing between them, so the pair needs a reason that a reviewer can
# check: the scenarios must differ in what they exercise even though
# nothing they emit says so, and no honest output could separate them.
# The rationale is mandatory, and the pair matches in either order.
# @arg $1 scenario name  @arg $2 other scenario name  @arg $3 rationale
function harness_assert_parity_exempt() {
  local -r scenario="$1" other="$2" rationale="$3"
  if [[ -z ${rationale} ]]; then
    printf 'harness-assert: parity exemption for %s and %s needs a rationale\n' \
      "${scenario@Q}" "${other@Q}" >&2
    return 1
  fi
  HARNESS_ASSERT_PARITY_EXEMPTIONS+=("${scenario}"$'\037'"${other}")
}

# @description Record one scenario's asserted substring and the output
# stream(s) the harness asserts against. Pass '' as the substring for a
# scenario that asserts only an exit code — its output still belongs in
# the comparison pool, because that is usually the output a failure-path
# substring wrongly matches.
# @arg $1 scenario name  @arg $2 asserted substring ('' if none)
# @arg $@ one or more captured output files
function harness_assert_record() {
  local -r scenario="$1" substring="$2"
  shift 2

  if [[ -z ${HARNESS_ASSERT_POOL} ]]; then
    HARNESS_ASSERT_POOL="$(make_temp --directory)"
  fi

  local -r index="${HARNESS_ASSERT_COUNT}"
  printf '%s' "${scenario}" >"${HARNESS_ASSERT_POOL}/${index}.name"
  : >"${HARNESS_ASSERT_POOL}/${index}.sub"
  if [[ -n ${substring} ]]; then
    printf '%s\n' "${substring}" >"${HARNESS_ASSERT_POOL}/${index}.sub"
  fi
  : >"${HARNESS_ASSERT_POOL}/${index}.out"

  local file
  for file in "$@"; do
    if [[ ! -f ${file} ]]; then
      printf 'harness-assert: %s: output file not found: %s\n' \
        "${scenario}" "${file}" >&2
      return 1
    fi
    cat -- "${file}" >>"${HARNESS_ASSERT_POOL}/${index}.out"
  done

  # Sameness is decided on output with clock-derived text removed: the
  # shared logger's timestamp prefix, and the elapsed-seconds cell of a
  # markdown summary row. Both vary with when the suite runs rather than
  # with what the script did, so a raw byte comparison would call two
  # scenarios the same when they land in one second and different when
  # they straddle the boundary — making the census depend on the clock.
  # The patterns are anchored to exactly those two shapes; any other
  # varying text still counts as a difference, which flags rather than
  # hides.
  sed --regexp-extended \
    -e 's/^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\] //' \
    -e 's/\| [0-9]+s \|/| <duration>s |/g' \
    -- "${HARNESS_ASSERT_POOL}/${index}.out" \
    >"${HARNESS_ASSERT_POOL}/${index}.norm"

  HARNESS_ASSERT_COUNT=$((HARNESS_ASSERT_COUNT + 1))
}

# @description Attach another asserted substring to the most recent
# record. Use when one invocation asserts several properties of its
# output: recording that invocation once per property makes those records
# byte-identical siblings, which the pairwise rule cannot separate and
# the census scores as collapsed coverage. Each attached substring is
# held to the same rule as the record's own.
# @arg $1 substring
function harness_assert_also() {
  local -r substring="$1"
  if [[ ${HARNESS_ASSERT_COUNT} -eq 0 ]]; then
    printf 'harness-assert: harness_assert_also called before any record\n' >&2
    return 1
  fi
  if [[ -z ${substring} ]]; then
    printf 'harness-assert: harness_assert_also needs a substring\n' >&2
    return 1
  fi
  printf '%s\n' "${substring}" \
    >>"${HARNESS_ASSERT_POOL}/$((HARNESS_ASSERT_COUNT - 1)).sub"
}

# @description Return 0 if the record at the given index asserts the
# given substring. Membership is a whole-line match against the record's
# substring list, so one substring being another's prefix does not count
# as the same assertion.
# @arg $1 substring  @arg $2 record index
function harness_assert_declares() {
  grep --fixed-strings --line-regexp --quiet -- "$1" \
    "${HARNESS_ASSERT_POOL}/${2}.sub"
}

# @description Return 0 if the substring/other-scenario pair is exempt,
# either by an exact pair or by a `*` wildcard registered for the substring.
# @arg $1 substring  @arg $2 other scenario name
function harness_assert_is_exempt() {
  local -r key="$1"$'\037'"$2"
  local -r wildcard="$1"$'\037''*'
  local entry
  for entry in ${HARNESS_ASSERT_EXEMPTIONS+"${HARNESS_ASSERT_EXEMPTIONS[@]}"}; do
    [[ ${entry} == "${key}" || ${entry} == "${wildcard}" ]] && return 0
  done
  return 1
}

# @description Return 0 if the two named scenarios are registered as a
# parity exemption, in either order.
# @arg $1 scenario name  @arg $2 other scenario name
function harness_assert_parity_is_exempt() {
  local -r key="$1"$'\037'"$2"
  local -r reversed="$2"$'\037'"$1"
  local entry
  for entry in ${HARNESS_ASSERT_PARITY_EXEMPTIONS+"${HARNESS_ASSERT_PARITY_EXEMPTIONS[@]}"}; do
    [[ ${entry} == "${key}" || ${entry} == "${reversed}" ]] && return 0
  done
  return 1
}

# @description Apply the pairwise rule, the identical-output rule and the
# parity rule to everything recorded, print the census, and drop the pool.
# Exit 1 if any asserted substring also occurs in a sibling scenario's
# output, if two records share one output while asserting different
# substrings, if two records share one output without a parity exemption,
# or if nothing was recorded at all. The census names every group of
# scenarios sharing one output before reporting the counts.
function harness_assert_verify() {
  if [[ ${HARNESS_ASSERT_COUNT} -eq 0 ]]; then
    printf 'harness-assert: no scenarios recorded — the harness is wired to the gate but never calls harness_assert_record\n' >&2
    return 1
  fi

  local flagged=0 asserted=0
  local i j sub_i name_i name_j
  for ((i = 0; i < HARNESS_ASSERT_COUNT; i++)); do
    name_i="$(cat -- "${HARNESS_ASSERT_POOL}/${i}.name")"
    while IFS= read -r sub_i; do
      [[ -z ${sub_i} ]] && continue
      asserted=$((asserted + 1))
      for ((j = 0; j < HARNESS_ASSERT_COUNT; j++)); do
        [[ ${i} -eq ${j} ]] && continue
        harness_assert_declares "${sub_i}" "${j}" && continue
        # Identical output means no substring can separate the two records,
        # so naming one of them as the weak assertion picks a side of a pair
        # the gate cannot tell apart, and no narrowing could clear it. The
        # identical-output rule below judges such records as a group instead,
        # and the census names the group, so the collapse stays visible
        # rather than quietly shrinking the comparison set.
        cmp --silent -- "${HARNESS_ASSERT_POOL}/${i}.norm" \
          "${HARNESS_ASSERT_POOL}/${j}.norm" && continue
        grep --fixed-strings --quiet -- "${sub_i}" \
          "${HARNESS_ASSERT_POOL}/${j}.out" || continue
        name_j="$(cat -- "${HARNESS_ASSERT_POOL}/${j}.name")"
        harness_assert_is_exempt "${sub_i}" "${name_j}" && continue
        printf 'harness-assert: %s asserts %s which also appears in the output of %s — the assertion does not discriminate\n' \
          "${name_i}" "${sub_i@Q}" "${name_j}" >&2
        flagged=$((flagged + 1))
      done
    done <"${HARNESS_ASSERT_POOL}/${i}.sub"
  done

  # Records whose normalized output is byte-identical are one observation
  # as far as this gate can see. Group them: the earliest record with a
  # given output leads its group, and every later record matching it joins.
  local -a group_of=()
  for ((i = 0; i < HARNESS_ASSERT_COUNT; i++)); do
    sort --unique -- "${HARNESS_ASSERT_POOL}/${i}.sub" \
      >"${HARNESS_ASSERT_POOL}/${i}.set"
    group_of[i]=${i}
    for ((j = 0; j < i; j++)); do
      if cmp --silent -- "${HARNESS_ASSERT_POOL}/${i}.norm" \
        "${HARNESS_ASSERT_POOL}/${j}.norm"; then
        group_of[i]=${group_of[j]}
        break
      fi
    done
  done

  # Every member of such a group must claim the same set of substrings.
  # When one member asserts a substring another does not, the pool credits
  # that assertion to output the other member never had to produce: the
  # substring cannot tell the two apart, so the assertion holds whether or
  # not the scenario it names behaves differently. Either the records
  # observe one invocation — then they are one record carrying several
  # substrings via `harness_assert_also` — or the scenarios really differ
  # and the harness must record output that shows it.
  local distinct=0 names p q name_p name_q
  local -a members=()
  for ((i = 0; i < HARNESS_ASSERT_COUNT; i++)); do
    [[ ${group_of[i]} -eq ${i} ]] || continue
    distinct=$((distinct + 1))
    name_i="$(cat -- "${HARNESS_ASSERT_POOL}/${i}.name")"
    names="" members=()
    for ((j = i; j < HARNESS_ASSERT_COUNT; j++)); do
      [[ ${group_of[j]} -eq ${i} ]] || continue
      members+=("${j}")
      name_j="$(cat -- "${HARNESS_ASSERT_POOL}/${j}.name")"
      names+="${names:+, }${name_j@Q}"
      [[ ${j} -eq ${i} ]] && continue
      cmp --silent -- "${HARNESS_ASSERT_POOL}/${i}.set" \
        "${HARNESS_ASSERT_POOL}/${j}.set" && continue
      printf 'harness-assert: %s and %s produce identical output but assert different substrings — neither assertion discriminates them\n' \
        "${name_i@Q}" "${name_j@Q}" >&2
      flagged=$((flagged + 1))
    done
    [[ ${#members[@]} -gt 1 ]] || continue

    # Two scenarios the gate cannot tell apart verify one thing between
    # them: whatever the second one is meant to exercise, its whole
    # observable outcome is already produced by the first, so deleting
    # either leaves the recorded evidence unchanged. A harness at parity
    # — as many distinct outcomes as scenarios — is one where every
    # scenario earns its place. Each pair in a collapsed group is judged
    # on its own, so excusing one pair never excuses the rest.
    for ((p = 0; p < ${#members[@]}; p++)); do
      name_p="$(cat -- "${HARNESS_ASSERT_POOL}/${members[p]}.name")"
      for ((q = p + 1; q < ${#members[@]}; q++)); do
        name_q="$(cat -- "${HARNESS_ASSERT_POOL}/${members[q]}.name")"
        harness_assert_parity_is_exempt "${name_p}" "${name_q}" && continue
        printf 'harness-assert: %s and %s share one observable outcome — make their outputs differ, merge them into one record with harness_assert_also, or register harness_assert_parity_exempt with a rationale\n' \
          "${name_p@Q}" "${name_q@Q}" >&2
        flagged=$((flagged + 1))
      done
    done

    printf 'harness-assert: scenarios sharing one output: %s\n' "${names}"
  done

  printf 'harness-assert: checked %d substring assertions across %d scenarios (%d distinct outputs)\n' \
    "${asserted}" "${HARNESS_ASSERT_COUNT}" "${distinct}"

  rm --recursive --force -- "${HARNESS_ASSERT_POOL}"
  HARNESS_ASSERT_POOL=""
  HARNESS_ASSERT_COUNT=0

  [[ ${flagged} -eq 0 ]]
}
