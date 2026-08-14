- **An actor's effective max HP/MP and four combat stats (ATK/DEF/SPI/AGI)
  now clamp to RPG_RT's own ceilings, equipment bonus included, instead of
  growing unbounded.** Verified against EasyRPG Player's actual C++ source:
  `Game_Actor::GetBaseAtk`/`GetBaseDef`/`GetBaseSpi`/`GetBaseAgi`
  (`src/game_actor.cpp`) clamp the level curve + Change-Parameters shadow +
  equipped-item bonus *together* to `Utils::Clamp(n, 1, MaxStatBaseValue())`
  (999, not edition-gated), and `GetBaseMaxHp`/`GetBaseMaxSp` clamp to
  `MaxActorHpValue()`/`MaxActorSpValue()` (HP: 999 RPG2000 / 9999 RPG2003;
  MP: 999 either edition). `Game::Actor#recompute_stats`
  (`mruby-rpg2k/mrblib/game.rb`) had no ceiling at all on any of the six
  stats — the existing `#change_param`/`#base_param_limit` clamp only ever
  applied to a live Change Parameters delta on the unequipped base value,
  never to the equip-inclusive total, and never to a fresh level-curve
  assignment either. Fixed with new `MAX_EFFECTIVE_STAT`/`MAX_EFFECTIVE_MP`/
  `MAX_EFFECTIVE_HP_2K`/`MAX_EFFECTIVE_HP_2K3` constants and a new
  `Actor#rpg2003?`/`#max_hp_cap` pair (mirroring `Game::Party#rpg2003?`'s
  detection) applied inside `#recompute_stats`. Covered by a new
  `scripts/rpg2k_logic_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
