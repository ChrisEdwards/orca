# Orca spawn owns target workspace resolution

Orca spawn resolves where a worker should appear in cmux: by default the calling workspace, or a caller-specified target workspace by exact name or UUID. A workspace name is resolved within the caller's current cmux window and creates a missing workspace in that same window; higher-level skills remain responsible for PR URLs, repository discovery, cloning, fetching, and review-specific brief construction.

This keeps `orca-spawn` as the reusable cmux-and-worker primitive while allowing skills such as PR review to route workers to the right repo workspace without duplicating spawn mechanics.
