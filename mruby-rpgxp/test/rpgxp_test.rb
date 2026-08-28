# Unit tests for the RPG Maker XP runtime pieces that do not need a display: the
# RGSS data schema's Marshal round-trip (a real game loads these same classes
# through mruby-marshal), the encrypted RGSSAD archive, the script host that runs
# a game's own scripts, and the RGSS standard library the player supplies
# (RPG::Sprite / RPG::Weather / RPG::Cache, Errno). The data layer is also
# smoke-tested against real projects by scripts/rpgxp_testbed_check.rb, and the
# host against them by scripts/rpgxp_script_host_check.rb.
#
# This gem no longer carries a reimplementation of RMXP's default engine (ADR
# 0030), so the tests that covered its title/map/interpreter went with it: what a
# game does is now the game's own scripts' business, and scripts/rpgxp_boot_check
# .bash is what checks they run.

# Some sources touch GAME_DIR when loading assets; the logic under test here
# never does, but define stand-ins so nothing is undefined.
GAME_DIR = "" unless Object.const_defined?(:GAME_DIR)
RTP_DIR = "" unless Object.const_defined?(:RTP_DIR)

assert "RPG schema Marshal round-trip" do
  sys = RPG::System.new
  sys.title_name = "001-Title01"
  sys.windowskin_name = "001-Blue01"
  sys.start_map_id = 1
  sys.start_x = 9
  sys.start_y = 7
  sys.party_members = [1, 2, 7, 8]

  bgm = RPG::AudioFile.new
  bgm.name = "064-Slow07"
  bgm.volume = 80
  bgm.pitch = 100
  sys.title_bgm = bgm

  words = RPG::System::Words.new
  words.gold = "G"
  words.hp = "HP"
  sys.words = words

  loaded = Marshal.load(Marshal.dump(sys))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "001-Title01", loaded.title_name
  assert_equal [1, 2, 7, 8], loaded.party_members
  assert_equal 1, loaded.start_map_id
  assert_true loaded.title_bgm.is_a?(RPG::AudioFile)
  assert_equal "064-Slow07", loaded.title_bgm.name
  assert_equal 80, loaded.title_bgm.volume
  assert_true loaded.words.is_a?(RPG::System::Words)
  assert_equal "G", loaded.words.gold
end

assert "RPG::Map + Table Marshal round-trip" do
  map = RPG::Map.new
  map.width = 2
  map.height = 2
  map.tileset_id = 1
  data = Table.new(2, 2, 3)
  data[0, 0, 0] = 384
  data[1, 1, 2] = 400
  map.data = data
  map.events = {}

  loaded = Marshal.load(Marshal.dump(map))
  assert_equal 2, loaded.width
  assert_true loaded.data.is_a?(Table)
  assert_equal 384, loaded.data[0, 0, 0]
  assert_equal 400, loaded.data[1, 1, 2]
  assert_equal 0, loaded.data[1, 0, 0]
end

assert "RGSSAD v1 round-trips entries (names, binary data, key advances)" do
  files = [
    ["Data\\System.rxdata", "sys\x00\x01\xfe\xff data"],
    ["Data\\Map001.rxdata", (("A".."Z").to_a.join) * 100], # spans 4-byte key steps
    ["Graphics\\Titles\\001-Title01.png", "\x89PNG\r\n\x1a\n"]
  ]
  archive = RPGXP::RGSSAD.pack_v1(files)
  a = RPGXP::RGSSAD.new(archive)

  assert_equal 1, a.version
  assert_equal 3, a.names.size
  files.each do |name, data|
    # Compare bytes so the check is encoding-agnostic (mruby strings are bytes;
    # CRuby would otherwise flag a binary vs UTF-8 literal mismatch).
    assert_equal data.bytes, a.read(name).bytes
  end
  # '/'-style lookups normalise to the archive's '\' names.
  assert_equal files[0][1].bytes, a.read("Data/System.rxdata").bytes
  assert_true a.include?("Data/Map001.rxdata")
  assert_false a.include?("Data/Missing.rxdata")
  assert_true a.read("Data/Missing.rxdata").nil?
end

assert "RGSSAD carries real Marshal data through the archive" do
  sys = RPG::System.new
  sys.title_name = "001-Title01"
  sys.start_map_id = 7
  blob = Marshal.dump(sys)

  a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.pack_v1([["Data\\System.rxdata", blob]]))
  loaded = Marshal.load(a.read("Data\\System.rxdata"))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "001-Title01", loaded.title_name
  assert_equal 7, loaded.start_map_id
end

assert "RGSSAD rejects a bad header and an unsupported version" do
  assert_raise(RuntimeError) { RPGXP::RGSSAD.new("NOTRGSS\x01") }
  # An unknown version (only 1 and 3 are supported) is rejected.
  v4 = "RGSSAD\x00\x04rest"
  assert_raise(RuntimeError) { RPGXP::RGSSAD.new(v4) }
end

assert "RGSSAD v3 (.rgss3a) round-trips entries" do
  files = [
    ["Data\\System.rxdata", "sys\x00\x01\xfe\xff data"],
    ["Data\\Map001.rxdata", (("A".."Z").to_a.join) * 100], # spans 4-byte key steps
    ["Graphics\\Titles\\001-Title01.png", "\x89PNG\r\n\x1a\n"]
  ]
  archive = RPGXP::RGSSAD.pack_v3(files)
  a = RPGXP::RGSSAD.new(archive)

  assert_equal 3, a.version
  assert_equal 3, a.names.size
  files.each do |name, data|
    assert_equal data.bytes, a.read(name).bytes
  end
  # '/'-style lookups normalise to the archive's '\' names.
  assert_equal files[0][1].bytes, a.read("Data/System.rxdata").bytes
  assert_true a.include?("Data/Map001.rxdata")
  assert_false a.include?("Data/Missing.rxdata")
  assert_true a.read("Data/Missing.rxdata").nil?
end

assert "RGSSAD v3 carries real Marshal data through the archive" do
  sys = RPG::System.new
  sys.title_name = "001-Title01"
  sys.start_map_id = 7
  blob = Marshal.dump(sys)

  a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.pack_v3([["Data\\System.rxdata", blob]]))
  loaded = Marshal.load(a.read("Data\\System.rxdata"))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "001-Title01", loaded.title_name
  assert_equal 7, loaded.start_map_id
end

# An entry larger than mruby's array-length cap (MRB_ARY_LENGTH_MAX, 131072) must
# still pack and read back byte-for-byte: real games ship maps, Animations.rxdata
# and graphics well past that, and accumulating one integer per byte used to
# overflow the Array. Build the payload with String#* (not a big Array literal,
# which would hit the same cap here) and compare with == / bytesize so the check
# itself never materialises an over-cap Array.
assert "RGSSAD round-trips an entry larger than the mruby array cap" do
  pattern = (0..255).to_a.pack("C*")           # 256 bytes, every value
  big = pattern * 900                            # 230400 bytes, over the cap
  assert_true big.bytesize > 131072
  [:pack_v1, :pack_v3].each do |packer|
    files = [
      ["Data\\Small.rxdata", "hi\x00\xff"],
      ["Data\\Big.rxdata", big]
    ]
    a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.send(packer, files))
    got = a.read("Data\\Big.rxdata")
    assert_equal big.bytesize, got.bytesize
    assert_true big == got
    assert_equal "hi\x00\xff".bytes, a.read("Data\\Small.rxdata").bytes
  end
end

# The whole point of the archive for a released game: its Graphics/ tree is in
# there too, and `Cache.*` asks for those by name through Bitmap.new. mruby-rgss
# covers its half against a stand-in archive; this is the end-to-end one, a real
# packed archive decoded into a real Bitmap, for both archive versions.
#
# The picture is the 3x2 XYZ used in mruby-rgss's loader tests: palette
# 0 = (10,20,30), 1 = red, 2 = green. Note the entry name uses RGSSAD's native
# '\' separators while the lookup uses '/', which is how a game spells it.
assert "a packed graphic loads into a Bitmap through RGSS.asset_archive" do
  xyz = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
        "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
        "\x8b\x02\x41"
  [:pack_v1, :pack_v3].each do |packer|
    files = [
      ["Data\\System.rxdata", Marshal.dump([1, 2, 3])],
      ["Graphics\\Titles\\Castle.xyz", xyz]
    ]
    a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.send(packer, files))
    RGSS.asset_archive = a
    begin
      # No loose file anywhere: this can only have come out of the archive, and
      # only by trying the ".xyz" candidate against the bare name the game uses.
      b = RGSS::Bitmap.new("Graphics/Titles/Castle")
      assert_equal 3, b.width, "#{packer}: width"
      assert_equal 2, b.height, "#{packer}: height"
      assert_equal 10.0, b.get_pixel(0, 0).red, "#{packer}: pixel"
      assert_equal 255.0, b.get_pixel(2, 0).green, "#{packer}: pixel"
      # The data entries still read back, so registering the archive for assets
      # has not disturbed what it was already doing.
      assert_equal [1, 2, 3], Marshal.load(a.read("Data/System.rxdata"))
    ensure
      RGSS.asset_archive = nil
    end
  end
end

# The same for audio, which a release packs alongside its graphics. Whether the
# bytes then reach the mixer is native and needs a real audio device — that is
# the `audio_probe` ctest. What this pins is that a game's bare track name finds
# the entry and arrives *decrypted*, through a real archive of both versions.
assert "a packed track plays through RGSS.asset_archive" do
  wav = "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00" \
        "\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x00\x00\x00\x00"
  [:pack_v1, :pack_v3].each do |packer|
    files = [
      ["Data\\System.rxdata", Marshal.dump([1, 2, 3])],
      ["Audio\\BGM\\Theme1.wav", wav]
    ]
    a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.send(packer, files))
    class << RGSS::Audio
      alias _bgm_play_mem_orig3 _bgm_play_mem
      alias _can_play_mem_orig3 _can_play_mem?
      def _bgm_play_mem(name, bytes, volume, pitch, pos = 0, fadein = 0)
        $audio_arch_capture = [name, bytes, volume, pitch, pos, fadein]
        nil
      end
      # The test binary installs no audio backend; pretend one is there so the
      # lookup is what is being measured.
      def _can_play_mem? = true
    end
    RGSS.asset_archive = a
    begin
      $audio_arch_capture = nil
      # No folder, no extension — how the database names a track.
      RGSS::Audio.bgm_play("Theme1", 70, 100)
      assert_false $audio_arch_capture.nil?, "#{packer}: packed BGM did not play"
      assert_equal "Audio/BGM/Theme1.wav", $audio_arch_capture[0]
      # Byte-for-byte through the encryption, or no decoder would take it.
      assert_equal wav.bytes, $audio_arch_capture[1].bytes
      assert_equal 70, $audio_arch_capture[2]
    ensure
      RGSS.asset_archive = nil
      class << RGSS::Audio
        alias _bgm_play_mem _bgm_play_mem_orig3
        alias _can_play_mem? _can_play_mem_orig3
      end
    end
  end
end

# Fake project DB for the script host: serves pre-decoded [name, source]
# sections and answers the Kernel built-ins load_data / save_data out of an
# in-memory store, so a save round-trips through the same instance.
class FakeScriptDB
  def initialize(sections)
    @sections = sections
    @store = {}
  end

  def scripts?; !@sections.empty?; end
  def scripts;  @sections; end
  def read_object(path); @store[path]; end
  def save_object(obj, path); @store[path] = obj; end
end

assert "ScriptHost.run evaluates sections in order and sets $RGSS_SCRIPTS" do
  db = FakeScriptDB.new([
    ["Setup", "$rgss_host_probe = 41"],
    ["Main", "$rgss_host_probe += 1"]
  ])
  assert_true RPGXP::ScriptHost.run(db)
  assert_equal 42, $rgss_host_probe
  # $RGSS_SCRIPTS mirrors RGSS's [id, name, source] triples in load order.
  assert_equal 2, $RGSS_SCRIPTS.size
  assert_equal 0, $RGSS_SCRIPTS[0][0]
  assert_equal "Setup", $RGSS_SCRIPTS[0][1]
  assert_equal "Main", $RGSS_SCRIPTS[1][1]
end

assert "ScriptHost.run defines classes at the top level" do
  db = FakeScriptDB.new([["Def", "class RgssHostProbe; def hi; 7; end; end"]])
  assert_true RPGXP::ScriptHost.run(db)
  assert_true Object.const_defined?(:RgssHostProbe)
  assert_equal 7, RgssHostProbe.new.hi
end

assert "ScriptHost.run returns false when the project ships no scripts" do
  assert_false RPGXP::ScriptHost.run(FakeScriptDB.new([]))
end

# current_scene is what every probe (move/menu/battle/save) and report_scene
# key on to see the game's own scene. A real VX Ace release's full script
# bundle never assigns `$scene` at all (RGSS3 replaced it with `SceneManager`,
# see the method's own comment) -- confirmed against a real downloaded VX Ace
# game's 213-section bundle, which left every probe silently inert (the game
# ran and rendered fine; `$scene` alone just never went non-nil).
assert "ScriptHost.current_scene reads $scene first, when set (XP/VX)" do
  previous = $scene
  begin
    $scene = "fake XP/VX scene"
    assert_equal "fake XP/VX scene", RPGXP::ScriptHost.current_scene
  ensure
    $scene = previous
  end
end

assert "ScriptHost.current_scene falls back to SceneManager.scene (VX Ace)" do
  previous_scene = $scene
  had_scene_manager = Object.const_defined?(:SceneManager)
  previous_scene_manager = had_scene_manager ? SceneManager : nil
  begin
    $scene = nil
    fake_manager = Object.new
    def fake_manager.scene
      "fake VX Ace scene"
    end
    Object.const_set(:SceneManager, fake_manager)
    assert_equal "fake VX Ace scene", RPGXP::ScriptHost.current_scene
  ensure
    $scene = previous_scene
    Object.send(:remove_const, :SceneManager) if Object.const_defined?(:SceneManager)
    Object.const_set(:SceneManager, previous_scene_manager) if had_scene_manager
  end
end

assert "ScriptHost.current_scene is nil with neither $scene nor SceneManager" do
  previous_scene = $scene
  had_scene_manager = Object.const_defined?(:SceneManager)
  previous_scene_manager = had_scene_manager ? SceneManager : nil
  begin
    $scene = nil
    Object.send(:remove_const, :SceneManager) if had_scene_manager
    assert_nil RPGXP::ScriptHost.current_scene
  ensure
    $scene = previous_scene
    Object.const_set(:SceneManager, previous_scene_manager) if had_scene_manager
  end
end

# The RGSS standard library (mrblib/rgss_library.rb) — the classes RGSS104E.dll
# supplies and no project ships. These tests run in the *built* engine, where
# RPG::Sprite really does subclass the native RGSS::Sprite; they are what would
# catch the library being dropped from the gem's rbfiles, or a native base class
# losing a method it is built on. Sprite/Viewport instances need a live display
# the headless test binary lacks (see mruby-rgss's own tests), so the behaviour
# of the effects is checked against fakes in scripts/rpgxp_script_host_check.rb
# and what is pinned here is the shape a game's scripts subclass.
assert "RPG::Sprite is the native Sprite plus the RGSS effect surface" do
  assert_equal RGSS::Sprite, RPG::Sprite.superclass
  methods = RPG::Sprite.instance_methods
  # Everything Sprite_Battler and Sprite_Character call on their superclass.
  %i[whiten appear escape collapse damage animation loop_animation
     blink_on blink_off blink? effect? update dispose].each do |name|
    assert_true methods.include?(name), "RPG::Sprite##{name} missing"
  end
end

# Errno, which mruby does not ship and every RGSS game's "Main" names:
#
#   begin ... $scene.main while $scene != nil ... rescue Errno::ENOENT
#
# A rescue clause is evaluated when an exception passes through it, so without
# the constant *any* exception leaving a game's main loop became
# "NameError: uninitialized constant Errno" — the boot check caught exactly that
# on a released game, where the ordinary end-of-run timeout was rewritten into a
# crash. What matters is that a foreign exception passes through the clause.
assert "Errno::ENOENT exists so a game's `rescue Errno::ENOENT` resolves" do
  assert_true Object.const_defined?(:Errno), "Errno missing"
  assert_true Errno::ENOENT.ancestors.include?(StandardError)
  # RGSS's message shape: the stock Main strips the prefix to name the file.
  assert_equal "No such file or directory - Data/Foo.rxdata",
               Errno::ENOENT.new("Data/Foo.rxdata").message
  passed_through = false
  begin
    begin
      raise "not a file error"
    rescue Errno::ENOENT
      # Unreachable — and before Errno existed, getting here raised NameError.
    end
  rescue StandardError => e
    passed_through = e.message == "not a file error"
  end
  assert_true passed_through, "a foreign exception did not survive the rescue clause"
end

# Module#private_method_defined? / #protected_method_defined? /
# #public_method_defined?, filled in from mruby-metaprog's existing
# private_instance_methods/protected_instance_methods/public_instance_methods
# (a real answer, not a stub -- see the comment above `class Module` in
# rgss_library.rb).
assert "Module visibility-filtered method_defined? variants answer correctly" do
  m = Module.new
  m.module_eval do
    def pub_m; end
    private def priv_m; end
    protected def prot_m; end
  end

  assert_true m.public_method_defined?(:pub_m)
  assert_false m.public_method_defined?(:priv_m)
  assert_false m.public_method_defined?(:prot_m)

  assert_true m.private_method_defined?(:priv_m)
  assert_false m.private_method_defined?(:pub_m)
  assert_false m.private_method_defined?(:prot_m)

  assert_true m.protected_method_defined?(:prot_m)
  assert_false m.protected_method_defined?(:pub_m)
  assert_false m.protected_method_defined?(:priv_m)

  assert_false m.private_method_defined?(:nope)
end

# Bare (argument-less) module_function -- CRuby's "declaration mode", where
# every `def` that follows in the same scope becomes both a private instance
# method and a public singleton method. Reimplemented via method_added (see
# the comment above `class Module` / `alias_method :__mrb_native_module_
# function` in rgss_library.rb, next to the private_method_defined? fix
# above); the explicit-argument form (module_function :name) is native and
# unchanged. A real bundled error-log utility script defines its entire
# public surface (only ever reachable as `TKG::ErrorLog.save(...)`) this way.
assert "bare module_function promotes subsequent defs to singleton methods" do
  m = Module.new
  m.module_eval do
    module_function
    def foo(x); x * 2; end
    def bar(x); x * 3; end
    public
    def baz(x); x * 4; end
  end

  assert_equal 6, m.foo(3)
  assert_equal 9, m.bar(3)
  # `public` (bare) ends the module_function declaration, same as in CRuby --
  # baz is an ordinary instance method, not reachable on the module itself.
  assert_false m.respond_to?(:baz), "baz should not have become a module function"
  assert_true m.respond_to?(:foo)
  # module_function's own explicit-argument form still keeps working.
  n = Module.new
  n.module_eval { def qux(x); x + 1; end; module_function :qux }
  assert_equal 6, n.qux(5)
end

# Win32API: real games bind Windows-only DLL calls unconditionally at script
# load time (a very common pattern for an *optional* feature, e.g. CACAO's
# widely bundled screenshot-saving utility binds MultiByteToWideChar/
# FindWindow/BitBlt/... just by being included in a project). There is no
# real Win32 to call into on this engine's targets (also Linux/PSP/wasm), so
# construction must not raise -- only #call is reached if the game actually
# tries to use the feature, and even then it degrades to a warning + 0 rather
# than ending the whole script host over an optional Windows integration.
assert "Win32API binds without raising and #call degrades to a warning" do
  api = Win32API.new("user32", "FindWindow", "pp", "l")
  assert_equal 0, api.call("class", "title")
end

# String#encode: this mruby build has no real transcoding tables, but a
# Japanese project's scripts routinely call it at a boundary this engine
# never observes (e.g. the same screenshot utility encodes a window title
# before handing it to the now-inert Win32API FindWindow above). Answering
# the receiver unchanged, rather than raising, is what keeps that boundary
# from ending the whole script host.
assert "String#encode is a no-op that does not raise" do
  assert_equal "hello", "hello".encode("SHIFT_JIS")
end

assert "RPG::Weather offers the surface Spriteset_Map drives" do
  methods = RPG::Weather.instance_methods
  %i[type= max= ox= oy= update dispose type max ox oy].each do |name|
    assert_true methods.include?(name), "RPG::Weather##{name} missing"
  end
end

# RPG::Cache is the one part that runs headlessly: it only builds Bitmaps.
assert "RPG::Cache caches by path and stands in for what will not load" do
  RPG::Cache.clear
  # Nothing on disk under this name, and RGSS would raise; the cache reports it
  # and hands back a blank so a missing RTP cannot end a boot.
  missing = RPG::Cache.picture("NoSuchPictureHere")
  assert_equal 32, missing.width
  assert_equal 32, missing.height
  # An empty name is RGSS's own "no graphic", also a blank.
  assert_equal 32, RPG::Cache.character("", 0).width
  # Same path, same object — a map redrawing its charsets every frame must not
  # reload them.
  assert_true RPG::Cache.picture("NoSuchPictureHere").equal?(missing)
  RPG::Cache.clear
  assert_false RPG::Cache.picture("NoSuchPictureHere").equal?(missing)
end

# The host is the default boot path (ADR 0029): with neither the native binary's
# RGSS_SCRIPT_HOST constant nor an opt-out in the environment, enabled? is true.
# This runs in the *built* engine, which is where a divergence between the CRuby
# harness and mruby would show — including ENV being absent here, which must
# still leave the host on rather than raise.
assert "ScriptHost.enabled? defaults on" do
  assert_true RPGXP::ScriptHost.enabled?
  # The opt-out list the native runtime mirrors (src/main.cxx) — kept in the
  # test so a spelling cannot silently drop out of one side.
  assert_equal ["0", "false", "off", "no"], RPGXP::ScriptHost::DISABLED_VALUES
  assert_equal "RGSS_SCRIPT_HOST", RPGXP::ScriptHost::ENABLED_ENV
end

# The environment channel, when this build has an ENV to read (the native binary
# resolves the variable in C++ instead — see enabled?).
assert "ScriptHost.enabled? honours the RGSS_SCRIPT_HOST opt-out in ENV" do
  skip "no ENV in this build" unless Object.const_defined?(:ENV)
  previous = ENV[RPGXP::ScriptHost::ENABLED_ENV]
  begin
    ENV[RPGXP::ScriptHost::ENABLED_ENV] = ""      # unset, as a plain boot is
    assert_true RPGXP::ScriptHost.enabled?
    RPGXP::ScriptHost::DISABLED_VALUES.each do |off|
      ENV[RPGXP::ScriptHost::ENABLED_ENV] = off
      assert_false RPGXP::ScriptHost.enabled?, "#{off.inspect} should disable the host"
    end
    ENV[RPGXP::ScriptHost::ENABLED_ENV] = "1"
    assert_true RPGXP::ScriptHost.enabled?
  ensure
    ENV[RPGXP::ScriptHost::ENABLED_ENV] = previous.nil? ? "" : previous
  end
end

assert "ScriptHost.install_kernel wires load_data / save_data round-trip" do
  db = FakeScriptDB.new([["x", "0"]])
  RPGXP::ScriptHost.install_kernel(db)
  # The built-ins are private Kernel methods (RGSS scripts call them bare);
  # save then load of a fresh path round-trips through the bound database.
  probe = Object.new
  probe.send(:save_data, { "hp" => 30 }, "ScriptHostProbe.rxdata")
  assert_equal({ "hp" => 30 }, probe.send(:load_data, "ScriptHostProbe.rxdata"))
end

# The RGSS script host needs Kernel#sprintf / #format / String#% (mruby-sprintf)
# to run the stock scripts that format numbers; confirm the gem is linked into
# the build and the integer/string specs the scripts use produce the right text.
assert "Kernel#sprintf / #format / String#% are available for the script host" do
  assert_equal "05", sprintf("%02d", 5)
  assert_equal "id=007", format("id=%03d", 7)
  assert_equal "0007", ("%0*d" % [4, 7])   # dynamic width, as the clock uses
  assert_equal "+5", sprintf("%+d", 5)
  assert_equal "S [0012-3456]", sprintf("S [%04d-%04d]", 12, 3456)
  assert_equal "  hi", ("%4s" % "hi")
end

# The script host evals the game's scripts, runs their blocking Main inside a
# Fiber (ADR 0023) and ends the game when one calls `exit` (raised as a catchable
# SystemExit). Confirm all three gems are linked into the build — without
# invoking `exit`, which would terminate the test runner.
# Kernel#Integer(), from mruby-kernel-ext. Every RGSS game clamps its battler
# stats through it — `n = [[Integer(n), 1].max, 999999].min` in Game_Battler_1,
# which runs the moment a party member is built — so a missing one does not
# surface until a player presses New Game. The gem is declared in
# build_config.rb and depended on in mrbgem.rake; this is what makes its absence
# fail here instead of in a booted game.
assert "Kernel#Integer is available for the script host" do
  assert_equal 7, Integer(7)
  assert_equal 7, Integer("7")
  assert_equal 0, Integer(0)
  # The stock clamp is `[[Integer(n), 1].max, 999999].min`, which is what a
  # game's maxhp= setter runs.
  assert_equal 999999, [[Integer(1_000_000), 1].max, 999999].min
  assert_equal 1, [[Integer(-5), 1].max, 999999].min
end

# The Math module, from mruby-math. `Game_Character#jump` is stock RMXP and
# sizes its arc with `Math.sqrt(x_plus * x_plus + y_plus * y_plus).round`, so the
# first jump in any game — an event's move route, a "Jump" command — needs it.
# Its absence surfaced only in a booted game (Pray for You's opening jumps an
# event), which is what this test exists to move forward.
assert "Math is available for the script host" do
  assert_true Object.const_defined?(:Math), "Math missing (mruby-math)"
  # The stock jump, for a two-tile diagonal hop.
  assert_equal 3, Math.sqrt(2 * 2 + 2 * 2).round
  assert_equal 1, Math.sqrt(1 * 1 + 0 * 0).round
  assert_equal 0, Math.sqrt(0).round
end

# Time, from mruby-time. The stock `Scene_Load` seeds its "newest save" search
# with `Time.at(0)` and `Window_SaveFile` stamps each slot with `File#mtime`,
# which answers a Time — so every game's save and load screens need the gem. It
# is only a *test* dependency of mruby-io, so it does not arrive with it.
assert "Time is available for the script host" do
  assert_true Object.const_defined?(:Time), "Time missing (mruby-time)"
  epoch = Time.at(0)
  assert_equal 0, epoch.to_i
  # The comparison Scene_Load makes against each slot's mtime.
  assert_true Time.at(1) > epoch
end

# strftime, filled in above in rgss_library.rb (mruby-time has no such method
# — see the comment on `class Time` there). A real bundled utility script
# (an error logger) formats both a save filename and a log line with it.
assert "Time#strftime covers the directives real scripts use" do
  # 2024-03-05 09:07:03 UTC, a Tuesday (picked so month/day/hour/minute/second
  # are all distinguishable from each other and none needs padding dropped).
  t = Time.utc(2024, 3, 5, 9, 7, 3)
  assert_equal "20240305090703", t.strftime("%Y%m%d%H%M%S")
  assert_equal "2024-03-05T09:07:03", t.strftime("%Y-%m-%dT%H:%M:%S")
  assert_equal "24", t.strftime("%y")
  assert_equal "Tue", t.strftime("%a")
  assert_equal "Tuesday", t.strftime("%A")
  assert_equal "Mar", t.strftime("%b")
  assert_equal "March", t.strftime("%B")
  assert_equal "AM", t.strftime("%p")
  assert_equal "09:07:03", t.strftime("%T")
  assert_equal "2024-03-05", t.strftime("%F")
  assert_equal "100%done", t.strftime("100%%done")
  # An unrecognised directive passes through literally rather than raising.
  assert_equal "%Q", t.strftime("%Q")
end

assert "eval, Fiber and Kernel#exit / SystemExit are available for the script host" do
  # mruby-eval is what makes the whole host possible; script_host.rb calls
  # Kernel#eval unconditionally because this gem is a hard dependency
  # (mruby-rpgxp/mrbgem.rake), so its absence has to fail here rather than at the
  # first booted game.
  assert_true Kernel.method_defined?(:eval), "Kernel#eval missing (mruby-eval)"
  assert_true Object.const_defined?(:Fiber), "Fiber missing (mruby-fiber)"
  # mruby-exit defines Kernel#exit (a private method) alongside SystemExit;
  # rgss_library.rb fills in Module#private_method_defined? (this mruby build
  # has no such gem), so this can check the private method directly, not just
  # the constant's presence.
  assert_true Object.const_defined?(:SystemExit),
              "SystemExit / Kernel#exit missing (mruby-exit)"
  assert_true Kernel.private_method_defined?(:exit),
              "Kernel#exit missing or not private (mruby-exit)"
  # A Fiber round-trips a value through yield/resume, the mechanism the driver
  # relies on to advance one frame per resume.
  f = Fiber.new { Fiber.yield(:frame); :done }
  assert_equal :frame, f.resume
  assert_equal :done, f.resume
end

assert "Dir.glob covers the patterns real scripts use for save/protect checks" do
  root = "tmp_rgss_glob_test"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    ["Save01.rvdata2", "Save02.rvdata2", "SaveOption.rvdata2",
     "Other.txt"].each do |name|
      File.open("#{root}/#{name}", "w") { |f| f.print "x" }
    end
    Dir.mkdir("#{root}/Data") unless FileTest.directory?("#{root}/Data")
    ["Map001.rvdata2", "Map012.rvdata2", "System.rvdata2"].each do |name|
      File.open("#{root}/Data/#{name}", "w") { |f| f.print "x" }
    end

    # Literal name, no wildcard: matches iff the file exists (the released-game
    # packed-archive check's shape, `Dir.glob('Game.rgss3a').empty?`).
    assert_equal ["#{root}/SaveOption.rvdata2"],
                  Dir.glob("#{root}/SaveOption.rvdata2")
    assert_equal [], Dir.glob("#{root}/NoSuchFile.rvdata2")

    # `*` wildcard: DataManager's own continue-screen check, `Dir.glob('Save0*
    # .rvdata2')`.
    assert_equal ["#{root}/Save01.rvdata2", "#{root}/Save02.rvdata2"],
                  Dir.glob("#{root}/Save0*.rvdata2").sort

    # `[0-9]` character class combined with `*`, spanning a literal directory
    # prefix: an event-log utility's own `Dir.glob("Data/Map[0-9]*[0-9]
    # .rvdata2")`.
    assert_equal ["#{root}/Data/Map001.rvdata2", "#{root}/Data/Map012.rvdata2"],
                  Dir.glob("#{root}/Data/Map[0-9]*[0-9].rvdata2").sort

    # Block form returns nil and yields each match, like real Dir.glob.
    seen = []
    result = Dir.glob("#{root}/Save0*.rvdata2") { |path| seen << path }
    assert_true result.nil?
    assert_equal ["#{root}/Save01.rvdata2", "#{root}/Save02.rvdata2"], seen.sort
  ensure
    ["Save01.rvdata2", "Save02.rvdata2", "SaveOption.rvdata2",
     "Other.txt"].each { |name| File.delete("#{root}/#{name}") }
    ["Map001.rvdata2", "Map012.rvdata2", "System.rvdata2"].each do |name|
      File.delete("#{root}/Data/#{name}")
    end
    Dir.delete("#{root}/Data")
    Dir.delete(root)
  end
end

# Real RGSS documents this constructor -- scripts synthesize new event
# commands with it directly. EventCommand had no #initialize at all
# (Object's own default takes zero arguments), so the 3-argument form
# real scripts call raised ArgumentError.
assert "RPG::EventCommand.new takes the real code/indent/parameters constructor" do
  cmd = RPG::EventCommand.new(355, 2, ["@commonevent_id = 7"])
  assert_equal 355, cmd.code
  assert_equal 2, cmd.indent
  assert_equal ["@commonevent_id = 7"], cmd.parameters

  defaulted = RPG::EventCommand.new
  assert_equal 0, defaulted.code
  assert_equal 0, defaulted.indent
  assert_equal [], defaulted.parameters
end
