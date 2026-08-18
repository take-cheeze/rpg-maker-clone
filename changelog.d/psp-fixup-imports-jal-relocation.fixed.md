- **The `psp` CI job now builds the PSP EBOOT with a patched
  `psp-fixup-imports`, fixing a real boot blocker.** pspsdk's post-link
  import-table tool requires every call site referencing a given PSP module
  to already be physically contiguous in the linked binary — a requirement
  this EBOOT's own `main.cxx` doesn't satisfy, since it calls into several
  PSP modules in ordinary control-flow order (confirmed: this reflects
  genuinely necessary separation in the program's own logic, not an
  accidental ordering slip a source reorder could fix). When out of order,
  the stock tool silently assigned several genuine, correctly-named imports
  the wrong `(module, function)` index, so calls into them returned
  `SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED` unchecked — this was what
  actually stopped the EBOOT booting to completion under PPSSPP-headless
  even after every other known bug on that path was fixed. A metadata-only
  regroup patch was tried first and found unsafe (confirmed to silently
  misdirect syscalls to the wrong function); the real fix additionally scans
  every executable section for `jal` instructions targeting a moved import
  slot and repoints them — the relocation work an ET_EXEC binary's loader
  would need but this prebuilt tool skips.
  `patches/psp-fixup-imports-jal-relocation-aware.patch` (pinned against a
  specific pspsdk commit) carries the fix;
  `scripts/build_psp_fixup_imports.bash` fetches pspsdk at that pin, applies
  it, and drops the rebuilt tool in place of the toolchain's own, wired into
  the `psp` CI job ahead of `psp-cmake`/`cmake --build`. Not yet upstreamed
  to `pspdev/pspsdk`. With this fixed, the EBOOT now boots dramatically
  further under PPSSPP-headless than at any earlier point — past
  `RPG2K_PSP_BOOT`, through `mrb_open`, into real LVGL widget creation —
  before hitting a new, separate, not-yet-fixed bug; see
  `docs/adr/0047-psp-memory-budget.md`'s P1 for the full trail.
