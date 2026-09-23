# 0204. bc2cpp reaches an embedded ivar only through IVAR_ACCESS

Date: 2026-09-23

## Status

Accepted

## Context

An embedded ivar (IvarLayout, `drop_unsafe_embeddings`) lives in the class's
RData struct, not in `iv_tbl`. `mrb_iv_get` on it returns nil, and
`mrb_iv_set` writes to a table that nothing reads. Five emitters produced ivar
access, and each one decided the storage itself. GETIV/SETIV and POLY_SMALL_N
checked for embedding. IVAR_ACCESSOR_DEVIRT and LEXICAL_SELF_IVAR_ACCESSOR did
not check, and always emitted `mrb_iv_get`/`mrb_iv_set`.

The shipped output had 66 such sites, all in `mruby-rpg2k-compiled` (45
IVAR_ACCESSOR, 20 IVAR_ACCESSOR/ELEMENT, 1 LEXICAL_SELF). Examples:

- `Game::Party#gold`, read by `Menu#draw_gold_window`, `StatusMenu#draw_gold`,
  `Shop#max_buy`, the shop and inn gold windows, and `State#to_lsd`.
- `Game::Actor#level`, `#id` and `#class_id`.
- Every `Game::MessageConfig` field, written by the Message Options and
  Change Face commands.
- `Game::Enemy#hidden`, `#levitate` and `#flying_phase`.
- `Game::NumberInput#digits`.
- `Game::State#bgm_looped`, `#encounter_total` and `#save_count` (14 sites).

Two related holes had no instances in the current output:

- A runtime-def or EXEC body (`class << X; def ...`) compiled GETIV against
  `d.owner`'s struct, but in those bodies self is the receiver.
- A subclass method's GETIV used the subclass's own layout, which has no
  struct, for an ivar that its superclass embeds.

## Decision

All ivar access now goes through one helper, IVAR_ACCESS
(`ivar_get_code`/`ivar_set_code`/`ivar_accessor_call_code`). Every emitter
passes it the receiver's class:

- For an ivar that is not embedded, the helper emits `mrb_iv_get`/`mrb_iv_set`.
- When the receiver is self in that class's own body, it accesses the struct
  field directly.
- For a guarded foreign receiver, it calls the synthesized `_impl`/`_eq_impl`
  accessor, if this gem defines it or declares it.
- Otherwise it returns nil. The accessor paths then keep `mrb_funcall`, and
  GETIV/SETIV emit `#error`.

The helper is now the only place that emits `mrb_iv_get`/`mrb_iv_set`, apart
from the internal `__attached__` read.

Inside a runtime-def or EXEC body, `self_class` is nil, and that carries into
nested blocks. If some class embeds the ivar name, GETIV/SETIV there emit
`#error`, and `lexical_self_owner` declines.

`every_accessor_compiles?` now refuses to embed an ivar that a subclass method
also touches.

## Consequences

The 66 sites go to zero. Coverage is unchanged: 2361 entry points, 0 `#error`,
100% of methods compiled. The same 176 ivars in 34 classes stay embedded. Only
those sites changed in the generated code.

`scripts/bc2cpp_embedded_ivar_access_check.rb` runs in the CI `bc2cpp` job and
fails on the previous generator. It has three parts:

- It checks the subclass gate and the unknown-self `#error`.
- It builds and runs a fixture against real mruby. The fixture covers a
  foreign read, a foreign write and a self-implicit read of an embedded
  accessor.
- It generates the three gems and requires zero `iv_tbl` calls on an
  embedded (class, ivar) pair.

Methods mixed in from a module can still read an embedded ivar through
`iv_tbl`. No embedded class has such a module method today.
