# 0399. The Marshal save is dropped; the .lsd is the only save format, wio included

Date: 2026-10-10

## Status

Accepted. Supersedes docs/adr/0128's wio decision (wio keeps no Marshal save and
no .lsd exclusion any more) and docs/adr/0395's kill switch and old-save reading.

## Context

ADR 0395 made the `.lsd` authoritative, but kept the Marshal dump for two cases:
old `save<N>.mrb` saves, and wio, where `Game::State#to_lsd`/`.from_lsd` were
excluded (ADR 0128, flash budget). Keeping `Marshal` referenced from
`mruby-rpg2k` also made the bc2cpp closed world reach `Marshal`, which withdraws
every class pool under `BC2CPP_CLASS_POOLS=strict` (ADR 0296; measured: 3,439
by-name sends strict vs 2,372 default, and 222 NOMETHOD_REVIEWED violations).

## Decision

1. **`save<N>.mrb` is no longer read.** A slot holding only a `.mrb` counts as
   empty. This is an intentional breaking change for players with pre-0395 saves.
2. **wio writes and reads `Save<N>.lsd`.** `mruby-rpg2k/mrblib/game/lsd_io.rb` ships on every build:
   the wio-only exclusion in `mruby-rpg2k/mrbgem.rake` is removed. Compiled, the
   file is 30,609 bytes with the host mrbc (ADR 0128 recorded +28,512 bytes).
3. **No Marshal in the save path.** `RPG2k#save_game` writes the `.lsd` alone and
   fails the save if that write fails. `RPG2k#load_save_state` reads only the
   `.lsd`. `RPG2K_SAVE_MARSHAL_FIRST` (C++ and Ruby) is removed.
4. **Strict pools are no longer withdrawn by the save path.** The closed world no
   longer reaches `Marshal` through `mruby-rpg2k`. Measuring strict against default
   after this lands is a follow-up, not claimed here.

## Consequences

- Pre-0395 saves (`save<N>.mrb`) are unreadable. Existing players must finish or
  re-create those saves before updating.
- wio flash: the 30,609-byte file is added to the wio image. The real image size
  depends on the link, and no ARM toolchain was available here, so the wio flash fit
  is unverified. The wio CI shard does not run on recent master runs (see docs/ci.md).
- The wio stub-stripping logic (`wio_strip_bc2cpp_stubs`) assumed `lsd_io.rb` was
  absent. Its comments in `mrbgem.rake` still describe that. A wio build is needed to
  confirm the stripping does not remove a `Game::State` method the save path uses.
- `Game::State#to_h`/`.load` remain (they still serve the in-engine snapshots); only
  the save-file use is gone.

## Checks

- `scripts/rpg2k_lsd_authoritative_check.rb`: 19 checks pass under CRuby. The save
  policy checks now cover the `.lsd`-only default, the unread `.mrb`, the failed-write
  failure, and the unreadable `.lsd`. The field-by-field Marshal-vs-LSD comparison is
  unchanged.
- Not run here: the wio image build and the wio CI shard.

## Not built

- A one-time `.mrb` to `.lsd` migration (it would need `Marshal.load` outside the
  closed world).
- Measuring strict pools after this change.
