- bc2cpp now records a bare `.new` receiver such as `Bitmap`, `Sprite` or
  `Weather` as the one class it can name (`RGSS::Bitmap`, `Game::Weather`).
  This happens only when the whole program defines that name once, never
  reassigns it, and the class is reachable from the call site.
  The 74 `Bitmap`/`Sprite`/`Viewport` ivar hints now name real classes but
  change no generated code, because every call on them is a native method.
  The `Game::Weather`/`Game::Variables` hints turn 10 call sites into guarded
  direct calls, including `Scene::Map#draw_weather` and `#pages_changed?`
  on the per-frame path. `Window` has two definitions and stays unresolved.
  See ADR 0203 and `scripts/bc2cpp_unique_class_names_check.rb`.
