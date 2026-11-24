- The bc2cpp declarations of an event interpreter's and the enemy AI's game
  state, and of an actor's base stats, equipment and states, no longer allow
  nil. None of them is ever nil (an actor now starts with empty base-stat
  arrays before its first level is set), so the compiled engine drops their
  nil tests and Wio flash shrinks.
