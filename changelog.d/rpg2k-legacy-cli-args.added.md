- **RPG2000/2003 now understands RPG_RT.exe's own legacy CLI arguments.** The
  editor's Test Play button (and any shortcut built the same way) launches the
  game as `Game.exe TestPlay HideTitle Window` — bare positional words instead
  of `--flag=value` ones. `src/main.cxx`'s gflags parsing already left them
  untouched and passed them straight through to `RPG2k.new(args)`, but nothing
  read them there, so they were silently dropped. `RPG2k#initialize` now parses
  them: `HideTitle` is read by `Scene::Title`, which skips the title picture
  and centres the command window instead of docking it near where the picture
  would have sat, matching RPG_RT. `TestPlay` is recorded on `RPG2k#test_play`
  for future use. `Window` is accepted without complaint — this build's SDL
  backend has no fullscreen mode to switch out of in the first place (see the
  Toggle Fullscreen event command), so there is nothing left for it to do.
