- **Break Loop now reproduces RPG_RT's own indent-blind nesting bug instead
  of the behaviourally "correct" reading of the command.** viprpg-dev wiki
  (`200X共通/基本的な仕様`・`バグ`): real RPG_RT's Break Loop does not track
  nesting depth at all — it searches downward for the very next End Loop
  command by list position alone and jumps just past whichever one it hits
  first. When a second, more-deeply-nested Loop/End Loop pair sits between a
  Break Loop and its own enclosing loop's End Loop, that inner End Loop is
  what gets hit, not the enclosing one — falling into whatever follows it and
  looping forever through the *outer* loop's own End Loop, so the code after
  the outer loop is never reached. `Game::Interpreter#do_break_loop`
  (`mruby-rpg2k/mrblib/interpreter.rb`) used to scan forward for the first
  End Loop whose indent was strictly less than the Break Loop's own — a
  nesting-aware scan that always lands on the true enclosing loop, and so
  never reproduced this compatibility gap. It now scans for the next End Loop
  by position alone, indent unconsidered, matching the wiki's worked example.
  Covered by two new `scripts/rpg2k_logic_check.rb` checks (the common case
  with nothing but the enclosing End Loop in between is unaffected; the
  worked nested-loop example now hangs in the outer loop instead of escaping
  it), the second confirmed to fail against the pre-fix code before the fix.
