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

assert 'MZ.effekseer_shim_js replaces window.effekseer with the diagnostic stub' do
  js = MZ.effekseer_shim_js
  assert_true js.include?("g.effekseer = { createContext: makeContext }")
  assert_true js.include?("EFKEFC")
end

assert 'the Effekseer stub survives Graphics._createEffekseerContext\'s real call sequence' do
  # rmmz_core.js's Graphics._createEffekseerContext calls init() and then
  # unconditionally setRestorationOfStatesFlag(false) on the context before
  # ever touching the effect-loading API this stub otherwise exercises. A
  # real downloaded game (Labyria) hit this: the stub had init() but not
  # setRestorationOfStatesFlag, so the second call threw "not a function",
  # was swallowed by rmmz_core.js's own try/catch, and silently reset
  # Graphics._app to null -- turning into an opaque "Failed to initialize
  # graphics." a scene later with no clue an Effekseer call was the cause.
  MV::JS.eval(MZ.effekseer_shim_js)
  MV::JS.eval(
    "globalThis.__ctx3 = effekseer.createContext(); " \
    "__ctx3.init(); __ctx3.setRestorationOfStatesFlag(false); " \
    "globalThis.__ctx3_survived = true;"
  )
  assert_true MV::JS.eval("__ctx3_survived")
end

assert 'the Effekseer stub loads a real effect file and reports it, honestly' do
  # Exercised against the real host and real files on disk, through the same
  # __mv_existsSync/__mv_readFileBytes natives every other MZ asset uses.
  MV::JS.base_dir = "mvjs_effekseer_fixture"
  begin
    Dir.mkdir("mvjs_effekseer_fixture") rescue nil
    Dir.mkdir("mvjs_effekseer_fixture/effects") rescue nil
    File.open("mvjs_effekseer_fixture/effects/Real.efkefc", "wb") do |f|
      f.write("EFKEFC\x01\x00garbage")
    end
    File.open("mvjs_effekseer_fixture/effects/Bogus.efkefc", "wb") do |f|
      f.write("not an effect file")
    end

    MV::JS.eval(MZ.effekseer_shim_js)
    MV::JS.eval("globalThis.__ctx = effekseer.createContext(); __ctx.init();")

    # A real, well-formed file: onLoad fires, isLoaded is true, and the magic
    # check passes.
    MV::JS.eval(
      "globalThis.__loaded = false; globalThis.__errored = false; " \
      "globalThis.__effect = __ctx.loadEffect('effects/Real.efkefc', 1, " \
      "function(){ __loaded = true; }, function(){ __errored = true; });"
    )
    assert_equal true, MV::JS.eval("__loaded")
    assert_equal false, MV::JS.eval("__errored")
    assert_equal true, MV::JS.eval("__effect.isLoaded")
    assert_equal true, MV::JS.eval("__effect.magicOk")

    # A file that exists but is not an .efkefc container: still loaded (so the
    # animation completes rather than throwing) but flagged, not silently
    # treated as a real effect.
    MV::JS.eval(
      "globalThis.__effect2 = __ctx.loadEffect('effects/Bogus.efkefc', 1, " \
      "function(){}, function(){});"
    )
    assert_equal true, MV::JS.eval("__effect2.isLoaded")
    assert_equal false, MV::JS.eval("__effect2.magicOk")

    # A genuinely missing effect reports through onError, same as the real
    # engine's fetch failure would -- not swallowed twice over.
    MV::JS.eval(
      "globalThis.__loaded3 = false; globalThis.__errored3 = false; " \
      "globalThis.__effect3 = __ctx.loadEffect('effects/Missing.efkefc', 1, " \
      "function(){ __loaded3 = true; }, function(){ __errored3 = true; });"
    )
    assert_equal false, MV::JS.eval("__loaded3")
    assert_equal true, MV::JS.eval("__errored3")
    assert_equal false, MV::JS.eval("__effect3.isLoaded")
  ensure
    File.delete("mvjs_effekseer_fixture/effects/Real.efkefc") rescue nil
    File.delete("mvjs_effekseer_fixture/effects/Bogus.efkefc") rescue nil
    Dir.delete("mvjs_effekseer_fixture/effects") rescue nil
    Dir.delete("mvjs_effekseer_fixture") rescue nil
    MV::JS.base_dir = ""
  end
end

assert 'the Effekseer stub retires play() handles instead of hanging forever' do
  MV::JS.eval(MZ.effekseer_shim_js)
  MV::JS.eval("globalThis.__ctx2 = effekseer.createContext(); __ctx2.init();")

  # Sprite_Animation.checkEnd (rmmz_sprites.js) waits for handle.exists to go
  # false before it considers the animation finished; without a bounded
  # lifetime here that wait would never end.
  MV::JS.eval("globalThis.__h = __ctx2.play({});")
  assert_equal true, MV::JS.eval("__h.exists")

  MV::JS.eval("for (var i = 0; i < 25; i++) __ctx2.update();")
  assert_equal false, MV::JS.eval("__h.exists")

  # stopAll (SceneManager.updateEffekseer, on scene change) retires every live
  # handle immediately rather than waiting out their lifetimes.
  MV::JS.eval("globalThis.__h2 = __ctx2.play({});")
  assert_equal true, MV::JS.eval("__h2.exists")
  MV::JS.eval("__ctx2.stopAll();")
  assert_equal false, MV::JS.eval("__h2.exists")
end

assert 'MZ.render_skip_bridge_js only wraps once Graphics._app exists' do
  js = MZ.render_skip_bridge_js
  assert_true js.include?("Graphics._app")
  # The idempotency guard: a second eval must not double-wrap an already
  # wrapped render (see the effect test below for what double-wrapping would
  # do — call the real render twice per app.render() call).
  assert_true js.include?("Graphics.__mzRealRender")
end

assert 'the MZ render-skip bridge suppresses render() until forced' do
  # Exercised against the real host with a stand-in Graphics/PIXI.Application,
  # so this checks the bridge's *effect* rather than its text. rmmz itself is a
  # fetched, CI-only fixture and is not present in this test build.
  MV::JS.eval(
    "globalThis.__mzRenderCalls = 0; " \
    "globalThis.Graphics = { _app: { render: function () { " \
    "__mzRenderCalls++; } } };"
  )
  MV::JS.eval(MZ.render_skip_bridge_js)

  # Armed by default: the wrapped app.render() must not reach the real one.
  assert_equal true, MV::JS.eval("Graphics.__mzSkipRender")
  MV::JS.eval("Graphics._app.render();")
  assert_equal 0, MV::JS.eval("__mzRenderCalls")

  # Flipping the flag off (as a live game, or #present's real-play path, would
  # leave it) lets frames through again.
  MV::JS.eval("Graphics.__mzSkipRender = false; Graphics._app.render();")
  assert_equal 1, MV::JS.eval("__mzRenderCalls")

  # __mzForceRender reaches the real render regardless of the flag — this is
  # what MZ#force_render_before_capture calls right before a screenshot, so a
  # capture on a skip-armed run still shows the current frame.
  MV::JS.eval("Graphics.__mzSkipRender = true;")
  MV::JS.eval("Graphics.__mzForceRender();")
  assert_equal 2, MV::JS.eval("__mzRenderCalls")

  # Idempotent: re-evaluating (boot_probe guards on this too, but the bridge
  # must not misbehave if it were ever run twice) leaves the real render
  # called exactly once per forced/unsuppressed call, not twice.
  MV::JS.eval(MZ.render_skip_bridge_js)
  MV::JS.eval("Graphics.__mzForceRender();")
  assert_equal 3, MV::JS.eval("__mzRenderCalls")
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

# A stand-in for the `$game*` objects the save probe's signature reads, plus a
# DataManager that really does round-trip them: `saveGame` snapshots the state
# and `loadGame` puts it back. The probe now arms those fields, clobbers them
# between the save and the load and compares what returns (`restored=`), so a
# fake that only resolves promises would no longer be testing the probe's actual
# claim — it would be testing the failure path. That path is covered too, by the
# spec that hands back a load which restores nothing.
MZ_SAVE_FAKE_JS = <<~'JS'
  globalThis.__mzCalls = [];
  globalThis.__mzSnap = null;
  globalThis.$gameParty = {
    _gold: 0, _items: {},
    gold: function () { return this._gold; },
    gainGold: function (n) { this._gold += n; },
    numItems: function (it) { return this._items[it.id] || 0; },
    gainItem: function (it, n) { this._items[it.id] = (this._items[it.id] || 0) + n; },
    loseItem: function (it, n) { this.gainItem(it, -n); }
  };
  globalThis.$gameSwitches = {
    _d: {},
    value: function (i) { return !!this._d[i]; },
    setValue: function (i, v) { this._d[i] = v; }
  };
  globalThis.$gameVariables = {
    _d: {},
    value: function (i) { return this._d[i] || 0; },
    setValue: function (i, v) { this._d[i] = v; }
  };
  globalThis.$gameActors = {
    _a: { hp: 400, mhp: 400, setHp: function (v) { this.hp = v; } },
    actor: function () { return this._a; }
  };
  globalThis.$gamePlayer = {
    x: 8, y: 6,
    locate: function (x, y) { this.x = x; this.y = y; }
  };
  globalThis.$dataItems = [null, { id: 1, name: 'Potion' }];

  globalThis.__mzDump = function () {
    return JSON.stringify({
      gold: $gameParty._gold, items: $gameParty._items,
      sw: $gameSwitches._d, vars: $gameVariables._d,
      hp: $gameActors._a.hp, x: $gamePlayer.x, y: $gamePlayer.y
    });
  };
  globalThis.__mzRestore = function (json) {
    var o = JSON.parse(json);
    $gameParty._gold = o.gold; $gameParty._items = o.items;
    $gameSwitches._d = o.sw; $gameVariables._d = o.vars;
    $gameActors._a.hp = o.hp; $gamePlayer.x = o.x; $gamePlayer.y = o.y;
  };
JS

assert 'MZ.save_probe_js round-trips through DataManager across frames' do
  # MZ's save path is a promise chain (unlike MV's synchronous one), so the
  # probe cannot read a return value: it starts the chain and the result lands
  # some pumped frames later. Driven here against the real host with a stand-in
  # DataManager, which is what makes the asynchrony visible.
  MV::JS.eval(MZ_SAVE_FAKE_JS)
  MV::JS.eval(<<~'JS')
    globalThis.DataManager = {
      saveGame: function (id) {
        __mzCalls.push('save' + id); __mzSnap = __mzDump();
        return Promise.resolve(0);
      },
      loadGame: function (id) {
        __mzCalls.push('load' + id); __mzRestore(__mzSnap);
        return Promise.resolve(0);
      },
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
  # `restored=true` is the claim that matters: the fields the probe armed came
  # back after being overwritten. The three before it only say the chain ran.
  assert_equal "saved=true exists=true loaded=true restored=true",
               MV::JS.eval(MZ.save_result_js)
  # The slot is honoured, and `savefileExists` is read *after* the save resolves
  # — StorageManager only refreshes its key cache at the end of its own chain.
  assert_equal "save1,exists1,load1", MV::JS.eval("__mzCalls.join(',')")
end

assert 'MZ.save_probe_js re-enters the map, and keeps its verdict if that fails' do
  # A real load throws the $game* objects away and rebuilds them, so the probe
  # finishes the way Scene_Load does — back into Scene_Map — rather than leaving
  # the running scene holding references the load discarded.
  MV::JS.eval(MZ_SAVE_FAKE_JS)
  MV::JS.eval(<<~'JS')
    globalThis.DataManager = {
      saveGame: function () { __mzSnap = __mzDump(); return Promise.resolve(0); },
      loadGame: function () { __mzRestore(__mzSnap); return Promise.resolve(0); },
      savefileExists: function () { return true; }
    };
    function Scene_Map() {}
    globalThis.Scene_Map = Scene_Map;
    globalThis.SceneManager = { went: null, goto: function (s) { this.went = s; } };
  JS
  MV::JS.eval(MZ.save_probe_js(1))
  5.times { |i| MV::JS.pump(i * (1000.0 / 60.0)) }
  assert_equal "saved=true exists=true loaded=true restored=true",
               MV::JS.eval(MZ.save_result_js)
  assert_equal true, MV::JS.eval("SceneManager.went === Scene_Map")

  # A re-entry that throws must not turn a successful round-trip into a failure
  # line — nor disappear silently.
  MV::JS.eval("SceneManager.goto = function () { throw new Error('no stack'); };")
  MV::JS.eval(MZ.save_probe_js(1))
  5.times { |i| MV::JS.pump(i * (1000.0 / 60.0)) }
  assert_equal "saved=true exists=true loaded=true restored=true " \
               "goto_error=no stack",
               MV::JS.eval(MZ.save_result_js)
end

assert 'MZ.save_probe_js catches a load that settles but restores nothing' do
  # The failure the three older claims cannot see. `loadGame` resolves, so
  # `saved`/`exists`/`loaded` are all true — and the state it was supposed to
  # bring back is still the clobbered one. This is what `restored=` is for, and
  # it is why the probe arms the fields first: a load that quietly started a new
  # game would leave the defaults, which is only distinguishable from a restored
  # save if the saved state was never the defaults.
  MV::JS.eval(MZ_SAVE_FAKE_JS)
  MV::JS.eval(<<~'JS')
    globalThis.DataManager = {
      saveGame: function () { __mzSnap = __mzDump(); return Promise.resolve(0); },
      loadGame: function () { return Promise.resolve(0); },
      savefileExists: function () { return true; }
    };
    delete globalThis.SceneManager;
    delete globalThis.Scene_Map;
  JS
  MV::JS.eval(MZ.save_probe_js(1))
  5.times { |i| MV::JS.pump(i * (1000.0 / 60.0)) }
  res = MV::JS.eval(MZ.save_result_js)
  assert_equal true, res.include?("loaded=true restored=false")
  # Both signatures are printed, so the line names the fields that did not come
  # back rather than only that something did not.
  assert_equal true, res.include?("before=[gold=1234 sw=1 var=4321")
  assert_equal true, res.include?("after=[gold=2011 sw=0 var=9999")
end

assert 'MZ.save_probe_js reports a rejected chain instead of hanging' do
  MV::JS.eval(MZ_SAVE_FAKE_JS)
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

assert 'MZ.transfer_probe_js runs Transfer Player through the map interpreter' do
  # Not $gamePlayer.reserveTransfer() from outside: command 201 is what also
  # puts the interpreter into its "transfer" wait mode, so the map waits for the
  # move the way it does in a game rather than running on through it.
  MV::JS.eval(
    "globalThis.$gameMap = { _interpreter: { setup: function (list, id) { " \
    "this.list = list; this.eventId = id; } } };"
  )
  MV::JS.eval(MZ.transfer_probe_js(2, 4, 5))
  assert_equal 201, MV::JS.eval("$gameMap._interpreter.list[0].code")
  # [designation, mapId, x, y, direction, fade] — 0 is a direct designation
  # (1 reads the three from variables), direction 0 keeps the facing.
  assert_equal "0,2,4,5,0,0",
               MV::JS.eval("$gameMap._interpreter.list[0].parameters.join(',')")
  assert_equal 0, MV::JS.eval("$gameMap._interpreter.list[1].code")
end

assert 'MZ.transfer_state_js reports the destination, not just the map id' do
  # `arrived` is the variable the *destination* map's own parallel event writes.
  # A map id that changed says the transfer was applied; only this says the new
  # map's data was fetched and its events set running.
  MV::JS.eval(<<~'JS')
    globalThis.$gameMap = {
      mapId: function () { return 2; },
      events: function () { return [{}]; }
    };
    globalThis.$gamePlayer = { x: 4, y: 5 };
    globalThis.$gameVariables = { value: function (i) { return i === 2 ? 7 : 0; } };
  JS
  assert_equal "map=2 x=4 y=5 arrived=7 events=1",
               MV::JS.eval(MZ.transfer_state_js)

  # Before the boot has built any of it, the state reads as absent rather than
  # throwing — every probe runs from the first frame.
  MV::JS.eval(
    "delete globalThis.$gameMap; delete globalThis.$gamePlayer; " \
    "delete globalThis.$gameVariables;"
  )
  assert_equal "map=-1 x=-1 y=-1 arrived=-1 events=-1",
               MV::JS.eval(MZ.transfer_state_js)
end

assert 'MZ.common_event_probe_js starts both kinds of common event' do
  # One command list doing both: Control Switches turns on the switch the
  # parallel common event is gated on (it has no other way to start — it is not
  # a map event and nothing calls it), and Call Common Event runs the other.
  MV::JS.eval(
    "globalThis.$gameMap = { _interpreter: { setup: function (list, id) { " \
    "this.list = list; this.eventId = id; } } };"
  )
  MV::JS.eval(MZ.common_event_probe_js(2, 2))
  assert_equal 121, MV::JS.eval("$gameMap._interpreter.list[0].code")
  # [startId, endId, value] — value 0 is ON, over the single switch 2.
  assert_equal "2,2,0",
               MV::JS.eval("$gameMap._interpreter.list[0].parameters.join(',')")
  assert_equal 117, MV::JS.eval("$gameMap._interpreter.list[1].code")
  assert_equal "2", MV::JS.eval("$gameMap._interpreter.list[1].parameters.join(',')")
  assert_equal 0, MV::JS.eval("$gameMap._interpreter.list[2].code")
end

assert 'MZ.common_event_state_js separates the two common event paths' do
  # `commons`/`active` are what tell "the parallel event never became active"
  # apart from "it ran and its write went nowhere" — Game_Map only holds
  # Game_CommonEvent objects for trigger-2 events, and only an active one has an
  # interpreter.
  MV::JS.eval(<<~'JS')
    globalThis.$gameVariables = {
      _d: { 3: 11, 4: 22 },
      value: function (i) { return this._d[i] || 0; }
    };
    globalThis.$gameMap = { _commonEvents: [{ _interpreter: {} }] };
  JS
  assert_equal "parallel=11 called=22 commons=1 active=1",
               MV::JS.eval(MZ.common_event_state_js(3, 4))

  # An inactive parallel common event: present in the list, no interpreter.
  MV::JS.eval("$gameMap._commonEvents = [{ _interpreter: null }]; " \
              "$gameVariables._d = {};")
  assert_equal "parallel=0 called=0 commons=1 active=0",
               MV::JS.eval(MZ.common_event_state_js(3, 4))
end

assert 'MZ.encounter_state_js reports the step counter, not just the outcome' do
  # `steps` is the diagnosis when no encounter happens: a counter that never
  # moves means no step was ever taken (or encounters are off for the map),
  # while one that counts down and re-arms without a battle means the encounter
  # fired somewhere else. Neither is visible from the outside without it.
  MV::JS.eval(<<~'JS')
    globalThis.$gameMap = { mapId: function () { return 2; } };
    globalThis.$gamePlayer = { _encounterCount: 3, x: 5, y: 5 };
    globalThis.$gameTroop = { _troopId: 1 };
  JS
  assert_equal "map=2 steps=3 x=5 y=5 troop=1",
               MV::JS.eval(MZ.encounter_state_js)

  # No battle yet: $gameTroop exists from the boot but holds no troop.
  MV::JS.eval("$gameTroop._troopId = 0; $gamePlayer._encounterCount = 0;")
  assert_equal "map=2 steps=0 x=5 y=5 troop=0",
               MV::JS.eval(MZ.encounter_state_js)
end

assert 'MZ.message_play_probe_js builds a choice with two distinct branches' do
  MV::JS.eval(
    "globalThis.$gameMap = { _interpreter: { setup: function (list, id) { " \
    "this.list = list; this.eventId = id; } } };"
  )
  MV::JS.eval(MZ.message_play_probe_js(5, 55, 11, "hello"))
  list = "$gameMap._interpreter.list"
  # Show Text, its two lines, then Show Choices.
  assert_equal 101, MV::JS.eval("#{list}[0].code")
  assert_equal 401, MV::JS.eval("#{list}[1].code")
  assert_equal "hello", MV::JS.eval("#{list}[1].parameters[0]")
  assert_equal 102, MV::JS.eval("#{list}[3].code")
  assert_equal "First,Second", MV::JS.eval("#{list}[3].parameters[0].join(',')")

  # Two branches, each writing the *same* variable a *different* value: that is
  # what makes the branch that ran identifiable. A single-branch list could not
  # tell "the choice was made" from "nothing happened".
  assert_equal 402, MV::JS.eval("#{list}[4].code")
  assert_equal 0, MV::JS.eval("#{list}[4].parameters[0]")
  assert_equal "5,5,0,0,11", MV::JS.eval("#{list}[5].parameters.join(',')")
  assert_equal 402, MV::JS.eval("#{list}[7].code")
  assert_equal 1, MV::JS.eval("#{list}[7].parameters[0]")
  assert_equal "5,5,0,0,55", MV::JS.eval("#{list}[8].parameters.join(',')")
  # ...closed by the end-of-branches command, then the end of the list.
  assert_equal 404, MV::JS.eval("#{list}[10].code")
  assert_equal 0, MV::JS.eval("#{list}[11].code")
end

assert 'MZ.message_play_state_js sees the choice window and the branch taken' do
  MV::JS.eval(<<~'JS')
    function Window_ChoiceList() {}
    globalThis.$gameMessage = { isBusy: function () { return true; } };
    globalThis.$gameVariables = { value: function () { return 55; } };
    globalThis.SceneManager = { _scene: {
      _messageWindow: { openness: 255 },
      _windowLayer: { children: [new Window_ChoiceList()] }
    } };
    SceneManager._scene._windowLayer.children[0].active = true;
    SceneManager._scene._windowLayer.children[0].index = function () { return 1; };
  JS
  assert_equal "busy=1 mopen=255 choice=1 branch=55",
               MV::JS.eval(MZ.message_play_state_js(5))

  # A choice window that is not accepting input is not a choice being made.
  MV::JS.eval("SceneManager._scene._windowLayer.children[0].active = false;")
  assert_equal "busy=1 mopen=255 choice=0 branch=55",
               MV::JS.eval(MZ.message_play_state_js(5))
end

assert 'MZ.equip_setup_js hands the party the weapon through an event command' do
  MV::JS.eval(
    "globalThis.$gameMap = { _interpreter: { setup: function (list, id) { " \
    "this.list = list; this.eventId = id; } } };"
  )
  MV::JS.eval(MZ.equip_setup_js(1))
  assert_equal 127, MV::JS.eval("$gameMap._interpreter.list[0].code")
  # [weaponId, operation, operandType, operand, includeEquipped] — one Dagger,
  # gained as a constant. Window_EquipItem lists what the party owns, so an
  # unowned weapon would never be selectable.
  assert_equal "1,0,0,1,false",
               MV::JS.eval("$gameMap._interpreter.list[0].parameters.join(',')")
  assert_equal 0, MV::JS.eval("$gameMap._interpreter.list[1].code")
end

assert 'MZ.equip_state_js watches the parameter, not just the slot' do
  MV::JS.eval(<<~'JS')
    globalThis.$dataWeapons = [null, { id: 1 }];
    globalThis.$gameParty = { numItems: function () { return 1; } };
    globalThis.$gameActors = {
      _a: { atk: 30, weapons: function () { return []; } },
      actor: function () { return this._a; }
    };
    globalThis.SceneManager = { _scene: { _windowLayer: { children: [] } } };
  JS
  assert_equal "atk=30 weapon=0 held=1 win=- idx=-1",
               MV::JS.eval(MZ.equip_state_js(1))

  # With the weapon on, both the slot and the stat move. Reporting them
  # separately is the point: a slot that fills while `atk` stays put is the
  # failure the check is for, and it is invisible if only the slot is read.
  MV::JS.eval("$gameActors._a.atk = 50; " \
              "$gameActors._a.weapons = function () { return [{ id: 1 }]; };")
  assert_equal "atk=50 weapon=1 held=1 win=- idx=-1",
               MV::JS.eval(MZ.equip_state_js(1))
end

assert 'the MZ probes are inert before the engine defines their globals' do
  # Every probe runs each frame from MZ#main_loop, including the frames before
  # the boot has defined $gameMessage / SceneManager / $gameMap. None may throw.
  MV::JS.eval(
    "delete globalThis.$gameMessage; delete globalThis.SceneManager; " \
    "delete globalThis.$gameMap; delete globalThis.Scene_Map; " \
    "delete globalThis.$gameVariables;"
  )
  assert_nothing_raised { MV::JS.eval(MZ.message_probe_js("x")) }
  assert_nothing_raised { MV::JS.eval(MZ.menu_probe_js) }
  assert_nothing_raised { MV::JS.eval(MZ.battle_probe_js(1)) }
  assert_nothing_raised { MV::JS.eval(MZ.transfer_probe_js(2, 4, 5)) }
  assert_nothing_raised { MV::JS.eval(MZ.common_event_probe_js(2, 2)) }
  assert_nothing_raised { MV::JS.eval(MZ.message_play_probe_js(5, 55, 11, "x")) }
  assert_nothing_raised { MV::JS.eval(MZ.equip_setup_js(1)) }
  MV::JS.eval("delete globalThis.$gamePlayer; delete globalThis.$gameTroop;")
  assert_equal "map=-1 steps=-1 x=-1 y=-1 troop=0",
               MV::JS.eval(MZ.encounter_state_js)
  assert_equal "parallel=-1 called=-1 commons=-1 active=0",
               MV::JS.eval(MZ.common_event_state_js(3, 4))
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

# The WOFF unpacker (mvcanvas.cxx's woff_to_sfnt, exercised through
# MV::Font.unpack_woff/smoke_test) is what lets an MZ project's fonts/*.woff
# draw text at all -- see docs/TODO.md's ".woff fonts" entry. It had no CI
# coverage because it needs a redistributable font and the test beds ship
# none; MV::Font.smoke_test bypasses game_font()'s process-lifetime cache
# (the normal load path, first text draw wins) so a font built fresh in a
# test is actually exercised rather than shadowed by whatever an earlier test
# already drew text with. So instead this authors the smallest font that can
# prove the pipeline: one glyph mapped from 'A', built table-by-table by hand
# the way the MV image fixtures in canvas_test.rb are (raw bytes, no
# generator dependency) -- see 3rd/stb/stb_truetype.h's
# stbtt_InitFont_internal for the required table set.
module MZFontFixture
  def self.u8(n)
    (n & 0xff).chr
  end

  def self.u16(n)
    ((n >> 8) & 0xff).chr + (n & 0xff).chr
  end

  def self.u32(n)
    ((n >> 24) & 0xff).chr + ((n >> 16) & 0xff).chr + ((n >> 8) & 0xff).chr +
      (n & 0xff).chr
  end

  # sfnt/WOFF tables are 4-byte aligned; padding beyond a table's real
  # (unpadded) length is what its directory entry's length field omits.
  def self.pad4(s)
    s + ("\x00" * ((4 - s.bytesize % 4) % 4))
  end

  # glyph 0 (.notdef) is the empty glyph; glyph 1 is a filled square, wound as
  # a single closed contour of on-curve points so it rasterises as solid ink
  # with no quadratic curve handling needed.
  def self.glyf
    g = u16(1)                                    # numberOfContours = 1
    g += u16(100) + u16(100) + u16(700) + u16(700) # xMin,yMin,xMax,yMax
    g += u16(3)                                    # endPtsOfContours[0]
    g += u16(0)                                    # instructionLength
    g += u8(1) * 4                                 # flags: on-curve, full deltas
    g += u16(100) + u16(600) + u16(0) + u16(-600)  # x deltas (a 600x600 box)
    g += u16(100) + u16(0) + u16(600) + u16(0)      # y deltas
    pad4(g)
  end

  # `glyf_len` is the (4-byte-aligned) total size of the glyf table, i.e. the
  # offset just past glyph 1 -- glyph 0 (.notdef) is zero-length, so it starts
  # and ends at 0.
  def self.loca(glyf_len)
    u16(0) + u16(0) + u16(glyf_len / 2) # short format: values are offset/2
  end

  def self.head
    h = u32(0x00010000) + u32(0x00010000) + u32(0) + u32(0x5F0F3CF5) + u16(0)
    h += u16(1000)          # unitsPerEm
    h += "\x00" * 16        # created/modified
    h += u16(100) + u16(100) + u16(700) + u16(700) # xMin,yMin,xMax,yMax
    h += u16(0) + u16(8) + u16(2) + u16(0) + u16(0) # ...indexToLocFormat=0 (short)
    h
  end

  def self.hhea
    h = u32(0x00010000)
    h += u16(800) + u16(-200) + u16(0) # ascent,descent,lineGap
    h += u16(800)                      # advanceWidthMax
    h += u16(100) + u16(100) + u16(700) + u16(1) + u16(0) + u16(0)
    h += "\x00" * 8  # reserved
    h += u16(0) + u16(2) # metricDataFormat, numberOfHMetrics (both glyphs)
    h
  end

  def self.hmtx
    u16(200) + u16(0) + u16(800) + u16(100) # glyph0(adv,lsb) glyph1(adv,lsb)
  end

  def self.maxp
    u32(0x00005000) + u16(2) # version 0.5 (only numGlyphs is read); numGlyphs
  end

  def self.cmap
    # Format 6 (trimmed table): codepoint 0x41 ('A') -> glyph 1. Platform 0
    # (Unicode) is accepted regardless of encodingID by stb_truetype.
    sub = u16(6) + u16(12) + u16(0) + u16(0x41) + u16(1) + u16(1)
    c = u16(0) + u16(1)             # version, numTables
    c += u16(0) + u16(3) + u32(12)  # platformID, encodingID, subtable offset
    c + sub
  end

  def self.tables
    glyf_data = glyf
    {"cmap" => cmap, "glyf" => glyf_data, "head" => head, "hhea" => hhea,
     "hmtx" => hmtx, "loca" => loca(glyf_data.bytesize), "maxp" => maxp}
  end

  # A bare sfnt: header + table directory (checksums left 0 -- stb_truetype
  # does not verify them, see woff_to_sfnt's comment) + 4-byte-aligned tables,
  # sorted by tag as woff/sfnt build below both do.
  def self.build_sfnt(tables)
    n = tables.size
    entry_selector = 0
    entry_selector += 1 while (1 << (entry_selector + 1)) <= n
    search_range = (1 << entry_selector) * 16
    range_shift = n * 16 - search_range

    header = u32(0x00010000) + u16(n) + u16(search_range) +
             u16(entry_selector) + u16(range_shift)
    dir = String.new
    data = String.new
    offset = 12 + n * 16
    tables.keys.sort.each do |tag|
      dir += tag + u32(0) + u32(offset) + u32(tables[tag].bytesize)
      padded = pad4(tables[tag])
      data += padded
      offset += padded.bytesize
    end
    header + dir + data
  end

  # The same tables wrapped as WOFF 1.0, every table stored (not deflated) --
  # the "comp_len == orig_len" branch of woff_to_sfnt -- so this fixture needs
  # no zlib dependency of its own.
  def self.build_woff(tables)
    n = tables.size
    dir = String.new
    data = String.new
    offset = 44 + n * 20
    tables.keys.sort.each do |tag|
      bytes = tables[tag]
      dir += tag + u32(offset) + u32(bytes.bytesize) + u32(bytes.bytesize) +
             u32(0)
      padded = pad4(bytes)
      data += padded
      offset += padded.bytesize
    end
    header = "wOFF" + u32(0x00010000) + u32(44 + dir.bytesize + data.bytesize) +
             u16(n) + u16(0) + u32(0) + u16(0) + u16(0) + u32(0) + u32(0) +
             u32(0) + u32(0) + u32(0)
    header + dir + data
  end
end

MZ_TINY_SFNT = MZFontFixture.build_sfnt(MZFontFixture.tables)
MZ_TINY_WOFF = MZFontFixture.build_woff(MZFontFixture.tables)

assert 'MZ tiny-font fixture: the bare sfnt rasterises real ink' do
  # Baseline: the hand-authored sfnt itself (no WOFF unpacking involved) is a
  # font stb_truetype accepts, and 'A' at 24px covers more than a handful of
  # pixels -- proves the fixture itself is sound before trusting it to
  # exercise the unpacker below.
  gw, gh, ink = MV::Font.smoke_test(MZ_TINY_SFNT, 0x41, 24)
  assert_true gw > 0 && gh > 0
  assert_true ink > 50
end

assert 'MZ .woff unpacking: MV::Font.unpack_woff reproduces the sfnt byte-for-byte' do
  # This is the actual WOFF unpacker (woff_to_sfnt in mvcanvas.cxx) round-
  # tripping the tables straight back out, checksum field aside (never
  # verified by stb_truetype either way).
  unpacked = MV::Font.unpack_woff(MZ_TINY_WOFF)
  assert_equal MZ_TINY_SFNT.bytesize, unpacked.bytesize
  assert_equal MZ_TINY_SFNT, unpacked
end

assert 'MZ .woff unpacking: a real MZ-style .woff renders the same glyph ink' do
  # End to end: WOFF bytes in, through woff_to_sfnt, through stb_truetype,
  # to a rasterised glyph -- the path MZ boots through once a font is under
  # fonts/*.woff (see mv_font_smoke_test's comment for why this needs its own
  # entry point rather than going through game_font()).
  sfnt_result = MV::Font.smoke_test(MZ_TINY_SFNT, 0x41, 24)
  woff_result = MV::Font.smoke_test(MZ_TINY_WOFF, 0x41, 24)
  assert_equal sfnt_result, woff_result
  assert_true woff_result[2] > 50
end

assert 'MZ .woff unpacking: MV::Font.smoke_test/unpack_woff reject non-fonts' do
  assert_nil MV::Font.smoke_test("wOF2" + ("\x00" * 40), 0x41, 24) # WOFF2, unsupported
  assert_nil MV::Font.smoke_test("not a font", 0x41, 24)
  assert_nil MV::Font.unpack_woff("wOFF" + ("\x00" * 4)) # too short to hold a table dir
end

# MV::Font.pick's own selection logic (pick_font_from_dir, mvcanvas.cxx) --
# the fix for the real bug docs/TODO.md's M6.3c EgoicAnswers font entry
# describes: a project shipping *two* `.woff` files (its real dialogue font
# plus a separately-subsetted `advanced.numberFontFilename`) had only luck
# deciding which one `readdir()` happened to return first, and the wrong one
# rendered every window's ordinary text with a font missing a `space` glyph
# entirely (a visible box at every word boundary) among other wrong metrics.
# Exercised against real files under a scratch dir with MV::Font.pick directly
# (bypassing both MV::Font.preferred_filename='s global and game_font()'s
# process-lifetime cache, the same reason MV::Font.smoke_test bypasses it) so
# the two-file case has deterministic CI coverage independent of directory
# iteration order, which a bed shipping only one font (every one before this)
# can never exercise regardless of how it is scanned.
assert 'MZ font selection: MV::Font.pick prefers the named file over either candidate' do
  dir = "mvjs_font_pick_fixture"
  begin
    Dir.mkdir(dir) rescue nil
    File.open("#{dir}/NumberFont.woff", "wb") { |f| f.write(MZ_TINY_WOFF) }
    File.open("#{dir}/MainFont.woff", "wb") { |f| f.write(MZ_TINY_WOFF) }

    # No preference named: some usable font wins over none at all -- which
    # one is exactly the pre-existing, order-dependent behaviour this does
    # not try to pin down.
    assert_true %W[#{dir}/NumberFont.woff #{dir}/MainFont.woff]
                .include?(MV::Font.pick(dir))

    # The named file wins outright, regardless of which of the two a bare
    # extension-based scan would have preferred between them.
    assert_equal "#{dir}/MainFont.woff", MV::Font.pick(dir, "MainFont.woff")
    assert_equal "#{dir}/NumberFont.woff",
                 MV::Font.pick(dir, "NumberFont.woff")

    # A name that names nothing present falls back to the pre-existing
    # behaviour rather than coming up empty -- e.g. a project whose
    # `mainFontFilename` and its actual fonts/ dir disagree should still draw
    # with *something* rather than the engine's own default silently
    # replacing every glyph.
    assert_true %W[#{dir}/NumberFont.woff #{dir}/MainFont.woff]
                .include?(MV::Font.pick(dir, "NoSuchFont.woff"))
  ensure
    File.delete("#{dir}/NumberFont.woff") rescue nil
    File.delete("#{dir}/MainFont.woff") rescue nil
    Dir.rmdir(dir) rescue nil
  end
end

assert 'MZ font selection: MV::Font.pick returns nil for an empty or missing dir' do
  assert_nil MV::Font.pick("mvjs_font_pick_fixture_missing_dir")
  dir = "mvjs_font_pick_fixture_empty"
  begin
    Dir.mkdir(dir) rescue nil
    assert_nil MV::Font.pick(dir)
  ensure
    Dir.rmdir(dir) rescue nil
  end
end

assert 'MV::Effekseer.available? tracks the same GLES3-capable backend as MV::GL' do
  # mvefk.cxx compiles its real implementation only where mvgl.cxx's own
  # EGL/GLES2 backend is present *and* the GLES3 header Effekseer's
  # GraphicsDevice.cpp needs is too (see CMakeLists.txt's own comment on why
  # ES3, not ES2) -- so this can be strictly stronger than MV::GL.available?
  # but never weaker.
  if MV::Effekseer.available?
    assert_true MV::GL.available?
  end
end

assert 'MV::Effekseer.smoke_test renders real, visible pixels from a downloaded MZ effect' do
  # Not a synthetic fixture: 91 real, unmodified .efkefc files ship with a
  # real downloaded MZ release under data/labyria (gitignored -- present only
  # on a machine that has actually fetched it, absent in a bare CI checkout),
  # exercising the vendored Effekseer C++ SDK (3rd/effekseer) against content
  # this project did not author. A non-zero result here is the strongest
  # signal mvefk.hxx describes: the file parses, the effect plays and
  # simulates, and the full render pipeline actually puts pixels on screen
  # (not just "ran with no GL error") -- confirming the native GL pipeline
  # renders real particle content end to end.
  #
  # Flash.efkefc specifically (not the smaller HitPhysical.efkefc): tracing
  # through why an earlier pass at this test saw zero lit pixels for
  # HitPhysical found that ALL of that effect's live particles live on a
  # NoneType (no assigned renderer) node -- Effekseer's own
  # InstanceContainer::Draw skips NoneType/Root nodes unconditionally,
  # regardless of RenderingPriority, so that file has no visual output by
  # design, not a rendering bug. Flash.efkefc's Sprite/Ring nodes hold real
  # instances and reliably produce both draw calls and lit pixels, so it is
  # a better fixture for a test whose job is proving the pipeline renders.
  #
  # Relative to this test binary's own working directory (3rd/mruby, where
  # the mruby_test ctest target runs rake from -- see CMakeLists.txt's
  # WORKING_DIRECTORY on that target).
  path = "../../data/labyria/Labyria/effects/Flash.efkefc"
  skip "no such fixture (data/labyria not downloaded)" unless File.exist?(path)
  skip "Effekseer backend unavailable" unless MV::Effekseer.available?

  result = MV::Effekseer.smoke_test(path)
  assert_true !result.nil?, "smoke_test failed to load/simulate a real effect"
  assert_true result.is_a?(Integer) && result > 0,
              "expected visible pixels from a real effect, got #{result.inspect}"
end

assert 'the Effekseer shim routes a real .efkefc through native simulation, not the synthetic fallback' do
  # The three shim tests above (survives the real call sequence / loads and
  # reports honestly / retires handles) all exercise hand-built fixtures
  # (garbage bytes with the right magic, a bare `{}`, a missing file) that
  # deliberately fail native Effekseer parsing -- proving the shim's
  # *fallback* path (see EFFEKSEER_SHIM_JS's own comment on why that is a
  # strict superset of its old, always-synthetic behavior). This test proves
  # the other half: genuinely real content takes the real, native-backed
  # path instead.
  path = "../../data/labyria/Labyria/effects/Flash.efkefc"
  skip "no such fixture (data/labyria not downloaded)" unless File.exist?(path)
  skip "Effekseer backend unavailable" unless MV::Effekseer.available?

  MV::JS.base_dir = "mvjs_effekseer_native_fixture"
  begin
    Dir.mkdir("mvjs_effekseer_native_fixture") rescue nil
    Dir.mkdir("mvjs_effekseer_native_fixture/effects") rescue nil
    bytes = File.open(path, "rb") { |f| f.read }
    File.open("mvjs_effekseer_native_fixture/effects/Flash.efkefc", "wb") do |f|
      f.write(bytes)
    end

    MV::JS.eval(MZ.effekseer_shim_js)
    MV::JS.eval(
      "globalThis.__ctx4 = effekseer.createContext(); __ctx4.init(); " \
      "globalThis.__effect4 = __ctx4.loadEffect('effects/Flash.efkefc', 1, " \
      "function(){}, function(){});"
    )
    # A real native effect handle (nonzero) -- proof Effekseer::Effect::Create
    # actually parsed this file, unlike the garbage/bogus fixtures above.
    assert_true MV::JS.eval("__effect4._native") != 0

    MV::JS.eval("globalThis.__h4 = __ctx4.play(__effect4, 0, 0, 0);")
    # A real play handle is >= 0 (Effekseer::Handle); the synthetic fallback
    # never sets `_native` on its handle at all.
    assert_true MV::JS.eval("typeof __h4._native === 'number' && __h4._native >= 0")
  ensure
    File.delete("mvjs_effekseer_native_fixture/effects/Flash.efkefc") rescue nil
    Dir.delete("mvjs_effekseer_native_fixture/effects") rescue nil
    Dir.delete("mvjs_effekseer_native_fixture") rescue nil
    MV::JS.base_dir = ""
  end
end

assert 'the Effekseer shim renders real, visible pixels through the exact call sequence Sprite_Animation._render uses (M6.2 addendum 4)' do
  # Everything above proves simulation only: a real .efkefc parses and plays
  # through a real Effekseer::Manager, but nothing before this addendum ever
  # called EffekseerRendererGL::Renderer -- beginDraw/drawHandle/endDraw/
  # setProjectionMatrix/setCameraMatrix were no-ops (see EFFEKSEER_SHIM_JS's
  # history). This test is the pixel-level proof the house style demands
  # (docs/TODO.md's M6.3i: a probe that merely *ran* proves nothing) that the
  # renderer half now actually draws, driven through the *real* WebGL bridge
  # a real game uses -- not mvefk.hxx's own isolated `smoke_test`, which
  # creates its own throwaway mvgl::Context and never touches the JS shim at
  # all.
  #
  # data/EgoicAnswers ships its own copy of MZ's stock "Flash" RTP effect
  # (the same content data/labyria's own Flash.efkefc test fixture uses,
  # confirmed identical in shape while developing this test), so this
  # verification does not depend on data/labyria (absent in most sandboxes)
  # at all.
  path = "../../data/EgoicAnswers/effects/Flash.efkefc"
  skip "no such fixture (data/EgoicAnswers not downloaded)" unless File.exist?(path)
  skip "Effekseer backend unavailable" unless MV::Effekseer.available?
  skip "WebGL backend unavailable" unless MV::GL.available?

  w, h = 200, 200
  MV::JS.base_dir = File.expand_path("../../data/EgoicAnswers", Dir.pwd)
  begin
    MV::JS.eval(MZ.effekseer_shim_js)

    # A real WebGLRenderingContext via the exact same getContext('webgl')
    # path PIXI itself uses (kWebGLPreamble, mvwebgl.cxx) -- not a bespoke
    # test-only context, so this exercises the real handle-resolution
    # `ctx.init(gl)` -> `__mv_efkInit` -> `mv_webgl_make_current` does.
    MV::JS.eval(<<~JS)
      globalThis.__canvas5 = document.createElement('canvas');
      __canvas5.width = #{w}; __canvas5.height = #{h};
      globalThis.__gl5 = __canvas5.getContext('webgl');
    JS
    gl_handle = MV::JS.eval("__gl5.__gl").to_i
    assert_true gl_handle > 0, "getContext('webgl') did not return a real context"

    MV::JS.eval(
      "globalThis.__ctx5 = effekseer.createContext(); __ctx5.init(__gl5);"
    )
    MV::JS.eval(
      "globalThis.__effect5 = __ctx5.loadEffect('effects/Flash.efkefc', 1, " \
      "function(){}, function(){});"
    )
    assert_true MV::JS.eval("__effect5._native") != 0,
                "Flash.efkefc failed to parse natively"

    MV::JS.eval("globalThis.__h5 = __ctx5.play(__effect5, 0, 0, 0);")
    # Sprite_Animation.updateEffectGeometry's own defaults (scale 100%,
    # no rotation) -- exercised for real, not skipped, since a handle that
    # never receives them is not what a real animation sprite does.
    MV::JS.eval(
      "__h5.setLocation(0, 0, 0); __h5.setRotation(0, 0, 0); " \
      "__h5.setScale(1, 1, 1); __h5.setSpeed(1);"
    )
    # SceneManager.updateEffekseer calls update() once per real frame;
    # 15 matches mvefk.hxx's own smoke_test warmup default closely enough to
    # land mid-burst (proven while developing this test: this effect's live
    # instance count is still in the hundreds at this point, not the hollowed
    # -out tail end of the burst).
    15.times { MV::JS.eval("__ctx5.update(1);") }
    assert_true MV::JS.eval("__h5.exists"), "effect finished simulating too soon"

    # PIXI's own renderer.render() clears colour *and* depth at the start of
    # every real frame, before Sprite_Animation (or anything else) ever
    # draws -- this off-screen context has never had a frame rendered into
    # it at all, so this stands in for that. (Found the hard way: without
    # it, an uninitialised depth buffer failed every fragment's depth test
    # and every draw call above visibly executed -- real program, real
    # texture, zero GL errors, GetDrawCallCount() > 0 -- yet the framebuffer
    # never changed. Not a rendering-pipeline bug; a missing per-frame clear
    # this test itself owed, since a real game's PIXI already does it.)
    MV::JS.eval(
      "__gl5.clearColor(0, 0, 0, 1); " \
      "__gl5.clear(__gl5.COLOR_BUFFER_BIT | __gl5.DEPTH_BUFFER_BIT);"
    )

    baseline = RGSS::Bitmap.new(w, h)
    MV::JS.present_gl(baseline, gl_handle)
    base_px = baseline.get_pixel(w / 2, h / 2)

    # Sprite_Animation.setProjectionMatrix/setCameraMatrix's own formulas
    # (rmmz_sprites.js), mirror=false, _viewportSize's real constant (4096),
    # `renderer.view.height` standing in for our own canvas height -- the
    # exact matrices a real playing animation sprite would compute for a
    # canvas this size, not stand-in values.
    p = -(4096.0 / h)
    MV::JS.eval(<<~JS)
      __ctx5.setProjectionMatrix([1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, #{p}, 0, 0, 0, 1]);
      __ctx5.setCameraMatrix([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -10, 1]);
      __ctx5.beginDraw();
      __ctx5.drawHandle(__h5);
      __ctx5.endDraw();
    JS

    drawn = RGSS::Bitmap.new(w, h)
    MV::JS.present_gl(drawn, gl_handle)

    # The cheapest real proof: sample a grid (a full per-pixel walk through
    # get_pixel is slow, matching RGSS.frame_mean's own tradeoff, mrbgems/
    # mruby-rgss/mrblib/lib.rb) and count pixels that differ from the
    # cleared baseline by more than a small tolerance -- the same idiom
    # mvefk.hxx's own smoke_test uses for exactly the same reason.
    lit = 0
    sampled = 0
    y = 0
    while y < h
      x = 0
      while x < w
        c = drawn.get_pixel(x, y)
        if (c.red - base_px.red).abs > 8 || (c.green - base_px.green).abs > 8 ||
           (c.blue - base_px.blue).abs > 8
          lit += 1
        end
        sampled += 1
        x += 2
      end
      y += 2
    end
    assert_true lit > 0,
                "expected real Effekseer content to change the framebuffer " \
                "(sampled #{sampled} pixels, #{lit} differed from the " \
                "cleared baseline)"
  ensure
    MV::JS.base_dir = ""
  end
end
