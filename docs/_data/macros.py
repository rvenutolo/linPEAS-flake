"""Macros module loaded by mkdocs-macros-plugin.

Exposes the dashboard data file as a top-level `dashboard` variable in
Jinja2 contexts (configured via `include_yaml` in `mkdocs.yml`). This
module intentionally defines no extra macros — keeping the Jinja surface
minimal makes templates predictable.
"""


def define_env(env):  # noqa: D401, ARG001
    """Register no extra macros. `include_yaml` handles data injection."""
    return None
