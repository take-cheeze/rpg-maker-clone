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

WIO_NUMBERS_REPS

No behaviour changes. Every target keeps the same data, now read-only.
