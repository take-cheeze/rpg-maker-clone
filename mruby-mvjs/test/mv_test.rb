# Tests for the pure Ruby logic of the MV maker layer. These exercise project
# detection and the script load order without needing the embedded JavaScript
# runtime (which is not built until milestone M2), so they run in the host test
# harness like the other maker gems' specs.

assert 'MV.satisfied? recognises an MV project layout' do
  present = [
    "js/rpg_core.js",
    "js/rpg_managers.js",
    "data/System.json",
    "data/Actors.json",
    "img/system/Window.png",
  ]
  assert_true MV.satisfied?(present)
end

assert 'MV.satisfied? rejects layouts missing a required marker' do
  # Has the engine script but no database.
  assert_false MV.satisfied?(["js/rpg_core.js", "js/main.js"])
  # Has the database but no engine script (e.g. a bare data dump).
  assert_false MV.satisfied?(["data/System.json", "data/Map001.json"])
  # An LCF project is not an MV project.
  assert_false MV.satisfied?(["RPG_RT.ldb", "RPG_RT.lmt"])
  assert_false MV.satisfied?([])
end

assert 'MV.core_scripts loads the vendored libraries before the engine' do
  scripts = MV.core_scripts
  pixi = scripts.index("js/libs/pixi.js")
  core = scripts.index("js/rpg_core.js")
  assert_true !pixi.nil? && !core.nil?
  assert_true pixi < core
end

assert 'MV.core_scripts evaluates main.js last' do
  assert_equal "js/main.js", MV.core_scripts.last
end

assert 'MV.core_scripts keeps the MV engine module order' do
  scripts = MV.core_scripts
  order = %w[
    js/rpg_core.js js/rpg_managers.js js/rpg_objects.js
    js/rpg_scenes.js js/rpg_sprites.js js/rpg_windows.js
  ].map { |f| scripts.index(f) }
  assert_false order.include?(nil)
  assert_equal order, order.sort
end

assert 'MV.js_available? is true once the quickjs-ng engine is compiled in' do
  # The full test binary compiles the gem's C++ (src/mvjs.cxx), so the embedded
  # engine — and thus MV::JS — is present.
  assert_true MV.js_available?
end

assert 'MV.runtime_available? is false until the game host is wired up' do
  # The JS *engine* is present (M2), but booting a whole game still needs the
  # host globals and rendering (M3/M4); until then this stays false and guards
  # the graceful "under construction" path in MV#start / MV#main_loop.
  assert_false MV.runtime_available?
end
