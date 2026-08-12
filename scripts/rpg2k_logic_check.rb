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
      def bgm_fade(*a); (@log ||= []) << [:bgm_fade, *a]; end
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

  # A jump only tests where it lands, never the tiles it crosses.
  def can_land?(_character, x, y); !@blocked.include?([x, y]); end

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

# A 2x2 Game::Map over literal tile arrays, for the Tile Substitution checks.
FakeMapUnit = Struct.new(:width, :height, :chipset_id, :lower_layer, :upper_layer)
def fake_map_2x2(lower, upper)
  Game::Map.new(1, FakeMapUnit.new(2, 2, 1, lower, upper))
end

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

# -- Begin Jump / End Jump ----------------------------------------------------

check 'a jump block hops to its accumulated destination in one step' do
  # Two rights and a down inside the block: one hop to (2, 1), not three steps.
  route = R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::MOVE_RIGHT),
                 mc(R::MOVE_DOWN), mc(R::END_JUMP), mc(R::MOVE_DOWN)],
                repeat: false)
  c = Game::Character.new(0, 0)
  w = FakeWorld.new
  eq :moved, route.step(c, w)
  eq [2, 1], [c.x, c.y], 'landed on the summed offset'
  eq :moved, route.step(c, w) # the command after End Jump runs next
  eq [2, 2], [c.x, c.y]
end

check 'a character records that its last move was a jump' do
  # The renderer lifts a jumping sprite along an arc, and needs to be told which
  # kind of move it is watching. Distance cannot say so: a jump can land one
  # tile away, or on the tile it left.
  c = Game::Character.new(0, 0)
  w = FakeWorld.new
  eq false, c.jumped, 'a fresh character has not jumped'

  c.move(6)
  eq false, c.jumped, 'an ordinary step is not a jump'

  R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::END_JUMP)],
        repeat: false).step(c, w)
  eq true, c.jumped, 'a one-tile hop is still a jump'

  c.move(6)
  eq false, c.jumped, 'and the next step clears it'

  c.move_diagonal(6, 2)
  eq false, c.jumped, 'a diagonal step is not a jump either'
end

check 'a jump that lands where it started still counts as a jump' do
  # RPG_RT hops in place, so the flag rather than the displacement is what the
  # renderer has to go on.
  c = Game::Character.new(3, 3, 8)
  R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::MOVE_LEFT), mc(R::END_JUMP)],
        repeat: false).step(c, FakeWorld.new)
  eq [3, 3], [c.x, c.y], 'back where it started'
  eq true, c.jumped
  eq 8, c.direction, 'and a jump going nowhere leaves the facing alone'
end

check 'placing a character outright is not a jump' do
  # Change Event Location snaps a character to a tile. Without clearing the
  # flag, an event that had jumped would arc again the next time one moved it.
  c = Game::Character.new(0, 0)
  R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::END_JUMP)],
        repeat: false).step(c, FakeWorld.new)
  eq true, c.jumped
  c.x = 5
  eq false, c.jumped
  R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_DOWN), mc(R::END_JUMP)],
        repeat: false).step(c, FakeWorld.new)
  eq true, c.jumped
  c.y = 9
  eq false, c.jumped
end

check 'a jump faces its dominant axis, not its last move' do
  # Two right, two down: a tie on distance, which RPG_RT settles vertically.
  route = R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::MOVE_RIGHT),
                 mc(R::MOVE_DOWN), mc(R::MOVE_DOWN), mc(R::END_JUMP)])
  c = Game::Character.new(0, 0, 8)
  route.step(c, FakeWorld.new)
  eq [2, 2], [c.x, c.y]
  eq 2, c.direction, 'a tie faces vertically'

  # Three right, one down: horizontal now dominates.
  route2 = R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::MOVE_RIGHT),
                  mc(R::MOVE_RIGHT), mc(R::MOVE_DOWN), mc(R::END_JUMP)])
  c2 = Game::Character.new(0, 0, 8)
  route2.step(c2, FakeWorld.new)
  eq 6, c2.direction
end

check 'faces inside a jump steer the next move without moving anything' do
  # Face left, then Move Forward: one tile left, even though the character
  # started facing down.
  route = R.new([mc(R::BEGIN_JUMP), mc(R::FACE_LEFT), mc(R::MOVE_FORWARD),
                 mc(R::END_JUMP)])
  c = Game::Character.new(5, 5, 2)
  eq :moved, route.step(c, FakeWorld.new)
  eq [4, 5], [c.x, c.y]
end

check 'a jump only tests where it lands, not what it clears' do
  # (1, 0) is a wall; the jump passes straight over it onto (2, 0).
  route = R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::MOVE_RIGHT),
                 mc(R::END_JUMP)])
  c = Game::Character.new(0, 0)
  eq :moved, route.step(c, FakeWorld.new(blocked: [[1, 0]]))
  eq [2, 0], [c.x, c.y], 'cleared the tile in between'
end

check 'a jump onto a blocked tile is retried, or skipped when skippable' do
  cmds = [mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::END_JUMP),
          mc(R::MOVE_DOWN)]
  w = FakeWorld.new(blocked: [[1, 0]])

  route = R.new(cmds, repeat: false, skippable: false)
  c = Game::Character.new(0, 0)
  eq :blocked, route.step(c, w)
  eq [0, 0], [c.x, c.y]
  eq 0, route.index, 'stays on the Begin Jump so the hop is retried'

  skip = R.new(cmds, repeat: false, skippable: true)
  c2 = Game::Character.new(0, 0)
  eq :blocked, skip.step(c2, w)
  eq [0, 0], [c2.x, c2.y]
  eq :moved, skip.step(c2, w), 'stepped past the whole block'
  eq [0, 1], [c2.x, c2.y]
end

check 'a jump toward the hero hops the way the hero lies' do
  # Nepheshel's roaming monsters: every one of its 625 jump blocks encloses a
  # runtime-directed move like this one rather than a literal direction.
  route = R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_TOWARD_HERO), mc(R::END_JUMP)])
  c = Game::Character.new(0, 0)
  eq :moved, route.step(c, FakeWorld.new(hero: [5, 0]))
  eq [1, 0], [c.x, c.y]

  away = R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_AWAY_HERO), mc(R::END_JUMP)])
  c2 = Game::Character.new(5, 5)
  eq :moved, away.step(c2, FakeWorld.new(hero: [9, 5]))
  eq [4, 5], [c2.x, c2.y]
end

check 'a Begin Jump with no End Jump abandons the rest of the route' do
  route = R.new([mc(R::BEGIN_JUMP), mc(R::MOVE_RIGHT), mc(R::MOVE_DOWN)],
                repeat: false)
  c = Game::Character.new(0, 0)
  route.step(c, FakeWorld.new)
  eq [0, 0], [c.x, c.y], 'nothing moved'
  ok route.done?, 'and the route unwound rather than stepping the moves'
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

check 'TextReveal halts at a pause until it is released' do
  # "ab" then a \! pause (at 2) then "cd".
  pauses = [{ at: 2, kind: :key }]
  r = Game::TextReveal.new(['abcd'], 0, pauses)
  r.advance(10)                       # cannot cross the pause
  eq 2, r.revealed, 'the reveal stops at the pause point'
  ok !r.done?
  ok r.pending_pause, 'the pause is pending once reached'
  eq :key, r.pending_pause[:kind]
  r.reveal_all                        # even a fast-forward respects it
  eq 2, r.revealed
  r.release_pause
  ok r.pending_pause.nil?, 'released -> no longer pending'
  r.advance(10)
  eq 4, r.revealed
  ok r.done?
end

check 'TextReveal reveal_all runs to the end when no pause blocks it' do
  r = Game::TextReveal.new(['abcd'], 0, [{ at: 2, kind: :quarter }])
  r.advance(2)
  r.release_pause                     # let the timed pause through
  r.reveal_all
  ok r.done?, 'with the only pause released, reveal_all finishes'
end

check 'Message.scan records pacing codes in revealed-char coordinates' do
  vars = Object.new
  def vars.[](i); { 3 => 42 }[i]; end
  names = ->(_i) { 'X' }
  s = Game::Message.scan('ab\.cd\|e\!f\^', vars, names)
  eq 6, s[:length], '"abcdef" = 6 visible characters'
  eq [{ at: 2, kind: :quarter }, { at: 4, kind: :full }, { at: 5, kind: :key }],
     s[:pauses]
  ok s[:auto_close], '\\^ sets auto_close'
  # Pause offsets count the expanded length of \v / \n, not the code text.
  s2 = Game::Message.scan('\v[3]\!x', vars, names)
  eq [{ at: 2, kind: :key }], s2[:pauses], '42 is two chars, so \\! sits at 2'
end

check 'Message.scan flags \$ (show gold) and drops it from the text' do
  vars = Object.new
  def vars.[](_i); 0; end
  names = ->(_i) { '' }
  s = Game::Message.scan('Gold:\$ here', vars, names)
  ok s[:show_gold], '\\$ sets show_gold'
  eq 'Gold: here'.length, s[:length], '\\$ emits no visible character'
  # No \$ -> flag stays off.
  ok !Game::Message.scan('plain', vars, names)[:show_gold]
end

check 'Message.scan records \> \< instant spans (and an unclosed one to EOL)' do
  vars = Object.new
  def vars.[](_i); 0; end
  names = ->(_i) { '' }
  s = Game::Message.scan('ab\>cd\<ef', vars, names)
  eq 6, s[:length], '"abcdef" = 6 visible characters'
  eq [[2, 4]], s[:instants], 'cd is the instant span'
  # An unclosed \> runs to the end of the line.
  s2 = Game::Message.scan('ab\>cd', vars, names)
  eq [[2, 4]], s2[:instants]
end

check 'TextReveal reveals an instant span in a single advance' do
  # "ab" normal, "cd" instant (\> \<), "ef" normal -> instant span [2, 4).
  r = Game::TextReveal.new(['abcdef'], 0, [], false, [[2, 4]])
  r.advance(1)
  eq 1, r.revealed, 'the first normal char reveals one at a time'
  r.advance(1)                          # lands at 2 -> inside the span -> jump to 4
  eq 4, r.revealed, 'the instant span appears at once'
  r.advance(1)
  eq 5, r.revealed, 'normal characters resume after the span'
end

check 'an instant span still stops at a pause inside it' do
  # instant [1, 5) but a \! pause sits at 3: the span cannot leap past the pause.
  r = Game::TextReveal.new(['abcdef'], 0, [{ at: 3, kind: :key }], false, [[1, 5]])
  r.advance(1)                          # 0 -> 1 (span start); capped at the pause 3
  eq 3, r.revealed, 'the instant leap is capped at the pause'
  ok r.pending_pause, 'the pause gates the span'
  r.release_pause
  r.advance(1)                          # 3 -> 4, still inside the span -> jump to 5
  eq 5, r.revealed, 'the rest of the span reveals once released'
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

# -- Show Choices -------------------------------------------------------------

# A Show Choices block: `cancel` is the command's cancel type, `options` the
# option indices to emit (the editor writes 0..3 for the drawn choices and 4 for
# the optional [Cancel] branch). Each branch sets switch `10 + index`, and the
# command after the block sets switch 1, so a run says which branch was taken
# and whether control came back.
def choice_block(cancel, options)
  cmds = [FakeCmd.new(IC::SHOW_CHOICES, [cancel], indent: 0)]
  options.each do |i|
    cmds << FakeCmd.new(IC::CHOICE_OPTION, [i], indent: 0,
                                                string: i == 4 ? '' : "opt#{i}")
    cmds << FakeCmd.new(IC::CONTROL_SWITCHES, [0, 10 + i, 10 + i, 0], indent: 1)
  end
  cmds << FakeCmd.new(IC::CHOICE_END, [], indent: 0)
  cmds << FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 0)
  cmds
end

def run_choice(cancel, options)
  st = new_state
  it = Game::Interpreter.new(st)
  it.start(choice_block(cancel, options))
  it.update
  [st, it]
end

check 'Show Choices lists its options and routes the chosen branch' do
  st, it = run_choice(0, [0, 1, 2])
  ok it.waiting?, 'Show Choices must pause the interpreter'
  eq :choice, it.wait_kind
  eq %w[opt0 opt1 opt2], it.choice_labels
  it.choose(1)
  it.update
  eq true, st.switches[11], 'the second branch ran'
  eq true, st.switches[1], 'and control returned after the block'
end

check 'Show Choices hides the [Cancel] branch from the drawn options' do
  # Cancel type 5 stores the cancel branch as a fifth option (index 4) with an
  # empty label. It is a jump target only — drawing it would add a blank row and
  # shift every label after it.
  _st, it = run_choice(5, [0, 1, 4])
  eq %w[opt0 opt1], it.choice_labels
end

check 'Show Choices cancel type picks the option it names' do
  # 0 = cancelling forbidden: the key is swallowed and the choice stays up.
  st, it = run_choice(0, [0, 1])
  eq false, it.choice_cancellable?
  eq false, it.cancel_choice
  ok it.waiting?, 'a non-cancellable choice stays on screen'
  eq false, st.switches[1]

  # 1..4 = cancel picks that choice (1-based), the editor's usual "no thanks".
  st, it = run_choice(2, [0, 1])
  ok it.choice_cancellable?
  ok it.cancel_choice
  it.update
  eq true, st.switches[11], 'cancel picked the second choice'
  eq true, st.switches[1]

  # 5 = cancel runs the dedicated [Cancel] branch, stored at option index 4.
  st, it = run_choice(5, [0, 1, 4])
  ok it.cancel_choice
  it.update
  eq true, st.switches[14], 'cancel ran the [Cancel] branch'
  eq false, st.switches[10]
  eq false, st.switches[11]
  eq true, st.switches[1]
end

check 'cancelling is only offered while a choice is on screen' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_MESSAGE, [], string: 'hello')])
  it.update
  eq false, it.choice_cancellable?, 'a plain message is not a choice'
  eq false, it.cancel_choice
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

# A resolver that counts every Call Event lookup instead of answering with
# real commands, so a Call Event round trip stays a one-command no-op (the
# empty-target early return in do_call_event) whose count is still visible.
class CountingResolver
  attr_reader :calls
  def initialize
    @calls = 0
  end

  def common_event_commands(_id)
    @calls += 1
    []
  end

  def map_event_commands(_id, _page); nil; end
end

check 'a single update spends its 10000-step budget at the documented per-command cost' do
  # RPG_RT's own timing measurements give most commands one step, but a Loop's
  # End Loop marker and a Call Event round trip cost two -- see the event
  # command spec. These two checks pin that MAX_STEPS (10000) is spent at
  # those weights, not a flat one step per command.
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([
    FakeCmd.new(IC::LOOP, [], indent: 0),
    FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 1, 0, 1], indent: 0), # variable 1 += 1
    FakeCmd.new(IC::END_LOOP, [], indent: 0),
  ])
  it.update
  eq 3333, st.variables[1],
     '10000 steps / (1 for the add + 2 for the loop-back) per iteration'

  st2 = new_state
  it2 = Game::Interpreter.new(st2)
  it2.resolver = CountingResolver.new
  it2.start(Array.new(6000) { FakeCmd.new(IC::CALL_EVENT, [0, 1, 0]) })
  it2.update
  eq 5000, it2.resolver.calls, '10000 steps / 2 per Call Event round trip'
end

check 'a Conditional Branch costs one step when matched, two when not' do
  # Per the event command spec, a Conditional Branch evaluation is one step
  # when it matches (falling through into the true body) and two when it does
  # not. A block here is a bare [Conditional Branch, End Branch] pair (no
  # body), which also exercises the asymmetry in how each path reaches End
  # Branch: a match falls through to it as an ordinary next command (so it is
  # separately dispatched and pays its own two-step cost, for 1+2=3 per
  # block); a miss jumps straight past it via #skip_to/#consume inside the
  # same do_conditional call, so it is never independently dispatched (just
  # the 2-step miss, for 2 per block) -- cheaper overall despite costing more
  # to evaluate.
  st = new_state
  st.switches[1] = true
  matched = Game::Interpreter.new(st)
  matched.start(Array.new(4000) {
    [FakeCmd.new(IC::CONDITIONAL, [0, 1, 0], indent: 0), # switch 1 == on
     FakeCmd.new(IC::END_BRANCH, [], indent: 0)]
  }.flatten)
  matched.update
  eq 3333, matched.instance_variable_get(:@index) / 2,
     '10000 steps / (1 to match + 2 for the End Branch it falls through to) per block'

  st2 = new_state
  st2.switches[1] = false
  unmatched = Game::Interpreter.new(st2)
  unmatched.start(Array.new(6000) {
    [FakeCmd.new(IC::CONDITIONAL, [0, 1, 0], indent: 0), # switch 1 == on (it is not)
     FakeCmd.new(IC::END_BRANCH, [], indent: 0)]
  }.flatten)
  unmatched.update
  eq 5000, unmatched.instance_variable_get(:@index) / 2,
     '10000 steps / 2 per miss, with no separate End Branch dispatch to pay for'
end

check 'Call Event with no resolver set is a safe no-op' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CALL_EVENT, [0, 5, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq true, st.switches[1]
end

check 'Call Event runs another page of "this event" (map target 10005 / 0)' do
  page2 = [FakeCmd.new(IC::CONTROL_SWITCHES, [0, 9, 9, 0])]
  [10005, 0].each do |ref|
    st = new_state
    it = Game::Interpreter.new(st)
    it.resolver = FakeResolver.new(maps: { 7 => { 2 => page2 } })
    it.start([FakeCmd.new(IC::CALL_EVENT, [1, ref, 2]),
              FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
    it.event_id = 7 # the list belongs to map event 7
    it.update
    eq true, st.switches[9], "page 2 of this event ran (ref #{ref})"
    eq true, st.switches[1], 'control returned to the caller'
  end
end

check 'Call Event on "this event" from a common event is a no-op' do
  st = new_state
  page2 = [FakeCmd.new(IC::CONTROL_SWITCHES, [0, 9, 9, 0])]
  it = Game::Interpreter.new(st)
  it.resolver = FakeResolver.new(maps: { 7 => { 2 => page2 } })
  it.start([FakeCmd.new(IC::CALL_EVENT, [1, 10005, 2]),  # no event is running it
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq false, st.switches[9], 'there is no "this event" to call'
  eq true, st.switches[1], 'and the caller carries on'
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
  st.screen.erase(Game::Transition::FADE_OUT, 32)
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
  # Setting 2 is Random Blocks Down, one of the styles a black mask cannot
  # express, so it runs as a fade of the same length.
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ERASE_SCREEN, [2])])
  it.update
  eq Game::Transition::RANDOM_BLOCKS_DOWN, st.screen.fade_transition
  ok st.screen.transition.uniform?, 'an unported style falls back to the fade'
  eq 41, st.screen.transition.frames, 'but keeps its own length'
  before = st.screen.fade_level
  st.screen.update
  ok st.screen.fade_level > before, 'the level eases toward black'
  ok st.screen.fade_level < 255, 'over time, not instantly'
end

# -- screen transitions (Game::Transition) ------------------------------------

TR = Game::Transition

check 'Erase / Show Screen map their parameter onto the RPG2000 style table' do
  # The two directions read the same setting index differently.
  eq TR::FADE_OUT,    TR.erase_style(0, 0)
  eq TR::FADE_IN,     TR.show_style(0, 0)
  eq TR::BLIND_CLOSE, TR.erase_style(4, 0)
  eq TR::BLIND_OPEN,  TR.show_style(4, 0)
  eq TR::CUT_OUT,     TR.erase_style(19, 0)
  eq TR::CUT_IN,      TR.show_style(19, 0)
  # Setting 20 and anything past the table are "no transition".
  eq TR::NONE, TR.erase_style(20, 0)
  eq TR::NONE, TR.erase_style(99, 0)
  # -1 means "use the configured transition", which is itself a setting index.
  eq TR::BLIND_CLOSE, TR.erase_style(-1, 4)
  eq TR::BLIND_OPEN,  TR.show_style(-1, 4)
  eq TR::NONE, TR.erase_style(-1, nil), 'an unconfigured slot has no style'
end

check 'each transition style runs for its own length' do
  eq 35, TR.default_frames(TR::FADE_OUT)
  eq 35, TR.default_frames(TR::FADE_IN)
  eq 1,  TR.default_frames(TR::CUT_OUT)
  eq 0,  TR.default_frames(TR::NONE)
  eq 41, TR.default_frames(TR::BLIND_CLOSE), 'the shaped ones all take 41'
end

check 'Erase Screen resolves -1 against the configured transition' do
  st = new_state
  st.set_screen_transition(0, 4) # teleport erase -> blinds
  st.set_screen_transition(1, 4) # teleport show  -> blinds
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ERASE_SCREEN, [-1])])
  it.update
  eq TR::BLIND_CLOSE, st.screen.fade_transition
  ok !st.screen.transition.uniform?, 'the blinds are painted, not faded'
  st.screen.update until !st.screen.fading?

  it.resume
  it.start([FakeCmd.new(IC::SHOW_SCREEN, [-1])])
  it.update
  eq TR::BLIND_OPEN, st.screen.fade_transition
end

check 'a cut transition takes a single frame, not a fade' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ERASE_SCREEN, [19]),   # cut out
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq TR::CUT_OUT, st.screen.fade_transition
  eq 1, st.screen.transition.frames, 'a cut is one frame long, not 35'
  # RPG_RT shows the live screen for that frame and lands black after it.
  eq [[0, 0, 320, 240]], st.screen.transition.visible_rects
  st.screen.update
  ok !st.screen.fading?, 'and it is over after that one frame'
  eq 255, st.screen.fade_level
  it.resume
  it.update
  eq true, st.switches[1]
end

check '"no transition" neither animates nor changes the screen' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ERASE_SCREEN, [20]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq TR::NONE, st.screen.fade_transition
  eq 0, st.screen.fade_level, 'the screen is left exactly as it was'
  ok !st.screen.erased?
  eq true, st.switches[1], 'and nothing waited'
end

check 'a fade ramps the overlay opacity, an erase up and a show down' do
  out = TR.new(TR::FADE_OUT, 35, 320, 240, true)
  eq 255 * 1 / 33, out.black_alpha, 'the ramp runs over total - 2 frames'
  32.times { out.advance }
  eq 255, out.black_alpha, 'and lands fully black before the last frame'

  into = TR.new(TR::FADE_IN, 35, 320, 240, false)
  eq 255 - 255 / 33, into.black_alpha, 'a show is the same ramp inverted'
  32.times { into.advance }
  eq 0, into.black_alpha
end

check 'blinds close band by band and open the other way' do
  # 8-pixel bands, one more pixel shut every five frames.
  close = TR.new(TR::BLIND_CLOSE, 41, 320, 240, true)
  rects = close.visible_rects
  eq 30, rects.size, '240 / 8 bands still showing'
  eq [0, 1, 320, 7], rects[0], 'one pixel of the first band has closed'
  eq [0, 9, 320, 7], rects[1], 'and of the second'
  4.times { close.advance }
  eq [0, 1, 320, 7], close.visible_rects[0], 'still one pixel four frames in'
  close.advance
  eq [0, 2, 320, 6], close.visible_rects[0], 'a pixel more every five frames'

  open = TR.new(TR::BLIND_OPEN, 41, 320, 240, false)
  eq [0, 7, 320, 1], open.visible_rects[0], 'opening reveals from the bottom up'
end

check 'stripe transitions march in from both edges' do
  # Vertical stripes: 3-pixel rows on a 6-pixel pitch. A show reveals the rows
  # the arriving screen has taken; an erase keeps the ones it has not.
  into = TR.new(TR::VERTICAL_STRIPES_IN, 41, 320, 240, false)
  eq [[0, 0, 320, 3], [0, 237, 320, 3]], into.visible_rects
  into.advance
  eq 4, into.visible_rects.size, 'one row from each edge per frame'

  out = TR.new(TR::VERTICAL_STRIPES_OUT, 41, 320, 240, true)
  # 39 rows from each edge, less the bottom one RPG_RT places at y = h — off the
  # screen on the first frame, and clipped away here rather than drawn.
  eq 77, out.visible_rects.size, 'an erase starts with nearly every row live'
  eq [0, 3, 320, 3], out.visible_rects[0]

  # Horizontal stripes are the same march in 4-pixel columns on an 8-pixel pitch.
  cols = TR.new(TR::HORIZONTAL_STRIPES_IN, 41, 320, 240, false)
  eq [[0, 0, 4, 240], [316, 0, 4, 240]], cols.visible_rects
end

check 'the window transitions shrink, grow, and invert for the other direction' do
  # Border to centre, erasing: the live scene is the shrinking centred window.
  out = TR.new(TR::BORDER_TO_CENTER_OUT, 41, 320, 240, true)
  eq [[0, 0, 320, 240]], out.visible_rects, 'the full screen on frame 0'
  20.times { out.advance }
  eq [[80, 60, 160, 120]], out.visible_rects, 'half way in, a half-size window'

  # Showing, the arriving screen is *outside* that window, so the live regions
  # are the four bands around it.
  into = TR.new(TR::BORDER_TO_CENTER_IN, 41, 320, 240, false)
  20.times { into.advance }
  eq [[0, 0, 320, 60], [0, 180, 320, 60], [0, 60, 80, 120], [240, 60, 80, 120]],
     into.visible_rects

  # Centre to border grows a window out of the middle.
  grow = TR.new(TR::CENTER_TO_BORDER_IN, 41, 320, 240, false)
  20.times { grow.advance }
  eq [[80, 60, 160, 120]], grow.visible_rects
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

check 'Timer Operation start carries the show-timer flag; text is M:SS' do
  st = new_state
  it = Game::Interpreter.new(st)
  # Set 90 s (constant operand), then start with the show-timer flag on.
  it.start([
    FakeCmd.new(IC::TIMER_OPERATION, [0, 0, 90]),        # set = 90 s
    FakeCmd.new(IC::TIMER_OPERATION, [1, 0, 0, 1, 0]),   # start, visible
  ])
  it.update
  # RPG_RT seeds seconds*60 + 59 so the display holds 1:30 for a whole second
  # instead of dropping to 1:29 after one frame.
  eq 90 * 60 + 59, st.timer_frames
  eq true, st.timer_running
  eq true, st.timer_visible, 'the show-timer flag turns the display on'
  eq '1:30', st.timer_display_text, '90 s reads as 1:30'
  # Stopping clears the display too, which is how a countdown that runs out
  # disappears rather than sitting at 0:00 (EasyRPG's Game_Party::StopTimer).
  it.start([FakeCmd.new(IC::TIMER_OPERATION, [2])])
  it.update
  eq false, st.timer_running
  eq false, st.timer_visible, 'stopping hides the timer'
  # A start with the flag clear leaves it hidden.
  it.start([FakeCmd.new(IC::TIMER_OPERATION, [1, 0, 0, 0, 0])])
  it.update
  eq true, st.timer_running
  eq false, st.timer_visible, 'starting without the flag hides the timer'
  # Padding: seconds below ten keep a leading zero, minutes are uncapped.
  st.timer_frames = 5 * 60
  eq '0:05', st.timer_display_text
  st.timer_frames = 605 * 60 # 10 min 5 s
  eq '10:05', st.timer_display_text
end

check 'a countdown reaches zero on the displayed second, then stops and hides' do
  t = Game::Timer.new
  t.set(1)
  t.start(true)
  eq 119, t.frames, '1 s is 60 frames of countdown plus the 59-frame lead-in'
  eq 1, t.seconds
  59.times { ok !t.tick, 'still reads 0:01' }
  eq 1, t.seconds, 'the full second is held, not lost on the first frame'
  # RPG_RT ends the countdown the moment the *displayed* seconds hit zero, so
  # the 59 frames that would still read 0:00 never run.
  ok t.tick, 'the sixtieth tick empties it and reports the finish'
  eq 0, t.seconds
  eq false, t.running
  eq false, t.visible, 'and it leaves the screen'
  ok !t.tick, 'a stopped timer does not keep reporting'
end

check 'a timer only counts in battle when it carries the battle flag' do
  t = Game::Timer.new
  t.set(10)
  t.start(true, false)
  frames = t.frames
  t.tick(true)
  eq frames, t.frames, 'no battle flag: paused for the fight'
  ok !t.drawn?(true), 'and hidden while it lasts'
  ok t.drawn?(false), 'but shown again on the map'

  t.in_battle = true
  t.tick(true)
  eq frames - 1, t.frames, 'with the flag it keeps counting'
  ok t.drawn?(true), 'and keeps drawing'
end

check "Timer Operation addresses RPG2003's second timer through param5" do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([
    FakeCmd.new(IC::TIMER_OPERATION, [0, 0, 30]),           # timer 1 = 30 s
    FakeCmd.new(IC::TIMER_OPERATION, [0, 0, 90, 0, 0, 1]),  # timer 2 = 90 s
    FakeCmd.new(IC::TIMER_OPERATION, [1, 0, 0, 1, 1, 1]),   # start timer 2
  ])
  it.update
  eq 30, st.timer(0).seconds
  eq 90, st.timer(1).seconds
  eq false, st.timer(0).running, 'the first timer was set but never started'
  eq true, st.timer(1).running
  eq true, st.timer(1).visible
  eq true, st.timer(1).in_battle, 'param4 is the run-in-battle flag'
  # RPG2000 data carries no sixth parameter, so it reads 0 and addresses the
  # only timer that edition has.
  eq 30, st.timer_seconds, 'the shorthand still means timer 1'
end

check 'Control Variables and Conditional Branch read the second timer' do
  st = new_state
  st.timer(0).set(10)
  st.timer(1).set(50)
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 7, 1]),   # timer 1 secs
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 7, 9])])  # timer 2 secs
  it.update
  eq 10, st.variables[1]
  eq 50, st.variables[2]

  # Conditional type 10 is the second timer, laid out like type 2.
  branch = lambda do |params|
    [FakeCmd.new(IC::CONDITIONAL, params, indent: 0),
     FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 0, 1], indent: 1),
     FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
     FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 0, 2], indent: 1),
     FakeCmd.new(IC::END_BRANCH, [], indent: 0)]
  end
  it.start(branch.call([10, 40, 0])) # timer 2 at least 40 s
  it.update
  eq 1, st.variables[3]
  it.start(branch.call([10, 40, 1])) # timer 2 at most 40 s
  it.update
  eq 2, st.variables[3]
  it.start(branch.call([2, 40, 0]))  # timer 1 at least 40 s -> no
  it.update
  eq 2, st.variables[3], 'type 2 still reads the first timer'
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

check 'Teleport converts its RPG2003 facing argument to a numpad direction' do
  # param3 is 1-based over the editor's up / right / down / left; the runtime
  # (and Game::State#direction) speak the 2/4/6/8 numpad. Passing it through
  # raw made 1 and 3 into numbers that are not directions at all.
  { 1 => 8, 2 => 6, 3 => 2, 4 => 4 }.each do |param, numpad|
    st = new_state
    it = Game::Interpreter.new(st)
    it.start([FakeCmd.new(IC::TELEPORT, [5, 3, 9, param])])
    it.update
    eq [5, 3, 9, numpad], it.teleport, "facing argument #{param}"
  end
end

check 'Teleport with no facing argument keeps the current one' do
  # 0 is what an RPG2000 project writes — the edition that has no such argument.
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::TELEPORT, [5, 3, 9, 0])])
  it.update
  eq [5, 3, 9, 0], it.teleport, 'nothing to face, so the scene leaves it alone'

  # An out-of-range value means the same rather than an invalid direction.
  st2 = new_state
  it2 = Game::Interpreter.new(st2)
  it2.start([FakeCmd.new(IC::TELEPORT, [5, 3, 9, 9])])
  it2.update
  eq [5, 3, 9, 0], it2.teleport
end

# -- Store Terrain ID / Store Event ID ---------------------------------------

# A map_info hook: terrain id is x*10+y, and an event id 7 sits at (2, 3) facing
# right (6), for the Store Terrain / Event ID and Control Variables commands.
class FakeMapInfo
  def terrain_id(x, y); x * 10 + y; end
  def event_id_at(x, y); (x == 2 && y == 3) ? 7 : 0; end
  def event_position(id); id == 7 ? { x: 2, y: 3, direction: 6 } : nil; end
  # The hero sits mid-screen; event 7 is up and to the left of it. Anything else
  # is not on this map.
  def character_screen_position(ref)
    return { x: 160, y: 120 } if ref == 10001
    ref == 7 ? { x: 40, y: 72 } : nil
  end
end

# The same map without the camera hook, for the headless case.
class FakeMapInfoNoCamera
  def event_position(id); id == 7 ? { x: 2, y: 3, direction: 6 } : nil; end
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
                           :initial_level, :status, :strong_defence,
                           # The actor's own critical-hit rate: whether it crits
                           # at all, and the 1-in-N denominator it crits at.
                           # Appended after strong_defence so the positional
                           # constructions above keep working; a row that names
                           # neither never crits, which is what a bare fixture
                           # wants.
                           :has_critical_rate, :critical_rate,
                           # 二刀流 -- turns the shield slot into a second
                           # weapon slot (Actor#double_hand?). Appended last for
                           # the same reason: every existing positional
                           # construction keeps working with it defaulting nil.
                           :double_hand,
                           # 装備固定 -- Actor#equipment_fixed?. Same reasoning.
                           :equipment_fixed)
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
# The occasion fields are named the way the real item row names them:
# `occasion_field1` (37) bars battle use, `occasion_field2` (57) is a switch
# item's field flag and `occasion_battle` (58) its battle flag. This fixture used
# to offer a single `occasion_field`, a name no genuine row carries — which is
# exactly how the runtime's gate came to read a field that was never there.
FakeItem = Struct.new(:atk_points1, :def_points1, :spi_points1, :agi_points1,
                      :max_hp_points, :max_sp_points, :type, :name, :scope,
                      :recover_hp, :recover_hp_rate, :recover_sp, :recover_sp_rate,
                      :price, :skill_id,
                      :atk_points2, :def_points2, :spi_points2, :agi_points2,
                      :occasion_battle, :state_set, :reverse_state_effect,
                      :prevent_critical, :attribute_set, :switch_id,
                      :occasion_field2, :occasion_field1,
                      :dual_attack, :ignore_evasion, :half_sp_cost, :hit,
                      # 会心必殺: the weapon's own critical-hit percentage.
                      :critical_hit,
                      # 蘇生専用: does nothing at all to a target still standing.
                      :ko_only,
                      # 両手持ち: a weapon that claims the shield hand too.
                      :two_handed)
def fake_item(atk: 0, dfn: 0, spi: 0, agi: 0, mhp: 0, msp: 0, type: 0, name: '',
              scope: 0, rhp: 0, rhp_rate: 0, rsp: 0, rsp_rate: 0, price: 0,
              skill_id: 0, atk2: 0, dfn2: 0, spi2: 0, agi2: 0, occ_battle: true,
              state_set: nil, reverse_state: false, prevent_crit: false,
              attribute_set: nil, switch_id: 0, occ_field: true,
              field_only: false, dual_attack: false, ignore_evasion: false,
              half_sp_cost: false, hit: 0, critical_hit: 0, ko_only: false,
              two_handed: 0)
  FakeItem.new(atk, dfn, spi, agi, mhp, msp, type, name, scope,
               rhp, rhp_rate, rsp, rsp_rate, price, skill_id,
               atk2, dfn2, spi2, agi2, occ_battle, state_set, reverse_state,
               prevent_crit, attribute_set, switch_id, occ_field, field_only,
               dual_attack, ignore_evasion, half_sp_cost, hit, critical_hit,
               ko_only, two_handed)
end
# A database skill row exposing the fields Game::Party's field-skill logic reads.
FakeSkill = Struct.new(:name, :type, :scope, :occasion_field, :sp_type, :sp_cost,
                       :sp_percent, :power, :physical_rate, :magical_rate,
                       :affect_hp, :affect_sp, :occasion_battle,
                       :state_effects, :reverse_state_effect, :hit, :variance,
                       :attribute_effects, :switch_id,
                       # 防御無視: the effect lands undiminished.
                       :ignore_defense)
def fake_skill(name: '', type: 0, scope: 3, occ: true, sp_type: 0, sp_cost: 0,
               sp_percent: 0, power: 0, prate: 0, mrate: 0, hp: false, sp: false,
               occ_battle: true, state_effects: nil, reverse_state: false, hit: 100,
               variance: 4, attribute_effects: nil, switch_id: 1,
               ignore_defense: false)
  FakeSkill.new(name, type, scope, occ, sp_type, sp_cost, sp_percent, power,
                prate, mrate, hp, sp, occ_battle, state_effects, reverse_state, hit,
                variance, attribute_effects, switch_id, ignore_defense)
end
# A state-definition lookup for the battle: id -> a row the sim reads for its
# per-turn slip damage (hp/sp change), action restriction and auto-recovery.
FakeStateDef = Struct.new(:restriction, :hp_change_val, :hp_change_max,
                          :sp_change_val, :sp_change_max,
                          :hold_turn, :auto_release_prob,
                          # A blow can shake a state off (release_by_attack), a
                          # state can spoil its victim's aim (reduce_hit_ratio,
                          # 100 = unhindered) and it can seal skills above a
                          # physical / magical threshold.
                          :release_by_attack, :reduce_hit_ratio,
                          :restrict_skill, :restrict_skill_level,
                          :restrict_magic, :restrict_magic_level,
                          # ... and what *showing* the state needs: its display
                          # name, its message-palette colour, the priority that
                          # decides which state a battler shows, and RPG2000's
                          # own sentences for it landing and lifting. Appended
                          # after the simulation fields so the positional
                          # constructions above keep working.
                          :name, :color, :priority,
                          :message_actor, :message_enemy, :message_recovery,
                          # ... and the map-step slip pair: how many walked tiles
                          # between drains and how much each drain takes, for HP
                          # and SP. Appended last, for the same reason.
                          :hp_change_map_steps, :hp_change_map_val,
                          :sp_change_map_steps, :sp_change_map_val)
# A state row carrying only the fields a check names, with the rest at the
# database defaults — notably reduce_hit_ratio 100, which is "does not blind".
def fake_state(restriction: 0, hp_val: 0, hp_max: 0, sp_val: 0, sp_max: 0,
               hold_turn: 0, auto_release: 0, release_by_attack: 0,
               reduce_hit_ratio: 100, restrict_skill: false, restrict_skill_level: 0,
               restrict_magic: false, restrict_magic_level: 0,
               name: '', color: Game::States::DEFAULT_COLOR, priority: 50,
               actor_msg: nil, enemy_msg: nil, recovery_msg: nil,
               hp_map_steps: 0, hp_map_val: 0, sp_map_steps: 0, sp_map_val: 0)
  FakeStateDef.new(restriction, hp_val, hp_max, sp_val, sp_max, hold_turn,
                   auto_release, release_by_attack, reduce_hit_ratio,
                   restrict_skill, restrict_skill_level,
                   restrict_magic, restrict_magic_level,
                   name, color, priority, actor_msg, enemy_msg, recovery_msg,
                   hp_map_steps, hp_map_val, sp_map_steps, sp_map_val)
end
# An RPG2003 class row (職業, database chunk 30): its own growth curve, learn
# table, EXP curve and battle-command list, exposed the way a real LCF row is.
class JobRow
  attr_reader :name, :skills, :battle_commands,
              :exp_basic, :exp_increase, :exp_correction
  def initialize(name, curve, learns = [], battle_commands = nil,
                 exp_basic: 30, exp_increase: 30, exp_correction: 0)
    @name = name
    @curve = curve
    @skills = FakeLearnTable.new(learns)
    @battle_commands = battle_commands
    @exp_basic = exp_basic
    @exp_increase = exp_increase
    @exp_correction = exp_correction
  end

  def int16_values(idx); idx == 31 ? @curve : nil; end
end

# An actor row that starts out in a class (RPG2003 field 57) and carries its own
# battle-command list (field 80).
class ClassedRow < SkillRow
  attr_reader :class_id, :battle_commands
  def initialize(name, cs, ci, level, curve, learns, class_id, battle_commands = nil)
    super(name, cs, ci, level, curve, learns)
    @class_id = class_id
    @battle_commands = battle_commands
  end
end

class FakeActorDB
  attr_reader :player, :system, :item, :skill, :job
  def initialize(players, party_ids, items = {}, skills = {}, jobs = {})
    @player = players
    @system = FakeActorSystem.new(party_ids)
    @item = items
    @skill = skills
    @job = jobs
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

check 'both timers round-trip through the save; an old save still loads' do
  db = FakeActorDB.new({ 1 => FakePlayerRow.new('Hero', '', 0, 1, max_hp: 10) }, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.timer(0).set(30); st.timer(0).start(true, true)
  st.timer(1).set(90); st.timer(1).start(false, false)
  loaded = Game::State.load(db, st.to_h)
  eq 30, loaded.timer(0).seconds
  eq true, loaded.timer(0).in_battle
  eq 90, loaded.timer(1).seconds
  eq false, loaded.timer(1).visible

  # A save from before the second timer existed carries only the flat fields.
  legacy = st.to_h
  legacy.delete(:timers)
  old = Game::State.load(db, legacy)
  eq 30, old.timer(0).seconds, 'the first timer comes back from the old keys'
  eq 0, old.timer(1).seconds, 'and the second starts empty'
end

# -- the permanent actor roster (Game::Actors) --------------------------------
#
# Nepheshel drives its whole party mechanic through Change Party Member: it adds
# and removes actors 2/3/4 and 5/6/7 thousands of times (630 adds + 471 removes
# for actor 2 alone). Rebuilding the actor from the database on every add threw
# away everything the player had earned, which is what these pin down.
def roster_db
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5, max_hp: 100, max_mp: 30, atk: 10, def: 8),
    2 => FakePlayerRow.new('Ally', '', 0, 3, max_hp: 50, max_mp: 20, atk: 6, def: 5),
  }
  FakeActorDB.new(players, [1])
end

check 'an actor who leaves and rejoins the party keeps their state' do
  db = roster_db
  party = Game::Party.new(db)
  party.add_actor(2)
  ally = party.actor_by_id(2)
  eq 3, ally.level, 'joins at the database initial level'
  ally.set_level(9)
  ally.name = 'Renamed'
  ally.hp = 7
  levelled_hp = ally.max_hp

  party.remove_actor(2)
  eq nil, party.actor_by_id(2), 'out of the party'
  ok party.roster.existing(2), 'but still in the roster'

  party.add_actor(2)
  back = party.actor_by_id(2)
  ok back.equal?(ally), 'the very same actor object rejoins'
  eq 9, back.level, 'keeps the level they left with'
  eq 'Renamed', back.name, 'keeps a renamed name'
  eq 7, back.hp, 'keeps current HP'
  eq levelled_hp, back.max_hp
end

check 'Actors builds each id once and reports a missing row as nil' do
  roster = Game::Actors.new(roster_db)
  a = roster[1]
  ok a.equal?(roster[1]), 'the same instance comes back'
  eq nil, roster.existing(2), 'existing() does not create'
  ok roster[2], 'and [] does'
  eq [1, 2], roster.all.map { |x| x.id }, 'all() is in id order'
  eq nil, roster[0], 'a non-positive id has no actor'
  eq nil, roster[99], 'nor does a row the database lacks'
end

check 'the save carries actors who are out of the party' do
  db = roster_db
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.party.add_actor(2)
  away = st.party.actor_by_id(2)
  away.change_level_by(6)           # 3 -> 9, the Change Level command's path
  away.name = 'Renamed'
  st.party.remove_actor(2)          # leaves the party *before* the save

  loaded = Game::State.load(db, st.to_h)
  eq [1], loaded.party.actors.map { |a| a.id }, 'the party is just the leader'
  restored = loaded.party.roster.existing(2)
  ok restored, 'the absent member is still in the restored roster'
  eq 9, restored.level
  eq 'Renamed', restored.name
  loaded.party.add_actor(2)
  eq 9, loaded.party.actor_by_id(2).level, 'and rejoins at that level'
end

check 'a stat command naming a fixed actor reaches one who is out of the party' do
  db = roster_db
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  ic = Game::Interpreter::Cmd
  interp = Game::Interpreter.new(st)

  # Bring the ally in, then send them away again.
  st.party.add_actor(2)
  away = st.party.actor_by_id(2)
  st.party.remove_actor(2)
  eq nil, st.party.actor_by_id(2), 'actor 2 is not in the party'

  # Scope 1 = "this actor", by fixed id: RPG_RT resolves it through the roster,
  # so it lands on the absent ally rather than being dropped. Params are
  # [scope, actor id, 0 add, 0 constant, amount, show-message].
  eq 3, away.level, 'the ally starts at their database level'
  interp.start([FakeCmd.new(ic::CHANGE_LEVEL, [1, 2, 0, 0, 7, 0])])
  interp.update while interp.running? && !interp.waiting?
  eq 10, away.level, 'Change Level reached the absent actor'

  interp.start([FakeCmd.new(ic::CHANGE_ACTOR_NAME, [2], string: 'Away')])
  interp.update while interp.running? && !interp.waiting?
  eq 'Away', away.name, 'Change Actor Name reached the absent actor'

  # Scope 0 = "the whole party" still means only the members present.
  leader_before = st.party.leader.level
  interp.start([FakeCmd.new(ic::CHANGE_LEVEL, [0, 0, 0, 0, 9, 0])])
  interp.update while interp.running? && !interp.waiting?
  eq 10, away.level, 'a party-wide change leaves the absent actor alone'
  eq leader_before + 9, st.party.leader.level, 'and does apply to the members present'
end

check 'reading an actor sees one who is out of the party; "in party" does not' do
  db = roster_db
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  ic = Game::Interpreter::Cmd
  interp = Game::Interpreter.new(st)

  st.party.add_actor(2)
  away = st.party.actor_by_id(2)
  away.change_level_by(4)          # 3 -> 7
  st.party.remove_actor(2)

  # Control Variables operand 5: [.., .., .., .., 5 operand, actor id, attribute]
  # attribute 0 = level. The absent ally reports their real level, not 0.
  interp.start([FakeCmd.new(ic::CONTROL_VARS, [0, 1, 1, 0, 5, 2, 0])])
  interp.update while interp.running? && !interp.waiting?
  eq 7, st.variables[1], "an absent actor's level reads through"

  # Conditional type 5: [5 type, actor id, sub-condition, value].
  # Sub-condition 2 is "level >=" — asked of the actor, so it is true.
  eq true, interp.send(:actor_condition, FakeCmd.new(ic::CONDITIONAL, [5, 2, 2, 7])),
     'a level test sees the absent actor'
  eq false, interp.send(:actor_condition, FakeCmd.new(ic::CONDITIONAL, [5, 2, 2, 8])),
     'and compares properly'
  # Sub-condition 0 is "is in the party" — that one really is about the party.
  eq false, interp.send(:actor_condition, FakeCmd.new(ic::CONDITIONAL, [5, 2, 0, 0])),
     '"in party" stays false while they are away'
  st.party.add_actor(2)
  eq true, interp.send(:actor_condition, FakeCmd.new(ic::CONDITIONAL, [5, 2, 0, 0])),
     'and true once they rejoin'
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

  # The save / battle tallies round-trip, and default to 0 in a legacy save.
  st.save_count = 4
  st.battle_count = 7
  st.win_count = 5
  st.defeat_count = 1
  st.escape_count = 1
  counted = Game::State.load(db, st.to_h)
  eq 4, counted.save_count, 'save count round-trips'
  eq 7, counted.battle_count, 'battle count round-trips'
  eq 5, counted.win_count
  eq 1, counted.defeat_count
  eq 1, counted.escape_count
  legacy2 = st.to_h
  legacy2.delete(:battle_count)
  eq 0, Game::State.load(db, legacy2).battle_count, 'absent battle count defaults 0'
end

check 'Vehicle: unplaced by default, placed once positioned' do
  v = Game::Vehicle.new(:boat)
  eq :boat, v.type
  eq false, v.placed?                          # map_id 0 -> never positioned
  v.map_id = 4; v.x = 8; v.y = 6; v.direction = 1
  eq true, v.placed?
  h = v.to_h
  w = Game::Vehicle.new(:boat)
  w.load_h(h)
  eq [4, 8, 6, 1], [w.map_id, w.x, w.y, w.direction]
end

check 'State save round-trips vehicle locations (boat / ship / airship)' do
  players = { 1 => FakePlayerRow.new('Hero', '', 0, 5, max_hp: 100, max_mp: 30) }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.vehicle(:boat).map_id = 4; st.vehicle(:boat).x = 8; st.vehicle(:boat).y = 6
  st.vehicle(:airship).map_id = 2; st.vehicle(:airship).x = 3
  st.vehicle(:airship).y = 5; st.vehicle(:airship).direction = 3
  loaded = Game::State.load(db, st.to_h)
  eq [4, 8, 6], [loaded.vehicle(:boat).map_id, loaded.vehicle(:boat).x,
                 loaded.vehicle(:boat).y]
  eq true, loaded.vehicle(:airship).placed?
  eq 3, loaded.vehicle(:airship).direction
  eq false, loaded.vehicle(:ship).placed?      # never positioned -> stays unplaced
  # A save written before vehicles existed simply restores them unplaced.
  legacy = st.to_h
  legacy.delete(:vehicles)
  eq false, Game::State.load(db, legacy).vehicle(:boat).placed?
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
  hero.change_hp(-1000, false);  eq 1, hero.hp  # death disallowed -> floor 1 (alive)
  eq false, hero.dead?
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

# -- RPG2003 class (Change Class 1008 / Change Battle Commands 1009) ----------

# A party of one whose actor row and class rows are all set up for the class
# checks: the actor is a level-3 "Fighter" curve, class 1 is twice as strong and
# class 2 half as strong, and each class teaches its own skill.
def class_db(class_id = 0, actor_learns = [[10, 1]])
  actor_curve = [] # levels 1..3, six stats each
  3.times { |i| actor_curve.concat([100 + i * 10, 20, 10 + i, 8, 6, 4]) }
  job1 = [] # class 1: double the actor's HP curve, distinct battle stats
  3.times { |i| job1.concat([200 + i * 10, 40, 20 + i, 16, 12, 8]) }
  job2 = []
  3.times { |i| job2.concat([50 + i * 10, 10, 5 + i, 4, 3, 2]) }
  players = {
    1 => ClassedRow.new('Hero', '', 0, 3, actor_curve, actor_learns, class_id,
                        [1, 2, 0, -1, -1, -1, -1]),
  }
  jobs = {
    1 => JobRow.new('Warrior', job1, [[21, 1], [22, 3]], [3, 0, -1, -1, -1, -1, -1]),
    2 => JobRow.new('Mage', job2, [[31, 1]]),
  }
  FakeActorDB.new(players, [1], {}, {}, jobs)
end

def class_state(class_id = 0, actor_learns = [[10, 1]])
  Game::State.new(Game::Party.new(class_db(class_id, actor_learns)), 1, 0, 0)
end

check 'an actor with a startup class reads its curve, learn table and EXP from it' do
  a = class_state(1).party.actor_by_id(1)
  eq 1, a.class_id
  eq 220, a.max_hp, "class 1's level-3 max HP, not the actor row's 120"
  eq [21, 22], a.skills.sort, "the class's learn table, not the actor's skill 10"
  # A database with no class table (every RPG2000 game) leaves the actor
  # class-less, so nothing changes for 2000 data.
  b = party_state.party.actor_by_id(1)
  eq 0, b.class_id
end

check 'Change Class swaps the growth curve and resets EXP' do
  st = class_state
  a = st.party.actor_by_id(1)
  eq 0, a.class_id
  eq 120, a.max_hp
  it = Game::Interpreter.new(st)
  # scope 1 (fixed actor 1), class 2, keep level, skills add, params reset-level.
  it.start([FakeCmd.new(IC::CHANGE_CLASS,
                        [1, 1, 2, 0, Game::Actor::CLASS_SKILL_ADD,
                         Game::Actor::CLASS_PARAM_RESET_LEVEL, 0])])
  it.update
  eq 2, a.class_id
  eq 3, a.level, 'the level is kept when the "level 1" flag is off'
  eq 70, a.max_hp, "class 2's level-3 max HP"
  eq a.exp_for_level(3), a.exp, 'RPG_RT resets EXP to the level threshold'
  ok a.skills.include?(31), "the new class's skill was added"
  ok a.skills.include?(10), 'and the actor kept what it already knew'
end

check 'Change Class parameter modes carry, halve or reset the base stats' do
  keep = class_state.party.actor_by_id(1)
  before = keep.max_hp
  keep.change_class(1, 3, Game::Actor::CLASS_SKILL_NO_CHANGE,
                    Game::Actor::CLASS_PARAM_NO_CHANGE)
  eq before, keep.max_hp, 'no-change carries the pre-swap stats across'

  half = class_state.party.actor_by_id(1)
  half.change_class(1, 3, Game::Actor::CLASS_SKILL_NO_CHANGE,
                    Game::Actor::CLASS_PARAM_HALF)
  eq before / 2, half.max_hp, 'halve applies to the pre-swap stats'

  lv1 = class_state.party.actor_by_id(1)
  lv1.change_class(1, 3, Game::Actor::CLASS_SKILL_NO_CHANGE,
                   Game::Actor::CLASS_PARAM_RESET_LV1)
  eq 200, lv1.max_hp, "reset-to-level-1 takes the new class's first row"
  eq 3, lv1.level, 'while the level itself still moves'
end

check 'Change Class skill modes keep, replace or add to the known skills' do
  keep = class_state.party.actor_by_id(1)
  keep.change_class(1, 3, Game::Actor::CLASS_SKILL_NO_CHANGE,
                    Game::Actor::CLASS_PARAM_NO_CHANGE)
  eq [10], keep.skills, 'no-change leaves the skill set exactly as it was'

  reset = class_state.party.actor_by_id(1)
  reset.change_class(1, 3, Game::Actor::CLASS_SKILL_RESET,
                     Game::Actor::CLASS_PARAM_NO_CHANGE)
  eq [21, 22], reset.skills.sort, "reset forgets everything but the class's"

  add = class_state.party.actor_by_id(1)
  add.change_class(1, 3, Game::Actor::CLASS_SKILL_ADD,
                   Game::Actor::CLASS_PARAM_NO_CHANGE)
  eq [10, 21, 22], add.skills.sort, 'add keeps both sets'
end

check 'Change Class to level 1 rewinds the level; an unknown class is a no-op' do
  a = class_state.party.actor_by_id(1)
  a.change_class(1, 1, Game::Actor::CLASS_SKILL_RESET,
                 Game::Actor::CLASS_PARAM_RESET_LEVEL)
  eq 1, a.level
  eq 200, a.max_hp
  eq [21], a.skills, 'only the level-1 class skill is learnt'

  b = class_state(1).party.actor_by_id(1)
  eq false, b.change_class(99, 3, 0, 0), 'an undefined class changes nothing'
  eq 1, b.class_id
  eq 220, b.max_hp, 'and leaves the stats it had'
end

check 'Change Class shows one level-up line when it taught skills' do
  st = class_state
  it = Game::Interpreter.new(st)
  # class 1, keep level 3, skills reset, params reset-level, show message on.
  it.start([FakeCmd.new(IC::CHANGE_CLASS,
                        [1, 1, 1, 0, Game::Actor::CLASS_SKILL_RESET,
                         Game::Actor::CLASS_PARAM_RESET_LEVEL, 1])])
  it.update
  eq :message, it.wait_kind
  eq ['Hero is now level 3!'], it.message_lines
  it.resume
  it.update
  ok !it.waiting?, 'a class change announces one line, not one per level'
end

check 'Change Class stays quiet when the level held and no skills moved' do
  st = class_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_CLASS,
                        [1, 1, 1, 0, Game::Actor::CLASS_SKILL_NO_CHANGE,
                         Game::Actor::CLASS_PARAM_NO_CHANGE, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'nothing to announce'
  eq true, st.switches[1]
end

check 'Change Battle Commands adds, removes and clears the command list' do
  st = class_state
  a = st.party.actor_by_id(1)
  eq [1, 2, 0, -1, -1, -1, -1], a.battle_commands, 'straight from the database'
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_BATTLE_COMMANDS, [1, 1, 5, 1])]) # add cmd 5
  it.update
  eq [1, 2, 5, 0], a.battle_commands, 'the new command lands before Row'
  a.change_battle_commands(true, 5)
  eq [1, 2, 5, 0], a.battle_commands, 'adding a command it already has is a no-op'
  a.change_battle_commands(false, 2)
  eq [1, 5, 0], a.battle_commands, 'removing drops just that entry'
  a.change_battle_commands(false, 0)
  eq [0], a.battle_commands, 'removing command 0 clears back to Row alone'
end

check 'Change Battle Commands stops at six commands plus Row' do
  a = class_state.party.actor_by_id(1)
  (3..8).each { |id| a.change_battle_commands(true, id) }
  eq [1, 2, 3, 4, 5, 6, 0], a.battle_commands, 'the seventh add is dropped'
end

check 'a class change takes the class battle commands' do
  a = class_state.party.actor_by_id(1)
  a.change_class(1, 3, 0, 0)
  eq [3, 0, -1, -1, -1, -1, -1], a.battle_commands
end

check 'a class change and its battle commands survive Save / Continue' do
  st = class_state
  st.party.actor_by_id(1).change_class(1, 3, Game::Actor::CLASS_SKILL_RESET,
                                       Game::Actor::CLASS_PARAM_RESET_LEVEL)
  st.party.actor_by_id(1).change_battle_commands(true, 7)
  saved = st.to_h

  restored = Game::State.load(class_db, saved)
  a = restored.party.actor_by_id(1)
  eq 1, a.class_id
  eq 220, a.max_hp, "the class's curve, not the actor row's"
  eq [3, 7, 0], a.battle_commands
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

# -- party wipe -> Game Over --------------------------------------------------

check 'a Change HP that wipes the party goes to Game Over' do
  st = party_state
  it = Game::Interpreter.new(st)
  # Scope 0 (the whole party), lethal, more damage than anyone has.
  it.start([FakeCmd.new(IC::CHANGE_HP, [0, 0, 1, 0, 9999, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok st.party.all_dead?, 'the party is down'
  ok it.waiting?, 'the event stops on the wipe'
  eq :game_over, it.wait_kind
  eq false, st.switches[1], 'the command after it never ran'
end

check 'a Simulated Attack that wipes the party goes to Game Over' do
  # Nepheshel's damage floors are Simulated Attacks (850 of them); one strong
  # enough to kill the party ends the game rather than leaving it walking.
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SIMULATED_ATTACK, [0, 0, 9999, 0, 0, 0, 0, 0])])
  it.update
  ok st.party.all_dead?
  eq :game_over, it.wait_kind
end

check 'a survivable hit leaves the event running' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_HP, [0, 0, 1, 0, 10, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !st.party.all_dead?
  ok !it.waiting?, 'nothing to stop for'
  eq true, st.switches[1]
end

check 'curing the death state clears the Game Over condition' do
  st = party_state
  st.party.actors.each { |a| a.set_hp(0) }
  ok st.party.all_dead?, 'everyone is down to start with'
  it = Game::Interpreter.new(st)
  # Change Condition removing state 1 revives; the wipe check then passes.
  it.start([FakeCmd.new(IC::CHANGE_CONDITION, [0, 0, 1, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !st.party.all_dead?, 'the party is back up'
  ok !it.waiting?
  eq true, st.switches[1]
end

check 'an empty party is not a Game Over, and a battle page never triggers one' do
  # RPG_RT allows a party with no members at all — a game between members is not
  # a game that has ended.
  db = FakeActorDB.new({ 1 => FakePlayerRow.new('Hero', '', 0, 5, max_hp: 100) }, [])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  eq 0, st.party.actors.size
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_HP, [0, 0, 1, 0, 9999, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'no members, no wipe'
  eq true, st.switches[1]

  # A battle page leaves defeat to the battle's own [Defeat] handler.
  st2 = party_state
  it2 = Game::Interpreter.new(st2)
  # Any battle context will do: the check only asks whether one is present.
  it2.battle = Object.new
  it2.start([FakeCmd.new(IC::CHANGE_HP, [0, 0, 1, 0, 9999, 1])])
  it2.update
  ok st2.party.all_dead?
  ok !it2.waiting?, 'the battle resolves its own defeat'
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

# A three-level growth curve (six stats per level) for the level-up-message
# checks: enough levels to gain more than one at a time.
def three_level_db
  FakeActorDB.new(
    { 1 => CurveRow.new('Hero', '', 0, 1,
                        [10, 5, 3, 2, 1, 4, 20, 10, 6, 4, 2, 8, 30, 15, 9, 6, 3, 12]) },
    [1])
end

check 'Change Level with the show-message flag queues a message per level gained' do
  st = Game::State.new(Game::Party.new(three_level_db), 1, 0, 0)
  a = st.party.actor_by_id(1)
  it = Game::Interpreter.new(st)
  # scope 1, actor 1, add, const, amount 2 (1 -> 3), show-message flag on.
  it.start([FakeCmd.new(IC::CHANGE_LEVEL, [1, 1, 0, 0, 2, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq 3, a.level, 'gained two levels'
  ok it.waiting?, 'the first level-up message pauses the event'
  eq :message, it.wait_kind
  eq ['Hero is now level 2!'], it.message_lines
  eq false, st.switches[1], 'the following command has not run yet'
  it.resume
  eq :message, it.wait_kind, 'the second level queues a second message'
  eq ['Hero is now level 3!'], it.message_lines
  it.resume
  it.update
  eq true, st.switches[1], 'the event resumes once the messages drain'
end

check 'Change Level / Change EXP without the flag show no level-up message' do
  st = Game::State.new(Game::Party.new(three_level_db), 1, 0, 0)
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_LEVEL, [1, 1, 0, 0, 2, 0])]) # flag off
  it.update
  eq 3, st.party.actor_by_id(1).level
  ok !it.waiting?, 'no message without the show flag'
end

check 'Change EXP with the show-message flag announces a level-up' do
  st = Game::State.new(Game::Party.new(three_level_db), 1, 0, 0)
  a = st.party.actor_by_id(1)
  need = a.exp_to_next # exactly enough EXP to reach level 2
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_EXP, [1, 1, 0, 0, need, 1])])
  it.update
  eq 2, a.level, 'crossed one level threshold'
  ok it.waiting?
  eq ['Hero is now level 2!'], it.message_lines
  it.resume
  ok !it.waiting?, 'a single level gained -> a single message'
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

check 'a field-only medicine is kept out of battle; every medicine is in the field' do
  # RPG2000 gives a medicine exactly one occasion flag, `occasion_field1`, and it
  # only ever *subtracts*: set, the medicine is field-only. There is no way to
  # make a medicine battle-only, which is why `field_usable?` asks nothing of it
  # (EasyRPG: `return !in_battle || !item->occasion_field1`).
  items = {
    5 => fake_item(type: 6, rhp: 50),                     # usable anywhere
    6 => fake_item(type: 6, rhp: 50, field_only: true),   # field only
  }
  st = item_party(items)
  st.party.gain_item(5, 1)
  st.party.gain_item(6, 1)
  ok st.party.field_usable?(5), 'an ordinary medicine is usable in the field'
  ok st.party.field_usable?(6), 'and so is a field-only one'
  eq [[5, 1], [6, 1]], st.party.field_items
  ok st.party.battle_usable?(5), 'the ordinary medicine is usable in battle'
  ok !st.party.battle_usable?(6), 'the field-only one is not'
  eq [[5, 1]], st.party.battle_items
end

check 'a switch item reads its own pair of occasion flags' do
  # A switch item is the one item kind gated on both sides, and by its *own*
  # fields: occasion_field2 (57) and occasion_battle (58).
  items = {
    5 => fake_item(type: 10, switch_id: 3, occ_field: true,  occ_battle: false),
    6 => fake_item(type: 10, switch_id: 4, occ_field: false, occ_battle: true),
  }
  st = item_party(items)
  st.party.gain_item(5, 1)
  st.party.gain_item(6, 1)
  eq [[5, 1]], st.party.field_items, 'only the field-flagged switch item'
  eq [[6, 1]], st.party.battle_items, 'only the battle-flagged one'
end

check 'a switch item is field-usable, effective, and flips its switch on use' do
  # Type 10 is the switch item (スイッチ); 9 is the special item that invokes a
  # skill. This fixture said 9, which is what the runtime used to believe too.
  items = { 4 => fake_item(type: 10, switch_id: 12, name: 'Whistle') }
  st = item_party(items)
  st.party.gain_item(4, 2)
  eq [[4, 2]], st.party.field_items, 'switch items appear in the field menu'
  ok st.party.switch_item?(4)
  ok st.party.item_effective?(4, st.party.leader), 'a switch item is always effective'
  # Using it consumes one and returns the switch to flip; the caller sets it.
  sid = st.party.use_switch_item(4)
  eq 12, sid, 'use returns the switch id'
  eq 1, st.party.item_count(4), 'one is consumed'
  st.switches[sid] = true
  ok st.switches[12], 'the switch is now on'
  # A non-switch (or absent) item flips nothing and consumes nothing.
  ok st.party.use_switch_item(999).nil?, 'a non-switch item is not a switch use'
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

check 'a cure medicine removes only its listed states' do
  # state_set: byte per state, index i -> state id i+1; states 3 and 7 marked.
  # No reverse flag -- that is what a real curative item looks like, and every
  # one in both test beds leaves it unset.
  items = { 5 => fake_item(type: 6, state_set: [0, 0, 1, 0, 0, 0, 1]) }
  st = item_party(items)
  st.party.gain_item(5, 2)
  hero = st.party.leader
  hero.add_state(3); hero.add_state(9)         # 3 is curable by the item, 9 is not
  eq [3, 7], st.party.item_cured_states(st.party.db_item(5))
  eq true, st.party.item_effective?(5, hero)
  eq [hero], st.party.use_item(5, hero)
  eq false, hero.state?(3)                      # cured
  eq true, hero.state?(9)                       # a state the item does not list stays
  eq 1, st.party.item_count(5)                  # consumed
end

check 'a cure medicine on an unafflicted, full target does nothing / not consumed' do
  items = { 5 => fake_item(type: 6, state_set: [0, 0, 1]) }
  st = item_party(items)
  st.party.gain_item(5, 1)
  hero = st.party.leader                        # full HP, no states
  eq false, st.party.item_effective?(5, hero)
  eq [], st.party.use_item(5, hero)
  eq 1, st.party.item_count(5)
end

check 'a heal+cure item counts either the heal or the cure as a use' do
  items = { 5 => fake_item(type: 6, rhp: 40, state_set: [0, 0, 1]) }
  st = item_party(items)
  st.party.gain_item(5, 3)
  hero = st.party.leader
  hero.add_state(3)                             # full HP but afflicted -> cures, consumes
  eq [hero], st.party.use_item(5, hero)
  eq false, hero.state?(3)
  eq 2, st.party.item_count(5)
  hero.change_hp(-50)                           # 100 -> 50, unafflicted -> heals, consumes
  eq [hero], st.party.use_item(5, hero)
  eq 90, hero.hp                                # 50 + 40
  eq 1, st.party.item_count(5)
end

check 'a reverse medicine cures nothing: inflicting is deliberately unbuilt' do
  # The flag flips a medicine from curing to inflicting, the same way it does for
  # a skill. No item in either test bed sets it, so there is nothing to measure
  # an implementation of the inflict half against and it is left unbuilt -- but
  # such an item must not be treated as a cure either.
  st = item_party({})
  it = fake_item(type: 6, state_set: [0, 0, 1], reverse_state: true)
  eq [], st.party.item_cured_states(it)
  eq [3], st.party.item_cured_states(fake_item(type: 6, state_set: [0, 0, 1])),
     'the same row without the flag does cure'
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
def skill_party(skills, items = {})
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           max_hp: 100, max_mp: 30, atk: 10, def: 8, int: 12, agi: 7),
    2 => FakePlayerRow.new('Ally', '', 0, 3,
                           max_hp: 50, max_mp: 20, atk: 6, def: 5, int: 4, agi: 6),
  }
  Game::State.new(Game::Party.new(FakeActorDB.new(players, [1, 2], items, skills)), 1, 0, 0)
end

check 'an RPG2003 subskill category behaves as an ordinary skill' do
  # Types from 4 up are 2003's custom battle-command categories, not a different
  # kind of skill. mtf-meido-action files 57 of its 134 skills that way — every
  # healing line among them — so reading type != 0 as "not a real skill" hid
  # them from both menus.
  skills = {
    1 => fake_skill(scope: 3, sp_cost: 1, power: 10, hp: true),          # type 0
    2 => fake_skill(scope: 3, sp_cost: 1, power: 10, hp: true, type: 5), # subskill
    3 => fake_skill(scope: 0, sp_cost: 1, power: 10, type: 7),           # subskill, foes
  }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  [1, 2, 3].each { |s| hero.learn_skill(s) }
  eq [[1, 1], [2, 1]], st.party.field_skills(hero), 'the subskill heal is offered'
  caster = Game::Battle.from_actor(hero)
  eq [[1, 1], [2, 1], [3, 1]], st.party.battle_skills(hero, caster)
end

check 'a switch skill is cast for its switch, and only where its flags allow' do
  skills = {
    4 => fake_skill(name: 'Summon', type: 3, sp_cost: 6, switch_id: 17),
    5 => fake_skill(name: 'Boost', type: 3, sp_cost: 2, switch_id: 18,
                    occ: false, occ_battle: true),
  }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  [4, 5].each { |s| hero.learn_skill(s) }
  caster = Game::Battle.from_actor(hero)
  # Skill 4 is field+battle by default; 5 is flagged battle-only.
  eq [[4, 6]], st.party.field_skills(hero), 'the battle-only switch skill is hidden'
  eq [[4, 6], [5, 2]], st.party.battle_skills(hero, caster)
  ok st.party.switch_skill?(4)
  before = hero.mp
  eq 17, st.party.cast_switch_skill(hero, 4), 'casting returns the switch to flip'
  eq before - 6, hero.mp, 'and spends the SP'
  # A non-switch skill is not one, and spends nothing.
  ok st.party.cast_switch_skill(hero, 99).nil?
end

check 'an Escape skill is hidden with no runtime state, then gated on access ' \
      'and a registered target, and warps there for free -- but not while flying' do
  skills = { 6 => fake_skill(name: 'Escape', type: Game::Party::SKILL_ESCAPE,
                             sp_cost: 4) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  hero.learn_skill(6)
  # No state at all -- the bare #field_skill?(sk) a fixture check would call --
  # reads exactly like the old "not built" behaviour.
  eq [], st.party.field_skills(hero), 'unsupported with no state to gate on'
  ok st.party.unsupported_field_skill?(st.party.db_skill(6))
  ok st.party.cast_escape_skill(hero, 6, nil).nil?
  # State present, but access off (the RPG2000 default) and no target set.
  eq [], st.party.field_skills(hero, st)
  st.escape_access = true
  eq [], st.party.field_skills(hero, st), 'access alone is not enough -- no target yet'
  st.escape_target = { map_id: 3, x: 4, y: 5, switch_id: nil }
  eq [[6, 4]], st.party.field_skills(hero, st)
  before = hero.mp
  eq({ map_id: 3, x: 4, y: 5 }, st.party.cast_escape_skill(hero, 6, st))
  eq before - 4, hero.mp, "the warp costs the skill's SP like any other cast"
  # Flying (boarded the airship) bars it even with access and a target set --
  # EasyRPG's Algo::IsSkillUsable Type_escape arm reads Game_Player::IsFlying.
  st.boarded = :airship
  eq [], st.party.field_skills(hero, st), 'the airship blocks it'
  ok st.party.cast_escape_skill(hero, 6, st).nil?
  st.boarded = nil
  # A skill that is not Escape casts nothing through the Escape path.
  ok st.party.cast_escape_skill(hero, 99, st).nil?
end

check 'a Teleport skill lists every registered destination and warps to the ' \
      'one chosen' do
  skills = { 7 => fake_skill(name: 'Warp', type: Game::Party::SKILL_TELEPORT,
                             sp_cost: 3) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  hero.learn_skill(7)
  eq [], st.party.field_skills(hero, st), 'no targets registered yet'
  st.teleport_access = true
  st.teleport_targets[10] = { x: 1, y: 2, switch_id: nil }
  st.teleport_targets[5]  = { x: 8, y: 9, switch_id: nil }
  eq [[7, 3]], st.party.field_skills(hero, st), 'access plus any target offers it'
  before = hero.mp
  eq({ map_id: 5, x: 8, y: 9 }, st.party.cast_teleport_skill(hero, 7, st, 5))
  eq before - 3, hero.mp
  # An id that was never registered casts nothing and spends nothing.
  before = hero.mp
  ok st.party.cast_teleport_skill(hero, 7, st, 999).nil?
  eq before, hero.mp, 'an unknown destination spends no SP'
  # Riding the airship bars Teleport the same way it bars Escape.
  st.boarded = :airship
  eq [], st.party.field_skills(hero, st)
  ok st.party.cast_teleport_skill(hero, 7, st, 5).nil?
end

check 'a special item invokes its skill, free of SP and without knowing it' do
  # Type 9 is 特殊: the item names a skill in skill_id and casting it is what
  # using the item does. Nepheshel's whole thrown-bomb line works this way.
  skills = { 8 => fake_skill(name: 'Elixir', scope: 3, sp_cost: 99,
                             power: 40, hp: true) }
  items = { 3 => fake_item(type: 9, skill_id: 8, name: 'Vial') }
  st = skill_party(skills, items)
  hero = st.party.actor_by_id(1)
  hero.change_hp(-50)
  hero.mp = 0                                   # cannot afford the skill itself
  ok !hero.knows_skill?(8), 'and has never learnt it'
  st.party.gain_item(3, 2)
  ok st.party.field_usable?(3), 'its skill targets an ally, so the field offers it'
  ok st.party.item_effective?(3, hero)
  affected = st.party.use_item(3, hero)
  eq [hero], affected
  eq 90, hero.hp, 'the skill landed'
  eq 0, hero.mp, 'no SP was spent'
  eq 1, st.party.item_count(3), 'one was consumed'
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
  # What keeps an ordinary skill out of the field menu is its *scope* and whether
  # it does anything at all — not `occasion_field`, which RPG2000 only reads for
  # a switch skill (skill 9 here carries it off and is listed all the same).
  skills = {
    7  => fake_skill(scope: 3, sp_cost: 5, power: 10, hp: true),        # usable
    8  => fake_skill(scope: 0, sp_cost: 1, power: 10, hp: true),        # enemy scope
    9  => fake_skill(scope: 3, occ: false, sp_cost: 1, power: 10, hp: true),
    10 => fake_skill(scope: 4, sp_cost: 99, power: 10, hp: true),       # too costly
    11 => fake_skill(scope: 3, sp_cost: 1, power: 10),                  # affects nothing
  }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)               # max SP 30
  [7, 8, 9, 10, 11].each { |s| hero.learn_skill(s) }
  eq [[7, 5], [9, 1], [10, 99]], st.party.field_skills(hero)
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

# -- Field skill status effects (cure / inflict, deterministic) --------------

check 'a cure skill removes only its state_effects states (usable at full HP)' do
  # state_effects index i -> state id i+1; [0,0,1,0,0,0,1] flags states 3 and 7.
  skills = { 5 => fake_skill(name: 'Refresh', scope: 3, sp_cost: 4,
                             state_effects: [0, 0, 1, 0, 0, 0, 1]) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)               # full HP
  hero.learn_skill(5)
  ally.add_state(3); ally.add_state(7); ally.add_state(9)
  eq true, st.party.skill_effective?(hero, 5, ally)   # afflicted -> usable at full HP
  eq [ally], st.party.cast_skill(hero, 5, ally)
  eq false, ally.state?(3)                     # cured
  eq false, ally.state?(7)                     # cured
  eq true, ally.state?(9)                      # not listed -> stays
  eq 26, hero.mp                               # 30 - 4, consumed
end

check 'a revive skill cures the death state, then its HP recovery lands' do
  # Cures state 1 (戦闘不能) and heals. States apply first: the cure revives the
  # ally to 1 HP, then the recovery lands. effect = power 20 + mrate 40*int12/40 = 32.
  skills = { 6 => fake_skill(name: 'Life', scope: 3, sp_cost: 6,
                             power: 20, mrate: 40, hp: true, state_effects: [1]) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.learn_skill(6)
  ally.change_hp(-9999)                        # KO: HP 0 + state 1
  eq true, ally.dead?
  eq [ally], st.party.cast_skill(hero, 6, ally)
  eq false, ally.dead?
  eq 33, ally.hp                               # revived to 1, then +32
end

check 'a plain heal skill cannot revive a downed ally' do
  skills = { 7 => fake_skill(name: 'Heal', scope: 3, sp_cost: 5,
                             power: 20, mrate: 40, hp: true) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.learn_skill(7)
  ally.change_hp(-9999)                        # KO
  eq [], st.party.cast_skill(hero, 7, ally)    # a plain heal can't touch a KO'd actor
  eq true, ally.dead?
  eq 30, hero.mp                               # nothing spent
end

check 'a reverse skill inflicts its state_effects states' do
  skills = { 8 => fake_skill(name: 'Curse', scope: 3, sp_cost: 3,
                             state_effects: [0, 0, 1], reverse_state: true) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.learn_skill(8)
  eq true, st.party.skill_effective?(hero, 8, ally)   # can inflict -> usable
  eq [ally], st.party.cast_skill(hero, 8, ally)
  eq true, ally.state?(3)                      # inflicted
  eq 27, hero.mp                               # 30 - 3
end

check 'a pure cure skill on an unafflicted ally does nothing and spends no SP' do
  skills = { 5 => fake_skill(name: 'Refresh', scope: 3, sp_cost: 4,
                             state_effects: [0, 0, 1]) }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.learn_skill(5)
  eq false, st.party.skill_effective?(hero, 5, ally)
  eq [], st.party.cast_skill(hero, 5, ally)
  eq 30, hero.mp
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

# RPG_RT's item-possession test counts an equipped copy even though equipping
# removes it from the bag (yado.tk 011_siyou/): #has_item? -> true although
# #item_count reads 0. The numeric possession-count operand stays bag-only.
check 'party#has_item? counts a copy equipped on any member, not just the bag' do
  items = { 7 => fake_item(atk: 15, type: 1) }   # weapon -> slot 0
  st = equip_party(items)
  a = st.party.leader
  eq false, st.party.has_item?(7)          # not held at all
  st.party.gain_item(7, 1)
  ok st.party.equip_from_bag(a, 7)
  eq 0, st.party.item_count(7)             # gone from the bag
  eq true, st.party.has_item?(7)           # but still counts as "had"
  eq 7, st.party.unequip_to_bag(a, 0)
  eq 1, st.party.item_count(7)             # back in the bag
  eq true, st.party.has_item?(7)
end

check 'Conditional Branch item test (type 4) sees an equipped copy too' do
  items = { 7 => fake_item(atk: 15, type: 1) }
  st = equip_party(items)
  a = st.party.leader
  st.party.gain_item(7, 1)
  ok st.party.equip_from_bag(a, 7)
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONDITIONAL, [4, 7, 0], indent: 0), # has item 7?
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
            FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
            FakeCmd.new(IC::END_BRANCH, [], indent: 0)])
  it.update
  eq true, st.switches[1]                  # equipped counts as "has" -> if-branch
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

check 'Control Variables reads the party size (operand type 7, selector 2)' do
  st = party_state                                             # 2 members
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 7, 2])]) # var1 = party size
  it.update
  eq 2, st.variables[1]
end

check 'Control Variables reads the save / battle / win / defeat / escape counts' do
  st = new_state
  st.save_count = 3
  st.battle_count = 9
  st.win_count = 6
  st.defeat_count = 1
  st.escape_count = 2
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 7, 3]),   # save count
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 7, 4]),   # battle count
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 7, 5]),   # win count
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 7, 6]),   # defeat count
            FakeCmd.new(IC::CONTROL_VARS, [0, 5, 5, 0, 7, 7])])  # escape count
  it.update
  eq 3, st.variables[1]
  eq 9, st.variables[2]
  eq 6, st.variables[3]
  eq 1, st.variables[4]
  eq 2, st.variables[5]
end

check 'battle counters advance: Enemy Encounter and its outcome' do
  st = new_state
  it = Game::Interpreter.new(st)
  # Enemy Encounter (troop 1, no handlers): suspends on a :battle wait.
  it.start([FakeCmd.new(IC::ENEMY_ENCOUNTER, [0, 1, 0, 0, 0, 0])])
  it.update
  eq 1, st.battle_count, 'entering a battle bumps the battle count'
  eq 0, st.win_count
  it.resume_battle(:victory)
  eq 1, st.win_count, 'a victory bumps the win count'
  eq 0, st.defeat_count
  eq 0, st.escape_count
end

check 'Control Variables reads item count and equipped count (operand type 4)' do
  st = party_state
  st.party.gain_item(7, 3)                                     # 3 of item 7 in the bag
  st.party.actor_by_id(1).equip([7, 0, 0, 0, 0])              # hero equips item 7
  st.party.actor_by_id(2).equip([0, 7, 0, 0, 0])              # ally equips item 7
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 4, 7, 0]),   # var1 = held
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 4, 7, 1])])  # var2 = equipped
  it.update
  eq 3, st.variables[1]                                        # 3 held in the bag
  eq 2, st.variables[2]                                        # two members equip it
end

check 'Control Variables reads the hero position (operand type 6, ref 10001)' do
  st = new_state
  st.map_id = 12; st.x = 5; st.y = 8; st.direction = 4
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 6, 10001, 0]),  # map id
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 6, 10001, 1]),  # x
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 6, 10001, 2]),  # y
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 6, 10001, 3])]) # facing
  it.update
  eq 12, st.variables[1]
  eq 5, st.variables[2]
  eq 8, st.variables[3]
  eq 4, st.variables[4]
end

check 'Control Variables reads a map event position (operand type 6)' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfo.new                                  # event 7 at (2,3) dir 6
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 6, 7, 1]),  # event 7 x
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 6, 7, 2]),  # event 7 y
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 6, 7, 3]),  # event 7 facing
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 6, 7, 0]),  # event map id -> 0
            FakeCmd.new(IC::CONTROL_VARS, [0, 5, 5, 0, 6, 9, 1])]) # unknown event -> 0
  it.update
  eq 2, st.variables[1]
  eq 3, st.variables[2]
  eq 6, st.variables[3]
  eq 0, st.variables[4]                                          # a map event's map id reads 0
  eq 0, st.variables[5]                                          # unknown event reads 0
end

check 'Control Variables reads "this event" (operand 6, ref 10005 / 0)' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfo.new                                  # event 7 at (2,3) dir 6
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 6, 10005, 1]),  # this x
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 6, 10005, 2]),  # this y
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 6, 0, 3]),      # this facing
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 6, 10005, 4])]) # this screen x
  it.event_id = 7 # the list belongs to map event 7
  it.update
  eq 2, st.variables[1]
  eq 3, st.variables[2]
  eq 6, st.variables[3]  # a bare 0 names this event too
  eq 40, st.variables[4] # measured through the same camera hook as any event
end

check 'Control Variables "this event" reads 0 without a running map event' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfo.new
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 6, 10005, 1]),
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 6, 10005, 4])])
  st.variables[1] = 99
  st.variables[2] = 99
  it.update # a common event: no "this event" to resolve
  eq 0, st.variables[1]
  eq 0, st.variables[2]
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

check 'Control Variables reads a character screen position (operand 6, attr 4/5)' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfo.new
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 6, 10001, 4]),  # hero screen x
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 6, 10001, 5]),  # hero screen y
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 6, 7, 4]),      # event 7 screen x
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 6, 9, 4])])     # not on this map
  it.update
  eq 160, st.variables[1]
  eq 120, st.variables[2]
  eq 40, st.variables[3]
  eq 0, st.variables[4]
end

check 'a screen position with no camera to measure against reads 0' do
  st = new_state
  st.variables[1] = 99
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfoNoCamera.new   # answers positions, but owns no view
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 6, 10001, 4])])
  it.update
  eq 0, st.variables[1]
end

check 'Control Variables reads an equipped item id (operand 5, attr 10..14)' do
  st = party_state
  a = st.party.actor_by_id(1)
  a.equip([11, 0, 13, 0, 15])
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 5, 1, 10]),   # weapon
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 5, 1, 11]),   # shield (empty)
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 5, 1, 12]),   # armour
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 5, 1, 14]),   # accessory
            FakeCmd.new(IC::CONTROL_VARS, [0, 5, 5, 0, 5, 1, 15])])  # unknown -> 0
  it.update
  eq 11, st.variables[1]
  eq 0, st.variables[2]
  eq 13, st.variables[3]
  eq 15, st.variables[4]
  eq 0, st.variables[5]
end

check 'the battle operand reads 0 outside a fight, not the member index' do
  st = new_state
  st.variables[1] = 99
  it = Game::Interpreter.new(st) # no #battle set: a map / common event
  # param5 is the troop member index; returning it would look like a real stat.
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 8, 3, 0])])
  it.update
  eq 0, st.variables[1]
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

# Like run_actor_cond but with a FakeMapInfo hook set (event 7 at (2,3) dir 6),
# for conditions that read map events. `event_id` says which map event is
# running the list, which is what a "this event" reference resolves to.
def run_cond_with_mapinfo(params, event_id: nil)
  st = party_state
  it = Game::Interpreter.new(st)
  it.map_info = FakeMapInfo.new
  it.start([FakeCmd.new(IC::CONDITIONAL, params, indent: 0),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
            FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
            FakeCmd.new(IC::END_BRANCH, [], indent: 0)])
  it.event_id = event_id
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

check 'Conditional actor: afflicted by state (type 5, sub 6)' do
  st = run_actor_cond([5, 1, 6, 4]) { |s| s.party.actor_by_id(1).add_state(4) }
  eq true, st.switches[1]            # state 4 present -> if-branch
  st = run_actor_cond([5, 1, 6, 4]) # no states -> else
  eq true, st.switches[2]
end

# -- Change Condition (event command 10480) ---------------------------------

check 'Change Condition inflicts a state on the targeted actor (op 0)' do
  st = party_state
  it = Game::Interpreter.new(st)
  # scope 1 (fixed actor), actor 1, op 0 (add), state 4.
  it.start([FakeCmd.new(IC::CHANGE_CONDITION, [1, 1, 0, 4])])
  it.update
  eq true, st.party.actor_by_id(1).state?(4)
end

check 'Change Condition removes a state on the targeted actor (op 1)' do
  st = party_state
  st.party.actor_by_id(1).add_state(4)
  it = Game::Interpreter.new(st)
  # op 1 (remove) clears state 4.
  it.start([FakeCmd.new(IC::CHANGE_CONDITION, [1, 1, 1, 4])])
  it.update
  eq false, st.party.actor_by_id(1).state?(4)
end

check 'Change Condition can KO the whole party (scope 0) via the death state' do
  st = party_state
  it = Game::Interpreter.new(st)
  # scope 0 (whole party), op 0 (add), state 1 (戦闘不能) -> everyone down.
  it.start([FakeCmd.new(IC::CHANGE_CONDITION, [0, 0, 0, Game::Actor::DEATH_STATE])])
  it.update
  eq true, st.party.actors.all?(&:dead?)
  eq [0, 0], st.party.actors.map(&:hp)
end

check 'Change Condition reviving the death state stands an actor back up' do
  st = party_state
  st.party.actor_by_id(1).add_state(Game::Actor::DEATH_STATE)  # down first
  it = Game::Interpreter.new(st)
  # op 1 (remove) state 1 -> revived with 1 HP.
  it.start([FakeCmd.new(IC::CHANGE_CONDITION, [1, 1, 1, Game::Actor::DEATH_STATE])])
  it.update
  a = st.party.actor_by_id(1)
  eq false, a.dead?
  eq 1, a.hp
end

check 'Actor status states: add / remove / query, cleared by Full Recovery' do
  a = party_state.party.actor_by_id(1)
  eq [], a.states
  eq false, a.state?(3)
  a.add_state(3); a.add_state(3); a.add_state(7)     # duplicate is ignored
  eq [3, 7], a.states
  eq true, a.state?(3)
  a.remove_state(3)
  eq [7], a.states
  a.states = [1, 0, nil, 2, 2]                        # setter drops 0/nil, dedups
  eq [1, 2], a.states
  a.full_heal
  eq [], a.states                                     # Full Recovery clears states
end

check 'Actor death state: lethal HP inflicts 戦闘不能 (state 1), block on revive' do
  a = party_state.party.actor_by_id(1)
  eq false, a.dead?
  a.change_hp(-1000, true)                            # lethal damage -> knocked out
  eq 0, a.hp
  eq true, a.dead?
  eq true, a.state?(Game::Actor::DEATH_STATE)         # HP 0 couples to state 1
  a.change_hp(500)                                    # a downed actor cannot be healed
  eq 0, a.hp
  eq true, a.dead?
  a.remove_state(Game::Actor::DEATH_STATE)            # curing 戦闘不能 revives with 1 HP
  eq 1, a.hp
  eq false, a.dead?
  a.change_hp(49); eq 50, a.hp                        # healing lands again once alive
end

check 'Actor death state: inflicting state 1 zeroes HP; Full Recovery revives' do
  a = party_state.party.actor_by_id(1)
  a.add_state(Game::Actor::DEATH_STATE)               # inflict KO directly
  eq 0, a.hp
  eq true, a.dead?
  a.full_heal                                         # Full Recovery clears states + revives
  eq 100, a.hp
  eq false, a.dead?
  eq false, a.state?(Game::Actor::DEATH_STATE)
end

check 'Actor death state: non-lethal damage floors HP at 1, no KO' do
  a = party_state.party.actor_by_id(1)
  a.change_hp(-1000, false)                           # death disallowed -> floor 1
  eq 1, a.hp
  eq false, a.dead?
  eq false, a.state?(Game::Actor::DEATH_STATE)
end

check 'Actor#set_hp sets an absolute HP and syncs the death state' do
  a = party_state.party.actor_by_id(1)                # max 100
  a.set_hp(9999); eq 100, a.hp                        # clamped to max
  a.set_hp(0)
  eq 0, a.hp
  eq true, a.dead?                                    # 0 -> knocked out
  eq true, a.state?(Game::Actor::DEATH_STATE)
  a.set_hp(25)
  eq 25, a.hp
  eq false, a.dead?                                   # positive -> revived
  eq false, a.state?(Game::Actor::DEATH_STATE)        # death state cleared
end

check 'Party#all_dead? / any_alive? track the game-over condition' do
  st = party_state
  eq true, st.party.any_alive?
  eq false, st.party.all_dead?
  st.party.actor_by_id(1).change_hp(-9999)            # leader down
  eq true, st.party.any_alive?                        # the ally still stands
  eq false, st.party.all_dead?
  st.party.actor_by_id(2).change_hp(-9999)            # ally down too
  eq false, st.party.any_alive?
  eq true, st.party.all_dead?                         # whole party wiped
  st.party.actor_by_id(1).full_heal                   # revive one
  eq true, st.party.any_alive?
  eq false, st.party.all_dead?
end

check 'State save round-trips per-actor status states' do
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5, max_hp: 100, max_mp: 30, atk: 10, def: 8),
    2 => FakePlayerRow.new('Ally', '', 0, 3, max_hp: 50, max_mp: 20, atk: 6, def: 5),
  }
  db = FakeActorDB.new(players, [1, 2])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  st.party.actor_by_id(1).add_state(3)
  st.party.actor_by_id(1).add_state(9)
  st.party.actor_by_id(2).add_state(5)
  loaded = Game::State.load(db, Marshal.load(Marshal.dump(st.to_h)))
  eq [3, 9], loaded.party.actor_by_id(1).states.sort
  eq [5], loaded.party.actor_by_id(2).states.sort
end

check 'Conditional actor: unmodelled sub-condition reads false (type 5, sub 6)' do
  eq true, run_actor_cond([5, 1, 6, 3]).switches[2] # has-state -> false -> else
end

check 'Conditional Branch: party riding a vehicle (type 7)' do
  # type 7, param1 the vehicle (0 boat / 1 ship / 2 airship).
  st = run_actor_cond([7, 1]) { |s| s.boarded = :ship }
  eq true, st.switches[1]                            # riding the ship -> if-branch
  st = run_actor_cond([7, 0]) { |s| s.boarded = :ship }
  eq true, st.switches[2]                            # asked about the boat -> else
  st = run_actor_cond([7, 2])                        # on foot (boarded nil)
  eq true, st.switches[2]                            # not aboard -> else
end

check 'Conditional Branch: character orientation (type 6)' do
  # direction param 0 up / 1 right / 2 down / 3 left -> numpad 8/6/2/4.
  st = run_actor_cond([6, 10001, 3]) { |s| s.direction = 4 } # hero facing left
  eq true, st.switches[1]                            # facing left -> if-branch
  st = run_actor_cond([6, 10001, 1]) { |s| s.direction = 4 } # asked facing right
  eq true, st.switches[2]                            # not facing right -> else
  # FakeMapInfo's event 7 faces right (numpad 6 = param 1).
  eq true, run_cond_with_mapinfo([6, 7, 1]).switches[1]  # event faces right
  eq true, run_cond_with_mapinfo([6, 7, 0]).switches[2]  # not facing up -> else
  eq true, run_cond_with_mapinfo([6, 9, 1]).switches[2]  # unknown event -> else
end

check 'Conditional Branch orientation: "this event" (type 6, ref 10005 / 0)' do
  # The event running the list is event 7, which FakeMapInfo faces right.
  eq true, run_cond_with_mapinfo([6, 10005, 1], event_id: 7).switches[1]
  eq true, run_cond_with_mapinfo([6, 10005, 0], event_id: 7).switches[2] # not up
  eq true, run_cond_with_mapinfo([6, 0, 1], event_id: 7).switches[1] # 0 is the same ref
  # A common event has no "this event", so the test cannot hold.
  eq true, run_cond_with_mapinfo([6, 10005, 1]).switches[2]
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

check 'Game Over raises a :game_over request and stops the event' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::GAME_OVER, []),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'Game Over pauses the interpreter'
  eq :game_over, it.wait_kind
  eq false, st.switches[1], 'the command after it does not run (the game is ending)'
end

# -- Change Screen Transitions ------------------------------------------------

check 'Change Screen Transitions sets the chosen slot; round-trips through save' do
  players = { 1 => FakePlayerRow.new('Hero', '', 0, 5,
                                     max_hp: 100, max_mp: 30, atk: 10, def: 8) }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  eq [nil] * 6, st.screen_transitions, 'a fresh state has no slot configured'
  # Seeding fills every slot from the database's System settings; this fake
  # database carries none, so each falls back to setting 0 (the plain fade).
  st.seed_screen_transitions(db)
  eq [0, 0, 0, 0, 0, 0], st.screen_transitions, 'seeded to the database defaults'

  it = Game::Interpreter.new(st)
  # Slot 2 (battle-start erase) -> style 5, slot 5 (battle-end show) -> style 9.
  it.start([FakeCmd.new(IC::CHANGE_TRANSITION, [2, 5]),
            FakeCmd.new(IC::CHANGE_TRANSITION, [5, 9])])
  it.update
  eq [0, 0, 5, 0, 0, 9], st.screen_transitions
  # An out-of-range slot is ignored.
  st.set_screen_transition(6, 3)
  st.set_screen_transition(-1, 3)
  eq [0, 0, 5, 0, 0, 9], st.screen_transitions

  loaded = Game::State.load(db, st.to_h)
  eq [0, 0, 5, 0, 0, 9], loaded.screen_transitions, 'transitions round-trip'
  # A save written before transitions existed restores all-default.
  legacy = st.to_h
  legacy.delete(:screen_transitions)
  eq [0, 0, 0, 0, 0, 0], Game::State.load(db, legacy).screen_transitions
end

# -- Change System Graphics ---------------------------------------------------

check 'Change System Graphics overrides the windowskin / font; round-trips' do
  players = { 1 => FakePlayerRow.new('Hero', '', 0, 5,
                                     max_hp: 100, max_mp: 30, atk: 10, def: 8) }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  eq nil, st.system_graphic, 'no override until a command sets one'
  eq 0, st.font_id

  it = Game::Interpreter.new(st)
  # string = windowskin name, param0 = stretch (ignored), param1 = font id.
  it.start([FakeCmd.new(IC::CHANGE_SYSTEM_GFX, [0, 1], string: 'Skin2')])
  it.update
  eq 'Skin2', st.system_graphic
  eq 1, st.font_id
  ok it.take_system_graphic_changed, 'a windowskin-reload request was raised'
  ok !it.take_system_graphic_changed, 'the request is one-shot'

  loaded = Game::State.load(db, st.to_h)
  eq 'Skin2', loaded.system_graphic, 'the override round-trips through the save'
  eq 1, loaded.font_id
end

# -- Enter Hero Name (Name Input) ---------------------------------------------

check 'Enter Hero Name suspends on :name_input and resume renames the actor' do
  st = party_state # Hero id 1, Ally id 2
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::NAME_INPUT, [1, 2, 1]), # actor 1, letters, seed name
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'the interpreter waits for the entry to finish'
  eq :name_input, it.wait_kind
  eq 1, it.name_input_request[:actor_id]
  eq 'Hero', it.name_input_request[:seed], 'seeded with the current name'
  eq false, st.switches[1], 'the following command has not run yet'
  it.resume_name_input('Zephyr')
  eq 'Zephyr', st.party.actor_by_id(1).name, 'the actor is renamed'
  it.update
  eq true, st.switches[1], 'execution continues after entry'
end

check 'Enter Hero Name without the seed flag starts from an empty name' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::NAME_INPUT, [1, 2, 0])]) # seed flag off
  it.update
  eq '', it.name_input_request[:seed]
  it.resume_name_input('') # a blank entry keeps the old name (RPG_RT behaviour)
  eq 'Hero', st.party.actor_by_id(1).name
end

check 'Enter Hero Name for an actor not in the party is a no-op' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::NAME_INPUT, [99, 0, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok !it.waiting?, 'no wait is raised for an actor this build never instantiated'
  eq true, st.switches[2], 'execution runs straight past the command'
end

# -- Vehicle commands ---------------------------------------------------------

check 'Set Vehicle Location places a vehicle (constant and variable modes)' do
  st = party_state
  it = Game::Interpreter.new(st)
  # boat (0), literal mode (param1 = 0): map 5, x 10, y 12.
  it.start([FakeCmd.new(IC::SET_VEHICLE_LOCATION, [0, 0, 5, 10, 12])])
  it.update
  boat = st.vehicle(:boat)
  eq [5, 10, 12], [boat.map_id, boat.x, boat.y]
  ok boat.placed?, 'a positioned vehicle reads as placed'
  # ship (1), variable mode (param1 = 1): map / x / y come from variables.
  st.variables[1] = 7
  st.variables[2] = 3
  st.variables[3] = 4
  it2 = Game::Interpreter.new(st)
  it2.start([FakeCmd.new(IC::SET_VEHICLE_LOCATION, [1, 1, 1, 2, 3])])
  it2.update
  ship = st.vehicle(:ship)
  eq [7, 3, 4], [ship.map_id, ship.x, ship.y]
end

check 'Change Vehicle Graphic sets the vehicle charset' do
  st = party_state
  it = Game::Interpreter.new(st)
  # airship (2), charset 'Airship1', cell 3.
  it.start([FakeCmd.new(IC::CHANGE_VEHICLE_GRAPHIC, [2, 3], string: 'Airship1')])
  it.update
  air = st.vehicle(:airship)
  eq 'Airship1', air.charset_name
  eq 3, air.charset_index
end

check 'an out-of-range vehicle id is a no-op' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SET_VEHICLE_LOCATION, [5, 0, 1, 2, 3]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 4, 4, 0])])
  it.update
  ok !st.vehicle(:boat).placed?, 'no vehicle was placed'
  eq true, st.switches[4], 'execution continues past the command'
end

check 'vehicle placement / graphic round-trip through the save' do
  players = { 1 => FakePlayerRow.new('Hero', '', 0, 5,
                                     max_hp: 100, max_mp: 30, atk: 10, def: 8) }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SET_VEHICLE_LOCATION, [0, 0, 5, 10, 12]),
            FakeCmd.new(IC::CHANGE_VEHICLE_GRAPHIC, [0, 1], string: 'Boat1')])
  it.update
  loaded = Game::State.load(db, st.to_h)
  boat = loaded.vehicle(:boat)
  eq [5, 10, 12], [boat.map_id, boat.x, boat.y], 'position round-trips'
  eq 'Boat1', boat.charset_name, 'graphic round-trips'
  eq 1, boat.charset_index
end

check 'the ridden vehicle round-trips through the save' do
  players = { 1 => FakePlayerRow.new('Hero', '', 0, 5,
                                     max_hp: 100, max_mp: 30, atk: 10, def: 8) }
  db = FakeActorDB.new(players, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  ok !st.boarded?, 'the party starts on foot'
  st.boarded = :ship
  ok st.boarded?
  eq :ship, Game::State.load(db, st.to_h).boarded, 'the ridden vehicle survives a save'
  # A save written before boarding existed restores on-foot.
  legacy = st.to_h
  legacy.delete(:boarded)
  ok !Game::State.load(db, legacy).boarded?
end

# -- Show Battle Animation ----------------------------------------------------

check 'Show Battle Animation records the request and waits with the flag' do
  st = party_state
  it = Game::Interpreter.new(st)
  # animation 7 on the player (target 10001), wait flag on.
  it.start([FakeCmd.new(IC::SHOW_BATTLE_ANIM, [7, 10001, 1]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok it.waiting?, 'the wait flag pauses the event'
  eq :animation, it.wait_kind
  eq 7, it.battle_animation[:animation]
  eq 10001, it.battle_animation[:target]
  eq true, it.battle_animation[:wait]
  eq false, st.switches[1], 'the next command waits for the animation'
  it.resume
  it.update
  eq true, st.switches[1], 'execution continues after the animation'
end

check 'Show Battle Animation without the wait flag does not pause' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SHOW_BATTLE_ANIM, [7, 10001, 0]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0])])
  it.update
  ok !it.waiting?, 'no wait without the flag'
  eq true, st.switches[2], 'execution runs straight through'
  eq 7, it.battle_animation[:animation], 'the request is still recorded for the renderer'
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

# -- Change Parallax Background -----------------------------------------------

check 'Change Parallax Background records a state override, non-blocking' do
  st = party_state
  it = Game::Interpreter.new(st)
  eq nil, st.parallax, 'no override to start (the map panorama applies)'
  # string = panorama; [loop_x, loop_y, auto_x, sx, auto_y, sy].
  it.start([FakeCmd.new(IC::CHANGE_PARALLAX, [1, 0, 1, 3, 0, -2], string: 'Sky'),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'Change Parallax must not pause the interpreter'
  eq true, st.switches[1], 'the command after it still ran'
  eq({ name: 'Sky', loop_x: true, loop_y: false, auto_x: true, sx: 3,
       auto_y: false, sy: -2 }, st.parallax)
end

check 'Change Parallax Background flags a one-shot rebuild request' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_PARALLAX, [0, 0, 0, 0, 0, 0], string: 'Cave')])
  it.update
  eq true, it.take_parallax_request, 'the scene is told to rebuild once'
  eq false, it.take_parallax_request, 'and the flag clears after one read'
end

check 'clear_parallax drops the override so the map panorama returns' do
  st = party_state
  st.set_parallax(name: 'Sky', loop_x: true, loop_y: true,
                  auto_x: false, sx: 0, auto_y: false, sy: 0)
  ok !st.parallax.nil?, 'override is set'
  st.clear_parallax
  eq nil, st.parallax, 'cleared on a map change'
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

check 'Shop max_buy is bounded by what the party can afford' do
  st, shop = shop_setup(450, { 3 => 100 })
  eq 4, shop.max_buy(3), '450 gold buys four at 100'
  st.party.gain_gold(-450)
  eq 0, shop.max_buy(3), 'and none when broke'
end

check 'Shop max_buy is bounded by the 99-item cap, not just gold' do
  st, shop = shop_setup(999_999, { 3 => 1 })
  eq 99, shop.max_buy(3), 'rich enough for more, but 99 is the cap'
  st.party.gain_item(3, 90)
  eq 9, shop.max_buy(3), 'only the remaining room'
  st.party.gain_item(3, 9)
  eq 0, shop.max_buy(3), 'full'
end

check 'Shop max_buy of a free item is limited only by the cap' do
  _st, shop = shop_setup(0, { 4 => 0 })
  eq 99, shop.max_buy(4), 'a price-0 good does not divide by zero'
end

check 'Shop max_buy is 0 for unstocked goods and in a sell-only shop' do
  _st, shop = shop_setup(500, { 3 => 100 })
  eq 0, shop.max_buy(7), 'not stocked'
  _st2, shop2 = shop_setup(500, { 3 => 100 }, allow_buy: false, allow_sell: true)
  eq 0, shop2.max_buy(3), 'this shop does not sell'
end

check 'Shop max_sell is what the party holds, and 0 when it cannot be sold' do
  st, shop = shop_setup(0, { 3 => 100 })
  st.party.gain_item(3, 7)
  eq 7, shop.max_sell(3)
  st2, shop2 = shop_setup(0, { 4 => 0 })
  st2.party.gain_item(4, 3)
  eq 0, shop2.max_sell(4), 'a price-0 key item cannot be sold'
  st3, shop3 = shop_setup(0, { 3 => 100 }, allow_buy: true, allow_sell: false)
  st3.party.gain_item(3, 3)
  eq 0, shop3.max_sell(3), 'this shop does not buy'
end

check 'Shop buys a whole stack in one transaction' do
  st, shop = shop_setup(500, { 3 => 100 })
  ok shop.buy(3, 4), 'four at once'
  eq 100, st.party.gold, '500 - 4*100'
  eq 4, st.party.item_count(3)
end

check 'Shop sells a whole stack in one transaction' do
  st, shop = shop_setup(0, { 3 => 100 })
  st.party.gain_item(3, 5)
  ok shop.sell(3, 3), 'three at once'
  eq 150, st.party.gold, '3 * 50'
  eq 2, st.party.item_count(3)
end

check 'a stack beyond what the party can afford buys nothing at all' do
  st, shop = shop_setup(500, { 3 => 100 })
  ok !shop.buy(3, 6), 'six would cost 600'
  eq 500, st.party.gold, 'no gold spent'
  eq 0, st.party.item_count(3), 'and no partial purchase'
  ok !shop.did_transaction
end

check 'a stack beyond what the party holds sells nothing at all' do
  st, shop = shop_setup(0, { 3 => 100 })
  st.party.gain_item(3, 2)
  ok !shop.sell(3, 3)
  eq 0, st.party.gold
  eq 2, st.party.item_count(3), 'the items are untouched'
end

check 'a zero or negative quantity is not a transaction' do
  st, shop = shop_setup(500, { 3 => 100 })
  ok !shop.buy(3, 0)
  ok !shop.buy(3, -2), 'a negative count cannot mint gold'
  eq 500, st.party.gold
  ok !shop.did_transaction
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
                      :agility, :exp, :gold, :drop_id, :drop_prob)
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

check 'Game::Enemy reads its treasure drop id and probability' do
  db = BattleDB.new({ 5 => EnemyRow.new('Golem', 100, 0, 10, 10, 5, 3, 20, 50, 7, 25) }, {})
  e = Game::Enemy.new(db, 5)
  eq 7, e.drop_id
  eq 25, e.drop_prob
  eq 0, Game::Enemy.new(battle_db, 2).drop_id, 'no drop when the row omits it'
end

check 'Troop#drops yields certain drops, skipping zero-chance / no-item foes' do
  db = BattleDB.new(
    { 2 => EnemyRow.new('Slime', 30, 0, 8, 4, 3, 5, 5, 10, 7, 100),  # always drops 7
      3 => EnemyRow.new('Bat',   12, 0, 6, 2, 2, 9, 3,  4, 9, 0),    # 0% -> never
      4 => EnemyRow.new('Imp',   12, 0, 6, 2, 2, 9, 3,  4, 0, 100) },# no drop item
    { 1 => GroupRow.new('Mob', { 1 => GroupMember.new(2, 0, 0, false),
                                 2 => GroupMember.new(3, 0, 0, false),
                                 3 => GroupMember.new(4, 0, 0, false) }) })
  troop = Game::Troop.new(db, 1)
  eq [7], troop.drops(Game::Rng.new(1)), 'only the 100% drop lands'
end

check 'Troop#drops rolls the drop probability on the given RNG' do
  db = BattleDB.new(
    { 2 => EnemyRow.new('Slime', 30, 0, 8, 4, 3, 5, 5, 10, 7, 50) }, # 50% drop
    { 1 => GroupRow.new('Mob', { 1 => GroupMember.new(2, 0, 0, false) }) })
  troop = Game::Troop.new(db, 1)
  rng = Game::Rng.new(1)                              # one RNG, many independent rolls
  results = Array.new(40) { troop.drops(rng) }
  ok results.any? { |r| r == [7] }, 'the 50% drop sometimes lands'
  ok results.any?(&:empty?), 'and sometimes misses'
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

# A combatant carrying SP, for the Skill checks (full SP at `mp`).
def combatant_mp(name, atk, dfn, agi, hp, mp)
  c = combatant(name, atk, dfn, agi, hp)
  c.mp = mp
  c.max_mp = mp
  c
end

check 'Battle.attack_damage is half attack less a quarter defence, min 1' do
  eq 18, Game::Battle.attack_damage(40, 8),  '20 - 2'
  eq 1,  Game::Battle.attack_damage(2, 40),  'floored at 1'
  eq 1,  Game::Battle.attack_damage(0, 0)
end

# base 20 (atk 40 vs def 0); variance 4 -> adj = 8, spread 20-4 .. 20+8-4 = 16..24.
def variance_hit(seed)
  hero = combatant('Hero', 40, 0, 20, 100)
  slime = combatant('Slime', 0, 0, 5, 1000)          # tanky, survives the hit
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(seed), nil, true)
  bat.begin_round
  bat.step_action[:damage]
end

check 'battle damage variance spreads a basic attack within its range' do
  d = variance_hit(1)
  ok d >= 16 && d <= 24, "in 16..24 (got #{d})"
end

check 'battle damage variance is seed-deterministic' do
  eq variance_hit(1), variance_hit(1), 'same seed -> same damage'
end

check 'battle damage variance produces a spread of values across hits' do
  hero = combatant('Hero', 40, 0, 20, 100)
  slime = combatant('Slime', 0, 0, 5, 100_000)       # huge HP: many hits land
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, true)
  20.times { bat.run_round }
  hits = bat.log.select { |e| e[:attacker] == 'Hero' }.map { |e| e[:damage] }
  ok hits.uniq.length > 1, "variance spreads damage (#{hits.uniq.sort.inspect})"
  ok hits.all? { |d| d >= 16 && d <= 24 }, 'every hit within 16..24'
end

check 'without variance a seeded fight deals exactly the base damage' do
  hero = combatant('Hero', 40, 0, 20, 100)
  slime = combatant('Slime', 0, 0, 5, 1000)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1))  # 3-arg: variance off
  bat.begin_round
  eq 20, bat.step_action[:damage]                    # exact base, unaffected
end

check 'Rng#scaled pays out a small threshold at its stated rate' do
  # The generator's period is prime, so `next_int % scale` leaves the lowest
  # `PERIOD % scale` values over-represented. At the sizes #random is used with
  # that is invisible; at CRIT_SCALE the surplus is 5537 values sitting exactly
  # where a roll-under-a-small-threshold test looks, and every such threshold
  # fires about 7% too often. #scaled spreads it instead.
  [[333, 30], [500, 20], [3333, 3]].each do |bp, denom|
    trials = 40_000
    modulo = Game::Rng.new(1)
    scaled = Game::Rng.new(1)
    m = s = 0
    trials.times do
      m += 1 if modulo.random(Game::CRIT_SCALE) < bp
      s += 1 if scaled.scaled(Game::CRIT_SCALE) < bp
    end
    want = trials * bp / Game::CRIT_SCALE.to_f
    ok (s - want).abs < want * 0.03,
       "1/#{denom}: scaled gave #{s}, wanted about #{want.round}"
    ok m > want * 1.03,
       "1/#{denom}: the modulus overshoots by more than 3% (#{m} vs #{want.round})"
  end
  eq 0, Game::Rng.new(1).scaled(0), 'a non-positive scale draws 0'
  ok Game::Rng.new(1).scaled(10).between?(0, 9), 'and a normal one stays in range'
end

check 'battle: a crit chance is paid out at the rate it states' do
  # End to end through the real roll, which is what the bias actually reached.
  chance = Game::CRIT_SCALE / 20                      # 1/20 -> 500 bp
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.crit_chance = chance
  foe = combatant('Foe', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [foe], Game::Rng.new(1), nil, false, true)
  trials = 40_000
  crits = 0
  trials.times { crits += 1 if bat.send(:critical?, hero) }
  want = trials / 20.0
  ok (crits - want).abs < want * 0.03,
     "a 1-in-20 chance crit #{crits} times in #{trials}, wanted about #{want.round}"
end

check 'battle: a critical hit triples the damage when the fight rolls one' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.crit_chance = Game::CRIT_SCALE                # certainty -> always crits
  slime = combatant('Slime', 0, 0, 5, 100_000)
  # 6-arg: variance off, criticals on.
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, true)
  bat.begin_round
  e = bat.step_action
  eq 60, e[:damage]                                  # base 20 * 3
  eq true, e[:critical]
end

check 'battle: no critical when the fight has criticals off' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.crit_chance = Game::CRIT_SCALE                # would always crit, but...
  slime = combatant('Slime', 0, 0, 5, 100_000)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1))  # 3-arg: crit off
  bat.begin_round
  e = bat.step_action
  eq 20, e[:damage]
  ok !e[:critical]
end

check 'battle: a zero crit_chance never criticals even with criticals on' do
  hero = combatant('Hero', 40, 0, 20, 100)           # crit_chance nil -> never
  slime = combatant('Slime', 0, 0, 5, 100_000)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, true)
  bat.begin_round
  e = bat.step_action
  eq 20, e[:damage]
  ok !e[:critical]
end

# A party whose actors carry their own critical-hit rate, for the weapon-bonus
# checks: the hero crits 1-in-30 (RPG2000's own default), the ally never does.
def crit_party(items)
  players = {
    1 => FakePlayerRow.new('Hero', '', 0, 5,
                           { max_hp: 100, atk: 40, def: 0, agi: 20 },
                           false, true, 30),
    2 => FakePlayerRow.new('Ally', '', 0, 3,
                           { max_hp: 50, atk: 6, def: 0, agi: 4 },
                           false, false, 0),
  }
  Game::State.new(Game::Party.new(FakeActorDB.new(players, [1, 2], items)), 1, 0, 0)
end

check 'Actor#crit_chance: the row rate alone, in basis points' do
  st = crit_party({})
  eq Game::CRIT_SCALE / 30, st.party.actor_by_id(1).crit_chance
  eq 333, st.party.actor_by_id(1).crit_chance, '1-in-30 is 3.33%'
  eq 0, st.party.actor_by_id(2).crit_chance, 'an actor that never crits'
end

check 'Actor#crit_chance: an equipped weapon adds its own percentage' do
  # The whole point of the probability model: RPG_RT adds the weapon's rate to
  # the wielder's, which no 1-in-N denominator can express.
  items = { 7 => fake_item(type: 1, atk: 5, critical_hit: 20) }
  st = crit_party(items)
  a = st.party.actor_by_id(1)
  eq 333, a.crit_chance, 'unarmed: the row rate'
  a.equip([7, 0, 0, 0, 0])
  eq 333 + 20 * Game::CRIT_PERCENT, a.crit_chance
  eq 2333, a.crit_chance, '3.33% + 20% = 23.33%'
end

check 'Actor#crit_chance: the best weapon wins, and only a weapon counts' do
  # `type` is what separates them. The armour case is not hypothetical: six of
  # Nepheshel's items carrying the field are armour and accessories, every one
  # of them at exactly 100 alongside a weapon-only `hit` of 70 -- the editor
  # leaving weapon fields alone in a record every item type shares, not six
  # pieces of armour that always critical.
  items = { 7 => fake_item(type: 1, critical_hit: 20),   # weapon
            8 => fake_item(type: 1, critical_hit: 5),    # a second weapon
            9 => fake_item(type: 3, critical_hit: 100) } # armour
  st = crit_party(items)
  a = st.party.actor_by_id(1)
  a.equip([8, 7, 0, 0, 0])
  eq 333 + 20 * Game::CRIT_PERCENT, a.crit_chance,
     'the better of two wielded weapons, not their sum'
  a.equip([0, 0, 9, 0, 0])
  eq 333, a.crit_chance, 'the armour contributes nothing'
end

check 'Actor#crit_chance: a weapon arms an actor whose own rate is off' do
  # The two are separate additive terms in RPG_RT, so the actor flag is not a
  # master switch over the weapon. Unobservable in either test bed -- all 50 of
  # Nepheshel's actors can crit -- so this pins the reading rather than a
  # measured behaviour.
  items = { 7 => fake_item(type: 1, critical_hit: 20) }
  st = crit_party(items)
  ally = st.party.actor_by_id(2)
  eq 0, ally.crit_chance
  ally.equip([7, 0, 0, 0, 0])
  eq 20 * Game::CRIT_PERCENT, ally.crit_chance
end

check 'battle: a 100% weapon crits every swing, and still triples' do
  st = crit_party({ 7 => fake_item(type: 1, critical_hit: 100) })
  hero = st.party.actor_by_id(1)
  hero.equip([7, 0, 0, 0, 0])
  c = Game::Battle.from_actor(hero)
  ok c.crit_chance >= Game::CRIT_SCALE, 'certainty or better'
  # A chance at or over the scale must land on every roll, whatever the seed.
  5.times do |i|
    slime = combatant('Slime', 0, 0, 5, 100_000)
    bat = Game::Battle.new([Game::Battle.from_actor(hero)], [slime],
                           Game::Rng.new(i + 1), nil, false, true)
    bat.begin_round
    eq true, bat.step_action[:critical], "seed #{i + 1}"
  end
end

# An Rng that always answers the same number, so a roll's boundary can be read
# off exactly instead of inferred from a sample.
class FixedRng
  def initialize(value); @value = value; end
  def random(n); n <= 0 ? 0 : @value % n; end
  # The crit roll draws through #scaled; a fixture pinning an exact roll wants
  # that value handed back untouched rather than rescaled.
  def scaled(scale); scale <= 0 ? 0 : @value % scale; end
end

check 'battle: the crit roll is read against the basis-point scale' do
  # A rate of N must crit on a roll of N-1 and not on N. This is what says the
  # chance is a probability over CRIT_SCALE rather than a denominator: 5000 bp
  # and "1 in 2" sample the same, but only one of them answers this.
  [[4999, true], [5000, false], [5001, false]].each do |roll, want|
    hero = combatant('Hero', 40, 0, 20, 100)
    hero.crit_chance = 5000
    slime = combatant('Slime', 0, 0, 5, 100_000)
    bat = Game::Battle.new([hero], [slime], FixedRng.new(roll), nil, false, true)
    bat.begin_round
    eq want, bat.step_action[:critical], "a 5000 bp rate on a roll of #{roll}"
  end
end

check 'battle: the crit rate is the chance, not a 1-in-N denominator' do
  # A 2500 bp battler crits about a quarter of the time; the old model could
  # only have said "1 in 4" and had no way to add a weapon's 20% to it.
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.crit_chance = 2500
  crits = 0
  400.times do |i|
    h = combatant('Hero', 40, 0, 20, 100)
    h.crit_chance = 2500
    slime = combatant('Slime', 0, 0, 5, 100_000)
    bat = Game::Battle.new([h], [slime], Game::Rng.new(i + 1), nil, false, true)
    bat.begin_round
    crits += 1 if bat.step_action[:critical]
  end
  ok crits > 60 && crits < 140,
     "expected roughly a quarter of 400 swings to crit, got #{crits}"
end

check 'battle: gear that prevents criticals blocks the 3x hit' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.crit_chance = Game::CRIT_SCALE                # would always crit...
  slime = combatant('Slime', 0, 0, 5, 100_000)
  slime.prevents_crit = true                         # ...but the target is guarded
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, true)
  bat.begin_round
  e = bat.step_action
  eq 20, e[:damage]                                  # base, crit blocked
  ok !e[:critical]
end

check 'Actor#prevents_critical? reads equipped prevent-critical gear' do
  items = { 8 => fake_item(type: 2, prevent_crit: true) } # a piece of armour
  st = item_party(items)
  a = st.party.actor_by_id(1)
  eq false, a.prevents_critical?                     # nothing equipped yet
  a.equip([0, 8, 0, 0, 0])                           # equip item 8
  eq true, a.prevents_critical?
  eq true, Game::Battle.from_actor(a).prevents_crit  # carried onto the combatant
end

# -- Battle elemental attributes ----------------------------------------------
# A weapon / skill carries a set of elements; the target's per-element rank
# (0=A weakest .. 4=E immune) scales the damage 200/150/100/50/0 percent.

check 'battle: an element the target is weak to amplifies the damage (rank A = 300%)' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.atk_attrs = [1]                               # weapon carries element 1
  slime = combatant('Slime', 0, 0, 5, 100_000)
  slime.attr_ranks = { 1 => 0 }                      # rank A -> 300% (RPG2000 default)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1)) # variance off
  bat.begin_round
  eq 60, bat.step_action[:damage]                    # base 20 * 300%
end

check 'battle: an element the target resists halves the damage (rank D = 50%)' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.atk_attrs = [1]
  slime = combatant('Slime', 0, 0, 5, 100_000)
  slime.attr_ranks = { 1 => 3 }                      # rank D -> 50%
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  bat.begin_round
  eq 10, bat.step_action[:damage]
end

check 'battle: an element the target is immune to deals no damage (rank E = 0%)' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.atk_attrs = [1]
  slime = combatant('Slime', 0, 0, 5, 100)
  slime.attr_ranks = { 1 => 4 }                      # rank E -> 0%
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  bat.begin_round
  e = bat.step_action
  eq 0, e[:damage]
  eq 100, slime.hp, 'no HP lost'
  ok !e[:defeated]
end

check 'battle: the attribute multiplier takes the strongest matching element' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.atk_attrs = [1, 2]                             # two elements
  slime = combatant('Slime', 0, 0, 5, 100_000)
  slime.attr_ranks = { 1 => 3, 2 => 0 }              # resists 1 (50%), weak to 2 (300%)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  bat.begin_round
  eq 60, bat.step_action[:damage]                    # max(50%, 300%) -> 60
end

check 'battle: an unlisted element deals full (C = 100%) damage' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.atk_attrs = [5]                               # slime lists no rank for 5
  slime = combatant('Slime', 0, 0, 5, 100_000)
  slime.attr_ranks = { 1 => 0 }
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  bat.begin_round
  eq 20, bat.step_action[:damage]                    # unchanged base
end

check 'battle: an elemental skill scales its damage by the target resistance' do
  mage = combatant_mp('Mage', 10, 0, 20, 100, 30)
  slime = combatant('Slime', 0, 0, 5, 100_000)
  slime.attr_ranks = { 3 => 0 }                      # weak to element 3 (300%)
  bat = Game::Battle.new([mage], [slime], Game::Rng.new(1)) # variance off
  bat.command_skill(mage, slime, name: 'Flame', cost: 0, hp: -30, attributes: [3])
  bat.begin_round
  eq 90, bat.step_action[:damage]                    # 30 * 300%
end

# A property/state row carrying the RPG2000 A..E rank rates (property table).
RateRow = Struct.new(:a_rate, :b_rate, :c_rate, :d_rate, :e_rate)

check "battle: a database attribute's own rank rates override the defaults" do
  props = { 1 => RateRow.new(250, 180, 100, 40, 0) } # element 1: rank A = 250%
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.atk_attrs = [1]
  slime = combatant('Slime', 0, 0, 5, 100_000)
  slime.attr_ranks = { 1 => 0 }                      # rank A
  # 9-arg: the attribute (property) table is the last arg.
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, false,
                         false, false, props)
  bat.begin_round
  eq 50, bat.step_action[:damage]                    # 20 * 250% (its own rate, not 300)
end

check "battle: a database state's own rank rate gates the infliction" do
  # A hardy status: state 3 is 0% at *every* rank, so even a fully-susceptible
  # (rank A) target never catches it — the DB rate overrides the 100% default.
  states = { 3 => RateRow.new(0, 0, 0, 0, 0) }
  mage = combatant_mp('Mage', 10, 0, 20, 100, 30)
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.state_ranks = { 3 => 0 }                       # nominally fully susceptible
  b = Game::Battle.new([mage], [foe], Game::Rng.new(1), states)
  b.command_skill(mage, foe, name: 'Poison', cost: 0, hp: -1, inflict: [3], chance: 100)
  b.begin_round
  e = b.step_action
  eq [], e[:inflicted], "the database rate (0%) overrides the rank-A default"
  ok !foe.state?(3)
end

check 'Party#battle_skill_command carries the skill elemental attributes' do
  skills = { 7 => fake_skill(name: 'Ice', scope: 0, power: 20, mrate: 40,
                             attribute_effects: [false, false, true]) } # element 3
  st = skill_party(skills)
  mage = Game::Battle.from_actor(st.party.actor_by_id(1))
  slime = combatant('Slime', 0, 0, 5, 100)
  c = st.party.battle_skill_command(st.party.db_skill(7), mage, slime)
  eq [3], c[:attributes]
end

check 'Actor weapon/attribute readers feed the combatant snapshot' do
  items = { 7 => fake_item(type: 1, atk: 10, attribute_set: [true, false, true]) }
  st = item_party(items)                             # elements 1 & 3 on the weapon
  a = st.party.actor_by_id(1)
  eq [], a.weapon_attributes, 'nothing equipped yet'
  a.equip([7, 0, 0, 0, 0])
  eq [1, 3], a.weapon_attributes
  eq [1, 3], Game::Battle.from_actor(a).atk_attrs, 'carried onto the combatant'
end

check 'Game::Enemy reads its per-attribute defence ranks' do
  ranks_row = Struct.new(:name, :max_hp, :max_sp, :attack, :defense, :spirit,
                         :agility, :exp, :gold, :attribute_ranks)
  db = BattleDB.new({ 5 => ranks_row.new('Golem', 100, 0, 10, 10, 5, 3, 20, 50,
                                          [2, 4, 0]) }, {})
  e = Game::Enemy.new(db, 5)
  eq({ 1 => 2, 2 => 4, 3 => 0 }, e.attribute_ranks)
  eq({ 1 => 2, 2 => 4, 3 => 0 }, Game::Battle.from_enemy(e).attr_ranks)
end

# -- Battle escape ------------------------------------------------------------

def escape_battle(party_agi, enemy_agi, seed = 1)
  Game::Battle.new([combatant('Hero', 0, 0, party_agi, 10)],
                   [combatant('Slime', 8, 0, enemy_agi, 10)], Game::Rng.new(seed))
end

check 'Battle#escape_chance scales with the agility ratio, clamped 0..100' do
  eq 50,  escape_battle(10, 10).escape_chance, 'equal agility -> 150 - 100 = 50'
  eq 100, escape_battle(20, 5).escape_chance,  'a much faster party clamps at 100'
  eq 0,   escape_battle(5, 20).escape_chance,  'a much slower party clamps at 0'
end

check 'Battle#attempt_escape flees the fight when the roll succeeds' do
  b = escape_battle(20, 5)                            # 100% chance
  ok b.attempt_escape, 'a 100% chance always flees'
  ok b.finished?, 'the fight is over'
  ok b.escaped?, 'flagged as escaped'
  eq :escaped, b.run, 'and the result stays :escaped'
end

check 'a failed escape raises the next attempt chance by 10, fight continues' do
  b = escape_battle(5, 20)                            # 0% chance -> always fails
  eq 0, b.escape_chance, 'a much slower party starts at 0%'
  ok !b.attempt_escape, 'and cannot flee'
  eq 10, b.escape_chance, 'but the next attempt is 10 points likelier'
  ok !b.finished?, 'the fight is still on'
  ok !b.escaped?
end

check 'a preemptive escape always succeeds regardless of the roll' do
  b = escape_battle(5, 20)                            # 0% by agility...
  ok b.attempt_escape(true), '...but a first strike guarantees the getaway'
  eq :escaped, b.result
end

check 'attempt_escape is a no-op once the battle is already decided' do
  hero = combatant('Hero', 40, 0, 20, 100)
  downed = combatant('Slime', 0, 0, 5, 0)            # already wiped -> victory
  b = Game::Battle.new([hero], [downed], Game::Rng.new(1))
  ok b.finished?, 'enemies already down'
  ok !b.attempt_escape, 'no escape from a decided fight'
  ok !b.escaped?
end

check 'command_skip forfeits an ally turn while the enemies still act' do
  hero = combatant('Hero', 40, 0, 20, 100)           # faster, acts first
  slime = combatant('Slime', 20, 0, 5, 100)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  b.command_skip(hero)
  b.run_round
  eq 100, slime.hp, 'the hero forfeited its attack'
  ok hero.hp < 100, 'but the slime still struck back'
end

# -- Battle hit / miss (accuracy) ---------------------------------------------

check 'Battle#to_hit uses the base hit rate adjusted by the agility ratio' do
  b = Game::Battle.new([combatant('H', 0, 0, 10, 10)],
                       [combatant('E', 0, 0, 10, 10)], Game::Rng.new(1))
  atk = b.allies.first
  tgt = b.enemies.first
  atk.hit_rate = 90
  eq 90, b.to_hit(atk, tgt), 'equal agility -> the base hit rate'
  tgt.agi = 30                                       # a 3x faster target dodges more
  eq 80, b.to_hit(atk, tgt), '100 - 10*(10+30)/(2*10) = 80'
  tgt.agi = 0                                        # a motionless target
  eq 95, b.to_hit(atk, tgt), '100 - 10*(10+0)/(2*10) = 95'
end

check 'Battle#to_hit clamps to 0..100 and a 100% base never misses' do
  b = Game::Battle.new([combatant('H', 0, 0, 10, 10)],
                       [combatant('E', 0, 0, 999, 10)], Game::Rng.new(1))
  atk = b.allies.first
  atk.hit_rate = 100
  eq 100, b.to_hit(atk, b.enemies.first), 'a perfect base stays 100 despite fast target'
end

check 'with accuracy off a basic attack always connects' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.hit_rate = 1                                  # would nearly always miss...
  slime = combatant('Slime', 0, 0, 20, 100)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1)) # accuracy off (default)
  b.begin_round
  e = b.step_action
  eq 20, e[:damage], '...but accuracy is off, so it lands for full damage'
  ok !e[:missed]
end

check 'with accuracy on a sure-miss attack deals no damage' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.hit_rate = 0                                  # 0% base, equal agility -> 0% hit
  slime = combatant('Slime', 0, 0, 20, 100)
  # 7-arg: variance off, criticals off, accuracy on.
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, false, true)
  b.begin_round
  e = b.step_action
  eq 0, e[:damage]
  ok e[:missed], 'flagged as a miss'
  eq 100, slime.hp, 'no HP lost'
end

check 'with accuracy on the to-hit roll both lands and misses over many swings' do
  hero = combatant('Hero', 40, 0, 10, 1_000_000)
  hero.hit_rate = 50                                 # equal agility -> 50% to hit
  slime = combatant('Slime', 0, 0, 10, 1_000_000)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, false, true)
  40.times { b.run_round }
  swings = b.log.select { |e| e[:attacker] == 'Hero' }
  ok swings.any? { |e| e[:missed] }, 'a 50% attacker whiffs sometimes'
  ok swings.any? { |e| !e[:missed] }, 'and connects sometimes'
end

# -- Battle first strike (pre-emptive) ----------------------------------------

check 'battle first strike: the party acts while the enemies skip round 1' do
  hero = combatant('Hero', 40, 0, 5, 100)            # slower than the slime...
  slime = combatant('Slime', 40, 0, 50, 100)         # ...which would normally go first
  # 8-arg: variance / criticals / accuracy off, first_strike on.
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, false, false, true)
  entries = b.run_round
  eq 1, entries.length, 'only the party acts in the opening round'
  eq 'Hero', entries.first[:attacker], 'the hero strikes first despite lower agility'
  eq 100, hero.hp, 'the ambushed slime never swung'
  eq 80, slime.hp, 'but the hero connected'
end

check 'battle first strike: the enemies rejoin from the second round' do
  hero = combatant('Hero', 8, 0, 5, 100)
  slime = combatant('Slime', 40, 0, 50, 100)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1), nil, false, false, false, true)
  b.run_round                                        # round 1: only the hero
  eq 100, hero.hp, 'no enemy action in the pre-emptive round'
  b.run_round                                        # round 2: the slime strikes back
  ok hero.hp < 100, 'the enemy acts normally from round 2'
end

check 'battle without first strike: both sides act in the opening round' do
  hero = combatant('Hero', 8, 0, 5, 100)
  slime = combatant('Slime', 8, 0, 50, 100)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1)) # no first strike
  eq 2, b.run_round.length, 'both battlers act in round 1'
end

# -- Battle all-target skill scopes -------------------------------------------

check 'battle: an all-enemy skill strikes every living foe, spending SP once' do
  mage = combatant_mp('Mage', 10, 0, 20, 100, 30)    # fast: acts first
  s1 = combatant('S1', 0, 0, 5, 100)
  s2 = combatant('S2', 0, 0, 5, 100)
  b = Game::Battle.new([mage], [s1, s2], Game::Rng.new(1))
  b.command_skill_all(mage, [{ target: s1, hp: -20 }, { target: s2, hp: -20 }],
                      name: 'Blizzard', cost: 6)
  b.begin_round
  e1 = b.step_action                                 # first hit surfaced now...
  e2 = b.step_action                                 # ...second from the buffer
  eq ['S1', 'S2'], [e1[:target], e2[:target]]
  eq [20, 20], [e1[:damage], e2[:damage]]
  eq [80, 80], [s1.hp, s2.hp]
  eq 24, mage.mp, 'the SP cost is charged once for the whole volley'
end

check 'battle: an all-ally heal restores every living member' do
  healer = combatant_mp('Healer', 10, 0, 20, 100, 30)
  a1 = combatant('A1', 0, 0, 5, 100); a1.hp = 40
  a2 = combatant('A2', 0, 0, 5, 100); a2.hp = 30
  b = Game::Battle.new([healer, a1, a2], [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  b.command_skill_all(healer, [{ target: a1, hp: 30 }, { target: a2, hp: 30 }],
                      name: 'Heal All', cost: 8)
  b.begin_round
  e1 = b.step_action
  b.step_action
  ok e1[:recover], 'reads as a recovery'
  eq [70, 60], [a1.hp, a2.hp]
  eq 22, healer.mp
end

check 'battle: an all-enemy skill skips foes already down' do
  mage = combatant_mp('Mage', 10, 0, 20, 100, 30)
  downed = combatant('Downed', 0, 0, 5, 0)           # already KO'd
  alive = combatant('Alive', 0, 0, 5, 100)
  b = Game::Battle.new([mage], [downed, alive], Game::Rng.new(1))
  b.command_skill_all(mage, [{ target: downed, hp: -20 }, { target: alive, hp: -20 }],
                      name: 'Blizzard', cost: 6)
  b.begin_round
  e = b.step_action
  eq 'Alive', e[:target], 'only the living foe is struck'
  ok b.log.none? { |x| x[:target] == 'Downed' }, 'the downed foe is skipped'
  eq 80, alive.hp
  eq 24, mage.mp
end

check 'battle: an all-ally skill fizzles and spares SP when every target is down' do
  healer = combatant_mp('Healer', 10, 0, 20, 100, 30)
  downed = combatant('Downed', 0, 0, 5, 0)           # the only target, already KO'd
  b = Game::Battle.new([healer, downed], [combatant('Foe', 0, 0, 1, 100)], Game::Rng.new(1))
  b.command_skill_all(healer, [{ target: downed, hp: 30 }], name: 'Heal', cost: 8)
  b.run_round
  eq 30, healer.mp, 'a fizzled all-ally heal spends no SP'
  ok b.log.none? { |x| x[:recover] }, 'nothing was healed'
end

check 'battle: run_round surfaces every hit of an all-enemy volley' do
  mage = combatant_mp('Mage', 10, 0, 50, 100, 30)    # fastest: acts first
  s1 = combatant('S1', 0, 0, 5, 100)
  s2 = combatant('S2', 0, 0, 5, 100)
  b = Game::Battle.new([mage], [s1, s2], Game::Rng.new(1))
  b.command_skill_all(mage, [{ target: s1, hp: -20 }, { target: s2, hp: -20 }],
                      name: 'Blizzard', cost: 6)
  hits = b.run_round.select { |e| e[:skill] == 'Blizzard' }
  eq 2, hits.length, 'both foes appear in the round log'
end

# -- Battle all-party items ---------------------------------------------------

check 'battle: an all-party item heals every ally and is consumed once' do
  healer = combatant('Healer', 0, 0, 20, 100)        # acts first
  a1 = combatant('A1', 0, 0, 5, 100); a1.hp = 40
  a2 = combatant('A2', 0, 0, 5, 100); a2.hp = 50
  b = Game::Battle.new([healer, a1, a2], [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  b.command_item_all(healer, [{ target: a1, hp: 30 }, { target: a2, hp: 30 }],
                     item_id: 5, name: 'Party Potion')
  b.begin_round
  e1 = b.step_action
  e2 = b.step_action
  eq 5, e1[:item_id], 'the first hit consumes the item'
  eq nil, e2[:item_id], 'the rest do not — one item for the whole volley'
  eq [70, 80], [a1.hp, a2.hp]
  ok e1[:recover] && e2[:recover]
end

check 'battle: an all-party antidote cures the status from each afflicted ally' do
  healer = combatant('Healer', 0, 0, 20, 100)
  a1 = combatant('A1', 0, 0, 5, 100); a1.states = [3]
  a2 = combatant('A2', 0, 0, 5, 100); a2.states = [3, 4]
  b = Game::Battle.new([healer, a1, a2], [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  b.command_item_all(healer, [{ target: a1, hp: 0 }, { target: a2, hp: 0 }],
                     item_id: 6, name: 'Party Antidote', cured: [3])
  b.begin_round
  b.step_action; b.step_action
  ok !a1.state?(3), 'a1 is cured'
  ok !a2.state?(3), 'a2 is cured'
  ok a2.state?(4), 'a2 keeps its other status'
end

check 'Party#item_all_allies? flags a whole-party item (scope 1)' do
  st = item_party({ 5 => fake_item(type: 6, scope: 1, rhp: 20),
                    6 => fake_item(type: 6, scope: 0, rhp: 20) })
  ok st.party.item_all_allies?(st.party.db_item(5)), 'scope 1 -> all allies'
  ok !st.party.item_all_allies?(st.party.db_item(6)), 'scope 0 -> single ally'
end

check 'battle skill damage varies by the skill variance when the fight rolls it' do
  skills = { 7 => fake_skill(name: 'Fire', scope: 0, sp_cost: 0, power: 20,
                             mrate: 40, variance: 4) }
  st = skill_party(skills)
  mage = Game::Battle.from_actor(st.party.actor_by_id(1))    # spi 12 -> effect 32
  slime = combatant('Slime', 0, 0, 5, 100_000)               # def 0, tanky
  bat = Game::Battle.new([mage], [slime], Game::Rng.new(1), nil, true) # variance on
  c = st.party.battle_skill_command(st.party.db_skill(7), mage, slime) # base 32
  dmgs = []
  20.times do
    bat.command_skill(mage, slime, name: 'Fire', cost: c[:cost], hp: c[:hp],
                      mp: c[:mp], inflict: c[:inflict], chance: c[:chance],
                      variance: c[:variance])
    e = bat.run_round.find { |x| x[:skill] == 'Fire' }
    dmgs << e[:damage] if e
    break if bat.finished?
  end
  # base 32, var 4 -> adj = 12, spread 32-6 .. 32+12-6 = 26..38.
  ok dmgs.uniq.length > 1, "skill damage varies (#{dmgs.uniq.sort.inspect})"
  ok dmgs.all? { |d| d >= 26 && d <= 38 }, "within 26..38 (#{dmgs.inspect})"
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

check 'Battle: a commanded attack hits the chosen enemy; run_round clears it' do
  hero = combatant('Hero', 40, 0, 20, 100)
  a = combatant('A', 0, 0, 5, 100) # harmless, slow enemies
  b = combatant('B', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [a, b], Game::Rng.new(1))
  bat.command_attack(hero, b) # target B specifically
  bat.run_round
  eq 100, a.hp, 'A was not the chosen target'
  eq 80, b.hp, 'B took 20 damage (40/2 - 0/4)'
  eq nil, hero.action, 'the command is cleared for the next round'
end

check 'Battle: a defending ally takes half damage and does not attack' do
  hero = combatant('Hero', 40, 0, 1, 100) # slow, so the foe acts first
  foe = combatant('Foe', 40, 0, 20, 100)  # 40/2 = 20 damage, halved to 10
  bat = Game::Battle.new([hero], [foe], Game::Rng.new(1))
  bat.command_defend(hero)
  bat.run_round
  eq 100, foe.hp, 'the defending hero did not strike back'
  eq 90, hero.hp, 'took half of 20 = 10'
end

check 'Battle#apply_to_party writes post-battle HP back, KOing at 0' do
  st = party_state
  hero = st.party.actor_by_id(1)   # hp 100
  ally = st.party.actor_by_id(2)   # hp 50
  hc = Game::Battle.from_actor(hero)
  ac = Game::Battle.from_actor(ally)
  hc.hp = 30                       # hero ended the fight wounded
  hc.mp = 12                       # ...and spent some SP on a battle skill
  ac.hp = -5                       # ally was knocked out
  bat = Game::Battle.new([hc, ac], [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  bat.apply_to_party
  eq 30, hero.hp                   # damage persisted to the real actor
  eq 12, hero.mp                   # SP spent in battle persisted too
  eq false, hero.dead?
  eq 0, ally.hp                    # clamped to 0
  eq true, ally.dead?
  eq true, ally.state?(Game::Actor::DEATH_STATE)  # a KO inflicts 戦闘不能
end

check 'Battle#apply_to_party revives a previously-downed actor that survives' do
  st = party_state
  ally = st.party.actor_by_id(2)
  ally.change_hp(-9999)            # currently KO'd from a prior fight
  eq true, ally.dead?
  c = Game::Battle.from_actor(ally)
  c.hp = 20                        # ...took part in a fight and came out at 20 HP
  bat = Game::Battle.new([c], [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  bat.apply_to_party
  eq 20, ally.hp
  eq false, ally.dead?
  eq false, ally.state?(Game::Actor::DEATH_STATE)  # revived, death state cleared
end

check 'Battle#apply_to_party ignores combatants with no source actor' do
  # A bare snapshot (from_enemy / test combatant) must not raise on write-back.
  bat = Game::Battle.new([combatant('Ghost', 10, 0, 5, 0)],
                         [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  bat.apply_to_party                # no source actor -> silently skipped
  ok true, 'write-back skipped bare combatants without error'
end

check 'Battle#step_action walks a round one attack at a time for animation' do
  # Two fast heroes vs two slow slimes: agility order is Ace, Bee, then the
  # slimes. #step_action surfaces the round one entry at a time (as the on-screen
  # battle animates), mutating a single battler's HP per call, then signals the
  # round boundary with nil without starting a new round.
  ace = combatant('Ace', 40, 0, 20, 100)
  bee = combatant('Bee', 40, 0, 15, 100)
  s1 = combatant('S1', 4, 0, 5, 100)
  s2 = combatant('S2', 4, 0, 5, 100)
  bat = Game::Battle.new([ace, bee], [s1, s2], Game::Rng.new(1))
  bat.command_attack(ace, s1)
  bat.command_attack(bee, s2)
  bat.begin_round

  e1 = bat.step_action
  eq 'Ace', e1[:attacker], 'the faster hero acts first'
  eq 'S1', e1[:target]
  eq 80, s1.hp, 'only S1 has been hit so far'
  eq 100, s2.hp, 'the second attack has not landed yet'

  e2 = bat.step_action
  eq 'Bee', e2[:attacker]
  eq 'S2', e2[:target]
  eq 80, s2.hp, 'now the second attack has landed'

  # The two slimes retaliate (they act after the faster heroes), one per step.
  e3 = bat.step_action
  eq 'S1', e3[:attacker], 'the slimes act after the heroes, in agility order'
  e4 = bat.step_action
  eq 'S2', e4[:attacker]

  eq nil, bat.step_action, 'the round is exhausted without starting a new one'
  eq 1, bat.rounds, 'and no fresh round was primed (still round 1)'

  bat.end_round
  eq nil, ace.action, 'end_round clears the commands for the next round'
  eq nil, bee.action
end

check 'Battle#step_action skips a defending ally (no attack, no log entry)' do
  # A defending ally produces no action entry, so the animation simply does not
  # step for them — only the foe's retaliation shows.
  hero = combatant('Hero', 40, 0, 20, 100)
  foe = combatant('Foe', 20, 0, 5, 100)
  bat = Game::Battle.new([hero], [foe], Game::Rng.new(1))
  bat.command_defend(hero)
  bat.begin_round
  entry = bat.step_action
  eq 'Foe', entry[:attacker], 'the defending hero is skipped; only the foe acts'
  eq nil, bat.step_action, 'nothing else to animate this round'
end

# -- Battle Skill / Item commands ---------------------------------------------

check 'battle_skills lists the caster\'s battle-usable skills with SP cost' do
  skills = {
    7  => fake_skill(name: 'Fire', scope: 0, sp_cost: 6, power: 20, mrate: 40),
    8  => fake_skill(name: 'Heal', scope: 3, sp_cost: 5, power: 20, mrate: 40, hp: true),
    9  => fake_skill(name: 'Guard', scope: 2, sp_cost: 3, power: 10, hp: true),
    # `occasion_battle` off does *not* keep an ordinary skill out of a fight:
    # RPG2000 reads that flag for switch skills only, and once a battle is
    # running every other skill is usable. Skill 13 is a switch skill, which is
    # the one kind the flag really does exclude.
    10 => fake_skill(name: 'NotFlagged', scope: 3, sp_cost: 4, hp: true, occ_battle: false),
    11 => fake_skill(name: 'AllFoes', scope: 1, sp_cost: 8, power: 20),  # all enemies
    12 => fake_skill(name: 'AllHeal', scope: 4, sp_cost: 7, power: 20, hp: true), # all allies
    13 => fake_skill(name: 'Summon', type: 3, sp_cost: 2, occ_battle: false)
  }
  st = skill_party(skills)
  hero = st.party.actor_by_id(1)
  [7, 8, 9, 10, 11, 12, 13].each { |s| hero.learn_skill(s) }
  caster = Game::Battle.from_actor(hero)
  eq [[7, 6], [8, 5], [9, 3], [10, 4], [11, 8], [12, 7]],
     st.party.battle_skills(hero, caster),
     'every ordinary skill, in id order; the unflagged switch skill excluded'
  eq :enemy,     st.party.battle_skill_target(st.party.db_skill(7))
  eq :ally,      st.party.battle_skill_target(st.party.db_skill(8))
  eq :self,      st.party.battle_skill_target(st.party.db_skill(9))
  eq :all_enemy, st.party.battle_skill_target(st.party.db_skill(11))
  eq :all_ally,  st.party.battle_skill_target(st.party.db_skill(12))
end

check 'battle_skill_command yields attack damage, ally heal and self recovery' do
  skills = {
    7 => fake_skill(name: 'Fire', scope: 0, sp_cost: 6, power: 20, mrate: 40),
    8 => fake_skill(name: 'Heal', scope: 3, sp_cost: 5, power: 20, mrate: 40, hp: true),
    9 => fake_skill(name: 'Cure', scope: 2, sp_cost: 4, power: 10, mrate: 40,
                    hp: true, sp: true)
  }
  st = skill_party(skills)
  caster = Game::Battle.from_actor(st.party.actor_by_id(1)) # atk 10, spi 12, maxSP 30
  foe = combatant('Foe', 0, 8, 5, 100)                      # def 8
  foe.spi = 16
  # skill_effect = 20 + 40*12/40 = 32. Fire is purely magical (physical_rate 0,
  # magical_rate 40), so RPG_RT blunts it with the target's *spirit* and not at
  # all with its armour: 32 - (0*8/40 + 40*16/80) = 32 - 8 = 24.
  eq({ cost: 6, hp: -24, mp: 0, inflict: [], chance: 100, variance: 4,
       attributes: [], absorb: false },
     st.party.battle_skill_command(st.party.db_skill(7), caster, foe))
  eq({ cost: 5, hp: 32, mp: 0 },
     st.party.battle_skill_command(st.party.db_skill(8), caster, nil))
  # Cure affects HP and SP: effect = 10 + 40*12/40 = 22
  eq({ cost: 4, hp: 22, mp: 22 },
     st.party.battle_skill_command(st.party.db_skill(9), caster, nil))
end

check 'a battle attack skill inflicts its state_effects on a surviving enemy' do
  skills = { 7 => fake_skill(name: 'Poison Sting', scope: 0, sp_cost: 3, power: 20,
                             mrate: 40, state_effects: [0, 0, 1], hit: 100) }
  st = skill_party(skills)
  mage = Game::Battle.from_actor(st.party.actor_by_id(1))
  foe = combatant('Foe', 0, 0, 5, 100)
  c = st.party.battle_skill_command(st.party.db_skill(7), mage, foe)
  eq [3], c[:inflict], 'state_effects -> state id 3'
  eq 100, c[:chance]
  bat = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  bat.command_skill(mage, foe, name: 'Poison Sting', cost: c[:cost],
                    hp: c[:hp], mp: c[:mp], inflict: c[:inflict], chance: c[:chance])
  bat.run_round
  eq true, foe.state?(3)                        # inflicted on the surviving enemy
end

check 'a battle attack skill at 0% accuracy never inflicts its state' do
  skills = { 7 => fake_skill(name: 'Dud', scope: 0, sp_cost: 3, power: 20,
                             mrate: 40, state_effects: [0, 0, 1], hit: 0) }
  st = skill_party(skills)
  mage = Game::Battle.from_actor(st.party.actor_by_id(1))
  foe = combatant('Foe', 0, 0, 5, 100)
  c = st.party.battle_skill_command(st.party.db_skill(7), mage, foe)
  eq 0, c[:chance]
  bat = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  bat.command_skill(mage, foe, name: 'Dud', cost: c[:cost], hp: c[:hp], mp: c[:mp],
                    inflict: c[:inflict], chance: c[:chance])
  bat.run_round
  eq false, foe.state?(3)                        # 0% -> never lands
end

check 'a skill-inflicted "do nothing" state then skips the enemy turn' do
  # Sleep inflicts state 4; the state table marks 4 as restriction 1 (do nothing).
  skills = { 7 => fake_skill(name: 'Sleep', scope: 0, sp_cost: 3, power: 1,
                             state_effects: [0, 0, 0, 1], hit: 100) }
  states = { 4 => FakeStateDef.new(1, 0, 0, 0, 0) }
  st = skill_party(skills)
  hero = Game::Battle.from_actor(st.party.actor_by_id(1))
  foe = combatant('Foe', 40, 0, 1, 100)          # slow (acts after the hero)
  bat = Game::Battle.new([hero], [foe], Game::Rng.new(1), states)
  c = st.party.battle_skill_command(st.party.db_skill(7), hero, foe)
  bat.command_skill(hero, foe, name: 'Sleep', cost: c[:cost], hp: c[:hp], mp: c[:mp],
                    inflict: c[:inflict], chance: c[:chance])
  bat.run_round
  eq true, foe.state?(4), 'the foe was put to sleep'
  hp_before = hero.hp
  bat.run_round                                  # next round: the asleep foe skips
  eq hp_before, hero.hp, 'the sleeping foe did not attack'
end

# -- Battle state susceptibility (state_ranks) --------------------------------

def poison_cast(foe, seed = 1)
  mage = combatant_mp('Mage', 10, 0, 20, 100, 30)    # faster -> acts first
  b = Game::Battle.new([mage], [foe], Game::Rng.new(seed))
  b.command_skill(mage, foe, name: 'Poison', cost: 0, hp: -1, inflict: [3], chance: 100)
  b.begin_round
  b.step_action
end

check 'battle: an immune target (state rank E) never catches the status' do
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.state_ranks = { 3 => 4 }                       # rank E -> 0% susceptibility
  e = poison_cast(foe)
  eq [], e[:inflicted], 'immunity blocks a sure-fire status'
  ok !foe.state?(3)
end

check 'battle: a susceptible target (state rank A) catches a sure status' do
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.state_ranks = { 3 => 0 }                       # rank A -> 100%
  e = poison_cast(foe)
  eq [3], e[:inflicted]
  ok foe.state?(3)
end

check 'battle: infliction is unscaled when the target models no state ranks' do
  foe = combatant('Foe', 0, 0, 5, 100)               # state_ranks nil (a bare fixture)
  e = poison_cast(foe)
  eq [3], e[:inflicted], 'a fixture still catches a 100% status'
end

check 'battle: a mid susceptibility (rank C 60%) both lands and resists' do
  rng = Game::Rng.new(1)                             # one RNG across many casts
  results = Array.new(40) do
    foe = combatant('Foe', 0, 0, 5, 100)
    foe.state_ranks = { 3 => 2 }                     # rank C -> 60%
    mage = combatant_mp('Mage', 10, 0, 20, 100, 30)
    b = Game::Battle.new([mage], [foe], rng)
    b.command_skill(mage, foe, name: 'Poison', cost: 0, hp: -1, inflict: [3], chance: 100)
    b.begin_round
    b.step_action[:inflicted]
  end
  ok results.any? { |r| r == [3] }, 'a 60% status sometimes lands'
  ok results.any?(&:empty?), 'and sometimes is resisted'
end

# A state the target already carries is not a silent no-op: RPG_RT reports it as
# a success in the state's own words, and it does so *without* rolling the
# skill's accuracy first.
check 'battle: a status the target already has reports "already", not a landing' do
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.states = [3]
  e = poison_cast(foe)
  eq [], e[:inflicted], 'nothing new landed'
  eq [3], e[:already], 'but the attempt is announced'
  ok foe.state?(3), 'and the state is still there, once'
  eq 1, foe.states.count { |s| s == 3 }, 'not stacked'
end

check 'battle: "already" is reported even at 0% accuracy' do
  skills = { 7 => fake_skill(name: 'Dud', scope: 0, sp_cost: 3, power: 20,
                             mrate: 40, state_effects: [0, 0, 1], hit: 0) }
  st = skill_party(skills)
  mage = Game::Battle.from_actor(st.party.actor_by_id(1))
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.states = [3]
  c = st.party.battle_skill_command(st.party.db_skill(7), mage, foe)
  eq 0, c[:chance]
  bat = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  bat.command_skill(mage, foe, name: 'Dud', cost: c[:cost], hp: c[:hp], mp: c[:mp],
                    inflict: c[:inflict], chance: c[:chance])
  bat.begin_round
  eq [3], bat.step_action[:already], 'the roll is skipped, so it always reports'
end

check 'battle: an immune target that already has the state still reports it' do
  # Susceptibility gates the *roll*, and there is no roll for a state already
  # carried -- a rank-E foe that is somehow already poisoned still says so.
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.state_ranks = { 3 => 4 }
  foe.states = [3]
  e = poison_cast(foe)
  eq [], e[:inflicted]
  eq [3], e[:already]
end

check 'battle: a clear target reports nothing as already' do
  foe = combatant('Foe', 0, 0, 5, 100)
  e = poison_cast(foe)
  eq [3], e[:inflicted]
  eq [], e[:already]
end

check 'Battle command_skill resolves an attack skill: damage lands, SP is spent' do
  mage = combatant_mp('Mage', 0, 0, 20, 100, 10)
  foe  = combatant('Foe', 0, 0, 5, 100)
  b = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  b.command_skill(mage, foe, name: 'Fire', cost: 6, hp: -30)
  b.begin_round
  e = b.step_action
  eq 'Fire', e[:skill], 'the entry names the skill'
  eq 30, e[:damage]
  eq 70, foe.hp
  eq 4, mage.mp, 'the caster paid 6 SP'
  ok e[:skill] && !e[:recover], 'an attack skill reads as an attack, not a recovery'
end

check 'Battle command_skill resolves a heal, clamped to max HP' do
  mage = combatant_mp('Mage', 0, 0, 20, 100, 10)
  ally = combatant('Ally', 0, 0, 5, 50)
  ally.hp = 30
  foe = combatant('Foe', 0, 0, 1, 100)
  b = Game::Battle.new([mage, ally], [foe], Game::Rng.new(1))
  b.command_skill(mage, ally, name: 'Heal', cost: 5, hp: 40) # 30 + 40 clamps at 50
  b.command_defend(ally)
  b.begin_round
  e = b.step_action # the faster mage heals first
  ok e[:recover], 'a recovery entry'
  eq 'Ally', e[:target]
  eq 50, ally.hp, 'clamped to max HP'
  eq 20, e[:recover_hp], 'restored 20 (30 -> 50)'
  eq 5, mage.mp
end

check 'Battle command_skill fizzles on a fallen target, sparing the SP' do
  mage   = combatant_mp('Mage', 0, 0, 20, 100, 10)
  downed = combatant('Downed', 0, 0, 5, 40)
  downed.hp = 0
  foe = combatant('Foe', 0, 0, 1, 100)
  b = Game::Battle.new([mage, downed], [foe], Game::Rng.new(1))
  b.command_skill(mage, downed, name: 'Heal', cost: 5, hp: 32)
  b.begin_round
  e = b.step_action # heal target is down -> fizzles -> the foe's attack surfaces
  ok !e[:recover], 'the heal on a fallen ally did not resolve'
  eq 10, mage.mp, 'no SP was spent on the fizzled cast'
  eq 0, downed.hp, 'the fallen ally stayed down'
end

check 'Battle command_item restores HP and tags the entry for bag consumption' do
  user = combatant('User', 0, 0, 20, 100)
  ally = combatant('Ally', 0, 0, 5, 50)
  ally.hp = 10
  foe = combatant('Foe', 0, 0, 1, 100)
  b = Game::Battle.new([user, ally], [foe], Game::Rng.new(1))
  b.command_item(user, ally, item_id: 5, name: 'Potion', hp: 30)
  b.begin_round
  e = b.step_action
  ok e[:recover]
  eq 5, e[:item_id], 'the item id rides along so the scene consumes it on land'
  eq 'Potion', e[:source]
  eq 40, ally.hp
  eq 30, e[:recover_hp]
end

check 'battle_items lists battle medicines; battle_item_command recovers' do
  items = { 5 => fake_item(type: 6, rhp: 40),                     # battle medicine
            6 => fake_item(type: 6, rhp: 20, field_only: true),   # field-only
            7 => fake_item(type: 1, atk: 5) }                     # a weapon
  st = item_party(items)
  st.party.gain_item(5, 2)
  st.party.gain_item(6, 1)
  st.party.gain_item(7, 1)
  eq [[5, 2]], st.party.battle_items, 'only the battle-flagged medicine'
  ok st.party.battle_usable?(5)
  ok !st.party.battle_usable?(6), 'a field-only medicine is not battle-usable'
  target = combatant('T', 0, 0, 5, 100)
  target.max_mp = 30
  eq({ hp: 40, mp: 0, cured: [] },
     st.party.battle_item_command(st.party.db_item(5), target))
end

check 'a battle item cures the target status; states carry out via apply_to_party' do
  # An antidote (a medicine curing state 3) used in battle on a poisoned ally.
  items = { 5 => fake_item(type: 6, state_set: [0, 0, 1]) }
  st = item_party(items)
  st.party.gain_item(5, 1)
  ally = st.party.actor_by_id(1)
  ally.add_state(3); ally.add_state(9)         # afflicted entering the fight
  c = Game::Battle.from_actor(ally)
  eq true, c.state?(3)                          # the status walked into battle
  bat = Game::Battle.new([c], [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  bat.command_item(c, c, item_id: 5, name: 'Antidote',
                   **st.party.battle_item_command(st.party.db_item(5), c))
  bat.run_round
  eq false, c.state?(3)                         # cured in battle
  eq true, c.state?(9)                          # an unlisted state stays
  bat.apply_to_party
  eq false, ally.state?(3)                      # ...and the cure persisted out
  eq true, ally.state?(9)
end

check 'battle carries an actor status through unchanged when nothing cures it' do
  st = party_state
  hero = st.party.actor_by_id(1)
  hero.add_state(5)                             # afflicted before the fight
  hc = Game::Battle.from_actor(hero)
  eq true, hc.state?(5)
  hc.hp = 40                                    # took some damage on the way
  bat = Game::Battle.new([hc], [combatant('Foe', 0, 0, 1, 1)], Game::Rng.new(1))
  bat.apply_to_party
  eq 40, hero.hp
  eq true, hero.state?(5)                       # the status survived the battle
end


check 'battle poison slips HP each turn (fixed val + percent of max)' do
  states = { 2 => FakeStateDef.new(0, 5, 10, 0, 0) } # 5 + 10% of max HP / turn
  hero = combatant('Hero', 40, 0, 20, 100)           # max HP 100, acts first
  hero.states = [2]
  slime = combatant('Slime', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), states)
  bat.begin_round
  bat.step_action                                    # hero's turn: slip then strike
  eq 85, hero.hp                                     # 100 - (5 + 10) poison
end

check 'battle poison (percent of max) can knock the battler out' do
  states = { 2 => FakeStateDef.new(0, 0, 100, 0, 0) } # 100% of max HP / turn
  hero = combatant('Hero', 0, 0, 1, 50)               # slow so the slip lands
  hero.states = [2]
  foe = combatant('Foe', 0, 0, 99, 100)               # fast but nearly harmless
  bat = Game::Battle.new([hero], [foe], Game::Rng.new(1), states)
  bat.run
  ok hero.dead?, 'the poison finished the hero off'
  eq :defeat, bat.result
end

check 'battle: a "do nothing" state (restriction 1) skips the turn' do
  states = { 3 => FakeStateDef.new(1, 0, 0, 0, 0) }  # asleep / paralysed
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.states = [3]
  slime = combatant('Slime', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), states)
  bat.command_attack(hero, slime)                    # even commanded, it cannot act
  bat.run_round
  eq 100, slime.hp                                   # the asleep hero never struck
end

check 'battle poison slips SP too when the battler has max SP' do
  states = { 4 => FakeStateDef.new(0, 3, 0, 2, 0) }  # 3 HP + 2 SP / turn
  mage = combatant_mp('Mage', 40, 0, 20, 100, 10)
  mage.states = [4]
  slime = combatant('Slime', 0, 0, 5, 100)
  bat = Game::Battle.new([mage], [slime], Game::Rng.new(1), states)
  bat.begin_round
  bat.step_action
  eq 97, mage.hp
  eq 8, mage.mp
end

check 'battle states stay inert without a state-definition lookup' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.states = [2]                                  # afflicted, but no lookup
  slime = combatant('Slime', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1)) # 3-arg: no state defs
  bat.begin_round
  bat.step_action
  eq 100, hero.hp                                    # nothing slipped
end

check 'battle state auto-recovers once it has held past hold_turn' do
  # hold_turn 1, 100% release: eligible only once the counter exceeds 1.
  states = { 5 => FakeStateDef.new(0, 0, 0, 0, 0, 1, 100) }
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.states = [5]
  slime = combatant('Slime', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), states)
  bat.run_round
  eq true, hero.state?(5)                            # turn 1: counter 1, not > 1
  bat.run_round
  eq false, hero.state?(5)                           # turn 2: counter 2 > 1 -> cured
end

check 'battle state at 0% auto_release_prob never wears off on its own' do
  states = { 5 => FakeStateDef.new(0, 0, 0, 0, 0, 0, 0) } # hold 0, prob 0
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.states = [5]
  slime = combatant('Slime', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), states)
  3.times { bat.run_round }
  eq true, hero.state?(5)                            # 0% -> stays for the whole fight
end

check 'battle: a confused battler (restriction 3) attacks its own side' do
  states = { 6 => FakeStateDef.new(3, 0, 0, 0, 0, 0, 0) } # attack-ally (confusion)
  hero = combatant('Hero', 40, 0, 1, 100)                 # slow: the foe acts first
  hero.states = [6]
  slime = combatant('Slime', 0, 0, 5, 100)                # harmless enemy (atk 0)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), states)
  bat.command_attack(hero, slime)                         # commanded at the enemy...
  bat.run_round
  eq 100, slime.hp                                        # ...confusion spared the enemy
  eq 79, hero.hp                                          # slime's 1 + the hero's own 20
end

check 'battle: a berserk battler (restriction 2) attacks despite defending' do
  states = { 7 => FakeStateDef.new(2, 0, 0, 0, 0, 0, 0) } # attack-enemy (berserk)
  hero = combatant('Hero', 40, 0, 20, 100)                # fast: acts first
  hero.states = [7]
  slime = combatant('Slime', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [slime], Game::Rng.new(1), states)
  bat.command_defend(hero)                                # tries to defend...
  bat.run_round
  eq 80, slime.hp                                         # ...but berserk forced a 20 hit
end

# -- the state table's display side (Game::States) ----------------------------
# The simulation acts on state *ids*; putting one on screen needs the row. These
# pin the reading of the row the battle status window and action banner use.

# A state row carrying only the display fields (`fake_state` defaults the
# simulation ones), so a check reads as what it is about.
def display_state(name:, color: Game::States::DEFAULT_COLOR, priority: 50,
                  actor_msg: nil, enemy_msg: nil, recovery_msg: nil)
  fake_state(name: name, color: color, priority: priority,
             actor_msg: actor_msg, enemy_msg: enemy_msg,
             recovery_msg: recovery_msg)
end

check 'States.significant: death outranks everything it is carried with' do
  table = { 1 => display_state(name: 'Down', priority: 10),
            4 => display_state(name: 'Poison', priority: 90) }
  # Priority 90 would otherwise win; state 1 is death, which never loses.
  eq 1, Game::States.significant([4, 1], table)
  eq 1, Game::States.significant([1], table)
  eq 4, Game::States.significant([4], table)
end

check 'States.significant: the highest priority wins, ties to the later id' do
  table = { 2 => display_state(name: 'Poison', priority: 30),
            3 => display_state(name: 'Sleep',  priority: 70),
            5 => display_state(name: 'Silence', priority: 70) }
  eq 3, Game::States.significant([2, 3], table)
  # 3 and 5 tie at 70; RPG_RT walks the table upward keeping the equal one, so
  # the *later* id shows. The battler's own list is in the order the states
  # landed, and must not change the answer.
  eq 5, Game::States.significant([3, 5], table)
  eq 5, Game::States.significant([5, 3], table)
  eq nil, Game::States.significant([], table), 'a clear battler shows no state'
  eq nil, Game::States.significant(nil, table)
end

check 'States.significant: an id the table does not define reads as priority 0' do
  table = { 2 => display_state(name: 'Poison', priority: 30) }
  eq 2, Game::States.significant([2, 9], table), 'the known state outranks it'
  eq 9, Game::States.significant([9], table), 'but alone it is still what shows'
  # With no table at all every state ties at 0, so the highest id shows.
  eq 9, Game::States.significant([2, 9], nil)
end

check 'States.name / color fall back when the row does not say' do
  table = { 2 => display_state(name: 'Poison', color: 2),
            3 => display_state(name: '') }
  eq 'Poison', Game::States.name(2, table)
  eq 2, Game::States.color(2, table)
  eq nil, Game::States.name(3, table), 'a blank name reads as none'
  eq nil, Game::States.name(9, table), '... as does an unknown id'
  eq Game::States::DEFAULT_COLOR, Game::States.color(9, table)
  eq nil, Game::States.name(2, nil)
end

check 'States messages read the row and are worded per side' do
  table = { 2 => display_state(name: 'Poison',
                               actor_msg: ' is poisoned!',
                               enemy_msg: ' succumbs to poison!',
                               recovery_msg: ' is cured of poison.'),
            3 => display_state(name: 'Sleep') }
  # RPG2000 stores the predicate only and prints it straight after the name.
  eq 'Hero is poisoned!', Game::States.inflict_message(2, table, 'Hero', true)
  eq 'Slime succumbs to poison!',
     Game::States.inflict_message(2, table, 'Slime', false)
  eq 'Hero is cured of poison.',
     Game::States.recovery_message(2, table, 'Hero')
  # A database that ships no sentence (an English release) says so, so the
  # caller can compose its own rather than printing a bare name.
  eq nil, Game::States.inflict_message(3, table, 'Hero', true)
  eq nil, Game::States.recovery_message(3, table, 'Hero')
  eq nil, Game::States.inflict_message(2, nil, 'Hero', true)
end

check 'a battle log entry records which side the target was on' do
  # Which wording a state message takes depends on it, and the entry carries
  # only the target's name.
  hero = combatant_mp('Hero', 0, 0, 20, 100, 10)
  foe  = combatant('Foe', 0, 0, 5, 100)
  b = Game::Battle.new([hero], [foe], Game::Rng.new(1))
  b.command_skill(hero, foe, name: 'Fire', cost: 0, hp: -10)
  b.run_round
  hit = b.log.find { |e| e[:skill] == 'Fire' }
  eq false, hit[:target_ally], 'an enemy target is not an ally'

  # A heal aimed at a party member reads the other way. from_actor is what
  # carries the live actor, which is the test the entry records.
  st = party_state
  wounded = st.party.actor_by_id(2)
  wounded.change_hp(-20)
  ally = Game::Battle.from_actor(wounded)
  b2 = Game::Battle.new([ally], [combatant('Foe', 0, 0, 1, 100)], Game::Rng.new(1))
  b2.command_item(ally, ally, item_id: 3, name: 'Potion', hp: 20)
  b2.run_round
  heal = b2.log.find { |e| e[:recover] }
  eq true, heal[:target_ally], 'a party target is an ally'
end

check 'States.map_step_drain: a slip lands only on a multiple of its interval' do
  # mtf-meido-action's Poison, the only state in either test bed that slips on
  # the map: 1 HP every 4 walked tiles.
  table = { 2 => fake_state(name: 'Poison', hp_map_steps: 4, hp_map_val: 1) }
  eq [0, 0], Game::States.map_step_drain(2, table, 1)
  eq [0, 0], Game::States.map_step_drain(2, table, 3)
  eq [1, 0], Game::States.map_step_drain(2, table, 4)
  eq [0, 0], Game::States.map_step_drain(2, table, 5)
  eq [1, 0], Game::States.map_step_drain(2, table, 8)
  # Step 0 is a multiple of every interval, so it has to be excluded outright --
  # otherwise standing still on a fresh map would drain on the first frame.
  eq [0, 0], Game::States.map_step_drain(2, table, 0)
  # The SP half is the same field pair; nothing in either test bed uses it.
  sp = { 3 => fake_state(name: 'Drain', sp_map_steps: 2, sp_map_val: 3) }
  eq [0, 3], Game::States.map_step_drain(3, sp, 2)
  eq [0, 0], Game::States.map_step_drain(3, sp, 3)
end

check 'States.map_step_drain: a half-configured row drains nothing' do
  # A state needs both an interval and an amount. Guarding the interval is also
  # what keeps the modulo off zero, which is how every ordinary state's row
  # arrives -- both fields defaulting to 0.
  table = { 1 => fake_state(name: 'Interval only', hp_map_steps: 4),
            2 => fake_state(name: 'Amount only', hp_map_val: 5),
            3 => fake_state(name: 'Ordinary') }
  eq [0, 0], Game::States.map_step_drain(1, table, 4)
  eq [0, 0], Game::States.map_step_drain(2, table, 4)
  eq [0, 0], Game::States.map_step_drain(3, table, 4)
  eq [0, 0], Game::States.map_step_drain(9, table, 4), 'an id the table lacks'
  eq [0, 0], Game::States.map_step_drain(1, nil, 4), 'no table at all'
end

check 'a walked step slips HP from the afflicted and leaves the clear alone' do
  table = { 2 => fake_state(name: 'Poison', hp_map_steps: 4, hp_map_val: 1) }
  st = party_state
  hero = st.party.actor_by_id(1)
  ally = st.party.actor_by_id(2)
  hero.add_state(2)
  before_hero = hero.hp
  before_ally = ally.hp

  eq [], st.party.apply_map_step_damage(table, 3), 'not a multiple: nobody hit'
  eq before_hero, hero.hp

  hit = st.party.apply_map_step_damage(table, 4)
  eq [hero], hit, 'only the afflicted member is reported'
  eq before_hero - 1, hero.hp
  eq before_ally, ally.hp, 'the clear member does not slip'

  # No table (the seeded harness fixtures) drains nothing rather than raising.
  eq [], st.party.apply_map_step_damage(nil, 4)
end

check 'map slip damage cannot kill: it floors at 1 HP' do
  # RPG_RT wears a poisoned party down and leaves it standing, which is why
  # nothing on this path re-checks for a game over the way the event commands
  # that damage the party do.
  table = { 2 => fake_state(name: 'Poison', hp_map_steps: 1, hp_map_val: 30) }
  st = party_state
  hero = st.party.actor_by_id(1)
  hero.add_state(2)
  hero.set_hp(20)
  st.party.apply_map_step_damage(table, 1)
  eq 1, hero.hp, 'a drain bigger than the remaining HP stops at 1'
  eq false, hero.dead?
  st.party.apply_map_step_damage(table, 2)
  eq 1, hero.hp, 'and walking on keeps it there'
  eq false, st.party.all_dead?

  # A member already down slips nothing at all.
  ally = st.party.actor_by_id(2)
  ally.add_state(2)
  ally.set_hp(0)
  eq [hero], st.party.apply_map_step_damage(table, 3)
end

check 'two slipping states stack rather than the worse one winning' do
  # The battle-side effects pick a single significant state; the map drain is
  # summed, so a doubly-afflicted member loses both amounts on a step that is a
  # multiple of each interval.
  table = { 2 => fake_state(name: 'Poison', hp_map_steps: 2, hp_map_val: 1),
            3 => fake_state(name: 'Bleed', hp_map_steps: 3, hp_map_val: 5,
                            sp_map_steps: 6, sp_map_val: 4) }
  st = party_state
  hero = st.party.actor_by_id(1)
  hero.add_state(2)
  hero.add_state(3)
  hp = hero.hp
  mp = hero.mp

  st.party.apply_map_step_damage(table, 2)
  eq hp - 1, hero.hp, 'step 2: poison only'
  st.party.apply_map_step_damage(table, 3)
  eq hp - 6, hero.hp, 'step 3: bleed only'
  st.party.apply_map_step_damage(table, 6)
  eq hp - 12, hero.hp, 'step 6: both, summed'
  eq mp - 4, hero.mp, 'and the SP half of the same state'
end

check 'the walked-step count advances and round-trips through the save' do
  db = FakeActorDB.new({ 1 => FakePlayerRow.new('Hero', '', 0, 1, max_hp: 10) }, [1])
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  eq 0, st.steps, 'a new game has walked nowhere'
  eq 1, st.walk_step
  eq 3, (st.walk_step; st.walk_step)
  eq 3, st.steps
  eq 3, Game::State.load(db, st.to_h).steps
  # A save written before the counter existed restores 0 rather than nil, which
  # would make the modulo raise on the next step.
  h = st.to_h
  h.delete(:steps)
  eq 0, Game::State.load(db, h).steps
end

check 'battle: a blinding state cuts its victim\'s accuracy by reduce_hit_ratio' do
  # A state's reduce_hit_ratio scales the attacker's to-hit chance. Blind is the
  # status whose whole purpose is this; nothing read the field before, so it did
  # nothing at all.
  states = { 8 => fake_state(reduce_hit_ratio: 50),
             9 => fake_state(reduce_hit_ratio: 20) }
  clear = combatant('Clear', 10, 0, 10, 100)
  blind = combatant('Blind', 10, 0, 10, 100)
  blind.states = [8]
  foe = combatant('Foe', 0, 0, 10, 100)
  bat = Game::Battle.new([clear, blind], [foe], Game::Rng.new(1), states,
                         false, false, true)          # accuracy on
  eq 90, bat.send(:to_hit, clear, foe), 'unhindered: the plain 90% base'
  eq 45, bat.send(:to_hit, blind, foe), 'halved by the state'

  # Several states take the *lowest* ratio, not the product of them.
  blind.states = [8, 9]
  eq 18, bat.send(:to_hit, blind, foe), 'the worst state wins (20%, not 50%*20%)'
end

check 'battle: a normal attack can shake a state off its target' do
  states = { 10 => fake_state(release_by_attack: 100),  # always
             11 => fake_state(release_by_attack: 0) }   # never
  hero = combatant('Hero', 20, 0, 20, 100)
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.states = [10, 11]
  foe.state_turns = {}
  bat = Game::Battle.new([hero], [foe], Game::Rng.new(1), states)
  entry = bat.send(:deal_attack, hero, foe)
  eq [10], entry[:woke], 'the 100% state was shaken off and reported'
  eq false, foe.state?(10)
  eq true, foe.state?(11), 'the 0% state held'

  # A blow that kills leaves the states alone — there is no one left to wake.
  dying = combatant('Dying', 0, 0, 5, 1)
  dying.states = [10]
  dying.state_turns = {}
  bat2 = Game::Battle.new([hero], [dying], Game::Rng.new(1), states)
  e2 = bat2.send(:deal_attack, hero, dying)
  ok e2[:defeated]
  ok e2[:woke].nil?, 'nothing is shaken off a defeated target'
end

check 'battle: a sealing state blocks skills above its threshold' do
  # restrict_magic bars any skill whose magical_rate reaches the level; a purely
  # physical skill (magical_rate 0) is left alone. Both test beds use level 1.
  states = { 12 => fake_state(restrict_magic: true, restrict_magic_level: 1),
             13 => fake_state(restrict_skill: true, restrict_skill_level: 2) }
  magic = fake_skill(name: 'Fire', mrate: 3, prate: 0)
  physical = fake_skill(name: 'Slash', mrate: 0, prate: 4)
  weak_phys = fake_skill(name: 'Tap', mrate: 0, prate: 1)
  hero = combatant('Hero', 10, 0, 10, 100)
  foe = combatant('Foe', 0, 0, 5, 100)
  bat = Game::Battle.new([hero], [foe], Game::Rng.new(1), states)

  hero.states = []
  eq false, bat.skill_sealed?(hero, magic), 'unafflicted: nothing is sealed'
  hero.states = [12]
  eq true, bat.skill_sealed?(hero, magic), 'silence seals the magic skill'
  eq false, bat.skill_sealed?(hero, physical), 'but not the physical one'
  hero.states = [13]
  eq true, bat.skill_sealed?(hero, physical), 'rate 4 reaches the level-2 seal'
  eq false, bat.skill_sealed?(hero, weak_phys), 'rate 1 stays under it'
  eq false, bat.skill_sealed?(hero, nil), 'a missing skill row is not sealed'
end

# -- equipment-granted combat modifiers (ADR 0033) ----------------------------
#
# A party built from a real database row, so the Actor -> Combatant plumbing that
# carries these flags is what is under test, not a hand-set snapshot.
def geared_party(items, strong_defence = false)
  row = CurveRow.new('Hero', '', 0, 1, [200, 50, 20, 10, 10, 10])
  row.strong_defence = strong_defence
  db = FakeActorDB.new({ 1 => row }, [1], items)
  Game::State.new(Game::Party.new(db), 1, 0, 0)
end

check 'battle: a 二刀流 weapon swings twice' do
  items = { 7 => fake_item(type: 1, atk: 5, dual_attack: true),
            8 => fake_item(type: 1, atk: 5) }
  st = geared_party(items)
  hero = st.party.leader
  foe = combatant('Foe', 0, 0, 5, 10_000)

  hero.equip([8, 0, 0, 0, 0])                      # plain weapon
  bat = Game::Battle.new([Game::Battle.from_actor(hero)], [foe], Game::Rng.new(1))
  eq 1, bat.allies[0].strike_count
  entry = bat.send(:swing, bat.allies[0], foe)
  ok entry.is_a?(Hash), 'one swing, one log entry'

  hero.equip([7, 0, 0, 0, 0])                      # 二刀流
  foe2 = combatant('Foe', 0, 0, 5, 10_000)
  bat2 = Game::Battle.new([Game::Battle.from_actor(hero)], [foe2], Game::Rng.new(1))
  eq 2, bat2.allies[0].strike_count
  entries = bat2.send(:swing, bat2.allies[0], foe2)
  eq 2, entries.size, 'two swings, two log entries'
  ok entries[0][:damage] > 0 && entries[1][:damage] > 0

  # The second swing is skipped when the first fells the target.
  dying = combatant('Dying', 0, 0, 5, 1)
  bat3 = Game::Battle.new([Game::Battle.from_actor(hero)], [dying], Game::Rng.new(1))
  e3 = bat3.send(:swing, bat3.allies[0], dying)
  ok e3.is_a?(Hash), 'a felled target is not struck again'
end

check 'battle: a 必中 weapon ignores the target\'s evasion' do
  items = { 7 => fake_item(type: 1, atk: 5, hit: 90, ignore_evasion: true),
            8 => fake_item(type: 1, atk: 5, hit: 90) }
  st = geared_party(items)
  hero = st.party.leader
  swift = combatant('Swift', 0, 0, 999, 100)       # far faster than the hero

  hero.equip([8, 0, 0, 0, 0])
  plain = Game::Battle.new([Game::Battle.from_actor(hero)], [swift],
                           Game::Rng.new(1), nil, false, false, true)
  dodgy = plain.send(:to_hit, plain.allies[0], swift)
  ok dodgy < 90, "a fast target evades (#{dodgy}% < the weapon's 90%)"

  hero.equip([7, 0, 0, 0, 0])
  sure = Game::Battle.new([Game::Battle.from_actor(hero)], [swift],
                          Game::Rng.new(1), nil, false, false, true)
  eq 90, sure.send(:to_hit, sure.allies[0], swift),
     "必中 drops the evasion term, leaving the weapon's own hit rate"
end

check 'battle: 必中 still suffers the wielder\'s own blindness' do
  # What the flag ignores is the *target's* evasion, not a status spoiling the
  # attacker's aim, so Blind still applies on top.
  states = { 3 => fake_state(reduce_hit_ratio: 50) }
  items = { 7 => fake_item(type: 1, atk: 5, hit: 90, ignore_evasion: true) }
  st = geared_party(items)
  hero = st.party.leader
  hero.equip([7, 0, 0, 0, 0])
  swift = combatant('Swift', 0, 0, 999, 100)
  bat = Game::Battle.new([Game::Battle.from_actor(hero)], [swift],
                         Game::Rng.new(1), states, false, false, true)
  bat.allies[0].states = [3]
  eq 45, bat.send(:to_hit, bat.allies[0], swift), 'the weapon is sure, the wielder is blind'
end

check 'battle: 強力防御 halves damage a second time' do
  st = geared_party({}, true)
  hero = st.party.leader
  ok hero.strong_defence?, 'the row carries the flag'
  brute = combatant('Brute', 200, 0, 5, 100)

  [false, true].each_with_index do |flag, i|
    bat = Game::Battle.new([Game::Battle.from_actor(hero)], [brute], Game::Rng.new(1))
    d = bat.allies[0]
    d.strong_defence = flag
    d.defending = true
    before = d.hp
    bat.send(:deal_attack, brute, d)
    @guard_damage ||= []
    @guard_damage[i] = before - d.hp
  end
  ok @guard_damage[0] > 0
  eq @guard_damage[0] / 2, @guard_damage[1],
     'strong defence takes half of what an ordinary guard leaves'
end

check 'MP消費半分 gear halves a skill cost, rounding up' do
  skills = { 1 => fake_skill(sp_cost: 7), 2 => fake_skill(sp_cost: 1),
             3 => fake_skill(sp_type: 1, sp_percent: 20) }
  items = { 9 => fake_item(type: 5, half_sp_cost: true) }  # an accessory
  db = FakeActorDB.new({ 1 => CurveRow.new('Hero', '', 0, 1, [100, 40, 10, 5, 5, 5]) },
                       [1], items, skills)
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  hero = st.party.leader
  eq false, hero.half_sp_cost?
  eq 7, st.party.skill_cost(db.skill[1], hero)
  hero.equip([0, 0, 0, 0, 9])
  ok hero.half_sp_cost?, 'the accessory grants it'
  eq 4, st.party.skill_cost(db.skill[1], hero), '7 -> 4, rounded up'
  eq 1, st.party.skill_cost(db.skill[2], hero), 'a 1-SP skill still costs 1'
  # A percentage cost is halved the same way (20% of 40 max SP = 8 -> 4).
  eq 4, st.party.skill_cost(db.skill[3], hero)
end

check 'Battle end_round clears a queued Skill / Item command' do
  mage = combatant_mp('Mage', 0, 0, 20, 100, 10)
  foe  = combatant('Foe', 0, 0, 5, 100)
  b = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  b.command_skill(mage, foe, name: 'Fire', cost: 6, hp: -30)
  b.run_round
  eq nil, mage.command, 'the command is cleared for the next round'
end

# -- newly-implemented event commands -----------------------------------------

# The opcodes are the numbers real .ldb/.lmu data carries, so a typo here is a
# command the runtime silently ignores. These pin the four that were wrong or
# missing against liblcf's Code enum.
check 'event-command opcodes match the LCF Code enum' do
  eq 10440, IC::CHANGE_SKILLS
  eq 10450, IC::CHANGE_EQUIP
  eq 10500, IC::SIMULATED_ATTACK
  eq 10640, IC::CHANGE_ACTOR_FACE
  eq 10840, IC::ENTER_EXIT_VEHICLE
  eq 11320, IC::FLASH_SPRITE
  eq 11520, IC::FADEOUT_BGM
  eq 11560, IC::PLAY_MOVIE
  eq 11750, IC::TILE_SUBSTITUTION
  eq 11910, IC::OPEN_SAVE_MENU
  eq 11950, IC::OPEN_MAIN_MENU
  eq 12420, IC::GAME_OVER
  eq 12510, IC::RETURN_TO_TITLE
end

check 'Change Skills teaches and removes a skill' do
  st = party_state
  hero = st.party.actor_by_id(1)
  it = Game::Interpreter.new(st)
  # scope 1 (fixed id), actor 1, op 0 (learn), operand const, skill 12
  it.start([FakeCmd.new(IC::CHANGE_SKILLS, [1, 1, 0, 0, 12])])
  it.update
  ok hero.knows_skill?(12), 'the skill was learnt'

  it.start([FakeCmd.new(IC::CHANGE_SKILLS, [1, 1, 1, 0, 12])]) # op 1 = forget
  it.update
  ok !hero.knows_skill?(12), 'the skill was forgotten'
end

check 'Change Skills reads the skill id from a variable and skips id 0' do
  st = party_state
  st.variables[4] = 21
  hero = st.party.actor_by_id(1)
  it = Game::Interpreter.new(st)
  it.start([
    FakeCmd.new(IC::CHANGE_SKILLS, [1, 1, 0, 1, 4]),  # operand type 1 -> var 4
    FakeCmd.new(IC::CHANGE_SKILLS, [1, 1, 0, 0, 0]),  # skill 0 = "none"
  ])
  it.update
  ok hero.knows_skill?(21), 'the variable named the skill'
  ok !hero.knows_skill?(0), 'skill id 0 is ignored'
end

check 'Change Skills applies to the whole party with scope 0' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_SKILLS, [0, 0, 0, 0, 9])])
  it.update
  ok st.party.actors.all? { |a| a.knows_skill?(9) }, 'everyone learnt it'
end

check 'Simulated Attack damages the target by atk less its defence share' do
  st = party_state
  hero = st.party.actor_by_id(1) # def 8, hp 100
  it = Game::Interpreter.new(st)
  # scope 1, actor 1, atk 50, def-weight 400, spi-weight 0, variance 0,
  # store-damage flag 0.
  it.start([FakeCmd.new(IC::SIMULATED_ATTACK, [1, 1, 50, 400, 0, 0, 0, 0])])
  it.update
  eq 58, hero.hp # 100 HP less (50 - 8 * 400 / 400) = 42 damage
end

check 'Simulated Attack stores the damage it dealt in a variable' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::SIMULATED_ATTACK, [1, 1, 30, 0, 0, 0, 1, 6])])
  it.update
  eq 30, st.variables[6]
  eq 70, st.party.actor_by_id(1).hp
end

check 'Simulated Attack floors the damage at zero' do
  st = party_state
  it = Game::Interpreter.new(st)
  # An attack far weaker than the target's defence must heal nobody.
  it.start([FakeCmd.new(IC::SIMULATED_ATTACK, [1, 1, 1, 4000, 0, 0, 1, 2])])
  it.update
  eq 0, st.variables[2]
  eq 100, st.party.actor_by_id(1).hp
end

check 'Change Actor Face overrides the actor FaceSet' do
  st = party_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CHANGE_ACTOR_FACE, [1, 3], string: 'Faces1')])
  it.update
  hero = st.party.actor_by_id(1)
  eq 'Faces1', hero.faceset_name
  eq 3, hero.faceset_index
  ok !it.waiting?, 'Change Actor Face must not pause the interpreter'
end

check 'Enter/Exit Vehicle raises a one-shot toggle request' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::ENTER_EXIT_VEHICLE, [])])
  it.update
  ok !it.waiting?, 'Enter/Exit Vehicle must not pause the interpreter'
  eq true, it.take_vehicle_toggle_request
  eq false, it.take_vehicle_toggle_request, 'the request is one-shot'
end

check 'Flash Sprite queues a scaled flash and waits when asked' do
  st = new_state
  it = Game::Interpreter.new(st)
  # target the hero, colour 31/0/16, power 31, 5 tenths, wait flag set
  it.start([FakeCmd.new(IC::FLASH_SPRITE, [10001, 31, 0, 16, 31, 5, 1])])
  it.update
  reqs = it.take_sprite_flash_requests
  eq 1, reqs.size
  eq 10001, reqs[0][:target]
  eq [248, 0, 128, 248], [reqs[0][:red], reqs[0][:green], reqs[0][:blue],
                          reqs[0][:power]]
  eq 30, reqs[0][:frames] # 5 tenths at 6 frames each
  eq :sprite_flash, it.wait_kind
  eq [], it.take_sprite_flash_requests, 'the queue drains'
end

check 'Flash Sprite without its wait flag does not pause the interpreter' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::FLASH_SPRITE, [10001, 31, 31, 31, 31, 3, 0])])
  it.update
  ok !it.waiting?, 'no wait flag, no pause'
  eq 1, it.take_sprite_flash_requests.size
end

check 'Fade Out BGM fades the music and forgets the current track' do
  st = new_state
  RGSS::Audio.log = []
  it = Game::Interpreter.new(st)
  it.start([
    FakeCmd.new(IC::PLAY_BGM, [0, 100, 100], string: 'Town'),
    FakeCmd.new(IC::FADEOUT_BGM, [20]), # 2 seconds
  ])
  it.update
  eq nil, st.current_bgm, 'nothing is playing after a fade-out'
  eq [:bgm_fade, 2000], RGSS::Audio.log.last, 'faded over 2000 ms'
end

check 'Play Movie records the request instead of dropping it' do
  st = new_state
  st.variables[8] = 40
  st.variables[9] = 24
  it = Game::Interpreter.new(st)
  # position mode 1 = read x/y from variables 8 and 9
  it.start([FakeCmd.new(IC::PLAY_MOVIE, [1, 8, 9, 160, 120], string: 'Opening')])
  it.update
  req = it.take_movie_request
  eq({ name: 'Opening', x: 40, y: 24, width: 160, height: 120 }, req)
  eq nil, it.take_movie_request, 'the request is one-shot'
end

check 'Tile Substitution rewrites a tile on the map and flags a redraw' do
  st = new_state
  st.map = fake_map_2x2([5, 5, 7, 5], [0, 0, 0, 0])
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::TILE_SUBSTITUTION, [0, 5, 9])]) # lower: 5 -> 9
  it.update
  eq 9, st.map.lower(0, 0)
  eq 7, st.map.lower(0, 1), 'other tiles are untouched'
  ok !it.waiting?, 'Tile Substitution must not pause the interpreter'
  eq true, it.take_tiles_changed
  eq false, it.take_tiles_changed, 'the flag is one-shot'
end

check 'Game::Map substitutions are per layer and undone by an identity swap' do
  m = fake_map_2x2([1, 1, 1, 1], [1, 1, 1, 1])
  m.substitute_tile(1, 1, 4) # upper only
  eq 1, m.lower(0, 0)
  eq 4, m.upper(0, 0)
  ok m.substituted?
  m.substitute_tile(1, 1, 1) # back to itself: drop the rewrite
  eq 1, m.upper(0, 0)
  ok !m.substituted?
end

check 'Open Save Menu and Open Main Menu pause on their own wait kinds' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::OPEN_SAVE_MENU, [])])
  it.update
  eq :save_menu, it.wait_kind
  it.resume

  it.start([FakeCmd.new(IC::OPEN_MAIN_MENU, [])])
  it.update
  eq :menu, it.wait_kind
end

check 'a conditional branch tests whether the decision key started the event' do
  st = new_state
  cmds = [
    FakeCmd.new(IC::CONDITIONAL, [8], indent: 0),
    FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 1], indent: 1),
    FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
    FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 2], indent: 1),
    FakeCmd.new(IC::END_BRANCH, [], indent: 0),
  ]
  it = Game::Interpreter.new(st)
  it.start(cmds)
  it.update
  eq 2, st.variables[1], 'not action-triggered: the else branch runs'

  it.start(cmds)
  it.triggered_by_decision_key = true
  it.update
  eq 1, st.variables[1], 'action-triggered: the true branch runs'
end

check 'a conditional branch tests whether the BGM has played through once' do
  st = new_state
  cond = [
    FakeCmd.new(IC::CONDITIONAL, [9], indent: 0),
    FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 1], indent: 1),
    FakeCmd.new(IC::ELSE_BRANCH, [], indent: 0),
    FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 2], indent: 1),
    FakeCmd.new(IC::END_BRANCH, [], indent: 0),
  ]
  it = Game::Interpreter.new(st)
  it.start(cond)
  it.update
  eq 2, st.variables[1], 'a fresh track has not looped'

  st.bgm_looped = true
  it.start(cond)
  it.update
  eq 1, st.variables[1]
end

check 'starting a new BGM clears the "played once" flag' do
  st = new_state
  st.bgm_looped = true
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::PLAY_BGM, [0, 100, 100], string: 'Field')])
  it.update
  eq false, st.bgm_looped
end

# -- battle-event pages and their commands ------------------------------------

BP = Game::BattlePage

# A troop battle-event page: a condition plus the command list it runs.
FakePage = Struct.new(:condition, :event)

# A troop battle-event page condition. Only the fields a given check enables in
# `flags` are read, so the rest can stay at their editor defaults.
FakeBattleCond = Struct.new(:flags, :switch_a_id, :switch_b_id, :variable_id,
                            :variable_value, :turn_a, :turn_b,
                            :fatigue_min, :fatigue_max,
                            :enemy_id, :enemy_hp_min, :enemy_hp_max,
                            :actor_id, :actor_hp_min, :actor_hp_max,
                            :turn_enemy_id, :turn_enemy_a, :turn_enemy_b,
                            :turn_actor_id, :turn_actor_a, :turn_actor_b,
                            :command_actor_id, :command_id)
def battle_cond(flags, opts = {})
  c = FakeBattleCond.new(flags)
  c.variable_value = 0
  c.turn_a = 0; c.turn_b = 0
  c.fatigue_min = 0; c.fatigue_max = 100
  c.enemy_hp_min = 0; c.enemy_hp_max = 100
  c.actor_hp_min = 0; c.actor_hp_max = 100
  c.turn_enemy_a = 0; c.turn_enemy_b = 0
  c.turn_actor_a = 0; c.turn_actor_b = 0
  opts.each { |k, v| c.send("#{k}=", v) }
  c
end

# A battle whose allies carry a source actor id, so the actor-keyed conditions
# and the battle Conditional Branch can find them.
FakeSourceActor = Struct.new(:id)
def battle_with(ally_hp: 100, foe_hp: 100, foe_mp: 8)
  hero = combatant('Hero', 10, 0, 10, ally_hp)
  hero.actor = FakeSourceActor.new(1)
  foe = combatant_mp('Slime', 5, 0, 5, foe_hp, foe_mp)
  Game::Battle.new([hero], [foe], Game::Rng.new(1))
end

check 'battle-event opcodes match the LCF Code enum' do
  eq 13110, IC::CHANGE_MONSTER_HP
  eq 13120, IC::CHANGE_MONSTER_MP
  eq 13130, IC::CHANGE_MONSTER_CONDITION
  eq 13150, IC::SHOW_HIDDEN_MONSTER
  eq 13210, IC::CHANGE_BATTLE_BG
  eq 13260, IC::SHOW_BATTLE_ANIM_B
  eq 13310, IC::CONDITIONAL_B
  eq 13410, IC::TERMINATE_BATTLE
  eq 23310, IC::ELSE_BRANCH_B
  eq 23311, IC::END_BRANCH_B
end

check 'BattlePage.check_turns matches EasyRPG CheckTurns exactly' do
  # Transcribed from Game_Battle::CheckTurns(turns, base, multiple):
  #   multiple == 0 -> turns >= base && (turns - base) == 0
  #   otherwise     -> turns >= base && (turns - base) % multiple == 0
  # Cross-check the Ruby against that C expression over a grid, so the
  # simplification of the first branch to `turn == base` stays honest.
  (0..8).each do |turn|
    (0..4).each do |base|
      (0..3).each do |mult|
        want = if mult == 0
                 turn >= base && (turn - base) == 0
               else
                 turn >= base && (turn - base) % mult == 0
               end
        got = BP.check_turns(turn, base, mult)
        eq want, got, "turn=#{turn} base=#{base} multiple=#{mult}"
      end
    end
  end
end

check 'BattlePage.check_turns matches RPG2000 turn arithmetic' do
  # No multiple: the turn must equal the base exactly.
  ok BP.check_turns(3, 3, 0)
  ok !BP.check_turns(4, 3, 0)
  # With a multiple: at or past the base, an exact number of steps beyond it.
  ok BP.check_turns(0, 0, 2)
  ok BP.check_turns(4, 0, 2)
  ok !BP.check_turns(3, 0, 2)
  ok !BP.check_turns(1, 2, 2), 'before the base never fires'
end

check 'BattlePage.active? tests switch, variable and turn conditions' do
  b = battle_with
  st = new_state
  sw = st.switches
  vars = st.variables
  # RPG_RT reads an entirely unticked condition box as "never", not "always".
  eq false, BP.active?(nil, sw, vars, b), 'a page with no condition never fires'
  eq false, BP.active?(battle_cond(0), sw, vars, b), 'nor one with no flags set'

  cond = battle_cond(BP::SWITCH_A, switch_a_id: 7)
  eq false, BP.active?(cond, sw, vars, b)
  sw[7] = true
  eq true, BP.active?(cond, sw, vars, b)

  vcond = battle_cond(BP::VARIABLE, variable_id: 3, variable_value: 5)
  eq false, BP.active?(vcond, sw, vars, b)
  vars[3] = 5
  eq true, BP.active?(vcond, sw, vars, b), 'the test is >=, not =='

  # Turn 0 before the first round has run.
  eq true, BP.active?(battle_cond(BP::TURN, turn_b: 0, turn_a: 0), sw, vars, b)
  eq false, BP.active?(battle_cond(BP::TURN, turn_b: 2, turn_a: 0), sw, vars, b)
end

check 'BattlePage.active? tests enemy and actor HP windows' do
  b = battle_with(ally_hp: 100, foe_hp: 100)
  st = new_state
  # Wound the monster to 30%: a "50% or below" page now fires.
  b.enemy(0).hp = 30
  cond = battle_cond(BP::ENEMY_HP, enemy_id: 0, enemy_hp_min: 0, enemy_hp_max: 50)
  eq true, BP.active?(cond, st.switches, st.variables, b)
  b.enemy(0).hp = 90
  eq false, BP.active?(cond, st.switches, st.variables, b)

  acond = battle_cond(BP::ACTOR_HP, actor_id: 1, actor_hp_min: 0, actor_hp_max: 25)
  eq false, BP.active?(acond, st.switches, st.variables, b)
  b.ally_by_actor_id(1).hp = 10
  eq true, BP.active?(acond, st.switches, st.variables, b)
end

check 'BattlePage.active? fails a condition the runtime cannot answer' do
  b = battle_with
  st = new_state
  # The chosen-command test needs the battler whose action triggered the check,
  # which a once-per-turn evaluation has no equivalent of (RPG_RT bails on a
  # null source too), so such a page must not fire unchecked.
  eq false, BP.active?(battle_cond(BP::COMMAND_ACTOR, command_actor_id: 1,
                                   command_id: 1), st.switches, st.variables, b)
  # Nor may one keyed to a battler that is not in this fight.
  eq false, BP.active?(battle_cond(BP::TURN_ENEMY, turn_enemy_id: 9),
                       st.switches, st.variables, b)
  eq false, BP.active?(battle_cond(BP::TURN_ACTOR, turn_actor_id: 99),
                       st.switches, st.variables, b)
end

# -- RPG2003 per-battler turn counters and party fatigue ----------------------

check 'a battler counts its own turns as it takes them' do
  hero = combatant('Hero', 40, 0, 20, 100)   # faster: acts first each round
  hero.actor = FakeSourceActor.new(1)
  slime = combatant('Slime', 5, 0, 5, 999)   # tanky, so the fight runs on
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  eq 0, b.enemy_turn(0), 'nobody has acted yet'
  eq 0, b.actor_turn(1)

  b.step                                     # the faster hero acts
  eq 1, b.actor_turn(1)
  eq 0, b.enemy_turn(0), 'the slower enemy has not had its turn yet'

  b.step                                     # now the enemy
  eq 1, b.enemy_turn(0)
  b.step; b.step                             # a second round for both
  eq 2, b.actor_turn(1)
  eq 2, b.enemy_turn(0)

  eq nil, b.enemy_turn(5), 'a member that is not in this fight is unknown'
  eq nil, b.actor_turn(99)
end

check 'turn_enemy / turn_actor read the per-battler counters' do
  hero = combatant('Hero', 40, 0, 20, 100)
  hero.actor = FakeSourceActor.new(1)
  slime = combatant('Slime', 5, 0, 5, 999)
  b = Game::Battle.new([hero], [slime], Game::Rng.new(1))
  st = new_state
  # Turn 0 for everyone before anyone has acted.
  eq true, BP.active?(battle_cond(BP::TURN_ENEMY, turn_enemy_id: 0,
                                  turn_enemy_b: 0, turn_enemy_a: 0),
                      st.switches, st.variables, b)
  eq false, BP.active?(battle_cond(BP::TURN_ENEMY, turn_enemy_id: 0,
                                   turn_enemy_b: 1, turn_enemy_a: 0),
                       st.switches, st.variables, b)
  b.step; b.step # both battlers have now had a turn
  eq 1, b.actor_turn(1)
  eq true, BP.active?(battle_cond(BP::TURN_ACTOR, turn_actor_id: 1,
                                  turn_actor_b: 1, turn_actor_a: 0),
                      st.switches, st.variables, b)
end

check 'Battle#fatigue weights HP two thirds and SP one third' do
  full = combatant_mp('Hero', 10, 0, 10, 100, 50)
  b = Game::Battle.new([full], [combatant('Slime', 5, 0, 5, 10)], Game::Rng.new(1))
  eq 0, b.fatigue, 'a party at full HP and SP is not tired at all'

  full.hp = 0
  eq 67, b.fatigue, 'no HP but full SP: HP is two thirds of the weight'
  full.hp = 100
  full.mp = 0
  eq 33, b.fatigue, 'no SP but full HP: SP is the other third'
  full.hp = 0
  eq 100, b.fatigue, 'wiped out'

  # An SP-less party divides by 1 rather than 0, so it never passes 66.
  nosp = combatant('Hero', 10, 0, 10, 100)
  b2 = Game::Battle.new([nosp], [combatant('Slime', 5, 0, 5, 10)], Game::Rng.new(1))
  eq 33, b2.fatigue
  nosp.hp = 0
  eq 100, b2.fatigue
end

check 'the fatigue page condition tests the window' do
  hero = combatant_mp('Hero', 10, 0, 10, 100, 50)
  b = Game::Battle.new([hero], [combatant('Slime', 5, 0, 5, 10)], Game::Rng.new(1))
  st = new_state
  # "at least half worn down" fires only once the party is.
  cond = battle_cond(BP::FATIGUE, fatigue_min: 50, fatigue_max: 100)
  eq false, BP.active?(cond, st.switches, st.variables, b)
  hero.hp = 0
  eq true, BP.active?(cond, st.switches, st.variables, b)
end

check 'BattlePage.select_all returns every matching page in order' do
  b = battle_with
  st = new_state
  st.switches[1] = true
  pages = {
    1 => FakePage.new(battle_cond(0), []),
    2 => FakePage.new(battle_cond(BP::SWITCH_A, switch_a_id: 2), []),
    3 => FakePage.new(battle_cond(BP::SWITCH_A, switch_a_id: 1), []),
    4 => FakePage.new(battle_cond(BP::TURN, turn_b: 0, turn_a: 0), []),
  }
  got = BP.select_all(pages, st.switches, st.variables, b).map { |(id, _)| id }
  eq [3, 4], got, 'unlike a map event, every matching battle page runs'
end

check 'Change Monster HP damages a troop member, honouring the lethal flag' do
  b = battle_with(foe_hp: 100)
  it = Game::Interpreter.new(new_state)
  it.battle = b
  # member 0, lose (1), constant operand (0), 30, lethal allowed (1)
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_HP, [0, 1, 0, 30, 1])])
  it.update
  eq 70, b.enemy(0).hp

  # A non-lethal hit far bigger than its HP leaves it on 1.
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_HP, [0, 1, 0, 999, 0])])
  it.update
  eq 1, b.enemy(0).hp

  # A lethal one finishes it.
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_HP, [0, 1, 0, 999, 1])])
  it.update
  eq 0, b.enemy(0).hp
  ok b.enemy(0).dead?
end

check 'Change Monster HP heals, reads a variable and a percentage' do
  b = battle_with(foe_hp: 100)
  st = new_state
  st.variables[4] = 25
  it = Game::Interpreter.new(st)
  it.battle = b
  b.enemy(0).hp = 20
  # gain (0), variable operand (1) -> variable 4 = 25
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_HP, [0, 0, 1, 4, 1])])
  it.update
  eq 45, b.enemy(0).hp

  # percentage operand (2): 10% of max_hp (100) = 10
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_HP, [0, 0, 2, 10, 1])])
  it.update
  eq 55, b.enemy(0).hp

  # Healing never exceeds the maximum.
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_HP, [0, 0, 0, 999, 1])])
  it.update
  eq 100, b.enemy(0).hp
end

check 'Change Monster MP adjusts SP and clamps to its range' do
  b = battle_with(foe_mp: 8)
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_MP, [0, 1, 0, 5])]) # lose 5
  it.update
  eq 3, b.enemy(0).mp
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_MP, [0, 1, 0, 99])])
  it.update
  eq 0, b.enemy(0).mp, 'SP floors at zero'
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_MP, [0, 0, 0, 99])])
  it.update
  eq 8, b.enemy(0).mp, 'and caps at the maximum'
end

check 'Change Monster Condition inflicts and cures a status' do
  b = battle_with
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_CONDITION, [0, 0, 4])])
  it.update
  ok b.enemy(0).state?(4), 'the status was inflicted'
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_CONDITION, [0, 0, 4])])
  it.update
  eq [4], b.enemy(0).states, 'inflicting twice does not duplicate it'
  it.start([FakeCmd.new(IC::CHANGE_MONSTER_CONDITION, [0, 1, 4])])
  it.update
  ok !b.enemy(0).state?(4), 'and it was cured'
end

check 'Show Hidden Monster and Change Battle Background raise one-shot requests' do
  b = battle_with
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::SHOW_HIDDEN_MONSTER, [2]),
            FakeCmd.new(IC::CHANGE_BATTLE_BG, [], string: 'Cave')])
  it.update
  eq [2], it.take_revealed_monsters
  eq [], it.take_revealed_monsters, 'the queue drains'
  eq 'Cave', it.take_battle_background
  eq nil, it.take_battle_background, 'the request is one-shot'
end

check 'Terminate Battle ends the fight and abandons the rest of the page' do
  b = battle_with
  st = new_state
  it = Game::Interpreter.new(st)
  it.battle = b
  it.start([FakeCmd.new(IC::TERMINATE_BATTLE, []),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 3, 3, 0])])
  it.update
  ok b.terminated?, 'the battle was told to end'
  ok !st.switches[3], 'the rest of the page did not run'
end

check 'the battle Conditional Branch tests switches, variables and battlers' do
  b = battle_with(foe_hp: 100)
  st = new_state
  it = Game::Interpreter.new(st)
  it.battle = b
  # A branch body that sets variable 1 to 1; the else sets it to 2.
  branch = lambda do |params|
    [FakeCmd.new(IC::CONDITIONAL_B, params, indent: 0),
     FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 1], indent: 1),
     FakeCmd.new(IC::ELSE_BRANCH_B, [], indent: 0),
     FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 0, 2], indent: 1),
     FakeCmd.new(IC::END_BRANCH_B, [], indent: 0)]
  end

  it.start(branch.call([0, 5, 0])) # switch 5 is on?
  it.update
  eq 2, st.variables[1], 'switch off: the else branch runs'
  st.switches[5] = true
  it.start(branch.call([0, 5, 0]))
  it.update
  eq 1, st.variables[1]

  # type 3: troop member 0 is still standing
  it.start(branch.call([3, 0, 0]))
  it.update
  eq 1, st.variables[1]
  b.enemy(0).hp = 0
  it.start(branch.call([3, 0, 0]))
  it.update
  eq 2, st.variables[1], 'a downed member fails the "is present" test'

  # type 2: actor 1 is in the fight
  it.start(branch.call([2, 1, 0]))
  it.update
  eq 1, st.variables[1]
  it.start(branch.call([2, 99, 0]))
  it.update
  eq 2, st.variables[1], 'an actor not in the fight fails'
end

check 'battle-only commands are no-ops outside a battle' do
  st = new_state
  it = Game::Interpreter.new(st) # no #battle set: a map/common event
  it.start([
    FakeCmd.new(IC::CHANGE_MONSTER_HP, [0, 1, 0, 30, 1]),
    FakeCmd.new(IC::SHOW_HIDDEN_MONSTER, [1]),
    FakeCmd.new(IC::CHANGE_BATTLE_BG, [], string: 'Cave'),
    FakeCmd.new(IC::FORCE_FLEE, [1, 0, 1]),
    FakeCmd.new(IC::ENABLE_COMBO, [1, 4, 3]),
    FakeCmd.new(IC::TERMINATE_BATTLE, []),
    FakeCmd.new(IC::CONTROL_SWITCHES, [0, 2, 2, 0]),
  ])
  it.update
  eq [], it.take_revealed_monsters
  eq [], it.take_fled_monsters
  eq nil, it.take_battle_background
  ok st.switches[2], 'the list still runs to the end'
end

# -- RPG2003 battle-page commands (Force Flee / Enable Combo / Call Common) ----

check 'Control Variables reads a monster stat in battle (operand type 8)' do
  b = battle_with(foe_hp: 80, foe_mp: 12)   # Slime: atk 5, def 0, agi 5
  st = new_state
  it = Game::Interpreter.new(st)
  it.battle = b
  it.start([FakeCmd.new(IC::CONTROL_VARS, [0, 1, 1, 0, 8, 0, 0]),   # HP
            FakeCmd.new(IC::CONTROL_VARS, [0, 2, 2, 0, 8, 0, 1]),   # SP
            FakeCmd.new(IC::CONTROL_VARS, [0, 3, 3, 0, 8, 0, 4]),   # attack
            FakeCmd.new(IC::CONTROL_VARS, [0, 4, 4, 0, 8, 0, 7]),   # agility
            FakeCmd.new(IC::CONTROL_VARS, [0, 5, 5, 0, 8, 9, 0])])  # not in the troop
  it.update
  eq 80, st.variables[1]
  eq 12, st.variables[2]
  eq 5, st.variables[3]
  eq 5, st.variables[4]
  eq 0, st.variables[5]
end

check 'RPG2003 event opcodes match the LCF Code enum' do
  eq 1005, IC::CALL_COMMON_EVENT
  eq 1006, IC::FORCE_FLEE
  eq 1007, IC::ENABLE_COMBO
  eq 1008, IC::CHANGE_CLASS
  eq 1009, IC::CHANGE_BATTLE_COMMANDS
  eq 5001, IC::OPEN_LOAD_MENU
  eq 5002, IC::EXIT_GAME
  eq 5004, IC::TOGGLE_FULLSCREEN
  eq 5005, IC::OPEN_VIDEO_OPTIONS
end

check 'Force Flee target 0 grants the party a guaranteed escape' do
  b = escape_battle(5, 20)                 # 0% by agility: never flees on its own
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::FORCE_FLEE, [0, 0, 0])])
  it.update
  ok b.force_flee?, 'the escape is granted...'
  ok !b.escaped?, '...but not taken until the party chooses Flee'
  ok b.attempt_escape, 'and then it always succeeds'
  eq :escaped, b.result
  eq [], it.take_fled_monsters, 'no troop member left'
end

check 'Force Flee target 2 takes one troop member out of the fight' do
  hero = combatant('Hero', 10, 0, 10, 100)
  foes = [combatant('Slime', 5, 0, 5, 30), combatant('Bat', 5, 0, 5, 30)]
  b = Game::Battle.new([hero], foes, Game::Rng.new(1))
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::FORCE_FLEE, [2, 1, 0])])
  it.update
  eq [1], it.take_fled_monsters
  ok b.enemy(1).hidden, 'the member is hidden, not killed'
  ok b.enemy(1).hp > 0
  ok !b.finished?, 'the other member keeps the fight going'
  eq [], it.take_fled_monsters, 'the queue drains'
end

check 'Force Flee target 1 empties the troop and ends the fight' do
  hero = combatant('Hero', 10, 0, 10, 100)
  foes = [combatant('Slime', 5, 0, 5, 30), combatant('Bat', 5, 0, 5, 0)]
  b = Game::Battle.new([hero], foes, Game::Rng.new(1))
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::FORCE_FLEE, [1, 0, 0])])
  it.update
  eq [0], it.take_fled_monsters, 'only the member still standing ran'
  ok b.finished?, 'nobody is left to fight'
  ok b.enemy(0).hp > 0, 'the runaway was not killed to end it'
  b.end_round # the scene settles the outcome at the end of the turn
  eq :victory, b.result
end

check 'Enable Combo arms a battle combo on a party actor' do
  st = class_state
  it = Game::Interpreter.new(st)
  it.battle = battle_with
  it.start([FakeCmd.new(IC::ENABLE_COMBO, [1, 4, 3]),
            FakeCmd.new(IC::ENABLE_COMBO, [99, 1, 2])]) # not in the party
  it.update
  eq({ command_id: 4, multiple: 3 }, st.party.actor_by_id(1).battle_combo)
end

check 'Call Common Event runs the common event and returns to the page' do
  st = new_state
  called = [FakeCmd.new(IC::CONTROL_SWITCHES, [0, 9, 9, 0])]
  it = Game::Interpreter.new(st)
  it.resolver = FakeResolver.new(common: { 4 => called })
  it.start([FakeCmd.new(IC::CALL_COMMON_EVENT, [4]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq true, st.switches[9], 'the common event ran'
  eq true, st.switches[1], 'and control came back'
end

check 'Call Common Event with no resolver or an unknown id is a safe no-op' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::CALL_COMMON_EVENT, [4]),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  eq true, st.switches[1]

  st2 = new_state
  it2 = Game::Interpreter.new(st2)
  it2.resolver = FakeResolver.new(common: {})
  it2.start([FakeCmd.new(IC::CALL_COMMON_EVENT, [4]),
             FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it2.update
  eq true, st2.switches[1]
end

# -- RPG2003 English-release (2k3e) system commands ---------------------------

check 'Open Load Menu and Exit Game raise their scene requests' do
  it = Game::Interpreter.new(new_state)
  it.start([FakeCmd.new(IC::OPEN_LOAD_MENU, [])])
  it.update
  ok it.waiting?
  eq :load_menu, it.wait_kind

  it2 = Game::Interpreter.new(new_state)
  it2.start([FakeCmd.new(IC::EXIT_GAME, [])])
  it2.update
  ok it2.waiting?
  eq :exit_game, it2.wait_kind
end

check 'Toggle Fullscreen / Open Video Options run on without pausing' do
  st = new_state
  it = Game::Interpreter.new(st)
  it.start([FakeCmd.new(IC::TOGGLE_FULLSCREEN, []),
            FakeCmd.new(IC::OPEN_VIDEO_OPTIONS, []),
            FakeCmd.new(IC::CONTROL_SWITCHES, [0, 1, 1, 0])])
  it.update
  ok !it.waiting?, 'neither command blocks the event'
  eq true, st.switches[1]
end

check 'Show Battle Animation (battle form) waits like the map form' do
  b = battle_with
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::SHOW_BATTLE_ANIM_B, [7, 0, 1])])
  it.update
  eq :animation, it.wait_kind
  eq 7, it.battle_animation[:animation]
  eq true, it.battle_animation[:battle]
end

# -- hidden troop members stay out of the fight --------------------------------

# A troop member the editor flagged invisible: from_enemy must carry that
# through, so the combatant starts out of play.
FakeHiddenEnemy = Struct.new(:name, :atk, :def, :agi, :hp, :max_hp, :sp,
                             :max_sp, :spi, :hidden)
def hidden_enemy(name, hidden, hp: 100, atk: 20)
  FakeHiddenEnemy.new(name, atk, 0, 5, hp, hp, 0, 0, 0, hidden)
end

check 'Battle.from_enemy carries the troop member invisible flag' do
  ok Game::Battle.from_enemy(hidden_enemy('Lurker', true)).out_of_play?
  ok !Game::Battle.from_enemy(hidden_enemy('Slime', false)).out_of_play?
  # out_of_play? is not dead? -- a hidden monster is at full HP, just absent.
  ok !Game::Battle.from_enemy(hidden_enemy('Lurker', true)).dead?
end

check 'a hidden monster takes no turn and cannot be attacked' do
  hero = combatant('Hero', 20, 0, 30, 100)   # fastest, acts first
  seen = Game::Battle.from_enemy(hidden_enemy('Slime', false, hp: 100))
  lurker = Game::Battle.from_enemy(hidden_enemy('Lurker', true, hp: 100, atk: 40))
  b = Game::Battle.new([hero], [seen, lurker], Game::Rng.new(1))
  b.run_round
  eq 100, lurker.hp, 'the hidden monster was never hit'
  ok seen.hp < 100, 'the visible one took the hero\'s attack'
  ok hero.hp > 60, "the hidden monster did not attack back (hero #{hero.hp})"
end

check 'a battle ends when every visible monster is down, hidden ones aside' do
  hero = combatant('Hero', 20, 0, 30, 100)
  seen = Game::Battle.from_enemy(hidden_enemy('Slime', false, hp: 1))
  lurker = Game::Battle.from_enemy(hidden_enemy('Lurker', true, hp: 100))
  b = Game::Battle.new([hero], [seen, lurker], Game::Rng.new(1))
  b.run_round
  ok seen.dead?, 'the visible monster fell'
  ok b.finished?, 'an unrevealed monster does not keep the fight going'
  eq :victory, b.result
end

check 'revealing a hidden monster brings it into the fight' do
  hero = combatant('Hero', 20, 0, 30, 100)
  lurker = Game::Battle.from_enemy(hidden_enemy('Lurker', true, hp: 100, atk: 40))
  b = Game::Battle.new([hero], [lurker], Game::Rng.new(1))
  ok b.finished?, 'with only a hidden monster there is nothing to fight'

  lurker.hidden = false # what Show Hidden Monster (13150) does
  ok !b.finished?, 'once revealed the fight is on'
  b.run_round
  ok lurker.hp < 100, 'it can now be attacked'
end

check 'Show Hidden Monster reveals through the interpreter and the battle' do
  b = battle_with(foe_hp: 100)
  b.enemy(0).hidden = true
  it = Game::Interpreter.new(new_state)
  it.battle = b
  it.start([FakeCmd.new(IC::SHOW_HIDDEN_MONSTER, [0])])
  it.update
  eq [0], it.take_revealed_monsters, 'the scene is told which member to reveal'
  # The interpreter queues the request; the scene clears the flag on both the
  # troop member and the combatant (see Scene::Map#reveal_battle_monster).
  ok b.enemy(0).out_of_play?, 'still out of play until the scene applies it'
  b.enemy(0).hidden = false
  ok !b.enemy(0).out_of_play?
end

# -- enemy action patterns (行動パターン) --------------------------------------

# A stand-in for one row of an enemy's action table; EnemyAction reads whichever
# fields are present, so a test only names the ones it cares about.
class FakeAction
  attr_accessor :kind, :basic, :skill_id, :enemy_id, :condition_type,
                :condition_param1, :condition_param2, :switch_id, :switch_on,
                :switch_on_id, :switch_off, :switch_off_id, :rating

  def initialize(h = {})
    h.each { |k, v| send("#{k}=", v) }
    @rating ||= 50
  end
end

def enemy_action(h = {})
  Game::EnemyAction.new(FakeAction.new(h))
end

# A battle whose single monster runs `actions`, against one hero.
def ai_battle(actions, ai = nil, foe: nil, hero: nil, seed: 1)
  hero ||= combatant('Hero', 40, 0, 20, 500)
  foe ||= combatant('Slime', 40, 0, 5, 500)
  foe.actions = actions
  # The skill formulas read the caster's spirit; a bare Combatant leaves it nil.
  hero.spi ||= 0
  foe.spi ||= 0
  Game::Battle.new([hero], [foe], Game::Rng.new(seed), nil, false, false, false,
                   false, nil, ai)
end

# One enemy action resolved: the log entry its turn produced.
def enemy_entry(actions, ai = nil, foe: nil, hero: nil, seed: 1)
  b = ai_battle(actions, ai, foe: foe, hero: hero, seed: seed)
  b.begin_round
  # The hero is faster (agi 20 vs 5), so drain its action first.
  b.step_action
  b.step_action
end

check 'EnemyAction decodes a database action row' do
  a = enemy_action(kind: 1, skill_id: 7, condition_type: 4,
                   condition_param1: 0, condition_param2: 50, rating: 80)
  ok a.skill?, 'kind 1 is a skill'
  eq 7, a.skill_id
  eq 4, a.condition_type
  eq 50, a.condition_param2
  eq 80, a.rating
end

check 'EnemyAction defaults the rating to the editor default of 50' do
  eq 50, enemy_action(kind: 0).rating
end

check 'an enemy with no action pattern still attacks (unchanged behaviour)' do
  e = enemy_entry([])
  eq 'Slime', e[:attacker]
  eq 20, e[:damage], 'a plain attack, exactly as before'
end

check 'an enemy defends instead of attacking when its pattern says so' do
  e = enemy_entry([enemy_action(kind: 0, basic: 2)])
  eq true, e[:defend]
  ok e[:damage].nil?, 'a guard deals no damage'
end

check 'a defending enemy takes half damage from the next blow' do
  hero = combatant('Hero', 40, 0, 5, 500)     # slower, so the foe guards first
  foe = combatant('Slime', 40, 0, 20, 500)
  b = ai_battle([enemy_action(kind: 0, basic: 2)], nil, foe: foe, hero: hero)
  b.begin_round
  eq true, b.step_action[:defend], 'the faster monster guards'
  eq 10, b.step_action[:damage], 'base 20 halved by the guard'
end

check "an enemy's guard expires on its next turn" do
  hero = combatant('Hero', 40, 0, 5, 500)
  foe = combatant('Slime', 40, 0, 20, 500)
  # Round 1 guards; round 2 attacks (and so drops the guard).
  b = ai_battle([enemy_action(kind: 0, basic: 2)], nil, foe: foe, hero: hero)
  b.begin_round; b.step_action; b.step_action; b.end_round
  b.begin_round
  b.step_action                               # the monster guards again
  eq 10, b.step_action[:damage], 'still guarding within the round'
  ok foe.defending, 'the guard is up'
  b.end_round
  b.begin_round
  b.step_action
  ok foe.defending, 're-raised by the same pattern'
end

check 'a charge doubles the enemy next attack, then is spent' do
  # Two entries: charge (rating 50) then attack. Charge first via a turn gate.
  foe = combatant('Slime', 40, 0, 5, 500)
  charge = enemy_action(kind: 0, basic: 4)
  b = ai_battle([charge], nil, foe: foe)
  b.begin_round; b.step_action
  eq true, b.step_action[:charge], 'the monster gathers strength'
  ok foe.charged, 'the charge is held'
  # Swap in a plain attack for the next turn and check it lands doubled.
  foe.actions = [enemy_action(kind: 0, basic: 0)]
  b.end_round; b.begin_round; b.step_action
  e = b.step_action
  eq 40, e[:damage], 'base 20 doubled by the charge'
  eq true, e[:charged]
  ok !foe.charged, 'and the charge is spent'
end

check 'a dual attack strikes twice in one turn' do
  b = ai_battle([enemy_action(kind: 0, basic: 1)])
  b.begin_round
  b.step_action                                # the hero
  first = b.step_action
  second = b.step_action
  eq 'Slime', first[:attacker]
  eq 'Slime', second[:attacker], 'the same monster swings again'
  eq 20, first[:damage]
  eq 20, second[:damage]
end

check 'an observing / idle enemy does nothing but still reads on the log' do
  eq true, enemy_entry([enemy_action(kind: 0, basic: 3)])[:observe]
  eq true, enemy_entry([enemy_action(kind: 0, basic: 7)])[:nothing]
end

check 'an escaping enemy leaves the fight without counting as a kill' do
  hero = combatant('Hero', 40, 0, 20, 500)
  foe = combatant('Slime', 40, 0, 5, 500)
  b = ai_battle([enemy_action(kind: 0, basic: 6)], nil, foe: foe, hero: hero)
  b.begin_round
  b.step_action
  eq true, b.step_action[:fled]
  ok foe.hidden, 'out of play'
  ok !foe.dead?, 'but not defeated'
  eq :victory, b.run, 'the fight is over with the troop gone'
end

check 'self-destruction hits the party for atk - def/2 and kills the caster' do
  hero = combatant('Hero', 40, 10, 20, 500)
  foe = combatant('Bomb', 60, 0, 5, 500)
  b = ai_battle([enemy_action(kind: 0, basic: 5)], nil, foe: foe, hero: hero)
  b.begin_round
  b.step_action
  e = b.step_action
  eq true, e[:autodestruct]
  eq 55, e[:damage], '60 - 10/2'
  ok foe.dead?, 'the bomb dies doing it'
end

# -- the rating-weighted choice ------------------------------------------------

check 'an action more than 10 below the best rating is never chosen' do
  # rating 50 vs 39: 39 - 50 + 10 = -1 -> floored to 0, so it never comes up.
  acts = [enemy_action(kind: 0, basic: 0, rating: 50),
          enemy_action(kind: 0, basic: 2, rating: 39)]
  20.times do |i|
    e = enemy_entry(acts, nil, seed: i + 1)
    ok e[:defend].nil?, "the rating-39 guard stays out (seed #{i + 1})"
  end
end

check 'an action within 10 of the best rating does come up' do
  # Drawn from one continuously advancing RNG rather than 30 fresh seeds: this
  # engine's LCG is seeded as `seed + 1` and reseeding it that narrowly gives a
  # badly clustered first draw, which would test the RNG rather than the choice.
  acts = [enemy_action(kind: 0, basic: 0, rating: 50),
          enemy_action(kind: 0, basic: 2, rating: 45)]
  b = ai_battle(acts)
  seen = {}
  40.times do
    b.begin_round
    b.step_action                              # the hero
    e = b.step_action                          # the monster
    seen[e && e[:defend] ? :defend : :attack] = true
    b.end_round
  end
  ok seen[:attack], 'the attack comes up'
  ok seen[:defend], 'and so does the rating-45 guard'
end

# -- the action conditions -----------------------------------------------------

check 'an HP-range action only fires inside its window' do
  # Only valid below 50% HP; with no other valid action the enemy falls back to
  # a plain attack, so the guard appearing is the signal.
  act = enemy_action(kind: 0, basic: 2, condition_type: 4,
                     condition_param1: 0, condition_param2: 50)
  healthy = combatant('Slime', 40, 0, 5, 500)
  ok enemy_entry([act], nil, foe: healthy)[:defend].nil?, 'at full HP it does not fire'
  hurt = combatant('Slime', 40, 0, 5, 500)
  hurt.hp = 100                                # 20% of 500
  eq true, enemy_entry([act], nil, foe: hurt)[:defend], 'below 50% it fires'
end

check 'a switch-gated action reads the live switch through the AI env' do
  st = new_state
  ai = Game::EnemyAi.new(nil, st)
  act = enemy_action(kind: 0, basic: 2, condition_type: 1, switch_id: 3)
  ok enemy_entry([act], ai)[:defend].nil?, 'switch off: not valid'
  st.switches[3] = true
  eq true, enemy_entry([act], ai)[:defend], 'switch on: fires'
end

check 'a switch-gated action is invalid with no AI env to ask' do
  act = enemy_action(kind: 0, basic: 2, condition_type: 1, switch_id: 3)
  ok enemy_entry([act], nil)[:defend].nil?, 'falls back to attacking'
end

check 'an actor-count action ranges over the living party' do
  act = enemy_action(kind: 0, basic: 2, condition_type: 3,
                     condition_param1: 2, condition_param2: 4)
  ok enemy_entry([act], nil)[:defend].nil?, 'a party of one is below the range'
end

check 'a turn-gated action uses the battle turn clock' do
  # base 0 / multiple 2 -> turns 0, 2, 4 ... (Game::BattlePage.check_turns)
  act = enemy_action(kind: 0, basic: 2, condition_type: 2,
                     condition_param1: 2, condition_param2: 0)
  b = ai_battle([act])
  b.begin_round                                # turn 1: no match
  b.step_action
  ok b.step_action[:defend].nil?, 'turn 1 does not match'
  b.end_round
  b.begin_round                                # turn 2: matches
  b.step_action
  eq true, b.step_action[:defend], 'turn 2 matches'
end

check 'a party-level action reads the average level through the AI env' do
  st = party_state
  ai = Game::EnemyAi.new(nil, st)
  # Two actors at levels 5 and 3, so the party average is 4 — not the leader's.
  lvl = ai.party_level
  eq 4, lvl, 'the average, not the leader'
  hit = enemy_action(kind: 0, basic: 2, condition_type: 6,
                     condition_param1: lvl, condition_param2: lvl + 10)
  miss = enemy_action(kind: 0, basic: 2, condition_type: 6,
                      condition_param1: lvl + 5, condition_param2: lvl + 10)
  eq true, enemy_entry([hit], ai)[:defend], 'inside the level range'
  ok enemy_entry([miss], ai)[:defend].nil?, 'outside it'
end

check 'an unknown condition type keeps the action out of the running' do
  act = enemy_action(kind: 0, basic: 2, condition_type: 99)
  ok enemy_entry([act], nil)[:defend].nil?, 'not fired unchecked'
end

# -- post-action switches ------------------------------------------------------

check 'an action flips its switches once it has run' do
  st = new_state
  ai = Game::EnemyAi.new(nil, st)
  st.switches[9] = true
  act = enemy_action(kind: 0, basic: 0, switch_on: true, switch_on_id: 8,
                     switch_off: true, switch_off_id: 9)
  enemy_entry([act], ai)
  eq true, st.switches[8], 'switched on'
  eq false, st.switches[9], 'and off'
end

# -- skill actions -------------------------------------------------------------

# A minimal skill row for the AI env to resolve.
class FakeAiSkill
  attr_accessor :name, :scope, :sp_type, :sp_cost, :sp_percent, :power,
                :physical_rate, :magical_rate, :hit, :variance, :state_effects,
                :attribute_effects, :affect_hp, :affect_sp

  def initialize(h = {})
    @name = 'Spell'; @scope = 0; @sp_type = 0; @sp_cost = 0; @power = 0
    @physical_rate = 0; @magical_rate = 0; @hit = 100; @variance = 0
    @affect_hp = true; @affect_sp = false
    h.each { |k, v| send("#{k}=", v) }
  end
end

# An AI env whose skill table is a fixed hash, casting through a real party.
class FakeAiEnv < Game::EnemyAi
  def initialize(skills, state)
    super(nil, state)
    @skills = skills
  end

  def skill(id); @skills[id]; end
end

def skill_ai(skills)
  FakeAiEnv.new(skills, party_state)
end

check 'an enemy casts an attack skill from its pattern' do
  ai = skill_ai(1 => FakeAiSkill.new(name: 'Fire', scope: 0, power: 30))
  foe = combatant_mp('Slime', 40, 0, 5, 500, 100)
  e = enemy_entry([enemy_action(kind: 1, skill_id: 1)], ai, foe: foe)
  eq 'Fire', e[:skill], 'the skill is named on the log'
  ok e[:damage] > 0, 'and it hurt'
end

check "an enemy's attack skill inflicts its states — enemy-cast infliction" do
  # state_effects marks state 2; scope 0 makes it an attack skill, whose states
  # roll against the skill's accuracy (100 here, so it always lands).
  sk = FakeAiSkill.new(name: 'Poison Sting', scope: 0, power: 20, hit: 100,
                       state_effects: [0, 1])
  ai = skill_ai(1 => sk)
  hero = combatant('Hero', 40, 0, 20, 500)
  foe = combatant_mp('Slime', 40, 0, 5, 500, 100)
  e = enemy_entry([enemy_action(kind: 1, skill_id: 1)], ai, foe: foe, hero: hero)
  eq [2], e[:inflicted], 'the party member is poisoned by the monster'
  ok hero.state?(2), 'and carries the state'
end

check 'an enemy heals a fellow monster with an ally-scoped skill' do
  ai = skill_ai(1 => FakeAiSkill.new(name: 'Heal', scope: 3, power: 50,
                                     affect_hp: true))
  hero = combatant('Hero', 40, 0, 30, 500)
  medic = combatant_mp('Medic', 10, 0, 5, 500, 100)
  medic.actions = [enemy_action(kind: 1, skill_id: 1)]
  hurt = combatant('Brute', 10, 0, 1, 500)
  hurt.hp = 100
  [hero, medic, hurt].each { |c| c.spi ||= 0 }
  b = Game::Battle.new([hero], [medic, hurt], Game::Rng.new(1), nil, false,
                       false, false, false, nil, ai)
  b.begin_round
  b.step_action                                # the hero swings
  e = b.step_action                            # the medic casts
  eq true, e[:recover], 'a recovery, not an attack'
  ok e[:recover_hp] > 0, 'HP restored to a monster'
end

check 'an all-enemies skill hits every party member at once' do
  ai = skill_ai(1 => FakeAiSkill.new(name: 'Blast', scope: 1, power: 30))
  a = combatant('A', 10, 0, 30, 500)
  bb = combatant('B', 10, 0, 29, 500)
  foe = combatant_mp('Slime', 40, 0, 5, 500, 100)
  foe.actions = [enemy_action(kind: 1, skill_id: 1)]
  [a, bb, foe].each { |c| c.spi ||= 0 }
  bat = Game::Battle.new([a, bb], [foe], Game::Rng.new(1), nil, false, false,
                         false, false, nil, ai)
  bat.begin_round
  bat.step_action; bat.step_action             # both heroes
  hits = [bat.step_action, bat.step_action]
  eq %w[A B], hits.map { |h| h[:target] }.sort, 'both members are hit'
  eq 1, hits.map { |h| h[:attacker] }.uniq.size, 'by the one monster'
end

check 'an enemy that cannot pay a skill SP cost falls back to attacking' do
  ai = skill_ai(1 => FakeAiSkill.new(name: 'Fire', scope: 0, power: 30,
                                     sp_cost: 50))
  foe = combatant_mp('Slime', 40, 0, 5, 500, 10)   # only 10 SP
  e = enemy_entry([enemy_action(kind: 1, skill_id: 1)], ai, foe: foe)
  ok e[:skill].nil?, 'no spell'
  eq 20, e[:damage], 'a plain attack instead'
end

check 'a skill action with no AI env to resolve it degrades to an attack' do
  e = enemy_entry([enemy_action(kind: 1, skill_id: 1)], nil)
  ok e[:skill].nil?
  eq 20, e[:damage]
end

check 'casting spends the enemy SP' do
  ai = skill_ai(1 => FakeAiSkill.new(name: 'Fire', scope: 0, power: 30,
                                     sp_cost: 12))
  foe = combatant_mp('Slime', 40, 0, 5, 500, 100)
  enemy_entry([enemy_action(kind: 1, skill_id: 1)], ai, foe: foe)
  eq 88, foe.mp, '100 - 12'
end

# -- transformation ------------------------------------------------------------

check 'a transformation re-points the monster at another database enemy' do
  # A tiny stand-in database exposing one enemy row.
  row = Struct.new(:name, :max_hp, :max_sp, :attack, :defense, :spirit,
                   :agility, :exp, :gold).new('Dragon', 900, 50, 90, 40, 30,
                                              25, 0, 0)
  db = Struct.new(:enemy).new({ 1 => row })
  ai = Game::EnemyAi.new(db, new_state)
  foe = combatant('Slime', 40, 0, 5, 500)
  e = enemy_entry([enemy_action(kind: 2, enemy_id: 1)], ai, foe: foe)
  eq true, e[:transform]
  eq 'Dragon', foe.name, 'the monster is now a Dragon'
  eq 90, foe.atk, 'with its stats'
  eq 900, foe.max_hp
end

check 'a transformation into an unknown enemy degrades to an attack' do
  ai = Game::EnemyAi.new(nil, new_state)
  e = enemy_entry([enemy_action(kind: 2, enemy_id: 99)], ai)
  ok e[:transform].nil?
  eq 20, e[:damage]
end

# -- the database path ---------------------------------------------------------

check 'Game::Enemy decodes its action pattern off the database row' do
  arow = FakeAction.new(kind: 1, skill_id: 4, rating: 60)
  erow = Struct.new(:name, :max_hp, :max_sp, :attack, :defense, :spirit,
                    :agility, :exp, :gold, :actions)
             .new('Imp', 30, 5, 12, 4, 3, 8, 7, 3, { 1 => arow })
  db = Struct.new(:enemy).new({ 1 => erow })
  e = Game::Enemy.new(db, 1)
  eq 1, e.actions.size
  ok e.actions.first.skill?
  eq 4, e.actions.first.skill_id
  eq 60, e.actions.first.rating
  eq e.actions, Game::Battle.from_enemy(e).actions,
     'and the combatant carries it into the fight'
end

# -- battle backdrop resolution (map tree backdrop_type) -----------------------

# One map-tree node's backdrop settings.
class FakeMapNode
  attr_accessor :backdrop_type, :backdrop_file, :parent_map_id
  def initialize(type, file = '', parent = 0)
    @backdrop_type = type; @backdrop_file = file; @parent_map_id = parent
  end
end

check 'backdrop type 2 uses the map own file, whatever the terrain says' do
  props = { 1 => FakeMapNode.new(2, 'black') }
  eq 'black', Game::Backdrop.name_for(1, props, 'Grassland')
end

check 'backdrop type 1 uses the terrain backdrop' do
  props = { 1 => FakeMapNode.new(1, 'ignored') }
  eq 'Grassland', Game::Backdrop.name_for(1, props, 'Grassland')
  eq '', Game::Backdrop.name_for(1, props, ''), 'and nothing when the terrain names none'
end

check 'backdrop type 0 inherits from the parent map' do
  props = { 1 => FakeMapNode.new(2, 'cave'),
            2 => FakeMapNode.new(0, '', 1) }
  eq 'cave', Game::Backdrop.name_for(2, props, 'Grassland'), 'the parent pins a file'
end

check 'backdrop inheritance walks more than one level' do
  props = { 1 => FakeMapNode.new(2, 'boss'),
            2 => FakeMapNode.new(0, '', 1),
            3 => FakeMapNode.new(0, '', 2) }
  eq 'boss', Game::Backdrop.name_for(3, props, 'Grassland')
end

check 'an inherited terrain type resolves to the terrain, not the parent file' do
  props = { 1 => FakeMapNode.new(1, 'unused'),
            2 => FakeMapNode.new(0, '', 1) }
  eq 'Desert', Game::Backdrop.name_for(2, props, 'Desert')
end

check 'a map inheriting from the root falls back to the terrain' do
  props = { 1 => FakeMapNode.new(0, '', 0) }   # parent 0 = the tree root
  eq 'Snow Field', Game::Backdrop.name_for(1, props, 'Snow Field')
end

check 'an unknown map id falls back to the terrain' do
  eq 'Swamp', Game::Backdrop.name_for(7, { 1 => FakeMapNode.new(2, 'x') }, 'Swamp')
  eq 'Swamp', Game::Backdrop.name_for(1, nil, 'Swamp'), 'and so does having no tree'
end

check 'a looping map tree ends at the terrain instead of hanging' do
  props = { 1 => FakeMapNode.new(0, '', 2),
            2 => FakeMapNode.new(0, '', 1) }   # 1 -> 2 -> 1 -> ...
  eq 'Forest1', Game::Backdrop.name_for(1, props, 'Forest1')
end

check 'a map that parents itself ends at the terrain' do
  eq 'Ruins1', Game::Backdrop.name_for(1, { 1 => FakeMapNode.new(0, '', 1) }, 'Ruins1')
end

check 'a node missing its fields is treated as inheriting' do
  bare = Struct.new(:nothing).new(0)
  eq 'Wasteland', Game::Backdrop.name_for(1, { 1 => bare }, 'Wasteland')
end

# -- menu Save access resolution (map tree save field, 33) --------------------

# One map-tree node's Save setting.
class FakeSaveNode
  attr_accessor :save, :parent_map_id
  def initialize(save, parent = 0)
    @save = save; @parent_map_id = parent
  end
end

check 'save type 1 (Allow) lets the menu Save command through' do
  props = { 1 => FakeSaveNode.new(1) }
  eq true, Game::MapAccess.save_allowed?(1, props)
end

check 'save type 2 (Forbid) blocks the menu Save command' do
  props = { 1 => FakeSaveNode.new(2) }
  eq false, Game::MapAccess.save_allowed?(1, props)
end

check 'save type 0 inherits from the parent map' do
  props = { 1 => FakeSaveNode.new(2), 2 => FakeSaveNode.new(0, 1) }
  eq false, Game::MapAccess.save_allowed?(2, props), 'the parent pins Forbid'
end

check 'save inheritance walks more than one level' do
  props = { 1 => FakeSaveNode.new(2),
            2 => FakeSaveNode.new(0, 1),
            3 => FakeSaveNode.new(0, 2) }
  eq false, Game::MapAccess.save_allowed?(3, props)
end

check 'a map inheriting from the root defaults to Allow' do
  props = { 1 => FakeSaveNode.new(0, 0) }   # parent 0 = the tree root
  eq true, Game::MapAccess.save_allowed?(1, props)
end

check 'an unknown map id defaults to Allow' do
  eq true, Game::MapAccess.save_allowed?(7, { 1 => FakeSaveNode.new(2) })
  eq true, Game::MapAccess.save_allowed?(1, nil), 'and so does having no tree'
end

check 'a looping map tree ends at Allow instead of hanging' do
  props = { 1 => FakeSaveNode.new(0, 2),
            2 => FakeSaveNode.new(0, 1) }   # 1 -> 2 -> 1 -> ...
  eq true, Game::MapAccess.save_allowed?(1, props)
end

check 'a map that parents itself defaults to Allow' do
  eq true, Game::MapAccess.save_allowed?(1, { 1 => FakeSaveNode.new(0, 1) })
end

check 'a node missing its save field defaults to Allow' do
  bare = Struct.new(:nothing).new(0)
  eq true, Game::MapAccess.save_allowed?(1, { 1 => bare })
end

# -- field Teleport/Escape access resolution (map tree fields 31, 32) --------
#
# The identical tri-state walk as Save above (field 33), just read off a
# different pair of fields -- confirmed against EasyRPG's Game_Map::Setup,
# which re-derives Game_System::AllowTeleport/AllowEscape from these two
# fields on every map load exactly as it does AllowSave. Since #allowed? is
# shared with #save_allowed? and its walk (inherit, loop, unknown map, root,
# a field-less node) is already exhaustively covered above, these checks only
# have to show each method reads its own field rather than borrowing #save's.

class FakeAccessNode
  attr_accessor :save, :teleport, :escape, :parent_map_id
  def initialize(save, teleport, escape, parent = 0)
    @save = save; @teleport = teleport; @escape = escape; @parent_map_id = parent
  end
end

check 'teleport_allowed? and escape_allowed? each read their own field' do
  props = { 1 => FakeAccessNode.new(1, 2, 1) }   # save Allow, teleport Forbid, escape Allow
  eq true,  Game::MapAccess.save_allowed?(1, props)
  eq false, Game::MapAccess.teleport_allowed?(1, props), 'teleport is the one forbidden here'
  eq true,  Game::MapAccess.escape_allowed?(1, props)
end

check 'teleport/escape access inherits from the parent map' do
  props = { 1 => FakeAccessNode.new(1, 2, 2),
            2 => FakeAccessNode.new(1, 0, 0, 1) }
  eq false, Game::MapAccess.teleport_allowed?(2, props), 'the parent pins Forbid'
  eq false, Game::MapAccess.escape_allowed?(2, props)
end

check 'an unknown map, missing field or missing tree defaults teleport/escape to Allow' do
  eq true, Game::MapAccess.teleport_allowed?(7, { 1 => FakeAccessNode.new(1, 2, 2) })
  eq true, Game::MapAccess.escape_allowed?(1, nil)
  bare = Struct.new(:nothing).new(0)
  eq true, Game::MapAccess.teleport_allowed?(1, { 1 => bare })
  eq true, Game::MapAccess.escape_allowed?(1, { 1 => bare })
end

# -- battle log terms (Game::States::BattleText) ------------------------------

BT = Game::States::BattleText

# The 用語 table stores predicates, not templates: RPG_RT prints the battler's
# name and then the field, with one particle rule for the damage line.
FakeTerms = Struct.new(:attacking, :defending, :observing, :focus,
                       :autodestruction, :enemy_escape, :enemy_transform,
                       :enemy_damaged, :actor_damaged,
                       :enemy_undamaged, :actor_undamaged, :dodge)

def fake_terms
  FakeTerms.new('の攻撃！', 'は身を守っている', 'は様子を見ている・・・',
                'は力をためている・・・', 'は自爆した！', 'は逃げてしまった！',
                'は別のモンスターに変身した！',
                'のダメージを与えた！', 'のダメージを受けた！',
                'にダメージを与えられない！', 'はダメージを受けていない！',
                'は身をかわした！')
end

check 'an action line is the battler name and the term, nothing else' do
  t = fake_terms
  eq 'スライムの攻撃！', BT.action(t, 'スライム', :attacking)
  eq 'リトは身を守っている', BT.action(t, 'リト', :defending)
  eq 'リトは様子を見ている・・・', BT.action(t, 'リト', :observing)
  eq 'スライムは力をためている・・・', BT.action(t, 'スライム', :focus)
  eq 'スライムは自爆した！', BT.action(t, 'スライム', :autodestruction)
  eq 'スライムは逃げてしまった！', BT.action(t, 'スライム', :enemy_escape)
end

# The two damage predicates differ, and so does the particle: RPG_RT says
# "...に N のダメージを与えた！" of a foe and "...は N のダメージを受けた！" of
# one of yours.
check 'the damage line picks its predicate and particle by side' do
  t = fake_terms
  eq 'スライムに 42 のダメージを与えた！', BT.damage(t, 'スライム', 42, false)
  eq 'リトは 42 のダメージを受けた！', BT.damage(t, 'リト', 42, true)
end

check 'a blow that lands for nothing has no number and no particle' do
  t = fake_terms
  eq 'スライムにダメージを与えられない！', BT.undamaged(t, 'スライム', false)
  eq 'リトはダメージを受けていない！', BT.undamaged(t, 'リト', true)
end

check 'a miss is worded from the target side, one term for both' do
  t = fake_terms
  eq 'スライムは身をかわした！', BT.dodge(t, 'スライム')
  eq 'リトは身をかわした！', BT.dodge(t, 'リト')
end

# A database that leaves a battle term blank (an English release often does)
# must not produce a half-sentence — the caller keeps its own wording instead.
check 'a blank or missing term yields nil rather than a bare name' do
  blank = FakeTerms.new('', '', '', '', '', '', '', '', '', '', '', '')
  eq nil, BT.action(blank, 'リト', :attacking)
  eq nil, BT.damage(blank, 'リト', 42, true)
  eq nil, BT.undamaged(blank, 'リト', true)
  eq nil, BT.dodge(blank, 'リト')
  eq nil, BT.action(nil, 'リト', :attacking), 'no term table at all'
  eq nil, BT.action(Struct.new(:nothing).new(0), 'リト', :attacking),
     'a table without the field'
end

# A skill has a voice of its own where a plain attack has only a term.
FakeSkillMsg = Struct.new(:using_message1, :using_message2, :failure_message)

check 'a skill names itself: the first line takes the caster, the second stands alone' do
  sk = FakeSkillMsg.new('は炎を放った！', 'あたりが真っ赤に染まる！', 0)
  eq ['リトは炎を放った！', 'あたりが真っ赤に染まる！'], BT.skill_start(sk, 'リト')
end

check 'a skill with only a first sentence gives one line' do
  eq ['リトは炎を放った！'],
     BT.skill_start(FakeSkillMsg.new('は炎を放った！', '', 0), 'リト')
end

check 'a skill with no sentence at all gives none' do
  eq [], BT.skill_start(FakeSkillMsg.new('', '', 0), 'リト')
  eq [], BT.skill_start(nil, 'リト'), 'and so does a missing row'
end

# failure_message indexes the three 用語 failure lines; 3 borrows the dodge line.
check 'a skill picks which failure sentence says it did nothing' do
  terms = Struct.new(:skill_failure_a, :skill_failure_b, :skill_failure_c, :dodge)
            .new('には効かなかった！', 'は平気だった！', 'は眠らなかった！',
                 'は身をかわした！')
  eq 'スライムには効かなかった！',
     BT.skill_failure(terms, FakeSkillMsg.new('', '', 0), 'スライム')
  eq 'スライムは平気だった！',
     BT.skill_failure(terms, FakeSkillMsg.new('', '', 1), 'スライム')
  eq 'スライムは眠らなかった！',
     BT.skill_failure(terms, FakeSkillMsg.new('', '', 2), 'スライム')
  eq 'スライムは身をかわした！',
     BT.skill_failure(terms, FakeSkillMsg.new('', '', 3), 'スライム'),
     'index 3 borrows the dodge line'
  eq 'スライムには効かなかった！',
     BT.skill_failure(terms, nil, 'スライム'), 'no row falls to the first line'
end

# An item borrows the use_item term rather than carrying a sentence, and is the
# one line RPG2000 builds from two names.
check 'an item line is the caster, the item and the term' do
  t = Struct.new(:use_item).new('を使った！')
  eq 'リトはポーションを使った！', BT.item_start(t, 'リト', 'ポーション')
  eq nil, BT.item_start(Struct.new(:use_item).new(''), 'リト', 'ポーション')
end

# 「リトのＨＰが 30 回復した！」 — name, の, the pool's own 用語 name, が, the
# amount, the term. Both pool names come from the table too, which is why
# Nepheshel's read ＨＰ / ＭＰ full-width and mtf's read HP / MP.
check 'a recovery names the pool from the table, not from a literal' do
  t = Struct.new(:hp_recovery, :hp, :mp).new('回復した！', 'ＨＰ', 'ＭＰ')
  eq 'リトのＨＰが 30 回復した！', BT.recovered(t, 'リト', 30, :hp)
  eq 'リトのＭＰが 12 回復した！', BT.recovered(t, 'リト', 12, :mp)
  ascii = Struct.new(:hp_recovery, :hp, :mp).new('回復した！', 'HP', 'MP')
  eq 'リトのHPが 30 回復した！', BT.recovered(ascii, 'リト', 30, :hp)
end

check 'a recovery with no wording yields nil rather than half a sentence' do
  no_term = Struct.new(:hp_recovery, :hp, :mp).new('', 'ＨＰ', 'ＭＰ')
  eq nil, BT.recovered(no_term, 'リト', 30, :hp)
  no_pool = Struct.new(:hp_recovery, :hp, :mp).new('回復した！', '', '')
  eq nil, BT.recovered(no_pool, 'リト', 30, :hp), 'the pool name matters too'
end

# 吸収 — the drain line. Close to the recovery line but not the same shape.
check 'the absorbed line differs from the recovery line in three places' do
  t = Struct.new(:enemy_hp_absorbed, :actor_hp_absorbed, :hp_recovery, :hp)
        .new('奪った！', '奪われた！', '回復した！', 'ＨＰ')
  eq 'スライムのＨＰを 20 奪った！', BT.absorbed(t, 'スライム', 20, :hp, false)
  eq 'リトはＨＰを 20 奪われた！', BT.absorbed(t, 'リト', 20, :hp, true)
  # The recovery line always takes の and follows the pool with が; the drain
  # picks の / は by side and follows with を, and the two sides differ.
  eq 'リトのＨＰが 20 回復した！', BT.recovered(t, 'リト', 20, :hp)
end

check 'a drain with no wording yields nil' do
  blank = Struct.new(:enemy_hp_absorbed, :actor_hp_absorbed, :hp)
            .new('', '', 'ＨＰ')
  eq nil, BT.absorbed(blank, 'スライム', 20, :hp, false)
  no_pool = Struct.new(:enemy_hp_absorbed, :actor_hp_absorbed, :hp)
              .new('奪った！', '奪われた！', '')
  eq nil, BT.absorbed(no_pool, 'スライム', 20, :hp, false)
end

# The rule that makes a drain more than "damage plus healing": RPG_RT clamps the
# effect to what the target has *before* applying it, so a big drain on a
# nearly-dead foe is weaker, not merely capped in what it gives back.
check 'a drain takes only what the target had, and deals only that much' do
  mage = combatant_mp('Mage', 0, 0, 20, 100, 30)
  mage.hp = 50
  foe = combatant('Foe', 0, 0, 5, 100)
  foe.hp = 30
  b = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  b.command_skill(mage, foe, name: 'Drain', cost: 0, hp: -200, absorb: true)
  b.begin_round
  e = b.step_action
  eq 30, e[:damage], 'the drain is capped at what was there'
  eq 30, e[:absorbed_hp]
  eq 0, foe.hp
  eq 80, mage.hp, 'and the caster gained exactly that'
end

check 'a drain cannot push the caster past its maximum' do
  mage = combatant_mp('Mage', 0, 0, 20, 100, 30)
  mage.hp = 95
  foe = combatant('Foe', 0, 0, 5, 100)
  b = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  b.command_skill(mage, foe, name: 'Drain', cost: 0, hp: -40, absorb: true)
  b.begin_round
  eq 40, b.step_action[:absorbed_hp], 'it still took 40 off the foe'
  eq 100, mage.hp, 'but the caster stops at full'
end

check 'a skill without the flag drains nothing' do
  mage = combatant_mp('Mage', 0, 0, 20, 100, 30)
  mage.hp = 50
  foe = combatant('Foe', 0, 0, 5, 100)
  b = Game::Battle.new([mage], [foe], Game::Rng.new(1))
  b.command_skill(mage, foe, name: 'Fire', cost: 0, hp: -40)
  b.begin_round
  eq 0, b.step_action[:absorbed_hp]
  eq 50, mage.hp
end

# -- 蘇生専用 items (ko_only) --------------------------------------------------
# RPG_RT returns from the item algorithm *before* both the HP and the state
# effects when the target is still standing, so a revive item is not merely
# "cures nothing" on a living ally -- its percentage HP restore does not land
# either. Every ko_only item in both test beds is a revive of exactly that shape.

def revive_party
  items = { 4 => fake_item(type: 6, rhp_rate: 25, state_set: [1], ko_only: true),
            5 => fake_item(type: 6, rhp: 50) } # an ordinary medicine
  item_party(items)
end

check 'a revive item does nothing to an ally who is still standing' do
  st = revive_party
  st.party.gain_item(4, 1)
  hero = st.party.actor_by_id(1)
  hero.change_hp(-60) # 40/100, wounded but up
  eq false, st.party.item_effective?(4, hero), 'the menu greys it out'
  eq [], st.party.use_item(4, hero)
  eq 40, hero.hp, 'and not even the 25% HP lands'
  eq 1, st.party.item_count(4), 'nothing is spent'
end

check 'the same item revives an ally who is down, HP and all' do
  st = revive_party
  st.party.gain_item(4, 1)
  hero = st.party.actor_by_id(1)
  hero.add_state(Game::Actor::DEATH_STATE)
  ok hero.dead?
  eq true, st.party.item_effective?(4, hero)
  eq [hero], st.party.use_item(4, hero)
  ok !hero.dead?, 'back on their feet'
  # Standing up puts them on 1 HP first (the existing revive path), and the
  # item's 25% of 100 lands on top of that.
  eq 26, hero.hp, 'with the 25% the item restores'
  eq 0, st.party.item_count(4), 'and it was spent'
end

check 'an ordinary medicine is unaffected by the rule' do
  st = revive_party
  st.party.gain_item(5, 1)
  hero = st.party.actor_by_id(1)
  hero.change_hp(-60)
  eq true, st.party.item_effective?(5, hero)
  eq [hero], st.party.use_item(5, hero)
  eq 90, hero.hp
end

# An all-party revive passes over the members who never fell rather than topping
# them up, which is the case the "not even the HP" reading decides.
check 'an all-party revive skips the members still standing' do
  items = { 4 => fake_item(type: 6, scope: 1, rhp_rate: 25, state_set: [1],
                           ko_only: true) }
  st = item_party(items)
  st.party.gain_item(4, 1)
  up = st.party.actor_by_id(1)
  down = st.party.actor_by_id(2)
  up.change_hp(-60)
  down.add_state(Game::Actor::DEATH_STATE)
  eq [down], st.party.use_item(4, nil)
  eq 40, up.hp, 'the standing member is passed over'
  ok !down.dead?, 'the fallen one is raised'
end

# -- the skill damage defence term --------------------------------------------
# RPG_RT blunts an enemy-scope skill with the *same two rates* that built its
# effect: physical_rate * def / 40 + magical_rate * spi / 80. A flat def/4 only
# coincides with that when the skill is purely physical at rate 10.

def defence_party
  skills = {
    1 => fake_skill(name: 'Slash', scope: 0, power: 20, prate: 10, mrate: 0),
    2 => fake_skill(name: 'Bolt',  scope: 0, power: 20, prate: 0,  mrate: 40),
    3 => fake_skill(name: 'Pierce', scope: 0, power: 20, prate: 10, mrate: 0,
                    ignore_defense: true),
    4 => fake_skill(name: 'Mixed', scope: 0, power: 20, prate: 10, mrate: 40),
  }
  skill_party(skills)
end

check 'a physical skill is blunted by armour, scaled by its own rate' do
  st = defence_party
  caster = Game::Battle.from_actor(st.party.actor_by_id(1)) # atk 10, spi 12
  foe = combatant('Foe', 0, 40, 5, 100)
  foe.spi = 40
  # effect = 20 + 10*10/20 = 25; term = 10*40/40 + 0 = 10
  eq(-15, st.party.battle_skill_command(st.party.db_skill(1), caster, foe)[:hp])
end

# The case a flat def/4 gets most wrong: armour should not blunt a spell at all.
check 'a magical skill is blunted by spirit, not by armour' do
  st = defence_party
  caster = Game::Battle.from_actor(st.party.actor_by_id(1))
  foe = combatant('Foe', 0, 40, 5, 100)
  foe.spi = 40
  # effect = 20 + 40*12/40 = 32; term = 0 + 40*40/80 = 20
  eq(-12, st.party.battle_skill_command(st.party.db_skill(2), caster, foe)[:hp])

  # Doubling the armour changes nothing; doubling the spirit is what bites.
  armoured = combatant('Foe', 0, 80, 5, 100)
  armoured.spi = 40
  eq(-12, st.party.battle_skill_command(st.party.db_skill(2), caster, armoured)[:hp],
     'armour is irrelevant to a spell')
  wise = combatant('Foe', 0, 40, 5, 100)
  wise.spi = 80
  eq(-1, st.party.battle_skill_command(st.party.db_skill(2), caster, wise)[:hp],
     'spirit is what resists it (floored at 1)')
end

check 'a skill with both rates takes both halves of the term' do
  st = defence_party
  caster = Game::Battle.from_actor(st.party.actor_by_id(1))
  foe = combatant('Foe', 0, 40, 5, 100)
  foe.spi = 40
  # effect = 20 + 10*10/20 + 40*12/40 = 37; term = 10*40/40 + 40*40/80 = 30
  eq(-7, st.party.battle_skill_command(st.party.db_skill(4), caster, foe)[:hp])
end

check '防御無視 skips the whole term, armour and spirit alike' do
  st = defence_party
  caster = Game::Battle.from_actor(st.party.actor_by_id(1))
  foe = combatant('Foe', 0, 40, 5, 100)
  foe.spi = 40
  # effect = 25, and nothing is taken off it
  eq(-25, st.party.battle_skill_command(st.party.db_skill(3), caster, foe)[:hp])
end

check 'a target that carries no stats absorbs nothing rather than raising' do
  st = defence_party
  caster = Game::Battle.from_actor(st.party.actor_by_id(1))
  bare = combatant('Bare', 0, 0, 5, 100) # spi nil
  eq(-25, st.party.battle_skill_command(st.party.db_skill(1), caster, bare)[:hp])
  eq(-32, st.party.battle_skill_command(st.party.db_skill(2), caster, nil)[:hp],
     'and no target at all takes the full effect')
end

# -- 両手持ち weapons (two_handed) --------------------------------------------
# RPG_RT keeps the weapon and shield slots mutually exclusive whenever either
# holds a two-handed weapon: filling one clears the other. 35 of Nepheshel's 104
# weapons are two-handed and 14 of mtf-meido-action's 26.

def two_handed_party
  items = { 1 => fake_item(type: 1, atk: 20),                     # one-handed
            2 => fake_item(type: 1, atk: 40, two_handed: 1),      # a claymore
            3 => fake_item(type: 2, dfn: 10),                     # a shield
            4 => fake_item(type: 3, dfn: 4) }                     # body armour
  item_party(items)
end

check 'a two-handed weapon empties the shield hand' do
  st = two_handed_party
  hero = st.party.actor_by_id(1)
  hero.equip_item(3)
  eq 3, hero.equipment[1], 'shield on'
  hero.equip_item(2)
  eq 2, hero.equipment[0]
  eq 0, hero.equipment[1], 'and the shield is off'
end

# The check reads both slots, so it works the other way round too.
check 'a shield knocks off the two-handed weapon already worn' do
  st = two_handed_party
  hero = st.party.actor_by_id(1)
  hero.equip_item(2)
  hero.equip_item(3)
  eq 3, hero.equipment[1]
  eq 0, hero.equipment[0], 'the claymore had to go'
end

check 'a one-handed weapon and a shield live together' do
  st = two_handed_party
  hero = st.party.actor_by_id(1)
  hero.equip_item(1)
  hero.equip_item(3)
  eq [1, 3], hero.equipment[0, 2]
end

check 'the rule only touches the two hands' do
  st = two_handed_party
  hero = st.party.actor_by_id(1)
  hero.equip_item(4) # body armour
  hero.equip_item(2) # claymore
  eq 4, hero.equipment[2], 'the armour is untouched'
  eq 2, hero.equipment[0]
end

# The flag means nothing on a non-weapon: RPG_RT tests the type alongside it.
check 'a shield carrying the flag does not claim the other hand' do
  items = { 1 => fake_item(type: 1, atk: 20),
            3 => fake_item(type: 2, dfn: 10, two_handed: 1) }
  st = item_party(items)
  hero = st.party.actor_by_id(1)
  hero.equip_item(1)
  hero.equip_item(3)
  eq [1, 3], hero.equipment[0, 2], 'both stay on'
end

# The menu swaps through the bag, so the hand it empties must give its item back.
check 'equipping from the bag returns the emptied hand to the bag' do
  st = two_handed_party
  hero = st.party.actor_by_id(1)
  st.party.gain_item(2, 1)
  st.party.gain_item(3, 1)
  ok st.party.equip_from_bag(hero, 3), 'shield on'
  eq 0, st.party.item_count(3), 'and out of the bag'
  ok st.party.equip_from_bag(hero, 2), 'now the claymore'
  eq 2, hero.equipment[0]
  eq 0, hero.equipment[1]
  eq 1, st.party.item_count(3), 'the shield came back rather than vanishing'
  eq 0, st.party.item_count(2)
end

# Restoring a saved loadout is not an equip action: RPG_RT stores what it stores,
# and EasyRPG enforces the rule only in ChangeEquipment.
check 'a bulk equip restores a saved pair as-is' do
  st = two_handed_party
  hero = st.party.actor_by_id(1)
  hero.equip([2, 3, 0, 0, 0])
  eq [2, 3], hero.equipment[0, 2], 'loaded exactly as saved'
end

# -- 二刀流 actors (double_hand) -----------------------------------------------
# An actor (or RPG2003 class) trait that turns the *shield* slot into a
# *second weapon* slot -- the flag ADR 0040 flagged as "left alone" (the
# opposite rule to two_handed above: that empties a hand, this fills it with
# a weapon). 4 of Nepheshel's actors carry it and 1 of mtf-meido-action's.

def double_hand_party(double_hand = true)
  items = { 1 => fake_item(type: 1, atk: 20, hit: 95),                # sword
            2 => fake_item(type: 1, atk: 15, hit: 85, critical_hit: 20), # dagger
            3 => fake_item(type: 2, dfn: 10),                         # shield
            4 => fake_item(type: 1, atk: 10, two_handed: 1) }         # claymore
  row = FakePlayerRow.new('Hero', '', 0, 5,
                          { max_hp: 100, max_mp: 30, atk: 10, def: 8 })
  row.double_hand = double_hand
  db = FakeActorDB.new({ 1 => row }, [1], items)
  Game::State.new(Game::Party.new(db), 1, 0, 0)
end

check 'a 二刀流 actor is offered weapons, not the shield, for the shield slot' do
  st = double_hand_party
  hero = st.party.actor_by_id(1)
  [1, 2, 3].each { |id| st.party.gain_item(id, 1) }
  eq [[1, 1], [2, 1]], st.party.equip_candidates(Game::Actor::SHIELD_SLOT, hero),
     'the two swords, not the shield'
  eq [[1, 1], [2, 1]], st.party.equip_candidates(Game::Actor::WEAPON_SLOT, hero),
     'the ordinary weapon slot lists exactly the same two weapons'
end

check 'an ordinary actor is still offered the shield for the shield slot' do
  st = double_hand_party(false)
  hero = st.party.actor_by_id(1)
  [1, 2, 3].each { |id| st.party.gain_item(id, 1) }
  eq [[3, 1]], st.party.equip_candidates(Game::Actor::SHIELD_SLOT, hero)
end

check 'equipping a second weapon from the bag lands it in the shield slot' do
  st = double_hand_party
  hero = st.party.actor_by_id(1)
  st.party.gain_item(1, 1)
  st.party.gain_item(2, 1)
  ok st.party.equip_from_bag(hero, 1, Game::Actor::WEAPON_SLOT), 'the sword, first hand'
  ok st.party.equip_from_bag(hero, 2, Game::Actor::SHIELD_SLOT), 'the dagger, second hand'
  eq [1, 2], hero.equipment[0, 2], 'both weapons are on, one per slot'
  # Both weapons now contribute -- the existing per-item-type scans in
  # attack_hit_rate / weapon_crit_bonus / equipment_flag? are slot-agnostic,
  # so the second weapon in the shield slot needed no changes of its own.
  eq 95, hero.attack_hit_rate, 'the better of the two weapons\' hit rates'
  eq 20, hero.weapon_crit_bonus, 'the dagger\'s crit bonus, the sword carrying none'
  eq 10 + 20 + 15, hero.atk, 'both weapons\' attack bonuses are summed in, like any slot'
end

check 'a shield is rejected for a 二刀流 actor\'s shield slot even named directly' do
  st = double_hand_party
  hero = st.party.actor_by_id(1)
  st.party.gain_item(3, 1)
  ok !st.party.equip_from_bag(hero, 3, Game::Actor::SHIELD_SLOT),
     'not a real candidate for that slot on this actor'
  eq 0, hero.equipment[1], 'nothing was equipped'
  eq 1, st.party.item_count(3), 'and the shield stayed in the bag'
end

check 'a two-handed second weapon still empties the shield-turned-weapon hand\'s neighbour' do
  st = double_hand_party
  hero = st.party.actor_by_id(1)
  st.party.gain_item(1, 1)
  st.party.gain_item(4, 1)
  ok st.party.equip_from_bag(hero, 1, Game::Actor::WEAPON_SLOT)
  ok st.party.equip_from_bag(hero, 4, Game::Actor::SHIELD_SLOT), 'the claymore, into the second hand'
  eq 4, hero.equipment[1]
  eq 0, hero.equipment[0], 'the two-handed claymore still claims the other hand'
end

# -- 装備固定 actors (equipment_fixed) -----------------------------------------
# An actor (or RPG2003 class) trait meaning the field cannot change their
# equipment at all. EasyRPG gates this at the equip *scene* -- confirming a
# slot refuses to even open the item list for such an actor -- rather than in
# Game_Actor::ChangeEquipment or Game_Party's bag-swapping helpers, which
# neither check it (a Change Equipment event command, unlike the menu, is not
# gated by this at all). So Game::Party's own equip API stays usable here on
# purpose; #equipment_fixed? exists for Scene::EquipMenu to read before
# opening its item list, which is exercised at that layer in
# scripts/rpg2k_scene_check.rb.

check 'Actor#equipment_fixed? reads the row flag, including an RPG2003 class override' do
  row = FakePlayerRow.new('Hero', '', 0, 5, { max_hp: 10 })
  row.equipment_fixed = true
  db = FakeActorDB.new({ 1 => row }, [1])
  hero = Game::Party.new(db).leader
  ok hero.equipment_fixed?, 'the row carries the flag'

  plain = FakePlayerRow.new('Ally', '', 0, 5, { max_hp: 10 })
  db2 = FakeActorDB.new({ 1 => plain }, [1])
  ok !Game::Party.new(db2).leader.equipment_fixed?, 'unset by default'
end

check 'equipment_fixed? does not itself block Party#equip_from_bag / #unequip_to_bag' do
  # The gate belongs to the equip menu, not the bag-swap logic -- RPG_RT's own
  # ChangeEquipment does not consult it either, so a caller that already knows
  # better (an event command, this test) is not refused here.
  items = { 1 => fake_item(type: 1, atk: 20) }
  row = FakePlayerRow.new('Hero', '', 0, 5, { max_hp: 10 })
  row.equipment_fixed = true
  db = FakeActorDB.new({ 1 => row }, [1], items)
  st = Game::State.new(Game::Party.new(db), 1, 0, 0)
  hero = st.party.actor_by_id(1)
  st.party.gain_item(1, 1)
  ok st.party.equip_from_bag(hero, 1)
  eq 1, hero.equipment[0]
  ok st.party.unequip_to_bag(hero, 0) != 0
  eq 0, hero.equipment[0]
end

# -- chipset terrain tags -----------------------------------------------------

FakeChipsetRow = Struct.new(:name, :chipset_name, :passable_data_lower,
                            :passable_data_upper, :terrain_data,
                            :animation_type, :animation_speed)

def chipset_with(terrain_data)
  db = Struct.new(:chipset).new(
    { 1 => FakeChipsetRow.new('cs', 'cs', nil, nil, terrain_data, 0, 0) }
  )
  Game::ChipSet.new(db, 1)
end

# RPG_RT drops the whole 162-entry terrain array when every tile of the chipset
# is terrain 1, and that is what nearly every real chipset does. Reading the
# absence as terrain 0 leaves the tile with no terrain row at all.
check 'a chipset that stores no terrain table reads terrain 1' do
  cs = chipset_with(nil)
  eq 1, cs.terrain(0), 'the first lower tile'
  eq 1, cs.terrain(4000), 'a block-E tile'
  cs = chipset_with([])
  eq 1, cs.terrain(0), 'an empty table is the same absence'
end

check 'a chipset that stores one reads it' do
  td = Array.new(162, 3)
  td[0] = 7
  cs = chipset_with(td)
  eq 7, cs.terrain(0)
  eq 3, cs.terrain(4000)
end

# RPG_RT reads the first lower tile's terrain for anything it cannot index,
# rather than answering with a terrain id no row can match.
check 'an unindexable tile reads the first lower tile' do
  td = Array.new(162, 3)
  td[0] = 7
  eq 7, chipset_with(td).terrain(-1)
end

# -- chipset directional passability ------------------------------------------

def chipset_with_passable(passable_data)
  db = Struct.new(:chipset).new(
    { 1 => FakeChipsetRow.new('cs', 'cs', passable_data, nil, nil, 0, 0) }
  )
  Game::ChipSet.new(db, 1)
end

check 'passable? reads exactly the requested direction bit' do
  data = Array.new(162, 0)
  data[0] = Game::ChipSet::DIR_BIT[2] | Game::ChipSet::DIR_BIT[6] # Down, Right
  cs = chipset_with_passable(data)
  ok cs.passable?(0, 2), 'Down is set'
  ok cs.passable?(0, 6), 'Right is set'
  ok !cs.passable?(0, 4), 'Left is clear'
  ok !cs.passable?(0, 8), 'Up is clear'
end

# RPG_RT ORs a jump's landing tile across all four direction bits rather than
# asking one specific side, since a jump does not arrive "from" anywhere the
# way a step does; it only refuses a tile blocked on every side.
check 'landable? accepts a tile passable from any single side' do
  data = Array.new(162, 0)
  data[0] = Game::ChipSet::DIR_BIT[8] # Up only
  cs = chipset_with_passable(data)
  ok cs.landable?(0), 'one open direction is enough to land'
  data[0] = 0
  ok !chipset_with_passable(data).landable?(0), 'blocked on every side refuses the landing'
end

# -- upper-layer chipset passability -------------------------------------------

def chipset_with_upper(lower_data, upper_data)
  db = Struct.new(:chipset).new(
    { 1 => FakeChipsetRow.new('cs', 'cs', lower_data, upper_data, nil, 0, 0) }
  )
  Game::ChipSet.new(db, 1)
end

BLOCK_F = Game::ChipsetLayout::BLOCK_F
ABOVE = Game::ChipSet::ABOVE_BIT
COUNTER = Game::ChipSet::COUNTER_BIT

# No upper tile at all (id 0, or a chipset with no upper table): the upper
# layer has nothing to say, so passability falls straight through to the
# lower layer exactly as before the upper check existed.
check 'passable_tile? with no upper tile falls through to the lower layer' do
  lower = Array.new(162, 0)
  lower[0] = Game::ChipSet::DIR_BIT[6]
  cs = chipset_with_upper(lower, Array.new(144, 0))
  ok cs.passable_tile?(0, 0, 6), 'lower allows Right, no upper tile'
  ok !cs.passable_tile?(0, 0, 2), 'lower refuses Down, no upper tile'

  cs_no_table = chipset_with_upper(lower, nil)
  ok cs_no_table.passable_tile?(0, BLOCK_F, 6), 'no upper table at all defers to lower too'
end

# A solid object on the upper layer (all direction bits clear, ABOVE_BIT
# clear) blocks movement outright, regardless of what the lower layer says --
# this is the counter tiles fix generalised: a boulder or fence post is just
# as impassable as a shop counter, and neither defers to the ground beneath.
check 'passable_tile? refuses a solid upper-layer obstacle even over open ground' do
  lower = Array.new(162, Game::ChipSet::ALL_DIRS) # wide open lower ground
  upper = Array.new(144, 0)
  upper[0] = 0 # blocked on every side, ABOVE_BIT clear
  cs = chipset_with_upper(lower, upper)
  ok !cs.passable_tile?(0, BLOCK_F, 2), 'a solid upper tile blocks Down'
  ok !cs.passable_tile?(0, BLOCK_F, 6), 'and Right'

  # A shop/inn counter is exactly this case, plus the counter flag.
  upper[0] = COUNTER
  ok !chipset_with_upper(lower, upper).passable_tile?(0, BLOCK_F, 6),
     'a counter (blocked + COUNTER_BIT) is impassable to walk onto'
end

# ABOVE_BIT set: the upper tile permits the direction, but is "see-through"
# ground, so the lower layer's own passability still gets the final word --
# a decorative overlay does not override a wall painted underneath it.
check 'passable_tile? with ABOVE_BIT still checks the lower layer' do
  lower = Array.new(162, 0) # lower blocks everything
  upper = Array.new(144, 0)
  upper[0] = Game::ChipSet::ALL_DIRS | ABOVE
  cs = chipset_with_upper(lower, upper)
  ok !cs.passable_tile?(0, BLOCK_F, 6), 'upper allows Right, but the lower wall still refuses it'

  lower[0] = Game::ChipSet::DIR_BIT[6]
  ok chipset_with_upper(lower, upper).passable_tile?(0, BLOCK_F, 6),
     'both layers now agree: passable'
end

check 'landable_tile? applies the same solid-vs-see-through rule to jumps' do
  lower = Array.new(162, 0) # lower blocks every side
  upper = Array.new(144, 0)
  upper[0] = Game::ChipSet::DIR_BIT[8] # one open side, ABOVE_BIT clear
  cs = chipset_with_upper(lower, upper)
  ok cs.landable_tile?(0, BLOCK_F), 'a solid object open on one side is still landable'

  upper[0] = 0
  ok !chipset_with_upper(lower, upper).landable_tile?(0, BLOCK_F),
     'blocked on every side refuses the landing'

  upper[0] = Game::ChipSet::DIR_BIT[8] | ABOVE
  ok !chipset_with_upper(lower, upper).landable_tile?(0, BLOCK_F),
     'ABOVE_BIT set defers to the lower layer, which is fully blocked'
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k logic check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k logic check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
