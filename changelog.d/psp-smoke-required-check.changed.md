- CI's `psp-smoke` job — which boots the PSP EBOOT under this flake's own
  patched PPSSPP headless build and checks for its `RPG2K_PSP_BOOT`/
  `RPG2K_PSP_BRINGUP` markers — is now a required check alongside `psp`
  instead of running with `continue-on-error`. It was left non-blocking from
  when the EBOOT did not yet boot to completion under PPSSPP-headless; now
  that it does (see `app/psp/README.md` and `docs/adr/0047-psp-memory-budget.md`'s
  addendum), the ten most recent `master` runs all captured the markers
  cleanly, so it gates the build like every other CI job.
