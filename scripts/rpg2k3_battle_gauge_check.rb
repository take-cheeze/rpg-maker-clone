#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side unit checks for the RPG2003 active-time (gauge) battle timing
# (ADR 0053, Phase 2). The gauge is an RPG2003 presentation-2 concept; this
# harness exercises the pure gauge-accumulation / ready-selection model in
# mruby-rpg2k/mrblib/game.rb. RPG2000 (battle_type 0) and the 2003
# traditional presentation (1) never advance the gauge.
#
# Usage: ruby scripts/rpg2k3_battle_gauge_check.rb   (exits non-zero on failure)

module RGSS
  module Audio
    class << self
      def bgm_play(*); end
      def bgm_volume(*); end
      def bgm_pan(*); end
      def bgm_fade(*); end
      def se_play(*); end
      def se_stop(*); end
    end
  end
  def self.warn_stub(*); end
end

require 'stringio'
module LCF
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{FFFD}")
  end
  def utf8_to_cp932(s)
    s.dup.encode('Windows-31J', invalid: :replace, undef: :replace)
     .force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932
end
lcf_lib = File.expand_path('../mruby-lcf/mrblib', __dir__)
load File.join(lcf_lib, 'lcf.rb')
load File.join(lcf_lib, 'schema.rb')

lib = File.expand_path('../mruby-rpg2k/mrblib', __dir__)
load File.join(lib, 'game.rb')
load File.join(lib, 'interpreter.rb')

$failures = 0
$checks = 0

def check(name)
  $checks += 1
  yield
rescue StandardError => e
  $failures += 1
  warn "  FAIL #{name}: #{e.class}: #{e.message}"
  warn "    #{e.backtrace.first}"
end

def eq(expected, actual, msg = nil)
  return if expected == actual
  raise "expected #{expected.inspect}, got #{actual.inspect}#{msg ? " (#{msg})" : ''}"
end

def ok(cond, msg = 'expected truthy')
  raise msg unless cond
end

def combatant(name, atk, dfn, agi, hp)
  Game::Battle::Combatant.new(name, atk, dfn, agi, hp, hp)
end

# -- gauge is inert for turn-based battles (battle_type 0) -------------------
check 'default battle_type is 0 (turn-based)' do
  bat = Game::Battle.new([combatant('A', 1, 1, 10, 1)], [combatant('B', 1, 1, 5, 1)], Game::Rng.new(1))
  eq 0, bat.battle_type
end

check 'Game::Battle.new accepts battle_type: and activates the gauge' do
  bat = Game::Battle.new([combatant('A', 1, 1, 20, 1)], [combatant('B', 1, 1, 10, 1)],
                         Game::Rng.new(1), nil, false, false, false, false, nil, nil,
                         battle_type: 2)
  eq 2, bat.battle_type
  bat.advance_gauges(6)
  eq Game::Battle::GAUGE_MAX, bat.all_combatants[0].gauge
end

check 'advance_gauges is a no-op for battle_type 0' do
  bat = Game::Battle.new([combatant('A', 1, 1, 10, 1)], [combatant('B', 1, 1, 5, 1)], Game::Rng.new(1))
  bat.advance_gauges(100)
  eq 0, bat.all_combatants.map(&:gauge).max
  eq 0, bat.ready_combatants.size
end

# -- gauge fills proportional to AGI for the 2003 gauge presentation ---------
fast = combatant('Fast', 1, 1, 20, 1)   # 20 gauge/tick -> full in 5 ticks
slow = combatant('Slow', 1, 1, 10, 1)   # 10 gauge/tick -> full in 10 ticks
bat = Game::Battle.new([fast], [slow], Game::Rng.new(1))
bat.battle_type = 2

check 'after 6 ticks the faster battler is full, the slower is not' do
  bat.advance_gauges(6)
  eq Game::Battle::GAUGE_MAX, fast.gauge
  eq 60, slow.gauge
  ready = bat.ready_combatants
  eq [fast], ready
end

check 'after 10 ticks both are full' do
  bat.advance_gauges(4)
  eq Game::Battle::GAUGE_MAX, slow.gauge
  eq 2, bat.ready_combatants.size
end

check 'ready_combatants is ordered by gauge descending' do
  # Bump the slower one past max so it sorts first, then re-check ordering.
  slow.gauge = Game::Battle::GAUGE_MAX + 5
  eq [slow, fast], bat.ready_combatants
end

check 'a dead battler does not charge or become ready' do
  dead = combatant('Dead', 1, 1, 50, 1)
  dead.hp = 0
  bat2 = Game::Battle.new([dead], [combatant('Live', 1, 1, 10, 1)], Game::Rng.new(1))
  bat2.battle_type = 2
  bat2.advance_gauges(100)
  eq 0, dead.gauge
  eq false, dead.gauge_full?
end

puts "rpg2k3 battle gauge check: #{$checks} checks, #{$failures} failures"
exit($failures.zero? ? 0 : 1)
