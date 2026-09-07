- iPod nano 7G map-walk port: chipset transparency is honoured, so cells no
  longer render as solid magenta on-device. The exporter
  (`scripts/export_nano7_map.rb`) loaded the chipset without RPG Maker's
  colour-key flag, which `Scene::Map` passes for the real renderer, baking
  palette entry 0 into the atlas as an opaque colour. Tile pixels are now
  ARGB1555 with one alpha bit — half the file and half the on-device `.bss`
  the 32-bit atlas took — identical composited tiles are folded into one
  atlas entry, the app merges a cell's two layers before blitting, and a
  map's parallax background is exported as a single backdrop colour so a
  chipset's deliberately empty region (an island map's sea) reads as sea
  rather than a hole. Format version 2; re-export before installing.
