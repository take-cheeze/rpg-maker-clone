- **Map transitions now have their own profiler sections** —
  `map.transition.load`, `map.transition.bgm`, `map.transition.chipset`,
  `map.transition.build_events` and `map.transition.build_parallels`
  (`mruby-rpg2k/mrblib/scene/map.rb`, both `Scene::Map#initialize` and
  `#perform_teleport`). Investigating a browser audio glitch report on scene
  transitions found that a map-to-map transition runs as one large
  synchronous block with no profiler visibility of its own — `scene.update`'s
  baseline already has an unremarked 536.65ms outlier consistent with exactly
  this — so it is now measurable instead of invisible inside the per-frame
  `scene.update` bar. See `docs/profiling.md`'s "Scene transitions" section
  for the full analysis; actually shortening the stall is follow-up work.
