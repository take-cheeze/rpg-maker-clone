- MV tiling patterns (parallax backgrounds and battlebacks): the Canvas2D
  bridge now implements `createPattern` and a repeating pattern `fillStyle`.
  MV's `TilingSprite` — the map parallax layer and the battle background
  sprites — renders by cutting the texture into a pattern with
  `createPattern(canvas, 'repeat')` and filling a rect with it. `createPattern`
  previously returned an empty object, so those layers filled with nothing and
  rendered blank. It now returns a pattern that `fillRect` tiles: the new native
  (`__mv_canvasFillPattern` in `mruby-mvjs/src/mvcanvas.cxx`) wraps the source
  over the rect under the current transform, anchored at the user-space origin
  to match canvas `'repeat'` semantics. Unit-tested in
  `mruby-mvjs/test/canvas_test.rb` (tiling and transform anchoring).
