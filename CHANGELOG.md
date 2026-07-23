# Changelog

All notable changes to this project are auto-generated from
conventional commits between release tags. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The release
tag matches the upstream peass-ng pin version (`YYYYMMDD-<sha>`); this
repo is not on a semver track.

## Unreleased

### Breaking Changes
- Drop darwin outputs, harden flake-eval observability ([#504](https://github.com/rvenutolo/linPEAS-flake/pull/504))

### CI
- Add monthly docs-audit reminder ([#481](https://github.com/rvenutolo/linPEAS-flake/pull/481))
- Retry watchdog API requests on transient GitHub 5xx ([#477](https://github.com/rvenutolo/linPEAS-flake/pull/477))

### Chores
- Drop local skills gitignore ([#475](https://github.com/rvenutolo/linPEAS-flake/pull/475))

### Documentation
- Correct security-doc inaccuracies, guard RW-token claim, fix stale comments ([#516](https://github.com/rvenutolo/linPEAS-flake/pull/516))
- Correct release VERSION shape to canonical pin regex ([#488](https://github.com/rvenutolo/linPEAS-flake/pull/488))
- Correct SBOM attestation predicate to CycloneDX ([#487](https://github.com/rvenutolo/linPEAS-flake/pull/487))
- Fix CI/verify/formatter prose drift ([#486](https://github.com/rvenutolo/linPEAS-flake/pull/486))
- Correct bump-PR author and split bundled invariant entry ([#485](https://github.com/rvenutolo/linPEAS-flake/pull/485))
- Correct CI, release-pipeline, and runbook claims ([#480](https://github.com/rvenutolo/linPEAS-flake/pull/480))
- Fix stale CI job and hook references ([#470](https://github.com/rvenutolo/linPEAS-flake/pull/470))

### Features
- Enforce DOCKERHUB_TOKEN scope split; reword bindings to consumption ([#503](https://github.com/rvenutolo/linPEAS-flake/pull/503))
- Enforce bump-script integrity guards 1-3 ([#501](https://github.com/rvenutolo/linPEAS-flake/pull/501))
- Add multi-agent-review skill (/repo-review) ([#498](https://github.com/rvenutolo/linPEAS-flake/pull/498))

### Fixes
- Assert linpeas pin version is the tag segment in its url ([#521](https://github.com/rvenutolo/linPEAS-flake/pull/521))
- Stop octoscan masking a per-file scanner error behind a finding ([#520](https://github.com/rvenutolo/linPEAS-flake/pull/520))
- Parse uses: with yq so flow-style refs cannot bypass SHA-pin lint ([#519](https://github.com/rvenutolo/linPEAS-flake/pull/519))
- Harden refresh-* generators against stale-block false-greens ([#517](https://github.com/rvenutolo/linPEAS-flake/pull/517))
- Soft-fall-back gen-dashboard-data on empty bump_pr_json ([#515](https://github.com/rvenutolo/linPEAS-flake/pull/515))
- Fail verify cron on any cosign image-signature failure ([#490](https://github.com/rvenutolo/linPEAS-flake/pull/490))
- Close silent-pass bugs in workflow-lint enforcers ([#489](https://github.com/rvenutolo/linPEAS-flake/pull/489))
- Confine ci-watchdog per-PR errors to the erroring PR ([#479](https://github.com/rvenutolo/linPEAS-flake/pull/479))
- Drop upstream nix from devshell in favor of host Determinate nix ([#476](https://github.com/rvenutolo/linPEAS-flake/pull/476))
- Catch sbom-action and gh-release-upload egress gaps ([#474](https://github.com/rvenutolo/linPEAS-flake/pull/474))
- Allowlist uploads.github.com in release image jobs ([#472](https://github.com/rvenutolo/linPEAS-flake/pull/472))
- Allowlist raw.githubusercontent.com in release image jobs ([#471](https://github.com/rvenutolo/linPEAS-flake/pull/471))

### Refactor
- Harden multi-agent-review workflow template ([#499](https://github.com/rvenutolo/linPEAS-flake/pull/499))
- Single-source the linpeas derivation across pin and shim ([#491](https://github.com/rvenutolo/linPEAS-flake/pull/491))

### Tests
- Wire the 14 orphan test harnesses into a runner + reachability guard ([#518](https://github.com/rvenutolo/linPEAS-flake/pull/518))
- Backfill coverage for five scanner/rewriter checks ([#497](https://github.com/rvenutolo/linPEAS-flake/pull/497))
- Backfill coverage for four generator/harness checks ([#496](https://github.com/rvenutolo/linPEAS-flake/pull/496))
- Backfill negative fixtures for five doc/script-scan checks ([#495](https://github.com/rvenutolo/linPEAS-flake/pull/495))
- Backfill negative fixtures for five posture/ratchet checks ([#494](https://github.com/rvenutolo/linPEAS-flake/pull/494))
- Cover workflow-shape null/flow gaps; fix present-null trigger bug ([#493](https://github.com/rvenutolo/linPEAS-flake/pull/493))
- Close yq-unparsable silent-pass gap in three workflow-lint checks ([#492](https://github.com/rvenutolo/linPEAS-flake/pull/492))

## [20260715-81d3c7f8] - 2026-07-15

### CI
- Drop SAST from curated scorecard check list ([#446](https://github.com/rvenutolo/linPEAS-flake/pull/446))

### Chores
- Bump linpeas to 20260715-81d3c7f8 ([#468](https://github.com/rvenutolo/linPEAS-flake/pull/468))
- Route docs-audit skill through slash command only ([#467](https://github.com/rvenutolo/linPEAS-flake/pull/467))
- Remove dead DeterminateSystems/* from Actions allowlist ([#456](https://github.com/rvenutolo/linPEAS-flake/pull/456))

### Features
- Lint egress allowlists against each job's tool inventory ([#453](https://github.com/rvenutolo/linPEAS-flake/pull/453))
- Add bounded CI retry watchdog for stuck bot PRs ([#452](https://github.com/rvenutolo/linPEAS-flake/pull/452))

### Fixes
- Stop flake-outputs.md drift and gate its freshness ([#466](https://github.com/rvenutolo/linPEAS-flake/pull/466))
- Let backfill-tag skip image jobs on image-less releases ([#465](https://github.com/rvenutolo/linPEAS-flake/pull/465))
- Guard jq substitutions in ratchet-pin-audit so failures emit a typed reason ([#462](https://github.com/rvenutolo/linPEAS-flake/pull/462))
- Stop ratchet-pin-audit flagging tag-object pins and floating majors ([#458](https://github.com/rvenutolo/linPEAS-flake/pull/458))
- Use portable DNS probe in setup-nix and degrade on timeout ([#447](https://github.com/rvenutolo/linPEAS-flake/pull/447))
- Swap gh api --field/--raw-field on force-rebase PATCH ([#448](https://github.com/rvenutolo/linPEAS-flake/pull/448))
- Allow sigstore timestamp and manifest signing egress ([#445](https://github.com/rvenutolo/linPEAS-flake/pull/445))
- Allow nixos.org egress in links workflow ([#444](https://github.com/rvenutolo/linPEAS-flake/pull/444))

### Refactor
- Remove flakehub-cache action and its egress hosts ([#451](https://github.com/rvenutolo/linPEAS-flake/pull/451))

### Tests
- Add lightweight-tag force-move case to classify-pin-ref matrix ([#463](https://github.com/rvenutolo/linPEAS-flake/pull/463))

## [20260708-abaa95f3] - 2026-07-14

### Chores
- Bump linpeas to 20260708-abaa95f3 ([#428](https://github.com/rvenutolo/linPEAS-flake/pull/428))
- Update flake.lock ([#429](https://github.com/rvenutolo/linPEAS-flake/pull/429))
- Update flake.lock ([#427](https://github.com/rvenutolo/linPEAS-flake/pull/427))

### Fixes
- Allow release-assets.githubusercontent.com egress in codeql ([#443](https://github.com/rvenutolo/linPEAS-flake/pull/443))

## [20260701-584b0e93] - 2026-07-01

### Chores
- Bump linpeas to 20260701-584b0e93 ([#426](https://github.com/rvenutolo/linPEAS-flake/pull/426))

## [20260629-0cf8c387] - 2026-06-30

### Chores
- Bump linpeas to 20260629-0cf8c387 ([#425](https://github.com/rvenutolo/linPEAS-flake/pull/425))

## [20260629-d458af0e] - 2026-06-29

### Chores
- Bump linpeas to 20260629-d458af0e ([#424](https://github.com/rvenutolo/linPEAS-flake/pull/424))

## [20260624-872a1386] - 2026-06-25

### CI
- Enforce harden-runner block mode and document the policy ([#412](https://github.com/rvenutolo/linPEAS-flake/pull/412))
- Switch harden-runner to block mode for remaining workflows ([#411](https://github.com/rvenutolo/linPEAS-flake/pull/411))
- Switch harden-runner to block mode for credential-bearing workflows ([#409](https://github.com/rvenutolo/linPEAS-flake/pull/409))
- Switch harden-runner to block mode for PR-triggered workflows ([#408](https://github.com/rvenutolo/linPEAS-flake/pull/408))
- Guard git-cliff output against duplicate PR links ([#401](https://github.com/rvenutolo/linPEAS-flake/pull/401))
- Watch nix/hooks in manifest-reading freshness filters ([#400](https://github.com/rvenutolo/linPEAS-flake/pull/400))
- Single-source workflow cron schedules + ban restatements ([#398](https://github.com/rvenutolo/linPEAS-flake/pull/398))
- Parity-check required-checks.md table against the ruleset mirror ([#330](https://github.com/rvenutolo/linPEAS-flake/pull/330))
- Raise timeouts on flakehub-cache cron jobs for upload headroom ([#327](https://github.com/rvenutolo/linPEAS-flake/pull/327))
- Promote 11 advisory CI jobs to required status checks ([#321](https://github.com/rvenutolo/linPEAS-flake/pull/321))
- Retime crons to daily 08:00-10:00 UTC and weekly Friday 05:00-07:00 UTC ([#320](https://github.com/rvenutolo/linPEAS-flake/pull/320))
- Move coverage matrix and image CVE scans to weekly cron workflows ([#319](https://github.com/rvenutolo/linPEAS-flake/pull/319))
- Remove actionlint-drift-check; drop cron-table-drift-check cron ([#318](https://github.com/rvenutolo/linPEAS-flake/pull/318))

### Chores
- Bump linpeas to 20260624-872a1386 ([#420](https://github.com/rvenutolo/linPEAS-flake/pull/420))
- Drop Administration from SCORECARD_PAT invariant scope ([#375](https://github.com/rvenutolo/linPEAS-flake/pull/375))
- Update flake.lock ([#344](https://github.com/rvenutolo/linPEAS-flake/pull/344))
- Remove image size monitoring ([#303](https://github.com/rvenutolo/linPEAS-flake/pull/303))

### Documentation
- Add nav-orphaned docs to mkdocs site navigation ([#405](https://github.com/rvenutolo/linPEAS-flake/pull/405))
- Fix dead refs to nonexistent CI job and devShell ([#404](https://github.com/rvenutolo/linPEAS-flake/pull/404))
- Fix assorted factual drift in hand-written prose ([#403](https://github.com/rvenutolo/linPEAS-flake/pull/403))
- Map lint member checks to their group CI jobs ([#402](https://github.com/rvenutolo/linPEAS-flake/pull/402))
- Fix changelog PR-link duplication, scorecard count, and stale cron/ephemeral references ([#378](https://github.com/rvenutolo/linPEAS-flake/pull/378))
- Index the lean lint-shell routing invariant ([#353](https://github.com/rvenutolo/linPEAS-flake/pull/353))
- Document workflow-scanner division of labor ([#341](https://github.com/rvenutolo/linPEAS-flake/pull/341))
- Align SECURITY.md posture-monitoring section with codeql.yml ([#328](https://github.com/rvenutolo/linPEAS-flake/pull/328))

### Features
- Enforce the ephemeral-reference ban with a CI lint ([#397](https://github.com/rvenutolo/linPEAS-flake/pull/397))
- Deterministic ephemeral-token + internal-link sweeps in docs-correctness-audit ([#392](https://github.com/rvenutolo/linPEAS-flake/pull/392))
- Add invoke-only docs-correctness-audit skill ([#388](https://github.com/rvenutolo/linPEAS-flake/pull/388))
- Gate auto-merge workflows on prior PR state ([#372](https://github.com/rvenutolo/linPEAS-flake/pull/372))
- Pin and verify integration_id on protect-main required checks ([#371](https://github.com/rvenutolo/linPEAS-flake/pull/371))
- Treat App-token-minting jobs as fork-guard privileged ([#370](https://github.com/rvenutolo/linPEAS-flake/pull/370))
- Enforce per-job GITHUB_TOKEN write-scope allowlist ([#368](https://github.com/rvenutolo/linPEAS-flake/pull/368))
- Assert bypass_actors empty in tag-protection drift check ([#366](https://github.com/rvenutolo/linPEAS-flake/pull/366))
- Assert strict policy and thread resolution in protect-main drift check ([#365](https://github.com/rvenutolo/linPEAS-flake/pull/365))
- Gate flake.lock auto-merge on input provenance ([#364](https://github.com/rvenutolo/linPEAS-flake/pull/364))

### Fixes
- Point README flake badge at nixos.org manual ([#418](https://github.com/rvenutolo/linPEAS-flake/pull/418))
- Wait for DNS to settle before Nix install in setup-nix ([#419](https://github.com/rvenutolo/linPEAS-flake/pull/419))
- Exclude redirect-chaining Docker status page from link check ([#416](https://github.com/rvenutolo/linPEAS-flake/pull/416))
- Allow second-order blocked egress on links and scorecard jobs ([#415](https://github.com/rvenutolo/linPEAS-flake/pull/415))
- Allow blocked egress on links and scorecard-drift-check jobs ([#414](https://github.com/rvenutolo/linPEAS-flake/pull/414))
- Run CodeQL on every PR to keep Scorecard SAST at 10 ([#407](https://github.com/rvenutolo/linPEAS-flake/pull/407))
- Detach seeded-defect worktree so plant.sh runs on main ([#394](https://github.com/rvenutolo/linPEAS-flake/pull/394))
- One entry per PR; move action-pin scratch off .claude ([#379](https://github.com/rvenutolo/linPEAS-flake/pull/379))
- Sweep in-repo temp files left by interrupted refresh generators ([#377](https://github.com/rvenutolo/linPEAS-flake/pull/377))
- Fail-fast when a workflow declares more than one cron line ([#373](https://github.com/rvenutolo/linPEAS-flake/pull/373))
- Require fork-guard on actions:write jobs in lint ([#369](https://github.com/rvenutolo/linPEAS-flake/pull/369))
- Detect all nix-installer declarations and guard dead renovate markers ([#367](https://github.com/rvenutolo/linPEAS-flake/pull/367))
- Exclude test fixtures from lychee link check ([#346](https://github.com/rvenutolo/linPEAS-flake/pull/346))
- Sweep stray in-repo temps from refresh-treefmt-config ([#337](https://github.com/rvenutolo/linPEAS-flake/pull/337))
- File notify issues for cancelled runs instead of ignoring them ([#329](https://github.com/rvenutolo/linPEAS-flake/pull/329))
- Skip redundant pytest suite in the pre-commit wrapper build ([#324](https://github.com/rvenutolo/linPEAS-flake/pull/324))

### Performance
- Merge docs-audit clusters to 4 readers (~29% token cut) ([#396](https://github.com/rvenutolo/linPEAS-flake/pull/396))
- Host light lint groups in lean devShells.lint ([#350](https://github.com/rvenutolo/linPEAS-flake/pull/350))
- Batch 3 setup-tax harness jobs into one harness-group job ([#336](https://github.com/rvenutolo/linPEAS-flake/pull/336))
- Batch 7 doc-freshness jobs into one doc-freshness job ([#332](https://github.com/rvenutolo/linPEAS-flake/pull/332))
- Batch 24 invariant-lint jobs into 3 grouped jobs ([#331](https://github.com/rvenutolo/linPEAS-flake/pull/331))

### Refactor
- Trim redundant scorecard checks ([#339](https://github.com/rvenutolo/linPEAS-flake/pull/339))
- Migrate to flake-parts module structure ([#305](https://github.com/rvenutolo/linPEAS-flake/pull/305))

### Style
- Drop causal-history phrase from lint-workflow-security comment ([#338](https://github.com/rvenutolo/linPEAS-flake/pull/338))

### Tests
- Seeded-defect eval harness to quantify docs-correctness-audit recall ([#393](https://github.com/rvenutolo/linPEAS-flake/pull/393))

## [20260604-085abf96] - 2026-06-08

### Chores
- Bump linpeas to 20260604-085abf96 ([#301](https://github.com/rvenutolo/linPEAS-flake/pull/301))
- Update flake.lock ([#297](https://github.com/rvenutolo/linPEAS-flake/pull/297))
- Pin GitHub Actions to exact patch tags ([#296](https://github.com/rvenutolo/linPEAS-flake/pull/296))
- Set nix substituter retry + timeouts in setup-nix ([#294](https://github.com/rvenutolo/linPEAS-flake/pull/294))

### Fixes
- Make update-linpeas idempotent on same-version reruns ([#300](https://github.com/rvenutolo/linPEAS-flake/pull/300))
- Unshallow image-smoke checkout for main baseline build ([#293](https://github.com/rvenutolo/linPEAS-flake/pull/293))

## [20260601-a39c90f1] - 2026-06-01

### CI
- Add customManager for octoscan digest + version bumps ([#278](https://github.com/rvenutolo/linPEAS-flake/pull/278))

### Chores
- Bump linpeas to 20260601-a39c90f1 ([#289](https://github.com/rvenutolo/linPEAS-flake/pull/289))

### Documentation
- Backfill cron schedule table ([#287](https://github.com/rvenutolo/linPEAS-flake/pull/287))

### Features
- Cron schedule drift guard ([#288](https://github.com/rvenutolo/linPEAS-flake/pull/288))
- Add local pre-commit hook for octoscan ([#285](https://github.com/rvenutolo/linPEAS-flake/pull/285))

### Fixes
- Drop libsystemd from procps to shrink OCI attack surface ([#284](https://github.com/rvenutolo/linPEAS-flake/pull/284))
- Route changelog commit via PR + auto-merge ([#282](https://github.com/rvenutolo/linPEAS-flake/pull/282))

## [20260528-82c8c3b6] - 2026-05-29

### CI
- Add ratchet-pin-audit-harness to protect-main mirror ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Gate ratchet-pin-audit invariants on PRs ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Image size advisory in image-smoke ([#240](https://github.com/rvenutolo/linPEAS-flake/pull/240))
- Harden actionlint embedded-linter integration ([#239](https://github.com/rvenutolo/linPEAS-flake/pull/239))
- Add nixpkgs-hammering pre-commit hook ([#237](https://github.com/rvenutolo/linPEAS-flake/pull/237))
- Add hammer-shim parity check ([#182](https://github.com/rvenutolo/linPEAS-flake/pull/182))
- Add nixpkgs-hammering pre-commit hook ([#182](https://github.com/rvenutolo/linPEAS-flake/pull/182))
- Enforce setup-nix composite via setup-nix-required lint ([#222](https://github.com/rvenutolo/linPEAS-flake/pull/222))
- Introduce setup-nix composite with authenticated tarball fetches ([#220](https://github.com/rvenutolo/linPEAS-flake/pull/220))

### Chores
- Bump linpeas to 20260528-82c8c3b6 ([#280](https://github.com/rvenutolo/linPEAS-flake/pull/280))
- Update flake.lock ([#279](https://github.com/rvenutolo/linPEAS-flake/pull/279))
- Triage scorecard-drift findings (drop 2 checks, pin commitlint) ([#265](https://github.com/rvenutolo/linPEAS-flake/pull/265))
- Bump codeql-action v3; revert spurious v4.3.0 dl-artifact ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Bump three force-moved action SHAs ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Add renovate-config-validator local + CI check (#183, #189) ([#229](https://github.com/rvenutolo/linPEAS-flake/pull/229))
- Watch flake files in .envrc so direnv rebuilds on change ([#228](https://github.com/rvenutolo/linPEAS-flake/pull/228))
- Auto-TOC via mdformat-toc ([#224](https://github.com/rvenutolo/linPEAS-flake/pull/224))
- Rename nixfmt-rfc-style to nixfmt ([#223](https://github.com/rvenutolo/linPEAS-flake/pull/223))
- Drop explicit pre-commit; let git-hooks.nix provide it ([#217](https://github.com/rvenutolo/linPEAS-flake/pull/217))
- Move devshell + CI tooling to nixpkgs-unstable; keep linpeas runtime on stable ([#195](https://github.com/rvenutolo/linPEAS-flake/pull/195))
- Expand auto-format and lint coverage to remaining tracked files ([#152](https://github.com/rvenutolo/linPEAS-flake/pull/152))
- Remove linpeas-bundle release artifact ([#150](https://github.com/rvenutolo/linPEAS-flake/pull/150))
- Update flake.lock ([#145](https://github.com/rvenutolo/linPEAS-flake/pull/145))

### Documentation
- Correct ratchet update guidance in pin audit ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Runbook for ratchet-pin-audit workflow ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Extract flake outputs section into dedicated reference doc ([#151](https://github.com/rvenutolo/linPEAS-flake/pull/151))
- Rework README Usage into per-artifact use-case examples ([#147](https://github.com/rvenutolo/linPEAS-flake/pull/147))

### Features
- Add backfill-tag mode to release-on-bump ([#277](https://github.com/rvenutolo/linPEAS-flake/pull/277))
- Emit .intoto.jsonl provenance sidecars on release assets ([#275](https://github.com/rvenutolo/linPEAS-flake/pull/275))
- Cosign sign-blob release-asset sidecars ([#270](https://github.com/rvenutolo/linPEAS-flake/pull/270))
- Attach CycloneDX SBOMs to releases ([#269](https://github.com/rvenutolo/linPEAS-flake/pull/269))
- Scorecard-drift-check workflow with curated 10-check allowlist ([#260](https://github.com/rvenutolo/linPEAS-flake/pull/260))
- Add octoscan workflow vulnerability scanner ([#255](https://github.com/rvenutolo/linPEAS-flake/pull/255))
- Actionlint cron drift-check workflow ([#251](https://github.com/rvenutolo/linPEAS-flake/pull/251))
- Zizmor cron drift-check workflow ([#248](https://github.com/rvenutolo/linPEAS-flake/pull/248))
- Add Grype as second-opinion image CVE scanner ([#244](https://github.com/rvenutolo/linPEAS-flake/pull/244))
- Add trufflehog secret scanner ([#243](https://github.com/rvenutolo/linPEAS-flake/pull/243))
- Ratchet pin audit workflow (closes #161) ([#242](https://github.com/rvenutolo/linPEAS-flake/pull/242))
- Ratchet-pin-audit notify body with per-reason runbook ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Ratchet-pin-audit emits typed drift/api/tool reasons ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Ratchet-pin-audit workflow skeleton ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Reproducibility check workflow ([#241](https://github.com/rvenutolo/linPEAS-flake/pull/241))
- Pr size labeler and actions cache prune workflows ([#235](https://github.com/rvenutolo/linPEAS-flake/pull/235))
- Generate CHANGELOG.md from conventional commits ([#234](https://github.com/rvenutolo/linPEAS-flake/pull/234))
- Standalone just-recipes + treefmt-config reference pages ([#190](https://github.com/rvenutolo/linPEAS-flake/pull/190)) ([#233](https://github.com/rvenutolo/linPEAS-flake/pull/233))
- Auto-generated CI DAG diagram ([#185](https://github.com/rvenutolo/linPEAS-flake/pull/185)) ([#232](https://github.com/rvenutolo/linPEAS-flake/pull/232))
- Shdoc-style scripts reference ([#184](https://github.com/rvenutolo/linPEAS-flake/pull/184)) ([#231](https://github.com/rvenutolo/linPEAS-flake/pull/231))
- Invariant-enforcer matrix ([#186](https://github.com/rvenutolo/linPEAS-flake/pull/186)) ([#230](https://github.com/rvenutolo/linPEAS-flake/pull/230))
- Classify notify-workflow-result issues by finding vs infra ([#215](https://github.com/rvenutolo/linPEAS-flake/pull/215))
- Lint nix run nixpkgs#<pkg> must be pinned ([#213](https://github.com/rvenutolo/linPEAS-flake/pull/213))
- Lint cosign verify pins identity + OIDC issuer ([#212](https://github.com/rvenutolo/linPEAS-flake/pull/212))
- Lint gh attestation verify pins --repo ([#211](https://github.com/rvenutolo/linPEAS-flake/pull/211))
- Lint release-grade jobs include fork-guard if: clause ([#210](https://github.com/rvenutolo/linPEAS-flake/pull/210))
- Lint multi-line run: blocks start with set -Eeuo pipefail ([#209](https://github.com/rvenutolo/linPEAS-flake/pull/209))
- Lint ci.yml jobs cross-checked against summary categories ([#208](https://github.com/rvenutolo/linPEAS-flake/pull/208))
- Lint scripts/check-*.sh paired with tests/check-*.test.sh ([#207](https://github.com/rvenutolo/linPEAS-flake/pull/207))
- Lint scripts/*.sh shebang + set -Eeuo pipefail ([#206](https://github.com/rvenutolo/linPEAS-flake/pull/206))
- Hard-ban pull_request_target trigger ([#205](https://github.com/rvenutolo/linPEAS-flake/pull/205))
- Lint pull_request/push triggers declare branches main ([#202](https://github.com/rvenutolo/linPEAS-flake/pull/202))
- Lint actions/upload-artifact uses if-no-files-found error ([#201](https://github.com/rvenutolo/linPEAS-flake/pull/201))
- Lint actions/checkout sets persist-credentials false ([#200](https://github.com/rvenutolo/linPEAS-flake/pull/200))
- Lint every workflow declares concurrency group ([#199](https://github.com/rvenutolo/linPEAS-flake/pull/199))
- Lint every workflow job declares timeout-minutes ([#198](https://github.com/rvenutolo/linPEAS-flake/pull/198))
- Generate derived doc blocks from source-of-truth files ([#146](https://github.com/rvenutolo/linPEAS-flake/pull/146))

### Fixes
- Upload SBOM files to release explicitly ([#274](https://github.com/rvenutolo/linPEAS-flake/pull/274))
- Ungate pin sign-blob from exists check ([#273](https://github.com/rvenutolo/linPEAS-flake/pull/273))
- Add checkout step to manifest job ([#272](https://github.com/rvenutolo/linPEAS-flake/pull/272))
- Write scorecard JSON to file via --output, not stdout redirect ([#264](https://github.com/rvenutolo/linPEAS-flake/pull/264))
- Silence scorecard info logs leaking into stdout JSON ([#263](https://github.com/rvenutolo/linPEAS-flake/pull/263))
- Enable SCORECARD_EXPERIMENTAL for SBOM + Webhooks checks ([#262](https://github.com/rvenutolo/linPEAS-flake/pull/262))
- Drop directory positional from actionlint-drift probe ([#253](https://github.com/rvenutolo/linPEAS-flake/pull/253))
- Strip monorepo subpath + skip self-refs in pin audit ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Use nix develop for ratchet; merge gh-api calls ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Unconditionally resolve annotated tags in pin audit ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))
- Scrub PYTHONPATH from pre-commit wrapper ([#226](https://github.com/rvenutolo/linPEAS-flake/pull/226))
- Pipe refresh-precommit-table output through treefmt ([#221](https://github.com/rvenutolo/linPEAS-flake/pull/221))

### Tests
- Invariant + fixtures for ratchet-pin-audit shape ([#161](https://github.com/rvenutolo/linPEAS-flake/pull/161))

## [20260521-859cab5f] - 2026-05-22

### CI
- Replace commitizen with commitlint for full CI parity ([#106](https://github.com/rvenutolo/linPEAS-flake/pull/106))
- Add gitleaks, dependency-review, labeler workflows ([#88](https://github.com/rvenutolo/linPEAS-flake/pull/88))

### Chores
- Bump linpeas to 20260521-859cab5f ([#142](https://github.com/rvenutolo/linPEAS-flake/pull/142))
- Scrub ephemeral references from tracked files ([#110](https://github.com/rvenutolo/linPEAS-flake/pull/110))
- Register protect-main-drift-check as required ([#104](https://github.com/rvenutolo/linPEAS-flake/pull/104))
- Best-practices review follow-ups ([#90](https://github.com/rvenutolo/linPEAS-flake/pull/90))
- Add doc-quality hooks + lychee recipe for local CI parity ([#83](https://github.com/rvenutolo/linPEAS-flake/pull/83))
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
- Add consumer-flake guide, threat model, and Renovate dashboard surfacing ([#129](https://github.com/rvenutolo/linPEAS-flake/pull/129))
- Extract security/CI invariants from CLAUDE.md into tracked docs ([#105](https://github.com/rvenutolo/linPEAS-flake/pull/105))
- Document expected breakage surface of nixpkgs bumps ([#96](https://github.com/rvenutolo/linPEAS-flake/pull/96))
- Move Docker Hub half-published recovery to tracked runbook ([#97](https://github.com/rvenutolo/linPEAS-flake/pull/97))
- Drop stale bump-credential refs and ephemeral planning tokens ([#92](https://github.com/rvenutolo/linPEAS-flake/pull/92))
- Ephemeral-ref cleanup + README/runbook refresh ([#82](https://github.com/rvenutolo/linPEAS-flake/pull/82))
- Correct release-on-bump gh release flags in diagram ([#67](https://github.com/rvenutolo/linPEAS-flake/pull/67))
- Refresh README + arch/security docs for Wave-P3/P4 changes ([#66](https://github.com/rvenutolo/linPEAS-flake/pull/66))
- Add flake-input bump runbook + Renovate descriptions ([#65](https://github.com/rvenutolo/linPEAS-flake/pull/65))
- Refresh README for recent CI, cron, and watchdog changes ([#34](https://github.com/rvenutolo/linPEAS-flake/pull/34))
- Document scorecard trigger, codeql advisory scope, manifest verify gap (CIW-5/CIW-6/SC-POST-8) ([#21](https://github.com/rvenutolo/linPEAS-flake/pull/21))

### Features
- Lint strict GITHUB_TOKEN min-permissions ([#137](https://github.com/rvenutolo/linPEAS-flake/pull/137))
- Lint every workflow job starts with harden-runner ([#136](https://github.com/rvenutolo/linPEAS-flake/pull/136))
- Sign bundle + images keyless with cosign ([#135](https://github.com/rvenutolo/linPEAS-flake/pull/135))
- Embed SBOM diff vs previous release in release notes ([#134](https://github.com/rvenutolo/linPEAS-flake/pull/134))
- Add bump-lag chart ([#133](https://github.com/rvenutolo/linPEAS-flake/pull/133))
- Extract invariant index and add doc-link lint checks ([#131](https://github.com/rvenutolo/linPEAS-flake/pull/131))
- Add allowed-actions API drift-check ([#108](https://github.com/rvenutolo/linPEAS-flake/pull/108))
- Add settings-posture drift-check ([#107](https://github.com/rvenutolo/linPEAS-flake/pull/107))
- Add protect-main-drift-check required CI job ([#101](https://github.com/rvenutolo/linPEAS-flake/pull/101))
- Re-assert :latest manifest parity + dockerhub-sync no-op cause ([#98](https://github.com/rvenutolo/linPEAS-flake/pull/98))
- Add org.opencontainers.image.revision label ([#95](https://github.com/rvenutolo/linPEAS-flake/pull/95))
- Add pin-diff-isolated required check ([#100](https://github.com/rvenutolo/linPEAS-flake/pull/100))
- Add pre-commit-hooks-sha-parity required check ([#99](https://github.com/rvenutolo/linPEAS-flake/pull/99))
- Add mdformat for markdown auto-formatting ([#84](https://github.com/rvenutolo/linPEAS-flake/pull/84))
- Add check-jsonschema for repo config validation ([#85](https://github.com/rvenutolo/linPEAS-flake/pull/85))
- Add taplo as treefmt's TOML formatter ([#87](https://github.com/rvenutolo/linPEAS-flake/pull/87))
- Add pr-title-lint required check + merge-commit-posture docs ([#81](https://github.com/rvenutolo/linPEAS-flake/pull/81))
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
- Add GitHub Pages site (landing + docs + dashboard) ([#4](https://github.com/rvenutolo/linPEAS-flake/pull/4))

### Fixes
- Add orphaned security pages to mkdocs nav ([#132](https://github.com/rvenutolo/linPEAS-flake/pull/132))
- Drop merge-method fields from settings-posture probe ([#128](https://github.com/rvenutolo/linPEAS-flake/pull/128))
- Add api-version header + scripts/ lint rule ([#109](https://github.com/rvenutolo/linPEAS-flake/pull/109))
- Add head_repository gate to renovate-flake-lock-refresh ([#93](https://github.com/rvenutolo/linPEAS-flake/pull/93))
- Guard image-cve-scan CRITICAL count against non-numeric severity ([#94](https://github.com/rvenutolo/linPEAS-flake/pull/94))
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
- Attribute verify-latest-release failures by reason ([#103](https://github.com/rvenutolo/linPEAS-flake/pull/103))
- Drop docker login from verify-only paths ([#102](https://github.com/rvenutolo/linPEAS-flake/pull/102))
- Switch Nix formatter to nixfmt-rfc-style ([#86](https://github.com/rvenutolo/linPEAS-flake/pull/86))
- Bump workflows authenticate as GitHub App for signed REST commits ([#80](https://github.com/rvenutolo/linPEAS-flake/pull/80))
- Trigger on release completion, not README push (P4.6) ([#59](https://github.com/rvenutolo/linPEAS-flake/pull/59))
- Split PAT off third-party action env (P3.2) ([#48](https://github.com/rvenutolo/linPEAS-flake/pull/48))
- BUMP_PAT blast-radius reduction phase 1 (AU-P-1/P-2/P-4) ([#20](https://github.com/rvenutolo/linPEAS-flake/pull/20))

### Tests
- Cover gen-dashboard-data.sh security hard-fail branches ([#6](https://github.com/rvenutolo/linPEAS-flake/pull/6))
- Assert bundle shebang rewrite in bundle-smoke ([#5](https://github.com/rvenutolo/linPEAS-flake/pull/5))

## [20260510-cd4bd619] - 2026-05-16

### Chores
- Bump linpeas to 20260510-cd4bd619 ([#2](https://github.com/rvenutolo/linPEAS-flake/pull/2))

### Tests
- Roll pin back to 20260506-5a27482a to exercise auto-bump pipeline ([#1](https://github.com/rvenutolo/linPEAS-flake/pull/1))


