- **Change Equipment event command:** now respects a 二刀流 (dual-wield)
  actor's second weapon slot, matching RPG_RT's own Change Equipment
  command handling, ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine. Handing such
  an actor a
  shield is a complete no-op (nothing equipped, nothing consumed from the
  bag), and handing them a second weapon fills their empty off-hand
  weapon slot instead of overwriting the first -- unless that slot is
  already occupied or the standing weapon is two-handed, in which case it
  falls through to the ordinary weapon-slot overwrite, same as before.
  Previously this command equipped purely by the item's database type,
  so a scripted "learn dual-wield, here is your second blade" event
  overwrote the first weapon, and handing such an actor a shield silently
  jammed it into their off-hand weapon slot.
