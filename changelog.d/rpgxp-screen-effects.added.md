- RPG Maker **XP** events can now run the remaining screen effects: **Prepare
  for Transition** (221) and **Execute Transition** (222), **Screen Flash**
  (224) and **Screen Shake** (225).
  - 221 holds the screen on a snapshot above everything, so the teleport, tint
    or map change that follows happens behind it unseen; 222 dissolves that
    still away over twenty frames. RMXP reaches the same ordering by *blocking*
    in `Graphics.transition(20)` — its scene simply is not updated meanwhile —
    but a twenty-frame loop inside one frame callback is what the browser build
    cannot afford, so the interpreter suspends and the scene fades the still one
    frame per update instead. Only the foreground interpreter freezes: a
    background process is never suspended on a UI request, so its transition
    would never dissolve and the screen would stay stuck on a snapshot.
  - 224 and 225 go through a `Game::Screen` that carries RMXP's own maths — the
    flash's alpha scaled by `(d - 1) / d` so it reaches zero exactly as its
    duration runs out, and the shake's spring, which reverses past twice its
    power and snaps back to centre on the last frame rather than being left off
    to one side. The scene hands the results to the viewport that holds the map,
    as its colour overlay and its scroll origin — where `Spriteset_Map` puts
    them.
  - Between them 871 uses in Pray for You.
