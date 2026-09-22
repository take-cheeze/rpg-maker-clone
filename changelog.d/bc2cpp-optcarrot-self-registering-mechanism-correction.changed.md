- `tools/optcarrot_probe/README.md` corrects #1870's own speculative
  explanation for `BC2CPP_SELF_REGISTERING`'s measured 6.2% wall-clock win:
  the "3 synthesized struct-aware accessor methods" theory is wrong (all 3
  have zero executions in the benchmark -- `Pad#buttons`/`#buttons=` are
  unreachable with `input: :none`, and `CPU#ppu_sync=`'s only real caller
  lives in `optcarrot/mapper/mmc3.rb`, which isn't even among this probe's
  loaded sources). The real mechanism, found by diffing `emit_register`'s
  own installed-method list directly: `BC2CPP_SELF_REGISTERING` unlocks
  48 more real, previously fully-interpreted hot-path methods across
  `Optcarrot::ROM` (including the cartridge memory-access path),
  `Optcarrot::Pad`, `Optcarrot::APU`, and `Optcarrot::APU::DMC`, not just
  the 3 embedded `CPU` ivars the original framing centered on. No code
  changed; this replaces a guess with a verified mechanism.
