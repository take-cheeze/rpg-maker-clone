- **Show Battle Animation (battle-event page form):** an out-of-range Ally
  or Enemy target index no longer draws a spurious screen-centre animation.
  Matches RPG_RT's own `Game_Interpreter_Battle::CommandShowBattleAnimation`,
  which no-ops the entire command whenever the named party/troop slot
  doesn't exist. A "wait until it finishes" request on such a target now
  also falls straight through to the next command the same tick, instead
  of stalling for the animation's own real duration.
