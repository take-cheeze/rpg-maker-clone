# 225. Drop the irep debug fields on wio (`MRB_NO_IREP_DEBUG`)

Date: 2026-09-24

## Status

Accepted

## Context

`struct mrb_irep` has two debug-only pointers:

- `lv`: the names of the irep's local variables;
- `debug_info`: the line-number table.

Every method and block of every gem's mrblib is one `mrb_irep`, dumped as a
static struct (ADR 0224). The wio build already leaves both fields `NULL`:
it compiles its Ruby without `-g`, and `build_config.rb` strips the lv
arrays from the cdump output. The fields still cost 8 bytes of flash per
irep on a 32-bit target.

## Decision

`patches/mruby-no-irep-debug.patch` adds a build option,
`MRB_NO_IREP_DEBUG`, that removes both fields from `struct mrb_irep`:

- Code reads them through `MRB_IREP_LV()` and `MRB_IREP_DEBUG_INFO()`.
  Under the option these return `NULL`, so every reader takes the path it
  already takes for an irep compiled without that information:
  - backtraces have no file and line;
  - `Proc#parameters` and `Kernel#local_variables` have no names.
- The `.mrb` loader skips the DEBUG and LV sections.
- `mrb_proc_merge_lvar` raises, as it already does when names are missing.
- Static `mrb_irep` initializers in the core use
  `MRB_IREP_DEBUG_NULL_FIELDS` where the two fields go.
- cdump.c wraps the two initializers it emits in
  `#ifndef MRB_NO_IREP_DEBUG`. So the host `mrbc`, built without the option,
  writes C that compiles for a target built with it.
- `mruby-compiler` and `mruby-binding` write the fields, so they refuse to
  build with the option (`#error`). The wio build links neither.

`build_config.rb` defines `MRB_NO_IREP_DEBUG` for the wio target only. The
patch is applied to every build, and no other build defines the option, so
nothing else changes.

`mruby-rgss/src/lib.cxx`'s `script_location` no longer reads
`irep->debug_info` itself. `mrb_debug_get_position` already returns false
for an irep without debug info.

## Consequences

Measured with a full `wio_rgss_boot` link (the baseline configuration of
`scripts/wio_bc2cpp_measure.bash`), on top of ADRs 0223 and 0224:

- **Flash: −19,936 B.** That is 8 bytes for each of about 2,490 ireps.
  `ld`'s `FLASH` overflow falls from 479,280 to 459,344 B.
- **Static RAM:** unchanged. The ireps were already `.rodata`.


- **No behaviour change on wio.** The fields were already `NULL` there.
  Bytecode loaded at run time (`mrb_load_irep_buf`) now drops its line
  numbers too. It had them before only if it was compiled with `-g`.
- mruby's own test suite, built with the option and without
  mruby-compiler/binding/eval, fails only these tests, all of which need
  local variable names: `Proc#parameters`, `Kernel#local_variables`,
  `Method#parameters`, `UnboundMethod#parameters`. Without the option the
  suite is unchanged.
