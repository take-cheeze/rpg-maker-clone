- Fixed a real gap in `mruby-rpgvx`: `RPG::UsableItem#battle_ok?`/`#menu_ok?`
  (RGSS3/VX Ace, checked by the stock `Game_BattlerBase#occasion_ok?` to
  decide whether a skill/item can be used in battle vs. from the menu) did
  not exist at all, raising `NoMethodError` the moment an actor or enemy AI
  tried to use one. Found because a real RPG Maker VX Ace game's enemy AI
  hit it selecting its very first battle action. Matches the editor's
  Occasion dropdown exactly (0 Always, 1 Only in Battle, 2 Only from the
  Menu, 3 Never) -- confirmed against RPG Maker MV's own `isOccasionOk`, a
  line-for-line port of the same VX Ace logic.
