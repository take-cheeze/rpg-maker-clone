- **RPG2000/2003 events:** The Simulated Attack event command no longer
  clamps its computed damage to 999/9999, matching RPG_RT. An earlier fix
  this session had added that cap by unverified analogy with the
  in-battle damage-popup cap, but real RPG_RT's own `CommandSimulatedAttack`
  applies no such clamp — that cap only exists for the battle actions
  that actually draw the fixed-width popup animation, which this silent
  map-side command never does. A project using the command's
  store-to-variable option as a damage calculator now sees the true,
  uncapped number. Covered by a corrected `scripts/rpg2k_logic_check.rb`
  check.
