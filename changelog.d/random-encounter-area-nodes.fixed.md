- **Map:** a map-tree "Area" sub-region's own random-encounter list now
  pools together with the map's own list while the party stands inside its
  bounds, matching RPG_RT -- previously Area nodes (the editor's rectangular
  per-region monster-set feature) were never read at all, so an area's own
  distinct troop set never had any effect on wandering-monster fights.
