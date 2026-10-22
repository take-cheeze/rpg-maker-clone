# Patch tracking on forks

The `patches/` directory holds the patches this project applies to vendored
upstream code. Each patch also has a tracking branch on a `take-cheeze` fork of
its upstream, so the change can be reviewed and rebased there. This page lists
where each patch lives. The build still applies the patches from `patches/`;
the forks are not yet wired into the build.

## Branch conventions

- **`rpg-maker-clone/patches-pin`**: starts at the commit this project pins
  (submodule or flake), and applies the patches in the order the build applies
  them. Use this branch to match what the build actually compiles.
- **`rpg-maker-clone/patches`**: starts at the fork's default branch. Used where
  the patch does not apply to the pin, or where the upstream has moved on.
- Each commit's message names its source file in `patches/`.

## Status by patch

Status key: **applied** (commit on a tracking branch), **in pin** (already in
the pinned commit, no commit needed), **not applied** (see the note).

### take-cheeze/mruby (pin `67a569e`, `rpg-maker-clone/patches-pin` at `1316065`)

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

### take-cheeze/ppsspp (default branch, `rpg-maker-clone/patches` at `7bd75e5`)

Applied on the default branch, since the build does not pin ppsspp (it uses
nixpkgs' copy):

- `ppsspp-lwmutex-workarea-validate`: **applied**.
- `ppsspp-sceio-null-path-validate`: **applied**.
- `ppsspp-sysclib-memset-memmove-return-value`: **applied**.
- `ppsspp-sysclib-strchr-strrchr`: **applied**.
- `ppsspp-mfic-mtic-interrupt-mask`: **not applied**. It conflicts with the
  current code and needs a manual port.
- `ppsspp-sysclibforkernel-missing-functions`: **not applied**. Same reason.
- `ppsspp-x64analyzer-8bit-mov`: **not applied**. Same reason.

## Remaining work

- Port the three ppsspp patches listed as not applied.
- Decide whether the build should use the fork branches instead of the
  patches in `patches/`. Doing so changes how CI and the local scripts apply
  them, so it is a separate change.
