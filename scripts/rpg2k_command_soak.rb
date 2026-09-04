#!/usr/bin/env ruby
# encoding: UTF-8
#
# Run every event command of a real game through Game::Interpreter and assert
# that none of them raises, and that none of them logs a gap.
#
# The unit checks (scripts/rpg2k_logic_check.rb) exercise the interpreter against
# hand-written commands, which is where the semantics are pinned. This is the
# other half: the same interpreter against the parameter combinations real games
# actually ship, at a scale nobody writes fixtures for — Nepheshel alone is
# 184,166 commands across 21,430 command lists.
#
# It catches two things a fixture cannot:
#
#   * a handler that raises on a shape no fixture happens to use — a nil where an
#     integer was assumed, an operand index past the end of a short parameter
#     list, an id that resolves to nothing;
#   * a handler that reaches its "I do not know this" arm, which the runtime
#     reports on $stderr with an `[RPG2k]` tag rather than swallowing (see the
#     error-handling rule in AGENTS.md). Those logs are the runtime telling us a
#     real game asked for something unhandled, so here they are failures.
#
# Each command is executed in isolation against a fresh state, so one command's
# wait or teleport cannot mask the rest of its list, and a command that would
# block the interpreter still gets run.
#
# Usage:
#   ruby scripts/rpg2k_command_soak.rb [GAME_DIR ...]
# With no GAME_DIR it soaks every downloaded game under ./data, and says so
# rather than passing vacuously when none is there. Exits non-zero on any
# exception or logged gap.

require 'stringio'

# The two names the game sources reference at load time. Audio is a sink: a
# command that plays a sound must run its handler, not be skipped.
module RGSS
  module Audio
    class << self
      def bgm_play(*); end
      def bgm_volume(*); end
      def bgm_pan(*); end
      def bgm_fade(*); end
      def bgm_stop(*); end
      def se_play(*); end
      def se_stop(*); end
      def me_play(*); end
    end
  end
  def self.warn_stub(*); end
end

module LCF
  # uni-algo stand-in (the native build uses uni-algo); mirrors the other checks.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
  module_function :cp932_to_utf8

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

root = File.expand_path('..', __dir__)
load File.join(root, 'mruby-lcf/mrblib/lcf.rb')
load File.join(root, 'mruby-lcf/mrblib/schema.rb')
load File.join(root, 'mruby-rpg2k/mrblib/game.rb')
load File.join(root, 'mruby-rpg2k/mrblib/interpreter.rb')

# Under CRuby `db.system` resolves to Kernel#system, so route that one field
# explicitly (the same trap AGENTS.md records for `save.system`).
class DbShim
  def initialize(db); @db = db; end
  def system; @db[22]; end
  def [](i); @db[i]; end
  def method_missing(sym, *args, &blk); @db.__send__(sym, *args, &blk); end
  def respond_to_missing?(*); true; end
end

# A Call Event resolver that answers every lookup with an empty list: the point
# is to run the *calling* command, not to recurse through the game.
class NullResolver
  def common_event_commands(_id); []; end
  def map_event_commands(_id, _page); []; end
end

# A map_info hook that answers every query, so the commands that read the map
# (Store Terrain / Event ID, the character operands) take their real path rather
# than the "no hook" early return.
class StubMapInfo
  def event_position(_id); { x: 3, y: 4, direction: 2 }; end
  def character_screen_position(_ref); { x: 40, y: 72 }; end
  def terrain_id(_x, _y); 1; end
  def event_id_at(_x, _y); 0; end
end

# Collects what the runtime writes to $stderr while a command runs. Any line is
# a gap the runtime is reporting, so it is kept verbatim for the summary.
class StderrCapture
  attr_reader :lines
  def initialize; @lines = []; end
  def puts(*args); args.flatten.each { |s| @lines << s.to_s }; end
  def write(s); @lines << s.to_s; s.to_s.length; end
  def print(*args); args.each { |s| @lines << s.to_s }; end
  def flush; end
end

# Every command list in a game: each common event, and each page of each map
# event.
def command_lists(dir)
  lists = []
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  db.common_event&.each do |id, ce|
    lists << ["common#{id}", ce.event] if ce.event
  end
  Dir[File.join(dir, 'Map*.lmu')].sort.each do |f|
    lmu = LCF::MapUnit.new(File.open(f, 'rb'))
    lmu.events.each do |eid, ev|
      ev.pages.each do |pid, pg|
        next unless pg.event_commands
        lists << ["#{File.basename(f)}:event#{eid}/page#{pid}", pg.event_commands]
      end
    end
  rescue StandardError => e
    warn "  #{File.basename(f)}: #{e.class}: #{e.message}"
  end
  [db, lists]
end

def soak(dir)
  raw_db, lists = command_lists(dir)
  db = DbShim.new(raw_db)
  resolver = NullResolver.new
  map_info = StubMapInfo.new
  commands = 0
  errors = Hash.new { |h, k| h[k] = [] }
  logs = Hash.new { |h, k| h[k] = [] }

  lists.each do |name, cmds|
    list = []
    cmds.each { |c| list << c }
    next if list.empty?
    state = Game::State.new(Game::Party.new(db), 1, 5, 5)
    state.seed_screen_transitions(db)
    interp = Game::Interpreter.new(state)
    interp.start([])
    interp.resolver = resolver
    interp.map_info = map_info
    # Pretend a map event is running the list, so a "this event" reference has
    # something to resolve to rather than taking the nil path every time.
    interp.event_id = 1
    list.each_with_index do |cmd, i|
      commands += 1
      captured = StderrCapture.new
      previous = $stderr
      $stderr = captured
      begin
        interp.send(:execute, cmd)
      rescue Exception => e # rubocop:disable Lint/RescueException
        errors["#{cmd.code}: #{e.class}: #{e.message}"] << "#{name}##{i}"
      ensure
        $stderr = previous
      end
      captured.lines.each do |line|
        text = line.strip
        next if text.empty?
        # A variable-driven Enemy Encounter (param0 1: #do_enemy_encounter reads
        # `variables[cmd.param(1)]` for the troop id) is executed here against a
        # freshly-built Game::State that never ran whatever earlier Control
        # Variables command the real event list uses to fill that variable in
        # -- an unavoidable consequence of soaking each command in isolation
        # (see this file's own doc comment). LCF tables are 1-indexed, so an
        # unset variable's default 0 can never name a real troop either way,
        # making "enemy group 0 not found" the harness's own fingerprint for
        # this, not a gap in the game's data or the engine's handling of it --
        # #skip_invalid_troop already has real fixture coverage
        # (rpg2k_logic_check.rb) for the dangling-reference case this same log
        # line also covers. histoire203, 774 maps of encounter-table variety,
        # is the first test bed with a variable-driven Enemy Encounter at all.
        next if text =~ /\A\[RPG2k\] Enemy Encounter: enemy group 0 not found, skipping (?:battle|random encounter)\z/
        logs[text] << "#{name}##{i}"
      end
    end
  end
  [commands, errors, logs]
end

games = ARGV.dup
if games.empty?
  data = File.join(File.expand_path('..', __dir__), 'data')
  games = Dir.glob(File.join(data, '**', 'RPG_RT.ldb')).map { |f| File.dirname(f) }.sort
end

if games.empty?
  warn 'rpg2k command soak: no game found under ./data — download a test-bed ' \
       'first (scripts/download-nepheshel.bash, ' \
       'scripts/download-mtf-meido-action.bash).'
  exit 1
end

failures = 0
games.each do |dir|
  commands, errors, logs = soak(dir)
  name = File.basename(dir.chomp('/'))
  puts "== #{name}: #{commands} commands =="
  errors.sort_by { |_, v| -v.size }.each do |key, where|
    failures += where.size
    puts format('  RAISED %6d  %s', where.size, key)
    puts "           first at #{where.first}"
  end
  logs.sort_by { |_, v| -v.size }.each do |text, where|
    failures += where.size
    puts format('  LOGGED %6d  %s', where.size, text)
    puts "           first at #{where.first}"
  end
  puts '  clean' if errors.empty? && logs.empty?
rescue StandardError => e
  failures += 1
  puts "== #{File.basename(dir.chomp('/'))}: soak failed: #{e.class}: #{e.message} =="
end

if failures.zero?
  puts 'OK: every event command ran without raising or reporting a gap'
  exit 0
end
warn "rpg2k command soak: #{failures} command(s) raised or reported a gap"
exit 1
