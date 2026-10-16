# 0454. RBS record types as checked RECORD_HASH_PROOF declarations

Date: 2026-10-16

## Status

Accepted

## Context

bc2cpp is moving its bespoke whole-program type proofs to RBS declarations that a checker verifies site by site
(ADR 0412, 0413, 0442). The closed-world facts stay as the preconditions for trusting any declaration: no
outside writer, which definitions a send reaches, and no reflection.

RECORD_HASH_PROOF (ADR 0285) infers per-key value classes of a Hash held in an ivar. It refuses
`RPG2k::Scene::Battle#@ui`, the battle scene's whole live state, because of one write:
`@ui.update({ phase: :command, troop: troop, battle: Game::Battle.new(...), ... })` (scene/battle.rb:160).
Every send on `@ui[:battle]`, `@ui[:troop]` or `@ui[:events]` therefore stayed a by-name send. The proof also
infers classes only from literals and `Array/Hash/String.new`, and since `@ui = {}` omits every key, no key
could become a non-nil fact even if `update` were understood.

## Decision

An RBS record type on an ivar is a declaration that a checker verifies at every write of the ivar
(tools/bc2cpp/rbs_record_types.rb, `RBS_RECORD_TYPES`):

```rbs
class RPG2k::Scene::Battle
  @ui: { ?battle: Game::Battle, ?troop: Game::Troop, ?events: Game::Interpreter, ?phase: untyped, ... }
end
```

**Loader.** `@x: { ... }`, `@x: { ... }?` and `attr_reader/attr_accessor x: { ... }` in the signature files
(the same directories RbsSignatures reads). A field is `key: T` (required) or `?key: T` (optional; the rbs gem
in use is 4.2.0, and 3.4.0 rejects the syntax). `T` is `untyped` (no check, no hint) or a type
RbsSignatures.value_classes_of names: a class, `T?`, a union, `bool`, `nil`, a literal, `Array[...]` or
`Hash[...]` (container class only; elements are not checked). Any other field type is a TC1009 error. A record
return type is accepted with a TC1005 note and gives nothing. RbsSignatures leaves record types alone (one guard
in its `seed_ivar`).

**Checker.** The ivar NAME is scanned across the whole closed world with RecordHash::Scanner's alias discipline
(the Hash may be read by key, written by `h[:k] = v`, copied by MOVE or captured by a block; anything else is an
escape), extended in a subclass with:

- `h.update({...})` / `h.merge!({...})`: one Hash literal argument, no block; each pair is a store. Admitted
  only while nothing that can land on Hash instances redefines `update`/`merge!`/`__merge`
  (mruby-hash-ext's own `merge!` is core; a definer inside `class << Const` answers that object only);
- `h.store(:k, v)`: a store;
- `h.delete(:k)`: only of a key declared optional;
- `key?`, `has_key?`, `include?`, `member?`, `size`, `length`, `empty?`, `fetch`, `dig` (no block): reads;
- `h.nil?`, `!h`, `h == nil` (OP_EQ) and `h != nil` (the operand a literal nil): truth tests, admitted under the
  same redefinition check as `update` (no definer that can land on a Hash: Hash, Object, Kernel, BasicObject,
  Enumerable in the program, or an outside Ruby source). A `{ ... }?` record tested for nil and then read by key
  needs nothing more: the scan follows the Hash, not nil, and the truthy edge of the test carries it;
- a self send (`SSEND`) whose leading register held the Hash: the op overwrites that register with self, so the
  Hash is dropped, not passed (`@x = {...}; draw` used to read as an escape).

**Interprocedural scan** (always on; there is no switch). Passing the Hash as an argument is not
an escape when it is a plain positional argument (no splat, keyword or block on the call, and not also the
receiver) and, for EVERY definition the send's name can reach:

1. ESCAPE_ANALYSIS (ADR 0316) says the callee does not capture that argument. The checker asks the installed
   EscapeAnalysis::World through `Analyzer#name_captures_arg?` with the argument class `Hash` (the record is a
   literal nothing can extend), so the callee's own sends on it resolve through Hash's ancestry rather than every
   definition of the name; the summary is memoised per class. A name the world cannot enumerate, a name with no
   definition, a native definition (no native has an audited argument fact) or a `define_method` body keeps it.
2. The callee's parameter register, scanned as one more alias of the Hash from the callee's entry, passes these
   same rules: literal-key reads, key writes that join the declaration's checked stores (declared key, conforming
   value class), the read-only queries and truth tests above, and passing it on to callees that satisfy 1 and 2.
   The parameter must be a leading mandatory one, and the callee may take no keywords. A block inside the callee
   that reads it is an escape.

Each (callee body, parameter) is scanned once per declaration; a frame being scanned is assumed to pass
(co-inductive, as EscapeAnalysis does). That is sound because the checker has no partial answer: any failure
anywhere in a cycle is a TC1009 error that refuses the whole declaration. Depth is capped at 16 callees. Without an
installed escape-analysis world (`BC2CPP_ESCAPE_ANALYSIS=0`, an open world) or with the kill switch, every such
call is an escape again, so a declaration that relies on it (`@name_ui`) becomes a TC1009 error.

Every key written must be declared; every Hash literal stored into the ivar must carry every required key; nil
may be stored only into `{ ... }?`; every value must be traced to a class that conforms (the class or a
subclass) to the field type: a literal, `Klass.new` (trace_new_target), or the Array rule ClassLayout's ivar facts
use (proven_array_source_scan). Keys come from RecordHash.literal_keys, so a parameter whose every call site passes
a Symbol literal (KeyPool) counts as literal.

Whatever the checker cannot verify is a TC1009 error at its file:line: a computed key, a non-literal update, a
wrong value class, an untraceable value under a typed field, an undeclared key, an omitted required key, a delete
of a required key, `clear`, `replace`, any escape of the Hash. The closed-world preconditions refuse the whole
declaration with a TC1009 at the .rbs line: a global or literal reflection (RecordHash::Poison), an attr_writer, an
accessor installed outside the registry, and an ivar name a native or foreign source spells (`outside_ivar_names`,
which covers the native and outside-Ruby ivar scopes). Two declarations of one ivar name must agree, since the
scan is name-wide. TC1009 errors abort the build like RBS_SEED_CONTRADICTION; under the type check
(BC2CPP_TYPE_FACTS) they join the signature diagnostics, so `scripts/bc2cpp/type_check.rb` exits 1 on them.

**Consumers.** A verified name joins RecordHash.table (and its attr_reader RecordHash.readers) in the shape
RECORD_HASH_PROOF produces, so the existing consumers (the unguarded exact-class call of codegen_record_hash.rb and
ClassLayout's Array read) apply their own rules to it: they need a non-nil key, which a key absent from some stored
literal never is. New: a literal-key read `@x[:k]` (or through the attr_reader) whose field names exactly one class
C, nil aside, returns C from trace_new_target's GETIDX arm, only for guarded consumers (`JoinDominance.guarded?`):
the send keeps its `mrb_obj_class` guard, and under STRICT_HINTS (ADR 0419) its else arm may be forced.

**Declarations.** `RPG2k::Scene::Battle#@ui` (sig/bc2cpp/record_types.rbs): all 51 keys optional (`@ui = {}`
comes first), `battle: Game::Battle`, `troop: Game::Troop`, `events: Game::Interpreter`, `allies`, `foes`,
`enemy_sprites?`, `actor_sprites?` as Array and `pages_run` as Hash; every other key `untyped` (its writers are
method results the checker cannot trace, such as `battle_panel_window(...)` or Integer arithmetic). The checker
verified it against both scene classes.

`RPG2k::Scene::Map#@name_ui` (the Enter Hero Name widget) is declared `{ ... }?` with the interprocedural scan:
its uses were `@name_ui.nil?` (#drive_parallel_wait), `@x = {...}` followed by a self send (#drive_name_input) and
`draw_kana_face(ui, ...)` / `draw_kana_name_field(ui)` / `draw_kana_grid(ui)`, which only read keys and store
their window under a declared key. #draw_kana_grid read `ui[:page]` inside an `each_with_index` block, which
ESCAPE_ANALYSIS (rightly) calls a capture; it now reads it into a local before the loop. Only `kana: bool` is
typed; every other key holds a method result, arithmetic or a window and is `untyped`, so the declaration adds a
checked RecordHash.table entry but no receiver hint and no forced strict-hint site. The other Hash ivars
RECORD_HASH_PROOF refuses are computed-key caches (`@started_auto`, `@picture_tone_cache`, `@vehicle_sprites`,
`clear`/`each_value`/`h[id] = ...`), return the Hash, or have an attr_writer; `@inn_window` and `@vehicles` are
already proven.

**Strict hints.** Fourteen new forced sites (`@ui[:troop].members`, `battle.result`, `ui[:events].start`) are
listed in tools/bc2cpp/strict_hints_reviewed.rb after an audit of each: the key's only writer is the update
literal's `Klass.new`, the class has no subclass, and the only other value, nil (before #start), already raises
NoMethodError for these names.

## Consequences

- Shipped pass (wio closed world): `bc2cpp_send(` 1824 -> 1809, `mrb_funcall*(` 384 -> 384; typed sites
  +45 (IVAR_ACCESSOR +26, TYPED +9, UNLISTED_CLASS_CALL +7, UNLISTED_CLASS_ACCESSOR +3; POLY_SMALL_N -34);
  STRICT_HINT_SITE 34 -> 48 keys (49 -> 64 forced sites).
- A record declaration is checked, never trusted: a wrong one stops the build at the offending write.
- Value tracing is intraprocedural; a key written from a method result has to stay `untyped` until return
  declarations are themselves checked.
- `?key:` needs an rbs gem that parses optional record fields (4.2.0 here); an older gem reports TC1002 for the
  file, as for any syntax it cannot read.
- scripts/bc2cpp/rbs_record_types_check.rb (needs MRBC; nightly `rbs-signatures` shard) covers the loader, the
  accepted writers, one located TC1009 per refused shape, the outside spelling, reflection, and the generated code
  with and without the declaration; the nil tests on a `{ ... }?` record (and a guarded TYPED read after one, and
  `Hash#nil?` redefined); and the interprocedural scan: a reading, writing and recursive callee accepted, and
  located TC1009s for a callee that stores the Hash in an ivar, returns it, writes an undeclared key or a wrong
  class, clears it, a recursive pair that misbehaves (in its second frame, or by returning it), a block in the
  callee, a call with a block, a splat, a keyword, a native callee, an undefined name, a POLY name with one bad
  definition, and the kill switch.
- The interprocedural scan adds no hint of its own: a read through a callee's parameter is not a RecordHash read
  site (read_slots needs `@x` or the attr_reader), only its writes are checked and joined.
