- The battle Skill menu now reopens with the cursor back on the last skill
  an actor cast this fight, instead of always resetting to the top of the
  list -- community デフォ戦bot/@2000_battle_bot trivia. The memory is
  shared with Auto-Battle: a Forced-AI actor's own automatically-chosen
  skill is remembered too, exactly as if the player had picked it manually.
  Falls back to the top of the list when nothing has been chosen yet this
  fight, or when the remembered skill no longer appears in it (forgotten
  mid-battle, or newly sealed by a status effect).
