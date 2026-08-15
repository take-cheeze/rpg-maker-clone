- **A GAIN-type (regen) status condition's map-step tick no longer flashes
  the screen red.** Confirmed against EasyRPG Player's source
  (`Game_Party::ApplyStateDamage`): the screen-flash flag is only ever set
  when a state actually drains HP/SP, never when one heals it. This build
  flashed the screen on any map-step status tick at all, heal included —
  the same exemption a healing terrain tile already correctly gets.
