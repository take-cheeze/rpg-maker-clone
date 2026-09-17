- `tools/bc2cpp/bc2cpp.rb`'s `FIXNUM_OPERAND_PROOF` gains a fifth proof
  source (`INTEGER_CONSTANT_PROOF`) and a real dominance test in place of
  its old syntactic label barrier (`REGION_DOMINANCE`). Together these
  take the real shipped whole-program build from 14197 to 13911
  `mrb_funcall`/`mrb_funcall_with_block` call sites -- 286 removed, the
  largest single round this mechanism has had (the original
  four-proof-source version moved 70). The `// operands proven Fixnum`
  marker count in the generated C++ goes 70 -> 356.

  Both changes came out of instrumenting the proof itself rather than
  guessing at it: a one-off run tagging every refusal with its reason
  across all 6950 failing `proven_fixnum_pair?` queries in the whole
  program put a plain label barrier first (1452 refusals, more than
  double the next cause) and `GETCONST` fifth (469). Ceiling runs -- the
  same build with one refusal reason forcibly disabled -- then reversed
  that ranking by actual value, because a refusal only costs a call site
  when the OTHER operand proves too: lifting dominance entirely reaches
  14023 (174 sites), while treating every integer-literal-defined
  constant as proven reaches 13790 (386 sites). The two were implemented
  in that order and are independent; dominance alone lands 21 sites
  (14197 -> 14176) and the constants add the remaining 265.

  `INTEGER_CONSTANT_PROOF` (`IntegerConstants.analyze`) is a whole-program
  pass over every irep proving "every definition of bare constant name N
  anywhere in this program assigns an integer literal". 669 names qualify.
  This is worth a pass at all because of what an RPG2000 interpreter is
  made of: opcode numbers (`CONTROL_SWITCHES = 10210`), slot indices
  (`WEAPON_SLOT = 0`), tile sizes and stat ids, read in arithmetic and
  comparison position constantly -- 454 real integer-literal constant
  definitions exist across this closed world's Ruby sources, and until
  now every read of one was opaque.

  Keyed by BARE name, never by qualified path, and that IS the soundness
  argument rather than a shortcut. A real `GETCONST R4 FOO` carries only
  `FOO`; what it resolves to depends on lexical nesting and then on the
  cref's own ancestors, neither of which this file models. So rather than
  predict which `FOO` wins, a name is admitted only when every definition
  of it agrees -- making the answer independent of the resolution this
  file cannot perform. Same "MONO by name" discipline the method registry
  already runs on, and the same "two sites disagreeing poisons the name"
  rule `container_constants` already uses one screen above it.

  Four poison sources, all required, none of them theoretical:

  1. A `SETCONST`/`SETMCNST` whose source register is not an integer
     literal. Real operand order confirmed against `3rd/mruby/src/
     codedump.c` rather than assumed -- `"SETCONST\t%s\tR%d"` puts the
     name FIRST and the register LAST, the reverse of `GETCONST`'s own
     `"GETCONST\tR%d\t%s"`, the same asymmetry `SETGV`/`GETGV` already
     carry; both also call `print_lv_a`, so a trailing `; R1:name`
     comment is stripped before the register is read. This is what
     poisons `ShopState = Struct.new(...)` and `NAME = "hi"`.
  2. A `CLASS`/`MODULE` instruction naming it. A class or module name is
     a real constant binding (`OP_CLASS` does its own `mrb_const_set`,
     3rd/mruby/src/class.c) that never goes through `SETCONST` at all, so
     without this a name used for both a module and an integer would look
     unanimously integral. `module Input` (mruby-rgss/mrblib/lib.rb) is
     poisoned exactly here.
  3. A native definition -- `mrb_define_const`/`mrb_define_global_const`
     (quoted name) or `mrb_define_const_id` (a presym `MRB_SYM(name)`
     token), the three forms a grep across every native source in this
     closed world actually finds (31/11/57 real call sites). C is never
     bytecode, so no amount of scanning ireps could see these.
  4. A definition in a Ruby source compiled into the same VM but outside
     bc2cpp's own closed world -- mruby's core mrblib, every core
     mrbgem's, and the three always-active external gems'
     (`foreign_mrblib_srcs`, compiled_gems.rb; passed as the new
     `FOREIGN_RUBY_SRCS`, the Ruby-side twin of `NATIVE_SRCS`, from all
     three `mrbgem.rake`s and the coverage script). Not hypothetical, and
     found by measuring the overlap instead of assuming there wasn't one:
     `3rd/mruby/mrblib/enum.rb` defines `NONE = Object.new` while
     `mruby-rpg2k/mrblib/game.rb` defines `NONE = 37`. Bare-name
     agreement across the closed world alone would have called `NONE` a
     proven integer. A compiled class that includes `Enumerable` really
     can resolve a bare `NONE` to the former.

  A name with zero integer definitions is never admitted, so a constant
  this analysis cannot see stays unproven and costs nothing but the
  missed proof. `const_set` is confirmed absent from the whole closed
  world. When either `NATIVE_SRCS` or `FOREIGN_RUBY_SRCS` is missing the
  analysis is skipped outright and no constant is proven, rather than run
  against a knowingly incomplete picture -- so a bare `ruby bc2cpp.rb
  foo.rb` exploration stays honest instead of quietly more optimistic
  than the code that ships.

  The poisoning was checked against real source, not just counted: of the
  19 names a naive `^CONST = <int>$` grep would have admitted and this
  analysis rejects, `SCREEN_W = RPG2k::WIDTH` is a `GETMCNST` source not
  a literal, `TILE = Game::TILE` disagrees with `TILE = 16`, `COLS =
  SCREEN_W / TILE + 1` is computed at runtime, `Input` is a module -- and
  `TEXT_COLOR` is defined as `0` in `scene/save_load.rb` but as
  `Color.new(255, 255, 255, 255)` in `scene/map_viewer.rb`, which
  proving would have been flatly wrong.

  `REGION_DOMINANCE` replaces the blunter rule the original proof shipped
  with ("refuse the moment the backward walk steps onto any address
  carrying a real `L<addr>:` label"), which was correct but rejected the
  single most common real shape in the program -- an `if` between an
  assignment and its use:

      x = 5          # LOADI_5
      if cond        # JMPNOT ... L1
        ...
      end            # L1:
      y = x + 1      # ADD, operand x

  `L1` sits between the write and the use, so the old rule refused even
  though every path reaching `L1` came through the write. The
  replacement (`fixnum_proof_region_ok?`) is a real local dominance test:
  let the REGION be the contiguous instruction range `[write, use]`
  (contiguous by construction -- the walk only steps `j -= 1`, and irep
  addresses increase monotonically with index). Any path reaching the
  use, traced backward, cannot have written the register while inside the
  region (the forward walk already checked every instruction in it), so
  the only question is where it ENTERED, and there are exactly two ways:
  falling through into the write, or branching to a label inside the
  region and skipping it. So the write dominates iff no in-region label
  is reachable from outside -- which is what this checks directly, by
  requiring every source address that branches to an in-region entry to
  lie within the region's own address bounds. A source below it is the
  real skip-the-write case; a source above it is a back-edge from after
  the use, which matters just as much, since it would let a later write
  clobber the register and loop back.

  Both shapes this codebase generates fall out correctly: a `while` loop
  entirely between write and use has its head label reached only by its
  own back-edge and its exit label only by its own head test, both inside
  -- so a write before the loop now correctly dominates a use after it;
  a loop whose body contains the use has its back-edge above the region
  and is still correctly refused.

  The branch-edge map (`fixnum_proof_edge_sources`) is complete by
  construction, re-verified against `3rd/mruby/include/mruby/ops.h`:
  exactly five opcodes move `pc` within a frame -- `JMP`/`JMPUW` (`S`
  operand, target printed alone) and `JMPIF`/`JMPNOT`/`JMPNIL` (`BS`,
  register then target). `OP_ENTER` does not branch (its `CASE(OP_ENTER)`
  arm falls straight through to `NEXT`); a real optional-argument
  signature's dispatch is an ordinary `JMP` table emitted after it, and
  is already covered. `RETURN`/`RETURN_BLK`/`BREAK`/`STOP` leave the
  frame; `RAISEIF`/`ERR`/`EXCEPT` reach a handler only through a real
  catch entry, which is why catch-handler targets are tracked separately
  and always refuse -- a raise edge has no source instruction to contain.
  An entry address with no recorded in-edge refuses too: that could only
  mean an unmodelled edge, and the test is worthless unless the map is
  complete. `JMPUW` is included even though `jump_targets` omits it (a
  method containing one always ends up `#error unhandled opcode JMPUW`
  and is dropped, but the proof still RUNS inside such a body during a
  speculative `compiles_clean?` probe).

  Measured on the real shipped build (`SKIP_UNSUPPORTED=1`, the same
  output `scripts/bc2cpp_coverage_report.rb` scans). Per operator:
  `*` 602 -> 460, `-` 625 -> 564, `+` 701 -> 665, `==` 628 -> 603,
  `/` 332 -> 319, `>` 281 -> 278, `<` 238 -> 235, `>=` 141 -> 138 --
  286 exactly, with nothing else moving. Compiled entry points (2252),
  per-method coverage (97.1%), the `#error` total (119), POLY-marked
  sites (5917) and the BLOCK_FALLBACK/LAMBDA_FALLBACK counts are
  byte-identical; the only other line to change in
  `docs/bc2cpp_coverage.txt` is the new `integer-valued constants proven
  (INTEGER_CONSTANT_PROOF): 669` fact, reported alongside the other
  proven facts for the same reason they are -- a constant reassigned to a
  non-literal silently removes one, along with every devirtualization it
  was feeding, and that drift should be visible in a diff. A real g++
  `-std=c++17 -fsyntax-only` pass over the whole generated translation
  unit still reports exactly the same 17 pre-existing, unrelated errors
  (12 `could not convert '1' from 'int' to 'mrb_value'`, 5
  `RPG2k::Scene::Map#vehicle_blocks` arity) and zero new ones.
  `scripts/rpg2k_logic_check.rb` (1201), `scripts/rpg2k_scene_check.rb`
  (1062) and `scripts/lcf_testbed_check.rb` all still pass with identical
  counts.

  Real example in the shipped output: `BORDER * 2` (`BORDER = 8`,
  mruby-rpg2k/mrblib/main.rb, single definition, no class/module of that
  name anywhere) is now three unconditional lines with no `mrb_funcall`
  at all, at every one of its window-layout call sites.

  Known, deliberately-unclaimed ground, measured rather than guessed.
  Constant-to-constant aliasing is not followed, which is why `TILE =
  Game::TILE` poisons `TILE` instead of chaining through to `16` --
  a real miss, not a soundness concern. Dominance still refuses when a
  region label has a genuine outside in-edge, which is the `if/else`
  join case (`x = 5` in one arm, `x = 7` in the other): proving that
  needs all REACHING definitions checked, not just the nearest one, a
  different mechanism with its own soundness argument. Between them
  those two account for most of the gap between this round's 286 and the
  460-site combined ceiling the instrumented runs measured.
