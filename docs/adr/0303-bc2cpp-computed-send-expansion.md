# 0303. bc2cpp expands a computed-name send over a provably finite name set

Date: 2026-10-01

## Status

Accepted

## Context

ADR 0298 ranked the remaining by-name dispatch by executed count and put the computed-name `send(...)`
sites of optcarrot's `CPU#r_op`, `#w_op` and `#rw_op` first. ADR 0279 made the proofs *see* such a send (a
name universe that poisons the call-site scans) but converted nothing: the site stays one `bc2cpp_send` of
`send`, which then does a second by-name lookup of the computed name.

The shape worth removing is a `send` whose name is one of a finite set the program spells out: a Symbol from a
frozen constant table (`MODES[i]`, `OPS[k]`), or a register every reaching definition of which is a Symbol
literal (`case`/`when`, `?:`). Each name is then an ordinary call whose target the closed world already
resolves per name (ADR 0259, 0297, 0299).

## Decision

`ComputedSend` (`tools/bc2cpp/codegen_computed_send.rb`, wrapping `compile_send` like `CheckedSend`) replaces a
`send` / `__send__` / `public_send` SEND or SSEND with a chain of per-name arms, from the name set that
`ComputedSendNames` (`tools/bc2cpp/computed_send_names.rb`) proves.

**Name set.** The reaching definitions of the name register (`BytecodeIR.reaching_definitions`, so joins and
loops are covered and an unmodelled write refuses) are all `LOADSYM`/`SYMBOL`, or a `GETIDX` whose receiver is
a `GETCONST`/`GETMCNST` of a bare constant name in `SymbolTables`: a name every definition of which is
`[...].freeze` or `{...}.freeze` of Symbol literals (array elements, hash values; keys are never read). Like
`IntegerConstants`, the table is keyed by bare name and poisoned by a definition of any other shape, a
`CLASS`/`MODULE` of that name, a native `mrb_define_const`/`mrb_const_set`/`mrb_define_class`, a foreign Ruby
`NAME =`, and by any `const_set`/`remove_const`/`autoload` in the world. At most 24 plain method names.

**Arms.** Each name is compiled by `splat_send_with` as the literal-name send of the same site (same receiver,
the remaining arguments), so it inherits that name's arity, visibility and dispatch proofs. The expansion is
taken only if every arm is a direct call (`_impl(M`) with no by-name dispatch, `bc2cpp_nomethod` or `#error` in
it; otherwise the site keeps its single computed send and the census sees no change. The chain compares the
Symbol value (`mrb_symbol`), not the table index, so a `case`, a `?:` and a table need no separate path.

**Default arm.** A Symbol outside the set is a proof violation (ADR 0290): `bc2cpp_guard_violation`, family
`COMPUTED_SEND`, logged to `$stderr` and raised as `BC2cppGuardViolation < NoMethodError` (`-DBC2CPP_NOMETHOD_VERIFY`
aborts; `-DBC2CPP_GUARD_VIOLATION_DISPATCH` dispatches by name for debugging). The one non-Symbol value a table
can yield is `nil` (an index or key outside it), which `send` rejects with `TypeError`; the arm calls
`mrb_obj_to_sym`, which raises exactly that, then falls into the violation. No arm dispatches by name.

**Withdrawn** (the site keeps its one computed send) when any of these holds: the world is open or has a global
refusal; any class has `method_missing`; a singleton class can be made on a non-class object (`def obj.m`,
`class << obj`, `define_singleton_method`, `extend`; `exact_instances_singleton_free?`); an installer
(`alias`, `define_method`, `undef`) has a computed name, or any name of the set is installed or blocked by
`RUNTIME_DEF_DEVIRT_GUARD`; `send` itself has a Ruby definition or is not registered by the build (`send` and
`public_send` live in `mruby-metaprog`; `__send__` is core); a table is read while `Array#[]`, `Hash#[]` or
`freeze` can be replaced (`core_native_arm_safe?`); a name has a second definition (a subclass override, a
reopening), which makes its arm a guard chain with a by-name else; or an arm's arity is wrong. `public_send`
additionally needs every name public, defined in the registry and `visibility_stable?`, since a direct arm
does not check visibility. `send` and `__send__` ignore visibility, as the arm does.

Kill switches: `BC2CPP_COMPUTED_SEND=0` (the before side of a measurement) and `BC2CPP_GUARD_VIOLATION=0` keep
every computed send as one by-name call.

## Consequences

Measured with `BC2CPP_COMPUTED_SEND=0` against the default, same tree:

- **optcarrot (the sites that motivated this): no change.** The probe's C++ is byte-identical with the switch
  off and on. Its 19 computed sends are all of two kinds. `r_op`/`w_op`/`rw_op`/`a_op` send *method parameters*
  (`send(mode, true, false)`, `send(instr)`): the name register is an incoming argument. `run` sends
  `send(*DISPATCH[@opcode])`, a splat of an element of a table that a class-body loop (`self.op`) fills from
  ~150 `op([...], [:r_op, :_lda, :alu])` calls and that is not frozen. Neither is a literal set, a frozen table
  or a `case`. Closing them needs an inter-procedural proof, not this one: (1) the contents of `DISPATCH`
  (every write of the constant, through `op`'s `args` and `ADDRESSING_MODES`, an unfrozen Hash of Arrays that
  must also be proven unmutated), (2) the splat call's arguments as the parameters' only call site, and (3) a
  `send(*array)` arm. Replacing the parameter sends by an arm chain over "every arity-2 method of `CPU`" would
  need the by-name send kept as the fallback, which is a guard hint (ADR 0210) rather than a proof, so it was not
  built.
- **The RPG engine (wio closed world):** see the table below; its computed sends (`target.send("#{field}=", v)`,
  `b.send(name)`) build their names from strings and are outside the proof.
- Expanded sites are exercised on synthetic programs only (`scripts/bc2cpp_computed_send_check.rb`).

A pre-existing divergence this work found and left alone: a by-name `public_send` from compiled code skips the
visibility check, because `send_method` in `3rd/mruby/src/vm.c` takes its `funcall` path for a call from C and
never reaches the `pub` test. The expansion never relies on it (it refuses a non-public name), and the check
does not run `public_send` of a private name.

`scripts/bc2cpp_computed_send_check.rb` (CI `bc2cpp-checks`, `core-mrbtest` shard, and the `int32` width job)
pins the generated code (table, hash, `case`, `?:`, private target, `public_send`), 21 negative worlds in which
the send must stay one computed send (subclass override, `define_method` with literal and computed names,
`alias_method`, singleton on an instance, `class << obj`, `define_singleton_method`, `method_missing`, redefined
`send`, unfrozen/duplicated/mixed tables, a table name that is also a class, `const_set`, `remove_const`,
`Array#[]`/`Hash#[]`/`Kernel#freeze` redefinitions, a foreign Ruby and a native definition of the table name, a
wrong arity, more than 24 names), and, against real mruby, compiled versus interpreted on a 64-bit full-core
build, a core-only build (`__send__`) and a 32-bit `mrb_int` full-core build: values, side effects, `send(nil)`'s
`TypeError` text and `ArgumentError`, and zero dynamic dispatches in the expanded sites. `CSEND_MUTANTS=1`
removes one proof at a time from a copy of the generator (16 mutants) and each must fail a check. Nothing in the
generated code is an integer constant or arithmetic, so the 32-bit build differs only in its `mrb_sym` width.

Not run: firmware smokes (psp/wio/maix), CI.
