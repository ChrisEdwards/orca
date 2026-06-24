# Target cmux surfaces by UUID, never by positional ref

cmux exposes two id forms, stable UUIDs and positional refs (`surface:N`, `pane:N`, `tab:N`). The refs are reassigned as surfaces and panes are created and closed. During a single session we watched the orchestrator's own surface move from `surface:26` in `pane:15` to `surface:35` in `pane:16`, and a `close-surface --surface surface:31` issued against a drifted ref disrupted the wrong surface (the orchestrator).

Orca captures the surface UUID at creation (`new-surface --id-format both` returns it inline, for example `OK surface:37 (9EA11FA4-...) pane:16 (...)`) and targets every later operation (`send`, `send-key`, `read-screen`, `close`) by UUID. A ref may be used only for a one-shot read consumed immediately, never stored for deferred action. The orchestrator also records its own surface UUID so it can never act on itself.

## Consequences

The `.orca` state that maps a task to its worker stores UUIDs, not refs. Any adapter or script that accepts a surface target takes a UUID. Closing by UUID was verified to be exact and to leave other surfaces, including the orchestrator, untouched.
