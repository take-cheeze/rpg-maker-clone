- **Battle (RPG2003 gauge system):** A fresh gauge-battle game now correctly
  defaults to Active ATB mode, matching RPG_RT -- the command menu no longer
  freezes every combatant's gauge by default. The Wait command's field-menu
  label was also fixed to match (previously showed "Wait On" while active and
  "Wait Off" while waiting, the reverse of RPG_RT). The two `SaveSystem.atb_mode`
  raw values (0/1) had been swapped from what real RPG_RT actually stores.
