# 80. WOLF RPG Editor Teleport(130): the hero-target case

Date: 2026-09-07

## Status

Accepted

## Context

`Teleport`(130), WolfTL's own name, is help/04ev_movepos.html's own "場所移
動" command: "プレイヤーキャラクター（主人公）やイベントの場所移動を行いま
す" -- moves either the hero or an arbitrary event to a new map/position. Its
own `target` field (arg(0)) reuses the exact convention `SetMoveRoute`(201)/
`SetVariableEx`(124) already cross-confirmed and implemented (`>=0` an event
id, `-1` this event -- "コモンなら呼び出し元イベント", the calling event for
a Common Event -- `-2` the hero, `-3..-7` a party member). The wolfrpg-map-
parser crate's own `TransferCommand` (`transfer_command.rs`) maps its
`target`/`destination_x`/`destination_y`/`destination_map`/`options` fields
directly onto this reader's `arg(N)` framing, matching every one of the 5
real calls' own 5-argument shape -- but the crate's own `Target` enum names
the `-1` sentinel (`0xffffffff` as an unsigned u32) "Hero" instead of "this
event," directly contradicting the manual's own unambiguous documentation
and this reader's own already-cross-confirmed reading of the identical
convention everywhere else it appears. The manual is trusted here.

All 5 real calls (every one on a map-event page, none in Common Events) use
target `-1` -- an event relocating *itself* to a new map, not the hero. This
reader cannot support that: `#event_position` only tracks a map event's
runtime position for the *currently loaded* map's own event list, and there
is no persistent per-map event state across a map change at all -- every
`Project#map(id)` call re-parses that map's file from scratch, with no
memory of a prior visit (switches, variables and moved/erased events on a
map the hero has left and returned to would all reset). That gap is well
beyond Teleport itself and not attempted here.

Only `target == -2` (the hero) is implemented -- covering none of this
specific sample game's own real calls, but the semantic most real WOLF
games actually use this command for (a door or staircase moving the
player). `options` (arg(4))'s low bit, the crate's own `precise_coordinates`,
is 0 in every real call and left unimplemented (no confirmed half-tile
conversion formula, unlike `SetVariableEx`'s own documented `PreciseX`/`Y`
one); its own transition kind (bits 4-7, the crate's own `Transition` --
none/no-fade/fade) is not modeled at all -- like every other instant scene
change this reader already makes (`Picture`(150)'s own Show/Move), a
teleport snaps immediately regardless of which transition was configured.

Actually swapping the running map required new architecture: `Wolf::
Interpreter` has no rendering code of its own and only ever reaches into
`#current_scene` for one `WolfRPG::MapScene`'s own operations (show/move a
picture, tint it, ...) -- but a teleport replaces the *entire* scene
(tileset, map bitmap, every event sprite, both viewports), something only
the top-level `WolfRPG` object that owns `@scene`'s own lifetime can safely
do, and not mid-frame while other Common Events may still be running.

## Decision

- `Wolf::Interpreter#exec_teleport` resolves and validates the request
  (gating on the 5-argument shape, `target == -2`, and a clear
  `precise_coordinates` bit), then records it as `[map_id, x, y]` on a new
  `#pending_teleport` accessor rather than acting immediately.
- `WolfRPG#main_loop` checks `@interpreter.pending_teleport` once per frame,
  right after `@interpreter.update` finishes (so every Common Event this
  frame has already run) and before `@scene.update`, consuming it via a new
  `#teleport_to(map_id, x, y)`.
- `#teleport_to` builds the new scene first (via a `#load_scene` extracted
  from the pre-existing `#build_start_scene`, shared by both), only
  disposing the *old* `MapScene` once the new one has actually loaded --
  never disposing `@scene` itself, since a failed `#load_scene` (an invalid
  map id, a bad tileset, ...) leaves it as the still-active running scene.
- A new `MapScene#dispose` releases every native sprite/bitmap/viewport it
  owns (mirroring `mruby-rpgxp`'s own established dispose-before-replace
  pattern for its weather/animation sprites), so a teleport does not leak
  them.

## Consequences

- A hero-targeted `Teleport`(130) call now actually changes the running
  map -- verified via the CRuby unit harness (`#exec_teleport`'s own
  request-resolution logic, including the real 5-argument/target-(-1)/
  precise-coordinates skip paths) and `ctest -R mruby_test` (crash count
  held at the pre-existing 19-crash baseline). The actual native scene
  rebuild (`WolfRPG#teleport_to`/`#load_scene`/`MapScene#dispose`, and the
  real `Viewport`/`Sprite`/`Bitmap` disposal/re-creation calls it makes) is
  **not exercised by this specific sample game's own real data at all**,
  since every one of its 5 real calls uses the still-unimplemented `-1`
  target -- reviewed carefully by hand instead (in particular, that a
  failed `#load_scene` never disposes the still-active `@scene`), the same
  gap ADR 0079 already documented for `ChangeColor`'s own native
  `Viewport#flash`/`#tone=` calls.
- Still unimplemented: every target besides the hero (`-1` this/calling
  event, `-3..-7` party members, an explicit event id -- all needing
  persistent per-map event state this reader does not have at all),
  `precise_coordinates`, and the transition/fade effect.
