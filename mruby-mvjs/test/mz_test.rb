# Tests for the pure Ruby logic of the RPG Maker MZ foundation (milestone M6.1):
# project detection and the script load order. Like the MV specs, these exercise
# the logic without the WebGL renderer (not built yet), so they run in the host
# test harness.

assert 'MZ.satisfied? recognises an MZ project layout' do
  present = [
    "js/rmmz_core.js",
    "js/rmmz_managers.js",
    "data/System.json",
    "data/Actors.json",
    "img/system/Window.png",
  ]
  assert_true MZ.satisfied?(present)
end

assert 'MZ.satisfied? rejects layouts missing a required marker' do
  # Has the engine script but no database.
  assert_false MZ.satisfied?(["js/rmmz_core.js", "js/main.js"])
  # Has the database but no engine script.
  assert_false MZ.satisfied?(["data/System.json", "data/Map001.json"])
  assert_false MZ.satisfied?([])
end

assert 'MZ.satisfied? does not mistake an MV project for MZ' do
  # MV ships js/rpg_core.js, not js/rmmz_core.js — the two never collide.
  assert_false MZ.satisfied?(["js/rpg_core.js", "data/System.json"])
  # And MV must not be recognised as MZ.
  assert_true MV.satisfied?(["js/rpg_core.js", "data/System.json"])
end

assert 'MZ.core_scripts loads the vendored libraries before the engine' do
  scripts = MZ.core_scripts
  pixi = scripts.index("js/libs/pixi.js")
  core = scripts.index("js/rmmz_core.js")
  assert_true !pixi.nil? && !core.nil?
  assert_true pixi < core
end

assert 'MZ.core_scripts evaluates main.js last' do
  assert_equal "js/main.js", MZ.core_scripts.last
end

assert 'MZ.core_scripts uses the real MZ library filenames' do
  scripts = MZ.core_scripts
  # These are the exact names from the engine's main.js scriptUrls / libs dir —
  # note vorbisdecoder.js (not vorbis.js), and MZ's pako/localforage/effekseer
  # rather than MV's lz-string.
  %w[
    js/libs/pixi.js js/libs/pako.min.js js/libs/localforage.min.js
    js/libs/effekseer.min.js js/libs/vorbisdecoder.js
  ].each { |lib| assert_true scripts.include?(lib) }
  # MV-only libraries must not leak into the MZ list.
  assert_false scripts.include?("js/libs/lz-string.js")
  assert_false scripts.include?("js/libs/vorbis.js")
end

assert 'MZ.core_scripts keeps the MZ engine module order' do
  scripts = MZ.core_scripts
  order = %w[
    js/rmmz_core.js js/rmmz_managers.js js/rmmz_objects.js
    js/rmmz_scenes.js js/rmmz_sprites.js js/rmmz_windows.js
  ]
  indices = order.map { |s| scripts.index(s) }
  assert_false indices.include?(nil)
  assert_equal indices, indices.sort
end

assert 'MZ.runnable_scripts drops the loader and the WASM-gated decoder' do
  scripts = MZ.runnable_scripts
  # The host drives the load order itself, so MZ's dynamic <script>-injection
  # loader is never evaluated...
  assert_false scripts.include?("js/main.js")
  # ...and the Vorbis decoder needs WebAssembly (absent from the quickjs host)
  # and is audio-only, so it is skipped rather than throwing at load.
  assert_false scripts.include?("js/libs/vorbisdecoder.js")
  # Everything else is kept, in the same order as CORE_SCRIPTS.
  expected = MZ.core_scripts - ["js/main.js", "js/libs/vorbisdecoder.js"]
  assert_equal expected, scripts
  # The engine core and PIXI must survive the filtering.
  assert_true scripts.include?("js/rmmz_core.js")
  assert_true scripts.include?("js/libs/pixi.js")
end

assert 'MZ.host_globals_js defines the DOM globals rmmz_managers needs' do
  js = MZ.host_globals_js
  # rmmz_managers.js aborts its module if these are undefined; the shim must
  # define both, and guard so re-evaluating does not clobber a real one.
  assert_true js.include?("HTMLVideoElement")
  assert_true js.include?("HTMLImageElement")
  assert_true js.include?("=== 'undefined'")
end

assert 'MZ.runtime_available? tracks whether the WebGL backend (MV::GL) is built' do
  # MZ boots to Scene_Boot and presents frames on-screen only where the native
  # surfaceless-EGL GLES2 backend is compiled in; elsewhere (Emscripten uses the
  # browser's WebGL; header-less builds) it stays a boot probe. So the predicate
  # mirrors MV::GL.available? exactly.
  assert_equal MV::GL.available?, MZ.runtime_available?
end
