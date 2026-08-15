# 50. Mid-battle party roster sync

Date: 2026-08-15

## Status

Accepted

## Context

`Game::Battle`'s ally roster (`@allies`) is built once, at battle start:
`Scene::Map#open_battle` snapshots `@state.party.actors.map { |a|
Game::Battle.from_actor(a) }` and hands the array to `Game::Battle.new`.
Nothing about the fight ever looks at `Game::Party` again after that.

A battle-event `Change Party Member` command
(`Interpreter#do_change_party`) mutates the live `Game::Party#actors`
(`#add_actor`/`#remove_actor`) at any point during a fight — a troop page
can run one after any acting battler's turn. Neither call reaches the
running battle: a member swapped in never gets a turn, and a member swapped
out keeps acting and keeps being a valid target for the rest of the fight.
Found via four independent community デフォ戦bot trivia items describing
this exact class of bug.

Checked against EasyRPG's real source rather than trusted from the trivia
alone:

- `Game_Party::AddActor`/`RemoveActor` (`src/game_party.cpp`) call
  `Scene::Find(Scene::Battle)` and, if a battle scene is running,
  `scene->OnPartyChanged(actor, added)`.
- `Game_Party::GetBattlers` is read **live** wherever the engine needs the
  current roster (e.g. `Game_Battle::UpdateAtbGauges`,
  `src/game_battle.cpp`) — there is no separate cached battle-roster array
  in EasyRPG at all. Per-battle ephemeral state (ATB gauge, equipment-derived
  combat flags) lives directly on the persistent `Game_Actor`, which is
  *why* EasyRPG needs no sync step: reading the party fresh always reflects
  the truth.
- `Game_Battler::Exists()` (`game_battler.h`) is
  `!IsHidden() && !IsDead() && IsInParty()`, and
  `Scene_Battle_Rpg2k::ProcessSceneActionBattle`'s `ePreAction` substate
  rechecks it **immediately before running each already-queued action**,
  discarding the ones that fail
  (`while (!battle_actions.empty() && !battle_actions.front()->Exists())
  RemoveCurrentAction();`). `battle_actions` (the turn queue) itself is
  built once per round, from the live party, by `SelectNextActor`/
  `CreateEnemyActions`, ahead of `CreateExecutionOrder`'s agility sort.

That last point **corrects** an initial reading of the trivia this fix was
scoped from. The trivia's own account ("if a character isn't in the party
at turn start... they don't act that round" / "swap out then back in still
lets their queued command execute") reads as: membership is read once, at
round start, and a queued-but-not-yet-run action is immune to a mid-round
departure. The first half holds up against `SelectNextActor`/
`CreateEnemyActions`. The second does not: `Exists()`'s `IsInParty()` term
is rechecked right before *every* queued action runs, not just once per
round, so a member who leaves after their action was queued but before
their turn comes up loses that turn. Only a turn that has already resolved
is unaffected (nothing rewinds the log) — which is the part of the trivia
that happens to still be true, just for a narrower reason than stated.

This codebase's own `Game::Battle::Combatant` is a deliberately different
design from EasyRPG's live-actor model — see the class's own comment — an
ephemeral per-fight snapshot so battle-only modifiers (`atk_mod`/`def_mod`/
`spi_mod`/`agi_mod`, `attr_ranks` shifts, inflicted `states`) never write
back to the persistent `Game::Actor` and reset cleanly every fight (ADR
0033 and the state-halving/doubling work). That design is real and
already battle-tested, and this fix does not change it: it must not
silently discard and rebuild a `Combatant` for an actor who leaves and
rejoins the *same* fight, or their accumulated battle-only state would
incorrectly reset mid-fight.

## Decision

- `Game::Battle.new` gains an optional `party:` keyword (default `nil`) — a
  live `Game::Party` reference. `Scene::Map#open_battle` passes
  `@state.party`; every existing fixture / spec battle (nothing passes
  `party:`) is unaffected, since `@allies` behaves exactly as before when
  it is nil. This keeps the constructor's existing test-fixture-friendly
  shape intact rather than threading party access through some other
  mechanism.
- `Combatant` gains one field, `member` (nil/true = "yes", the default so
  nothing existing changes), tracking "currently a member of the live
  party" — distinct from "has ever appeared in this fight", the same way
  `hidden` already tracks "off currently" distinct from "left the troop
  entirely" for enemies. `#out_of_play?` now folds this in alongside
  `dead?`/`hidden`, so every existing `turn_order`/`side_targets`/`alive?`/
  etc. call site that already filters `out_of_play?` stops queueing or
  targeting a departed member for free, with no call site of its own to
  update.
- `Battle#sync_allies_from_party` (private) re-derives `@allies` from the
  live party: a member with no `Combatant` yet gets a fresh one
  (`.from_actor`) — matching EasyRPG's live-read semantics for a genuinely
  new participant, no accumulated modifiers; a member who already has one
  (they left *this* fight and are rejoining) reuses that exact object
  rather than rebuilding it, so accumulated battle-only state survives. A
  `Combatant` whose actor has left the live party is kept in `@allies` (not
  removed) — a later rejoin needs to find it, and `#apply_to_party` still
  needs to write its final state back to the actor at battle end — but
  flagged `member = false`.
- The sync runs in two places, mirroring the two EasyRPG call sites found
  above: once per round in `#refill_queue` (decides who is queueable this
  round, ahead of `#turn_order`), and again in both `#step`/`#step_action`
  right after popping the next queued battler (mirrors `ePreAction`'s
  per-action `Exists()` recheck) — so a battler removed after their action
  was queued, but before it runs, has that action dropped rather than
  resolved.

## Consequences

The mechanical roster is now correct: a member added mid-fight joins the
next round they're present for and can act and be targeted; a member
removed mid-fight stops being queued and stops being targetable, and loses
a turn still only queued (not yet run) at the moment they leave, while a
turn that already resolved before they left stands; a member who leaves and
rejoins the same fight keeps their accumulated battle-only state (states,
`atk_mod`/etc.) rather than it resetting, because the same `Combatant`
object is reused rather than rebuilt.

Deliberately out of scope for this step, and left for a follow-up:
`Scene::Map`'s battle-screen rendering. `@battle_ui[:allies]`, the actor
status window and actor sprites are still the one-shot snapshot taken when
the fight opened — the mechanical fix above does not touch them, so a
mid-fight swap is now correct in how the fight plays out but the screen
still shows the original cast until that follow-up lands.

Threading `party:` through turned out not to be architecturally awkward:
`Game::Battle` already receives everything else it needs (rng, states,
attributes, ai) as optional constructor arguments from `Scene::Map#open_battle`,
so `party:` is one more of the same shape, and the two per-round/per-action
sync call sites were natural extensions of `#refill_queue` (which already
runs once per round) and `#step`/`#step_action` (which already special-case
a dead battler the same way).

Covered by three new checks in `scripts/rpg2k_logic_check.rb`: an actor
added mid-fight joins the next round's turn order and can act; an actor
removed mid-round loses a turn only queued (not yet resolved) at the moment
they leave, then stops being queued or targetable in the following round;
an actor who leaves and rejoins the same fight keeps an accumulated state
and stat modifier on the *same* `Combatant` object. Every pre-existing
`Game::Battle.new` fixture across `scripts/rpg2k_logic_check.rb` (dozens,
none passing `party:`) and `scripts/rpg2k_scene_check.rb`'s own
`Scene::Map#open_battle`-driven battles continue to pass unchanged.
