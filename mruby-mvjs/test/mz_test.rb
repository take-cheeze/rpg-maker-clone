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
