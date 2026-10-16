# 0453. SUBTREE receiver facts dispatched through per-class slot tables

Date: 2026-10-16

## Status

Proposed

## Context

Every receiver-class fact bc2cpp keeps names an EXACT class: ClassLayout's ivar join, `trace_new_target`,
ClassAnnotations, and the RBS ivar, return and parameter types (ADR 0413). When two stores into one ivar disagree,
ClassLayout poisons the ivar to UNKNOWN, even when both classes sit in one small closed hierarchy.
`RPG2k::Scene::Map#@battle` holds either `RPG2k::Scene::Battle.new` or `RPG2k3::Scene::Battle.new`, and the second
class is a subclass of the first. Its sends fall back to the name-wide POLY_SMALL_N chain or to dynamic dispatch.

Two further problems:

- **RBS base-class types were exact hints.** A class type in an RBS signature fed the exact tables: ivar types were
  seeded into ClassLayout, parameter types into ClassAnnotations, and return types into ElementAnnotations'
  `ret_class`. When the named class has subclasses, a subclass receiver fails the TYPED or IVAR_ACCESSOR exact guard.
  Under the default strict-hint tier (ADR 0419/0438) that else arm is `bc2cpp_hint_violation`, which raises
  NoMethodError. A *correct* signature such as `@scene: RPG2k::Scene::Base` would therefore break the program. No
  signature in `sig/` names such a class today, so the bug was latent. `Array[C]` and `Hash[K, C]` element types had
  the same exposure through the `element` family.
- **The RBS loader ignored `class C < S`.** A wrong superclass in a signature went unnoticed.

## Decision

1. **RBS superclass check (TC1016).** `RbsSignatures.load` records each `class C < S`. `apply` (with the build's
   `class_decls`) compares S with the program's superclass of C, read from its CLASS declarations the way
   ClosedWorld#class_parent reads them. A mismatch is a TC1016 error: `type_check.rb` fails, and the build aborts with
   the other RBS errors. Some classes are not checked: a class the program does not declare, a core class it only
   reopens (listed in `sig/native/core_hierarchy.rbs`), and a superclass the program does not name with certainty.

2. **SUBTREE facts** (`tools/bc2cpp/subtree_facts.rb`). A SUBTREE(A) fact means "A or any descendant of A". It is a
   separate table (`CodeGen.subtree_facts`). Only the send devirtualization reads it, and only on a miss of every exact
   fact. Embedding, constructor pools, element facts and ClassLayout's own consumers stay on exact facts. Sources:
   - *Join.* After ClassLayout's fixed point, a poisoned ivar is joined to SUBTREE(A) when four conditions hold:
     - every logged store resolved to a declared class;
     - those classes meet at a nearest common declared ancestor A below Object;
     - A is a `closed_root?`: its hierarchy is known, it is not opaque, it has no wild descendant, it does not derive
       from Module or Class, and it has at least one descendant;
     - the program has no global refusal and no singleton maker.

     NIL_TOLERANT_JOIN carries over: `@x = nil` stores are not in the store log. Ancestry uses the new
     `ClosedWorld#declared_parent`. That method also accepts a superclass written as the full path of a declared
     class, which `class_parent` refuses when the last segment is shared (`RPG2k3::Scene::Battle <
     RPG2k::Scene::Battle`, alongside `Game::Battle`).
   - *RBS.* A class type that names a declared class with descendants is routed to `subtree_ivars`, `subtree_args`
     or `subtree_returns`. It never reaches the exact tables, and it gets a TC1005 note. An element type naming such a
     class gives no element hint. "Has descendants" over-approximates by simple name when a superclass expression is
     not itself a declared path. This routing does not depend on the kill switch, because it fixes the latent bug.

3. **Dispatch** (`tools/bc2cpp/codegen_subtree_dispatch.rb`). The hook sits in `compile_send`, just before the
   name-wide POLY_SMALL_N / POLY_TABLE step. It applies to an explicit-receiver send with no exact class, element hint
   or exact core site. The receiver is traced with `trace_new_target`, fed only the subtree ivar, argument and return
   tables.
   - **Gates.** The site needs the name gates CHA_SELF uses: not runtime-defined, `inherited_lookup_safe?`,
     `visibility_stable?`, not installed, and method_missing free.
   - **Lookup.** `closed_world_lookup_target` resolves the name for every class K in A's subtree. A `<native>`
     definition of the name does not refuse the site. Instead, a K counts as resolved only when every class from K up
     to the definer is declared and untouched by outside sources, so no native body can sit between them.
   - **SUBTREE_DIRECT.** Used when every K resolves to one public definition that CHA_SELF's readiness test accepts.
     The site is one direct call (`cha_call_code`; an attr_* accessor is allowed) behind
     `mrb_obj_is_kind_of(M, recv, A)`.
   - **SUBTREE_TABLE.** Used otherwise. There is one table per root A, shared by every name: a row per subtree class
     (getter and OWNER_CLASS_CACHE slot) and a column per (name, argc) used on it. A cell holds a Ruby `_impl` of
     POLY_TABLE's plain shape (public, exact arity, no unboxed or block parameter, compiles clean, emitted). Any other
     cell is null: native, accessor, arity mismatch, or unresolved. The site does one class→row lookup
     (`bc2cpp_vtbl_lookup`, memoized per table like `bc2cpp_poly_lookup` and cleared with OWNER_CLASS_CACHE), then an
     indexed call. A class outside the rows, or a null cell, takes the else arm. A column that only dropped methods
     used is emitted as nulls.
   - **Else arm.** The else arm is `guarded_fallback_line`. It lists only the classes the site calls directly, so a
     null-cell class that answers the name is unlisted and keeps its dispatch. The strict-hint family `subtree` is in
     `StrictHints::FAMILIES` but not in the default set, so it is forced only when `BC2CPP_STRICT_HINTS` names it (or
     is `all`).
   - **Kill switch.** `BC2CPP_SUBTREE_DISPATCH=0` builds no fact and no table, and its output is byte-identical to
     the build without this ADR. This was verified on the wio shipped pass and in the fixture check.
   - **Debugging.** `BC2CPP_SUBTREE_DEBUG=1` lists the refused and untraced sites on stderr.

## Consequences

- On the wio shipped pass, the join finds one fact: `RPG2k::Scene::Map#@battle (RPG2k::Scene::Battle)`. Most `@battle`
  sends were already devirtualized by MONO and USER_RECEIVER_UNION (ADR 0289), so the new dispatch reaches only the 4
  `owner` sites. Each was a POLY_SMALL_N chain with an INHERITED_GUARD and is now a SUBTREE_DIRECT accessor read
  behind one `mrb_obj_is_kind_of`. The one `start` site is refused (`unsafe_name`: `inherited_lookup_safe?` refuses
  the name). No table is emitted. The real by-name counts do not change (`bc2cpp_send(` 1826, `mrb_funcall*(` 400),
  the default STRICT_HINT_SITE listing is unchanged (34), and the NOMETHOD_REVIEWED state is identical. No current
  signature names a base class, so the RBS source adds nothing yet. What it changes is that writing one is now safe.
  The benefit on this workload is small. The tables exist for hierarchies with real overrides (exercised by the
  fixture).
- `scripts/bc2cpp/subtree_dispatch_check.rb` covers four groups of cases:
  - positives: join, full-path superclass, RBS return, RBS parameter, direct, table;
  - negatives: Class.new hierarchy, Object-rooted stores, kill-switch identity, strict family off by default;
  - the TC1016 error;
  - a full-core run that compares interpreted and compiled results, with zero dispatches at the subtree sites.
- The table's else arm can repeat arms NATIVE_OWNER_MAP adds for classes the table already covers. This is dead
  weight but correct.
- Follow-ups:
  - Join facts through accessor chains and call results. The implicit-self sites are CHA_SELF's.
  - Mark the RBS slots that become subtree facts in TypeCheckRbs' emitted signatures.
