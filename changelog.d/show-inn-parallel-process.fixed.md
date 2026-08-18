- **Events:** Show Inn issued from a Parallel Process now actually opens the
  inn screen, matching real RPG_RT — it used to be a silent no-op, the same
  defect Open Shop and Enter Hero Name had before their own earlier fixes.
  Also reproduces a documented RPG_RT quirk EasyRPG's own source calls out: a
  *priced* stay issued from a Parallel Process now barges open over an
  already-open message window instead of waiting for it to clear, while a
  *free* stay still waits, matching the asymmetry in real RPG_RT. Covered by
  two new `scripts/rpg2k_scene_check.rb` checks.
