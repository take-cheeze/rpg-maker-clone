- RPG Maker **XP** message control codes — Show Text and Show Choices now expand
  the common RMXP codes instead of printing them raw. `RPGXP::Game::Message.expand`
  substitutes `\V[n]` (variable value) and `\N[n]` (actor name), turns `\\` into a
  literal backslash, and consumes the display-only `\C[n]` (colour) and `\G`
  (gold window) codes; `Scene::Map` expands each message and choice line against
  the game variables and the actor database before drawing it. Covered by new
  `mruby-rpgxp/test` cases.
