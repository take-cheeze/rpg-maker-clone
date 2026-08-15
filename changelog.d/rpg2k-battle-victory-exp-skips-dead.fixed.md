- **A KO'd party member no longer earns EXP from a battle victory.**
  Confirmed against EasyRPG Player's source: the battle-victory EXP loop
  iterates only active battlers (`Game_Party_Base::GetActiveBattlers`, which
  excludes anyone failing `!IsDead()`). This build granted EXP to every
  current party member unconditionally, so a fallen ally still enrolled in
  the party at the moment of victory could earn (and even level up from) EXP
  it never fought for.
