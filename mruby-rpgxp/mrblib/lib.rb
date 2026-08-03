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
    @scenes = []
    push Scene::Title.new(self)
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

  def main_loop
    RGSS::Profiler.frame do
      RGSS::Profiler.section("scene.update") { @scenes.last.update }
      RGSS::Profiler.section("input.update") { Input.update }
      Graphics.update
    end
  end

  def start
    loop { main_loop }
  rescue RGSS::Timeout
  end

  private

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
