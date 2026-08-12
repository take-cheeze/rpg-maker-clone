- CI's RPG XP real-game boot smoke now runs its four engine-boot passes
  (script host and battle and save on the editor test bed, script host on
  Pray for You) as four separate, concurrent steps instead of one step that
  ran them serially. `scripts/rpgxp_boot_check.bash` gained `RPGXP_BOOT_PASS`
  to select a single pass per invocation; unset, it still runs every pass that
  applies to each requested game, as before.
