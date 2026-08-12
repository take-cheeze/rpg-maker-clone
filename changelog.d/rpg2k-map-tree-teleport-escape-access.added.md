- **The map tree's per-map Teleport and Escape settings (map_properties
  fields 31 and 32) are now applied**, the same way field 33 (Save) already
  was. RPG_RT.lmt lets each map pin the Escape / Teleport field skill types to
  Allow or Forbid, or inherit whatever the parent map resolves to, and the
  fields were parsed off `RPG_RT.lmt` but never fed into the runtime — so a
  dungeon the editor marked "no Teleport" never actually blocked it, and
  (since RPG2000's own schema default for the field is Allow) most maps'
  Escape / Teleport skills stayed permanently unusable outside a `Change
  Teleport/Escape Access` event command, when RPG_RT allows them by default
  almost everywhere. `Game::MapAccess.teleport_allowed?` / `#escape_allowed?`
  share the exact tree walk `#save_allowed?` already used (confirmed against
  EasyRPG's `Game_Map::Setup`, which re-derives all three
  `Game_System::Allow*` flags from their map-tree fields identically on every
  map load). `Scene::Map#apply_map_access` (renamed from
  `#apply_map_save_access`, now setting all three) recomputes
  `Game::State#teleport_access` / `#escape_access` alongside `#save_access` on
  the initial map load and on every Teleport: a `Control Teleport/Escape
  Access` event command can still override either for the rest of that map's
  visit, but the next map load re-derives it from the tree again, exactly as
  RPG_RT does. Covered by new checks in `scripts/rpg2k_logic_check.rb` (each
  method reads its own field rather than borrowing Save's, inheritance, and
  the Allow defaults) and `scripts/rpg2k_scene_check.rb` (`Scene::Map` reaches
  a real map tree on both the initial load and a Teleport to a second map with
  the opposite settings).
