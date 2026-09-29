# 254. bc2cpp resolves calls on `self` by class hierarchy analysis

Date: 2026-09-29

## Status

Accepted

## Context

A call on `self` inside a method of class C can only reach C or one of its
descendants. When C had subclasses, bc2cpp still guarded such a call: an
INHERITED_GUARD / POLY_SMALL_N chain listing every class that answers the name
(plus every subclass inheriting from a listed one), or a MONO_EMBED_GUARD
`class == owner` compare for an embedding owner, each with a dispatching (or,
ADR 0252, `bc2cpp_nomethod`) fallback. CLOSED_WORLD_SELF dropped the guard only
for a class nothing subclasses.

Measured on the shipped wio closed-world build (all three compiled gems,
`SKIP_UNSUPPORTED=1`) with `BC2CPP_CHA_REPORT`
(`scripts/bc2cpp_cha_self_report.rb`) on the parent commit: 3954 self-receiver
sends, 676 of them still dispatching. 3303 were eligible under the rules
below (3274 with one resolution, 29 with overriders), 469 of them dispatching:
232 of 275 MONO_EMBED_GUARD, 194 of 219 INHERITED_GUARD, 43 of 97 POLY_SMALL_N.
The dispatching remainder was `db` (95), `term` (74), `state_field` (18),
`windowskin` (17), `side_of` (13), `state_def` (11) and a tail of `Game::Battle`
methods. The refusals among dispatching sites were modules and singletons (95),
opaque hierarchies (70), core/native names (17) and arity (24).

## Decision

`CodeGen#cha_self_plan(name, n, self_owner, explicit:)` (codegen_ivar_poly.rb)
answers whether every possible receiver of `self.name` resolves it to known
definitions, and `compile_send` emits the result (`CLOSED_WORLD_SELF`, marker
text "class hierarchy analysis") ahead of the POLY chain. The MONO_EMBED_GUARD
branch also takes the unguarded form when the plan's default is its target.

The plan holds when all of these do:

- C is a declared class (`class_declared?`, not a module, not a singleton) that
  is not opaque and has only non-opaque descendants (`ClosedWorld#class_hierarchy`,
  which returns `descendants(C)` including `@wild`); there is no global refusal.
- The name is not installed at runtime (`devirt_blocked_name?`,
  `symbol_installed_names`, `@unknown_defs`, `@outside_names` through
  `inherited_lookup_safe?`), has no `<native>` definition, and no descendant of
  C, nor C itself, can answer through `method_missing`
  (`self_method_missing_free?`).
- C's own lookup (`closed_world_lookup_target(..., self_call: true)`, mruby's
  ancestor order) reaches one definition: an irep def (private allowed for an
  implicit-self call, public only for `self.name`) or an `attr_*` accessor.
- No descendant mixes in, prepends or unknowably mixes in a module that can
  supply the name (`cha_mixin_may_define?`: a module that defines it, has an
  unstable identity, or has such a module in its own mixins).
- Descendants that define the name (overriders) each define it once, no wild
  descendant exists when there is an overrider (its place in the hierarchy is
  unknown), and every descendant's superclass chain to C is resolvable.
  Overriders plus the classes inheriting from them number at most
  `CHA_SELF_GUARDS_MAX` (8).
- Every target (default and overriders) is directly callable: emitted in this
  build or another compiled gem, arity fits, `compiles_clean?` (which is false
  for a HOT_ONLY-excluded def), and an accessor is linkable and not stored
  differently by a descendant.

Emission: no overriders is a direct `_impl` call (or the accessor's ivar code)
with no class compare. With overriders, one exact-class arm per overrider
(the overrider and the descendants whose lookup ends at it, found by walking
each descendant up to C) and a default arm calling C's inherited definition,
so the number of comparisons is bounded by the classes that differ, not by
every class answering the name.

Soundness of dropping the class compare:

- `self` is a kind_of the method's owner: every entry into a compiled method
  comes through dispatch, a guarded or lexical direct call, or `super`. This is
  the fact LEXICAL_SELF and CLOSED_WORLD_SELF already rest on; a body whose
  self is unknown (`@self_class_unknown`) yields no self owner.
- The descendants are enumerable: an opaque class, a class created by
  `Class.new`, a constant rebinding, or a subclass in outside code makes the
  hierarchy refuse; every dynamic mixin or definition is a global refusal or an
  installed/unknown name. An alias or `undef` of the name anywhere refuses.
- Embedded ivars (why MONO_EMBED_GUARD existed): the guard protected a
  `DATA_PTR(self)` cast against a receiver that is not the owner (an
  `Array1D` reached through method_missing). Here the receiver is self, and
  `select_embeddings` (codegen.rb) keeps an embedding class and its sub/superclass
  apart: a subclass instance carries its embedding ancestor's payload (a
  subclass `initialize` must call `super` first, otherwise the ancestor is not
  embedded at all), so the ancestor's struct is the payload of every
  descendant. An accessor is refused when a descendant embeds the ivar the
  accessor's owner keeps in iv_tbl.

## Consequences

- Shipped build: self-receiver `bc2cpp_send` sites 688 to 213, all
  `bc2cpp_send`/`mrb_funcall_with_block` sites 11044 to 10569
  (`scripts/bc2cpp_coverage_report.rb`), `bc2cpp_nomethod(M, self` 331 to 4,
  INHERITED_GUARD markers 268 to 51, CLOSED_WORLD_SELF ("guards dropped") 691
  to 1211. Every eligible dispatching site was converted (469 to 0).
- Generated code changes only by removing guard chains and their fallbacks and
  adding direct calls or overrider chains; the 253 NOMETHOD_REVIEWED keys whose
  fallback vanished were removed with `bc2cpp_nomethod_reviewed_update.rb
  --write`. No new dead fallback appeared (no key was added).
- A few diagnostic-only `POLY_DIAG` lines for `to_lcf` change their excluded
  reason (`unclean` to `unsupported_arity`): the plan calls `compiles_clean?`
  earlier, which reorders when the cycle-guarded probe answers are memoized.
  The chosen candidates are unchanged.
- `BC2CPP_CHA_REPORT=<path>` writes one row per self-receiver send (construct,
  plan or refusal); `scripts/bc2cpp_cha_self_report.rb` aggregates it.
- Not covered: keyword/splat sends on self (compile_keyword_send keeps
  LEXICAL_SELF_KEYWORD only for an exact class), module methods and singleton
  methods (self is any includer), and opaque hierarchies, which another change
  may relax by refining `opaque?`.
