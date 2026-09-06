- The RPG2000 battle backdrop is now the background the runtime is *carrying*
  (`Game::State#battle_background`, restored from the save's SAVE_SYSTEM field
  125 and dropped on a map change) rather than a fresh map-tree walk at battle
  start, and the field drawn when nothing names a backdrop is flat black
  instead of a dark blue-grey. Both measured against genuine RPG_RT.exe under
  wine on the RPG2000 test bed (cycle #245): the same Nepheshel map-2 save
  with field 125 hand-set to `light` fought over `Backdrop/light.png` even
  though the map tree resolves `black` for that map, and with the field absent
  fought over an exactly RGB(0,0,0) screen. The same captures confirm the
  backdrop is blitted once, 1:1 at the screen origin (no scaling, tiling,
  offset or scrolling) under the troop sprites, that a troop member is centred
  on its database x/y on both axes, and that the lower-numbered member draws
  on top.
