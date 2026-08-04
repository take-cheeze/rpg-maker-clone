- RPG Maker **XP**: a per-actor runtime model. `RPGXP::Game::Actor` wraps each
  `RPG::Actor` database record and its `RPG::Class`, deriving the actor's
  level-based stats straight from its `parameters` table (max HP/SP, str, dex,
  agi, int), its known skills from the class's learnings up to the current level,
  and its equipment from the actor's default weapon and four armor slots.
  `Game::State#actor(id)` memoises one live actor per id (the way RMXP's
  `$game_actors[id]` does), so future Change-Actor commands have a place to mutate
  state. The model immediately powers the full **actor Conditional Branch** (type
  4): *is in the party*, *name is*, *skill learned*, *weapon equipped* and *armor
  equipped* — previously only "is in the party" was evaluated and the rest
  silently took the true branch, so conditions gated on a learned skill or worn
  equipment now behave correctly. Matched to RMXP's `command_111`. Covered by new
  `mruby-rpgxp/test` unit tests (the model plus the conditional branches) and by
  `scripts/rpgxp_testbed_check.rb`, which now builds a `Game::Actor` for every
  actor in the real OpenGame.exe XP test bed and checks the derived state
  resolves. The Change-Actor commands that mutate this model are a follow-up.
