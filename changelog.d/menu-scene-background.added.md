- **The field menu (Scene::Menu) now has a proper background** instead of
  showing the frozen map through the gaps between its windows. The whole
  screen is filled with the windowskin's own background chip — the same
  32x32 tile every `RPG2k::Window` stretches over its own interior — stretched
  across the full 320x240, matching RPG_RT's menu backdrop. New
  `Scene::Base#build_field_background` is shared so the item/skill/equip/
  status sub-screens get the same treatment for free, since they never pop
  the menu underneath them.
