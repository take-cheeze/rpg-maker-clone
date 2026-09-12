MRuby::Gem::Specification.new('mruby-rgss') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RGSS implementation in mruby'

  # Color, Tone and Table provide RGSS-compatible Marshal (_dump/_load) support.
  add_dependency 'mruby-marshal'
  # RGSS::Audio.decrypt_mv_asset (mrblib/lib.rb) reverses RPG Maker MV/MZ's
  # loose-asset encryption with String#unpack("C*")/Array#pack("C*"); a real
  # dependency (not test-only), same as mruby-lcf/mruby-rpgxp declaring it for
  # their own binary (de)serialization.
  add_dependency 'mruby-pack'
  # The Bitmap loader tests write fixture images to disk and read them back with
  # File, so the standalone mrbtest build needs mruby-io. The loader itself
  # reads files through C stdio, so this is only needed for the tests.
  add_test_dependency 'mruby-io'
  # The audio loader's directory-shadowing test (a folder named like a track,
  # as Nepheshel's `Title/` sits beside its `Music/title.mid`) has to create a
  # real directory to stand in for it, and Dir lives in its own core gem.
  # Nothing in the engine's own code needs Dir, so this is test-only.
  add_test_dependency 'mruby-dir'
  # The wave_blt test computes its expected phase with Math::PI. Math is part
  # of the full game's gem set (build_config.rb's rpg_maker_gems), but the
  # standalone mrbtest build only pulls this gem plus its declared
  # dependencies -- see AGENTS.md's "mruby stdlib methods live in core *-ext
  # mrbgems" note. wave_blt itself is pure C++ (mruby-rgss/src/lib.cxx), so
  # this is only needed for the test.
  add_test_dependency 'mruby-math'
  # The RGSS::Input::N0..PERIOD id test uses Array#uniq to prove every new key
  # id is distinct. Same story as mruby-math above: Array#uniq lives in
  # mruby-array-ext (build_config.rb's rpg_maker_gems has it for the full
  # game), so the standalone mrbtest build needs it declared here too.
  add_test_dependency 'mruby-array-ext'

  cxx.include_paths <<
    "#{dir}/../3rd/uni-algo/include" <<
    "#{dir}/../3rd/lvgl"
  # PSP and wio each want their own lv_conf.h (LV_USE_LOG 0, and for PSP its
  # own LVGL pool sized for the PSP's ~24 MB) ahead of the shared repo-root
  # one below: LVGL's lv_conf_internal.h auto-includes whichever lv_conf.h
  # __has_include finds first on the search path, and this rake-driven
  # compile of mruby-rgss (which calls into LVGL -- lib.cxx's
  # vp_refresh_overlay/gfx_snap_to_bitmap) needs to see the same config the
  # real firmware's own LVGL build uses (app/psp/CMakeLists.txt's
  # add_subdirectory, or PlatformIO's own `lib_deps = symlink://3rd/lvgl`
  # for wio's platformio.ini environments), or the two disagree on what LVGL
  # actually compiled in (LV_USE_LOG/LV_USE_SNAPSHOT) and the final link
  # fails with undefined references (lv_log_add, lv_snapshot_take) that only
  # the *other* config's LVGL build would have provided -- confirmed for
  # real linking env:wio_rgss_boot against this gem's own libmruby.a before
  # this line existed for wio.
  cxx.include_paths << "#{dir}/../app/psp" if build.name == 'psp'
  cxx.include_paths << "#{dir}/../app/wio" if build.name == 'wio'
  cxx.include_paths <<
    "#{dir}/../include" <<
    "#{dir}/../3rd/stb" <<
    build_dir
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo" << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/lvgl/lib"
  linker.libraries << "uni-algo" << "lvgl"
  # pthread backs terminal.cxx's std::thread writer (the sixel/iTerm2
  # backends). That file compiles out entirely on PSP/Wio (see its file-level
  # comment) -- neither bare-metal target has a proven std::thread/pthread
  # story, and nothing on either can select a terminal backend anyway -- so
  # linking pthread there would be a requirement with no corresponding need,
  # on toolchains where it may not even exist. Checked against *this build's*
  # own name (the psp/wio MRuby::CrossBuild, not the ENV MRUBY_TARGET a
  # cross-compile also sets for the native host build that produces mrbc
  # alongside it in the same rake run -- that host build still wants
  # pthread).
  linker.libraries << "pthread" unless %w[psp wio].include?(build.name)

  objs << objfile("#{build_dir}/shinonome")

  # docs/adr/0110/0112: build_config.rb's wio CrossBuild defaults both this
  # and SHINONOME_GOTHIC_SD_FILE (read directly from ENV by
  # gen_shinonome_data.rb itself, below) so a plain wio build gets the SD
  # offload without asking -- still a plain ENV-gated no-op for every other
  # target (desktop/wasm/psp/android), same convention as the project's
  # other opt-in escape hatches. Names the on-device path lib.cxx's own
  # find_gothic_char binary-searches when the GOTHIC face isn't found in the
  # (then-empty) compiled-in array -- must agree with whatever real path a
  # game's SD-card deployment step actually writes gothic.bin to; that
  # deployment step doesn't exist yet (ADR 110's own "what was not done"),
  # so this fixes what the build produces, not how it reaches a real card.
  if ENV["RGSS_SHINONOME_GOTHIC_SD_PATH"]
    # mruby's own Command::Compiler#_run shells out via a single interpolated
    # string (no per-argument shellquote) -- a plain #inspect'd C string
    # literal's own `"..."` gets stripped by the shell before gcc ever sees
    # it, leaving a bare, unterminated path token. Escaping the quotes here
    # (\\") is what survives that shell round-trip as a real `"..."` token.
    cxx.defines << %(RGSS_SHINONOME_GOTHIC_SD_PATH=\\"#{ENV["RGSS_SHINONOME_GOTHIC_SD_PATH"]}\\")
  end

  file "#{dir}/src/lib.cxx" => "#{build_dir}/shinonome.hxx"
  file "#{build_dir}/shinonome.hxx" => "#{build_dir}/shinonome.cxx"
  file "#{build_dir}/shinonome.cxx" => "#{dir}/gen_shinonome_data.rb" do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    Dir.chdir build_dir do
      ruby  t.prereqs.first
    end
  end

  # docs/adr/0144 (bounded proof, plain-instance-method owners only):
  # RGSS::Sprite -- all 17 of its real bc2cpp-registered methods.
  #
  # docs/adr/0144's own dated follow-up section (this round) scales this to
  # two more owners, real .singleton coverage included -- not
  # mruby-rgss-compiled's own full 14-owner `owners:` list
  # (tools/bc2cpp/compiled_gems.rb), still a deliberately bounded subset:
  #   - RGSS::Window: a second plain-instance-method owner (12 real
  #     bc2cpp-registered methods, mruby-rgss/mrblib/lib.rb's `class Window`)
  #     -- proves nothing regressed in strip_wio_bc2cpp_stubs.rb's existing
  #     DEFN path once .singleton support was added alongside it.
  #   - RGSS::Audio.singleton / RGSS::ErrorReport.singleton: the first two
  #     real `.singleton` owners this mechanism strips -- 13 real methods
  #     defined as plain `def name; ...; end` inside `RGSS::Audio`'s own
  #     `class << self ... end` block (mruby-rgss/mrblib/lib.rb), and 6 more
  #     defined as `def self.name` at `RGSS::ErrorReport`'s own module body
  #     top level (mruby-rgss/mrblib/error_report.rb) -- deliberately one of
  #     each real `.singleton` shape (SCLASS-nested DEFN vs. a bare DEFS),
  #     to exercise strip_wio_bc2cpp_stubs.rb's own new support against both
  #     rather than just one. Gem-init-ordering correctness (this ADR's own
  #     required per-owner check) was re-run for all three: grepped every
  #     mruby-rgss/src/*.cxx for a real `mrb_funcall` back into any of
  #     Window's 12 / Audio.singleton's 13 / ErrorReport.singleton's 6 real
  #     method names -- zero matches anywhere in the gem's own native
  #     sources (not just inside gem_init itself), so no live correctness
  #     gap found for any of the three. See the ADR follow-up section for
  #     the full per-owner writeup, including a real (but unrelated to this
  #     round's own three owners) `mrb_funcall(..., "press"/"release", ...)`
  #     found into RGSS::Input.singleton from wio_input_bridge.cxx's own
  #     per-frame poll -- a real *runtime* call path (Graphics.update, long
  #     after every gem's own init has finished), not a gem-init-time one,
  #     flagged for whichever future round scales to RGSS::Input.singleton
  #     rather than re-derived silently by that round.
  # Round 39 follow-up: this round scales the above 4-owner proof to
  # mruby-rgss-compiled's own FULL 14-owner `owners:` list
  # (tools/bc2cpp/compiled_gems.rb) -- every remaining real candidate this
  # gem's own compiled build actually registers a C++ override for:
  # `RGSS::Plane`, `RGSS::Tilemap`, `RGSS::Bitmap`, `RGSS::Bitmap.singleton`,
  # `RGSS.singleton`, `RGSS::Input.singleton`, `RGSS::Graphics.singleton`,
  # `RGSS::Font.singleton`, `RGSS::ErrorReport::Tee`, `Array` -- 10 new
  # owners, none left over after this round.
  #
  # Real ground truth (a real `wio_registered_methods.rb` run against
  # mruby-rgss-compiled's own real bc2cpp.rb registry, never hand-counted,
  # cross-checked directly against the real bc2cpp.rb stderr "== compiled
  # entry points ==" diagnostic itself, not just the TSV): RGSS::Plane 6
  # (blend_type/color/opacity/tone/zoom_x/zoom_y), RGSS::Tilemap 1
  # (autotiles), RGSS::Bitmap 2 (font/font=), RGSS::Bitmap.singleton 2
  # (extensions/failure_reason), RGSS.singleton 5
  # (tilemap_above_layer_probe/transition_shape_probe/warn_once/warn_stub/
  # window_probe), RGSS::Input.singleton 11 (dir4/dir8/key_index/
  # mouse_pressed?/mouse_x/mouse_y/press/press?/release/repeat?/trigger?),
  # RGSS::Graphics.singleton 4 (brightness=/brightness_sprite [private]/
  # freeze/resize_screen), RGSS::Font.singleton 1 (exist?),
  # RGSS::ErrorReport::Tee 1 (#initialize, private -- ordinary Ruby
  # #initialize privacy, not an explicit companion statement), Array 1
  # (include?) -- 34 real registered methods total across these 10 owners.
  #
  # One real, notable discrepancy from tools/bc2cpp/compiled_gems.rb's own
  # dated comment on `RGSS::Bitmap.singleton`: that comment (written at
  # docs/adr/0139's own time) says `self.failure_reason`'s own real body
  # was "not re-verified opcode-by-opcode" past confirming it reaches
  # `compile_method` at all, and that `SKIP_UNSUPPORTED=1` drops it either
  # way if it doesn't compile clean. A real, fresh run against the current
  # codebase (this round) shows it now compiles clean and IS a real
  # registered entry point -- confirmed directly against the raw bc2cpp.rb
  # stderr (`RGSS__Bitmap_singleton_failure_reason_impl (RGSS::Bitmap.
  # singleton#failure_reason, arity 1)` inside the real "== compiled entry
  # points ==" section, not the "== skipped ==" one), not merely trusted
  # from the TSV alone -- some intervening round between docs/adr/0139 and
  # this one evidently closed the opcode gap that comment flagged as open.
  # Not a soundness concern for this round (the real registry, whatever it
  # says today, is what this mechanism has always trusted -- see
  # wio_registered_methods.rb's own file comment), just worth recording so
  # a future reader of that older comment isn't misled by it.
  #
  # Companion-statement hazard check (private/protected/public with an
  # explicit Symbol argument, alias_method, attr_reader/attr_accessor/
  # attr_writer colliding with a registered method name -- the
  # `Game::ChipSet` precedent from the parallel mruby-rpg2k track): a real
  # grep of every `private`/`protected`/`public`/`private_class_method`/
  # `public_class_method`/`alias_method`/`attr_reader`/`attr_accessor`/
  # `attr_writer` statement in mruby-rgss/mrblib/*.rb, cross-checked
  # against these 10 owners' own 34 real registered method names: zero
  # collisions found for any of them. Every `attr_*` hit defines a
  # DIFFERENT name than any registered method on the same owner (e.g.
  # `RGSS::Bitmap.singleton`'s own `attr_writer :extensions` defines
  # `extensions=`, never the registered `extensions` getter, which is a
  # separate, explicit `def extensions` right below it; `RGSS::Plane`/
  # `RGSS::Tilemap`'s own `attr_reader`/`attr_accessor` lines cover
  # entirely different ivars -- `bitmap`/`ox`/`oy`/`z`/`viewport`,
  # `tileset`/`map_data`/`flags`/`flash_data` -- than their own registered
  # method names). `RGSS::Graphics.singleton`'s own `brightness_sprite`
  # (the one private registered method in this round's whole set) is
  # marked private by a bare `private` mode switch, not an explicit
  # `private :brightness_sprite` -- confirmed directly by reading the
  # source around it -- so deleting its own `def...end` (this mechanism's
  # own strip behaviour: the whole method, header included, not just its
  # body) leaves nothing referencing it by name and raises nothing. Every
  # `alias_method`/explicit-name `private`/`public` statement found
  # anywhere in the gem (`array_sort.rb`'s own `alias_method
  # :_rgss_native_sort, :sort`/`:_rgss_native_sort!, :sort!`, `lib.rb`'s
  # own `alias_method :_probe_update, :update`/`:update, :_probe_update`
  # and `:_rgss1_initialize, :initialize`) references a name (`sort`/
  # `sort!`/`update`/`initialize` on RGSS::Sprite, an existing, already-
  # regression-checked owner) that is not one of this round's own 34
  # registered names, so none of them are a hazard for this round's new
  # owners either.
  #
  # `Array`'s own reopening (this round's own required check): `Array#
  # include?` is a real, checked-in `class Array; def include?; ...; end;
  # end` reopening in mruby-rgss/mrblib/array_include.rb (not some
  # structurally-unreachable native definition) -- confirmed directly by
  # reading the file. It is a real member of this gem's own `spec.rbfiles`
  # (mrblib/*.rb, no exclusion applies to it on any build), so
  # `wio_strip_bc2cpp_stubs` can and does reach it exactly like any other
  # owner. A separate file, `array_sort.rb`, also reopens `class Array`
  # (for `#sort`/`#sort!`, wrapped via `alias_method`) -- neither of those
  # two names is registered for the `Array` owner, so that file is
  # untouched by this round's own strip regardless.
  #
  # Gem-init-ordering correctness (the same whole-closed-world
  # `mrb_funcall`/`mrb_funcall_argv`/`mrb_funcall_id`/
  # `mrb_funcall_with_block` grep the parallel mruby-rpg2k track's own
  # rounds 35-37 established -- `src/error_dump.cxx`, `src/main.cxx`,
  # `app/wio/src/mruby_sd_smoke_main.cxx`, `app/psp/main.cxx`, all three
  # `*-compiled/src/register.cxx`, every `mruby-rgss/src/*.cxx`, plus the
  # three always-active external mrbgems `3rd/mruby-marshal`/
  # `3rd/mruby-stringio`/`3rd/mruby-onig-regexp` -- `git submodule update
  # --init` them to re-run this yourself), re-run against all 34 of this
  # round's own registered method names: two real literal matches found,
  # both confirmed unrelated or genuinely runtime-only by reading the call
  # site directly, not assumed:
  #   - `mrb_funcall(M, fv, "color", 0)` (mruby-rgss/src/lib.cxx's own
  #     `read_font`) -- `fv` there is `self`'s own `@font` ivar, a real
  #     `RGSS::Font` instance (an ordinary `attr_accessor`-defined reader,
  #     never one of this round's own owners), not `RGSS::Plane` --
  #     `RGSS::Plane#color` is a different method on a different class
  #     entirely, read directly from the function body rather than
  #     assumed from the shared name.
  #   - `mrb_funcall(M, RGSS_module, "warn_stub", 1, name)`
  #     (`RGSS_warn_stub`, mruby-rgss/src/lib.cxx) -- a real call into
  #     `RGSS.singleton#warn_stub`, one of this round's own owners. Its
  #     only two real call sites are both inside `Graphics.snap_to_bitmap`'s
  #     own native implementation, reached only when Ruby code calls
  #     `Graphics.snap_to_bitmap` itself -- and that method's own real
  #     Ruby callers (`RGSS.singleton#frame_mean`/`#effect_probe`,
  #     `RGSS::Graphics.singleton#freeze` -- itself one of this round's own
  #     owners -- and `RPG2k::Scene::Map`'s own transition code) are all
  #     genuine gameplay/scene-transition/CLI-probe paths, never anything
  #     reachable from any gem's own `gem_init`/`gem_final`. No top-level
  #     (outside-a-`def`) call to `Graphics.snap_to_bitmap` or
  #     `RGSS.warn_stub` exists anywhere in this gem's own mrblib either
  #     (checked directly) -- confirmed a real, but genuinely runtime-only,
  #     call path, not a gem-init-time hazard.
  # Every other literal method-name argument at any of these call sites
  # (`"marshal_dump"`/`"_dump"`/`"instance_variables"`/`"sort!"`/
  # `"source"`/`"options"`/`"_dump_data"`/`"write"`/`"marshal_load"`/
  # `"new"`/`"getc"`/`"ungetc"`/`"read"`/`"_sys_fail"`/`"replace"` --
  # StringIO's own `@string` ivar, same POLY precedent the rpg2k track
  # already documents --, `aref`/`"[]"`/`"string_gsub"`/`"to_enum"`/
  # `"onig_regexp_gsub"`/`"string_scan"`/`"string_split"`/`"string_sub"`/
  # `"source"`/`"new"` from the onig-regexp gem, `"name"`/`"size"`/
  # `"bold"`/`"italic"`/`"outline"`/`"shadow"`/`"out_color"` also from
  # `read_font`, `"clear"`/`"blt"`/`"stretch_blt"` from Window's own
  # canvas compositing) is real, different, and unrelated to any of this
  # round's own 34 names.
  #
  # `RGSS::Input.singleton` specifically -- flagged by the original round's
  # own comment above as a real `mrb_funcall(..., "press"/"release", ...)`
  # call site from `wio_input_bridge.cxx`'s own per-frame poll, "not a
  # gem-init-time hazard" but never independently re-verified before this
  # round: re-verified directly here, not just trusted. All four platform
  # input backends (`mruby-rgss/src/terminal.cxx`, `psp_input_bridge.cxx`,
  # `input_bridge.cxx` (SDL), `wio_input_bridge.cxx`) call
  # `mrb_funcall(..., "press"/"release", ...)` on `RGSS::Input`, but every
  # one of those four `rgss_*_poll` functions is itself called from
  # exactly one place in the whole closed world: `input_poll`
  # (mruby-rgss/src/lib.cxx), which is bound (via `mrb_define_module_
  # function`) to `RGSS::Input._poll` -- confirmed directly via a whole-
  # tree grep for each `rgss_*_poll` function's own name, not assumed from
  # the file-level comments alone (which, incidentally, are themselves
  # stale on three of the four backends -- `wio_input_bridge.cxx`/
  # `psp_input_bridge.cxx`/`input_bridge.cxx` all still say "called once
  # per frame from Graphics.update", but `lib.cxx`'s own newer comment
  # right above `input_poll` explains the drain was deliberately MOVED to
  # `Input.update` at some earlier point -- a real bug fix: draining
  # transitions during `Graphics.update` was silently wiped by the game's
  # own very next `Input.update` call, permanently zeroing every trigger).
  # `RGSS::Input._poll` is itself called from exactly one place:
  # `RGSS::Input.update`'s own Ruby body (mruby-rgss/mrblib/lib.rb) --
  # confirmed by reading that method directly, not the stale native
  # comments. `Input.update` is RGSS's own per-frame API method, called
  # only from a running game's own scene loop (`loop { Graphics.update;
  # Input.update; update; ... }`) or from test/tooling code that
  # explicitly drives a frame (e.g. mruby-rpg2k/mrblib/main.rb's own
  # battle-play harness) -- never automatically, never during any gem's
  # own `gem_init`/`gem_final`, and no top-level (outside-a-`def`) call to
  # `Input.update` exists anywhere in this gem's own mrblib either (grepped
  # directly). Confirmed sound to add.
  #
  # `DIRECT_CONSTRUCT_TARGETS`/`NATIVE_ARG_TARGETS` (tools/bc2cpp/
  # bc2cpp.rb): checked directly, not assumed from the class names alone.
  # `DIRECT_CONSTRUCT_TARGETS` is `%w[Game::Transition Game::Map]` --
  # no `RGSS::` entry at all, so none of this round's 10 owners interact
  # with it. `NATIVE_ARG_TARGETS` is an explicit `"Owner#name"` Set whose
  # every entry starts with `Game::` -- confirmed directly (`grep -c
  # RGSS`, zero matches inside the Set literal) -- so it cannot match any
  # of this round's owner strings either.
  #
  # Real strip + parse + AST-diff verification: a real
  # `strip_wio_bc2cpp_stubs.rb` run against the real checked-in
  # mrblib/lib.rb, mrblib/error_report.rb and mrblib/array_include.rb with
  # exactly this round's own full 14-owner csv raised nothing, every
  # rewritten file still parses (`ruby -c`), and a real before/after
  # `RubyVM::AbstractSyntaxTree` walk (every real DEFN/DEFS/SCLASS-nested
  # DEFN in each file) shows EXACTLY 74 methods removed from lib.rb (17
  # Sprite + 12 Window + 13 Audio.singleton + 6 Plane + 1 Tilemap + 2
  # Bitmap + 2 Bitmap.singleton + 5 RGSS.singleton + 11 Input.singleton +
  # 4 Graphics.singleton + 1 Font.singleton), 7 from error_report.rb (6
  # ErrorReport.singleton + 1 ErrorReport::Tee), and 1 from
  # array_include.rb (Array#include?) -- 82 total, cross-checked directly
  # against the per-owner counts above, nothing added or removed beyond
  # that.
  #
  # Regression check (this round only ever extends the same `owners:`
  # array the original round populated, so a mistake here could silently
  # change the pre-existing 4 owners' own behaviour too): re-ran the exact
  # same strip against the same 3 files with ONLY the original 4 owners
  # (`RGSS::Sprite`/`RGSS::Window`/`RGSS::Audio.singleton`/`RGSS::
  # ErrorReport.singleton`) and diffed the result against this round's own
  # 14-owner run, restricted to those same 4 owners' own surviving class/
  # module bodies (`class Sprite`/`class Window`/`module Audio`/
  # `RGSS::ErrorReport`'s own `class << self` block) -- byte-for-byte
  # identical in every case (confirmed via a real text diff, not just an
  # AST name comparison): `apply_deletion_plan`'s own line-granular
  # deletion plan is computed from ALL requested owners' original line
  # numbers in one pass before any line is actually removed, so stripping
  # additional, non-overlapping owners in the same invocation cannot
  # perturb an already-established owner's own removed span. No
  # regression found.
  #
  # Real measured size effect (host `mrbc -g`, matching this build's own
  # `enable_debug`, filename-length-controlled so debug-info string
  # padding doesn't skew the comparison): lib.rb 33,649 -> 22,180 bytes
  # (11,469 bytes, 34.1%, from lib.rb's own 74 stripped methods);
  # error_report.rb 3,478 -> 2,403 bytes (1,075 bytes, 30.9%, from its own
  # 7); array_include.rb 336 -> 124 bytes (212 bytes, 63.1%, from its own
  # 1) -- 37,463 -> 24,707 bytes combined, a 12,756-byte (34.0%) reduction
  # across the three affected files, on top of the original round's own
  # measured effect. (array_include.rb's own before-figure, 336, matches
  # its own after-figure when re-run with ONLY the original 4 owners --
  # neither of which ever touches this file -- confirming the measurement
  # methodology itself introduces no spurious skew.)
  #
  # With this round, mruby-rgss's own `owners:` list here now matches
  # mruby-rgss-compiled's own full 14-owner list in tools/bc2cpp/
  # compiled_gems.rb exactly -- no further owner-scaling candidate remains
  # for this gem specifically (a future round adding a new bc2cpp-covered
  # RGSS owner would need to extend compiled_gems.rb's own list first).
  wio_strip_bc2cpp_stubs(spec, compiled_gem: 'mruby-rgss-compiled',
                         owners: %w[RGSS::Sprite RGSS::Window RGSS::Audio.singleton
                                    RGSS::ErrorReport.singleton RGSS::Plane RGSS::Tilemap
                                    RGSS::Bitmap RGSS::Bitmap.singleton RGSS.singleton
                                    RGSS::Input.singleton RGSS::Graphics.singleton
                                    RGSS::Font.singleton RGSS::ErrorReport::Tee Array])
  wio_strip_debug_rbfiles(spec)
end
