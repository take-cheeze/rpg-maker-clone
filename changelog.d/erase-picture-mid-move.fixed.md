- **Pictures:** Calling Erase Picture on a picture that is still animating
  toward a target from a Move Picture command no longer freezes it in place.
  It now keeps gliding invisibly toward its old destination and only settles
  once the move's own duration elapses, matching RPG_RT. This is only
  observable through a saved game made while the picture is still gliding
  (its saved position/countdown keep advancing instead of being stuck), so a
  save made shortly after such an Erase Picture will now restore a picture
  further along its old path than before.
