# 0522. Desktop-only: remove the embedded hardware targets

Date: 2026-10-20

## Status

Accepted

## Context

The repository carried five embedded firmware ports besides the desktop build:
Wio Terminal (`app/wio`, ADR 0007 and its follow-ups), M5Stack Core (`app/m5stack`),
Sipeed Maix Amigo (`app/maix`), iPod nano 7G (`app/nano7`, with `app/shared/rpg2k_walk`),
and PlayStation Portable (`app/psp`, ADR 0010). Each one needed its own cross build,
its own `#if` guards in the engine sources, its own PlatformIO/Renode/QEMU jobs in CI,
and its own labels and docs.

The Wio build also became the canonical closed world for bc2cpp (ADR 0466). Its
gem list, its wio-only strip steps (`wio_strip_*` in `build_config.rb`), and its
check baselines were the reference every bc2cpp check was tuned to. Keeping that
machinery alive for hardware nobody ships to made the desktop workflow slower and
harder to review, and most of CI's wall-clock went to the embedded jobs.

## Decision

The project targets desktop (the host native build) only, with the Emscripten
(browser), Android and Optcarrot builds kept as they were.

- Removed: `app/wio`, `app/m5stack`, `app/maix`, `app/nano7`, `app/psp`,
  `app/shared/rpg2k_walk`, the `scripts/` helpers that existed only for them, their
  mruby gem shims and HAL headers, and the embedded-only `#if` branches in the engine
  sources.
- The bc2cpp canonical closed world moves from the `wio` build name to the `closed`
  build. The wio-only strip steps in `build_config.rb` are deleted with it, and the
  bc2cpp checks and baselines are regenerated against `closed`.
- CI keeps the host, Emscripten, Android, Optcarrot and bc2cpp/checks jobs; the
  Wio, Renode, PSP, M5Stack, Maix and nano7 jobs are removed. Labels and issue
  templates for those targets are removed too.

Historical ADRs are not edited. They still describe the embedded ports as they were
at the time, and a reader who needs the hardware history can find it in git
history at the commit before this change.

## Consequences

- The engine sources lose their `PSP_BUILD`, `WIO_TERMINAL`, `MAIX_BUILD`,
  `M5STACK` and `NANO7` branches; the desktop and Emscripten code paths are the
  only ones that compile.
- Embedded hardware bring-up can no longer be checked in CI. Anyone who wants to
  restart an embedded port has to restore it from git history and re-add its CI
  job, which is the cost of this decision.
- bc2cpp measurements taken before this change were taken against the `wio` world.
  Results from before this date are historical; new baselines are against `closed`.
- Several dated `docs/bc2cpp-*.md` measurement pages keep their numbers, marked as
  historical.
- The `closed` build no longer links `mruby-io` through a HAL shim; it uses the
  stock POSIX `mruby-io` the desktop build uses.
