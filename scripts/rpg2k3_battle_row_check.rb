#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side unit checks for the RPG2003 front/back row battle mechanic
# (ADR 0053 Phase 1, resolved against EasyRPG's Algo::IsRowAdjusted /
# CalcNormalAttackToHit / CalcNormalAttackEffect, src/algo.cpp). The row is an
# RPG2003-only concept: it changes how the fight treats a battler -- a back-row
# defender is 25 harder to hit and takes -25% damage, a front-row actor deals
# +25% damage, and an enemy attacker (or a back-row attacker) is not row-
# adjusted at all. RPG2000 never sets a row, so the path is a no-op there and
# these checks exercise the 2003 behaviour directly on the shared helpers in
# mruby-rpg2k/mrblib/game.rb. Skills are deliberately NOT row-adjusted (the
# reference gates that behind an EasyRPG-only field absent from real files).
#
# Usage: ruby scripts/rpg2k3_battle_row_check.rb   (exits non-zero on failure)

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

# A bare combatant (mirrors scripts/rpg2k_logic_check.rb#combatant).
def combatant(name, atk, dfn, agi, hp)
  Game::Battle::Combatant.new(name, atk, dfn, agi, hp, hp)
end

# A minimal Party (no roster needed for the skill_to_hit checks).
def fake_party
  db = Object.new
  def db.system; Struct.new(:party).new([]); end
  Game::Party.new(db)
end

front = combatant('Front', 50, 0, 20, 10_000)
back = combatant('Back', 50, 0, 20, 10_000)
back.row = Game::Battle::ROW_BACK

# -- the row model ----------------------------------------------------------
check 'combatant defaults to the front row' do
  c = combatant('C', 1, 1, 1, 1)
  eq Game::Battle::ROW_FRONT, c.row
  eq false, c.back_row?
end

check 'setting ROW_BACK makes back_row? true' do
  eq true, back.back_row?
  eq false, front.back_row?
end

# -- can_leave_front_row?/toggle_row (RowSelected's front_row_battlers
#    headcount, EasyRPG's own `Game_Party::GetActors()` loop -- unfiltered by
#    HP/hidden, only a party member who has actually left the roster drops
#    out) -------------------------------------------------------------------
check 'a KO\'d front-row ally still counts toward keeping the front row ' \
      'non-empty, so a living front-row ally may still step back' do
  alive = combatant('Alive', 10, 5, 8, 100)
  alive.row = Game::Battle::ROW_FRONT
  dead = combatant('Dead', 10, 5, 8, 100)
  dead.row = Game::Battle::ROW_FRONT
  dead.hp = 0

  bat = Game::Battle.new([alive, dead], [combatant('Enemy', 5, 5, 5, 50)], Game::Rng.new(1))

  eq true, bat.can_leave_front_row?(alive)
  eq true, bat.toggle_row(alive)
  eq Game::Battle::ROW_BACK, alive.row
end

check 'a lone living front-row ally may not step back merely because a ' \
      'dead ally is also nominally front-row' do
  alive = combatant('Alive', 10, 5, 8, 100)
  alive.row = Game::Battle::ROW_FRONT
  dead = combatant('Dead', 10, 5, 8, 100)
  dead.row = Game::Battle::ROW_BACK
  dead.hp = 0

  bat = Game::Battle.new([alive, dead], [combatant('Enemy', 5, 5, 5, 50)], Game::Rng.new(1))

  eq false, bat.can_leave_front_row?(alive)
  eq false, bat.toggle_row(alive)
  eq Game::Battle::ROW_FRONT, alive.row
end

# -- row_adjusted? (the Algo::IsRowAdjusted port) ----------------------------
# An actor-backed attacker in the front row is row-adjusted; a back-row actor
# attacker and every enemy attacker are not; a back-row defender is.
def actor_combatant(name, atk, dfn, agi)
  c = combatant(name, atk, dfn, agi, 10_000)
  c.actor = Object.new # ally?(battler) keys on a non-nil #actor
  c
end

bat = Game::Battle.new([front], [front], Game::Rng.new(1), rpg2003: true)
attacker = actor_combatant('Atk', 100, 0, 20)
target_front = bat.enemies[0]
target_back = target_front.dup
target_back.row = Game::Battle::ROW_BACK

check 'row_adjusted?: front-row ally attacker is adjusted' do
  eq true, bat.row_adjusted?(attacker, true)
end

check 'row_adjusted?: back-row ally attacker is not adjusted' do
  back_attacker = attacker.dup
  back_attacker.row = Game::Battle::ROW_BACK
  eq false, bat.row_adjusted?(back_attacker, true)
end

check 'row_adjusted?: an enemy attacker is never adjusted' do
  eq false, bat.row_adjusted?(target_front, true)
end

check 'row_adjusted?: a back-row defender is adjusted' do
  eq true, bat.row_adjusted?(target_back, false)
end

check 'row_adjusted?: a front-row defender is not adjusted' do
  eq false, bat.row_adjusted?(target_front, false)
end

# -- Battle#to_hit integration ----------------------------------------------
check 'a back-row defender is exactly 25 harder to hit (flat, not a multiplier)' do
  front_hit = bat.to_hit(attacker, target_front)
  back_hit = bat.to_hit(attacker, target_back)
  ok back_hit < front_hit, "expected back-row hit (#{back_hit}) < front hit (#{front_hit})"
  eq [front_hit - Game::Battle::ROW_HIT_PENALTY, 0].max, back_hit,
      'back-row hit should be the front hit less the flat 25 row penalty'
end

# -- deal_attack damage integration (CalcNormalAttackEffect order) -----------
# Variance and criticals off so the integer damage is deterministic:
#   attack_damage(100, 0) = 100/2 - 0/4 = 50
#   front-row attacker: 125 * 50 / 100 = 62   (attacker row, before attribute)
#   front defender: unchanged 62
#   back  defender: 75 * 62 / 100 = 46        (defender row, after attribute)
dmg_bat = Game::Battle.new([attacker], [target_front], Game::Rng.new(1),
                           nil, false, false, false, rpg2003: true)

check 'a front-row attacker deals +25% damage vs a front-row defender' do
  entry = dmg_bat.send(:deal_attack, attacker, target_front)
  eq 62, entry[:damage]
end

check 'a back-row defender takes -25% damage from the same swing' do
  entry = dmg_bat.send(:deal_attack, attacker, target_back)
  eq 46, entry[:damage]
end

check 'a back-row attacker loses the +25% bonus' do
  back_attacker = attacker.dup
  back_attacker.row = Game::Battle::ROW_BACK
  front_entry = dmg_bat.send(:deal_attack, attacker, target_front) # 50 *125/100 = 62
  back_entry = dmg_bat.send(:deal_attack, back_attacker, target_front) # base 50, no bonus
  eq 62, front_entry[:damage]
  eq 50, back_entry[:damage]
end

# -- skills are NOT row-adjusted (reference: gated behind an EasyRPG-only
#    field absent from real files) -------------------------------------------
party = fake_party
src = actor_combatant('Src', 50, 0, 20)
sk = Object.new
def sk.hit; 90; end
def sk.failure_message; 3; end   # physical skill -> agility/evasion branch
def sk.scope; 0; end

tgt_front = combatant('TgtF', 0, 0, 5, 10_000)
tgt_back = combatant('TgtB', 0, 0, 5, 10_000)
tgt_back.row = Game::Battle::ROW_BACK

check 'a physical skill is not harder to land on a back-row defender' do
  front_hit = party.skill_to_hit(sk, src, tgt_front)
  back_hit = party.skill_to_hit(sk, src, tgt_back)
  eq front_hit, back_hit,
      'vanilla RPG_RT skills are not row-adjusted; the hits should match'
end

# -- from_actor defaults to the front row ------------------------------------
actor = Object.new
def actor.name; 'A'; end
def actor.atk; 10; end
def actor.def; 5; end
def actor.agi; 8; end
def actor.hp; 100; end
def actor.max_hp; 100; end
def actor.mp; 0; end
def actor.max_mp; 0; end
def actor.int; 0; end
def actor.states; []; end

check 'from_actor leaves a battler in the front row by default' do
  c = Game::Battle.from_actor(actor)
  eq Game::Battle::ROW_FRONT, c.row
  eq false, c.back_row?
end

# -- row safety net (EasyRPG's Scene_Battle_Rpg2k3::InitActors "ROW
#    ADJUSTMENT"): a fight that would start with nobody able to act in the
#    front row forces everyone to the front, so back-row survivors are never
#    stuck behind a wiped-out front row for the rest of the fight. ----------

check 'an rpg2003 battle forces every ally to the front row when the whole ' \
      'front row starts dead and only back-row allies are alive' do
  dead_front = combatant('Front', 10, 5, 8, 100)
  dead_front.row = Game::Battle::ROW_FRONT
  dead_front.hp = 0
  alive_back = combatant('Back', 10, 5, 8, 100)
  alive_back.row = Game::Battle::ROW_BACK

  Game::Battle.new([dead_front, alive_back], [combatant('Enemy', 5, 5, 5, 50)],
                    Game::Rng.new(1), rpg2003: true)

  eq Game::Battle::ROW_FRONT, dead_front.row, 'the dead front-row ally is left front'
  eq Game::Battle::ROW_FRONT, alive_back.row, 'the living survivor is snapped to front'
end

check 'an rpg2003 battle leaves rows untouched when a living ally already ' \
      'occupies the front row' do
  alive_front = combatant('Front', 10, 5, 8, 100)
  alive_front.row = Game::Battle::ROW_FRONT
  alive_back = combatant('Back', 10, 5, 8, 100)
  alive_back.row = Game::Battle::ROW_BACK

  Game::Battle.new([alive_front, alive_back], [combatant('Enemy', 5, 5, 5, 50)],
                    Game::Rng.new(1), rpg2003: true)

  eq Game::Battle::ROW_FRONT, alive_front.row
  eq Game::Battle::ROW_BACK, alive_back.row, 'a living front-row ally means no forcing happens'
end

check 'an rpg2000 (non-2003) battle never forces rows, even with an ' \
      'all-dead front row' do
  dead_front = combatant('Front', 10, 5, 8, 100)
  dead_front.row = Game::Battle::ROW_FRONT
  dead_front.hp = 0
  alive_back = combatant('Back', 10, 5, 8, 100)
  alive_back.row = Game::Battle::ROW_BACK

  Game::Battle.new([dead_front, alive_back], [combatant('Enemy', 5, 5, 5, 50)],
                    Game::Rng.new(1))

  eq Game::Battle::ROW_BACK, alive_back.row, 'the row-forcing rule is 2003-only'
end

puts "rpg2k3 battle row check: #{$checks} checks, #{$failures} failures"
exit($failures.zero? ? 0 : 1)
