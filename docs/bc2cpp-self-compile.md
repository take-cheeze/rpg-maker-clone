# bc2cpp as a self-compiled mruby executable

Status: investigation. `host-libs/mruby-bc2cpp-runner` runs bc2cpp under mruby (an interpreted `bin/mruby` that loads the baked
sources). This note lists what stands between that and an executable that bc2cpp itself compiled.

## What exists

- `mruby-bc2cpp-sources` bakes the files reachable from `tools/bc2cpp/bc2cpp.rb` (309) into bytecode: `bake_sources.rb --dir`
  writes each under the build directory, `mrbc -g` compiles each to a C array, and `MRubyRequire.load_baked(name)` runs one
  with `mrb_top_run` on Object. `mruby-require` no longer depends on `mruby-eval`, and the runner binary has no `eval`.
- `mruby-bc2cpp-runner` names the entry (`BC2CPPRunner.run`); `bc2cpp_main.rb` is the script `bin/mruby` runs.
- The closed build and the optcarrot probe can generate code through the executable (`BC2CPP_MRUBY_RUNNER`).

## Why bc2cpp refuses it today

`bc2cpp_closed_world_violations` (tools/bc2cpp/compiled_gems.rb) accepts the build names `closed`, `optcarrot-probe` and `wio`, and
rejects any gem list with a gem in `BC2CPP_OPEN_WORLD_GEMS`: `mruby-eval`, `mruby-binding`, `mruby-proc-binding` and the bin gems
`mruby-bin-mruby`, `mruby-bin-mirb`, `mruby-bin-debugger`, among others. The runner build has all of those:

| Gem | Why the runner has it | Needed for a compiled executable? |
| --- | --- | --- |
| `mruby-eval`, `mruby-binding` | `mruby-require` evaluated baked sources with `eval`; now done (precompiled), the runner build has neither | No |
| `mruby-bin-mruby` | `bin/mruby` runs the entry script | No: done, a C `main` (host-libs/mruby-bc2cpp-runner/tools/mruby/main.c) boots the state and calls the entry; the runner build no longer has mruby-bin-mruby |
| `mruby-bin-mrbc`, `mruby-compiler` | the build compiles its own mrblib | Build time only, not linked |

bc2cpp's own sources never call `eval`: the only `eval` in the build is the baked-source loader.

## Steps

1. **Precompile the baked sources.** Done: see above. (A first attempt ran the bytecode with `mrb_load_irep` from a C function of
   `MRubyRequire`; the source's constants and methods then landed on that module's singleton class. The proc's target class
   is set to Object instead.)
2. **A C `main`.** Done: `tools/mruby/main.c` in the runner gem sets `ARGV`, boots the state and calls `BC2CPPRunner.run` (or
   `run_tool` for `mruby_tool.rb`), prints an uncaught exception with `mrb_print_error` and exits non-zero. It is installed as
   `bin/mruby` and skips a first argument `bc2cpp_main.rb` or `mruby_tool.rb`, so the callers are unchanged.
3. **A build kind.** Done: `bc2cpp-self` is in `BC2CPP_CLOSED_WORLD_BUILDS` (tools/bc2cpp/compiled_gems.rb), with its gem list in
   `BC2CPP_SELF_GEMS`. `bc2cpp_closed_world_violations` requires every gem of the list, refuses the open-world gems
   (`mruby-eval`, `mruby-binding`, `mruby-proc-binding`), `mruby-compiler` and every `mruby-bin-*`, and leaves the other kinds
   as they were. `scripts/bc2cpp/self_build_kind_check.rb` (in CI) checks all of that, and that the list equals the runner's
   build_config.rb minus its build-time gems (`mruby-bin-mruby`, `mruby-bin-mrbc`, `mruby-compiler`) plus `mruby-env`, which
   `mruby-bc2cpp-sources` depends on. The C main of step 2 is part of the runner gem (`mruby-bc2cpp-runner`), so it needs no entry of its own.
   Not done: nothing builds this kind yet, so `bc2cpp_closed_world_outside_srcs` and the rest of the closed-world bookkeeping
   are untouched.

   The closed-world inputs are the sources outside bc2cpp's own program that share the executable's VM: the C and C++ sources
   of mruby core (`3rd/mruby/src`) and of each gem (`src` and `core` of the gems in the list, including Onigmo bundled by
   `mruby-onig-regexp`, `3rd/mruby-marshal`, `3rd/mruby-stringio`, `3rd/nfcxx/bc2cpp/host-libs/mruby-prism` with Prism's C, `3rd/nfcxx/bc2cpp/host-libs/mruby-process`
   and `3rd/nfcxx/bc2cpp/host-libs/mruby-env`), and the Ruby `mrblib` of the core and ruby-libs gems (`3rd/nfcxx/bc2cpp/ruby-libs`) (shellwords, json, digest, fileutils,
   tmpdir, tempfile, dir-glob, strscan, compare-by-identity, yaml, zlib, and the generated rbs and prism mrblibs). The program
   itself is `tools/bc2cpp/**` and `scripts/rpg2k/closed_world_lint.rb`, baked as bytecode.

4. **Analysis parity (a prerequisite).** The runner must reach the same analysis results as CRuby. It does not yet: on the RPG2000
   closed unit, CRuby's RBS_CHECKED_PARAMS check passes, while the runner reports 94 unproven parameters. The narrowing state at one
   instruction differs (1 fact instead of 6). Decoding, control-flow edges and `Set` operations match; the difference is in the
   class-guard inputs or in the dataflow's use of them, and has not been located.
5. **Coverage.** Measured once, with bc2cpp under CRuby over the 309 baked sources as the `bc2cpp-self` world (92 native and 31
   Ruby sources outside it; the generated prism and rbs mrblibs included), about 154 s and 1.7 GB: 3,995 methods compile to
   entry points and 846 stay interpreted (about 83% of the 4,841 attempted), in 26 MB of C++ over 4 shards (not yet compiled or
   linked). The skipped methods, by reason:
   - 383 sends with a splat or keyword-argument list, and 3 methods with optional, rest or keyword parameters of their own;
   - 296 methods with a `BLOCK` opcode (a block that is not an inlined iterator);
   - 88 `ARGARY`, 38 `LAMBDA`, 13 `EXCEPT` (rescue), 4 `BLKPUSH`, 2 `APOST`; 14 unlabelled.

   The run needed these changes to bc2cpp's own code (all made): the predicate-returns gate off; `Irep`'s accessors spelled out;
   `AncestorElementHint` a class; `StrictKeySet` defined once; `Psych` looked up by name; probe nesting capped (`BC2CPP_PROBE_DEPTH`);
   and, for the kind only, the constants the gems' Ruby binds counted as known. The entry's main block also has about 250
   top-level locals, more than one mruby irep holds when all files are compiled as one program: the scan ran it as a lambda in
   a copy. That one is not made in the tree.

## Already fixed on the way

`mruby-process` (fork/exec, `Open3`, `Kernel#system`, `IO#reopen`), `mruby-env`, the Marshal fixes, the onig `$\`` and `$'` sharing
(`ClosedWorld.new` went from over 12 GB to 395 MB), `Prism.lex`, and a set of CRuby-compatible core shims in `mruby-require`.
