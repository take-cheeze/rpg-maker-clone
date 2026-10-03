# 0323. bc2cpp: per-class resolution for proven receiver sets (measured, partly built)

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0315 measured why 453 rpg2k guard-chain sites still dispatch by name and named three proofs a table or arm
needs together: (1) a def inside `class << <class constant>` is a class-object definer, not an instance definer, (2)
native and outside-Ruby definers are resolved per class, (3) the gates are judged against the proven receiver set
`S` instead of the whole name. ADR 0317 added call facts (`S` from an earlier call on the same value) and measured
about 130 more sites bounded to sets with core or native members, which "need per-class native arms". ADR 0325 added
that `Hash#delete` is mrblib Ruby, so a flow-proven Hash misses only because CORE_EXACT_DIRECT does not read the flow.

The request: measure how many by-name sends those proofs and per-class native arms would really remove (not the 339
upper bound) and build the sound slice when it clears 30 removed by-name sends in the engine gems.

## Measurement

`BC2CPP_NATIVE_ARMS_REPORT=<tsv>` (`tools/bc2cpp/native_arms_report.rb`, aggregated by
`scripts/bc2cpp_native_arms_report.rb`) writes one row per explicit-receiver send whose final code still reaches a
by-name call: the set `S` (proven by the exact-class flow, or bounded by call facts, whatever its members), what each
cell of `S` would be, the whole-name gates that fail today, and the gates re-judged against `S`. It changes no
generated code. Wio closed world, `origin/master` `7818f0f5`, `3rd/*` populated, engine gems (rpg2k, lcf, rgss).

| Engine gems | Sites |
| --- | ---: |
| by-name sites (explicit receiver) | 2,009 |
| ... whose else still dispatches (kept marker 372, bare send with no chain 1,553) | 1,925 |
| ... receiver set bounded (proven 163, call facts 107) | 270 |
| ... receiver set unproven (no lever here can touch them) | 1,655 |
| bounded sites: kept else / bare send | 92 / 178 |
| bounded sites a cell blocks: a native with no frame-independent entry, an `:int` entry, a Ruby body that is not direct-callable | 186 of 270 |
| bounded sites with a class object in the set (`width`, `height`, `action`: a class object has no class id to compare) | 23 |

Bounded sites by set source and members: proven user classes 95 (44 kept else), proven core class 66 (9 kept else),
proven core+user 2, call facts with core+native+user 27, core+user 27, core 12, native 5, native+user 7, user 6,
with a class object 21. The cells that block most: `Array#size` 19, `Hash#size` 17, `Range#size` 10, two-argument
`[]` on String/Array/Hash/Struct/OnigMatchData 9-10 each, `Array#first` 8, `Hash#count`/`Array#count` and their
inherited natives 4-6, `Hash#empty?` 6, `Range#cover?` 5, `Array#pack` 16 and `Array#inspect` 11 (the native owner is
not readable), and `RGSS::Sprite#x=`/`y=`/`z=` 29 (a direct entry whose `:int` argument needs a guard, so the by-name
else stays for any other argument: a relocation, not a removal). A frame-independent native entry exists for 11 core
methods and 153 RGSS owner entries. `Array#size`/`length`, `Hash#size`/`length`/`empty?`, `Array#first`/`empty?`,
`Range#size` and `String#[]` are one-line C bodies an audit could add, but each bounded `size` site has 12-18
classes (`Array, Enumerator, File, Hash, Integer, Range, String, Struct, StringIO, LCF::*`...) and most of those
(`File#size`, `Struct#size`, `OnigMatchData#size`, `Enumerator#size`) have no entry: a cell that is a send is a
relocation. Of the 68 core-only flow-proven sites ADR 0325 counts (`pack` 16, `inspect` 11, `delete` 10, `include?` 8,
`cover?` 5), `Hash#delete` (8) has a compiled body; `Array#delete`, `pack`, `inspect`, `cover?` and `Hash#clear` are C
bodies without a readable owner or entry, and `Array#include?` is an engine-gem body on a boot class
(`opaque_definer`).

The lever model of the report (the three proofs alone, in combination) finds 2 removable sites, because it cannot see
the `update` family: its name is unbounded in `Answers` until the class-object proof exists. The real build, switch off
against on on the same tree, is the number that counts:

| Lever | Sites removed |
| --- | ---: |
| class-object definers alone, per-class resolution alone, scoped set alone | 0 each (measured with the model; only the three together move `update`) |
| `update` on a proven `RPG2k::Window` (23) and `Game::Interpreter` (16 proven, 3 by call facts) | 42 |
| `Hash#delete` on a flow-proven Hash (FLOW_CORE_DIRECT) | 8 |
| **total** (cutoff: 30) | **50** |

Sites with an unproven receiver set cannot be fixed by these levers: 1,655 of 1,925 dispatching sites. The 339 upper
bound of the baseline counted combinations of gates, not cells: the `width` and `height` sites (128) have a class
object in their set or an unproven receiver, and the 130 CALL_FACTS-bounded sites with core/native members are bare
sends over 12-18 classes whose native cells have no entry.

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
   (`ClosedWorld#outside_spells_class?`; without that, the RGSS native `Window` would stand for `RPG2k::Window`). A
   method_missing class, an unknown mixin, an unresolvable superclass and a name unbounded for instances give no
   answer. The exact-class flow's set is now scoped as the call-fact sets are (only its classes need an arm) and uses
   this per class instead of the whole-name `core_or_native`.
3. **FLOW_CORE_DIRECT** (`CodeGen#flow_core_direct_line`). A send whose receiver the flow proves is exactly a core
   class that CORE_EXACT_DIRECT (ADR 0314) accepts (a compiled mruby core body, here `Hash#delete`) calls it instead
   of getting a guard chain over the user classes that also define the name: the arms of those classes were dead for
   an exact Hash. This is the ADR 0325 observation; the lever was the chain, not a native entry.

Not built: per-class **native arms** for core and native members (`size`, `count`, `first`, `delete` on Array, ...).
186 of the 270 bounded sites have a native cell with no frame-independent entry, an entry that keeps a by-name else
for the wrong argument type, or a Ruby body that is not direct-callable. `mrb_get_args` reads the call frame, so an
arm needs a hand-audited body per (class, name, arity) with a source manifest and a differential test; the sets
above have 12-18 classes per site, so a site is removed only when every class of its set has an entry, and the
measured yield of core/native members alone is 0 sites. The entries that would pay first are `Array#size`/`length`
and `Hash#size`/`length` (about 40 sites combined, only where the whole set has an entry).

## Soundness

A hint is not a proof (ADR 0210, 0290). Every lift needs a proven `S` and a proof about each member:

* the lift of `unknown_definer` and `dynamic_install` needs every definer and install of the name to be directly in a
  class-object body; one other source keeps the old refusal;
* `native_free` needs `resolves_in_ruby?` for every member, and `scoped` the classes of `S` to be listed (the
  existing `unlisted_class` guards add the rest);
* **nil.** The exact set leaves nil out (`receiver_instances`), but a nil the flow cannot exclude reaches the else arm
  too and must raise what dispatch raises. A name NilClass may answer (an installed name, a registry or outside
  definer, a native or unreadable native owner: `nil_unanswerable_refusal`) keeps the whole-name gates for such a
  site; the instance variant leaves out the installs and unknown definers only a class object sees (nil is an
  instance of a non-Module class), so the `class << Graphics` probe does not make `update` answerable on nil. The
  fixture gives NilClass a native `na_zork` in one world: a possibly nil receiver must keep its else there;
* the withdrawal worlds of `scripts/bc2cpp_native_class_arms_check.rb`: a singleton on an instance, `class << obj`, a
  constant that is not a class, an instance-level alias (`alias_method` and the `alias` keyword), a computed
  definition, a nested def, an install on another class from the body, a method_missing class in the set, an outside
  Ruby source reopening or subclassing a class of the set, an outside native defining the name on a class of the
  set, a module that provides the name, a reopened `Hash#delete`, the kill switch and the open world.

Kept conservative: a module definer anywhere (`opaque_definer`) keeps the else; so does a method_missing class in `S`
and a facts set that contains a method_missing class.

Found, not fixed (present on master with the switch off): a chain arm calls the registry body of a class even when
the program later replaces the name with `alias_method` or `define_method` over an existing definition, and a
`def obj.name` singleton on an instance of a listed class is not seen by the class-id compare. The behavioural half
of the check therefore runs those worlds as generated code only.

## Consequences

* 50 by-name sends removed in the engine gems of the wio build (42 `update`, 8 `Hash#delete`), measured switch off
  against on: `bc2cpp_send` 2,513 -> 2,463, `mrb_funcall*`, helper-held and block sends unchanged, and no by-name
  site appears anywhere else, so this is removal, not relocation. `bc2cpp_nomethod` sites 4,380 -> 4,441: the 42 `update` sites plus 19 sites that had no by-name else before (17
  `index` on a `ShopState`, 1 `to_h` and 1 more `update`): their receiver is `K|nil`, NILABLE_RECEIVER used to test nil first and call the
  exact accessor, and the scoped set now ends the chain in the dead arm instead, so those sites trade a nil test for
  a class compare (same behaviour: nil reaches the arm, which raises the NoMethodError dispatch raises).
  `NOMETHOD_REVIEWED` gains 21 keys (`update` on the scenes' windows, `index` on a `ShopState`, `to_h` on
  `Game::Switches`/`Game::Variables`), each a receiver the flow proves is exactly the listed classes (plus nil, which
  the instance proof above covers).
* The `class << Graphics` probe in `mruby-rgss/mrblib/lib.rb` no longer makes `update` a dynamic install for every
  instance receiver.
* Next levers, in order: audited `Array#size`/`length`, `Hash#size`/`length`/`empty?` entries together with a chain
  emitter for bare sends with a bounded set (about 40 sites, needs every class of the set to have a cell); SENDB receiver facts (277 block sends); the class-object member
  of a set (`width`/`height`/`action`, 23 sites: a class object has no class id, so a by-name arm stays).
* Not run locally: the 32-bit `mrb_int` leg (no 32-bit build in this environment; it runs in `bc2cpp-width (int32)`),
  the firmware smokes, the optcarrot open-world comparison. The check ran against a full-core build made by
  `runtime.full_or_build` and a core-only build of `3rd/mruby`.
