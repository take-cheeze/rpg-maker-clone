- The **RGSS2 / RGSS3 built-ins** a VX / VX Ace project's own scripts call, so a
  bundle can actually run on the script host (a VX game's engine *is* its script
  bundle). Measured against the stock VX Ace script set — 109 sections, ~19.9k
  lines — and tracked in
  [`docs/rpgvx-rgss-api-gap.md`](docs/rpgvx-rgss-api-gap.md), the new
  counterpart to the XP gap document:
  - **`Input` symbol keys.** RGSS2/RGSS3 name keys as symbols
    (`Input.trigger?(:C)`) and the stock scripts use *nothing else*, where XP
    used integer constants. `RGSS::Input` now accepts either spelling through
    one key table (`SYMBOL_KEYS`), leaving the XP/RPG2000 callers and the C++
    input bridge untouched; an unrecognised key reads as unpressed and is
    reported once instead of raising out of the game loop.
  - **`Graphics.width`/`height`** (~82 uses: VX's camera and every window layout
    are computed from them) via a new `resize_screen`, which each maker's boot
    shell calls with its own resolution — the VX shell declares 544×416, the
    size `src/main.cxx` opens the window at. Plus RGSS2's `wait`, `fadeout`,
    `fadein` and `brightness`: the waits run **real frames**, so a scene that
    holds for a fade takes the right time (`transition` now consumes its frames
    too, instead of returning instantly).
  - **`RPG::BGM`/`BGS`/`ME`/`SE` play themselves.** In RGSS2/RGSS3 the audio
    records carry behaviour (`$game_system.battle_bgm.play`, `@map_bgm.replay`,
    `RPG::BGM.fade(1000)`, `RPG::SE.stop`): `#play`/`#replay`/`#stop`/`#fade`
    plus the class-side `last`/`stop`/`fade`, routed to `RGSS::Audio`, including
    RGSS's "an empty name stops the channel" rule and the `last` slot a save
    restores from.
  - **`Window` RGSS2/RGSS3 surface** — `openness` with `open?`/`close?` (the
    open/close animation the scripts drive themselves), `padding` /
    `padding_bottom`, `arrows_visible`, `tone`, and the VX-shaped constructor
    `Window.new(x, y, width, height)` alongside XP's optional-viewport form.
  - **RGSS3 Kernel methods** — `rgss_main` (the entire `Main` section of every
    VX Ace project), `rgss_stop`, `msgbox` / `msgbox_p` — and `Audio.setup_midi`.
  `scripts/rpgvx_testbed_check.rb` now boots each generated project through a
  `rgss_main { … }` Main that loads the database, plays its title BGM and waits
  frames, so the path is exercised end to end; the rest is covered by new
  `mruby-rgss/test` and `mruby-rpgvx/test` cases.
