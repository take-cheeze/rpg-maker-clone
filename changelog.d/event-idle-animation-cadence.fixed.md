- **Map:** a Continuous/Fixed-Continuous event's idle walk-frame cycle and a
  Spin event's facing rotation now use their own, slower cadence, matching
  RPG_RT -- previously both reused the same (faster) cadence an event uses
  while actually sliding between tiles, so decorative "always animates"
  events (torches, waterwheels) and rotating events visibly animated too
  fast while standing still.
