# 0323. bc2cpp: per-class resolution for proven receiver sets (measured, partly built)

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0315 measured why 453 rpg2k guard-chain sites still dispatch by name and named three proofs a table or arm
needs together: (1) a def inside `class << <class constant>` is a class-object definer, not an instance definer, (2)
native and outside-Ruby definers are resolved per class, (3) the gates are judged against the proven receiver set
`S` instead of the whole name. ADR 0317 added call facts (`S` from an earlier call on the same value) and measured
about 130 more sites bounded to sets with core or native members, which "need per-class native arms".

The request: measure how many by-name sends those proofs and per-class native arms would really remove (not the 339
upper bound), and build the sound slice when it clears 30 removed by-name sends in the engine gems.

## Measurement

`BC2CPP_NATIVE_ARMS_REPORT=<tsv>` (`tools/bc2cpp/native_arms_report.rb`, aggregated by
`scripts/bc2cpp_native_arms_report.rb`) writes one row per explicit-receiver send whose final code still reaches a
by-name call: the set `S` (proven by the exact-class flow, or bounded by call facts, whatever its members), what each
cell of `S` would be, the whole-name gates that fail today, and the gates re-judged against `S`. It changes no
generated code. Wio closed world, `origin/master` `7818f0f5`, `3rd/*` populated, engine gems (rpg2k, lcf, rgss).

| Population | Sites |
| --- | ---: |
| by-name sites with a row (explicit receiver, final code reaches a by-name call) | 2,254 |
| of those a chain whose else still dispatches (kept marker) / a bare send with no chain / an arm of a dead-else chain | 503 + 92 bounded / see below |
| dispatching sites (kept else or bare send) with a bounded receiver set (proven 163, call facts 107) | 270 (rpg2k: 211) |
| ... kept else / bare send | 92 / 178 |
| ... receiver set unproven | 6,900 (rpg2k: 1,464) |

Bounded dispatching sites by set source and member kinds (engine gems): proven user classes 95 (44 kept else, 51 bare),
proven core class 66 (9 kept else, 57 bare), proven core+user 2; call facts with core+native+user members 27, core+user
27, core only 12, native only 5, native+user 7, user only 6, with a class object 21. Per cell of the 155 bounded sites
a cell blocks: `Array#size` 19, `Hash#size` 17, `Range#size` 10, `String#[]` and `Array#[]`/`Hash#[]` with two arguments
9-10 each, `Array#first` 8, `Hash#count`/`Array#count` and friends 4-6 (inherited natives), `Hash#delete` 8 (an outside
Ruby body, see below), `Hash#empty?` 6, `Range#cover?` 5, `Array#pack` 16 and `Array#inspect` 11 (no readable owner),
`RGSS::Sprite#x=`/`y=`/`z=` 30 (a direct entry whose `:int` argument needs a guard, so the by-name else stays for the
other arguments: a relocation, not a removal). A native cell has a frame-independent entry for 11 core methods and 153
RGSS owner entries; `Array#size`/`length`, `Hash#size`/`length`/`empty?`, `Array#first`/`empty?`, `Range#size`,
`String#[]` and `Symbol#name` are one-line C bodies an audit could add (`RARRAY_LEN`, `mrb_hash_size`, ...), but each
bounded site's set has 12-18 classes (`size` on `Array, Enumerator, File, Hash, Integer, Range, String, Struct,
StringIO, LCF::*...`), so the arm chain would list a native arm per class and most of them (`File#size`, `Struct#size`,
`OnigMatchData#size`, `Enumerator#size`) have no entry: a cell that is a send is a relocation.

Realistic yield of the levers, measured on the real build (kill switch off against on, same tree):

| | Sites removed |
| --- | ---: |
| (a) alone, (b) alone, (c) alone | 0 each |
| `update` on a proven `RPG2k::Window` / `Game::Interpreter` (proven 23 + 16, call facts 3): all of (a), (b), (c) | 42 |
| `Hash#delete` on a flow-proven Hash (FLOW_CORE_DIRECT, below) | 8 |
| **total** | **50** |

Sites with an unproven receiver set (6,900 of 7,170 dispatching, 1,464 of 1,675 in rpg2k) cannot be fixed by any of
these levers. The 339 upper bound of the baseline counted combinations of gates, not cells: the `width` and `height`
sites (128) have a class object in their set or an unproven receiver, and the 130 CALL_FACTS-bounded sites with
core/native members are 118 bare sends with 12-18 classes each, gated by native cells that have no entry.

## Decision

Built (kill switch `BC2CPP_NATIVE_CLASS_ARMS=0`, `shipped.cxx` byte-identical to master):

1. **Class-object definers** (`ClosedWorld#instance_unknown_def?`, `#class_object_body?`,
   `CodeGen#symbol_instance_installed_names`). A `def`/`alias`/`alias_method` that is directly in the body of a
   `class << <constant that no SETCONST binds>` (or `class << self` in a walked class body) lands on that class or
   module object. An instance of a class that is not a Module or Class (the only sets `receiver_instances` and call
   facts produce) cannot see it, so it neither makes the name an unknown definer nor an installed name for that set.
   Nested blocks, an install with another receiver, a fresh `Object.new` and every non-constant target stay what
   they were. `refusal(instance_scope: true)` reads the instance-only sets; the old sets still serve every
   class-object receiver.
2. **Per-class resolution** (`CallFacts::Answers#resolves_in_ruby?`). The first definer on the lookup path of a class
   is a Ruby definition of the registry and no native or outside-Ruby owner sits at or before it, or no definer
   exists (a NoMethodError). The Ruby side is judged by full class name; an outside source names a class by its last
   segment, so a declared class counts as theirs only when some outside source spells its root too
   (`ClosedWorld#outside_spells_class?`). A method_missing class, an unknown mixin, an unresolvable superclass and a
   name unbounded for instances give no answer. The exact-class flow's set is now scoped as the call-fact sets are
   (only its classes need an arm) and uses this per class instead of the whole-name `core_or_native`.
3. **FLOW_CORE_DIRECT** (`CodeGen#flow_core_direct_line`). A send whose receiver the flow proves is exactly a core
   class that CORE_EXACT_DIRECT (ADR 0314) accepts (a compiled mruby core body, here `Hash#delete`) now calls it
   instead of getting a guard chain over the user classes that also define the name: the arms of those classes were
   dead for an exact Hash. This is the ADR 0325 observation: the lever was the chain, not a native entry.

Not built, and why: per-class **native arms** for core and native members (`size`, `count`, `first`, `delete` on
Array, ...). 155 of the 270 bounded sites have a native cell with no frame-independent entry or a Ruby body that is not
direct-callable, and most of the rest are `:int` entries whose by-name else is kept for the wrong argument type.
`mrb_get_args` reads the call frame, so an arm needs a hand-audited body per (class, name, arity) with a source manifest
and a differential test; for the sets above that is 12-18 classes per site and at most a handful of sites per name, a
cost the measured yield (0 sites for core/native members alone) does not repay. The audited entries that would pay
first are `Array#size`/`length` and `Hash#size`/`length` (about 40 sites combined, only where the whole set has an
entry).

## Soundness

A hint is not a proof (ADR 0210, 0290). Every lift needs a proven `S` and a proof about each member:

* the lift of `unknown_definer` and `dynamic_install` needs every definer and install of the name to be directly in a
  class-object body; one other source keeps the old refusal;
* `native_free` needs `resolves_in_ruby?` for every member, and `scoped` the classes of `S` to be listed (the
  existing `unlisted_class` guards add the rest);
* the withdrawal worlds of `scripts/bc2cpp_native_class_arms_check.rb`: a singleton on an instance, `class << obj`, a
  constant that is not a class, an instance-level alias (`alias_method` and the `alias` keyword), a computed
  definition, a nested def, an install on another class from the body, a method_missing class in the set, an outside
  Ruby source reopening or subclassing a class of the set, an outside native defining the name on a class of the
  set, a module that provides the name, a reopened `Hash#delete`, the kill switch and the open world.

Kept conservative: a module definer anywhere (`opaque_definer`) keeps the else; so does a method_missing class in `S`
and a facts set that contains a method_missing class.

## Consequences

* 50 by-name sends removed in the engine gems of the wio build (23 + 19 `update`, 8 `Hash#delete`); no by-name site
  appears anywhere else (the `mrb_funcall*`, helper-held and block sends are unchanged), so this is removal, not
  relocation. `bc2cpp_nomethod` sites grow with them and `NOMETHOD_REVIEWED` gains the keys of the new dead arms.
* The `class << Graphics` probe in `mruby-rgss/mrblib/lib.rb` no longer makes `update` a dynamic install for every
  instance receiver.
* Next levers, in order: audited `Array#size`/`length`, `Hash#size`/`length`/`empty?` entries together with a
  chain emitter for bare sends with a bounded set (about 40 sites, needs every class of the set to have a cell);
  SENDB receiver facts (277 block sends); the class-object member of a set (`width`/`height`/`action`, 23 sites: a
  class object cannot be told apart by class id, so a by-name arm stays); a proof that a receiver is not nil for the
  `Hash|nil` ivars whose `delete`/`clear` sites NILABLE_RECEIVER already wraps.
* Not run locally: see the PR description (the 32-bit `mrb_int` leg, the firmware smokes, the optcarrot open-world
  comparison, `NOMETHOD_REVIEWED` was regenerated from the same run it re-proves).
