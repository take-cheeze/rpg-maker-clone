# 258. bc2cpp resolves module-singleton self, keywordless and accessor calls

Date: 2026-09-30

## Status

Accepted

## Context

After ADR 0254-0256 the shipped wio closed-world build (all three compiled
gems, `SKIP_UNSUPPORTED=1`, `scripts/bc2cpp_coverage_report.rb`) still had 467
generic dispatch sites: 283 `dynamic_single_registered_definition`, 109
`dynamic_no_complete_candidate_set`, 74 `dynamic_no_registered_definition` and
1 runtime-definition guard. Reading every site's enclosing method, name and
definitions (a temporary `POLY_DIAG` suffix, not kept) showed that most of the
single-definition bucket is not a receiver-typing problem: most of its 283
sites name a core native (`min`, `inspect`, `raise`, `read`, ...), where even
a proven receiver class has no `_impl` to call. The sites with a compiled Ruby target
that could still become direct calls were blocked for four separate reasons:

- Implicit-self calls in `def self.x` of a module (33 sites: `term`, `row`,
  `int_field`, `action`, `active?`, `compare`). SINGLETON_LEXICAL_SELF (ADR
  0207) covers a module, but `exact_receiver_class?` asks `ClosedWorld#exact_class?`
  under a closed world, and that answers only for a declared class: a module is
  never in `class_decls`, so the fact was lost exactly when the closed world was
  switched on.
- Calls without keywords to a method whose parameters include keywords (26
  sites: `set_level`, `add_state`, `remove_state`, `perform_teleport`,
  `open_message`, `build_parallels`, `build_events`, `step_events`, ...). The
  callee has one definition, but `pure_mandatory_or_optional_arity?` rejects any
  method with a KEY field, so the ordinary MONO path declined and the site
  dispatched. Only a call that passes keywords reached `compile_keyword_call`.
- Constant-object calls to a `module_function` copy whose body has a block or
  reads `self` (13 sites: `LCF.write_ber`, `read_ber`, `to_rb`, `read_section`,
  `encode`, `encode_event_commands`). ADR 0235 refused any use of `self`, but ADR
  0241 already passes the module object as `self` to that same shared body for
  its own bare calls.
- Constant-object calls to a singleton `attr_reader`/`attr_writer` (10 sites:
  `RGSS.asset_archive`, `RGSS::Bitmap.extensions=`, `RGSS::Graphics.frame_rate`).
  The constant-object path only handled a def with an irep.

The other unresolved origins (send results, incoming registers, captured
upvars, indexed results) are almost entirely core natives, and the poisoned
ivar/element facts are dominated by Integer/String/Boolean ivars whose class
never decides a dispatch; neither was changed.

## Decision

**MODULE_SINGLETON_SELF.** `build_registry` now also returns its declared module
names; `ClosedWorld` takes them (`module_names:`, default empty) and answers
`module_declared?`. `lexical_self_singleton_owner(owner_def, name:)` accepts a
module base when `ClosedWorld#inherited_lookup_safe?(name, base)` holds: the
module constant is stable (not rebound, and no outside file that could reopen
or natively define it, `stable_class_constant?`) and no by-name installer or
outside definer of `name` exists. A module has no subclass and its singleton's
own definitions win lookup, so `self` in `def self.x` is that module and the
existing one-definition/no-prepend/no-unknown-mixin rules of ADR 0207 apply
unchanged.

**KEYWORDLESS_CALL.** `compile_keywordless_call` (codegen_keyword_send.rb), tried
before the ordinary MONO decision in `compile_send`, sends a call with no
keyword pairs to `compile_keyword_call` with an empty keyword list when the
name's one definition (MONO, or the lexical-self keyword target) has keyword
parameters and the ordinary path cannot take it. Every keyword is then "not
passed" (`given = 0`), which is what OP_ENTER sees for a call without keywords;
a required keyword, a positional count outside `[mand, mand + opt]`, or an
optional-argument table without resolved jump targets keeps the dispatch (the
interpreter raises ArgumentError, or the callee has no direct entry). An
explicit receiver never reaches a non-public target. An owner that embeds ivars
keeps a runtime class guard with a dynamic fallback, unless `self` is exactly
that owner with no subclass (`exact_class?`), the same rule as MONO_EMBED_GUARD.

**MODULE_FUNCTION_COPY.** The constant-object call to a `module_function` copy
no longer requires the shared body to be free of blocks. It
requires that the body, including nested blocks, contains no `GETIV`, `SETIV`,
`GETCV`, `SETCV`, `SUPER` or `ARGARY` (state or hierarchy tied to a class's
instances) and that the module owner embeds no ivars. A body that reads `self` (R0) is still refused, as in ADR 0259, which owns this
rule together with the constant-object arms (`codegen_constant_object.rb`).

**CONSTANT_OBJECT_ACCESSOR.** A stable module constant whose singleton has one
public `attr_*` definition with the right arity compiles to `mrb_iv_get` /
`mrb_iv_set` of the module object through `ivar_accessor_call_code` (the
IVAR_ACCESSOR_DEVIRT lowering), under the constant-object path's existing
mixin, blocked-name and identity conditions.

`scripts/bc2cpp_receiver_typing_check.rb` pins each rule and each refusal on
fixtures (prepend onto the singleton, duplicate definition, outside definer,
`define_singleton_method`, required keyword, explicit receiver to a private
method, embedding owner, two definitions, ivar state in a copy, second accessor
definition), then compiles a fixture against real mruby and checks every
answer against the interpreter's with zero dynamic dispatches. It runs in the
`fast` shard of `bc2cpp-checks`. `NOMETHOD_REVIEWED` lost three keys
(`Scene::Map#drive_message`, `#drive_number_input`, `#drive_text_message` ->
`close_message`, now direct calls); none was added.

## Consequences

Generic sites 467 -> 391: `dynamic_single_registered_definition` 283 -> 257,
`dynamic_no_complete_candidate_set` 109 -> 59, `implicit_self_unresolved`
129 -> 77, `constant_lookup` origins 63 -> 45, `owner_not_emitted` exclusions
13 -> 0. The semantic diff of the generated wio output (digit-masked line
multiset) adds only `MONO`, `LEXICAL_SELF` and `CLOSED_WORLD_CONSTANT_OBJECT`
lines and removes the dispatches they replace.

What remains in the single-definition bucket is core natives (no `_impl`), Ruby
methods with a rest, keyword-rest or block parameter (`move_picture`,
`Array#sort`), uncompiled bodies, and explicit-receiver calls to private
methods. Resolving those needs new callee shapes or native call tables, not a
better receiver fact.

Risk. MONO for a keyword callee inherits MONO's trust that a name with one
program-wide definition reaches that definition (a receiver answering through
`method_missing` is the known hole, guarded only for embedding owners).
MODULE_SINGLETON_SELF and MODULE_FUNCTION_COPY assume no `Module#clone`d module
runs a singleton body with another `self`; a clone copies the singleton's method
table, so the name resolves to the same definition either way.
