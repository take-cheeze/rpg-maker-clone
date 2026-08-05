- Starting an RPG Maker 2000 game no longer freezes for seconds. An `LCF`
  chunk holding a nested table (`:Array1D` / `:Array2D`) was re-parsed in full on
  *every* read, and the runtime reads the same ones over and over: building the
  party alone asks for `db.item` thirty times — `Game::Actor#equip_bonus`, six
  stats across five equipment slots — so New Game on Nepheshel spent **7.7
  seconds** inside one `recompute_stats`, in a single blocked frame. Nested
  tables are now decoded once and kept (and dropped again when the chunk under
  them is rewritten or deleted), which takes that frame to 0.5 s and the whole
  transition second from 3.8 to 28.7 frames a second. Scalars and strings are
  still decoded per read, so callers keep getting their own object.
