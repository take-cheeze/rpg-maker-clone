- RPG Maker 2000: **a battle's damage now sticks to the party**. The auto-battle
  runs on `Game::Battle::Combatant` snapshots (so the real actors are untouched
  mid-fight); when the fight ends, `Battle#apply_to_party` writes each ally
  combatant's final HP back to its source actor via the new `Game::Actor#set_hp`
  (an absolute setter that clamps to `[0, max]` and keeps the death state in
  sync). So a member who took damage stays wounded, and one reduced to 0 comes
  out **knocked out** (戦闘不能) — tying the battle into the death-state model —
  while a survivor keeps exactly the HP it ended on. `Scene::Map#finish_battle`
  applies this before resuming the event, and because a level-up on victory only
  clamps HP down (never heals), reward EXP can't secretly refill a wounded party.
  Combatants built from an enemy (or bare test snapshots) carry no source actor
  and are skipped. Covered by new `scripts/rpg2k_logic_check.rb` checks
  (`set_hp` HP↔death sync, write-back persisting damage and a KO, reviving a
  previously-downed actor that survived, and the no-op for actorless combatants).
  Reviving / healing a downed member is still done through Full Recovery, item
  cure, or the death-state cure — battle just no longer discards its own results.
