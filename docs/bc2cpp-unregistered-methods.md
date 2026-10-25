# Unregistered compiled methods

A compiled method needs a method-table entry only if something can look it up
by name at runtime. When every caller reaches it through a direct `_impl` call
in generated C++, bc2cpp leaves it out of the table: no `mrb_define_method`
call, and no `mrb_get_args` wrapper kept alive for it.

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
  registration. Two kinds of use don't count, because neither looks up a
  compiled method: the by-name fallback of a `MONO_EMBED_GUARD` on an owner
  nothing subclasses, and the proof-failure helpers (`bc2cpp_nomethod`,
  `bc2cpp_nomethod_raise`, `bc2cpp_guard_violation`,
  `bc2cpp_hint_violation`, `bc2cpp_nil_receiver`). The nomethod helpers only
  dispatch on a receiver proven not to answer the name. The violation helpers
  raise without dispatching. The nil helper dispatches on `nil`;
- `super`;
- a string-pool literal or a `"#{x}_suffix"`-style fragment. For the closed
  list, a literal counts as a fragment only when a load of it may reach a
  built string. Each load is followed forward, through MOVE copies, closed
  methods' parameters and return values, and array or hash literals and the
  constants holding them. It stops being a fragment when every use only
  compares it (`==`, `when`, `start_with?`), looks it up as a native hash
  key, tests a constant list for it (`LIST.include?(x)`), or puts it into a
  string that also gets a character no name has (a space, a colon). Any
  other use keeps it a fragment: a store, a concatenation, an argument of a
  method the trace doesn't know, or a use the flow query refuses;
- a token in core, external or other-maker mrblib, tests, `scripts/`,
  `.github/`, `tools/` or native sources;
- for the closed list only, a narrower outside scan:
  - the other makers' gems (mruby-rpgxp, mruby-rpgvx, mruby-wolf,
    mruby-mvjs) are skipped, since the single-format closed build doesn't
    load them;
  - a native file contributes only its string literals, its presym operands
    (`MRB_SYM_Q(name)` and the like), and the arguments of macros that turn
    an argument into a name (`#param`, or passing it on to such a macro).
    A C local or field spelled like a method name looks nothing up;
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
    `define_method`, ...) or a `method_missing` keeps the text rule;

Only RPG2000/2003 internal owners qualify.

The fragment and pool-literal rules also cover computed reflection: for
example `LCF.field?`, which calls `obj.respond_to?(name)` with a field name
from data, keeps every name that appears as a literal or fragment. A name
built at runtime from pieces that appear nowhere as a literal is the one
case this proof cannot see. So is a name taken back out of a built string
(`"#{a}: #{b}".split(': ')`), which the closed fragment rule treats as
never being a name. Verify mode below exists to catch both.

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

The probe generates its C++ with `BC2CPP_BUILD_NAME=closed`, so the names
already on the closed list are missing from its registrations.
`--closed-only` therefore counts both lists as already unregistered. If it
did not, a rerun would drop every name on the closed list from the candidate
set and write a shorter list than the one checked in.

`BC2CPP_UNREGISTERED_EXTRA="Owner#name,..."` adds more names for a single
generation. It is meant for check fixtures, which have no place in the
committed lists.

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
