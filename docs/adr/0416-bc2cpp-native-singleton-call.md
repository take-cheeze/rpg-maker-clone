# 0416. bc2cpp calls native singleton functions of a stable constant through a per-site method cache

Date: 2026-10-12

## Status

Accepted

## Context

After ADR 0259 and 0281, the `origin=constant_lookup` sites of the wio coverage run (`Const.name(args)` whose
receiver register holds a class or module constant) were still by-name `bc2cpp_send` calls when the target is a C
function of mruby core or of a gem: `File.exist?`, `File.file?`, `File.basename`, `Math.sin`, `Time.now`,
`Graphics.snap_to_bitmap`, `LCF.cp932_to_utf8`, `RGSS.to_nfd`, `RGSS.__log_bridge_write`. ADR 0281 binds only the
RGSS natives that have a frame-independent entry point (ADR 0263). The others cannot be called bare: they read their
arguments with `mrb_get_args` from the callinfo `mrb_funcall` pushes (native_names.rb, ADR 0253).

Classification of the 40 sites measured on the older snapshot (Tts excluded; those sites go away with the Tts
disable):

- native C singleton functions on a top-level or scoped stable constant: this ADR;
- `File.open` / `IO.open` (about 8 sites): `IO.open(*args, &block)` is mruby-io mrblib, hidden from the registry and
  left interpreted ("unhandled opcode EXCEPT"; rest plus block parameters are not a compiled entry shape, ADR 0264,
  0271), and `File.open` then runs `File#initialize`, which is interpreted too (SUPER). Not bindable here;
- Ruby-defined singletons that already pass the ADR 0259 proof but are not emitted: `Game::CommonEvent.load` and
  `Game::MoveRoute.same_route?` are `owner_not_emitted` (their `.singleton` owners are not in the curated owner list
  of mruby-rpg2k-compiled, whose registration is hand written), `Game::MoveRoute.from_page` is
  `candidate_not_compiled_clean` (rescue plus keyword `new`);
- constants holding a value (`each`, `times`, `strip`, ...): genuinely dynamic.

## Decision

`Const.name(args)` (SEND/SEND0, no block, no splat or keyword) becomes
`bc2cpp_native_singleton_named(M, recv, "name", n, args...)`, rewritten by SymbolCache to
`bc2cpp_native_singleton(M, recv, i, BC2CPP_NSC_SLOT, n, args...)`. The helper keeps one slot per site (a lambda
static) holding the method found for the receiver, valid for one VM (epoch bumped by the symbol-cache reset, and
state) and one receiver object, and calls it with `mrb_funcall_with_method` (the fork's `funcall_with_block_m` with the
lookup done, ADR 0365). The function therefore runs in the frame mrb_funcall would push: argument-count errors,
backtrace and blocks are the interpreter's. What goes away is the by-name site and the two lookups of a checked send.

The first call fills the slot (`bc2cpp_nsc_fill`) and refuses to cache anything the proof assumed but the VM does not
show: a method that is not a C function, a private or protected one, a NOARG function given arguments. For a raw C
function the fill also applies the check OP_SEND makes against the aspec the function was registered with
(`check_argument_count`); a by-name funcall does not, so master's `Time.now(1)` returned a Time where the interpreter
raises ArgumentError. Those cases take the ordinary checked send (`bc2cpp_check_send` then `bc2cpp_funcall_argv`).

Compile-time proof (`tools/bc2cpp/codegen_native_singleton.rb`, `native_singletons.rb`); all must hold:

1. The receiver is a stable constant: either `constant_object_owner` (ADR 0259), or a bare top-level native class
   (`File`, `Math`, `Time`, `IO`) that is a StableClassConstants name and that no bytecode or outside-Ruby `class` or
   `module` statement nests in a scope the site can see: a lexical prefix of its owner, or any class or module on the
   owner's ancestor chain (`unlisted_lookup_chain`).
2. At least one native registration (`mrb_define_class_method[_id]`, `mrb_define_module_function[_id]`) puts the name on
   `<Const>.singleton`, and every spelling of the name in every scanned native source (the closed world's native
   paths and NATIVE_SRCS) is a registration the parser understands. An alias, a ROM-table entry or a call by name
   refuses. Two C registrations (the wio build scans mruby-math and mruby-math-wio) are accepted: the slot resolves
   the one the VM ends up with.
3. `ClosedWorld#native_singleton_name_refusal`: no global refusal (extend, define_singleton_method, method_missing
   hook, ...), no dynamic visibility, no unplaceable DEF of the name, no `private`/`public`/`module_function` naming it,
   no outside-Ruby definition (closed world sources and FOREIGN_RUBY_SRCS, the latter checked in
   `native_singleton_target`). This is the only guard for a global refusal: the top-level constant proof does not repeat it,
   because `native_singleton_target` asks this first. A Ruby definition of the name on another owner (another class's
   instance method, Kernel, Class) is not a refusal: the native function sits on the constant's own singleton class, which
   is searched first. A registry definition on that singleton class is.
4. `symbol_installed_names` is known and lacks the name (alias, undef, define_method), and the singleton class has no
   include or prepend.

`BC2CPP_NATIVE_SINGLETON=0` turns the route off (output equals master's); `BC2CPP_NSC_DEBUG=1` prints the refusal of
every candidate site.

## Consequences

`scripts/bc2cpp/native_singleton_check.rb` generates 18 worlds (a base world plus 17 that each add one way for the lookup
to change) and runs compiled against interpreted on real mruby, including a `private`, a redefinition and a prepend
executed after compilation. `native_singleton_mutation_check.rb` breaks each condition above (17 mutants plus a control);
all are killed, and none was dropped to make the run pass: the three that first survived got their own world
(`a build gem Ruby definer`, `a def nested in a method`, `a global refusal and a scoped native constant`) or had the
redundant guard deleted. The nightly shard is `native-singleton`.

Measured on the wio closed world's shipped pass (SKIP_UNSUPPORTED=1, the second pass of
`scripts/bc2cpp/coverage_report.rb`; all owners, the same tree at master 7714f4d0, once with
`BC2CPP_NATIVE_SINGLETON=0` and once without; the two runs' diagnostics are identical, so only the route differs):

| | live `bc2cpp_send(M` | `bc2cpp_native_singleton(M` | live `mrb_funcall*` text | `origin=constant_lookup` |
|---|---|---|---|---|
| `BC2CPP_NATIVE_SINGLETON=0` | 1818 | 0 | 392 | 37 |
| on | 1796 | 22 | 394 | 15 |

22 sites bound, each replacing exactly one send (1818 - 1796): 5 `File.exist?`, 3 `File.file?`, 1 `File.basename`, 4 `Math.sin`,
3 `Graphics.snap_to_bitmap`, 2 `Time.now`, 2 `LCF.cp932_to_utf8`, 1 `RGSS.to_nfd`, 1 `RGSS.__log_bridge_write`. The two
extra `mrb_funcall*` are the helper's own text (it calls `mrb_funcall_with_method`). The earlier figure of 13 bound sites,
taken before the last two proof relaxations from a partial run, is superseded by this table.

Not done: Ruby-defined core singletons (`File.open` / `IO.open`: ADR 0426 lists exactly what is missing, with an estimate),
scoped natives unknown to ConstructClassNames, and a rooted `::File`. (`Game::CommonEvent.singleton` and
`Game::MoveRoute.singleton` are emitted, and a keyword `new` in a class method compiles, by ADR 0426.) A cached slot is not
revalidated against a later redefinition; the closed-world proof (no installer anywhere) is what rules that out, as for the
other direct arms.
