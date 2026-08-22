- **Move Type Vertical/Horizontal-cycle:** an event caught facing off its
  own cycle axis (e.g. a Vertical-cycle event whose page facing is Left or
  Right) now takes its first autonomous step in the correct default
  direction -- matching RPG_RT's own `Game_Event::MoveTypeCycle`, whose
  default is Down for Vertical-cycle and Right for Horizontal-cycle.
  Previously it stepped the opposite way (Up / Left) instead.
