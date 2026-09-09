# 121. Remove a dead, shadowed method definition found searching the Ruby scripts themselves

Date: 2026-09-09

## Status

Accepted

## Context

Asked to search the mruby scripts (not just C++/build config) for
omittable patterns. Ruled out the two obvious blind approaches quickly:
"unused methods" has no safe static answer here (ADR 116 already found
real `receiver.send(data_derived_symbol)` dispatch), and grepping for
duplicate `def` names by text alone would flag hundreds of same-named
methods across different classes (`#initialize` alone appears dozens of
times across `game.rb`'s many `Game::*` classes) as false positives.

Instead wrote a small Ripper-based scanner (`Ripper.sexp`, walking
`class`/`module` nodes to track each `def`'s real enclosing scope) to find
a **narrow, mechanically sound** class of dead code: a method defined
*twice* inside the same class body. Ruby class reopening means the second
`def` always wins outright -- there is no ambiguity about whether the
first one might still be reachable via some dynamic-dispatch path
(`send`, `method_missing`, ...), the way "is this method ever called"
is ambiguous in general: once shadowed, the first definition's body is
unreachable by *any* calling convention, string-based dispatch included,
because Ruby's method table has already discarded it. Nothing to guess at
game-data reachability for.

Ran it across every `.rb` file in `mruby-rpg2k`/`mruby-rgss`/`mruby-lcf`'s
`mrblib` (both flagged for methods and, separately, for constants): one
real hit.

## Decision

`mruby-rpg2k/mrblib/scene/map.rb`'s `RPG2k::Scene::Map` defined
`#vehicle_pixel(type)` twice:

- **Line 8315** (removed): reads the vehicle's static x/y straight off
  `Game::Vehicle`, falling back to `#player_pixel` if the vehicle record
  doesn't exist. No interpolation, per its own comment.
- **Line 10510** (kept, the real one): checks `v.placed? &&
  v.map_id == @state.map_id` (nil if the vehicle isn't on the currently
  loaded map at all), and specifically returns the *interpolated*
  `#player_pixel` when the vehicle is the one currently boarded --
  matching what `#draw_vehicles` actually renders.

These aren't identical bodies (a real second look at "vehicle position"
that ended up more complete, likely written without noticing the first
one was already there) -- but that doesn't matter for safety here: since
the class body defines the same name twice, *every* call to
`vehicle_pixel` anywhere in the program, including from
`#animation_target_pixel` sitting right above the dead definition in the
same file, already resolved to the second (kept) one. The first was never
reachable from the moment both definitions existed, regardless of call
site or dispatch mechanism.

### What was verified

- **The scanner's own soundness**: constant-assignment scan (same
  path-tracking approach) found zero duplicates across the same three
  gems -- this codebase is otherwise clean of this bug class.
- **The file re-parses** after the removal (`Ripper.sexp`, no syntax
  error).
- **The only call site's target is unaffected**: `#animation_target_pixel`
  (line 8299, same file) calls `vehicle_pixel(...)`; Ruby method dispatch
  resolves by the class's *current* method table, not by textual
  proximity, so it already invoked the kept (second) definition before
  this change and continues to after it -- removing the dead one changes
  nothing about what runs, only what's compiled.
- A real relink, `env:wio_rgss_boot`, on top of ADR 120's state: **917,648
  -> 917,512**, 136 bytes. Small, as expected for one shadowed method body
  -- reported honestly rather than inflated.

## Consequences

- This is a plain source fix, not a wio-scoped build change: `scene/map.rb`
  is shared, unconditional source for every target (desktop/wasm/psp/wio
  alike), so every one of them gets a byte-for-byte identical, slightly
  smaller, slightly less confusing file -- no `build_config.rb`/
  `mrbgem.rake` wiring needed at all.
- The Ripper-based duplicate-definition scanner used here is a reusable,
  mechanically sound check (unlike "unused methods," it has no dynamic-
  dispatch escape hatch to worry about) -- worth re-running after any large
  merge or refactor of the shared `mrblib` source, not just this once.
