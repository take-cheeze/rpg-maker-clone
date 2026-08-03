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

# -- TextReveal (message typewriter effect) ----------------------------------

check 'TextReveal exposes characters across lines in order' do
  r = Game::TextReveal.new(['abc', 'de'])
  eq 5, r.total
  eq 0, r.revealed
  eq ['', ''], r.visible_lines
  r.advance(2)
  eq ['ab', ''], r.visible_lines
  r.advance(2)                      # 4 revealed: first line full, one of line 2
  eq ['abc', 'd'], r.visible_lines
  ok !r.done?, 'not done until every character shows'
  r.advance(2)                      # capped at 5
  eq 5, r.revealed
  ok r.done?
  eq ['abc', 'de'], r.visible_lines
end

check 'TextReveal#reveal_all finishes immediately' do
  r = Game::TextReveal.new(['hello', 'world'])
  r.reveal_all
  ok r.done?
  eq ['hello', 'world'], r.visible_lines
end

check 'TextReveal handles empty lines and an all-empty message' do
  r = Game::TextReveal.new(['', 'x', ''])
  eq 1, r.total
  eq ['', '', ''], r.visible_lines
  r.advance(1)
  ok r.done?
  eq ['', 'x', ''], r.visible_lines

  empty = Game::TextReveal.new([''])
  ok empty.done?, 'a message with no characters is already fully revealed'
end

# -- Screen (tint state machine) ---------------------------------------------

check 'Screen starts neutral and settled' do
  s = Game::Screen.new
  eq [100, 100, 100, 100], s.tint
  ok !s.tinting?, 'no transition in progress at rest'
end

check 'Screen tint interpolates to its target and lands exactly' do
  s = Game::Screen.new
  s.tint_to(200, 100, 100, 100, 4) # red 100 -> 200 over 4 frames
  ok s.tinting?
  s.update; eq 125, s.tint[0]
  s.update; eq 150, s.tint[0]
  s.update; eq 175, s.tint[0]
  s.update; eq 200, s.tint[0], 'lands exactly on the target on the last frame'
  ok !s.tinting?, 'settled once the transition completes'
  s.update # further updates are a no-op
  eq 200, s.tint[0]
end

check 'Screen tint with non-divisible steps still lands exactly' do
  s = Game::Screen.new
  s.tint_to(0, 100, 100, 100, 3) # red 100 -> 0 over 3 frames
  s.update; s.update; s.update
  eq 0, s.tint[0]
  ok !s.tinting?
end

check 'Screen tint with zero duration applies immediately' do
  s = Game::Screen.new
  s.tint_to(0, 50, 200, 100, 0)
  eq [0, 50, 200, 100], s.tint
  ok !s.tinting?, 'an instant tint needs no frames'
end

check 'Screen tint clamps channels to 0..200' do
  s = Game::Screen.new
  s.tint_to(999, -50, 100, 100, 0)
  eq [200, 0, 100, 100], s.tint
end

check 'Screen shake oscillates within amplitude and settles after its duration' do
  s = Game::Screen.new
  eq 0, s.shake_offset
  ok !s.shaking?
  s.shake(4, 5, 10) # power 4 -> amplitude 8 px, over 10 frames
  ok s.shaking?
  amp = 8
  moved = false
  9.times do
    s.update
    off = s.shake_offset
    ok off >= -amp && off <= amp, "shake offset #{off} outside +/-#{amp}"
    moved ||= off != 0
  end
  ok moved, 'the shake actually displaced the view'
  s.update # final frame settles back to centre
  eq 0, s.shake_offset
  ok !s.shaking?
end

check 'Screen shake with zero duration is inert' do
  s = Game::Screen.new
  s.shake(9, 9, 0)
  ok !s.shaking?
  eq 0, s.shake_offset
end

check 'Screen zero-power shake produces no offset' do
  s = Game::Screen.new
  s.shake(0, 5, 30)
  20.times { s.update }
  eq 0, s.shake_offset
end

check 'Screen flash fades from its peak strength to zero, then settles' do
  s = Game::Screen.new
  eq [0, 0, 0, 0], s.flash_color
  ok !s.flashing?
  s.flash(255, 255, 200, 40, 4) # colour, peak strength 40, over 4 frames
  ok s.flashing?
  eq [255, 255, 200, 40], s.flash_color, 'peaks at full strength when it starts'
  s.update; eq 30, s.flash_color[3]
  s.update; eq 20, s.flash_color[3]
  s.update; eq 10, s.flash_color[3]
  s.update
  eq 0, s.flash_color[3], 'faded fully out'
  ok !s.flashing?, 'no longer flashing once faded'
  s.update # further updates are a no-op
  eq 0, s.flash_color[3]
end

check 'Screen flash with zero duration is inert' do
  s = Game::Screen.new
  s.flash(255, 0, 0, 31, 0)
  ok !s.flashing?
  eq 0, s.flash_color[3]
end

check 'Screen busy? reflects tint, shake or flash activity' do
  s = Game::Screen.new
  ok !s.busy?
  s.tint_to(200, 100, 100, 100, 3)
  ok s.busy?, 'a tint transition makes it busy'
  3.times { s.update }
  ok !s.busy?
  s.shake(3, 3, 3)
  ok s.busy?, 'a shake makes it busy'
  3.times { s.update }
  ok !s.busy?
  s.flash(255, 255, 255, 20, 3)
  ok s.busy?, 'a flash makes it busy'
  3.times { s.update }
  ok !s.busy?
end

# -- Message parsing (control codes / colour) --------------------------------

check 'Message.expand fills v/n codes and drops display codes' do
  vars = Game::Variables.new
  vars[3] = 7
  names = { 5 => 'Aria' }
  eq 'HP:7', Game::Message.expand('HP:\v[3]', vars, names)
  eq 'Aria!', Game::Message.expand('\n[5]!', vars, names)
  eq 'ab', Game::Message.expand('a\.\|b', vars, names)   # wait codes dropped
  eq 'a\\b', Game::Message.expand('a\\\\b', vars, names) # \\ -> one backslash
  eq '', Game::Message.expand(nil, vars, names)
end

check 'Message.parse splits colour runs and expands codes within them' do
  vars = Game::Variables.new
  vars[3] = 7
  names = { 5 => 'Aria' }
  segs = Game::Message.parse('Hi \c[2]\n[5]\c[0]!', vars, names)
  eq [{ text: 'Hi ', color: 0 },
      { text: 'Aria', color: 2 },
      { text: '!', color: 0 }], segs
  # A variable inside a coloured run keeps that run's colour.
  eq [{ text: 'HP:', color: 0 }, { text: '7', color: 1 }],
     Game::Message.parse('HP:\c[1]\v[3]', vars, names)
end

check 'Message.parse omits empty runs and matches expand when joined' do
  vars = Game::Variables.new
  names = {}
  # A leading colour change produces no empty run.
  eq [{ text: 'x', color: 4 }], Game::Message.parse('\c[4]x', vars, names)
  eq [], Game::Message.parse('\c[3]', vars, names) # nothing visible
  src = 'a\c[1]b\c[0]c'
  joined = Game::Message.parse(src, vars, names).map { |s| s[:text] }.join
  eq Game::Message.expand(src, vars, names), joined
end

check 'Message.visible_segments truncates colour runs to the revealed count' do
  sl = [[{ text: 'ab', color: 0 }, { text: 'cd', color: 2 }],
        [{ text: 'ef', color: 1 }]]
  eq [[], []], Game::Message.visible_segments(sl, 0)
  # 3 chars: first run whole, one char of the second run; nothing on line 2.
  eq [[{ text: 'ab', color: 0 }, { text: 'c', color: 2 }], []],
     Game::Message.visible_segments(sl, 3)
  eq [[{ text: 'ab', color: 0 }, { text: 'cd', color: 2 }], []],
     Game::Message.visible_segments(sl, 4)
  # Line 1 full (4), then one char of line 2.
  eq [[{ text: 'ab', color: 0 }, { text: 'cd', color: 2 }],
      [{ text: 'e', color: 1 }]],
     Game::Message.visible_segments(sl, 5)
  eq sl, Game::Message.visible_segments(sl, 99) # capped: everything shows
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

# -- Message Options / Change Face Graphic ------------------------------------

check 'Message Options sets window position, transparency and continue flag' do
  st = new_state
  it = Game::Interpreter.new(st)
  # transparent=1, position=0 (top), param2=1 (auto-position -> not fixed),
  # continue events=1.
  it.start([FakeCmd.new(IC::MESSAGE_OPTIONS, [1, 0, 1, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  cfg = st.message_config
  eq true, cfg.transparent
  eq Game::MessageConfig::POS_TOP, cfg.position
  eq false, cfg.position_fixed             # param2 == 1 -> not fixed
  eq true, cfg.continue_events
  ok !it.waiting?, 'Message Options must not pause the interpreter'
  eq true, st.switches[1], 'the command after Message Options still ran'
end

check 'Message Options param2 == 0 pins the window (position fixed)' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::MESSAGE_OPTIONS, [0, 2, 0, 0])])
  it.update
  eq true, st.message_config.position_fixed
  eq Game::MessageConfig::POS_BOTTOM, st.message_config.position
  eq false, st.message_config.transparent
end

check 'Change Face Graphic selects a face; an empty name clears it' do
  st = new_state
  it = Game::Interpreter.new(st)
  # name "Hero1", index 3, right=1, flipped=1.
  it.start([FakeCmd.new(IC::CHANGE_FACE, [3, 1, 1], string: 'Hero1')])
  it.update
  cfg = st.message_config
  ok cfg.face?, 'a face is selected'
  eq 'Hero1', cfg.face_name
  eq 3, cfg.face_index
  eq true, cfg.face_right
  eq true, cfg.face_flipped
  ok !it.waiting?, 'Change Face Graphic must not pause the interpreter'
  # An empty name clears the face for subsequent messages.
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_FACE, [0, 0, 0], string: '')])
  it2.update
  ok !cfg.face?, 'an empty name clears the face'
  eq '', cfg.face_name
  eq 0, cfg.face_index
end

check 'MessageConfig round-trips through to_h / load_h' do
  cfg = Game::MessageConfig.new
  cfg.transparent = true
  cfg.position = Game::MessageConfig::POS_MIDDLE
  cfg.position_fixed = true
  cfg.continue_events = true
  cfg.face_name = 'Faces1'
  cfg.face_index = 7
  cfg.face_right = true
  cfg.face_flipped = true
  restored = Game::MessageConfig.new.load_h(cfg.to_h)
  eq cfg.to_h, restored.to_h
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

check 'Erase Event sets a one-shot request without pausing the interpreter' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ERASE_EVENT, []),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'Erase Event must not pause the interpreter'
  eq true, st.switches[1], 'the command after Erase Event still ran'
  eq true, it.take_erase_request, 'the erase was requested'
  eq false, it.take_erase_request, 'the request is one-shot (cleared on read)'
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

check 'Proceed With Movement pauses the interpreter on a movement wait' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::PROCEED_WITH_MOVEMENT, []),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'Proceed With Movement pauses'
  eq :movement, it.wait_kind
  ok !st.switches[1], 'the following command has not run while waiting'
  it.resume # the scene resumes once forced movement completes
  it.update
  eq true, st.switches[1], 'resuming runs the rest of the list'
end

check 'Tint Screen without a wait sets the target and does not pause' do
  st = new_state
  it = Game::Interpreter.new(st)
  # red 200, green/blue/sat 100, over 5 tenths (30 frames), wait=0.
  it.start([FakeCmd.new(IC::TINT_SCREEN, [200, 100, 100, 100, 5, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'a no-wait tint keeps running'
  eq true, st.switches[1], 'the command after the tint still ran'
  ok st.screen.tinting?, 'a timed tint transition is in progress'
end

check 'Tint Screen with a wait pauses until the transition settles' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::TINT_SCREEN, [0, 100, 100, 100, 1, 1]), # 6 frames, wait
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok it.waiting?, 'a waiting tint pauses the interpreter'
  eq :screen, it.wait_kind
  ok !st.switches[2], 'the following command has not run yet'
  # The scene advances the screen each frame; drive it to completion, then resume.
  st.screen.update until !st.screen.tinting?
  it.resume
  it.update
  eq true, st.switches[2], 'resumed and ran the rest once the tint settled'
  eq 0, st.screen.tint[0]
end

check 'Tint Screen with an instant (zero-duration) transition does not wait' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::TINT_SCREEN, [50, 60, 70, 100, 0, 1])]) # dur 0, wait 1
  it.update
  ok !it.waiting?, 'nothing to wait for when the tint is immediate'
  eq [50, 60, 70, 100], st.screen.tint
end

check 'Shake Screen without a wait starts a shake and does not pause' do
  st = new_state
  it = Game::Interpreter.new(st)
  # power 5, speed 4, 5 tenths (30 frames), wait 0.
  it.start([FakeCmd.new(IC::SHAKE_SCREEN, [5, 4, 5, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'a no-wait shake keeps running'
  eq true, st.switches[1], 'the command after the shake still ran'
  ok st.screen.shaking?, 'a shake is in progress'
end

check 'Shake Screen with a wait pauses until the shake ends' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHAKE_SCREEN, [5, 4, 1, 1]), # 6 frames, wait
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok it.waiting?, 'a waiting shake pauses the interpreter'
  eq :screen, it.wait_kind
  ok !st.switches[2]
  st.screen.update until !st.screen.busy? # the scene advances it each frame
  it.resume
  it.update
  eq true, st.switches[2], 'resumed once the shake finished'
end

check 'Flash Screen without a wait starts a flash and does not pause' do
  st = new_state
  it = Game::Interpreter.new(st)
  # white flash, strength 31, 5 tenths (30 frames), wait 0.
  it.start([FakeCmd.new(IC::FLASH_SCREEN, [255, 255, 255, 31, 5, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'a no-wait flash keeps running'
  eq true, st.switches[1], 'the command after the flash still ran'
  ok st.screen.flashing?, 'a flash is in progress'
  eq [255, 255, 255, 31], st.screen.flash_color
end

check 'Flash Screen with a wait pauses until the flash fades out' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::FLASH_SCREEN, [255, 0, 0, 20, 1, 1]), # 6 frames, wait
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok it.waiting?, 'a waiting flash pauses the interpreter'
  eq :screen, it.wait_kind
  ok !st.switches[2]
  st.screen.update until !st.screen.busy? # the scene advances it each frame
  it.resume
  it.update
  eq true, st.switches[2], 'resumed once the flash faded'
  eq 0, st.screen.flash_color[3]
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

# -- Memorize / Recall Location ----------------------------------------------

check 'Memorize Location stores map/x/y into three variables' do
  st = new_state # map_id 1
  st.x = 7
  st.y = 4
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::MEMORIZE_LOCATION, [10, 11, 12])])
  it.update
  eq 1, st.variables[10], 'map id stored'
  eq 7, st.variables[11], 'x stored'
  eq 4, st.variables[12], 'y stored'
  ok !it.waiting?, 'Memorize Location does not pause the interpreter'
end

check 'Recall to Location issues a teleport from the stored variables' do
  st = new_state
  st.variables[10] = 3 # map
  st.variables[11] = 6 # x
  st.variables[12] = 2 # y
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::RECALL_LOCATION, [10, 11, 12])])
  it.update
  ok it.waiting?, 'Recall pauses on the teleport request'
  eq :teleport, it.wait_kind
  eq [3, 6, 2, 0], it.teleport # keeps the current facing (direction 0)
end

# -- Store Terrain ID / Store Event ID ---------------------------------------

# A map_info hook: terrain id is x*10+y, and an event id 7 sits at (2, 3).
class FakeMapInfo
  def terrain_id(x, y); x * 10 + y; end
  def event_id_at(x, y); (x == 2 && y == 3) ? 7 : 0; end
end

check 'Store Terrain ID reads a constant tile and a variable-addressed tile' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfo.new
  st.variables[8] = 4
  st.variables[9] = 1
  it.start([FakeCmd.new(IC::STORE_TERRAIN_ID, [0, 5, 6, 1]),   # const (5,6) -> var1
            FakeCmd.new(IC::STORE_TERRAIN_ID, [1, 8, 9, 2])])  # var (4,1) -> var2
  it.update
  eq 56, st.variables[1], 'terrain at (5,6)'
  eq 41, st.variables[2], 'terrain at (4,1) via variables'
  ok !it.waiting?, 'Store Terrain ID does not pause'
end

check 'Store Event ID stores the event at a tile, 0 when none' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfo.new
  it.start([FakeCmd.new(IC::STORE_EVENT_ID, [0, 2, 3, 1]),   # event 7 sits here
            FakeCmd.new(IC::STORE_EVENT_ID, [0, 0, 0, 2])])  # nothing here
  it.update
  eq 7, st.variables[1]
  eq 0, st.variables[2]
end

check 'Store Terrain / Event ID store 0 when no map_info hook is set' do
  st = new_state
  it = Game::Interpreter.new(st) # map_info defaults to nil
  it.start([FakeCmd.new(IC::STORE_TERRAIN_ID, [0, 5, 6, 1]),
            FakeCmd.new(IC::STORE_EVENT_ID, [0, 2, 3, 2])])
  it.update
  eq 0, st.variables[1]
  eq 0, st.variables[2]
end

# -- Change Main Menu / Save Access ------------------------------------------

check 'Change Main Menu Access allows and forbids opening the menu' do
  st = new_state
  ok st.menu_access, 'menu access defaults on'
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_MENU_ACCESS, [0])]) # forbid
  it.update
  eq false, st.menu_access
  ok !it.waiting?, 'the command does not pause the interpreter'
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_MENU_ACCESS, [1])]) # allow again
  it2.update
  eq true, st.menu_access
end

check 'Change Save Access allows and forbids saving' do
  st = new_state
  ok st.save_access, 'save access defaults on'
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_SAVE_ACCESS, [0])]) # forbid
  it.update
  eq false, st.save_access
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_SAVE_ACCESS, [1])]) # allow again
  it2.update
  eq true, st.save_access
end

# -- Memorize / Play Memorized BGM (the BGM stack) ---------------------------

check 'Memorize/Play Memorized BGM stashes and restores the current BGM' do
  RGSS::Audio.log = []
  st = new_state
  it = Game::Interpreter.new(st)
  # Play "town", memorize it, duck to "fanfare", then restore the memorized BGM.
  it.start([
    FakeCmd.new(IC::PLAY_BGM, [0, 80, 100], string: 'town'),
    FakeCmd.new(IC::MEMORIZE_BGM, []),
    FakeCmd.new(IC::PLAY_BGM, [0, 100, 100], string: 'fanfare'),
    FakeCmd.new(IC::PLAY_MEMORIZED_BGM, []),
  ])
  it.update
  eq 'town', st.current_bgm[:name], 'the memorized BGM is current again'
  eq 80, st.current_bgm[:volume], 'its volume was preserved'
  names = RGSS::Audio.log.select { |e| e[0] == :bgm }.map { |e| e[1] }
  eq %w[town fanfare town], names, 'the backend played town, fanfare, then town'
end

check 'Play Memorized BGM with nothing memorized does nothing' do
  RGSS::Audio.log = []
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::PLAY_MEMORIZED_BGM, [])])
  it.update
  eq 0, RGSS::Audio.log.select { |e| e[0] == :bgm }.size, 'no BGM was played'
  eq nil, st.memorized_bgm
end

# -- actor HP / MP commands ---------------------------------------------------

# A database row for an actor, and a fake DB exposing just what Game::Party /
# Game::Actor read (player table + the initial party list).
FakePlayerRow = Struct.new(:name, :charset_name, :charset_index,
                           :initial_level, :status)
# Like FakePlayerRow but exposing the full growth curve the way a real LCF row
# does (six shorts per level via #int16_values(31)), so Actor scales its base
# stats by level instead of using a single level-independent status hash.
class CurveRow < FakePlayerRow
  def initialize(name, cs, ci, level, curve)
    super(name, cs, ci, level, nil)
    @curve = curve
  end

  def int16_values(idx)
    idx == 31 ? @curve : nil
  end
end
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

check 'State save round-trips the message configuration' do
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8),
  }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.message_config.transparent = true
  st.message_config.position = Game::MessageConfig::POS_TOP
  st.message_config.face_name = 'F'
  st.message_config.face_index = 2
  st.menu_access = false
  st.save_access = false
  st.current_bgm = { name: 'town', volume: 80, tempo: 100 }
  st.memorized_bgm = { name: 'field', volume: 70, tempo: 90 }
  loaded = Game::State.load(db, st.to_h)
  eq true, loaded.message_config.transparent
  eq Game::MessageConfig::POS_TOP, loaded.message_config.position
  eq 'F', loaded.message_config.face_name
  eq 2, loaded.message_config.face_index
  eq false, loaded.menu_access, 'menu access round-trips'
  eq false, loaded.save_access, 'save access round-trips'
  eq 'town', loaded.current_bgm[:name], 'current BGM round-trips'
  eq 'field', loaded.memorized_bgm[:name], 'memorized BGM round-trips'
  # A save written before these flags existed keeps them enabled (default on).
  legacy = st.to_h
  legacy.delete(:menu_access)
  legacy.delete(:save_access)
  legacy_loaded = Game::State.load(db, legacy)
  eq true, legacy_loaded.menu_access, 'absent menu access defaults on'
  eq true, legacy_loaded.save_access, 'absent save access defaults on'
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

check 'Actor base stats scale with level from the growth curve' do
  # Two levels, six stats each: L1 = maxhp10/maxmp5/atk3/def2/int1/agi4,
  # L2 = double each (except as listed).
  curve = [10, 5, 3, 2, 1, 4,  20, 10, 6, 4, 2, 8]
  db = FakeActorDB.new({ 1 => CurveRow.new('Hero', '', 0, 1, curve) }, [1])
  a = Game::Party.new(db).leader
  eq 1, a.level
  eq [10, 5, 3, 2, 1, 4], [a.max_hp, a.max_mp, a.atk, a.def, a.int, a.agi]
  eq 10, a.hp                       # a fresh actor starts full
  a.set_level(2)
  eq [20, 10, 6, 4, 2, 8], [a.max_hp, a.max_mp, a.atk, a.def, a.int, a.agi]
  # A level past the curve clamps to its last entry rather than reading past it.
  a.set_level(99)
  eq 20, a.max_hp
  # Lowering the level re-clamps current HP/MP to the smaller maxima.
  a.hp = 20; a.mp = 10
  a.set_level(1)
  eq [10, 5], [a.hp, a.mp]
end

check 'Actor without a growth curve falls back to a level-independent status' do
  # party_state uses FakePlayerRow (a status hash, no int16_values): stats stay
  # put regardless of level, and the initial level is honoured.
  hero = party_state.party.actor_by_id(1)
  eq 5, hero.level
  eq [100, 30], [hero.max_hp, hero.max_mp]
  hero.set_level(2)
  eq [100, 30], [hero.max_hp, hero.max_mp]
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

# -- Control Variables operands ----------------------------------------------

check 'Control Variables random operand stays within its range' do
  st = new_state
  it = Game::Interpreter.new(st)
  20.times do
    # var 1 = random in [10, 20]: operand type 3, param5 = lo, param6 = hi.
    it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 3, 10, 20])])
    it.update
    v = st.variables[1]
    ok v >= 10 && v <= 20, "random operand #{v} outside [10, 20]"
  end
end

check 'Control Variables reads party gold and the timer (operand type 7)' do
  st = new_state
  st.party.gain_gold(500)
  st.timer_frames = 90 * 60 # 90 seconds
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 7, 0]),   # var1 = gold
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 7, 1])])  # var2 = timer secs
  it.update
  eq 500, st.variables[1]
  eq 90, st.variables[2]
end

check 'Control Variables reads an actor stat (operand type 5)' do
  st = party_state
  a = st.party.actor_by_id(1) # atk 10, max_hp 100
  a.hp = 42
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 5, 1, 6]),  # var1 = attack
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 5, 1, 2]),  # var2 = HP
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 5, 1, 4]),  # var3 = max HP
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 5, 1, 7])]) # var4 = defence
  it.update
  eq 10, st.variables[1]
  eq 42, st.variables[2]
  eq 100, st.variables[3]
  eq 8, st.variables[4]
end

check 'Control Variables actor operand reads 0 for an absent actor' do
  st = party_state
  st.variables[1] = 7
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 5, 99, 2])]) # actor 99 absent
  it.update
  eq 0, st.variables[1]
end

# -- Conditional branch: actor (hero) sub-conditions -------------------------

# Build a conditional (type 5) with an if-body switch 1 and an else-body switch
# 2, run it against a fresh party_state, and return that state.
def run_actor_cond(params, string: '')
  st = party_state
  yield st if block_given?
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONDITIONAL, params, indent: 0, string: string),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
            FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
            FakeCmd.new(IC::END_BRANCH, [], indent: 0)])
  it.update
  st
end

check 'Conditional actor: in-party sub-condition (type 5, sub 0)' do
  st = run_actor_cond([5, 1, 0])     # actor 1 is in the party
  eq true, st.switches[1]
  st = run_actor_cond([5, 9, 0])     # actor 9 is not
  eq true, st.switches[2]
end

check 'Conditional actor: level >= (type 5, sub 2)' do
  eq true,  run_actor_cond([5, 1, 2, 5]).switches[1] # actor 1 level 5 >= 5
  eq true,  run_actor_cond([5, 1, 2, 6]).switches[2] # 5 >= 6 is false -> else
end

check 'Conditional actor: HP >= (type 5, sub 3)' do
  st = run_actor_cond([5, 1, 3, 50]) { |s| s.party.actor_by_id(1).hp = 30 }
  eq true, st.switches[2] # hp 30 < 50 -> else
  st = run_actor_cond([5, 1, 3, 50]) { |s| s.party.actor_by_id(1).hp = 80 }
  eq true, st.switches[1] # hp 80 >= 50
end

check 'Conditional actor: name equals the command string (type 5, sub 1)' do
  eq true, run_actor_cond([5, 1, 1], string: 'Hero').switches[1]
  eq true, run_actor_cond([5, 1, 1], string: 'Nope').switches[2]
end

check 'Conditional actor: unmodelled sub-condition reads false (type 5, sub 6)' do
  eq true, run_actor_cond([5, 1, 6, 3]).switches[2] # has-state -> false -> else
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k logic check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k logic check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
