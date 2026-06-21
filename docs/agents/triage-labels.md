# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to beads statuses and tags.

| Canonical Role    | Beads Equivalent                            | Meaning                                  |
| ----------------- | ------------------------------------------- | ---------------------------------------- |
| `needs-triage`    | status `open`, priority unset or P2         | Maintainer needs to evaluate this issue  |
| `needs-info`      | status `open` + tag `needs-info`            | Waiting on reporter for more information |
| `ready-for-agent` | status `open`, unblocked (visible in `br ready`) | Fully specified, ready for an AFK agent  |
| `ready-for-human` | status `open` + tag `human-required`        | Requires human implementation            |
| `wontfix`         | closed with reason "Won't fix"              | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding beads command from this table.
