#!/usr/bin/env ruby
# encoding: UTF-8
#
# Host-side unit checks for the pure-Ruby RPG2000 game logic.
#
# The gameplay logic in mruby-rpg2k/mrblib/{game,interpreter}.rb is written in
# the mruby/CRuby common subset and touches neither RGSS (drawing/audio) nor the
# native LCF parser at load time, so — like scripts/lcf_testbed_check.rb does for
# the loaders — this harness loads those exact sources under CRuby and exercises
# them directly. That gives the move-route runtime, autonomous movement and the
# event-command interpreter regression coverage that the SDL/mruby binary (which
# cannot be built or run in CI's cheap path) would otherwise be the only place to
# get.
#
# Usage: ruby scripts/rpg2k_logic_check.rb   (exits non-zero on any failure)

# Minimal stubs for the two names the sources reference. Neither is touched by
# the code paths under test; they only need to exist so the files load and the
# audio side effect of a move route can be observed.
module RGSS
  module Audio
    class << self
      attr_accessor :log
      def bgm_play(*a); (@log ||= []) << [:bgm, *a]; end
      def se_play(*a);  (@log ||= []) << [:se, *a];  end
    end
  end
  def self.warn_stub(*); end
end

lib = File.expand_path('../mruby-rpg2k/mrblib', __dir__)
load File.join(lib, 'game.rb')
load File.join(lib, 'interpreter.rb')

# -- tiny test framework ------------------------------------------------------

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

# -- fakes --------------------------------------------------------------------

# A grid world implementing the MoveRoute/MoveType `world` protocol. Passability
# is a set of blocked [x, y] tiles; everything else is walkable.
class FakeWorld
  attr_accessor :hero, :switches, :sounds, :rolls

  def initialize(blocked: [], hero: [0, 0], rolls: [])
    @blocked = blocked
    @hero = hero
    @switches = {}
    @sounds = []
    @rolls = rolls # queued values for random(n); falls back to 0
  end

  def passable?(character, dir)
    x, y = Game::Character.step_tile(character.x, character.y, dir)
    !@blocked.include?([x, y])
  end

  def hero_position; @hero; end
  def set_switch(id, on); @switches[id] = on; end
  def play_sound(*a); @sounds << a; end
  def random(_n); @rolls.empty? ? 0 : @rolls.shift; end
end

# Build an LCF::MoveCommand-alike without loading the native parser.
FakeMoveCommand = Struct.new(:command_id, :parameter_string,
                             :parameter_a, :parameter_b, :parameter_c)
def mc(id, str: '', a: 0, b: 0, c: 0)
  FakeMoveCommand.new(id, str, a, b, c)
end

# A stand-in for an LCF event command: the interpreter only calls #code,
# #string, #indent, #param(i) and #parameters.
class FakeCmd
  attr_reader :code, :indent, :string, :parameters
  def initialize(code, params = [], indent: 0, string: '')
    @code = code
    @parameters = params
    @indent = indent
    @string = string
  end
  def param(i); @parameters[i] || 0; end
end

R = Game::MoveRoute

# -- Character ----------------------------------------------------------------

check 'Character#move steps and faces in the move direction' do
  c = Game::Character.new(5, 5, 2)
  c.move(6)
  eq [6, 5], [c.x, c.y]
  eq 6, c.direction
  c.move(8)
  eq [6, 4], [c.x, c.y]
  eq 8, c.direction
end

check 'Character#face changes facing but not position; lock freezes it' do
  c = Game::Character.new(3, 3, 2)
  c.face(4)
  eq 4, c.direction
  eq [3, 3], [c.x, c.y]
  c.facing_locked = true
  c.move(6) # moves east but keeps facing west
  eq [4, 3], [c.x, c.y]
  eq 4, c.direction
end

check 'Character turns rotate through the cardinals' do
  c = Game::Character.new(0, 0, 8)
  c.turn_right;  eq 6, c.direction
  c.turn_right;  eq 2, c.direction
  c.turn_left;   eq 6, c.direction
  c.turn_around; eq 4, c.direction
end

check 'direction_toward/away point at and away from a target' do
  c = Game::Character.new(5, 5, 2)
  eq 6, c.direction_toward(9, 6)  # dx dominates -> east
  eq 2, c.direction_toward(5, 9)  # pure vertical -> south
  eq 4, c.direction_away(9, 5)    # away from east -> west
  eq 2, c.direction_toward(5, 5)  # already there -> keep facing
end

# -- MoveRoute: movement ------------------------------------------------------

check 'MoveRoute walks a cardinal path and repeats' do
  route = R.new([mc(R::MOVE_RIGHT), mc(R::MOVE_DOWN)], repeat: true)
  c = Game::Character.new(0, 0)
  w = FakeWorld.new
  eq :moved, route.step(c, w)
  eq [1, 0], [c.x, c.y]
  eq :moved, route.step(c, w)
  eq [1, 1], [c.x, c.y]
  ok !route.done?, 'a repeating route is never done'
  eq :moved, route.step(c, w) # wrapped back to MOVE_RIGHT
  eq [2, 1], [c.x, c.y]
end

check 'a non-repeating route reports done after its last command' do
  route = R.new([mc(R::MOVE_RIGHT)], repeat: false)
  c = Game::Character.new(0, 0)
  eq :moved, route.step(c, FakeWorld.new)
  ok route.done?, 'route should be done after the only command'
  eq :done, route.step(c, FakeWorld.new)
  eq [1, 0], [c.x, c.y] # no further movement
end

check 'a blocked non-skippable move faces the wall and retries' do
  route = R.new([mc(R::MOVE_RIGHT)], repeat: false, skippable: false)
  c = Game::Character.new(0, 0)
  w = FakeWorld.new(blocked: [[1, 0]])
  eq :blocked, route.step(c, w)
  eq [0, 0], [c.x, c.y] # did not move
  eq 6, c.direction     # but turned to face the obstacle
  ok !route.done?, 'non-skippable blocked move must not advance'
  eq 0, route.index
end

check 'a blocked skippable move advances past the obstruction' do
  route = R.new([mc(R::MOVE_RIGHT), mc(R::MOVE_DOWN)],
                repeat: false, skippable: true)
  c = Game::Character.new(0, 0)
  w = FakeWorld.new(blocked: [[1, 0]])
  eq :blocked, route.step(c, w)
  eq [0, 0], [c.x, c.y]
  eq :moved, route.step(c, w) # moved on to MOVE_DOWN
  eq [0, 1], [c.x, c.y]
end

check 'a "through" character ignores collision' do
  route = R.new([mc(R::MOVE_RIGHT)], repeat: false)
  c = Game::Character.new(0, 0)
  c.through = true
  eq :moved, route.step(c, FakeWorld.new(blocked: [[1, 0]]))
  eq [1, 0], [c.x, c.y]
end

check 'move toward / away hero uses the hero position' do
  toward = R.new([mc(R::MOVE_TOWARD_HERO)])
  c = Game::Character.new(0, 0)
  eq :moved, toward.step(c, FakeWorld.new(hero: [5, 0]))
  eq [1, 0], [c.x, c.y]

  away = R.new([mc(R::MOVE_AWAY_HERO)])
  c2 = Game::Character.new(5, 5)
  eq :moved, away.step(c2, FakeWorld.new(hero: [9, 5]))
  eq [4, 5], [c2.x, c2.y]
end

check 'random move consults the world RNG' do
  route = R.new([mc(R::MOVE_RANDOM)])
  c = Game::Character.new(3, 3)
  # CARDINALS = [2, 4, 6, 8]; roll 2 -> index 2 -> direction 6 (east).
  eq :moved, route.step(c, FakeWorld.new(rolls: [2]))
  eq [4, 3], [c.x, c.y]
end

check 'diagonal move needs both cardinals and faces vertical' do
  route = R.new([mc(R::MOVE_UPRIGHT)])
  c = Game::Character.new(2, 2)
  eq :moved, route.step(c, FakeWorld.new)
  eq [3, 1], [c.x, c.y]
  eq 8, c.direction # faced the vertical (up) component

  # Blocked on either cardinal -> the whole diagonal is blocked.
  route2 = R.new([mc(R::MOVE_UPRIGHT)], skippable: false)
  c2 = Game::Character.new(2, 2)
  eq :blocked, route2.step(c2, FakeWorld.new(blocked: [[3, 2]])) # east blocked
  eq [2, 2], [c2.x, c2.y]
end

check 'move forward steps in the current facing' do
  route = R.new([mc(R::MOVE_FORWARD)])
  c = Game::Character.new(4, 4, 4) # facing west
  eq :moved, route.step(c, FakeWorld.new)
  eq [3, 4], [c.x, c.y]
end

# -- MoveRoute: turns and side effects ---------------------------------------

check 'face and turn commands change facing only' do
  route = R.new([mc(R::FACE_LEFT), mc(R::TURN_180), mc(R::FACE_HERO)],
                repeat: false)
  c = Game::Character.new(5, 5, 2)
  w = FakeWorld.new(hero: [5, 0])
  eq :turned, route.step(c, w); eq 4, c.direction # face left
  eq :turned, route.step(c, w); eq 6, c.direction # 180 from left
  eq :turned, route.step(c, w); eq 8, c.direction # face hero (north)
  eq [5, 5], [c.x, c.y]
end

check 'switch on/off route commands drive the world switches' do
  route = R.new([mc(R::SWITCH_ON, a: 7), mc(R::SWITCH_OFF, a: 3)], repeat: false)
  c = Game::Character.new(0, 0)
  w = FakeWorld.new
  route.step(c, w); route.step(c, w)
  eq true, w.switches[7]
  eq false, w.switches[3]
end

check 'change-graphic and play-sound route commands apply' do
  route = R.new([mc(R::CHANGE_GRAPHIC, str: 'Hero', a: 2),
                 mc(R::PLAY_SOUND, str: 'bell', a: 90, b: 100, c: 50)],
                repeat: false)
  c = Game::Character.new(0, 0)
  w = FakeWorld.new
  route.step(c, w)
  eq 'Hero', c.graphic_name
  eq 2, c.graphic_index
  route.step(c, w)
  eq [['bell', 90, 100, 50]], w.sounds
end

check 'speed/frequency/through/transparency flags clamp at their bounds' do
  c = Game::Character.new(0, 0)
  c.move_speed = 6
  c.move_frequency = 1
  cmds = [mc(R::SPEED_UP), mc(R::FREQ_DOWN), mc(R::THROUGH_ON),
          mc(R::LOCK_FACING), mc(R::TRANSP_UP)]
  route = R.new(cmds, repeat: false)
  w = FakeWorld.new
  cmds.size.times { route.step(c, w) }
  eq 6, c.move_speed          # clamped at the max
  eq 1, c.move_frequency      # clamped at the min
  eq true, c.through
  eq true, c.facing_locked
  eq 1, c.transparency
end

check 'from_page builds a route from a parsed page, nil when empty' do
  page = Struct.new(:commands, :repeat, :skippable)
  route = R.from_page(page.new([mc(R::MOVE_UP)], false, true))
  ok route, 'expected a route'
  ok !route.repeat?, 'repeat flag carried through'
  ok route.skippable?, 'skippable flag carried through'
  eq nil, R.from_page(page.new([], true, false))
  eq nil, R.from_page(nil)
end

# -- MoveType (autonomous movement) ------------------------------------------

check 'MoveType stationary and custom yield no autonomous direction' do
  c = Game::Character.new(0, 0)
  w = FakeWorld.new
  eq nil, Game::MoveType.next_direction(Game::MoveType::STATIONARY, c, w)
  eq nil, Game::MoveType.next_direction(Game::MoveType::CUSTOM, c, w)
end

check 'MoveType vertical bounces off a blocked tile' do
  c = Game::Character.new(2, 2, 8) # heading up
  # Up (2,1) is blocked, so it should reverse to down.
  w = FakeWorld.new(blocked: [[2, 1]])
  eq 2, Game::MoveType.next_direction(Game::MoveType::VERTICAL, c, w)
  # Unobstructed, it keeps its current axis direction.
  eq 8, Game::MoveType.next_direction(Game::MoveType::VERTICAL, c, FakeWorld.new)
end

check 'MoveType toward/away chase and flee the hero' do
  c = Game::Character.new(0, 0)
  w = FakeWorld.new(hero: [0, 5])
  eq 2, Game::MoveType.next_direction(Game::MoveType::TOWARD, c, w)
  eq 8, Game::MoveType.next_direction(Game::MoveType::AWAY, c, w)
end

# -- Rng ----------------------------------------------------------------------

check 'Rng stays in range and is deterministic per seed' do
  a = Game::Rng.new(1234)
  b = Game::Rng.new(1234)
  20.times do
    v = a.random(4)
    ok v >= 0 && v < 4, "random(4) out of range: #{v}"
    eq v, b.random(4) # same seed -> same stream
  end
  eq 0, Game::Rng.new.random(0) # random(0) is defined as 0
end

# -- Interpreter (a few existing-behaviour regressions) -----------------------

# Build a minimal State without the LCF database: stub Party just enough for the
# commands the checks below drive (gold/items).
class FakeParty
  attr_reader :gold, :items
  def initialize; @gold = 0; @items = {}; end
  def gain_gold(n); @gold += n; end
  def gain_item(id, n); @items[id] = (@items[id] || 0) + n; end
  def has_item?(id); (@items[id] || 0) > 0; end
end

def new_state
  Game::State.new(FakeParty.new, 1, 0, 0)
end

IC = Game::Interpreter::Cmd

check 'interpreter sets and toggles switches' do
  st = new_state
  it = Game::Interpreter.new(st)
  # Control Switches: mode single (0), id 5, (unused), op 0 = ON.
  it.start([FakeCmd.new(Game::Interpreter::Cmd::CONTROL_SWITCHES, [0, 5, 5, 0])])
  it.update
  eq true, st.switches[5]
end

check 'interpreter evaluates a conditional branch and its else' do
  st = new_state
  st.switches[1] = true
  # if switch 1 on: set var 1 = 10 (in branch) else set var 1 = 20.
  cmds = [
    FakeCmd.new(IC::CONDITIONAL, [0, 1, 0], indent: 0),        # switch 1 == on
    FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 10], indent: 1),
    FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
    FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 20], indent: 1),
    FakeCmd.new(IC::END_BRANCH, [], indent: 0),
  ]
  it = Game::Interpreter.new(st)
  it.start(cmds)
  it.update
  eq 10, st.variables[1]
end

check 'interpreter change gold/items updates the party' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([
    FakeCmd.new(IC::CHANGE_GOLD, [0, 0, 100]),   # add constant 100
    FakeCmd.new(IC::CHANGE_ITEMS, [0, 0, 3, 0, 2]), # add 2 of item 3
  ])
  it.update
  eq 100, st.party.gold
  eq 2, st.party.items[3]
end

check 'interpreter pauses on a message and resumes' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_MESSAGE, [], string: 'hello'),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok it.waiting?, 'should wait on the message'
  eq :message, it.wait_kind
  eq ['hello'], it.message_lines
  it.resume
  it.update
  eq true, st.switches[2] # ran the command after the message
end

# A Call Event resolver stub: maps common-event id -> command list, and
# (map event id, page) -> command list.
class FakeResolver
  def initialize(common: {}, maps: {})
    @common = common
    @maps = maps
  end
  def common_event_commands(id); @common[id]; end
  def map_event_commands(id, page); (@maps[id] || {})[page]; end
end

check 'Call Event runs a common event then returns to the caller' do
  st = new_state
  called = [FakeCmd.new(IC::CONTROL_SWITCHES, [0, 9, 9, 0])] # switch 9 = ON
  it = Game::Interpreter.new(st)
  it.resolver = FakeResolver.new(common: { 5 => called })
  it.start([
    FakeCmd.new(IC::CALL_EVENT, [0, 5, 0]),          # call common event 5
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0]), # then switch 1 = ON
  ])
  it.update
  eq true, st.switches[9], 'the called common event ran'
  eq true, st.switches[1], 'control returned to the caller'
  ok !it.running?, 'the whole process finished'
end

check 'Call Event as the last command returns cleanly (nested unwinds)' do
  st = new_state
  inner = [FakeCmd.new(IC::CONTROL_SWITCHES, [0, 3, 3, 0])]
  # common event 5 is: set switch 2, then call common event 6 (its last command)
  middle = [FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0]),
            FakeCmd.new(IC::CALL_EVENT, [0, 6, 0])]
  it = Game::Interpreter.new(st)
  it.resolver = FakeResolver.new(common: { 5 => middle, 6 => inner })
  it.start([FakeCmd.new(IC::CALL_EVENT, [0, 5, 0])]) # call 5 as the only command
  it.update
  eq true, st.switches[2]
  eq true, st.switches[3]
  ok !it.running?, 'both nested calls unwound and the process ended'
end

check 'a missing Call Event target is a no-op and the caller continues' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.resolver = FakeResolver.new(common: {}) # id 5 not defined
  it.start([FakeCmd.new(IC::CALL_EVENT, [0, 5, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq true, st.switches[1]
  ok !it.running?
end

check 'a self-calling common event terminates instead of hanging' do
  st = new_state
  it = Game::Interpreter.new(st)
  self_call = [FakeCmd.new(IC::CALL_EVENT, [0, 1, 0])] # calls itself
  it.resolver = FakeResolver.new(common: { 1 => self_call })
  it.start([FakeCmd.new(IC::CALL_EVENT, [0, 1, 0])])
  it.update # must return (bounded by MAX_CALL_DEPTH), not loop forever
  ok !it.running?, 'recursion was bounded and the process ended'
end

check 'Call Event with no resolver set is a safe no-op' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CALL_EVENT, [0, 5, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq true, st.switches[1]
end

check 'a message inside a called event pauses and resumes across the boundary' do
  st = new_state
  called = [FakeCmd.new(IC::SHOW_MESSAGE, [], string: 'hi'),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 8, 8, 0])]
  it = Game::Interpreter.new(st)
  it.resolver = FakeResolver.new(common: { 7 => called })
  it.start([FakeCmd.new(IC::CALL_EVENT, [0, 7, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'paused on the message inside the called event'
  eq ['hi'], it.message_lines
  it.resume
  it.update
  eq true, st.switches[8], 'finished the called event after the message'
  eq true, st.switches[1], 'returned to and finished the caller'
end

check 'Move Event queues a decoded, non-blocking route request' do
  st = new_state
  it = Game::Interpreter.new(st)
  # target 25 (a map event), freq 4, repeat on, skippable off, then MOVE_UP(0),
  # MOVE_RIGHT(1); a Control Switches command follows to prove no pause.
  it.start([FakeCmd.new(IC::MOVE_EVENT, [25, 4, 1, 0, R::MOVE_UP, R::MOVE_RIGHT]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'Move Event must not pause the interpreter'
  eq true, st.switches[1], 'the command after Move Event still ran'
  reqs = it.take_move_route_requests
  eq 1, reqs.size
  r = reqs[0]
  eq 25, r[:target]
  eq 4, r[:frequency]
  eq true, r[:repeat]
  eq false, r[:skippable]
  eq [R::MOVE_UP, R::MOVE_RIGHT], r[:commands].map(&:command_id)
  eq 0, it.take_move_route_requests.size, 'draining clears the queue'
end

check 'Move Event decodes switch / change-graphic / play-sound sub-commands' do
  st = new_state
  it = Game::Interpreter.new(st)
  # header: this-event target, freq 0, repeat 0, skippable 0. Then:
  #   SWITCH_ON(32) + switch 7
  #   CHANGE_GRAPHIC(34) + len 4 + index 2   (string "Hero")
  #   PLAY_SOUND(35)    + len 3 + 90,100,50  (string "bel")
  params = [10005, 0, 0, 0, 32, 7, 34, 4, 2, 35, 3, 90, 100, 50]
  it.start([FakeCmd.new(IC::MOVE_EVENT, params, string: 'Herobel')])
  it.update
  cmds = it.take_move_route_requests[0][:commands]
  eq [32, 34, 35], cmds.map(&:command_id)
  eq 7, cmds[0].parameter_a
  eq 'Hero', cmds[1].parameter_string
  eq 2, cmds[1].parameter_a
  eq 'bel', cmds[2].parameter_string
  eq [90, 100, 50],
     [cmds[2].parameter_a, cmds[2].parameter_b, cmds[2].parameter_c]
end

check 'a decoded Move Event route drives a Character through a MoveRoute' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::MOVE_EVENT, [7, 0, 0, 0, R::MOVE_RIGHT, R::MOVE_DOWN])])
  it.update
  route = R.new(it.take_move_route_requests[0][:commands], repeat: false)
  c = Game::Character.new(0, 0)
  w = FakeWorld.new
  route.step(c, w); route.step(c, w)
  eq [1, 1], [c.x, c.y], 'the decoded commands moved the character'
  ok route.done?, 'non-repeating decoded route finishes'
end

check 'conditional branch on the timer' do
  st = new_state
  st.timer_frames = 30 * 60 # 30 seconds remaining
  it = Game::Interpreter.new(st)
  cmds = [
    FakeCmd.new(IC::CONDITIONAL, [2, 10, 0], indent: 0), # timer >= 10s ?
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 4, 4, 0], indent: 1),
    FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 1),
    FakeCmd.new(IC::END_BRANCH, [], indent: 0),
  ]
  it.start(cmds)
  it.update
  eq true, st.switches[4], 'timer >= 10s branch taken'
  eq false, st.switches[5]
end

# -- actor HP / MP commands ---------------------------------------------------

# A database row for an actor, and a fake DB exposing just what Game::Party /
# Game::Actor read (player table + the initial party list).
FakePlayerRow = Struct.new(:name, :charset_name, :charset_index,
                           :initial_level, :status)
FakeActorSystem = Struct.new(:party)
class FakeActorDB
  attr_reader :player, :system
  def initialize(players, party_ids)
    @player = players
    @system = FakeActorSystem.new(party_ids)
  end
end

def party_state
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8),
    2 => FakePlayerRow.new('Ally', '', 0, 3,
                           max_hp: 50, max_mp: 20, atk: 6, def: 5),
  }
  Game::State.new(Game::Party.new(FakeActorDB.new(players, [1, 2])), 1, 0, 0)
end

check 'Actor change_hp/change_mp/full_heal clamp within their bounds' do
  hero = party_state.party.actor_by_id(1)
  hero.change_hp(-30);          eq 70, hero.hp
  hero.change_hp(-1000, true);  eq 0, hero.hp   # death allowed -> floor 0
  hero.change_hp(-5, false);    eq 1, hero.hp   # death disallowed -> floor 1
  hero.change_hp(9999);         eq 100, hero.hp # capped at max_hp
  hero.change_mp(-1000);        eq 0, hero.mp
  hero.change_mp(9999);         eq 30, hero.mp  # capped at max_mp
  hero.hp = 10; hero.mp = 5
  hero.full_heal
  eq [100, 30], [hero.hp, hero.mp]
end

check 'Change HP command damages a fixed actor' do
  st = party_state
  it = Game::Interpreter.new(st)
  # scope 1 (fixed id), actor 1, op 1 (remove), operand const 40, allow-death 0
  it.start([FakeCmd.new(IC::CHANGE_HP, [1, 1, 1, 0, 40, 0])])
  it.update
  eq 60, st.party.actor_by_id(1).hp
end

check 'Change HP allow-death flag chooses the floor (0 vs 1)' do
  st = party_state
  a = st.party.actor_by_id(1)
  a.hp = 20
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_HP, [1, 1, 1, 0, 999, 0])]) # not lethal
  it.update
  eq 1, a.hp
  a.hp = 20
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_HP, [1, 1, 1, 0, 999, 1])]) # lethal
  it2.update
  eq 0, a.hp
end

check 'Change HP heals with a variable operand' do
  st = party_state
  st.variables[3] = 25
  a = st.party.actor_by_id(1)
  a.hp = 50
  it = Game::Interpreter.new(st)
  # scope 1, actor 1, op 0 (add), operand type 1 (variable), var id 3 (=25)
  it.start([FakeCmd.new(IC::CHANGE_HP, [1, 1, 0, 1, 3, 0])])
  it.update
  eq 75, a.hp
end

check 'Change HP targets an actor id held in a variable' do
  st = party_state
  st.variables[7] = 2
  it = Game::Interpreter.new(st)
  # scope 2 (actor id from variable 7 -> actor 2), op 1 remove, const 15
  it.start([FakeCmd.new(IC::CHANGE_HP, [2, 7, 1, 0, 15, 0])])
  it.update
  eq 35, st.party.actor_by_id(2).hp # 50 - 15
end

check 'Change MP applies to the whole party' do
  st = party_state
  st.party.actors.each { |a| a.mp = 5 }
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_MP, [0, 0, 0, 0, 10])]) # scope 0, add const 10
  it.update
  eq 15, st.party.actor_by_id(1).mp
  eq 15, st.party.actor_by_id(2).mp
end

check 'Full Heal restores the whole party to max HP/MP' do
  st = party_state
  st.party.actors.each { |a| a.hp = 1; a.mp = 0 }
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::FULL_HEAL, [0, 0])]) # scope 0 (whole party)
  it.update
  eq [100, 30], [st.party.actor_by_id(1).hp, st.party.actor_by_id(1).mp]
  eq [50, 20],  [st.party.actor_by_id(2).hp, st.party.actor_by_id(2).mp]
end

check 'Change Parameters adds to a base battle stat' do
  st = party_state
  a = st.party.actor_by_id(1) # atk 10
  it = Game::Interpreter.new(st)
  # scope 1, actor 1, op 0 (add), param 2 (atk), operand const 5
  it.start([FakeCmd.new(IC::CHANGE_PARAM, [1, 1, 0, 2, 0, 5])])
  it.update
  eq 15, a.atk
end

check 'Change Parameters lowering max HP re-clamps current HP' do
  st = party_state
  a = st.party.actor_by_id(1) # max_hp 100, hp 100
  it = Game::Interpreter.new(st)
  # scope 1, actor 1, op 1 (remove), param 0 (max_hp), const 60 -> max_hp 40
  it.start([FakeCmd.new(IC::CHANGE_PARAM, [1, 1, 1, 0, 0, 60])])
  it.update
  eq 40, a.max_hp
  eq 40, a.hp # current HP clamped down to the new maximum
end

check 'Change Parameters clamps a stat at its floor across the whole party' do
  st = party_state
  it = Game::Interpreter.new(st)
  # scope 0 (party), op 1 (remove), param 2 (atk), const 9999 -> floor 1
  it.start([FakeCmd.new(IC::CHANGE_PARAM, [0, 0, 1, 2, 0, 9999])])
  it.update
  eq 1, st.party.actor_by_id(1).atk
  eq 1, st.party.actor_by_id(2).atk
end

check 'Change Parameters raises max MP with a variable operand' do
  st = party_state
  st.variables[4] = 20
  a = st.party.actor_by_id(2) # max_mp 20
  it = Game::Interpreter.new(st)
  # scope 1, actor 2, op 0 (add), param 1 (max_mp), operand type 1 (var), var 4
  it.start([FakeCmd.new(IC::CHANGE_PARAM, [1, 2, 0, 1, 1, 4])])
  it.update
  eq 40, a.max_mp
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k logic check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k logic check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
