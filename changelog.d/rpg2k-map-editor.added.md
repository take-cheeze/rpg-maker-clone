- **The F9 debug menu's Map viewer gained an actual Map Editor.** Press **L**
  inside the whole-map viewer to enter Edit mode: **Ctrl** picks up the tile
  under the cursor as the brush, **Shift** swaps which layer (lower/upper) is
  active, **C** stamps the brush onto the cursor's tile — an outright rewrite
  of that one cell via the new `Game::Map#set_lower`/`#set_upper`, distinct
  from the Tile Substitution event command's map-wide "every tile with this
  id" rewrite — and **R** writes the edited map back to its `.lmu` file
  (`Game::Map#sync_layers_to_unit` plus `LCF::File#save_to`, the same writer
  already proven byte-exact for saves and, via `scripts/lcf_text_convert.rb`,
  the database and map files themselves). Edits render immediately either
  way, in this viewer and in the live field map, since both read the same
  layer arrays the paint tool mutates — `R` is only about persisting past the
  current session. A brush only ever comes from the eyedropper, never a typed
  id, so a painted tile is always one that already validly exists somewhere
  on the map.
