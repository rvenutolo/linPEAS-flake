# scripts/lib/harness-assert.sh
#
# @description Cross-scenario discrimination gate for test harnesses.
# A harness asserts behavior by grepping a scenario's captured output for
# a substring. If that substring also appears in a sibling scenario's
# output, the assertion passes whether or not the asserted behavior
# exists — green while verifying nothing. Record each scenario here and
# call `harness_assert_verify` at the end of the run to fail on any such
# substring. Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

HARNESS_ASSERT_POOL=""
HARNESS_ASSERT_COUNT=0
declare -a HARNESS_ASSERT_EXEMPTIONS=()

# @description Register a substring as legitimately shared with one named
# scenario. Use only when the failure path emits no token the nominal path
# lacks; the rationale is mandatory so the weakening is reviewable.
# @arg $1 substring  @arg $2 other scenario name  @arg $3 rationale
function harness_assert_exempt() {
  local -r substring="$1" other="$2" rationale="$3"
  if [[ -z ${rationale} ]]; then
    printf 'harness-assert: exemption for %s needs a rationale\n' "${substring@Q}" >&2
    return 1
  fi
  HARNESS_ASSERT_EXEMPTIONS+=("${substring}"$'\037'"${other}")
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
    HARNESS_ASSERT_POOL="$(mktemp -d)"
  fi

  local -r index="${HARNESS_ASSERT_COUNT}"
  printf '%s' "${scenario}" >"${HARNESS_ASSERT_POOL}/${index}.name"
  printf '%s' "${substring}" >"${HARNESS_ASSERT_POOL}/${index}.sub"
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

  HARNESS_ASSERT_COUNT=$((HARNESS_ASSERT_COUNT + 1))
}

# @description Return 0 if the substring/other-scenario pair is exempt.
# @arg $1 substring  @arg $2 other scenario name
function harness_assert_is_exempt() {
  local -r key="$1"$'\037'"$2"
  local entry
  for entry in ${HARNESS_ASSERT_EXEMPTIONS+"${HARNESS_ASSERT_EXEMPTIONS[@]}"}; do
    [[ ${entry} == "${key}" ]] && return 0
  done
  return 1
}

# @description Apply the pairwise rule to everything recorded, print the
# census, and drop the pool. Exit 1 if any asserted substring also occurs
# in a sibling scenario's output, or if nothing was recorded at all.
function harness_assert_verify() {
  if [[ ${HARNESS_ASSERT_COUNT} -eq 0 ]]; then
    printf 'harness-assert: no scenarios recorded — the harness is wired to the gate but never calls harness_assert_record\n' >&2
    return 1
  fi

  local flagged=0 asserted=0
  local i j sub_i sub_j name_i name_j
  for ((i = 0; i < HARNESS_ASSERT_COUNT; i++)); do
    sub_i="$(cat -- "${HARNESS_ASSERT_POOL}/${i}.sub")"
    [[ -z ${sub_i} ]] && continue
    asserted=$((asserted + 1))
    name_i="$(cat -- "${HARNESS_ASSERT_POOL}/${i}.name")"
    for ((j = 0; j < HARNESS_ASSERT_COUNT; j++)); do
      [[ ${i} -eq ${j} ]] && continue
      sub_j="$(cat -- "${HARNESS_ASSERT_POOL}/${j}.sub")"
      [[ ${sub_j} == "${sub_i}" ]] && continue
      grep --fixed-strings --quiet -- "${sub_i}" \
        "${HARNESS_ASSERT_POOL}/${j}.out" || continue
      name_j="$(cat -- "${HARNESS_ASSERT_POOL}/${j}.name")"
      harness_assert_is_exempt "${sub_i}" "${name_j}" && continue
      printf 'harness-assert: %s asserts %s which also appears in the output of %s — the assertion does not discriminate\n' \
        "${name_i}" "${sub_i@Q}" "${name_j}" >&2
      flagged=$((flagged + 1))
    done
  done

  printf 'harness-assert: checked %d substring assertions across %d scenarios\n' \
    "${asserted}" "${HARNESS_ASSERT_COUNT}"

  rm --recursive --force -- "${HARNESS_ASSERT_POOL}"
  HARNESS_ASSERT_POOL=""
  HARNESS_ASSERT_COUNT=0

  [[ ${flagged} -eq 0 ]]
}
