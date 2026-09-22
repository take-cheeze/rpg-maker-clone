# 0186. Guard MONO devirtualized calls into ivar-embedding classes

Date: 2026-09-22

## Status

Accepted

## Context

`monomorphic_target(name)` proves a MONO devirtualization target by counting
`@registry[name]` -- exactly one *compiled bytecode* definition of that bare
name anywhere in the whole program. Once found, `compile_send`'s plain MONO
branch called `impl` directly on whatever the call site's receiver expression
evaluated to, with **no runtime check that the receiver is actually an
instance of `target.owner`**.

That is unsound whenever some other class answers the same bare name only
through `method_missing` -- `LCF::Array1D`/`Sections`
(`mruby-lcf/mrblib/lcf.rb`), which dispatch a database row's schema-field
accessors this way. `method_missing` never installs a method under that name
on any class, so it adds no entry to `@registry` and is invisible to the
"exactly one compiled definition" count. Calling the wrong receiver through
an unguarded direct C++ call was already wrong for an ordinary (non-embedding)
class -- a stray read/write against the wrong object's own `iv_tbl` entry,
memory-safe if semantically incorrect. It is no longer merely wrong once
`target.owner` embeds any ivar as a real struct field: GETIV/SETIV for an
embedded field cast `DATA_PTR(self)` (`RDATA(self)->data`) unconditionally,
and a receiver that was never proven to be that owner (an ordinary `RObject`,
not an `RData` of the matching shape) turns that into a real out-of-bounds /
type-confused read.

Found live, not hypothetically: `@db_row.faceset_index` inside
`Game::Actor#faceset_index` targets `Game::Actor#faceset_index` itself via
MONO (the bare name has exactly one compiled definition program-wide), even
though `@db_row` is an `Array1D` row answering through `method_missing` --
reproduced under gdb, a real crash. The same shape already exists on a class
this project ships with **today**: `Game::ChipSet#terrain` is a real `def`
(not an `attr_reader`, so it stays a single, true MONO definition rather than
going through the two-entry `attr_reader`-override path
`drop_unsafe_embeddings`'s own `ATTR_STRUCT_DEVIRT` machinery already makes
POLY), and `RPG2k::Scene::Map`'s own tile lookup calls `chip_set.terrain(id)`
where `chip_set` is traced from `Game::Map#lower`. `Game::ChipSet@animation_
type`/`@animation_speed` are `attr_reader`-declared and therefore already
POLY_SMALL_N-guarded by that separate, pre-existing mechanism -- confirming
the vulnerable shape is specifically a *real, hand-written* method on an
embedding class whose bare name is otherwise unique program-wide, not every
embedded accessor.

## Decision

`compile_send`'s MONO branch now checks `@ivar_layout.key?(target.owner)` --
is `target.owner` an embedding class at all (the same "safe, final" ivar
layout `embed_type`/`embedding_classes` already read from). If so, emit the
same guard-plus-`mrb_funcall`-fallback shape the `typed` branch already uses,
tagged `MONO_EMBED_GUARD` in the generated comment. A wrong receiver falls
through to ordinary dynamic dispatch (correctly reaching `method_missing`)
instead of dereferencing `DATA_PTR` on an object that was never that owner.

This is deliberately per-*owner*, not per-*method*: precisely proving "this
compiled body never reaches a `DATA_PTR` dereference, even transitively
through a helper it calls" is a materially deeper reachability question than
this gate is willing to get wrong in the unsafe direction, and it costs one
`mrb_obj_class` compare on top of an already-devirtualized call -- the same
price the file already pays everywhere else a receiver is not proven exactly.
A MONO call into a class with no embedded ivars is untouched (its own GETIV/
SETIV never reaches `DATA_PTR` regardless of the real receiver, so the
existing unguarded fast path stays exactly as fast as before).

Considered and rejected: making `Game::Actor#initialize`/`#faceset_index`
usable by fixing this one call site only, or by trying to detect a
`method_missing` collision specifically (undetectable in general -- a real
`method_missing` never adds a registry entry to compare against, by
definition). Also considered: eagerly allocating the embedded struct at the
top of every compiled `#initialize`, matching ordinary Ruby's "unset ivar
reads nil" semantics instead of guarding call sites -- rejected for this
round because it does not address the underlying issue at all: this whole
hazard is triggered by a call whose receiver **is not the owner in the first
place** (a different, unrelated object), so no amount of `#initialize`-side
initialization for the real owner changes what happens when a wrong-typed
`self` reaches the accessor.

`Game::Actor` itself is **not** added to `BC2CPP_WIRED_EMBEDDINGS` by this
change. `scripts/bc2cpp_wired_embedding_check.rb` (a separate, pre-existing
invariant) already refuses it for an independent reason: 44 of its 124
compiled entry points -- including `#initialize` itself -- are not installed
by `mruby-rpg2k-compiled/src/register.cxx`, so real construction never runs
the compiled `#initialize` that would allocate the embedded struct at all
(every other embedded field crashes the same way, calling on a `self` that
was never even given real backing storage, independent of this ADR's own
fix). Making `Game::Actor` safe to embed needs that separate registration gap
closed too (`emit_owner_registrations`-shaped generation of every entry point,
not this file's own scope) before it can be added.

## Consequences

Every current and future embedding class is now protected against a MONO
call mistargeting it from an unrelated, `method_missing`-answering (or any
other registry-invisible) receiver, closing a real, already-shipping hazard
on `Game::ChipSet#terrain` as well as the specific `Game::Actor` shape this
was found investigating. The cost is one extra class-pointer compare on a
MONO call whose target owns embedded ivars -- unmeasured here, expected to be
negligible next to the direct-call win MONO already provides over
`mrb_funcall`. `scripts/bc2cpp_mono_embed_guard_check.rb` covers both the
guarded (embedding target) and unguarded (plain, non-embedding target) shapes
so a regression in either direction fails loudly.
