# 52. Battle as its own Scene, not a mode of Scene::Map

Date: 2026-08-15

## Status

Accepted

## Context

RPG2000's turn-based fight used to be a *mode* of `Scene::Map` rather than a
scene in its own right. A `@battle_ui` hash living on the map scene carried
the fight's entire live state (phase, the `Game::Battle` model, combatant
snapshots, cursors, windows, sprites), and roughly a hundred `drive_battle_*`
/ `battle_*` methods sat in the middle of `mruby-rpg2k/mrblib/scene/map.rb`
right alongside the field-map's own event/movement/rendering code — about
3,000 of the file's ~10,600 lines. `Scene::Map#update`'s own `:battle` wait
branch called `#drive_battle`, which built and drove the fight inline; there
was no `Scene::Battle` a Battle Processing (Enemy Encounter) command could
push the way `Scene::Menu`/`Scene::Title`/etc. are pushed onto `RPG2k
#@scenes` elsewhere in this codebase.

That worked (every mechanic RPG_RT's real `Scene_Battle` has was faithfully
ported), but it meant:

- The single largest file in the engine kept growing in a section that has
  nothing to do with map rendering, event stepping or movement — the two
  concerns were interleaved by accident of history, not by any real coupling.
- Every battle-only helper was reachable (and callable) from any of Scene
  ::Map's other ~350 methods, with nothing marking the boundary; a mistaken
  cross-call between "the fight" and "the field map" would have compiled and
  run without any signal it had happened.
- The fight could never be reached except through `Scene::Map`'s own
  `@battle_ui` gate — there was no independent object a future caller (a
  scripted/debug battle, a battle-only test harness, a different call site
  entirely) could construct and drive on its own.

RPG_RT itself keeps the two as genuinely separate scenes — ported from how a
reference implementation structures them, not independently confirmed
against genuine RPG_RT under wine; this ADR brings the port's own structure
in line with that, without changing any observable behaviour.

## Decision

- New `RPG2k::Scene::Battle < Scene::Base`
  (`mruby-rpg2k/mrblib/scene/battle.rb`) owns everything the fight itself is
  made of: the phase machine (`#update`), the command / target / skill / item
  / ally-target windows, the troop and party sprites, the per-action round
  animation, the troop's own battle-event pages, and the result screen. Its
  live state is the same hash the old `@battle_ui` was (`@ui`, `attr_reader
  :ui`), just owned by the fight's own object instead of the map's.
- `Scene::Map` keeps a single `@battle` ivar (a `Scene::Battle` instance, or
  `nil` between encounters) instead of `@battle_ui`. `#drive_battle` is still
  `Scene::Map`'s own method — Battle Processing can be issued from the
  foreground event or from a Parallel Process's own interpreter, and only
  `Scene::Map` sees every interpreter that could raise the wait — but it now
  only decides *whether* a fight should open or keep running, constructing a
  `Scene::Battle` and calling its `#start` the first frame, then handing every
  later frame to that instance's own `#update` for as long as the calling
  interpreter still owns it (the same block-and-retry shape already used for
  `:message`/`:choice`/`:number`). `Scene::Map#close_battle` disposes the
  fight's windows/sprites (`Scene::Battle#dispose`) and drops the reference;
  every other truthy `@battle_ui` check on the map side (rendering the battle
  backdrop instead of the map, hiding pictures, pausing a non-`in_battle`
  timer, gating `#parallels_paused?`/`#event_busy?`) became the equivalent
  `@battle`/`@battle.nil?` check unchanged.
- `Scene::Battle` is *not* pushed onto `RPG2k#@scenes` the way
  `Scene::Menu`/`Scene::Title` are. `Scene::Map#update` still runs every frame
  a fight is open — the map keeps ticking the screen tint, pictures, timers,
  weather and the owner Parallel Process exactly as before, all of which the
  existing comments document at length as deliberately *not* pausing for a
  battle — so a real scene-stack push (which would leave `Scene::Map#update`
  uncalled while `Scene::Battle` sits on top, the way it already *is*
  uncalled while `Scene::Menu` is up) would have had to duplicate all of that
  onto the new scene to preserve it. Composition (`Scene::Map` owns and
  drives a `Scene::Battle` instance every frame) gets the same object
  separation with zero behavioural risk; a real stack push is a larger,
  separate change this ADR does not make.
- What a fight still needs from the surrounding map — graphic caches shared
  across encounters (a monster/backdrop/battler decoded in one fight stays
  warm for the next), the RNG the map's own event/move-route code already
  shares with the party, the windowskin (reloaded by a mid-fight Change
  System Graphic), and the animation player a round's skill/item animation
  shares with the map's own Show Battle Animation command — is reached back
  through `@map` (`Scene::Battle#initialize(map, req, owner)`), against a set
  of readers and methods `Scene::Map` now exposes publicly for exactly this
  (grouped under the "Services Scene::Battle calls back into" heading next to
  `#dispose`, plus a second `public :...` list once the rest are defined).
  The two map-triggered/battle-round twins of the same mechanism
  (`#fire_target_flash`/`#fire_map_target_flash`,
  `#fire_target_shake`/(no map twin — a documented no-op in a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine),
  `#clear_target_flash`/`#clear_map_target_flash`) split the same way: the
  battle-only half moved to `Scene::Battle`, the map-only half stayed, and
  `Scene::Map#fire_animation_flashes`/`#hold_animation_target_flash` dispatch
  to `@battle.fire_target_flash`/`@battle.fire_target_shake`/
  `@battle.clear_target_flash` on the `ma[:battle]` branch.

## Consequences

`mruby-rpg2k/mrblib/scene/map.rb` shrank from ~10,600 to ~7,700 lines;
`mruby-rpg2k/mrblib/scene/battle.rb` is a new ~3,000-line file. No mechanic
changed — `scripts/rpg2k_scene_check.rb`'s 628 checks (rewritten to reach the
fight's state via `scene.instance_variable_get(:@battle)`/`.ui` and the
`battle_ui(scene)`/`fake_battle(scene, ui)` helpers that back it, and to send
battle-only methods to that object instead of the map scene) and
`scripts/rpg2k_logic_check.rb`'s 907 all still pass unchanged in what they
assert. `Interpreter#battle_screen` — the hook `Change Party Member` battle
events use to push a roster change onto the render layer (ADR 0050/0051) —
now naturally resolves to the `Scene::Battle` instance instead of the whole
map scene, which is the hook's real target and was previously reached only
because the map scene *was* the battle screen.

The one gap this does not close: `Scene::Battle` still cannot be reached or
driven except through `Scene::Map#drive_battle` opening one. A future battle-
only test harness or a scripted/debug encounter that wants to drive a fight
without a full map scene behind it is easier to build now (`Scene::Battle
.new(map, req, owner)` takes a narrow, already-public dependency list) but
still needs *some* `Scene::Map`-shaped object to hand it — closing that gap
further is follow-up work, not part of this change.
