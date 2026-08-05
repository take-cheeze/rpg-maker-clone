- RPG Maker 2003: the **RPG2003-only event commands** now run. The editor emits
  these as low opcodes RPG2000 never had, and until now none of them had a
  handler — the interpreter's opcode table stopped at the shared RPG2000 set.
  Added, with the parameter layouts taken from liblcf's `EventCommand::Code`
  enum and EasyRPG Player's own handlers rather than guessed:
  - **Change Class** (1008) moves an actor to a database class (職業, chunk 30 —
    `db.job`), following RPG_RT's order of operations: equipment is stripped
    first, the class swap re-points the actor at the *class's* growth curve,
    skill learn table and EXP curve (`Game::Actor#curve_row`, matching how
    EasyRPG's `GetBaseMaxHp` / `LearnLevelSkills` / `CalculateExp` all branch on
    `class_id > 0`), and EXP is reset to the new level's threshold even when the
    level is unchanged. Both the skill mode (keep / reset / add) and the
    parameter mode (keep / halve / the new class's level-1 or current-level
    values) are honoured, as is the "show level-up message" flag. An actor whose
    database row names a class reads its curves from startup.
  - **Change Battle Commands** (1009) adds or removes an actor's battle commands
    (戦闘コマンド, actor/class field 80), including RPG_RT's capacity rule — six
    commands plus the trailing Row entry — and the "remove command 0" form that
    clears the list back to Row alone.
  - **Force Flee** (1006), **Enable Combo** (1007) and **Call Common Event**
    (1005) in a troop's battle-event pages. Force Flee either grants the party a
    guaranteed escape (the player still has to choose Flee) or sends one / every
    troop member running — the member is hidden rather than killed, which takes
    it out of the fight and drops its sprite, with the database's escape SE.
  - The RPG2003 English-release system commands **Open Load Menu** (5001) and
    **Exit Game** (5002), which leave the map for the loader and quit outright.
    **Toggle Fullscreen** (5004) and **Open Video Options** (5005) are logged
    no-ops: this build's display backend has neither mode, which is also what
    EasyRPG does on a platform whose window cannot change.

  A class change and its battle-command edits survive Save / Continue. RPG2000
  data is unaffected — those databases carry no class table, so every actor stays
  class-less and a Change Class targeting an undefined class changes nothing.
  Covered by new checks in `scripts/rpg2k_logic_check.rb` and exercised against
  the real RPG2003 test bed.
