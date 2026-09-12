# 143. Superseding docs/adr/0142: a real `wio_rgss_boot` flash/RAM measurement at bc2cpp's *actual* current scope

Date: 2026-09-12

## Status

Accepted — supersedes docs/adr/0142

## Context

docs/adr/0142 set out to measure `RPGMAKER_BC2CPP=1`'s real, linked
flash/RAM cost on `wio_rgss_boot` "at its current (~30-round) coverage
scope." Its own results table, though, shows a per-gem method count of
`mruby-lcf-compiled` ×7, `mruby-rgss-compiled` ×17 (`RGSS::Sprite` only),
`mruby-rpg2k-compiled` ×31 (`Game::Picture` ×25, `Game::EnemyAction` ×6) —
55 methods total, across 3 owner classes for rpg2k. That is the state of
`tools/bc2cpp/compiled_gems.rb` from very early in this effort (roughly
docs/adr/0139's first two rounds), not the ~31-round scope the ADR's own
prose claims to measure. By the time 0142 was written, `compiled_gems.rb`'s
real `owners:` lists already covered:

| gem | owner classes | of which `.singleton` |
| --- | ---: | ---: |
| `mruby-lcf-compiled` | 12 | 0 |
| `mruby-rgss-compiled` | 14 | 7 |
| `mruby-rpg2k-compiled` | 74 | 24 |

— including `RPG2k::Scene::Map`, `RPG2k::Scene::Battle`,
`Game::Interpreter`, `Game::Battle::Combatant`, `Game::Actor`/`Party`, and
31 `.singleton` owners across both gems. 0142's own measurement almost
certainly ran against a stale or half-regenerated build directory (most
likely a `3rd/mruby/build/wio` left over from an earlier point in this
session's own history, or a rake dependency-tracking gap that did not
re-run `bc2cpp.rb` after a later `compiled_gems.rb`/`register.cxx` edit) —
not the tree its own commit actually carried. Its numbers, its "one gem is
a wild, 100x outlier" framing, and its "not evenly distributed" conclusion
are all downstream of that stale build and need a real, provably-clean
re-measurement, which is what this ADR does.

This session did not touch `tools/bc2cpp/`, any `*-compiled/` source file,
or docs/adr/0139 — same scope restriction 0142 itself had.

## What was done

**A provably clean re-measurement**, paranoid about the exact failure mode
above:

1. **Verified the real, current scope *before* cross-compiling anything.**
   `tools/bc2cpp/compiled_gems.rb`'s `owners:` arrays gave the table above.
   Real method counts were cross-checked two independent ways against a
   freshly generated build (not reused from any prior state in this
   worktree, which started with no `3rd/mruby` submodule checked out at
   all): counting `mrb_define_method`/`mrb_define_private_method`/
   `mrb_define_class_method`-family call sites in each gem's committed,
   hand-written `register.cxx`, and counting distinct top-level
   `mrb_value …_impl` function definitions in the freshly-generated
   `*_compiled_gen.cpp` bc2cpp actually emitted for this build. Both agree:

   | gem | `register.cxx` call sites | generated `_impl` functions |
   | --- | ---: | ---: |
   | `mruby-lcf-compiled` | 34 | 34 |
   | `mruby-rgss-compiled` | 81 | 82 |
   | `mruby-rpg2k-compiled` | 1,457 | 1,457 |

   1,573 real compiled methods total — **28.6x** 0142's own stale count of
   55.

2. **Wiped every wio-specific build artifact before each cross-compile.**
   This worktree began with no submodules checked out at all (a fresh
   `.claude/worktrees` checkout), so the first build was clean by
   construction; `3rd/mruby/build/wio`, `.pio/build/wio_rgss_boot` and
   `.pio/build/wio` were still explicitly `rm -rf`'d before both the
   baseline and the `RPGMAKER_BC2CPP=1` build, per this ADR's own
   instructions, so neither run could reuse the other's generated code.
   `3rd/mruby/build/host` (the `mrbc` bootstrap compiler) was left in place
   between the two builds, same as 0142 — it does not depend on
   `RPGMAKER_BC2CPP`.
3. **Reproduced 0130/0133/0135/0142's established process exactly**: `git
   submodule update --init` for every submodule the build actually touches
   (`3rd/mruby`, `3rd/uni-algo`, `3rd/lvgl`, `3rd/stb`, `3rd/mruby-marshal`,
   `3rd/mruby-onig-regexp`, `3rd/mruby-stringio`, `3rd/quickjs`,
   `3rd/effekseer`, `3rd/mgem-list` — the host build's default `mruby-mvjs`
   gem needs the last two, a real gap this session hit fresh, same as
   docs/adr/0130/0140 before it); all nine `patches/*.patch` files applied
   by hand in `cmake/build-mruby.cmake`'s own order (all nine applied
   cleanly — `mruby-stringio-native-getbyte.patch` and
   `mruby-marshal-psp-wio-onigmo-optional.patch` target the
   `3rd/mruby-stringio`/`3rd/mruby-marshal` submodules, not `3rd/mruby`
   itself, confirmed directly from `cmake/build-mruby.cmake`); the CP932
   (`bestfit932.txt`) and JIS0208 Unicode mapping tables downloaded fresh
   and SHA-256-verified byte-for-byte against `flake.nix`'s own pins
   (`sha256-JhTP6jXDyGxB0zGYeTqEykTt7jzw7gATphpD+6Ts4zE=` and
   `sha256-HFcYcEV/Gcl3IGMfqD7kkVSalroUNtoSlnhqZ9hjLoc=`); `arm-none-eabi-*`
   14.2.1 (PlatformIO's own pinned `toolchain-gccarmnoneeabi` package,
   confirmed present and used throughout — the unversioned
   `~/.platformio/packages/toolchain-gccarmnoneeabi` this project's own
   `build_config.rb` prefers); `RGSS_WIO_ARDUINO_INCLUDES` freshly
   extracted from this session's own real `pio run -e wio -v` compile of
   `app/wio/src/main.cxx` (13 real framework `-I` paths: Arduino core,
   CMSIS, CMSIS-Atmel, `Seeed_Arduino_LCD`/`SPI`/`Adafruit_ZeroDMA`/
   `Seeed_Arduino_FreeRTOS`, the board's `variant.h`), not reused from any
   prior session; a standalone `arm-none-eabi` `libuni-algo.a` cross-build
   of `3rd/uni-algo/src/data.cpp` with the same trim defines
   `cmake/uni-algo-trim.cmake` documents (`.text` 145,440 bytes — an exact
   match to docs/adr/0140's own independently-built number, confirming
   this session's toolchain and flags reproduce the project's real,
   established state); no `-flto` (docs/adr/0135).
4. **Two full `MRUBY_TARGET=wio rake` cross-compiles** (baseline, then
   `RPGMAKER_BC2CPP=1`), each followed by a real `pio run -e wio_rgss_boot`
   link from a freshly-wiped `.pio/build/wio_rgss_boot`. Confirmed each
   build's own gem list via rake's own summary output: the baseline's
   `wio` config carries no `*-compiled` gem at all; the `RPGMAKER_BC2CPP=1`
   build's carries exactly `mruby-lcf-compiled`, `mruby-rgss-compiled`,
   `mruby-rpg2k-compiled` and nothing else different — a clean, single-
   variable A/B.
5. **Positively confirmed the `RPGMAKER_BC2CPP=1` build's generated code
   reflects full, current coverage before trusting any size number** — the
   exact check this ADR exists to do that 0142 evidently skipped. `arm-
   none-eabi-nm` on the real, freshly-built
   `3rd/mruby/build/wio/mrbgems/mruby-rpg2k-compiled/src/register.o`:

   ```
   RPG2k__Scene__Battle_* symbols:  220  (110 methods x wrapper+_impl)
   *_singleton_* symbols:           196  (round 29-31's .singleton owners)
   Battle__Combatant_* symbols:      32  (round 31's newest owner)
   ```

   All three late-round symbol families — absent from any early-round
   build — are present in the real, linked object file. Staleness ruled
   out positively, not just by absence of an error.

Both links fail on the real `FLASH` region overflow, as every
`wio_rgss_boot` link has since docs/adr/0104 (see docs/adr/0140/0141 for
the current, non-bc2cpp overflow's own breakdown) — `ld` still completes
real, full section layout before refusing to emit `firmware.elf`, so
`firmware.map` carries exact `.text`/`.ARM.extab`/`.ARM.exidx`/`.data`/
`.bss` sizes both times, not an estimate. The baseline's own numbers are an
exact match to docs/adr/0140/0141/0142's own previously-recorded baseline
(`.text` 1,167,296; `.data` 12,880; `.bss` 19,360; overflow 675,960 bytes)
— independent confirmation that *this* rebuild, unlike 0142's, reproduces
the project's real current state.

## What was measured

| | baseline (no bc2cpp) | `RPGMAKER_BC2CPP=1` (real, full ~31-round scope) | delta |
| --- | ---: | ---: | ---: |
| `.text` (flash) | 1,167,296 | 2,211,592 | **+1,044,296** |
| `.ARM.extab` | 4,328 | 4,556 | +228 |
| `.ARM.exidx` | 12,240 | 35,240 | +23,000 |
| `.data` (RAM) | 12,880 | 12,880 | 0 |
| `.bss` (RAM) | 19,360 | 19,360 | 0 |
| **Flash needed** (`.text`+`.ARM.extab`+`.ARM.exidx`, 507,904 budget) | **1,183,864** (233.1%) | **2,251,388** (443.3%) | **+1,067,524** |
| **RAM used** (`.data`+`.bss` of 196,608 budget) | **32,240** (16.4%) | **32,240** (16.4%) | **0** |
| real `ld` "region FLASH overflowed by" | 675,960 | 1,743,484 | +1,067,524 |

**RAM is still bit-for-bit identical with the flag on or off**, now
reconfirmed at 28.6x the method-coverage scope — the same reasoning
docs/adr/0142 already gave still holds: `.data`/`.bss` are compile-time
static storage, and every AOT-compiled method is still registered via a
plain `mrb_define_method` call at gem-init time regardless of whether it
installs an `MRB_METHOD_FUNC` or a bytecode `RProc`. This measurement still
cannot see the runtime heap cost docs/adr/0136/0137 measured separately
(the live `RProc`/method-table construction cost, not visible in
`.data`/`.bss`) — answering that at bc2cpp's current scope is real,
separate, out-of-scope follow-up work, same as 0142 already flagged.

### A real, surprising finding 0142's stale measurement could not have shown

0142's own (stale, 55-method) `RPGMAKER_BC2CPP=1` build measured `.text` at
2,190,496 bytes and a Flash-needed figure of 2,229,304 bytes (438.9%). This
session's real, full-scope (1,573-method) rebuild measures `.text` at
2,211,592 and Flash-needed at 2,251,388 (443.3%) — **only +21,096 and
+22,084 bytes more respectively, for 28.6x more compiled method coverage.**
The overwhelming majority of `RPGMAKER_BC2CPP=1`'s real flash cost was
apparently already "paid for" by the first couple of rounds' own shared
per-gem fixed overhead (embedding/type-check helper code, MONO/POLY
dispatch scaffolding, and similar infrastructure paid once per gem rather
than once per method); each additional method past that point costs
comparatively little on average. This is consistent with — and now
directly explains — the per-method-cost picture below: `mruby-rpg2k-
compiled`'s real per-method cost, measured honestly across its *actual*
1,457-method scope, is nowhere near the "100x RGSS::Sprite" outlier 0142
reported for its own 31-method slice (that framing was an artifact of
dividing mostly-fixed overhead across a tiny denominator, not a real,
specific codegen inefficiency in Game::Picture/EnemyAction). Why the
marginal cost is this low for later rounds specifically is a real question
this ADR does not answer (`tools/bc2cpp/` is out of scope for the session
that produced this measurement, same restriction 0142 had) — flagged here
as a finding, not chased further.

### Per-gem breakdown, honestly re-checked at the real, current scale

Per-object-file `.text` sizes (`arm-none-eabi-size`) of the three compiled
gems' real, freshly-generated `register.o`, from the `RPGMAKER_BC2CPP=1`
build, against each gem's real, confirmed method count:

| gem | methods (confirmed) | `register.o` `.text` | bytes/method |
| --- | ---: | ---: | ---: |
| `mruby-lcf-compiled` | 34 | 11,309 | ~333 |
| `mruby-rgss-compiled` | 82 | 26,400 | ~322 |
| `mruby-rpg2k-compiled` | 1,457 | 1,069,716 | ~734 |

Summing the three gems' own `register.o` sizes (1,107,425 bytes) comes
within ~40,000 bytes of the real, measured net `.text` delta above
(1,044,296) — the same order of small, unreconciled gap 0142's own
methodology showed (its 1,047,376-byte `mruby-rpg2k-compiled` alone against
a 1,045,440-byte net delta), plausibly linker `--gc-sections`/relaxation
trimming a modest amount of dead code from the pre-link object; not chased
further here, consistent with 0142's own precedent of reporting gross
per-object sizes rather than a fully reconciled link-level attribution.

**Checking honestly, rather than assuming 0142's specific attribution still
holds at the new scale: it still does, directionally.**
`mruby-rpg2k-compiled` is still responsible for the large majority of the
real flash cost (1,069,716 of the 1,107,425-byte combined gross total,
~97%) — `mruby-lcf-compiled` and `mruby-rgss-compiled` together cost only
37,709 bytes. What changes is the *interpretation*: at 0142's stale
31-method scope this looked like "31 methods costing over 100x what 17
comparable methods cost" — a specific, damning-sounding per-method outlier.
At the real, current 1,457-method scope, `mruby-rpg2k-compiled`'s own
per-method cost (~734 bytes) is only ~2.2x `mruby-rgss-compiled`'s (~322)
and `mruby-lcf-compiled`'s (~333) — a real but far more modest difference,
plausibly just Game/RPG2k-namespace methods doing more real per-call work
on average (Sprite/Bitmap accessors are simple property gets/sets; Game::
Actor/Party/Battle methods implement real formulas and state machines).
Nothing here supports 0142's "a genuine outlier... a specific inefficiency
in this round's own codegen" framing once the correct, current denominator
is used.

## Decision

No code change — this is a measurement-only ADR, same shape as docs/adr/
0137/0142. It corrects the record rather than changing behavior:
docs/adr/0142's own flash/RAM numbers, its per-gem attribution, and its
"genuine outlier" framing were measured against a stale build reflecting
roughly 3.5% of bc2cpp's real, current method coverage (55 of 1,573
methods) and should not be relied on. This ADR's own numbers above are the
current, real, provably-clean ones.

## Consequences

- **At its current, real coverage scope, `RPGMAKER_BC2CPP=1` is still a
  clear net loss on `wio_rgss_boot`'s real flash budget** — now measured at
  +1,067,524 bytes (slightly more than 0142's stale +1,045,440), against a
  board that was already 675,960 bytes over budget without it. This
  conclusion survives the correction: flipping the flag on for wio remains
  a large regression at any coverage scope measured so far, not just at
  the small one 0142 happened to measure.
- **It remains a wash, not a win, on real static RAM** — reconfirmed at the
  new scale, same as 0142 already found. Answering whether bc2cpp changes
  the much larger runtime *heap* shortfall (docs/adr/0135/0136) still needs
  a live heap walk against a bc2cpp build, not attempted here (same
  deliberate scope boundary 0142 drew).
- **0142's "one gem is a 100x outlier, a specific codegen inefficiency"
  conclusion does not survive re-measurement at the real scope** and should
  not be cited going forward. The real, current per-method cost picture
  (`mruby-rpg2k-compiled` ~734 bytes/method vs `mruby-rgss-compiled`/
  `mruby-lcf-compiled` ~322-333 bytes/method) is a modest, plausible
  difference, not a red flag calling for a dedicated codegen investigation.
- **A real, unexplained finding for any future round to keep in mind**:
  the marginal flash cost of covering many more methods (55 -> 1,573, a
  28.6x increase) was surprisingly small in absolute terms (roughly
  +21,000 bytes) — most of `RPGMAKER_BC2CPP=1`'s real flash cost look to be
  front-loaded, fixed per-gem overhead rather than scaling with method
  count. Not investigated further here (`tools/bc2cpp/` stays out of scope
  for the session that produced this measurement) but worth a real look if
  a future round wants to find genuine savings.
- **Any future real re-measurement of this kind should independently
  verify scope before trusting its own numbers, the same way this ADR did
  for 0142's** — checking `tools/bc2cpp/compiled_gems.rb`'s real `owners:`
  arrays and cross-checking a freshly-generated build's own method count
  against them, *before* running an hours-long cross-compile, is cheap
  insurance against exactly the failure mode this ADR exists to correct.
- **Neither build boots or fits regardless of this flag** — same
  unresolved, dominant `FLASH` overflow docs/adr/0104-0141 already
  established; this ADR's comparison remains a controlled A/B on top of
  that shared, still-unfit baseline, not a claim either configuration
  produces working firmware.

## Addendum: which symbols the `RPGMAKER_BC2CPP=1` flash image actually spends its bytes on

A same-session follow-up to the aggregate numbers above, using the same
process (fresh submodule checkout, all nine patches, verified Unicode
tables, `RGSS_WIO_ARDUINO_INCLUDES` from a real `pio run -e wio -v`, no
`-flto`) and re-confirming non-staleness the same way: the real, freshly
built `mruby-rpg2k-compiled/src/register.o` carries 220
`RPG2k__Scene__Battle_*` symbols, 196 `*_singleton_*` symbols and 32
`Battle__Combatant_*` symbols — an exact match to this ADR's own numbers
above — and each gem's `register.o` real `.text` size
(`arm-none-eabi-size`) is bit-for-bit identical to the table above (11,309 /
26,400 / 1,069,716), as is the real link's `.text`/`.ARM.extab`/
`.ARM.exidx`/`.data`/`.bss` breakdown and its "region FLASH overflowed by
1743484 bytes" message. This is not a new measurement of a different build;
it is a per-symbol breakdown of the identical one.

`firmware.map`'s own linker-script memory-map listing gives an exact
address+size for every input section the link placed into `.text`. Summing
all 15,897 of them (2,355,092 bytes) overshoots the real linked `.text`
size (2,211,592) by about 143,500 bytes (~6.5%) — the same *kind* of small,
unreconciled gross-vs-net gap this ADR's own per-gem table already flagged
(1,107,425 gross vs. 1,044,296 net, ~40,000 bytes), most plausibly
`-fmerge-all-constants` (build_config.rb) folding equal-valued string/
constant sections across translation units at final-link time in a way the
map's *per-input-section* listing still shows at each contributor's
pre-fold size. Reported here as gross per-input-section sizes, the same
precedent this ADR's own per-gem table already set, not chased to a fully
reconciled link-level accounting.

### Top 30 individual symbols across the whole linked image

| # | bytes | % of `.text` | symbol | category |
| ---: | ---: | ---: | --- | --- |
| 1 | 85,253 | 3.85% | `(anonymous namespace)::build_ui(char const*)` [merged string pool] | app/wio boot main |
| 2 | 66,270 | 3.00% | `str1.1` (merged string-literal pool) | mruby core (`symbol.o`) |
| 3 | 37,944 | 1.72% | `cp932_reverse_table` | mruby-lcf CP932 codec table |
| 4 | 37,944 | 1.72% | `cp932_table` | mruby-lcf CP932 codec table |
| 5 | 34,468 | 1.56% | `mrb_mruby_rpg2k_compiled_gem_init` | bc2cpp: mruby-rpg2k-compiled |
| 6 | 27,044 | 1.22% | `Game__Interpreter_execute_impl` | bc2cpp: mruby-rpg2k-compiled |
| 7 | 20,952 | 0.95% | `presym_name_table` | mruby core symbol table |
| 8 | 18,964 | 0.86% | `mrb_vm_exec` | mruby core VM |
| 9 | 18,372 | 0.83% | `mrb_mruby_rpg2k_compiled_gem_init.str1.1` | bc2cpp: mruby-rpg2k-compiled |
| 10 | 18,359 | 0.83% | `.rodata` (whole-object blob) | mruby core gem-init / iseq pool |
| 11 | 10,476 | 0.47% | `presym_length_table` | mruby core symbol table |
| 12 | 9,204 | 0.42% | `Game__MoveRoute_execute_impl` | bc2cpp: mruby-rpg2k-compiled |
| 13 | 8,832 | 0.40% | `glyph_bitmap` | LVGL (`lv_font_montserrat_14`) |
| 14 | 7,488 | 0.34% | `RPG2k__Scene__Battle_drive_battle_item_impl` | bc2cpp: mruby-rpg2k-compiled |
| 15 | 7,420 | 0.34% | `RPG2k__Scene__SkillMenu_build_status_window_impl` | bc2cpp: mruby-rpg2k-compiled |
| 16 | 7,188 | 0.33% | `RPG2k__Scene__DebugMenu_build_window_impl` | bc2cpp: mruby-rpg2k-compiled |
| 17 | 7,112 | 0.32% | `RPG2k__Scene__Map_handle_name_input_impl` | bc2cpp: mruby-rpg2k-compiled |
| 18 | 6,584 | 0.30% | `RPG2k__Window_draw_cursor_skin_impl` | bc2cpp: mruby-rpg2k-compiled |
| 19 | 6,400 | 0.29% | `RPG2k__Scene__Map_handle_kana_name_input_impl` | bc2cpp: mruby-rpg2k-compiled |
| 20 | 5,396 | 0.24% | `mrb_f_sprintf` | mruby core |
| 21 | 5,317 | 0.24% | `gem_mrblib_mruby_rpg2k_proc_iseq_68902` | mruby core gem-init / iseq pool |
| 22 | 5,300 | 0.24% | `RPG2k__Scene__ChipsetEditor_move_cursor_impl` | bc2cpp: mruby-rpg2k-compiled |
| 23 | 5,272 | 0.24% | `RPG2k__Scene__ItemMenu_choose_item_impl` | bc2cpp: mruby-rpg2k-compiled |
| 24 | 5,200 | 0.24% | `RPG2k__Scene__ItemMenu_update_teleport_target_impl` | bc2cpp: mruby-rpg2k-compiled |
| 25 | 5,200 | 0.24% | `RPG2k__Scene__SkillMenu_update_teleport_target_impl` | bc2cpp: mruby-rpg2k-compiled |
| 26 | 5,152 | 0.23% | `RPG2k__Scene__Battle_drive_battle_skill_impl` | bc2cpp: mruby-rpg2k-compiled |
| 27 | 5,148 | 0.23% | `RPG2k__Scene__Map_drive_message_impl` | bc2cpp: mruby-rpg2k-compiled |
| 28 | 5,068 | 0.23% | `RPG2k__Scene__DebugMenu_update_block_focus_impl` | bc2cpp: mruby-rpg2k-compiled |
| 29 | 4,988 | 0.23% | `RPG2k__Scene__EquipMenu_update_slots_impl` | bc2cpp: mruby-rpg2k-compiled |
| 30 | 4,944 | 0.22% | `RPG2k__Scene__EquipMenu_update_items_impl` | bc2cpp: mruby-rpg2k-compiled |

(Full top 40 and raw per-input-section data retained in this session's own
working notes, not reproduced in full here.) Past the first ~10-12 entries
(genuinely large single tables/blobs — Unicode/CP932 tables, mruby's presym
symbol tables, a merged UI string pool, one whole-object `.rodata` blob),
the list is dominated by individual `mruby-rpg2k-compiled` `_impl`
functions in the 4-9 KB range rather than a few outsized ones: bc2cpp's
1,457 real compiled methods are many mid-sized functions, not a handful of
huge ones, so a flat by-symbol ranking naturally fills up with them once the
handful of genuinely large tables/blobs are past. This is a different
picture from "one giant symbol dominates" — it is many multi-KB
contributors adding up, consistent with this ADR's own "front-loaded fixed
overhead, then a mostly-flat marginal cost per method" finding above.

### Largest individual symbols within each compiled gem's own `register.o`

Same `register.o` files as this ADR's own per-gem table, `arm-none-eabi-nm
--size-sort -S`, real symbols (not merged/discarded), demangled:

**`mruby-lcf-compiled`** (34 methods, `register.o` `.text` 11,309 bytes; 73
real text symbols, top 15 sum to 9,898 bytes):

| bytes | symbol |
| ---: | --- |
| 1,656 | `LCF__Array1D____impl` |
| 1,432 | `LCF__Array1D_____impl` |
| 1,084 | `LCF__File_to_lcf_impl` |
| 912 | `mrb_mruby_lcf_compiled_gem_init` |
| 592 | `LCF__Array2D____impl` |
| 412 | `LCF__Array1D_key__impl` |
| 320 | `LCF__Sections____impl` |
| 300 | `LCF__Array1D_delete_impl` |
| 192 | `LCF__MapTree_schema_impl` |
| 192 | `LCF__MapUnit_schema_impl` |
| 192 | `LCF__Database_schema_impl` |
| 192 | `LCF__SaveData_schema_impl` |
| 160 | `LCF__Sections_add_impl` |
| 160 | `LCF__Array1D_int16_values_impl` |
| 156 | `StringIO_ungetbyte_impl` |

**`mruby-rgss-compiled`** (82 methods, `register.o` `.text` 26,400 bytes;
168 real text symbols, top 15 sum to 22,110 bytes) — dominated by the
`.singleton`-owner probe/dispatch methods added in rounds 29-31, not
`RGSS::Sprite`'s own plain accessors:

| bytes | symbol |
| ---: | --- |
| 2,984 | `RGSS_singleton_window_probe_impl` |
| 1,980 | `mrb_mruby_rgss_compiled_gem_init` |
| 1,640 | `RGSS__Bitmap_singleton_failure_reason_impl` |
| 1,400 | `RGSS_singleton_transition_shape_probe_impl` |
| 1,328 | `RGSS_singleton_tilemap_above_layer_probe_impl` |
| 1,276 | `RGSS__Input_singleton_dir8_impl` |
| 1,204 | `RGSS__Graphics_singleton_brightness_sprite_impl` |
| 1,064 | `RGSS__ErrorReport_singleton_push_impl` |
| 628 | `RGSS__Input_singleton_dir4_impl` |
| 628 | `RGSS__Input_singleton_key_index_impl` |
| 348 | `RGSS_singleton_warn_once_impl` |
| 344 | `RGSS__Input_singleton_press_impl` |
| 340 | `RGSS__ErrorReport_singleton_record_impl` |
| 276 | `RGSS__Graphics_singleton_brightness__impl` |
| 240 | `RGSS__Input_singleton_release_impl` |

**`mruby-rpg2k-compiled`** (1,457 methods, `register.o` `.text` 1,069,716
bytes; 2,922 real text symbols — wrapper+`_impl` per method — top 15 sum to
994,078 bytes, i.e. the top 15 alone are ~93% of this gem's whole real
`.text`, `mrb_mruby_rpg2k_compiled_gem_init` and `Game__Interpreter_execute_impl`
together already ~5.7%):

| bytes | symbol |
| ---: | --- |
| 34,468 | `mrb_mruby_rpg2k_compiled_gem_init` |
| 27,044 | `Game__Interpreter_execute_impl` |
| 9,204 | `Game__MoveRoute_execute_impl` |
| 7,488 | `RPG2k__Scene__Battle_drive_battle_item_impl` |
| 7,420 | `RPG2k__Scene__SkillMenu_build_status_window_impl` |
| 7,188 | `RPG2k__Scene__DebugMenu_build_window_impl` |
| 7,112 | `RPG2k__Scene__Map_handle_name_input_impl` |
| 6,584 | `RPG2k__Window_draw_cursor_skin_impl` |
| 6,400 | `RPG2k__Scene__Map_handle_kana_name_input_impl` |
| 5,300 | `RPG2k__Scene__ChipsetEditor_move_cursor_impl` |
| 5,272 | `RPG2k__Scene__ItemMenu_choose_item_impl` |
| 5,200 | `RPG2k__Scene__ItemMenu_update_teleport_target_impl` |
| 5,200 | `RPG2k__Scene__SkillMenu_update_teleport_target_impl` |
| 5,152 | `RPG2k__Scene__Battle_drive_battle_skill_impl` |
| 5,148 | `RPG2k__Scene__Map_drive_message_impl` |

`Game::Interpreter#execute` and `Game::MoveRoute#execute` (both real
event-command/move-command dispatch loops with many branches) are, by a
wide margin, the two largest *individual* compiled methods in the entire
image — consistent with this ADR's own "Game/RPG2k-namespace methods doing
more real per-call work on average" explanation for `mruby-rpg2k-compiled`'s
higher per-method byte cost, rather than a codegen inefficiency. Past those
two and the gem-init table, the remaining bulk of `mruby-rpg2k-compiled`'s
size is the long tail this ADR's own body already describes: ~1,450
further methods averaging a few KB each, not one or two outsized ones.

### Decision / consequences (addendum)

No code change, same as this ADR's own body. This addendum does not revise
any conclusion above — it only shows, at the individual-symbol level, what
the aggregate and per-gem-total numbers already implied: outside the first
dozen or so genuinely large tables/blobs (mostly *not* bc2cpp: Unicode/CP932
tables, mruby's own presym tables, a UI string pool), the image's size is
dominated by a very long tail of individually modest `mruby-rpg2k-compiled`
generated methods, with `Game::Interpreter#execute` and
`Game::MoveRoute#execute` standing out as the two largest single compiled
functions in the whole firmware.
