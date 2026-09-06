#!/usr/bin/env bash
# collect-ground-truth.sh — bundled with the docs-correctness-audit skill.
#
# @description Emit, in one labeled dump, the repo ground-truth bundle the audit
# shares with every cluster reader: a prose-hotspot ranking of the docs recent
# fix passes rewrote most, a pass-attribution listing of which merge in the
# window wrote which prose file, flake outputs, just recipes, scripts
# (entry points, sourced libraries, and awk programs),
# workflows, the ci.yml top-level job list, lint-group membership, a union
# allowlist of all valid CI job/check names, workflow crons, the
# required-check context count, an ephemeral-token sweep over tracked
# docs, and an internal link/anchor check. Run this ONCE and hand its output to every
# reader, so a path/recipe/output/job/cron named in a doc is checked against one
# authoritative list instead of re-derived per agent. The job list, lint-group
# map, and union allowlist are the load-bearing facts: a doc calling a lint-group
# member check a standalone "required CI job" (mislabel), or naming a "CI job"
# that exists in no workflow at all (ghost), is the drift no freshness gate
# catches.
set -Eeuo pipefail
IFS=$'\n\t'

section() { printf '\n===== %s =====\n' "$1"; }

# A harness roster entry's third field is its enforce script, and the
# absence of one is what "test-only" means in ci.md and the enforcement
# matrix. That model is about the SCRIPT. A harness with no enforce script
# can still hold a scenario that runs against the live tree — invoking its
# subject with no fixture override, or reading the real nix/ or .github/
# trees — and such a scenario fails a pull request on a fact about the
# repo rather than about a fixture. Prose calling that harness "test-only"
# is then wrong while the roster it was derived from is right, so no
# freshness gate covers it and reading the roster does not find it.
# @arg $1 path to run-harness-group.sh  @arg $2 directory holding the harnesses
list_harness_live_tree() {
  local -r roster="$1" tests_dir="$2"
  if [[ ! -f ${roster} ]]; then
    echo "(no ${roster})"
    return 0
  fi
  local id harness enforce path markers
  sed -n "/^readonly -a HARNESSES=(/,/^)/p" "${roster}" |
    grep -oE "^[[:space:]]*'[^']+'" |
    sed -E "s/^[[:space:]]*'//; s/'\$//" |
    while IFS='|' read -r id harness enforce; do
      [[ -n ${id} ]] || continue
      path="${tests_dir}/${harness}"
      if [[ ! -f ${path} ]]; then
        printf '%-34s harness not found: %s\n' "${id}" "${path}"
        continue
      fi
      # Every harness resolves its subject through ${REPO_ROOT}/scripts, so
      # that path is not the signal — it is how a harness finds the script,
      # in fixture scenarios too. A live-tree READ is narrower: running the
      # subject from the repo root with no fixture override, or reading the
      # real nix/, .github/, docs/ or lock files. grep is enough because the
      # output is a short list of harnesses to open, not a classification to
      # trust.
      markers="$(grep -nE 'cd "?\$\{REPO_ROOT\}"?|\$\{REPO_ROOT\}/(nix|\.github|docs|flake\.(lock|nix))|git ls-files' "${path}" |
        head -4 || true)"
      if [[ -n ${markers} ]]; then
        printf '%-34s LIVE-TREE (enforce=%s)\n' "${id}" "${enforce:--}"
        printf '%s\n' "${markers}" | sed 's/^/    /'
      else
        printf '%-34s fixtures only (enforce=%s)\n' "${id}" "${enforce:--}"
      fi
    done
}

# Banned-token sweep over tracked docs. Canonical list: references/repo-map.md §4.
#
# The sweep reads prose only. Before matching, it blanks the three regions the
# repo's own lint (scripts/check-ephemeral-refs.sh) exempts: fenced code blocks,
# inline code spans, and generated BEGIN/END bodies. Without that pass the sweep
# reports a doc that *documents* a banned shape as an example — a table of
# banned token shapes, a generated hook table — as though it carried one, which
# is a false positive on every hit. Blanking preserves line numbering, so a
# reported line number still points at the right line.
#
# This mirrors the real lint rather than calling it, so the sweep still works on
# a fixture repo that does not contain it. The real lint remains the final
# authority: when the two disagree, believe `scripts/check-ephemeral-refs.sh`.
EPH_FILES=()
EPH_SCAN_DIR=""

# Seeded-defect fixture trees, as an ERE over repo-relative paths. Why they
# are out of scope: references/repo-map.md, "Doc cluster map". lychee.toml
# carries the same pattern for the consumers that reach lychee without this
# filter; collect-ground-truth.test.sh asserts the two select the same set.
RE_SEEDED_FIXTURES='\.claude/skills/[^/]+/evals/seeded-defects/fixtures/'

# Prose-hotspot ranking. What the section means and how to read it:
# references/repo-map.md §1, "PROSE HOTSPOTS".
#
# How far back the ranking reaches, counted in recorded audit points rather
# than commits: `.github/docs-audit-state` is rewritten once per cycle, so its
# own history is the only in-tree record of where one cycle ended.
HOTSPOT_MARKERS=5
# Where the line-level window starts. A marker records the sha its cycle
# audited once that cycle's fixes had landed, so it marks the END of a cycle:
# the range after the newest marker holds only what the cycle in progress
# has landed so far (when the audit opens a cycle, usually only the daily
# bump and changelog PRs), and the last
# completed pass sits between the second-newest marker and HEAD.
HOTSPOT_RECENT_MARKERS=2
# Under two touches the ranking says no more than "changed recently", which the
# priority set already says.
HOTSPOT_MIN_TOUCHES=2
# How many of the ranked files to resolve down to line numbers. Blame is
# per-file work, and the counts carry the ranking on their own.
HOTSPOT_BLAME_LIMIT=8
# Churn that is not prose drift: release-driven records, generated data, and
# fixture trees that exist to carry defects.
RE_HOTSPOT_SKIP="^(CHANGELOG\.md|docs/releases\.md|docs/_data/|tests/fixtures/)|${RE_SEEDED_FIXTURES}"
# What counts as prose for the ranking. Documentation here is a function, not a
# file extension: the body a workflow writes into an issue and the rationale
# header a script carries are read by a maintainer at the moment they act, and
# they drift the way a runbook does. Ranking Markdown alone leaves every defect
# in them unaimed-at. Git pathspec `*` crosses `/`, so `scripts/*.sh` reaches
# `scripts/lib/` too — the same reach the twin sweep uses.
# Not readonly: the harness sources this file more than once per run, and a
# readonly array makes the second source a fatal error rather than a no-op.
HOTSPOT_PATHSPECS=(
  '*.md'
  '.github/workflows/*.yml'
  '.github/ISSUE_TEMPLATE/*.yml'
  'scripts/*.sh'
)
# The same four shapes as a path regex, for the pass-attribution listing, so
# the files a pass is credited with are the files the ranking scores: a `.yml`
# outside those two directories is config, not prose, and never ranks.
RE_HOTSPOT_PROSE='\.md$|^\.github/(workflows|ISSUE_TEMPLATE)/[^/]+\.yml$|^scripts/.*\.sh$'

# @description Emit one file with its exempt regions blanked, line for line,
# mirroring check-ephemeral-refs.sh's strip_exempt ordering: fences (backtick
# or tilde) are recognized first, inline code spans are blanked before a BEGIN
# is looked for (so a marker quoted in a span is documentation, not a block
# opener), and an END closes a generated block only from inside one. An
# unterminated fence or generated block would silently blank every line to
# EOF, hiding any hit below it — fail loud instead, exactly as the lint does.
_eph_blank() { # $1=path
  awk -v src="$1" '
    {
      line = $0
      if (line ~ /^[[:space:]]*(```|~~~)/) { in_fence = !in_fence; print ""; next }
      if (in_fence) { print ""; next }
      while (match(line, /`[^`]*`/)) {
        pad = ""
        for (i = 0; i < RLENGTH; i++) pad = pad " "
        line = substr(line, 1, RSTART - 1) pad substr(line, RSTART + RLENGTH)
      }
      if (line ~ /<!--[[:space:]]*BEGIN[[:space:]]/) { in_gen = 1; print ""; next }
      if (in_gen) {
        if (line ~ /<!--[[:space:]]*END[[:space:]]/) { in_gen = 0 }
        print ""
        next
      }
      print line
    }
    END {
      if (in_fence) { printf "%s: unterminated code fence\n", src > "/dev/stderr"; bad = 1 }
      if (in_gen) { printf "%s: unterminated generated block\n", src > "/dev/stderr"; bad = 1 }
      if (bad) exit 1
    }
  ' <"$1"
}

# @description Materialise blanked copies of EPH_FILES under a temp mirror, so
#              each category grep runs once over prose-only text.
_eph_prepare() {
  local f dir
  EPH_SCAN_DIR="$(mktemp -d)"
  for f in "${EPH_FILES[@]}"; do
    dir="${f%/*}"
    [[ ${dir} == "${f}" ]] && dir="."
    mkdir -p "${EPH_SCAN_DIR}/${dir}"
    # A failed blank (unterminated fence / generated block) is a doc defect
    # the sweep must not paper over — propagate it instead of scanning a
    # partially-blanked mirror.
    if ! _eph_blank "${f}" >"${EPH_SCAN_DIR}/${f}"; then
      rm -rf "${EPH_SCAN_DIR}"
      EPH_SCAN_DIR=""
      return 1
    fi
  done
}

_emit_eph() { # $1=category $2=ERE $3=optional extra grep flag — emits "file:line\t(category) <trimmed line>"
  local -a flags=(-HnE)
  if [[ -n ${3:-} ]]; then flags+=("$3"); fi
  (cd "${EPH_SCAN_DIR}" && grep "${flags[@]}" "$2" -- "${EPH_FILES[@]}" 2>/dev/null) |
    sed -E "s/^([^:]+:[0-9]+):[[:space:]]*/\1	($1) /" || true
}
sweep_ephemeral_tokens() {
  mapfile -t EPH_FILES < <(git ls-files '*.md' | grep -vE '^(\.claude/|tests/fixtures/|docs/_data/|CHANGELOG\.md$|docs/releases\.md$)' || true)
  if [[ ${#EPH_FILES[@]} -eq 0 ]]; then
    echo '(none)'
    return 0
  fi
  _eph_prepare || return 1
  local hits
  hits="$(
    {
      # The blocking classes are transcribed from RE_PLANNING, RE_REVIEW,
      # RE_DATE, RE_ISSUE and RE_CLAUDE in scripts/lib/ephemeral-refs-scope.sh, left
      # boundary guards included. Without the guard a shape matches inside a
      # larger token — `UTF-8` -> `F-8`, `PDF-1.7` -> `F-1`, `ID5:` -> `D5:`,
      # `abc#12` -> `#12` — and the sweep reports candidates the gate never
      # raises, which is what teaches a reader to scroll past its output.
      _emit_eph planning-label '(^|[^-&[:alnum:]_])(GAP-[0-9]+|P[0-9]+\.[0-9]+|Wave-P?[0-9]+|Phase[[:space:]]+[0-9]+|AU-P-[0-9]+|SC-POST-[0-9]+|plan[[:space:]]+[0-9]+|F-[0-9]+)'
      _emit_eph review-pass '(^|[^-&[:alnum:]_])(\(D[0-9]+\)|\(L[0-9]+[,)]|Per[[:space:]]+D[0-9]+|D[0-9]+:)'
      _emit_eph ad-hoc-ticket 'DH-[0-9]+|NC-[A-Z][0-9]+|[A-Z]{2,3}-[0-9]+' |
        grep -vE '(SHA|UTF|RFC|ISO|BASE)-[0-9]+' || true
      _emit_eph date '([0-9]{4}-[0-9]{2}-[0-9]{2}|(January|February|March|April|May|June|July|August|September|October|November|December)[[:space:]]+[0-9]{4}|Q[1-4][[:space:]]+[0-9]{4})' |
        grep -vE 'X-GitHub-Api-Version: [0-9]{4}-[0-9]{2}-[0-9]{2}' || true
      # Mirrors RE_CAUSAL in scripts/lib/ephemeral-refs-scope.sh. Bare verbs
      # and prepositions (`prior to`, `swapped`, `was reshaped`) are excluded
      # there on purpose, so including them here would report hits the real
      # lint never raises. The lint runs this class with --ignore-case, so the
      # sweep does too: the commonest form is sentence-initial (`Previously,`),
      # and a case-sensitive sweep silently misses every one of them. The
      # blocking classes stay case-sensitive on both sides.
      _emit_eph causal-history 'previously|Migration note|Tightened from|switched (from|to)|legacy .* was deleted|added in #?[0-9]+|post-PR #?[0-9]+' --ignore-case
      # RE_ISSUE's guards subsume the entity and anchor suppressions below;
      # both are kept so a shape the guard admits stays suppressed. Hex colors
      # need their own filter either way: RE_ISSUE admits `#333`, and the lint
      # relies on colors living in fenced blocks to keep it quiet.
      _emit_eph pr-ref '(^|[^-&[:alnum:]_])#[0-9]+([^-[:alnum:]_]|$)' |
        grep -vE '(fill|stroke|color):#[0-9a-fA-F]{3,8}|&#[0-9]+;|#[0-9]+-' || true
      _emit_eph claude-path '\.claude/'
    } | sort -u || true
  )"
  [[ -n ${EPH_SCAN_DIR} ]] && rm -rf "${EPH_SCAN_DIR}"
  EPH_SCAN_DIR=""
  if [[ -z ${hits} ]]; then echo '(none)'; else printf '%s\n' "${hits}"; fi
}

# Internal link + anchor resolution via lychee (offline; external URLs skipped).
# Run from a tmp cwd so lychee's gitignored .lycheecache never lands in the repo.
sweep_internal_links() {
  if ! command -v lychee >/dev/null 2>&1; then
    echo '(lychee not found — internal-link sweep skipped)'
    return 0
  fi
  local repo_root tmp errs raw lychee_rc skipped
  repo_root="$(git rev-parse --show-toplevel)"
  local files=()
  # Wider than the ephemeral sweep: tracked .claude/ tooling quotes banned
  # token shapes as pattern data, but its links are ordinary links, so they
  # stay in. Only tests/fixtures/, docs/_data/ and the seeded-defect fixtures
  # named by RE_SEEDED_FIXTURES drop out.
  mapfile -t files < <(git ls-files '*.md' | grep -vE "^(tests/fixtures/|docs/_data/|${RE_SEEDED_FIXTURES})" || true) # first of two filters; lychee.toml exclude_path narrows it again
  if [[ ${#files[@]} -eq 0 ]]; then
    echo '(none)'
    return 0
  fi
  tmp="$(mktemp -d)"
  # Capture lychee's own status, not the pipeline's. lychee exits non-zero
  # both for "found broken links" (2) and for "could not run at all" (1 — an
  # input it cannot parse, a bad config), and only the first shape prints an
  # [ERROR] line — so a status-blind pipeline reports an empty error list,
  # which is byte-identical to a clean sweep. A tracked doc deleted but not
  # staged reaches that path: git ls-files names it, lychee refuses the
  # input, and the bundle would claim a clean link check over zero files.
  # The branch below keys off the error lines first rather than off the exit
  # code, so it stays correct if those codes ever change.
  #
  # A per-input refusal is quieter still: lychee skips the input with a
  # "No files found for this input source" warning and still exits 0. An
  # exclude_path entry matching a tracked doc — or matching the checkout's
  # own parent directory — therefore shrinks the sweep silently, possibly to
  # nothing, which again reads as a clean run. Count those warnings too.
  raw="$(
    cd "${tmp}" &&
      lychee --config "${repo_root}/lychee.toml" --offline \
        --include-fragments=anchor-only --cache=false --no-progress \
        "${files[@]/#/${repo_root}/}" 2>&1
  )" && lychee_rc=0 || lychee_rc=$?
  rm -rf "${tmp}"
  errs="$(printf '%s\n' "${raw}" | grep '\[ERROR\]' | sed "s#file://${repo_root}/##g" || true)"
  skipped="$(printf '%s\n' "${raw}" | grep -c 'No files found for this input source' || true)"
  # A shrunken input set is independent of whether the links that WERE read
  # resolved, so this reports first and does not compete with the error list.
  if ((skipped > 0)); then
    printf '(lychee skipped %d of %d input(s) — internal-link sweep incomplete)\n' \
      "${skipped}" "${#files[@]}"
    printf '%s\n' "${raw}" | grep 'No files found for this input source' |
      sed "s#file://${repo_root}/##g;s#${repo_root}/##g"
  fi
  if [[ -n ${errs} ]]; then
    printf '%s\n' "${errs}"
  elif ((lychee_rc != 0)); then
    printf '(lychee failed — internal-link sweep unusable; exit %d)\n' "${lychee_rc}"
    printf '%s\n' "${raw}"
  elif ((skipped == 0)); then
    echo '(none)'
  fi
}

# @description Read `nix flake show --json` on stdin, emit "outputs: a, b, c".
#
# Newer Nix wraps the tree in an "inventory" key and emits a stub for every
# well-known output name whether or not this flake defines it, so a naive key
# dump reports nixosModules, nixosConfigurations and legacyPackages as outputs
# this flake has. flake-parts does create those three, but empty, and the
# renderer behind docs/reference/flake-outputs.md omits them — a reader handed
# the naive dump reports that omission as generator drift. Keep only outputs
# holding something: a child with real entries, a derivation, or a system Nix
# declined to enumerate. A bare isLegacy marker is a placeholder for an empty
# legacyPackages set, not content.
filter_flake_outputs() {
  python3 -c '
import json, sys

def substantive(node):
    if not isinstance(node, dict):
        return bool(node)
    if node.get("filtered") or "derivation" in node:
        return True
    kids = node.get("children")
    if isinstance(kids, dict):
        return any(substantive(c) for c in kids.values())
    return not node.get("isLegacy", False) and bool(node)

def defined(v):
    if not isinstance(v, dict) or "output" not in v:
        return True
    return substantive(v["output"])

d = json.load(sys.stdin)
tree = d["inventory"] if isinstance(d.get("inventory"), dict) else d
names = sorted(k for k, v in tree.items() if defined(v))
print("outputs: " + ", ".join(names))
'
}

list_scripts() { # emits one `scripts/`-relative path per script, cwd = repo root
  # Both shell trees plus the awk programs. Tracked docs cite the sourced
  # libraries under scripts/lib/ and the `scripts/*.awk` programs by path as
  # readily as the top-level entry points, and a `scripts/*.sh` glob covers
  # neither — so an inventory that stops at top-level *.sh makes every such
  # citation read to a reader as a script that does not exist. The `lib/`
  # prefix is what keeps a library entry distinguishable from an entry-point
  # one; a bare basename would collapse the distinction the citations rely on.
  local f
  for f in scripts/*.sh scripts/lib/*.sh scripts/*.awk; do
    [[ -e ${f} ]] || continue
    printf '%s\n' "${f#scripts/}"
  done
}

list_ci_jobs() { # $1=workflow path — emits "<line>:  <job-id>" for the jobs: block only
  # Scoped to the jobs: block. A bare 2-space-key grep also returns `on:`
  # trigger names and `concurrency:` keys, which read as job ids to someone
  # checking a doc's "CI job X" claim against this section.
  awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    /^[A-Za-z]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:/ {
      name = $0
      sub(/:.*/, "", name)
      gsub(/[[:space:]]/, "", name)
      printf "%d:  %s\n", NR, name
    }
  ' "$1"
}

list_workflow_crons() { # $1=workflows dir — emits "<file>:<schedule line>" for `- cron:` entries only
  # Anchored to the list-item shape. A bare `cron:` grep also returns prose
  # inside a run: block (an issue body that says "the `cron:` lines under
  # ..."), which reads as an extra scheduled workflow to someone diffing this
  # section against the ci.md cron table.
  # Both suffixes, matching the scan sets the repo's own workflow lints use.
  # An unmatched glob would reach grep as a literal path and exit 2, so drop
  # the non-existent ones before the scan rather than relying on 2>/dev/null.
  local -a files=()
  local f
  for f in "$1"/*.yml "$1"/*.yaml; do
    [[ -f ${f} ]] && files+=("${f}")
  done
  [[ ${#files[@]} -gt 0 ]] || return 0
  grep -HE '^[[:space:]]*-[[:space:]]*cron:' "${files[@]}" 2>/dev/null |
    sed "s#^$1/##"
}

# @description Print the commit the audit started from N recorded audit points
#              back, or nothing when the marker history cannot supply a
#              reachable one.
# @arg $1 how many recorded audit points to reach back (1 = the current point)
# @stdout one commit sha, or nothing
hotspot_base_sha() {
  local -r depth="$1"
  local state='.github/docs-audit-state'
  [[ -f ${state} ]] || return 0
  local -a markers=()
  # Marker commits newest first; each one records the sha its cycle audited.
  mapfile -t markers < <(git log --format=%H -- "${state}" 2>/dev/null || true)
  [[ ${#markers[@]} -gt 0 ]] || return 0
  local idx=$((depth - 1))
  # Fewer recorded points than the window asks for: reach back to the oldest.
  ((idx < ${#markers[@]})) || idx=$((${#markers[@]} - 1))
  local recorded
  recorded="$(git show "${markers[idx]}:${state}" 2>/dev/null | sed -n 's/^LAST_AUDIT_SHA=//p' | head -1 || true)"
  [[ -n ${recorded} ]] || return 0
  # A recorded sha can be unreachable — a shallow clone, or rewritten history.
  # Returning it anyway would rank nothing at all rather than say why.
  git cat-file -e "${recorded}^{commit}" 2>/dev/null || return 0
  printf '%s\n' "${recorded}"
}

# @description Emit the current line numbers of one file whose latest change
#              came from a listed commit, collapsed into ranges. Blame reports
#              lines as they stand now, so a range points at text a reader can
#              go read rather than at an offset inside an old hunk.
# @arg $1 path to a tracked file
# @arg $2 path to a file of candidate commit shas, one per line
hotspot_lines() {
  local -r path="$1"
  local -r shafile="$2"
  # A blame that cannot run leaves the ranking intact — the counts do not
  # depend on it — so report the gap for that one file instead of aborting.
  git blame --porcelain -- "${path}" 2>/dev/null | awk -v listfile="${shafile}" '
    BEGIN { while ((getline sha < listfile) > 0) recent[sha] = 1 }
    # Content lines are tab-prefixed; only headers carry sha + line numbers.
    /^\t/ { next }
    length($1) == 40 && $1 ~ /^[0-9a-f]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
      if ($3 > maxline) maxline = $3
      if ($1 in recent) mark[$3] = 1
      next
    }
    END {
      for (i = 1; i <= maxline; i++) {
        if (i in mark) {
          if (!start) start = i
          prev = i
          continue
        }
        if (start) {
          out = out sep (start == prev ? start : start "-" prev)
          sep = ", "
          start = 0
        }
      }
      if (start) out = out sep (start == prev ? start : start "-" prev)
      print (out == "" ? "(blame names none)" : out)
    }
  ' || true
}

# @description Rank tracked prose by how many recent commits rewrote it, and
#              name the surviving lines of the files at the top.
rank_prose_hotspots() {
  local base latest
  # Two windows, because the two facts a reader needs are different. The wide
  # one measures how much rewriting a doc has absorbed; the newest point says
  # which of its lines the last pass rewrote. A paragraph that scores on both
  # is one an earlier pass edited around and the last pass edited again.
  base="$(hotspot_base_sha "${HOTSPOT_MARKERS}")"
  latest="$(hotspot_base_sha "${HOTSPOT_RECENT_MARKERS}")"
  if [[ -z ${base} ]]; then
    echo '(no usable audit point — .github/docs-audit-state is absent, records no'
    echo ' reachable sha, or this is a shallow clone. Ranking skipped: read the'
    echo ' priority set unranked.)'
    return 0
  fi
  # An unreachable newest point with a reachable older one would leave the line
  # window as a bare `..HEAD`; fall back to the one window that resolved.
  [[ -n ${latest} ]] || latest="${base}"
  local tmp
  tmp="$(mktemp -d)"
  git log --format=%H "${latest}..HEAD" >"${tmp}/commits"
  # One commit contributes one line per path it touched, and a merge contributes
  # none, so an occurrence count is a count of distinct non-merge commits — of
  # any type; in this tree nearly every commit that touches prose is a fix pass.
  git log --format='' --name-only "${base}..HEAD" -- "${HOTSPOT_PATHSPECS[@]}" >"${tmp}/raw"
  # grep exits 1 on no match, which pipefail would turn into a collector abort
  # for the legitimate "nothing changed since that audit point" case.
  grep -vE "^$|${RE_HOTSPOT_SKIP}" "${tmp}/raw" >"${tmp}/paths" || true
  sort "${tmp}/paths" | uniq -c | awk '{ print $1, $2 }' | sort -rn -k1,1 >"${tmp}/ranked"
  # Same population as the per-file counts: non-merge commits, prose-touching
  # or not, so the two figures read on one scale.
  printf 'rewrite pressure: %s commit(s) since audit point %s (%s point(s) back)\n' \
    "$(git rev-list --count --no-merges "${base}..HEAD")" "${base:0:7}" "${HOTSPOT_MARKERS}"
  printf 'lines below are what the most recent cycle rewrote, since audit point %s\n' "${latest:0:7}"
  local ranked=0 count path
  # The file's strict IFS holds no space, so the split is set per-read here.
  while IFS=' ' read -r count path; do
    ((count >= HOTSPOT_MIN_TOUCHES)) || continue
    ranked=$((ranked + 1))
    if ((ranked > HOTSPOT_BLAME_LIMIT)); then continue; fi
    if [[ -f ${path} ]]; then
      printf '%s — %s commit(s); most recent cycle rewrote: %s\n' \
        "${path}" "${count}" "$(hotspot_lines "${path}" "${tmp}/commits")"
    else
      printf '%s — %s commit(s); not in the worktree\n' "${path}" "${count}"
    fi
  done <"${tmp}/ranked"
  if ((ranked == 0)); then
    echo '(no doc was rewritten by more than one fix commit since that audit point)'
  elif ((ranked > HOTSPOT_BLAME_LIMIT)); then
    printf '(%s further doc(s) scored %s+ and are not listed; the whole set is the priority set)\n' \
      "$((ranked - HOTSPOT_BLAME_LIMIT))" "${HOTSPOT_MIN_TOUCHES}"
  fi
  rm -rf "${tmp}"
  echo '(Read the whole paragraph around each line, not the sentence the diff'
  echo ' changed: the surviving defect is usually a sibling clause the fix pass'
  echo ' left alone, and a paragraph high on this list has survived several.)'
}

# @description Name every fix pass in the line window and the prose files each
#              of its commits touched, so a finding can be attributed to the
#              pass that wrote it without re-deriving the mapping per reader.
attribute_passes() {
  local latest
  latest="$(hotspot_base_sha "${HOTSPOT_RECENT_MARKERS}")"
  if [[ -z ${latest} ]]; then
    echo '(no usable audit point — attribution needs a recorded sha to bound the'
    echo ' window. Attribute findings by hand with git log -L.)'
    return 0
  fi
  printf 'passes merged since audit point %s (newest first)\n' "${latest:0:7}"
  local -a merges=()
  mapfile -t merges < <(git log --format=%H --merges --first-parent "${latest}..HEAD" 2>/dev/null || true)
  if [[ ${#merges[@]} -eq 0 ]]; then
    echo '(no merge in the window — this cycle landed on the branch directly;'
    echo ' read the commits the PROSE HOTSPOTS line window names.)'
    return 0
  fi
  local merge subject commit csubject files
  for merge in "${merges[@]}"; do
    subject="$(git log --format=%s -1 "${merge}")"
    printf '\n%s %s\n' "${merge:0:7}" "${subject}"
    # ^1..^2 is the branch side of the merge: the commits the pass itself wrote,
    # excluding whatever main gained underneath it while the PR was open.
    # The file's strict IFS holds no space, so the split is set per-read here.
    while IFS=' ' read -r commit csubject; do
      [[ -n ${commit} ]] || continue
      files="$(git diff-tree --no-commit-id --name-only -r "${commit}" |
        grep -E "${RE_HOTSPOT_PROSE}" | grep -vE "${RE_HOTSPOT_SKIP}" | paste -sd' ' - || true)"
      [[ -n ${files} ]] || continue
      printf '  %s %s\n    %s\n' "${commit}" "${csubject}" "${files}"
    done < <(git log --format='%h %s' --no-merges "${merge}^1..${merge}^2" 2>/dev/null || true)
  done
  echo
  echo '(A finding inside a file one of these commits touched is attributable to'
  echo ' that pass. Say so in the report: a defect a fix pass manufactured says'
  echo ' the fix discipline leaked, which is worth more than its severity.)'
}

main() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  cd "${REPO_ROOT}"

  section "PROSE HOTSPOTS (docs the recent fix passes rewrote most; aim here first)"
  rank_prose_hotspots

  section "PASS ATTRIBUTION (which fix pass wrote which prose file in the window)"
  attribute_passes

  section "FLAKE OUTPUTS (nix flake show)"
  if ! nix flake show --json 2>/dev/null | filter_flake_outputs 2>/dev/null; then
    nix flake show 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  fi

  section "JUST RECIPES (just --list)"
  just --list 2>/dev/null | sed 's/^ *//'

  section "SCRIPTS (scripts/*.sh + scripts/lib/*.sh + scripts/*.awk)"
  list_scripts

  section "WORKFLOWS (.github/workflows)"
  ls .github/workflows/

  section "CI.YML TOP-LEVEL JOBS (ci.yml's own jobs; see union allowlist below for ALL valid names)"
  list_ci_jobs .github/workflows/ci.yml

  section "LINT-GROUP MEMBERSHIP (.github/lint-groups.yml)"
  if [[ -f .github/lint-groups.yml ]]; then
    grep -vE '^[[:space:]]*#' .github/lint-groups.yml | grep -vE '^[[:space:]]*$'
  else
    echo '(no .github/lint-groups.yml)'
  fi

  section "VALID CI JOB / CHECK NAMES (union: every workflow job id + every lint-group member + every harness-group member)"
  {
    # job ids from the jobs: block of every workflow (not just ci.yml)
    for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
      [[ -f ${wf} ]] || continue
      awk '
        /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
        /^[A-Za-z]/ { in_jobs = 0 }
        in_jobs && /^  [A-Za-z0-9_-]+:/ {
          name = $0
          sub(/:.*/, "", name)
          gsub(/[[:space:]]/, "", name)
          print name
        }
      ' "${wf}"
    done
    # lint-group member check basenames (list items under each group)
    if [[ -f .github/lint-groups.yml ]]; then
      grep -E '^[[:space:]]*-[[:space:]]' .github/lint-groups.yml |
        sed -E "s/^[[:space:]]*-[[:space:]]*//; s/[[:space:]].*$//; s/[\"']//g"
    fi
    # harness-group member ids: first pipe-delimited field of every
    # HARNESSES entry in scripts/run-harness-group.sh
    if [[ -f scripts/run-harness-group.sh ]]; then
      sed -n "/^readonly -a HARNESSES=(/,/^)/p" scripts/run-harness-group.sh |
        grep -oE "^[[:space:]]*'[^|']+\|" |
        sed -E "s/^[[:space:]]*'//; s/\|$//"
    fi
  } | sort -u
  echo '(GHOST CHECK: a name a doc calls a "CI job" or "required check" that is'
  echo ' ABSENT from this list exists in no workflow, no lint group and no harness'
  echo ' group — high severity.)'

  section "HARNESS LIVE-TREE SCENARIOS (which harness-group harnesses read the real repo, not a fixture)"
  list_harness_live_tree scripts/run-harness-group.sh tests
  echo '(A harness listed LIVE-TREE with enforce=- is still test-only in the'
  echo ' enforcement model and still fails a PR on a live-tree fact. Prose'
  echo ' calling it "test-only", "fixture tests alone" or "probes no live tree"'
  echo ' is a finding. Open the named lines before filing one either way.)'

  section "WORKFLOW CRONS (authoritative schedules; ci.md table must match)"
  list_workflow_crons .github/workflows

  section "REQUIRED-CHECK CONTEXTS (ruleset)"
  ruleset='.github/rulesets/protect-main.json'
  if [[ -f ${ruleset} ]]; then
    printf 'protect-main.json context count: %s\n' "$(grep -c '"context"' "${ruleset}")"
  else
    echo '(no ruleset file at .github/rulesets/protect-main.json)'
  fi

  section "EPHEMERAL-TOKEN HITS (banned shapes in tracked-doc PROSE; see repo-map §4)"
  sweep_ephemeral_tokens
  echo '(Prose only: fenced code blocks, inline code spans, and generated'
  echo ' BEGIN/END bodies are blanked before matching, mirroring check-ephemeral-refs.sh.'
  echo ' Per-class suppressions: pr-ref drops fill:/stroke:/color:#hex, &#NNN;,'
  echo ' #N-anchor targets; ad-hoc-ticket drops SHA/UTF/RFC/ISO/BASE-NNN; date'
  echo ' drops the X-GitHub-Api-Version date literal.'
  echo ' Excludes .claude/ tooling, CHANGELOG.md + docs/releases.md (historical records),'
  echo ' tests/fixtures, docs/_data.'
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  echo ' NOT authoritative — `scripts/check-ephemeral-refs.sh` is. Run it and'
  echo ' believe its exit code; treat anything here it does not report as a'
  echo ' false positive. causal-history is advisory-only even in the real lint.)'

  section "UNRESOLVED INTERNAL LINKS / ANCHORS (lychee --offline; external skipped; authoritative)"
  sweep_internal_links
}

if [[ ${BASH_SOURCE[0]} == "${0:-}" ]]; then
  main "$@"
fi
