- An item's per-actor "usable characters" restriction (`actor_set`, and the
  RPG2003 by-class `class_set`) is honoured again. The database stores these as
  int8 flags where `0` means "not permitted", but `0` is truthy in Ruby and
  mruby alike, so the old truthiness read turned every restriction into
  "permitted" — genuine `RPG_RT.exe` never offers Nepheshel's item 26 to actor
  15, while this engine did. An all-zero array stays permissive: that is the
  editor's untouched state, not a ban on every actor.
