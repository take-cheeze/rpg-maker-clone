# 0152: A CI job that reports the bc2cpp Wio flash overflow (baseline A/B)

Date: 2026-09-13

## Status

Accepted.

## Context

`RPGMAKER_BC2CPP=1` (build_config.rb) adds the three AOT-compiled gems to a
build, and on the Wio Terminal it is a large net *loss* on flash: ADRs
0142/0143 measured the `wio_rgss_boot` link overflowing the real 507,904-byte
FLASH region by 1,743,484 bytes with the flag on, against 675,960 bytes
without it. Those numbers have only ever been produced by hand. Nothing in CI
sets `RPGMAKER_BC2CPP` at all, and `env:wio_rgss_boot` — the only firmware that
exercises it and the only one that overflows — has never been built in CI,
because it needs two things no other target does: a from-scratch
`MRUBY_TARGET=wio` cross-build (`WIO_MRUBY_BUILD_DIR`) and a standalone
arm-none-eabi build of `3rd/uni-algo` (`WIO_UNIALGO_LIB_DIR`). `platformio.ini`
and `changelog.d/ci-wio-size-report.added.md` both said so.

The gap is a feedback one, not a feature: `wio_size_report.rb` already posts a
size table for the three firmwares that *do* fit (`wio`, `wio_walk`,
`wio_sd_upload`), and `wio_rgss_boot` — the build every flash-trimming ADR in
this series is actually about — is the one missing from that table. Two facts
make reporting it possible without changing any build:

- On a failed link GNU ld still writes a **complete `firmware.map`** (via the
  env's `-Wl,-Map=...`) before refusing to emit the ELF, so the exact section
  totals are available even though there is no binary to `size` (ADRs
  0141/0142/0143).
- ld's own message, ``region `FLASH' overflowed by N bytes``, gives an
  independent cross-check of the map-derived number.

ADR 0142 is also a cautionary tale about how easy this is to get wrong: it
published a full measurement taken against a stale build directory and had to
be corrected by 0143. Any automated measurement has to be as paranoid about
staleness as a careful manual one.

## Decision

Add a `wio-bc2cpp` CI job, plus the two scripts it drives:

- **`scripts/wio_bc2cpp_measure.bash`** reproduces the manual recipe of ADRs
  0141/0143/0144 in one place: the nine `patches/*.patch` (via
  `scripts/apply_mruby_patch.bash`), the two SHA-256-verified Unicode tables,
  the standalone ARM `libuni-algo.a` with `cmake/uni-algo-trim.cmake`'s defines,
  `RGSS_WIO_ARDUINO_INCLUDES` extracted from a real `pio run -e wio -t compiledb`,
  then two isolated `MRUBY_TARGET=wio rake` builds (baseline and
  `RPGMAKER_BC2CPP=1`) each followed by a `pio run -e wio_rgss_boot` link. Each
  variant gets its own `MRUBY_BUILD_DIR`, wiped before it is built, and the two
  links are expected to fail on the overflow — a failure for any *other* reason
  fails the script.
- **`scripts/wio_overflow_report.rb`** reads the resulting `firmware.map` pair
  and posts the A/B table (section sizes, flash needed, real overflow, % of
  budget, the `ld` cross-check and the delta) plus a best-effort
  per-object/archive breakdown of the bc2cpp image, following the existing
  `*_report.rb` conventions (`$GITHUB_STEP_SUMMARY`, plain-text twin, no-data
  path).
- **`scripts/wio_overflow_report_check.rb`** pins the parsing/arithmetic
  against a hand-built map, so the report is tested without a multi-minute
  cross-build; it joins the `ruby-checks` job.

- **The cross build's bootstrap host skips the AOT gems.**
  `build_config.rb`'s `MRUBY_BC2CPP_SKIP_HOST` (set by the measure script)
  leaves the compiled gems out of the `mrbc`-only host build. That build exists
  solely to produce the bytecode compiler, so compiling ~1,500 generated
  methods for it is wasted work — and on the host GCC the CI runners ship, the
  generated C++ is a hard compile error (``could not convert '1' from 'int' to
  'mrb_value'``), which blocked the whole cross build before the gem list was
  narrowed. Only the wio `libmruby.a` is measured; the **target** build still
  compiles the gems, and unset (the default) the desktop/wasm builds still
  compile them too, which is where they are actually exercised.

Two deliberate shape decisions:

- **Advisory, not a gate.** The overflow is expected and currently unfixable at
  every coverage scope measured, so the report step runs under `if: always()`
  and the job fails only when the cross-build or the report tooling breaks.
- **The build is cached on a content hash, and only that way.** The cache key
  hashes every input that feeds the generated `libmruby.a`
  (`build_config.rb`, `tools/bc2cpp/**`, the `*-compiled` and source gems,
  `patches/**`, `3rd/mruby/**`, …), so a hit is provably current and a change
  to any input forces a clean rebuild. That is the guard against exactly ADR
  0142's stale-build failure mode; the links themselves always re-run, so the
  maps also reflect the current app/LVGL.

## Consequences

- **The series' central number becomes visible on every push.** The
  bc2cpp-vs-baseline flash delta on `wio_rgss_boot`, which ADRs 0142/0143
  could only record by hand, now lands in the job summary — so a change that
  moves it is caught in review rather than at the next manual measurement.
- **No gating threshold to maintain, and no per-symbol breakdown.** The report
  does not fail on the overflow and does not produce ADR 0143's per-symbol
  ranking (that needs the widened-flash `wio_rgss_boot_heapdbg` ELF, an extra
  link); it reports sections, the real overflow and gross per-object totals.
- **CI cost is real on a cache miss** — two full ARM cross-builds plus two
  links, which is why it is a separate job with a 180-minute timeout rather
  than an addition to the two-minute `wio` job. The content-hash cache is what
  makes the common case cheap.
- **The measurement is reusable outside CI.** `scripts/wio_bc2cpp_measure.bash`
  is the scripted form of a process that until now lived only in ADR prose, so
  reproducing or extending an ADR's numbers no longer means re-deriving it.
- **`env:wio_rgss_boot` is unchanged.** Nothing about the firmware, its link
  or its overflow changes; this ADR only builds and reports it.
