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
DB_SKILL = 12
DB_ITEM = 13
DB_STATE = 18
CHANGE_PARTY = Game::Interpreter::Cmd::CHANGE_PARTY

# Commands that name one actor by a fixed id rather than acting on the party.
# RPG_RT resolves all of these through Game_Actors, so they reach a member who
# is currently out of the party. `:scope` means param0 selects party (0) / this
# actor (1) / variable-indexed actor (2) with the id in param1; `:actor0` means
# param0 *is* the actor id.
Cmd = Game::Interpreter::Cmd
FIXED_ACTOR_COMMANDS = {
  Cmd::CHANGE_EXP => :scope,       Cmd::CHANGE_LEVEL => :scope,
  Cmd::CHANGE_PARAM => :scope,     Cmd::CHANGE_SKILLS => :scope,
  Cmd::CHANGE_EQUIP => :scope,     Cmd::CHANGE_HP => :scope,
  Cmd::CHANGE_MP => :scope,        Cmd::CHANGE_CONDITION => :scope,
  Cmd::FULL_HEAL => :scope,        Cmd::SIMULATED_ATTACK => :scope,
  Cmd::CHANGE_ACTOR_NAME => :actor0,   Cmd::CHANGE_ACTOR_TITLE => :actor0,
  Cmd::CHANGE_ACTOR_SPRITE => :actor0, Cmd::CHANGE_ACTOR_FACE => :actor0,
}.freeze

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

# Every fixed-actor-id command anywhere in the game (common events, troop pages
# and map event pages), as { actor_id => [command, ...] }.
def fixed_actor_commands(db, dir)
  out = Hash.new { |h, k| h[k] = [] }
  collect = lambda do |cmds|
    next unless cmds.is_a?(Array)
    cmds.each do |c|
      layout = FIXED_ACTOR_COMMANDS[c.code] or next
      aid = layout == :actor0 ? c.param(0) : (c.param(0) == 1 ? c.param(1) : nil)
      out[aid] << c if aid && aid > 0
    end
  end
  db[DB_COMMON_EVENT]&.each { |_id, ev| collect.call(ev[CE_COMMANDS]) }
  db[15]&.each { |_g, g| g[11]&.each { |_p, pg| collect.call(pg[12]) } }
  Dir[File.join(dir, 'Map*.lmu')].sort.each do |f|
    mu = LCF::MapUnit.new(File.open(f, 'rb'))
    mu[81]&.each { |_e, ev| ev[5]&.each { |_p, pg| collect.call(pg[52]) } }
  end
  out
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

  # A command that names one actor by a fixed id acts on that actor wherever they
  # are — RPG_RT looks them up in Game_Actors, not the party. In a game that
  # swaps members this is not a corner case: every such command Nepheshel issues
  # names a companion it also dismisses, so a party-only lookup drops all of
  # them whenever the target happens to be away.
  fixed = fixed_actor_commands(db, dir)
  aimed_at_companions = fixed.select { |aid, _| companions.include?(aid) }
  n = aimed_at_companions.values.map(&:size).inject(0) { |a, b| a + b }
  puts "   #{n} fixed-actor-id command(s) name a swappable companion"

  aimed_at_companions.keys.sort.each do |aid|
    check "#{name}: fixed-id commands reach actor #{aid} while away" do
      state = Game::State.new(Game::Party.new(db, party_ids), 1, 0, 0)
      run(state, [adds[aid]])
      ok state.party.actor_by_id(aid), "actor #{aid} joined"
      run(state, [removes[aid]])
      eq nil, state.party.actor_by_id(aid), "actor #{aid} is away"

      # The game's own commands, run while the target is out of the party. Every
      # one must find its actor; none may silently no-op.
      away = state.party.roster.existing(aid)
      ok away, 'the absent actor is still in the roster'
      before = snapshot(away)
      aimed_at_companions[aid].each { |c| run(state, [c]) }
      ok snapshot(away) != before,
         "#{aimed_at_companions[aid].size} command(s) changed the absent actor"
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

# What the menus offer a party that knows everything and carries one of each.
#
# A real game's skills and items have to reach its menus, and "reaches nothing"
# is the failure this catches: gating every skill on `occasion_battle` (a flag
# RPG2000 only writes for switch skills) left the battle skill menu **empty in
# both test beds** — 306 skills and 134 skills, none of them offered — while
# every fixture check passed.
def check_menus(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
  leader = party.leader
  unless leader
    puts "   (no party leader — menus skipped)"
    return
  end
  skill_ids = []
  db[DB_SKILL]&.each { |id, _| skill_ids << id }
  skill_ids.each { |id| leader.learn_skill(id) }
  leader.mp = 99_999                     # affordability is not what is under test
  db[DB_ITEM]&.each { |id, _| party.gain_item(id, 1) }

  field_skills = party.field_skills(leader)
  battle_skills = party.battle_skills(leader, leader)
  field_items = party.field_items
  battle_items = party.battle_items
  puts format('   menus: %d/%d skills field/battle, %d/%d items field/battle ' \
              '(of %d skills, %d items)',
              field_skills.size, battle_skills.size, field_items.size,
              battle_items.size, skill_ids.size, party.items.size)

  check "#{name}: the battle skill menu is not empty" do
    ok battle_skills.size > 0, "#{skill_ids.size} skills, none offered in battle"
  end
  check "#{name}: the field skill menu is not empty" do
    ok field_skills.size > 0, "#{skill_ids.size} skills, none offered in the field"
  end
  check "#{name}: the field item menu is not empty" do
    ok field_items.size > 0, 'the bag holds one of everything and offers nothing'
  end

  # Every skill kind the game actually uses has to be reachable somewhere: a
  # skill offered in neither menu is one no player can ever cast. Escape and
  # teleport skills are the known exception (see Party#unsupported_field_skill?).
  check "#{name}: no skill is unreachable from both menus" do
    unreachable = skill_ids.reject do |id|
      sk = party.db_skill(id)
      next true if party.unsupported_field_skill?(sk)
      party.field_skill?(sk) || party.battle_skill?(sk)
    end
    eq [], unreachable.first(8), "#{unreachable.size} skill(s) castable nowhere"
  end

  # Special items (type 9) invoke a skill; switch items (type 10) flip a switch.
  # Reading those two the other way round put the special items on the switch
  # branch, where they flipped the switch id they never set — the default, 1.
  special = []
  switch = []
  db[DB_ITEM]&.each do |id, it|
    special << id if it.type == Game::Party::ITEM_SPECIAL
    switch << id if it.type == Game::Party::ITEM_SWITCH
  end
  return if special.empty? && switch.empty?
  puts "   #{special.size} special item(s), #{switch.size} switch item(s)"

  check "#{name}: special items invoke a real skill, switch items a real switch" do
    special.each do |id|
      sk = party.db_skill(party.db_item(id).skill_id)
      ok sk, "special item ##{id} names a skill that exists"
      ok party.field_usable?(id) || party.battle_usable?(id),
         "special item ##{id} (#{sk.name}) is usable somewhere"
    end
    switch.each do |id|
      sid = party.db_item(id).switch_id
      ok sid && sid > 1,
         "switch item ##{id} names a switch of its own, not the default 1"
      ok party.switch_item?(id), "switch item ##{id} is recognised as one"
    end
  end
end

# The status effects a real game's 状態 table asks for, exercised against that
# table. A state whose numbers the runtime never reads is a status that does
# nothing — Blind not blinding, a blow never waking a sleeper, Silence not
# silencing — and that is invisible to any fixture built from the same
# assumption. See docs/adr/0032-state-effects.md.
def combatant(name, atk, dfn, agi, hp, states = [])
  c = Game::Battle::Combatant.new(name, atk, dfn, agi, hp, hp)
  c.states = states
  c.state_turns = {}
  c.hit_rate = 90
  c
end

def check_states(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  states = db[DB_STATE]
  return unless states

  blinding = []
  waking = []
  sealing = []
  states.each do |id, r|
    blinding << id if r.reduce_hit_ratio && r.reduce_hit_ratio < 100
    waking << id if (r.release_by_attack || 0) > 0
    sealing << id if r.restrict_magic || r.restrict_skill
  end
  puts format('   states: %d blinding, %d shaken off by a blow, %d sealing',
              blinding.size, waking.size, sealing.size)

  unless blinding.empty?
    check "#{name}: a blinding state cuts accuracy" do
      foe = combatant('Foe', 0, 0, 10, 100)
      bat = Game::Battle.new([combatant('A', 10, 0, 10, 100)], [foe],
                             Game::Rng.new(1), states, false, false, true)
      clear = bat.allies[0]
      base = bat.send(:to_hit, clear, foe)
      ok base > 0, 'an unafflicted attacker can hit'
      blinding.each do |sid|
        clear.states = [sid]
        ratio = states[sid].reduce_hit_ratio
        eq base * ratio / 100, bat.send(:to_hit, clear, foe),
           "state ##{sid} (#{states[sid].name}) scales accuracy by #{ratio}%"
      end
    end
  end

  unless waking.empty?
    check "#{name}: a blow shakes off a state that allows it" do
      # Roll each state many times; a state set to N% must come off sometimes and
      # a 100% one every time. Seeds vary so the rolls do.
      sid = waking.max_by { |i| states[i].release_by_attack }
      shaken = 0
      200.times do |i|
        foe = combatant('Foe', 0, 0, 5, 1000, [sid])
        bat = Game::Battle.new([combatant('A', 10, 0, 10, 100)], [foe],
                               Game::Rng.new(i + 1), states)
        shaken += 1 if bat.send(:deal_attack, bat.allies[0], foe)[:woke]
      end
      ok shaken > 0,
         "state ##{sid} (#{states[sid].name}, #{states[sid].release_by_attack}%) " \
         'never came off in 200 blows'
    end
  end

  unless sealing.empty?
    check "#{name}: a sealing state seals magic but not plain physical skills" do
      bat = Game::Battle.new([combatant('A', 10, 0, 10, 100)],
                             [combatant('B', 0, 0, 5, 100)], Game::Rng.new(1), states)
      caster = bat.allies[0]
      sealing.each do |sid|
        caster.states = [sid]
        sealed = 0
        physical_sealed = 0
        total_magic = 0
        db[DB_SKILL]&.each do |_id, sk|
          if (sk.magical_rate || 0) > 0
            total_magic += 1
            sealed += 1 if bat.skill_sealed?(caster, sk)
          elsif (sk.physical_rate || 0) == 0
            physical_sealed += 1 if bat.skill_sealed?(caster, sk)
          end
        end
        next unless states[sid].restrict_magic
        ok total_magic.zero? || sealed > 0,
           "state ##{sid} (#{states[sid].name}) seals no magic at all"
        eq 0, physical_sealed,
           "state ##{sid} left rate-0 skills alone"
      end
    end
  end
end

dirs.each { |d| check_game(d); check_menus(d); check_states(d) }

if $failures.zero?
  puts "rpg2k test-bed logic check: #{$checks} checks passed"
else
  warn "rpg2k test-bed logic check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
