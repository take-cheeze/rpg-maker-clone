- MV canvas `stroke`: the Canvas2D bridge now strokes a path instead of ignoring
  the call. Each segment is drawn as a `lineWidth`-thick quad filled through the
  polygon rasteriser, honoring the current transform, `globalAlpha` and composite
  mode. MV core doesn't stroke paths, but the plugins most published MV games
  ship (custom HUDs, gauge and window borders) do, and previously drew nothing.
  Butt caps, no joins — enough for the thin lines plugins use; solid
  `strokeStyle` only. Unit-tested in `mruby-mvjs/test/canvas_test.rb`.
