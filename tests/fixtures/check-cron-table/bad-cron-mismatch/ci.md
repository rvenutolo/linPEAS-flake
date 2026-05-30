# CI

## Cron schedule

| Workflow | Cron        | UTC         | Purpose    |
| -------- | ----------- | ----------- | ---------- |
| `alpha`  | `0 8 * * *` | 08:00 daily | Alpha job  |
| `weekly` | `0 6 * * 0` | Sun 06:00   | Weekly job |

Daily crons fire in this UTC order: `alpha` (08:00).

## Other section
