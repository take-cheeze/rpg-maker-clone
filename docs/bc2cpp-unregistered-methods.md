# Unregistered compiled methods

A compiled method needs a method-table entry only if something can look it up
by name at runtime. When every caller reaches it through a direct `_impl` call
in generated C++, bc2cpp leaves it out of the table: no `mrb_define_method`
call, and no `mrb_get_args` wrapper kept alive for it. The gem's mrblib has
already defined the method as bytecode (or as an `attr_*` accessor) by then,
so the generated registration removes that definition too, and the build ships
its body empty ([Stubbed mrblib bodies](bc2cpp-mrblib-stubs.md)).

## What decides it

`tools/bc2cpp/static_dispatch_registrations.rb` proves each name. The proof is
name-level and its default answer is "dynamic". A name stays registered when
any of these could look it up:

- a send in bytecode that can run (a fixpoint, with the mrblib load phase
  modelled separately). A block of a registered compiled method runs as
  bytecode only during the load phase, together with its method, because the
  generated C++ makes only C procs. If any generated C++ builds a bytecode
  proc (`mrb_proc_new`, `mrb_closure_new`), every such block counts as
  runnable again;
- a C string literal in the generated C++, outside the name's own
  registration. Three kinds of use don't count, because none looks up a
  compiled method:
  - the by-name fallback of a `MONO_EMBED_GUARD` on an owner nothing
    subclasses;
  - the proof-failure helpers (`bc2cpp_nomethod`, `bc2cpp_nomethod_raise`,
    `bc2cpp_guard_violation`, `bc2cpp_hint_violation`,
    `bc2cpp_nil_receiver`). The nomethod helpers only dispatch on a receiver
    proven not to answer the name. The violation helpers raise without
    dispatching. The nil helper dispatches on `nil`;
  - an owner call (`bc2cpp_owner_call`) that covers every engine owner it
    lists (`OWNER_CALL_GUARDED`). The call runs only a method found on a
    listed owner and raises a closed-world violation for any other, so it
    needs no registration but its listed owners'. A listed owner is covered
    when the call is the final else of an exact-class guard chain
    (`bc2cpp_class_is`) that tests it and nothing subclasses it, or when the
    call carries its compiled entry (`OWNER_CALL_DIRECT`,
    `tools/bc2cpp/owner_call_direct.rb`). With direct entries the call walks
    the receiver's ancestors in lookup order and answers with the entry where
    the lookup would have found it, so it behaves the same whether the entry
    is registered or not. The emitter adds entries only to a call they
    complete, because each entry costs a row of read-only data.

  "Nothing subclasses" is a scan for written superclasses (`< Foo`,
  `Class.new(Foo)`, a native define call's superclass argument). Full-line
  Ruby comments don't count. A native file adds all its capitalized string
  literals only when one of its define calls passes a superclass that isn't a
  builtin (`M->object_class`, `E_STANDARD_ERROR`, ...). For the closed list the
  scan reads only the closed binary's sources: the check scripts'
  `Class.new(klass)` fixtures made every class count as subclassed;
- `super`;
- a string-pool literal or a `"#{x}_suffix"`-style fragment. For the closed
  list, a literal counts as a fragment only when a load of it may reach a
  built string. Each load is followed forward, through MOVE copies, closed
  methods' parameters and return values, and array or hash literals and the
  constants holding them. It stops being a fragment when every use only
  compares it (`==`, `when`, `start_with?`), looks it up as a native hash
  key, tests a constant list for it (`LIST.include?(x)`), or puts it into a
  string that also gets a character no name has (a space, a colon). A
  concatenation is followed too: the built string's own uses decide, so a
  string only printed or compared isn't one. Any other use keeps it a
  fragment: a store, an interned Symbol (`:"#{type}_name"`), an argument of
  a method the trace doesn't know, or a use the flow query refuses. Engine
  code that needs per-kind field names spells them in a table
  (`Game::Vehicle::SYSTEM_NAME_FIELD`) rather than building them. The closed
  list asks the same of an identifier-shaped literal itself (IDENT_USES),
  once SYMBOL_USES has proven every lookup in the closed bytecode takes a
  literal name: otherwise a compared literal could be what a computed
  `send(x)` looks up;
- a token in core, external or other-maker mrblib, tests, `scripts/`,
  `.github/`, `tools/` or native sources;
- for the closed list only, a narrower outside scan:
  - the other makers' gems (mruby-rpgxp, mruby-rpgvx, mruby-wolf,
    mruby-mvjs) are skipped, since the single-format closed build doesn't
    load them;
  - a native file contributes only its string literals, its presym operands
    (`MRB_SYM_Q(name)` and the like), and the arguments of macros that turn
    an argument into a name (`#param`, or passing it on to such a macro).
    A C local or field spelled like a method name looks nothing up, and
    neither does the name argument of a registration call
    (`mrb_define_method(M, c, "name", ...)` and the other defining calls): it
    defines the name. An alias's two names still count. Comments are left
    out: `/* "count" is "width" */` names nothing. A file the comment scan
    can't read (an unterminated quote, a raw string) is scanned whole;
  - only sources the closed binary contains are read. A core `mruby-*` gem
    outside the closed build's gem closure (mruby-socket, mruby-enum-lazy,
    mruby-complex, ...), an external gem it leaves out (mruby-onig-regexp),
    an engine mrblib file its rake swaps out (`scene/map_tts.rb`) and the
    device apps under `app/` are skipped. HAL gems stay: a rake adds them in
    its own Ruby, which the closure doesn't follow. The closed host,
    `scripts/bc2cpp/trace_host.cxx`, is read instead of `app/`;
  - the workflows under `.github/` are skipped: their inline Ruby runs in
    the desktop binary, and the closed library is linked only into
    `trace_host.cxx`, which runs no script;
  - core and external-gem Ruby under `3rd/` is read as bytecode, not text,
    and so is the mrblib of the core gems compiled as program (array-ext,
    enum-ext, struct, enumerator, ...), which no scan read before. A send
    there counts only if its receiver may be an engine object. That rules
    out a literal, a core constant, and self in a method of a core class
    outside the engine classes' superclass chain. Self in a module, Object,
    Kernel, Class or Module method, and any unknown value, still count.
    Symbols, identifier-shaped strings and implicit operators always count.
    A file with a reflective send (`__send__`, `instance_exec`,
    `define_method`, ...) or a `method_missing` loses the receiver rule: every
    symbol of its bytecode counts. Its comments and local variable names
    don't, since they never become a symbol, and a name it sends that comes
    from its caller is counted where the caller spells it;
  - a setter, predicate or bang name (`x=`, `x?`, `x!`) stays registered
    because of its base name `x` only when `x` was read as text: a text
    scan reads `obj.x = 1` as `x`, and a naming macro may append the suffix
    itself. A name from bytecode or a C string literal is the exact name
    looked up, so `done` being dynamic no longer keeps `done?`. If a
    one-character literal `"="`, `"?"` or `"!"` may reach a built string
    (the fragment rule above), `"#{x}="` could build the suffixed name from
    any base, and the old rule (every dynamic base) comes back. The full
    list keeps the old rule;

The proof also takes the `attr_*` accessors of every owner a compiled gem
lists, when no compiled entry has the same key. An accessor is a native
`mrb_iv_get`/`mrb_iv_set` on its ivar. Compiled callers read the ivar
directly, so a name nothing looks up needs no table entry either. The gem
that lists the owner removes a listed accessor the same way as a compiled
entry (`left_out_accessors`).

Only RPG2000/2003 internal owners qualify (`Game`, `RPG2k`, `RPG2k3`,
`LCF`). RGSS classes are the scripting API an RPGXP/VX game's own scripts
call, so the open list leaves them registered. The closed list also takes
RGSS owners and the engine modules' own singletons (`Game.singleton`): the
closed build is RPG2000/2003 only, and those games carry no Ruby. Reopened
core classes (`Array`, `StringIO`) never qualify.

The fragment and pool-literal rules also cover computed reflection: for
example `LCF.field?`, which calls `obj.respond_to?(name)` with a field name
from data, keeps every name that appears as a literal or fragment. A name
built at runtime from pieces that appear nowhere as a literal is the one
case this proof cannot see. So is a name taken back out of a built string
(`"#{a}: #{b}".split(': ')`), which the closed fragment rule treats as
never being a name. Verify mode below exists to catch both.

## Symbols

By default every `:name` literal counts as a lookup of `name`, since a
Symbol can be handed to `send`. Most are hash keys, `when` labels or
`respond_to?` arguments. For the closed list,
`tools/bc2cpp/static_dispatch_symbol_uses.rb` checks that every call in the
closed bytecode that takes a method name passes a literal: `send`,
`method`, `define_method`, `inject` / `reduce`, `to_enum` / `enum_for`,
`instance_eval` and the like, and the block of any call (`&:name` runs
`Symbol#to_proc`). A block may also be a block literal, `nil` or the
caller's own block. When that holds, a Symbol from anywhere else never
reaches such a call, so only the literals at those calls name a method:

- a `LOADSYM` elsewhere in bytecode is not a lookup;
- in the generated C++, a symbol that is only made into a value
  (`mrb_symbol_value`), compared, or used as a keyword name is not a lookup;
- a call that lists methods (`methods`, `instance_methods`,
  `method_defined?`, ...) or an `undef` refuses the whole rule.

`respond_to?` is the one name-taking method left out of that list. The
closed build answers it for left-out methods too: `bc2cpp_left_out` records
each left-out entry's class in a table shared by every compiled gem. The
generated `mrb_respond_to` and a `Kernel#respond_to?` installed over mruby's
own consult it after the method table. mruby's `respond_to?` ignores
visibility, and the rule refuses `undef`, so "the receiver is a kind of an
owner of the entry" is the whole answer. Natives look methods up only by
names they spell, which the outside scan already counts.

## The two lists

- `static_dispatch_unregistered.rb`: names safe in every build.
- `static_dispatch_unregistered_closed.rb`: further names that are safe once
  the closed world's direct calls replace by-name sends. Builds with
  `BC2CPP_BUILD_NAME=closed` (`scripts/bc2cpp/closed_build.bash`) apply
  both lists.

Regenerate them with:

```sh
MRBC=<host mrbc> ruby tools/bc2cpp/static_dispatch_registrations.rb --write
MRBC=<host mrbc> ruby tools/bc2cpp/static_dispatch_registrations.rb --closed-only --write
```

Repeat the `--closed-only --write` step until the list stops growing:
each dropped registration removes generated code that mentioned other names.

### Generated registration only

Every compiled method is registered by the generated
`bc2cpp_register_owner_methods`, the same in every build. Each compiled gem's
`src/register.cxx` only includes the generated file and calls its
`bc2cpp_gem_init` and `bc2cpp_gem_final`, and
`static_dispatch_scan_check.rb` fails if one registers a method by hand. An
entry the build's list leaves out gets `bc2cpp_left_out` instead of its
registration. In verify mode that registers the stub below, over the mrblib
definition. In any other build it removes the definition, if the owner itself
holds one (an inherited one belongs to another entry, and every entry of a
listed name is listed). A plain closed build also records the entry for
`respond_to?` (see "Symbols" above).

`bc2cpp_register_owner_methods` runs two halves in order:
`bc2cpp_register_core_owner_methods` (the core owners and the wired
embeddings) and `bc2cpp_register_program_owner_methods` (every other owner).
The core half looks up no program class, so a program that needs the compiled
core methods before its own class bodies run can install it first. The
optcarrot probe's `install_prelude!` does that, and its `install!` runs the
program half later. `scripts/bc2cpp/registration_split_check.rb` checks the
split.

### Native methods

The closed list also covers native methods: a C/C++ registration made with
`mrb_define_method` and the other defining calls, on an engine owner whose
class `NativeOwnerMap` resolves (in practice RGSS's C++ classes). The owner's
compiled gem (the one whose `native_namespaces` holds its top namespace)
calls `bc2cpp_left_out` for each listed one, so it is removed like a left-out
compiled entry. It looks the class up first and skips it when the build does
not define it. A native is no candidate when Ruby defines the same name on
its owner (the removal would take the Ruby method), when a native alias or
undef names it there, or when the owner has a registration with a computed
name.

mruby's own natives mostly sit in ROM method tables (`MRB_MT_ENTRY`), which
are not candidates here: removing one at run time adds a tombstone entry in
RAM. They are listed separately (below).

### Core ROM entries

The closed build leaves core ROM entries out of their tables at compile time.
The proof's `--closed-only --write` also writes
`tools/bc2cpp/static_dispatch_core_excluded.rb` (`CoreNativeCandidates`,
`tools/bc2cpp/core_native_candidates.rb`). `build_config.rb` turns that list
into the header that `MRB_MT_EXCLUDE_HEADER` names
(`3rd/mruby/include/mruby/class.h`). Each listed entry then has no table slot,
and its function goes too once nothing else calls it.

The engine proof reads core Ruby only for the sends that may reach an engine
object. A core method is also reached through core receivers, so this rule is
receiver-blind and coarser. A name stays when any of these spells it:

- a symbol an instruction of the program may look up: a send, a `LOADSYM`,
  an alias, an undef or a key. The operand of a `DEF`, `TDEF` or `SDEF`
  defines its name, so a name only a def names does not count. An irep with an
  `ALIAS` keeps all its symbols, because the disassembly shows the alias's old
  name, the one it looks up, as the new one;
- an operator opcode's operator (`ADD` sends `+`) and, under `SUPER`, the name
  of the method the body belongs to;
- an identifier-shaped pool string.

Every engine irep counts. A core, external or foreign mrblib method body
counts only while its own name stays reachable (`LIVE_CORE`), solved as a
fixpoint. Nothing runs a Ruby-defined core method but a lookup of its name or a
direct `_impl` call from compiled code. A `<Owner>_<name>_impl` token in the
generated code counts as that name's lookup. Root and class bodies, and the
blocks made in them, always count. Pool fragments are read from every body,
live or not.

The rule stays receiver-blind on purpose. A measured variant attributed each
owner-call site (`BC2CPP_OWNERS`) and each typed compiled send to its receiver's
owners only. It freed at most four more entries, because the same names stay
reachable through core mrblib and native lookups whose receivers are unknown.

Names also count from:

- a lookup in the native sources (string literals, presym macros, naming
  macros). The name operand of a table entry or registration call defines the
  name, so it does not count;
- a string literal of the generated code;
- `ALWAYS_DYNAMIC`, or a name a pool fragment may build.

The VM's implicit calls are presym uses in `src/`, so the scan reads them like
any other lookup. Operator names are never listed, because the VM sends them
from opcodes.

An exclusion macro names (`MRB_MT_CLASS`, name), and that pair covers every
table of the class, its singleton's included. So a pair is listed only when
each of its entries sits in a table installed into `MRB_MT_CLASS` itself, and
only into it.

A verify build (`BC2CPP_UNREGISTERED_VERIFY`) also registers the aborting stub
under each listed name, from mruby-core-compiled's core half.

Core natives registered at run time (`mrb_define_method` and the other
defining calls) go by the same rule, listed in
`STATIC_DISPATCH_CORE_LEFT_OUT`. mruby-core-compiled's core half removes each
one like a left-out native. A class the build does not define is skipped.
Some keys stay whatever their name:

- a key a ROM entry of the same class shares, because the removal would take
  the ROM entry and leave a tombstone;
- a key that a native alias or undef names;
- a key on an owner with a computed-name registration.

`scripts/bc2cpp/core_native_candidates_check.rb` checks the rule.

#### Device builds

The ROM exclusion also applies to the interpreted `psp` and `maix` builds.
Only ROM entries are covered; the run-time list needs mruby-core-compiled, which
these builds do not link. A build may take the list only when everything it can
run lies inside the world the proof read. That world is:

- the RPG2000/2003 engine's mrblib;
- every core and external gem's mrblib;
- every native source under `src/`, `app/`, `include/`, the engine gems and
  `3rd/mruby`;
- the closed build's generated code.

psp and maix are single-format builds, so they have no game Ruby and no other
maker gem. Their engine mrblib is the closed one, less a few files (psp drops
the debug tools), and the proof already reads their native sources. Fewer
sources only remove references, so the closed list stays sound for both. The
maix firmware's `mrb_load_string` probe evaluates a string literal and sends
nothing.

On maix the firmware link's `--gc-sections` then drops each excluded entry's C
function. `app/psp` links without section GC, so on psp only the table rows go.

These builds do not take the list:

- **psp or maix with `RPGMAKER_BC2CPP=1`.** Their generated code is not the
  closed build's, and a by-name fallback it emits may name a core method the
  closed generation never did.
- **wio, and m5stack, which links the wio library.** `wio_strip_*` rewrites its
  mrblib, and it swaps in a generated `schema_blob.rb`. The proof reads
  neither.
- **desktop, wasm and android.** They run a game's own Ruby (RGSS scripts,
  `eval`), which may name any method.

The probe generates its C++ with `BC2CPP_BUILD_NAME=closed`, so the names
on either list are missing from its registrations. Every run therefore
counts both lists as already unregistered. If it did not, a rerun would drop
those names from the candidate set and write a shorter list than the one
checked in.

`BC2CPP_UNREGISTERED_EXTRA="Owner#name,..."` adds more names for a single
generation. It is meant for check fixtures, which have no place in the
committed lists.

## Why an entry stays

`scripts/bc2cpp/dynamic_names_report.rb` runs the closed-only proof and prints,
for each entry it keeps, the first source that made the name dynamic: a C
string literal in a gem's generated code, `ALWAYS_DYNAMIC`, a Symbol literal
(`SYMBOL_USES`), a file whose text names it, a send in code that may run as
bytecode, a string fragment that may build it, or the base name of a suffixed
one. The default output is a summary by source; `--entries` lists every kept
entry with its reason. Only the first reason is shown, so removing one source
can reveal the next.

## Verify mode

`BC2CPP_UNREGISTERED_VERIFY=1` (`build_config.rb`) defines
`BC2CPP_UNREGISTERED_VERIFY`. With it, each unregistered entry is registered
as a stub instead. The stub prints the message below and aborts:

```text
bc2cpp: UNREGISTERED_VERIFY: unregistered method looked up by name: Class#name
```

A plain build would raise `NoMethodError` at that point, and game code may
rescue it. The abort makes a lookup the proof missed fail loudly instead.
The debug builds that turn a proof-failure helper back into a dispatch
(`-DBC2CPP_HINT_VIOLATION_LOG`, `-DBC2CPP_*_DISPATCH`) may also reach a stub.
Use verify mode to run a game trace against the lists, for example
`BC2CPP_UNREGISTERED_VERIFY=1 scripts/bc2cpp/closed_build.bash <dir>` and
then `scripts/bc2cpp/trace_host.bash <dir> <game>`. Set
`BC2CPP_HOST_BATTLE_TROOP=<troop id>` (and `BC2CPP_HOST_BATTLE_PLAY=1`) to
open a battle after New Game and drive it. Other scenes take scripted input:

- `BC2CPP_HOST_KEYS="FRAME:KEY,..."` taps `RGSS::Input` keys (`C`, `B`,
  `DOWN`, ...) before the given frames, for example to open the menu (`B`)
  and enter a command.
- `BC2CPP_HOST_PREVIEW_MAP=<map id>` starts New Game on that map. A map
  without an opening event lets the menu open, and only some maps allow
  saving.
- `BC2CPP_HOST_CONTINUE=1` picks Continue on the title, which loads the save.

Saving writes into the game directory, so trace a copy.

`scripts/bc2cpp/unregistered_verify_check.rb` checks the emitted
registrations, and checks both modes' runtime behaviour on a small host.
`scripts/bc2cpp/static_dispatch_scan_check.rb` checks the scan rules on
fixture text.
