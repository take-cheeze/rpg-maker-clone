# Patches on the take-cheeze forks

The vendored upstream code the build compiles is pinned to take-cheeze forks,
and those fork commits carry the patches this project needs. The patch files
no longer live in `patches/`.

## What the build uses

- **`3rd/mruby`, `3rd/mruby-stringio`, `3rd/mruby-marshal`,
  `3rd/mruby-onig-regexp`** are submodules pinned to the fork commits listed
  below. `.gitmodules` points at the forks. Nothing is applied at build time.
- **pspsdk** (`scripts/build/psp_fixup_imports.bash`, `flake.nix`) builds
  psp-fixup-imports from the fork commit `723862d`.
- **ppsspp** (`flake.nix`) builds `take-cheeze/ppsspp` at commit `70cb2fb`,
  which is the v1.20.4 release plus the seven local patches.

## Branch conventions

- **`rpg-maker-clone/patches-pin`**: starts at the commit this project pins
  (submodule or flake), and carries the patches on top. This is what the build
  compiles.
- **`rpg-maker-clone/patches`**: starts at the fork's default branch. Used for
  patches that do not apply to the pin.
- Each commit's message names the source patch it came from.

## Status by patch

Status key: **applied** (commit on a tracking branch), **in pin** (already in
the pinned commit, no commit needed), **not applied** (see the note).

### take-cheeze/mruby (pin `67a569e`, `rpg-maker-clone/patches-pin` at `eab0234`)

Applied on the pin, in build order: `mruby-colon3-assign-setmcnst`,
`mruby-dollar-bang-scoped`, `mruby-defined-keyword`, `mruby-module-function-scope`,
`mruby-parser-dump-back-nth-ref`, `mruby-nomemoryerror-reentrant-alloc`,
`mruby-gc-type-live-counts`, `mruby-rdata-ivar-slots`,
`mruby-io-maxpathlen-fallback`, `mruby-io-file-size-bigint`,
`mruby-io-read-direct`, `mruby-force-no-cxx-exception-escape-hatch`,
`mruby-presym-compact-table`, `mruby-cdump-const-reps`, `mruby-no-irep-debug`,
`mruby-expose-misc-bodies`, `mruby-expose-index-bodies`,
`mruby-expose-collection-op-bodies`, `mruby-frozen-string-literal-persist`,
`mruby-cxx-novolatile`, `mruby-vm-goto-table-void`: **applied** (21 commits).

- `mruby-io-direct-puts`: **in pin**.
- `mruby-module-function-scope`: applied with `patch -p1` (the hunk headers do
  not satisfy `git apply`), as the build's apply script does.


Regenerated files: the mruby-defined-keyword change edits `keywords` and
`parse.y`, so its generated `lex.def` and `y.tab.c` are regenerated on the pin
branch (`eab0234`). The build used to force that regeneration by applying the
patch; the pinned tree has no such step, so the generated files must be
committed up to date.

### take-cheeze/mruby-stringio (pin `41eb37e`, `rpg-maker-clone/patches-pin` at `c3a3e11`)

- `mruby-stringio-native-getbyte`: **applied**.
- `mruby-stringio-read-direct`: **applied**. It applies only on the pin, not on
  the default branch.

`rpg-maker-clone/patches` (`c034c07`) carries `native-getbyte` on the default
branch. It is superseded by the pin branch.

### take-cheeze/mruby-marshal (pin `7da40de`, `rpg-maker-clone/patches-pin` at `a628ef1`)

- `mruby-marshal-psp-wio-onigmo-optional`: **applied**.

### take-cheeze/pspsdk (pin `314b2083`, `rpg-maker-clone/patches-pin` at `723862d`)

- `psp-fixup-imports-jal-relocation-aware`: **applied**.

`rpg-maker-clone/patches` (`ddc7b6f`) carries the same patch on the default
branch. It is superseded by the pin branch.

### take-cheeze/mruby-onig-regexp (pin `4962d7e`, `rpg-maker-clone/patches-pin` at `a8d3772`)

- `mruby-onig-regexp-no-chdir`: **applied**.
- It does not apply to the default branch (`db01151`), which rewrote
  `mrbgem.rake` (Onigmo 6.1.3, changed build tasks). Porting it there needs a
  manual change across three `Dir.chdir` blocks, including the Windows path.
- `rpg-maker-clone/mattn-no-chdir` (`b782dcf`) carries the same change on top of
  mattn's `master`, which is the same commit as the pin. mattn's repo itself is
  not pushed to.

### take-cheeze/ppsspp (pin `v1.20.4`, `rpg-maker-clone/patches-pin` at `70cb2fb`)

The flake builds this commit. All seven patches apply in the flake's order, one
commit each:

- `ppsspp-lwmutex-workarea-validate`: **applied**.
- `ppsspp-mfic-mtic-interrupt-mask`: **applied**.
- `ppsspp-x64analyzer-8bit-mov`: **applied**.
- `ppsspp-sysclibforkernel-missing-functions`: **applied**.
- `ppsspp-sysclib-memset-memmove-return-value`: **applied**.
- `ppsspp-sysclib-strchr-strrchr`: **applied**.
- `ppsspp-sceio-null-path-validate`: **applied**.

The `rpg-maker-clone/patches` branch on the fork (`7bd75e5`) carries the first
four on the fork's default branch. It is superseded by the pin branch.

## Remaining work

- Confirm CI builds the flake's ppsspp from the fork commit (`flake` and
  `psp-smoke` jobs). Nothing else is left to port.
