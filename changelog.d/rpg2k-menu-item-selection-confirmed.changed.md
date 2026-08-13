- **Scene::Menu's Item command reaching Scene::ItemMenu is now covered by a
  scene check, and its file comment no longer says otherwise.** The wiring
  itself (`select_command`'s `@parent.push Scene::ItemMenu.new(...)`) has
  been correct since `rpg2k-item-menu.added.md`, but the class comment at the
  top of `menu.rb` still read "the item/skill/equip/status screens are
  placeholders that report they are not implemented" — stale, and nothing in
  `scripts/rpg2k_scene_check.rb` asserted that pressing C on Item actually
  pushes a live `Scene::ItemMenu` rather than falling through to the generic
  "not implemented yet" message. Corrected the comment and added a check that
  drives each of the four scene-backed commands (Item, Skill, Equip, Status)
  and asserts the pushed scene's class.
