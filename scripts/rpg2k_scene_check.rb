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

  # Scriptable input: tests set `dir_value` (a numpad direction held down) and
  # `triggered` (buttons pressed this frame). Defaults to no input.
  module Input
    C = 1; B = 2; UP = 3; DOWN = 4; LEFT = 5; RIGHT = 6
    class << self
      attr_accessor :dir_value, :triggered
    end
    def self.reset; @dir_value = 0; @triggered = []; end
    def self.trigger?(k); Array(@triggered).include?(k); end
    def self.dir4; @dir_value || 0; end
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
  RGSS::Input.reset # each check starts from a clean input state
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

# A minimal parent (stands in for the RPG2k app) and party leader. load_map is
# what perform_teleport (and Recall to Location) calls to swap maps; it hands
# back a fresh empty map for the requested id.
class FakeParent
  attr_reader :db, :map_tree, :pushed
  def initialize(db, &map_maker)
    @db = db
    @map_tree = nil
    @map_maker = map_maker
    @pushed = []
  end

  def load_map(id); @map_maker.call(id); end
  # Scene::Map#try_open_menu pushes a Scene::Menu; record it instead.
  def push(scene); @pushed << scene; end
end

def fake_parent(db)
  FakeParent.new(db) { |id| fake_map(id, {}) }
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

check 'player-touch (trigger 1): walking into an event runs it, no move' do
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 1) # player touch
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  RGSS::Input.dir_value = 6 # hold right, into the event at (1,0)
  6.times { scene.update }
  st = scene.instance_variable_get(:@state)
  ok st.switches[6], 'player-touch event ran'
  eq [0, 0], [st.x, st.y], 'player did not step onto the event'
end

check 'event-touch (trigger 2): an event walking into the player runs it' do
  ic = Game::Interpreter::Cmd
  pg = page(x_move_type: Game::MoveType::TOWARD, trigger: 2, frequency: 8)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])]
  scene = new_scene({ 1 => event(3, 0, pg) }, player: [0, 0])
  ch = chars(scene)[1]
  20.times { scene.update }
  st = scene.instance_variable_get(:@state)
  ok st.switches[5], 'event-touch event ran'
  eq [1, 0], [ch.x, ch.y], 'event stopped adjacent, did not enter the player'
end

check 'action (trigger 0) does not fire on mere contact' do
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 0) # needs the action button
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  RGSS::Input.dir_value = 6 # walk into it, but do not press the action button
  6.times { scene.update }
  st = scene.instance_variable_get(:@state)
  ok !st.switches[4], 'a trigger-0 event must not run just from being bumped'
end

# CONTROL_VARS params to add `by` to variable `id`:
# [mode 0=single, id, id, op 1=add, operand 0=const, value].
def add_var_cmd(id, by = 1)
  ECmd.new(Game::Interpreter::Cmd::CONTROL_VARS, [0, id, id, 1, 0, by])
end

check 'parallel (trigger 4): a background event runs every frame' do
  pg = page(trigger: 4)
  pg.event_commands = [add_var_cmd(1)]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  10.times { scene.update }
  v = scene.instance_variable_get(:@state).variables[1]
  ok v >= 8, "parallel event should have looped ~10 times, got #{v}"
end

check 'parallel common event runs only while its switch gate is on' do
  ce = OpenStruct.new(start_term: 4, need_flag: true, switch_id: 2,
                      event: [add_var_cmd(3)])
  scene = new_scene({}, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  5.times { scene.update }
  eq 0, st.variables[3], 'gated-off parallel common event must not run'
  st.switches[2] = true
  5.times { scene.update }
  ok st.variables[3] > 0, 'it should run once the gate switch is on'
end

check 'parallel processes pause while a foreground event is running' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi')]
  par = page(trigger: 4)
  par.event_commands = [add_var_cmd(1)]
  scene = new_scene({ 1 => event(2, 2, auto), 2 => event(4, 4, par) })
  10.times { scene.update }
  # The autostart event opens a message and waits for input we never give, so
  # the foreground stays busy and the parallel process never advances.
  eq 0, scene.instance_variable_get(:@state).variables[1]
end

check 'Move Event forces a target map event onto a route' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # auto-start: on load, tell event 2 to walk east
  # target event 2, freq 8, repeat on, skippable on, MOVE_RIGHT.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [2, 8, 1, 1, R::MOVE_RIGHT])]
  mover = event(1, 1, page) # stationary by default; the route drives it
  scene = new_scene({ 1 => event(0, 4, auto), 2 => mover }, player: [5, 0])
  40.times { scene.update }
  c = chars(scene)[2]
  ok c.x > 1, "forced event should have walked east, at x=#{c.x}"
  eq 1, c.y, 'it stayed on its row'
end

check 'Move Event with "this event" moves the running event itself' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target 10005 (this event), freq 8, repeat on, skippable on, MOVE_DOWN.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10005, 8, 1, 1, R::MOVE_DOWN])]
  scene = new_scene({ 1 => event(2, 0, auto) }, player: [5, 4])
  c = chars(scene)[1]
  30.times { scene.update }
  ok c.y > 0, "the event moved itself downward, at y=#{c.y}"
  eq 2, c.x, 'it stayed on its column'
end

check 'a forced player route suppresses input while it runs' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target 10001 (player), freq 8, repeat on, skippable on, MOVE_DOWN.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10001, 8, 1, 1, R::MOVE_DOWN])]
  scene = new_scene({ 1 => event(3, 0, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 8 # hold up: must be ignored while the route drives down
  30.times { scene.update }
  ok st.y > 0, "player was driven downward by the route, at y=#{st.y}"
  eq 0, st.x, 'input (up) was suppressed; player stayed on its column'
end

check 'a non-repeating player route finishes and returns control to input' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target 10001 (player), freq 8, repeat off, skippable on, MOVE_RIGHT.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10001, 8, 0, 1, R::MOVE_RIGHT])]
  scene = new_scene({ 1 => event(3, 3, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  10.times { scene.update } # the route steps the player east once, then ends
  eq [1, 0], [st.x, st.y], 'the one-command route moved the player east'
  RGSS::Input.dir_value = 2 # input works again now the route is done
  20.times { scene.update } # enough frames for the interpolated step to commit
  ok st.y > 0, "input resumed after the route finished, at y=#{st.y}"
end

check 'Erase Event removes the running event from the map' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # auto-start: erase myself
  auto.event_commands = [ECmd.new(ic::ERASE_EVENT, [])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  ok chars(scene)[1], 'event present before it runs'
  5.times { scene.update }
  evs = scene.instance_variable_get(:@events)
  ok evs.none? { |e| e[:id] == 1 }, 'the event is gone from the runtime list'
  tiles = scene.instance_variable_get(:@event_tiles)
  ok !tiles[[2, 2]], 'its occupied tile is cleared (no marker, no collision)'
end

check 'Erase Event stops a parallel process that erases itself' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4) # parallel: bump var 1, then erase myself
  par.event_commands = [add_var_cmd(1), ECmd.new(ic::ERASE_EVENT, [])]
  scene = new_scene({ 1 => event(2, 2, par) }, player: [5, 5])
  10.times { scene.update }
  st = scene.instance_variable_get(:@state)
  eq 1, st.variables[1], 'the process ran once, then erased itself (no re-loop)'
  ok scene.instance_variable_get(:@events).none? { |e| e[:id] == 1 },
     'erased from the event list'
  ok scene.instance_variable_get(:@parallels).empty?,
     'its background process was removed'
end

check 'a message types out gradually, then a button completes and dismisses it' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hello'),
                         ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  # Tick until the message window opens (autostart -> Show Message).
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  ok !reveal.done?, 'text is not fully revealed as soon as it opens'
  before = reveal.revealed

  scene.update # no input: more characters reveal
  ok reveal.revealed > before, 'text keeps revealing over frames'

  # A button press while revealing completes the text but does not dismiss it.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  ok reveal.done?, 'the button press completed the reveal'
  ok scene.instance_variable_get(:@message), 'message stays open once completed'
  ok !st.switches[1], 'the command after the message has not run yet'

  # A second press, now fully shown, dismisses and resumes the interpreter.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  ok !scene.instance_variable_get(:@message), 'message dismissed'
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[1], 'the interpreter resumed and ran the next command'
end

# Tick a scene until its message window opens (or give up after `limit` frames).
def open_msg(scene, limit = 15)
  msg = nil
  limit.times do
    scene.update
    msg = scene.instance_variable_get(:@message)
    break if msg
  end
  msg
end

check 'Message Options positions the message window at the top' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MESSAGE_OPTIONS, [0, 0, 0, 0]), # position top (0), fixed
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = open_msg(scene)
  ok msg, 'message window opened'
  ok msg[:window].y < 60, "top-positioned window should sit near the top, y=#{msg[:window].y}"
end

check 'Change Face Graphic opens a message with a face and insets the text' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::CHANGE_FACE, [2, 0, 0], string: 'Faces1'), # left-side face, cell 2
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = open_msg(scene)
  ok msg, 'message window opened'
  ok msg[:face], 'a face graphic was loaded for the message'
  eq 2, msg[:face_index]
  ok msg[:text_x] > 0, 'text is inset to the right of a left-side face'
end

check 'a right-side face draws on the right and does not inset the text' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::CHANGE_FACE, [0, 1, 0], string: 'Faces1'), # right-side face
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = open_msg(scene)
  ok msg, 'message window opened'
  eq 0, msg[:text_x], 'a right-side face leaves the left text edge in place'
  ok msg[:face_x] > 0, 'the face is drawn on the right side of the contents'
end

check 'Memorize Location stores the player position into variables' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::MEMORIZE_LOCATION, [1, 2, 3])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [3, 4])
  10.times { scene.update }
  st = scene.instance_variable_get(:@state)
  eq 1, st.variables[1], 'map id stored'
  eq 3, st.variables[2], 'x stored'
  eq 4, st.variables[3], 'y stored'
end

check 'Recall to Location teleports the player to the stored position' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Set the destination vars, then recall to (map 1, x 4, y 3).
  auto.event_commands = [
    ECmd.new(ic::CONTROL_VARS, [0, 1, 1, 0, 0, 1]), # var1 = map 1
    ECmd.new(ic::CONTROL_VARS, [0, 2, 2, 0, 0, 4]), # var2 = x 4
    ECmd.new(ic::CONTROL_VARS, [0, 3, 3, 0, 0, 3]), # var3 = y 3
    ECmd.new(ic::RECALL_LOCATION, [1, 2, 3]),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [0, 0])
  20.times { scene.update }
  st = scene.instance_variable_get(:@state)
  eq [4, 3], [st.x, st.y], 'player recalled to the stored tile'
  eq 1, st.map_id, 'on the recalled map'
end

check 'the menu opens on cancel only when menu access is allowed' do
  scene = new_scene({}, player: [2, 2])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)

  st.menu_access = false
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  eq 0, parent.pushed.size, 'menu is suppressed when access is forbidden'

  st.menu_access = true
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  eq 1, parent.pushed.size, 'menu opens once access is allowed'
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k scene check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k scene check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
