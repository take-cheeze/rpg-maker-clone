- The engine now defers initializing an RPG Maker version's mruby gem
  (RPG2000/2003, XP, VX/VX Ace, MV, MZ) until the game directory's own maker
  is actually detected, instead of initializing all four on every run. Cuts
  the live-heap cost `mrb_open()` used to pay for the makers a given run
  never uses. See `docs/adr/0060-deferred-per-maker-gem-init.md`.
