- **Skills:** an attribute-resistance-shift ("raise X resistance") buff skill
  no longer requires a matching weapon equipped just because its named
  attribute happens to be weapon-type -- matching RPG_RT's own
  skill-usability check, ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine, which exempts
  this skill type from the weapon-equip check entirely. Previously such a skill was incorrectly
  greyed out on the field menu, in battle, and for auto-battle whenever the
  caster had no matching weapon equipped.
