# RPG Maker XP runtime.
#
# Boots an RMXP project: reads Game.ini, loads the Data/*.rxdata database
# (see rgss_data.rb) and drives a scene stack, mirroring how the RPG2000 side
# (mruby-rpg2k) boots from an LCF database. XP games ship their whole engine as
# Ruby scripts inside Data/Scripts.rxdata; running those unmodified is a large
# future milestone (see docs/adr/0009-rpgxp-rgss-data-layer.md and docs/TODO.md).
# This layer instead reimplements the default title/map flow directly against the
# database, the same staged approach the RPG2000 runtime took.

# So the scenes can use the bare RGSS names (Bitmap, Sprite, Viewport, Input,
# Audio, ...) — and so Marshal resolves the value types Table/Color/Tone/Rect —
# pull RGSS into the top-level namespace, as the RPG2000 runtime does.
class Object
  include RGSS
end

# The RGSS value types appear in RMXP `.rxdata` streams under their bare names
# (Table/Color/Tone/Rect) — the editor serialises them from a top-level Ruby
# where that is their class path. mruby-marshal resolves a marshaled class by an
# absolute path lookup from Object, so bind the native RGSS classes as real
# top-level constants (not merely visible through the `include` above) so those
# streams load regardless of how the resolver treats included-module constants.
Table = RGSS::Table
Color = RGSS::Color
Tone = RGSS::Tone
Rect = RGSS::Rect

class RPGXP
  # RPG Maker XP renders at 640x480. src/main.cxx sizes the window to match when
  # an XP project is detected and the size is not overridden on the command line.
  WIDTH = 640
  HEIGHT = 480
  TILE = 32

  def initialize(_args)
    @title = read_ini_title
    @db = RGSSData.new(GAME_DIR)
    # A packed release holds its Graphics/ and Audio/ trees in the same archive
    # as its Data/, and assets are asked for by name from deep inside the game's
    # own scripts, so the loaders need it globally (see RGSS.asset_archive).
    RGSS.asset_archive = @db.archive
    @scenes = []
    # When the script host is enabled and the project ships its scripts, the
    # game's own Ruby drives everything (see script_host.rb); skip building the
    # built-in title scene, which #start would otherwise run instead.
    @use_script_host = ScriptHost.enabled? && @db.scripts?
    if @use_script_host
      # The scripts own their whole blocking main loop; drive it one frame at a
      # time through a Fiber so the web build's per-frame callback still gets
      # control back each frame (docs/adr/0023-rpgxp-script-host-frame-driver.md).
      setup_script_host_driver
    else
      push Scene::Title.new(self)
    end
  end

  attr_reader :db, :title

  def push(scene)
    @scenes.push scene
  end

  def pop
    return if @scenes.size <= 1
    scene = @scenes.pop
    scene.dispose if scene.respond_to?(:dispose)
  end

  # Tear everything down and return to a fresh title screen.
  def return_to_title
    @scenes.each { |s| s.dispose if s.respond_to?(:dispose) }
    @scenes = [Scene::Title.new(self)]
  end

  # New Game: build the initial party from System.party_members, read the start
  # position from System and enter the map scene. A data problem is reported and
  # leaves the title intact rather than crashing to a blank screen.
  def start_new_game
    sys = @db.system
    state = Game::State.new(@db, sys.party_members, sys.start_map_id,
                            sys.start_x, sys.start_y)
    state.map = @db.load_map(state.map_id)
    scene = Scene::Map.new(self, state)
    @scenes.last.dispose
    @scenes = [scene]
    # A machine-readable marker so a headless run (see --rpgxp_new_game,
    # scripts/rpgxp_boot_check.bash and scripts/compare-rpgxp-wine.bash) can
    # assert the map scene was really reached, not just the title.
    $stderr.puts "[RPGXP-MAP] map=#{state.map_id} x=#{state.x} y=#{state.y}"
  rescue StandardError => e
    $stderr.puts "[RGSS] Failed to start new game: #{e.message}"
  end

  # Continue: reload the portable Marshal save (the real RMXP `.rxdata` save
  # format is a later refinement) and resume on its map.
  def continue_game
    unless save_exists?
      RGSS.warn_stub "Continue (no save data found)"
      return
    end
    data = File.open(save_path, "rb") { |f| f.read }
    state = Game::State.load(@db, Marshal.load(data))
    state.map = @db.load_map(state.map_id)
    scene = Scene::Map.new(self, state)
    @scenes.last.dispose
    @scenes = [scene]
  rescue StandardError => e
    $stderr.puts "[RGSS] Failed to continue: #{e.message}"
  end

  def save_path(slot = 1)
    "#{GAME_DIR}/save#{slot}.mrb"
  end

  def save_exists?(slot = 1)
    File.exist? save_path(slot)
  rescue StandardError => e
    $stderr.puts "[RGSS] save-slot check failed for slot #{slot}: #{e.message}"
    false
  end

  def save_game(state, slot = 1)
    File.open(save_path(slot), "wb") { |f| f.write Marshal.dump(state.to_h) }
    true
  rescue StandardError => e
    $stderr.puts "[RGSS] Failed to save: #{e.message}"
    false
  end

  # One frame of the game. Both the desktop `loop { main_loop }` and the web
  # per-frame `emscripten_set_main_loop` callback (src/main.cxx) call this. When
  # the script host is driving, a frame is one resume of its Fiber (which runs
  # the scripts' loop up to their next Graphics.update); otherwise it is the
  # built-in scene/input/graphics tick. The `@host_fiber` guard is nil in the
  # default flow, so that path is unchanged.
  def main_loop
    return drive_script_host if @host_fiber
    # The host game has ended (Main returned, or a script called `exit`); the web
    # per-frame callback keeps calling this, so idle instead of falling into the
    # built-in tick with no scenes.
    return if @host_done

    RGSS::Profiler.frame do
      RGSS::Profiler.section("scene.update") { @scenes.last.update }
      RGSS::Profiler.section("input.update") { Input.update }
      Graphics.update
    end
  end

  def start
    # The built-in flow needs a scene; a script-host boot builds its Fiber in
    # #initialize instead. `@host_done` only becomes true once the host's Main
    # returns, so the built-in flow loops forever exactly as before.
    push Scene::Title.new(self) if @scenes.empty? && !@host_fiber
    loop do
      main_loop
      break if @host_done
    end
  rescue RGSS::Timeout
  end

  private

  # Build the driver Fiber for the bundled scripts (which installs the per-frame
  # Graphics.update yield). Only reached when the host is enabled, so the
  # built-in flow never creates a Fiber nor wraps Graphics.update. The driver
  # itself lives in ScriptHost so the VX / VX Ace shell (mruby-rpgvx) drives the
  # bundled scripts through the same code.
  def setup_script_host_driver
    @host_fiber = ScriptHost.build_driver(@db)
  end

  # Advance the script host by one frame. When its Main returns the Fiber is
  # dead and the game is over; a boot failure logs and falls back to the
  # built-in flow rather than crashing to a blank screen.
  def drive_script_host
    if @host_fiber.alive?
      @host_fiber.resume
    else
      @host_fiber = nil
      @host_done = true
    end
  rescue RGSS::Timeout, SystemExit
    # A clean end: the timeout guard fired, or a script called `exit` (RMXP's
    # Interpreter does this to abort on runaway common-event recursion). End the
    # game rather than treating it as a boot failure.
    @host_fiber = nil
    @host_done = true
  rescue StandardError => e
    $stderr.puts "[RGSS] script host failed (#{e.class}: #{e.message}); " \
                 "falling back to the built-in flow"
    @host_fiber = nil
    @use_script_host = false
    push Scene::Title.new(self) if @scenes.empty?
  end

  # The window title from Game.ini's [Game] Title=, falling back to the folder
  # name. Parsed with core string operations only (no regexp/String ext), since
  # this mruby build bundles neither. Best effort: a missing/garbled ini must not
  # stop the boot.
  KEY = "Title=".freeze

  def read_ini_title
    path = "#{GAME_DIR}/Game.ini"
    return default_title unless File.exist?(path)
    File.open(path, "r") do |f|
      f.each_line do |line|
        next unless line.size >= KEY.size && line[0, KEY.size] == KEY
        value = trim(line[KEY.size, line.size])
        return value unless value.empty?
      end
    end
    default_title
  rescue StandardError => e
    $stderr.puts "[RGSS] Game.ini read failed: #{e.message}"
    default_title
  end

  # Strip trailing CR/LF/space from a string without String#strip (absent here).
  def trim(s)
    e = s.size
    while e > 0
      c = s[e - 1]
      break unless c == "\r" || c == "\n" || c == " " || c == "\t"
      e -= 1
    end
    s[0, e]
  end

  def default_title
    File.basename(GAME_DIR)
  rescue StandardError
    "RPG Maker XP"
  end
end
