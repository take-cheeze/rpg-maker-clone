#!/usr/bin/env ruby
# encoding: UTF-8
#
# What share of a real RPG Maker XP game's event commands does the interpreter
# handle?
#
# scripts/rpgxp_testbed_check.rb already drives every event page through
# RPGXP::Game::Interpreter and fails if one raises — but it deliberately treats
# an unsupported command as "skipped, not fatal", so a game can run end to end
# through it while a sixth of its commands do nothing. That is the same blind
# spot the RPG2000 side had: scripts/analyze_game.rb reported 100 % opcode
# coverage for years while seven handlers quietly mishandled what they were
# given, and making the number visible is what started fixing it.
#
# This is the RPG2000 tool's counterpart for XP. It tallies every command code
# in a game's common events and map event pages and splits them three ways,
# exactly as analyze_game.rb does:
#
#   implemented (✓)  the interpreter names the code in its own constant table,
#                    so it is dispatched;
#   no-op (·)        the codes that carry no behaviour — the list terminator and
#                    the continuation lines the handler for the opening command
#                    consumes;
#   gap (✗)          used by the game and unknown to the interpreter.
#
# A gap's code is reported as its number. The interpreter's constants are the
# only naming authority used here, so the report never invents a name for a
# command it does not implement — the same rule analyze_game.rb follows.
#
# Usage:
#   ruby scripts/rpgxp_command_coverage.rb [GAME_DIR ...]
# With no GAME_DIR it scans ./data for XP projects (a Game.ini beside either a
# Data/ directory or a Game.rgssad). Reports only; it never fails a build, since
# an unimplemented command is a known state of the world rather than a
# regression.

require 'stringio'
require 'zlib'

# --- RGSS value-type shims (native classes in the real build) ----------------
# Same stand-ins scripts/rpgxp_testbed_check.rb uses; only presence matters.
class Table
  attr_reader :dim, :xsize, :ysize, :zsize, :data
  def self._load(s)
    dim, x, y, z, count = s[0, 20].unpack('l<5')
    t = allocate
    t.instance_variable_set(:@dim, dim)
    t.instance_variable_set(:@xsize, x)
    t.instance_variable_set(:@ysize, y)
    t.instance_variable_set(:@zsize, z)
    t.instance_variable_set(:@data, s[20, count * 2].unpack("s<#{count}"))
    t
  end
  def [](x, y = 0, z = 0); @data[x + @xsize * (y + @ysize * z)]; end
end
class Color; def self._load(s); c = allocate; c.instance_variable_set(:@v, s.unpack('E4')); c; end; end
class Tone;  def self._load(s); c = allocate; c.instance_variable_set(:@v, s.unpack('E4')); c; end; end
class Rect;  def self._load(s); r = allocate; r.instance_variable_set(:@v, s.unpack('l<4')); r; end; end

module Audio
  def self.bgm_play(*); end
  def self.bgs_play(*); end
  def self.me_play(*); end
  def self.se_play(*); end
end
class RPGXP; end

mrblib = File.expand_path('../mruby-rpgxp/mrblib', __dir__)
load File.join(mrblib, 'rgss_data.rb')
load File.join(mrblib, 'game.rb')
load File.join(mrblib, 'interpreter.rb')
load File.join(mrblib, 'rgssad.rb')

I = RPGXP::Game::Interpreter

# The interpreter's integer constants that are limits, sentinels and unit
# conversions rather than command codes. Listed by name, not matched by prefix:
# a prefix rule silently absorbs the next constant that happens to fit it, and
# an absorbed *code* would be reported as a gap while an absorbed *limit* would
# be reported as an implemented command that does not exist.
NOT_A_CODE = %w[
  MAX_STEPS_PER_FRAME MAX_CALL_DEPTH
  MOVE_TARGET_PLAYER MOVE_TARGET_THIS
  TRANSITION_FRAMES MS_PER_SECOND
].freeze

# RGSS1 event command codes run 101 (Show Text) to 655 (Script continuation).
CODE_RANGE = (101..655).freeze

# Every command code the interpreter names, and the name it uses. These are the
# numbers it actually dispatches on, so they cannot drift from the runtime the
# way a hand-copied table would. A new integer constant that is neither listed
# above nor a plausible code is reported rather than guessed at, so the day the
# interpreter grows one this tool says so instead of quietly miscounting.
HANDLED = I.constants.each_with_object({}) do |const, out|
  value = I.const_get(const)
  next unless value.is_a?(Integer)
  next if NOT_A_CODE.include?(const.to_s)
  unless CODE_RANGE.include?(value)
    warn "rpgxp command coverage: #{const} = #{value} is not a command code " \
         "and is not listed in NOT_A_CODE; ignoring it"
    next
  end
  out[value] ||= const.to_s
end.freeze

# Codes that carry no behaviour of their own, and must not be counted as gaps —
# they would drown the real ones.
#
#   0    terminates a command list.
#   509  the Move Route continuation. RGSS repeats each move of a 209 Set Move
#        Route as its own 509 line for the editor's benefit, but the route
#        itself is the RPG::MoveRoute in the 209's own parameters, which
#        #do_move_route reads — so the 509s are display, not behaviour.
#        Verified against the data rather than assumed: in PrayforYou every one
#        of its 2487 509 lines directly follows a 209 or another 509, with no
#        exceptions. Left uncounted, it alone would report a 15.7 % gap.
NOOP = [0, 509].freeze

def classify(code)
  return :noop if NOOP.include?(code)
  return :impl if HANDLED.key?(code)
  :gap
end

def label(code)
  HANDLED[code] || "code #{code}"
end

# Tally the command codes of every common event and map event page.
def tally(dir)
  db = RPGXP::RGSSData.new(dir)
  hist = Hash.new(0)
  maps = 0
  (db.common_events || []).each do |ce|
    next unless ce && ce.list
    ce.list.each { |c| hist[c.code] += 1 }
  end
  (db.map_infos || {}).each_key do |id|
    map = begin
      db.load_map(id)
    rescue StandardError
      nil
    end
    next unless map && map.events
    maps += 1
    map.events.each do |_eid, ev|
      (ev.pages || []).each do |page|
        next unless page && page.list
        page.list.each { |c| hist[c.code] += 1 }
      end
    end
  end
  [hist, maps]
end

def report(dir)
  hist, maps = tally(dir)
  total = hist.values.sum
  if total.zero?
    puts "== #{File.basename(dir.chomp('/'))} == (no event commands)"
    return
  end
  impl = hist.select { |c, _| classify(c) == :impl }.values.sum
  noop = hist.select { |c, _| classify(c) == :noop }.values.sum
  gaps = hist.select { |c, _| classify(c) == :gap }
  pct = ->(n) { total.zero? ? 0 : 100.0 * n / total }

  puts "== #{File.basename(dir.chomp('/'))} =="
  puts "  maps=#{maps} event commands=#{total} distinct codes=#{hist.size}"
  puts format('    implemented: %d (%.1f%%) + no-op: %d (%.1f%%)',
              impl, pct.call(impl), noop, pct.call(noop))
  puts format('    gaps: %d (%.1f%%) across %d distinct code(s)',
              gaps.values.sum, pct.call(gaps.values.sum), gaps.size)
  return if gaps.empty?

  puts '  -- codes the interpreter does not name (most used first) --'
  gaps.sort_by { |_, n| -n }.each do |code, n|
    puts format('    %-12s %6d  (%.1f%%)', label(code), n, pct.call(n))
  end
end

# An XP project: Game.ini beside a Data/ directory or an encrypted archive.
def xp_project?(dir)
  return false unless File.exist?(File.join(dir, 'Game.ini'))
  File.directory?(File.join(dir, 'Data')) ||
    !RPGXP::RGSSAD.find(dir).nil?
end

games = ARGV.dup
if games.empty?
  root = File.expand_path('../data', __dir__)
  games = Dir.glob(File.join(root, '**', 'Game.ini'))
             .map { |f| File.dirname(f) }.select { |d| xp_project?(d) }.sort
end

if games.empty?
  warn 'rpgxp command coverage: no XP project under ./data — download one ' \
       'first (scripts/download-prayforyou.bash, ' \
       'scripts/download-opengame-xp.bash).'
  exit 1
end

games.each do |dir|
  report(dir)
rescue StandardError => e
  warn "  #{File.basename(dir.chomp('/'))}: #{e.class}: #{e.message}"
end
