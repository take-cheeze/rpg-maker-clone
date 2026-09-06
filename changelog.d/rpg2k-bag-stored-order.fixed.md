- The Item menus and the save writer now keep the party's bag in the order the
  bag actually holds, instead of sorting it by item id. Measured against a
  genuine `RPG_RT.exe` under wine: a save whose chunk 109 `item_ids` was written
  deliberately out of order lists on RPG_RT's own field Item screen in exactly
  that stored order. `Game::State#to_lsd` sorted on the way out too, so this
  engine's own Save/Continue silently reordered the player's bag.
