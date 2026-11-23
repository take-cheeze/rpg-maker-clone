- **rpg2k**: the battle scene's live state (`Scene::Battle#ui`) is a
  `Scene::Battle::Ui` with one field per former Hash key, so the compiled code
  reads fixed slots instead of looking up Symbol keys.
