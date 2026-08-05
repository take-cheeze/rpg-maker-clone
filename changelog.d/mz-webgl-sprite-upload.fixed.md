- **RPG Maker MZ now actually draws.** The engine booted, played and presented
  frames, but everything except the tilemap came out blank — no title screen, no
  characters, no windows, no text. Two gaps in the native WebGL wrapper
  (`mruby-mvjs/src/mvwebgl.cxx`) were swallowing the pixels:
  - `texSubImage2D` was a no-op. PIXI re-uploads a texture whose size has not
    changed with it rather than `texImage2D`, so **every bitmap redrawn after
    its first upload** was lost — window contents, rendered text, and the tile
    pages rmmz's `Tilemap` sub-uploads into its 2048×2048 atlas. Both overloads
    (sized/typed-array and canvas/image source) now reach GL.
  - `bufferData`/`bufferSubData` accepted only a typed-array *view*, but WebGL's
    `BufferSource` is `ArrayBufferView | ArrayBuffer`, and PIXI v5's sprite
    batcher uploads its interleaved vertex block as the bare `ArrayBuffer`
    behind its views (`ViewableBuffer.rawBinaryData`). That upload silently
    became zero-length, so every batched sprite drew from an empty vertex
    buffer — degenerate triangles, no fragments — which is exactly why the
    tilemap (rmmz's own renderer, with its own geometry) was the only thing on
    screen.

  MZ now renders its title screen and command window, the map with the player
  sprite and touch UI, message windows with their text, and the full party menu
  over a blurred map background. Both fixes are covered at the pixel level on
  the real EGL backend by `mruby-mvjs/test/gl_test.rb`, and `--mz_battle_test`
  now waits for `Scene_Battle`'s fade-in before capturing its screenshot.
