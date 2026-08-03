- The `SAVE_PARTY_ACTOR` save chunk (108) now decodes per-actor **level, exp,
  learned skills, equipment and current HP/MP**, decoded from a real save and
  cross-checked (level rises with exp across the roster; the level-1 hero's HP
  matches the independent SAVE_TITLE summary; every equipment slot's item id
  resolves to an item of the matching type in the database). `lcf_save_check.rb`
  also cross-checks the `SAVE_MAP_EVENT` (chunk 111) saved event positions
  against the current map when its `.lmu` is present — every saved event must be
  a real, in-bounds event on that map (confirmed: 21/21 on Nepheshel's map 12). `Game::State.from_lsd` restores the roster's
  saved HP/MP so **Continue resumes a wounded party instead of healing it to
  full**, `lcf_save_check.rb` reports each actor's level/exp/HP/MP, and
  `rpg2k_save_load_check.rb` asserts the restored vitals. See ADR 0014.
