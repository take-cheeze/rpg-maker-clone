- **Opening Item/Skill/Equip/Status from the field menu no longer leaves the
  menu's own command list and status panel drawn behind the new screen.**
  Verified against genuine `RPG_RT.exe` under wine: its Item screen shows
  only its own item-list window, not the field menu's command/status panels
  behind it. `RPG2k#push`/`#pop` now call an optional `#suspend`/`#resume` on
  the scene being covered/uncovered, and `Scene::Menu` uses it to hide its
  `@command`/`@status` windows while a child screen is on top.
