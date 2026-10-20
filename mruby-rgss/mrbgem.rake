require_relative '../tools/rgss_tts_config'

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
  cxx.include_paths <<
    "#{dir}/../include" <<
    "#{dir}/../3rd/stb" <<
    build_dir
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/uni-algo" << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/lvgl/lib"
  linker.libraries << "uni-algo" << "lvgl"
  # pthread backs terminal.cxx's std::thread writer (the sixel/iTerm2 backends).
  linker.libraries << "pthread"

  objs << objfile("#{build_dir}/shinonome")

  # ADR 0417: RGSS::Tts (src/tts.cxx) forwards to a backend only the desktop
  # "host" build's executable can install (src/voicevox_tts.cxx). Elsewhere it
  # is a permanent no-op, so src/tts_off.cxx (an empty rgss_tts_define, so
  # lib.cxx stays untouched -- its digest is pinned by bc2cpp) takes its place:
  # no object, no registration, no RGSS::Tts constant.
  objs.delete(objfile("#{build_dir}/src/#{RgssTtsConfig.backend_possible?(build.name) ? 'tts_off' : 'tts'}"))

  file "#{dir}/src/lib.cxx" => "#{build_dir}/shinonome.hxx"
  file "#{build_dir}/shinonome.hxx" => "#{build_dir}/shinonome.cxx"
  file "#{build_dir}/shinonome.cxx" => "#{dir}/gen_shinonome_data.rb" do |t|
    FileUtils.mkdir_p build_dir, verbose: true
    # chdir: rather than Dir.chdir, which is process-wide and races `rake -m`.
    ruby t.prereqs.first, chdir: build_dir
  end
end
