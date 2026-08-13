- `scripts/download-yumenikki.bash` — a new RPG2000-format test-bed game
  (Yume Nikki 0.10, Kikiyama's first public release; its data is RPG Maker
  2003, per the edition detection in `lcf_testbed_check.rb`), fetched as a
  `.lzh` from Vector and extracted with `lha` (the `lhasa` package, now in
  the nix dev shell) — `unar` silently drops about a third of this archive's
  entries as zero-byte files. Wired into CI alongside the existing
  Nepheshel / mtf-meido-action / Pray-for-You downloads. Every event command
  it uses (42 661 across 176 maps and 340 common events) already has a
  handler: `analyze_game.rb`, `lcf_testbed_check.rb`,
  `rpg2k_testbed_logic_check.rb` and `rpg2k_command_soak.rb` all pass clean
  against it.
