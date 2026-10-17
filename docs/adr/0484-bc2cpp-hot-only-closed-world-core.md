# 0484. bc2cpp: a hot-only build keeps mruby's core Ruby in the closed world

Date: 2026-10-17

## Status

Accepted. Amends ADR 0214 (the closed-world source set of a hot-only build).

## Context

ADR 0214 makes hot-only a choice of what is compiled. Its own argument is that an excluded method still defines its
name, so the closed world (ADR 0210) proves the same things with or without the exclusion.

`bc2cpp_closed_world_srcs` did not follow that for mruby's core Ruby: a hot-only build passed `core_gems = nil`, so
`3rd/mruby/mrblib/*.rb` and the core gems' mrblib were not in the world at all. A closed build (hot-only by
build_config.rb) therefore did not know mruby's `Array#each` (`3rd/mruby/mrblib/array.rb`). Every proof that names a
core definition failed for it, e.g. the guarded block loop of ADR 0420 for `ids.each` in `Game::Party#initialize`.
The fixture worlds, which are not hot-only, did see it.

## Decision

The closed-world sources of every build include the core mrblib of the gems the build has. Compilation is still
limited by the hot list (`HotMethods.excluded_labels` and `core_hidden_defs` in bc2cpp.rb): a core method outside the
list is registered for the proofs and emitted as the interpreter's bytecode, as every other excluded method is.

## Consequences

- Proofs that name a core Ruby definition (MONO/POLY resolution, the block-core arms of ADR 0270, the guarded loops of
  ADR 0420, ADR 0483's source check) see mruby's own definitions in a hot-only build too.
- A hot-only build's generated code can change where a proof now sees a core definition. That is what the CI
  bc2cpp checks are for; the flash builds (psp, wio, maix) use the same source set and are checked by the same jobs.
- No method is compiled that the hot list does not name. The hot list check (`hot_only_check`) still applies.
