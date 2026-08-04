- **Message text colours from the windowskin** — `\c[n]` message colours are
  now read from the game's own System graphic instead of a built-in
  approximation. `Game::MessagePalette` ports EasyRPG Player's system-colour
  layout (the 20 text colours are a 10×2 grid of 16×16 swatches starting at
  y = 48 in the 160×80 System image), and `Scene::Map` samples each swatch off
  the loaded windowskin with `Bitmap#get_pixel` to build the palette, falling
  back to the previous approximation only when no windowskin is present. The
  swatch geometry is pinned by `scripts/rpg2k_render_check.rb` and the sampling
  wiring by `scripts/rpg2k_scene_check.rb`.
