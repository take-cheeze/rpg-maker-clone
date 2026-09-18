- `tools/bc2cpp/bc2cpp.rb` now compiles a `SEND`/`SSEND` call site that
  carries keyword pairs (`n=N|nk=K`) whose real callee declares no
  keyword parameters at all -- previously an unconditional `#error
  SEND/SSEND ... has a splat and/or keyword argument list`, leaving the
  whole enclosing method on the interpreter. Such a site is not a keyword
  call in any runtime sense: the caller writes `state.set_parallax(name:
  n, loop_x: lx, ...)` but the callee is a plain `def set_parallax(opts)`
  taking one ordinary positional Hash.

  Instrumenting a real whole-program diagnostic first showed the standing
  20-site bucket is entirely `n=N|nk=K` with literal counts and contains
  **no splat at all** (not one `n=*`/`nk=*`), splitting by why
  `compile_keyword_call` declined: 8 x `:new` (native `Class#new`, no
  MONO target -- the keywords belong to the class's own `#initialize`,
  and `Game::MoveRoute#initialize(commands, repeat: true, skippable:
  false)` really does declare keywords), 4 x `:deal_attack` (one real def
  that declares a real keyword but does not itself compile clean), 1 x
  `:close_message` (genuinely POLY across two defs that *disagree* --
  `RPG2k::Scene::Menu#close_message` takes no arguments,
  `RPG2k::Scene::Map#close_message(animate: true)` declares a real
  keyword), and 7 of this new shape. Only the last group is closed here;
  the rest keep the honest `#error`.

  Both halves of the translation were read out of real
  `3rd/mruby/src/vm.c` (mruby 4.0.0, submodule `831da26b9`) rather than
  assumed. `OP_SEND` (vm.c:2283-2288) packs the K `(sym, value)` register
  pairs into one real Hash *unconditionally*, knowing nothing about the
  callee: `mrb_value kdict = hash_new_from_regs(mrb, nk, kidx);
  regs[kidx] = kdict;` with `kidx = a+n+1`. `OP_ENTER` (vm.c:2573,
  2589-2611) is what decides its meaning: `kd = (MRB_ASPEC_KEY(a) > 0 ||
  MRB_ASPEC_KDICT(a)) ? 1 : 0`, and when `!kd` it runs `ci->n++; argc++;
  /* include kdict in normal arguments */` then `ci->nk = 0`. So for a
  keyword-free callee the exact, complete semantics are "append one Hash
  to the positional list", and nothing keyword-specific survives -- which
  is why `mrb_funcall` is usable here even though it can never carry real
  keywords (vm.c:740's own `ci->nk = 0; /* funcall does not support
  keyword arguments */` is precisely the state `OP_ENTER` would have
  produced anyway).

  The register layout was re-confirmed against a fresh `mrbc -v`
  disassembly of a minimal reproduction rather than inherited from the
  existing keyword path: `f.bar(name: 1, x: 2)` into `def bar(h)` emits
  `LOADSYM R3 :name` / `LOADI_1 R4` / `LOADSYM R5 :x` / `LOADI_2 R6` then
  `SEND R2 :bar n=0|nk=2`, and the callee's own entry is `ENTER
  1:0:0:0:0:0:0:0` (`kw=0`, `kwrest=0`) -- contrasted against `def kw(a,
  name: nil, x: 0)`, which is `ENTER 1:0:0:0:2:0:0:0` followed by real
  `KEY_P`/`KARG`/`KEYEND`.

  The soundness gate is `pure_mandatory_arity?` plus an exact
  `mandatory_arity == n + 1` match on **every** def the closed-world
  registry knows for the name. `pure_mandatory_arity?` already requires
  ENTER's opt/rest/post/kw/kwrest/block fields to all be zero, so it
  proves exactly the `kd == 0` the vm.c arm turns on; the `+1` is the
  `ci->n++` above, checked against the real signature. Requiring it of
  every def (not just a MONO one) is what makes the emitted dynamic
  dispatch sound, and is exactly what separates `:load_h` -- POLY across
  five real defs (`Game::MessageConfig`/`Screen`/`Weather`/`Vehicle`/
  `Timer`) that all agree on `def load_h(h)`, so every possible receiver
  is correct -- from `:close_message`, whose two defs disagree and which
  is therefore left alone. A `<native>` def fails the gate outright (its
  argument spec is invisible to this compiler), which is what correctly
  keeps the eight `:new` sites out. `n < 14` mirrors vm.c's own `if (argc
  < 14)` arm; the `argc == 14`/`== 15` Array-packing arms are not
  modelled.

  Measured on a real whole-program diagnostic with submodules
  initialized, before/after: `#error` markers **48 -> 39** (-9) and
  compiled entry points **2287 -> 2293**, method-level coverage **98.6%
  -> 98.9%** (31 -> 25 methods left on the interpreter). The
  splat/keyword bucket itself goes **20 -> 13** (-7); the remaining -2 is
  a real second-order effect worth naming, because an eighth site of this
  same shape sits inside a *block* rather than a method body:
  `Game::State.restore_pictures`'s own `pictures.each do |id, pic| ...
  state.show_picture(id, name: name, ...) ... end`
  (`mruby-rpg2k/mrblib/game/lsd_io.rb:1647`, `n=1|nk=13`).
  `BLOCK_CFUNC_FALLBACK_SUPPORT` only compiles a block whose child irep
  is clean, so that one call site used to poison the whole block and
  `Game::State.singleton#restore_pictures` fell back to `#error unhandled
  opcode BLOCK` + `#error unhandled opcode SENDB`; both now compile
  (`BLOCK` 4 -> 3, `SENDB` 4 -> 3, `BLOCK_FALLBACK` 396 -> 397). The six
  methods that newly compile clean are `Game::Interpreter#do_change_
  parallax`, `Game::Interpreter#do_show_picture`,
  `Game::State.singleton#from_lsd`, `Game::State.singleton#restore_
  pictures`, `RPG2k::Scene::Battle#start_battle_page_animation` and
  `RPG2k::Scene::Map#apply_map_access`; zero methods regressed the other
  way. A real `g++ -std=c++17 -fsyntax-only` compile of the actual
  `SKIP_UNSUPPORTED=1` output stays at **zero** errors, and
  `scripts/rpg2k_logic_check.rb` (1201), `scripts/rpg2k_scene_check.rb`
  (1062) and `scripts/lcf_testbed_check.rb` all pass unchanged -- those
  two harnesses load these exact Ruby sources and exercise these exact
  call paths, which is also a live empirical confirmation of the
  Hash-as-trailing-positional semantics.

  Deliberately dynamic-dispatch-only (`mrb_funcall`), the same scoping
  choice `SPLAT_UNROLL_SUPPORT`'s plain-positional case documents:
  getting these sites compiling at all is this round's goal. Unlike a
  real keyword call there is no obstacle to layering the existing
  MONO/POLY/TYPED devirtualization on top afterwards, since once the Hash
  is built this is an ordinary positional call -- a clean follow-up. The
  13 remaining sites in the bucket are the three genuinely different
  shapes listed above.
