# 224. Make mruby's dumped irep child tables const

Date: 2026-09-24

## Status

Accepted

## Context

Every gem's mrblib is compiled with `mrbc -S`, which goes through
`src/cdump.c` and emits each irep as static C structs. For an irep with
child ireps (blocks, method bodies of a class body) it writes

```c
static const mrb_irep *NAME_reps_N[len] = { &NAME_irep_1, ... };
```

The pointees are const, but the array is not. So the array goes to `.data`:
its initializer takes flash, and the startup code copies it into RAM. The
Wio Terminal has 192 KB of RAM. Nothing writes these arrays: `mrb_irep`'s
own `reps` field is already `const struct mrb_irep *const *`, and ireps
dumped this way are `MRB_IREP_STATIC`, so they are never freed.

## Decision

`patches/mruby-cdump-const-reps.patch` makes cdump.c emit
`static const mrb_irep *const NAME_reps_N[]`, which puts the arrays in
`.rodata`. It is applied to every build.

## Consequences

Measured with a full `wio_rgss_boot` link (the baseline configuration of
`scripts/wio_bc2cpp_measure.bash`):

- **Static RAM: −10,544 B.** `.data` shrinks from 12,720 to 2,176 B.
- **Flash: −320 B**, measured at the end of the load image (the last
  `.data`/`.hsram` load address). The arrays still take flash, now in
  `.rodata` instead of as `.data` initializers.

`ld`'s `region 'FLASH' overflowed by N` number rises by 10,216 B for this
change, and so does `scripts/wio_overflow_report.rb`'s "flash needed". Both
count `.text`, `.ARM.extab` and `.ARM.exidx`, but not the `.data`
initializers the image also carries in flash. So they show the bytes
arriving in `.rodata` but not the same bytes leaving `.data`. Making the
report count `.data` is a follow-up.

No behaviour changes. Every target keeps the same data, now read-only.
