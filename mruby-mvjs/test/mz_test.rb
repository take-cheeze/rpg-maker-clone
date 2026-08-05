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

assert 'MZ.host_globals_js installs the globals MZ boots on' do
  # Evaluated against the real host, so this checks the shim's *effect* rather
  # than its text. Idempotent, so running it here cannot disturb another spec.
  MV::JS.eval(MZ.host_globals_js)

  # rmmz_managers.js needs both constructors to exist at module-load time.
  assert_equal 'function', MV::JS.eval("typeof HTMLVideoElement")
  assert_equal 'function', MV::JS.eval("typeof HTMLImageElement")

  # HTMLImageElement must be the host's *own* Image constructor. PIXI v5 wraps a
  # texture source with `source instanceof HTMLImageElement`; when that is false
  # it builds a fresh Image and assigns the object it was handed to its `src`,
  # so every bitmap MZ loads would become a broken texture.
  assert_equal true, MV::JS.eval("HTMLImageElement === Image")
  assert_equal true, MV::JS.eval("(new Image()) instanceof HTMLImageElement")

  # SceneManager.checkBrowser throws "does not support IndexedDB" without this.
  assert_equal true, MV::JS.eval("!!indexedDB")
  assert_equal 'function', MV::JS.eval("typeof indexedDB.open")
end

assert 'MZ reuses MVs input probe cadence' do
  # The movement probe holds a direction through RGSS::Input and cycles so some
  # open direction is found on any map; rmmz and rmmv share the button names and
  # state shape, so MZ drives MV's probe rather than duplicating it.
  assert_true MV::MOVE_PROBE_FRAMES > MV::MOVE_PROBE_DWELL
  dirs = (0...MV::MOVE_PROBE_FRAMES).map { |f| MV.move_probe_dir(f) }.uniq
  # All four directions come up inside one probe run, so a wall on one side
  # cannot make the probe report "did not move".
  assert_equal 4, dirs.size
end

assert 'MZ.runnable_scripts is what the boot evaluates, in load order' do
  # The boot evaluates exactly this list (see MZ#boot_probe) and then hands the
  # loop to PIXI's ticker, so a library missing from it is a library the engine
  # never sees. PIXI must precede every rmmz module that builds on it.
  scripts = MZ.runnable_scripts
  assert_true scripts.index("js/libs/pixi.js") < scripts.index("js/rmmz_core.js")
  assert_true scripts.index("js/rmmz_core.js") < scripts.index("js/rmmz_scenes.js")
  # plugins.js loads last so a game's plugins can patch the engine classes.
  assert_equal "js/plugins.js", scripts.last
end

assert 'MZ.runtime_available? tracks whether the WebGL backend (MV::GL) is built' do
  # MZ boots to Scene_Boot and presents frames on-screen only where the native
  # surfaceless-EGL GLES2 backend is compiled in; elsewhere (Emscripten uses the
  # browser's WebGL; header-less builds) it stays a boot probe. So the predicate
  # mirrors MV::GL.available? exactly.
  assert_equal MV::GL.available?, MZ.runtime_available?
end

assert 'MZ.audio_bridge_js is MVs bridge plus the MZ-only overrides' do
  js = MZ.audio_bridge_js
  # The shared bridge (the play/stop/fade replacements) is included verbatim...
  assert_true js.include?(MV::AUDIO_BRIDGE_JS)
  # ...and MZ adds the preload neutralisers on top.
  assert_true js.include?("loadStaticSe")
  assert_true js.include?("createBuffer")
end

assert 'the MZ audio bridge queues ops and neutralises the eager preload' do
  # Exercised against the real host with a stand-in AudioManager, so this checks
  # the bridge's *effect* rather than its text. A stand-in is used because rmmz
  # itself is a fetched, CI-only fixture and is not present in this test build.
  MV::JS.eval(
    "globalThis.AudioManager = { _seBuffers: [], " \
    "playSe: function(){ return 'ORIGINAL'; }, " \
    "loadStaticSe: function(){ throw new Error('would construct WebAudio'); }, " \
    "createBuffer: function(){ throw new Error('would construct WebAudio'); } };"
  )
  MV::JS.eval(MZ.audio_bridge_js)

  # Playing an SE now queues an op instead of touching the engine's audio stack.
  MV::JS.eval(
    "AudioManager.playSe({ name: 'Beep', volume: 90, pitch: 100, pan: 0 });"
  )
  assert_equal "se_play\tBeep\t90\t100", MV::JS.eval("__mv_drainAudio()")
  # ...and draining clears the queue.
  assert_equal "", MV::JS.eval("__mv_drainAudio()")

  # Scene_Boot.start preloads the system sounds through loadStaticSe. MZ's
  # WebAudio fetches with `fetch`, which this host does not provide, so leaving
  # it live kills the boot the moment a game names a system sound. Both entry
  # points must now be inert rather than throwing.
  assert_equal "ok", MV::JS.eval(
    "(function(){ try { AudioManager.loadStaticSe({ name: 'Beep' }); " \
    "return 'ok'; } catch (e) { return 'threw: ' + e.message; } })();"
  )
  assert_equal "object", MV::JS.eval(
    "typeof AudioManager.createBuffer('se/', 'Beep')"
  )

  # A parsed op maps onto the RGSS::Audio call MZ dispatches, folder and all.
  call = MV.parse_audio_op("se_play\tBeep\t90\t100")
  assert_equal :se_play, call[0]
  assert_equal "audio/se/Beep", call[1]
end

assert 'MZ.message_probe_js queues text through $gameMessage' do
  # Exercised against the real host with a stand-in $gameMessage, so this checks
  # the injection's *effect*: it must call the engine's own Game_Message#add
  # (what a Show Text command does) rather than poke at window state.
  MV::JS.eval(
    "globalThis.$gameMessage = { texts: [], busy: false, " \
    "add: function (t) { this.texts.push(t); }, " \
    "isBusy: function () { return this.busy; } };"
  )
  MV::JS.eval(MZ.message_probe_js("hello"))
  assert_equal "hello", MV::JS.eval("$gameMessage.texts.join('|')")

  # A message already on screen is left alone, so the probe never stacks onto a
  # game's own dialogue.
  MV::JS.eval("$gameMessage.busy = true;")
  MV::JS.eval(MZ.message_probe_js("second"))
  assert_equal "hello", MV::JS.eval("$gameMessage.texts.join('|')")
end

assert 'MZ.js_string escapes what it quotes' do
  # The probe text is interpolated into a JS source string, so a quote or a
  # backslash in it must not end (or reopen) the literal.
  assert_equal "'plain'", MZ.js_string("plain")
  assert_equal "'it\\'s'", MZ.js_string("it's")
  assert_equal "'a\\\\b'", MZ.js_string("a\\b")
  # And the result really is one string to the engine.
  assert_equal "it's", MV::JS.eval("(#{MZ.js_string("it's")})")
end

assert 'MZ.message_state_js reports both halves of the message state' do
  MV::JS.eval(
    "globalThis.$gameMessage = { isBusy: function () { return true; } }; " \
    "globalThis.SceneManager = { _scene: { _messageWindow: { openness: 255 } } };"
  )
  assert_equal "busy=true window_open=true", MV::JS.eval(MZ.message_state_js)

  # A window that has not opened yet is reported as such, which is the whole
  # point: queued text with a shut window means the message path is broken.
  MV::JS.eval("SceneManager._scene._messageWindow.openness = 0;")
  assert_equal "busy=true window_open=false", MV::JS.eval(MZ.message_state_js)
end

assert 'MZ.menu_probe_js sets the flag Scene_Map acts on, and only there' do
  # rmmz's keyboard Input.keyMapper has no "menu" binding, so a key press cannot
  # reach Scene_Map#isMenuCalled; `menuCalling` is exactly what that predicate
  # sets, and updateCallMenu then runs the real callMenu.
  MV::JS.eval(
    "function Scene_Map() {} globalThis.Scene_Map = Scene_Map; " \
    "globalThis.SceneManager = { _scene: new Scene_Map() };"
  )
  MV::JS.eval(MZ.menu_probe_js)
  assert_equal true, MV::JS.eval("SceneManager._scene.menuCalling === true")

  # Any other scene is left untouched — the menu is only ever called from the
  # map, and Scene_Menu itself must not be poked while it is up.
  MV::JS.eval(
    "function Scene_Menu() {} globalThis.SceneManager._scene = new Scene_Menu();"
  )
  MV::JS.eval(MZ.menu_probe_js)
  assert_equal true, MV::JS.eval("SceneManager._scene.menuCalling === undefined")
end

assert 'MZ.save_probe_js round-trips through DataManager across frames' do
  # MZ's save path is a promise chain (unlike MV's synchronous one), so the
  # probe cannot read a return value: it starts the chain and the result lands
  # some pumped frames later. Driven here against the real host with a stand-in
  # DataManager, which is what makes the asynchrony visible.
  MV::JS.eval(<<~'JS')
    globalThis.__mzCalls = [];
    globalThis.DataManager = {
      saveGame: function (id) { __mzCalls.push('save' + id); return Promise.resolve(0); },
      loadGame: function (id) { __mzCalls.push('load' + id); return Promise.resolve(0); },
      savefileExists: function (id) { __mzCalls.push('exists' + id); return true; }
    };
    // No scene stack here, so the probe skips the Scene_Map re-entry a real
    // load ends with (covered separately below).
    delete globalThis.SceneManager;
    delete globalThis.Scene_Map;
  JS
  MV::JS.eval(MZ.save_probe_js(1))
  # Nothing yet — every step of the chain settles on a later microtask turn.
  assert_equal "", MV::JS.eval(MZ.save_result_js)

  5.times { |i| MV::JS.pump(i * (1000.0 / 60.0)) }
  assert_equal "saved=true exists=true loaded=true",
               MV::JS.eval(MZ.save_result_js)
  # The slot is honoured, and `savefileExists` is read *after* the save resolves
  # — StorageManager only refreshes its key cache at the end of its own chain.
  assert_equal "save1,exists1,load1", MV::JS.eval("__mzCalls.join(',')")
end

assert 'MZ.save_probe_js re-enters the map, and keeps its verdict if that fails' do
  # A real load throws the $game* objects away and rebuilds them, so the probe
  # finishes the way Scene_Load does — back into Scene_Map — rather than leaving
  # the running scene holding references the load discarded.
  MV::JS.eval(<<~'JS')
    globalThis.DataManager = {
      saveGame: function () { return Promise.resolve(0); },
      loadGame: function () { return Promise.resolve(0); },
      savefileExists: function () { return true; }
    };
    function Scene_Map() {}
    globalThis.Scene_Map = Scene_Map;
    globalThis.SceneManager = { went: null, goto: function (s) { this.went = s; } };
  JS
  MV::JS.eval(MZ.save_probe_js(1))
  5.times { |i| MV::JS.pump(i * (1000.0 / 60.0)) }
  assert_equal "saved=true exists=true loaded=true",
               MV::JS.eval(MZ.save_result_js)
  assert_equal true, MV::JS.eval("SceneManager.went === Scene_Map")

  # A re-entry that throws must not turn a successful round-trip into a failure
  # line — nor disappear silently.
  MV::JS.eval("SceneManager.goto = function () { throw new Error('no stack'); };")
  MV::JS.eval(MZ.save_probe_js(1))
  5.times { |i| MV::JS.pump(i * (1000.0 / 60.0)) }
  assert_equal "saved=true exists=true loaded=true goto_error=no stack",
               MV::JS.eval(MZ.save_result_js)
end

assert 'MZ.save_probe_js reports a rejected chain instead of hanging' do
  MV::JS.eval(
    "globalThis.DataManager = { saveGame: function () { " \
    "return Promise.reject(new Error('disk full')); } };"
  )
  MV::JS.eval(MZ.save_probe_js(2))
  5.times { |i| MV::JS.pump(i * (1000.0 / 60.0)) }
  assert_equal "error: disk full", MV::JS.eval(MZ.save_result_js)
end

assert 'MZ.battle_probe_js runs Battle Processing through the map interpreter' do
  # Not a bare SceneManager.push(Scene_Battle): that deadlocks, because
  # Scene_Map.stop starts the encounter effect and the effect only advances
  # while the scene is inactive. Command 301 inside the map interpreter is the
  # path the engine itself takes.
  MV::JS.eval(
    "globalThis.$gameMap = { _interpreter: { setup: function (list, id) { " \
    "this.list = list; this.eventId = id; } } };"
  )
  MV::JS.eval(MZ.battle_probe_js(7))
  assert_equal 301, MV::JS.eval("$gameMap._interpreter.list[0].code")
  # [type, troopId, canEscape, canLose] — a direct designation of troop 7.
  assert_equal "0,7,true,false",
               MV::JS.eval("$gameMap._interpreter.list[0].parameters.join(',')")
  # ...terminated by the end-of-list command, so the interpreter stops after it.
  assert_equal 0, MV::JS.eval("$gameMap._interpreter.list[1].code")
  assert_equal 0, MV::JS.eval("$gameMap._interpreter.eventId")
end

assert 'the MZ probes are inert before the engine defines their globals' do
  # Every probe runs each frame from MZ#main_loop, including the frames before
  # the boot has defined $gameMessage / SceneManager / $gameMap. None may throw.
  MV::JS.eval(
    "delete globalThis.$gameMessage; delete globalThis.SceneManager; " \
    "delete globalThis.$gameMap; delete globalThis.Scene_Map;"
  )
  assert_nothing_raised { MV::JS.eval(MZ.message_probe_js("x")) }
  assert_nothing_raised { MV::JS.eval(MZ.menu_probe_js) }
  assert_nothing_raised { MV::JS.eval(MZ.battle_probe_js(1)) }
  assert_equal "busy=false window_open=false", MV::JS.eval(MZ.message_state_js)
  # ...and a save probe with no DataManager says so rather than never settling.
  MV::JS.eval("delete globalThis.DataManager;")
  MV::JS.eval(MZ.save_probe_js(1))
  assert_equal "error: no DataManager", MV::JS.eval(MZ.save_result_js)
end

assert 'MZ.host_globals_js provides the FontFace MZ builds when a font is named' do
  MV::JS.eval(MZ.host_globals_js)

  # FontManager.startLoading does `new FontFace(family, url)` and waits on its
  # load() promise. Without the constructor that throws inside
  # Scene_Boot.onDatabaseLoaded, so naming a font in System.advanced kills the
  # boot outright — the glyphs themselves are rasterised natively from the
  # game's fonts/ dir, so the shim only has to satisfy the bookkeeping.
  assert_equal 'function', MV::JS.eval("typeof FontFace")
  assert_equal 'rmmz-mainfont',
               MV::JS.eval("new FontFace('rmmz-mainfont', 'url(x)').family")
  assert_equal true,
               MV::JS.eval("typeof (new FontFace('f','url(x)').load().then) === 'function'")
  # document.fonts.add is what the resolved load() calls; it must exist too.
  assert_equal 'function', MV::JS.eval("typeof document.fonts.add")
end
