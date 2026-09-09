# 115. Strip mrbc debug info (line numbers, local-variable names) from wio's compiled Ruby

Date: 2026-09-09

## Status

Accepted

## Context

Prompted by a simple question -- "is there an effective mruby bytecode
optimization/compression method?" -- while looking for one, `build_config.rb`
turned out to already answer it, just not for this target: PSP's own
`CrossBuild` block (line ~636) already strips `-g` from `conf.mrbc.
compile_options` right after `enable_debug` sets it, with a real, cited
reason (docs/adr/0047-psp-memory-budget.md): `-g` embeds line-number and
local-variable debug tables into every compiled `.rb` file's RITE bytecode
(mruby-rpg2k, mruby-rgss, mruby-lcf, and mruby's own core `mrblib` --
whatever gem the build compiles Ruby for, not just the game's own script),
and ADR 47 measured that costing roughly 240-350 KB of live RAM on PSP once
`mrb_load_irep` parses it at boot.

wio's own `CrossBuild` block also calls `enable_debug` (needed for its
other effects -- `-g3` on the C/C++ compilers, real native DWARF that never
gets mapped into RAM) but never got the same mrbc-side fix. Nothing about
that omission was deliberate -- it's the same gap PSP's ADR 47 already
named and fixed for itself, just never carried over to the sibling
bare-metal target this whole series has been trying to fit into a much
smaller board.

## Decision

Added the same fix to wio's `CrossBuild` block, and went one step further:
also pass `--remove-lv` (`MRB_DUMP_NO_LVAR`, the same flag mruby's own
`mruby-bin-strip` gem uses for identical post-compile stripping), which
drops the separate local-variable name table PSP's own fix leaves alone.
Both tables exist purely for introspection a debugger or `eval`/`binding`
would use (`Kernel#local_variables`, backtraces with real variable names) --
confirmed by grepping every `.rb` file this build compiles
(`mruby-rpg2k`/`mruby-rgss`/`mruby-lcf`) for `eval`/`instance_eval`/
`class_eval`/`binding`: none, matching the mruby-compiler-isn't-even-linked
finding from earlier the same day. Neither table is read by anything this
firmware calls.

```ruby
conf.mrbc.compile_options =
  (conf.mrbc.compile_options.split(' ').reject { |o| o == '-g' } << '--remove-lv').join(' ')
```

### What was measured

A standalone host-side `mrbc` run on this project's own `mruby-rpg2k`
mrblib (16 files -- the same set already trimmed by ADR 97/107, minus
`debug_menu.rb`/`battle.rb`/`battle_rpg2k3.rb`) first, to size the effect
before touching the real build:

| flags | output size |
| --- | --- |
| `-g` (current wio default) | 648,201 |
| *(default, no `-g`)* | 563,013 |
| *(default)* + `--remove-lv` | 541,216 |

**106,985 bytes off rpg2k's own mrblib alone** -- and that's one gem; every
other gem's Ruby (rgss, lcf, mruby's own core mrblib) pays the same `-g`
tax today.

Then a real relink, `env:wio_rgss_boot`, on top of everything landed this
session (font SD offload default, cp932 build-time table, LVGL CLIB
backend, blend-format trim):

| state | FLASH overflow | RAM used | RAM headroom (of 196,608) |
| --- | --- | --- | --- |
| before (ADR 114's state) | 1,106,596 | 150,224 | 46,384 (23.6%) |
| after (`-g` + `--remove-lv` stripped) | **993,676** | **45,536** | **151,072 (76.8%)** |

**112,920 bytes of flash and 104,688 bytes of RAM**, both from one config
change with zero source-level risk (pure debug-metadata stripping, the same
mechanism `mruby-bin-strip` already performs post-compile and PSP's ADR 47
already validated as safe on a sibling target).

The RAM number is bigger, and shows up differently, than ADR 47's own
framing anticipated: on PSP it was a *runtime* cost (`mrb_load_irep`
parsing debug tables into fresh heap structures at boot, invisible to a
static link-time size check -- the same invisible-to-static-measurement
shape ADR 111 warned about generally). Here, comparing the real
`firmware.map` before and after shows most of it is a **static** cost:
`.data` alone drops by 105,200 bytes. The debug-info structs mruby emits
(`mrb_irep_debug_info`/`mrb_irep_debug_info_file`, holding pointers to
per-line tables and filename strings) apparently don't fold into `.rodata`
the way the plain iseq/pool arrays do on this toolchain -- confirmed by
inspecting the generated `gem_init.c` before and after: `grep -c
"mrb_irep_debug_info"` goes from present to zero once `-g` is gone. Whether
there is *also* a runtime heap-parsing cost on top of this static one (as
ADR 47 found on PSP) was not tested here -- no Renode boot run was done for
this ADR either, matching this whole series' standing practice of not
spending a hardware run to confirm a win the static numbers already prove
convincingly.

## Consequences

- Wio's flash overflow drops from 1,106,596 to 993,676, and -- far more
  significant for this board -- RAM headroom more than triples, from 6.4%
  of the earlier default-build baseline to 76.8% of budget now. Every prior
  ADR this session measured RAM headroom in the single digits of percent;
  this is the first real cushion this port has had.
- This applies to every gem's compiled Ruby uniformly (rpg2k, rgss, lcf,
  and mruby's own core `mrblib`), not something that needed per-gem
  wiring -- `conf.mrbc.compile_options` is build-wide.
- Backtraces produced by this firmware (if any error-reporting path ever
  surfaces one) will show numeric IREP/PC positions rather than source file
  names, line numbers, or local variable names. Nothing in this codebase's
  own error handling was found to rely on that (no `eval`/`binding`/
  `local_variables` call sites), and matches exactly what PSP's own ADR 47
  fix already accepted as the tradeoff there.
- The desktop/wasm/android builds are untouched -- `enable_debug`'s mrbc
  stripping is only added inside wio's own `CrossBuild` block, the same
  scoping PSP's fix already uses.
