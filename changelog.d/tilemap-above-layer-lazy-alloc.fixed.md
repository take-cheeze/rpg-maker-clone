- Fixed a real resource-waste bug in `mruby-rgss`: every native `Tilemap`
  unconditionally allocated a second, internal LVGL canvas for the priority
  "above" layer (roofs/tree crowns sorting over character sprites) at
  construction time, even though ADR 0022's per-row priority scheme means an
  RPG Maker XP tilemap's own priority tiles route through the per-row strips
  exclusively and never draw a single pixel into that companion canvas -- only
  the VX/VX Ace tile model still uses it, as a flat "above characters" layer.
  Every XP tilemap therefore paid a permanent, always-blank 1.17 MiB canvas
  (at XP's 640x480) plus a wasted per-refresh viewport-tone pass walking all
  of its pixels, for a layer that could never show anything -- dead weight on
  every RPG Maker XP game, including the psp/wio targets this code is shared
  with. The above layer is now allocated lazily, on the first VX-path refresh
  that actually needs it (mirroring the same lazy shape the per-row priority
  strips already use), and picks up whatever `z`/`visible` the tilemap already
  has at that point rather than the fixed defaults the old eager allocation in
  `Tilemap.new` could assume.
