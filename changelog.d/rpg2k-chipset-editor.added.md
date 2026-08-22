- **The F9 debug menu gained a Chipset page: a visual passability editor** for
  the current map's chipset. A coloured grid (green passable, dark red
  blocked) over its 162 lower / 144 upper cells, since passability is spatial
  data a text file is a poor fit for — same reasoning as the Map viewer/editor
  itself. **L** switches between the lower and upper tables, arrow keys move
  the cell cursor, **C** toggles passability on the selected cell — coarse,
  all four direction bits at once, matching how `Game::ChipSet#landable_tile?`
  itself reads "passable" — leaving an upper cell's own "star" (draws in front
  of the hero) and counter (talk-across) flags untouched, and **R** writes the
  database back to its `.ldb` file and rebuilds the live map's chipset so the
  edit is visible immediately. Fine per-field edits this doesn't cover
  (terrain id, water-animation speed, ...) are still reachable through
  `scripts/lcf_text_convert.rb`.
