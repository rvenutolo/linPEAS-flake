# The Python the scripts-reference round-trip check renders with: the
# site's own Markdown renderer plus the libraries mkdocs.yml's extensions
# load. One binding, imported by the check's pre-commit hook and by
# `devShells.default` (where the `lint-doc-invariants` group runs it), so
# the two cannot carry different library sets.
{ pkgs-unstable }:
pkgs-unstable.python3.withPackages (ps: [
  ps.markdown
  ps.pygments
  ps.pymdown-extensions
  ps.pyyaml
])
