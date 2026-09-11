- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler's `.singleton` owner
  support (previous round) now covers five more real RGSS classes'
  singleton methods, not just `RGSS::Bitmap`'s: `RGSS::Audio.singleton`
  (13 methods -- `bgm_volume`/`bgm_pan`/`bgm_stop`/`bgm_fade`/`bgm_pos`,
  `bgs_stop`/`bgs_fade`/`bgs_pos`, `me_stop`/`me_fade`, `se_stop`,
  `midi_available?`/`setup_midi`), `RGSS::Input.singleton` (11 --
  `key_index`, `press`/`release`/`press?`/`trigger?`/`repeat?`,
  `dir4`/`dir8`, `mouse_x`/`mouse_y`/`mouse_pressed?`),
  `RGSS::ErrorReport.singleton` (6 -- `push`, `installed?`, `record`,
  `clear`, `probe!`, `probe_raise`), `RGSS.singleton` (5 --
  `warn_once`/`warn_stub`, `transition_shape_probe`, `window_probe`,
  `tilemap_above_layer_probe`), and `RGSS::Graphics.singleton` (4 --
  `resize_screen`, `brightness=`, `freeze`, and the private
  `brightness_sprite` helper). 38 of these 39 are now real,
  `mrb_define_class_method`-registered entry points; `Graphics.singleton#
  brightness_sprite` compiles and is reachable via an already-
  devirtualized same-owner call from `brightness=` but is deliberately
  left unregistered, since it is genuinely `private` in the real source
  and mruby's public API has no way to register a private class method.

  Confirms the `.singleton` owner mechanism generalizes correctly across
  classes: bare constant references inside these methods' bodies
  (`SYMBOL_KEYS`/`UP`/`DOWN`/`LEFT`/`RIGHT` in `RGSS::Input`,
  `MAX_LINE_CHARS` in `RGSS::ErrorReport`, `Bitmap`/`Color`/`Sprite` at the
  enclosing `RGSS` scope from `RGSS::Graphics`) all resolve at the correct
  owner scope in the real generated code, same-owner (and cross-
  `.singleton`-owner) calls correctly MONO-devirtualize into direct C++
  calls with zero `mrb_funcall` fallback, and a real, function-by-function
  diff against the previous generated output shows every one of this
  gem's own 40 already-shipped methods byte-for-byte unchanged.
