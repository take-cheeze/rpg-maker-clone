MRuby::Gem::Specification.new('mruby-rpg2k') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = ''

  add_dependency 'mruby-lcf'
  add_dependency 'mruby-rgss'

  # Core *-ext gems whose methods this gem's Ruby actually calls. They are in the
  # shared list in build_config.rb (rpg_maker_gems) so the full game build has
  # them, but the dependency belongs here too — see AGENTS.md: a per-gem build
  # only pulls the gem plus its declared dependencies, so an undeclared one is a
  # NoMethodError waiting for the first gem-level test.
  #   mruby-array-ext   Array#compact  (Show Choices' label list, the party
  #                     roster's initial members)
  #   mruby-numeric-ext Integer#zero?  (used across game.rb / main.rb)
  #   mruby-enum-ext    Enumerable#sort_by / each_with_object
  #   mruby-range-ext   Range#cover?   (Game::Shop#equip?, the special-item
  #                     type checks in game.rb / scene/item_menu.rb)
  add_dependency 'mruby-array-ext'
  add_dependency 'mruby-numeric-ext'
  add_dependency 'mruby-enum-ext'
  add_dependency 'mruby-range-ext'

  # RPG_RT's own F9 debug menu (Switch/Variable browser, the chipset
  # passability editor, the whole-map viewer) and the matching
  # --rpg2k_map_editor/--rpg2k_chipset_editor CLI dev tools are gated behind
  # RPG2k#test_play at every real call site (Scene::Map#try_open_debug_menu:
  # "return unless @parent.test_play") -- a released game never reaches any
  # of it. Measured by compiling mrblib with and without these three files
  # (real `mrbc -g`, see docs/adr/0097-rpg2k-debug-tools-trim.md): 18,259 of
  # the 413,612 bytes mruby-rpg2k's mrblib compiles to (iseq+pool+syms) --
  # code no player-facing psp/wio binary calls. Same `%w[psp wio]` grouping
  # mruby-rgss's own mrbgem.rake already uses (that gem's pthread linking):
  # this build's own name, not the host half of a cross build that also
  # produces mrbc alongside it.
  if %w[psp wio].include?(build.name)
    spec.rbfiles -= %W[
      #{dir}/mrblib/scene/debug_menu.rb
      #{dir}/mrblib/scene/chipset_editor.rb
      #{dir}/mrblib/scene/map_viewer.rb
    ]
  end

  # docs/adr/0108's own real attempt: mruby-rpg2k is a pure-Ruby gem (its own
  # src/rgss_ext.cxx is two empty gem_init/gem_final stubs -- everything real
  # is mrblib/*.rb), so in principle its entire compiled bytecode could live
  # on the SD card instead of the firmware, loaded once at boot via
  # mrb_load_irep_buf the same way ADR 0099's own smoke test loads
  # mruby-lcf's. RGSS_WIO_EXTERNAL_RPG2K, a no-op unless set, drops every one
  # of this gem's own rbfiles for *whichever* build it's set for (not just
  # wio -- a host build with it set is exactly how the ADR's own host-side
  # proof produces a "core + shared gems, no rpg2k Ruby" libmruby.a to load
  # a matching external .mrb into), superseding the narrower debug-tools/
  # battle trims above wherever it's active. Not the default: see the ADR
  # for why loading it back in on real wio hardware is the open, unresolved
  # half of this attempt.
  if ENV['RGSS_WIO_EXTERNAL_RPG2K']
    spec.rbfiles = []
  elsif build.name == 'wio'
    # A live fight's own bytecode -- Game::Battle (the headless combat model,
    # split into its own file for exactly this exclusion), Scene::Battle and
    # RPG2k3::Scene::Battle -- is 180,368 bytes on its own (docs/adr/0107's
    # own real measurement: three separate mrbc compiles, summed), a sixth of
    # the Wio Terminal's entire flash budget, for a feature most of any given
    # session never reaches (a save/load/menu-only play session, or this
    # port's own current boot-test firmware, which loads no game data and so
    # starts no fight at all). Unlike the debug-tools trim above, this is
    # *wio-only*, not psp -- PSP has real flash/storage headroom this board
    # does not, and dropping these files here does not yet come with any way
    # to get them back: no runtime loader reads them from the SD card the way
    # ADR 0007's still-unbuilt P3 asset-streaming work would need to, so a
    # wio build with this exclusion cannot actually start a fight today. This
    # trim exists to prove the split is real and measure its actual cost, not
    # to claim battle done as a wio feature -- see the ADR for what remains.
    spec.rbfiles -= %W[
      #{dir}/mrblib/game/battle.rb
      #{dir}/mrblib/scene/battle.rb
      #{dir}/mrblib/scene/battle_rpg2k3.rb
    ]
  end

  # game/battle_support.rb and scene/battle_support.rb hold the game.rb/
  # interpreter.rb/scene/base.rb methods and whole classes (Game::Troop,
  # Game::Enemy, Game::EnemyAction, Game::EnemyAi, Game::BattlePage, Game::
  # States::BattleText, ...) that were only ever reachable from the three
  # files just excluded above -- confirmed by grepping every real call site
  # of each before it moved, see docs/adr/0124-rpg2k-battle-only-helpers-trim.md.
  # Excluded on exactly the same condition as those three files (psp keeps
  # battle, so psp keeps this too): a wio-only exclusion, not the psp/wio
  # debug-tools one above.
  if build.name == 'wio'
    spec.rbfiles -= %W[
      #{dir}/mrblib/game/battle_support.rb
      #{dir}/mrblib/scene/battle_support.rb
    ]
  end

  # game/lsd_io.rb (Game::State#to_lsd/.from_lsd and their exclusive helpers)
  # is the RPG_RT-interop save/load path: exporting/importing a genuine
  # Save<N>.lsd so a save this game writes can round-trip through real
  # RPG_RT or other RPG2000/2003 editor tooling. wio has no PC to hand a
  # save file to and no editor tooling to receive one from, so that
  # interop has no audience there -- Save/Continue itself keeps working
  # unchanged through Game::State#to_h/.load, the separate Marshal-based
  # format main.rb's own #save_game already documents as this game's
  # actual authoritative save (see docs/adr/0128). A wio-only exclusion,
  # same reasoning as the debug-tools trim above (psp keeps it: real
  # flash/storage headroom, and a real editor-facing interop use there is
  # at least plausible).
  if build.name == 'wio'
    spec.rbfiles -= %W[
      #{dir}/mrblib/game/lsd_io.rb
    ]
  end

  # docs/adr/0144: mruby-rgss/mrbgem.rake was, until this round, the ONLY
  # caller of wio_strip_bc2cpp_stubs (4 owners: RGSS::Sprite, RGSS::Window,
  # RGSS::Audio.singleton, RGSS::ErrorReport.singleton) even though
  # tools/bc2cpp/compiled_gems.rb's own `mruby-rpg2k-compiled` entry already
  # lists ~60 real compiled owners. This is the first round to wire
  # mruby-rpg2k up too -- a bounded, plain-instance-method-only first slice
  # (11 owners, all real classes living in mruby-rpg2k/mrblib/game.rb, all
  # kept in this gem's own wio spec.rbfiles -- neither the psp/wio
  # debug-tools trim above nor the wio-only battle trims below ever remove
  # game.rb itself), not the full ~60-owner list:
  #   Game::TextReveal Game::MessageConfig Game::Switches Game::Variables
  #   Game::NumberInput Game::Actors Game::Rng Game::MoveRoute Game::Shop
  #   Game::Weather Game::Timer
  # -- 74 real bc2cpp-registered methods total (ground truth from a real
  # wio_registered_methods.rb run against this gem's own real bc2cpp.rb
  # registry, never hand-counted): TextReveal 6, MessageConfig 4,
  # Switches 7, Variables 5, NumberInput 6, Actors 3, Rng 3, MoveRoute 18,
  # Shop 11, Weather 4, Timer 7.
  #
  # Chosen deliberately for this first rpg2k round the same way
  # mruby-rgss's own first round was: plain instance-method owners only (no
  # `.singleton`), none of them in bc2cpp.rb's own DIRECT_CONSTRUCT_TARGETS
  # (`Game::Transition`/`Game::Map`) or NATIVE_ARG_TARGETS (`Game::Actor`/
  # `Game::Map`/`Game::Transition`/`Game::Screen`/`Game::State`/
  # `Game::Interpreter`/`LCF::EventCommand`/`LCF::MoveCommand`) allowlists,
  # so none of this round's own stripping interacts with either of those
  # more elaborate codegen paths -- confirmed directly against both
  # constants in tools/bc2cpp/bc2cpp.rb, not assumed from the class names
  # alone.
  #
  # Two real, confirmed-safe-to-defer exclusions found while scoping this
  # round, left for a future one rather than silently worked around:
  #
  #   - Game::Troop/Game::Enemy/Game::EnemyAction/Game::EnemyAi (all four
  #     real bc2cpp-registered owners too) are entirely defined in
  #     mrblib/game/battle_support.rb (moved there by docs/adr/0124), which
  #     the wio-only battle trim just below this comment already drops from
  #     spec.rbfiles outright -- confirmed directly (`grep -n '^class ' game/
  #     battle_support.rb`). Stripping their stub bodies would be a real
  #     no-op for wio today (wio_strip_bc2cpp_stubs only ever rewrites
  #     `spec.rbfiles` entries, and that file is not one on this build), not
  #     a live correctness risk -- omitted here as pointless rather than
  #     unsafe, revisit if a future round ever stops excluding that file for
  #     wio (or adds a psp caller, which keeps battle_support.rb).
  #   - Game::ChipSet (9 real registered methods, otherwise exactly as
  #     simple a target as the 11 above -- no `.singleton`, no
  #     DIRECT_CONSTRUCT_TARGETS/NATIVE_ARG_TARGETS involvement) is left out
  #     because one of its own real registered methods, #upper_flags, is
  #     marked private via a real class-body-level `private :upper_flags`
  #     call (game.rb line 708) rather than a bare `private` mode switch --
  #     confirmed directly with a real AST walk of every `private`/
  #     `protected`/`public`/`attr_*`/`alias_method` call inside all 12
  #     candidate owners' own class bodies (the only other explicit-name
  #     `private :x` anywhere in game.rb, `swap_equipment_through_bag`,
  #     belongs to `Game::Party`, not a candidate owner here; every other
  #     hit was a plain `attr_reader`/`attr_accessor` whose own names never
  #     collide with a registered method name, or `Game::MoveRoute`'s own
  #     bare `private` mode switch). Stripping `#upper_flags`'s own `def`
  #     while leaving `private :upper_flags` standing would raise a real
  #     `NameError` the moment this gem's own mrblib loads (`Module#private`
  #     with an explicit Symbol argument requires the named method to
  #     already exist) -- strictly BEFORE mruby-rpg2k-compiled's own gem_init
  #     gets a chance to install `#upper_flags`'s C++ override a few lines
  #     of load order later, a real boot-time crash this round's own dry
  #     run against a real host mrbc caught directly (a plain `ruby -e
  #     'load "..."'` smoke load of the stripped file raised exactly this
  #     NameError) rather than shipping and finding out on real hardware.
  #     strip_wio_bc2cpp_stubs.rb has no mechanism today to also delete a
  #     stripped method's own companion `private :name`/`protected :name`/
  #     `public :name` statement, so `Game::ChipSet` is left out of
  #     `owners:` entirely (all 9 of its methods, not just #upper_flags,
  #     since this mechanism strips a whole owner at a time) rather than
  #     half-fixed -- a real future-round item for strip_wio_bc2cpp_stubs.rb
  #     itself, not something to route around per-owner here.
  #
  # strip_wio_bc2cpp_stubs.rb itself needed one real fix before ANY of this
  # round's 11 owners could strip cleanly: 9 of the 12 original candidates
  # (every one except MessageConfig/Rng, and ChipSet above before it was
  # dropped) have at least one real one-line `def name; body; end` among
  # their own registered methods (e.g. `Game::Timer#seconds`,
  # `Game::Switches#initialize`, `Game::Shop#allow_buy?`) -- a shape that
  # file's own comment had explicitly flagged as unsupported (raises rather
  # than guesses) because no owner any prior round stripped had ever hit
  # one. Fixed there directly (see that file's own updated comment for the
  # full writeup and the real per-line column-span safety check added
  # alongside it), not routed around here by dropping every owner that
  # happens to use one.
  #
  # Gem-init-ordering correctness (this mechanism's own required per-owner
  # check, see build_config.rb's wio_strip_bc2cpp_stubs and mruby-rgss/
  # mrbgem.rake's own comment for the methodology): grepped every real
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/`mrb_funcall_with_block`
  # call site in the whole native closed world outside `3rd/`/`build/`
  # (`app/psp/main.cxx`, `app/wio/src/mruby_sd_smoke_main.cxx`,
  # `mruby-lcf-compiled/src/register.cxx`, `mruby-rgss-compiled/src/
  # register.cxx`, every `mruby-rgss/src/*.cxx`, `mruby-rpg2k-compiled/src/
  # register.cxx`, `src/error_dump.cxx`, `src/main.cxx` -- confirmed this is
  # the complete list via a whole-tree `grep -rl mrb_funcall`) against all
  # 74 of this round's own real registered method names: zero real call
  # sites found anywhere (every literal method-name argument that DOES
  # appear -- "press"/"release", "main_loop", "width"/"height", "name" on an
  # RGSS::Font value, "message"/"backtrace"/"log_tail"/"install", ...  -- is
  # a real, different, unrelated method). Also checked the always-active
  # external mrbgems' own native sources (3rd/mruby-marshal, 3rd/
  # mruby-stringio, 3rd/mruby-onig-regexp, mirroring compiled_gems.rb's own
  # `external_gem_native_srcs`): the one hit, `mruby-stringio/src/
  # stringio.c`'s own `mrb_funcall(..., "replace", ...)`, calls `#replace`
  # on a real `String` ivar (`StringIO`'s own `@string`), never a
  # `Game::Switches`/`Game::Variables` instance -- the same "registry keys
  # by name, not by class" POLY shape compiled_gems.rb's own StringIO/
  # `#ungetbyte` precedent already documents, not a boot-ordering hazard
  # either way. `register.cxx` in all three `*-compiled` gems (including
  # this round's own `mruby-rpg2k-compiled/src/register.cxx`) has zero real
  # `mrb_funcall` call sites in actual code at all -- every match there is
  # inside a comment describing the *generated* (not checked-in)
  # `rpg2k_compiled_gen.cpp`'s own runtime POLY-dispatch fallback, which
  # only ever runs after every gem's own gem_init has completed, never
  # during boot.
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on `mruby-rpg2k/mrblib/game.rb` alone, before this
  # gem's own wio_strip_debug_rbfiles/wio_strip_inline_helpers passes run):
  # 162,963 -> 147,790 bytes, a 15,173-byte (9.3%) reduction from these 11
  # owners' 74 stripped method bodies (517 of the file's own 10,334 lines).
  #
  # Future-round candidates (tools/bc2cpp/compiled_gems.rb's own
  # `mruby-rpg2k-compiled` owners: list has ~60 total): `Game::ChipSet`
  # above once strip_wio_bc2cpp_stubs.rb grows companion-statement support;
  # every `.singleton` owner (`Game::Party.singleton`, `Game::State.singleton`,
  # ... 20+ of them); the `RPG2k::Scene::*` menu/scene classes (already
  # excluded from wio's own spec.rbfiles for `DebugMenu`/`ChipsetEditor`/
  # `MapViewer` per the debug-tools trim above, so stripping those three
  # specifically would be as moot as the battle_support.rb owners above,
  # but `ItemMenu`/`SkillMenu`/`EquipMenu`/`Menu`/`StatusMenu`/`SaveLoad`/
  # `Order`/`Base`/`Title`/`MapWorld`/`VehicleWorld`/`EventResolver`/
  # `GameOver` all stay in wio's own rbfiles and are real, uncovered
  # candidates); and the larger/`DIRECT_CONSTRUCT_TARGETS`/
  # `NATIVE_ARG_TARGETS`-touching owners (`Game::Actor`, `Game::Party`,
  # `Game::Battle`, `Game::Character`, `Game::Map`, `Game::Screen`,
  # `Game::Transition`, `Game::State`, `Game::Interpreter`,
  # `RPG2k::Scene::Map`, `RPG2k::Scene::Battle`) -- each needs its own
  # dedicated per-owner soundness pass, deliberately not attempted in this
  # round's own bounded slice.
  wio_strip_bc2cpp_stubs(spec, compiled_gem: 'mruby-rpg2k-compiled',
                         owners: %w[Game::TextReveal Game::MessageConfig Game::Switches
                                    Game::Variables Game::NumberInput Game::Actors Game::Rng
                                    Game::MoveRoute Game::Shop Game::Weather Game::Timer])
  wio_strip_inline_helpers(spec)
  wio_strip_debug_rbfiles(spec)
end
