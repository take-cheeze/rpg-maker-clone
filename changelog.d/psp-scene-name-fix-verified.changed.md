- **Verified the `current_scene_name` `.to_s` fix ([#1349](https://github.com/take-cheeze/rpg-maker-clone/pull/1349))
  against a real `psp-smoke-game` CI run.** Every `RPG2K_PSP_BRINGUP`
  heartbeat now reads `scene=RPG2k::Scene::Title` where it previously always
  read `scene=none`, confirming the per-scene memory attribution documented
  in `docs/adr/0047-psp-memory-budget.md`'s P1b actually works on real
  device output. No code change -- this fragment records the CI-confirmed
  result.
