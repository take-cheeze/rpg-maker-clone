# 0524. bc2cpp's canonical closed world is the `closed` build

Date: 2026-10-20

## Status

Accepted

## Context

bc2cpp's canonical closed world (ADR 0466) was the `wio` cross build, the Wio
Terminal firmware. That world carried wio-only tooling: stub-stripping and
unreachable-method passes that existed only to shrink the Wio firmware's flash,
an A/B flash-overflow measurement (`scripts/wio/bc2cpp_measure.bash`,
`overflow_report.rb`), a registered-methods probe, and a `wio-bc2cpp` CI job that
built and measured them. Those checks answer a question about one embedded board,
not about the closed world itself.

The `closed` build is the native (host-compiled) build of the same closed world
(RPG2000/2003 only, no `mruby-dir`, no Onigmo), and CI already runs bc2cpp against
it in the `bc2cpp-build` and `bc2cpp` jobs.

## Decision

- The bc2cpp canonical closed world is the `closed` build. Its gem set and
  check baselines are the reference the bc2cpp checks compile against.
- Removed, as wio-only bc2cpp tooling: `scripts/wio/bc2cpp_measure.bash`,
  `scripts/wio/overflow_report.rb` and its check, `scripts/wio/strip_bc2cpp_stubs.rb`,
  `scripts/wio/strip_unreachable_methods.rb`, `scripts/wio/unreachable_methods.rb`
  and its check, `tools/bc2cpp/wio_registered_methods.rb`, the `wio-bc2cpp` CI job,
  and the `wio_strip_bc2cpp_stubs` and `wio_strip_unreachable` steps in
  `build_config.rb` and the three `*-compiled`-owning gem rakes.
- Kept: the wio, m5stack, maix, nano7 and psp build configurations, their CI jobs,
  their engine guards and their flash-size strip steps (`strip_debug_output`,
  `strip_inline_helpers`, `strip_rgss_probes`, `strip_clock`), since they serve the
  embedded firmware builds rather than bc2cpp.

## Consequences

- bc2cpp's checks answer against the `closed` build alone, so the wio flash
  measurements and the wio-only stub stripping are no longer run in CI.
- The `closed` build's bc2cpp results are not yet re-baselined against the
  restored engine sources. Until they are, the checks that depend on the real
  profiler (`profiler.cxx` registrations and the closed world's rebind sites) may
  need their expectations updated.
- Comments in the gem rakes and `build_config.rb` that still name the removed
  `wio_strip_bc2cpp_stubs` and `wio_strip_unreachable` steps are left for a
  follow-up cleanup; they do not affect the build.
