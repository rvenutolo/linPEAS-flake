#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-ci-job-in-summary.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/ci-job-in-summary"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  # Optional 4th/5th args override the lint-groups manifest + scripts dir
  # so the manifest-coverage assertion can be exercised against a fixture.
  # Optional 6th arg overrides the EXEMPT list. Only set when provided so
  # the script's own defaults apply otherwise.
  local -a env_overrides=(
    "WORKFLOWS_DIR_OVERRIDE=${FIXTURES}/${fixture}"
    "CI_WORKFLOW_OVERRIDE=${FIXTURES}/${fixture}/ci.yml"
    "CATEGORIES_FILE_OVERRIDE=${FIXTURES}/${fixture}/categories.yml"
  )
  [[ -n ${4:-} ]] && env_overrides+=("LINT_GROUPS_OVERRIDE=${4}")
  [[ -n ${5:-} ]] && env_overrides+=("SCRIPTS_DIR_OVERRIDE=${5}")
  [[ -n ${6:-} ]] && env_overrides+=("EXEMPT_OVERRIDE=${6}")
  local got_exit=0 got_stderr
  got_stderr="$(env "${env_overrides[@]}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good 0 ""
expect bad-missing-category 1 "EXEMPT"
expect bad-orphan-category 1 "does not match any job"
# Manifest coverage: a lint-groups basename with no real check script fails.
expect bad-missing-manifest-check 1 "lint-groups basename" \
  "${FIXTURES}/bad-missing-manifest-check/lint-groups.yml" \
  "${FIXTURES}/bad-missing-manifest-check/scripts"
# A missing manifest is a hard infrastructure error, not drift: nothing was
# cross-checked, so it carries the could-not-run code (exit 2).
expect good 2 "manifest not found" \
  "${FIXTURES}/bad-missing-manifest-check/does-not-exist.yml" \
  "${FIXTURES}/bad-missing-manifest-check/scripts"
# An unmapped auxiliary job with no EXEMPT entry fails — the exemption in
# the next scenario is load-bearing, not incidentally passing.
expect good-exempt 1 "EXEMPT"
# An EXEMPT entry naming a real, unmapped ci.yml job exempts it.
expect good-exempt 0 "" "" "" "aux"
# An EXEMPT entry that is not a ci.yml job exempts nothing.
expect good 1 "is not a job" "" "" "not-a-real-job"
# An EXEMPT entry that is already a category key exempts nothing — the
# forward loop matches the category map first and never reaches it.
expect good 1 "already a key" "" "" "foo"
# A lint-groups manifest yq cannot parse is a tooling error, not drift
# — it must fail loud (exit 2) rather than silently skip coverage.
expect good 2 "" "${FIXTURES}/bad-malformed-manifest/lint-groups.yml" ""

# The two files the cross-check reads are inputs, not findings: absent, the
# lint has compared nothing and must not report drift.
expect does-not-exist 2 "ci workflow not found"
# Present but unparsable is the same verdict as absent, and for the same
# reason: neither file was read, so nothing was cross-checked. Left to
# `set -e`, yq's own exit 1 reaches the caller as a job missing from the
# summary — drift found in a document this run never opened.
expect bad-malformed-ci 2 "cannot read job keys"
expect bad-malformed-categories 2 "cannot read category keys"

# @description Make a directory holding a `yq` that exits with a given
# status for every call whose arguments hold a given string and hands any
# other call to the real `yq`, and point STUB_DIR at it. A scenario puts
# the directory first on PATH for its own run only.
# @arg $1 argument text that marks the failing call
# @arg $2 exit status for that call
function yq_stub() {
  local real_yq
  real_yq="$(command -v yq)"
  STUB_DIR="$(mktemp --directory)"
  printf '#!/usr/bin/env bash\ncase "$*" in *%q*) exit %d ;; esac\nexec %q "$@"\n' \
    "$1" "$2" "${real_yq}" >"${STUB_DIR}/yq"
  chmod +x -- "${STUB_DIR}/yq"
}

# @description Run the lint over a workflows directory whose job keys one
# `yq` read cannot produce. The reverse check holds every category entry
# against the jobs of every workflow, so a workflow it could not read
# leaves that set short: the run must stop as a could-not-run, on a line
# naming the file, `yq` and its status, rather than report entries the
# unread file may hold, or pass without it.
# @arg $1 scenario label
# @arg $2 workflows directory (holding ci.yml and categories.yml)
# @arg $3 file the line must name
# @arg $4 status the line must carry
# @arg $5 argument text of the read to fail, or empty for the real `yq`,
#         whose own message must then sit above the line
function expect_unread_workflow() {
  local -r label="$1" dir="$2" file="$3" status="$4" pattern="$5"
  local -r want="cannot read job keys from ${file}: yq exited ${status}"
  local run_path="${PATH}" got_exit=0 got_stderr
  if [[ -n ${pattern} ]]; then
    yq_stub "${pattern}" "${status}"
    run_path="${STUB_DIR}:${PATH}"
  fi
  got_stderr="$(PATH="${run_path}" WORKFLOWS_DIR_OVERRIDE="${dir}" \
    CI_WORKFLOW_OVERRIDE="${dir}/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${dir}/categories.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ -n ${pattern} ]]; then rm --recursive --force -- "${STUB_DIR}"; fi
  if [[ ${got_exit} != 2 ]]; then
    printf 'FAIL %s: exit %s, want 2\n  stderr: %s\n' "${label}" "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  # The last line, so that `yq`'s own message above it is allowed and a
  # verdict printed after it is not.
  if [[ -z ${pattern} && ${got_stderr} != *$'\n'* ]]; then
    printf 'FAIL %s: nothing printed above the line\n  got: %s\n' "${label}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr##*$'\n'} != "${want}" ]]; then
    printf 'FAIL %s: last stderr line is not %q\n  got: %s\n' "${label}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

# The stub text ends in the file's path, which only the per-workflow read
# of that one file carries: the read of ci.yml's own job list has no
# `explode`.
expect_unread_workflow 'failed read of a workflow holding mapped jobs' \
  "${FIXTURES}/good" "${FIXTURES}/good/ci.yml" 7 \
  "explode(.) | keys | .[] ${FIXTURES}/good/ci.yml"
expect_unread_workflow 'failed read of a workflow holding no job' \
  "${FIXTURES}/good" "${FIXTURES}/good/categories.yml" 9 \
  "explode(.) | keys | .[] ${FIXTURES}/good/categories.yml"

# A workflow that does not parse, written at run time so no unparsable
# file sits in the tree for the formatters to refuse.
unparsable_dir="$(mktemp --directory)"
cp -- "${FIXTURES}/good/ci.yml" "${FIXTURES}/good/categories.yml" "${unparsable_dir}/"
printf 'on: [push\n' >"${unparsable_dir}/broken.yml"
expect_unread_workflow 'unparsable workflow beside ci.yml' \
  "${unparsable_dir}" "${unparsable_dir}/broken.yml" 1 ''
rm --recursive --force -- "${unparsable_dir}"

# A run that could not read a workflow has cross-checked nothing, so it
# prints no drift line either: the unmapped job beside the unparsable
# workflow is not reported under the could-not-run code.
drift_dir="$(mktemp --directory)"
cp -- "${FIXTURES}/bad-missing-category/ci.yml" "${FIXTURES}/bad-missing-category/categories.yml" "${drift_dir}/"
printf 'on: [push\n' >"${drift_dir}/broken.yml"
drift_exit=0
drift_stderr="$(WORKFLOWS_DIR_OVERRIDE="${drift_dir}" \
  CI_WORKFLOW_OVERRIDE="${drift_dir}/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${drift_dir}/categories.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || drift_exit=$?
rm --recursive --force -- "${drift_dir}"
if [[ ${drift_exit} != 2 || ${drift_stderr} == *'EXEMPT'* ||
  ${drift_stderr} != *"cannot read job keys from ${drift_dir}/broken.yml: yq exited 1" ]]; then
  printf 'FAIL drift beside an unparsable workflow: exit %s, want 2 and no drift line\n  stderr: %s\n' \
    "${drift_exit}" "${drift_stderr}" >&2
  exit 1
fi
printf 'OK   drift beside an unparsable workflow\n'

# A missing or unreadable lint-groups manifest stops the run before any
# check prints: beside an unmapped job, no drift line is reported under
# the could-not-run code.
manifest_dir="$(mktemp --directory)"
manifest_exit=0
manifest_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}/bad-missing-category" \
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/bad-missing-category/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${FIXTURES}/bad-missing-category/categories.yml" \
  LINT_GROUPS_OVERRIDE="${manifest_dir}/absent.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || manifest_exit=$?
if [[ ${manifest_exit} != 2 || ${manifest_stderr} != "lint-groups manifest not found: ${manifest_dir}/absent.yml" ]]; then
  printf 'FAIL drift beside a missing manifest: exit %s, want 2 and only the manifest line\n  stderr: %s\n' \
    "${manifest_exit}" "${manifest_stderr}" >&2
  exit 1
fi
printf 'OK   drift beside a missing manifest\n'
printf 'a: [\n' >"${manifest_dir}/broken.yml"
manifest_exit=0
manifest_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}/bad-missing-category" \
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/bad-missing-category/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${FIXTURES}/bad-missing-category/categories.yml" \
  LINT_GROUPS_OVERRIDE="${manifest_dir}/broken.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || manifest_exit=$?
rm --recursive --force -- "${manifest_dir}"
if [[ ${manifest_exit} != 2 || ${manifest_stderr} == *'EXEMPT'* ||
  ${manifest_stderr} != *$'\n'"${manifest_dir}/broken.yml: could not evaluate lint-groups manifest with yq (malformed?)" ]]; then
  printf 'FAIL drift beside an unparsable manifest: exit %s, want 2 and no drift line\n  stderr: %s\n' \
    "${manifest_exit}" "${manifest_stderr}" >&2
  exit 1
fi
printf 'OK   drift beside an unparsable manifest\n'

# @description Run the lint with a lint-groups manifest written to a
# temp dir at run time, beside one fixture's ci.yml and category map, and
# compare the whole of stderr. The scripts dir holds check-foo.sh only.
# @arg $1 manifest file name, which is also the scenario's label
# @arg $2 manifest body  @arg $3 fixture  @arg $4 expected exit status
# @arg $5 expected stderr, with DIR standing for the temp dir
function expect_manifest() {
  local -r name="$1" body="$2" fixture="$3" want_exit="$4"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  printf '%s' "${body}" >"${dir}/${name}"
  want="${5//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}/${fixture}" \
    CI_WORKFLOW_OVERRIDE="${FIXTURES}/${fixture}/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/${fixture}/categories.yml" \
    LINT_GROUPS_OVERRIDE="${dir}/${name}" \
    SCRIPTS_DIR_OVERRIDE="${FIXTURES}/bad-missing-manifest-check/scripts" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL manifest %s: exit %s, want %s, and stderr %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   manifest %s\n' "${name}"
}

# The manifest is a precondition: one YAML document mapping each group
# to a non-empty list of check names. Any other shape lists no check the
# coverage can hold to a script, so the run stops (exit 2) before any
# check prints, beside drift (bad-orphan-category) as beside none.
readonly NOT_MAP='lint-groups manifest is not a map of groups'
unread_n=0
expect_manifest valid.yml $'g:\n  - foo\n' good 0 ''
expect_manifest empty.yml '' good 2 "DIR/empty.yml: ${NOT_MAP} (kind=scalar, tag=!!null)"
expect_manifest comment.yml $'# only a comment\n' bad-orphan-category 2 "DIR/comment.yml: ${NOT_MAP} (kind=scalar, tag=!!null)"
expect_manifest tilde.yml $'~\n' bad-orphan-category 2 "DIR/tilde.yml: ${NOT_MAP} (kind=scalar, tag=!!null)"
expect_manifest scalar.yml $'foo\n' good 2 "DIR/scalar.yml: ${NOT_MAP} (kind=scalar, tag=!!str)"
expect_manifest list.yml $'- foo\n- nosuch\n' bad-orphan-category 2 "DIR/list.yml: ${NOT_MAP} (kind=seq, tag=!!seq)"
expect_manifest empty-map.yml $'{}\n' good 2 'DIR/empty-map.yml: lint-groups manifest names no group'
expect_manifest several.yml $'g:\n  - foo\n---\nh:\n  - foo\n' bad-orphan-category 2 \
  'DIR/several.yml: lint-groups manifest holds several YAML documents'
expect_manifest group-scalar.yml $'g: foo\n' bad-orphan-category 2 \
  'DIR/group-scalar.yml: lint-groups group g is not a list (kind=scalar, tag=!!str)'
expect_manifest group-null.yml $'h:\n  - foo\ng:\n' good 2 \
  'DIR/group-null.yml: lint-groups group g is not a list (kind=scalar, tag=!!null)'
expect_manifest group-empty.yml $'g: []\nh:\n  - foo\n' good 2 'DIR/group-empty.yml: lint-groups group g lists no check'
expect_manifest item-map.yml $'g:\n  - foo\n  - {a: nosuch}\n' good 2 \
  'DIR/item-map.yml: lint-groups group g holds an item that is not a check name (kind=map, tag=!!map)'
expect_manifest item-int.yml $'g:\n  - 5\n' bad-orphan-category 2 \
  'DIR/item-int.yml: lint-groups group g holds an item that is not a check name (kind=scalar, tag=!!int)'
expect_manifest item-strtag.yml $'g:\n  - foo\n  - !!str [nosuch]\n' good 2 \
  'DIR/item-strtag.yml: lint-groups group g holds an item that is not a check name (kind=seq, tag=!!str)'
readonly ALIAS='lint-groups manifest holds an alias or a merge key'
expect_manifest alias.yml $'x: &l [foo]\ng: *l\n' good 2 "DIR/alias.yml: ${ALIAS}"
expect_manifest merge.yml $'x: &m {g: [foo]}\n<<: *m\n' good 2 "DIR/merge.yml: ${ALIAS}"
expect_manifest alias-key.yml $'g: [&k foo]\n*k : [foo]\n' good 2 "DIR/alias-key.yml: ${ALIAS}"
expect_manifest merge-list.yml $'<<: [foo]\ng: [foo]\n' good 2 "DIR/merge-list.yml: ${ALIAS}"
# A check name is one non-empty line: the coverage below reads names a
# line at a time.
readonly BAD_NAME='holds a check name that is empty or spans lines'
expect_manifest name-empty.yml $'g:\n  - foo\n  - ""\n' good 2 "DIR/name-empty.yml: lint-groups group g ${BAD_NAME}"
expect_manifest name-lines.yml $'h:\n  - "foo\\nfoo"\n' good 2 "DIR/name-lines.yml: lint-groups group h ${BAD_NAME}"
# A list or a map carrying a tag of its own is still read by its kind.
expect_manifest group-strtag.yml $'g: !!str [foo, nosuch]\n' good 1 \
  "DIR/group-strtag.yml: lint-groups basename nosuch has no check script (${FIXTURES}/bad-missing-manifest-check/scripts/check-nosuch.sh)"$'\n1 ci.yml / categories drift entry/entries'
expect_manifest root-xtag.yml $'!x\ng:\n  - foo\n' good 0 ''

# Each read of the manifest is status-tested: with `yq` failing it, the
# run stops (exit 2) on the manifest line alone. Each scenario names its
# own manifest, so no two print the same line.
for read in 'eval kind + ' 'select(kind == "alias" or' 'eval length ' 'kind != "seq"' 'length == 0' 'tag != "!!str"' 'select(. == ""' 'eval .[] | .[]'; do
  unread_dir="$(mktemp --directory)"
  unread_name="unread-$((++unread_n)).yml"
  printf 'g:\n  - foo\n' >"${unread_dir}/${unread_name}"
  yq_stub "${read}" 7
  unread_exit=0
  unread_stderr="$(PATH="${STUB_DIR}:${PATH}" WORKFLOWS_DIR_OVERRIDE="${FIXTURES}/good" \
    CI_WORKFLOW_OVERRIDE="${FIXTURES}/good/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/good/categories.yml" \
    LINT_GROUPS_OVERRIDE="${unread_dir}/${unread_name}" \
    SCRIPTS_DIR_OVERRIDE="${FIXTURES}/bad-missing-manifest-check/scripts" \
    "${SCRIPT}" 2>&1 >/dev/null)" || unread_exit=$?
  rm --recursive --force -- "${unread_dir}" "${STUB_DIR}"
  unread_want="${unread_dir}/${unread_name}: could not evaluate lint-groups manifest with yq (malformed?)"
  if [[ ${unread_exit} != 2 || ${unread_stderr} != "${unread_want}" ]]; then
    printf 'FAIL manifest read %q failing: exit %s, want 2, and stderr %q\n  got: %s\n' \
      "${read}" "${unread_exit}" "${unread_want}" "${unread_stderr}" >&2
    exit 1
  fi
  printf 'OK   manifest read %s failing\n' "${read}"
done

# A `jobs:` written as an alias stands for the map it names: its keys are
# job keys, and the category entry naming one of them resolves. Only
# `jobs:` is resolved: a merge key `yq` cannot resolve elsewhere in a
# workflow leaves its job keys readable.
alias_dir="$(mktemp --directory)"
cp -- "${FIXTURES}/good/ci.yml" "${alias_dir}/"
printf 'foo: Category-A\nbar: Category-B\nbaz: Category-C\n' >"${alias_dir}/categories.yml"
printf 'x: &j\n  baz:\n    runs-on: ubuntu-latest\njobs: *j\n' >"${alias_dir}/aliased.yml"
printf 'c: &c [x]\nenv:\n  <<: *c\njobs:\n  foo:\n    runs-on: ubuntu-latest\n' >"${alias_dir}/merge-elsewhere.yml"
alias_exit=0
alias_stderr="$(WORKFLOWS_DIR_OVERRIDE="${alias_dir}" \
  CI_WORKFLOW_OVERRIDE="${alias_dir}/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${alias_dir}/categories.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || alias_exit=$?
rm --recursive --force -- "${alias_dir}"
if [[ ${alias_exit} != 0 || -n ${alias_stderr} ]]; then
  printf 'FAIL jobs written as an alias: exit %s, want 0 and no output\n  stderr: %s\n' \
    "${alias_exit}" "${alias_stderr}" >&2
  exit 1
fi
printf 'OK   jobs written as an alias\n'

# @description Run the lint over a temp dir holding ci.yml, a category
# map and optionally a second workflow, and compare the exit status and
# that stderr holds a message.
# @arg $1 scenario label  @arg $2 ci.yml body  @arg $3 category map body
# @arg $4 second workflow body or empty  @arg $5 expected exit status
# @arg $6 text stderr must hold, with DIR standing for the temp dir
function expect_jobs() {
  local -r label="$1" ci="$2" cats="$3" other="$4" want_exit="$5"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  printf '%s' "${ci}" >"${dir}/ci.yml"
  printf '%s' "${cats}" >"${dir}/categories.yml"
  if [[ -n ${other} ]]; then printf '%s' "${other}" >"${dir}/other.yml"; fi
  want="${6//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" CI_WORKFLOW_OVERRIDE="${dir}/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${dir}/categories.yml" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != *"${want}"* ]]; then
    printf 'FAIL %s: exit %s, want %s, and stderr holding %q\n  got: %s\n' \
      "${label}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

# A job key the job list cannot carry is a finding naming the key, in
# ci.yml and in any other workflow: listed a line at a time, a line-break
# key reads as two names that the category map can then match, and an
# empty key reads as none.
readonly REFUSED='holds a job key that is empty, holds a line break or a tab, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read'
readonly ONE_JOB=$'jobs:\n  foo:\n    runs-on: ubuntu-latest\n'
expect_jobs 'ci.yml job key with a line break' \
  $'jobs:\n  "a\\nb":\n    runs-on: ubuntu-latest\n' $'a: A\nb: B\n' '' 1 \
  "DIR/ci.yml: jobs: ${REFUSED} (first: \"a\\nb\")"
expect_jobs 'ci.yml empty job key' \
  $'jobs:\n  foo:\n    runs-on: ubuntu-latest\n  "":\n    runs-on: ubuntu-latest\n' $'foo: A\n' '' 1 \
  "DIR/ci.yml: jobs: ${REFUSED}"
expect_jobs 'ci.yml merge key under jobs' \
  $'x: &j\n  baz:\n    runs-on: ubuntu-latest\njobs:\n  <<: *j\n  foo:\n    runs-on: ubuntu-latest\n' $'foo: A\nbaz: B\n' '' 1 \
  "DIR/ci.yml: jobs: ${REFUSED} (first: \"<<\")"
expect_jobs 'other workflow job key with a line break' \
  "${ONE_JOB}" $'foo: A\nc: C\nd: D\n' $'jobs:\n  "c\\nd":\n    runs-on: ubuntu-latest\n' 1 \
  "DIR/other.yml: jobs: ${REFUSED} (first: \"c\\nd\")"
expect_jobs 'other workflow empty job key' \
  "${ONE_JOB}" $'foo: A\n' $'jobs:\n  "":\n    runs-on: ubuntu-latest\n' 1 \
  "DIR/other.yml: jobs: ${REFUSED} (first: \"\")"
expect_jobs 'other workflow merge key under jobs' \
  "${ONE_JOB}" $'foo: A\n' $'x: &j\n  qux:\n    runs-on: ubuntu-latest\njobs:\n  <<: *j\n' 1 \
  "DIR/other.yml: jobs: ${REFUSED} (first: \"<<\")"

# A merge key whose value is not a mapping cannot be resolved; the refusal
# is the verdict, not a could-not-read exit.
expect_jobs 'ci.yml merge key holding a scalar' \
  $'s: &s 5\njobs:\n  <<: *s\n  z:\n    runs-on: ubuntu-latest\n' $'z: A\n' '' 1 \
  "DIR/ci.yml: jobs: ${REFUSED} (first: \"<<\")"
expect_jobs 'other workflow merge key holding a scalar' \
  "${ONE_JOB}" $'foo: A\n' $'t: &t 5\njobs:\n  <<: *t\n  y:\n    runs-on: ubuntu-latest\n' 1 \
  "DIR/other.yml: jobs: ${REFUSED} (first: \"<<\")"

# @description Run the lint over a ci.yml and a category map and compare
# the exit status and the whole of stderr.
# @arg $1 scenario label  @arg $2 ci.yml body  @arg $3 category map body
# @arg $4 expected stderr, with DIR standing for the temp dir
# @arg $5 optional EXEMPT list, one name per line
function expect_exact() {
  local -r label="$1" ci="$2" cats="$3"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  printf '%s' "${ci}" >"${dir}/ci.yml"
  printf '%s' "${cats}" >"${dir}/categories.yml"
  want="${4//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" CI_WORKFLOW_OVERRIDE="${dir}/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${dir}/categories.yml" EXEMPT_OVERRIDE="${5:-}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != 1 || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want 1, and exactly:\n%s\n  got: %s\n' \
      "${label}" "${got_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

# A refused ci.yml key is one drift entry: the jobs it spells or brings in
# are not read, so the forward check does not report them as well.
readonly ONE_ENTRY='1 ci.yml / categories drift entry/entries'
expect_exact 'ci.yml merge key is one drift entry' \
  $'x: &j\n  baz:\n    runs-on: ubuntu-latest\njobs:\n  <<: *j\n  foo:\n    runs-on: ubuntu-latest\n' $'foo: A\nbaz: B\n' \
  "DIR/ci.yml: jobs: ${REFUSED} (first: \"<<\")"$'\n'"${ONE_ENTRY}"
expect_exact 'ci.yml line-break key is one drift entry' \
  $'jobs:\n  "a\\nb":\n    runs-on: ubuntu-latest\n' $'x: A\n' \
  "DIR/ci.yml: jobs: ${REFUSED} (first: \"a\\nb\")"$'\n'"DIR/categories.yml: category entry x does not match any job in .github/workflows/"$'\n''2 ci.yml / categories drift entry/entries'

# The refused ci.yml's job list is not read, so an EXEMPT entry is not
# held against it.
expect_exact 'ci.yml merge key is one drift entry beside an EXEMPT entry' \
  $'x: &j\n  baz:\n    runs-on: ubuntu-latest\njobs:\n  <<: *j\n  foo:\n    runs-on: ubuntu-latest\n' $'foo: A\nbaz: B\n' \
  "DIR/ci.yml: jobs: ${REFUSED} (first: \"<<\")"$'\n'"${ONE_ENTRY}" $'zzz\n'

# The EXEMPT-versus-category check does not read ci.yml's job list, so a
# refused ci.yml still reports an entry that is already a category key.
expect_exact 'ci.yml refused key beside an EXEMPT entry that is a category key' \
  $'jobs:\n  "lint\\nzz":\n    runs-on: ubuntu-latest\n  build:\n    runs-on: ubuntu-latest\n' $'build: A\n' \
  "DIR/ci.yml: jobs: ${REFUSED} (first: \"lint\\nzz\")"$'\n'"EXEMPT entry build is already a key in DIR/categories.yml"$'\n''2 ci.yml / categories drift entry/entries' \
  $'build\n'

# ci.yml sits in the workflows directory too and is checked once: a
# second pass over it would print its finding twice.
once_dir="$(mktemp --directory)"
printf 'jobs:\n  foo:\n    runs-on: ubuntu-latest\n  "":\n    runs-on: ubuntu-latest\n' >"${once_dir}/ci.yml"
printf 'foo: A\n' >"${once_dir}/categories.yml"
once_stderr="$(WORKFLOWS_DIR_OVERRIDE="${once_dir}" CI_WORKFLOW_OVERRIDE="${once_dir}/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${once_dir}/categories.yml" "${SCRIPT}" 2>&1 >/dev/null)" || true
once_count="$(grep --count --fixed-strings -- "${once_dir}/ci.yml: jobs: ${REFUSED}" <<<"${once_stderr}")" || true
rm --recursive --force -- "${once_dir}"
if [[ ${once_count} != 1 ]]; then
  printf 'FAIL ci.yml finding printed %s times, want 1\n  stderr: %s\n' "${once_count}" "${once_stderr}" >&2
  exit 1
fi
printf 'OK   ci.yml finding printed once\n'

# A merge list inside a job of another workflow is read first mapping
# wins, which also keeps `yq` from printing its warning about the
# default order.
mergelist_dir="$(mktemp --directory)"
printf '%s' "${ONE_JOB}" >"${mergelist_dir}/ci.yml"
printf 'foo: A\nbar: B\n' >"${mergelist_dir}/categories.yml"
printf 'p: &p\n  runs-on: a\nq: &q\n  runs-on: b\njobs:\n  bar:\n    <<: [*p, *q]\n' >"${mergelist_dir}/other.yml"
mergelist_exit=0
mergelist_stderr="$(WORKFLOWS_DIR_OVERRIDE="${mergelist_dir}" CI_WORKFLOW_OVERRIDE="${mergelist_dir}/ci.yml" \
  CATEGORIES_FILE_OVERRIDE="${mergelist_dir}/categories.yml" "${SCRIPT}" 2>&1 >/dev/null)" || mergelist_exit=$?
rm --recursive --force -- "${mergelist_dir}"
if [[ ${mergelist_exit} != 0 || -n ${mergelist_stderr} ]]; then
  printf 'FAIL job merge list: exit %s, want 0 and no output\n  stderr: %s\n' \
    "${mergelist_exit}" "${mergelist_stderr}" >&2
  exit 1
fi
printf 'OK   job merge list\n'

missing_categories_exit=0
missing_categories_stderr="$(env \
  "WORKFLOWS_DIR_OVERRIDE=${FIXTURES}/good" \
  "CI_WORKFLOW_OVERRIDE=${FIXTURES}/good/ci.yml" \
  "CATEGORIES_FILE_OVERRIDE=${FIXTURES}/good/does-not-exist.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || missing_categories_exit=$?
if [[ ${missing_categories_exit} != 2 ]]; then
  printf 'FAIL missing-categories: exit %s, want 2\n  stderr: %s\n' \
    "${missing_categories_exit}" "${missing_categories_stderr}" >&2
  exit 1
fi
if [[ ${missing_categories_stderr} != *"categories file not found"* ]]; then
  printf 'FAIL missing-categories: stderr missing %q\n  got: %s\n' \
    "categories file not found" "${missing_categories_stderr}" >&2
  exit 1
fi
printf 'OK   missing-categories\n'

# --print-exempt is the shared source of the ci-job exemption list for
# scripts/refresh-enforcement-matrix.sh. It must exit 0 and emit exactly
# the list — nothing at all when the list is empty, so that an empty
# stdout means "no exemptions" and a nonzero exit means "unreadable".
function expect_print_exempt() {
  local -r label="$1" override="$2" want="$3"
  local got exit_code=0
  if [[ -n ${override} ]]; then
    got="$(EXEMPT_OVERRIDE="${override}" "${SCRIPT}" --print-exempt)" || exit_code=$?
  else
    got="$("${SCRIPT}" --print-exempt)" || exit_code=$?
  fi
  if [[ ${exit_code} != 0 ]]; then
    printf 'FAIL %s: exit %s, want 0\n' "${label}" "${exit_code}" >&2
    return 1
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL %s: got %q, want %q\n' "${label}" "${got}" "${want}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

expect_print_exempt 'print-exempt: empty list prints nothing' "" ""
expect_print_exempt 'print-exempt: single entry' "aux-sandbox" "aux-sandbox"
expect_print_exempt 'print-exempt: multiple entries, one per line' \
  $'aux-one\naux-two' $'aux-one\naux-two'

# An unrecognized argument exits 2 so a caller that asks for a mode this
# script does not have fails loud instead of reading an empty list.
unknown_arg_exit=0
"${SCRIPT}" --not-a-mode >/dev/null 2>&1 || unknown_arg_exit=$?
if [[ ${unknown_arg_exit} != 2 ]]; then
  printf 'FAIL unknown-argument: exit %s, want 2\n' "${unknown_arg_exit}" >&2
  exit 1
fi
printf 'OK   unknown-argument\n'

printf 'all tests passed\n'
