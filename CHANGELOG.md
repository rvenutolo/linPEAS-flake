# Changelog

All notable changes to this project are auto-generated from
conventional commits between release tags. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The release
tag matches the upstream peass-ng pin version (`YYYYMMDD-<sha>`); this
repo is not on a semver track.

## Unreleased

### CI
- Wire permission-scopes check into hooks and lint group
- Run flake-lock-provenance in lint-doc-invariants group
- Parity-check required-checks.md table against the ruleset mirror ([#330](https://github.com/rvenutolo/linPEAS-flake/pull/330))
- Parity-check required-checks.md table against the ruleset mirror
- Raise timeouts on flakehub-cache cron jobs for upload headroom ([#327](https://github.com/rvenutolo/linPEAS-flake/pull/327))
- Raise timeouts on flakehub-cache cron jobs for upload headroom
- Promote 11 advisory CI jobs to required status checks ([#321](https://github.com/rvenutolo/linPEAS-flake/pull/321))
- Promote 11 advisory CI jobs to required status checks
- Retime crons to daily 08:00-10:00 UTC and weekly Friday 05:00-07:00 UTC ([#320](https://github.com/rvenutolo/linPEAS-flake/pull/320))
- Retime crons to daily 08:00-10:00 UTC and weekly Friday 05:00-07:00 UTC
- Move coverage matrix and image CVE scans to weekly cron workflows ([#319](https://github.com/rvenutolo/linPEAS-flake/pull/319))
- Move coverage matrix and image CVE scans to weekly cron workflows
- Remove actionlint-drift-check; drop cron-table-drift-check cron ([#318](https://github.com/rvenutolo/linPEAS-flake/pull/318))
- Remove actionlint-drift-check; drop cron-table-drift-check cron

### Chores
- Drop Administration from SCORECARD_PAT invariant scope ([#375](https://github.com/rvenutolo/linPEAS-flake/pull/375))
- Drop Administration from SCORECARD_PAT invariant scope
- Update flake.lock ([#344](https://github.com/rvenutolo/linPEAS-flake/pull/344))
- Update flake.lock
- Remove image size monitoring ([#303](https://github.com/rvenutolo/linPEAS-flake/pull/303))
- Remove image size monitoring

### Documentation
- Document write-scope allowlist and sync derived docs
- Document bypass_actors assertion in tag-protection control
- Document strict + thread-resolution protect-main assertions
- Index the lean lint-shell routing invariant ([#353](https://github.com/rvenutolo/linPEAS-flake/pull/353))
- Index the lean lint-shell routing invariant
- Document workflow-scanner division of labor ([#341](https://github.com/rvenutolo/linPEAS-flake/pull/341))
- Document workflow-scanner division of labor
- Align SECURITY.md posture-monitoring section with codeql.yml ([#328](https://github.com/rvenutolo/linPEAS-flake/pull/328))
- Align SECURITY.md posture-monitoring section with codeql.yml
- Update flake.nix references for the flake-parts module split

### Features
- Gate auto-merge workflows on prior PR state ([#372](https://github.com/rvenutolo/linPEAS-flake/pull/372))
- Add auto-merge decline-gate lint
- Gate auto-merge update workflows on prior PR state
- Pin and verify integration_id on protect-main required checks ([#371](https://github.com/rvenutolo/linPEAS-flake/pull/371))
- Pin and verify integration_id on protect-main required checks
- Treat App-token-minting jobs as fork-guard privileged ([#370](https://github.com/rvenutolo/linPEAS-flake/pull/370))
- Treat App-token-minting jobs as fork-guard privileged
- Enforce per-job GITHUB_TOKEN write-scope allowlist ([#368](https://github.com/rvenutolo/linPEAS-flake/pull/368))
- Enforce per-job GITHUB_TOKEN write-scope allowlist
- Add per-job GITHUB_TOKEN write-scope allowlist file
- Add CI guard against dead renovate customManager markers
- Assert bypass_actors empty in tag-protection drift check ([#366](https://github.com/rvenutolo/linPEAS-flake/pull/366))
- Assert bypass_actors empty in tag-protection drift check
- Assert strict policy and thread resolution in protect-main drift check ([#365](https://github.com/rvenutolo/linPEAS-flake/pull/365))
- Assert strict policy and thread resolution in protect-main drift check
- Gate flake.lock auto-merge on input provenance ([#364](https://github.com/rvenutolo/linPEAS-flake/pull/364))
- Gate flake.lock auto-merge on input provenance
- Add run-harness-group runner for batched harness job
- Add run-doc-freshness runner for batched doc-freshness job
- Add run-lint-group runner for batched invariant lints
- Add lint-groups manifest for batched invariant lints

### Fixes
- Sweep in-repo temp files left by interrupted refresh generators ([#377](https://github.com/rvenutolo/linPEAS-flake/pull/377))
- Sweep in-repo temp files left by interrupted refresh generators
- Fail-fast when a workflow declares more than one cron line ([#373](https://github.com/rvenutolo/linPEAS-flake/pull/373))
- Fail-fast when a workflow declares more than one cron line
- Require fork-guard on actions:write jobs in lint ([#369](https://github.com/rvenutolo/linPEAS-flake/pull/369))
- Require fork-guard on actions:write jobs in lint
- Detect all nix-installer declarations and guard dead renovate markers ([#367](https://github.com/rvenutolo/linPEAS-flake/pull/367))
- Match all nix-installer declarations in renovate customManager
- Exclude test fixtures from lychee link check ([#346](https://github.com/rvenutolo/linPEAS-flake/pull/346))
- Exclude test fixtures from lychee link check
- Sweep stray in-repo temps from refresh-treefmt-config ([#337](https://github.com/rvenutolo/linPEAS-flake/pull/337))
- Sweep stray in-repo temps from refresh-treefmt-config
- File notify issues for cancelled runs instead of ignoring them ([#329](https://github.com/rvenutolo/linPEAS-flake/pull/329))
- File notify issues for cancelled runs instead of ignoring them
- Skip redundant pytest suite in the pre-commit wrapper build ([#324](https://github.com/rvenutolo/linPEAS-flake/pull/324))
- Skip redundant pytest suite in the pre-commit wrapper build
- Repoint ratchet-pin-audit devShell check to nix/devshell.nix

### Performance
- Host light lint groups in lean devShells.lint ([#350](https://github.com/rvenutolo/linPEAS-flake/pull/350))
- Host light lint groups in lean devShells.lint
- Batch 3 setup-tax harness jobs into one harness-group job ([#336](https://github.com/rvenutolo/linPEAS-flake/pull/336))
- Batch 3 setup-tax harness jobs into one harness-group job
- Batch 7 doc-freshness jobs into one doc-freshness job ([#332](https://github.com/rvenutolo/linPEAS-flake/pull/332))
- Batch 7 doc-freshness jobs into one doc-freshness job
- Batch 24 invariant-lint jobs into 3 grouped jobs ([#331](https://github.com/rvenutolo/linPEAS-flake/pull/331))
- Batch 24 invariant-lint jobs into 3 grouped jobs

### Refactor
- Trim redundant scorecard checks ([#339](https://github.com/rvenutolo/linPEAS-flake/pull/339))
- Trim redundant scorecard checks
- Migrate to flake-parts module structure ([#305](https://github.com/rvenutolo/linPEAS-flake/pull/305))
- Split pre-commit hooks into domain modules
- Extract packages, image, checks, treefmt, devshell modules
- Extract pin and wrappers modules
- Adopt git-hooks flakeModule
- Adopt treefmt-nix flakeModule
- Introduce flake-parts skeleton, drop flake-utils

### Style
- Normalize fixture quoting to treefmt
- Drop causal-history phrase from lint-workflow-security comment ([#338](https://github.com/rvenutolo/linPEAS-flake/pull/338))
- Drop causal-history phrase from lint-workflow-security comment

### Tests
- Assert refresh generators sweep leaked in-repo temp files
- Add integration_id drift fixture exposing protect-main gap
- Add app-token fixture exposing fork-guard lint gap
- Add actions:write fixture exposing fork-guard lint gap
- Add fixtures for permission-scope allowlist check
- Add non-empty bypass_actors fixture for tag-protection drift check
- Add strict + thread-resolution drift fixtures for protect-main
- Add strict + thread-resolution fields to good protect-main fixture
- Repoint enforcement-matrix fixtures to grouped lint jobs

## [20260604-085abf96] - 2026-06-08

### Chores
- Bump linpeas to 20260604-085abf96 ([#301](https://github.com/rvenutolo/linPEAS-flake/pull/301))
- Bump linpeas to 20260604-085abf96
- Update flake.lock ([#297](https://github.com/rvenutolo/linPEAS-flake/pull/297))
- Update flake.lock
- Pin GitHub Actions to exact patch tags ([#296](https://github.com/rvenutolo/linPEAS-flake/pull/296))
- Pin GitHub Actions to exact patch tags
- Pin codeql-action/init comment to exact patch tag
- Set nix substituter retry + timeouts in setup-nix ([#294](https://github.com/rvenutolo/linPEAS-flake/pull/294))
- Set nix substituter retry + timeouts in setup-nix

### Documentation
- Document patch-tag pin convention

### Features
- Enforce patch-tag pin convention via pre-commit hook
- Add check-patch-tag-pins.sh lint
- Add apply-patch-tag-pin-rewrite.sh
- Add inventory-action-pin-tags.sh

### Fixes
- Make update-linpeas idempotent on same-version reruns ([#300](https://github.com/rvenutolo/linPEAS-flake/pull/300))
- Rebase open same-version bump PR onto main HEAD before re-merging
- Make update-linpeas push-and-merge idempotent on same-version reruns
- Unshallow image-smoke checkout for main baseline build ([#293](https://github.com/rvenutolo/linPEAS-flake/pull/293))
- Unshallow image-smoke checkout for main baseline build

### Tests
- Inventory-action-pin-tags offline-test fixture mode

## [20260601-a39c90f1] - 2026-06-01

### CI
- Add customManager for octoscan digest + version bumps ([#278](https://github.com/rvenutolo/linPEAS-flake/pull/278))

### Chores
- Bump linpeas to 20260601-a39c90f1 ([#289](https://github.com/rvenutolo/linPEAS-flake/pull/289))
- Refresh flake-show for linpeas 20260601-a39c90f1
- Bump linpeas to 20260601-a39c90f1
- Scope octoscan customManager to scripts/octoscan-scan.sh

### Documentation
- Backfill cron schedule table ([#287](https://github.com/rvenutolo/linPEAS-flake/pull/287))
- Backfill cron schedule table

### Features
- Cron schedule drift guard ([#288](https://github.com/rvenutolo/linPEAS-flake/pull/288))
- Weekly drift-check for cron schedule table
- Wire check-cron-table pre-commit hook
- Add check-cron-table.sh drift detector
- Add local pre-commit hook for octoscan ([#285](https://github.com/rvenutolo/linPEAS-flake/pull/285))
- Add octoscan pre-commit hook backed by scripts/octoscan-scan.sh
- Add scripts/octoscan-scan.sh as single source of truth for octoscan invocation

### Fixes
- Octoscan-scan.sh per-file loop + SARIF aggregation
- Drop libsystemd from procps to shrink OCI attack surface ([#284](https://github.com/rvenutolo/linPEAS-flake/pull/284))
- Drop libsystemd from procps to shrink OCI attack surface
- Route changelog commit via PR + auto-merge ([#282](https://github.com/rvenutolo/linPEAS-flake/pull/282))
- Route changelog commit via PR + auto-merge

### Refactor
- Route octoscan workflow through scripts/octoscan-scan.sh

### Tests
- Cover argument parsing + docker-missing branch for octoscan-scan.sh

## [20260528-82c8c3b6] - 2026-05-29

### Build
- Add commitlint to devShell buildInputs
- Add scorecard CLI to devShell
- Add ratchet to devShell for action pin audits
- Add nixpkgs-hammer shim for flake-defined derivation
- Exclude CHANGELOG.md from treefmt and markdownlint
- Add cliff.toml for conventional-commit changelog generation
- Expose git-cliff package for changelog generation
- Add treefmt-config-fresh hook and extend just-recipes-fresh
- Expose devTooling.treefmtConfig for doc generator
- Add ci-dag-fresh pre-commit hook
- Add scripts-reference-fresh pre-commit hook

### CI
- Add customManager for octoscan digest + version
- Grant contents: write to release image jobs for SBOM upload
- Add ratchet-pin-audit-harness to protect-main mirror ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Gate ratchet-pin-audit invariants on PRs ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Image size advisory in image-smoke ([#240](https://github.com/rvenutolo/linPEAS-flake/pull/240))
- Harden actionlint embedded-linter integration ([#239](https://github.com/rvenutolo/linPEAS-flake/pull/239))
- Add nixpkgs-hammering pre-commit hook ([#237](https://github.com/rvenutolo/linPEAS-flake/pull/237))
- Add hammer-shim parity check ([#182](https://github.com/rvenutolo/linPEAS-flake/pull/182))
- Add nixpkgs-hammering pre-commit hook ([#182](https://github.com/rvenutolo/linPEAS-flake/pull/182))
- Prune stale actions caches on cron + PR close
- Add size-label job
- Generate CHANGELOG.md and patch release body
- Enforce cliff.toml tag-pattern parity
- Add refresh-treefmt-config-test job
- Add refresh-ci-dag-test job
- Add refresh-scripts-reference-test job
- Add refresh-enforcement-matrix-test job
- Mirror renovate-config-validator as required context
- Add renovate-config-validator job + summary wiring
- Enforce setup-nix composite via setup-nix-required lint ([#222](https://github.com/rvenutolo/linPEAS-flake/pull/222))
- Add setup-nix-required lint job and register as required check
- Introduce setup-nix composite with authenticated tarball fetches ([#220](https://github.com/rvenutolo/linPEAS-flake/pull/220))
- Introduce setup-nix composite with authenticated tarball fetches
- Auto-refresh flake.lock for nixpkgs-unstable bumps
- Track nixpkgs-unstable input

### Chores
- Bump linpeas to 20260528-82c8c3b6 ([#280](https://github.com/rvenutolo/linPEAS-flake/pull/280))
- Refresh flake-show for linpeas 20260528-82c8c3b6
- Bump linpeas to 20260528-82c8c3b6
- Update flake.lock ([#279](https://github.com/rvenutolo/linPEAS-flake/pull/279))
- Update flake.lock
- Drop manual-bump hints now that Renovate manages them
- Triage scorecard-drift findings (drop 2 checks, pin commitlint) ([#265](https://github.com/rvenutolo/linPEAS-flake/pull/265))
- Triage scorecard-drift findings (drop 2 checks, pin commitlint)
- Add label-description for zizmor-drift label
- Bump codeql-action v3; revert spurious v4.3.0 dl-artifact ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Bump three force-moved action SHAs ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Guard against python run: without pyflakes wired
- Pin shellcheck path in actionlint hook
- Add size/XS through size/XL
- Add cliff-tag-pattern parity enforcer
- Add renovate-config-validator local + CI check (#183, #189) ([#229](https://github.com/rvenutolo/linPEAS-flake/pull/229))
- Wire renovate-config-validator into verify recipe
- Add renovate for renovate-config-validator
- Watch flake files in .envrc so direnv rebuilds on change ([#228](https://github.com/rvenutolo/linPEAS-flake/pull/228))
- Watch flake files in .envrc so direnv rebuilds on change
- Auto-TOC via mdformat-toc ([#224](https://github.com/rvenutolo/linPEAS-flake/pull/224))
- Auto-TOC via mdformat-toc
- Rename nixfmt-rfc-style to nixfmt ([#223](https://github.com/rvenutolo/linPEAS-flake/pull/223))
- Rename nixfmt-rfc-style to nixfmt
- Drop explicit pre-commit; let git-hooks.nix provide it ([#217](https://github.com/rvenutolo/linPEAS-flake/pull/217))
- Drop explicit pre-commit; let git-hooks.nix provide it
- Move devshell + CI tooling to nixpkgs-unstable; keep linpeas runtime on stable ([#195](https://github.com/rvenutolo/linPEAS-flake/pull/195))
- Move devShell tools to nixpkgs-unstable
- Move pre-commit hook tools to nixpkgs-unstable
- Move treefmt evaluator to nixpkgs-unstable
- Move mkdocs site to nixpkgs-unstable
- Add nixpkgs-unstable input + binding
- Expand auto-format and lint coverage to remaining tracked files ([#152](https://github.com/rvenutolo/linPEAS-flake/pull/152))
- Enable IndentSize check + drop LICENSE ec-checker exclude
- Drop [*.md] trim_trailing_whitespace override
- Add .envrc + justfile to treefmt; wire just --fmt
- Remove linpeas-bundle release artifact ([#150](https://github.com/rvenutolo/linPEAS-flake/pull/150))
- Drop orphan sbom-diff script and tests
- Drop bundle_url from dashboard generator and tests
- Drop bundle verification from verify-latest-release
- Drop bundle job from release-on-bump
- Drop bundle-smoke CI job and required-check
- Drop linpeas-bundle derivation
- Update flake.lock ([#145](https://github.com/rvenutolo/linPEAS-flake/pull/145))

### Documentation
- Link verification.md to backfill runbook
- Add scorecard signed-releases backfill procedure
- Note manifest idempotency under backfill-tag mode
- Index release-asset provenance sidecar invariant
- Document release-asset .intoto.jsonl sidecar contract
- Index release-asset blob sig invariant
- Document cosign verify-blob for release-asset sidecars
- Correct ratchet update guidance in pin audit ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Runbook for ratchet-pin-audit workflow ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Note burn-in notification path in runbook
- Runbook for reproducibility check workflow
- Replace flake.nix line numbers with grep anchors
- Runbook for actionlint embedded linters
- Document size labels and ignore-list parity
- Add cache-cleanup runbook and ops-hygiene invariants
- Add changelog generation runbook and invariant entries
- Seed changelog from historical release tags
- Add show-treefmt recipe to justfile
- Surface just-recipes and treefmt-config pages in mkdocs nav
- Add show-ci-dag recipe to justfile
- Surface CI DAG in mkdocs nav
- Surface Reference nav section and show-scripts recipe
- Add shdoc-style header annotations to all scripts
- Surface enforcement matrix in mkdocs nav and justfile
- Add generated invariant-enforcer matrix
- Annotate each invariant with enforcer metadata
- Alphabetize renovate-config-validator before renovate-invariants
- Wrap setup-nix doc in raw to escape mkdocs-macros
- Document setup-nix composite requirement
- Runbook covers nixpkgs-unstable bump policy
- Note prettier contract near pin JSON write
- Extract flake outputs section into dedicated reference doc ([#151](https://github.com/rvenutolo/linPEAS-flake/pull/151))
- Extract flake outputs tree into docs/reference/flake-outputs.md
- Fix stale bundle phrase in cosign intro
- Drop linpeas-bundle references
- Rework README Usage into per-artifact use-case examples ([#147](https://github.com/rvenutolo/linPEAS-flake/pull/147))
- Drop redundant 'Use case:' prefix in README Usage prose
- Rework README Usage into per-artifact use-case examples
- Frame docker.md container-audit example as smoke test

### Features
- Add backfill-tag mode to release-on-bump ([#277](https://github.com/rvenutolo/linPEAS-flake/pull/277))
- Backfill arm64 SBOM + sidecars from registry image
- Backfill amd64 SBOM + sidecars from registry image
- Backfill pin .sigstore + .intoto.jsonl on existing release
- Extend image/manifest/verify gates to honour backfill-tag
- Add backfill-tag workflow_dispatch input with mutex validation
- Emit .intoto.jsonl provenance sidecars on release assets ([#275](https://github.com/rvenutolo/linPEAS-flake/pull/275))
- Upload arm64 SBOM provenance bundle as release-asset sidecar
- Upload amd64 SBOM provenance bundle as release-asset sidecar
- Upload pin provenance bundle as release-asset sidecar
- Cosign sign-blob release-asset sidecars ([#270](https://github.com/rvenutolo/linPEAS-flake/pull/270))
- Verify release-asset blob signatures in daily cron
- Verify release-asset blob signatures at release time
- Sign arm64 SBOM with cosign sign-blob
- Sign amd64 SBOM with cosign sign-blob
- Sign linpeas-pin.json with cosign sign-blob
- Attach CycloneDX SBOMs to releases ([#269](https://github.com/rvenutolo/linPEAS-flake/pull/269))
- Attach arm64 CycloneDX SBOM to release
- Attach amd64 CycloneDX SBOM to release
- Scorecard-drift-check workflow with curated 11-check allowlist ([#260](https://github.com/rvenutolo/linPEAS-flake/pull/260))
- Add scorecard-drift-check workflow
- Add check-scorecard-threshold.sh + scorecard PAT runbook
- Add octoscan workflow vulnerability scanner ([#255](https://github.com/rvenutolo/linPEAS-flake/pull/255))
- Add octoscan workflow vulnerability scanner (closes #159)
- Actionlint cron drift-check workflow ([#251](https://github.com/rvenutolo/linPEAS-flake/pull/251))
- Actionlint cron drift-check workflow (closes #247)
- Expose actionlintWrapped as packages.actionlint-wrapped
- Zizmor cron drift-check workflow ([#248](https://github.com/rvenutolo/linPEAS-flake/pull/248))
- Zizmor cron drift-check workflow (closes #246)
- Add Grype as second-opinion image CVE scanner ([#244](https://github.com/rvenutolo/linPEAS-flake/pull/244))
- Add Grype as second-opinion image CVE scanner
- Add trufflehog secret scanner ([#243](https://github.com/rvenutolo/linPEAS-flake/pull/243))
- Add trufflehog secret scanner alongside gitleaks (closes #158)
- Ratchet pin audit workflow (closes #161) ([#242](https://github.com/rvenutolo/linPEAS-flake/pull/242))
- Ratchet-pin-audit notify body with per-reason runbook ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Ratchet-pin-audit emits typed drift/api/tool reasons ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Ratchet-pin-audit workflow skeleton ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Reproducibility check workflow ([#241](https://github.com/rvenutolo/linPEAS-flake/pull/241))
- Reproducibility-check workflow (closes #164)
- Compare-repro.sh + match-scenario test
- Post sticky PR comment with image-size delta vs main
- Report image size in image-smoke job summary
- Script to measure image compressed + closure sizes
- Pr size labeler and actions cache prune workflows ([#235](https://github.com/rvenutolo/linPEAS-flake/pull/235))
- Generate CHANGELOG.md from conventional commits ([#234](https://github.com/rvenutolo/linPEAS-flake/pull/234))
- Standalone just-recipes + treefmt-config reference pages ([#190](https://github.com/rvenutolo/linPEAS-flake/pull/190)) ([#233](https://github.com/rvenutolo/linPEAS-flake/pull/233))
- Publish just-recipes as standalone reference page
- Add refresh-treefmt-config generator + test
- Auto-generated CI DAG diagram ([#185](https://github.com/rvenutolo/linPEAS-flake/pull/185)) ([#232](https://github.com/rvenutolo/linPEAS-flake/pull/232))
- Auto-generate CI DAG diagram from ci.yml needs
- Shdoc-style scripts reference ([#184](https://github.com/rvenutolo/linPEAS-flake/pull/184)) ([#231](https://github.com/rvenutolo/linPEAS-flake/pull/231))
- Add refresh-scripts-reference generator and harness
- Add shdoc-style awk parser for script headers
- Invariant-enforcer matrix ([#186](https://github.com/rvenutolo/linPEAS-flake/pull/186)) ([#230](https://github.com/rvenutolo/linPEAS-flake/pull/230))
- Add enforcement-matrix-fresh pre-commit hook
- Add refresh-enforcement-matrix generator and harness
- Add renovate-config-validator hook
- Add check-renovate-config-validator + harness
- Add check-setup-nix-required lint script and harness
- Classify notify-workflow-result issues by finding vs infra ([#215](https://github.com/rvenutolo/linPEAS-flake/pull/215))
- Classify notify-workflow-result issues by finding vs infra
- Lint nix run nixpkgs#<pkg> must be pinned ([#213](https://github.com/rvenutolo/linPEAS-flake/pull/213))
- Lint nix run nixpkgs#<pkg> must be pinned
- Lint cosign verify pins identity + OIDC issuer ([#212](https://github.com/rvenutolo/linPEAS-flake/pull/212))
- Lint cosign verify pins identity + OIDC issuer
- Lint gh attestation verify pins --repo ([#211](https://github.com/rvenutolo/linPEAS-flake/pull/211))
- Lint gh attestation verify pins --repo
- Lint release-grade jobs include fork-guard if: clause ([#210](https://github.com/rvenutolo/linPEAS-flake/pull/210))
- Lint release-grade jobs include fork-guard if: clause
- Lint multi-line run: blocks start with set -Eeuo pipefail ([#209](https://github.com/rvenutolo/linPEAS-flake/pull/209))
- Lint multi-line run: blocks start with set -Eeuo pipefail
- Lint ci.yml jobs cross-checked against summary categories ([#208](https://github.com/rvenutolo/linPEAS-flake/pull/208))
- Lint ci.yml jobs cross-checked against summary categories
- Lint scripts/check-*.sh paired with tests/check-*.test.sh ([#207](https://github.com/rvenutolo/linPEAS-flake/pull/207))
- Lint scripts/check-*.sh paired with tests/check-*.test.sh
- Lint scripts/*.sh shebang + set -Eeuo pipefail ([#206](https://github.com/rvenutolo/linPEAS-flake/pull/206))
- Lint scripts/*.sh shebang + set -Eeuo pipefail
- Hard-ban pull_request_target trigger ([#205](https://github.com/rvenutolo/linPEAS-flake/pull/205))
- Hard-ban pull_request_target trigger
- Lint pull_request/push triggers declare branches main ([#202](https://github.com/rvenutolo/linPEAS-flake/pull/202))
- Lint pull_request/push triggers declare branches main
- Lint actions/upload-artifact uses if-no-files-found error ([#201](https://github.com/rvenutolo/linPEAS-flake/pull/201))
- Lint actions/upload-artifact uses if-no-files-found error
- Lint actions/checkout sets persist-credentials false ([#200](https://github.com/rvenutolo/linPEAS-flake/pull/200))
- Lint actions/checkout sets persist-credentials false
- Lint every workflow declares concurrency group ([#199](https://github.com/rvenutolo/linPEAS-flake/pull/199))
- Lint every workflow declares concurrency group
- Lint every workflow job declares timeout-minutes ([#198](https://github.com/rvenutolo/linPEAS-flake/pull/198))
- Lint every workflow job declares timeout-minutes
- Generate derived doc blocks from source-of-truth files ([#146](https://github.com/rvenutolo/linPEAS-flake/pull/146))

### Fixes
- Drop dead link to runbook from verification.md
- Upload SBOM files to release explicitly ([#274](https://github.com/rvenutolo/linPEAS-flake/pull/274))
- Upload SBOM files to release explicitly
- Ungate pin sign-blob from exists check ([#273](https://github.com/rvenutolo/linPEAS-flake/pull/273))
- Ungate pin sign-blob from exists check
- Add checkout step to manifest job ([#272](https://github.com/rvenutolo/linPEAS-flake/pull/272))
- Add checkout step to manifest job
- Write scorecard JSON to file via --output, not stdout redirect ([#264](https://github.com/rvenutolo/linPEAS-flake/pull/264))
- Write scorecard JSON to file via --output, not stdout redirect
- Silence scorecard info logs leaking into stdout JSON ([#263](https://github.com/rvenutolo/linPEAS-flake/pull/263))
- Silence scorecard info logs leaking into stdout JSON
- Enable SCORECARD_EXPERIMENTAL for SBOM + Webhooks checks ([#262](https://github.com/rvenutolo/linPEAS-flake/pull/262))
- Enable SCORECARD_EXPERIMENTAL for SBOM + Webhooks checks
- Reject empty stdin in check-scorecard-threshold.sh
- Drop directory positional from actionlint-drift probe ([#253](https://github.com/rvenutolo/linPEAS-flake/pull/253))
- Drop directory positional from actionlint-drift probe
- Decompress OCI image tarball before grype scan
- Strip monorepo subpath + skip self-refs in pin audit ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Use nix develop for ratchet; merge gh-api calls ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Unconditionally resolve annotated tags in pin audit ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Use absolute URL + nav entry for repro runbook
- Unindent issue-body heredoc so markdown renders
- Handle gzipped image when extracting manifest
- Upload linpeas tar; diffoscope both pairs on mismatch
- Absolute URL for runbook link in step summary
- Drop store-path fields from compare loop
- Trap-based worktree cleanup in measure-main step
- Measure uncompressed tar size, not derivation closure
- Don't merge stderr into JSON capture in happy-path scenario
- Extend pyflakes guard to pip3 and sudo-prefixed forms
- Broaden pyflakes guard regex to catch inline run: forms
- Register hammer-shim-parity + fix pin-diff-isolated path bug
- Use App token for gh release edit
- Decouple verify from changelog job
- Relativize matrix link paths to page location
- Use comma for within-field separator in enforcer annotations
- Canonicalize TOC nested-list indent to 2-space
- Scrub PYTHONPATH from pre-commit wrapper ([#226](https://github.com/rvenutolo/linPEAS-flake/pull/226))
- Scrub PYTHONPATH from pre-commit wrapper
- Pipe refresh-precommit-table output through treefmt ([#221](https://github.com/rvenutolo/linPEAS-flake/pull/221))
- Pipe refresh-precommit-table output through treefmt
- Skip self when scanning
- Drop bundle from refresh-just-recipes assertion
- Use absolute README URL in docker.md link (mkdocs strict)

### Style
- Align justfile to 2-space indent using newer just
- Align continuation indents to multiples of two
- Apply treefmt repo-wide (justfile reflow)

### Tests
- Invariant + fixtures for ratchet-pin-audit shape ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Missing-input scenario for compare-repro.sh
- Mismatch scenarios for compare-repro.sh
- Smoke-test actionlint shellcheck integration
- Add fixtures (good + bad cases)
- Add fixtures for setup-nix-required lint

## [20260521-859cab5f] - 2026-05-22

### Build
- Register check-orphan-invariants and check-doc-anchors hooks

### CI
- Add check-orphan-invariants and check-doc-anchors jobs
- Exclude tests/fixtures/** to match flake.nix
- Add settings-posture-harness job
- Replace commitizen with commitlint for full CI parity ([#106](https://github.com/rvenutolo/linPEAS-flake/pull/106))
- Add local commitlint pre-commit hook for CI parity
- Cap every job with timeout-minutes; tighten matrix + pages self-ref
- Fail on CRITICAL findings and notify
- Fail on CRITICAL CVEs and notify
- Add gitleaks, dependency-review, labeler workflows ([#88](https://github.com/rvenutolo/linPEAS-flake/pull/88))
- Add gitleaks, dependency-review, labeler workflows
- Drop hydra unstable-Nix URL from coverage matrix

### Chores
- Bump linpeas to 20260521-859cab5f ([#142](https://github.com/rvenutolo/linPEAS-flake/pull/142))
- Refresh README flake-show for linpeas 20260521-859cab5f
- Bump linpeas to 20260521-859cab5f
- Update flake.lock
- Enable dependency dashboard
- Scrub ephemeral references from tracked files ([#110](https://github.com/rvenutolo/linPEAS-flake/pull/110))
- Scrub ephemeral references from tracked files
- Register protect-main-drift-check as required ([#104](https://github.com/rvenutolo/linPEAS-flake/pull/104))
- Register protect-main-drift-check as a required check
- Best-practices review follow-ups ([#90](https://github.com/rvenutolo/linPEAS-flake/pull/90))
- Tidy lint config and add a single-shot verify recipe
- Bump actions/github-script v7.1.0 -> v9.0.0 in notify composite
- Add check-jsonschema to required-check set
- Add doc-quality hooks + lychee recipe for local CI parity ([#83](https://github.com/rvenutolo/linPEAS-flake/pull/83))
- Add doc-quality hooks + lychee recipe for local CI parity
- Strip remaining ephemeral planning tokens
- Strip ephemeral planning refs from tracked files
- Add CODEOWNERS and issue templates ([#74](https://github.com/rvenutolo/linPEAS-flake/pull/74))
- Track NixOS/nixpkgs stable branch in flake.nix ([#64](https://github.com/rvenutolo/linPEAS-flake/pull/64))
- Bump nixpkgs to nixos-25.11 ([#63](https://github.com/rvenutolo/linPEAS-flake/pull/63))
- Track cachix/git-hooks.nix flake input ([#62](https://github.com/rvenutolo/linPEAS-flake/pull/62))
- Split DOCKERHUB_TOKEN into push + delete PATs (P4.5) ([#58](https://github.com/rvenutolo/linPEAS-flake/pull/58))
- Add step-security/harden-runner (audit mode, P4.4) ([#57](https://github.com/rvenutolo/linPEAS-flake/pull/57))
- Tighten artifact retention to 1d (P4.3) ([#56](https://github.com/rvenutolo/linPEAS-flake/pull/56))
- Attest SBOMs for bundle + OCI image (P4.2) ([#55](https://github.com/rvenutolo/linPEAS-flake/pull/55))
- Add OCI image CVE scan (P4.1) ([#54](https://github.com/rvenutolo/linPEAS-flake/pull/54))
- Add SHA-pin lint for every uses: (P3.5) ([#53](https://github.com/rvenutolo/linPEAS-flake/pull/53))
- Add renovate.json invariant lint (P3.4) ([#52](https://github.com/rvenutolo/linPEAS-flake/pull/52))
- Switch allowed_actions to selected with vendor allowlist (P3.1) ([#47](https://github.com/rvenutolo/linPEAS-flake/pull/47))
- Add tag protection ruleset + drift lint (P2.3) ([#45](https://github.com/rvenutolo/linPEAS-flake/pull/45))
- Add minimumReleaseAge + scope automerge by manager (P2.1) ([#43](https://github.com/rvenutolo/linPEAS-flake/pull/43))
- Apply Wave A settings hardening (P1) ([#39](https://github.com/rvenutolo/linPEAS-flake/pull/39))
- Remove OpenSSF Scorecard (P0) ([#37](https://github.com/rvenutolo/linPEAS-flake/pull/37))
- Drop DOCKERHUB_TOKEN calendar rotation; document Delete scope rationale ([#23](https://github.com/rvenutolo/linPEAS-flake/pull/23)) ([#36](https://github.com/rvenutolo/linPEAS-flake/pull/36))
- Enforce PR-triggered workflow secret allowlist (CIW-4) ([#33](https://github.com/rvenutolo/linPEAS-flake/pull/33))
- Shift pages cron to 14:00 UTC + document schedule ([#32](https://github.com/rvenutolo/linPEAS-flake/pull/32))
- Mirror Docker Hub triage hints into release-on-bump notify body ([#31](https://github.com/rvenutolo/linPEAS-flake/pull/31))
- Security review lows cleanup batch ([#19](https://github.com/rvenutolo/linPEAS-flake/pull/19))
- Push docker.io before ghcr to avoid half-published state ([#17](https://github.com/rvenutolo/linPEAS-flake/pull/17))
- Pin notify-workflow-result composite by sha ([#15](https://github.com/rvenutolo/linPEAS-flake/pull/15))
- Add zizmor pre-commit hook and address findings ([#7](https://github.com/rvenutolo/linPEAS-flake/pull/7))
- Harden CI, build, and auto-update against supply-chain risks ([#3](https://github.com/rvenutolo/linPEAS-flake/pull/3))

### Documentation
- Document platform support matrix and x86_64-darwin untested status ([#140](https://github.com/rvenutolo/linPEAS-flake/pull/140))
- Document platform support matrix and x86_64-darwin untested status
- State dev toolchain comes from flake devShell
- Extract invariant index to tracked docs/invariant-index.md
- Add consumer-flake guide, threat model, and Renovate dashboard surfacing ([#129](https://github.com/rvenutolo/linPEAS-flake/pull/129))
- Add security threat-model overview
- Surface Renovate dependency dashboard in README
- Add consumer-flake usage guide
- Extract security/CI invariants from CLAUDE.md into tracked docs ([#105](https://github.com/rvenutolo/linPEAS-flake/pull/105))
- Extract dockerhub token-split + notify-parity invariants from CLAUDE.md
- Add PR auto-labeling reference
- Extract treefmt/readme-auto-block invariants from CLAUDE.md
- Extract OCI image + manifest digest invariants from CLAUDE.md
- Extract bundle shebang invariant from CLAUDE.md
- Extract flake-input credential/refresh invariants from CLAUDE.md
- Extract cron/attribution/pages invariants from CLAUDE.md
- Extract pin/release invariants from CLAUDE.md
- Extract protect-main ruleset invariant from CLAUDE.md
- Extract trust-model invariants from CLAUDE.md
- Fix Prettier list-marker corruption in dependency review section
- Extract verification/cron-attribution invariants from CLAUDE.md
- Extract SHA-pinning/renovate/tag-protection invariants from CLAUDE.md
- Document expected breakage surface of nixpkgs bumps ([#96](https://github.com/rvenutolo/linPEAS-flake/pull/96))
- Document expected breakage surface of nixpkgs bumps
- Move Docker Hub half-published recovery to tracked runbook ([#97](https://github.com/rvenutolo/linPEAS-flake/pull/97))
- Move Docker Hub half-published recovery to tracked runbook
- Drop stale bump-credential refs and ephemeral planning tokens ([#92](https://github.com/rvenutolo/linPEAS-flake/pull/92))
- Drop stale bump-credential refs and ephemeral planning tokens
- Explain markdownlint disables and the tests/fixtures pattern
- Add CONTRIBUTING.md and PR template
- Drop non-functional / transitional posture references
- Ephemeral-ref cleanup + README/runbook refresh ([#82](https://github.com/rvenutolo/linPEAS-flake/pull/82))
- Collapse README to overview, link runbooks
- Add git workflow + repository configuration runbooks
- Document lint required checks + merge policy
- Reflect merge-commit posture + App-signed bot commits
- Correct release-on-bump gh release flags in diagram ([#67](https://github.com/rvenutolo/linPEAS-flake/pull/67))
- Refresh README + arch/security docs for Wave-P3/P4 changes ([#66](https://github.com/rvenutolo/linPEAS-flake/pull/66))
- Add flake-input bump runbook + Renovate descriptions ([#65](https://github.com/rvenutolo/linPEAS-flake/pull/65))
- Refresh README for recent CI, cron, and watchdog changes ([#34](https://github.com/rvenutolo/linPEAS-flake/pull/34))
- Document scorecard trigger, codeql advisory scope, manifest verify gap (CIW-5/CIW-6/SC-POST-8) ([#21](https://github.com/rvenutolo/linPEAS-flake/pull/21))
- Add self-deprecating over-engineering note to README

### Features
- Generate README CI summary from required-checks + category map
- Generate README just-recipes list from justfile
- Generate pre-commit hook table from flake manifest
- Lint strict GITHUB_TOKEN min-permissions ([#137](https://github.com/rvenutolo/linPEAS-flake/pull/137))
- Lint strict GITHUB_TOKEN min-permissions
- Lint every workflow job starts with harden-runner ([#136](https://github.com/rvenutolo/linPEAS-flake/pull/136))
- Lint every workflow job starts with harden-runner
- Sign bundle + images keyless with cosign ([#135](https://github.com/rvenutolo/linPEAS-flake/pull/135))
- Sign bundle + images keyless with cosign
- Embed SBOM diff vs previous release in release notes ([#134](https://github.com/rvenutolo/linPEAS-flake/pull/134))
- Embed SBOM diff vs previous release in release notes
- Add bump-lag chart ([#133](https://github.com/rvenutolo/linPEAS-flake/pull/133))
- Add bump-lag chart
- Extract invariant index and add doc-link lint checks ([#131](https://github.com/rvenutolo/linPEAS-flake/pull/131))
- Require check-orphan-invariants and check-doc-anchors
- Add check-doc-anchors lint
- Add check-orphan-invariants lint
- Add allowed-actions API drift-check ([#108](https://github.com/rvenutolo/linPEAS-flake/pull/108))
- Add allowed-actions API drift-check
- Add settings-posture drift-check ([#107](https://github.com/rvenutolo/linPEAS-flake/pull/107))
- Add settings-posture drift-check
- Add protect-main-drift-check required CI job ([#101](https://github.com/rvenutolo/linPEAS-flake/pull/101))
- Add protect-main-drift-check required CI job
- Re-assert :latest manifest parity + dockerhub-sync no-op cause ([#98](https://github.com/rvenutolo/linPEAS-flake/pull/98))
- Add org.opencontainers.image.revision label ([#95](https://github.com/rvenutolo/linPEAS-flake/pull/95))
- Add org.opencontainers.image.revision label
- Add pin-diff-isolated required check ([#100](https://github.com/rvenutolo/linPEAS-flake/pull/100))
- Add pin-diff-isolated required check
- Add pre-commit-hooks-sha-parity required check ([#99](https://github.com/rvenutolo/linPEAS-flake/pull/99))
- Add pre-commit-hooks-sha-parity required check
- Re-assert :latest manifest parity + dockerhub-sync no-op cause
- Auto-refresh flake.lock on Renovate flake-input PRs
- Expose linpeas + linpeas-bundle as flake checks
- Add mdformat for markdown auto-formatting ([#84](https://github.com/rvenutolo/linPEAS-flake/pull/84))
- Add mdformat for markdown auto-formatting
- Add check-jsonschema for repo config validation ([#85](https://github.com/rvenutolo/linPEAS-flake/pull/85))
- Add check-jsonschema for repo config validation
- Add taplo as treefmt's TOML formatter ([#87](https://github.com/rvenutolo/linPEAS-flake/pull/87))
- Add taplo as treefmt's TOML formatter
- Add pr-title-lint required check + merge-commit-posture docs ([#81](https://github.com/rvenutolo/linPEAS-flake/pull/81))
- Add pr-title-lint required check
- Add lychee link checker + README badges ([#77](https://github.com/rvenutolo/linPEAS-flake/pull/77))
- Add commitlint required check (Conventional Commits) ([#76](https://github.com/rvenutolo/linPEAS-flake/pull/76))
- Add markdownlint, typos, editorconfig required checks ([#75](https://github.com/rvenutolo/linPEAS-flake/pull/75))
- Add force-republish dispatch to release-on-bump ([#71](https://github.com/rvenutolo/linPEAS-flake/pull/71))
- Sync README.md to Docker Hub on push to main ([#14](https://github.com/rvenutolo/linPEAS-flake/pull/14))
- Multi-arch image (amd64 + arm64) ([#13](https://github.com/rvenutolo/linPEAS-flake/pull/13))
- Mirror release image to Docker Hub ([#12](https://github.com/rvenutolo/linPEAS-flake/pull/12))
- Add stale-pin-check watchdog cron ([#11](https://github.com/rvenutolo/linPEAS-flake/pull/11))
- Add notify-workflow-result composite + wire all crons ([#10](https://github.com/rvenutolo/linPEAS-flake/pull/10))
- Add OpenSSF Scorecard workflow and README badge ([#9](https://github.com/rvenutolo/linPEAS-flake/pull/9))
- Add CodeQL workflow for actions analysis ([#8](https://github.com/rvenutolo/linPEAS-flake/pull/8))
- Ship grep/sed/awk/find/ps in OCI image; document use cases
- Add GitHub Pages site (landing + docs + dashboard) ([#4](https://github.com/rvenutolo/linPEAS-flake/pull/4))

### Fixes
- Add orphaned security pages to mkdocs nav ([#132](https://github.com/rvenutolo/linPEAS-flake/pull/132))
- Add orphaned security pages to mkdocs nav
- Repair slug newline and SIGPIPE false-positives in check-doc-anchors
- Add invariant-index entry for settings-drift-checker runbook
- Drop cross-tree links and add new pages to nav
- Drop merge-method fields from settings-posture probe ([#128](https://github.com/rvenutolo/linPEAS-flake/pull/128))
- Drop merge-method fields from settings-posture probe
- Add api-version header + scripts/ lint rule ([#109](https://github.com/rvenutolo/linPEAS-flake/pull/109))
- Add X-GitHub-Api-Version header to gen-dashboard-data + lint
- Use App token for settings-posture drift-check
- Wrap GHA expression in trust-model in Jinja2 raw block
- Add head_repository gate to renovate-flake-lock-refresh ([#93](https://github.com/rvenutolo/linPEAS-flake/pull/93))
- Add head_repository gate to renovate-flake-lock-refresh
- Guard image-cve-scan CRITICAL count against non-numeric severity ([#94](https://github.com/rvenutolo/linPEAS-flake/pull/94))
- Guard image-cve-scan CRITICAL count against non-numeric severity
- Avoid markdownlint ul-style false positive
- Exclude Jinja-templated and auth-required URLs from lychee ([#78](https://github.com/rvenutolo/linPEAS-flake/pull/78))
- Verify per-arch image digests in verify-latest-release ([#73](https://github.com/rvenutolo/linPEAS-flake/pull/73))
- Set GH_TOKEN on update-linpeas bump pin step ([#70](https://github.com/rvenutolo/linPEAS-flake/pull/70))
- Re-validate pin in push-and-merge sanity check (P3.3) ([#51](https://github.com/rvenutolo/linPEAS-flake/pull/51))
- Drop unsupported --commit-lock-file=false flag ([#50](https://github.com/rvenutolo/linPEAS-flake/pull/50))
- Align tag-protection drift messages, run harness first ([#46](https://github.com/rvenutolo/linPEAS-flake/pull/46))
- Pin release-create target to triggering commit SHA (P2.2) ([#44](https://github.com/rvenutolo/linPEAS-flake/pull/44))
- Wire settings-posture into mkdocs nav, drop dead refs ([#42](https://github.com/rvenutolo/linPEAS-flake/pull/42))
- Bump upload-pages-artifact to v5.0.0 (SHA pin compliance) ([#41](https://github.com/rvenutolo/linPEAS-flake/pull/41))
- Pin gh api version header and attribute stale-pin failures ([#30](https://github.com/rvenutolo/linPEAS-flake/pull/30))
- Close docker hub verification gaps (SC-POST-1/2/3) ([#18](https://github.com/rvenutolo/linPEAS-flake/pull/18))
- Validate upstream peass-ng tag shape before interpolation ([#16](https://github.com/rvenutolo/linPEAS-flake/pull/16))

### Refactor
- Name preCommitHooks and expose description manifest
- Drop commitizen now that commitlint covers subject
- Attribute verify-latest-release failures by reason ([#103](https://github.com/rvenutolo/linPEAS-flake/pull/103))
- Attribute verify-latest-release failures by reason
- Drop docker login from verify-only paths ([#102](https://github.com/rvenutolo/linPEAS-flake/pull/102))
- Drop docker login from verify-only paths
- Switch Nix formatter to nixfmt-rfc-style ([#86](https://github.com/rvenutolo/linPEAS-flake/pull/86))
- Switch Nix formatter from nixpkgs-fmt to nixfmt-rfc-style
- Bump workflows authenticate as GitHub App for signed REST commits ([#80](https://github.com/rvenutolo/linPEAS-flake/pull/80))
- Bump workflows authenticate as GitHub App for signed REST commits
- Trigger on release completion, not README push (P4.6) ([#59](https://github.com/rvenutolo/linPEAS-flake/pull/59))
- Split PAT off third-party action env (P3.2) ([#48](https://github.com/rvenutolo/linPEAS-flake/pull/48))
- BUMP_PAT blast-radius reduction phase 1 (AU-P-1/P-2/P-4) ([#20](https://github.com/rvenutolo/linPEAS-flake/pull/20))

### Style
- Reformat markdown via mdformat

### Tests
- Add fixtures and harness for check-doc-anchors
- Add harness for check-orphan-invariants
- Cover gen-dashboard-data.sh security hard-fail branches ([#6](https://github.com/rvenutolo/linPEAS-flake/pull/6))
- Assert bundle shebang rewrite in bundle-smoke ([#5](https://github.com/rvenutolo/linPEAS-flake/pull/5))
- Cover image tooling + real linpeas check in image-smoke

## [20260510-cd4bd619] - 2026-05-16

### CI
- Add daily SLSA attestation re-verification of latest release
- Add Renovate config (Friday batch, automerge, Nix-version regex manager)
- Add release-on-bump workflow with SLSA attestation, bundles, ghcr image, sync verify
- Add weekly flake.lock updater
- Add daily linpeas pin updater with PR + auto-merge
- Add CI workflow + yamllint config for renovate marker comments

### Chores
- Bump linpeas to 20260510-cd4bd619 ([#2](https://github.com/rvenutolo/linPEAS-flake/pull/2))
- Bootstrap repo with ignore/attribute/editor configs

### Documentation
- Add README + harden refresh-flake-show.sh
- Add SECURITY.md (resolve treefmt shfmt config)
- Add MIT license

### Features
- Add helper scripts + enable shfmt editorconfig
- Add linpeas-bundle as raw linpeas.sh copy with portable shebang
- Add linpeas-image OCI output
- Add devShell + pin pre-commit-hooks for nixos-25.05 compat
- Add pre-commit-hooks with deadnix, statix, actionlint, yamllint, shellcheck
- Add treefmt-nix unified formatter (nixpkgs-fmt, prettier, shfmt)
- Add minimal flake with linpeas package, app, overlay
- Seed linpeas pin at 20260510-cd4bd619

### Fixes
- Skip readme-flake-show-fresh hook inside nix build sandbox
- Use Entrypoint not Cmd in linpeas-image so docker run args reach linpeas
- Exclude justfile from shellcheck and add bash directive to .envrc

### Refactor
- Merge programs attrset in treefmt.nix to satisfy statix

### Tests
- Roll pin back to 20260506-5a27482a to exercise auto-bump pipeline ([#1](https://github.com/rvenutolo/linPEAS-flake/pull/1))


