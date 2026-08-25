# RPG Maker XP runtime.
#
# Boots an RMXP project by running **the game's own engine**: it reads Game.ini,
# loads the Data/*.rxdata database (rgss_data.rb), supplies the RGSS class
# library a game expects (native `mruby-rgss` plus the Ruby classes the player
# ships, rgss_library.rb) and hands the project's `Data/Scripts.rxdata` to the
# script host (script_host.rb), which evaluates them the way RGSS104E.dll does.
#
# There is no second engine any more. This runtime used to carry a
# reimplementation of RMXP's default title/map/event flow (ADR 0010), written
# before a game's own scripts could run; ADR 0030 removed it once they could,
# because a reimplementation can only ever reproduce the *default* engine, while
# every game that matters customises it. A project that ships no scripts now says
# so rather than being played by a stand-in.
#
# The VX / VX Ace shell (mruby-rpgvx) is the same shape and shares the host.

# So a game's scripts can use the bare RGSS names (Bitmap, Sprite, Viewport,
# Input, Audio, ...) — and so Marshal resolves the value types
# Table/Color/Tone/Rect — pull RGSS into the top-level namespace, which is where
# RGSS itself puts them.
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
    # Name the window after the game, as RGSS104E.dll does with the same
    # Game.ini value (and the browser tab, in the web build).
    RGSS.window_title = @title
    # XP selects its UI font by family name (Font.default_name, "MS PGothic" on
    # Windows) and expects the file under the project's Fonts/. Projects that
    # ship none would render every window with the 12px shinonome bitmap font
    # whatever size they asked for, so fall back to the bundled default font
    # (assets/fonts) when it is installed. A project font still wins.
    RGSS::Font.default_path ||= RGSS.default_font_path
    @db = RGSSData.new(GAME_DIR)
    # A packed release holds its Graphics/ and Audio/ trees in the same archive
    # as its Data/, and assets are asked for by name from deep inside the game's
    # own scripts, so the loaders need it globally (see RGSS.asset_archive).
    RGSS.asset_archive = @db.archive
    # The scripts own their whole blocking main loop; drive it one frame at a
    # time through a Fiber so the web build's per-frame callback still gets
    # control back each frame (docs/adr/0023-rpgxp-script-host-frame-driver.md).
    setup_script_host_driver if ScriptHost.enabled? && @db.scripts?
  end

  attr_reader :db, :title

  # The active scene's class name, mirroring RPG2k#current_scene_name
  # (mruby-rpg2k/mrblib/main.rb) -- see there for why a native caller wants
  # this. Unlike RPG2k's own @scenes stack, this engine runs the game's own
  # bundled scripts (see the class comment above), so "the active scene" is
  # whatever *they* publish -- ScriptHost.current_scene already resolves that
  # across both real conventions (RGSS/RGSS2's `$scene`, RGSS3's
  # `SceneManager.scene`; script_host.rb). "none" covers the script host being
  # disabled, a project shipping no scripts, or the host simply not having
  # reported a scene yet.
  def current_scene_name
    scene = ScriptHost.enabled? ? ScriptHost.current_scene : nil
    scene ? scene.class.name : "none"
  end

  # One frame of the game: one resume of the host's Fiber, which runs the
  # scripts' own loop up to their next Graphics.update. Both the desktop
  # `loop { main_loop }` and the web per-frame `emscripten_set_main_loop`
  # callback (src/main.cxx) call this.
  def main_loop
    return drive_script_host if @host_fiber
    # The game has ended (its Main returned, or a script called `exit`) or never
    # started; the web per-frame callback keeps calling this, so idle.
    nil
  end

  def start
    unless @host_fiber
      report_nothing_to_run
      return
    end
    loop do
      main_loop
      break if @host_done
    end
  rescue RGSS::Timeout
  end

  private

  # Why there is nothing to run: either the project ships no script bundle (an
  # editor project mid-authoring, or a folder that only looks like one), or the
  # host was switched off with --norgss_script_host. Reported once — the web
  # callback would otherwise print it every frame.
  def report_nothing_to_run
    return if @warned_nothing_to_run
    @warned_nothing_to_run = true
    if !ScriptHost.enabled?
      $stderr.puts "[RGSS] the script host is off (--norgss_script_host), so " \
                   "the project's own scripts will not run; there is no other " \
                   "engine to fall back to (docs/adr/0030-rgss-only-the-games-own-engine.md)"
    else
      $stderr.puts "[RGSS] #{@title.inspect} ships no Data/Scripts.rxdata: an " \
                   "RPG Maker XP game *is* its scripts, so there is nothing to run"
    end
  end

  # Build the driver Fiber for the bundled scripts (which installs the per-frame
  # Graphics.update yield). The driver itself lives in ScriptHost so the VX /
  # VX Ace shell (mruby-rpgvx) drives the bundled scripts through the same code.
  def setup_script_host_driver
    @host_fiber = ScriptHost.build_driver(@db)
  end

  # Advance the script host by one frame. When its Main returns the Fiber is dead
  # and the game is over. A failure inside the game's own scripts ends the run and
  # is reported by the host with the section and line it came from — there is no
  # fallback engine to hide it behind.
  def drive_script_host
    if @host_fiber.alive?
      @host_fiber.resume
    else
      @host_fiber = nil
      @host_done = true
    end
  rescue RGSS::Timeout, SystemExit
    # A clean end: the timeout guard fired, or a script called `exit` (RMXP's
    # Interpreter does this to abort on runaway common-event recursion).
    @host_fiber = nil
    @host_done = true
  rescue StandardError => e
    $stderr.puts "[RGSS] script host failed (#{e.class}: #{e.message})"
    @host_fiber = nil
    @host_done = true
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
