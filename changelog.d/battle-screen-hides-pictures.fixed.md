- **Pictures no longer show through the battle screen.** yado.tk / the
  viprpg-dev wiki's `01_shoshin`/`011_siyou` sweep: "Picture -- none show on
  Menu/Battle screens." The Menu half was already correct --
  `Scene::Base#build_field_background` paints an opaque panel above the
  picture layer (`@picture_sprite`, z 250) specifically so nothing behind the
  menu shows through, and `Scene::Map#update` (and with it `#render`) simply
  is not called while `Scene::Menu` sits on top. The battle screen has no
  equivalent scene push -- it runs inline on the same `Scene::Map`, gated only
  by `@battle_ui` -- and nothing painted over the picture layer for it: the
  battle backdrop (`@battle_ui[:back_sprite]`) sits at a much lower z, so a
  picture shown before the encounter, or by a Parallel Process still running
  during it, drew straight over the battle UI. `#render` now hides
  `@picture_sprite` and skips compositing entirely for as long as `@battle_ui`
  is set, and un-hides and resumes drawing the instant it clears. Covered by
  a new `scripts/rpg2k_scene_check.rb` check, confirmed to fail against the
  pre-fix code before the fix.
