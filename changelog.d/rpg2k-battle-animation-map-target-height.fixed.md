- **A Head/Feet-positioned battle animation triggered on the map (Show
  Battle Animation over the player, a map event, or a vehicle) now splits
  by RPG_RT's real 12px offset, not 16px.** Confirmed against EasyRPG
  Player's source (`BattleAnimationMap::DrawSingle`): the map-side split
  uses a hardcoded `24`, not the CharSet frame's actual 32px height, despite
  reading like it should be the same thing. The battle-side split (over an
  enemy/actor sprite) already used the real battler bitmap height and was
  unaffected.
