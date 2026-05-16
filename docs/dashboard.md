# Dashboard

Live status of the `linPEAS-flake` pin, releases, and upstream parity.

!!! warning "This page is documentation, not a verification surface"
The status below is regenerated at site-build time from the
`linpeas-pin.json` file and the GitHub API. It is **not** a trust
anchor. Always verify release artifacts with
`gh attestation verify <artifact> --repo rvenutolo/linPEAS-flake`
against the actual release downloads. See
[Security → Verification](security/verification.md).

## Current pin

<div class="status-tiles" markdown>

<div class="status-tile" markdown>
**Pin version**

`{{ dashboard.pin.version }}`

</div>

<div class="status-tile" markdown>
**Upstream latest**

`{{ dashboard.drift.upstream_latest }}`

</div>

<div class="status-tile {{ 'ok' if dashboard.drift.days == 0 else 'fail' }}" markdown>
**Drift gap**

{{ dashboard.drift.days }} day{{ '' if dashboard.drift.days == 1 else 's' }}

</div>

<div class="status-tile {{ 'ok' if dashboard.parity.conclusion == 'success' else 'fail' }}" markdown>
**Upstream parity**

{{ dashboard.parity.conclusion }}

</div>

</div>

- **Upstream release:** [{{ dashboard.pin.upstream_tag }}](https://github.com/peass-ng/PEASS-ng/releases/tag/{{ dashboard.pin.upstream_tag }})
- **Pinned URL:** [{{ dashboard.pin.url }}]({{ dashboard.pin.url }})
- **Last upstream tag date:** {{ dashboard.pin.upstream_date }}

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
- **Bundle:** [`linpeas-bundle.sh`]({{ dashboard.release.bundle_url }})
- **OCI image:** `{{ dashboard.release.image_ref }}`

Verify:

```bash
gh attestation verify linpeas-bundle.sh --repo rvenutolo/linPEAS-flake
gh attestation verify oci://{{ dashboard.release.image_ref }} --repo rvenutolo/linPEAS-flake
```

{% else %}
No releases published yet.
{% endif %}

## Upstream parity check

The daily [`verify-latest-release.yml`](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/verify-latest-release.yml) workflow re-fetches the pinned `linpeas.sh`, recomputes its SRI hash, and compares against the pin file. Detects upstream tag replacement that attestation alone cannot see.

{% if dashboard.parity.checked_at %}

- **Last result:** {{ dashboard.parity.conclusion }}
- **Checked:** {{ dashboard.parity.checked_at }}
- **Run:** [view on GitHub Actions]({{ dashboard.parity.run_url }})
  {% else %}
  No parity-check runs have completed yet.
  {% endif %}

---

_Generated: {{ dashboard.generated_at }}_
