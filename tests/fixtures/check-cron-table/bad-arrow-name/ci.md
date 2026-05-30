# CI

## Cron schedule

| Workflow | Cron         | UTC         | Purpose    |
| -------- | ------------ | ----------- | ---------- |
| `alpha`  | `0 9 * * *`  | 09:00 daily | Alpha job  |
| `beta`   | `0 11 * * *` | 11:00 daily | Beta job   |
| `weekly` | `0 6 * * 0`  | Sun 06:00   | Weekly job |

Daily crons fire in this UTC order: `alpha` (09:00) → `gamma` (11:00).

## Other section
