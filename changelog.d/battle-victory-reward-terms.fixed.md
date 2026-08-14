- **A battle victory's EXP/gold/item-drop lines now read the database's own
  `exp_received`/`gold_received_a`/`gold_received_b`/`item_received` terms**,
  instead of always showing hardcoded English ("Gained 10 EXP.", "Found 20
  gold.", "Found Potion."). These four `term` chunk fields (LCF fields 7-10)
  were parsed by the schema and never read anywhere in `mruby-rpg2k`.
  Confirmed against EasyRPG Player's actual C++ source rather than guessed
  at: `PartyMessage::GetExperienceGainedMessage`/`GetGoldReceivedMessage`/
  `GetItemReceivedMessage` (`src/game_message_terms.cpp`) compose, for stock
  RPG2000 (the non-`Feature::HasPlaceholders`, non-Maniac-Patch branch),
  `"{exp}{exp_received}"`, `"{gold_received_a} {money}{gold}{gold_received_b}"`
  and `"{item_name}{item_received}"`. `Scene::Map#battle_result_lines`
  (`mruby-rpg2k/mrblib/scene/map.rb`) now composes exactly these three
  shapes, falling back to composed English when the database leaves a term
  blank, matching the "victory"/"defeat" terms it already read the same way.
  Covered by two new `scripts/rpg2k_scene_check.rb` checks (a database
  setting all four terms shows the composed sentences around the granted
  EXP/gold/item name; a blank database falls back to the composed English),
  both confirmed to fail against the pre-fix code before the fix.
