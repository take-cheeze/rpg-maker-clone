- **The Item and Skill menus no longer show a hardcoded English "No items" /
  "No skills" message on an empty list.** Found by comparing this engine's
  field menu against a genuine `RPG_RT.exe` under wine: with an empty bag,
  RPG_RT draws a blank list row with a visible (but empty) selection cursor
  and no text at all — the placeholder strings were never localized (every
  other piece of menu text goes through the `term(...)` database lookup) and
  don't match what the real runtime shows. `Scene::ItemMenu`/`Scene::SkillMenu`
  now draw nothing for an empty list, and their selection cursor stays visible
  on the blank row instead of collapsing to zero height, matching RPG_RT.
