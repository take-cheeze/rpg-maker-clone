- **Save/Continue:** a screen tint set by Tint Screen -- whether already
  settled or still mid-transition -- now survives a real save/load, matching
  RPG_RT's `Game_Screen::SetSaveData` -- previously the screen silently
  snapped back to neutral on Continue, and a fade that hadn't finished lost
  its remaining frames instead of resuming exactly where it left off.
