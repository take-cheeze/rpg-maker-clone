- **Special-skill HP recovery is now hard-capped at 999 per use**, matching
  yado.tk and mirroring the existing battle damage cap: RPG_RT's heal popup
  is the same fixed 3-digit widget as the damage one, so a single heal
  can't display (or apply) more than 999 no matter how large
  `recover_hp_rate` × max HP computes it. `Game::Battle::RECOVER_CAP = 999`
  clamps the recovery amount before it's added to HP.
