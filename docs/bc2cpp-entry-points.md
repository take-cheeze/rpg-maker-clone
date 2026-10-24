# bc2cpp: calling compiled methods from a host's `main`

A host drives the game through a few Ruby methods every frame. The trace host
(`scripts/bc2cpp/trace_host.cxx`), the PSP host (`app/psp/main.cxx`) and the
Maix host (`app/wio/src/maix_game_main.cxx`) call `RPG2k#main_loop` and
`RPG2k#current_scene_name`. Called with `mrb_funcall`, each call looks the
method up, pushes a call frame and runs the registered wrapper, which then
calls the compiled body.

`BC2CPP_ENTRY` lets a host call the compiled body (`<Owner>_<name>_impl`)
directly, when bc2cpp has proved that is what the dispatch would run.

## Using it

Include `include/bc2cpp_entry.hxx` and call the entry functions where you would
call `mrb_funcall`:

```c++
#include "bc2cpp_entry.hxx"

bc2cpp_entry_RPG2k_main_loop(M, game);           // mrb_funcall(M, game, "main_loop", 0)
mrb_value name = bc2cpp_entry_RPG2k_current_scene_name(M, game);
if (M->exc) { /* the same error handling as after mrb_funcall */ }
```

Each function has `mrb_funcall`'s contract. With no protected region active,
a raise leaves the exception in `M->exc` and returns the exception object.
Inside a region (`mrb_protect_error`, or compiled code that set `M->jmp`), the
raise propagates to that region.

`BC2CPP_ENTRY_<Owner>_<name>` is `1` when the function calls the compiled body
and `0` when it calls by name. The trace host prints which one it got
(`TRACE_HOST entry main_loop=direct ...`).

## Where the direct form comes from

In a closed-world build (`RPGMAKER_BC2CPP=1`: PSP, Wio, Maix and
`scripts/bc2cpp/trace_host.bash`), each compiled gem's bc2cpp run writes
`<OUT_SYMBOL>_entry.h`, for example `rpg2k_compiled_entry.h`. It goes next to
its `_decls.h` and into the build's include directory
(`BC2CPP_ENTRY_INCLUDE_DIR`, which `tools/bc2cpp/compiled_gems.rb` sets).
That include directory already holds `mrbconf.h` and the presym headers. Every
host of that libmruby has it on its include path, so `bc2cpp_entry.hxx` finds
the generated header with `__has_include` and no build changes are needed.

The desktop, wasm and Android builds (`src/main.cxx`) run plain mruby with no
compiled gems. There the header is absent, and the fallbacks in
`bc2cpp_entry.hxx` call by name. Define `BC2CPP_ENTRY_BY_NAME` to force the
by-name forms in any build.

## When an entry is direct

The entry list is `ENTRY_POINTS` in `tools/bc2cpp/codegen_entry_header.rb`:
`RPG2k#main_loop`, `RPG2k#start` and `RPG2k#current_scene_name`, each with
its argument count. `BC2CPP_ENTRY_POINTS="Owner#name/argc ..."` replaces it.
The generator emits the direct form only when:

- **The compiled entry is a plain forwarder.** Its registered wrapper is
  `return <impl>(M, self, args...)`, so it has no Fiber hand-off, no core
  block guard, no resumable step function, and no optional, rest, keyword or
  block parameter. The body must also be compiled clean.
- **It is public**, with the declared argument count.
- **Nothing can put another body in front of it.** The name is not installed,
  aliased or undefined at run time; the owner has no prepended or unknown
  mixin; and the owner has exactly one definition of the name.

At run time the direct form also checks that the receiver's class is exactly
the owner (`mrb_class(M, self)`, so a singleton class counts too). It looks the
owner up by constant path on every call; it doesn't cache it, because a VM
reopened at the same address would make a cached pointer stale. A subclass
receiver, or one with a singleton method, takes `mrb_funcall`.

The direct call pushes no call frame, so the entry method itself has no frame
in an exception's backtrace. Calls from it, and the exception itself, are
unaffected.

## Adding an entry point

Add `Owner#name/argc` to `ENTRY_POINTS`, and add the by-name fallback to
`include/bc2cpp_entry.hxx`. `scripts/bc2cpp/entry_header_check.rb` fails when
a listed entry has no fallback. The check also generates a fixture header and
runs it. It asserts:

- the direct and by-name choices;
- that a direct call makes no dynamic dispatch;
- the exception contract, inside and outside a protected region;
- that a subclass or singleton receiver falls back.
