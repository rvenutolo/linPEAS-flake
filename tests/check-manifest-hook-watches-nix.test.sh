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
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
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
# non-empty) a required stderr substring; records the run's whole
# observable outcome for the cross-scenario discrimination gate.
function expect() {
  local -r name="$1" hooks_dir="$2" scripts_dir="$3"
  local -r want_exit="$4" want_msg="$5"

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  HOOKS_DIR_OVERRIDE="${hooks_dir}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  local got_stderr
  got_stderr="$(cat -- "${stderr_file}")"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${name}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %s)\n' "${name}" "${got_exit}"
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
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
# A manifest-reading hook whose filter contains the text `nix/hooks` in a
# pattern that matches no path under that directory, paired with a covered
# sibling so guard-the-guard stays quiet and a clean exit can only mean the
# decoy was accepted. ${1}=dir.
function write_hook_names_not_matches() {
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

  fixture-decoy-filter-fresh = {
    enable = true;
    name = "fixture-decoy-filter-fresh";
    description = "Fixture manifest-reading hook whose filter only names nix/hooks.";
    entry = "bash scripts/refresh-fixture-table.sh --check";
    files = "^docs/nix/hooks-notes\.md$";
    pass_filenames = false;
    language = "system";
  };
}
EOF
}

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

# Write the nix module a fixture attribute-evaluating hook builds from.
# ${1}=tree root, ${2}=`manifest` for a module that reads the flake hook
# manifest, anything else for one that does not. Both assign the same
# attribute, so the pair isolates the manifest reference as the only thing
# that makes the hook owe a `nix/hooks` filter entry.
function write_attr_module() {
  local -r root="$1" mode="$2"
  mkdir --parents -- "${root}/nix"
  if [[ ${mode} == 'manifest' ]]; then
    cat >"${root}/nix/attr-source.nix" <<'EOF'
{
  perSystem =
    { config, pkgs, ... }:
    {
      checks.fixtureCheck = pkgs.runCommandLocal "fixture-check" { } ''
        printf '%s' '${builtins.toJSON config.devTooling.preCommitHooks}' >"$out"
      '';
    };
}
EOF
  else
    cat >"${root}/nix/attr-source.nix" <<'EOF'
{
  perSystem =
    { pkgs, ... }:
    {
      checks.fixtureCheck = pkgs.runCommandLocal "fixture-check" { } ''
        printf 'fixture attribute' >"$out"
      '';
    };
}
EOF
  fi
}

# Write a fixture tree carrying a hook that builds a flake attribute
# directly — the shape the real attribute-evaluating hook uses, which names
# no `scripts/*.sh` at all and so is invisible to the script-keyed lookup.
#
# ${1}=tree root, ${2}=the attribute hook's files-filter value, ${3}=the
# assigning module's mode, as `write_attr_module` takes it, ${4}=`companion`
# to add a covered manifest-reading script hook alongside. The companion
# keeps the subject-count guard quiet on its own, so a clean exit can only
# mean the attribute hook went unevaluated; omitting it leaves a tree whose
# only subject is the attribute hook, which is what a subject count that
# spans both classes has to accept.
function write_attr_tree() {
  local -r root="$1" files="$2" mode="$3" companion="$4"
  mkdir --parents -- "${root}/scripts" "${root}/hooks"
  write_attr_module "${root}" "${mode}"
  if [[ ${companion} == 'companion' ]]; then
    write_manifest_script "${root}/scripts"
    write_hook "${root}/hooks" '^(flake\.nix|nix/hooks/.*\.nix)$'
  fi
  cat >"${root}/hooks/attr.nix" <<EOF
{
  fixture-attr-check = {
    enable = true;
    name = "fixture-attr-check";
    description = "Fixture hook that builds a flake attribute directly.";
    entry = "nix build --no-link .#checks.\${pkgs.stdenv.hostPlatform.system}.fixtureCheck";
    files = "${files}";
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

  # (d2) BAD: a filter that names nix/hooks inside a pattern that can never
  # match a path under it. Coverage is decided by matching the regex, so a
  # filter is judged on the paths it re-triggers on rather than on the text
  # it happens to contain.
  write_manifest_script "${work}/bad-names-not-matches/scripts"
  write_hook_names_not_matches "${work}/bad-names-not-matches/hooks"
  expect 'bad: a filter naming nix/hooks without matching it is reported' \
    "${work}/bad-names-not-matches/hooks" "${work}/bad-names-not-matches/scripts" 1 \
    'hook fixture-decoy-filter-fresh: files filter missing nix/hooks'

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
    "${work}/empty/hooks" "${work}/empty/scripts" 1 \
    'no manifest-reading or attribute-building hook blocks found'

  # (f) BAD: a hook whose entry builds a flake attribute directly, where the
  # module assigning that attribute reads the hook manifest. Editing a hook
  # definition then changes what the attribute builds, yet the filter never
  # re-triggers the hook that builds it. A lint keyed only on script tokens
  # skips this block entirely, and the covered companion hook keeps the
  # subject-count guard quiet, so it reports full coverage.
  write_attr_tree "${work}/attr-bad" '^(flake\.nix|nix/attr-source\.nix)$' \
    manifest companion
  expect 'bad: an attribute-building hook reaching the manifest needs nix/hooks' \
    "${work}/attr-bad/hooks" "${work}/attr-bad/scripts" 1 \
    'hook fixture-attr-check: files filter missing nix/hooks (builds checks.fixtureCheck, assigned by nix/attr-source.nix which reads the hook manifest)'

  # (g) GOOD: the same hook with nix/hooks in its filter.
  write_attr_tree "${work}/attr-good" \
    '^(flake\.nix|nix/hooks/.*\.nix|nix/attr-source\.nix)$' manifest companion
  expect 'good: an attribute-building hook watching nix/hooks passes' \
    "${work}/attr-good/hooks" "${work}/attr-good/scripts" 0 ''

  # (h) GOOD: an attribute hook standing alone, whose assigning module reads
  # no manifest. Two things must hold at once: the manifest never decides
  # what this attribute builds, so no nix/hooks entry is owed — the shape the
  # repo's own attribute-evaluating hook has, and without it a rule demanding
  # nix/hooks of every attribute-building hook would look correct — and the
  # attribute hook is the tree's only subject, so a subject count that still
  # recognised the script class alone would trip its guard here.
  write_attr_tree "${work}/attr-plain" '^(flake\.nix|nix/attr-source\.nix)$' \
    plain alone
  expect 'good: a lone attribute-building hook whose sources skip the manifest passes' \
    "${work}/attr-plain/hooks" "${work}/attr-plain/scripts" 0 ''

  # A silent exit 0 carries no output naming which subject class it
  # verified — the guard prints nothing on success by design — so a clean
  # run over a script-referencing hook and a clean run over either shape of
  # attribute-building hook are indistinguishable outcomes even though the
  # three fixtures exercise disjoint discovery paths (Step 1 script lookup
  # vs Step 2/3 attrpath parse, with or without a manifest-reading
  # assigner).
  harness_assert_parity_exempt \
    'good: files containing nix/hooks passes' \
    'good: an attribute-building hook watching nix/hooks passes' \
    'both are a silent exit 0; the script-lookup and attrpath-parse paths that produced it are not distinguishable from an empty diagnostic stream'
  harness_assert_parity_exempt \
    'good: files containing nix/hooks passes' \
    'good: a lone attribute-building hook whose sources skip the manifest passes' \
    'both are a silent exit 0; the script-lookup and attrpath-parse paths that produced it are not distinguishable from an empty diagnostic stream'
  harness_assert_parity_exempt \
    'good: an attribute-building hook watching nix/hooks passes' \
    'good: a lone attribute-building hook whose sources skip the manifest passes' \
    'both are a silent exit 0; whether the assigning module reads the hook manifest changes nothing observable when the filter already covers what the block needs'

  # The single-mention and double-mention hook entries name the same
  # offending hook for the same single reason, so the reported violation
  # text is necessarily identical — the difference under test is in the
  # Step 2 script-list split (IFS=' ' vs the global newline+tab IFS), which
  # has no observable trace once both splits land on the same script token.
  harness_assert_parity_exempt \
    'bad: files missing nix/hooks fails and names hook' \
    'bad: a hook naming its script twice still fails and names the hook' \
    'both report the same single hook for the same single reason; the script-list split under test only diverges on whether the token is found at all, not on what a found token reports'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
