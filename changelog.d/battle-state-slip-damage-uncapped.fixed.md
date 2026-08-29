- **Battle:** a state's per-turn HP slip damage (poison, and any custom
  status with a percent-of-max HP drain) is no longer clamped to the
  damage-popup cap (999 on RPG2000, 9999 on RPG2003) -- matching RPG_RT's
  own slip-damage application, ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine, which applies
  the full computed slip every turn with no clamp at all (only floored at
  1 HP, never lethal on its own). Previously, a heavy percent-of-max drain on a
  high-max-HP battler ticked for less damage than genuine RPG_RT once the
  computed amount exceeded the edition's popup ceiling.
