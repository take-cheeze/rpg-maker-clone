# 51. Mid-battle party roster sync: rendering

Date: 2026-08-15

## Status

Accepted

## Context

ADR 0050 fixed the mechanic: `Game::Battle#sync_allies_from_party` re-derives
the fight's real ally roster from the live `Game::Party` at each round
boundary and before every action, so a `Change Party Member` battle event
correctly adds/removes combatants from turn order and targeting. That step
deliberately left the screen untouched: `@battle_ui[:allies]`, the battle
status window, and RPG2003's actor battle sprites (added by the
alternate-battle-screen initiative, ADR 0043/0044-era work, `Scene::Map
#build_actor_sprites`/`#build_actor_sprite`) still showed whoever was in the
party when the fight opened, for the fight's whole duration.

Checked against EasyRPG Player's real source rather than assumed:
`Scene_Battle_Rpg2k::OnPartyChanged(Game_Actor*, bool added)`
(`src/scene_battle_rpg2k.cpp`) builds or tears down that one actor's
`Sprite_Actor` and is called **synchronously**, at the exact moment the party
changes, from `Game_Party::AddActor`/`RemoveActor` (`src/game_party.cpp`) via
`Scene::Find(Scene::Battle)`. This codebase's render layer is event-driven,
not polled — `#refresh_battle_status` already runs reactively at specific
moments (opening the battle, selecting a command, opening the options
window) — but nothing fired when a battle-event page's `Change Party Member`
command actually mutated the party mid-fight, so the render layer had no
signal that anything had happened at all.

## Decision

- `Interpreter` gains `attr_accessor :battle_screen`, set on `@battle_ui
  [:events]` in `Scene::Map#open_battle` right alongside the existing
  `@battle_ui[:events].battle = @battle_ui[:battle]` — the same kind of
  reference `.battle` already gives a battle-event page's interpreter back
  into the fight's own domain object, just one level up, into the screen
  that owns it. `@battle_ui[:events]` is the only interpreter that ever runs
  commands while `@battle_ui` exists (the foreground/parallel interpreters
  are held off by `event_busy?`/`parallels_paused?` for as long as a battle
  is open), so this is never set on any other interpreter, and reads nil
  (a no-op) everywhere but a running battle-event page — the same scope
  `.battle` already has.
- `Interpreter#do_change_party` detects a genuine membership flip (comparing
  `party.include_actor?` before/after — `#add_actor`/`#remove_actor` both
  silently no-op on a full party, an unknown roster id, or a redundant
  add/remove) and calls `@battle_screen.on_battle_party_changed(actor,
  added)`, mirroring EasyRPG's `Game_Party::AddActor`/`RemoveActor` calling
  `OnPartyChanged` at the exact point of mutation, not on some later poll.
- `Scene::Map#on_battle_party_changed` builds (`#add_battle_actor_sprite`) or
  disposes (`#remove_battle_actor_sprite`) that one actor's sprite, updates
  `@battle_ui[:allies]`, and calls `#refresh_battle_status` immediately —
  covering both the plain text status rows and, since `#refresh_battle_status`
  already dispatches on `#gauge_battle_layout?`, the RPG2003 gauge card too,
  with no separate code path needed.
- `Game::Battle`'s own roster (`@battle_ui[:battle].allies`) is never
  written to by the removal path, and `Game::Battle.new` is now handed
  `allies.dup` rather than the same array `@battle_ui[:allies]` holds. Ruby
  arrays are mutable objects — without the dup, deleting a departed member
  from the render-facing array (so their sprite/status row actually
  disappears) would delete it from `Game::Battle`'s own bookkeeping array
  too, and the *next* `#sync_allies_from_party` call would no longer find
  their existing `Combatant` on a rejoin, silently rebuilding a fresh one
  and losing the accumulated battle-only state ADR 0050 specifically set out
  to preserve. The two arrays start with the same `Combatant` *objects* (a
  lookup through either one sees the same battle-only state) but are free to
  diverge in which objects they each hold. The one exception is a genuinely
  new participant: `#add_battle_actor_sprite` pushes their fresh `Combatant`
  onto `@battle_ui[:battle].allies` too (mirroring the exact line
  `#sync_allies_from_party` would run on its own next call), so the
  mechanics and the screen are never tracking two different `Combatant`
  objects for the same actor.
- Every actor sprite's Z is re-derived from its current index in
  `@battle_ui[:allies]` (`#reset_actor_battler_z`, using the existing
  `#actor_sprite_z(i) = 200 + i` formula unchanged) after every add and
  remove, not just assigned once for the newly (dis)appearing sprite. An add
  or remove elsewhere in the roster shifts every later member's index, and
  without a full recompute, a survivor can be left at a stale Z that a later
  insertion recomputes independently — e.g. removing index 1 of 3 leaves
  index 2's sprite at its old Z (202); adding a new member back in at the
  new index 2 would then compute the same Z 202, and the two sprites would
  collide. Matches EasyRPG's own `ResetAllBattlerZ()`, called for the same
  reason right after `OnPartyChanged` adds a sprite.

## Consequences

The battle screen now matches the roster `Game::Battle` has been playing
against since ADR 0050: a member added mid-fight gets their sprite and status
row the instant the `Change Party Member` command runs, not on some later
incidental redraw; a member removed mid-fight has their own sprite disposed
and their row dropped, with every other member's sprite object left
untouched; and a member who leaves and rejoins the same fight is drawn with a
freshly built sprite (never a disposed-and-reused one) while reusing the
exact same `Combatant` the mechanics already keep for them, so no duplicate
render-side bookkeeping accumulates across repeated swaps within one fight.

`Game::Battle`'s own mechanics (`#sync_allies_from_party`, `#out_of_play?`,
`Combatant#member`) are untouched — this step only consumes the roster state
ADR 0050 already keeps correct.

Covered by six new checks in `scripts/rpg2k_scene_check.rb`: an add and a
remove driven through a real `Change Party Member` battle-event page (the
production path, not a direct method call); the gauge-card status panel
(`battle_type` 2) picking up an add the same as the plain text rows; a
leave-then-rejoin within the same fight reusing the same `Combatant` and its
accumulated state while never reusing a disposed `Sprite` object or leaking
a duplicate; and the Z-recompute specifically preventing the stale-Z
collision described above across a remove-then-add cycle.
