#!/usr/bin/env ruby
# encoding: UTF-8
#
# Integration smoke-test for the map scene's event-movement wiring.
#
# Unlike scripts/rpg2k_logic_check.rb (which exercises the pure Game:: logic in
# isolation), this loads the *actual* Scene::Map from mruby-rpg2k/mrblib/main.rb
# behind small RGSS stubs and a synthetic map, then ticks it like the game loop
# would. It catches the wiring the pure checks can't: method visibility (the
# MapWorld adapter calling back into the scene), the LCF page field names
# build_event reads, and that autonomous / custom-route events actually roam
# without raising. No real SDL/mruby binary is needed, so it runs in CI's cheap
# path next to the loader and logic checks.
#
# Usage: ruby scripts/rpg2k_scene_check.rb   (exits non-zero on any failure)

require 'ostruct'

# -- RGSS stubs (just enough for Scene::Map to build, render and tick) --------

module RGSS
  Rect = Struct.new(:x, :y, :width, :height)

  class Color
    def initialize(*); end
  end

  # A no-op drawing surface. Records nothing; every draw call is ignored.
  class Bitmap
    attr_reader :width, :height
    def initialize(w = 1, h = 1); @width = w.to_i; @height = h.to_i; end
    def clear; end
    def fill_rect(*); end
    def blt(*); end
    def stretch_blt(*); end
    def draw_text(*); end
    def text_size(_); Rect.new(0, 0, 0, 0); end
    def font; @font ||= OpenStruct.new; end
    def dispose; end
  end

  class Sprite
    attr_accessor :bitmap, :x, :y, :z, :visible
    def initialize(*); end
    def dispose; end
  end

  class Viewport
    attr_accessor :z, :visible, :rect
    def initialize(*); end
    def dispose; end
  end

  # No input: the player never moves, no buttons are pressed.
  module Input
    C = 1; B = 2; UP = 3; DOWN = 4; LEFT = 5; RIGHT = 6
    def self.trigger?(_); false; end
    def self.dir4; 0; end
    def self.update; end
  end

  module Graphics
    def self.frame_rate; 60; end
    def self.update; end
  end

  module Audio
    def self.bgm_play(*); end
    def self.se_play(*); end
  end

  def self.warn_stub(*); end
  class Timeout < StandardError; end
end

lib = File.expand_path('../mruby-rpg2k/mrblib', __dir__)
load File.join(lib, 'game.rb')
load File.join(lib, 'interpreter.rb')
load File.join(lib, 'main.rb')

# -- tiny test framework ------------------------------------------------------

$failures = 0
$checks = 0

def check(name)
  $checks += 1
  yield
rescue StandardError => e
  $failures += 1
  warn "  FAIL #{name}: #{e.class}: #{e.message}"
  warn "    #{e.backtrace.first(3).join("\n    ")}"
end

def ok(cond, msg = 'expected truthy'); raise msg unless cond; end
def eq(exp, act, msg = nil)
  return if exp == act
  raise "expected #{exp.inspect}, got #{act.inspect}#{msg ? " (#{msg})" : ''}"
end

# -- synthetic database / map -------------------------------------------------

R = Game::MoveRoute

# A chipset with no passability table -> every tile is walkable, so movement is
# bounded only by the map edges, the player and other events.
def fake_chipset
  OpenStruct.new(name: 'cs', chipset_name: 'cs', passable_data_lower: nil)
end

def fake_db(common = nil)
  OpenStruct.new(
    system: OpenStruct.new(system_graphic: ''),
    chipset: { 1 => fake_chipset },
    common_event: common,
    player: {}
  )
end

# An event command (the interpreter reads code/param/string/indent/parameters).
class ECmd
  attr_reader :code, :indent, :string, :parameters
  def initialize(code, params = [], indent: 0, string: '')
    @code = code
    @parameters = params
    @indent = indent
    @string = string
  end
  def param(i); @parameters[i] || 0; end
end

# One event page. Defaults: an action-trigger, stationary event with no route.
def page(x_move_type: Game::MoveType::STATIONARY, route: nil, trigger: 0,
         frequency: 6)
  OpenStruct.new(
    condition: nil, direction: 2, move_type: x_move_type, move_speed: 3,
    move_frequency: frequency, charset_name: '', charset_index: 0,
    trigger: trigger, event_commands: nil, move_route: route
  )
end

def event(x, y, pg)
  OpenStruct.new(x: x, y: y, pages: { 1 => pg })
end

def move_route(cmd_ids, repeat: true, skippable: true)
  cmds = cmd_ids.map { |id| OpenStruct.new(command_id: id, parameter_string: '',
                                           parameter_a: 0, parameter_b: 0,
                                           parameter_c: 0) }
  OpenStruct.new(commands: cmds, repeat: repeat, skippable: skippable)
end

# A 6x5 map, all tiles walkable, holding the given events (id => ev).
def fake_map(id, events)
  w = 6; h = 5
  unit = OpenStruct.new(width: w, height: h, chipset_id: 1,
                        lower_layer: Array.new(w * h, 0),
                        upper_layer: Array.new(w * h, 0),
                        events: events)
  Game::Map.new(id, unit)
end

# A minimal parent (stands in for the RPG2k app) and party leader.
def fake_parent(db)
  OpenStruct.new(db: db, map_tree: nil)
end

def fake_party
  OpenStruct.new(leader: nil, actors: [])
end

def new_scene(events, player: [0, 0], common: nil)
  db = fake_db(common)
  state = Game::State.new(fake_party, 1, player[0], player[1])
  state.map = fake_map(1, events)
  RPG2k::Scene::Map.new(fake_parent(db), state)
end

# The scene builds a Game::Character per source event; movement updates those
# runtime characters (not the source structs), so tests inspect them by id.
def chars(scene)
  h = {}
  scene.instance_variable_get(:@events).each { |e| h[e[:id]] = e[:char] }
  h
end

# -- checks -------------------------------------------------------------------

check 'Scene::Map builds and ticks with no events without raising' do
  scene = new_scene({})
  30.times { scene.update }
  ok true
end

check 'a custom-route event walks right and is blocked by the map edge' do
  ev = event(1, 1, page(x_move_type: Game::MoveType::CUSTOM,
                        route: move_route([R::MOVE_RIGHT])))
  scene = new_scene({ 1 => ev }, player: [0, 0])
  200.times { scene.update }
  c = chars(scene)[1]
  # The route repeats MOVE_RIGHT; the event should have walked to the east edge
  # (x == width - 1 == 5) and stopped there, never leaving the map.
  eq 5, c.x, 'custom-route event should reach and hold the east edge'
  eq 1, c.y
end

check 'a random-mover roams but stays in bounds and off the player tile' do
  ev = event(3, 2, page(x_move_type: Game::MoveType::RANDOM))
  scene = new_scene({ 1 => ev }, player: [0, 0])
  c = chars(scene)[1]
  moved = false
  300.times do
    scene.update
    moved ||= [c.x, c.y] != [3, 2]
    ok c.x >= 0 && c.x < 6 && c.y >= 0 && c.y < 5, 'left the map'
    ok !(c.x.zero? && c.y.zero?), 'stepped onto the player'
  end
  ok moved, 'a random mover should have moved at least once in 300 frames'
end

check 'two events do not stack on the same tile' do
  a = event(2, 2, page(x_move_type: Game::MoveType::CUSTOM,
                       route: move_route([R::MOVE_RIGHT])))
  b = event(4, 2, page(x_move_type: Game::MoveType::CUSTOM,
                       route: move_route([R::MOVE_LEFT])))
  scene = new_scene({ 1 => a, 2 => b }, player: [0, 0])
  ca = chars(scene)[1]
  cb = chars(scene)[2]
  200.times do
    scene.update
    ok !(ca.x == cb.x && ca.y == cb.y), 'events collided onto the same tile'
  end
  # They walk toward each other and end up adjacent on row 2.
  ok (ca.x - cb.x).abs == 1, "expected adjacency, got a=#{ca.x} b=#{cb.x}"
end

check 'an autostart event Calls a call-only common event through the scene' do
  ic = Game::Interpreter::Cmd
  # A common event with start_term 5 (call-only): auto-start/parallel never runs
  # it, so if switch 7 flips it can only be via Call Event.
  ce = OpenStruct.new(start_term: 5, need_flag: false, switch_id: 1,
                      event: [ECmd.new(ic::CONTROL_SWITCHES, [0, 7, 7, 0])])
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::CALL_EVENT, [0, 1, 0])] # call common event 1
  scene = new_scene({ 1 => event(2, 2, pg) }, common: { 1 => ce })
  10.times { scene.update }
  st = scene.instance_variable_get(:@state)
  ok st.switches[7], 'call-only common event ran via Call Event'
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k scene check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k scene check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
