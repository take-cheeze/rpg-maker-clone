- **A status the target already has is announced instead of going silent** — the
  状態 row's `message_already` (「はすでに毒に冒されている！」), the fifth of its
  sentences and the one nothing read. RPG_RT counts an already-carried state as a
  **success** and decides that *before* rolling the skill's accuracy, so a Poison
  Sting on an already-poisoned foe always reports, and a 0%-accuracy skill reports
  too. `Game::Battle#roll_inflict` returns the already-carried states beside the
  landed ones, the battle log entry carries them, and the action banner prints the
  state's own sentence — one wording for both sides, with the composed fallback
  kept for a database that leaves it blank. 15 of Nepheshel's 25 states and 7 of
  mtf-meido-action's 10 fill the field in. `message_affected` stays deliberately
  unread: EasyRPG defines its helper and never calls it, so nothing pins when
  RPG_RT prints it. See the addendum to ADR 0032.
