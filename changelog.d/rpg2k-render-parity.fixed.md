- **RPG2000 rendering now matches the genuine RPG_RT**, from a frame-by-frame
  comparison under wine (ADR 0021):
  - **Nepheshel is playable again.** `Game::ChipsetLayout`,
    `Game::EventGraphic`, `Game::MessagePalette` and `Game::Parallax` declared
    their methods with a bare `module_function`, which mruby implements as a
    no-op — so the whole ported chipset / character / parallax geometry was
    missing from the shipped engine and New Game raised `NoMethodError`. The
    CRuby host checks could not see it. `Enumerable#none?` (not in this mruby
    build) crashed the engine mid-cutscene for the same reason.
  - The title command window is sized and placed the way RPG_RT places it
    (widest label + 16 wide, bottom edge at `height * 53 / 60`), and the
    selection cursor is drawn from the windowskin's own cursor block instead of
    a flat blue bar.
  - Window and message text is drawn RPG_RT's way: a shadow glyph from the
    System image's shadow block, then the glyph filled from the colour swatch.
  - The message window is the fixed 320x80 panel at the screen edge with 16px
    rows, not a box fitted to its text.
  - The engine runs at 60fps instead of ~44: frame pacing now targets a
    carried-forward deadline, so walk cycles, animated tiles, message reveal and
    Wait no longer run a quarter too slow.
  - A map change clears shown pictures and the Pan Screen offset / camera lock,
    and reloads the destination map's chipset graphic. Keeping the pan drew a
    320x240 map from (304, 352) — a blank screen — right after Nepheshel's
    opening.
  - The screen behind the map is black with no scrollbars, not LVGL's default
    light-grey panel.
