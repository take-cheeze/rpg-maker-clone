- RPG Maker **XP** events run their inline Ruby: **Script** (355) and its
  continuation lines (655) are joined into one source and evaluated at the top
  level, as RGSS does. The two RMXP globals this runtime can honestly back are
  bound to it — `$game_switches` and `$game_variables` reach the same switches
  and variables Control Switches / Control Variables write — and anything else a
  script reaches for is simply absent: the built-in flow is a reimplementation,
  and a game that needs the rest of RMXP's object graph wants
  `RGSS_SCRIPT_HOST`. A script that raises is reported with its map and event
  and the event carries on. That covers what a real game does with the command:
  22 of Pray for You's 23 script blocks assign globals of the game's own
  invention, and the last reads `$game_variables[1]` before dumping a save.
