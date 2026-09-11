- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers
  `LCF::File#[]`/`#[]=` in `mruby-lcf-compiled` -- the forwarding
  `@root[idx]`/`@root[idx] = value` accessors every `.ldb`/`.lmt`/`.lmu`/
  `.lsd` file object (`Database`/`MapTree`/`MapUnit`/`SaveData`) shares.
  Both already compiled clean (a real, previously-missed coverage
  opportunity flagged by the `LCF::Array1D` follow-up, since a stale
  `mruby-lcf-compiled/mrbgem.rake`/`src/register.cxx` comment kept
  claiming they stayed interpreted); both compile to the same generic
  Array/Hash-fastpath-plus-`mrb_funcall`-fallback shape `LCF::Array1D`'s/
  `LCF::Sections`'s own already-registered `#[]`/`#[]=` use, dispatched
  dynamically against `@root`'s real runtime class either way, so no
  devirtualization of `@root` itself -- and therefore no dependence on
  which `LCF::File` subclass it is -- is involved.
