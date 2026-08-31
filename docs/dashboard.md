# Dashboard

Live status of the `linPEAS-flake` pin, releases, and upstream parity.

!!! warning "This page is documentation, not a verification surface"
    The status below is regenerated at site-build time from the
    `linpeas-pin.json` file and the GitHub API. It is **not** a trust
    anchor. Always verify release artifacts with
    `gh attestation verify <artifact> --repo rvenutolo/linPEAS-flake`
    against the actual release downloads — for the OCI image, against a
    per-arch digest rather than a tag. See
    [Security → Verification](security/verification.md).

## Current pin

<div class="status-tiles" markdown>

<div class="status-tile" markdown>
<span class="label">Pin version</span>

<span class="value">{{ dashboard.pin.version }}</span>
</div>

<div class="status-tile" markdown>
<span class="label">Upstream latest</span>

<span class="value">{{ dashboard.drift.upstream_latest }}</span>
</div>

<div class="status-tile {{ 'ok' if dashboard.drift.days == 0 else 'fail' }}" markdown>
<span class="label">Drift gap</span>

<span class="value">{{ dashboard.drift.days }} day{{ '' if dashboard.drift.days == 1 else 's' }}</span>
</div>

<div class="status-tile {{ 'ok' if dashboard.parity.conclusion == 'success' else 'fail' }}" markdown>
<span class="label">Upstream parity</span>

<span class="value">{{ dashboard.parity.conclusion }}</span>
</div>

</div>

- **Pinned release:** [{{ dashboard.pin.version }}](https://github.com/peass-ng/PEASS-ng/releases/tag/{{ dashboard.pin.version }})
- **Pinned URL:** [{{ dashboard.pin.url }}]({{ dashboard.pin.url }})
- **Pinned-vs-upstream comparison target** (same value as the "Upstream latest" tile): [{{ dashboard.pin.upstream_tag }}](https://github.com/peass-ng/PEASS-ng/releases/tag/{{ dashboard.pin.upstream_tag }}), published {{ dashboard.pin.upstream_date }}

## Last automated bump

{% if dashboard.last_bump.pr_number and dashboard.last_bump.pr_number > 0 %}
- **PR:** [#{{ dashboard.last_bump.pr_number }}]({{ dashboard.last_bump.pr_url }})
- **Merged:** {{ dashboard.last_bump.merged_at }}
{% else %}
No bump PRs found yet.
{% endif %}

## Latest release

{% if dashboard.release.latest_tag %}
- **Tag:** [{{ dashboard.release.latest_tag }}](https://github.com/rvenutolo/linPEAS-flake/releases/tag/{{ dashboard.release.latest_tag }})
- **OCI image:** `{{ dashboard.release.image_ref }}`

That reference is a manifest tag, and the tag resolves to a manifest index
that carries no attestation — `gh attestation verify` against it fails with
a not-found error. Resolve your platform's per-arch image digest from the
index first and verify that digest:
[Security → Verification → Multi-arch attestations](security/verification.md#multi-arch-attestations).
{% else %}
No releases published yet.
{% endif %}

## Upstream parity check

The weekly [`verify-latest-release.yml`](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/verify-latest-release.yml) workflow re-fetches the pinned `linpeas.sh`, recomputes its SRI hash, and compares against the pin file. Detects upstream tag replacement that attestation alone cannot see.

{% if dashboard.parity.checked_at %}
- **Last result:** {{ dashboard.parity.conclusion }}
- **Checked:** {{ dashboard.parity.checked_at }}
- **Run:** [view on GitHub Actions]({{ dashboard.parity.run_url }})
{% else %}
No parity-check runs have completed yet.
{% endif %}

## Bump lag

Hours between each upstream release and the corresponding this-repo
release. Surfaces whether the auto-bump pipeline is keeping pace.

{% if dashboard.lag.recent and dashboard.lag.recent | length > 0 %}
```mermaid
xychart-beta
    title "Bump lag (hours) — last {{ dashboard.lag.recent | length }} releases"
    x-axis [{% for entry in dashboard.lag.recent %}"{{ entry.tag }}"{% if not loop.last %}, {% endif %}{% endfor %}]
    y-axis "Lag (hours)"
    bar [{% for entry in dashboard.lag.recent %}{{ entry.lag_hours }}{% if not loop.last %}, {% endif %}{% endfor %}]
```
{% else %}
No paired releases yet.
{% endif %}

---

_Generated: {{ dashboard.generated_at }}_
