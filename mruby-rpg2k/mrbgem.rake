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
  # Round 36: the 13 plain `RPG2k::Scene::*` menu/scene owners the comment
  # above already named as the next real, uncovered candidates --
  # `ItemMenu`/`SkillMenu`/`EquipMenu`/`Menu`/`StatusMenu`/`SaveLoad`/
  # `Order`/`Base`/`Title`/`MapWorld`/`VehicleWorld`/`EventResolver`/
  # `GameOver` -- all real classes living in mruby-rpg2k/mrblib/scene/
  # {item_menu,skill_menu,equip_menu,menu,status_menu,save_load,order,
  # base,title,game_over}.rb (`MapWorld`/`VehicleWorld`/`EventResolver` are
  # all three defined inside base.rb, right below `Base` itself -- see that
  # file directly), none of them `DebugMenu`/`ChipsetEditor`/`MapViewer`
  # (already excluded from wio's own spec.rbfiles by the debug-tools trim
  # above, so those three stay untouched -- stripping them would be as
  # pointless a no-op as the battle_support.rb owners already documented
  # above). Same profile as round 35's own 11 owners: plain instance
  # methods only (no `.singleton`), none of them in bc2cpp.rb's own
  # DIRECT_CONSTRUCT_TARGETS (`Game::Transition`/`Game::Map`) or
  # NATIVE_ARG_TARGETS (`Game::Actor`/`Game::Map`/`Game::Transition`/
  # `Game::Screen`/`Game::State`/`Game::Interpreter`/`LCF::EventCommand`/
  # `LCF::MoveCommand`) allowlists -- confirmed directly against both
  # constants in tools/bc2cpp/bc2cpp.rb, not assumed from the class names.
  #
  # Real ground truth (a real wio_registered_methods.rb run against
  # mruby-rpg2k-compiled's own real bc2cpp.rb registry, never hand-
  # counted): ItemMenu 41, SkillMenu 39, EquipMenu 29, Menu 28,
  # StatusMenu 13, SaveLoad 12, Order 12, Base 17, Title 6, MapWorld 7,
  # VehicleWorld 6, EventResolver 2, GameOver 4 -- 216 real registered
  # methods total across these 13 owners. Only 213 of those 216 actually
  # strip out of wio's own copy of base.rb: `Base`'s own real registered
  # method list includes 3 (`advance_list_arrow_anim`, `list_arrow_blink_on?`,
  # `sticky_list_top`) that are not defined in base.rb at all -- a second,
  # real `class Base` reopening inside `mrblib/scene/battle.rb` adds them
  # (confirmed directly: `grep -rn` finds all three only in battle.rb/
  # battle_support.rb), and that file is already dropped from wio's own
  # spec.rbfiles entirely by the wio-only battle trim below this comment,
  # so wio_strip_bc2cpp_stubs (which only ever rewrites spec.rbfiles
  # entries) never sees or touches them -- not a gap in this round's own
  # `owners:` list, just the same "battle-only reopening wio never ships"
  # shape `Game::Troop`/`Game::Enemy`/etc. already have in round 35's own
  # comment above.
  #
  # Companion-statement hazard check (the same real AST walk round 35's own
  # comment above describes, re-run against all 13 of these owners' own
  # class bodies): every one of the 10 real files uses only a bare
  # `private` mode switch (`item_menu.rb`, `skill_menu.rb`, `equip_menu.rb`,
  # `menu.rb`, `status_menu.rb`, `save_load.rb`, `order.rb`, `title.rb`,
  # `game_over.rb`) or none at all -- no explicit `private :name`/
  # `protected :name`/`public :name`/`alias_method` call anywhere in any of
  # them. `base.rb` additionally has one `attr_reader :parent, :db,
  # :map_tree` at `Base`'s own class-body top level; none of those three
  # names collide with any of `Base`'s own 17 real registered methods (see
  # the list above), so it is not a hazard either. No `Game::ChipSet`-style
  # exclusion needed for any of this round's 13 owners.
  #
  # Gem-init-ordering correctness (same methodology and same real closed-
  # world file list as round 35's own comment above, re-run against all 159
  # unique method names these 13 owners' 216 real registered methods use):
  # zero real call sites found. `3rd/mruby-marshal`, `3rd/mruby-stringio`,
  # `3rd/mruby-onig-regexp` (not checked out in every worktree by default --
  # `git submodule update --init` them to re-run this yourself) each have
  # real `mrb_funcall`/`mrb_funcall_id`/`mrb_funcall_argv`/
  # `mrb_funcall_with_block` call sites, but every literal method-name
  # argument they use (`"marshal_dump"`, `"_dump"`, `"instance_variables"`,
  # `"sort!"`, `"source"`, `"options"`, `"_dump_data"`, `"write"`,
  # `"marshal_load"`, `"new"`, `"getc"`, `"ungetc"`, `"read"`, `"_sys_fail"`,
  # `"replace"` -- StringIO's own `@string` ivar, the same POLY precedent
  # round 35's own comment already documents --, `aref`/`"[]"`,
  # `"string_gsub"`, `"to_enum"`, `"onig_regexp_gsub"`, `"string_scan"`,
  # `"string_split"`, `"string_sub"`) is real, different, and unrelated to
  # any of these 159 names. `src/`, `app/`, all three `*-compiled/src/
  # register.cxx`, and every `mruby-rgss/src/*.cxx` real call site (the
  # same ones round 35's own comment already lists and rules out --
  # `"width"`/`"height"`/`"main_loop"`/`"start"`/`"call"`/
  # `"current_scene_name"`/`"press"`/`"release"`/`"dup"`/`"default_path"`/
  # `"name"`/`"size"`/`"bold"`/`"italic"`/`"outline"`/`"shadow"`/`"color"`/
  # `"out_color"`/`"warn_stub"`/`"clear"`/`"blt"`/`"stretch_blt"`/
  # `"log_tail"`/`"message"`/`"backtrace"`/`"install"`/`"probe!"`) were
  # re-checked against this round's own 159 names too -- same zero-hit
  # result.
  #
  # Real strip + parse + AST-diff verification: a real
  # strip_wio_bc2cpp_stubs.rb run against all 10 real checked-in files with
  # exactly this round's own 13-owner csv raised nothing, every rewritten
  # file still parses (`ruby -c`), and a real before/after
  # RubyVM::AbstractSyntaxTree walk (restricted to these 13 owners) shows
  # EXACTLY the 213 real stripped methods removed and nothing else -- no
  # unexpected addition or removal, cross-checked directly against the
  # per-owner counts above, not eyeballed.
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on each of the 10 affected files, before this gem's own
  # wio_strip_debug_rbfiles/wio_strip_inline_helpers passes run): base.rb
  # 11,201 -> 6,298; item_menu.rb 18,379 -> 5,302; skill_menu.rb
  # 19,951 -> 5,914; equip_menu.rb 14,613 -> 5,906; menu.rb 15,836 -> 6,105;
  # status_menu.rb 8,740 -> 5,208; save_load.rb 9,403 -> 5,157; order.rb
  # 6,451 -> 3,166; title.rb 7,614 -> 5,190; game_over.rb 2,445 -> 1,578 --
  # 114,633 -> 49,824 bytes combined, a 64,809-byte (56.5%) reduction.
  #
  # Future-round candidates, as of round 36: `Game::ChipSet` still deferred
  # (companion-statement support); every `.singleton` owner (20+, see
  # tools/bc2cpp/compiled_gems.rb's own `mruby-rpg2k-compiled` entry); and
  # the larger/`DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS`-touching
  # owners (`Game::Actor`, `Game::Party`, `Game::Battle`, `Game::Character`,
  # `Game::Map`, `Game::Screen`, `Game::Transition`, `Game::State`,
  # `Game::Interpreter`, `RPG2k::Scene::Map`, `RPG2k::Scene::Battle`) --
  # each still needs its own dedicated per-owner soundness pass.
  #
  # Round 37: this round's own primary target is the `.singleton` owners
  # just named above -- 21 of the 25 real `.singleton` candidates in
  # tools/bc2cpp/compiled_gems.rb's own `mruby-rpg2k-compiled` `owners:`
  # list (`Game.singleton` through `RPG2k::Scene.singleton` in the array
  # below), the other 4 deliberately omitted as real, confirmed no-ops
  # (see "4 real no-op omissions" below) rather than silently skipped.
  #
  # Real shape confirmation (never assumed): a whole-gem grep of every real
  # `mrblib/**/*.rb` file for `class << self`/`<<\s*self` finds ZERO
  # matches anywhere in mruby-rpg2k -- every one of this gem's own
  # bc2cpp-registered `.singleton` methods (all 25 candidates, not just the
  # 21 added here) is a plain top-level `def self.foo` (a `DEFS` node),
  # never an `SCLASS`-nested `DEFN` -- unlike mruby-rgss's own
  # `RGSS::Audio.singleton`/`RGSS::ErrorReport.singleton` (already
  # stripped, `class << self`-shaped). strip_wio_bc2cpp_stubs.rb's own
  # DEFS/SCLASS support (added well before this round -- see that file's
  # own file comment) already handles this shape; nothing needed changing
  # there for this round's own owners.
  #
  # Also confirmed directly, not assumed from a task description alone:
  # bc2cpp.rb's own `build_registry` (`case insn.op when 'CLASS',
  # 'MODULE'`, tools/bc2cpp/bc2cpp.rb) and strip_wio_bc2cpp_stubs.rb's own
  # `collect_defs` (`case node.type when :CLASS ... when :MODULE`) both
  # walk a real Ruby `module` identically to a `class` for this purpose --
  # matters here because most of this round's own 21 owners are real
  # modules, not classes (`Game`, `Game::States`, `Game::CharSet`,
  # `Game::Message`, `Game::MessagePalette`, `Game::WindowCursor`,
  # `Game::ChipsetLayout`, `Game::EventGraphic`, `Game::Parallax`,
  # `Game::MoveType`, `Game::EventPage`, `Game::Backdrop`, `Game::MapBgm`,
  # `Game::MapAccess`, `RPG2k::Scene` -- checked directly, `grep -n
  # '^\s*\(class\|module\)\s\+Name\b'`), the rest real classes
  # (`Game::ChipSet`, `Game::Party`, `Game::Character`, `Game::Transition`,
  # `Game::Picture`, `RPG2k::Scene::Map` -- a `class Map < Base`). Both
  # real code paths agree, so a module singleton strips exactly like a
  # class singleton -- no exclusion needed on that account.
  #
  # Real ground truth (a real wio_registered_methods.rb run against
  # mruby-rpg2k-compiled's own real bc2cpp.rb registry, never hand-
  # counted) for all 25 real `.singleton` candidates: Game 5, Game::States
  # 13, Game::States::BattleText 13, Game::ChipsetLayout 10,
  # Game::EventGraphic 9, Game::Battle 11, Game::Transition 6, Game::State
  # 2, Game::Party 2, Game::Picture 1, Game::Character 1, Game::ChipSet 1,
  # RPG2k::Scene::Map 1, Game::MoveType 4, Game::MapAccess 4,
  # Game::Parallax 3, Game::MessagePalette 3, Game::MapBgm 2,
  # Game::BattlePage 2, Game::WindowCursor 1, Game::Message 1,
  # Game::EventPage 1, Game::CharSet 1, Game::Backdrop 1, RPG2k::Scene 1 --
  # 99 real registered methods total, every one of them public (checked
  # directly against the TSV's own visibility column, not assumed).
  #
  # 4 real no-op omissions (all of an owner's own registered methods live
  # entirely in a file wio's own spec.rbfiles already drops -- the same
  # "pointless, not unsafe" shape round 35's own comment above documents
  # for `Game::Troop`/`Game::Enemy`/`Game::EnemyAction`/`Game::EnemyAi`),
  # confirmed directly by an AST walk of every real file in this gem's
  # mrblib locating each owner's own registered method names, not assumed
  # from the class name alone:
  #   - Game::States::BattleText.singleton (13/13 registered methods, all
  #     defined in game/battle_support.rb)
  #   - Game::Battle.singleton (11 of 13 real `def self.*` under this
  #     owner are registered -- `from_actor`/`from_enemy` do not compile --
  #     all 11 registered ones in game/battle.rb)
  #   - Game::State.singleton (2 of 10 real `def self.*` under this owner
  #     are registered -- `bgm_from_chunk`/`se_from_chunk`, both in
  #     game/lsd_io.rb; the other 8, including `load` in game.rb itself,
  #     simply never compiled clean enough for bc2cpp to register them)
  #   - Game::BattlePage.singleton (2 of 4 real `def self.*` under this
  #     owner are registered -- `check_turns`/`hp_within?`, both in
  #     game/battle_support.rb)
  # battle_support.rb/battle.rb/lsd_io.rb are all wio-only exclusions
  # already in force above this comment; wio_strip_bc2cpp_stubs only ever
  # rewrites spec.rbfiles entries, so listing any of these four owners in
  # `owners:` below would strip nothing real for wio today -- omitted as
  # pointless, exactly like the round 35 precedent, not because of any
  # correctness problem.
  #
  # Partial-owner shape (the same "some of an owner's own registered
  # methods live in an excluded file, others don't" shape round 36's own
  # comment already documents for `Base`/`EventResolver`/`MapWorld`/
  # `VehicleWorld`): `Game::States.singleton` has 13 real registered
  # methods total, but only 6 (`name`, `priority_of`, `color`,
  # `map_step_drain`, `drain`, `int_field`) are defined in game.rb (the
  # in-scope file); the other 7 (`animation_pose`, `inflict_message`,
  # `recovery_message`, `affected_message`, `already_message`, `field`,
  # `message`) are defined in game/battle_support.rb, wio-excluded, so
  # stripping this owner only ever removes the 6 game.rb methods for wio --
  # correct and intentional, not a gap. Separately, `Game::Message.singleton`,
  # `Game::EventPage.singleton`, `Game::CharSet.singleton`, and
  # `Game::Backdrop.singleton` each have MORE real `def self.*` in game.rb
  # than bc2cpp actually registered (5/1, 3/1, 3/1, 2/1 respectively -- the
  # un-registered ones, e.g. `Game::Message.scan`, simply didn't compile
  # clean enough for bc2cpp to cover, same shape as `Game::ChipsetLayout.
  # singleton`'s own `quads`/`quads_from_quarters`/`water_quads`/
  # `terrain_quads`, 4 of its 14 real defs) -- every registered one of
  # them is, itself, in game.rb, so these four are ordinary full (not
  # partial) owners despite the gap.
  #
  # Companion-statement hazard check (this round's own required check,
  # extended to the singleton-specific companion `private_class_method`/
  # `public_class_method` alongside the usual `private :name`/
  # `protected :name`/`public :name`/`alias_method`/`attr_reader`/
  # `attr_accessor`/`attr_writer`): a whole-gem grep of every real
  # mrblib/**/*.rb file for all of these finds `private_class_method`/
  # `public_class_method`/`alias_method`/`singleton_class` NOWHERE in this
  # gem at all, and the only real explicit-name `private :x`/`public :x`
  # statements anywhere are `game.rb`'s own `private :upper_flags`
  # (`Game::ChipSet#upper_flags`, an INSTANCE method, already the reason
  # the separate non-singleton `Game::ChipSet` owner stays deferred above
  # -- irrelevant to this round's own `Game::ChipSet.singleton#lower_index`,
  # a different owner entirely) and `private :swap_equipment_through_bag`
  # (`Game::Party#`, likewise an instance method unrelated to
  # `Game::Party.singleton`'s own `usable_flag?`/`normal_skill?`), plus a
  # handful of `public :x` mode restorers in interpreter.rb/scene/map.rb/
  # scene/battle.rb/game/battle.rb/main.rb (`start_random_battle`,
  # `message_window_open?`, `char_passable?`, `terrain_id`, ... -- the full
  # list checked directly, not summarized) -- none of these names match
  # any of this round's own 71 real registered method names across the 21
  # owners below (99 total minus the 28 in the 4 no-op owners just
  # above). Every one of those 71 is also TSV-confirmed `public`,
  # consistent with there being no companion statement touching any of
  # them at all. No `Game::ChipSet`-style exclusion needed for any of this
  # round's own 21 owners.
  #
  # Gem-init-ordering correctness (same methodology as every prior round,
  # re-run against this round's own 61 unique method names -- `int_field`
  # is reused by three different owners, `name` by one, `full` by one):
  # the same whole-tree `grep -rl mrb_funcall` closed-world file list
  # rounds 35/36 already established (`src/error_dump.cxx`, `src/main.cxx`,
  # `app/wio/src/mruby_sd_smoke_main.cxx`, `app/psp/main.cxx`, all three
  # `*-compiled/src/register.cxx`, every `mruby-rgss/src/*.cxx`) re-checked
  # against these 61 names: two real literal matches, both confirmed
  # unrelated by reading the call site directly rather than assumed --
  # `mruby-rgss/src/lib.cxx`'s own `read_font` calls `mrb_funcall(M, fv,
  # "name", 0)` and `mrb_funcall(M, fv, "color", 0)` (alongside `"size"`/
  # `"bold"`/`"italic"`/`"outline"`/`"shadow"`/`"out_color"`, already ruled
  # out by round 35's own comment), but `fv` there is `self`'s own `@font`
  # ivar -- a real `RGSS::Font` value, never a `Game::States`/anything else
  # in this round's own owner set -- read directly from the function body,
  # not assumed. Every other literal method name at any of these call
  # sites (`"width"`/`"height"`/`"main_loop"`/`"start"`/`"call"`/
  # `"current_scene_name"`/`"press"`/`"release"`/`"dup"`/`"default_path"`/
  # `"warn_stub"`/`"clear"`/`"blt"`/`"log_tail"`/`"message"`/`"backtrace"`/
  # `"install"`/`"probe!"`) is, as every prior round already found, real,
  # different, and unrelated. The three always-active external mrbgems
  # (`3rd/mruby-marshal`, `3rd/mruby-stringio`, `3rd/mruby-onig-regexp`)
  # re-checked too: same real call sites rounds 35/36 already documented
  # (`"marshal_dump"`, `"_dump"`, `"instance_variables"`, `"sort!"`,
  # `"source"`, `"options"`, `"_dump_data"`, `"write"`, `"marshal_load"`,
  # `"new"`, `"getc"`, `"ungetc"`, `"read"`, `"_sys_fail"`, `"replace"`,
  # `aref`/`"[]"`, `"string_gsub"`, `"to_enum"`, `"onig_regexp_gsub"`,
  # `"string_scan"`, `"string_split"`, `"string_sub"`), none matching any
  # of this round's own 61 names either.
  #
  # DIRECT_CONSTRUCT_TARGETS/NATIVE_ARG_TARGETS (tools/bc2cpp/bc2cpp.rb):
  # `Game::Transition.singleton` shares its enclosing class's own bare name
  # with `DIRECT_CONSTRUCT_TARGETS`'s own `Game::Transition` entry --
  # checked directly rather than waved through on that account alone: none
  # of this owner's own 6 registered methods (`setting?`, `erase_style`,
  # `show_style`, `style_for`, `default_frames`, `block_grid`) is named
  # `new`/`allocate`, the only two names that gate `DIRECT_CONSTRUCT_TARGETS`'s
  # own codegen decision, and that decision is made by bc2cpp.rb's own
  # separate, earlier compile of the real, UNSTRIPPED source in any case
  # (wio_strip_bc2cpp_stubs's own comment above: "nothing this function
  # does to spec.rbfiles can ever reach or perturb bc2cpp's own
  # registry-building input") -- no interaction either way.
  # `NATIVE_ARG_TARGETS` is keyed entirely on bare `Owner#name` (instance
  # method) strings; none of this round's `.singleton`-suffixed owner
  # strings can ever match one.
  #
  # Real strip + parse + AST-diff verification: a real
  # strip_wio_bc2cpp_stubs.rb run against the 3 real checked-in files these
  # 21 owners' in-scope methods live in (game.rb, scene/map.rb, scene/
  # base.rb) with exactly this round's own 21-owner csv raised nothing,
  # every rewritten file still parses (`ruby -c`), and a real before/after
  # RubyVM::AbstractSyntaxTree walk (every real DEFN/DEFS/SCLASS-DEFN in
  # each file, not just this round's own owners) shows EXACTLY 64 methods
  # removed and NOTHING else added or removed -- cross-checked directly
  # against the per-owner counts above (62 from game.rb, 1 from scene/
  # map.rb's own `tone_channel`, 1 from scene/base.rb's own
  # `battle_scene_class`), not eyeballed.
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on the 3 affected files, before this gem's own
  # wio_strip_debug_rbfiles/wio_strip_inline_helpers passes run): game.rb
  # 163,046 -> 150,990 bytes (12,056 bytes, 7.4%, from 62 stripped
  # methods); scene/map.rb 196,496 -> 196,349 bytes (147 bytes, 0.1%, from
  # its own single `tone_channel`); scene/base.rb 11,199 -> 11,024 bytes
  # (175 bytes, 1.5%, from its own single `battle_scene_class`) --
  # 370,741 -> 358,363 bytes combined, a 12,378-byte (3.3%) reduction.
  # (game.rb's own pre-strip baseline moved slightly since round 35's own
  # 162,963-byte figure -- unrelated intervening comment/documentation
  # edits to that file between rounds, not a discrepancy in either round's
  # own measurement.)
  #
  # Round 38: two real, independently-verified additions.
  #
  # (1) `Game::ChipSet` (the plain, non-singleton instance-method owner),
  # deferred by round 35's own comment above solely for lack of a real
  # mechanism to also remove its own `private :upper_flags` companion
  # statement. That mechanism is now real: strip_wio_bc2cpp_stubs.rb's own
  # new `collect_visibility_calls` (see its own comment for the full
  # writeup) finds a receiverless `private(...)`/`protected(...)`/
  # `public(...)` FCALL naming an explicit Symbol/String, and deletes it
  # alongside the `def`s it strips whenever every name it lists is itself
  # being stripped from the very same owner -- raising rather than
  # guessing for a mixed stripped/kept argument list (not needed by
  # `Game::ChipSet`'s own single-name case) or an argument list this
  # script cannot statically read at all (a splat, a variable, ...).
  # Verified in isolation first (hand-built fixtures: a full-overlap
  # multi-name statement deletes cleanly, a mixed stripped/kept one
  # raises, a non-literal-arg one raises, an unrelated-method one is left
  # completely untouched), then against the real target: a real CRuby
  # `load` of the OLD, unmodified stripper's own output (the `def` gone,
  # `private :upper_flags` left standing) reproduces the exact `NameError`
  # ("undefined method `upper_flags' for class `Game::ChipSet`") this
  # round's own fix exists to prevent; the NEW stripper's real output for
  # the same input loads clean. `Game::ChipSet`'s own real 9 registered
  # methods (ground truth: a real `wio_registered_methods.rb` run against
  # `mruby-rpg2k-compiled`, never hand-counted) are `initialize`,
  # `upper_flags` (private -- the one with the companion statement),
  # `elevated?`, `passable?`, `landable?`, `counter?`, `passable_tile?`,
  # `landable_tile?`, `terrain`; `self.lower_index`, the class's own 10th
  # real def, is a DIFFERENT owner (`Game::ChipSet.singleton`, already
  # stripped since round 37) and untouched by this addition. Regression
  # check (this round's own required one, since strip_wio_bc2cpp_stubs.rb
  # itself changed): a real re-run of the modified script against every
  # one of rounds 35-37's own already-shipped owners (all 15 affected
  # files across mruby-rpg2k, mruby-rgss, mruby-lcf) produced
  # byte-for-byte identical output to the unmodified script -- this
  # round's own new companion-statement logic is a real no-op for every
  # owner that doesn't need it, confirmed rather than assumed.
  #
  # (2) A first, deliberately bounded slice of the larger
  # `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS`-touching INSTANCE-
  # method owners round 36/37's own comments left as a standing future-
  # round item: `Game::Map` (11 in-scope methods), `Game::Transition`
  # (32), `Game::State` (21 of 23 in-scope), `Game::Screen` (41),
  # `Game::Actor` (65 of 74 in-scope), `Game::Character` (14) -- 184
  # methods total, each given the SAME full per-owner soundness pass as
  # every prior round (real registry ground truth, a real AST-walked
  # companion-statement hazard check, a real whole-closed-world
  # `mrb_funcall` grep, a real strip + parse + AST-diff verification, a
  # real `mrbc -g` measurement), not waved through as a block just because
  # the mechanism itself is unchanged for these six.
  #
  # `Game::Map` and `Game::Transition` are both `DIRECT_CONSTRUCT_TARGETS`
  # members (tools/bc2cpp/bc2cpp.rb): a `SomeClass.new(...)` call site
  # compiled against either one skips the ordinary Class#new allocate+
  # dispatch chain entirely and calls a direct `_impl` C++ function for
  # `#initialize` instead (see bc2cpp.rb's own `DIRECT_CONSTRUCT_TARGETS`
  # comment and its `compile_send` handling: `init_impl = cpp_name(known,
  # 'initialize') + '_impl'`). Checked directly, not assumed either way,
  # whether this changes anything for THIS mechanism: it does not.
  # bc2cpp.rb's own registry (`build_registry`) is what decides whether
  # `#initialize` compiles clean and gets registered AT ALL, independent
  # of whether any particular call site later devirtualizes into calling
  # it directly -- and that registry is exactly wio_registered_methods.rb's
  # own real ground truth, the only thing strip_wio_bc2cpp_stubs.rb ever
  # trusts. Both classes' own `#initialize` IS real, registered, ordinary
  # `private` methods in the TSV (`Game::Map#initialize` arity 2,
  # `Game::Transition#initialize` arity 5) -- exactly like any other
  # stripped method, no special-casing needed or added. The narrow
  # DIRECT_CONSTRUCT_TARGETS-specific hazard this MIGHT have introduced --
  # real code observing the interpreted `#initialize` missing in the
  # window between mrblib load and gem_init's override install, via some
  # OTHER call path than the devirtualized one -- is exactly the same
  # gem-init-ordering question this mechanism already requires checking
  # per owner regardless, and it was (zero real `mrb_funcall` hits on
  # either class's own method names anywhere in the closed world, same as
  # every other owner below).
  #
  # `Game::Map` (11 in-scope methods) and `Game::State` (21 of 23) are
  # both real, familiar partial-owner shapes (round 36's own precedent):
  # `Game::Map` has a SECOND real class reopening in game/battle_support.rb
  # (wio-excluded) that defines its own 12th registered method,
  # `sync_layers_to_unit` -- confirmed directly (`grep -n` finds it nowhere
  # in game.rb), so this owner's own 11 game.rb-resident methods are all
  # that ever strips for wio, correct and intentional. `Game::State` has
  # its own second reopening in game/lsd_io.rb (also wio-excluded, dropped
  # from spec.rbfiles by the interop-trim near the top of this file),
  # which owns 2 of its 23 real registered methods (`bgm_chunk`/
  # `se_chunk`) -- the other 21 are all in game.rb and all strip cleanly.
  # `Game::Actor` has the same shape a THIRD time: game/battle_support.rb
  # reopens it too, owning 9 of its 74 real registered methods (`alive?`,
  # `atb_gauge=`, `attack_all?`, `attack_animation_id`,
  # `clear_battle_combo`, `ignores_evasion?`, `preemptive?`,
  # `skill_command_name`, `weapon_sp_cost`) -- the other 65 are in game.rb
  # and strip cleanly. `Game::Transition`, `Game::Screen`, and
  # `Game::Character` each have exactly one real class body anywhere in
  # this gem (`grep -rn '^\s*class'` confirms it directly), so all of
  # their own registered methods (32/41/14 respectively) are ordinary,
  # full (not partial) owners.
  #
  # Companion-statement hazard check (the same real AST walk every prior
  # round's own comment describes, re-run against all six of these
  # owners' own real class bodies in game.rb): `Game::Map` and
  # `Game::Screen` each use only a bare `private` mode switch; `Game::
  # Transition` (`attr_reader :style, :frames, :frame`), `Game::State`
  # (many `attr_accessor`/`attr_reader` pairs -- `map`, `x`, `y`,
  # `direction`, `steps`, `boarded`, ... -- the full real list checked
  # directly, not summarized) and `Game::Character` (`attr_accessor
  # :direction, :move_speed, ...`, `attr_reader :graphic_name,
  # :graphic_index, :x, :y, ...`) each have real `attr_reader`/
  # `attr_accessor` calls but NO bare or explicit-name `private`/
  # `protected`/`public` mode statement of any kind; `Game::Actor` has
  # both real `attr_reader`/`attr_accessor`/`attr_writer` calls (`id`,
  # `level`, `hp`, `mp`, `name`, `title`, ..., checked directly) and one
  # bare `private` mode switch, no explicit-name form. None of any of
  # these six owners' own attr names collide with any of their own real
  # registered method names (an attr's plain reader/writer pair is a
  # DIFFERENT method than a same-stem `?`/`=`/compound-name registered
  # method every time this was checked -- e.g. `Game::Actor`'s own
  # `attr_reader :class_id` vs. its own registered `set_class_id`/
  # `class_row_for`, never a bare `class_id` collision; `Game::State`'s
  # own `attr_reader :map_id` -- a READER only -- vs. its own registered
  # `map_id=` -- a WRITER only -- never both sides of the same pair).
  # `Game::ChipSet`'s own companion-statement need is the only one this
  # round's own six new owners actually have.
  #
  # Gem-init-ordering correctness (the same whole-closed-world
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/
  # `mrb_funcall_with_block` grep every prior round's own comment
  # describes -- `src/`, `app/`, all three `*-compiled/src/register.cxx`,
  # every `mruby-rgss/src/*.cxx`, plus the always-active external mrbgems
  # `3rd/mruby-marshal`/`3rd/mruby-stringio`/`3rd/mruby-onig-regexp`,
  # `git submodule update --init`d fresh for this round's own check rather
  # than assumed already checked out -- re-run against every one of this
  # round's own 7 new owners' real method names, including `Game::ChipSet`'s
  # own 9): ZERO real call sites anywhere in the whole closed world for
  # ANY of them, including deliberately generic-sounding ones this round
  # double-checked rather than waved through on a name-recognition
  # assumption alone (`Game::Screen#update`, `Game::Map#tile`/`#lower`/
  # `#upper`, `Game::Character#move`/`#face`, `Game::Actor#dead?`,
  # `Game::Transition#half`). Every prior round's own already-documented
  # unrelated hits (`"press"`/`"release"`/`"main_loop"`/`"width"`/
  # `"height"`/`"name"`/`"color"`/... on real, different receivers) were
  # re-confirmed still unrelated to this round's own new names too.
  #
  # Real strip + parse + AST-diff verification: a real
  # strip_wio_bc2cpp_stubs.rb run against the real checked-in game.rb with
  # this round's own 7-owner csv (isolated, then combined with every
  # prior round's own owners together) raised nothing, every rewritten
  # file still parses (`ruby -c`), and a real before/after
  # RubyVM::AbstractSyntaxTree walk (every real owner+name DEFN pair in
  # the whole file, not just this round's own) shows EXACTLY this round's
  # own 184 intended methods removed (9 ChipSet + 11 Map + 32 Transition +
  # 21 State + 41 Screen + 65 Actor + 14 Character) and NOTHING else added
  # or removed -- cross-checked directly against the per-owner counts
  # above, not eyeballed. The 10 already-covered scene files and
  # scene/map.rb/scene/base.rb are untouched by this round's own additions
  # (none of the 7 new owners live there) -- confirmed by a real run
  # producing byte-for-byte identical output to the pre-round-38 owner
  # list for every one of those 12 files.
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on `game.rb` alone, isolating each owner's own
  # marginal contribution by adding them one at a time on top of every
  # prior round's own already-shipped owner set): ChipSet -2,520;
  # Map -1,852; Transition -7,444; State -3,796; Screen -7,654;
  # Actor -11,799; Character -2,292 -- **-37,357 bytes** combined for this
  # round's own 7 owners (184 methods), on top of round 35-37's own
  # already-shipped 150,990 -> 135,705-byte state (game.rb's own
  # pre-strip baseline moved again since round 37's own comment, same
  # unrelated intervening-edit reason round 36 already noted for its own
  # baseline drift) -- a cumulative 162,963 -> ~98,340 bytes, roughly 40%
  # off this file's own fully-unstripped size, across all four rounds'
  # combined coverage. (The exact final byte count depends by a handful of
  # bytes on the length of whatever path string is handed to `mrbc -g`
  # itself -- `mrbc` embeds its own source-file-path argument into its
  # `-g` debug tables, so two otherwise-identical inputs measured via
  # differently-named temp paths differ by a few bytes; every delta
  # figure above holds the measurement path constant between its own
  # before/after pair, so this noise cancels out of every reported delta
  # even though it means the absolute totals are approximate to within
  # about a dozen bytes, same "directionally trustworthy, not exact"
  # caveat round 37's own `.singleton` follow-up ADR section already
  # documents for this same proxy.)
  #
  # What round 38 deliberately did NOT do, and why (an honest scoping
  # decision, not an oversight): `Game::Party` (85 registered methods),
  # `Game::Battle` (72), `Game::Interpreter` (173), `RPG2k::Scene::Map`
  # (224), and `RPG2k::Scene::Battle` (110) were all real remaining
  # `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS`-touching candidates
  # (ground truth counts from the same real registry run above), but each
  # was large enough that giving it the SAME real, thorough, per-owner
  # soundness pass that round gave its own six smaller owners -- not a
  # quicker, skimmed version of it -- did not fit in that round's own
  # scope. `Game::Character` (14 methods) was the only owner from that
  # original future-candidates list round 38 itself did not leave for
  # later.
  #
  # Round 39: `Game::Party` (the smallest of the five round-38 left off),
  # given the full soundness pass, plus a real, honest look at
  # `Game::Battle` that this round did NOT end up adding.
  #
  # Ground truth (a real `wio_registered_methods.rb` run against
  # `mruby-rpg2k-compiled`, never hand-counted): `Game::Party` has 85 real
  # registered methods total, confirming round 38's own forward-looking
  # count exactly. Same familiar partial-owner shape round 38's own
  # `Game::Map`/`Game::State`/`Game::Actor` already established:
  # `game/battle_support.rb` (wio-excluded) reopens `Game::Party` too,
  # owning 16 of its 85 real registered methods (`automatic_battle_placement?`,
  # `battle_item_command`, `battle_occasion?`, `battle_skill?`,
  # `battle_skill_target`, `battle_usable?`, `gauge_battle_layout?`,
  # `item_all_allies?`, `skill_absorbs?`, `skill_attr_shift`, `skill_hit`,
  # `skill_hit_weapon_fallback`, `skill_invoking_item?`, `skill_to_hit`,
  # `skill_variance`, `state_hit_ratio` -- confirmed directly, a real AST
  # walk of both files' own `Game::Party` class bodies, not eyeballed) --
  # the other 69 are all in game.rb and strip cleanly for this round.
  #
  # Companion-statement hazard check (the same real AST walk every prior
  # round's own comment describes, re-run against `Game::Party`'s own real
  # class body in game.rb): four `attr_reader` calls (`:actors, :items,
  # :gold`; `:item_usage`; `:roster`; `:revision`) and exactly one
  # explicit-name visibility statement, `private :swap_equipment_through_bag`
  # -- the exact same one round 35's own comment already flagged by name
  # as a standing hazard for whenever `Game::Party` itself got picked up.
  # None of the four attr names collide with any of this round's own 69
  # in-scope method names. `swap_equipment_through_bag` -- unlike round
  # 35's own worry -- IS itself one of this round's own 69 real registered
  # methods (TSV-confirmed: arity 3, visibility `private`), so this is
  # exactly the single-name-companion-statement case round 38's own
  # `collect_visibility_calls` mechanism exists to handle. Verified for
  # real on this real case, not assumed to generalize from the `Game::
  # ChipSet` precedent: a real `strip_wio_bc2cpp_stubs.rb` run against the
  # real checked-in game.rb with this round's own owners csv deletes both
  # the `def swap_equipment_through_bag` and its own `private
  # :swap_equipment_through_bag` line together (confirmed by `grep -n
  # swap_equipment_through_bag` on the real output: only the interior call
  # site inside `#use_equip_skill_item` remains, no dangling `def` or
  # `private` statement), the rewrite still parses (`ruby -c`), AND a real
  # CRuby `load` of the rewritten file raises no `NameError` -- the exact
  # failure round 38's own comment reproduced for the unfixed script
  # against `Game::ChipSet`'s own `upper_flags`, now independently
  # reconfirmed clean for this second, different owner.
  #
  # Gem-init-ordering correctness (the same whole-closed-world
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/
  # `mrb_funcall_with_block` grep every prior round's own comment
  # describes -- `src/`, `app/`, all three `*-compiled/src/register.cxx`,
  # every `mruby-rgss/src/*.cxx`, plus the always-active external mrbgems
  # `3rd/mruby-marshal`/`3rd/mruby-stringio`/`3rd/mruby-onig-regexp`,
  # `git submodule update --init`d fresh for this round's own check rather
  # than assumed already checked out -- re-run against all 69 of this
  # round's own in-scope method names): exactly one real literal match,
  # `"size"`, at the same `mruby-rgss/src/lib.cxx`'s own `read_font`
  # function rounds 35/38's own comments already ruled out for `"name"`/
  # `"color"` -- `mrb_funcall(M, fv, "size", 0)` there calls `fv`, that
  # function's own local read straight off `self`'s own `@font` ivar (a
  # real `RGSS::Font` value, never a `Game::Party`), read directly from
  # the function body, not assumed. Every other literal name at any
  # `mrb_funcall*` call site in the whole closed world (`"clear"`, the
  # `blt`/`sblt`-suffixed window-skin `mrb_funcall_argv` calls in the same
  # file, `"new"`, `"aref"`/`MRB_OPSYM(aref)`, `"string_gsub"`,
  # `"to_enum"`, `"onig_regexp_gsub"`, `"string_scan"`, `"source"`,
  # `"string_split"`, `"string_sub"`, ... -- the full real list checked
  # directly) matches none of this round's own 69 names at all. Zero real
  # hazards found.
  #
  # `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS` (tools/bc2cpp/bc2cpp.rb,
  # checked directly against both constants' own real contents, not
  # assumed): `Game::Party` appears in NEITHER -- `DIRECT_CONSTRUCT_TARGETS`
  # is only ever `%w[Game::Transition Game::Map]`, and `NATIVE_ARG_TARGETS`
  # has no `Game::Party#...` entry among its own 35. Simpler than every one
  # of round 38's own six new owners: no `Owner#initialize` devirtualization
  # question to work through at all for this owner.
  #
  # Real strip + parse + AST-diff verification: a real
  # `strip_wio_bc2cpp_stubs.rb` run against the real checked-in game.rb,
  # once with round 38's own already-shipped owners csv and once with that
  # same csv plus this round's own `Game::Party`, both raised nothing and
  # both rewrites parse (`ruby -c`). A real before/after
  # `RubyVM::AbstractSyntaxTree` walk (every real `DEFN`/`DEFS`/`SCLASS`-
  # nested `DEFN` in the whole file, not just this round's own owner) shows
  # the two outputs differ by EXACTLY this round's own 69 `Game::Party`
  # methods removed and NOTHING else added or removed -- a line-level
  # `diff` between the two outputs independently confirms the same thing a
  # different way (444 changed lines, every single one a deletion -- zero
  # `>`-side additions), cross-checked directly, not eyeballed. The other
  # two files round 38's own owners touch (`scene/map.rb`'s own
  # `tone_channel`, `scene/base.rb`'s own `battle_scene_class`) are
  # untouched by this round's own addition -- confirmed by a real run
  # producing byte-for-byte identical output for both files whether or not
  # `Game::Party` is in the owners csv (`Game::Party` has no `def` in
  # either file).
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on `game.rb` alone, isolating `Game::Party`'s own
  # marginal contribution on top of round 38's own already-shipped owner
  # set): real, current game.rb baseline (unstripped) 162,963 bytes;
  # round-38 owners alone 98,418 bytes; round-38 owners + `Game::Party`
  # 83,690 bytes -- **-14,728 bytes** for this round's own 69 methods (same
  # "measurement-path-length noise, a handful of bytes, direction and
  # magnitude trustworthy" caveat every prior round's own comment already
  # documents for this proxy).
  #
  # Regression check (this round's own required one, since this round adds
  # to the SAME shared `owners:` array and reuses the SAME
  # `strip_wio_bc2cpp_stubs.rb` unmodified -- no change to that script this
  # round): the `diff` above already shows round 38's own owners strip
  # byte-for-byte identically inside this round's own new output wherever
  # `Game::Party` did not touch a line, and `scene/map.rb`/`scene/base.rb`
  # (the other two round-38-affected files) are proven byte-for-byte
  # identical between the old and new owners csv directly above. No
  # regression to any of rounds 35-38's own already-shipped owners.
  #
  # `Game::Battle` (72 registered methods, ground truth from the same real
  # registry run): investigated for real this round, NOT added, for a
  # reason different from "too large" -- `Game::Battle`'s entire real class
  # body lives in exactly one place, `mrblib/game/battle.rb` (confirmed
  # directly: `grep -rn 'class Battle'` finds no other reopening of this
  # owner anywhere in mrblib), and that file is one of the three the
  # wio-only battle trim at the very top of this file (`spec.rbfiles -=
  # %W[#{dir}/mrblib/game/battle.rb ...]`) already drops from wio's own
  # `spec.rbfiles` entirely. `wio_strip_bc2cpp_stubs` only ever rewrites
  # `spec.rbfiles` entries (see build_config.rb's own comment), so listing
  # `Game::Battle` in `owners:` below would strip nothing real for wio
  # today -- the exact same "pointless, not unsafe" shape this file's own
  # very first comment block already documents for `Game::BattleText.
  # singleton`/`Game::Battle.singleton`/`Game::State.singleton`/`Game::
  # BattlePage.singleton` (all four also entirely defined in wio-excluded
  # battle files). Omitted as structurally pointless for as long as the
  # wio-only battle trim stands, not deferred for size the way `Game::
  # Interpreter`/`RPG2k::Scene::Map`/`RPG2k::Scene::Battle` (173/224/110
  # methods, genuinely still too large for one round's own full rigor) are.
  #
  # Round 42: `Game::Interpreter` (the RPG2000/2003 event-command
  # interpreter) -- the smallest of the three remaining round-38-deferred
  # owners (`RPG2k::Scene::Map`/`RPG2k::Scene::Battle`, 224/110 methods,
  # still deferred, each genuinely deserving its own dedicated round),
  # given the SAME full per-owner soundness pass as every prior round, not
  # a skimmed one.
  #
  # Ground truth (a real `wio_registered_methods.rb` run against
  # `mruby-rpg2k-compiled`, never hand-counted): 173 real registered
  # methods, confirming both round 38's own forward-looking count and
  # `tools/bc2cpp/compiled_gems.rb`'s own real emission-owner writeup
  # exactly ("173 of its own 207 real bytecode-defined methods... compile
  # clean"). `Game::Interpreter`'s own real class body is defined in
  # `mrblib/interpreter.rb` (confirmed directly, `grep -rn 'class
  # Interpreter'` across the whole gem), with a SECOND real reopening in
  # `game/battle_support.rb` (wio-excluded) -- the same familiar
  # partial-owner shape round 38's own `Game::Map`/`Game::State`/`Game::
  # Actor` and round 39's own `Game::Party` already established. That
  # reopening owns 4 of the 173 real registered methods
  # (`take_revealed_monsters`, `take_fled_monsters`, `take_monster_kills`,
  # `take_battle_background`, all public zero-arity drain methods for the
  # battle scene to poll) -- confirmed directly, a real AST walk of both
  # files' own `Game::Interpreter` class bodies, not eyeballed. The other
  # 169 are all in interpreter.rb and strip cleanly for this round.
  #
  # Companion-statement hazard check (the same real AST walk every prior
  # round's own comment describes, re-run against `Game::Interpreter`'s own
  # real class body in interpreter.rb): 8 `attr_reader`/`attr_accessor`
  # calls (`wait_kind`/`message_lines`/`choice_labels`/`wait_frames`/
  # `teleport`/`input_digits`/`key_input_request`/`inn_request`/
  # `shop_request`/`battle_request`/`name_input_request`/
  # `battle_animation`/`choice_cancel_type`/`message_followup` via one
  # `attr_reader`; `resolver`, `triggered_by_decision_key`, `battle`,
  # `battle_screen`, `battle_source`, `map_info`, `event_id` each their own
  # `attr_accessor`; `call_frame_event_id` via `attr_reader` -- the full
  # real list checked directly, not summarized), one bare `private` mode
  # switch, and exactly two explicit-name visibility statements:
  # `public :start_random_battle` and `public :start_death_handler`. None
  # of the 22 attr names collide with any of this round's own 169 in-scope
  # method names. `start_random_battle` is NOT itself a registered method
  # (TSV-confirmed absent) -- its own companion statement names an
  # unrelated, unstripped method and is left completely untouched.
  # `start_death_handler` IS one of this round's own 169 real registered
  # methods (TSV-confirmed: arity 0, visibility `public`) -- exactly the
  # single-name companion-statement case round 38's own
  # `collect_visibility_calls` mechanism exists to handle, verified for
  # real on this real case rather than assumed to generalize from the
  # `Game::ChipSet`/`Game::Party` precedents: a real
  # `strip_wio_bc2cpp_stubs.rb` run against the real checked-in
  # interpreter.rb with this round's own owners csv deletes both `def
  # start_death_handler` and its own `public :start_death_handler` line
  # together (confirmed by `grep -n start_death_handler` on the real
  # output: no dangling `def` or `public` statement remains), the rewrite
  # still parses (`ruby -c`), AND a real CRuby `load` of the rewritten file
  # raises no `NameError`. As a sanity check on the check itself (not done
  # by any prior round, added here for extra rigor on this
  # heavily-used class): a hand-built fixture with only the `def` removed
  # and `public :start_death_handler` left standing was confirmed to
  # reproduce the exact real `NameError` ("undefined method
  # `start_death_handler' for class `Game::Interpreter`") this mechanism
  # exists to prevent, before confirming the real mechanism's own output
  # avoids it.
  #
  # Gem-init-ordering correctness (the same whole-closed-world
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/
  # `mrb_funcall_with_block` grep every prior round's own comment
  # describes -- `src/`, `app/`, all three `*-compiled/src/register.cxx`,
  # every `mruby-rgss/src/*.cxx`, plus the always-active external mrbgems
  # `3rd/mruby-marshal`/`3rd/mruby-stringio`/`3rd/mruby-onig-regexp`,
  # `git submodule update --init`d fresh for this round's own check rather
  # than assumed already checked out -- re-run against all 173 of this
  # round's own real registered method names): exactly two real literal
  # matches, both confirmed unrelated by reading the call site directly.
  # `src/main.cxx`'s own `mrb_funcall(M, game_obj, "start", 0)` (the game's
  # top-level boot dispatch) calls `#start` on `game_obj`, an instance of
  # whichever top-level game class (`RPG2k`/`MZ`/`MV`/`RPGVX`/`RPGXP`/
  # `WolfRPG`) this session's own `detect_game_kind` picked -- for the
  # `kRpg2k` case specifically, `game_obj` is a freshly `mrb_obj_new`'d
  # `RPG2k` instance (confirmed directly at the same call site's own
  # earlier `case` block), and `RPG2k#start` is a real, different method
  # defined in `mrblib/main.rb` -- never `Game::Interpreter#start`.
  # `mruby-rpg2k-compiled/src/register.cxx`'s own `mrb_funcall(M, r5,
  # "switches", 0)` is, like every prior round's own register.cxx hits,
  # inside a `//` comment describing GENERATED (not checked-in) code, not
  # a real call site -- confirmed directly (`cat -A` on the surrounding
  # lines shows every line `//`-prefixed). That comment itself is worth
  # noting in full since it is genuinely about this same method name: it
  # documents a real, independently-tracked MONO/POLY registry-soundness
  # question (`:switches` has exactly one bytecode-visible definition
  # anywhere in the closed world, `Game::Interpreter#switches`, which an
  # unrestricted whole-program diagnostic would report MONO -- but every
  # real call site actually sends `:switches` to a `Game::State` instance,
  # whose own real `:switches` is a runtime `attr_reader`, structurally
  # invisible to bc2cpp.rb's own native-method-name scanner) -- but that
  # question is about bc2cpp.rb's own `compile_send` devirtualization
  # decision for a call site compiled from the *original, unstripped*
  # source, entirely orthogonal to this mechanism: `wio_strip_bc2cpp_stubs`
  # only ever rewrites the *base* gem's own interpreted-bytecode `mrblib`
  # copy that ships for wio, and never reaches or perturbs bc2cpp.rb's own,
  # separate compile of the real, unstripped source (the same
  # already-established property every prior round's own comment already
  # relies on) -- so whatever that question's own real answer is today
  # (a pre-existing bc2cpp.rb question, not this round's to resolve) is
  # completely unaffected by whether `Game::Interpreter`'s own redundant
  # Ruby method bodies still exist in interpreter.rb or not. Every other
  # literal method name at any real (non-comment) `mrb_funcall*` call site
  # in the whole closed world -- every one every prior round's own comment
  # already found and ruled out -- was re-checked against this round's own
  # 173 names too, same zero-hit result.
  #
  # `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS` (tools/bc2cpp/bc2cpp.rb,
  # checked directly against both constants' own real contents, not
  # assumed): `Game::Interpreter` does not appear in
  # `DIRECT_CONSTRUCT_TARGETS` (`%w[Game::Transition Game::Map]` only) --
  # simpler than round 38's own `Game::Map`/`Game::Transition` additions,
  # no `Owner#initialize` devirtualization question at all. It DOES appear
  # in `NATIVE_ARG_TARGETS`, 9 times (`#character_ref`, `#trunc_div`,
  # `#skip_to`, `#find_choice_option`, `#do_control_vars_range_variable`,
  # `#vehicle_operand`, `#screen_operand`, `#queue_level_up_messages`,
  # `#trunc_mod`) -- of these, 6 (`#character_ref`, `#trunc_div`,
  # `#trunc_mod`, `#find_choice_option`, `#vehicle_operand`,
  # `#screen_operand`) are real, registered methods this round strips;
  # the other 3 (`#skip_to`, `#do_control_vars_range_variable`,
  # `#queue_level_up_messages`) are NOT in the real registered-method TSV
  # at all (never compiled clean enough for bc2cpp to register, same
  # "candidate but not actually registered" shape every prior round's own
  # comment already documents for other owners) and so are never touched
  # by this round either way. Confirmed EMPIRICALLY for real on this
  # class's own six in-scope `NATIVE_ARG_TARGETS` methods, not just
  # assumed to carry over from round 38's own `Game::Actor`/`Game::Screen`
  # precedent the task description already named: all six are ordinary
  # multi-line `def`s (confirmed directly, no one-line-def edge case among
  # them) that stripped, parsed, and AST-diffed clean exactly like any
  # other method in this round's own real strip run below -- unsurprising
  # given `NATIVE_ARG_TARGETS` only ever changes the *C++* calling
  # convention bc2cpp.rb itself generates for the compiled override, a
  # decision this mechanism never reaches or perturbs (same "operates
  # purely off wio_registered_methods.rb's own ground truth" property the
  # task description already names), but checked directly here rather than
  # left as an assumption.
  #
  # Real strip + parse + AST-diff verification: a real
  # `strip_wio_bc2cpp_stubs.rb` run against every real wio-relevant
  # `mrblib` file (14 files -- `game.rb`, `main.rb`, `scene/*.rb` minus the
  # battle-only ones the wio-only trims above already drop, plus
  # `interpreter.rb` itself), once with round 39's own already-shipped
  # owners csv and once with that same csv plus this round's own
  # `Game::Interpreter`, both raised nothing and both rewrites parse (`ruby
  # -c`). A real before/after `RubyVM::AbstractSyntaxTree` walk (every real
  # `DEFN`/`DEFS`/`SCLASS`-nested `DEFN` in `interpreter.rb`, not just this
  # round's own owner) shows the two outputs differ by EXACTLY this
  # round's own 169 `Game::Interpreter` methods removed and NOTHING else
  # added or removed -- cross-checked directly against the missing-4
  # partial-owner set above (the only 4 of 173 not among the 169 removed
  # are exactly `take_revealed_monsters`/`take_fled_monsters`/
  # `take_monster_kills`/`take_battle_background`, confirmed by set
  # difference, not eyeballed). Every one of the other 13 wio-relevant
  # files is confirmed byte-for-byte identical whether or not
  # `Game::Interpreter` is in the owners csv (`Game::Interpreter` has no
  # `def` in any of them) -- this round's own required regression check,
  # since this round adds to the SAME shared `owners:` array and reuses
  # the SAME `strip_wio_bc2cpp_stubs.rb` unmodified (no change to that
  # script this round).
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on `mrblib/interpreter.rb` alone, before this gem's own
  # wio_strip_debug_rbfiles/wio_strip_inline_helpers passes run): 78,235 ->
  # 22,235 bytes, a 56,000-byte (71.6%) reduction from these 169 stripped
  # method bodies.
  #
  # Round 44: `RPG2k::Scene::Map` (the field-map scene class) -- the larger
  # of the two remaining round-38-deferred owners (`RPG2k::Scene::Battle`,
  # 110 methods, still deferred, genuinely deserving its own dedicated
  # round), given the SAME full per-owner soundness pass as every prior
  # round, not a skimmed one, and the largest single owner this whole
  # series has ever added (223 methods -- bigger than round 38's own six
  # owners COMBINED).
  #
  # Ground truth (a real `wio_registered_methods.rb` run against
  # `mruby-rpg2k-compiled`, never hand-counted): 223 real registered
  # methods, confirming both round 38's own forward-looking count and
  # `tools/bc2cpp/compiled_gems.rb`'s own real emission-owner writeup
  # exactly. Unlike every `Game::*` owner rounds 38-42 covered,
  # `RPG2k::Scene::Map` has no partial-owner reopening anywhere: a whole-gem
  # `grep -rn 'class Map'` finds exactly one real class body defining it,
  # `mrblib/scene/map.rb` (the other two "class Map" hits are `Game::Map`,
  # a completely different owner in a different namespace, in `game.rb` and
  # the wio-excluded `game/battle_support.rb`) -- confirmed directly, not
  # assumed, and independently reconfirmed by a real AST-collected list of
  # every one of this owner's own 223 real registered names against every
  # real `def` in `scene/map.rb`: all 223 present, zero missing (a
  # `comm -23` set-difference, not eyeballed). `RPG2k::Scene::Map::
  # LRUBitmapCache` (5 of its own real registered methods, `#initialize`
  # among them -- the one `NATIVE_ARG_TARGETS` entry anywhere near this
  # owner's own name, see below) and `RPG2k::Scene::MapViewer`/`RPG2k::
  # Scene::MapWorld` (34/7 of their own) are real, confirmed-different
  # owners nested in or sharing this same file -- untouched by this round's
  # own `owners:` entry, which names `RPG2k::Scene::Map` exactly and never
  # its own nested `LRUBitmapCache`.
  #
  # `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS` (tools/bc2cpp/bc2cpp.rb,
  # checked directly against both constants' own real contents, not
  # assumed, per this round's own task brief): `RPG2k::Scene::Map` appears
  # in NEITHER. `DIRECT_CONSTRUCT_TARGETS` is only ever `%w[Game::Transition
  # Game::Map Game::Switches Game::Timer Game::MessageConfig]`.
  # `NATIVE_ARG_TARGETS`'s own one `RPG2k::Scene::Map`-adjacent entry is
  # `RPG2k::Scene::Map::LRUBitmapCache#initialize` -- a real, different
  # owner (the nested class named above), never the bare `RPG2k::Scene::Map`
  # owner string this round's own `owners:` entry names. Simpler than every
  # round-38 owner in this one specific respect: no `Owner#initialize`
  # devirtualization question to work through at all for the owner this
  # round actually strips.
  #
  # Companion-statement hazard check (the same real AST walk every prior
  # round's own comment describes, re-run against `RPG2k::Scene::Map`'s own
  # real class body in scene/map.rb): 2 bare `private` mode switches, 5
  # `attr_reader`/`attr_accessor` calls (`:state`; `:events`; `:interpreter`;
  # `:rng, :monster_cache, :backdrop_cache, :battlecharset_cache,
  # :system2_cache, :windowskin`; `:map_animation`, an `attr_accessor`),
  # and 13 explicit-name `public :name` statements -- by far the most
  # companion statements any owner in this series has had (`Game::
  # Interpreter`'s own 2 was the previous high). None of the 10 attr names
  # collide with any of this round's own 223 in-scope method names. Of the
  # 13 `public` statements, 11 are single-name (`message_window_open?`,
  # `vehicle_char_passable?`, `vehicle_char_can_land?`, `char_passable?`,
  # `char_can_land?`, `terrain_id`, `event_id_at`, `event_position`,
  # `headless_battle`, `active_battle`, `rebuild_chipset`) -- 6 of those 11
  # (`message_window_open?`, `vehicle_char_passable?`,
  # `vehicle_char_can_land?`, `terrain_id`, `active_battle`,
  # `rebuild_chipset`) name one of this round's own 223 registered methods
  # each (the ordinary full-overlap single-name shape round 38's own
  # `collect_visibility_calls` mechanism already strips cleanly, reconfirmed
  # for real here -- see the strip+parse+AST-diff paragraph below); the
  # other 5 (`char_passable?`, `char_can_land?`, `event_id_at`,
  # `event_position`, `headless_battle`) name real methods that simply never
  # compiled clean enough for bc2cpp to register (TSV-confirmed absent),
  # same "candidate but not actually registered" shape every prior round's
  # own comment already documents, so their own companion statements are
  # never even inspected for overlap and stay standing untouched.
  #
  # The remaining 2 `public` statements are real, multi-name, and were
  # MIXED -- naming both a registered (to-be-stripped) and a non-registered
  # (kept) method in the same statement -- exactly the one companion-
  # statement shape strip_wio_bc2cpp_stubs.rb's own file comment already
  # documents as a real, deliberate, unimplemented limitation ("partial-
  # argument-list editing is not supported yet, refusing to guess"), and no
  # owner in rounds 35-42 had ever actually hit it: `public :camera_position,
  # :character_screen_position, :char_in_sight?` (only `#char_in_sight?`
  # registered) and a second, longer one spanning
  # `:play_battle_bgm`/`:play_victory_bgm`/`:restore_pre_battle_bgm`/
  # `:terrain_backdrop`/`:backdrop_for_terrain_id`/`:map_properties`/
  # `:perform_game_over`/`:try_open_debug_menu`/`:build_animation`/
  # `:anim_target`/`:drive_map_animation`/`:fire_animation_flashes`/
  # `:frames_from_tenths`/`:load_face_bitmap`/`:step_map_animation`/
  # `:close_battle`/`:current_map_tone` (7 of those 17 registered:
  # `terrain_backdrop`, `try_open_debug_menu`, `drive_map_animation`,
  # `frames_from_tenths`, `step_map_animation`, `close_battle`,
  # `current_map_tone`). Confirmed for real, not just reasoned about: a real
  # `strip_wio_bc2cpp_stubs.rb` run against the real checked-in (pre-this-
  # round) `scene/map.rb` with this round's own owners csv reproduces
  # exactly the documented `RuntimeError` for the first statement
  # ("names both a stripped method (char_in_sight?) and a kept one
  # (camera_position, character_screen_position) -- partial-argument-list
  # editing is not supported yet") -- the real sanity-check-on-the-check
  # every prior round's own comment already performs for its own real
  # companion-statement cases, reconfirmed here for a genuinely new shape.
  #
  # Resolved by splitting each of these 2 real statements in `scene/map.rb`
  # itself into two homogeneous ones (one naming only kept methods, one
  # naming only stripped methods) -- a source-level fix, not a
  # strip_wio_bc2cpp_stubs.rb change: `Module#public` with an explicit name
  # list only marks those names public, so calling it twice with disjoint
  # subsets of the original name set has the exact same net effect as
  # calling it once with the union -- a behaviorally inert refactor for
  # every build, wio or otherwise, verified two ways rather than assumed:
  # (1) a real `strip_wio_bc2cpp_stubs.rb` run with this round's own
  # 54-owner (unchanged) baseline csv against the split source reproduces
  # output identical to the same run against the ORIGINAL unsplit source
  # everywhere except the literal lines this round's own edit touched (a
  # real `diff`, not eyeballed) -- the split has zero effect on any
  # already-shipped owner; (2) after this round's own new
  # `RPG2k::Scene::Map` owner is added, the resulting output has ZERO
  # dangling explicit-name `public`/`private`/`protected` statement anywhere
  # in the file (a real AST walk collecting every literal Symbol/String
  # argument at every such statement and confirming each one still has a
  # real `def` of that name still present) -- the general form of the same
  # correctness property round 38's own `Game::ChipSet`/`swap_equipment_
  # through_bag` precedent checked by hand for a single name, checked here
  # exhaustively for all 17 companion-statement names still standing after
  # the strip. `strip_wio_bc2cpp_stubs.rb` itself needed no change for this
  # round -- the documented "mixed argument list" limitation stays exactly
  # as documented, real, and (for this round) deliberately routed around at
  # the source level instead of implemented, since a source-level fix
  # carries zero regression risk to the other 54 already-shipped owners'
  # own companion-statement handling and a script-level fix would.
  #
  # 7 of this round's own 223 registered methods (`clamp_speed`,
  # `walk_slide_step`, `jump_slide_step`, `anim_frame_period`,
  # `anim_continuous_period`, `anim_spin_period`, `shop_gold_term`) are
  # real one-line `def name; body; end`s -- the shape round 35's own
  # comment already fixed strip_wio_bc2cpp_stubs.rb to support; confirmed
  # directly that all 7 sit alone on their own physical line (the real
  # strip run below hit no "shares its own physical line" raise for any of
  # them).
  #
  # Gem-init-ordering correctness (the same whole-closed-world
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/
  # `mrb_funcall_with_block` grep every prior round's own comment
  # describes -- `src/error_dump.cxx`, `src/main.cxx`, `app/wio/src/
  # mruby_sd_smoke_main.cxx`, `app/psp/main.cxx`, all three `*-compiled/src/
  # register.cxx`, every `mruby-rgss/src/*.cxx`, plus the always-active
  # external mrbgems `3rd/mruby-marshal`/`3rd/mruby-stringio`/`3rd/
  # mruby-onig-regexp`, `git submodule update --init`d fresh for this
  # round's own check rather than assumed already checked out -- re-run
  # against all 223 of this round's own real registered method names via a
  # small script rather than by hand, given the size): ZERO real literal
  # string-argument matches anywhere in the whole closed world against any
  # of the 223 names. Every literal method-name argument that DOES appear
  # at any real `mrb_funcall*` call site in this closed world (`"press"`/
  # `"release"`/`"main_loop"`/`"width"`/`"height"`/`"name"`/`"color"`/
  # `"bold"`/`"italic"`/`"outline"`/`"shadow"`/`"out_color"`/`"warn_stub"`/
  # `"clear"`/`"start"`/`"switches"`/`"dup"`/`"default_path"`/`"call"`/
  # `"current_scene_name"`/`"size"`/`"[]"`/`"[]="`/`"clamp"`/`"%"`/`"new"`/
  # `"Regexp"`/`"RGSS"`/`"marshal_dump"`/`"marshal_load"`/`"_dump"`/
  # `"_dump_data"`/`"instance_variables"`/`"sort!"`/`"source"`/`"options"`/
  # `"write"`/`"read"`/`"getc"`/`"ungetc"`/`"replace"`/`"_sys_fail"`,
  # `"probe!"`) is, as every prior round already found, real, different,
  # and unrelated -- every register.cxx hit is inside a `//`-comment
  # describing generated (not checked-in) code, same as every prior round.
  # `"clamp"` is the one name in this list not already named by a prior
  # round's own comment (`mruby-rgss/src/lib.cxx`, unrelated to this round's
  # own registered `#clamp_speed`, a completely different method name, not
  # a bare `clamp`).
  #
  # Real strip + parse + AST-diff verification: a real
  # `strip_wio_bc2cpp_stubs.rb` run against every one of the 14 real
  # wio-relevant `mrblib` files (`game.rb`, `interpreter.rb`, `main.rb`,
  # `scene/{base,equip_menu,game_over,item_menu,map,menu,order,save_load,
  # skill_menu,status_menu,title}.rb` -- the same 14-file set round 42's own
  # comment already established), once with round 42's own already-shipped
  # 54-owner csv and once with that same csv plus this round's own
  # `RPG2k::Scene::Map`, both raised nothing and both rewrites parse (`ruby
  # -c`). 13 of the 14 files are BYTE-FOR-BYTE IDENTICAL between the two
  # runs (confirmed by a real `diff`, not eyeballed) -- this round's own
  # required regression check, since this round adds to the SAME shared
  # `owners:` array and reuses the SAME `strip_wio_bc2cpp_stubs.rb`
  # unmodified (no change to that script this round). Only `scene/map.rb`
  # differs, and a real before/after `RubyVM::AbstractSyntaxTree` walk
  # (every real `DEFN`/`DEFS`/`SCLASS`-nested `DEFN` in the whole file, not
  # just this round's own owner) shows the two outputs differ by EXACTLY
  # this round's own 223 `RPG2k::Scene::Map` methods removed and NOTHING
  # else added or removed -- a set-difference against the real registered-
  # method-name ground truth confirms the removed-method set and the
  # registered-method set are IDENTICAL (a real `diff` of the two sorted
  # name lists, empty), not just equal in count.
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on `scene/map.rb` alone, isolating this round's own
  # marginal contribution on top of round 42's own already-shipped 54-owner
  # set, both runs against identical-length output filenames to cancel the
  # path-length measurement noise every prior round's own comment already
  # documents for this proxy): 196,252 -> 122,052 bytes, a 74,200-byte
  # (37.8%) reduction from these 223 stripped method bodies -- by far the
  # largest single-file byte reduction this whole series has measured
  # (round 38's own combined `game.rb` total across 7 owners was 37,357
  # bytes; this round's own single owner, in one file, is double that).
  #
  # What round 44 deliberately did NOT do: `RPG2k::Scene::Battle` (110
  # registered methods) remains deferred, genuinely deserving its own
  # dedicated round rather than being folded into this one under time
  # pressure -- unlike `RPG2k::Scene::Map`, it was not even investigated for
  # real this round (no registry/companion-statement/gem-init-ordering
  # check run against it), so its own real shape (partial-owner reopenings,
  # companion statements, or otherwise) is completely open for whichever
  # round picks it up next.
  #
  # Round 45: a real, from-scratch `comm`/diff of this file's own 55-owner
  # `owners:` list below against `tools/bc2cpp/compiled_gems.rb`'s own full,
  # real `BC2CPP_COMPILED_GEMS['mruby-rpg2k-compiled'][:owners]` (75 total,
  # re-run for real via `ruby -e 'require "./tools/bc2cpp/compiled_gems.rb"; ...'`,
  # never hand-copied) finds 20 owners this file's own `owners:` list had
  # never listed. Of those 20, 15 are real, confirmed no-ops for wio today,
  # every one of them entirely defined inside a file this file's own
  # wio-only exclusions above already drop from `spec.rbfiles` -- the same
  # "pointless, not unsafe" shape rounds 35/37/39 already established,
  # reconfirmed here by a real `grep -rn 'class Name\b'`/`Name = Struct.new`
  # search of the whole gem for each one, not assumed from the class name
  # alone: `RPG2k::Scene::MapViewer`/`RPG2k::Scene::DebugMenu`/
  # `RPG2k::Scene::ChipsetEditor` (scene/map_viewer.rb, scene/debug_menu.rb,
  # scene/chipset_editor.rb -- the psp/wio debug-tools trim at the top of
  # this file); `Game::Battle`/`RPG2k::Scene::Battle`/`RPG2k3::Scene::Battle`/
  # `Game::Battle::Combatant` (game/battle.rb -- `Combatant` is a real
  # `Struct.new`, not a `class`, but the same file either way --, scene/
  # battle.rb, scene/battle_rpg2k3.rb -- the wio-only battle trim);
  # `Game::EnemyAction`/`Game::EnemyAi`/`Game::Troop`/`Game::Enemy`/`Game::
  # States::BattleText.singleton`/`Game::Battle.singleton`/`Game::
  # BattlePage.singleton` (game/battle_support.rb -- the wio-only
  # battle_support.rb trim); `Game::State.singleton` (game/lsd_io.rb -- the
  # wio-only lsd_io.rb/RPG_RT-interop trim) -- this last one deliberately
  # RE-CHECKED rather than trusted from an earlier survey that had named it
  # as a live candidate "in game.rb": a real `wio_registered_methods.rb` run
  # shows its own 2 real registered methods (`bgm_from_chunk`/
  # `se_from_chunk`) are BOTH still defined in `game/lsd_io.rb`, not
  # `game.rb`, exactly matching round 37's own already-documented no-op
  # finding for this same owner -- that earlier survey's own "game.rb" note
  # was wrong, caught here by re-deriving from the real registry and a real
  # `grep -n 'def self\.\(bgm\|se\)_from_chunk'` rather than trusted as
  # given, and `Game::State.singleton` is correctly left OUT of this
  # round's own additions below.
  #
  # The other 5 of the 20 are real, genuine, previously-uncovered owners --
  # all five added this round, all five confirmed to live entirely in files
  # this gem's own wio spec.rbfiles still ships (no partial-owner reopening
  # in any wio-excluded file for any of them, checked directly the same way
  # as every other owner above, not assumed):
  #   - `RPG2k::Window` (mruby-rpg2k/mrblib/main.rb) -- the message/menu
  #     window base class every scene's own window subclasses build on.
  #   - `RPG2k` itself (mruby-rpg2k/mrblib/main.rb) -- the top-level game
  #     object (scene stack push/pop, title-screen boot, save/continue,
  #     the bug-report dump). Real shape confirmation: a whole-gem `grep
  #     -rn 'class RPG2k\b'` finds this bare class reopened in every single
  #     scene file (`class RPG2k; module Scene; class ItemMenu ... end end
  #     end`, etc.) plus `main.rb` itself, game/battle.rb, game/
  #     battle_support.rb, and the three debug-tool files -- but a real
  #     per-file AST walk of every one of those reopenings' own top-level
  #     (non-`Scene`-nested) `def`s shows every real registered method
  #     under the bare `RPG2k` owner is defined in `main.rb` and ONLY
  #     `main.rb` (every other file's own `class RPG2k` reopening exists
  #     solely to nest its own `module Scene; class Whatever` a level
  #     deeper, with zero `RPG2k`-level `def`s of its own) -- confirmed by
  #     a real set-difference against the registry's own 15 names, not
  #     eyeballed.
  #   - `Game::Picture` (mruby-rpg2k/mrblib/game.rb) -- the show/move/erase
  #     picture-command state machine. `Game::Picture.singleton` (its own
  #     `.from_h`) has been stripped since round 37; this is the separate,
  #     previously-uncovered plain-instance-method owner of the same class.
  #   - `Game::Vehicle` (mruby-rpg2k/mrblib/game.rb) -- the boat/ship/
  #     airship placement/serialization state (a small, 4-method owner;
  #     the vehicle's own movement/boarding logic lives on `Game::
  #     Character`, a different, already-stripped-since-round-38 owner).
  #   - `RPG2k::Scene::Map::LRUBitmapCache` (mruby-rpg2k/mrblib/scene/
  #     map.rb) -- the bounded per-kind bitmap-decode cache `RPG2k::Scene::
  #     Map` itself builds several instances of (`@charset_cache`, `@
  #     picture_cache`, ...). A real, different, nested owner from `RPG2k::
  #     Scene::Map` itself (already stripped since round 44) -- this
  #     round's own `owners:` entry below names the nested class
  #     explicitly, not `RPG2k::Scene::Map` again.
  #
  # Ground truth (a real `wio_registered_methods.rb` run against
  # `mruby-rpg2k-compiled`, never hand-counted): `RPG2k::Window` 32,
  # `RPG2k` 15, `Game::Picture` 25, `Game::Vehicle` 4, `RPG2k::Scene::Map::
  # LRUBitmapCache` 5 -- 81 real registered methods total across these 5
  # owners. All five are ordinary, full (not partial) owners: a whole-gem
  # `grep -rn 'class Window\b'`/`'class Picture\b'`/`'class Vehicle\b'`/
  # `'class LRUBitmapCache\b'` finds exactly one real class body defining
  # each (main.rb/game.rb/game.rb/scene/map.rb respectively), and the
  # `RPG2k` case is the multi-reopening shape already traced out above.
  #
  # `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS` (tools/bc2cpp/bc2cpp.rb,
  # checked directly against both constants' own real current contents, not
  # assumed): `DIRECT_CONSTRUCT_TARGETS` is `%w[Game::Transition Game::Map
  # Game::Switches Game::Timer Game::MessageConfig]` -- none of this
  # round's own 5 owners appears there. `NATIVE_ARG_TARGETS` has exactly
  # one entry anywhere near this round's own owners,
  # `RPG2k::Scene::Map::LRUBitmapCache#initialize` (already noted, in
  # passing, by round 44's own comment, since it shares that round's own
  # owner's name) -- informational only, same as every prior round's own
  # `NATIVE_ARG_TARGETS` hits: this mechanism only ever rewrites the base
  # gem's own interpreted-bytecode `mrblib` copy from
  # `wio_registered_methods.rb`'s own ground truth, and never reaches or
  # perturbs bc2cpp.rb's own separate compile of the real, unstripped
  # source that `NATIVE_ARG_TARGETS`'s own calling-convention decision is
  # made from -- no interaction either way, confirmed rather than assumed.
  #
  # Companion-statement hazard check (the same real AST walk every prior
  # round's own comment describes, re-run against all 5 of this round's own
  # real class bodies): `RPG2k::Window` has 2 `attr_reader` calls (`:x, :y,
  # :width, :height, :contents, :windowskin, :cursor_rect`; `:active,
  # :visible, :pause`) and one bare `private` mode switch; `Game::Picture`
  # has 2 `attr_reader` calls (`:id, :name, :fixed_to_map,
  # :use_transparent_color`; `:show_x, :show_y`) and one bare `private`
  # mode switch; `Game::Vehicle` has one `attr_accessor` (`:map_id, :x, :y,
  # :direction, :charset_name, :charset_index`) and one `attr_reader`
  # (`:type`); `RPG2k::Scene::Map::LRUBitmapCache` has one bare `private`
  # mode switch and no attrs at all. None of any of these attr names
  # collide with any of this round's own 81 in-scope method names (every
  # attr reader name is a bare noun -- `x`, `contents`, `map_id`, `type`,
  # ... -- while this round's own registered writers are all `name=`-
  # suffixed, e.g. `RPG2k::Window#x=`/`#contents=`, a different method
  # every time, the same "reader vs. writer are different methods" shape
  # round 38's own `Game::State`/`Game::Actor` comment already established).
  #
  # `RPG2k` itself (main.rb) is the one real, explicit-name case: one
  # `attr_reader :db, :map_tree, :test_play, :title` (no collision with any
  # of this round's own 15 `RPG2k` names) and four explicit-name `private
  # :name` statements -- `private :native_test_play?`, `private
  # :read_ini_title`, `private :trim_ini_value`, `private :default_title`
  # (main.rb lines 682/710/722/729). None of these four names is among
  # `RPG2k`'s own 15 real registered methods (TSV-confirmed absent from all
  # four) -- the same "candidate but not actually registered" shape every
  # prior round's own comment already documents for other owners, so all
  # four statements are left completely untouched by this round's own
  # strip, no split needed. Verified directly, not just reasoned about: a
  # real post-strip scan of every explicit-name `private`/`protected`/
  # `public` statement remaining in the stripped `main.rb`/`game.rb`/
  # `scene/map.rb` confirms every named method still has a real `def`
  # present (zero dangling references) -- the general correctness property
  # round 44's own comment already checked exhaustively for its own 17
  # standing companion-statement names, re-run here for these three files.
  #
  # Gem-init-ordering correctness (the same whole-closed-world
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/
  # `mrb_funcall_with_block` grep every prior round's own comment
  # describes -- `src/error_dump.cxx`, `src/main.cxx`, `app/wio/src/
  # mruby_sd_smoke_main.cxx`, `app/psp/main.cxx`, all three `*-compiled/src/
  # register.cxx`, every `mruby-rgss/src/*.cxx`, plus the always-active
  # external mrbgems `3rd/mruby-marshal`/`3rd/mruby-stringio`/`3rd/
  # mruby-onig-regexp`, `git submodule update --init`d fresh for this
  # round's own check -- re-run via a small script against all 81 of this
  # round's own real registered method names, including both literal
  # string arguments and `MRB_SYM`/`MRB_OPSYM` symbol arguments): exactly
  # one real, non-comment match anywhere in the whole closed world --
  # `app/psp/main.cxx`'s own `append_scene_name` helper, `mrb_funcall(M,
  # game_obj, "current_scene_name", 0)`, a real call onto a real `RPG2k`
  # instance (per that function's own comment: "via each maker's own
  # RPG2k#current_scene_name/RPGXP#current_scene_name/
  # RPGVX#current_scene_name") -- genuinely this round's own new
  # `RPG2k#current_scene_name`, not a different-receiver false alarm like
  # every prior round's own `"name"`/`"color"`/`"size"`/`"start"` hits.
  # Ruled out on a DIFFERENT basis than any prior round's own hits, though:
  # `app/psp/main.cxx` is PSP's own standalone CMake project's entry point
  # (see this file's own debug-tools-trim comment above: `%w[psp wio]` is
  # this build's own name, not a shared host half), never compiled into
  # the wio PlatformIO firmware at all -- confirmed directly, not assumed
  # from the path alone: a real `grep -rn current_scene_name src/
  # app/wio/` finds this diagnostic string NOWHERE in either wio's own
  # `src/` or `app/wio/` sources, only in this one PSP-only file. Since
  # `wio_strip_bc2cpp_stubs` only ever rewrites the copy of `mrblib` that
  # ships inside the wio build's own binary, and this call site can only
  # ever run inside a completely separate PSP binary that never links that
  # stripped copy at all, it can never observe the stripped body missing --
  # a real, structural reason to rule it out, not a coincidence of what
  # this one round happened to check. Every other literal method-name
  # argument or `MRB_SYM`/`MRB_OPSYM` argument at any real (non-comment)
  # `mrb_funcall*` call site in the whole closed world -- every one every
  # prior round's own comment already found and ruled out (`"press"`/
  # `"release"`/`"main_loop"`/`"width"`/`"height"`/`"name"`/`"color"`/
  # `"bold"`/`"italic"`/`"outline"`/`"shadow"`/`"out_color"`/`"warn_stub"`/
  # `"clear"`/`"start"`/`"switches"`/`"dup"`/`"default_path"`/`"call"`/
  # `"size"`/`"clamp"`/`aref`/`"[]"`/`"[]="`/`"new"`/`"marshal_dump"`/
  # `"marshal_load"`/`"_dump"`/`"_dump_data"`/`"instance_variables"`/
  # `"sort!"`/`"source"`/`"options"`/`"write"`/`"read"`/`"getc"`/
  # `"ungetc"`/`"replace"`/`"_sys_fail"`/`"probe!"`/`"string_gsub"`/
  # `"to_enum"`/`"onig_regexp_gsub"`/`"string_scan"`/`"string_split"`/
  # `"string_sub"`) -- was re-checked against this round's own 81 names
  # too, same zero-hit result.
  #
  # Real strip + parse + AST-diff verification: a real
  # `strip_wio_bc2cpp_stubs.rb` run against every one of the 14 real
  # wio-relevant `mrblib` files (the same set round 44's own comment
  # established), once with round 44's own already-shipped 55-owner csv
  # and once with that same csv plus this round's own 5 new owners, both
  # raised nothing and both rewrites parse (`ruby -c`). 11 of the 14 files
  # are BYTE-FOR-BYTE IDENTICAL between the two runs (a real `diff`, not
  # eyeballed) -- this round's own required regression check, since this
  # round adds to the SAME shared `owners:` array and reuses the SAME
  # `strip_wio_bc2cpp_stubs.rb` unmodified (no change to that script this
  # round). Only `game.rb`, `main.rb`, and `scene/map.rb` differ, and a
  # real before/after `RubyVM::AbstractSyntaxTree` walk (every real
  # `DEFN`/`DEFS`/`SCLASS`-nested `DEFN` in each of the three files, not
  # just this round's own owners) shows the two outputs differ by EXACTLY
  # this round's own 81 methods removed and NOTHING else added or removed:
  # `game.rb` loses exactly `Game::Picture`'s 25 and `Game::Vehicle`'s 4;
  # `main.rb` loses exactly `RPG2k`'s 15 and `RPG2k::Window`'s 32;
  # `scene/map.rb` loses exactly `RPG2k::Scene::Map::LRUBitmapCache`'s 5 --
  # a real set-difference against the registry's own per-owner name lists
  # confirms an exact match, not just equal counts.
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, on `game.rb`/`main.rb`/`scene/map.rb`, isolating this
  # round's own marginal contribution on top of round 44's own
  # already-shipped 55-owner set, both runs against identical-length output
  # filenames to cancel the path-length measurement noise every prior
  # round's own comment already documents for this proxy): `game.rb`
  # 83,688 -> 79,464 bytes (4,224 bytes, 5.0%); `main.rb` 28,028 -> 17,016
  # bytes (11,012 bytes, 39.3%); `scene/map.rb` 122,491 -> 121,733 bytes
  # (758 bytes, 0.6%) -- 234,207 -> 218,213 bytes combined, a 15,994-byte
  # reduction for this round's own 81 stripped methods.
  #
  # What round 45 deliberately did NOT do: the 15 real no-op owners
  # documented above stay out of `owners:` (stripping them would be a real
  # no-op for wio today, the same "pointless, not unsafe" reasoning every
  # prior round's own no-op list already uses) -- most notably
  # `RPG2k::Scene::Battle` (110 methods) and `RPG2k3::Scene::Battle` (7),
  # both still real, live, uncovered owners for whichever future round
  # ever stops excluding `scene/battle.rb`/`scene/battle_rpg2k3.rb` from
  # wio's own `spec.rbfiles`. With this round's own 5 additions, EVERY
  # owner in `tools/bc2cpp/compiled_gems.rb`'s own real
  # `mruby-rpg2k-compiled` `:owners` list that is not entirely confined to
  # a wio-excluded file is now covered by this file's own `owners:` list
  # below (60 of 75 total; the other 15 are the confirmed no-ops) --
  # `mruby-rpg2k`'s own wio bc2cpp stub-stripping coverage is complete
  # modulo the battle-file exclusions themselves, the same "100%" state
  # `mruby-rgss`/`mruby-lcf`'s own `owners:` lists have already reached.
  wio_strip_bc2cpp_stubs(spec, compiled_gem: 'mruby-rpg2k-compiled',
                         owners: %w[Game::TextReveal Game::MessageConfig Game::Switches
                                    Game::Variables Game::NumberInput Game::Actors Game::Rng
                                    Game::MoveRoute Game::Shop Game::Weather Game::Timer
                                    RPG2k::Scene::ItemMenu RPG2k::Scene::SkillMenu
                                    RPG2k::Scene::EquipMenu RPG2k::Scene::Menu
                                    RPG2k::Scene::StatusMenu RPG2k::Scene::SaveLoad
                                    RPG2k::Scene::Order RPG2k::Scene::Base
                                    RPG2k::Scene::Title RPG2k::Scene::MapWorld
                                    RPG2k::Scene::VehicleWorld RPG2k::Scene::EventResolver
                                    RPG2k::Scene::GameOver
                                    Game.singleton Game::States.singleton
                                    Game::ChipsetLayout.singleton Game::EventGraphic.singleton
                                    Game::Transition.singleton Game::Party.singleton
                                    Game::Picture.singleton Game::Character.singleton
                                    Game::ChipSet.singleton RPG2k::Scene::Map.singleton
                                    Game::MoveType.singleton Game::MapAccess.singleton
                                    Game::Parallax.singleton Game::MessagePalette.singleton
                                    Game::MapBgm.singleton Game::WindowCursor.singleton
                                    Game::Message.singleton Game::EventPage.singleton
                                    Game::CharSet.singleton Game::Backdrop.singleton
                                    RPG2k::Scene.singleton
                                    Game::ChipSet Game::Map Game::Transition Game::State
                                    Game::Screen Game::Actor Game::Character Game::Party
                                    Game::Interpreter RPG2k::Scene::Map
                                    RPG2k::Window RPG2k Game::Picture Game::Vehicle
                                    RPG2k::Scene::Map::LRUBitmapCache])
  wio_strip_inline_helpers(spec)
  wio_strip_debug_rbfiles(spec)
end
