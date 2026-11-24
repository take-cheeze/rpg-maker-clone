- **RPG_RT.lmt rows are read on demand**: the map tree's per-map rows stay in
  the file until a scene reads one, about 80 KB less heap on Nepheshel from the
  title screen on. A host that defines `LCF_EAGER_MAP_TREE` true reads them
  whole as before.
