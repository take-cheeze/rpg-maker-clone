# 0365. The index helpers' by-name arm is closed by exposing mruby's `[]` / `[]=` bodies

Date: 2026-10-06

## Status

Accepted. Supersedes ADR 0363 (its third alternative, "export the static bodies from the patched mruby").

## Context

ADR 0363 recorded why `bc2cpp_getidx`, `bc2cpp_getidx0` and `bc2cpp_setidx` (`[]` / `[]=`, ADR 0216) kept a by-name tail:

1. `CallFacts::Answers#members` read instance registrations only, so a Class-object receiver (`Array[...]`, `Hash[...]`, a
   `Struct.new` class's `.[]`) was not a member and a proven NoMethodError would have been wrong.
2. `Proc#[]` is a VM-level method (`call_proc`, OP_CALL).
3. The native bodies are `static` in mruby and read the CALLING frame (`mrb_get_args`), which a shared helper does not have.

The project already patches mruby, so the bodies can be exported instead of mirrored.

## Decision

### The patch

`patches/mruby-expose-index-bodies.patch` (one new file; no existing patch is edited) splits each native body in two: a
non-static `<name>_impl` that takes its arguments as parameters and holds the whole body, and the original method, which
reads its arguments as before and calls the impl. Interpreted behaviour is unchanged (the `i` of `mrb_get_args` is
`mrb_as_int`, which `aget_index1` spells for the one-argument forms; every other statement moved verbatim).

| Function | Body |
| --- | --- |
| `mrb_ary_aget1_impl`, `mrb_ary_aset2_impl`, `mrb_ary_s_create_impl` | `Array#[]` (one argument), `Array#[]=` (index, value), `Array.[]` |
| `mrb_struct_aref_impl`, `mrb_struct_aset_impl` | `Struct#[]`, `Struct#[]=` |
| `mrb_hash_s_create_impl`, `mrb_set_s_create_impl` | `Hash.[]` (mruby-hash-ext), `Set.[]` |
| `mrb_str_aset` | `String#[]=` (it reads no frame; it was only `static`) |
| `mrb_proc_aref_impl` + `mrb_funcall_with_method` | `Proc#[]`: `mrb_funcall_with_block` with the method (`call_proc`) already found; `vm.c`'s `funcall_with_block_m` takes an optional fixed method and owner, `mrb_funcall_with_block` passes none |

`Hash#[]`, `Hash#[]=`, `String#[]` and a Struct class's `.[]` need nothing: `mrb_hash_get`, `mrb_hash_set`, `mrb_str_aref` and
`mrb_obj_new` (`mrb_instance_new` without a block) are public and read no frame. Every declaration sits in `MRB_BEGIN_DECL`
so the symbols keep C linkage when a build compiles the core as C++. Table (rgss) is in this repository:
`mruby-rgss/src/lib.cxx` gains `rgss_table_p`, `rgss_table_aref_impl` and `rgss_table_aset_impl` (the bodies of `table_get` /
`table_set` with their arguments passed in).

Generated C++ declares the exported functions itself (`extern "C"`; a gem's are `__attribute__((weak))` and tested before use,
so a libmruby without the gem still links).

How every target applies it: the cmake patch chain (`cmake/build-mruby.cmake`, after `mruby-no-irep-debug.patch`) is what
native, Emscripten, PSP, Wio, Android and the CI jobs build through; `scripts/maix_mruby_build.bash` and
`scripts/wio_bc2cpp_measure.bash` keep their own copies of the list and gain it. The nix flake and PlatformIO build no mruby of
their own (PlatformIO links a libmruby cmake produced).

### The generator

* `CallFacts::Answers` scans class-level registrations (`mrb_define_class_method*`, `mrb_define_singleton_method*`,
  `mrb_define_module_function*`) as `definers[:class_native]`; a class or module object is then a member of any name that has
  one (`members('[]')` includes `<ClassObject>`). That also corrects the instance-only view for other consumers.
* `INDEX_CLOSED` (`tools/bc2cpp/codegen_index_closed.rb`): the helper's chain keeps its inline fast paths and the
  program's own `[]` / `[]=` candidates (and the subclasses that inherit one, resolved by full class name from the plan), and
  its else arm becomes a tag switch over Array, Hash, String, Struct, Table and Proc (`[]=` has no Proc arm), a class-object arm
  (`Array.[]`, `Hash.[]`, a `Struct.new` class's `.[]` tested by the `__members__` it carries) and `bc2cpp_nomethod_named`. The
  form applies only when `Answers` bounds the name with no foreign, module or singleton definer, the world is singleton-free
  and has no `method_missing` class, every member class resolves to a chain arm or a native arm, and the sources the build
  compiles still have the registration, the wrapper that calls the exported body and (Hash, String) the method body the arm
  stands for. Members from gems the build does not link (Method, OnigMatchData, Set in wio) drop out as Time did in ADR 0364;
  a build that does link one keeps the by-name helper. `BC2CPP_INDEX_HELPER_CLOSED=0` keeps it too, byte for byte.
* The helpers are built by `prepare_index_helpers`, after the bodies compile: a core body compiles with the closed world
  withdrawn, so the first use cannot decide.

## Consequences

Measured values are in the "Results" section below. `scripts/bc2cpp_index_closed_check.rb` runs each closed helper against the
real method over a receiver / key matrix (every member class, subclasses, frozen receivers, class objects, procs, non-members;
valid, invalid, negative, range, wrong-typed and bignum keys), comparing value, error class and message and the receiver
afterwards, compiled and interpreted, at `mrb_int` 64, 32 and without bigint, with negative worlds, a source audit with
mutants of the trusted sources and the kill switch. Table runs against a stand-in with the same entry points (rgss is not in
libmruby).

Pinned digests: `NativeClassResults::FILES` accepts the patched `array.c`, `string.c`, `struct.c` and `lib.cxx` next to the
upstream ones; `NativeIvarScopes::FILES` moves to the new `lib.cxx`.

## Results

Measured with `scripts/bc2cpp_dynamic_site_census.rb` on the wio closed world (shipped pass, base `b4efe59e`, the head of
ADR 0364's branch). All three helpers close in the real world: every member of `[]` / `[]=` (the eight and six program
classes, `LCF::Database` / `MapTree` / `MapUnit` / `SaveData` below `LCF::File`, the reopened core classes, `File` and its
chain, Array, Hash, String, Struct and the Struct.new classes, Proc, Table, class objects) resolves to a chain arm or a native arm.

| | Before | After |
| --- | ---: | ---: |
| by-name calls held in helpers | 19 | 16 |
| `bc2cpp_send` in the helper region | 17 | 14 |
| generated callers of `bc2cpp_getidx` / `getidx0` / `setidx` that still reach a by-name call | 2,017 / 32 / 348 | 0 / 0 / 0 |
| `bc2cpp_send` in generated bodies, closed-world nomethod sites | 2,286, 4,460 | 2,286, 4,460 |

2,397 generated callers stop reaching by-name dispatch. `Proc#[]` is closed too (`mrb_proc_aref_impl`): the by-name call it
replaced and this one run the same `call_proc` frame.

Not closed, and why: a build that links mruby-method (`Method#[]` is `method_call`, which looks its target up by name inside
mruby), mruby-onig-regexp (`MatchData#[]` forwards to Array by name; it lives in a separate checkout this patch cannot reach)
keeps the by-name helper; the closed worlds (psp, wio, maix) link neither. mruby-set's `Set.[]` has an arm but no closed
world links it. A name with exactly one program definer has no chain to put the arms behind (the chain needs two
candidates), and more than 16 subclasses of one definer overflow the chain; both keep the by-name helper.

The check's Table run uses a stand-in with rgss's three entry points because libmruby does not link rgss. The real bodies are
the old `table_get` / `table_set` text moved behind the same wrappers (`mruby-rgss/test` exercises them interpreted);
`scripts/native_binding_split_check.rb` needs libclang and was not run here.

A cfunc-backed Proc (every compiled block, ADR 0266) cannot run `call_proc`'s OP_CALL from a compiled frame, so the Proc arm yields to it (`bc2cpp_yield_argv`) exactly as `bc2cpp_funcall_argv` does for the by-name call it replaces, and only a bytecode Proc takes `mrb_proc_aref_impl`. `scripts/bc2cpp_index_closed_check.rb` runs `IxCap`, compiled methods that capture a block and index it (`blk[x]`, a stored proc, `b[1]` next to `call`/`.()`/`yield`, a returned proc, lambdas, a break, upvars, nesting), interpreted and compiled; `scripts/bc2cpp_proc_call_block_given_check.rb` passes.
