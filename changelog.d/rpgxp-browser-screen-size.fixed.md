- An RPG Maker XP project loaded in the **browser** build now renders at XP's
  native 640x480 instead of the 320x240 default, so its title window and centred
  text no longer fall off the canvas: the native path sizes the display from
  `--game_dir` before creating it, but in the browser the project is mounted
  later by the page's loader, so `rpg_start_game()` resizes the display when it
  detects one. The page's loader panel also disappears once a game starts —
  `hidden` was being overridden by the panel's own `display: flex` rule. Both
  found by `scripts/rpgxp_browser_check.py`.
