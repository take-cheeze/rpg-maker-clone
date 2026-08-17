MRuby::Gem::Specification.new('mruby-rgss') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RGSS implementation in mruby'

  # Color, Tone and Table provide RGSS-compatible Marshal (_dump/_load) support.
  add_dependency 'mruby-marshal'
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
  # PSP wants its own lv_conf.h (LV_USE_LOG 0, LVGL's pool sized for the
  # PSP's ~24 MB) ahead of the shared repo-root one below: LVGL's
  # lv_conf_internal.h auto-includes whichever lv_conf.h __has_include finds
  # first on the search path, and this rake-driven compile of mruby-rgss
  # (which calls into LVGL -- lib.cxx's vp_refresh_overlay/gfx_snap_to_bitmap)
  # needs to see the same config app/psp/CMakeLists.txt's own LVGL build
  # used, or the two disagree on what LVGL actually compiled in
  # (LV_USE_LOG/LV_USE_SNAPSHOT) and the final EBOOT link fails with
  # undefined references (lv_log_add, lv_snapshot_take) that only the
  # *other* config's LVGL build would have provided.
  cxx.include_paths << "#{dir}/../app/psp" if build.name == 'psp'
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

  file "#{dir}/src/lib.cxx" => "#{build_dir}/shinonome.hxx"
  file "#{build_dir}/shinonome.hxx" => "#{build_dir}/shinonome.cxx"
  file "#{build_dir}/shinonome.cxx" => "#{dir}/gen_shinonome_data.rb" do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    Dir.chdir build_dir do
      ruby  t.prereqs.first
    end
  end
end
