- **`flake.nix`'s `ppsspp` package now carries a local patch fixing a real
  PPSSPP-headless crash.** `sceKernelCreateLwMutex`
  (`Core/HLE/sceKernelMutex.cpp`) dereferenced its caller-supplied workarea
  pointer without validating it first, unlike every sibling `LwMutex`
  function in the same file — a guest passing `workareaPtr=0` turned that
  into a null-pointer write that segfaulted the *host* `ppsspp-headless`
  process rather than raising a guest-catchable error (confirmed with `gdb`
  against a core dump, same crash address across independent runs). Found
  while trying to read the PSP EBOOT's own boot log under PPSSPP-headless
  (see `docs/adr/0047-psp-memory-budget.md` and `app/psp/README.md`). Not yet
  upstreamed to `hrydgard/ppsspp`, so `nix/patches/
  ppsspp-lwmutex-workarea-validate.patch` applies it locally via
  `pkgs.ppsspp.overrideAttrs` — both CI's `psp-smoke` job and a local
  `nix build '.#ppsspp'` now build PPSSPP from source with the fix rather
  than fetching nixpkgs' prebuilt (unpatched) closure, a real but one-time
  CI cost. A second, separate bug remains unfixed and is what actually stops
  the EBOOT from booting under PPSSPP now — see the ADR's P1 for the trail.
