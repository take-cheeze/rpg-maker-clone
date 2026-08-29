- **Move Type Vertical/Horizontal-cycle:** an event caught facing off its
  own cycle axis (e.g. a Vertical-cycle event whose page facing is Left or
  Right) now takes its first autonomous step in the correct default
  direction -- ported from a reference implementation's own cycle-movement
  handling, not independently confirmed against genuine RPG_RT under wine,
  whose default is Down for Vertical-cycle and Right for Horizontal-cycle.
  Previously it stepped the opposite way (Up / Left) instead.
