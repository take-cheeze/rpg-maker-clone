# 0456. RBS loader: checked class parameters, `def self.` returns and `T?` facts

Date: 2026-10-16

## Status

Accepted

## Context

bc2cpp's whole-program type proofs are moving to RBS declarations that are checked site by site (ADR 0413, 0441).
An attempt to add verified receiver declarations found three loader gaps:

* A `def self.m: ... -> C` signature was loaded under its `Klass.singleton` owner, but nothing read its return:
  the receiver tracer (`trace_new_target`) only looks up a declared return once it has a receiver *class*, and a
  `Klass.m(...)` receiver is a constant. `Game::Message.scan` / `.parse` could not be typed.
* `T?` gave no hint, only an IR nominal bound. Nil-able ivars such as `Combatant#@actions` and
  `ScanResult#@pauses` could not be declared truthfully.
* A class parameter type `(C) -> R` fed ClassAnnotations as a seed. Nothing compared it with the callers, except
  where ArgTypes / ClassArgTypes happened to infer something. Most of these declarations came from CRuby traces or
  from `# bc2cpp:` comments, so they were hints, not facts.

## Decision

**Singleton returns (RBS_SINGLETON_RETURN, `dispatch_targets.rb`).** When the receiver of a `SEND` traces to no
class, and the name has exactly one definition in the whole program (natives included) which is a
`def self.m` with a declared return class, that class is the result. Every call that does not raise NoMethodError
runs that one body, whatever the receiver. The fact has the ret_class contract ("C or nil", guarded).
A singleton signature on a method that exists matches its definition and gives no TC1003 (fixture checked).

**`T?` (RBS_OPTIONAL_HINT, `rbs_optional_hint.rb`).** `Type#optional` holds T's own Type for `T?`. The `T?` Type
itself keeps kind `:other`. Two consumers read it:

* `@x: C?`, `@x: Array[C]?`, `@x: Hash[K, C]?` seed ClassLayout and its element tables exactly like `@x: C`.
  ClassLayout facts are already "C or nil": NIL_TOLERANT_JOIN skips `@x = nil`, so the inference produces such
  facts by itself. Every consumer re-checks the class:
  * TYPED / IVAR_ACCESSOR guards with a by-name, nil or hint-violation else (nil fails `mrb_obj_class == C`);
  * the loop emitters' `mrb_array_p` / `mrb_hash_p` tripwires (nil raises where `nil.each` raises
    NoMethodError);
  * ElementLayout, which treats a `nil` store as no evidence.
  The contradiction check (TC1001, element conflicts) compares the inner T.
* `-> C?` gives ElementAnnotations' `ret_class` C. Its documented contract is already "every non-nil value is C".

Not fed, because their consumers are exact:
* `Integer?` / `Symbol?` (IvarLayout typed slots; FIXNUM_NIL_IVARS stays the reviewed opt-in);
* an `Array?` / `Hash?` return (annotated_array_return admits a proven Array);
* `Array[C?]` elements;
* constructor pools;
* parameters.

**Checked class parameters (RBS_CHECKED_PARAMS, `rbs_param_check.rb`).** After RbsSignatures.apply, every class
parameter that reached ClassAnnotations from a signature (a `# bc2cpp:` comment still wins and is not checked
here) is either verified or removed. Removal covers the ClassAnnotations seed and its IR argument contract.

* Refused, TC1014 at the signature:
  * a POLY name, including every `initialize`;
  * a name in DynamicNames.universe (a computed send, ADR 0279);
  * a name an outside-world (native or foreign Ruby) source spells;
  * a packed (`f(*a)`, `f(*a, &b)`) or keyword caller.
* Verified otherwise. Every call site (CallSiteIndex, `super` and computed `to_enum` sites included) whose
  argument count the definition can take must pass, through all reaching definitions of the argument register,
  one of:
  * `Klass.new` of exactly that class, while no program `new` exists;
  * a call whose every definition declares that non-optional class as its return;
  * a parameter of the enclosing method that is itself a kept, signature-only declaration of that class;
  * `self` in a method body (not a block) of a class nothing subclasses.
  A caller with another argument count raises ArgumentError before the body runs. A name nothing calls holds
  vacuously. Anything else is TC1013 at the call site's file:line. Dropping is iterated to a fixed point, because
  a caller's own parameter only proves an argument while it is kept.
* A build aborts on either error, like any unusable signature. The type check reports them, and never trusts
  the dropped parameter.

TC1013 and TC1014 are new codes. The record-types branch (ADR 0454) owns TC1009.

**Declarations.**
* `sig/bc2cpp/singleton_optional.rbs`:
  * `Game::Message.scan -> ScanResult`;
  * `.parse -> Array[Segment]`;
  * `ScanResult @segments / @pauses` as `T?`;
  * `Combatant @actions: Array[Game::EnemyAction]?`;
  * the checked parameters `Game::Enemy#reseed_rewards(Game::Enemy)` and
    `Scene::Battle#battle_encounter_lines(Game::Troop, untyped)`.
* The existing parameter declarations the check cannot prove are now `untyped`:
  * every `initialize` (POLY);
  * Interpreter#execute (POLY) and the 33 `do_*` / helper methods whose only caller passes execute's `cmd`;
  * #range (an outside-world name);
  * the Vehicle / Picture helpers (arguments from `@vehicles[type]` and elements);
  * `promote_to_leader`;
  * `weapon_attack_multiplier`;
  * `LCF::Array2D#[]=` (POLY).
* The ivars those `initialize` parameters fed are declared `T?` in `sig/bc2cpp/nilable_ivars.rbs`, each checked
  against every writer and construction site:
  * `@state` of the Interpreter, EnemyAi and eleven scenes;
  * `@db`;
  * `@party`;
  * `Game::Map@unit`;
  * Scene::Base `@parent` / `@db` / `@map_tree`;
  * `Scene::Battle@map`;
  * `MapWorld` / `VehicleWorld` `@scene` / `@rng`.

## Consequences

The measurement is the shipped wio pass, against master f256da4f. Comment lines are excluded.

| | master | this change |
| --- | --- | --- |
| `bc2cpp_send(` | 1824 | 1838 |
| `mrb_funcall*(` | 384 | 383 |
| `STRICT_HINT_SITE` | 34 | 20 |
| receiver-fact comment markers | 1303 | 1292 |

* The strict rule costs receiver facts. It is a net loss: about 90 typed accessor sites, mostly
  `LCF::EventCommand` in the Interpreter's `do_*` bodies (41 → 4) and the Vehicle / Picture helpers.
* The `T?` ivars restore nearly all of the `Game::State` facts (426 → 421). They are seeded after the ClassLayout
  fixed point (as every ivar signature is), so facts ClassLayout used to derive *from* a parameter inside
  `initialize` are not restored (for example Scene::Map#initialize's `state.map`).
* Seeding signature ivars into the fixed point itself would recover them. That is follow-up work, because it
  changes every existing ivar signature.
* The new declarations add a few facts: Segment#@text in Message.expand and Game::Enemy#@name in
  battle_encounter_lines. The second is a new forced site, audited and listed.
* Where a declaration could not be proven, the system no longer depends on an unchecked claim. A wrong
  parameter class is now a build error at the caller, not a strict-hint abort at run time.
* Follow-ups that would let more declarations pass:
  * constructor-site checking for `initialize` (the allocated class of each `.new`);
  * arity-disambiguated POLY names (`execute` has 1 and 3 parameters);
  * accepting ivars whose every writer is checked.
