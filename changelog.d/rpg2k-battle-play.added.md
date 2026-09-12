- **A headless "play the battle out" driver for RPG Maker 2000/2003 combat**,
  `--rpg2k_battle_play` (requires `--rpg2k_battle_troop=N`): once the fight
  opens, it taps confirm through the Battle/Auto Battle/Escape options
  window, the per-actor Attack command and the enemy-target cursor —
  `RGSS::Input.press`/`.release` on the same key-edge tap-and-release cadence
  as MZ's existing `--mz_battle_play` — relying on the default selections
  (Battle, Attack, the first living foe) rather than navigating there, until
  the enemy troop's HP falls and the battle hands back to the map, then logs
  `[RPG2k-BTLPLAY] hp_before=... hp_after=... alive=... damaged=... ended=...`
  to `$stderr`. `--rpg2k_battle_troop` alone only proves a fight can be
  *entered* ([RPG2k-BATTLE] fires the instant the screen is built, before any
  command is taken); this covers what lies between that and combat actually
  resolving. `RPG2k::Scene::Map` gained a small `#active_battle` reader so the
  driver (which lives outside the scene, in `RPG2k#maybe_battle_play_test`)
  can read the live `Game::Battle` model's enemy HP and the fight's phase.
  `scripts/rpg2k_boot_check.bash` now runs it against a real multi-round
  Nepheshel fight (troop 6) and fails if the run ends before the fight does,
  no attack ever lands, or the battle never resolves.

  This was built to get real per-frame allocation numbers *during actual
  combat* (attacks landing, HP changing, gauge redraws) rather than an idle
  battle menu, to settle whether the gauge-card digit/bar rendering's
  per-digit `Rect.new`/`Color.new` allocations (`draw_number_system2` et al.,
  `mruby-rpg2k/mrblib/scene/battle.rb`) are a genuine allocation-reduction
  opportunity. Measured on real fights (Nepheshel troops 4 and 6, profiler
  trace's `mruby_type_allocs` cumulative counters sampled every 2s across the
  whole fight, cross-checked by stderr line order against the trace's own
  sample sequence): "C data" (the `MRB_TT_CDATA` bucket Rect/Color/Tone/Table
  fall into) does spike during actual attack-resolution intervals — real
  command-menu-draw + target-select + animate + damage rounds measured
  ~330-400 allocs/s, versus ~46-50/s once the same fight settles back onto
  the idle map afterward (~7-8x) and ~50-140/s during an enemy-only round
  with no player menu redraw. In absolute terms that peak is still only
  ~6-8% of the same interval's own Array rate (~4700-5200/s) and ~17-20% of
  its Proc rate — nowhere near dominant, and small next to the map scene's
  own already-tuned steady-state budget (Array ~4027/s, Proc ~1653/s, env
  ~990/s), which real combat's Array/Proc numbers land within the same order
  of magnitude of (env runs ~1.6x the map's own baseline during combat, the
  only type that moves by more than roughly a third). No fix was made: the
  effect is real and attributable to `#refresh_battle_status`, but not large
  enough to be a genuine allocation-reduction opportunity by this session's
  own bar (contrast `Bitmap#blt_quads`'s measured ~45-60ms win on a genuinely
  hot per-frame path) — reported honestly rather than manufactured.
