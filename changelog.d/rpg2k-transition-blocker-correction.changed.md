- **Corrected the note on what the remaining screen transitions need.** They were
  written up as waiting for a screen capture the renderer does not have.
  `RGSS::Graphics.snap_to_bitmap` does exist, is tested, is enabled on the builds
  that draw (`LV_USE_SNAPSHOT`; the Wio/PSP builds compile it out and it answers
  nil there), and the **RPG Maker XP scene already uses it** for its own
  Prepare for Transition. `docs/TODO.md` now says what each remaining style
  actually needs: the scrolls, combine / division and zoom want the overlay
  painted as a full composite from a capture rather than as a mask (`blt` /
  `stretch_blt`, no native work); only mosaic and wave want a native per-pixel
  pass; and random blocks wants RPG_RT's incremental block paint. It also records
  the one wrinkle a Show Screen has — its capture would include the erase overlay
  currently hiding the scene — and that the RPG2003 test-bed uses zoom / mosaic /
  wave twelve times, which is what makes the family worth finishing.
