- Corrected the RPG Maker MZ (M6) plan: MZ's engine is **not** open-source. MV's
  corescript is an official MIT project (`rpgtkoolmv`, redistributed by KADOKAWA)
  that `data/mv-sample` fetches, but MZ's engine ships only with the paid editor
  and has no equivalent open-source release — the GitHub mirrors of it carry no
  license. So, unlike MV, there is no committable/fetchable MZ test bed; MZ is
  developed against a user-supplied project. Updates ADR 0004, `docs/TODO.md`
  and `mruby-mvjs/mrblib/mz.rb`, which had incorrectly described
  `stak/rmmz-corescript` as an MIT reimplementation.
