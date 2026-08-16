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
require 'ostruct'
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

# -- the active-time turn cycle: pop_ready consumes and resets --------------
cycle_fast = combatant('CFast', 1, 1, 20, 1)
cycle_slow = combatant('CSlow', 1, 1, 10, 1)
cbat = Game::Battle.new([cycle_fast], [cycle_slow], Game::Rng.new(1))
cbat.battle_type = 2
cbat.advance_gauges(6)   # fast full (100), slow at 60

check 'pop_ready returns the highest-gauge combatant and resets its gauge' do
  taken = cbat.pop_ready
  eq cycle_fast, taken
  eq 0, cycle_fast.gauge
  eq false, cycle_fast.gauge_full?
  # slow is still charging, so nothing else is ready yet
  eq [], cbat.ready_combatants
end

check 'after the taker refills it becomes ready again (the ATB loop repeats)' do
  cbat.advance_gauges(5)   # fast: 0 -> 100 (agi 20 * 5); slow: 60 -> 110 -> 100
  eq 2, cbat.ready_combatants.size
  taken = cbat.pop_ready
  eq cycle_fast, taken   # fast reached full first again
  eq 0, cycle_fast.gauge
end

check 'pop_ready is nil for a turn-based battle' do
  tbat = Game::Battle.new([combatant('A', 1, 1, 20, 1)], [combatant('B', 1, 1, 10, 1)], Game::Rng.new(1))
  eq nil, tbat.pop_ready
end

# -- begin_gauge_turn: the per-ready-combatant action the scene's picker primes
# -- (RPG2k3::Scene::Battle#drive_battle_atb), the single-battler counterpart
# -- to begin_round's whole agility-ordered queue ----------------------------
turn_hero = combatant('THero', 30, 0, 20, 1000)
turn_slime = combatant('TSlime', 0, 0, 5, 1000)
tbat = Game::Battle.new([turn_hero], [turn_slime], Game::Rng.new(1))
tbat.battle_type = 2
tbat.advance_gauges(5) # the hero's gauge is full

check 'begin_gauge_turn queues one battler: step_action plays its turn, then nothing remains' do
  tbat.command_attack(turn_hero, turn_slime)
  tbat.begin_gauge_turn(turn_hero)
  eq 0, turn_hero.gauge, 'the fired gauge was consumed'
  entry = tbat.step_action
  ok entry, 'the queued battler acted'
  eq 'TSlime', entry[:target], 'against the commanded target'
  eq nil, tbat.step_action, 'no second battler is in the queue -- the turn is done'
end

check 'begin_gauge_turn bumps the battler\'s per-battler turn counter, not the round count' do
  eq 1, turn_hero.turns_taken, 'the battler\'s own page-condition turn counter ticks'
  eq 0, tbat.turn, 'but the RPG2000-style round count stays 0 -- a gauge battle has no rounds'
  eq nil, tbat.ready_combatants.first, 'and the consumed gauge is no longer ready'
end

check 'a do-nothing-restricted battler\'s gauge turn is consumed as a silent no-op' do
  asleep = combatant('Asleep', 30, 0, 20, 1000)
  asleep.states = [4] # Sleep: restriction 1
  states = { 4 => OpenStruct.new(restriction: Game::Battle::RESTRICTION_DO_NOTHING) }
  abat = Game::Battle.new([asleep], [combatant('Awake', 0, 0, 5, 1000)],
                          Game::Rng.new(1), states, false, false, false, false,
                          nil, nil, battle_type: 2)
  abat.advance_gauges(5)
  eq Game::Battle::GAUGE_MAX, asleep.gauge, 'ready to act'
  abat.begin_gauge_turn(asleep)
  eq 0, asleep.gauge, 'the turn consumed the gauge even though it cannot act'
  eq 1, asleep.turns_taken, 'the skipped turn still counts as the battler\'s turn'
  eq nil, abat.step_action, 'the restriction resolved the turn to no action at all'
end

puts "rpg2k3 battle gauge check: #{$checks} checks, #{$failures} failures"
exit($failures.zero? ? 0 : 1)
