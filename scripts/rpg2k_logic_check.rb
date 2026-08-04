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

check 'Screen pan scrolls the offset toward its target and lands exactly' do
  s = Game::Screen.new
  eq [0, 0], s.pan_offset
  ok !s.panning?
  s.pan(1, 2, 3) # pan right 2 tiles (32 px) at speed 3 -> 4 px/frame
  ok s.panning?
  ok s.busy?, 'a pan in progress makes the screen busy'
  s.update; eq [4, 0], s.pan_offset
  s.update; eq [8, 0], s.pan_offset
  6.times { s.update } # 32 px total reached (and clamped)
  eq [32, 0], s.pan_offset
  ok !s.panning?, 'settles exactly on the target'
end

check 'Screen pan directions move the offset the right way' do
  s = Game::Screen.new
  s.pan(0, 1, 6); 5.times { s.update } # up: negative y
  eq [0, -16], s.pan_offset
  s.pan_reset(6); 5.times { s.update }
  eq [0, 0], s.pan_offset, 'reset scrolls back to the origin'
  s.pan(3, 1, 6); 5.times { s.update } # left: negative x
  eq [-16, 0], s.pan_offset
end

check 'Screen pan lock / unlock toggles the follow flag' do
  s = Game::Screen.new
  ok !s.pan_locked?
  s.pan_lock
  ok s.pan_locked?
  s.pan_unlock
  ok !s.pan_locked?
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

check 'Pan Screen lock / unlock are instant and never pause' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::PAN_SCREEN, [0, 0, 0, 0, 1]),   # lock, wait flag set
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'lock does not pause even with the wait flag'
  ok st.screen.pan_locked?
  eq true, st.switches[1]
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::PAN_SCREEN, [1, 0, 0, 0, 0])]) # unlock
  it2.update
  ok !st.screen.pan_locked?
end

check 'Pan Screen (op 2) with a wait pauses until the scroll finishes' do
  st = new_state
  it = Game::Interpreter.new(st)
  # op 2 pan, direction 1 (right), distance 1 tile, speed 6, wait 1.
  it.start([FakeCmd.new(IC::PAN_SCREEN, [2, 1, 1, 6, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok it.waiting?, 'a waiting pan pauses the interpreter'
  eq :screen, it.wait_kind
  ok !st.switches[2]
  ok st.screen.panning?
  st.screen.update until !st.screen.busy? # the scene advances it each frame
  it.resume
  it.update
  eq true, st.switches[2], 'resumed once the pan reached its target'
  eq [16, 0], st.screen.pan_offset
end

# -- Erase / Show Screen ------------------------------------------------------

check 'Erase Screen fades to black, pauses the event, then holds erased' do
  st = new_state
  eq 0, st.screen.fade_level, 'screen visible by default'
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ERASE_SCREEN, [0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'Erase Screen suspends until the fade settles'
  eq :screen, it.wait_kind
  ok st.screen.fading?, 'the fade is in progress'
  ok !st.switches[1], 'the next command has not run yet'
  st.screen.update until !st.screen.busy? # the scene advances it each frame
  eq 255, st.screen.fade_level, 'fully black'
  ok st.screen.erased?, 'the screen is held erased'
  it.resume
  it.update
  eq true, st.switches[1], 'the event continued once the fade settled'
end

check 'Show Screen fades back in from black' do
  st = new_state
  st.screen.erase(0, 32)
  st.screen.update until !st.screen.fading? # start fully black
  eq 255, st.screen.fade_level
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_SCREEN, [0])])
  it.update
  ok it.waiting?, 'Show Screen also waits for its fade'
  st.screen.update until !st.screen.fading?
  eq 0, st.screen.fade_level, 'fully visible again'
  ok !st.screen.erased?
end

check 'Show Screen when already visible does not pause' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_SCREEN, [0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok !it.waiting?, 'a no-op show settles immediately'
  eq true, st.switches[2], 'the event ran straight through'
end

check 'Erase Screen records the transition style and ramps the level' do
  st = new_state
  st.screen.erase(3, 32) # transition style 3 (a block/stripe variant)
  eq 3, st.screen.fade_transition, 'the style is recorded for fidelity'
  before = st.screen.fade_level
  st.screen.update
  ok st.screen.fade_level > before, 'the level eases toward black'
  ok st.screen.fade_level < 255, 'over time, not instantly'
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

# A database learn-table row (skill_id learnt at level), plus an Array2D-alike
# table exposing them the way the real player row's #skills does (each yields
# id, entry). Lets Game::Actor seed its skills by level without the LCF parser.
FakeLearn = Struct.new(:skill_id, :level)
class FakeLearnTable
  def initialize(pairs); @pairs = pairs; end # [[skill_id, level], ...]
  def each; @pairs.each_index { |i| yield i, FakeLearn.new(*@pairs[i]) }; end
end
class SkillRow < CurveRow
  def initialize(name, cs, ci, level, curve, learns)
    super(name, cs, ci, level, curve)
    @learns = learns
  end

  def skills; FakeLearnTable.new(@learns); end
end
FakeActorSystem = Struct.new(:party)
# A database item row exposing the equipment-bonus fields Game::Actor reads plus
# the medicine recovery/scope fields Game::Party#use_item reads.
FakeItem = Struct.new(:atk_points1, :def_points1, :spi_points1, :agi_points1,
                      :max_hp_points, :max_sp_points, :type, :name, :scope,
                      :recover_hp, :recover_hp_rate, :recover_sp, :recover_sp_rate,
                      :price, :skill_id,
                      :atk_points2, :def_points2, :spi_points2, :agi_points2)
def fake_item(atk: 0, dfn: 0, spi: 0, agi: 0, mhp: 0, msp: 0, type: 0, name: '',
              scope: 0, rhp: 0, rhp_rate: 0, rsp: 0, rsp_rate: 0, price: 0,
              skill_id: 0, atk2: 0, dfn2: 0, spi2: 0, agi2: 0)
  FakeItem.new(atk, dfn, spi, agi, mhp, msp, type, name, scope,
               rhp, rhp_rate, rsp, rsp_rate, price, skill_id,
               atk2, dfn2, spi2, agi2)
end
# A database skill row exposing the fields Game::Party's field-skill logic reads.
FakeSkill = Struct.new(:name, :type, :scope, :occasion_field, :sp_type, :sp_cost,
                       :sp_percent, :power, :physical_rate, :magical_rate,
                       :affect_hp, :affect_sp)
def fake_skill(name: '', type: 0, scope: 3, occ: true, sp_type: 0, sp_cost: 0,
               sp_percent: 0, power: 0, prate: 0, mrate: 0, hp: false, sp: false)
  FakeSkill.new(name, type, scope, occ, sp_type, sp_cost, sp_percent, power,
                prate, mrate, hp, sp)
end
class FakeActorDB
  attr_reader :player, :system, :item, :skill
  def initialize(players, party_ids, items = {}, skills = {})
    @player = players
    @system = FakeActorSystem.new(party_ids)
    @item = items
    @skill = skills
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

check 'Party save round-trips actor name / title / sprite overrides' do
  players = {
    1 => FakePlayerRow.new('Hero', 'Base', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8),
  }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  hero = st.party.actor_by_id(1)
  hero.name = 'Renamed'
  hero.title = 'Champion'
  hero.set_charset('Monster', 3)
  hero.transparent = true
  loaded = Game::State.load(db, st.to_h).party.actor_by_id(1)
  eq 'Renamed', loaded.name
  eq 'Champion', loaded.title
  eq 'Monster', loaded.charset_name
  eq 3, loaded.charset_index
  eq true, loaded.transparent
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

check 'Actor equipment adds item bonuses to the effective stats' do
  items = { 10 => fake_item(atk: 20), 11 => fake_item(dfn: 8, agi: -3),
            12 => fake_item(mhp: 50) }
  # base at L1: maxhp10 maxmp5 atk3 def2 int1 agi4
  db = FakeActorDB.new({ 1 => CurveRow.new('Hero', '', 0, 1, [10, 5, 3, 2, 1, 4]) },
                       [1], items)
  a = Game::Party.new(db).leader
  eq [3, 2, 4, 10], [a.atk, a.def, a.agi, a.max_hp]   # nothing equipped
  a.equip([10, 11, 12, 0, 0])
  eq [23, 10, 1, 60], [a.atk, a.def, a.agi, a.max_hp] # +20 atk, +8 def-3 agi, +50 hp
  eq true, a.equipped?(11)
  eq false, a.equipped?(99)
  # Change Parameters lands on the base stat; the equipment bonus stays on top.
  a.change_param(Game::Actor::PARAM_ATK, 5)           # base 3 -> 8
  eq 28, a.atk                                        # 8 + 20
  # Unequipping removes the bonus.
  a.equip([0, 0, 0, 0, 0])
  eq [8, 2, 4, 10], [a.atk, a.def, a.agi, a.max_hp]
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

check 'Actor learns skills from the growth table up to its level' do
  # 25@L1, 32@L1, 27@L5 -- mirrors a real actor whose L5 skill set is 25/27/32.
  learns = [[25, 1], [32, 1], [27, 5]]
  db = FakeActorDB.new(
    { 1 => SkillRow.new('Hero', '', 0, 1, [10, 5, 3, 2, 1, 4], learns) }, [1])
  a = Game::Party.new(db).leader
  eq [25, 32], a.skills.sort            # only the L1 skills at level 1
  a.set_level(5)
  eq [25, 27, 32], a.skills.sort        # 27 joins at level 5
  a.set_level(1)
  eq [25, 27, 32], a.skills.sort        # levelling down keeps learnt skills
  ok a.knows_skill?(27)
  ok !a.knows_skill?(99)
  # learn / forget mutate the set.
  a.learn_skill(99); ok a.knows_skill?(99)
  a.forget_skill(27); ok !a.knows_skill?(27)
  # restoring a saved set replaces it.
  a.skills = [1, 2, 2, 0]
  eq [1, 2], a.skills.sort
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

check 'Change Level command raises the level and rescales stats' do
  # Two-level curve: L1 maxhp10/atk3, L2 maxhp20/atk6.
  db = FakeActorDB.new(
    { 1 => CurveRow.new('Hero', '', 0, 1, [10, 5, 3, 2, 1, 4, 20, 10, 6, 4, 2, 8]) }, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  a = st.party.actor_by_id(1)
  eq [1, 10, 3], [a.level, a.max_hp, a.atk]
  it = Game::Interpreter.new(st)
  # scope 1 fixed, actor 1, op 0 (add), operand-type 0 (const), amount 1, show 0
  it.start([FakeCmd.new(IC::CHANGE_LEVEL, [1, 1, 0, 0, 1, 0])])
  it.update
  eq [2, 20, 6], [a.level, a.max_hp, a.atk]
  # op 1 removes a level.
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_LEVEL, [1, 1, 1, 0, 1, 0])])
  it2.update
  eq 1, a.level
end

check 'Change Equipment command equips into the type slot and removes' do
  items = { 7 => fake_item(atk: 15, type: 1),   # weapon -> slot 0
            8 => fake_item(dfn: 9, type: 3) }    # armour -> slot 2
  db = FakeActorDB.new(
    { 1 => CurveRow.new('Hero', '', 0, 1, [10, 5, 3, 2, 1, 4]) }, [1], items)
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  a = st.party.actor_by_id(1)
  # Equip weapon 7 (const item): scope1, actor1, op0 equip, operand0 const, item7.
  Game::Interpreter.new(st).tap { |it| it.start([FakeCmd.new(IC::CHANGE_EQUIP, [1, 1, 0, 0, 7])]); it.update }
  eq 18, a.atk         # base 3 + 15
  eq 7, a.equipment[0]
  # Equip armour 8 from variable 5 (operand source 1).
  st.variables[5] = 8
  Game::Interpreter.new(st).tap { |it| it.start([FakeCmd.new(IC::CHANGE_EQUIP, [1, 1, 0, 1, 5])]); it.update }
  eq 11, a.def         # base 2 + 9
  eq 8, a.equipment[2]
  # Remove the weapon slot (op 1, slot 0).
  Game::Interpreter.new(st).tap { |it| it.start([FakeCmd.new(IC::CHANGE_EQUIP, [1, 1, 1, 0, 0])]); it.update }
  eq 3, a.atk
  eq 0, a.equipment[0]
  eq 8, a.equipment[2] # armour still on
end

# -- Field item menu (Game::Party medicine use) ------------------------------

# A two-actor party (Hero max 100/30, Ally max 50/20) plus the given item table,
# for the medicine-use checks.
def item_party(items)
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5, max_hp: 100, max_mp: 30, atk: 10, def: 8),
    2 => FakePlayerRow.new('Ally', '', 0, 3, max_hp: 50, max_mp: 20, atk: 6, def: 5),
  }
  Game::State.new(Game::Party.new(FakeActorDB.new(players, [1, 2], items)), 1, 0, 0)
end

check 'field_items lists only held medicines, in id order with counts' do
  items = { 5 => fake_item(type: 6, rhp: 50),   # medicine
            7 => fake_item(type: 1, atk: 10),   # weapon -- not field-usable
            9 => fake_item(type: 6, rsp: 10) }  # medicine
  st = item_party(items)
  st.party.gain_item(9, 2)
  st.party.gain_item(5, 1)
  st.party.gain_item(7, 1)   # weapon in the bag but not usable from the menu
  eq [[5, 1], [9, 2]], st.party.field_items
end

check 'item_recovery sums the flat amount and the percentage (integer math)' do
  st = item_party({})
  hero = st.party.leader                       # max_hp 100, max_mp 30
  it = fake_item(type: 6, rhp: 10, rhp_rate: 25, rsp: 3, rsp_rate: 10)
  eq [35, 6], st.party.item_recovery(it, hero) # 10 + 100*25/100 ; 3 + 30*10/100
end

check 'use_item heals a single-target medicine, clamps and consumes one' do
  items = { 5 => fake_item(type: 6, rhp: 40) }
  st = item_party(items)
  st.party.gain_item(5, 3)
  hero = st.party.leader
  hero.change_hp(-70)                          # 100 -> 30
  affected = st.party.use_item(5, hero)
  eq [hero], affected
  eq 70, hero.hp                               # 30 + 40
  eq 2, st.party.item_count(5)
  # A second use overheals but clamps to max, still consuming one.
  st.party.use_item(5, hero)
  eq 100, hero.hp
  eq 1, st.party.item_count(5)
end

check 'use_item on an already-full target has no effect and consumes nothing' do
  items = { 5 => fake_item(type: 6, rhp: 40) }
  st = item_party(items)
  st.party.gain_item(5, 2)
  hero = st.party.leader                       # full HP
  eq false, st.party.item_effective?(5, hero)
  eq [], st.party.use_item(5, hero)
  eq 2, st.party.item_count(5)                 # not consumed
end

check 'an all-ally medicine heals the whole party and consumes one' do
  items = { 8 => fake_item(type: 6, scope: 1, rhp_rate: 100) } # full HP heal
  st = item_party(items)
  st.party.gain_item(8, 1)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.change_hp(-60)                          # 100 -> 40
  ally.change_hp(-30)                          # 50  -> 20
  affected = st.party.use_item(8, nil)         # all-ally: target arg ignored
  eq [1, 2], affected.map { |a| a.id }.sort
  eq 100, hero.hp
  eq 50, ally.hp
  eq 0, st.party.item_count(8)
end

check 'use_item restores MP and item_effective? tracks the SP deficit' do
  items = { 6 => fake_item(type: 6, rsp: 15) }
  st = item_party(items)
  st.party.gain_item(6, 1)
  hero = st.party.leader
  hero.change_mp(-20)                          # 30 -> 10
  eq true, st.party.item_effective?(6, hero)
  st.party.use_item(6, hero)
  eq 25, hero.mp                               # 10 + 15
  eq 0, st.party.item_count(6)
end

check 'field_items includes skill books alongside medicines' do
  items = { 5 => fake_item(type: 6, rhp: 10),       # medicine
            8 => fake_item(type: 7, skill_id: 42),  # skill book
            3 => fake_item(type: 1, atk: 5) }       # weapon (not usable)
  st = item_party(items)
  [5, 8, 3].each { |id| st.party.gain_item(id, 1) }
  eq [[5, 1], [8, 1]], st.party.field_items
end

check 'a skill book teaches its skill to the target and is consumed' do
  st = item_party({ 8 => fake_item(type: 7, skill_id: 42) })
  st.party.gain_item(8, 2)
  hero = st.party.leader
  eq false, hero.knows_skill?(42)
  eq true, st.party.item_effective?(8, hero)
  eq [hero], st.party.use_item(8, hero)
  eq true, hero.knows_skill?(42)
  eq 1, st.party.item_count(8)                 # one book consumed
end

check 'a skill book on an actor who already knows the skill does nothing' do
  st = item_party({ 8 => fake_item(type: 7, skill_id: 42) })
  st.party.gain_item(8, 1)
  hero = st.party.leader
  hero.learn_skill(42)
  eq false, st.party.item_effective?(8, hero)
  eq [], st.party.use_item(8, hero)
  eq 1, st.party.item_count(8)                 # not consumed
end

check 'a seed permanently raises the target stats (points2 set) and is consumed' do
  st = item_party({ 9 => fake_item(type: 8, mhp: 50, atk2: 5) })
  st.party.gain_item(9, 2)
  hero = st.party.leader                        # max_hp 100, atk 10
  eq true, st.party.item_effective?(9, hero)
  eq [hero], st.party.use_item(9, hero)
  eq 150, hero.max_hp                           # +50 base max HP
  eq 15, hero.atk                               # +5 base attack (atk_points2)
  eq 1, st.party.item_count(9)                  # one seed consumed
end

check 'field_items includes seeds; a seed with no boost is ineffective' do
  items = { 9 => fake_item(type: 8, mhp: 20),   # seed with a boost
            4 => fake_item(type: 8) }           # seed with no boost
  st = item_party(items)
  st.party.gain_item(9, 1)
  st.party.gain_item(4, 1)
  eq [[4, 1], [9, 1]], st.party.field_items     # both held seeds are listed
  hero = st.party.leader
  eq false, st.party.item_effective?(4, hero)   # no boost -> ineffective
  eq [], st.party.use_item(4, hero)             # nothing happens
  eq 1, st.party.item_count(4)                  # not consumed
end

# -- Field skill menu (Game::Party skill casting) ----------------------------

# A two-actor party (Hero atk 10 / spirit 12 / max SP 30, Ally max HP 50) plus
# the given skill table, for the field-skill checks.
def skill_party(skills)
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8, int: 12, agi: 7),
    2 => FakePlayerRow.new('Ally', '', 0, 3,
                           max_hp: 50, max_mp: 20, atk: 6, def: 5, int: 4, agi: 6),
  }
  Game::State.new(Game::Party.new(FakeActorDB.new(players, [1, 2], {}, skills)), 1, 0, 0)
end

check 'a field heal skill restores HP by the RPG2000 formula and spends SP' do
  # effect = power 20 + physical_rate 0 * atk/20 + magical_rate 40 * spirit 12 /40
  #        = 20 + 0 + 12 = 32
  skills = { 7 => fake_skill(name: 'Heal', scope: 3, sp_cost: 5,
                             power: 20, mrate: 40, hp: true) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.learn_skill(7)
  ally.change_hp(-40)                          # 50 -> 10
  eq [[7, 5]], st.party.field_skills(hero)
  eq true, st.party.skill_effective?(hero, 7, ally)
  eq [ally], st.party.cast_skill(hero, 7, ally)
  eq 42, ally.hp                               # 10 + 32
  eq 25, hero.mp                               # 30 - 5
end

check 'field_skills lists only known field-usable ally skills; can_cast? checks SP' do
  skills = {
    7  => fake_skill(scope: 3, sp_cost: 5, power: 10, hp: true),        # usable
    8  => fake_skill(scope: 0, sp_cost: 1, power: 10, hp: true),        # enemy scope
    9  => fake_skill(scope: 3, occ: false, sp_cost: 1, power: 10, hp: true), # not field
    10 => fake_skill(scope: 4, sp_cost: 99, power: 10, hp: true),       # too costly
  }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)               # max SP 30
  [7, 8, 9, 10].each { |s| hero.learn_skill(s) }
  eq [[7, 5], [10, 99]], st.party.field_skills(hero)  # ally-scope, field-usable
  eq true, st.party.can_cast?(hero, 7)
  eq false, st.party.can_cast?(hero, 10)       # 99 SP > 30
  eq false, st.party.can_cast?(hero, 99)       # unknown skill
end

check 'an all-ally heal skill heals the whole party (caster included) and spends SP' do
  skills = { 5 => fake_skill(scope: 4, sp_cost: 8, power: 30, hp: true) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.learn_skill(5)
  hero.change_hp(-20)                          # 100 -> 80
  ally.change_hp(-15)                          # 50 -> 35
  aff = st.party.cast_skill(hero, 5, nil)
  eq [1, 2], aff.map { |a| a.id }.sort
  eq 100, hero.hp                              # 80 + 30, clamped to max
  eq 50, ally.hp                               # 35 + 30, clamped to max
  eq 22, hero.mp                               # 30 - 8
end

check 'skill_cost supports a percentage of max SP (sp_type 1)' do
  skills = { 5 => fake_skill(scope: 2, sp_type: 1, sp_percent: 10, power: 5, sp: true) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)               # max SP 30
  hero.learn_skill(5)
  eq [[5, 3]], st.party.field_skills(hero)      # 30 * 10 / 100 = 3
end

check 'casting a heal with the target already full spends no SP' do
  skills = { 5 => fake_skill(scope: 3, sp_cost: 8, power: 30, hp: true) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)               # full HP
  hero.learn_skill(5)
  eq false, st.party.skill_effective?(hero, 5, ally)
  eq [], st.party.cast_skill(hero, 5, ally)
  eq 30, hero.mp                               # unchanged
end

# -- Field equip menu (Game::Party bag-aware equip) --------------------------

# A single-hero party (base stats maxHP10/maxSP5/atk3/def2/int1/agi4) plus the
# given item table, for the equip-menu checks.
def equip_party(items)
  db = FakeActorDB.new({ 1 => CurveRow.new('Hero', '', 0, 1, [10, 5, 3, 2, 1, 4]) },
                       [1], items)
  Game::State.new(Game::Party.new(db), 1, 0, 0)
end

check 'equip_candidates lists held items for a slot, in id order' do
  items = { 7 => fake_item(atk: 15, type: 1),   # weapon  -> slot 0
            9 => fake_item(atk: 5,  type: 1),   # weapon  -> slot 0
            8 => fake_item(dfn: 9,  type: 3),   # armour  -> slot 2
            5 => fake_item(type: 6, rhp: 10) }  # medicine (not equipment)
  st = equip_party(items)
  [7, 9, 8, 5].each { |id| st.party.gain_item(id, 1) }
  eq [[7, 1], [9, 1]], st.party.equip_candidates(0)   # weapons
  eq [[8, 1]], st.party.equip_candidates(2)           # armour
  eq [], st.party.equip_candidates(1)                 # shield: none held
end

check 'equip_from_bag equips, consumes the item and returns the old one' do
  items = { 7 => fake_item(atk: 15, type: 1), 9 => fake_item(atk: 5, type: 1) }
  st = equip_party(items)
  a = st.party.leader
  st.party.gain_item(7, 1)
  st.party.gain_item(9, 1)
  eq 3, a.atk                        # base atk
  ok st.party.equip_from_bag(a, 7)
  eq 18, a.atk                       # +15
  eq 7, a.equipment[0]
  eq 0, st.party.item_count(7)       # consumed from the bag
  # Swapping to weapon 9 returns weapon 7 to the bag.
  ok st.party.equip_from_bag(a, 9)
  eq 8, a.atk                        # base 3 + 5
  eq 9, a.equipment[0]
  eq 0, st.party.item_count(9)
  eq 1, st.party.item_count(7)       # the replaced weapon came back
end

check 'unequip_to_bag clears the slot and returns the item to the bag' do
  st = equip_party({ 8 => fake_item(dfn: 9, type: 3) })
  a = st.party.leader
  st.party.gain_item(8, 1)
  st.party.equip_from_bag(a, 8)
  eq 11, a.def                       # base 2 + 9
  eq 8, st.party.unequip_to_bag(a, 2)
  eq 2, a.def
  eq 0, a.equipment[2]
  eq 1, st.party.item_count(8)       # back in the bag
  eq 0, st.party.unequip_to_bag(a, 2) # already empty -> 0
end

check 'equip_from_bag rejects a non-equippable or unheld item' do
  items = { 5 => fake_item(type: 6, rhp: 10), 7 => fake_item(atk: 15, type: 1) }
  st = equip_party(items)
  a = st.party.leader
  st.party.gain_item(5, 1)
  eq false, st.party.equip_from_bag(a, 5)   # medicine: not equipment
  eq false, st.party.equip_from_bag(a, 7)   # not held
  eq 1, st.party.item_count(5)              # untouched
  eq 0, a.equipment[0]
end

# -- Status screen (Game::Actor EXP-to-next) ---------------------------------

check 'next_level_exp / exp_to_next track the curve across a level up' do
  db = FakeActorDB.new({ 1 => CurveRow.new('Hero', '', 0, 3, [10, 5, 3, 2, 1, 4]) },
                       [1])
  a = Game::Party.new(db).leader                 # starts at level 3
  eq a.exp_for_level(4), a.next_level_exp
  eq a.next_level_exp - a.exp, a.exp_to_next
  need = a.exp_to_next
  ok need > 0, "expected a positive EXP-to-next, got #{need}"
  a.gain_exp(need)                               # exactly reaches level 4
  eq 4, a.level
  eq a.exp_for_level(5) - a.exp, a.exp_to_next   # now measured against level 5
end

check 'next_level_exp / exp_to_next are nil at the maximum level' do
  db = FakeActorDB.new({ 1 => CurveRow.new('Hero', '', 0, 1, [10, 5, 3, 2, 1, 4]) },
                       [1])
  a = Game::Party.new(db).leader
  a.set_level(a.max_level)
  eq nil, a.next_level_exp
  eq nil, a.exp_to_next
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

check 'Conditional actor: knows skill (type 5, sub 4)' do
  st = run_actor_cond([5, 1, 4, 12]) { |s| s.party.actor_by_id(1).learn_skill(12) }
  eq true, st.switches[1]            # skill 12 known -> if-branch
  st = run_actor_cond([5, 1, 4, 12]) # skill not known -> else
  eq true, st.switches[2]
end

check 'Conditional actor: equipped item (type 5, sub 5)' do
  st = run_actor_cond([5, 1, 5, 10]) { |s| s.party.actor_by_id(1).equip([10, 0, 0, 0, 0]) }
  eq true, st.switches[1]            # item 10 equipped -> if-branch
  st = run_actor_cond([5, 1, 5, 10]) # nothing equipped -> else
  eq true, st.switches[2]
end

check 'Conditional actor: unmodelled sub-condition reads false (type 5, sub 6)' do
  eq true, run_actor_cond([5, 1, 6, 3]).switches[2] # has-state -> false -> else
end

# -- Input Number -------------------------------------------------------------

check 'Input Number pauses with a :number request, resume stores the value' do
  st = party_state
  it = Game::Interpreter.new(st)
  # RPG2000 layout is [digits, variable_id]: 3 digits into variable 7.
  it.start([FakeCmd.new(IC::INPUT_NUMBER, [3, 7]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'Input Number must pause the interpreter'
  eq :number, it.wait_kind
  eq 3, it.input_digits
  it.resume_number(123)
  it.update
  eq 123, st.variables[7], 'the entered value lands in the target variable'
  eq true, st.switches[1], 'the command after Input Number still ran'
end

check 'Input Number clamps a zero digit count to at least one cell' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::INPUT_NUMBER, [0, 4])])
  it.update
  eq 1, it.input_digits
end

check 'NumberInput edits digits and reads out the entered value' do
  m = Game::NumberInput.new(3)
  eq 3, m.digits
  eq 0, m.cursor
  m.left # already leftmost: no move
  eq 0, m.cursor
  m.inc; m.inc          # leftmost digit -> 2
  m.right; m.inc        # middle digit  -> 1
  m.right; m.right      # clamp at the rightmost cell
  eq 2, m.cursor
  m.dec                 # rightmost 0 -> 9 (wraps)
  eq 219, m.value
end

check 'NumberInput clamps its digit count to the 1..7 range' do
  eq 1, Game::NumberInput.new(0).digits
  eq 7, Game::NumberInput.new(99).digits
end

# -- Change Actor Name / Title / Sprite ---------------------------------------

check 'Change Actor Name renames the actor; a blank name is ignored' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_ACTOR_NAME, [1], string: 'Zelda')])
  it.update
  eq 'Zelda', st.party.actor_by_id(1).name
  ok !it.waiting?, 'Change Actor Name must not pause the interpreter'
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_ACTOR_NAME, [1], string: '')])
  it2.update
  eq 'Zelda', st.party.actor_by_id(1).name # unchanged by the blank name
end

check 'Change Actor Title sets the title; an empty string clears it' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_ACTOR_TITLE, [2], string: 'Sage')])
  it.update
  eq 'Sage', st.party.actor_by_id(2).title
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_ACTOR_TITLE, [2], string: '')])
  it2.update
  eq '', st.party.actor_by_id(2).title
end

check 'Change Sprite Association swaps the CharSet and flags a graphic change' do
  st = party_state
  it = Game::Interpreter.new(st)
  # actor 1, charset "Monster", cell 4, transparent = 1.
  it.start([FakeCmd.new(IC::CHANGE_ACTOR_SPRITE, [1, 4, 1], string: 'Monster')])
  it.update
  a = st.party.actor_by_id(1)
  eq 'Monster', a.charset_name
  eq 4, a.charset_index
  eq true, a.transparent
  ok !it.waiting?, 'Change Actor Graphic must not pause the interpreter'
  eq true, it.take_actor_graphic_changed, 'a one-shot graphic-change request is set'
  eq false, it.take_actor_graphic_changed, 'and it clears after the first read'
end

# -- Halt All Movement --------------------------------------------------------

check 'Halt All Movement raises a one-shot request without pausing' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::HALT_ALL_MOVEMENT, []),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 3, 3, 0])])
  it.update
  ok !it.waiting?, 'Halt All Movement must not pause the interpreter'
  eq true, st.switches[3], 'the command after Halt All Movement still ran'
  eq true, it.take_halt_movement_request, 'a one-shot halt request is set'
  eq false, it.take_halt_movement_request, 'and it clears after the first read'
end

# -- Pictures (Game::Picture + Show/Move/Erase Picture) -----------------------

check 'Game::Picture holds its shown parameters' do
  p = Game::Picture.new(3, name: 'pic', x: 160, y: 120, zoom: 100,
                        opacity: 255, fixed_to_map: true,
                        use_transparent_color: true,
                        red: 100, green: 100, blue: 100, saturation: 100)
  eq [3, 'pic', 160, 120, 100, 255], [p.id, p.name, p.x, p.y, p.zoom, p.opacity]
  ok p.fixed_to_map && p.use_transparent_color
  ok !p.moving?
end

check 'Game::Picture eases a move and lands exactly on the last frame' do
  p = Game::Picture.new(1, x: 0, y: 0, zoom: 100, opacity: 0)
  p.move_to(40, 20, 200, 255, 100, 100, 100, 100, 4) # over 4 frames
  ok p.moving?
  p.update; eq [10, 5], [p.x, p.y]
  p.update; eq [20, 10], [p.x, p.y]
  p.update; eq [30, 15], [p.x, p.y]
  p.update; eq [40, 20, 200, 255], [p.x, p.y, p.zoom, p.opacity]
  ok !p.moving?, 'settled once the move completes'
end

check 'Game::Picture with non-divisible steps still lands exactly' do
  p = Game::Picture.new(1, x: 0, y: 0)
  p.move_to(10, 0, 100, 255, 100, 100, 100, 100, 3)
  3.times { p.update }
  eq 10, p.x
  ok !p.moving?
end

check 'Game::Picture with zero duration applies immediately' do
  p = Game::Picture.new(1, x: 5, y: 5, opacity: 0)
  p.move_to(99, 88, 150, 128, 100, 100, 100, 100, 0)
  eq [99, 88, 150, 128], [p.x, p.y, p.zoom, p.opacity]
  ok !p.moving?
end

check 'Show Picture creates a picture from its parameters' do
  st = new_state
  it = Game::Interpreter.new(st)
  # id 1, pos-mode 0 (literal), x 160, y -32, fixed 0, zoom 100, trans 0,
  # use-transp 1, tone 100/100/100/100, effect 0/60.
  it.start([FakeCmd.new(IC::SHOW_PICTURE,
                        [1, 0, 160, -32, 0, 100, 0, 1, 100, 100, 100, 100, 0, 60],
                        string: 'pic01')])
  it.update
  p = st.pictures[1]
  ok p, 'picture 1 exists'
  eq ['pic01', 160, -32, 100, 255], [p.name, p.x, p.y, p.zoom, p.opacity]
  ok p.use_transparent_color, 'transparent-colour flag decoded'
  ok !p.fixed_to_map
end

check 'Show Picture transparency maps to opacity and reads position variables' do
  st = new_state
  st.variables[7] = 200
  st.variables[8] = 40
  it = Game::Interpreter.new(st)
  # pos-mode 1 -> x/y come from variables 7/8; transparency 100 -> opacity 0.
  it.start([FakeCmd.new(IC::SHOW_PICTURE,
                        [2, 1, 7, 8, 1, 100, 100, 0, 100, 100, 100, 100, 0, 0],
                        string: 'p')])
  it.update
  p = st.pictures[2]
  eq [200, 40, 0], [p.x, p.y, p.opacity], 'x/y from vars, transparency 100 -> opacity 0'
  ok p.fixed_to_map, 'fixed-to-map flag decoded'
end

check 'Move Picture eases the picture and its wait flag pauses the interpreter' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([
    FakeCmd.new(IC::SHOW_PICTURE,
               [1, 0, 0, 0, 0, 100, 0, 0, 100, 100, 100, 100, 0, 0], string: 'p'),
    # Move to (60,0) over 1 tenth (=6 frames) with the wait flag set, then a
    # switch we can watch to prove the interpreter paused.
    FakeCmd.new(IC::MOVE_PICTURE,
               [1, 0, 60, 0, 0, 100, 0, 0, 100, 100, 100, 100, 0, 0, 1, 1]),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])
  ])
  it.update # Show
  it.update # Move -> starts the move and waits
  ok it.waiting?, 'the wait flag paused the interpreter'
  ok st.pictures[1].moving?, 'the picture is interpolating'
  # Drive the picture the way the scene does, then let the interpreter resume.
  6.times { st.update_pictures }
  ok !st.pictures_moving?, 'the move finished'
  eq 60, st.pictures[1].x
  it.resume
  it.update
  eq true, st.switches[1], 'the command after the waited move ran'
end

check 'Erase Picture removes the picture' do
  st = new_state
  # Show alone first, to confirm it is present before erasing.
  its = Game::Interpreter.new(st)
  its.start([FakeCmd.new(IC::SHOW_PICTURE,
                         [5, 0, 0, 0, 0, 100, 0, 0, 100, 100, 100, 100, 0, 0],
                         string: 'p')])
  its.update
  ok st.pictures[5], 'shown'
  # Then Erase (both commands are non-blocking, so they run in one update).
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ERASE_PICTURE, [5])])
  it.update
  ok st.pictures[5].nil?, 'erased'
end

# -- Player Visibility / Return to Title --------------------------------------

check 'Set Transparent Flag toggles the player-transparent state, non-blocking' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::PLAYER_VISIBILITY, [1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq true, st.player_transparent, 'param0 != 0 hides the player'
  ok !it.waiting?, 'Set Transparent Flag must not pause the interpreter'
  eq true, st.switches[1], 'the command after it still ran'
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::PLAYER_VISIBILITY, [0])])
  it2.update
  eq false, st.player_transparent, 'param0 == 0 shows the player again'
end

check 'player_transparent round-trips through the save' do
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8),
  }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.player_transparent = true
  eq true, Game::State.load(db, st.to_h).player_transparent
  # A save written before the flag existed defaults to visible (off).
  legacy = st.to_h
  legacy.delete(:player_transparent)
  eq false, Game::State.load(db, legacy).player_transparent
end

check 'Return to Title Screen raises a :return_title request' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::RETURN_TO_TITLE, []),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'Return to Title pauses the interpreter'
  eq :return_title, it.wait_kind
  eq false, st.switches[1], 'the command after it does not run (the game is ending)'
end

# -- Change / Trade Event Location --------------------------------------------

check 'Change Event Location queues a :set request (constant and variable modes)' do
  st = party_state
  st.variables[7] = 4
  st.variables[8] = 9
  it = Game::Interpreter.new(st)
  # event 3, mode 0 (constants), to (5, 6); then event 3, mode 1 (variables 7/8),
  # then a switch to prove it did not pause.
  it.start([FakeCmd.new(IC::CHANGE_EVENT_LOCATION, [3, 0, 5, 6]),
            FakeCmd.new(IC::CHANGE_EVENT_LOCATION, [3, 1, 7, 8]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'Change Event Location must not pause the interpreter'
  eq true, st.switches[1]
  reqs = it.take_location_requests
  eq 2, reqs.size
  eq({ op: :set, target: 3, x: 5, y: 6 }, reqs[0])
  eq({ op: :set, target: 3, x: 4, y: 9 }, reqs[1], 'variable mode resolves x/y')
  eq [], it.take_location_requests, 'the queue clears after draining'
end

check 'Trade Event Locations queues a :swap request' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::TRADE_EVENT_LOCATIONS, [3, 7])])
  it.update
  ok !it.waiting?, 'Trade Event Locations must not pause the interpreter'
  eq [{ op: :swap, a: 3, b: 7 }], it.take_location_requests
end

check 'Change Map Tileset queues a one-shot tileset request, non-blocking' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_MAP_TILESET, [7]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'Change Map Tileset must not pause the interpreter'
  eq true, st.switches[1], 'the command after it still ran'
  eq 7, it.take_tileset_request, 'the requested tileset id is reported once'
  eq nil, it.take_tileset_request, 'and clears after the first read'
end

# -- Weather Effects ----------------------------------------------------------

check 'Weather Effects sets the weather type and strength, non-blocking' do
  st = party_state
  it = Game::Interpreter.new(st)
  ok st.weather.none?, 'no weather to start'
  it.start([FakeCmd.new(IC::WEATHER_EFFECTS, [1, 2]), # rain, strong
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'Weather Effects must not pause the interpreter'
  eq 1, st.weather.type
  eq 2, st.weather.strength
  ok !st.weather.none?, 'weather is now active'
  eq true, st.switches[1], 'the command after it still ran'
end

check 'Weather round-trips through the save' do
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8),
  }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.weather.set(2, 1) # snow, medium
  loaded = Game::State.load(db, st.to_h)
  eq 2, loaded.weather.type
  eq 1, loaded.weather.strength
  # A save written before weather existed defaults to none.
  legacy = st.to_h
  legacy.delete(:weather)
  ok Game::State.load(db, legacy).weather.none?
end

# -- Change Teleport / Escape Access ------------------------------------------

check 'Change Teleport / Escape Access toggle their flags, non-blocking' do
  st = party_state
  eq false, st.teleport_access, 'teleport access defaults off'
  eq false, st.escape_access, 'escape access defaults off'
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_TELEPORT_ACCESS, [1]),
            FakeCmd.new(IC::CHANGE_ESCAPE_ACCESS, [1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'the access commands must not pause the interpreter'
  eq true, st.teleport_access
  eq true, st.escape_access
  eq true, st.switches[1], 'the command after them still ran'
  # And they can be turned back off.
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::CHANGE_TELEPORT_ACCESS, [0])])
  it2.update
  eq false, st.teleport_access
end

check 'Teleport / Escape access round-trip through the save' do
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8),
  }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.teleport_access = true
  st.escape_access = true
  loaded = Game::State.load(db, st.to_h)
  eq true, loaded.teleport_access
  eq true, loaded.escape_access
  # A save written before these existed defaults them off.
  legacy = st.to_h
  legacy.delete(:teleport_access)
  legacy.delete(:escape_access)
  legacy_loaded = Game::State.load(db, legacy)
  eq false, legacy_loaded.teleport_access
  eq false, legacy_loaded.escape_access
end

# -- EXP / level (Change EXP / Change Level) ---------------------------------

# A database row carrying the EXP-curve fields, a max level and either a level-
# independent status hash or a full per-level stat curve (int16_values(31)).
class ExpRow
  attr_reader :name, :charset_name, :charset_index, :initial_level, :max_level,
              :status, :exp_basic, :exp_increase, :exp_correction
  def initialize(initial_level: 1, max_level: 10, exp_basic: 100,
                 exp_increase: 0, exp_correction: 0, status: nil, curve: nil)
    @name = 'Hero'
    @charset_name = ''
    @charset_index = 0
    @initial_level = initial_level
    @max_level = max_level
    @exp_basic = exp_basic
    @exp_increase = exp_increase
    @exp_correction = exp_correction
    @status = status || { max_hp: 100, max_mp: 20, atk: 10, def: 8, int: 6, agi: 5 }
    @curve = curve
  end

  def int16_values(idx); idx == 31 ? @curve : nil; end
end

def exp_db(**opts)
  FakeActorDB.new({ 1 => ExpRow.new(**opts) }, [1])
end

def exp_actor(**opts)
  Game::Party.new(exp_db(**opts)).actor_by_id(1)
end

def exp_state(**opts)
  Game::State.new(Game::Party.new(exp_db(**opts)), 1, 0, 0)
end

check 'EXP thresholds follow the RPG2000 curve and increase with level' do
  a = exp_actor(exp_basic: 100, exp_increase: 0, exp_correction: 0)
  eq 0, a.exp_for_level(1)
  eq 100, a.exp_for_level(2)  # correction + base per step; base 100
  eq 250, a.exp_for_level(3)  # + base*inflation (100 * 1.5)
  prev = -1
  (1..8).each do |lv|
    t = a.exp_for_level(lv)
    ok t > prev, "threshold for level #{lv} (#{t}) must exceed the previous"
    prev = t
  end
end

check 'a fresh actor starts with the EXP for its initial level' do
  eq 0, exp_actor(initial_level: 1).exp
  eq 250, exp_actor(initial_level: 3, exp_basic: 100, exp_increase: 0,
                    exp_correction: 0).exp
end

check 'gain_exp levels the actor up across thresholds and recomputes stats' do
  # Per-level curve (level-major, six stats per level): max_hp 100/120/140.
  curve = [100, 20, 10, 8, 6, 5, 120, 22, 11, 9, 7, 6, 140, 24, 12, 10, 8, 7]
  a = exp_actor(initial_level: 1, max_level: 3, curve: curve,
                exp_basic: 100, exp_increase: 0, exp_correction: 0)
  eq 1, a.level
  eq 100, a.max_hp
  a.gain_exp(100)          # reaches the level-2 threshold exactly
  eq 2, a.level
  eq 120, a.max_hp, 'base stats recomputed from the curve at the new level'
  a.gain_exp(1000)         # far past level 3; capped at max_level
  eq 3, a.level
  eq 140, a.max_hp
end

check 'gain_exp with a negative delta levels the actor down' do
  a = exp_actor(initial_level: 3, max_level: 5, exp_basic: 100,
                exp_increase: 0, exp_correction: 0)
  eq 250, a.exp
  a.gain_exp(-200)         # 50, below the level-2 threshold (100)
  eq 1, a.level
end

check 'change_level_by raises the level and bumps EXP to its threshold' do
  a = exp_actor(initial_level: 1, max_level: 5, exp_basic: 100,
                exp_increase: 0, exp_correction: 0)
  a.change_level_by(2)     # 1 -> 3
  eq 3, a.level
  eq 250, a.exp, 'EXP raised to the level-3 threshold'
  a.change_level_by(-1)    # 3 -> 2
  eq 2, a.level
  eq 100, a.exp, 'EXP clamped down to the level-2 threshold'
end

check 'change_level_by clamps at 1 and at max_level' do
  a = exp_actor(initial_level: 2, max_level: 3, exp_basic: 100)
  a.change_level_by(-5); eq 1, a.level
  a.change_level_by(99);  eq 3, a.level
end

check 'set_exp caps EXP at 999999' do
  a = exp_actor(initial_level: 1, max_level: 99, exp_basic: 100)
  a.set_exp(10_000_000)
  eq 999_999, a.exp
end

IC2 = Game::Interpreter::Cmd

check 'Change EXP command levels up a fixed actor' do
  st = exp_state(initial_level: 1, max_level: 5, exp_basic: 100,
                 exp_increase: 0, exp_correction: 0)
  it = Game::Interpreter.new(st)
  # scope 1 (fixed id), actor 1, op 0 (add), operand type 0 (const), value 100
  it.start([FakeCmd.new(IC2::CHANGE_EXP, [1, 1, 0, 0, 100, 0])])
  it.update
  eq 2, st.party.actor_by_id(1).level
  eq 100, st.party.actor_by_id(1).exp
end

check 'Change Level command raises the whole party by a delta' do
  st = exp_state(initial_level: 1, max_level: 5, exp_basic: 100,
                 exp_increase: 0, exp_correction: 0)
  it = Game::Interpreter.new(st)
  # scope 0 (party), op 0 (add), operand type 0 (const), value 2 levels
  it.start([FakeCmd.new(IC2::CHANGE_LEVEL, [0, 0, 0, 0, 2, 0])])
  it.update
  eq 3, st.party.actor_by_id(1).level
end

check 'Control Variables reads actor EXP (operand type 5, attribute 1)' do
  st = exp_state(initial_level: 3, exp_basic: 100, exp_increase: 0,
                 exp_correction: 0)
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC2::CONTROL_VARS, [0, 1, 1, 0, 5, 1, 1])]) # var1 = actor1 EXP
  it.update
  eq 250, st.variables[1]
end

check 'party save round-trips actor EXP and re-derives the level' do
  db = exp_db(initial_level: 1, max_level: 5, exp_basic: 100,
              exp_increase: 0, exp_correction: 0)
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.party.actor_by_id(1).gain_exp(250) # -> level 3
  eq 3, st.party.actor_by_id(1).level
  loaded = Game::State.load(db, st.to_h)
  la = loaded.party.actor_by_id(1)
  eq 250, la.exp, 'EXP restored from the save'
  eq 3, la.level, 'level re-derived from the restored EXP'
end

# -- Set Teleport / Escape Target, Change Encounter Rate ----------------------

check 'Set Teleport Target registers, updates and removes a destination' do
  st = party_state
  eq({}, st.teleport_targets, 'no targets registered by default')
  it = Game::Interpreter.new(st)
  # Add map 4 @ (7, 9) with switch 12 gating it, then a plain command after.
  it.start([FakeCmd.new(IC::SET_TELEPORT_TARGET, [0, 4, 7, 9, 1, 12]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'setting a target must not pause the interpreter'
  eq({ x: 7, y: 9, switch_id: 12 }, st.teleport_targets[4])
  eq true, st.switches[1], 'the command after it still ran'
  # Re-adding the same map overwrites; an absent switch flag stores nil.
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::SET_TELEPORT_TARGET, [0, 4, 2, 3, 0, 0])])
  it2.update
  eq({ x: 2, y: 3, switch_id: nil }, st.teleport_targets[4])
  # Operation 1 removes it.
  it3 = Game::Interpreter.new(st)
  it3.start([FakeCmd.new(IC::SET_TELEPORT_TARGET, [1, 4])])
  it3.update
  ok !st.teleport_targets.key?(4), 'the target was removed'
end

check 'Set Escape Target stores the single escape destination' do
  st = party_state
  eq nil, st.escape_target, 'no escape target by default'
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SET_ESCAPE_TARGET, [8, 3, 5, 1, 20])])
  it.update
  eq({ map_id: 8, x: 3, y: 5, switch_id: 20 }, st.escape_target)
  # A second command replaces it; no switch flag stores nil.
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::SET_ESCAPE_TARGET, [2, 1, 1, 0, 0])])
  it2.update
  eq({ map_id: 2, x: 1, y: 1, switch_id: nil }, st.escape_target)
end

check 'Change Encounter Rate stores the step rate, non-blocking' do
  st = party_state
  eq nil, st.encounter_rate, 'encounter rate unset by default'
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_ENCOUNTER_RATE, [25]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'changing the rate must not pause the interpreter'
  eq 25, st.encounter_rate
  eq true, st.switches[1], 'the command after it still ran'
end

check 'Change System BGM / SFX stash per-slot audio overrides' do
  st = party_state
  it = Game::Interpreter.new(st)
  # System BGM slot 0 (battle): [fadein, volume, tempo, balance].
  it.start([FakeCmd.new(IC::CHANGE_SYSTEM_BGM, [0, 2, 80, 110, 50],
                        string: 'Battle1'),
            FakeCmd.new(IC::CHANGE_SYSTEM_SFX, [1, 90, 100, 50],
                        string: 'Decision2')])
  it.update
  eq({ name: 'Battle1', fadein: 2, volume: 80, tempo: 110, balance: 50 },
     st.system_bgm[0])
  eq({ name: 'Decision2', volume: 90, tempo: 100, balance: 50 },
     st.system_sfx[1])
end

check 'Targets / rate / system audio round-trip through the save' do
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8),
  }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.encounter_rate = 30
  st.teleport_targets[4] = { x: 7, y: 9, switch_id: 12 }
  st.escape_target = { map_id: 8, x: 3, y: 5, switch_id: nil }
  st.system_bgm[0] = { name: 'Battle1', fadein: 0, volume: 100,
                       tempo: 100, balance: 50 }
  st.system_sfx[1] = { name: 'Decision2', volume: 100, tempo: 100,
                       balance: 50 }
  loaded = Game::State.load(db, st.to_h)
  eq 30, loaded.encounter_rate
  eq({ x: 7, y: 9, switch_id: 12 }, loaded.teleport_targets[4])
  eq({ map_id: 8, x: 3, y: 5, switch_id: nil }, loaded.escape_target)
  eq 'Battle1', loaded.system_bgm[0][:name]
  eq 'Decision2', loaded.system_sfx[1][:name]
  # A save written before these existed restores empty / unset registries.
  legacy = st.to_h
  [:encounter_rate, :teleport_targets, :escape_target,
   :system_bgm, :system_sfx].each { |k| legacy.delete(k) }
  legacy_loaded = Game::State.load(db, legacy)
  eq nil, legacy_loaded.encounter_rate
  eq({}, legacy_loaded.teleport_targets)
  eq nil, legacy_loaded.escape_target
  eq({}, legacy_loaded.system_bgm)
  eq({}, legacy_loaded.system_sfx)
end

# -- Key Input Processing -----------------------------------------------------

check 'Key Input Proc (1.50 layout) waits, clears the var, resolves by priority' do
  st = party_state
  st.variables[1] = 99 # a stale value the waiting proc must clear
  it = Game::Interpreter.new(st)
  # var 1, wait, (legacy dir slot 0), decision, cancel, shift, down, left,
  # right, up — every key accepted.
  it.start([FakeCmd.new(IC::KEY_INPUT_PROC, [1, 1, 0, 1, 1, 1, 1, 1, 1, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 3, 3, 0])])
  it.update
  ok it.waiting?, 'a waiting proc suspends the interpreter'
  eq :key_input, it.wait_kind
  eq 0, st.variables[1], 'the target variable is cleared while waiting'
  eq true, it.key_input_request[:wait]
  # Highest-valued matching key wins: Shift(7) > Cancel(6) > Decision(5) >
  # Up(4) > Right(3) > Left(2) > Down(1); nothing pressed yields 0.
  eq 7, it.key_input_result([:down, :decision, :shift])
  eq 6, it.key_input_result([:cancel, :decision, :down])
  eq 5, it.key_input_result([:decision, :down])
  eq 1, it.key_input_result([:down])
  eq 0, it.key_input_result([])
  # A key press resumes, stores the code, and the next command runs.
  it.resume_key_input(it.key_input_result([:decision, :down]))
  ok !it.waiting?, 'the proc resumed'
  it.update
  eq 5, st.variables[1]
  eq true, st.switches[3], 'the command after the proc ran'
end

check 'Key Input Proc pre-1.50 layout enables the whole D-pad, no Shift' do
  st = party_state
  it = Game::Interpreter.new(st)
  # Five params (<6): var 2, no-wait, all-directions flag on, decision on,
  # cancel off.
  it.start([FakeCmd.new(IC::KEY_INPUT_PROC, [2, 0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'even a no-wait proc routes through the scene once'
  req = it.key_input_request
  eq false, req[:wait], 'no-wait requests read held state, not edges'
  acc = req[:accepted]
  [:down, :left, :right, :up, :decision].each { |k| eq true, acc[k], "#{k} on" }
  eq false, acc[:cancel], 'cancel not accepted'
  eq false, acc[:shift], 'pre-1.50 has no Shift'
  eq 4, it.key_input_result([:up])
  eq 0, it.key_input_result([:cancel]), 'an unaccepted key yields 0'
  # No-wait mode does not pre-clear the variable; the resume writes the read.
  it.resume_key_input(it.key_input_result([]))
  eq 0, st.variables[2]
end

check 'Key Input Proc accepts only the chosen keys' do
  st = party_state
  it = Game::Interpreter.new(st)
  # Accept Decision only (all direction / shift / cancel flags off).
  it.start([FakeCmd.new(IC::KEY_INPUT_PROC, [1, 1, 0, 1, 0, 0, 0, 0, 0, 0])])
  it.update
  eq 5, it.key_input_result([:decision])
  eq 0, it.key_input_result([:cancel, :up, :down]), 'unlisted keys ignored'
end

# -- Show Inn (Stay at Inn) ---------------------------------------------------

check 'Show Inn: staying charges the price and full-heals the party' do
  st = party_state
  st.party.gain_gold(1000)
  st.party.actors.each { |a| a.hp = 1; a.mp = 0 }
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_INN, [0, 100, 0])])
  it.update
  ok it.waiting?, 'Show Inn suspends the interpreter'
  eq :inn, it.wait_kind
  req = it.inn_request
  eq true, req[:prompt], 'a priced inn prompts'
  eq true, req[:can_afford]
  eq 100, req[:price]
  it.resume_inn(true)
  ok !it.waiting?, 'the inn resolved'
  eq 900, st.party.gold, 'the price was deducted'
  st.party.actors.each do |a|
    eq a.max_hp, a.hp, "#{a.name} HP restored"
    eq a.max_mp, a.mp, "#{a.name} MP restored"
  end
end

check 'Show Inn: cancelling leaves gold and HP untouched' do
  st = party_state
  st.party.gain_gold(1000)
  st.party.actors.each { |a| a.hp = 1; a.mp = 0 }
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_INN, [0, 100, 0])])
  it.update
  it.resume_inn(false)
  eq 1000, st.party.gold, 'no gold spent on cancel'
  eq 1, st.party.actors.first.hp, 'no healing on cancel'
end

check 'Show Inn: a free stay (price 0) skips the prompt' do
  st = party_state
  st.party.actors.each { |a| a.hp = 1 }
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_INN, [0, 0, 0])])
  it.update
  eq false, it.inn_request[:prompt], 'a free inn needs no prompt'
  it.resume_inn(true)
  eq st.party.actors.first.max_hp, st.party.actors.first.hp, 'still heals'
end

check 'Show Inn: the affordability flag reflects the party gold' do
  st = party_state
  st.party.gain_gold(50)
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_INN, [0, 100, 0])])
  it.update
  eq false, it.inn_request[:can_afford], 'cannot afford a 100g inn with 50g'
end

check 'Show Inn: Stay / No Stay handler branches route on the outcome' do
  # Layout mirrors a Show Choices block: the command is followed by the two
  # marked branches, closed by INN_END, then a command that always runs.
  list = [
    FakeCmd.new(IC::SHOW_INN, [0, 100, 0], indent: 0),
    FakeCmd.new(IC::INN_STAY, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    FakeCmd.new(IC::INN_NO_STAY, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    FakeCmd.new(IC::INN_END, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 3, 3, 0], indent: 0)
  ]
  st = party_state
  st.party.gain_gold(1000)
  it = Game::Interpreter.new(st)
  it.start(list)
  it.update
  it.resume_inn(true)
  it.update
  eq true, st.switches[1], 'the Stay branch ran'
  ok !st.switches[2], 'the No Stay branch was skipped'
  eq true, st.switches[3], 'execution continued past the inn'
  # And the No Stay path on a fresh run.
  st2 = party_state
  it2 = Game::Interpreter.new(st2)
  it2.start(list)
  it2.update
  it2.resume_inn(false)
  it2.update
  ok !st2.switches[1], 'the Stay branch was skipped'
  eq true, st2.switches[2], 'the No Stay branch ran'
  eq true, st2.switches[3], 'execution continued past the inn'
end

# -- Open Shop ----------------------------------------------------------------

# A shop over a party with `gold` gold and the given goods (id => price). Item
# names are irrelevant to the logic, so they are left blank.
def shop_setup(gold, goods, allow_buy: true, allow_sell: true)
  items = {}
  goods.each { |id, price| items[id] = fake_item(name: "i#{id}", price: price) }
  db = FakeActorDB.new(
    { 1 => FakePlayerRow.new('Hero', '', 0, 5, max_hp: 100, max_mp: 30,
                             atk: 10, def: 8) }, [1], items)
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.party.gain_gold(gold)
  shop = Game::Shop.new(db, st.party, goods.keys, allow_buy, allow_sell)
  [st, shop]
end

check 'Shop buy deducts gold, adds the item, and records a transaction' do
  st, shop = shop_setup(500, { 3 => 100 })
  ok shop.buy(3), 'the purchase succeeds'
  eq 400, st.party.gold, 'price deducted'
  eq 1, st.party.item_count(3), 'item added'
  ok shop.did_transaction
end

check 'Shop buy refuses when unaffordable, unstocked, capped, or sell-only' do
  st, shop = shop_setup(50, { 3 => 100 })
  ok !shop.buy(3), 'cannot afford 100 with 50'
  eq 50, st.party.gold
  ok !shop.buy(7), 'item 7 is not stocked'
  ok !shop.did_transaction, 'no failed purchase counts as a transaction'
  # capped at 99
  st2, shop2 = shop_setup(999_999, { 3 => 1 })
  st2.party.gain_item(3, 99)
  ok !shop2.buy(3), 'cannot exceed 99 of an item'
  # sell-only shop refuses buys
  _st3, shop3 = shop_setup(500, { 3 => 100 }, allow_buy: false, allow_sell: true)
  ok !shop3.buy(3)
end

check 'Shop sell adds half price, removes the item, records a transaction' do
  st, shop = shop_setup(0, { 3 => 100 })
  st.party.gain_item(3, 2)
  ok shop.sell(3), 'the sale succeeds'
  eq 50, st.party.gold, 'half of 100'
  eq 1, st.party.item_count(3), 'one removed'
  ok shop.did_transaction
end

check 'Shop sell refuses unowned, price-0 (key), or in a buy-only shop' do
  st, shop = shop_setup(0, { 3 => 100 })
  ok !shop.sell(3), 'nothing owned to sell'
  # a price-0 item is unsellable even when held
  st2, shop2 = shop_setup(0, { 4 => 0 })
  st2.party.gain_item(4, 1)
  ok !shop2.sell(4), 'key / price-0 items cannot be sold'
  # buy-only shop refuses sells
  st3, shop3 = shop_setup(0, { 3 => 100 }, allow_buy: true, allow_sell: false)
  st3.party.gain_item(3, 1)
  ok !shop3.sell(3)
end

check 'Shop sellable_items lists only held, priced goods in id order' do
  st, shop = shop_setup(0, { 3 => 100, 5 => 40, 8 => 0 })
  st.party.gain_item(8, 1) # price 0 -> not sellable
  st.party.gain_item(5, 2)
  st.party.gain_item(3, 1)
  eq [3, 5], shop.sellable_items
end

check 'Open Shop parses the mode and goods and suspends on :shop' do
  st = party_state
  it = Game::Interpreter.new(st)
  # mode 1 (buy only), type 0, param2 handlers flag, param3 unused, goods 3/5/7.
  it.start([FakeCmd.new(IC::OPEN_SHOP, [1, 0, 0, 0, 3, 5, 7])])
  it.update
  ok it.waiting?, 'Open Shop suspends the interpreter'
  eq :shop, it.wait_kind
  req = it.shop_request
  eq true, req[:allow_buy]
  eq false, req[:allow_sell], 'mode 1 is buy-only'
  eq [3, 5, 7], req[:goods]
end

check 'Open Shop routes Transaction / No Transaction handler branches' do
  list = [
    FakeCmd.new(IC::OPEN_SHOP, [0, 0, 0, 0, 3], indent: 0),
    FakeCmd.new(IC::SHOP_TRANSACTION, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    FakeCmd.new(IC::SHOP_NO_TRANSACTION, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    FakeCmd.new(IC::SHOP_END, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 3, 3, 0], indent: 0)
  ]
  st = party_state
  it = Game::Interpreter.new(st)
  it.start(list)
  it.update
  it.resume_shop(true) # bought something
  it.update
  eq true, st.switches[1], 'the Transaction branch ran'
  ok !st.switches[2], 'the No Transaction branch was skipped'
  eq true, st.switches[3], 'execution continued past the shop'
  # And the no-transaction path on a fresh run.
  st2 = party_state
  it2 = Game::Interpreter.new(st2)
  it2.start(list)
  it2.update
  it2.resume_shop(false)
  it2.update
  ok !st2.switches[1]
  eq true, st2.switches[2], 'the No Transaction branch ran'
  eq true, st2.switches[3]
end

# -- Enemy Encounter (troop model + command) ----------------------------------

EnemyRow = Struct.new(:name, :max_hp, :max_sp, :attack, :defense, :spirit,
                      :agility, :exp, :gold)
GroupMember = Struct.new(:enemy_id, :x, :y, :invisible)
GroupRow = Struct.new(:name, :members)
BattleDB = Struct.new(:enemy, :enemy_group)

# A database with two enemies and one troop of three (two Slimes + a hidden Bat).
def battle_db
  enemies = {
    2 => EnemyRow.new('Slime', 30, 0, 8, 4, 3, 5, 5, 10),
    3 => EnemyRow.new('Bat',   12, 0, 6, 2, 2, 9, 3, 4)
  }
  groups = {
    1 => GroupRow.new('Slimes', { 1 => GroupMember.new(2, 10, 20, false),
                                  2 => GroupMember.new(2, 40, 20, false),
                                  3 => GroupMember.new(3, 70, 20, true) })
  }
  BattleDB.new(enemies, groups)
end

check 'Game::Troop instantiates its members and totals EXP / gold' do
  troop = Game::Troop.new(battle_db, 1)
  eq 'Slimes', troop.name
  eq [2, 2, 3], troop.members.map(&:id)
  eq 13, troop.total_exp, '5 + 5 + 3'
  eq 24, troop.total_gold, '10 + 10 + 4'
  first = troop.members.first
  eq 30, first.max_hp
  eq 30, first.hp, 'starts at full HP'
  eq [10, 20], [first.x, first.y]
  ok !first.hidden
  ok troop.members.last.hidden, 'the Bat is invisible'
end

check 'Game::Enemy reads its combat stats from the database' do
  e = Game::Enemy.new(battle_db, 3)
  eq 'Bat', e.name
  eq 12, e.max_hp
  eq 9, e.agi
  eq 3, e.exp
  ok !e.dead?
  e.hp = 0
  ok e.dead?
end

check 'a missing troop / enemy degrades to an empty, harmless model' do
  troop = Game::Troop.new(battle_db, 99)
  eq [], troop.members
  eq 0, troop.total_exp
  eq 1, Game::Enemy.new(battle_db, 99).max_hp, 'defaults for a missing enemy'
end

check 'Enemy Encounter parses the troop and modes and suspends on :battle' do
  st = party_state
  it = Game::Interpreter.new(st)
  # const troop 4, setup 0, escape mode 2 (custom), defeat mode 1 (custom),
  # first-strike on.
  it.start([FakeCmd.new(IC::ENEMY_ENCOUNTER, [0, 4, 0, 2, 1, 1])])
  it.update
  ok it.waiting?
  eq :battle, it.wait_kind
  req = it.battle_request
  eq 4, req[:troop_id]
  eq true, req[:allow_escape]
  eq true, req[:first_strike]
  eq false, req[:defeat_game_over], 'defeat mode 1 uses a handler'
end

check 'Enemy Encounter reads a variable troop id and escape-disallow' do
  st = party_state
  st.variables[7] = 12
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ENEMY_ENCOUNTER, [1, 7, 0, 0, 0, 0])])
  it.update
  eq 12, it.battle_request[:troop_id]
  eq false, it.battle_request[:allow_escape], 'escape mode 0 disallows escape'
  eq true, it.battle_request[:defeat_game_over], 'defeat mode 0 is game over'
end

check 'Enemy Encounter routes Victory / Escape / Defeat handler branches' do
  list = [
    FakeCmd.new(IC::ENEMY_ENCOUNTER, [0, 1, 0, 2, 1, 0], indent: 0),
    FakeCmd.new(IC::VICTORY_HANDLER, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    FakeCmd.new(IC::ESCAPE_HANDLER, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    FakeCmd.new(IC::DEFEAT_HANDLER, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 3, 3, 0], indent: 1),
    FakeCmd.new(IC::END_BATTLE, [], indent: 0),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 4, 4, 0], indent: 0)
  ]
  { victory: 1, escape: 2, defeat: 3 }.each do |result, branch_switch|
    st = party_state
    it = Game::Interpreter.new(st)
    it.start(list)
    it.update
    it.resume_battle(result)
    it.update
    [1, 2, 3].each do |s|
      eq(s == branch_switch, st.switches[s] || false, "#{result} -> switch #{s}")
    end
    eq true, st.switches[4], 'execution continues past the encounter'
  end
end

check 'Enemy Encounter escape-abort mode ends the event' do
  list = [
    FakeCmd.new(IC::ENEMY_ENCOUNTER, [0, 1, 0, 1, 0, 0], indent: 0), # escape=abort
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  st = party_state
  it = Game::Interpreter.new(st)
  it.start(list)
  it.update
  it.resume_battle(:escape)
  it.update
  ok !st.switches[5], 'the rest of the event is abandoned on an aborting escape'
end

# -- Battle (headless auto-battle) --------------------------------------------

def combatant(name, atk, dfn, agi, hp)
  Game::Battle::Combatant.new(name, atk, dfn, agi, hp, hp)
end

check 'Battle.attack_damage is half attack less a quarter defence, min 1' do
  eq 18, Game::Battle.attack_damage(40, 8),  '20 - 2'
  eq 1,  Game::Battle.attack_damage(2, 40),  'floored at 1'
  eq 1,  Game::Battle.attack_damage(0, 0)
end

check 'Battle: a stronger party wins, a weaker one is defeated' do
  hero = combatant('Hero', 40, 20, 20, 200)
  slime = combatant('Slime', 8, 4, 5, 30)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  eq :victory, b.run
  ok slime.dead?, 'the enemy was defeated'
  ok !hero.dead?
  ok hero.hp < 200, 'the hero took some damage on the way'

  weak = combatant('Weak', 6, 2, 3, 10)
  boss = combatant('Boss', 60, 30, 40, 500)
  b2 = Game::Battle.new([weak], [boss], Game::Rng.new(1))
  eq :defeat, b2.run
  ok weak.dead?
  ok !boss.dead?
end

check 'Battle: the fastest battler strikes first' do
  # A fast glass cannon one-shots a slow foe before it ever acts.
  fast = combatant('Fast', 100, 0, 99, 20)
  slow = combatant('Slow', 100, 0, 1, 40) # 50 damage kills it in one hit
  b = Game::Battle.new([fast], [slow], Game::Rng.new(1))
  eq :victory, b.run
  eq 20, fast.hp, 'the slow enemy never landed a hit'
end

check 'Battle#step performs one action at a time and logs it' do
  hero = combatant('Hero', 40, 20, 20, 200)
  slime = combatant('Slime', 8, 4, 5, 30)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  ok !b.finished?
  first = b.step
  ok first, 'a step returns its log entry'
  eq 1, b.log.length
  # Hero (agility 20) acts before the Slime (5): 40/2 - 4/4 = 19 damage.
  eq 'Hero', first[:attacker]
  eq 'Slime', first[:target]
  eq 19, first[:damage]
  eq 11, first[:target_hp]
  ok !first[:defeated]
  b.step until b.finished?
  ok slime.dead?
  ok b.log.last[:defeated], 'the final logged hit downed the enemy'
  eq nil, b.step, 'stepping a decided battle yields nothing'
end

check 'Battle#run records a combat log of every hit' do
  b = Game::Battle.new([combatant('Hero', 40, 20, 20, 200)],
                       [combatant('Slime', 8, 4, 5, 30)], Game::Rng.new(1))
  eq :victory, b.run
  ok b.log.length >= 2, 'the Slime took at least two hits'
  ok b.log.all? { |e| e[:damage] >= 1 }, 'every hit did at least 1 damage'
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k logic check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k logic check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
