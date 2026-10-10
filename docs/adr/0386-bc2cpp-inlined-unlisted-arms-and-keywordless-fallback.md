# 0386. bc2cpp resolves unlisted-class arms in inlined block bodies, and closes the keyword-less embedding guard

Date: 2026-10-10

## Status

Accepted

## Context

A census of the remaining by-name `bc2cpp_send` sites of the shipped wio pass (2,032 on origin/master 5ddf1d98)
looked at two groups that were believed to be over-wide candidate sets or unproven class constants.

**RGSS native exact-class else (89 sites).** The hypothesis was that the else arm exists because a class
constant (`Bitmap`, `Sprite`, `Viewport`) might have been reassigned. It does not: the constant guard of every
native `Klass.new` is already omitted (CLOSED_WORLD_STABLE_CLASS) or turned into a GUARD_VIOLATION arm (ADR
0290). The 89 sites are three other things:

| Count | Guard | Meaning |
|---:|---|---|
| 39 | `mrb_integer_p(arg)` of `Bitmap.new(w, h)` | the argument-tag test (ADR 0318 / 0372); about 20 of the 39 are the file-load form `Bitmap.new(path_string, flag)`, whose first argument is a `mrb_ensure_string_type` result, so the direct arm can never fire and the by-name `Class#new` is the real path |
| 50 | `mrb_obj_class(M, recv) == rgss::native_bitmap_class()` (30) / `native_sprite_class()` (14), `bc2cpp_native_class == native_viewport_class()` (6) | an exact class test of an instance held in an ivar or upvar (`@contents.blt`, `@sprite.update`), not of a constant |

Dropping either else needs argument-class or ivar-class facts, never constant stability, so this change leaves
them alone and records the finding.

**Known-class arm still by name (35 sites).** `IVAR_ACCESSOR/ELEMENT :actor` on an `Array<Combatant>` element
ended in an `owner_class == RPG2k::Scene::EquipMenu` arm that was a by-name send. The arm is not an
impossible candidate: it is the ADR 0252 unlisted-class branch for a *private* `EquipMenu#actor`, and ADR 0297
already turns such an arm into the NoMethodError `OP_SEND` raises. ADR 0297 records the residual: "30 private
explicit-receiver arms inside inlined block bodies, whose site instruction the code generator does not carry
(`idx` is nil there), and 5 of a name mentioned by `private :x`". Inlined `each` bodies pass `idx: nil` and
carry the unshifted site in `trace_idx`, so `closed_world_site` built a site without the instruction and
`unlisted_class_call` kept the dispatch.

**Owner-chain default else (11 sites).** Seven of them are the else of KEYWORDLESS_CALL's embedding-owner guard
(`actor.add_state(id)` to `Game::Actor#add_state(id, ...keywords)`), which was always
`dynamic_dispatch_line`, while the identical MONO_EMBED_GUARD guard ends in `guarded_fallback_line`.

## Decision

1. `closed_world_site` takes `trace_idx:` and records `site[:trace_insn]`, the original instruction at that
   index of the same irep, only when the send has no `idx` of its own. `unlisted_class_call` reads
   `site[:insn] || site[:trace_insn]` (`unlisted_site_insn`). Nothing else reads `trace_insn`: the flow-based
   consumers (`refined_receiver_instances`, `receiver_instances`, `nil_may_answer?`) key on `site[:insn]`/
   `site[:idx]` and keep seeing nil for a shifted body, so no other proof changes. Both consumers in
   `codegen_unlisted_class_call.rb` still require the instruction's symbol to equal the name being compiled and
   `self_owner` to be nil for the explicit-receiver private error, so a synthetic send (an inlined loop's own
   `each`, a typed `[]` fallback) never borrows a neighbour's opcode. Wired at the four guarded-fallback sites
   of `compile_send` (TYPED, MONO_EMBED_GUARD, IVAR_ACCESSOR/ELEMENT, the POLY chain). Kill switch
   `BC2CPP_INLINED_UNLISTED=0`.
2. KEYWORDLESS_CALL's embedding-owner guard ends in `guarded_fallback_line(d, recv, name, argv, [target.owner],
   site)`: the call is an ordinary send of `name` with `argv` (no keyword pairs), so the closed world's proven
   chain (nomethod, unlisted-class arms) is as valid as for MONO_EMBED_GUARD, and a chain it cannot prove keeps
   the same dispatch. Kill switch `BC2CPP_KEYWORDLESS_FALLBACK=0`.

Soundness arguments: (1) the VM raises `vis_error` for a private method found by an explicit-receiver
`OP_SEND` whatever the receiver value, and the arm is reached only when `mrb_obj_class(recv)` is exactly the
unlisted class, whose own lookup (ADR 0297: stable class constant, `exact_chain_lookup_safe?`,
`visibility_stable?`) finds the private def. The inlined body is the block's own bytecode, so its `SEND` is the
instruction the VM would execute. (2) `guarded_fallback_line` already proves, per site, that no class outside
`listed` answers `name` (refusal reasons are counted and kept as `CLOSED_WORLD kept: <reason>`); the keywordless
call is such a send.

Refused, not done: the remaining 8 known-class arms are of names mentioned by `private :x`/`public :x`
(`load_face_bitmap` is made public by `public ... :load_face_bitmap` in `Scene::Map`; `terrain_id`, `dead?`
likewise), which `visibility_stable?` refuses globally by design; a per-class visibility proof would be a
separate decision.

## Consequences

- Shipped wio pass: `bc2cpp_send(` 2,032 -> 1,998 (-34): known-class arm still by name 35 -> 8 (-27: 17 `actor`,
  6 `party`, 4 `skills`), owner-chain default else 11 -> 4 (-7). `mrb_funcall*` unchanged.
- Seven new `NOMETHOD_REVIEWED` keys (`Game::Party#cast_skill -> add_state`/`remove_state`,
  `Game::Party#use_medicine -> remove_state`, `Game::Interpreter#do_change_condition -> add_state`,
  `Game::State.singleton#from_lsd -> set_level`, `Game::EnemyAi#skill_command -> battle_skill_command`,
  `Game::Battle#swing -> deal_attack`): each is the else arm of a guard on the only definer of the name, with
  a receiver that is an actor/party/battle held in a variable, so a miss is the nil dereference the runtime
  already rescues.
- A private method called through an inlined block body now raises like the interpreter; before, the
  unchecked by-name call (CHECKED_SEND needs `idx`) answered.
- `scripts/bc2cpp_unlisted_class_call_check.rb` gains an inlined `each` fixture (positive, protected stays
  by name, kill switch, interpreted-vs-compiled, mutant); `scripts/bc2cpp_receiver_typing_check.rb` pins the
  keywordless fallback (closed, kill switch, method_missing refusal).
