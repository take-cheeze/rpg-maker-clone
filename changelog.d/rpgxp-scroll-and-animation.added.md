- RPG Maker **XP** events can now **Scroll Map** (203) and **Show Animation**
  (207) — the last two commands a real game uses that had no handler.
  - 203 pushes the camera off the party leader for a cutscene. RMXP has no
    separate notion here (`$game_map.display_x/y` *is* its camera), but ours
    derives the camera from the leader every frame, so the commanded scroll is
    carried as an offset on top and clamped to the map the same way the follow
    camera is. A second Scroll Map holds the command list until the first has
    finished, as `command_203` does by asking to be run again.
  - 207 plays an `RPG::Animation` on the player or any event: its cells are
    blitted from the 192x192 grid of the sheet in `Graphics/Animations` with
    each cell's own offset, zoom, angle, mirror, opacity and blend type, held
    four game frames per animation frame, anchored over / on / under the target
    or fixed to the screen, and its per-frame timings play their sound effect
    and flash either the target or the whole screen. RGSS centres a cell with
    `ox`/`oy` = 96, which is not wired to where a sprite draws here, so the
    half-cell comes off the position instead, scaled with the zoom.
