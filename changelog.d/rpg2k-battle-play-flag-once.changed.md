- RPG2000/2003 games no longer look up the `RPG2K_BATTLE_PLAY` launcher
  constant every frame when battle play is off (a raised `NameError` on hosts
  that never set it): the result is kept after the first frame.
