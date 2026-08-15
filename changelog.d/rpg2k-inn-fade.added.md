- **Show Inn** (RPG Maker 2000, command 10730) now fades the screen the way
  real RPG_RT does: accepting a stay — or a free (price 0) stay auto-accepting
  — fades to black *before* the heal, holds through it, then fades back in,
  instead of cutting straight from the prompt to the healed party with no
  transition. `Scene::Map#drive_inn` reuses the same Erase/Show Screen overlay
  and default 35-frame `FADE_OUT`/`FADE_IN` styles rather than a bespoke fade:
  new `#start_inn_fade_out` erases the screen the instant Accept is confirmed
  and parks on a new `@inn_fading_out` sub-state until it settles; `#finish_inn`
  then charges gold, heals the party and starts the fade back in before
  resuming the interpreter. Cancel and an ignored (unaffordable) Accept skip
  the fade entirely, matching real RPG_RT — a declined or unaffordable prompt
  never fades. Covered by a new `scripts/rpg2k_scene_check.rb` check pinning
  the exact fade-out/hold/fade-in frame timing, plus fade assertions on the
  existing cancel and unaffordable-Accept checks.
