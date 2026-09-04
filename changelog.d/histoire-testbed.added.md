- `scripts/download-histoire.bash` — a new RPG2000 test-bed game (イストワール
  / Histoire, version 2.03), fetched as a `.lzh` from Vector like
  `download-yumenikki.bash`'s game and extracted the same way with `lha`.
  By far the largest test bed here: 774 maps, 20448 events and 149967 move
  commands, against Nepheshel's ~250 maps. `lcf_testbed_check.rb` parses all
  of it cleanly; `rpg2k_testbed_logic_check.rb` needed three of its own
  checks widened for real data this big turned up for the first time — a
  menu-invisible switch skill meant only for a map/battle event's Force
  Skill Use, a blank unused item-table row left over from editing 610
  items, and a sealing state whose `restrict_skill`/`restrict_magic`
  thresholds are both 0 (a total-paralysis status, not a Silence).
  `rpg2k_command_soak.rb` gained one carve-out of its own: a variable-driven
  Enemy Encounter, soaked in isolation with no earlier Control Variables
  command to fill the variable, reads the harness's own default 0 as the
  troop id — never a real one, since LCF tables are 1-indexed — so that
  exact log line is the harness's own fingerprint, not a gap. All four
  consumers (`lcf_testbed_check.rb`, `rpg2k_testbed_logic_check.rb`,
  `rpg2k_command_soak.rb`, `analyze_game.rb`) now pass clean against it,
  Nepheshel, mtf-meido-action, Killer Knights and Yume Nikki alike. Wired
  into CI next to the other RPG2000/2003 downloads.
