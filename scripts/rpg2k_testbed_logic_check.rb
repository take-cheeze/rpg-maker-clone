#!/usr/bin/env ruby
# encoding: UTF-8
#
# Run the RPG2000 game logic against the *real* test-bed databases.
#
# scripts/rpg2k_logic_check.rb exercises Game::* against hand-built fixtures and
# scripts/lcf_testbed_check.rb parses the real games without running them. This
# harness is the join: it loads a genuine RPG_RT.ldb through the pure-Ruby LCF
# parser and drives the actual event commands the game ships through
# Game::Interpreter, so a rule that only real data violates gets caught.
#
# It exists because of one such rule. Nepheshel's whole companion mechanic is
# Change Party Member (5205 of them, none in the other test bed), and the party
# used to rebuild an actor from the database row on every add — so a dismissed
# companion came back at level 1 with none of their EXP, skills or renaming.
# A fixture check passes either way; only the real game's add/remove pairs show
# how much of the game that covers. See docs/adr/0030-permanent-actor-roster.md.
#
# Usage:
#   ruby scripts/rpg2k_testbed_logic_check.rb [GAME_DIR ...]
# With no arguments it scans ./data for directories containing an RPG_RT.ldb.
# A game that ships no Change Party Member is reported and skipped, not failed;
# exits non-zero on any violated invariant.

require 'stringio'

module LCF
  # uni-algo stand-in, as in scripts/lcf_testbed_check.rb: only structural,
  # encoding-independent invariants are asserted, so the shim never affects the
  # result.
  def cp932_to_utf8(s)
    s.dup.force_encoding('Windows-31J')
     .encode('UTF-8', invalid: :replace, undef: :replace, replace: "\u{fffd}")
  end

  # The write direction, for the .lsd export round trip below.
  def utf8_to_cp932(s)
    s.dup.encode('Windows-31J', invalid: :replace, undef: :replace)
     .force_encoding('BINARY')
  end
  module_function :cp932_to_utf8, :utf8_to_cp932

  def self.max_level; MODE == 2003 ? 99 : 50; end
end

# The two names Game::* references at load time; neither is reached from the
# command paths under test (see scripts/rpg2k_logic_check.rb).
module RGSS
  module Audio
    class << self
      def bgm_play(*); end
      def bgm_fade(*); end
      def se_play(*); end
    end
  end
  def self.warn_stub(*); end
end

root = File.expand_path('..', __dir__)
load File.join(root, 'mruby-lcf/mrblib/lcf.rb')
load File.join(root, 'mruby-lcf/mrblib/schema.rb')
load File.join(root, 'mruby-rpg2k/mrblib/game.rb')
load File.join(root, 'mruby-rpg2k/mrblib/interpreter.rb')

# Database chunk ids used directly. `db.system` is unusable here — it resolves to
# Kernel#system under CRuby (see AGENTS.md) — so the System section and its
# initial-party field are read by id.
DB_SYSTEM = 22
SYS_PARTY = 22
DB_COMMON_EVENT = 25
CE_COMMANDS = 22
CHANGE_PARTY = Game::Interpreter::Cmd::CHANGE_PARTY

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

# Every Change Party Member command in the game's common events, as
# [command, add?, actor_id] — only the ones naming a constant actor id
# (param1 == 0; the variable-indexed form depends on runtime state).
def change_party_commands(db)
  out = []
  ce = db[DB_COMMON_EVENT]
  return out unless ce
  ce.each do |_id, ev|
    cmds = ev[CE_COMMANDS]
    next unless cmds.is_a?(Array)
    cmds.each do |c|
      next unless c.code == CHANGE_PARTY && c.param(1) == 0
      out << [c, c.param(0) == 0, c.param(2)]
    end
  end
  out
end

# Run a command list to completion through a real interpreter, releasing the
# presentation waits (message / timed wait / screen effect) nothing is driving.
def run(state, cmds, limit = 200)
  interp = Game::Interpreter.new(state)
  interp.start(cmds)
  limit.times do
    break unless interp.running?
    interp.update
    next unless interp.waiting?
    break unless [:message, :wait, :screen].include?(interp.wait_kind)
    interp.resume
  end
  interp
end

# A snapshot of everything a party member should not lose by stepping out.
def snapshot(a)
  { level: a.level, exp: a.exp, name: a.name, hp: a.hp, mp: a.mp,
    skills: a.skills.dup.sort, equipment: a.equipment.dup, states: a.states.dup.sort }
end

def check_game(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  party_ids = db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil

  swaps = change_party_commands(db)
  adds = {}
  removes = {}
  swaps.each do |cmd, add, aid|
    (add ? adds : removes)[aid] ||= cmd
  end
  # Actors the game both adds and removes: its swappable companions.
  companions = adds.keys.select { |aid| removes.key?(aid) }.sort
  puts "== #{name}: #{swaps.size} constant-id Change Party Member command(s) in " \
       "its common events, #{companions.size} swappable companion(s) " \
       "#{companions.inspect}"
  if companions.empty?
    puts '   (no companion swaps to exercise — skipped)'
    return
  end

  companions.each do |aid|
    check "#{name}: actor #{aid} survives a real remove/add pair" do
      state = Game::State.new(Game::Party.new(db, party_ids), 1, 0, 0)
      # Bring the companion in through the game's own add command, then give
      # them something to lose.
      run(state, [adds[aid]])
      actor = state.party.actor_by_id(aid)
      ok actor, "the game's own Change Party Member did not add actor #{aid}"
      actor.change_level_by(5)
      actor.name = "#{actor.name}+"
      actor.hp = 1
      before = snapshot(actor)
      ok before[:level] > 1, 'the companion levelled up before the swap'

      run(state, [removes[aid]])
      eq nil, state.party.actor_by_id(aid), 'left the party'

      run(state, [adds[aid]])
      back = state.party.actor_by_id(aid)
      ok back, 'rejoined the party'
      eq before, snapshot(back), 'rejoined with everything they left with'
    end

    check "#{name}: actor #{aid} survives a save taken while away" do
      state = Game::State.new(Game::Party.new(db, party_ids), 1, 0, 0)
      run(state, [adds[aid]])
      actor = state.party.actor_by_id(aid)
      actor.change_level_by(5)
      actor.name = "#{actor.name}+"
      actor.hp = 1
      before = snapshot(actor)
      run(state, [removes[aid]])   # away when the game is saved

      loaded = Game::State.load(db, state.to_h)
      run(loaded, [adds[aid]])
      back = loaded.party.actor_by_id(aid)
      ok back, 'rejoined the reloaded party'
      eq before, snapshot(back), 'rejoined intact after Save / Continue'
    end

    check "#{name}: actor #{aid} survives a .lsd round trip while away" do
      state = Game::State.new(Game::Party.new(db, party_ids), 1, 0, 0)
      run(state, [adds[aid]])
      actor = state.party.actor_by_id(aid)
      actor.change_level_by(5)
      actor.hp = 1
      before = snapshot(actor)
      run(state, [removes[aid]])

      # A genuine Save<N>.lsd keeps chunk 108 for every actor the party has
      # held, so the export/import pair has to carry the absent companion too.
      lsd = LCF::SaveData.new(StringIO.new(state.to_lsd.to_lcf))
      ok lsd[108][aid], "chunk 108 holds the absent actor #{aid}"
      loaded = Game::State.from_lsd(db, lsd)
      run(loaded, [adds[aid]])
      back = loaded.party.actor_by_id(aid)
      ok back, 'rejoined after the .lsd round trip'
      # The .lsd carries no per-actor name override for a non-leader member
      # (only the title chunk's leader name), which is a known export gap — see
      # docs/TODO.md. Everything else has a field and must come back.
      [:level, :exp, :hp, :mp, :skills, :equipment, :states].each do |f|
        eq before[f], snapshot(back)[f], "#{f} survived the .lsd round trip"
      end
    end
  end
end

dirs = ARGV
if dirs.empty?
  dirs = Dir[File.join(root, 'data', '**', 'RPG_RT.ldb')].map { |f| File.dirname(f) }.sort
end
if dirs.empty?
  puts 'no RPG2000 game dir found under ./data (download a test bed first) — skipped'
  exit 0
end

dirs.each { |d| check_game(d) }

if $failures.zero?
  puts "rpg2k test-bed logic check: #{$checks} checks passed"
else
  warn "rpg2k test-bed logic check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
