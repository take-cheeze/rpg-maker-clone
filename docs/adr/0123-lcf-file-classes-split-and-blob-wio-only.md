# 123. Split LCF::File classes out of schema.rb; scope the schema blob to wio only

Date: 2026-09-09

## Status

Accepted

## Context

ADR 109's `schema.rb` -> packed-blob swap (`mruby-lcf/mrbgem.rake`) dropped
`mrblib/schema.rb` from `spec.rbfiles` for *every* build target and replaced
it with the generated `schema_blob.rb`. `schema.rb` itself carried two
unrelated things in one file: the `LCF::Schema` data module the blob
generator actually reads, and, tacked on at the end, the real hand-written
`LCF::File`/`Database`/`MapTree`/`MapUnit`/`SaveData` classes (the `#initialize`
read path, `#to_lcf` write path, `#rpg2003?`, `#terminate_root?`). The blob
generator only ever walked `LCF::Schema`'s constants -- it never carried
those classes into `schema_blob.rb` -- so the swap silently dropped them from
every shipped target's own mruby build, not just wio's.

Running the real ctest suite for the first time this session (`exe_open`,
which runs the actual desktop `rpg_maker_clone` binary against real
Nepheshel game data) caught this immediately: `NameError: uninitialized
constant LCF::Database`. This was a real, product-affecting bug that had
been present since ADR 109 landed, invisible to `mruby-lcf`'s own unit tests
(they exercise `LCF::Array1D`/`Array2D` directly, never `LCF::File` and its
subclasses) and to every prior relink-only measurement in this series
(measuring flash/RAM never actually *runs* the resulting binary).

Fixing that surfaced a second, narrower problem while re-running the full
`ctest` suite (`mruby_test`, mrbtest's "host" config, which loads every
maker gem -- rpg2k/rpgxp/rpgvx/wolf/mvjs -- plus every test dependency at
once, unlike any real shipped target): 28 crashes, all `NameError:
uninitialized constant` for exactly 6 of `LCF::Schema`'s 27 top-level
constants (`DATABASE`, `MAP_TREE`, `MAP_UNIT`, `SAVE_DATA`, `SAVE_MOVABLE`,
`SAVE_PARTY_ACTOR`), confined entirely to `mruby-lcf/test/lcf_test.rb`.
Printing the freshly-assigned constant's own class immediately after the
assignment statement that sets it (inside the generated `schema_blob.rb`)
confirmed all 27 assignments succeed correctly at mruby-lcf's own gem-init
time -- the six then go missing sometime before `lcf_test.rb`'s own
top-level code runs, after every other gem has also initialised.
`const_defined?` (no inline cache) agreed with the direct `::` syntax and
`Module#const_get`, so this was not an inline-cache staleness bug on the
constant-access opcode. An explicit `GC.disable` placed before the blob
assigns them made no difference, ruling out a missing-write-barrier GC
explanation. What *did* fully explain it: toggling only the `schema.rb` /
`schema_blob.rb` swap off, with everything else about the host build held
identical, took `mruby_test` from `Crash: 28` to `Crash: 0`. The bug is
deterministically, 100% attributable to the schema-blob decoder's runtime
behaviour under mrbtest's specific full-27-gem scale; no narrower root
cause inside `Blob.parse!`/`section`/`decode_field_body` was found despite
this. No real shipped target was ever affected: `exe_open`/`render_probe`/
`audio_probe`/`error_dump` (desktop, single maker gem) passed both before
and after, and a standalone host-side C++ probe loading only "shared gems"
+ rpg2k resolved every one of the six constants correctly.

ADR 109's own numbers only ever justified the blob for wio's flash budget
(15,624 bytes recovered on a real `env:wio_rgss_boot` relink) -- no other
target was measured or needed it.

## Decision

**Split `mrblib/schema.rb`**: the `LCF::File`/`Database`/`MapTree`/
`MapUnit`/`SaveData` classes move to a new file, `mrblib/lcf_file.rb`,
verbatim. `schema.rb` keeps only `module LCF; module Schema; ...; end; end`
-- the pure data the blob generator reads. Both files are plain Ruby,
loaded together by every consumer: the default `spec.rbfiles` glob picks up
`lcf_file.rb` automatically for every mruby build target, and every
`scripts/*_check.rb`/`scripts/*.rb` that used to `load .../schema.rb`
directly under CRuby now also `load`s `.../lcf_file.rb` right after it (15
call sites: `analyze_game.rb`, `export_nano7_map.rb`, `lcf_save_check.rb`,
`lcf_save_roundtrip.rb`, `lcf_schema_coverage.rb`, `lcf_testbed_check.rb`,
`lcf_text_convert.rb`, `lcf_text_convert_check.rb`,
`rpg2k3_battle_command_check.rb`, `rpg2k3_battle_gauge_check.rb`,
`rpg2k3_battle_row_check.rb`, `rpg2k_command_soak.rb`,
`rpg2k_field_audit.rb`, `rpg2k_logic_check.rb`, `rpg2k_scene_check.rb`,
`rpg2k_testbed_logic_check.rb`).

**Scope the schema-blob swap to wio only** (`mruby-lcf/mrbgem.rake`, guarded
by `spec.build.name == 'wio'`): every other target (host/desktop, wasm,
psp, android) goes back to `schema.rb`'s plain Hash literals -- the same
form the CRuby `scripts/*_check.rb` scripts already trust, and the one ADR
109's own comparison script verified byte-for-byte against the blob. This
sidesteps the mrbtest bug entirely rather than chasing its root cause
further: wio is cross-compiled and never runs through `rake test` (the host
build only exists there to produce `mrbc`), so the one target that keeps
the blob is also the one target that was never going to exercise this
failure mode. `psp` is not included even though it is also a
cross-compiled, flash-constrained target -- ADR 109 never measured or
justified the blob there, so this keeps the change to exactly what is
proven necessary.

### What was verified

- `mruby_test` (`rake test`, the real "host" config, `cp932_table`/
  `jis0208_table` env vars set): **28 crashes -> 0**, `2057` assertions, all
  passing.
- Full `ctest`: **10/10 passing**, including `exe_open` (was failing with
  `NameError: uninitialized constant LCF::Database` before the
  `lcf_file.rb` split) and `nano7_host_smoke` (was failing the same way
  once the missing `lcf_file.rb` load was added to
  `scripts/export_nano7_map.rb`).
- A real, fresh `env:wio_rgss_boot` link (regenerated `WIO_MRUBY_BUILD_DIR`
  and `libmruby.a` from scratch, not a cached one, to rule out stale-cache
  numbers): **916,908 -> 919,572 bytes** FLASH overflow, a real **+2,664
  byte** regression. Verified against a controlled A/B on the *same* fresh
  toolchain/environment (this ADR's own change stashed vs. applied) rather
  than trusting the older cached ADR 122 number, which this run's "before"
  measurement reproduced exactly (916,908), confirming the environment
  itself introduced no drift. The remaining delta is genuinely this ADR's
  own split: dividing one compiled file into two costs a small, fixed
  per-file amount in mruby (a second top-level scope/proc, a second
  debug-file symbol) regardless of how the content is divided -- there is
  no way to avoid paying it and also fix the real `LCF::Database` bug the
  split exists to fix. `.data`/`.bss` (RAM) unaffected: this is a
  code-organisation change, not a heap-shape one.

## Consequences

- The real `LCF::Database`/`MapTree`/`MapUnit`/`SaveData` gap (present in
  every shipped target since ADR 109, not just wio) is fixed for every
  target, not just wio.
- wio keeps 100% of ADR 109's flash savings (still the only target using
  `schema_blob.rb`), at the cost of the `lcf_file.rb` split's own +2,664
  bytes -- a net new cost on top of ADR 109's original 15,624-byte win, but
  paying it was mandatory once the correctness bug was found; there was no
  version of this fix that both restored `LCF::File` everywhere and avoided
  the split's fixed per-file overhead.
- Every other target (desktop, wasm, psp, android) now compiles
  `schema.rb`'s plain Hash literals again instead of the blob -- a flash
  cost increase there (unmeasured; none of those targets are flash-
  constrained enough for ADR 109 to have measured it as a win in the first
  place) in exchange for no longer depending on a decoder mechanism with an
  unexplained failure mode under mrbtest's own test scale.
- The mrbtest-only bug itself (blob decoder + full 27-gem host load) is
  sidestepped, not root-caused. If a future change ever needs the blob on
  a *second* cross target (e.g. psp, if its own flash budget gets tight
  enough to justify measuring it there the way ADR 109 measured wio), that
  investigation is still open -- re-scoping the swap to include that target
  would need either accepting the same mrbtest-only test gap (that target's
  own build never runs `rake test` either, same as wio) or actually
  narrowing this bug's root cause first.
