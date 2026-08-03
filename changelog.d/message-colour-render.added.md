- Message text now draws `\c[n]` **colour changes** in colour. `Scene::Map`
  parses each line into `Game::Message.parse` colour runs and draws each run in
  its palette colour, laid out left to right; `Game::Message.visible_segments`
  truncates the runs to the gradual-reveal cursor so colour and the typewriter
  effect work together. The palette is a small built-in approximation for now
  (reading the real 20-colour row from the System windowskin is a follow-up).
  Covered by a new `Message.visible_segments` check in
  `scripts/rpg2k_logic_check.rb`.
