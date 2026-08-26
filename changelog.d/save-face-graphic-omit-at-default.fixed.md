- **Save/Load:** the message-window face graphic set by Change Face Graphic
  (file name, cell index, side, and mirroring) is now written to the save
  file only when it differs from its own default, matching RPG_RT's real
  save format. Previously every save carried explicit values for all four
  settings even when no face was ever shown, producing save bytes real
  RPG_RT.exe never writes.
