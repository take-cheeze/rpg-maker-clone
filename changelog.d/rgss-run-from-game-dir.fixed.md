- **An RGSS game runs from its own directory, so its saves stay its own.** A
  game's scripts do relative file I/O with nothing to tell them where they are —
  the stock `Scene_Save` writes `File.open("Save1.rxdata", "wb")` and the stock
  `Scene_Title` asks `FileTest.exist?("Save1.rxdata")`. `RGSS104E.dll` never has
  to think about it, because `Game.exe` is launched from the game's folder; this
  engine is launched from anywhere with `--game_dir` pointing elsewhere, so every
  game's saves landed in one shared place. The boot check caught what that means:
  *Pray for You*'s own title screen offered Continue on the strength of the
  editor test bed's save file, read it as its own, and died on the mismatch —
  which with a player in the chair is one game overwriting another's progress.
  `--game_dir` is now resolved to an absolute path and the engine changes into
  it, for the RGSS makers only (the MV/MZ smokes write screenshots relative to
  where they were invoked, and an LCF game's saves already go through this
  engine's own code against the game directory). The font search's last-resort
  relative `assets/fonts` is handed the launch directory explicitly, so a
  source-tree run still finds it, and a crash report now records the working
  directory alongside the game directory.
