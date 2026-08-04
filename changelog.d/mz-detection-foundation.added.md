- RPG Maker MZ project detection (milestone M6.1). A new `MZ` class
  (`mruby-mvjs/mrblib/mz.rb`) recognises an MZ project (`js/rmmz_core.js` +
  `data/System.json`) and knows the canonical `rmmz_*` script load order, wired
  into `src/main.cxx`'s maker sniff. MZ shares MV's embedded quickjs host, but
  ships PIXI v5 (WebGL-only) and so needs a WebGL-subset backend that is not
  built yet; pointing the binary at an MZ game now reports that pending state
  cleanly instead of failing with "no project found". Covered by host specs
  (`mruby-mvjs/test/mz_test.rb`); see ADR 0004 (M6) for the sub-milestone plan.
