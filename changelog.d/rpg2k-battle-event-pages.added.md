- RPG Maker 2000: **battle-event pages now run**, completing the RPG2000 event
  command set. A troop's pages (`enemy_group` chunk 11, already decoded by the
  LCF schema but until now unused) are evaluated by the new `Game::BattlePage`
  at the start of every turn — its `flags` bitfield follows liblcf's
  `TroopPageCondition::Flags` declaration order packed LSB-first, the same
  convention `Game::EventPage` uses for map pages — and every page whose
  condition holds runs, unlike a map event where only the highest page wins.
  Switch, variable, turn (RPG2000's base/multiple turn arithmetic), enemy-HP and
  actor-HP conditions are tested; a condition the runtime cannot answer (party
  fatigue, the per-battler turn counters, the chosen-command test) fails its page
  rather than letting it fire unchecked. Pages run through a `Game::Interpreter`
  carrying a new `battle` context, so they have the whole ordinary command set
  plus the battle-only commands: **Change Monster HP** (13110, with the constant
  / variable / percent operands and the non-lethal floor), **Change Monster MP**
  (13120), **Change Monster Condition** (13130), **Show Hidden Monster** (13150,
  which builds the sprite the troop skipped), **Change Battle Background**
  (13210, which now loads a real `Backdrop/<name>` image), the battle **Show
  Battle Animation** (13260), **Conditional Branch** (13310 with its `_B`
  else/end markers — switch, variable, actor-present / actor-status and
  monster-present / monster-status tests) and **Terminate Battle** (13410, which
  leaves the fight with no victory or defeat processing). A page's messages are
  shown in a battle text panel and dismissed with a button. The battle-only
  commands are no-ops in a map or common event, where RPG_RT cannot place them.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
