- The psp and wio mruby cross builds now compile RPG2000/2003 only:
  `mruby-rpgxp`, `mruby-rpgvx`, `mruby-wolf`, `mruby-mvjs` and
  `mruby-onig-regexp` (onigmo) are no longer built for either target, since
  this project has never run an XP/VX/VX Ace/WOLF/MV game on them and none
  of `mruby-rpg2k`/`mruby-lcf`/`mruby-rgss` use regex. Desktop, wasm and
  Android are unchanged and keep every format. See ADR 98.
