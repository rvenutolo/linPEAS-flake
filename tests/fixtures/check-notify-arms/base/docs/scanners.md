# Scanners

## codeql

On non-PR runs a finding, and a failure before analysis or a cancelled job,
are paged under `codeql-critical` <!-- notify-arms: codeql.yml/notify-finding = finding non-pr -->
and `codeql-infra` <!-- notify-arms: codeql.yml/notify-infra = failure cancelled non-pr -->.

## octoscan

- **Status:** on non-PR runs a finding is paged under `octoscan-finding` <!-- notify-arms: octoscan.yml/notify-finding = finding non-pr -->,
    and an incomplete scan or a cancelled job under `octoscan-infra` <!-- notify-arms: octoscan.yml/notify-infra = failure cancelled non-pr -->.
- **Adding a suppression:** unrelated.

## watchdogs

A failed or cancelled scorecard run opens `scorecard-drift` <!-- notify-arms: scorecard-drift-check.yml/notify = failure cancelled -->.

A failed or cancelled zizmor run opens `zizmor-drift` <!-- notify-arms: zizmor-drift-check.yml/notify = failure cancelled -->.

## image CVE scan

- `image-cve-scan-trivy-notify-finding` — a CRITICAL CVE <!-- notify-arms: image-cve-scan.yml/image-cve-scan-trivy-notify-finding = finding -->.
- `image-cve-scan-trivy-notify-infra` — no count, or a cancelled job <!-- notify-arms: image-cve-scan.yml/image-cve-scan-trivy-notify-infra = failure cancelled -->.
- `image-cve-scan-grype-notify-finding` — a CRITICAL CVE <!-- notify-arms: image-cve-scan.yml/image-cve-scan-grype-notify-finding = finding -->.
- `image-cve-scan-grype-notify-infra` — no count, or a cancelled job <!-- notify-arms: image-cve-scan.yml/image-cve-scan-grype-notify-infra = failure cancelled -->.

A marker shown as syntax is not a declaration: `<!-- notify-arms: codeql.yml/nope = bogus -->`.

```text
<!-- notify-arms: codeql.yml/nope = bogus -->
```

Enforced by a lint <!-- enforcer: scripts/check-notify-arms.sh -->.

<!--
Text <!-- notify-arms: codeql.yml/nope = bogus
-->
