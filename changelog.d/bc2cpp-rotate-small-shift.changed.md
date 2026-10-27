- **bc2cpp**: the NATIVE_CORE_DIRECT `Array#rotate!` mirror moves a shift whose short side is at most 16 values
  through a stack buffer and `memmove` instead of mruby's triple reversal (ROTATE_SMALL_SHIFT), which stays for
  longer shifts. optcarrot's `@bg_pixels.rotate!(8)` takes the new path, about 0.37M fewer instructions per frame
  (1.2%). New check `scripts/bc2cpp/rotate_small_shift_check.rb`.
