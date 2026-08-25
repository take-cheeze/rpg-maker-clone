- The game timer is now drawn on the map. The Timer Operation command's start
  carries RPG2000's "show timer" flag, and while set `Scene::Map` shows a small
  top-centre window counting down as `M:SS` (independent of whether the timer is
  still running, so a stopped timer stays on screen frozen). The visibility flag
  round-trips through the save.
