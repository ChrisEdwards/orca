# Orca fork is a self-contained skill

Orca fork is a separate skill from orca-spawn because it branches an existing conversation instead of spawning a fresh worker from a brief. The skill bundles its own runtime files rather than calling sibling skill scripts, preserving the packaging rule that each skill can be copied and installed independently. When a runtime helper is intentionally shared between skills, duplicate it verbatim so one copy can be maintained and copied to the others; fork-specific orchestration remains separate.
