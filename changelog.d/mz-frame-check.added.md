- **The MZ smoke tests now look at the picture.** Every assertion in
  `scripts/mz_boot_check.bash` read the engine's *log* — Scene_Map was reached,
  `Window_Message` reports itself open, the save chain settled — and none of them
  looked at a pixel, which is how MZ spent a milestone passing every probe while
  the captured frames were nearly empty. `scripts/mz_frame_check.rb` decodes the
  captured PNGs (a small pure-Ruby reader for the subset stb_image_write emits)
  and asks two things the log cannot answer. Per frame: the scene's art actually
  reached it (a map frame that lost its tiles is 99.5% one colour against 68.5%
  intact), and the message window's band carries enough distinct colours to mean
  glyphs (105 with contents uploading, 18 without). Across frames: the message
  frame differs from the plain map frame in the bottom band *and only there*, the
  menu and battle frames replace it, and the post-save frame is back on it. The
  boot check runs the single-frame half itself, so each mode still fails on its
  own; the comparisons run once all five frames exist. Verified by rebuilding
  with the `texSubImage2D` fix reverted: every boot-check mode still reports OK,
  and the frame check fails.
