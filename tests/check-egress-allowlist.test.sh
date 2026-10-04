#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-egress-allowlist.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/egress-allowlist"
readonly DECLARATION_FIXTURES="${REPO_ROOT}/tests/fixtures/egress-allowlist-declaration"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
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

expect good.yml 0 ""
expect bad-codeql-missing-release-assets.yml 1 "release-assets.githubusercontent.com"
expect bad-trivy-missing-ghcr-fallback.yml 1 "ghcr.io"
expect bad-trivy-missing-get-trivy.yml 1 "get.trivy.dev"
expect bad-release-asset-download.yml 1 "release-assets.githubusercontent.com"
expect bad-sign-missing-timestamp.yml 1 "timestamp.sigstore.dev"
expect bad-sigstore-partial-set.yml 1 "incomplete sigstore host set"
expect bad-verify-carries-timestamp.yml 1 "timestamp.sigstore.dev"
expect bad-denylisted-host.yml 1 "cafe.github.com"
expect bad-flakehub-action.yml 1 "flakehub-cache-action"
expect bad-sbom-missing-raw-githubusercontent.yml 1 "raw.githubusercontent.com"
expect bad-gh-release-upload-missing-uploads.yml 1 "uploads.github.com"
expect bad-verify-missing-tuf.yml 1 "verification requires at least tuf-repo-cdn.sigstore.dev"
expect bad-sbom-missing-get-anchore.yml 1 "get.anchore.io"
expect bad-scan-action-missing-get-anchore.yml 1 "get.anchore.io"
expect bad-scan-action-missing-grype-anchore.yml 1 "grype.anchore.io"
expect bad-scan-action-missing-raw-githubusercontent.yml 1 "raw.githubusercontent.com"
expect bad-ghcr-missing-pkg-containers.yml 1 "pkg-containers.githubusercontent.com"
expect bad-dockerhub-missing-auth.yml 1 "auth.docker.io"
expect bad-dockerhub-missing-registry.yml 1 "registry-1.docker.io"
expect bad-dockerhub-missing-cloudfront.yml 1 "production.cloudfront.docker.com"
expect bad-dockerhub-push-missing-index.yml 1 "index.docker.io"
expect bad-buildx-imagetools-create-missing-index.yml 1 "index.docker.io"
expect bad-dockerhub-description-missing-hub.yml 1 "hub.docker.com"
expect bad-scorecard-missing-scorecards-api.yml 1 "api.securityscorecards.dev"
expect bad-scorecard-missing-osv.yml 1 "api.osv.dev"
expect bad-scorecard-missing-deps-dev.yml 1 "api.deps.dev"
expect bad-attestation-verify-missing-tuf.yml 1 "tuf-repo.github.com"

# The mirror of assertion 7: a job that runs the setup-nix composite must carry
# both nix hosts. Proven per host rather than all-or-nothing — the second
# fixture carries cache.nixos.org and is still a violation, and its single
# violation count is what proves the rule did not blanket-demand both hosts
# from a job already carrying one.
expect bad-nix-setup-nix-missing-both-hosts.yml 1 "does not allowlist cache.nixos.org"
expect bad-nix-setup-nix-missing-both-hosts.yml 1 "does not allowlist releases.nixos.org"
expect bad-nix-setup-nix-missing-releases-host.yml 1 "does not allowlist releases.nixos.org"
expect bad-nix-setup-nix-missing-releases-host.yml 1 "1 egress-allowlist violation(s)"
# Boundary discipline for the same rule: a composite whose path merely starts
# with the setup-nix path is a different action, so it is not required to carry
# the nix hosts. A bare substring test would fail this fixture.
expect good-nix-lookalike-without-hosts.yml 0 ""

# A workflow yq cannot parse must fail loud, not empty the scan silently.
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# Every job carrying the notify composite is bound to the declared host set.
# The pure three-step shape must match it exactly; a job with extra steps may
# carry more, but never less.
expect good-notify-parity.yml 0 ""
expect bad-notify-missing-host.yml 1 "github.com:443"
expect bad-notify-extra-host.yml 1 "cache.nixos.org"
expect good-notify-sha-pinned.yml 0 ""
# The SHA-pinned self-reference has to be discovered, not merely tolerated: a
# clean run over the matching pinned job says nothing about whether the job
# was read at all, so the pinned form gets a violating job of its own.
expect bad-notify-sha-pinned-missing-host.yml 1 "github.com:443"
expect good-notify-extended.yml 0 ""
expect bad-notify-extended-missing.yml 1 "api.github.com:443"

# The parity rule is worth exactly as much as the declaration it reads, so a
# declaration that is unreadable or that names no host is a could-not-run:
# with an empty comparison set every notify job scores clean whatever its
# allowlist holds, and the run would report that as a checked tree. Exit 2,
# not 1 — nothing was evaluated, so this is not drift.
function expect_declaration() {
  local -r name="$1" declaration="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(NOTIFY_EGRESS_DECLARATION_OVERRIDE="${declaration}" \
    WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER=good-notify-parity.yml \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != 2 ]]; then
    printf 'FAIL %s: exit %s, want 2\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${name}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# Absent: the diagnostic has to name the file it could not read, otherwise an
# operator cannot tell which path the run resolved.
expect_declaration declaration-absent "${DECLARATION_FIXTURES}/absent.txt" "absent.txt"
# Present and readable, but comments and blanks only. A file that exists is
# not a declaration that declares anything, so the host count is what the
# guard keys on rather than the file's existence.
expect_declaration declaration-zero-hosts "${DECLARATION_FIXTURES}/comments-only.txt" "read 0 host(s)"

# Zero notify jobs on an unfiltered scan is a broken discovery predicate, not
# a clean tree: assert the breadth the rule claims to have checked. Exit 2,
# not 1 — this is the repo's "could not run" code, and check-guard-exit-code.sh
# enforces the split.
got_exit=0
got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-notify" \
  "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
if [[ ${got_exit} != 2 || ${got_stderr} != *"0 notify job"* ]]; then
  printf 'FAIL zero-notify-discovery: exit %s\n  stderr: %s\n' "${got_exit}" "${got_stderr}" >&2
  exit 1
fi
printf 'OK   zero-notify-discovery\n'

# ...and the documented override suppresses it.
LINT_ALLOW_EMPTY_SCAN=1 WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-notify" \
  "${SCRIPT}" >/dev/null 2>&1 ||
  {
    printf 'FAIL zero-notify-discovery-override\n' >&2
    exit 1
  }
printf 'OK   zero-notify-discovery-override\n'

# Assertion 7: nix-host reachability. A job whose allowlist carries
# cache.nixos.org or releases.nixos.org must reach nix through the
# setup-nix composite, a run: block invoking a nix subcommand, or an
# in-job `# egress-nix-exempt: <reason>` marker; where the job reaches no
# nix tooling, an empty-reason marker is rejected, and a marker on a job
# carrying neither host is reported as stale rather than silently
# tolerated.
expect good-nix-setup-nix.yml 0 ""
expect good-nix-run-invocation.yml 0 ""
expect bad-nix-neither.yml 1 "reaches no nix tooling"
# A same-prefixed but different composite (`setup-nix-cache-thing`) must not
# satisfy the setup-nix arm: the arm matches the composite path itself, not
# any path that merely starts with it.
expect bad-nix-setup-nix-lookalike.yml 1 "reaches no nix tooling"
expect good-nix-exempt.yml 0 ""
expect bad-nix-exempt-empty-reason.yml 1 "no reason"
expect bad-nix-stale-marker.yml 1 "stale"

# Breadth: zero jobs carrying either nix host on an unfiltered scan is a
# broken discovery predicate, not a clean tree — same convention, and same
# could-not-run exit code, as the zero-notify-discovery guard above. The
# fixture workflow carries a notify job (so assertion 6's breadth passes)
# but no nix host at all, isolating assertion 7's own guard.
got_exit=0
got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-nix-host" \
  "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
if [[ ${got_exit} != 2 || ${got_stderr} != *"0 job(s) carrying cache.nixos.org/releases.nixos.org"* ]]; then
  printf 'FAIL zero-nix-host-discovery: exit %s\n  stderr: %s\n' "${got_exit}" "${got_stderr}" >&2
  exit 1
fi
printf 'OK   zero-nix-host-discovery\n'

# ...and the documented override suppresses it.
LINT_ALLOW_EMPTY_SCAN=1 WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/tests/fixtures/egress-allowlist-no-nix-host" \
  "${SCRIPT}" >/dev/null 2>&1 ||
  {
    printf 'FAIL zero-nix-host-discovery-override\n' >&2
    exit 1
  }
printf 'OK   zero-nix-host-discovery-override\n'

# A job key is workflow text, and the end of the job before it is computed
# from the key's start line. The key must never reach the arithmetic as
# text: bash 5.1 expands a command substitution held in an associative
# subscript there, and ran this one. The devShell's bash does not, so on
# it this scenario holds the outcome rather than telling the two forms
# apart. The workflow is built at run time so the marker lands in this
# run's own directory.
key_dir="$(mktemp --directory)"
trap 'rm --recursive --force -- "${key_dir}"' EXIT
mkdir -- "${key_dir}/wf"
cat >"${key_dir}/wf/key.yml" <<EOF
name: job-key-in-arithmetic
on:
  workflow_dispatch: {}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3
        with:
          egress-policy: block
          allowed-endpoints: >
            cache.nixos.org:443
      - run: nix build .#linpeas
  "a\$(>${key_dir}/MARKER)":
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3
        with:
          egress-policy: block
          allowed-endpoints: >
            api.github.com:443
      - run: echo PAYLOAD_RAN
EOF
got_exit=0
got_stdout="$(WORKFLOWS_DIR_OVERRIDE="${key_dir}/wf" WORKFLOW_FILE_FILTER=key.yml \
  "${SCRIPT}" 2>"${key_dir}/stderr")" || got_exit=$?
want_stdout=$'0 notify job(s) checked against the declared egress allowlist\n1 nix-host job(s) checked for reachability'
if [[ -e "${key_dir}/MARKER" ]]; then
  printf 'FAIL job-key-in-arithmetic: the command in the job key ran\n' >&2
  exit 1
fi
if [[ ${got_exit} != 0 || ${got_stdout} != "${want_stdout}" || -s "${key_dir}/stderr" ]]; then
  printf 'FAIL job-key-in-arithmetic: exit %s\n  stdout: %s\n  stderr: %s\n' \
    "${got_exit}" "${got_stdout}" "$(<"${key_dir}/stderr")" >&2
  exit 1
fi
printf 'OK   job-key-in-arithmetic\n'

# The job line read is one tab-separated row per key, key first. A key
# holding a tab or a line break splits into rows of its own choosing,
# and the range arithmetic evaluated the text that landed in the line
# field: the subscript ran its command, the run dropped the nix job and
# exited 0. A key shaped `b<TAB>999<LF>c` gives well-formed rows and
# moves a job's range instead. Each such key is a counted finding naming
# the key, with nothing run and nothing else read from the file: the
# build job downloads a release asset its allowlist omits, a violation
# only a further read would report. An empty key's own job is not read
# (the job list skips an empty name, as on main), and the same violation
# shows the build job still is.
# @arg $1 scenario name, which also names its marker file  @arg $2 the
# job key, as a YAML double-quoted body  @arg $3 the expected finding
# line, after the file name; it and the tally are the whole of stderr
# @arg $4 `raw` to write the key as given rather than double-quoted
function expect_job_key() {
  local -r name="$1" key="$2" want_line="$3" form="${4:-}"
  local got_exit=0 got_stderr key_text="\"$2\""
  [[ ${form} == raw ]] && key_text="${key}"
  cat >"${key_dir}/wf/${name}.yml" <<EOF
name: ${name}
on:
  workflow_dispatch: {}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3
        with:
          egress-policy: block
          allowed-endpoints: >
            cache.nixos.org:443
      - run: nix build .#linpeas
      - run: curl --location --remote-name https://github.com/o/r/releases/download/v1/a
  ${key_text}:
    runs-on: ubuntu-latest
    steps:
      - run: echo PAYLOAD_RAN
EOF
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${key_dir}/wf" WORKFLOW_FILE_FILTER="${name}.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ -e "${key_dir}/${name}.marker" ]]; then
    printf 'FAIL %s: the command in the job key ran\n' "${name}" >&2
    exit 1
  fi
  if [[ ${got_exit} != 1 || ${got_stderr} != "${key_dir}/wf/${name}.yml: ${want_line}"$'\n1 egress-allowlist violation(s)' ]]; then
    printf 'FAIL %s: exit %s, want 1 and %q\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_line}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly odd_key='holds a tab or a line break, which the job line read cannot carry'
expect_job_key job-key-tab-forges-line \
  "b\\tBASH_VERSINFO[\$(>${key_dir}/job-key-tab-forges-line.marker)]" \
  "job key \"b\\tBASH_VERSINFO[\$(>${key_dir}/job-key-tab-forges-line.marker)]\" ${odd_key}"
expect_job_key job-key-line-break-forges-line \
  "b\\nc\\tBASH_VERSINFO[\$(>${key_dir}/job-key-line-break-forges-line.marker)]" \
  "job key \"b\\nc\\tBASH_VERSINFO[\$(>${key_dir}/job-key-line-break-forges-line.marker)]\" ${odd_key}"
expect_job_key job-key-tab-digits-forges-line 'b\t5' "job key \"b\\t5\" ${odd_key}"
expect_job_key job-key-digits-line-break-forges-line '7\n5' "job key \"7\\n5\" ${odd_key}"
expect_job_key job-key-leading-line-break '\nx' "job key \"\\nx\" ${odd_key}"
expect_job_key job-key-forges-whole-rows 'b\t999\nc' "job key \"b\\t999\\nc\" ${odd_key}"
readonly release_finding="job 'build' downloads a GitHub release asset but does not allowlist release-assets.githubusercontent.com (the github.com redirect is unconditional)"
expect_job_key job-key-empty '' "${release_finding}"
# A key is tested whatever its tag: an integer key is read, and a tag
# on a key holding a tab does not hide it.
expect_job_key job-key-integer 5 "${release_finding}" raw
expect_job_key job-key-tagged-tab '!!int "b\t6"' "job key \"b\\t6\" ${odd_key}" raw
# Two such keys: the finding names the first.
expect_job_key job-key-two-odd $'"b\\t7": {}\n  "c\\t8"' "job key \"b\\t7\" ${odd_key}" raw

# A job key is data, never expression text. Each key below closes a
# quoted segment if spliced into a `yq` expression: it would end the
# read early, read the clean decoy job instead, or print an environment
# variable or a file through `error()`. Read as data, every one names
# its own job and its denylisted host.
printf 'FILE_READ_MARK\n' >"${key_dir}/probe.txt"
# @arg $1 scenario name  @arg $2 the job key, written single-quoted
function expect_spliced_key() {
  local -r name="$1" key="$2"
  local got_exit=0 got_stderr want
  cat >"${key_dir}/wf/${name}.yml" <<EOF
name: ${name}
on:
  workflow_dispatch: {}
jobs:
  '${key//\'/\'\'}':
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3
        with:
          egress-policy: block
          allowed-endpoints: >
            api.github.com:443
            cafe.github.com:443
  decoy:
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3
        with:
          egress-policy: block
          allowed-endpoints: >
            api.github.com:443
EOF
  got_stderr="$(PROBE=PAYLOAD_RAN PROBE_FILE="${key_dir}/probe.txt" WORKFLOWS_DIR_OVERRIDE="${key_dir}/wf" WORKFLOW_FILE_FILTER="${name}.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  want="${key_dir}/wf/${name}.yml: job '${key}' allowlists cafe.github.com, which no tool in this repo reaches"$'\n1 egress-allowlist violation(s)'
  if [[ ${got_exit} != 1 || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want 1\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
expect_spliced_key job-key-reads-decoy 'x" // .jobs."decoy'
expect_spliced_key job-key-reads-nothing 'x" | select(false) | ."y'
expect_spliced_key job-key-reads-env 'x" | error(strenv(PROBE)) | ."y'
expect_spliced_key job-key-reads-file 'x" | error(load_str(strenv(PROBE_FILE))) | ."y'
expect_spliced_key job-key-quote 'k"x'
expect_spliced_key job-key-backslash 'k\x'

# A key that prints as an empty name still opens a block, so it ends the
# job before it. Here the job before it carries a nix host but runs no
# nix, and the empty-named job's block holds an exempt marker: a range
# that ran on past the empty-named key read that marker as the earlier
# job's and passed it.
# @arg $1 scenario name  @arg $2 the key, written as given
function expect_empty_name_ends_range() {
  local -r name="$1" key="$2"
  local got_exit=0 got_stderr want
  cat >"${key_dir}/wf/${name}.yml" <<EOF
name: ${name}
on:
  workflow_dispatch: {}
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3
        with:
          egress-policy: block
          allowed-endpoints: >
            cache.nixos.org:443
      - run: echo PAYLOAD_RAN
  ${key}:
    # egress-nix-exempt: belongs to the job with the empty name
    runs-on: ubuntu-latest
    steps:
      - run: echo PAYLOAD_RAN
EOF
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${key_dir}/wf" WORKFLOW_FILE_FILTER="${name}.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  want="${key_dir}/wf/${name}.yml: job 'build' allowlists cache.nixos.org/releases.nixos.org but reaches no nix tooling — neither ./.github/actions/setup-nix nor a run: nix invocation is detected, and no '# egress-nix-exempt: <reason>' marker justifies it"$'\n1 egress-allowlist violation(s)'
  if [[ ${got_exit} != 1 || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
expect_empty_name_ends_range job-key-null-ends-range null
expect_empty_name_ends_range job-key-empty-ends-range '""'

# The range itself, for a job that is not the last: a marker inside the
# first job's block exempts it.
# @arg $1 scenario name  @arg $2 the build job's marker line, or empty
# @arg $3 the comment on the next job's key line, or empty
# @arg $4 the whole expected stderr, after any file name prefix
function expect_range() {
  local -r name="$1" own_marker="$2" key_comment="$3" finding="$4"
  local got_exit=0 got_stderr want_exit=0 want=''
  [[ -n ${finding} ]] && want_exit=1
  cat >"${key_dir}/wf/${name}.yml" <<EOF
name: ${name}
on:
  workflow_dispatch: {}
jobs:
  build:
${own_marker}
    runs-on: ubuntu-latest
    steps:
      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3
        with:
          egress-policy: block
          allowed-endpoints: >
            cache.nixos.org:443
      - run: echo PAYLOAD_RAN
  other: ${key_comment}
    runs-on: ubuntu-latest
    steps:
      - run: echo PAYLOAD_RAN
EOF
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${key_dir}/wf" WORKFLOW_FILE_FILTER="${name}.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  [[ -n ${finding} ]] && want="${key_dir}/wf/${name}.yml: ${finding}"$'\n1 egress-allowlist violation(s)'
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
expect_range job-range-holds-own-marker '    # egress-nix-exempt: reaches nix through a script' '' ''

# The row check is the range arithmetic's own guard. The key test above
# leaves yq no way to print a row it fails, so a yq stub answers the job
# line read with the rows in STUB_ROWS, and fails the key read when
# STUB_FAIL_KEYS is set; every other read goes to the real yq.
real_yq="$(command -v yq)"
mkdir -- "${key_dir}/stub"
# shellcheck disable=SC2016 # the shim's own text
printf '%s\n' "#!${BASH}" \
  'for a in "$@"; do' \
  '  if [[ -n ${STUB_FAIL_KEYS:-} && ${a} == *"test("* ]]; then exit 7; fi' \
  '  if [[ ${a} == *"[., line]"* ]]; then printf "%s\n" "${STUB_ROWS}"; exit 0; fi' \
  'done' \
  "exec ${real_yq@Q} \"\$@\"" >"${key_dir}/stub/yq"
chmod +x -- "${key_dir}/stub/yq"
cp -- "${key_dir}/wf/job-key-empty.yml" "${key_dir}/wf/stubbed.yml"
# @arg $1 scenario name  @arg $2 STUB_ROWS  @arg $3 STUB_FAIL_KEYS
# @arg $4 the expected finding line, after the file name
function expect_stubbed() {
  local -r name="$1" rows="$2" fail_keys="$3" want_line="$4"
  local got_exit=0 got_stderr
  got_stderr="$(PATH="${key_dir}/stub:${PATH}" STUB_ROWS="${rows}" STUB_FAIL_KEYS="${fail_keys}" \
    WORKFLOWS_DIR_OVERRIDE="${key_dir}/wf" WORKFLOW_FILE_FILTER=stubbed.yml \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != 1 || ${got_stderr} != "${key_dir}/wf/stubbed.yml: ${want_line}"$'\n1 egress-allowlist violation(s)' ]]; then
    printf 'FAIL %s: exit %s, want 1 and %q\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_line}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly bad_row='a job line row is not a key and a line number:'
expect_stubbed job-line-row-word $'build\t5\nbuild\tX' '' "${bad_row} \$'build\\tX'"
expect_stubbed job-line-row-no-tab $'build\t5\n7' '' "${bad_row} '7'"
expect_stubbed job-line-row-empty $'build\t5\n\nbuild\t9' '' "${bad_row} ''"
expect_stubbed job-line-row-digits-then-text $'build\t5\nbuild\t5x' '' "${bad_row} \$'build\\t5x'"
expect_stubbed job-line-row-text-then-digits $'build\t5\nbuild\tx5' '' "${bad_row} \$'build\\tx5'"
expect_stubbed job-line-row-ten-digits $'build\t5\nbuild\t1234567890' '' "${bad_row} \$'build\\t1234567890'"
expect_stubbed job-key-read-fails '' 1 'could not evaluate job keys with yq (malformed?)'

# LIVE: the real tree must satisfy assertion 7, and the run must have
# actually scanned something. The assertion checks the printed count is
# nonzero rather than pinning it to today's exact job count, which would
# turn every unrelated job addition into a spurious fixture failure — the
# same convention tests/check-payload-source-helper.test.sh uses for its
# own live-tree breadth assertion. A regression that narrows the
# discovery predicate without flipping any fixture above is exactly what
# this count catches instead.
live_out=""
live_exit=0
live_out="$(WORKFLOWS_DIR_OVERRIDE="${REPO_ROOT}/.github/workflows" "${SCRIPT}" 2>&1)" || live_exit=$?
if [[ ${live_exit} != 0 ]]; then
  printf 'FAIL live-nix-host-tree: expected exit 0, got %s\n  output: %s\n' "${live_exit}" "${live_out}" >&2
  exit 1
fi
live_count="$(grep -oE '[0-9]+ nix-host job\(s\) checked' <<<"${live_out}" | grep -oE '^[0-9]+' || true)"
if [[ -z ${live_count} || ${live_count} -eq 0 ]]; then
  printf 'FAIL live-nix-host-tree: 0 nix-host jobs checked\n  output: %s\n' "${live_out}" >&2
  exit 1
fi
printf 'OK   live-nix-host-tree (%s job(s) checked)\n' "${live_count}"

printf 'all tests passed\n'
