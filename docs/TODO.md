# TODO

This list tracks near-term extraction work before Hao becomes the runtime
dependency used by Affon and other hosts.

## Before Affon Switches

- Validate the Affon integration path by replacing copied runtime pieces with a
  Hao dependency in an Affon branch or worktree.
- Stabilize the Cyna runtime embedding ABI in `include/hao.h`; `include/addon.h`
  is the addon ABI.
- Decide the Jupyter boundary: core CLI/runtime feature, optional package, or
  separate package.
- Smooth package lifecycle helpers so `RuntimeEnvironment` users do not have to manage
  package deinit manually.

## Addon ABI

- Add typed array and buffer helpers.
- Add property enumeration helpers.
- Add function-call helpers.
- Add external pointer or resource finalizer support.

## Tracing

- Add an external exporter, such as OTLP, as a filtered consumer of the native
  trace ring; the in-process console remains the only exporter today.
- Clarify trace record identity: `sequence` is currently the global record ID;
  decide whether events also need a separate event ID.

## Docs And Examples

- Add a complete C embedding example.
- Add a complete addon package example.
- Add a short std module usage example.

## Cleanup

- Finish snapshot dedent behavior in `std:test`.
