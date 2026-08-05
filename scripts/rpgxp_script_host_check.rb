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
# loop and needs the full RGSS graphics/audio library); it evaluates a load-safe
# logic subset to prove real script source decodes, inflates and evaluates into
# top-level classes with their real methods.
#
# Usage:
#   ruby scripts/rpgxp_script_host_check.rb [GAME_DIR ...]
# With no arguments it scans ./data for directories with Data/Scripts.rxdata.
# Exits non-zero if any invariant is violated.

require "zlib"

# --- RGSS value-type + native shims (native classes in the real build) ------

class Table; def self._load(s); allocate; end; end
class Color; def self._load(s); allocate; end; end
class Tone;  def self._load(s); allocate; end; end
class Rect;  def self._load(s); allocate; end; end

# RGSS.zlib_inflate is a native module function in the real build (mruby-rgss,
# via stb_image's zlib decoder). Provide the CRuby equivalent so the shared
# RGSSData#scripts decoder runs here unchanged.
module RGSS
  def self.zlib_inflate(bytes)
    Zlib::Inflate.inflate(bytes)
  end
end

# --- Load the real sources --------------------------------------------------

mrblib = File.expand_path("../mruby-rpgxp/mrblib", __dir__)
load File.join(mrblib, "rgss_data.rb")
load File.join(mrblib, "rgssad.rb")
load File.join(mrblib, "script_host.rb")

# Native RGSS base classes the default scripts subclass at load time.
%w[Sprite Plane Window Tilemap Viewport Bitmap].each do |c|
  Object.const_set(c, Class.new) unless Object.const_defined?(c)
end
module RPG
  class Sprite < ::Sprite; end unless const_defined?(:Sprite)
  class Weather; end unless const_defined?(:Weather)
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

  # Evaluate the logic subset the way the host does and confirm the real classes
  # and event-command methods land at the top level.
  def check_eval_subset(sections)
    top = TOPLEVEL_BINDING
    evaled = 0
    sections.each do |name, source|
      next unless LOGIC_SECTIONS.include?(name)
      begin
        eval(source, top, name, 1)
        evaled += 1
      rescue SyntaxError, StandardError => e
        fail "eval #{name.inspect}: #{e.class}: #{e.message}"
      end
    end
    expect(evaled == LOGIC_SECTIONS.size,
           "evaluated #{evaled}/#{LOGIC_SECTIONS.size} logic sections")
    expect(Object.const_defined?(:Interpreter), "Interpreter class not defined")
    expect(Object.const_defined?(:Game_System), "Game_System class not defined")
    if Object.const_defined?(:Interpreter)
      methods = Interpreter.instance_methods(false)
      expect(methods.include?(:command_301),
             "Interpreter#command_301 (Battle Processing) missing")
      expect(methods.include?(:command_121),
             "Interpreter#command_121 (Control Switches) missing")
    end
    puts "  evaluated #{evaled} logic sections; Interpreter/Game_System defined with real commands"
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
errors = check_enabled_default + check_run_defines_top_level

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
