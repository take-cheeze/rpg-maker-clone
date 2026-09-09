# 118. Strip local-variable-name tables mruby's own C-struct dumper always emits, regardless of --remove-lv

Date: 2026-09-09

## Status

Accepted

## Context

Asked to look for further bytecode-level reductions. ADR 115 added
`--remove-lv` (`MRB_DUMP_NO_LVAR`) to wio's `conf.mrbc.compile_options`
believing it stripped the same local-variable-name table
`mruby-bin-strip`'s own post-compile tool removes for the same reason. That
belief was wrong for this build specifically, and the real relink numbers
ADR 115 reported (993,676) were genuine, verified measurements -- but the
flag itself was not doing what its own comment claimed.

Root cause, found by comparing a freshly-generated `gem_init.c` against
what `--remove-lv` should have produced: mruby's `Command::Mrbc#run`
(`3rd/mruby/lib/mruby/build/command.rb`) always adds `-S` when generating
this build's C-source output (`cdump: true` is mrbgem.rake's own default,
never overridden anywhere in this project), which routes mrbc through
`3rd/mruby/src/cdump.c` rather than the *binary* `.mrb` dump path
(`src/dump.c`). `cdump.c`'s two `if (irep->lv)` checks (the array
definition and the `mrb_irep` struct's own pointer to it) never look at
`flags & MRB_DUMP_NO_LVAR` at all -- unlike `dump.c`'s own
`lv_defined = (flags & MRB_DUMP_NO_LVAR) ? FALSE : lv_defined_p(irep)`,
which does. A genuine feature-parity gap between mruby's two dump
backends, confirmed two ways: (1) a real `gem_init.c`, regenerated after
this ADR's own fix, still showed a populated `..._lv_62` array with real
symbol names (`index`, `dir`, `pattern`, `col`, `row`, `bx`, `by`) even
with `--remove-lv` passed; (2) a local, temporary patch to
`3rd/mruby/src/cdump.c` (adding the same `!(flags & MRB_DUMP_NO_LVAR)`
check `dump.c` already has) recovered a further 43,416 bytes on a real
relink, proving the data really was still there.

`irep->lv` itself is populated unconditionally by the compiler
(`mrbgems/mruby-compiler/core/codegen.c`, `s->irep->lv = lv = ...` inside
`if (nlv) { ... }`) for every scope with named local variables -- there is
no compile-time flag to suppress it at the source; only the *dump* step
ever had a flag for it, and only one of its two backends honored that
flag.

`3rd/mruby` is a submodule pointing at the real upstream `mruby/mruby`
(`.gitmodules`: `url = https://github.com/mruby/mruby.git`), not a fork
this project's own GitHub access can push a patch to -- so the
`cdump.c` fix used to *prove* the bug real cannot be the shipped fix.

## Decision

Wrap `conf.mrbc`'s own `run` method (a per-build-instance
`define_singleton_method`, scoped to wio's own `conf.mrbc` only -- PSP,
android, emscripten, and the host build each have their own separate
instance, untouched) to call the original implementation and then strip
the same data out of the C source it already wrote:

```ruby
conf.mrbc.define_singleton_method(:run) do |out, *args, **kwargs|
  method(:run).super_method.call(out, *args, **kwargs)
  path = out.path
  src = File.read(path)
  src.gsub!(/^mrb_DEFINE_SYMS_VAR\(\w+_lv_\d+, .*\);\n/, '')
  src.gsub!(/^(  )(\w+_lv_\d+),\n/, "\\1NULL,\t\t\t\t\t/* lv */\n")
  File.write(path, src)
end
```

Same effect as patching `cdump.c` directly, from a file this project
actually owns and can commit -- the same shape of fix ADR 111 already used
(patch the build-time generator, not the C++/C it feeds) applied one layer
further up the toolchain.

### What was verified

- **The root cause, directly**: a real `gem_init.c` before this fix still
  had populated `_lv_N` arrays despite `--remove-lv`; a temporary local
  patch to the vendored `cdump.c` (reverted, not shipped) fixing the same
  two checks `dump.c` already has recovered 43,416 bytes on a real relink,
  confirming the data was genuinely present and genuinely removable.
- **The build-side fix reproduces that number**: after wrapping
  `conf.mrbc.run` instead, a regenerated `gem_init.c` has zero `_lv_`
  occurrences (`grep -c "_lv_"` -> 0, was non-zero), and a real relink,
  `env:wio_rgss_boot`, on top of ADR 117's state:

  | state | FLASH overflow |
  | --- | --- |
  | ADR 117 (`MRB_DEBUG` stripped) | 975,984 |
  | + build-side `lv` table strip | **932,672** |

  **43,312 bytes** -- 104 bytes off the vendored-patch measurement above
  (minor whitespace/formatting differences between the regex substitution's
  output and mrbc's own native no-op-flag codepath, not worth chasing
  further). `.data`/`.bss` unchanged (45,536 bytes RAM used, 151,072
  headroom) -- pure flash win, matching expectations (`irep->lv` is
  `.rodata`, not RAM).
- **Scoped correctly**: only wio's own `conf.mrbc` instance is touched;
  PSP/android/emscripten/host builds use their own separate `Command::Mrbc`
  objects and are unaffected.

## Consequences

- Wio's flash overflow drops to 932,672. ADR 115's own comment
  (`--remove-lv ... drops the separate local-variable name table the same
  way`) was corrected in the same edit that added this fix -- it described
  intent, not what was actually happening.
- This project now carries one real, working local patch to mruby's own
  toolchain behavior, applied from `build_config.rb` rather than the
  submodule, specifically because the submodule cannot carry it. If a
  future session gets write access to a maintained mruby fork this project
  controls, the cleaner long-term fix is the two-line `cdump.c` change
  itself (upstream-reportable, too -- this looks like a genuine gap in
  mruby's own dumper, not something specific to this project's build).
- The regex targets `Command::Mrbc`'s own generated-identifier convention
  (`<name>_lv_<N>`, from `cdump.c`'s `sym_var_name`) -- if a future mruby
  upgrade changes that naming scheme, this fix silently stops matching
  (falls back to emitting the lv tables again, not a build break). Worth a
  quick `grep -c "_lv_"` check on `gem_init.c` after any mruby version
  bump.
