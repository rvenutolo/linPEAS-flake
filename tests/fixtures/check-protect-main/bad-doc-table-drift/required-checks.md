# Required Status Checks — main branch (fixture)

## Required contexts

| Context       | Source workflow | Source file              |
| ------------- | --------------- | ------------------------ |
| build-linpeas | ci              | .github/workflows/ci.yml |

## Maintenance

Fixture: drops `flake-check`, which mirror.json in this directory still
requires — the doc-table parity check must fail.
