- **bc2cpp: a block reads the exact class of a captured local.** A local an enclosing method assigns
  and a block only reads or mutates (`acc = {}; 3.times { |i| acc[i] = acc.size }`) was unknown inside the
  block; the exact-class flow now answers the class the defining frame stored there, so the block's `size`,
  `empty?`, `first` and `[]`/`[]=` lose their class test and by-name fallback. 67 fewer by-name-reachable
  sites on the rpg2k gem (7,625 to 7,558), of them 41 hash index arms; the census categories named in the
  request move by 7 of 918 and the ivar one by none (the report lists why each ivar has no pool).
  `BC2CPP_CAPTURED_LOCAL_CLASS=0` turns it off; a build that can write a local by name
  (`binding`, `eval`) never uses it. See `docs/adr/0308-bc2cpp-captured-local-classes.md`;
  checks `scripts/bc2cpp_captured_local_class_check.rb` and its mutation check.
