- **Docs:** corrected four live doc comments in `mruby-rpg2k/mrblib/` that
  still described already-shipped features as "still to come" -- no
  behavior changed anywhere, only comments that had drifted out of date as
  the features they described landed in later cycles:
  - `Game::Screen`'s class doc said applying a Tint Screen as an
    `RGSS::Viewport` tone was "the native (C++) half still to come, so the
    tint does not yet draw", and that the class "models two effects so
    far" with "Flash will join the class the same way" -- but the tint has
    reached the map viewport (and the battle backdrop) since the "screen
    tone reaches the map" work, and `Flash`/`Pan`/`Fade` were all added to
    this same class long ago alongside `Tint`/`Shake`.
  - `Interpreter#do_weather`'s doc said "compositing the rain/snow
    particles is native renderer work still to come" -- but
    `Scene::Map#draw_weather` has drawn the weather overlay (rain streaks,
    drifting snow) every frame since it was added.
  - `Scene::Map#perform_game_over`'s doc opened with "Stop the event and
    return to the title screen -- the faithful end state. (RPG2000 shows a
    Game Over graphic first; that screen is native renderer work still to
    come.)", directly contradicted by the very next sentence in the same
    comment block describing the already-implemented Game Over screen --
    a leftover first draft that was never deleted once the real
    description was written beside it.
  - `Game::Battle`'s class doc called it "a deliberately simple first cut"
    with "escape and enemy-cast state infliction still to come" -- but
    `#attempt_escape` and `#inflict_state` (fed from both an ally's and an
    enemy's own skill picks) are implemented directly on this class, which
    is now the ~4000-line engine driving `Scene::Battle`'s live fights,
    not a stand-in for one.
