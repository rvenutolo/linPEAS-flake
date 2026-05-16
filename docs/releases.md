# Releases

The 20 most recent releases. Full history on [GitHub Releases](https://github.com/rvenutolo/linPEAS-flake/releases).

{% if dashboard.releases | length == 0 %}
No releases have been published yet.
{% else %}
| Tag | Date | Bundle | Image |
|-----|------|--------|-------|
{% for r in dashboard.releases -%}
| [`{{ r.tag }}`](https://github.com/rvenutolo/linPEAS-flake/releases/tag/{{ r.tag }}) | {{ r.date or "—" }} | {% if r.bundle_url %}[`linpeas-bundle.sh`]({{ r.bundle_url }}){% else %}—{% endif %} | `{{ r.image_tag }}` |
{% endfor %}
{% endif %}

Each release is built by [`release-on-bump.yml`](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/release-on-bump.yml) when `linpeas-pin.json` changes on `main`. Build provenance is attested via SLSA; verify with `gh attestation verify`. See [Verification walkthrough](security/verification.md).
