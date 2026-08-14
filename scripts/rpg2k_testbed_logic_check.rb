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
      def bgm_volume(*); end
      def bgm_pan(*); end
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
DB_ACTOR = 11
DB_TERRAIN = 16
DB_CHIPSET = 20
DB_ANIME = 19
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

# 蘇生専用 (`ko_only`): an item that does nothing at all to a target still
# standing -- not even its percentage HP restore, since RPG_RT returns from the
# item algorithm before both effects. Every such item in both test beds is a
# revive, which is the only shape that makes the distinction visible.
# The skill damage defence term, against the real skill table. Only a real game
# can say how much of its arsenal the old flat `def / 4` got wrong, and that the
# bulk of it is *purely magical* -- skills a target's armour should not touch.
def check_skill_defence(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  skills = db[DB_SKILL]
  return unless skills

  atk = []
  ignoring = []
  magical = 0
  skills.each do |id, sk|
    next unless sk.scope == 0 || sk.scope == 1
    atk << id
    ignoring << id if sk.ignore_defense
    magical += 1 if (sk.physical_rate || 0).zero? && (sk.magical_rate || 0) > 0
  end
  puts format('   skills: %d enemy-scope, %d 防御無視, %d purely magical',
              atk.size, ignoring.size, magical)
  return if atk.empty?

  party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)

  check "#{name}: every enemy-scope skill takes its own two-rate defence term" do
    foe = combatant('Foe', 0, 40, 5, 1000)
    foe.spi = 40
    atk.each do |id|
      sk = skills[id]
      want = if sk.ignore_defense
               0
             else
               (sk.physical_rate || 0) * 40 / 40 + (sk.magical_rate || 0) * 40 / 80
             end
      eq want, party.send(:skill_defence_term, sk, foe), "skill ##{id} (#{sk.name})"
    end
  end

  check "#{name}: a purely magical skill is indifferent to armour" do
    soft = combatant('Soft', 0, 0, 5, 1000)
    soft.spi = 40
    hard = combatant('Hard', 0, 999, 5, 1000)
    hard.spi = 40
    n = 0
    atk.each do |id|
      sk = skills[id]
      next unless (sk.physical_rate || 0).zero? && (sk.magical_rate || 0) > 0
      n += 1
      eq party.send(:skill_defence_term, sk, soft),
         party.send(:skill_defence_term, sk, hard),
         "skill ##{id} (#{sk.name}) reads the same through any armour"
    end
    ok n > 0, "#{n} purely magical skill(s) checked"
  end

  return if ignoring.empty?
  check "#{name}: a real 防御無視 skill is blunted by nothing at all" do
    hard = combatant('Hard', 0, 999, 5, 1000)
    hard.spi = 999
    ignoring.each do |id|
      eq 0, party.send(:skill_defence_term, skills[id], hard),
         "skill ##{id} (#{skills[id].name})"
    end
  end
end

def check_ko_only(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  items = db[DB_ITEM]
  return unless items

  ko = []
  items.each { |id, it| ko << id if it.ko_only }
  puts format('   items: %d 蘇生専用 (revive-only)', ko.size)
  return if ko.empty?

  check "#{name}: a real revive item is inert on a member still standing" do
    party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
    hero = party.leader
    ok hero, 'the game has a party to test with'
    ko.each do |iid|
      it = items[iid]
      # Every one of them restores a *percentage* of max HP, which is what makes
      # "not even the HP" a different answer from "cures nothing".
      ok (it.recover_hp_rate || 0) > 0 || (it.recover_hp || 0) > 0,
         "item ##{iid} (#{it.name}) restores something when it does work"
      hero.clear_states
      hero.set_hp(1)
      eq false, party.item_effective?(iid, hero),
         "item ##{iid} (#{it.name}) is inert on a standing member"
      party.gain_item(iid, 1)
      eq [], party.use_item(iid, hero)
      eq 1, hero.hp, 'and left the HP alone'

      # ... and does its job on one who has fallen.
      hero.add_state(Game::Actor::DEATH_STATE)
      eq true, party.item_effective?(iid, hero),
         "item ##{iid} works on a fallen member"
      eq [hero], party.use_item(iid, hero)
      ok !hero.dead?, 'who is back on their feet'
    end
    hero.clear_states
    hero.set_hp(hero.max_hp)
  end
end

# 両手持ち — a weapon that claims the shield hand too. A fixture cannot say what
# fraction of a real arsenal is two-handed, nor that the flag never lands on a
# shield; both matter, because the rule reads the item's *type* alongside it.
def check_two_handed(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  items = db[DB_ITEM]
  return unless items

  two = []
  weapons = 0
  shields = 0
  odd = []
  items.each do |id, it|
    weapons += 1 if it.type == 1
    shields += 1 if it.type == 2
    next if (it.two_handed || 0) == 0
    two << id
    odd << id unless it.type == 1
  end
  puts format('   items: %d 両手持ち of %d weapon(s), %d shield(s)',
              two.size, weapons, shields)
  return if two.empty? || shields.zero?

  check "#{name}: every real two-handed weapon empties the shield hand" do
    party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
    hero = party.leader
    ok hero, 'the game has someone to equip'
    shield = nil
    items.each { |id, it| shield ||= id if it.type == 2 }
    two.each do |wid|
      hero.equip([0, 0, 0, 0, 0])
      hero.equip_item(shield)
      eq shield, hero.equipment[1], 'the shield went on'
      hero.equip_item(wid)
      eq wid, hero.equipment[0], "weapon ##{wid} (#{items[wid].name}) went on"
      eq 0, hero.equipment[1], 'and took the shield hand with it'
    end
    hero.equip([0, 0, 0, 0, 0])
  end

  check "#{name}: the flag never lands on something that is not a weapon" do
    eq [], odd,
       'a non-weapon carrying the bit would claim a hand it has no business in'
  end
end

def check_states(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  states = db[DB_STATE]
  return unless states

  blinding = []
  waking = []
  sealing = []
  slipping = []
  already = []
  states.each do |id, r|
    blinding << id if r.reduce_hit_ratio && r.reduce_hit_ratio < 100
    waking << id if (r.release_by_attack || 0) > 0
    sealing << id if r.restrict_magic || r.restrict_skill
    slipping << id if (r.hp_change_map_steps || 0) > 0 &&
                      (r.hp_change_map_val || 0) > 0
    already << id unless r.message_already.to_s.empty?
  end
  puts format('   states: %d blinding, %d shaken off by a blow, %d sealing, ' \
              '%d slipping on the map, %d with an "already" sentence',
              blinding.size, waking.size, sealing.size, slipping.size,
              already.size)

  unless already.empty?
    # A fixture cannot say whether the sentence is worded from the speaker's
    # side (as message_actor / message_enemy are) or shared -- it is written to
    # match whatever the code does. Only a real game's own text can: every one
    # of these reads as a complete predicate after the battler's name, and one
    # sentence serves both sides.
    check "#{name}: an 'already' sentence composes after either battler's name" do
      already.each do |sid|
        row = states[sid]
        line = Game::States.already_message(sid, states, 'スライム')
        eq "スライム#{row.message_already}", line,
           "state ##{sid} (#{row.name})"
        eq "リト#{row.message_already}",
           Game::States.already_message(sid, states, 'リト'),
           'and the same sentence for the other side'
      end
    end

    # The rule that makes the field reachable at all: a state the target already
    # carries reports without rolling, so even a 0%-accuracy skill says so.
    check "#{name}: a real state already carried reports without a roll" do
      sid = already.first
      foe = combatant('Foe', 0, 0, 5, 1000, [sid])
      bat = Game::Battle.new([combatant('A', 10, 0, 10, 100)], [foe],
                             Game::Rng.new(1), states)
      e = bat.send(:apply_skill_hit, bat.allies[0], foe, -1,
                   0, { name: 'X', inflict: [sid], chance: 0 })
      eq [], e[:inflicted]
      eq [sid], e[:already],
         "state ##{sid} (#{states[sid].name}) is announced at 0% accuracy"
      ok Game::States.already_message(sid, states, foe.name),
         'and the database has the sentence to announce it with'
    end
  end

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

  unless slipping.empty?
    check "#{name}: a map-slipping state drains on its own step interval" do
      # The real party, walking the real interval. mtf-meido-action's Poison is
      # the only state in either test bed that carries the field (1 HP every 4
      # steps), so this is the check that says the reading is right rather than
      # merely self-consistent.
      party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
      ok !party.actors.empty?, 'the initial party has members to poison'
      slipping.each do |sid|
        row = states[sid]
        every = row.hp_change_map_steps
        amount = row.hp_change_map_val
        actor = party.actors.first
        actor.clear_states
        actor.set_hp(actor.max_hp)
        actor.add_state(sid)

        # Every step short of the interval leaves it alone ...
        (1...every).each do |s|
          eq [], party.apply_map_step_damage(states, s),
             "state ##{sid} (#{row.name}) drained on step #{s} of #{every}"
        end
        # ... and the one that reaches it takes exactly the row's amount.
        before = actor.hp
        eq [actor], party.apply_map_step_damage(states, every)
        eq before - amount, actor.hp,
           "state ##{sid} (#{row.name}) should drain #{amount} HP every " \
           "#{every} steps"

        # It never kills: walk far enough to drain the member's whole HP bar
        # several times over, and it is still standing.
        laps = actor.max_hp / amount + 5
        laps.times { |i| party.apply_map_step_damage(states, (i + 1) * every) }
        eq 1, actor.hp, "state ##{sid} (#{row.name}) wore it below 1 HP"
        ok !actor.dead?, 'field slip damage must not knock a member out'
        actor.clear_states
        actor.set_hp(actor.max_hp)
      end
    end
  end
end

# Equipment-granted combat modifiers, against the real item and actor tables.
# A weapon flag the runtime never reads is a weapon whose selling point does
# nothing — a 二刀流 blade that swings once, a 必中 dagger that misses. See
# docs/adr/0033-equipment-combat-modifiers.md.
def check_equipment(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  items = db[DB_ITEM]
  return unless items

  dual = []
  sure = []
  half = []
  crit_weapons = []
  crit_others = []
  items.each do |id, it|
    dual << id if it.type == 1 && it.dual_attack
    sure << id if it.type == 1 && it.ignore_evasion
    half << id if it.half_sp_cost
    next unless (it.critical_hit || 0) > 0
    (it.type == 1 ? crit_weapons : crit_others) << id
  end
  strong = []
  db[DB_ACTOR]&.each { |id, r| strong << id if r.strong_defence }
  puts format('   equipment: %d 二刀流, %d 必中, %d MP消費半分, %d 強力防御 actor(s), ' \
              '%d 会心必殺 weapon(s) (+%d non-weapon)',
              dual.size, sure.size, half.size, strong.size,
              crit_weapons.size, crit_others.size)

  unless dual.empty?
    check "#{name}: a 二刀流 weapon makes its wielder swing twice" do
      dual.each do |iid|
        a = Game::Actor.new(db, first_actor_id(db))
        a.equip([iid, 0, 0, 0, 0])
        eq true, a.dual_attack?, "item ##{iid} (#{items[iid].name}) grants it"
        eq 2, Game::Battle.from_actor(a).strike_count
      end
    end
  end

  unless sure.empty?
    check "#{name}: a 必中 weapon drops the evasion term" do
      swift = combatant('Swift', 0, 0, 999, 100)
      sure.each do |iid|
        a = Game::Actor.new(db, first_actor_id(db))
        a.equip([iid, 0, 0, 0, 0])
        bat = Game::Battle.new([Game::Battle.from_actor(a)], [swift],
                               Game::Rng.new(1), db[DB_STATE], false, false, true)
        eq a.attack_hit_rate, bat.send(:to_hit, bat.allies[0], swift),
           "item ##{iid} (#{items[iid].name}) hits at its own rate"
      end
    end
  end

  unless half.empty?
    check "#{name}: MP消費半分 gear halves a skill's cost" do
      party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
      sk = nil
      db[DB_SKILL]&.each { |_i, s| sk ||= s if (s.sp_cost || 0) > 1 && s.sp_type == 0 }
      next unless sk
      a = Game::Actor.new(db, first_actor_id(db))
      full = party.skill_cost(sk, a)
      ok full > 1, "the sample skill costs more than 1 SP (#{full})"
      half.each do |iid|
        # Equip it in the slot its own type names (1..5 map to the five slots),
        # so the flag is read off gear the actor is really wearing.
        slot = items[iid].type - 1
        next unless slot >= 0 && slot < 5
        gear = [0, 0, 0, 0, 0]
        gear[slot] = iid
        a.equip(gear)
        ok a.half_sp_cost?, "item ##{iid} (#{items[iid].name}) grants MP消費半分"
        eq (full + 1) / 2, party.skill_cost(sk, a),
           "and halves the #{full}-SP skill, rounding up"
      end
    end
  end

  unless crit_weapons.empty?
    check "#{name}: a 会心必殺 weapon adds its own rate to its wielder's" do
      aid = first_actor_id(db)
      # Stripped, not fresh: an actor is built wearing its initial equipment,
      # which for Nepheshel's first actor is already a 会心必殺 weapon.
      bare = Game::Actor.new(db, aid)
      bare.equip([0, 0, 0, 0, 0])
      base = bare.crit_chance
      crit_weapons.each do |iid|
        a = Game::Actor.new(db, aid)
        a.equip([iid, 0, 0, 0, 0])
        eq base + items[iid].critical_hit * Game::CRIT_PERCENT, a.crit_chance,
           "item ##{iid} (#{items[iid].name}) adds #{items[iid].critical_hit}%"
        ok a.crit_chance > base, 'and the weapon really moves the rate'
      end
    end
  end

  unless crit_others.empty?
    check "#{name}: a non-weapon's critical_hit field is left alone" do
      # These are not gear that always criticals -- they are the editor leaving
      # weapon-only fields untouched in the record every item type shares. Each
      # one carries exactly 100 alongside a `hit` of 70, another weapon field,
      # which is the pattern rather than a design.
      aid = first_actor_id(db)
      bare = Game::Actor.new(db, aid)
      bare.equip([0, 0, 0, 0, 0])
      base = bare.crit_chance
      crit_others.each do |iid|
        it = items[iid]
        slot = it.type - 1
        next unless slot >= 0 && slot < 5
        gear = [0, 0, 0, 0, 0]
        gear[slot] = iid
        a = Game::Actor.new(db, aid)
        a.equip(gear)
        eq base, a.crit_chance,
           "item ##{iid} (#{it.name}, type #{it.type}, +#{it.critical_hit}) " \
           'must not arm its wearer'
      end
    end
  end
end

# The lowest defined actor id in the database.
def first_actor_id(db)
  db[DB_ACTOR].each { |id, _r| return id }
  1
end

# 地形ダメージ against the real terrain table, and the gear that blocks it.
# A damaging tile that takes nothing is a floor with no teeth; gear sold to
# survive it that does not is worse.
def check_terrain(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  terrain = db[DB_TERRAIN]
  return unless terrain

  # RPG_RT omits a chipset's whole terrain array when every one of its tiles is
  # terrain 1, and that is what nearly every chipset in a real game does. Reading
  # the absence as terrain 0 left those tiles naming no terrain row at all.
  bare = []
  total_cs = 0
  db[DB_CHIPSET]&.each do |id, c|
    total_cs += 1
    bare << id if c.terrain_data.nil? || c.terrain_data.empty?
  end
  puts format('   chipsets: %d of %d store no terrain table at all',
              bare.size, total_cs)
  unless bare.empty?
    check "#{name}: a chipset with no terrain table still names a terrain row" do
      bare.each do |id|
        cs = Game::ChipSet.new(db, id)
        # One tile id out of each lower block, plus an id no block claims.
        [0, 1000, 3000, 4000, 5000, -1].each do |tile|
          eq 1, cs.terrain(tile), "chipset ##{id} (#{db[DB_CHIPSET][id].name}) tile #{tile}"
        end
        ok terrain[1], 'and terrain #1 is a row the database really has'
      end
    end
  end

  damaging = []
  terrain.each { |id, r| damaging << id if (r.damage || 0) > 0 }
  blockers = []
  db[DB_ITEM]&.each { |id, it| blockers << id if it.no_terrain_damage }
  puts format('   terrain: %d damaging tile type(s), %d item(s) that block them',
              damaging.size, blockers.size)
  return if damaging.empty?

  check "#{name}: a damaging terrain takes HP, and cannot kill" do
    party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
    leader = party.leader
    ok leader, 'the game has a party to hurt'
    damaging.each do |tid|
      amount = terrain[tid].damage
      leader.hp = leader.max_hp
      hit = party.apply_terrain_damage(amount)
      ok hit.include?(leader),
         "terrain ##{tid} (#{terrain[tid].name}, #{amount} HP) hit the leader"
      eq leader.max_hp - amount, leader.hp
      # However long the party stands in it, it is worn down rather than killed.
      (leader.max_hp / amount + 2).times { party.apply_terrain_damage(amount) }
      eq 1, leader.hp, "terrain ##{tid} floors at 1 HP instead of killing"
      ok !leader.dead?
    end
  end

  return if blockers.empty?
  check "#{name}: gear flagged 地形ダメージ無効 blocks it" do
    party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
    leader = party.leader
    worst = damaging.map { |tid| terrain[tid].damage }.max
    blockers.each do |iid|
      slot = db[DB_ITEM][iid].type - 1
      next unless slot >= 0 && slot < 5
      gear = [0, 0, 0, 0, 0]
      gear[slot] = iid
      leader.equip(gear)
      ok leader.prevents_terrain_damage?,
         "item ##{iid} (#{db[DB_ITEM][iid].name}) grants the immunity"
      leader.hp = leader.max_hp
      eq [], party.apply_terrain_damage(worst), 'and nothing gets through'
      eq leader.max_hp, leader.hp
    end
  end
end

# 下半身消去 / 半透明表示 — the terrain `bush_depth` that sinks a character's
# sprite into the tile. Unlike the damage field beside it, this one the test bed
# really *uses*: Nepheshel names four terrains after the effect and lays two of
# them across thousands of tiles, so the count below is a count of ground the
# hero visibly wades through.
def check_bush(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  terrain = db[DB_TERRAIN]
  return unless terrain

  bush = {}
  terrain.each { |id, r| bush[id] = r.bush_depth if (r.bush_depth || 0) > 0 }
  if bush.empty?
    puts '   bush: no terrain sinks a sprite'
    return
  end

  # How much of the shipped map really stands on one. Sweeping every Map*.lmu
  # through the same chipset lookup the scene uses is the only way to tell an
  # authored-and-used field from an authored-and-forgotten one.
  cache = {}
  tiles = Hash.new(0)
  maps = 0
  Dir[File.join(dir, 'Map*.lmu')].sort.each do |f|
    m = LCF::MapUnit.new(File.open(f, 'rb'))
    cs = (cache[m.chipset_id] ||= Game::ChipSet.new(db, m.chipset_id))
    hot = false
    (m.lower_layer || []).each do |t|
      tid = cs.terrain(t)
      next unless bush.key?(tid)
      tiles[tid] += 1
      hot = true
    end
    maps += 1 if hot
  end
  total = tiles.values.reduce(0) { |a, b| a + b }
  puts format('   bush: %d sinking terrain(s), %d tile(s) across %d map(s)',
              bush.size, total, maps)

  check "#{name}: every sinking terrain converts to a real pixel split" do
    bush.each do |id, depth|
      px = Game::CharSet.bush_pixels(depth)
      ok px > 0, "terrain ##{id} (#{terrain[id].name}, depth #{depth}) sinks something"
      ok px <= Game::CharSet::HEIGHT, 'and never more than the whole frame'
      # RPG_RT's divisor form: depth 1 is a third of the frame, 2 a half, 3 all
      # of it. Nepheshel's own names say the same thing.
      eq Game::CharSet::HEIGHT / (4 - depth), px
    end
  end

  return if total.zero?
  check "#{name}: the ground the game actually lays down sinks the hero" do
    ok maps > 0, 'at least one shipped map places a sinking tile'
    tiles.each do |id, n|
      ok n > 0, "terrain ##{id} (#{terrain[id].name}) is on #{n} tile(s)"
      ok Game::CharSet.bush_pixels(bush[id]) > 0,
         "and #{n} tile(s) of it would sink the hero"
    end
  end
end

# Curative items, against the real item table. A fixture cannot catch a field
# read with the wrong polarity — it is written to match whatever the code does —
# so only a real game's antidotes can say which way round `reverse_state_effect`
# goes. Nepheshel's アンチドーテ and ユニコーンの角 name all fifteen states and
# 気付け薬 names 戦闘不能 alone; none of them sets the flag.
def check_items(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  items = db[DB_ITEM]
  return unless items

  curative = []
  reversed = []
  items.each do |id, it|
    next unless it.type == 6 # medicine
    set = it.state_set
    next unless set.respond_to?(:each_index)
    ids = []
    set.each_index { |i| ids << (i + 1) if set[i] && set[i] != 0 }
    next if ids.empty?
    (it.reverse_state_effect ? reversed : curative) << [id, ids]
  end
  puts format('   items: %d curative medicine(s), %d with reverse_state_effect',
              curative.size, reversed.size)
  return if curative.empty?

  check "#{name}: every curative medicine actually cures what it names" do
    party = Game::Party.new(db, db[DB_SYSTEM] ? db[DB_SYSTEM][SYS_PARTY] : nil)
    actor = party.leader
    ok actor, 'the initial party has a leader to heal'
    curative.each do |iid, ids|
      row = items[iid]
      eq ids, party.item_cured_states(row),
         "item ##{iid} (#{row.name}) should cure #{ids.size} state(s)"

      # ... and using it really lifts them, including from a downed actor: a
      # medicine naming state 1 is a revive, and several of these name only it.
      # HP first, then the states: set_hp with a positive value *clears* the
      # death state, so afflicting before healing would quietly undo state 1 --
      # and state 1 is the only one several of these name.
      actor.clear_states
      actor.set_hp(actor.max_hp)
      ids.each { |sid| actor.add_state(sid) }
      party.gain_item(iid, 1)
      ok party.item_effective?(iid, actor),
         "item ##{iid} (#{row.name}) is offered to an afflicted target"
      party.use_item(iid, actor)
      ids.each do |sid|
        eq false, actor.state?(sid),
           "item ##{iid} (#{row.name}) left state #{sid} on"
      end
    end
    actor.clear_states
    actor.set_hp(actor.max_hp)
  end
end

# The 用語 (term) table's battle sentences, against the real thing. Both test
# beds fill in 126 of the 127 fields; a fixture cannot say whether a field is a
# predicate the name goes in front of or a whole sentence, because it is written
# to match whatever the code does. Only the games' own text can.
DB_TERM = 21
BASIC_TERMS = [:attacking, :defending, :observing, :focus, :autodestruction,
               :enemy_escape, :enemy_transform].freeze

def check_terms(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  terms = db[DB_TERM]
  return unless terms
  bt = Game::States::BattleText

  filled = BASIC_TERMS.select { |f| bt.term(terms, f) }
  puts format('   terms: %d of %d basic action sentences, damage %s, dodge %s',
              filled.size, BASIC_TERMS.size,
              bt.term(terms, :enemy_damaged) ? 'yes' : 'no',
              bt.term(terms, :dodge) ? 'yes' : 'no')
  return if filled.empty?

  check "#{name}: every basic action sentence composes after a battler's name" do
    filled.each do |f|
      line = bt.action(terms, 'スライム', f)
      eq "スライム#{terms.send(f)}", line, "term #{f}"
      ok line.length > terms.send(f).length, 'the name really is in front of it'
    end
  end

  # A skill's own two sentences, against the real skill table. Only a real game
  # can say these are predicates the caster's name goes in front of (the first)
  # and a standalone line (the second) -- a fixture is written to match the code.
  first = []
  second = []
  failures = Hash.new(0)
  db[DB_SKILL]&.each do |id, sk|
    first << id unless sk.using_message1.to_s.empty?
    second << id unless sk.using_message2.to_s.empty?
    failures[sk.failure_message || 0] += 1
  end
  puts format('   skills: %d with a first sentence, %d with a second; ' \
              'failure_message %s',
              first.size, second.size,
              failures.sort.map { |k, v| "#{k}:#{v}" }.join(' '))

  unless first.empty?
    check "#{name}: every skill sentence composes the way RPG_RT prints it" do
      first.each do |id|
        sk = db[DB_SKILL][id]
        lines = bt.skill_start(sk, 'リト')
        eq "リト#{sk.using_message1}", lines[0], "skill ##{id} (#{sk.name})"
        if sk.using_message2.to_s.empty?
          eq 1, lines.size, "skill ##{id} has only a first line"
        else
          # The second line stands alone -- no name in front of it.
          eq sk.using_message2, lines[1], "skill ##{id} second line"
          ok !lines[1].start_with?('リト'), 'and it is not prefixed'
        end
      end
    end

    check "#{name}: every skill's failure_message names a real 用語 line" do
      db[DB_SKILL].each do |id, sk|
        i = sk.failure_message || 0
        ok i >= 0 && i < Game::States::BattleText::FAILURE_TERMS.size,
           "skill ##{id} (#{sk.name}) failure_message #{i} is in range"
        line = bt.skill_failure(terms, sk, 'スライム')
        ok line && line.start_with?('スライム'),
           "skill ##{id} composes a failure sentence"
      end
    end
  end

  if bt.term(terms, :use_item) && bt.term(terms, :hp_recovery)
    check "#{name}: the item and recovery lines build from the real table" do
      it = db[DB_ITEM] && db[DB_ITEM][1]
      if it
        line = bt.item_start(terms, 'リト', it.name)
        ok line.start_with?("リトは#{it.name}"),
           'the caster, は and the item name lead it'
        ok line.end_with?(terms.use_item), 'and the term closes it'
      end
      # The pool name is the table's too, which is why one game reads ＨＰ and
      # the other HP -- a literal "HP" would be wrong in exactly one of them.
      %i[hp mp].each do |pool|
        next unless bt.term(terms, pool)
        r = bt.recovered(terms, 'リト', 30, pool)
        ok r.include?(terms.send(pool).to_s), "the #{pool} line names the pool"
        ok r.include?('30') && r.end_with?(terms.hp_recovery),
           'with the amount and the term'
      end
    end
  end

  if bt.term(terms, :enemy_hp_absorbed) && bt.term(terms, :hp)
    drains = []
    db[DB_SKILL]&.each { |id, sk| drains << id if sk.absorb_damage }
    puts format('   skills: %d 吸収 (drain)', drains.size)
    unless drains.empty?
      check "#{name}: a real 吸収 skill drains what it deals, and no more" do
        sid = drains.first
        sk = db[DB_SKILL][sid]
        mage = combatant('Mage', 20, 0, 10, 100)
        mage.hp = 40
        foe = combatant('Foe', 0, 0, 5, 100)
        foe.hp = 25
        bat = Game::Battle.new([mage], [foe], Game::Rng.new(1))
        e = bat.send(:apply_skill_hit, mage, foe, -200, 0,
                     { name: sk.name, absorb: true })
        eq 25, e[:damage], "skill ##{sid} (#{sk.name}) is capped by the target"
        eq 25, e[:absorbed_hp]
        eq 65, mage.hp
        ok bt.absorbed(terms, foe.name, 25, :hp, false),
           'and the database has the sentence to report it with'
      end
    end
  end

  return unless bt.term(terms, :enemy_damaged) && bt.term(terms, :actor_damaged)
  check "#{name}: the damage sentence differs by side, and carries the number" do
    foe = bt.damage(terms, 'スライム', 42, false)
    ally = bt.damage(terms, 'リト', 42, true)
    ok foe.include?('42') && ally.include?('42'), 'both name the amount'
    ok foe.include?(terms.enemy_damaged), 'the foe predicate'
    ok ally.include?(terms.actor_damaged), 'the ally predicate'
    ok foe != ally.sub('リト', 'スライム'),
       'the two sides really are worded differently'
    # The particle is what makes them read as Japanese rather than as two names
    # glued to numbers, and it is the one part not in the database.
    ok foe.start_with?('スライムに '), 'a foe takes に'
    ok ally.start_with?('リトは '), 'one of yours takes は'
  end
end

# Every skill and item names a battle animation, and until now none of them
# played. A fixture cannot say whether the ids resolve -- it defines whatever
# table it needs -- so this asks the real ones.
def check_animations(dir)
  name = File.basename(dir)
  db = LCF::Database.new(File.open(File.join(dir, 'RPG_RT.ldb'), 'rb'))
  anims = db[DB_ANIME]
  return unless anims

  total = 0
  named = {}
  anims.each { |id, _| total += 1 }
  [[DB_SKILL, :skill], [DB_ITEM, :item]].each do |chunk, label|
    rows = 0
    with = 0
    resolves = 0
    db[chunk]&.each do |_id, r|
      rows += 1
      a = r.animation_id || 0
      next unless a > 0
      with += 1
      resolves += 1 if anims[a]
    end
    named[label] = [rows, with, resolves]
  end
  puts format('   animations: %d in the table; skills %d/%d name one (%d ' \
              'resolve), items %d/%d (%d resolve)',
              total, named[:skill][1], named[:skill][0], named[:skill][2],
              named[:item][1], named[:item][0], named[:item][2])

  check "#{name}: every animation a skill or item names is a real row" do
    [[DB_SKILL, 'skill'], [DB_ITEM, 'item']].each do |chunk, label|
      db[chunk]&.each do |id, r|
        a = r.animation_id || 0
        next unless a > 0
        ok anims[a], "#{label} ##{id} (#{r.name}) names animation ##{a}"
      end
    end
  end

  check "#{name}: a real animation builds a drawable player" do
    # The first animation with frames: the scene's build_animation is what turns
    # a row into something the round can play, and a row whose frame table is
    # empty must not arm one.
    drawable = 0
    anims.each do |_id, a|
      f = a.frames
      n = 0
      f&.each { |_i, _fr| n += 1 }
      drawable += 1 if n > 0
    end
    ok drawable > 0, "#{drawable} of #{total} animations carry frames"
  end
end

dirs.each do |d|
  check_animations(d)
  check_terms(d)
  check_game(d)
  check_menus(d)
  check_states(d)
  check_equipment(d)
  check_terrain(d)
  check_bush(d)
  check_ko_only(d)
  check_skill_defence(d)
  check_two_handed(d)
  check_items(d)
end

if $failures.zero?
  puts "rpg2k test-bed logic check: #{$checks} checks passed"
else
  warn "rpg2k test-bed logic check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
