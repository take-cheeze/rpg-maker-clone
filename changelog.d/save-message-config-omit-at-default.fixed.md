- **Save/Load:** the message-window options set by Change Message Options
  (transparency, position, whether the window is pinned, whether events
  keep running behind it) are now written to the save file only when they
  differ from their own default, matching RPG_RT's real save format.
  Previously every save carried explicit values for all four settings even
  when the player never changed any of them, producing save bytes real
  RPG_RT.exe never writes.
