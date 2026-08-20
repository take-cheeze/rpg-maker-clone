- **Interpreter:** A Transfer Player / Recall to Location command reached
  while a message window or choice list is open, anywhere in the scene, is
  now blocked and retried every subsequent frame instead of warping the map
  immediately -- matching RPG_RT's own `Game_Interpreter_Map::
  CommandTeleport`/`CommandRecallToLocation`. A still-running parallel
  process could previously warp the map out from under an on-screen message
  window from another event.
