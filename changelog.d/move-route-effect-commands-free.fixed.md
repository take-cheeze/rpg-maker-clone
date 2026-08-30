- **Move routes:** an effect-only sub-command (Switch On/Off, Speed/
  Frequency Up/Down, Change Graphic, Play Sound, Through Mode, Stop/Start
  Animation, Transparency Up/Down) no longer spends a full pacing delay of
  its own -- ported from a reference implementation's own move-route
  update, not independently confirmed against genuine RPG_RT under wine,
  which runs any number of these in the same frame and only pauses for an actual
  Move/Turn/Wait/Jump sub-command. Previously, a route mixing effect
  commands with moves (a common "reskin then step" authoring pattern)
  crawled through the effect commands at the route's own pacing speed
  instead of applying them instantly before the next real move.
