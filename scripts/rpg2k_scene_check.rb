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

  # Records its components so the screen-overlay checks can assert the colour a
  # layer was filled with, not just that a fill happened.
  class Color
    attr_reader :red, :green, :blue, :alpha
    def initialize(r = 0, g = 0, b = 0, a = 255)
      @red = r; @green = g; @blue = b; @alpha = a
    end
  end

  # A no-op drawing surface. Records nothing; every draw call is ignored. A
  # String first arg means "load this file": we pretend a standard 480x256
  # chipset (or other graphic) loaded, so Scene::Map exercises the real
  # ChipsetLayout blit path instead of the colour-block fallback.
  class Bitmap
    attr_reader :width, :height
    def initialize(w = 1, h = 1)
      if w.is_a?(String)
        @width = 480; @height = 256
      else
        @width = w.to_i; @height = h.to_i
      end
    end
    def clear; end
    def fill_rect(*a); (@fill_calls ||= []) << a; end
    attr_reader :fill_calls
    def blt(*); end
    def stretch_blt(*); end
    # Record draw_text / blend_text calls so message-rendering checks can assert
    # which path (flat colour vs windowskin blend) was taken.
    def draw_text(*a); (@draw_calls ||= []) << a; end
    def blend_text(*a); (@blend_calls ||= []) << a; end
    attr_reader :draw_calls, :blend_calls
    def text_size(_); Rect.new(0, 0, 0, 0); end
    def font; @font ||= OpenStruct.new; end
    def get_pixel(x, y); Color2.new(x % 256, y % 256, 42, 255); end
    def dispose; end
  end

  # A readable colour (the real Color stub above swallows its args); get_pixel
  # returns one of these so tests can inspect the sampled components.
  Color2 = Struct.new(:red, :green, :blue, :alpha)

  class Sprite
    attr_accessor :bitmap, :x, :y, :z, :visible, :opacity
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
    C = 1; B = 2; UP = 3; DOWN = 4; LEFT = 5; RIGHT = 6; SHIFT = 7
    class << self
      attr_accessor :dir_value, :triggered
    end
    def self.reset; @dir_value = 0; @triggered = []; end
    def self.trigger?(k); Array(@triggered).include?(k); end
    # The scene treats a held key like a triggered one for widget navigation; the
    # stub answers both from the same `triggered` set.
    def self.repeat?(k); Array(@triggered).include?(k); end
    def self.press?(k); Array(@triggered).include?(k); end
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
def fake_chipset(name = 'cs')
  # All tiles passable (no lower table); terrain tag 42 on chip index 0 (the id
  # every tile of the synthetic all-zero map maps to).
  td = Array.new(162, 0)
  td[0] = 42
  OpenStruct.new(name: name, chipset_name: name, passable_data_lower: nil,
                 terrain_data: td)
end

def fake_db(common = nil)
  OpenStruct.new(
    system: OpenStruct.new(system_graphic: ''),
    # A second chipset (id 2) so Change Map Tileset has somewhere to swap to.
    chipset: { 1 => fake_chipset, 2 => fake_chipset('cs2') },
    # Terms the Show Inn window reads; blank greeting fields exercise the
    # scene's English fallbacks.
    term: OpenStruct.new(gold: 'G'),
    # A tiny item table the Open Shop window prices its goods from.
    item: { 3 => OpenStruct.new(name: 'Potion', price: 100),
            5 => OpenStruct.new(name: 'Herb', price: 40) },
    # An enemy and a troop of two, for the placeholder Enemy Encounter victory.
    enemy: { 2 => OpenStruct.new(name: 'Slime', max_hp: 30, max_sp: 0, attack: 8,
                                 defense: 4, spirit: 3, agility: 5, exp: 5,
                                 gold: 10) },
    enemy_group: { 1 => OpenStruct.new(name: 'Slimes', members: {
      1 => OpenStruct.new(enemy_id: 2, x: 0, y: 0, invisible: false),
      2 => OpenStruct.new(enemy_id: 2, x: 0, y: 0, invisible: false) }) },
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
         frequency: 6, direction: 2, charset_name: '', charset_index: 0,
         layer: 0, pattern: 1, animation_type: 0, translucent: false)
  OpenStruct.new(
    condition: nil, direction: direction, move_type: x_move_type, move_speed: 3,
    move_frequency: frequency, charset_name: charset_name,
    charset_index: charset_index, trigger: trigger, event_commands: nil,
    move_route: route, layer: layer, pattern: pattern,
    animation_type: animation_type, translucent: translucent
  )
end

def event(x, y, pg)
  OpenStruct.new(x: x, y: y, pages: { 1 => pg })
end

# The runtime event hash (id => {char:, layer:, anim_type:, ...}) the scene built.
def event_hashes(scene)
  h = {}
  scene.instance_variable_get(:@events).each { |e| h[e[:id]] = e }
  h
end

def move_route(cmd_ids, repeat: true, skippable: true)
  cmds = cmd_ids.map { |id| OpenStruct.new(command_id: id, parameter_string: '',
                                           parameter_a: 0, parameter_b: 0,
                                           parameter_c: 0) }
  OpenStruct.new(commands: cmds, repeat: repeat, skippable: skippable)
end

# A 6x5 map, all tiles walkable, holding the given events (id => ev). `parallax`
# is an optional hash of MAP_UNIT parallax fields merged onto the unit.
def fake_map(id, events, parallax: nil)
  w = 6; h = 5
  fields = { width: w, height: h, chipset_id: 1,
             lower_layer: Array.new(w * h, 0),
             upper_layer: Array.new(w * h, 0), events: events }
  fields.merge!(parallax) if parallax
  Game::Map.new(id, OpenStruct.new(fields))
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
  # Return to Title Screen (12510) hands control back here; record that it fired.
  attr_reader :returned_to_title
  def return_to_title; @returned_to_title = true; end
end

def fake_parent(db)
  FakeParent.new(db) { |id| fake_map(id, {}) }
end

def fake_party
  OpenStruct.new(leader: nil, actors: [])
end

def new_scene(events, player: [0, 0], common: nil, parallax: nil)
  db = fake_db(common)
  state = Game::State.new(fake_party, 1, player[0], player[1])
  state.map = fake_map(1, events, parallax: parallax)
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

# A lightweight party for the inn tests: resume_inn only needs gold + a party
# roster whose members respond to full_heal, and Scene::Map reads party.leader.
class InnStubActor
  attr_accessor :hp, :mp
  attr_reader :max_hp, :max_mp, :name
  def initialize(name); @name = name; @hp = 1; @mp = 0; @max_hp = 100; @max_mp = 30; end
  def full_heal; @hp = @max_hp; @mp = @max_mp; end
end

class InnStubParty
  attr_reader :actors, :gold
  attr_accessor :leader
  def initialize(gold); @gold = gold; @actors = [InnStubActor.new('Hero')]; @leader = nil; end
  def gain_gold(n); @gold += n; end
end

# A party the placeholder battle grants rewards to: gold plus actors that bank
# EXP, with the leader Scene::Map reads while rendering.
class BattleStubActor
  attr_accessor :exp, :hp
  attr_reader :id, :name, :atk, :def, :agi, :max_hp
  # Defaults are strong enough to beat the two-Slime troop the scene db defines;
  # a defeat test passes weaker stats.
  def initialize(atk: 40, dfn: 20, agi: 20, hp: 200)
    @exp = 0; @id = 1; @name = 'Hero'
    @atk = atk; @def = dfn; @agi = agi; @hp = hp; @max_hp = hp
  end
  def gain_exp(n); @exp += n; end
  # Battle write-back (Game::Battle#apply_to_party) sets the actor's post-battle
  # HP absolutely; the stub has no state model, so just clamp to [0, max].
  def set_hp(value); @hp = value < 0 ? 0 : (value > @max_hp ? @max_hp : value); end
  def dead?; @hp <= 0; end
end

class BattleStubParty
  attr_reader :actors, :gold
  attr_accessor :leader
  def initialize(actor = BattleStubActor.new); @actors = [actor]; @gold = 0; @leader = nil; end
  def gain_gold(n); @gold += n; end
  def any_alive?; @actors.any? { |a| !a.dead? }; end
  def all_dead?; !any_alive?; end
end

# A party the shop can charge and stock: gold plus an item-count bag, with the
# leader Scene::Map reads while rendering.
class ShopStubParty
  attr_reader :actors, :gold, :items
  attr_accessor :leader
  def initialize(gold); @gold = gold; @items = {}; @actors = []; @leader = nil; end
  def gain_gold(n); @gold += n; @gold = 0 if @gold < 0; end
  def item_count(id); @items[id] || 0; end
  def gain_item(id, n = 1)
    c = item_count(id) + n
    c = 0 if c < 0
    c = 99 if c > 99
    @items[id] = c
  end
end

# Build an auto-start event running `commands`, with a stub party holding `gold`.
def inn_scene(gold, commands)
  auto = page(trigger: 3)
  auto.event_commands = commands
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, InnStubParty.new(gold))
  [scene, st]
end

# Show Inn followed by [Stay] / [No Stay] handler branches (switch 1 / switch 2),
# closed by INN_END — the standard structured layout.
def inn_commands(ic, price)
  [
    ECmd.new(ic::SHOW_INN, [0, price, 0], indent: 0),
    ECmd.new(ic::INN_STAY, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::INN_NO_STAY, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::INN_END, [], indent: 0)
  ]
end

check 'Show Inn scene: accepting heals the party, spends gold, runs Stay branch' do
  scene, st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 100))
  5.times { scene.update } # inn command runs; the greeting prompt opens
  ok !st.switches[1] && !st.switches[2], 'still waiting on the prompt'
  RGSS::Input.triggered = [RGSS::Input::C] # cursor starts on Accept (affordable)
  scene.update # resumes with a stay
  scene.update # runs the Stay branch
  eq 900, st.party.gold, 'the price was deducted'
  eq st.party.actors.first.max_hp, st.party.actors.first.hp, 'party healed'
  ok st.switches[1], 'the Stay branch ran'
  ok !st.switches[2], 'the No Stay branch was skipped'
end

check 'Show Inn scene: cancelling with B spends nothing and runs No Stay' do
  scene, st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 100))
  5.times { scene.update }
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update # resumes with no stay
  scene.update # runs the No Stay branch
  eq 1000, st.party.gold, 'no gold spent on cancel'
  eq 1, st.party.actors.first.hp, 'no healing on cancel'
  ok !st.switches[1], 'the Stay branch was skipped'
  ok st.switches[2], 'the No Stay branch ran'
end

check 'Show Inn scene: an unaffordable Accept is ignored' do
  scene, st = inn_scene(50, inn_commands(Game::Interpreter::Cmd, 100)) # 50g < 100g
  5.times { scene.update }
  # Cursor starts on Cancel when broke; move up to Accept and press it.
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C]
  3.times { scene.update }
  ok !st.switches[1] && !st.switches[2], 'Accept is inert while unaffordable'
  eq 50, st.party.gold, 'no gold spent'
  # Cancel still works.
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  scene.update
  ok st.switches[2], 'the No Stay branch ran on cancel'
end

check 'Key Input Proc waits for a key, stores its code, then continues' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Wait-mode proc into var 1 accepting Decision + all directions (1.50
  # layout: [var, wait, _, decision, cancel, shift, down, left, right, up]),
  # then flip switch 5 to prove it resumed.
  auto.event_commands = [
    ECmd.new(ic::KEY_INPUT_PROC, [1, 1, 0, 1, 0, 0, 1, 1, 1, 1]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  5.times { scene.update } # no key pressed: the proc keeps waiting
  eq 0, st.variables[1], 'no key yet -> variable stays 0'
  ok !st.switches[5], 'the proc has not resumed'
  RGSS::Input.triggered = [RGSS::Input::C] # press Decision (OK)
  scene.update # this frame resumes the proc and stores the code
  eq 5, st.variables[1], 'Decision stored code 5'
  scene.update # the following command runs once the proc has resumed
  ok st.switches[5], 'the event continued after the key press'
end

check 'Key Input Proc ignores keys it was not told to accept' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Accept Decision only; a Cancel press must not resume it.
  auto.event_commands = [
    ECmd.new(ic::KEY_INPUT_PROC, [1, 1, 0, 1, 0, 0, 0, 0, 0, 0]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  RGSS::Input.triggered = [RGSS::Input::B] # Cancel: not accepted
  3.times { scene.update }
  ok !st.switches[5], 'an unaccepted key must not resume the proc'
  eq 0, st.variables[1]
  RGSS::Input.triggered = [RGSS::Input::C] # Decision: accepted
  scene.update # resumes and stores the code
  eq 5, st.variables[1]
  scene.update # the following command runs
  ok st.switches[5]
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

check 'Halt All Movement cancels a forced player route in the scene' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Force the player onto a repeating downward route, then immediately halt all
  # movement: the route must be cancelled before it can step the player.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10001, 8, 1, 1, R::MOVE_DOWN]),
                         ECmd.new(ic::HALT_ALL_MOVEMENT, [])]
  scene = new_scene({ 1 => event(3, 0, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  20.times { scene.update }
  ok scene.instance_variable_get(:@player_route).nil?,
     'the forced player route was cancelled'
  eq [0, 0], [st.x, st.y], 'the player never moved (movement was halted)'
end

check 'Set Transparent Flag hides and shows the player sprite' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::PLAYER_VISIBILITY, [1])] # transparent ON
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  5.times { scene.update }
  spr = scene.instance_variable_get(:@player_sprite)
  eq false, spr.visible, 'the player sprite is hidden while transparent'
  # A second event turns it back off.
  st = scene.instance_variable_get(:@state)
  st.player_transparent = false
  scene.update
  eq true, spr.visible, 'the player sprite shows again once transparency clears'
end

check 'Return to Title Screen hands control back to the app' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::RETURN_TO_TITLE, [])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  parent = scene.instance_variable_get(:@parent)
  5.times { scene.update }
  ok parent.returned_to_title, 'the app was told to return to the title screen'
end

check 'Change Event Location snaps another event to a tile' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # auto-start: place event 2 at (5, 3)
  auto.event_commands = [ECmd.new(ic::CHANGE_EVENT_LOCATION, [2, 0, 5, 3])]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(1, 1, page) },
                    player: [5, 5])
  5.times { scene.update }
  c = chars(scene)[2]
  eq [5, 3], [c.x, c.y], 'the event was moved to the target tile'
  tiles = scene.instance_variable_get(:@event_tiles)
  ok tiles[[5, 3]] && tiles[[5, 3]][:id] == 2, 'the occupied-tile cache followed'
  ok !tiles[[1, 1]], 'its old tile was released'
end

check 'Change Event Location with "this event" moves the runner itself' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::CHANGE_EVENT_LOCATION, [10005, 0, 4, 4])]
  scene = new_scene({ 1 => event(2, 0, auto) }, player: [5, 5])
  5.times { scene.update }
  c = chars(scene)[1]
  eq [4, 4], [c.x, c.y], 'the running event moved itself'
end

check 'Change Event Location targeting the player snaps the hero' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::CHANGE_EVENT_LOCATION, [10001, 0, 3, 2])]
  scene = new_scene({ 1 => event(0, 0, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  5.times { scene.update }
  eq [3, 2], [st.x, st.y], 'the player was moved to the target tile'
end

check 'Trade Event Locations swaps two events' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # auto-start: swap this event (1) with event 2
  auto.event_commands = [ECmd.new(ic::TRADE_EVENT_LOCATIONS, [10005, 2])]
  scene = new_scene({ 1 => event(2, 2, auto), 2 => event(4, 1, page) },
                    player: [5, 5])
  5.times { scene.update }
  a = chars(scene)[1]
  b = chars(scene)[2]
  eq [4, 1], [a.x, a.y], 'event 1 took event 2 old tile'
  eq [2, 2], [b.x, b.y], 'event 2 took event 1 old tile'
end

check 'Change Map Tileset rebuilds the map chipset from the new id' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::CHANGE_MAP_TILESET, [2])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  eq 'cs', scene.instance_variable_get(:@chipset).name, 'starts on chipset 1'
  5.times { scene.update }
  eq 'cs2', scene.instance_variable_get(:@chipset).name,
     'the chipset was rebuilt from the requested tileset id'
  eq 2, scene.instance_variable_get(:@tileset_id), 'the override id is recorded'
end

check 'Input Number opens a widget; confirming stores the entered value' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Two digits into variable 5, then flip switch 1 so we can see it resumed.
  auto.event_commands = [ECmd.new(ic::INPUT_NUMBER, [2, 5]),
                         ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  ni = nil
  12.times do
    scene.update
    ni = scene.instance_variable_get(:@number_input)
    break if ni
  end
  ok ni, 'the number-entry widget opened'

  RGSS::Input.triggered = [RGSS::Input::UP] # tens digit 0 -> 1 (value 10)
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C]  # confirm
  scene.update
  ok !scene.instance_variable_get(:@number_input), 'the widget closed on confirm'
  5.times { RGSS::Input.reset; scene.update }
  eq 10, st.variables[5], 'the entered value landed in variable 5'
  ok st.switches[1], 'the interpreter resumed and ran the next command'
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

check 'a teleport clears every shown picture' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    # Show a full-screen picture, then teleport to map 1. RPG2000 drops the
    # picture on the map change, so it cannot cover the destination map.
    ECmd.new(ic::SHOW_PICTURE, [1, 0, 160, 120, 0, 100, 0, 1, 0, 0, 0, 0],
             string: 'pic'),
    ECmd.new(ic::TELEPORT, [1, 4, 3]),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update
  ok st.pictures.key?(1), 'the picture is shown before the teleport'
  20.times { scene.update }
  eq 1, st.map_id, 'teleported'
  ok st.pictures.empty?, 'the picture did not survive the map change'
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

check 'Store Terrain / Event ID query the map through the scene' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::STORE_TERRAIN_ID, [0, 1, 1, 1]), # terrain at (1,1) -> var1
    ECmd.new(ic::STORE_EVENT_ID, [0, 3, 1, 2]),   # event 2 sits at (3,1) -> var2
    ECmd.new(ic::STORE_EVENT_ID, [0, 5, 0, 3]),   # empty tile -> var3
  ]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(3, 1, page) },
                    player: [5, 5])
  10.times { scene.update }
  st = scene.instance_variable_get(:@state)
  eq 42, st.variables[1], 'terrain tag read from the chipset'
  eq 2, st.variables[2], 'id of the event at (3,1)'
  eq 0, st.variables[3], 'no event at the empty tile'
end

check 'Proceed With Movement holds the interpreter until a forced route finishes' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Force event 2 to walk right 3 tiles (freq 4, repeat off), wait for it, then
  # flip switch 1 — which must not happen until the route completes.
  auto.event_commands = [
    ECmd.new(ic::MOVE_EVENT,
             [2, 4, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]),
    ECmd.new(ic::PROCEED_WITH_MOVEMENT, []),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(0, 1, page) },
                    player: [5, 5])
  st = scene.instance_variable_get(:@state)
  c = chars(scene)[2]

  10.times { scene.update } # mid-route: still moving, switch not yet flipped
  ok c.x < 3, "route still in progress, at x=#{c.x}"
  ok !st.switches[1], 'the command after Proceed With Movement waits'

  200.times { scene.update } # enough frames for the freq-4 route to finish
  eq 3, c.x, 'the forced event reached the end of its route'
  ok st.switches[1], 'the interpreter resumed and ran the next command'
end

check 'Tint Screen with a wait holds the interpreter until the tint settles' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::TINT_SCREEN, [200, 100, 100, 100, 5, 1]), # red over 0.5s, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  10.times { scene.update } # mid-transition: still tinting, switch not flipped
  ok st.screen.tinting?, 'the tint is still transitioning'
  ok !st.switches[1], 'the command after the tint waits'

  60.times { scene.update } # enough frames (30) for the tint to settle
  eq 200, st.screen.tint[0], 'the tint reached its target'
  ok st.switches[1], 'the interpreter resumed once the tint settled'
end

check 'Shake Screen with a wait holds the interpreter and renders with an offset' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHAKE_SCREEN, [6, 5, 3, 1]), # power 6, speed 5, 0.3s, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  5.times { scene.update } # mid-shake: rendering runs with a non-zero offset
  ok st.screen.shaking?, 'still shaking'
  ok !st.switches[1], 'the command after the shake waits'

  40.times { scene.update } # 0.3s -> 18 frames, plenty
  ok !st.screen.shaking?, 'the shake ended'
  ok st.switches[1], 'the interpreter resumed after the shake'
end

check 'Flash Screen with a wait holds the interpreter until the flash fades' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::FLASH_SCREEN, [255, 255, 255, 31, 3, 1]), # white, 0.3s, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  5.times { scene.update } # mid-flash: still fading, switch not yet flipped
  ok st.screen.flashing?, 'still flashing'
  ok !st.switches[1], 'the command after the flash waits'

  40.times { scene.update } # 0.3s -> 18 frames, plenty
  ok !st.screen.flashing?, 'the flash faded out'
  ok st.switches[1], 'the interpreter resumed after the flash'
end

# -- event graphic rendering --------------------------------------------------

check 'an event page facing is converted from LCF (0..3) to numpad' do
  # LCF facing 1 = right -> numpad 6; 0 = up -> 8; 3 = left -> 4.
  { 0 => 8, 1 => 6, 2 => 2, 3 => 4 }.each do |lcf, numpad|
    ev = event(2, 2, page(direction: lcf))
    scene = new_scene({ 1 => ev })
    eq numpad, chars(scene)[1].direction, "LCF dir #{lcf}"
  end
end

check 'build_event captures the page graphic + layer fields' do
  ev = event(2, 2, page(charset_name: 'hero', charset_index: 3, layer: 2,
                        pattern: 2, animation_type: Game::EventGraphic::SPIN,
                        translucent: true))
  e = event_hashes(new_scene({ 1 => ev }))[1]
  eq 'hero', e[:char].graphic_name
  eq 3, e[:char].graphic_index
  eq 2, e[:layer]
  eq 2, e[:base_pattern]
  eq Game::EventGraphic::SPIN, e[:anim_type]
  ok e[:translucent], 'translucent page flagged'
end

check 'events route into the tile buffer matching their layer / y-order' do
  below = event(2, 2, page(charset_name: 'c', layer: 0))
  above = event(3, 2, page(charset_name: 'c', layer: 2))
  # Same-layer events sort around the player (at y=4 below both): a same-layer
  # event north of the player (smaller y) draws behind him, south draws in front.
  same_behind = event(4, 1, page(charset_name: 'c', layer: 1))
  same_front  = event(5, 4, page(charset_name: 'c', layer: 1))
  scene = new_scene({ 1 => below, 2 => above, 3 => same_behind, 4 => same_front },
                    player: [0, 3])
  eh = event_hashes(scene)
  lower = scene.instance_variable_get(:@lower_bmp)
  upper = scene.instance_variable_get(:@upper_bmp)
  eq lower, scene.send(:event_target_buffer, eh[1]), 'below-hero -> lower'
  eq upper, scene.send(:event_target_buffer, eh[2]), 'above-hero -> upper'
  eq lower, scene.send(:event_target_buffer, eh[3]), 'same layer, north -> lower'
  eq upper, scene.send(:event_target_buffer, eh[4]), 'same layer, south -> upper'
end

check 'a wandering event cycles its walk phase; a stationary one rests' do
  mover = event(3, 2, page(charset_name: 'c', x_move_type: Game::MoveType::RANDOM))
  still = event(1, 1, page(charset_name: 'c')) # stationary, non-continuous
  scene = new_scene({ 1 => mover, 2 => still }, player: [5, 4])
  eh = event_hashes(scene)
  slid = false
  200.times { scene.update; slid ||= eh[1][:moving] }
  ok slid, 'a random mover slides between tiles at some point'
  ok [eh[1][:char].x, eh[1][:char].y] != [3, 2], 'the mover changed tiles'
  ok eh[1][:anim_phase] != 0, 'the mover advanced its walk animation while sliding'
  ok !eh[2][:moving], 'a stationary event never slides'
  eq [1, 1], [eh[2][:char].x, eh[2][:char].y], 'the stationary event held its tile'
  eq 0, eh[2][:anim_phase], 'a stationary non-continuous event holds its pose'
end

check 'an event slides smoothly between tiles instead of teleporting' do
  # A forced route walks the event one tile east; sample its pixel position
  # through the step and confirm it eases across rather than jumping a full tile.
  ev = event(0, 2, page(charset_name: 'c', frequency: 6))
  scene = new_scene({ 1 => ev }, player: [5, 4])
  e = event_hashes(scene)[1]
  scene.send(:force_event_route, e,
             Game::MoveRoute.new(move_route([R::MOVE_RIGHT]).commands,
                                 repeat: false, skippable: true), nil)
  xs = []
  20.times { scene.update; xs << scene.send(:event_pixel, e)[0] }
  ok xs.include?(16), 'the slide completes on the destination tile (x px 16)'
  mids = xs.select { |px| px.positive? && px < 16 }
  ok !mids.empty?, "expected intermediate pixel offsets during the slide, got #{xs.inspect}"
  ok xs.each_cons(2).all? { |a, b| b >= a }, 'the slide advances monotonically east'
end

check 'a multi-tile hop snaps rather than streaking across the map' do
  # Reoccupy with a >1-tile jump should not start a slide (move_count stays at
  # TILE, so event_pixel is the destination tile immediately).
  ev = event(1, 1, page(charset_name: 'c'))
  scene = new_scene({ 1 => ev })
  e = event_hashes(scene)[1]
  e[:char].x = 4 # simulate a jump landing (2 tiles east)
  scene.send(:reoccupy, e, 1, 1)
  eq RPG2k::Scene::Map::TILE, e[:move_count], 'a long hop does not slide'
  eq [4 * RPG2k::Scene::Map::TILE, 1 * RPG2k::Scene::Map::TILE],
     scene.send(:event_pixel, e), 'it snaps to the destination tile'
end

check 'a continuous-animation event advances even while standing still' do
  ev = event(2, 2, page(charset_name: 'c',
                        animation_type: Game::EventGraphic::CONTINUOUS))
  scene = new_scene({ 1 => ev }, player: [5, 4])
  40.times { scene.update }
  e = event_hashes(scene)[1]
  eq [2, 2], [e[:char].x, e[:char].y], 'it did not move'
  ok e[:anim_phase] != 0, 'but its walk animation kept cycling'
end

check 'a map with a looping, autoscrolling parallax renders without raising' do
  scene = new_scene({}, parallax: {
    parallax_flag: true, parallax_name: 'BG',
    parallax_loop_x: true, parallax_loop_y: true,
    parallax_autoloop_x: true, parallax_sx: 4,
    parallax_autoloop_y: false, parallax_sy: 0
  })
  ok scene.instance_variable_get(:@parallax_sprite), 'a parallax sprite is built'
  ok scene.instance_variable_get(:@parallax_sprite).z < 0, 'drawn behind the tiles'
  20.times { scene.update } # exercises the tiling + autoscroll draw path
  ok true
end

check 'a map with no parallax builds no backdrop sprite' do
  scene = new_scene({})
  ok scene.instance_variable_get(:@parallax_sprite).nil?, 'no parallax sprite'
  5.times { scene.update }
  ok true
end

check 'a shown picture renders through the scene and its move advances' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  ok scene.instance_variable_get(:@picture_sprite), 'a picture layer sprite exists'
  ok scene.instance_variable_get(:@picture_sprite).z < 300, 'below the message window'
  # Show a picture on the state, start a move, then let the scene loop drive it:
  # each update advances the pictures and re-renders (which must not raise).
  st.show_picture(1, name: 'pic', x: 160, y: 120, zoom: 100, opacity: 255)
  st.move_picture(1, 160, 60, 200, 128, 100, 100, 100, 100, 6)
  ok st.pictures_moving?, 'the picture is moving'
  6.times { scene.update }
  ok !st.pictures_moving?, 'the move completed under the scene loop'
  eq 60, st.pictures[1].y, 'the picture reached its target'
end

check 'coloured message text blends with the windowskin swatch when present' do
  scene = new_scene({})
  skin = RGSS::Bitmap.new('System/skin')
  scene.instance_variable_set(:@windowskin, skin)
  c = RGSS::Bitmap.new(100, 20)
  scene.send(:draw_message_run, c, 4, 0, 80, { text: 'hi', color: 3 })
  bc = c.blend_calls
  # RPG_RT draws each glyph twice: the shadow first, one pixel down and right,
  # then the glyph from the colour swatch.
  ok bc && bc.size == 2, 'blend_text was used for the shadow and the glyph'
  sxx, syy, sww, _sh2, stxt, ssrc, ssx, ssy = bc[0]
  eq [5, 1, 80], [sxx, syy, sww], 'shadow offset by one pixel'
  eq 'hi', stxt
  eq skin, ssrc, 'shadow blended against the windowskin'
  eq [16, 32], [ssx, ssy], 'shadow taken from the System shadow block'
  x, y, w, _h, txt, src, sx, sy, sw, sh = bc[1]
  eq [4, 0, 80], [x, y, w]
  eq 'hi', txt
  eq skin, src, 'blended against the windowskin'
  # colour 3 -> swatch cell (3%10*16, 3/10*16+48) = (48, 48), 16x16.
  eq [48, 48, 16, 16], [sx, sy, sw, sh]
  ok (c.draw_calls || []).empty?, 'no flat draw_text used'
end

check 'message text falls back to a flat colour without a windowskin' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, nil)
  c = RGSS::Bitmap.new(100, 20)
  scene.send(:draw_message_run, c, 4, 0, 80, { text: 'hi', color: 3 })
  ok (c.blend_calls || []).empty?, 'no blend without a windowskin'
  eq 1, (c.draw_calls || []).size, 'flat draw_text used'
end

check 'an out-of-range colour index falls back to a flat colour' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, RGSS::Bitmap.new('System/skin'))
  c = RGSS::Bitmap.new(100, 20)
  scene.send(:draw_message_run, c, 0, 0, 80, { text: 'x', color: 99 })
  ok (c.blend_calls || []).empty?, 'an invalid \\c[n] index does not blend'
  eq 1, (c.draw_calls || []).size, 'flat draw_text used'
  ok scene.send(:message_color, 99), 'out-of-range flat colour is safe'
end

check 'rendering a map with charset + tile-substitution events does not raise' do
  charset_ev = event(2, 2, page(charset_name: 'npc', charset_index: 1, layer: 1))
  tile_ev    = event(3, 3, page(charset_name: '', charset_index: 97, layer: 0))
  invisible  = event(4, 4, page(charset_name: '', charset_index: 0, trigger: 1))
  scene = new_scene({ 1 => charset_ev, 2 => tile_ev, 3 => invisible })
  10.times { scene.update }
  ok true
end

check 'Pan Screen locks the camera and holds the interpreter while scrolling' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::PAN_SCREEN, [0, 0, 0, 0, 0]), # lock the camera in place
    ECmd.new(ic::PAN_SCREEN, [2, 1, 5, 2, 1]), # pan right 5 tiles, speed 2, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [3, 3])
  st = scene.instance_variable_get(:@state)

  5.times { scene.update } # mid-scroll: renders with a locked, panned camera
  ok st.screen.pan_locked?, 'the camera is locked'
  ok st.screen.panning?, 'still scrolling (80 px at 2 px/frame)'
  ok !st.switches[1], 'the command after the pan waits'

  80.times { scene.update } # 80 px at 2 px/frame -> 40 frames, plenty
  ok !st.screen.panning?, 'the pan reached its target'
  eq [80, 0], st.screen.pan_offset
  ok st.switches[1], 'the interpreter resumed after the pan'
end

check 'Erase Screen pauses the event until the fade settles, then continues' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::ERASE_SCREEN, [0]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  scene.update # runs Erase Screen -> suspends on :screen
  ok !st.switches[5], 'the event pauses while the screen fades'
  ok st.screen.fading?, 'the fade is in progress'
  40.times { scene.update } # the scene advances Game::Screen each frame
  eq 255, st.screen.fade_level, 'the screen is fully erased'
  ok st.screen.erased?, 'held erased'
  ok st.switches[5], 'the event resumed after the fade settled'
end

check 'Open Shop scene: buying then leaving runs the Transaction branch' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::OPEN_SHOP, [1, 0, 0, 0, 3, 5], indent: 0), # buy-only, goods 3/5
    ECmd.new(ic::SHOP_TRANSACTION, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::SHOP_NO_TRANSACTION, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::SHOP_END, [], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, ShopStubParty.new(500))
  3.times { scene.update } # the shop opens straight to the buy list (buy-only)
  ok !st.switches[1] && !st.switches[2], 'still shopping'
  RGSS::Input.triggered = [RGSS::Input::C] # buy the first good (id 3 @ 100)
  scene.update
  RGSS::Input.triggered = []
  scene.update
  eq 400, st.party.gold, 'one Potion bought'
  eq 1, st.party.item_count(3)
  RGSS::Input.triggered = [RGSS::Input::B] # leave the shop
  scene.update
  scene.update # the Transaction branch runs
  ok st.switches[1], 'the Transaction branch ran (a purchase happened)'
  ok !st.switches[2], 'the No Transaction branch was skipped'
end

check 'Open Shop scene: leaving without buying runs the No Transaction branch' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::OPEN_SHOP, [1, 0, 0, 0, 3], indent: 0),
    ECmd.new(ic::SHOP_TRANSACTION, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::SHOP_NO_TRANSACTION, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::SHOP_END, [], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, ShopStubParty.new(500))
  3.times { scene.update }
  RGSS::Input.triggered = [RGSS::Input::B] # leave immediately
  scene.update
  scene.update
  eq 500, st.party.gold, 'no gold spent'
  ok !st.switches[1], 'the Transaction branch was skipped'
  ok st.switches[2], 'the No Transaction branch ran'
end

# Battle command / result command lists for the encounter tests below.
def battle_event_commands(ic, escape_mode: 0, second_switch_code: nil)
  handler2 = second_switch_code || ic::ESCAPE_HANDLER
  [
    ECmd.new(ic::ENEMY_ENCOUNTER, [0, 1, 0, escape_mode, 1, 0], indent: 0),
    ECmd.new(ic::VICTORY_HANDLER, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(handler2, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, (handler2 == ic::DEFEAT_HANDLER ? 3 : 2),
                                    (handler2 == ic::DEFEAT_HANDLER ? 3 : 2), 0], indent: 1),
    ECmd.new(ic::END_BATTLE, [], indent: 0)
  ]
end

# Drive a battle by having each living actor Attack the first enemy every round
# until the result window appears (command / target cursors start on Attack /
# the first target).
def battle_attack_to_end(scene, max = 100)
  max.times do
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:phase] == :result
    RGSS::Input.triggered = [RGSS::Input::C] if ui && %i[command target].include?(ui[:phase])
    scene.update # a nil ui just means the battle is still opening
    RGSS::Input.triggered = []
  end
end

check 'Enemy Encounter scene: winning (per-actor Attack) grants rewards, runs Victory' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  scene.update # opens the per-actor command menu (Attack / Defend)
  eq 0, st.party.gold, 'no rewards mid-battle'
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  eq 20, st.party.gold, 'gained the troop gold (2 Slimes x 10)'
  eq 10, st.party.actors.first.exp, 'gained the troop EXP (2 Slimes x 5)'
  ok !st.switches[1], 'showing the Victory result'
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss result
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update }
  ok st.switches[1], 'the Victory handler ran'
  ok !st.switches[2], 'the Escape handler was skipped'
end

check 'Enemy Encounter scene: losing shows the defeat result, no rewards' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, second_switch_code: ic::DEFEAT_HANDLER)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  # A frail hero the two Slimes overwhelm.
  st.instance_variable_set(:@party,
                           BattleStubParty.new(BattleStubActor.new(atk: 6, dfn: 0, agi: 3, hp: 10)))
  scene.update
  battle_attack_to_end(scene)
  ok !st.switches[1] && !st.switches[3], 'defeat result window is up'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update }
  eq 0, st.party.gold, 'no gold on a loss'
  eq 0, st.party.actors.first.exp, 'no EXP on a loss'
  ok !st.switches[1], 'the Victory handler was skipped'
  ok st.switches[3], 'the Defeat handler ran'
end

check 'Enemy Encounter scene: a game-over defeat returns to the title' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # A bare encounter with defeat mode 0 (game over) and no handler block.
  auto.event_commands = [ECmd.new(ic::ENEMY_ENCOUNTER, [0, 1, 0, 0, 0, 0], indent: 0)]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  # A frail hero the two Slimes overwhelm.
  st.instance_variable_set(:@party,
                           BattleStubParty.new(BattleStubActor.new(atk: 6, dfn: 0, agi: 3, hp: 10)))
  scene.update
  battle_attack_to_end(scene)
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the defeat result window
  scene.update
  RGSS::Input.triggered = []
  # finish_battle wrote the wipe back to the party, then went to the title.
  ok st.party.all_dead?, 'the party was wiped out'
  parent = scene.instance_variable_get(:@parent)
  ok parent.returned_to_title, 'a game-over defeat returns to the title screen'
end

check 'Enemy Encounter scene: Flee (B on the first actor) runs Escape' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2) # custom escape handler
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  2.times { scene.update } # the encounter runs, then the command menu opens
  RGSS::Input.triggered = [RGSS::Input::B] # Flee (cancel on the first actor)
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update } # interpreter resumes -> Escape handler
  eq 0, st.party.gold, 'fleeing grants nothing'
  ok !st.switches[1], 'the Victory handler was skipped'
  ok st.switches[2], 'the Escape handler ran'
end

# -- headless title auto-select (--rpg2k_new_game / --rpg2k_continue) ---------
#
# Both flags exist so a headless run can leave the title screen without input:
# CI's boot smoke uses New Game, and the save comparison
# (scripts/compare-nepheshel-save-wine.bash) uses Continue. The invariant worth
# pinning is that each fires *once* -- it is checked every frame, and a
# re-triggering flag would re-enter the scene forever.
#
# Scene::Title needs graphics to construct, so the selector is exercised on a
# bare instance: these methods only read the flag constants and set
# @selected_index.
def title_selector(flag)
  scene = RPG2k::Scene::Title.allocate
  scene.instance_variable_set(:@auto_started, false)
  scene.instance_variable_set(:@selected_index, 0)
  Object.const_set(flag, true) unless Object.const_defined?(flag)
  scene
end

def clear_title_flags
  %i[RPG2K_NEW_GAME RPG2K_CONTINUE].each do |f|
    Object.send(:remove_const, f) if Object.const_defined?(f)
  end
end

check '--rpg2k_continue selects the title screen Continue entry, once' do
  clear_title_flags
  scene = title_selector(:RPG2K_CONTINUE)
  ok scene.send(:auto_select?), 'the first frame fires the auto-select'
  eq 1, scene.instance_variable_get(:@selected_index), 'Continue is entry 2'
  ok !scene.send(:auto_select?), 'it does not fire again on the next frame'
  clear_title_flags
end

check '--rpg2k_new_game selects New Game, and wins over --rpg2k_continue' do
  clear_title_flags
  scene = title_selector(:RPG2K_NEW_GAME)
  Object.const_set(:RPG2K_CONTINUE, true)
  ok scene.send(:auto_select?), 'the first frame fires the auto-select'
  # New Game needs no save data, so it is the entry that cannot fail for an
  # unrelated reason when both flags are set.
  eq 0, scene.instance_variable_get(:@selected_index), 'New Game is entry 1'
  clear_title_flags
end

check 'neither flag set leaves the title screen waiting for input' do
  clear_title_flags
  scene = RPG2k::Scene::Title.allocate
  scene.instance_variable_set(:@auto_started, false)
  scene.instance_variable_set(:@selected_index, 0)
  ok !scene.send(:auto_select?), 'no auto-select without a flag'
end

# -- screen fade / flash overlays ---------------------------------------------
#
# Erase/Show Screen and Flash Screen are drawn as two full-screen colour sprites
# above everything (RPG2000 fades and flashes the message window too), shown at
# the effect's own 0..255 strength through Sprite#opacity. docs/TODO.md had these
# down as needing native alpha support first; they do not -- Sprite#opacity is
# already LVGL's per-object alpha -- and a forced mid-fade halves the rendered
# frame's brightness in the real binary, which is what motivated writing them.
#
# What is worth pinning here is the wiring: the levels reach the sprites, and the
# flash layer is not re-filled on frames where its colour has not changed (it is
# a screen-sized fill per frame otherwise, to produce an identical image).
def overlay(scene)
  [scene.instance_variable_get(:@fade_sprite),
   scene.instance_variable_get(:@flash_sprite)]
end

check 'Erase/Show Screen drives the fade layer opacity' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  eq 0, fade.opacity, 'nothing erased yet, so the fade layer is invisible'

  st = scene.instance_variable_get(:@state)
  st.screen.erase(0, 1) # fade fully out over one frame
  4.times { scene.update }
  eq 255, fade.opacity, 'a completed Erase Screen leaves the screen black'

  st.screen.show(0, 1)
  4.times { scene.update }
  eq 0, fade.opacity, 'Show Screen brings it back'
end

check 'Flash Screen drives the flash layer, and refills only on a colour change' do
  scene = new_scene({}, player: [5, 5])
  _, flash = overlay(scene)
  scene.update
  eq 0, flash.opacity, 'no flash, no overlay'

  st = scene.instance_variable_get(:@state)
  st.screen.flash(31, 0, 0, 200, 20) # red
  scene.update
  fills = flash.bitmap.fill_calls || []
  eq 1, fills.length, 'the flash layer is filled once when the colour is set'
  eq [31, 0, 0], fills.last[4].then { |c| [c.red, c.green, c.blue] },
     'filled with the flash colour'
  eq true, flash.opacity > 0, 'the flash layer is visible while flashing'

  # Same colour on the next frame: the strength changes, the fill does not.
  before = flash.opacity
  scene.update
  eq 1, (flash.bitmap.fill_calls || []).length,
     'an unchanged colour does not re-fill the screen-sized layer'
  eq true, flash.opacity <= before, 'the flash decays'
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k scene check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k scene check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
