- **Text sat 2px high in every window that did not pad it by hand.**
  `RGSS::Bitmap#draw_text` and `#blend_text` top-aligned the 12px shinonome
  bitmap cell inside the rect they were given, where RGSS (and this engine's
  own TrueType path) centre a line in it. RPG2000's 16px rows therefore came
  out right only in the scenes that added the missing 2px themselves
  (`Scene::Title`, `Scene::Menu`, `Scene::ItemMenu`) and 3 ink rows high
  everywhere else -- the load screen, the battle panels and the map message
  window. The centring now lives in the renderer and the hand-written pads are
  gone. Measured against a genuine `RPG_RT.exe` under wine (Nepheshel): the
  load screen's `デモ用` line inked screen rows 65..76 against RPG_RT's 68..77
  and the battle status row 168..180 against 171..181; both now land on
  RPG_RT's rows. Covered by new pixel tests in the `mruby-rgss` gem test and a
  new `scripts/rpg2k_scene_check.rb` check.
