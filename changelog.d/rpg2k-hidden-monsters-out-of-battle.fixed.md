- RPG Maker 2000: a troop member flagged **invisible** no longer fights while it
  is still hidden. `Game::Battle::Combatant` gained the flag (carried through by
  `Battle.from_enemy`) and an `out_of_play?` predicate — distinct from `dead?`,
  which is purely about HP — and the battle now skips out-of-play battlers when
  building the turn order, picking an attack target and deciding whether a side
  is still standing; `Scene::Map#living_foes` skips them in the target cursor
  too. Previously every troop entry became a full combatant regardless of its
  invisible flag, so a monster with no sprite would attack the party, sit in the
  target list and have to be killed before the fight could be won. **Show Hidden
  Monster** (13150) now does what its name says: `reveal_battle_monster` clears
  the flag on the combatant as well as the troop member, so the monster enters
  the fight at that moment instead of having been in it all along. An
  unrevealed member no longer keeps a battle alive after every visible monster
  is down, matching RPG_RT.
