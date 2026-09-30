# 259. bc2cpp resolves singleton calls on class constants and argument-count mismatches

Date: 2026-09-30

## Status

Accepted

## Context

After ADRs 0254 to 0256 the shipped wio build's `POLY_DIAG` sites still excluded
definitions for three reasons that a proof can remove. Measured with
`scripts/bc2cpp_coverage_report.rb` on `master`:

- `singleton_owner` (319): a definition on `X.singleton` was never a candidate.
  98 of them sat at dispatching sites. The dispatching ones were an
  implicit-self call in a module's `def self.x` (`term`/`action` in
  `Game::States::BattleText`, `row`/`message`/`int_field` in `Game::States`,
  `Game.clamp`, ...: the closed world refuses a module in `exact_class?`,
  although the non-closed-world SINGLETON_LEXICAL_SELF accepts it), and
  `Const.name` on a stable constant that CLOSED_WORLD_CONSTANT_OBJECT could not
  take: a module_function whose body has a block (`LCF.write_ber`, `read_ber`,
  `read_section`, `to_rb`, `encode`), a singleton with an optional parameter
  (`EventPage.select`, `Graphics.transition`), and `attr_accessor` in
  `class << self` (`RGSS.asset_archive`, `Bitmap.extensions=`,
  `Graphics.frame_rate`).
- `arity` (214) and `unsupported_arity` (19): a definition whose signature does
  not fit the call. Optional parameters were never chain candidates, and a class
  whose definition rejects the argument count got an exact-class arm that
  dispatched just to raise `ArgumentError`.
- `owner_not_emitted` (13) were the instance halves of the LCF module_function
  copies above; `unclean` (7) are `LOADL` bignum pool entries in
  `LCF.pack_double`/`unpack_double` (see the 32-bit `mrb_int` notes in
  `AGENTS.md`) and two definitions with constructs bc2cpp cannot compile.

## Decision

`CodeGen#constant_object_send_code` (codegen_constant_object.rb, extracted from
`compile_send`) resolves `Const.name(args)` when `constant_object_owner` proved
the receiver is that constant:

- Lookup follows mruby's singleton order. `constant_object_singleton_def` visits
  `Const.singleton`, then each superclass's singleton
  (`ClosedWorld#class_parent`: a declared, non-opaque class whose superclass
  expression names exactly one declared class), and stops at the first
  definition. Every singleton class on the way must have no included, prepended
  or unknown mixin, and the definition must be unique and public. A class that
  is opaque, has an unresolved or ambiguous superclass, or is a module without a
  definition ends the walk without a target.
- An irep definition is called directly, with omitted optional parameters padded
  by `direct_call_args`. An `attr_accessor` of `class << self` is a bare
  `mrb_iv_get`/`mrb_iv_set` on the constant (a class object never embeds ivars).
- `module_function_copy_self_safe?` accepts a body with blocks when every nested
  rep is itself free of `GETIV`/`SETIV`/`SUPER` and register 0.

An implicit-self call in `def self.x` of a declared module uses
SINGLETON_LEXICAL_SELF in the closed world too: `ClosedWorld#module_object_self?`
holds for a `MODULE`-declared, stable-identity module. `self` there is the module
object because only `Kernel#clone` copies a module's singleton methods, so a
`clone` spelled in the closed-world bytecode, a `LOADSYM :clone`, an outside Ruby
file or an outside native file's `mrb_obj_clone`/`"clone"` refuses. A singleton
`attr_accessor` is resolved there as well.

STATIC_ARGC_ERROR: when a send provably reaches a definition with a plain
signature (mandatory and optional parameters only) and the argument count is
outside `[mandatory, mandatory + optional]`, the call is replaced by
`mrb_argnum_error(M, n, m, m)`. That is what `OP_ENTER` raises: its message
names the mandatory count alone, even with optional parameters
(`vm.c` `argnum_error`), and the call passes no keyword hash. A callee with a
rest, post, keyword or block parameter keeps dispatch. It applies to constant
receivers, to `self`-resolved singleton and exact-class calls, and to the
UNLISTED_CLASS_GUARDS arms below.

`unlisted_class_call` replaces the dispatch in an UNLISTED_CLASS_GUARDS arm
(receiver class exactly `klass`) when `closed_world_lookup_target` proves the
public definition it reaches: a direct call, or the static `ArgumentError`.
Anything else keeps the dispatching arm.

`poly_candidates(optional: true)` admits definitions with optional parameters to
a POLY_SMALL_N chain (padded through `direct_call_args`, which the callee's
`_impl` requires). The POLY table keeps the exact-arity set, and the chain uses
the wider set only while it stays within `POLY_SMALL_N_MAX`. `poly_diagnostic`
now calls a definition `unsupported_arity` only for a rest/keyword/block
signature and `arity` for a count outside the optional range.

`build_registry` returns the declared module names as a last element, passed to
`ClosedWorld` as `module_names:`.

## Consequences

Measured on the shipped wio closed-world build (`SKIP_UNSUPPORTED=1`, all three
gems), master to this change:

| | before | after |
|---|---|---|
| `bc2cpp_send`/`mrb_funcall_with_block` sites | 10185 | 9976 |
| POLY-marked (generic dispatch) sites | 467 | 404 |
| `POLY_DIAG` sites | 3138 | 3074 |
| excluded `singleton_owner` | 319 | 239 |
| excluded `arity` | 214 | 177 |
| excluded `unsupported_arity` | 19 | 9 |
| excluded `owner_not_emitted` | 13 | 0 |
| excluded `unclean` | 7 | 7 |

The remaining `singleton_owner` exclusions are 221 chain sites and 18 dispatching
ones. The chain sites (`width`, `height`, `name`) belong to unrelated receivers
that native classes also answer, so their fallback stays a dispatch for the
native reason; the 18 are constants of native classes (`File.exist?`,
`Marshal.load`) that an unrelated singleton `exist?`/`load` also names. The
remaining `arity` exclusions are classes whose receiver is unknown, and
`unsupported_arity` is `Array#sort!(&block)` and `write(*args)`.

Generated code gained direct calls (CLOSED_WORLD_CONSTANT_OBJECT 471 to 492,
LEXICAL_SELF 479 to 520, 131 UNLISTED_CLASS_CALL arms, 15 STATIC_ARGC_ERROR
arms) and lost the matching dispatch; nothing else changed. One reviewed key was
added to `NOMETHOD_REVIEWED`, `RPG2k::Scene::Map#drive_text_message -> advance`:
the receiver is always the `Game::TextReveal` that `MessageState#reveal` holds,
and the chain now lists it, so the else is dead.

`scripts/bc2cpp_singleton_arity_check.rb` (bc2cpp-checks `fast` shard) pins every
resolution and every refusal (singleton prepend, unresolved superclass, private
singleton method, rest parameter, `clone`) and compiles the fixture against the
real mruby core, comparing each result and each `ArgumentError` message with the
interpreter's. `scripts/bc2cpp_closed_world_check.rb` now expects the CwPuppy arm
to be a direct call.

Not covered: sends whose receiver class is unknown (a chain fallback for a
singleton definer would need an identity arm on the constant, and the native
definers of the same names would still dispatch), keyword-parameter, rest and
block-parameter callees, and definitions with `LOADL` bignum pool entries.

## Relationship to ADR 0258

ADR 0258 (merged first) added a module-singleton self rule, a module_function
copy rule and a singleton `attr_accessor` arm inline in `compile_send`. This
ADR's extraction (`codegen_constant_object.rb`) is now the single home of the
constant-object arms, and the overlapping rules are unified:

- Module `self` is `ClosedWorld#module_object_self?` (declared module, stable
  identity, no `clone` spelled anywhere) plus 0258's `inherited_lookup_safe?`
  name gate; `module_declared?` is gone.
- A module_function copy is called directly only if its body (blocks included)
  has no ivar, class-variable, `super` or `ARGARY` instruction, never mentions
  self (R0), and the module owner embeds no ivars. That is the union of both
  ADRs' refusals.
- The singleton `attr_accessor` arm is `constant_object_accessor_code`; 0258's
  inline copy was dropped.
