- **Battle:** a battler still afflicted with a status condition (or one that
  just wore off on its own) now opens its turn with that state's own
  reminder line -- "Zero is poisoned!" (or, the turn it clears, its own
  recovery line) -- before whatever it goes on to do, matching RPG_RT's own
  per-turn state scan. Previously the `message_affected`/`message_recovery`
  database fields were only ever read the instant a state first landed or
  was actively cured by an item/skill; the ordinary per-turn "still
  poisoned" reminder a player would see every single turn a real RPG_RT
  game runs never appeared here at all.
