- **Move Type "Approach Player" / "Away from Player":** a chase/flee event no
  longer homes in on the player with perfect precision on every step --
  matching RPG_RT's own `Game_Event::MoveTypeTowardsOrAwayPlayer`, which only
  computes the real toward/away direction 8 times out of 10 while the event
  is actually on screen (otherwise it keeps its current facing or picks a
  random cardinal), and picks a fully random cardinal unconditionally, with
  no attempt to track the player at all, once off screen.
