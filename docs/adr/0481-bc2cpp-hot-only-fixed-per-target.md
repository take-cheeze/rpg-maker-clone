# 0481. bc2cpp hot-only is set per build, not by a desktop environment switch

Date: 2026-10-16

## Status

Accepted. Amends ADR 0214 (the `BC2CPP_HOT_ONLY=1` override is gone).

## Context

ADR 0214 made hot-only a build property (`enable_bc2cpp_hot_only` in
`build_config.rb`) and added an environment override, `BC2CPP_HOT_ONLY=1/0`,
that forced the mode either way for a whole build. The `=1` side let a build
that did not opt in, such as a desktop build, be made hot-only from the
shell. Nothing in CI or the build set it, so the switch only added a second
way to choose the mode, and its wiring had to be kept consistent with the
per-build setting.

## Decision

The mode is chosen only by the build definition. `bc2cpp_hot_only_build?`
returns false for any build that did not opt in, whatever the environment
says. `BC2CPP_HOT_ONLY=0` stays: it turns a flash build's mode off for one
run, which the census and nomethod-verify tools need for full-compile
measurements. Flash builds (psp, wio, maix) and the native `closed` build
are hot-only by `build_config.rb`.

## Consequences

- To measure a full-compile closed build, run it with `BC2CPP_HOT_ONLY=0`.
- To check a new hot list, compare the closed build against the `=0` build
  (docs/profiling.md). The `=1` route is gone.
- `scripts/bc2cpp/hot_only_check.rb` keeps its wiring checks, including that
  `=1` no longer turns a desktop build hot-only. Its generated-code section
  stops at an RBS load error on the fixture world; that error is on master too.
