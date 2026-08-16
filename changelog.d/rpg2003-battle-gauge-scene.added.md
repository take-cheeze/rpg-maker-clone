- Route a fight to the RPG2003 battle scene (RPG2k3::Scene::Battle) whenever the
  database was authored in 2003, via a new `RPG2k::Scene.battle_scene_class(db)`
  factory that Scene::Map#drive_battle now uses instead of constructing
  `RPG2k::Scene::Battle` directly (ADR 0053, Phase 2 scene integration). The 2003
  scene subclasses the 2000 battle scene and overrides `#update` to advance the
  active-time gauge every frame for a gauge (battle_type 2) presentation; the
  traditional (0) and alternative (1) presentations inherit the unchanged
  turn-based machine, so routing every 2003 fight through it is safe. This is the
  first 2003-boot slice that actually drives the 2003 gauge engine the moment a
  fight is reached, without touching the 2000 path.
