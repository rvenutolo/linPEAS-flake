# Doc

Every PR must pass 3 <!-- count: required-contexts --> required status
checks before merge.

The seven functional gates are a subset of the required set.

Scheduled at 08:05, a run opens a PR; required checks then run.

The required checks number 3 in total.

Three of the other required checks are scanners.

Someone required checks on every branch, and the 2 required contextual notes
are elsewhere.

If any one of the required checks fails, the PR is blocked. At 08:05 required
checks run, and in 2024 required status checks became mandatory. The
x-three required checks label is not a count.

A marker may drop its spaces: 3<!--count:required-contexts--> required checks.

<!-- enforcer: scripts/check-required-check-counts.sh -->

About 2 days after release required checks re-run.

We enforce two-factor required checks, and two of the required checks are
scanners. If one required check fails, the PR
is blocked.
