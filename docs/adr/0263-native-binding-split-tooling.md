# 0263. Mechanical split of RGSS native bindings into direct entry points

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0253 gave the RGSS natives `rgss::<owner>_<name>_direct` entry points so
bc2cpp can call them without a frame, but only about 40 of the 177
`mrb_define_method` bindings in `mruby-rgss/src/lib.cxx` had one. The rest
unpack `mrb_get_args`, which reads the calling frame, and every entry point and
its row in `tools/bc2cpp/native_direct.rb` was written by hand, so a binding, its
entry point and the compiler's table could drift apart silently.

## Decision

Tooling, in two halves.

- `scripts/native_binding_facts.py` (libclang's Python bindings) parses each
  `mruby-rgss/src/*.cxx` once per configuration (host, wio, psp, maix,
  emscripten) and reports, for every `mrb_define_method` /
  `mrb_define_class_method` / `mrb_define_module_function` registration, the
  bound function or lambda, its parameters and top-level statements, its
  `mrb_get_args` call and every reason its body can read the frame, followed
  transitively through everything it calls that the translation unit defines.
  Frame readers (`mrb_get_args`/`argc`/`argv`/`arg1`, `block_given_p`,
  `get_mid`, `mrb_yield*`, `cfunc_env`, `super`), fields of `mrb_context` /
  `mrb_callinfo`, indirect calls and any `mrb_state`-taking function not on a
  reviewed allowlist refuse the binding. The gem is built by mruby's rake, so
  CMake's `CMAKE_EXPORT_COMPILE_COMMANDS` does not describe it; the script
  derives the flags from the gem's include paths (`--emit-compile-commands`
  writes them as a `compile_commands.json`).
- `scripts/native_binding_split.rb` (plain Ruby over that JSON and the source
  text) classifies, reports, rewrites and generates. `report` lists every
  registration with class, name, format, typed parameters and either
  `splittable` or the refusal reasons. `write` applies the split; `check` fails
  when `write` would change anything. Fail closed: a binding is split only if
  every check passes in every configuration.

The split. `mrb_value f(M, self) { T a; mrb_get_args(M, "..", &a); BODY }`
becomes `f_native_body(M, self, a) { BODY }` plus `f`, which keeps the
declarations and the `mrb_get_args` call and forwards. The body text moves, it
is never copied, so the binding and the direct path run one body. A lambda
binding is lifted to a static function ahead of its registering function. A
binding that reads no arguments and no frame needs no change. Each gets
`rgss::<name>_direct`, a forwarder in a generated block at the end of
`lib.cxx`, declared in the generated `include/rgss_native_direct.hxx` (included
by `rgss_construct.hxx`). The block wraps each forwarder in the `#if` that
guards its callee and gives the other configurations a raising stub, as ADR 0253
did by hand for wio. Refused, not split: `|`, `&`, `*`, `:`, `?`, `d`, `!`
formats, `mrb_get_argc`, any statement before `mrb_get_args` (a raise there
would reorder errors), `goto`, an `#if` inside the body, function template
specializations, and a header that does not parse.

Guarantees `write` checks after the rewrite: each moved body refers to the same
declarations as before (a digest of every referenced USR, since the body now
resolves names from another scope); each configuration defines every entry
point, really or as a stub, exactly where the guard predicts the callee is
compiled; each forwarder calls the intended function.

The compiler's table is generated: `tools/bc2cpp/native_direct_table.rb` holds
name -> class -> `[entry point, argument kinds]` from the same classification,
and `native_direct.rb` loads it, keeping the entries whose kinds the codegen
passes (`:int`, `:bool`, `:value`). All 35 hand-written entries are reproduced
unchanged. Owners come from `NativeDirect.class_variables`; bindings whose
class it cannot resolve (audio, tts, profiler) are reported but not rewritten,
since nothing could call their entry points and they would only cost flash on
wio.

Tests: `scripts/native_binding_split_check.rb` (no compiler; a fixture with
checked-in facts, a golden rewrite, and text invariants of the tree, in the
`ruby-checks` job and `scripts/coverage_report.rb`);
`mruby-rgss/test/native_direct.rb` runs the split bindings and their entry
points side by side in mrbtest through a generated probe table.
`scripts/native_binding_split.rb check` is the full freshness check and needs
libclang: the `clang` flake dev shell adds it.

## Consequences

Direct entry points and table rows come from one place and cannot drift; adding
a frame-independent binding shows up as `splittable` until `write` is run.
Each split binding pays one extra call (wrapper to body) and one forwarder per
entry point, which the linker drops when unreferenced. Sizes on wio were not
measured (no arm toolchain here). The clang-based check is not part of
`ruby-checks` (no submodules there); the compiler-free check is.
