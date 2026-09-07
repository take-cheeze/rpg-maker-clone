- The map-walk port (iPod nano 7G and Wio Terminal) **animates**: the water
  autotiles and the block-C animated tiles now move on RPG2000's own two
  clocks instead of being frozen at their first frame. The export asks
  `Game::ChipsetLayout.anim_ab` / `.anim_c` what those clocks are — their step
  lengths, and the ping-pong the water does for one `animation_type` and not
  the other — rather than restating any of it, so a chipset the exporter has
  never seen animates the way the engine would animate it. A cell now names an
  entry (up to four atlas slots plus the clock that moves them), a tile whose
  frames are identical is recorded still, and the device redraws only the
  cells that moved. Costs 480 bytes of device code and 1.3 KB of RAM; the
  worst map in the test bed needs 180 of 255 atlas slots. Format version 5:
  re-export before installing, or pass `--no-animate` for the old still
  export. See ADR 94.
