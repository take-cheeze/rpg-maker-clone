- **`--rpg2k_map_editor`/`--rpg2k_chipset_editor` now exit the process when the
  editor is closed (B)**, instead of falling back to an ordinary playable map.
  Both flags push their editor straight onto a freshly-built map scene,
  skipping F9's debug menu entirely, so the previous plain "pop back to
  whatever's underneath" behaviour landed the player in a live, controllable
  game rather than ending the run -- not what a quick CLI-driven edit (or a
  headless screenshot script) wants. Opening the same editors from F9's debug
  menu is unaffected: B there still pops back to the debug menu as before.
