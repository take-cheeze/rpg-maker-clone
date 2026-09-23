# 0206. bc2cpp reads attr_*/visibility/module_function names from packed calls

Date: 2026-09-23

## Status

Accepted

## Context

`build_registry` learns the names an `attr_reader`/`attr_writer`/
`attr_accessor`, `private`/`protected`/`public` or `module_function` call
defines by walking back over the `LOADSYM`s before the send, counting them from
its `n=<count>`. mrbc packs a call with 15 or more arguments into one `ARRAY`
and prints the send as `n=*` (`CALL_MAXARGS`). The count then parsed as 0, and
every name was dropped without a trace.

Two calls in the closed world are packed: `Game::Enemy`'s 15-name
`attr_reader` (`battle_support.rb`) and a 16-name `module_function` in
`lcf.rb`. The first was not a harmless miss. With its readers unknown,
`drop_unsafe_embeddings` saw no native accessor for `@max_hp`, `@atk`, `@def`,
`@spi`, `@agi`, `@gold`, `@x` or `@y`, embedded them, and synthesized no
accessor to replace mruby's native `attr_reader`, which reads `iv_tbl`. Every
enemy then reported nil stats, and every RPGMAKER_BC2CPP battle ended in
`undefined method '+' for NilClass` inside `Game::Battle#modified_stat`.

## Decision

When the send is `n=*` and the instruction before it is `ARRAY Rk N`, read the
`N` `LOADSYM`s before the `ARRAY`. Any other packed shape is a real splat
(`attr_reader(*NAMES)`), whose names are not known statically; that now raises
instead of being ignored. There is none in the closed world today.

## Consequences

The registry sees every `Game::Enemy` reader. Eight struct accessors are
synthesized and registered for it (`max_hp`, `max_sp`, `atk`, `def`, `spi`,
`agi`, `x`, `y`; ATTR_STRUCT_DEVIRT 69 -> 77), `@gold` is no longer embedded
(EMBED 223 -> 222), and 23 call sites stop being dynamic (POLY 3268 -> 3245).
Three Array-return proofs are no longer made, because names that gained
registered definitions (the readers and the `lcf.rb` module-function copies)
are not monomorphic any more. The compiled entry points go from 2361 to 2369
with no `#error`.

With this change a real `RPGMAKER_BC2CPP=1` build runs
`--rpg2k_battle_troop=1 --rpg2k_battle_play` to the same result as the
interpreted build. `scripts/bc2cpp_packed_attr_args_check.rb` checks the packed
reader and module function and the refused splat.
