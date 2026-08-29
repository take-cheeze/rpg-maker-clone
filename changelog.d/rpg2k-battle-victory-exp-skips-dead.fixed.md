- **A KO'd party member no longer earns EXP from a battle victory.**
  Ported from a reference implementation, not independently confirmed
  against genuine RPG_RT under wine: the battle-victory EXP loop
  iterates only active battlers, excluding anyone already downed.
  This build granted EXP to every
  current party member unconditionally, so a fallen ally still enrolled in
  the party at the moment of victory could earn (and even level up from) EXP
  it never fought for.
