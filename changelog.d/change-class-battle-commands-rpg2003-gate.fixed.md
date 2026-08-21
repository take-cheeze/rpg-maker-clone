- **Events:** Change Class and Change Battle Commands now no-op outright on
  an RPG2000-compatible database, matching RPG_RT -- previously both
  applied unconditionally on any edition, so a "no class" Change Class
  could still reset an actor's EXP, and a Change Battle Commands "clear"
  could still wipe an actor's command list, on a database that never
  offered either command in the first place.
