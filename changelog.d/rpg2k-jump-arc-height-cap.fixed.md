- **A jumping character's hop now peaks at exactly one tile (16px), instead
  of overshooting to 21px.** Confirmed against EasyRPG Player's source
  (`Game_Character::GetJumpHeight`): the jump-height formula's own offset/cap
  shape was previously mis-ported as an uncapped `h + 5`, missing the real
  formula's `h < 13 ? h + 4 : 16` cap — every full-height jump (hero or
  event) rose about 31% past the real arc's own ceiling.
