- **Show Hidden Monster (Enemy Appearance) is confirmed rather than an open
  yado.tk claim.** A scripted reinforcement can't be lost to a premature
  victory when the enemies visible so far are wiped before its own Show
  Hidden Monster command fires: the mid-round battle-page check already lands
  strictly before the round's own `battle.finished?` test, so the
  reinforcement's `hidden` flag is always cleared in time. Targeting an
  already-revealed troop member is also confirmed as the silent no-op it
  should be. Covered by a new `scripts/rpg2k_scene_check.rb` check.
