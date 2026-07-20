# TODO

This list tracks near-term extraction work before Hao becomes the runtime
dependency used by Affon and other hosts.

## Before Affon Switches

- Validate the Affon integration path by replacing copied runtime pieces with a
  Hao dependency in an Affon branch or worktree.
- Add the future runtime/embedder C header. `include/addon.h` is now the addon
  ABI; `include/hao.h` should eventually describe the runtime embedding ABI.
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

- Add async context propagation across promises, timers, and native callbacks.
- Define the host consumer/export policy before exposing tracing through the
  addon ABI.
- Clarify trace record identity: `sequence` is currently the global record ID;
  decide whether events also need a separate event ID.

## Docs And Examples

- Add a small Zig embedding example.
- Add a complete addon package example.
- Add a short std module usage example.

## Cleanup

- Finish snapshot dedent behavior in `std:test`.
