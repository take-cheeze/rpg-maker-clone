- CI: dropped the standalone `screenshots` job (and `scripts/take_title_screenshot.bash`).
  It ran the original `RPG_RT.exe` under Wine/Docker to capture reference images of the
  reference engine — it never built or exercised this project, and nothing consumed its
  artifact. The `build` job already smoke-tests the clone with real screenshots and covers
  RPG2000 rendering via `scripts/rpg2k_render_check.rb`.
