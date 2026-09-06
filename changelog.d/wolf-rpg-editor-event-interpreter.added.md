- **WOLF RPG Editor (ウディタ/Woditor)** projects now run their own
  auto-start and parallel-process Common Events every frame -- the "RPG
  Basic System" bundled with the editor implements the message window,
  menu and save/load, so this is the prerequisite for any of that to
  eventually work. Implemented: variable/string assignment
  (`SetVariable`/`SetString`), multi-case branches
  (`VariableCondition`), loops (`StartLoop`/`BreakLoop`/`LoopEnd`/
  `GotoLoopStart`), labels (`SetLabel`/`JumpLabel`), `Wait`, and calling
  other Common Events with self-variable arguments and return values.
  Map events do not run yet, and several commands (real message windows,
  pictures, `StringCondition`, database writes) are still explicit
  no-ops. See `docs/adr/0065-wolf-rpg-editor-event-interpreter.md`.
