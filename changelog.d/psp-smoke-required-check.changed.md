- **CI:** the `psp-smoke` job (boots the PSP EBOOT under this flake's patched
  PPSSPP-headless) is now a required check instead of running with
  `continue-on-error`, and its assertion now requires *both* markers:
  `RPG2K_PSP_BOOT` (booted, output captured) and `RPG2K_PSP_BRINGUP` (the
  frame loop pumps). A BOOT-only grep would have stayed green through the
  weeks the boot crashed before its first heartbeat; BRINGUP now flows at
  thousands per run.
