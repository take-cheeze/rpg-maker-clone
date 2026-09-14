- **Maix Amigo Renode boot**: `scripts/maix_renode_boot.bash` boots the P0
  firmware under stock Renode (which ships the K210 SoC description, so no
  from-source emulator build) and CI's new `maix-smoke` job asserts the
  `setup()`/`loop()` hooks plus the Serial hello and heartbeat. See
  `app/maix/README.md`.
