- **PSP devshell** now derives from the `build` package via `overrideAttrs`
  instead of re-listing its host tools, so anything added to the native build
  environment (including the gperf/bison pair mruby's lexer regeneration
  needs) reaches `nix develop .#psp` without a second list drifting out of
  sync. Only the PSP-specific additions (`pspdev`, `pkg-config`, PPSSPP) are
  declared in the shell itself.
