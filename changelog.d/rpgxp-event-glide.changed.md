- RPG Maker XP events move the way RGSS moves them: a step claims the
  destination tile at once (collision sees it immediately, as in the real
  runtime) and the drawn position closes the gap at `2 ** move_speed` a frame
  instead of teleporting a whole tile at a time. The walk row cycles off the
  same animation counter RMXP uses -- 1.5 ticks a frame while walking, one a
  frame for a page that animates on the spot, a new frame every
  `18 - move_speed * 2` ticks -- and an event that has come to rest falls back
  to its page's own frame. The wait between autonomous steps is now RMXP's
  `(40 - frequency * 2) * (6 - frequency)` frames rather than the placeholder
  table, and a move route's non-movement commands (turns, switches, a graphic
  change) run in the same turn as the step that follows them instead of costing
  a whole wait period each.
