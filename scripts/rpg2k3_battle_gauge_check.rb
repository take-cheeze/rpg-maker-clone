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
  bat.advance_gauges(1)
  eq 2112, bat.all_combatants[0].gauge, 'A (agi 20, half the field\'s agi sum) gains 2112/frame'
  eq 1102, bat.all_combatants[1].gauge, 'B (agi 10) gains 1102/frame'
end

check 'advance_gauges is a no-op for battle_type 0' do
  bat = Game::Battle.new([combatant('A', 1, 1, 10, 1)], [combatant('B', 1, 1, 5, 1)], Game::Rng.new(1))
  bat.advance_gauges(100)
  eq 0, bat.all_combatants.map(&:gauge).max
  eq 0, bat.ready_combatants.size
end

# -- gauge fills by EasyRPG's relative curve for the 2003 gauge presentation ---
# Port of Game_Battle::UpdateAtbGauges (src/game_battle.cpp): every non-hidden
# battler's AGI is summed (times 100), and each battler's per-frame increment
# is GAUGE_MAX / (sum_agi / (agi + 1)), all integer-truncated -- so the faster
# battler fills first but the field charges together, not at independent rates.
fast = combatant('Fast', 1, 1, 20, 1)   # 300000 / (3000/21) = 2112/frame
slow = combatant('Slow', 1, 1, 10, 1)   # 300000 / (3000/11) = 1102/frame
bat = Game::Battle.new([fast], [slow], Game::Rng.new(1))
bat.battle_type = 2

check 'after one tick the faster battler is ahead by exactly the relative curve' do
  bat.advance_gauges(1)
  eq 2112, fast.gauge
  eq 1102, slow.gauge
  eq [], bat.ready_combatants, 'neither is anywhere near full at one tick (max 300000)'
end

check 'the faster battler fills before the slower, and both reach full (143 vs 273 ticks)' do
  bat.advance_gauges(142) # 143 ticks total
  eq Game::Battle::GAUGE_MAX, fast.gauge, 'fast crosses 300000 first (143 ticks)'
  ok slow.gauge < Game::Battle::GAUGE_MAX, 'slow is still charging (273 ticks to fill)'
  eq [fast], bat.ready_combatants, 'only the fast one is ready'
  bat.advance_gauges(130) # 273 ticks total
  eq Game::Battle::GAUGE_MAX, slow.gauge, 'slow crosses too (273 ticks)'
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

check 'a do-nothing-restricted ally never charges, matching EasyRPG\'s CanAct() gate' do
  asleep = combatant('Asleep', 1, 1, 20, 1)
  asleep.states = [4] # Sleep: restriction 1
  states = { 4 => OpenStruct.new(restriction: Game::Battle::RESTRICTION_DO_NOTHING) }
  abat = Game::Battle.new([asleep], [combatant('Awake', 1, 1, 5, 1)],
                          Game::Rng.new(1), states, false, false, false, false,
                          nil, nil, battle_type: 2)
  abat.advance_gauges(300)
  eq 0, asleep.gauge, 'a restricted ally cannot take a turn, so it does not charge'
  ok abat.all_combatants[1].gauge > 0, 'the awake enemy charges normally'
end

# -- the active-time turn cycle: pop_ready consumes and resets --------------
cycle_fast = combatant('CFast', 1, 1, 20, 1)
cycle_slow = combatant('CSlow', 1, 1, 10, 1)
cbat = Game::Battle.new([cycle_fast], [cycle_slow], Game::Rng.new(1))
cbat.battle_type = 2
cbat.advance_gauges(143) # fast full (300000), slow at 143 * 1102 = 157586

check 'pop_ready returns the highest-gauge combatant and resets its gauge' do
  taken = cbat.pop_ready
  eq cycle_fast, taken
  eq 0, cycle_fast.gauge
  eq false, cycle_fast.gauge_full?
  # slow is still charging (157586 < 300000), so nothing else is ready yet
  eq [], cbat.ready_combatants
end

check 'after the taker refills it becomes ready again (the ATB loop repeats)' do
  cbat.advance_gauges(143) # fast: 0 -> 300000; slow: 157586 + 157586 -> 300000
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
tbat.advance_gauges(120) # the hero's gauge is full: 300000 / (2500/21) = 2521/frame

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
  # A restricted ally never *charges* (see the check above), but a full gauge
  # one somehow has still fires its turn -- and the restriction resolves it to
  # a silent no-op, exactly as if it could act.
  asleep.gauge = Game::Battle::GAUGE_MAX
  eq Game::Battle::GAUGE_MAX, asleep.gauge, 'ready to act'
  abat.begin_gauge_turn(asleep)
  eq 0, asleep.gauge, 'the turn consumed the gauge even though it cannot act'
  eq 1, asleep.turns_taken, 'the skipped turn still counts as the battler\'s turn'
  eq nil, abat.step_action, 'the restriction resolved the turn to no action at all'
end

puts "rpg2k3 battle gauge check: #{$checks} checks, #{$failures} failures"
exit($failures.zero? ? 0 : 1)
