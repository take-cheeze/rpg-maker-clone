- **Three more `LcfSaveData` sections decoded** from the real save (ADR 0011):
  chunk **109 inventory** (`item_ids`/`item_counts`/`gold` — gold confirmed
  against the on-screen 100G and the item ids round-tripped through the game's
  own `RPG_RT.ldb` to 薬草 ×3 + 導きの書 ×1), chunk **114 common-event state**
  (`Array2D` of per-event execution state) and chunk **113 foreground event
  state** (the running event captured mid-command). `lcf_save_check.rb` now
  reports these as documented and prints the inventory; only chunks 102, 112 and
  200 remain undocumented.
