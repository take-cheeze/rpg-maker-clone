- **`--rgss_host_battle_test` fights in a game's own battle scene.** Once the
  game is on its own map the host calls a battle exactly the way that game's own
  Battle Processing command does — the same five `$game_temp` fields the stock
  `Interpreter#command_301` sets — and reports where it got to as
  `[RPGXP-HOST-BATTLE] scene=.. reached=.. frame=..`. This is the biggest
  surface the boot check reaches: a battle builds the game's own
  `Spriteset_Battle`, so every enemy is a `Sprite_Battler` on top of
  `RPG::Sprite`, whose whiten/appear/collapse transitions, damage pop-up and
  animation playback nothing had ever run. It is the one probe that *writes* to a
  game's globals rather than only reading them, because no keypress starts a
  battle; confirm taps keep running through it, which is what advances the game's
  own party and actor command windows.
- **The boot check gives it its own pass**, on the editor test bed only: a battle
  is called from the map and the walk/menu pass ends inside the menu, and a
  released game's opening is an event sequence a battle call would land in the
  middle of. The reserved CI display numbers shift accordingly (the XP boot smoke
  now takes 112..114, the RGSSAD A/B 115..116).
