#!/usr/bin/env ruby
# encoding: UTF-8
#
# Feasibility + smoke check for the RPG Maker XP *script host* (the "run the
# bundled RGSS scripts" path, ADR 0017), driven against a real test-bed project.
#
# The native runtime boots an XP game by evaluating the ~90 Ruby sections in
# Data/Scripts.rxdata in order (see mruby-rpgxp/mrblib/script_host.rb). The
# host plumbing — decoding/inflating the sections, installing the Kernel
# load_data/save_data built-ins, and evaluating each section at the top level so
# its classes become global — is written in the mruby/CRuby common subset, so
# this harness loads the exact sources under CRuby and exercises them end to end
# against genuine editor output, the way scripts/rpgxp_testbed_check.rb guards
# the data layer.
#
# It does NOT run the "Main" section (that would start the game's blocking main
# loop and needs the full RGSS graphics/audio library); it evaluates every other
# section to prove real script source decodes, inflates and evaluates into
# top-level classes with their real methods.
#
# The RGSS *standard library* — RPG::Cache, RPG::Sprite, RPG::Weather, which the
# player supplies and no project ships — is loaded here from the real
# mruby-rpgxp/mrblib/rgss_library.rb and exercised against fake native classes.
# It used to be stubbed with empty classes, and that stub is precisely why this
# check stayed green while the engine could not boot a game past
# `class Sprite_Character < RPG::Sprite` (see the RPG::Sprite entry in
# docs/rpgxp-rgss-api-gap.md). Shimming a *native* class here is unavoidable;
# shimming our own Ruby is how a gap hides.
#
# Usage:
#   ruby scripts/rpgxp_script_host_check.rb [GAME_DIR ...]
# With no arguments it scans ./data for directories with Data/Scripts.rxdata.
# Exits non-zero if any invariant is violated.

require "zlib"

# --- RGSS value-type + native shims (native classes in the real build) ------

class Table; def self._load(s); allocate; end; end
class Tone;  def self._load(s); allocate; end; end

# The native classes mruby-rgss implements in C++, as far as the RGSS standard
# library below drives them: enough to record what it asked for, so the checks
# can assert on it. Everything here is a *stand-in for native code*; our own Ruby
# is always loaded for real.
module RGSS
  # RGSS.zlib_inflate is a native module function in the real build (via
  # stb_image's zlib decoder). Provide the CRuby equivalent so the shared
  # RGSSData#scripts decoder runs here unchanged.
  def self.zlib_inflate(bytes)
    Zlib::Inflate.inflate(bytes)
  end

  class Color
    attr_accessor :red, :green, :blue, :alpha
    def initialize(r, g, b, a = 255); set(r, g, b, a); end
    def set(r, g, b, a = 255); @red, @green, @blue, @alpha = r, g, b, a; end
    def self._load(_s); allocate; end
  end

  class Rect
    attr_accessor :x, :y, :width, :height
    def initialize(x = 0, y = 0, w = 0, h = 0); set(x, y, w, h); end
    def set(x, y, w, h); @x, @y, @width, @height = x, y, w, h; end
    def self._load(_s); allocate; end
  end

  class Font
    attr_accessor :name, :size, :color
    def initialize; @name = "Arial"; @size = 22; @color = Color.new(255, 255, 255); end
  end

  # Records draws instead of rasterising. A path containing "Missing" stands in
  # for an asset that will not load, so the cache's fallback can be checked.
  class Bitmap
    attr_reader :width, :height, :texts, :hue, :path
    def initialize(a, b = nil)
      if a.is_a?(String)
        raise "Failed to init bitmap: #{a}" if a.include?("Missing")
        @path = a
        @width = @height = 64
      else
        @width, @height = a, b
      end
      @texts = []
      @disposed = false
    end
    def font; @font ||= Font.new; end
    def draw_text(*args); @texts << args; end
    def fill_rect(*); end
    def blt(*); end
    def hue_change(hue); @hue = hue; end
    def dispose; @disposed = true; end
    def disposed?; @disposed; end
  end

  class Sprite
    attr_accessor :bitmap, :ox, :oy, :visible, :zoom_x, :zoom_y, :angle,
                  :mirror, :blend_type, :src_rect, :color, :tone
    attr_reader :viewport, :opacity, :flashes
    def initialize(viewport = nil)
      @viewport = viewport
      @opacity = 255
      @ox = @oy = 0
      @src_rect = Rect.new(0, 0, 0, 0)
      @flashes = []
      @disposed = false
    end
    def x; @x || 0; end
    def y; @y || 0; end
    def z; @z || 0; end
    attr_writer :x, :y, :z
    # The native setter takes an Integer and clamps it to 0..255 — RGSS's own
    # fades deliberately overshoot (`appear` ends on 256, `collapse` on -32), so
    # a fake that stored those verbatim would report opacities the engine can
    # never show. A Float raises there, so it raises here too.
    def opacity=(value)
      raise TypeError, "opacity= got #{value.class}" unless value.is_a?(Integer)
      @opacity = value < 0 ? 0 : (value > 255 ? 255 : value)
    end
    def flash(color, duration); @flashes << [color, duration]; end
    def update; end
    def dispose; @disposed = true; end
    def disposed?; @disposed; end
  end

  class Viewport
    attr_reader :rect, :flashes
    def initialize(rect); @rect = rect; @flashes = []; end
    def flash(color, duration); @flashes << [color, duration]; end
  end

  module Graphics
    class << self; attr_accessor :frame_count; end
    @frame_count = 0
  end

  module Audio
    class << self; attr_reader :played; end
    @played = []
    def self.se_play(name, volume = 100, pitch = 100); @played << [name, volume, pitch]; end
    def self.reset; @played = []; end
  end
end

# The real runtime pulls RGSS into the top level (mruby-rpgxp/mrblib/lib.rb), so
# the scripts' bare `Sprite`/`Bitmap`/`Color` resolve. Do the same here.
class Object; include RGSS; end
Color = RGSS::Color
Rect = RGSS::Rect

# --- Load the real sources --------------------------------------------------

mrblib = File.expand_path("../mruby-rpgxp/mrblib", __dir__)
load File.join(mrblib, "rgss_data.rb")
load File.join(mrblib, "rgssad.rb")
load File.join(mrblib, "rgss_library.rb")
load File.join(mrblib, "script_host.rb")

# The remaining native classes the stock scripts subclass or instantiate at load
# time, which the RGSS standard library above does not drive.
%w[Plane Window Tilemap].each do |c|
  Object.const_set(c, Class.new) unless Object.const_defined?(c)
end

class Checker
  # Sections that are pure game logic — safe to evaluate with no running engine.
  LOGIC_SECTIONS = [
    "Game_Switches", "Game_Variables", "Game_SelfSwitches", "Game_System",
    "Interpreter 1", "Interpreter 2", "Interpreter 3",
    "Interpreter 4", "Interpreter 5", "Interpreter 6", "Interpreter 7"
  ].freeze

  def initialize
    @errors = 0
  end

  attr_reader :errors

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  def expect(cond, msg)
    fail(msg) unless cond
  end

  def check_game(dir)
    puts "== #{dir} =="
    db = RPGXP::RGSSData.new(dir)

    expect(db.scripts?, "project reports no script bundle")
    sections = db.scripts
    expect(sections.is_a?(Array) && !sections.empty?, "no script sections decoded")
    sections.each do |name, source|
      expect(name.is_a?(String), "section name is #{name.class}, not String")
      expect(source.is_a?(String) && !source.empty?,
             "section #{name.inspect} inflated to empty/non-String")
    end
    puts "  decoded #{sections.size} script sections (e.g. #{sections.first[0].inspect})"

    check_driving_flag
    check_kernel_builtins(db)
    check_eval_subset(sections)
  rescue => ex
    fail "#{dir}: #{ex.class}: #{ex.message}"
  end

  # The per-frame Fiber driver reads ScriptHost.driving? from the wrapped
  # Graphics.update to decide whether to yield (ADR 0023). The wrapping needs the
  # native runtime, but the flag itself is plain Ruby, so guard its default and
  # round-trip here.
  def check_driving_flag
    expect(RPGXP::ScriptHost.driving? == false,
           "ScriptHost.driving? should default to false")
    RPGXP::ScriptHost.driving = true
    expect(RPGXP::ScriptHost.driving? == true, "ScriptHost.driving= did not set")
    RPGXP::ScriptHost.driving = false
    expect(RPGXP::ScriptHost.driving? == false, "ScriptHost.driving= did not clear")
    puts "  ScriptHost.driving? defaults false and round-trips"
  end

  # install_kernel wires load_data/save_data through the database, so a script's
  # `load_data("Data/System.rxdata")` round-trips to the real RPG::System.
  def check_kernel_builtins(db)
    RPGXP::ScriptHost.install_kernel(db)
    obj = Object.new
    sys = obj.send(:load_data, "Data/System.rxdata")
    expect(sys.is_a?(RPG::System), "load_data did not return an RPG::System")
    expect(sys.start_map_id.to_i > 0, "load_data System.start_map_id not positive")
    puts "  Kernel#load_data returns RPG::System (start_map_id=#{sys.start_map_id})"
  end

  # Evaluate the bundle the way the host does and confirm the real classes and
  # event-command methods land at the top level.
  #
  # *Every* section except "Main" is evaluated, not a hand-picked logic subset:
  # a section that cannot even be defined is what stops a boot, and the one that
  # did (`class Sprite_Character < RPG::Sprite`) sat outside the old subset. Main
  # is still skipped — it starts the game's blocking main loop.
  def check_eval_subset(sections)
    top = TOPLEVEL_BINDING
    evaled = 0
    sections.each do |name, source|
      next if name == "Main"
      begin
        eval(source, top, name, 1)
        evaled += 1
      rescue SyntaxError, StandardError => e
        fail "eval #{name.inspect}: #{e.class}: #{e.message}"
      end
    end
    expect(evaled == sections.size - 1,
           "evaluated #{evaled}/#{sections.size - 1} sections (Main excluded)")
    LOGIC_SECTIONS.each do |name|
      expect(sections.any? { |s, _| s == name },
             "the bundle no longer ships #{name.inspect} — is this an XP project?")
    end
    expect(Object.const_defined?(:Interpreter), "Interpreter class not defined")
    expect(Object.const_defined?(:Game_System), "Game_System class not defined")
    if Object.const_defined?(:Interpreter)
      methods = Interpreter.instance_methods(false)
      expect(methods.include?(:command_301),
             "Interpreter#command_301 (Battle Processing) missing")
      expect(methods.include?(:command_121),
             "Interpreter#command_121 (Control Switches) missing")
    end
    # The sprites that stopped the boot: both subclass the RGSS standard
    # library's RPG::Sprite, so this is what proves the class is really there and
    # really usable as a superclass.
    %w[Sprite_Character Sprite_Battler].each do |name|
      unless Object.const_defined?(name)
        fail "#{name} not defined"
        next
      end
      expect(Object.const_get(name).ancestors.include?(RPG::Sprite),
             "#{name} does not inherit RPG::Sprite")
    end
    puts "  evaluated #{evaled} sections; Interpreter/Game_System defined with " \
         "real commands, Sprite_Character/Sprite_Battler on RPG::Sprite"
  end

  def report
    if @errors.zero?
      puts "OK: XP script host decodes, installs built-ins and evaluates real scripts"
    else
      warn "#{@errors} error(s)"
    end
  end
end

# Project-independent: ScriptHost.run must eval a section so its class defines a
# GLOBAL (::) constant, the way RGSS evaluates scripts at top level. Mirrors the
# mruby test; catches a regression in rgss_eval_section's top-level scoping.
def check_run_defines_top_level
  tiny = Object.new
  def tiny.scripts; [["Probe", "class RgssHostCheckProbe; def v; 5; end; end"]]; end
  def tiny.read_object(*); end
  def tiny.save_object(*); end
  unless RPGXP::ScriptHost.run(tiny)
    warn "  FAIL ScriptHost.run returned false for a one-section project"
    return 1
  end
  unless Object.const_defined?(:RgssHostCheckProbe) && RgssHostCheckProbe.new.v == 5
    warn "  FAIL ScriptHost.run did not define the section's class at the top level"
    return 1
  end
  puts "  ScriptHost.run defines section classes at the top level"
  0
end

# Project-independent: the RGSS standard library the player supplies
# (mruby-rpgxp/mrblib/rgss_library.rb). Driven against the fake native classes at
# the top of this file, so the *behaviour* a game's own engine depends on —
# not merely the existence of the constants — is checked on every run.
def check_rgss_library
  errors = 0
  check = lambda do |cond, msg|
    next 0 if cond
    warn "  FAIL #{msg}"
    1
  end

  viewport = RGSS::Viewport.new(RGSS::Rect.new(0, 0, 640, 480))
  sprite = RPG::Sprite.new(viewport)
  sprite.x = 100
  sprite.y = 200

  # The battler transitions are timed effects: `effect?` is what a battle scene
  # waits on, so each has to start one and each has to end.
  errors += check.call(!sprite.effect?, "a fresh RPG::Sprite reports an effect")
  sprite.whiten
  errors += check.call(sprite.effect?, "whiten did not start an effect")
  16.times { sprite.update }
  errors += check.call(!sprite.effect?, "whiten never ended (16 frames)")
  sprite.appear
  16.times { sprite.update }
  errors += check.call(sprite.opacity == 255, "appear ended at opacity #{sprite.opacity}")
  sprite.escape
  32.times { sprite.update }
  errors += check.call(!sprite.effect?, "escape never ended (32 frames)")
  sprite.collapse
  48.times { sprite.update }
  errors += check.call(!sprite.effect?, "collapse never ended (48 frames)")

  # The damage pop-up: its own sprite at z 3000, the number drawn unsigned, a
  # recovery in green, CRITICAL above it, gone after 40 frames.
  sprite.damage(120, true)
  pop = sprite.instance_variable_get(:@_damage_sprite)
  errors += check.call(!pop.nil? && pop.z == 3000, "damage pop-up is not at z 3000")
  drawn = pop.nil? ? [] : pop.bitmap.texts.map { |t| t[4] }
  errors += check.call(drawn.include?("120"), "damage did not draw its value")
  errors += check.call(drawn.include?("CRITICAL"), "a critical did not draw CRITICAL")
  40.times { sprite.update }
  errors += check.call(!sprite.effect?, "the damage pop-up never expired")
  sprite.damage(-30, false)
  recovery = sprite.instance_variable_get(:@_damage_sprite)
  errors += check.call(!recovery.nil? &&
                       recovery.bitmap.texts.map { |t| t[4] }.include?("30"),
                       "recovery did not draw its value unsigned")
  sprite.dispose_damage

  sprite.blink_on
  errors += check.call(sprite.blink?, "blink_on did not turn blinking on")
  sprite.update
  errors += check.call(!sprite.effect?, "blinking must not count as an effect")
  sprite.blink_off
  errors += check.call(!sprite.blink?, "blink_off did not turn blinking off")

  # An animation over the sprite: 16 cell sprites aimed from the frame's cell
  # data, the timing's SE played and its flash fired. Full opacity first — the
  # collapse above faded the sprite out, and a cell's opacity is scaled by the
  # sprite's, so the cells would be invisible too (which is RGSS's own rule).
  sprite.opacity = 255
  RGSS::Audio.reset
  cells = FakeTable.new([[3, 10, -20, 200, 45, 1, 128, 1]] +
                        Array.new(15) { [-1, 0, 0, 100, 0, 0, 255, 0] })
  flash_color = RGSS::Color.new(255, 255, 255, 255)
  animation = FakeAnimation.new(
    2, "Anim1", 0, 1, [FakeFrame.new(cells), FakeFrame.new(cells)],
    [FakeTiming.new(0, 0, FakeSE.new("Hit", 80, 100), 1, flash_color, 5)]
  )
  sprite.animation(animation, true)
  cell_sprites = sprite.instance_variable_get(:@_animation_sprites)
  errors += check.call(cell_sprites.size == 16,
                       "#{cell_sprites.size} animation cell sprites, expected 16")
  cell = cell_sprites[0]
  errors += check.call(cell.visible, "the first animation cell is not visible")
  errors += check.call(cell.src_rect.x == 3 % 5 * 192 && cell.src_rect.width == 192,
                       "animation cell reads the wrong 192x192 patch")
  errors += check.call(cell.z == 2000, "animation cell is not at z 2000")
  errors += check.call(cell.zoom_x == 2.0, "animation cell zoom is #{cell.zoom_x}")
  errors += check.call(cell.angle == 45, "animation cell angle is #{cell.angle}")
  errors += check.call(cell.mirror, "animation cell is not mirrored")
  errors += check.call(cell.opacity == 128, "animation cell opacity is #{cell.opacity}")
  errors += check.call(!cell_sprites[1].visible, "an unused cell is visible")
  errors += check.call(RGSS::Audio.played == [["Audio/SE/Hit", 80, 100]],
                       "the timing's SE did not play (#{RGSS::Audio.played.inspect})")
  errors += check.call(sprite.flashes == [[flash_color, 10]],
                       "the timing's flash did not fire (#{sprite.flashes.inspect})")
  moved_from = cell.x
  sprite.x = sprite.x + 40
  errors += check.call(cell.x - moved_from == 40,
                       "animation cells did not follow the sprite")
  RGSS::Graphics.frame_count = 0
  sprite.update
  errors += check.call(sprite.effect?, "the animation ended a frame early")
  RGSS::Graphics.frame_count = 2
  sprite.update
  errors += check.call(!sprite.effect?, "the animation never ended")

  # Weather: 40 recycled drops, only `max` of them shown, each moving per frame.
  weather = RPG::Weather.new(viewport)
  errors += check.call(weather.type == 0 && weather.max == 0,
                       "weather does not start clear")
  weather.type = 1
  weather.max = 20
  drops = weather.instance_variable_get(:@sprites)
  errors += check.call(drops[1].visible && !drops[25].visible,
                       "weather shows the wrong number of drops")
  errors += check.call(drops[1].bitmap.width == 7, "rain drops use the wrong bitmap")
  weather.ox = 5
  errors += check.call(drops[0].ox == 5, "weather ox did not reach its sprites")
  before = [drops[1].x, drops[1].y]
  weather.update
  errors += check.call([drops[1].x, drops[1].y] != before, "no weather drop moved")

  # The cache: one bitmap per path, a hue variant of its own, a blank for an
  # empty name, and — our deviation from RGSS — a blank for an asset that will
  # not load rather than a raise that would end the game.
  plain = RPG::Cache.character("Hero", 0)
  errors += check.call(plain.equal?(RPG::Cache.character("Hero", 0)),
                       "RPG::Cache reloaded a cached bitmap")
  hued = RPG::Cache.character("Hero", 120)
  errors += check.call(!hued.equal?(plain) && hued.hue == 120,
                       "RPG::Cache did not build a hue variant")
  errors += check.call(RPG::Cache.character("", 0).width == 32,
                       "an empty name did not give a blank bitmap")
  errors += check.call(RPG::Cache.picture("MissingOnPurpose").width == 32,
                       "a missing asset did not fall back to a blank bitmap")
  errors += check.call(RPG::Cache.tile("Grass", 384 + 9, 0).width == 32,
                       "RPG::Cache.tile did not cut a 32x32 tile")
  RPG::Cache.clear
  errors += check.call(!RPG::Cache.character("Hero", 0).equal?(plain),
                       "RPG::Cache.clear did not empty the cache")

  if errors.zero?
    puts "  RGSS standard library: RPG::Sprite effects/animation, RPG::Weather " \
         "and RPG::Cache behave"
  end
  errors
end

# Stand-ins for the RPG::Animation records the editor stores (the real ones come
# from rgss_data.rb, built by Marshal); `cell_data` is a Table, indexed [cell,
# field].
FakeTable = Struct.new(:rows) do
  def [](i, j); rows[i] ? rows[i][j] : nil; end
end
FakeFrame = Struct.new(:cell_data)
FakeTiming = Struct.new(:frame, :condition, :se, :flash_scope, :flash_color,
                        :flash_duration)
FakeSE = Struct.new(:name, :volume, :pitch)
FakeAnimation = Struct.new(:frame_max, :animation_name, :animation_hue,
                           :position, :frames, :timings)

# Project-independent: the host is the default boot path (ADR 0029), and
# RGSS_SCRIPT_HOST is the opt-out that restores the built-in flow. Guarding it
# here as well as in mruby-rpgxp/test keeps the two spellings of the rule (the
# CRuby harness and the built engine) from drifting apart.
def check_enabled_default
  previous = ENV["RGSS_SCRIPT_HOST"]
  errors = 0
  check = lambda do |want, msg|
    next 0 if RPGXP::ScriptHost.enabled? == want
    warn "  FAIL #{msg}"
    1
  end

  ENV.delete("RGSS_SCRIPT_HOST")
  errors += check.call(true, "ScriptHost.enabled? is false with RGSS_SCRIPT_HOST unset")
  ENV["RGSS_SCRIPT_HOST"] = ""
  errors += check.call(true, "an empty RGSS_SCRIPT_HOST should leave the default (on)")
  RPGXP::ScriptHost::DISABLED_VALUES.each do |off|
    ENV["RGSS_SCRIPT_HOST"] = off
    errors += check.call(false, "RGSS_SCRIPT_HOST=#{off} did not switch the host off")
  end
  ENV["RGSS_SCRIPT_HOST"] = "1"
  errors += check.call(true, "RGSS_SCRIPT_HOST=1 did not keep the host on")

  # The native binary has no ENV to offer the Ruby side, so it resolves
  # --rgss_script_host / RGSS_SCRIPT_HOST itself and passes the answer down as a
  # constant (src/main.cxx). That channel wins over the environment.
  begin
    Object.const_set(:RGSS_SCRIPT_HOST, false)
    errors += check.call(false, "the RGSS_SCRIPT_HOST constant did not switch the host off")
    Object.send(:remove_const, :RGSS_SCRIPT_HOST)
    Object.const_set(:RGSS_SCRIPT_HOST, true)
    ENV["RGSS_SCRIPT_HOST"] = "0"
    errors += check.call(true, "the RGSS_SCRIPT_HOST constant should win over the environment")
  ensure
    Object.send(:remove_const, :RGSS_SCRIPT_HOST) if Object.const_defined?(:RGSS_SCRIPT_HOST)
  end

  puts "  ScriptHost.enabled? defaults on; #{RPGXP::ScriptHost::DISABLED_VALUES.join('/')} opt out " \
       "(env or the native RGSS_SCRIPT_HOST constant)" if errors.zero?
  errors
ensure
  previous.nil? ? ENV.delete("RGSS_SCRIPT_HOST") : ENV["RGSS_SCRIPT_HOST"] = previous
end

# Every XP project under `root` that carries scripts: an editor project (a loose
# Data/Scripts.rxdata) or a *released* one, which keeps Scripts.rxdata inside its
# encrypted Game.rgssad with no loose Data/ to glob for.
def discover_games(root)
  return [] unless Dir.exist?(root)
  loose = Dir.glob(File.join(root, "**", "Data", "Scripts.rxdata"))
              .map { |f| File.dirname(File.dirname(f)) }
  packed = Dir.glob(File.join(root, "**", "Game.rgssad"))
              .map { |f| File.dirname(f) }
  (loose + packed).sort.uniq
end

games = ARGV.dup
games = discover_games(File.expand_path("../data", __dir__)) if games.empty?

# The project-independent checks run first, so they still guard the rules when
# no test bed has been downloaded.
errors = check_enabled_default + check_run_defines_top_level + check_rgss_library

if games.empty?
  warn "no XP test-bed game found (run scripts/download-opengame-xp.bash first)"
  exit(errors.zero? ? 0 : 1)
end

checker = Checker.new
games.each { |g| checker.check_game(g) }
errors += checker.errors
if errors.zero?
  puts "OK: XP script host decodes, installs built-ins and evaluates real scripts"
else
  warn "#{errors} error(s)"
end
exit(errors.zero? ? 0 : 1)
