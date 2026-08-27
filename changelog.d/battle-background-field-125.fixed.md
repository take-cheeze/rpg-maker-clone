- `Game::State#to_lsd` now writes chunk 101 (SAVE_SYSTEM) field 125 (liblcf's
  own `background`, this schema's `:battle_background`) when given a database
  and map tree: the current map's resolved encounter background, off the
  same `Game::Backdrop.name_for` map-tree walk `Scene::Battle#
  encounter_backdrop` already uses for a fight's own backdrop, with a
  `Game::ChipSet`/terrain lookup built from the party's current tile.
  Previously undecoded and unwritten — field 125's own meaning had been an
  open question across several prior cycles. Confirmed byte-for-byte against
  a genuine kk1.12 save under wine, taken during ordinary map exploration:
  loading it and re-exporting reproduces "草原" (grassland) exactly. Omitted
  when no database/map tree is given (tests, tools) or this state has no map
  loaded, matching the prior behavior for those cases. Does not yet account
  for a live Change Map Tileset override (`Scene::Map`'s own transient
  `@tileset_id`), which this codebase does not persist anywhere — a separate,
  pre-existing gap.
