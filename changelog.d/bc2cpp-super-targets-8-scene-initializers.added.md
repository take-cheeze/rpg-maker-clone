- `tools/bc2cpp/bc2cpp.rb`'s `SUPER_TARGETS` allowlist gains 8 more
  entries: `RPG2k::Scene::ChipsetEditor#initialize`, `EquipMenu#
  initialize`, `GameOver#initialize`, `MapViewer#initialize`, `Order#
  initialize`, `SkillMenu#initialize`, `StatusMenu#initialize`, `Title#
  initialize` -- exactly the "future round" `tools/bc2cpp/compiled_gems.rb`'s
  own `RPG2k::Scene::Base` comment already flagged when the first 4
  entries (`Battle`/`DebugMenu`/`ItemMenu`/`Menu#initialize`) landed.

  A real whole-program survey (every `#error unhandled opcode SUPER`
  against a properly patched host mrbc) found each of these 8 blocked
  ONLY by their own `super parent` call (single explicit arg) into the
  same, already-clean `RPG2k::Scene::Base#initialize` -- the exact first
  shape the existing 4 entries already use, so this is a pure allowlist
  extension with zero new codegen. Both real soundness facts the table's
  own comment requires re-checking per entry were re-verified fresh, not
  assumed from the first 4: every real `.new` call site for all 8 classes
  across the whole closed world (mrblib plus `scripts/
  rpg2k_scene_check.rb`) was grepped and none pass a block literal, and
  the whole closed world still has exactly 3 real `include`s total (two
  unrelated `Enumerable`s, one top-level `include RGSS`), none between
  any of these 8 classes and `RPG2k::Scene::Base`.

  Verified via a real whole-program regen diff: `#error unhandled opcode
  SUPER` drops from 15 to 7, total `#error` count drops from 918 to 910
  (exactly 8), and the 8 methods' own generated bodies now call
  `RPG2k__Scene__Base_initialize_impl` directly instead of falling back
  to the interpreter. `docs/bc2cpp_coverage.txt` regenerated for real:
  coverage moves from 84.4% to 84.7% (2293 methods attempted unchanged,
  1935 -> 1943 compiled clean, 358 -> 350 left on the interpreter).
  `scripts/rpg2k_logic_check.rb` (1201 checks) and `scripts/
  rpg2k_scene_check.rb` (1062 checks) both still pass.
