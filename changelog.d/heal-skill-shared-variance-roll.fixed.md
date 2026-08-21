- **Battle:** a recovery skill (or an ATK/DEF/SPI/AGI-modifying buff) that
  affects more than one of HP, SP, and a stat modifier at once now spreads
  all of them by the *same* randomized amount, instead of rolling each one
  independently -- matching RPG_RT, which computes one variance-adjusted
  effect per cast and reuses it raw for every affected field. Previously a
  Cure spell restoring both HP and SP (or a buff healing HP while also
  raising a stat) could land two or three different randomized amounts on
  the same cast, and consumed extra random draws that desynced every
  subsequent seeded roll in the fight. Also fixed: the ATK/DEF/SPI/AGI
  modifier never received the skill's elemental attribute scaling at all,
  and the SP amount was never capped the way HP and the stat modifier were.
