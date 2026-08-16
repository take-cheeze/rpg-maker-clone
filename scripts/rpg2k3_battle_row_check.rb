#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side unit checks for the RPG2003 front/back row battle mechanic
# (ADR 0053, Phase 1). The row is an RPG2003-only concept: a back-row
# defender is harder to hit by a physical attack. RPG2000 never sets a row,
# so the path is a no-op there and these checks exercise the 2003 behaviour
# directly on the shared hit-chance helpers in mruby-rpg2k/mrblib/game.rb.
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

# A minimal Party (no roster needed for the row helper / skill_to_hit).
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

# -- Battle#to_hit integration ----------------------------------------------
bat = Game::Battle.new([front], [front], Game::Rng.new(1))
attacker = bat.allies[0]
target_front = bat.enemies[0]
target_back = target_front.dup
target_back.row = Game::Battle::ROW_BACK

check 'Battle#row_hit_modifier: 100 for a front defender' do
  eq 100, bat.row_hit_modifier(attacker, target_front)
end

check 'Battle#row_hit_modifier: 50 for a back defender' do
  eq Game::Battle::ROW_BACK_DEFENDER_HIT_MULT, bat.row_hit_modifier(attacker, target_back)
end

check 'back-row defender is strictly harder to hit (basic attack)' do
  front_hit = bat.to_hit(attacker, target_front)
  back_hit = bat.to_hit(attacker, target_back)
  ok back_hit < front_hit, "expected back-row hit (#{back_hit}) < front hit (#{front_hit})"
  eq (front_hit * Game::Battle::ROW_BACK_DEFENDER_HIT_MULT / 100), back_hit,
      'back-row hit should be the front hit scaled by the row multiplier'
end

# -- Party#skill_to_hit integration (the 2003 physical-skill path) -----------
party = fake_party
src = combatant('Src', 50, 0, 20, 10_000)
sk = Object.new
def sk.hit; 90; end
def sk.failure_message; 3; end   # physical skill -> agility/evasion branch
def sk.scope; 0; end

tgt_front = combatant('TgtF', 0, 0, 5, 10_000)
tgt_back = combatant('TgtB', 0, 0, 5, 10_000)
tgt_back.row = Game::Battle::ROW_BACK

check 'Party#row_hit_modifier: 50 for a back defender' do
  eq Game::Battle::ROW_BACK_DEFENDER_HIT_MULT, party.row_hit_modifier(src, tgt_back)
end

check 'back-row defender is harder to hit by a physical skill' do
  front_hit = party.skill_to_hit(sk, src, tgt_front)
  back_hit = party.skill_to_hit(sk, src, tgt_back)
  ok back_hit < front_hit, "expected back-row skill hit (#{back_hit}) < front (#{front_hit})"
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

puts "rpg2k3 battle row check: #{$checks} checks, #{$failures} failures"
exit($failures.zero? ? 0 : 1)
