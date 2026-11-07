# bc2cpp as a self-compiled mruby executable

Status: investigation. `host-libs/mruby-bc2cpp-runner` runs bc2cpp under mruby (an interpreted `bin/mruby` that loads the baked
sources). This note lists what stands between that and an executable that bc2cpp itself compiled.

## What exists

- `mruby-bc2cpp-sources` bakes the 311 files reachable from `tools/bc2cpp/bc2cpp.rb` into one mrblib; `mruby-require` evaluates
  each by name with `eval`.
- `mruby-bc2cpp-runner` names the entry (`BC2CPPRunner.run`); `bc2cpp_main.rb` is the script `bin/mruby` runs.
- The closed build and the optcarrot probe can generate code through the executable (`BC2CPP_MRUBY_RUNNER`).

## Why bc2cpp refuses it today

`bc2cpp_closed_world_violations` (tools/bc2cpp/compiled_gems.rb) accepts the build names `closed`, `optcarrot-probe` and `wio`, and
rejects any gem list with a gem in `BC2CPP_OPEN_WORLD_GEMS`: `mruby-eval`, `mruby-binding`, `mruby-proc-binding` and the bin gems
`mruby-bin-mruby`, `mruby-bin-mirb`, `mruby-bin-debugger`, among others. The runner build has all of those:

| Gem | Why the runner has it | Needed for a compiled executable? |
| --- | --- | --- |
| `mruby-eval`, `mruby-binding` | `mruby-require` evaluates baked sources with `eval` (its dependency) | No, if the sources are precompiled |
| `mruby-bin-mruby` | `bin/mruby` runs the entry script | No: a C `main` boots the state and calls the entry |
| `mruby-bin-mrbc`, `mruby-compiler` | the build compiles its own mrblib | Build time only, not linked |

bc2cpp's own sources never call `eval`: the only `eval` in the build is the baked-source loader.

## Steps

1. **Precompile the baked sources.** `mruby-bc2cpp-sources` runs `mrbc` on each baked file at build time, embeds the bytecode, and
   `require` loads it with `mrb_load_irep`. `mruby-require` then drops its `mruby-eval` dependency.
2. **A C `main`.** It sets `ARGV` and `$PROGRAM_NAME`, boots the state, requires the entry, and runs the exit handlers, in place of
   `bin/mruby` + `bc2cpp_main.rb`.
3. **A build kind.** Add a build name (for example `bc2cpp-self`) to `BC2CPP_CLOSED_WORLD_BUILDS` with its own required gem list.
   The closed-world inputs are the C and Ruby sources of the gems in the executable (onig, prism, marshal, stringio, json, yaml,
   zlib, ...).
4. **Analysis parity (a prerequisite).** The runner must reach the same analysis results as CRuby. It does not yet: on the RPG2000
   closed unit, CRuby's RBS_CHECKED_PARAMS check passes, while the runner reports 94 unproven parameters. The narrowing state at one
   instruction differs (1 fact instead of 6). Decoding, control-flow edges and `Set` operations match; the difference is in the
   class-guard inputs or in the dataflow's use of them, and has not been located.
5. **Coverage.** bc2cpp's code is Hash, Set, Struct, block and keyword-argument heavy. How much of it bc2cpp can compile is
   unmeasured; unsupported methods stay interpreted, so the executable still works, but the speedup is unknown.

## Already fixed on the way

`mruby-process` (fork/exec, `Open3`, `Kernel#system`, `IO#reopen`), `mruby-env`, the Marshal fixes, the onig `$\`` and `$'` sharing
(`ClosedWorld.new` went from over 12 GB to 395 MB), `Prism.lex`, and a set of CRuby-compatible core shims in `mruby-require`.
