# 220. Compile unreachable RGSS features out of the wio build

Date: 2026-09-23

## Status

Accepted

## Context

The default `wio_rgss_boot` firmware overflows the Wio Terminal's
507,904 B of flash by 624,164 B at 7ed1848e.

wio builds exactly one maker, RPG2k (`rpg_maker_gems`, `single_format_only`).
Even so, `mruby-rgss` still links everything an RPG Maker XP/VX game needs.
The analysis of 7ed1848e's link map found three blocks that no wio code can
reach:

- **TrueType text.** stb_truetype and its glue take about 15.5 KB.
  - A face is found in only two ways: by scanning a `Fonts/` directory, or
    through `RGSS::Font.default_path`.
  - On wio, `opendir` is a stub that always fails, because newlib has no
    dirent.
  - Only the rpgxp, rpgvx and wolf boots set `default_path`, and none of
    them is built for wio.
  - Every `read_font` therefore ended in an unloaded face, and text always
    drew with shinonome.
- **The native `RGSS::Tilemap` and `RGSS::Window`**, about 10.5 KB and
  5.3 KB. RPG2k draws maps with its own tilemap and windows with
  `RPG2k::Window`.
- **The render/audio probes.** `RGSS.effect_probe` and `RGSS.audio_probe`
  plus seven helpers only they call, about 470 lines of `lib.rb`. Only
  `src/main.cxx`'s desktop `--rgss_effect_probe`/`--rgss_audio_probe` flags
  call them.

### Reachability

Reachability was checked, not assumed:

- **Tilemap/Window references.** A Prism walk of every wio mrblib file
  (`mruby-rpg2k`, `mruby-lcf`, `mruby-rgss`) finds 206 references to a
  `Window` or `Tilemap` constant.
  - 202 sit lexically inside `class RPG2k`, so they resolve to
    `RPG2k::Window` before `Object.include RGSS` is consulted.
  - The other four are inside the probes.
  - No `const_get` or computed `send` names either class. The closed-world
    lint (ADR 0212) keeps it that way.
  - In C, the only references are `lib.cxx`'s own registration and
    `vp_refresh_children`.
- **Probe callers.** Outside the probes themselves, `src/main.cxx` is the
  only caller. `app/wio/src/wio_rgss_boot_main.cxx` calls none of them.

## Decision

Under `WIO_TERMINAL`, the existing wio macro used by ADR 0126, 0132 and 0140:

1. **TrueType.** `STB_TRUETYPE_IMPLEMENTATION`, the `TtfFont` loader and
   cache, the `Fonts/` scan and the TrueType draw/measure paths are compiled
   out.
   - `read_font` still reads the font attributes.
   - It raises `NotImplementedError` when `RGSS::Font.default_path` is set.
     A future caller that asks for a face therefore fails loudly instead of
     silently getting shinonome.
2. **Tilemap and Window.** Both native sections, their registrations and
   `vp_refresh_children`'s Tilemap branch are compiled out.
   - Both classes are still defined, with an `initialize` that raises
     `NotImplementedError` naming the class.
   - `lib.rb`'s reopenings still load: the readers, and `Window`'s
     `alias_method :_rgss1_initialize, :initialize`.
   - `Tilemap.new` and `Window.new` therefore raise rather than returning an
     object that never draws.
3. **Probes.** `scripts/strip_wio_rgss_probes.rb` deletes the nine
   `def self.` probe methods from a build-time copy of `lib.rb`.
   - `build_config.rb`'s `wio_strip_rgss_probes` applies it. It is the first
     step of `mruby-rgss`'s chain, so it reads the checked-in source.
   - The script raises when:
     - a probe is missing or duplicated;
     - a def shares a line with other code;
     - anything left still calls a stripped name;
     - the output does not parse.
   - `scripts/wio_strip_scripts_check.rb`, which runs in CI, also fails if any
     wio mrblib file calls a stripped name after the whole chain.

Nothing changes for other targets.

## Consequences

Each step was measured with a full `wio_rgss_boot` link, the baseline
configuration of `scripts/wio_bc2cpp_measure.bash`:

| state | flash (text+extab+exidx) | `FLASH` overflow | step | static RAM |
| --- | ---: | ---: | ---: | ---: |
| 7ed1848e | 1,132,068 | 624,164 | | 32,296 |
| + TrueType out | 1,110,728 | 602,824 | −21,340 | 32,264 |
| + Tilemap/Window out | 1,092,800 | 584,896 | −17,928 | 32,264 |
| + probes stripped | 1,087,224 | 579,320 | −5,576 | 32,072 |
| **total** | | | **−44,844** | −224 |

- **A game on wio that needs these features fails loudly.** Supporting
  XP/VX text or tilemaps on wio would mean reverting the relevant guard.
- **The desktop probes are unchanged.** The `render_probe` and `audio_probe`
  ctests still exercise them.
- **The `RPGMAKER_BC2CPP=1` wio configuration was not rebuilt here.**
  `mruby-rgss-compiled` registers compiled readers on `RGSS::Tilemap` and
  `RGSS::Window`, which still exist, and compiled copies of the probes,
  which stay unreachable.
