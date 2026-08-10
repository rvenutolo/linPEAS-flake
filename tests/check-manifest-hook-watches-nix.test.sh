#!/usr/bin/env bash
# tests/check-manifest-hook-watches-nix.test.sh
#
# Spec-driven harness for scripts/check-manifest-hook-watches-nix.sh.
# Drives the guard against fixture nix/hooks + scripts dirs via the
# HOOKS_DIR_OVERRIDE + SCRIPTS_DIR_OVERRIDE env vars.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-manifest-hook-watches-nix.sh"

failures=0

# Declared top-level so the EXIT trap can reach across function boundaries.
work=''
function cleanup() {
  if [[ -n ${work:-} && -d ${work} ]]; then
    rm --recursive --force -- "${work}"
  fi
}
trap cleanup EXIT

# Run the guard against a fixture pair, asserting exit code and (when
# non-empty) a required stderr substring.
function expect() {
  local -r name="$1" hooks_dir="$2" scripts_dir="$3"
  local -r want_exit="$4" want_msg="$5"
  local got_exit=0 got_stderr
  got_stderr="$(HOOKS_DIR_OVERRIDE="${hooks_dir}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${name}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'PASS: %s (exit %s)\n' "${name}" "${got_exit}"
}

# Write a fixture scripts/ dir containing a manifest-reading script.
function write_manifest_script() {
  local -r dir="$1"
  mkdir --parents -- "${dir}"
  cat >"${dir}/refresh-fixture-table.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# Reads the flake hook manifest.
nix eval --json ".#devTooling.${sys}.preCommitHooks"
EOF
}

# Write a fixture nix/hooks/foo.nix with one hook block running the
# fixture manifest script. ${1}=dir, ${2}=files-filter string value.
function write_hook() {
  local -r dir="$1" files="$2"
  mkdir --parents -- "${dir}"
  cat >"${dir}/foo.nix" <<EOF
{
  fixture-table-fresh = {
    enable = true;
    name = "fixture-table-fresh";
    description = "Fixture manifest-reading hook.";
    entry = "bash scripts/refresh-fixture-table.sh --check";
    files = "${files}";
    pass_filenames = false;
    language = "system";
  };
}
EOF
}

# Write a fixture nix/hooks/foo.nix whose hook block names its manifest
# script twice — the house shape every freshness hook uses (a `[[ ! -f
# scripts/foo.sh ]]` guard plus an `exec ... scripts/foo.sh` call).
# ${1}=dir, ${2}=files-filter string value.
function write_hook_two_mention() {
  local -r dir="$1" files="$2"
  mkdir --parents -- "${dir}"
  cat >"${dir}/foo.nix" <<EOF
{
  fixture-table-fresh = {
    enable = true;
    name = "fixture-table-fresh";
    description = "Fixture manifest-reading hook.";
    entry = "if [[ ! -f scripts/refresh-fixture-table.sh ]]; then exit 0; fi; exec bash scripts/refresh-fixture-table.sh --check";
    files = "${files}";
    pass_filenames = false;
    language = "system";
  };
}
EOF
}

# Write a fixture nix/hooks/foo.nix with two hook blocks, both running the
# fixture manifest script: a covered one that watches nix/hooks, and one
# whose files filter is the empty string. The covered block keeps the
# guard-the-guard quiet, so a clean exit can only mean the empty-filter
# block went unevaluated. ${1}=dir.
function write_hook_empty_files() {
  local -r dir="$1"
  mkdir --parents -- "${dir}"
  cat >"${dir}/foo.nix" <<'EOF'
{
  fixture-table-fresh = {
    enable = true;
    name = "fixture-table-fresh";
    description = "Fixture manifest-reading hook watching nix/hooks.";
    entry = "bash scripts/refresh-fixture-table.sh --check";
    files = "^(flake\.nix|nix/hooks/.*\.nix)$";
    pass_filenames = false;
    language = "system";
  };

  fixture-empty-filter-fresh = {
    enable = true;
    name = "fixture-empty-filter-fresh";
    description = "Fixture manifest-reading hook with an empty files filter.";
    entry = "bash scripts/refresh-fixture-table.sh --check";
    files = "";
    pass_filenames = false;
    language = "system";
  };
}
EOF
}

function main() {
  work="$(mktemp --directory)"

  # (a) BAD: manifest-reading hook whose files lacks nix/hooks → exit 1,
  # naming the hook on stderr.
  write_manifest_script "${work}/bad/scripts"
  write_hook "${work}/bad/hooks" '^(flake\.nix|docs/development/git\.md)$'
  expect 'bad: files missing nix/hooks fails and names hook' \
    "${work}/bad/hooks" "${work}/bad/scripts" 1 'hook fixture-table-fresh'

  # (b) GOOD: same hook whose files includes nix/hooks → exit 0.
  write_manifest_script "${work}/good/scripts"
  write_hook "${work}/good/hooks" '^(flake\.nix|nix/hooks/.*\.nix|docs/development/git\.md)$'
  expect 'good: files containing nix/hooks passes' \
    "${work}/good/hooks" "${work}/good/scripts" 0 ''

  # (c) BAD: the hook entry names its manifest-reading script twice (the
  # real house shape), and files omits nix/hooks. Under the global
  # newline+tab IFS, splitting the entry's script list without an explicit
  # space split leaves the two mentions as one unsplittable token, the
  # manifest_scripts lookup misses it, and the block is skipped with no
  # output — this case must still fail and name the hook.
  write_manifest_script "${work}/bad-two-mention/scripts"
  write_hook_two_mention "${work}/bad-two-mention/hooks" \
    '^(flake\.nix|docs/development/git\.md)$'
  expect 'bad: a hook naming its script twice still fails and names the hook' \
    "${work}/bad-two-mention/hooks" "${work}/bad-two-mention/scripts" 1 \
    'hook fixture-table-fresh'

  # (d) BAD: a manifest-reading hook whose files filter is the empty string
  # still omits nix/hooks, so it must be reported by name. A record whose
  # middle field is empty puts two field delimiters back to back, and a
  # delimiter that bash's `read` treats as IFS whitespace would collapse
  # them — shifting the script list into the files field and dropping the
  # block from evaluation entirely. The sibling covered block in the same
  # fixture keeps guard-the-guard quiet, so a clean exit here can only mean
  # the empty-filter block was never evaluated.
  write_manifest_script "${work}/bad-empty-files/scripts"
  write_hook_empty_files "${work}/bad-empty-files/hooks"
  expect 'bad: an empty files filter is still reported as missing nix/hooks' \
    "${work}/bad-empty-files/hooks" "${work}/bad-empty-files/scripts" 1 \
    'hook fixture-empty-filter-fresh: files filter missing nix/hooks'

  # (e) EMPTY: no manifest-reading hook at all → guard-the-guard non-zero.
  mkdir --parents -- "${work}/empty/scripts" "${work}/empty/hooks"
  cat >"${work}/empty/hooks/bar.nix" <<'EOF'
{
  some-other-hook = {
    enable = true;
    name = "some-other-hook";
    entry = "bash scripts/check-something-else.sh";
    files = "^scripts/.*\.sh$";
    pass_filenames = false;
    language = "system";
  };
}
EOF
  expect 'empty: zero manifest hooks trips guard-the-guard' \
    "${work}/empty/hooks" "${work}/empty/scripts" 1 'no manifest-reading hook blocks found'

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
