- **Battle**: a party member added or removed mid-fight by a `Change Party
  Member` battle event now actually joins or leaves the fight's own roster.
  `Game::Battle` previously snapshotted `@allies` once at battle start and
  never re-read `Game::Party`, so a swapped-in member never got a turn and a
  swapped-out member kept acting and being targeted for the rest of the
  fight. `Game::Battle.new` now takes an optional `party:` (the live
  `Game::Party`, passed by `Scene::Map#open_battle`); with it, the roster is
  re-derived from the live party before every action, a rejoining member
  reuses their existing `Combatant` (so battle-only states/stat modifiers
  survive the round trip rather than resetting) rather than getting a fresh
  one, and a turn already queued when its owner leaves is dropped rather
  than resolving, matching EasyRPG's `Scene_Battle_Rpg2k::
  ProcessSceneActionBattle` (`battler->Exists()`) once checked directly
  against its real source. Every existing `Game::Battle.new` fixture (no
  `party:` argument) is unaffected. This step covers the core mechanic only
  (roster/turn-order/targeting) — the battle screen's status window and actor
  sprites still show the roster as it was when the fight opened; that's
  rendering work for a follow-up. See ADR 0050.
