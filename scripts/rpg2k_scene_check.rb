#!/usr/bin/env ruby
# encoding: UTF-8
#
# Integration smoke-test for the map scene's event-movement wiring.
#
# Unlike scripts/rpg2k_logic_check.rb (which exercises the pure Game:: logic in
# isolation), this loads the *actual* Scene::Map from mruby-rpg2k/mrblib/scene/
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
    # Recorded so the bush-depth checks can assert *how* a character frame was
    # laid down — one blit or a split pair, and at what opacity — rather than
    # only that drawing happened.
    def blt(*a); (@blt_calls ||= []) << a; end
    attr_reader :blt_calls
    def clear_blt_calls; @blt_calls = []; end
    def stretch_blt(*); end
    # Record the tone a Flash Sprite pass asks for, so the flash checks can
    # assert the colour actually reached the renderer.
    def tone_blt(src, tone); (@tone_calls ||= []) << [src, tone]; self; end
    attr_reader :tone_calls
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

  # RGSS Tone, as tone_blt (the Flash Sprite pass) takes it.
  Tone = Struct.new(:red, :green, :blue, :gray)

  class Sprite
    attr_accessor :bitmap, :x, :y, :z, :visible, :opacity
    # Which viewport the sprite was built in, so the tone checks can assert that
    # the map layers share one and the overlays do not.
    attr_reader :viewport
    def initialize(viewport = nil, *); @viewport = viewport; end
    def dispose; end
  end

  class Viewport
    attr_accessor :z, :visible, :rect
    # The screen tone rides on a viewport (Scene::Map#update_map_tone), so the
    # stub records what was set on it and how often it was pushed.
    attr_accessor :tone, :color
    attr_reader :updates
    def initialize(*); @updates = 0; end
    def update; @updates += 1; end
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
    # Record bgm_play calls so BGM checks (the vehicle music, the Game Over
    # screen) can assert which track started.
    class << self; attr_accessor :bgm_calls; end
    def self.bgm_play(*a); (@bgm_calls ||= []) << a; end
    def self.reset_bgm; @bgm_calls = []; end
    def self.bgm_fade(*); end
    def self.bgm_stop(*); end
    # Scriptable playback position, so the "BGM played once" watcher can be
    # driven: a value that jumps backwards is how SDL_mixer reports a loop.
    class << self; attr_accessor :pos; end
    def self.bgm_pos; @pos || 0; end
    # Record se_play calls so system-SFX checks can assert which sound fired.
    class << self; attr_accessor :se_calls; end
    def self.se_play(*a); (@se_calls ||= []) << a; end
    def self.reset_se; @se_calls = []; end
  end

  def self.warn_stub(*); end
  class Timeout < StandardError; end
end

lib = File.expand_path('../mruby-rpg2k/mrblib', __dir__)
load File.join(lib, 'game.rb')
load File.join(lib, 'interpreter.rb')
load File.join(lib, 'main.rb')
Dir[File.join(lib, 'scene', '*.rb')].sort.each { |path| load path }

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
  # The upper passage table marks chip 0 as a counter, so a test can lay a
  # counter tile by putting BLOCK_F in the upper layer.
  up = Array.new(144, 0)
  up[0] = Game::ChipSet::COUNTER_BIT
  OpenStruct.new(name: name, chipset_name: name, passable_data_lower: nil,
                 passable_data_upper: up, terrain_data: td)
end

# A map whose upper layer carries a counter tile at each of `counters`.
def fake_map_with_counters(id, events, counters)
  w = 6; h = 5
  upper = Array.new(w * h, 1) # 1 is not an upper tile id, so: no counter
  counters.each { |x, y| upper[y * w + x] = Game::ChipsetLayout::BLOCK_F }
  Game::Map.new(id, OpenStruct.new(width: w, height: h, chipset_id: 1,
                                   lower_layer: Array.new(w * h, 0),
                                   upper_layer: upper, events: events))
end

def fake_db(common = nil, troop_pages = nil, terrain_damage = 0, bush_depth = 0,
            airship_land: true, airship_pass: true)
  OpenStruct.new(
    system: OpenStruct.new(system_graphic: '', title: 'TitleGraphic',
                           boat_music: OpenStruct.new(file: 'BoatBGM', volume: 80, pitch: 100),
                           ship_music: OpenStruct.new(file: 'ShipBGM', volume: 80, pitch: 100),
                           airship_music: OpenStruct.new(file: 'AirBGM', volume: 80, pitch: 100),
                           cursor_se: OpenStruct.new(file: 'Cursor1', volume: 100, pitch: 100),
                           decision_se: OpenStruct.new(file: 'Decision1', volume: 100, pitch: 100),
                           # The battle per-hit sounds (Scene::Map::DB_SE_FIELD).
                           enemy_damaged_se: OpenStruct.new(file: 'EnemyHit', volume: 100, pitch: 100),
                           actor_damaged_se: OpenStruct.new(file: 'ActorHit', volume: 100, pitch: 100),
                           dodge_se: OpenStruct.new(file: 'Dodge1', volume: 100, pitch: 100),
                           enemy_death_se: OpenStruct.new(file: 'EnemyKill', volume: 100, pitch: 100),
                           item_se: OpenStruct.new(file: 'ItemUse', volume: 100, pitch: 100),
                           gameover_name: 'GameOver1',
                           gameover_music: OpenStruct.new(file: 'GameOverBGM', volume: 90, pitch: 100)),
    # A second chipset (id 2) so Change Map Tileset has somewhere to swap to.
    chipset: { 1 => fake_chipset, 2 => fake_chipset('cs2') },
    # Terms the Show Inn window reads; blank greeting fields exercise the
    # scene's English fallbacks. `normal_status` is what the battle status
    # window shows for a battler carrying no state.
    # The battle sentences RPG_RT keeps in the 用語 table, as *predicates* the
    # battler's name goes in front of. `observing` is deliberately left blank so
    # the scene's fallback wording is exercised.
    term: OpenStruct.new(gold: 'G', normal_status: 'Normal',
                         attacking: 'の攻撃！', defending: 'は身を守っている',
                         observing: '', focus: 'は力をためている・・・',
                         autodestruction: 'は自爆した！',
                         enemy_escape: 'は逃げてしまった！',
                         enemy_transform: 'は変身した！',
                         enemy_damaged: 'のダメージを与えた！',
                         actor_damaged: 'のダメージを受けた！',
                         enemy_undamaged: 'にダメージを与えられない！',
                         actor_undamaged: 'はダメージを受けていない！',
                         dodge: 'は身をかわした！',
                         skill_failure_a: 'には効かなかった！',
                         skill_failure_b: 'は平気だった！',
                         skill_failure_c: 'は眠らなかった！',
                         use_item: 'を使った！', hp_recovery: '回復した！',
                         hp: 'ＨＰ', mp: 'ＭＰ',
                         enemy_hp_absorbed: '奪った！',
                         actor_hp_absorbed: '奪われた！'),
    # Skill rows for the battle log: RPG2000 gives each skill its own two
    # sentences. Skill 8 sets both, 9 only the first, 10 neither (an
    # English-release row), and 11 picks the second failure sentence.
    skill: { 8 => OpenStruct.new(name: 'Fire', using_message1: 'は炎を放った！',
                                 using_message2: 'あたりが真っ赤に染まる！',
                                 failure_message: 0, animation_id: 8),
             9 => OpenStruct.new(name: 'Heal', using_message1: 'は光をまとった！',
                                 using_message2: '', failure_message: 0,
                                 animation_id: 0),
             10 => OpenStruct.new(name: 'Mute', using_message1: '',
                                  using_message2: '', failure_message: 0),
             11 => OpenStruct.new(name: 'Sleep', using_message1: 'は呪文を唱えた！',
                                  using_message2: '', failure_message: 2) },
    # The state table the battle status window and action banner read: a name, a
    # palette colour, the priority that decides which one a battler shows, and
    # RPG2000's own sentences for it landing and lifting. State 5 deliberately
    # ships no sentences, so the scene's own fallback wording is exercised.
    situation: { 1 => OpenStruct.new(name: 'Down', color: 14, priority: 100,
                                     message_actor: ' falls!',
                                     message_enemy: ' is struck down!',
                                     message_recovery: ' stands up!'),
                 # Poison also slips on the map, the way mtf-meido-action's does
                 # (the only state in either test bed that carries the field):
                 # 1 HP every 4 walked tiles.
                 3 => OpenStruct.new(name: 'Poison', color: 2, priority: 30,
                                     message_actor: ' is poisoned!',
                                     message_enemy: ' looks ill!',
                                     message_recovery: ' is cured.',
                                     message_already: ' is already poisoned!',
                                     hp_change_map_steps: 4,
                                     hp_change_map_val: 1),
                 4 => OpenStruct.new(name: 'Sleep', color: 4, priority: 80),
                 5 => OpenStruct.new(name: 'Silence', color: 5, priority: 10) },
    # A tiny item table the Open Shop window prices its goods from.
    item: { 3 => OpenStruct.new(name: 'Potion', price: 100),
            5 => OpenStruct.new(name: 'Herb', price: 40) },
    # An enemy and a troop of two, for the placeholder Enemy Encounter victory.
    enemy: { 2 => OpenStruct.new(name: 'Slime', battler_name: 'Slime',
                                 max_hp: 30, max_sp: 0, attack: 8,
                                 defense: 4, spirit: 3, agility: 5, exp: 5,
                                 gold: 10) },
    enemy_group: { 1 => OpenStruct.new(name: 'Slimes', members: {
      1 => OpenStruct.new(enemy_id: 2, x: 100, y: 80, invisible: false),
      2 => OpenStruct.new(enemy_id: 2, x: 200, y: 80, invisible: false) },
      pages: troop_pages) },
    # A drawable battle animation (id 8): four frames, with a screen flash timing
    # on frame 1. (Id 7 is intentionally absent so that test exercises the
    # timed-wait fallback.)
    battle_anime: { 8 => OpenStruct.new(
      animation_name: 'Anim', position: 1,
      frames: {
        1 => OpenStruct.new(cells: { 1 => OpenStruct.new(visible: true, cell_id: 0, x: 0, y: 0) }),
        2 => OpenStruct.new(cells: { 1 => OpenStruct.new(visible: true, cell_id: 1, x: 0, y: 0) }),
        3 => OpenStruct.new(cells: {}),
        4 => OpenStruct.new(cells: {})
      },
      timings: { 1 => OpenStruct.new(frame: 1, flash_scope: 2, flash_red: 31,
                                     flash_green: 31, flash_blue: 31, flash_power: 20) }
    ) },
    # Every tile of the synthetic map is chip 0, which the fake chipset tags as
    # terrain 42 — so this one row decides whether walking hurts, and (for the
    # airship checks) whether it may fly over / land on any tile.
    terrain: { 42 => OpenStruct.new(damage: terrain_damage, bush_depth: bush_depth,
                                    airship_land: airship_land, airship_pass: airship_pass) },
    common_event: common,
    # Database actor rows carry the *original* names, which a \N[n] must not
    # use once the actor has been renamed in play (see the \N[n] check).
    player: { 1 => OpenStruct.new(name: 'DbHero'),
              2 => OpenStruct.new(name: 'DbAlly'),
              3 => OpenStruct.new(name: 'DbStranger') }
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
         layer: 0, pattern: 1, animation_type: 0, translucent: false,
         overlap_forbidden: false)
  OpenStruct.new(
    condition: nil, direction: direction, move_type: x_move_type, move_speed: 3,
    move_frequency: frequency, charset_name: charset_name,
    charset_index: charset_index, trigger: trigger, event_commands: nil,
    move_route: route, layer: layer, pattern: pattern,
    animation_type: animation_type, translucent: translucent,
    overlap_forbidden: overlap_forbidden
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
  attr_reader :db, :pushed
  # Writable (unlike `db`): a test that needs Scene::Map#apply_map_access to
  # see a real map tree sets this directly, since the default (nil) is what
  # every other check wants -- no tree, so save/teleport/escape all default
  # to Allow.
  attr_accessor :map_tree
  def initialize(db, &map_maker)
    @db = db
    @map_tree = nil
    @map_maker = map_maker
    @pushed = []
  end

  def load_map(id); @map_maker.call(id); end
  # Scene::Map#try_open_menu pushes a Scene::Menu; record it instead.
  def push(scene); @pushed << scene; end
  # An Escape / Teleport field skill closes the whole menu stack at once;
  # record that it fired rather than modelling a real scene stack here.
  attr_reader :pop_to_map_called
  def pop_to_map; @pop_to_map_called = true; end
  # Return to Title Screen (12510) hands control back here; record that it fired.
  attr_reader :returned_to_title
  def return_to_title; @returned_to_title = true; end
  # Game Over (12420) and a game-over battle defeat put up Scene::GameOver,
  # which returns to the title once dismissed. Record that it was reached.
  attr_reader :game_over_shown
  def show_game_over; @game_over_shown = true; end
  # Open Save Menu (11910) saves through the app; record the calls.
  def saved; @saved ||= []; end
  def save_game(state); saved << state; true; end
end

def fake_parent(db)
  FakeParent.new(db) { |id| fake_map(id, {}) }
end

# A party member reduced to what map-step slip damage touches. Building a
# database actor needs a whole row; what these checks want to know is only what
# walking does to one, so the double answers the same contract
# Party#apply_map_step_damage calls -- and its own HP floor is deliberately not
# modelled, so the check reads the floor the *party* applies rather than one the
# fixture faked.
class SlipActor
  attr_reader :states, :hp, :mp
  # The scene draws whoever leads the party, so the double also answers the
  # three graphic fields that path reads. A blank charset falls back to the
  # marker sprite, which is what the rest of these checks already run on.
  attr_reader :charset_name, :charset_index
  attr_accessor :transparent
  # 地形ダメージ無効 gear, which Party#apply_terrain_damage asks about.
  attr_accessor :prevents_terrain_damage

  def initialize(states = [], hp = 100, mp = 20)
    @states = states
    @hp = hp
    @mp = mp
    @charset_name = ''
    @charset_index = 0
    @transparent = false
    @prevents_terrain_damage = false
  end

  def prevents_terrain_damage?; @prevents_terrain_damage; end

  def dead?; @hp <= 0; end

  def change_hp(delta, allow_death = true)
    floor = allow_death ? 0 : 1
    @hp = [[@hp + delta, floor].max, 100].min
  end

  def change_mp(delta); @mp = [@mp + delta, 0].max; end
end

def fake_party(members = [])
  # A real Game::Party rather than a stand-in: Scene::Map runs the party through
  # Party#apply_map_step_damage on every walked tile, so the fixture has to
  # answer the real interface. It starts empty -- `system.party` is [] and the
  # movement / event checks have no members to care about -- and takes any it
  # needs from the caller.
  party = Game::Party.new(OpenStruct.new(system: OpenStruct.new(party: [])))
  members.each { |m| party.actors << m }
  party
end

def new_scene(events, player: [0, 0], common: nil, parallax: nil, troop_pages: nil,
              members: [], terrain_damage: 0, bush_depth: 0,
              airship_land: true, airship_pass: true)
  db = fake_db(common, troop_pages, terrain_damage, bush_depth,
               airship_land: airship_land, airship_pass: airship_pass)
  state = Game::State.new(fake_party(members), 1, player[0], player[1])
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

check 'a custom-route jump clears a tile and stops at the map edge' do
  # Begin Jump / two rights / End Jump: a two-tile hop per route lap, which
  # lands on tiles a walking route would have had to step through.
  ev = event(0, 1, page(x_move_type: Game::MoveType::CUSTOM,
                        route: move_route([R::BEGIN_JUMP, R::MOVE_RIGHT,
                                           R::MOVE_RIGHT, R::END_JUMP])))
  scene = new_scene({ 1 => ev }, player: [0, 0])
  200.times { scene.update }
  c = chars(scene)[1]
  # The map is 6 wide, so hops from x = 0 land on 2 and 4; 6 is off the map, so
  # the event holds at 4 rather than clipping to the edge the way a step does.
  eq 4, c.x, 'hopped two tiles at a time and stopped when the landing left the map'
  eq 1, c.y
end

check 'a jumping event slides across the whole hop instead of snapping' do
  # A two-tile hop used to jump the sprite straight to the landing tile: only a
  # single-tile step slid, and a jump is never that. The event is the subject
  # here because it is what jumps in the real games -- 632 of Nepheshel's 634
  # Begin Jump blocks drive an event (625 of them a page's own route), against
  # two that drive the player.
  ev = event(0, 1, page(x_move_type: Game::MoveType::CUSTOM,
                        route: move_route([R::BEGIN_JUMP, R::MOVE_RIGHT,
                                           R::MOVE_RIGHT, R::END_JUMP])))
  scene = new_scene({ 1 => ev }, player: [5, 5])
  seen = []
  60.times do
    scene.update
    e = scene.instance_variable_get(:@events).first
    seen << scene.send(:event_pixel, e)[0] if e[:jumping]
  end
  ok seen.size >= 4, "the hop was drawn over several frames, got #{seen.size}"
  ok seen.uniq.size > 1, 'and the sprite actually travelled'
  ok seen.min >= 0 && seen.max <= 4 * Game::TILE,
     "the slide stayed between the take-off and landing tiles: #{seen.minmax}"
end

check 'a jumping sprite is lifted off the ground and comes back down' do
  ev = event(0, 1, page(x_move_type: Game::MoveType::CUSTOM,
                        route: move_route([R::BEGIN_JUMP, R::MOVE_RIGHT,
                                           R::MOVE_RIGHT, R::END_JUMP])))
  scene = new_scene({ 1 => ev }, player: [5, 5])
  heights = []
  40.times do
    scene.update
    e = scene.instance_variable_get(:@events).first
    heights << scene.send(:event_jump_offset, e) if e[:jumping]
  end
  ok heights.max > 0, 'the sprite left the ground'
  eq 21, heights.max, "RPG_RT's arc peaks at 21px on a 16px tile"
  # It is an arc, not a step up: it rises from nothing and returns.
  peak = heights.index(heights.max)
  ok peak > 0, 'the hop starts on the ground'
  ok heights[0...peak] == heights[0...peak].sort,
     "rises to the peak: #{heights.inspect}"
end

check 'an event that walks is never lifted' do
  ev = event(0, 1, page(x_move_type: Game::MoveType::CUSTOM,
                        route: move_route([R::MOVE_RIGHT])))
  scene = new_scene({ 1 => ev }, player: [5, 5])
  40.times do
    scene.update
    e = scene.instance_variable_get(:@events).first
    eq false, e[:jumping], 'a walking step is not a hop'
    eq 0, scene.send(:event_jump_offset, e)
  end
end

check 'a jump that lands on its own tile still hops visibly' do
  # Nothing moves, so the slide cannot be recognised from the displacement --
  # only the jump flag says the sprite should leave the ground at all.
  ev = event(2, 1, page(x_move_type: Game::MoveType::CUSTOM,
                        route: move_route([R::BEGIN_JUMP, R::MOVE_RIGHT,
                                           R::MOVE_LEFT, R::END_JUMP])))
  scene = new_scene({ 1 => ev }, player: [5, 5])
  lifted = 0
  40.times do
    scene.update
    e = scene.instance_variable_get(:@events).first
    lifted += 1 if scene.send(:event_jump_offset, e) > 0
  end
  ok lifted > 0, 'a hop in place still leaves the ground'
  c = chars(scene)[1]
  eq [2, 1], [c.x, c.y], 'and it landed back where it started'
end

check 'Change Event Location does not arc the event it snaps' do
  # A snap moves an event further than a step, which is exactly the shape that
  # now slides when it is a jump. It must not be mistaken for one.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::CHANGE_EVENT_LOCATION, [1, 0, 4, 2])]
  scene = new_scene({ 1 => event(0, 1, page), 2 => event(5, 5, pg) },
                    player: [5, 0])
  20.times { scene.update }
  e = scene.instance_variable_get(:@events).find { |x| x[:id] == 1 }
  eq [4, 2], [e[:char].x, e[:char].y], 'the snap landed'
  eq false, e[:jumping], 'a snap is not a hop'
  eq 0, scene.send(:event_jump_offset, e), 'so the sprite is not lifted'
end

# The map's own sprite layers, in the order they must composite. Events are not
# here because they are blitted into the two tile-layer buffers rather than
# owning sprites of their own.
MAP_LAYER_IVARS = %i[@parallax_sprite @lower_sprite @airship_shadow
                     @player_sprite @animation_sprite @upper_sprite].freeze
# ... and everything that draws *over* the map, which the screen tone must not
# touch: pictures carry their own tone, and the weather / flash / fade overlays
# are screen effects in their own right.
ABOVE_MAP_IVARS = %i[@picture_sprite @weather_sprite @flash_sprite
                     @fade_sprite].freeze

def sprite_z(scene, ivar)
  s = scene.instance_variable_get(ivar)
  s && s.z
end

check 'the map layers composite in a fixed order, under the overlays' do
  # Pinned because the screen tone moves every one of these into a viewport:
  # the tone has to reach the map and nothing above it, and the order within the
  # map has to survive the move.
  # With a panorama, so the parallax layer is built and pinned too.
  scene = new_scene({}, parallax: {
    parallax_flag: true, parallax_name: 'BG',
    parallax_loop_x: true, parallax_loop_y: true,
    parallax_autoloop_x: false, parallax_sx: 0,
    parallax_autoloop_y: false, parallax_sy: 0
  })
  zs = MAP_LAYER_IVARS.map { |i| [i, sprite_z(scene, i)] }
  zs.each { |i, z| ok !z.nil?, "#{i} exists and has a z" }
  ordered = zs.map { |_i, z| z }
  eq ordered.sort, ordered, "map layers out of order: #{zs.inspect}"

  top = ordered.max
  ABOVE_MAP_IVARS.each do |i|
    z = sprite_z(scene, i)
    next if z.nil? # a layer this scene has not built
    ok z > top, "#{i} (z=#{z}) must draw over the map (top z=#{top})"
  end

  # The three vehicles sit between the shadow and the hero.
  vs = scene.instance_variable_get(:@vehicle_sprites)
  vs.each_value do |s|
    ok s.z > sprite_z(scene, :@airship_shadow), 'a vehicle is over its shadow'
    ok s.z < sprite_z(scene, :@player_sprite), 'and under a party riding it'
  end
end

# -- event page refresh -------------------------------------------------------

# An event with two pages: page 1 unconditional, page 2 gated on switch
# `switch_id`. Later pages win, so page 2 takes over the moment the switch goes
# on — the "talk to me once and I become someone else" idiom.
def two_page_event(x, y, switch_id, page1, page2)
  page2.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A,
                                   switch_a_id: switch_id)
  OpenStruct.new(x: x, y: y, pages: { 1 => page1, 2 => page2 })
end

check 'flipping a switch re-selects an event page mid-map' do
  ic = Game::Interpreter::Cmd
  # Page 1 is a stationary NPC; page 2 is a parallel process that sets switch 5.
  p1 = page(trigger: 0, charset_name: 'Villager')
  p2 = page(trigger: 4, charset_name: 'Ghost')
  p2.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])]
  scene = new_scene({ 1 => two_page_event(2, 2, 3, p1, p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)

  5.times { scene.update }
  ev = event_hashes(scene)[1]
  eq 0, ev[:trigger], 'page 1 is active while switch 3 is off'
  ok !st.switches[5], 'so the page-2 parallel process is not running'

  st.switches[3] = true
  5.times { scene.update }
  ev = event_hashes(scene)[1]
  eq 4, ev[:trigger], 'switch 3 flipped the event to page 2'
  ok st.switches[5], 'and its parallel process now runs'
end

check 'a page change keeps the event where it stands' do
  # The event walks east on page 1; when it flips to page 2 it must stay put
  # rather than snapping back to its spawn tile.
  p1 = page(x_move_type: Game::MoveType::CUSTOM, route: move_route([R::MOVE_RIGHT]))
  p2 = page(trigger: 0, charset_name: 'Stopped')
  scene = new_scene({ 1 => two_page_event(0, 1, 3, p1, p2) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  60.times { scene.update }
  moved_x = chars(scene)[1].x
  ok moved_x > 0, "the event walked east first (got #{moved_x})"

  st.switches[3] = true
  scene.update
  eq moved_x, chars(scene)[1].x, 'the page change left it where it was'
  eq 1, chars(scene)[1].y
end

check 'an identical custom move route continues its progress across a page switch' do
  route_cmds = [R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]
  p1 = page(x_move_type: Game::MoveType::CUSTOM,
           route: move_route(route_cmds, repeat: false), charset_name: 'A')
  p2 = page(x_move_type: Game::MoveType::CUSTOM,
           route: move_route(route_cmds, repeat: false), charset_name: 'A')
  scene = new_scene({ 1 => two_page_event(0, 1, 3, p1, p2) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  10.times { scene.update }
  idx = event_hashes(scene)[1][:route].index
  ok idx > 0, "expected progress before the switch (got #{idx})"
  ok !event_hashes(scene)[1][:route].done?, 'not finished yet'

  st.switches[3] = true
  scene.update
  eq idx, event_hashes(scene)[1][:route].index,
     'the identical route kept its place instead of restarting'
end

check 'a different custom move route restarts from the top on a page switch' do
  p1 = page(x_move_type: Game::MoveType::CUSTOM,
           route: move_route([R::MOVE_RIGHT] * 5, repeat: false), charset_name: 'A')
  p2 = page(x_move_type: Game::MoveType::CUSTOM,
           route: move_route([R::MOVE_LEFT] * 5, repeat: false), charset_name: 'A')
  scene = new_scene({ 1 => two_page_event(0, 1, 3, p1, p2) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  10.times { scene.update }
  idx = event_hashes(scene)[1][:route].index
  ok idx > 0, "expected progress before the switch (got #{idx})"

  st.switches[3] = true
  scene.update
  eq 0, event_hashes(scene)[1][:route].index, 'a changed route restarts from the top'
end

check 'a refresh does not resurrect an erased event' do
  ic = Game::Interpreter::Cmd
  p1 = page(trigger: 3) # auto-start: erase myself
  p1.event_commands = [ECmd.new(ic::ERASE_EVENT, [])]
  p2 = page(trigger: 0)
  scene = new_scene({ 1 => two_page_event(2, 2, 3, p1, p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  10.times { scene.update }
  ok event_hashes(scene)[1].nil?, 'the event erased itself'

  st.switches[3] = true # would select page 2 if it were still around
  5.times { scene.update }
  ok event_hashes(scene)[1].nil?, 'an Erase Event outlasts a page refresh'
end

check 'an event with no matching page drops off the map, and comes back' do
  # Only one page, gated on switch 3: with it off there is no active page at all.
  only = page(trigger: 0)
  only.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A,
                                  switch_a_id: 3)
  scene = new_scene({ 1 => OpenStruct.new(x: 2, y: 2, pages: { 1 => only }) },
                    player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update
  ok event_hashes(scene)[1].nil?, 'no page holds, so nothing is on the map'

  st.switches[3] = true
  scene.update
  ok event_hashes(scene)[1], 'the condition now holds, so the event appears'
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

# Priority type (the page `layer` field) gates collision the same way it gates
# draw order: only LAYER_SAME (1) — "same as normal characters" — is solid.
# LAYER_BELOW (0) and LAYER_ABOVE (2) are decorations the hero, vehicles and
# other events all walk straight through. See the LAYER_* comment in map.rb.
check 'a below-characters event does not block the hero' do
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW) # action trigger, not touch
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6 # hold right, through the event at (1,0)
  12.times { scene.update }
  RGSS::Input.dir_value = 0
  ok st.x >= 1, "expected the hero to walk onto/through (1,0), stuck at x=#{st.x}"
end

check 'an above-characters event does not block the hero' do
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_ABOVE)
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6
  12.times { scene.update }
  RGSS::Input.dir_value = 0
  ok st.x >= 1, "expected the hero to walk onto/through (1,0), stuck at x=#{st.x}"
end

check 'a same-layer event still blocks the hero' do
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_SAME)
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6
  12.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 0], [st.x, st.y], 'a same-layer event still blocks like a normal character'
end

check 'events on different layers pass through each other via Move Route' do
  # A below-layer event sits at (3,2); an above-layer event runs a custom
  # route straight through its column. Only a matching layer collides (see
  # #char_passable?), so the mover reaches the far side instead of stopping.
  below = event(3, 2, page(layer: RPG2k::Scene::Map::LAYER_BELOW))
  mover = event(1, 2, page(x_move_type: Game::MoveType::CUSTOM,
                           route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false),
                           layer: RPG2k::Scene::Map::LAYER_ABOVE))
  scene = new_scene({ 1 => below, 2 => mover }, player: [0, 0])
  ch = chars(scene)[2]
  40.times { scene.update }
  eq [3, 2], [ch.x, ch.y],
     "an above-layer mover should cross a below-layer event, got #{[ch.x, ch.y]}"
end

check 'a below-characters event with overlap_forbidden still blocks the hero' do
  # The "doesn't overlap" page flag (LCF field 35) is a second, independent
  # collision axis: it forces the block even though the layer alone would not.
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW, overlap_forbidden: true)
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6 # hold right, toward the event at (1,0)
  12.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 0], [st.x, st.y], 'overlap_forbidden blocks the hero despite the mismatched layer'
end

check 'events on different layers no longer pass through when overlap_forbidden is set' do
  # Same setup as the pass-through check above, but the below-layer event now
  # carries overlap_forbidden — the above-layer mover must stop at its tile.
  below = event(3, 2, page(layer: RPG2k::Scene::Map::LAYER_BELOW, overlap_forbidden: true))
  mover = event(1, 2, page(x_move_type: Game::MoveType::CUSTOM,
                           route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false),
                           layer: RPG2k::Scene::Map::LAYER_ABOVE))
  scene = new_scene({ 1 => below, 2 => mover }, player: [0, 0])
  ch = chars(scene)[2]
  40.times { scene.update }
  eq [2, 2], [ch.x, ch.y],
     "overlap_forbidden should stop the mover short of the blocker, got #{[ch.x, ch.y]}"
end

# Each tile's four passability bits mark whether *that tile's own* north/
# south/east/west edge is open; crossing a boundary needs the leaving tile's
# bit for the side it exits through *and* the entering tile's bit for the
# side it enters through (the same physical edge, named from each tile's own
# side of it) -- so a wall can be painted from either tile, and both have to
# agree for the crossing to work. Nepheshel ships 513 tiles across 17 of its
# 100 chipsets whose direction bits are not all-or-nothing like a fixture
# defaults to, so a scene that only asked the destination (as this one used
# to, and using the direction of travel rather than the reverse) missed both
# halves of that agreement.
#
# `edge_x`/`edge_y` are the map cell whose chip index 0 carries `edge_flags`;
# every other cell is chip index 1, fully open in all four directions.
def edge_scene(player, edge_x, edge_y, edge_flags)
  db = fake_db
  open = Game::ChipSet::DIR_BIT[2] | Game::ChipSet::DIR_BIT[4] |
         Game::ChipSet::DIR_BIT[6] | Game::ChipSet::DIR_BIT[8]
  data = Array.new(162, open)
  data[0] = edge_flags
  db.chipset = { 1 => OpenStruct.new(name: 'edge', chipset_name: 'edge',
                                     passable_data_lower: data,
                                     passable_data_upper: nil, terrain_data: nil) }
  w = 6; h = 5
  lower = Array.new(w * h, 1000) # chip index 1: fully open
  lower[edge_y * w + edge_x] = 0 # chip index 0: edge_flags
  unit = OpenStruct.new(width: w, height: h, chipset_id: 1, lower_layer: lower,
                        upper_layer: Array.new(w * h, 0), events: {})
  state = Game::State.new(fake_party, 1, player[0], player[1])
  state.map = Game::Map.new(1, unit)
  RPG2k::Scene::Map.new(fake_parent(db), state)
end


check 'a step is blocked when the tile being left disallows that side, ' \
      'even though the tile ahead is open' do
  # Standing on a tile that only permits crossing its Right edge; every other
  # side of it, including Down, is closed. The tile below is fully open, but
  # that never gets asked -- the departure fails at the standing tile first.
  scene = edge_scene([0, 0], 0, 0, Game::ChipSet::DIR_BIT[6])
  RGSS::Input.dir_value = 2 # try to walk down
  20.times { scene.update }
  st = scene.instance_variable_get(:@state)
  eq [0, 0], [st.x, st.y], 'the standing tile\'s own closed Down edge blocks the step'
end

check 'a step is blocked when the tile ahead disallows the side being entered, ' \
      'even though it allows the opposite side' do
  # The tile at (1,0) only permits crossing its own Right edge (the boundary
  # with whatever is further east of it) -- not its Left edge, which is the
  # boundary being crossed here. Checking the destination with the direction
  # of travel (Right) instead of the entered side (Left) -- the pre-fix bug
  # -- would read this tile's Right bit and wrongly allow the step.
  scene = edge_scene([0, 0], 1, 0, Game::ChipSet::DIR_BIT[6])
  RGSS::Input.dir_value = 6 # try to walk right, into (1,0)
  20.times { scene.update }
  st = scene.instance_variable_get(:@state)
  eq [0, 0], [st.x, st.y], 'the destination\'s closed Left edge blocks entry from the west'
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

check 'event-touch (trigger 2) also fires when the player walks into it' do
  # RPG_RT tests both touch triggers as one set on the player's own move — so a
  # trigger-2 event fires from either side, which is how Nepheshel's roaming
  # monsters (9,637 trigger-2 pages) start a fight when you walk into them.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 2) # event touch, standing still
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  RGSS::Input.dir_value = 6 # hold right, into the event at (1,0)
  6.times { scene.update }
  st = scene.instance_variable_get(:@state)
  ok st.switches[6], 'walking into an event-touch event ran it'
  eq [0, 0], [st.x, st.y], 'and the party did not step onto it'
end

check 'an action event is not set off by walking into it' do
  # The pairing is only the two touch triggers: trigger 0 still needs the button.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 0)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  RGSS::Input.dir_value = 6
  6.times { scene.update }
  st = scene.instance_variable_get(:@state)
  ok !st.switches[6], 'an action event ignores being walked into'
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

# A scene on a map with counter tiles, for the talk-across-a-counter checks.
def counter_scene(events, counters, player:)
  db = fake_db
  state = Game::State.new(fake_party, 1, player[0], player[1])
  state.map = fake_map_with_counters(1, events, counters)
  RPG2k::Scene::Map.new(fake_parent(db), state)
end

check 'the action button reaches across a shop counter' do
  ic = Game::Interpreter::Cmd
  # Same-as-characters: a facing (not overlapping) action check only answers a
  # LAYER_SAME event — see 'the action button does not answer a below/above
  # -characters event from an adjacent facing tile' below.
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_SAME)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 0])]
  # Player at (0,0) facing east; (1,0) is the counter, the keeper is at (2,0).
  scene = counter_scene({ 1 => event(2, 0, pg) }, [[1, 0]], player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 6
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  5.times { scene.update }
  ok st.switches[4], 'talked to the keeper standing behind the counter'
end

check 'the reach stops after three counters, and at a non-counter tile' do
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_SAME)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 0])]
  # (1,0) is a counter but (2,0) is not, so the event at (3,0) is out of reach.
  scene = counter_scene({ 1 => event(3, 0, pg) }, [[1, 0]], player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 6
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  5.times { scene.update }
  ok !st.switches[4], 'the run of counters ended, so nothing was reached'

  # Four counters deep is one more than RPG_RT looks through.
  far = counter_scene({ 1 => event(5, 0, pg) },
                      [[1, 0], [2, 0], [3, 0], [4, 0]], player: [0, 0])
  st2 = far.instance_variable_get(:@state)
  st2.direction = 6
  RGSS::Input.triggered = [RGSS::Input::C]
  far.update
  RGSS::Input.reset
  5.times { far.update }
  ok !st2.switches[4], 'four counters is past the three-tile reach'
end

# A shop/inn counter is an impassable upper-layer tile, not just a talk-across
# one: nothing in the chipset's lower table refuses the tile (fake_chipset has
# none), so before Game::ChipSet read the upper passage table during movement
# too, a walking party could step straight onto — and through — the counter.
check 'a shop counter blocks walking onto it, not only the action button' do
  scene = counter_scene({}, [[1, 0]], player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 6
  RGSS::Input.dir_value = 6
  10.times { scene.update }
  eq 0, st.x, 'the party never left its tile'
  eq 0, st.y
end

check 'an action event under the player answers the action button' do
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 0)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 0])]
  # The event shares the player's tile — RPG_RT checks there before the tile
  # ahead, which is how a trigger-0 event on a doorway answers the button.
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [2, 2])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  5.times { scene.update }
  ok st.switches[4], 'the event under the party ran'
end

# yado.tk: 決定キーを押してもマップイベントが実行しない (「決定キーを押しても
# マップイベントが実行しない」バグ・エラーページ) — a below/above-characters
# action event only answers the button by overlap (see the check above), never
# by facing it from an adjacent tile; only LAYER_SAME does that (its own tile
# is unreachable, since it blocks the party from ever standing there).
check 'a below-characters action event does not answer the button from an adjacent tile' do
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 6 # face the event at (1,0) without stepping onto it
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  5.times { scene.update }
  ok !st.switches[4], 'a below-characters event must not answer the button while merely faced'
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

check 'Wait 0.0 sec pauses a foreground event for exactly one frame' do
  # RPG_RT pauses a Wait 0.0 command and resumes it on the very next frame,
  # since 0 seconds have already elapsed by then -- so it costs exactly one
  # frame (1/60s), the same as any other single-frame pause, not two.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
                       ECmd.new(ic::WAIT, [0]), # 0.0 seconds
                       ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0])]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update
  ok st.switches[1], 'the command before the wait ran on the first frame'
  ok !st.switches[2], 'the command after Wait 0.0 must not run on that same frame'
  scene.update
  ok st.switches[2], 'Wait 0.0 sec costs exactly one frame, not two'
end

check 'Wait 0.0 sec doubles a parallel process lap gap to two frames' do
  # A parallel process already gets a free one-frame gap between laps with no
  # explicit wait at all (the check above). Adding a Wait 0.0 stacks one more
  # frame on top, for a 2-frame (1/30s) gap -- not the free gap alone, and not
  # three frames from an extra "detect it finished" frame.
  pg = page(trigger: 4)
  pg.event_commands = [add_var_cmd(1), ECmd.new(Game::Interpreter::Cmd::WAIT, [0])]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  4.times { scene.update }
  eq 2, st.variables[1], 'two laps (increment + wait) should have run in four frames'
  scene.update
  eq 3, st.variables[1], 'a third lap starts on the fifth frame'
end

check 'an auto-start event reads its own position ("this event", ref 10005)' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Control Variables: variable 1 = this event's x, variable 2 = its y.
  auto.event_commands = [ECmd.new(ic::CONTROL_VARS, [0, 1, 1, 0, 6, 10005, 1]),
                         ECmd.new(ic::CONTROL_VARS, [0, 2, 2, 0, 6, 10005, 2])]
  scene = new_scene({ 4 => event(6, 3, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  5.times { scene.update }
  eq 6, st.variables[1], 'this event\'s x'
  eq 3, st.variables[2], 'this event\'s y'
end

check 'a parallel process keeps its "this event" id across laps' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4)
  par.event_commands = [ECmd.new(ic::CONTROL_VARS, [0, 1, 1, 0, 6, 10005, 1])]
  scene = new_scene({ 9 => event(7, 2, par) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  # Several laps: the interpreter restarts its list each time, which must not
  # drop the id the reference resolves through.
  10.times { scene.update }
  eq 7, st.variables[1], 'the parallel event still knows its own x'
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
  attr_accessor :exp, :hp, :mp
  attr_reader :id, :name, :atk, :def, :agi, :int, :max_hp, :max_mp, :skills
  # Defaults are strong enough to beat the two-Slime troop the scene db defines;
  # a defeat test passes weaker stats.
  def initialize(atk: 40, dfn: 20, agi: 20, hp: 200, mp: 20, int: 20, skills: [])
    @exp = 0; @id = 1; @name = 'Hero'
    @atk = atk; @def = dfn; @agi = agi; @hp = hp; @max_hp = hp
    @mp = mp; @max_mp = mp; @int = int; @skills = skills
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

check 'Show Inn scene: the Accept / Cancel cursor wraps around' do
  scene, _st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 100))
  5.times { scene.update } # inn command runs; the greeting prompt opens
  eq 0, scene.instance_variable_get(:@inn_choice), 'affordable: cursor starts on Accept'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@inn_choice), 'Up from Accept wraps to Cancel'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@inn_choice), 'Down from Cancel wraps back to Accept'
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

check 'a Show Text keeps its window open when a Show Choices follows directly' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_MESSAGE, [], indent: 0, string: 'hello'),
    ECmd.new(ic::SHOW_CHOICES, [0], indent: 0), # cancel forbidden
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'no'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  win = msg[:window]

  scene.update # no input: text keeps revealing
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # completes the reveal; window stays open
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # would dismiss a lone message -- but a Show Choices follows directly
  RGSS::Input.reset

  choice_msg = nil
  8.times do
    scene.update
    choice_msg = scene.instance_variable_get(:@message)
    break if choice_msg && choice_msg[:choice]
  end
  ok choice_msg, 'the window is still open once the choices appear'
  ok choice_msg[:window].equal?(win), 'the same window is reused, not closed and reopened'
  eq 2, choice_msg[:count], 'both options are listed'
  eq 1, choice_msg[:choice_start], 'the choices are appended below the one text line'

  RGSS::Input.triggered = [RGSS::Input::C] # confirm option 0 ("yes")
  scene.update
  ok !scene.instance_variable_get(:@message), 'the window closes once the choice is made'
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[1], 'the chosen branch ran'
  ok !st.switches[2], 'and the other did not'
end

check 'a Show Text keeps its window open when an Input Number follows directly' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_MESSAGE, [], indent: 0, string: 'hello'),
    ECmd.new(ic::INPUT_NUMBER, [2, 5], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  win = msg[:window]

  scene.update # no input: text keeps revealing
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # completes the reveal
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # would dismiss a lone message -- but Input Number follows directly
  RGSS::Input.reset

  ni = nil
  8.times do
    scene.update
    ni = scene.instance_variable_get(:@number_input)
    break if ni
  end
  ok ni, 'the number-entry widget opened'
  ok ni[:embedded], 'it was embedded in the still-open message window, not a new one'
  ok scene.instance_variable_get(:@message), 'the message window was not closed for it'
  ok scene.instance_variable_get(:@message)[:window].equal?(win),
     'the same window is reused, not closed and reopened'

  RGSS::Input.triggered = [RGSS::Input::UP] # tens digit 0 -> 1 (value 10)
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C]  # confirm
  scene.update
  ok !scene.instance_variable_get(:@number_input), 'the widget closed on confirm'
  ok !scene.instance_variable_get(:@message), 'and the message window closed with it'
  5.times { RGSS::Input.reset; scene.update }
  eq 10, st.variables[5], 'the entered value landed in variable 5'
  ok st.switches[1], 'the interpreter resumed and ran the next command'
end

check 'the cancel key backs out of a Show Choices, per its cancel type' do
  ic = Game::Interpreter::Cmd
  # Cancel type 5: the block carries a [Cancel] branch as option index 4 (an
  # empty label the window must not draw), which the cancel key runs.
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_CHOICES, [5], indent: 0),
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::CHOICE_OPTION, [4], indent: 0, string: ''),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'the choice window opened'
  eq 1, msg[:count], 'only the drawn option is listed, not the [Cancel] branch'

  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  ok !scene.instance_variable_get(:@message), 'cancel closed the choice window'
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[2], 'the [Cancel] branch ran'
  ok !st.switches[1], 'and the drawn option did not'
end

check 'a Show Choices that forbids cancelling swallows the cancel key' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_CHOICES, [0], indent: 0), # cancel type 0
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'the choice window opened'
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.reset
  ok scene.instance_variable_get(:@message), 'the choice stayed on screen'
  parent = scene.instance_variable_get(:@parent)
  ok parent.pushed.empty?, 'and the cancel key did not leak to the main menu'
end

check 'a \\! pause holds the reveal until a button is pressed' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # "ab" then a wait-for-key pause then "cd".
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'ab\\!cd')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  # Reveal runs up to the pause (2 chars) and then holds, no matter how long.
  10.times { RGSS::Input.reset; scene.update }
  eq 2, reveal.revealed, 'the reveal stops at the \\! pause'
  ok reveal.pending_pause, 'and is waiting on the pause'
  ok !reveal.done?
  # Pressing a button releases the pause; the rest then types out.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  ok reveal.pending_pause.nil?, 'the button released the pause'
  5.times { RGSS::Input.reset; scene.update }
  eq 4, reveal.revealed, 'the remaining text revealed'
  ok reveal.done?
end

# A party whose actors have been renamed in play, backed by a roster, for the
# \N[n] message-code check.
class RosterStubActor
  attr_reader :id, :charset_name, :charset_index, :transparent
  attr_accessor :name
  def initialize(id, name)
    @id = id
    @name = name
    @charset_name = ''
    @charset_index = 0
    @transparent = false
  end
end
# Stands in for Game::Actors: `[]` is the get-or-create lookup the interpreter's
# fixed-id commands use, `existing` the non-creating one \N[n] reads through.
# The fixture is fixed, so both answer from the same table.
class RosterStub
  def initialize(h); @h = h; end
  def [](id); @h[id]; end
  def existing(id); @h[id]; end
end
class RosterStubParty
  attr_reader :actors, :roster, :revision
  def initialize
    hero = RosterStubActor.new(1, 'Named')      # renamed by Enter Hero Name
    away = RosterStubActor.new(2, 'Levelled')   # met, then left the party
    @actors = [hero]
    @roster = RosterStub.new(1 => hero, 2 => away)
    @revision = 0
  end
  def leader; @actors.first; end
  def actor_by_id(id); @actors.find { |a| a.id == id }; end
end

check '\\N[n] names the live actor, and \\N[0] the party leader' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: '\\N[0]/\\N[1]/\\N[2]/\\N[3]')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  scene.instance_variable_get(:@state).instance_variable_set(:@party, RosterStubParty.new)
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message opened'
  text = msg[:seg_lines].map { |segs| segs.map { |s| s[:text] }.join }.join
  # \N[0] is the leader; 1 and 2 are live actors (2 is out of the party but in
  # the roster); 3 has never been instantiated, so it falls back to its row.
  eq 'Named/Named/Levelled/DbStranger', text
end

check 'a message with \$ shows a gold window; a plain one does not' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'Rich! \\$')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message opened'
  gw = msg[:gold_window]
  ok gw, 'the \\$ gold window is present'
  ok gw.visible, 'and visible'

  # A plain message (no \$) shows no gold window.
  auto2 = page(trigger: 3)
  auto2.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hello')]
  scene2 = new_scene({ 1 => event(2, 2, auto2) }, player: [5, 5])
  msg2 = nil
  12.times { scene2.update; msg2 = scene2.instance_variable_get(:@message); break if msg2 }
  ok msg2, 'plain message opened'
  ok msg2[:gold_window].nil?, 'no \\$ -> no gold window'
end

check 'a \> \< instant span reveals far faster than the typewriter' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # 'a', a long instant span 'bcdefghij', then 'z' (11 visible characters).
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'a\\>bcdefghij\\<z')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  # At 2 chars/frame the plain typewriter would show ~4 characters in two frames;
  # the instant span collapses, so 'a' + the whole span is already out.
  2.times { RGSS::Input.reset; scene.update }
  ok reveal.revealed >= 10, 'the instant span revealed all at once, not 2/frame'
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

check 'a teleport lands the party facing the direction it asked for' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # RPG2003's facing argument: 1 = up, which the runtime speaks as numpad 8.
  auto.event_commands = [ECmd.new(ic::TELEPORT, [1, 4, 3, 1])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 2 # facing down to start with
  20.times { scene.update }
  eq [4, 3], [st.x, st.y], 'arrived at the destination'
  eq 8, st.direction, 'and turned to face up'
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

check 'two same-layer events sharing a buffer still draw in their own y-order' do
  # Both south of the player (y=0), so event_target_buffer sends both to the
  # upper buffer -- but "near" (small y, drawn first / underneath) is defined
  # *after* "far" (large y, drawn last / on top) in the event table, id 1 vs 2.
  # Sorting only by event order (the pre-fix behaviour) would draw id 1 last
  # and put the nearer sprite on top of the farther one, backwards from RPG_RT's
  # own y-then-x-then-id tie-break.
  far  = event(1, 5, page(charset_name: 'far',  layer: 1))
  near = event(2, 1, page(charset_name: 'near', layer: 1))
  scene = new_scene({ 1 => far, 2 => near }, player: [0, 0])
  upper = scene.instance_variable_get(:@upper_bmp)
  scene.send(:draw_events, 0, 0)
  far_bmp = scene.send(:event_charset, 'far')
  near_bmp = scene.send(:event_charset, 'near')
  order = upper.blt_calls.map { |c| c[2] }.select { |b| b.equal?(far_bmp) || b.equal?(near_bmp) }
  eq [near_bmp, far_bmp], order.uniq, 'the smaller-y sprite draws first, the larger-y one on top of it'
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

check 'a toned picture is tinted before it is composited' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  # A darkened picture: RPG2000's 30/30/30/100 is the tone 128 of the RPG2003
  # test-bed's 315 Show Pictures ask for.
  st.show_picture(1, name: 'pic', x: 160, y: 120, zoom: 100, opacity: 255,
                     red: 30, green: 30, blue: 30, saturation: 100)
  scene.update
  toned = scene.instance_variable_get(:@picture_tone_cache)
  ok toned && toned.size == 1, 'the source was toned into a scratch bitmap'
  _src, tone = toned.values.first.tone_calls.first
  # (30 - 100) * 255 / 100 = -178 on each colour channel, no desaturation.
  eq [-178, -178, -178, 0], [tone.red, tone.green, tone.blue, tone.gray]

  # Drawing again reuses the cache rather than re-toning every frame.
  scene.update
  eq 1, scene.instance_variable_get(:@picture_tone_cache).size
  eq 1, toned.values.first.tone_calls.size, 'toned once, not once per frame'
end

check 'an untinted picture skips the tone pass entirely' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  st.show_picture(1, name: 'pic', x: 160, y: 120, zoom: 100, opacity: 255)
  scene.update
  eq 0, scene.instance_variable_get(:@picture_tone_cache).size,
     'a neutral tone costs no work'
end

check 'a picture saturation below neutral desaturates' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  st.show_picture(1, name: 'pic', x: 160, y: 120, zoom: 100, opacity: 255,
                     red: 100, green: 100, blue: 100, saturation: 0)
  scene.update
  toned = scene.instance_variable_get(:@picture_tone_cache)
  _src, tone = toned.values.first.tone_calls.first
  # RPG2000 counts down from 100 to "less saturated"; RGSS counts grey up.
  eq [0, 0, 0, 255], [tone.red, tone.green, tone.blue, tone.gray]
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
  # Picking a good opens the quantity counter; a second confirm commits it.
  RGSS::Input.triggered = [RGSS::Input::C] # select the first good (id 3 @ 100)
  scene.update
  RGSS::Input.triggered = []
  scene.update
  eq 500, st.party.gold, 'nothing is spent just by opening the counter'
  RGSS::Input.triggered = [RGSS::Input::C] # confirm the default quantity of 1
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

check 'Open Shop scene: the buy list cursor wraps around' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::OPEN_SHOP, [1, 0, 0, 0, 3, 5], indent: 0), # buy-only, goods 3/5
    ECmd.new(ic::SHOP_END, [], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, ShopStubParty.new(500))
  3.times { scene.update } # the shop opens straight to the buy list (buy-only)
  shop = scene.instance_variable_get(:@shop)
  eq 0, shop[:index], 'starts on the first good'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 1, shop[:index], 'Up from the first good wraps to the last (2 goods)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, shop[:index], 'Down from the last good wraps to the first'
end

# Open a buy-only shop stocking goods 3 (100g) and 5, with `gold` on hand, and
# advance to the quantity counter for the first good.
def shop_quantity_scene(gold)
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::OPEN_SHOP, [1, 0, 0, 0, 3, 5], indent: 0),
    ECmd.new(ic::SHOP_END, [], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, ShopStubParty.new(gold))
  3.times { scene.update }
  press(scene, RGSS::Input::C) # select the first good -> the counter
  [scene, st]
end

# Send one triggered button and let the scene settle.
def press(scene, button)
  RGSS::Input.triggered = [button]
  scene.update
  RGSS::Input.triggered = []
  scene.update
end

check 'Open Shop scene: the quantity counter opens on a chosen good' do
  scene, _st = shop_quantity_scene(500)
  shop = scene.instance_variable_get(:@shop)
  eq :quantity, shop[:screen], 'the counter is up'
  eq 1, shop[:quantity][:count], 'starting at one'
  eq 3, shop[:quantity][:id]
  eq 5, shop[:quantity][:max], '500 gold buys five at 100'
end

check 'Open Shop scene: the counter steps by one and clamps to its bounds' do
  scene, _st = shop_quantity_scene(500)
  shop = scene.instance_variable_get(:@shop)
  press(scene, RGSS::Input::UP)
  eq 2, shop[:quantity][:count]
  press(scene, RGSS::Input::DOWN)
  eq 1, shop[:quantity][:count]
  press(scene, RGSS::Input::DOWN)
  eq 1, shop[:quantity][:count], 'never below one'
  5.times { press(scene, RGSS::Input::UP) }
  eq 5, shop[:quantity][:count], 'never past what the party can afford'
end

check 'Open Shop scene: the counter steps by ten on the horizontal axis' do
  scene, _st = shop_quantity_scene(999_999)
  shop = scene.instance_variable_get(:@shop)
  eq 99, shop[:quantity][:max], 'rich enough to hit the item cap'
  press(scene, RGSS::Input::RIGHT)
  eq 11, shop[:quantity][:count], '1 + 10'
  press(scene, RGSS::Input::LEFT)
  eq 1, shop[:quantity][:count]
  20.times { press(scene, RGSS::Input::RIGHT) }
  eq 99, shop[:quantity][:count], 'clamped at the cap'
end

check 'Open Shop scene: confirming the counter buys the whole stack at once' do
  scene, st = shop_quantity_scene(500)
  press(scene, RGSS::Input::UP)
  press(scene, RGSS::Input::UP)   # three
  press(scene, RGSS::Input::C)
  eq 200, st.party.gold, '500 - 3*100'
  eq 3, st.party.item_count(3), 'three bought in one confirm'
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen], 'and it returns to the buy list'
end

check 'Open Shop scene: cancelling the counter buys nothing' do
  scene, st = shop_quantity_scene(500)
  press(scene, RGSS::Input::UP)
  press(scene, RGSS::Input::B)
  eq 500, st.party.gold, 'no gold spent'
  eq 0, st.party.item_count(3)
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen], 'back on the buy list'
end

check 'Open Shop scene: the counter sells a whole stack too' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # mode 2 = sell-only, so the shop opens straight onto the sell list.
  auto.event_commands = [
    ECmd.new(ic::OPEN_SHOP, [2, 0, 0, 0, 3], indent: 0),
    ECmd.new(ic::SHOP_END, [], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, ShopStubParty.new(0))
  st.party.gain_item(3, 5)
  3.times { scene.update }
  press(scene, RGSS::Input::C)          # pick the held item -> the counter
  shop = scene.instance_variable_get(:@shop)
  eq :quantity, shop[:screen]
  eq :sell, shop[:quantity][:mode], 'selling, not buying'
  eq 5, shop[:quantity][:max], 'bounded by what is held'
  press(scene, RGSS::Input::UP)
  press(scene, RGSS::Input::UP)         # three
  press(scene, RGSS::Input::C)
  eq 150, st.party.gold, '3 * half of 100'
  eq 2, st.party.item_count(3)
end

check 'Open Shop scene: an unaffordable good never opens the counter' do
  scene, st = shop_quantity_scene(50)   # good 3 costs 100
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen], 'still on the list'
  ok shop[:quantity].nil?, 'no counter for something out of reach'
  eq 50, st.party.gold
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
# the first target). The budget is generous: between command phases each round
# now animates action by action (BATTLE_ANIM_FRAMES per hit), so a multi-round
# fight spans a few hundred frames.
def battle_attack_to_end(scene, max = 600)
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
  RGSS::Audio.reset_se
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  eq 20, st.party.gold, 'gained the troop gold (2 Slimes x 10)'
  eq 10, st.party.actors.first.exp, 'gained the troop EXP (2 Slimes x 5)'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'EnemyKill' },
     'both fallen Slimes played the enemy-death SE'
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
  ok parent.game_over_shown, 'a game-over defeat puts up the Game Over screen'
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
  ui = scene.instance_variable_get(:@battle_ui)
  eq :result, ui[:phase], 'a successful flee shows the result window too, like a win or a loss'
  ok !st.switches[2], 'the Escape handler has not run yet -- the result is still up'
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the result
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update } # interpreter resumes -> Escape handler
  eq 0, st.party.gold, 'fleeing grants nothing'
  ok !st.switches[1], 'the Victory handler was skipped'
  ok st.switches[2], 'the Escape handler ran'
end

check 'Enemy Encounter scene: a game-over defeat returns to the title' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Defeat mode 0 (param 4) = game over, with no [Defeat] handler; the switch
  # after the encounter must never run once the game ends.
  auto.event_commands = [
    ECmd.new(ic::ENEMY_ENCOUNTER, [0, 1, 0, 0, 0, 0], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  # A frail hero the two Slimes overwhelm.
  st.instance_variable_set(:@party,
                           BattleStubParty.new(BattleStubActor.new(atk: 6, dfn: 0, agi: 3, hp: 10)))
  scene.update
  battle_attack_to_end(scene) # the hero is worn down -> the defeat result shows
  parent = scene.instance_variable_get(:@parent)
  ok !parent.game_over_shown, 'still on the defeat result, not yet game over'
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the defeat result
  scene.update
  RGSS::Input.triggered = []
  ok parent.game_over_shown, 'a game-over defeat reached the Game Over screen'
  ok !st.switches[5], 'the rest of the event never ran'
end

check 'Game Over event command returns to the title, abandoning the event' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::GAME_OVER, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  parent = scene.instance_variable_get(:@parent)
  5.times do
    scene.update
    break if parent.game_over_shown
  end
  ok parent.game_over_shown, 'Game Over put up the Game Over screen'
  ok !st.switches[5], 'the rest of the event never ran'
end

# A one-member party for the wipe check: the scene's usual fake party is empty,
# which RPG_RT (rightly) does not treat as a Game Over.
class WipeStubActor
  attr_reader :id
  attr_accessor :hp
  def initialize; @id = 1; @hp = 30; end
  def change_hp(amount, allow_death)
    @hp += amount
    floor = allow_death ? 0 : 1
    @hp = floor if @hp < floor
  end
  def dead?; @hp <= 0; end
end

class WipeStubParty
  attr_reader :actors
  attr_accessor :leader
  def initialize; @actors = [WipeStubActor.new]; @leader = nil; end
  def actor_by_id(id); @actors.find { |a| a.id == id }; end
  def all_dead?; @actors.all? { |a| a.dead? }; end
end

check 'an event that wipes the party drops into Game Over' do
  # No Game Over command anywhere — the wipe itself is what ends the game, the
  # way a Simulated Attack floor trap does in a real game.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::CHANGE_HP, [0, 0, 1, 0, 9999, 1], indent: 0), # party, lethal
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, WipeStubParty.new)
  parent = scene.instance_variable_get(:@parent)
  5.times do
    scene.update
    break if parent.game_over_shown
  end
  ok parent.game_over_shown, 'the wipe put up the Game Over screen'
  ok !st.switches[5], 'and the rest of the event never ran'
end

check 'the Game Over screen shows its picture, plays its BGM and waits' do
  parent = fake_parent(fake_db)
  Audio.reset_bgm
  Input.reset
  scene = RPG2k::Scene::GameOver.new(parent)
  eq [['GameOverBGM', 90, 100]], Audio.bgm_calls, 'the database game-over music'
  ok scene.instance_variable_get(:@picture).bitmap, 'the GameOver/ picture loaded'

  scene.update
  ok !parent.returned_to_title, 'it waits for a button'
  Input.triggered = [Input::C]
  scene.update
  ok parent.returned_to_title, 'and then hands back to the title'
  Input.reset
end

check 'a button still held from the battle does not skip the Game Over screen' do
  parent = fake_parent(fake_db)
  Input.reset
  # The key that dismissed the defeat message is still down as the scene opens.
  Input.triggered = [Input::C]
  scene = RPG2k::Scene::GameOver.new(parent)
  scene.update
  ok !parent.returned_to_title, 'the held key is ignored'
  Input.reset
  scene.update                       # released: the screen arms
  Input.triggered = [Input::C]
  scene.update                       # pressed afresh
  ok parent.returned_to_title, 'a fresh press dismisses it'
  Input.reset
end

check 'a game with no game-over picture still reaches the screen' do
  db = fake_db
  db.system.gameover_name = ''
  parent = fake_parent(db)
  Input.reset
  scene = RPG2k::Scene::GameOver.new(parent)
  eq nil, scene.instance_variable_get(:@picture).bitmap, 'nothing to show'
  scene.update
  Input.triggered = [Input::B]
  scene.update
  ok parent.returned_to_title, 'and it still dismisses to the title'
  Input.reset
end

check 'Change System Graphics reloads the windowskin from the override' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::CHANGE_SYSTEM_GFX, [0, 0], indent: 0, string: 'Skin2')]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  # The fake db's system graphic is blank, so the scene opens with no windowskin.
  eq nil, scene.instance_variable_get(:@windowskin), 'no windowskin from the blank db default'
  5.times { scene.update }
  eq 'Skin2', st.system_graphic, 'the override is recorded on the state'
  ok scene.instance_variable_get(:@windowskin), 'the windowskin was reloaded from the override'
end

# A party with a renameable actor for the Name Input check.
class NameStubActor
  attr_accessor :name
  attr_reader :id
  def initialize(id, name); @id = id; @name = name; end
end
class NameStubParty
  attr_reader :actors, :roster
  attr_accessor :leader
  # leader stays nil (no sprite to render) — the name widget doesn't need it.
  # Enter Hero Name names its actor by id, which resolves through the roster.
  def initialize
    @actors = [NameStubActor.new(1, 'Hero')]
    @leader = nil
    @roster = RosterStub.new(1 => @actors[0])
  end
  def actor_by_id(id); @actors.find { |a| a.id == id }; end
end

check 'Enter Hero Name: typing on the grid and confirming renames the actor' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::NAME_INPUT, [1, 2, 0], indent: 0), # actor 1, letters, no seed
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, NameStubParty.new)
  # Let the encounter open the entry widget.
  6.times do
    scene.update
    break if scene.instance_variable_get(:@name_ui)
  end
  ui = scene.instance_variable_get(:@name_ui)
  ok ui, 'the name-entry widget opened'
  eq '', ui[:name], 'starts empty (no seed)'

  # The cursor starts on the first cell ('A'); C types it.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 'A', ui[:name], 'confirming the first cell types an A'

  # Jump the cursor to the OK cell and confirm to commit.
  ui[:sel] = RPG2k::Scene::Map::NAME_CELLS.length - 1
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 'A', st.party.actor_by_id(1).name, 'the actor was renamed on confirm'
  eq nil, scene.instance_variable_get(:@name_ui), 'the widget closed'
  3.times { scene.update }
  ok st.switches[5], 'the event resumed after entry'
end

check 'Enter Hero Name: the character grid cursor wraps around' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::NAME_INPUT, [1, 2, 0], indent: 0), # actor 1, letters, no seed
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, NameStubParty.new)
  6.times do
    scene.update
    break if scene.instance_variable_get(:@name_ui)
  end
  ui = scene.instance_variable_get(:@name_ui)
  ok ui, 'the name-entry widget opened'
  # 26 letters (upper) + 26 (lower) + 10 digits + 4 punctuation = 66 characters,
  # plus BS and OK = 68 cells; 13 per row makes 6 rows, the last ragged with 3.
  eq 68, RPG2k::Scene::Map::NAME_CELLS.length
  eq 13, RPG2k::Scene::Map::NAME_COLS

  # Row-local wrap: Right past the end of the first (full, 13-cell) row wraps
  # to that same row's start, not into row 1.
  ui[:sel] = 12 # row 0, col 12 (last cell of row 0)
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.triggered = []
  eq 0, ui[:sel], 'Right from the last cell of row 0 wraps to its first cell'

  # ...and the wrap respects the ragged last row's narrower width (3 cells:
  # indices 65-67), not a full 13-wide row.
  ui[:sel] = 67 # row 5, col 2 (OK, the last of the 3 cells)
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.triggered = []
  eq 65, ui[:sel], 'Right from the last cell of the ragged row wraps to its own first cell'

  # Column wrap: Down from the last row (row 5) wraps to row 0, keeping the
  # column when the target row is wide enough to hold it.
  ui[:sel] = 66 # row 5, col 1 (BS)
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.triggered = []
  eq 1, ui[:sel], 'Down from row 5 wraps to row 0, same column (1)'

  # Up from row 0 wraps to the last row, with the column clamped modulo that
  # row's narrower width (col 10 in a 13-wide row becomes col 1 of the 3-wide
  # last row: 10 % 3 == 1).
  ui[:sel] = 10 # row 0, col 10
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.triggered = []
  eq 66, ui[:sel], 'Up from row 0 wraps to row 5, column 10 % 3 == 1'
end

# A party whose actor levels up on demand, for the level-up-message check.
class LevelStubActor
  attr_reader :name, :id
  attr_accessor :level
  def initialize; @id = 1; @name = 'Hero'; @level = 1; end
  def change_level_by(n); @level += n; end
end
class LevelStubParty
  attr_reader :actors, :roster
  attr_accessor :leader
  # A Change Level naming a fixed actor id resolves through the roster.
  def initialize
    @actors = [LevelStubActor.new]
    @leader = nil
    @roster = RosterStub.new(@actors[0].id => @actors[0])
  end
  def actor_by_id(id); @actors.find { |a| a.id == id }; end
  # The stat commands re-check for a party wipe; this stub's actor is alive.
  def all_dead?; false; end
end

check 'Change Level show-message: the scene shows a message per level, then resumes' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::CHANGE_LEVEL, [1, 1, 0, 0, 2, 1], indent: 0), # +2 levels, show flag
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, LevelStubParty.new)
  # The first level-up message opens.
  10.times do
    scene.update
    break if scene.instance_variable_get(:@message)
  end
  ok scene.instance_variable_get(:@message), 'a level-up message is shown'
  eq 3, st.party.actor_by_id(1).level, 'both levels were applied at once'
  # Confirm through both queued messages (two C presses each: reveal, dismiss).
  40.times do
    RGSS::Input.triggered = [RGSS::Input::C]
    scene.update
    RGSS::Input.triggered = []
    break if st.switches[5]
  end
  ok st.switches[5], 'the event resumes once both level-up messages are dismissed'
end

check 'boarding a boat and disembarking onto the shore' do
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 2 # face down, toward (0, 1)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  # Press the action button while facing the boat: board and step onto it.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded, 'boarded the boat ahead'
  eq [0, 1], [st.x, st.y], 'stepped onto the boat tile'
  # Face back to the shore and press the button: step off.
  st.direction = 8 # face up, toward (0, 0)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  ok !st.boarded?, 'disembarked back onto foot'
  eq [0, 0], [st.x, st.y], 'stepped off onto the shore tile'
  eq [0, 1], [boat.x, boat.y], 'the boat stayed where the party left it'
end

check 'the airship flies over a tile blocked on foot, and follows the party' do
  # A same-layer event occupies (1, 0): impassable on foot, but the airship
  # flies over it regardless of layer.
  scene = new_scene({ 1 => event(1, 0, page(layer: 1)) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 0
  air.y = 0 # the airship sits under the party; board in place
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'boarded the airship in place'
  # Fly east onto the blocked tile.
  RGSS::Input.dir_value = 6
  20.times { scene.update }
  RGSS::Input.dir_value = 0
  ok st.x >= 1, 'the airship crossed the on-foot-blocked tile'
  eq [st.x, st.y], [air.x, air.y], 'the airship follows the party'
end

check 'the airship cannot fly over terrain whose airship_pass flag forbids it' do
  scene = new_scene({}, player: [0, 0], airship_pass: false)
  st = scene.instance_variable_get(:@state)
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 0
  air.y = 0 # the airship sits under the party; board in place
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'boarded the airship in place'
  RGSS::Input.dir_value = 6
  10.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 0], [st.x, st.y], 'airship_pass: false grounded the airship in place'
end

check 'the airship cannot land where the terrain\'s airship_land flag forbids it' do
  scene = new_scene({}, player: [0, 0], airship_land: false)
  st = scene.instance_variable_get(:@state)
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 0
  air.y = 0
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'boarded the airship'
  # Try to land again: every tile forbids it, so the party stays aboard.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'airship_land: false kept the party aboard'
end

check 'the airship lands in place where the terrain allows it' do
  scene = new_scene({}, player: [0, 0], airship_land: true)
  st = scene.instance_variable_get(:@state)
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 0
  air.y = 0
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'boarded the airship'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  ok !st.boarded?, 'landed where airship_land allows it'
  eq [0, 0], [st.x, st.y], 'the party stands where the airship touched down'
  eq [0, 0], [air.x, air.y], 'the airship stayed where it landed'
end

check 'Show Battle Animation with the wait flag holds the event then resumes' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [7, 10001, 1], indent: 0), # animation, player, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  3.times { scene.update }
  ok !st.switches[5], 'the event is held while the animation plays'
  60.times { scene.update } # outlast the fallback animation length
  ok st.switches[5], 'the event resumes once the animation finishes'
end

check 'Show Battle Animation plays: an animation sprite shows and a flash fires' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # animation 8 (a drawable one in the fake db) on the player, wait flag on.
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  spr = scene.instance_variable_get(:@animation_sprite)
  shown = false
  flashed = false
  40.times do
    scene.update
    shown ||= spr.visible
    flashed ||= st.screen.flashing?
    break if st.switches[6]
  end
  ok shown, 'the animation sprite was shown while the animation played'
  ok flashed, 'a screen-flash timing fired during the animation'
  ok st.switches[6], 'the event resumed after the animation'
  ok !spr.visible, 'the animation sprite is hidden once it finishes'
end

check 'a vehicle placed on the current map is drawn; one off-map or absent is not' do
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 2
  boat.y = 1
  boat.charset_name = 'Boat'
  scene.update
  sprites = scene.instance_variable_get(:@vehicle_sprites)
  ok sprites[:boat].visible, 'the placed boat is drawn as a sprite'
  ok !sprites[:ship].visible, 'an unplaced vehicle is not drawn'
  # A vehicle on a different map stays hidden.
  ship = st.vehicle(:ship)
  ship.map_id = st.map_id + 1
  ship.x = 0
  ship.y = 0
  ship.charset_name = 'Ship'
  scene.update
  ok !sprites[:ship].visible, 'a vehicle on another map is not drawn'
end

check 'the ridden vehicle sprite follows the party, under the hero' do
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 2
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  boat.charset_name = 'Boat'
  RGSS::Input.triggered = [RGSS::Input::C] # board the boat ahead
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded
  scene.update
  sprites = scene.instance_variable_get(:@vehicle_sprites)
  player = scene.instance_variable_get(:@player_sprite)
  ok sprites[:boat].visible, 'the ridden boat is drawn'
  eq [player.x, player.y], [sprites[:boat].x, sprites[:boat].y],
     'the boat tracks the party position'
  ok sprites[:boat].z < player.z, 'the vehicle sits under the hero'
end

check 'the airship floats above a ground shadow; a boat casts none' do
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 2
  air.y = 2
  air.charset_name = 'Airship'
  scene.update
  sprites = scene.instance_variable_get(:@vehicle_sprites)
  shadow = scene.instance_variable_get(:@airship_shadow)
  ok shadow.visible, 'the airship casts a shadow'
  ok sprites[:airship].y < shadow.y, 'the airship floats above its shadow'
  ok shadow.z < sprites[:airship].z, 'the shadow sits under the airship'
  # A boat (no airship placed) casts no shadow.
  air.map_id = 0 # unplace the airship
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 1
  boat.y = 1
  boat.charset_name = 'Boat'
  scene.update
  ok !shadow.visible, 'a boat casts no airship shadow'
end

def tint_scene(*params)
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::TINT_SCREEN, params, indent: 0)]
  scene = new_scene({ 1 => event(2, 2, auto) })
  5.times { scene.update }
  scene
end

def map_tone(scene)
  scene.instance_variable_get(:@map_viewport).tone
end

check 'Tint Screen darkens the map through the viewport tone' do
  # Tint to (0,0,0) sat 100 instantly (0 tenths), no wait -- a full darken.
  scene = tint_scene(0, 0, 0, 100, 0, 0)
  t = map_tone(scene)
  ok t, 'a tone reached the viewport'
  eq(-255, t.red, 'a black tint takes every channel to the floor')
  eq(-255, t.green)
  eq(-255, t.blue)
  eq 0, t.gray, 'and leaves saturation alone'
end

check 'Tint Screen brightens, which the old overlay could not do at all' do
  # Above neutral. The black overlay approximated only darkening, so this used
  # to be silently ignored -- the screen simply did not change.
  scene = tint_scene(200, 200, 200, 100, 0, 0)
  t = map_tone(scene)
  eq 255, t.red, 'a full brighten reaches the ceiling'
  eq 255, t.green
  eq 255, t.blue
end

check 'Tint Screen casts a colour, not just a brightness' do
  # Red up, green and blue down: a red wash. An overlay of one opacity cannot
  # express this -- it can only darken every channel by the same amount.
  scene = tint_scene(200, 50, 50, 100, 0, 0)
  t = map_tone(scene)
  eq 255, t.red
  eq(-127, t.green, 'truncating toward zero, as the picture tone does')
  eq(-127, t.blue)
  ok t.red > t.green && t.red > t.blue, 'the cast really is red'
end

check "Tint Screen's saturation inverts into RGSS grey" do
  # RPG2000 counts saturation *down* from 100 to mean less saturated; RGSS grey
  # counts up. A fully desaturated tint is therefore full grey.
  scene = tint_scene(100, 100, 100, 0, 0, 0)
  t = map_tone(scene)
  eq 255, t.gray, 'saturation 0 is fully grey'
  eq 0, t.red, 'with the channels untouched'
end

check 'a neutral tint leaves the map alone, and is not re-pushed every frame' do
  scene = tint_scene(100, 100, 100, 100, 0, 0)
  t = map_tone(scene)
  eq 0, t.red
  eq 0, t.gray
  vp = scene.instance_variable_get(:@map_viewport)
  before = vp.updates
  10.times { scene.update }
  eq before, vp.updates, 'an unchanging tone is set once, not once a frame'
end

check 'the tone reaches the map layers and nothing above them' do
  scene = tint_scene(0, 0, 0, 100, 0, 0)
  vp = scene.instance_variable_get(:@map_viewport)
  MAP_LAYER_IVARS.each do |i|
    spr = scene.instance_variable_get(i)
    next unless spr # a layer this scene did not build
    ok spr.viewport.equal?(vp), "#{i} is tinted with the map"
  end
  ABOVE_MAP_IVARS.each do |i|
    spr = scene.instance_variable_get(i)
    next unless spr
    ok !spr.viewport.equal?(vp),
       "#{i} must not be tinted -- it draws over the map"
  end
  scene.instance_variable_get(:@vehicle_sprites).each_value do |spr|
    ok spr.viewport.equal?(vp), 'a vehicle is tinted with the map it sits on'
  end
end

check 'the choice window plays the cursor and decision system sounds' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_CHOICES, [], indent: 0),
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'Yes'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'No'),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg && msg[:choice] }
  ok(msg && msg[:choice], 'choice window opened')
  RGSS::Audio.reset_se
  # Moving the cursor plays the database cursor sound.
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 'Cursor1', RGSS::Audio.se_calls.last[0], 'cursor move plays the cursor SE'
  # A Change System SFX override then wins over the database default.
  st = scene.instance_variable_get(:@state)
  st.system_sfx[0] = { name: 'MyCursor', volume: 90, tempo: 100 }
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 'MyCursor', RGSS::Audio.se_calls.last[0], 'the override wins over the DB default'
  # Confirming plays the decision sound and closes the window.
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq 'Decision1', RGSS::Audio.se_calls.last[0], 'confirm plays the decision SE'
  ok !scene.instance_variable_get(:@message), 'the choice window closed on confirm'
end

check 'the choice window cursor wraps around, like Scene::Title (98dad9b)' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_CHOICES, [], indent: 0),
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'Yes'),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'No'),
    ECmd.new(ic::CHOICE_OPTION, [2], indent: 0, string: 'Maybe'),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg && msg[:choice] }
  ok(msg && msg[:choice], 'choice window opened')
  eq 0, scene.instance_variable_get(:@choice_index), 'starts on the first choice'
  # Up on the first choice wraps to the last, instead of clamping at 0.
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 2, scene.instance_variable_get(:@choice_index), 'Up from the first choice wraps to the last'
  # Down on the last choice wraps back to the first, instead of clamping.
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@choice_index), 'Down from the last choice wraps to the first'
end

check 'character_screen_position measures against the live camera' do
  # A map small enough that the camera cannot scroll, so screen position is just
  # the map position: the offsets RPG_RT applies are then visible on their own.
  scene = new_scene({ 1 => event(3, 4, page) }, player: [1, 2])
  tile = RPG2k::Scene::Map::TILE
  eq [0, 0], scene.camera_position, 'a map smaller than the view cannot scroll'

  hero = scene.character_screen_position(10001)
  # X is measured from the tile's centre, Y from its bottom — RPG_RT's own
  # asymmetry, which is the whole reason this is worth pinning down.
  eq 1 * tile + tile / 2, hero[:x]
  eq 2 * tile + tile, hero[:y]

  ev = scene.character_screen_position(1)
  eq 3 * tile + tile / 2, ev[:x]
  eq 4 * tile + tile, ev[:y]

  eq nil, scene.character_screen_position(99), 'no such event on this map'
end

check 'a scrolled camera shifts the screen position it reports' do
  # A tall map so the follow camera actually scrolls, and the hero's screen
  # position stops tracking its map position.
  scene = new_scene({}, player: [1, 20])
  w = 6; h = 40
  tall = Game::Map.new(1, OpenStruct.new(
    width: w, height: h, chipset_id: 1,
    lower_layer: Array.new(w * h, 0), upper_layer: Array.new(w * h, 0),
    events: {}))
  scene.instance_variable_set(:@map, tall)
  scene.instance_variable_get(:@state).map = tall

  cam_y = scene.camera_position[1]
  ok cam_y > 0, 'the camera scrolled down to follow the hero'
  tile = RPG2k::Scene::Map::TILE
  eq 20 * tile + tile - cam_y, scene.character_screen_position(10001)[:y]
end

check 'the message window moves away from the hero when not position-fixed' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  cfg = st.message_config
  # A tall map so the follow camera clamps and the hero can sit low on screen.
  w = 6; h = 30
  tall = Game::Map.new(1, OpenStruct.new(
    width: w, height: h, chipset_id: 1,
    lower_layer: Array.new(w * h, 0), upper_layer: Array.new(w * h, 0),
    events: {}))
  scene.instance_variable_set(:@map, tall)
  st.map = tall
  win_h = 80
  mwy = ->(c) { scene.send(:message_window_y, win_h, c) }
  # Default (not fixed): hero near the bottom -> the window jumps to the top.
  st.y = 28
  eq 0, mwy.call(cfg), 'hero low on screen -> window at the top'
  # Hero at the top of the map -> the window sits at the bottom.
  st.y = 0
  eq 240 - win_h, mwy.call(cfg), 'hero high on screen -> window at the bottom'
  # Pinned: the configured position wins regardless of where the hero stands.
  cfg.position_fixed = true
  cfg.position = Game::MessageConfig::POS_MIDDLE
  st.y = 28
  eq (240 - win_h) / 2, mwy.call(cfg), 'position-fixed keeps the configured slot'
end

check 'Weather draws a particle overlay when active and hides it when clear' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  wsp = scene.instance_variable_get(:@weather_sprite)
  scene.update
  ok !wsp.visible, 'no weather -> no overlay'
  st.weather.set(1, 2) # heavy rain
  scene.update
  ok wsp.visible, 'rain draws an overlay'
  # A stronger downpour draws more particles than a light one.
  heavy = scene.send(:weather_particle_count, st.weather)
  st.weather.set(1, 0) # light rain
  light = scene.send(:weather_particle_count, st.weather)
  ok heavy > light, 'strength scales the particle count'
  st.weather.set(2, 1) # snow
  scene.update
  ok wsp.visible, 'snow draws an overlay too'
  st.weather.set(0, 0) # clear
  scene.update
  ok !wsp.visible, 'clearing weather hides the overlay'
end

check 'the timer window shows M:SS while visible and hides when never shown' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  scene.update
  eq [nil, nil], scene.instance_variable_get(:@timer_windows),
     'no window until shown'
  # Show a 75 s timer (Start with the show flag on).
  st.timer_frames = 75 * 60
  st.timer_visible = true
  scene.update
  win = scene.instance_variable_get(:@timer_windows)[0]
  ok win, 'the window is built on first display'
  ok win.visible, 'and shown'
  eq '1:15', win.contents.draw_calls.last[4], 'it draws the M:SS text'
  # Hiding the timer hides the window.
  st.timer_visible = false
  scene.update
  ok !win.visible, 'clearing visibility hides the timer window'
end

check "RPG2003's second timer draws in its own window" do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  st.timer(1).set(30)
  st.timer(1).start(true)
  scene.update
  wins = scene.instance_variable_get(:@timer_windows)
  eq nil, wins[0], 'the first timer was never shown, so has no window'
  ok wins[1], 'the second one does'
  eq '0:30', wins[1].contents.draw_calls.last[4]
  ok wins[1].x > (RPG2k::Scene::Map::SCREEN_W / 2),
     'and sits to the right of the first, the way RPG_RT parks it'
end

check 'a timer without the battle flag pauses and hides for the fight' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  st.timer(0).set(30)
  st.timer(0).start(true, false)  # visible, but not during battle
  scene.update
  ok scene.instance_variable_get(:@timer_windows)[0].visible

  frames = st.timer(0).frames
  scene.instance_variable_set(:@battle_ui, { phase: :command })
  scene.update
  eq frames, st.timer(0).frames, 'it stopped counting for the fight'
  ok !scene.instance_variable_get(:@timer_windows)[0].visible, 'and is hidden'

  st.timer(0).in_battle = true
  scene.update
  ok st.timer(0).frames < frames, 'with the battle flag it keeps counting'
  ok scene.instance_variable_get(:@timer_windows)[0].visible, 'and drawing'
end

check 'boarding plays the vehicle BGM; disembarking restores the map BGM' do
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.current_bgm = { name: 'Field', volume: 100, tempo: 100 } # the map's BGM
  st.direction = 2
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  boat.charset_name = 'Boat'
  RGSS::Input.triggered = [RGSS::Input::C] # board the boat ahead
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded
  eq 'BoatBGM', st.current_bgm[:name], 'the boat BGM plays while aboard'
  eq 80, st.current_bgm[:volume]
  # face the shore and disembark
  st.direction = 8
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  ok !st.boarded?, 'disembarked'
  eq 'Field', st.current_bgm[:name], 'the map BGM resumes on disembark'
end

check 'Enemy Encounter scene: the round animates action by action, not at once' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  # Let the encounter open the per-actor command menu (it takes a frame or two).
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:phase] == :command
  end
  # Command the sole hero to Attack the first enemy: C picks Attack, C confirms
  # the target; with one ally that starts the round animation.
  2.times do
    RGSS::Input.triggered = [RGSS::Input::C]
    scene.update
    RGSS::Input.triggered = []
  end
  ui = scene.instance_variable_get(:@battle_ui)
  eq :animate, ui[:phase], 'the commanded round now plays out as an animation'
  eq 0, ui[:battle].log.length, 'no hit has landed the instant the round starts'

  RGSS::Audio.reset_se
  scene.update # lands exactly the first action of the round
  eq 1, ui[:battle].log.length, 'one attack landed on the first animation step'
  ok ui[:action_win], 'and it is bannered on screen'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'EnemyHit' }, 'and its damage SE played'
  # The timer holds the next action back, so a mid-timer frame lands nothing more.
  scene.update
  eq 1, ui[:battle].log.length, 'the next action waits out BATTLE_ANIM_FRAMES'
end

# A party whose lone Hero (fast, so it acts first) knows a battle skill and
# carries potions — enough for the scene to drive the Skill / Item sub-menus.
# The battle_* hooks return canned commands so the checks assert the scene wires
# them through (the numbers themselves are exercised in rpg2k_logic_check).
class BattleMagicParty
  attr_reader :actors, :gold, :items
  attr_accessor :leader
  def initialize(hurt: false)
    @hero = BattleStubActor.new(atk: 40, agi: 20, mp: 10, skills: [1]) # max HP 200
    @hero.hp = 100 if hurt # below max, so a heal has room to show
    @actors = [@hero]
    @gold = 0
    @leader = nil
    @items = { 5 => 2 }
  end
  def gain_gold(n); @gold += n; end
  def item_count(id); @items[id] || 0; end
  def gain_item(id, n = 1); @items[id] = item_count(id) + n; end
  def lose_item(id, n = 1); @items[id] = [item_count(id) - n, 0].max; end

  # Battle sub-menu hooks the scene calls (Game::Party provides these for real):
  def battle_skills(actor, _caster); actor.skills.include?(1) ? [[1, 3]] : []; end
  def db_skill(id); id == 1 ? OpenStruct.new(name: 'Fire', scope: 0) : nil; end
  def battle_skill_target(sk); sk.scope == 0 ? :enemy : :ally; end
  def battle_skill_command(_sk, _caster, _target); { cost: 3, hp: -15, mp: 0 }; end
  def battle_items
    @items.keys.sort.select { |id| item_count(id) > 0 }.map { |id| [id, item_count(id)] }
  end
  def db_item(id); id == 5 ? OpenStruct.new(name: 'Potion') : nil; end
  def battle_item_command(_it, _target); { hp: 20, mp: 0 }; end
  def item_all_allies?(it); it.respond_to?(:scope) && it.scope == 1; end
end

# Open a battle and step to the per-actor command menu.
def battle_to_command(scene)
  ui = nil
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:phase] == :command
  end
  ui
end

def press_key(scene, key)
  RGSS::Input.triggered = [key]
  scene.update
  RGSS::Input.triggered = []
end

check 'Enemy Encounter scene: casting an attack Skill damages a foe and spends SP' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleMagicParty.new)
  ui = battle_to_command(scene)

  press_key(scene, RGSS::Input::DOWN)   # move cursor Attack -> Skill
  eq 1, ui[:cmd]
  press_key(scene, RGSS::Input::C)      # open the skill list
  eq :skill, ui[:phase]
  press_key(scene, RGSS::Input::C)      # choose Fire (enemy-scope) -> target
  eq :target, ui[:phase]
  press_key(scene, RGSS::Input::C)      # confirm the first foe -> round animates
  eq :animate, ui[:phase]

  foe_hp = ui[:foes].first.hp
  scene.update                          # the fast Hero's Fire lands first
  entry = ui[:battle].log.first
  eq 'Fire', entry[:skill], 'the skill resolved as the Hero\'s action'
  eq 15, foe_hp - ui[:foes].first.hp, 'the foe took the skill damage'
  eq 7, ui[:allies].first.mp, 'the caster spent 3 SP (10 -> 7)'
end

check 'Enemy Encounter scene: using an Item heals and consumes one from the bag' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleMagicParty.new(hurt: true))
  ui = battle_to_command(scene)

  press_key(scene, RGSS::Input::DOWN)   # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN)   # Skill -> Item
  eq 2, ui[:cmd]
  press_key(scene, RGSS::Input::C)      # open the item list
  eq :item, ui[:phase]
  press_key(scene, RGSS::Input::C)      # choose Potion -> ally target
  eq :ally_target, ui[:phase]
  press_key(scene, RGSS::Input::C)      # heal the Hero -> round animates
  eq :animate, ui[:phase]
  eq 2, st.party.item_count(5), 'the potion is not spent until the action lands'

  hp_before = ui[:allies].first.hp
  RGSS::Audio.reset_se
  scene.update                          # the Hero uses the Potion first
  eq 1, st.party.item_count(5), 'one potion consumed when the item action landed'
  eq 20, ui[:allies].first.hp - hp_before, 'the Hero was healed 20 HP'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'ItemUse' }, 'the item SE played too'
end

check 'Enemy Encounter scene: the command and target cursors wrap around' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  eq 0, ui[:cmd], 'starts on Attack'
  press_key(scene, RGSS::Input::UP)
  eq 3, ui[:cmd], 'Up from Attack wraps to Defend (the last of the four commands)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:cmd], 'Down from Defend wraps back to Attack'

  press_key(scene, RGSS::Input::C) # open the enemy target list (2 Slimes)
  eq :target, ui[:phase]
  eq 0, ui[:target_i], 'starts on the first foe'
  press_key(scene, RGSS::Input::UP)
  eq 1, ui[:target_i], 'Up from the first foe wraps to the last (2 Slimes)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:target_i], 'Down from the last foe wraps to the first'
end

# A hero with two battle skills, so the skill-list cursor has more than one row
# to wrap across (BattleMagicParty above only carries one).
class BattleTwoSkillParty < BattleMagicParty
  def initialize
    super()
    @hero.instance_variable_set(:@skills, [1, 2])
  end
  def battle_skills(actor, _caster); actor.skills.map { |sid| [sid, 3] }; end
  def db_skill(id); OpenStruct.new(name: "Skill#{id}", scope: 0); end
end

check 'Enemy Encounter scene: the skill list cursor wraps around' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleTwoSkillParty.new)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::C)    # open the skill list
  eq :skill, ui[:phase]
  eq 0, ui[:skill_i], 'starts on the first skill'
  press_key(scene, RGSS::Input::UP)
  eq 1, ui[:skill_i], 'Up from the first skill wraps to the last (2 skills)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:skill_i], 'Down from the last skill wraps to the first'
end

# A hero with two battle items, so the item-list cursor has more than one row
# to wrap across (BattleMagicParty above only carries one).
class BattleTwoItemParty < BattleMagicParty
  def initialize
    super()
    @items = { 5 => 2, 6 => 1 }
  end
  def db_item(id); OpenStruct.new(name: "Item#{id}"); end
end

check 'Enemy Encounter scene: the item list cursor wraps around' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleTwoItemParty.new)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Item
  press_key(scene, RGSS::Input::C)    # open the item list
  eq :item, ui[:phase]
  eq 0, ui[:item_i], 'starts on the first item'
  press_key(scene, RGSS::Input::UP)
  eq 1, ui[:item_i], 'Up from the first item wraps to the last (2 items)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:item_i], 'Down from the last item wraps to the first'
end

# A two-actor party, so the ally-target cursor (heal skill / medicine) has
# more than one row to wrap across.
class BattleTwoAllyParty < BattleMagicParty
  def initialize(hurt: false)
    super(hurt: hurt)
    @hero2 = BattleStubActor.new(atk: 10, agi: 5, mp: 5, hp: 150)
    @actors = [@hero, @hero2]
  end
end

check 'Enemy Encounter scene: the ally target cursor wraps around' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleTwoAllyParty.new)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Item
  press_key(scene, RGSS::Input::C)    # open the item list
  press_key(scene, RGSS::Input::C)    # choose the Potion -> ally target
  eq :ally_target, ui[:phase]
  eq 0, ui[:ally_i], 'starts on the first ally'
  press_key(scene, RGSS::Input::UP)
  eq 1, ui[:ally_i], 'Up from the first ally wraps to the last (2 actors)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:ally_i], 'Down from the last ally wraps to the first'
end

check 'Enemy Encounter scene: draws a battler sprite per enemy, hidden on death' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)

  sprites = ui[:enemy_sprites]
  eq 2, sprites.compact.length, 'one battler sprite per visible troop member'
  ok ui[:back_sprite], 'a battle background sprite is drawn behind them'
  ok sprites.all? { |s| s.visible }, 'both enemies are shown at the start'
  # Centred on the member's troop position (member 1 at x = 100, y = 80).
  eq 100 - sprites[0].bitmap.width / 2, sprites[0].x, 'sprite centred on its x'
  eq 80 - sprites[0].bitmap.height / 2, sprites[0].y, 'sprite centred on its y'
  ok sprites[0].z < 300, 'battlers sit below the UI windows (z >= 300)'
  ok ui[:back_sprite].z < sprites[0].z, 'the backdrop sits behind the battlers'

  battle_attack_to_end(scene) # both Slimes fall
  ok sprites.all? { |s| !s.visible }, 'a defeated enemy sprite is hidden'
end

check 'Enemy Encounter scene: a monster that leaves the field is not drawn' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  sprites = ui[:enemy_sprites]
  ok sprites[0].visible, 'drawn to begin with'
  # Out of play without being dead — an enemy that ran (its own Escape action or
  # a page's Force Flee), which used to stay on screen because visibility keyed
  # off `dead?` alone.
  ui[:foes][0].hidden = true
  scene.send(:refresh_battle_sprites)
  ok !sprites[0].visible, 'a monster that fled is taken off the field'
  ok !ui[:foes][0].dead?, 'without counting as a kill'
  ok sprites[1].visible, 'its companion is untouched'
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

# -- RPG_RT.exe legacy CLI arg: HideTitle --------------------------------------
#
# RPG_RT.exe (and the RPG2000/2003 editor's own Test Play button) is launched
# with bare positional words -- `Game.exe TestPlay HideTitle Window` -- rather
# than --flag=value ones. RPG2k#initialize parses them off the args it is
# already handed and exposes HideTitle as `hide_title?`; Scene::Title reads
# that to skip the title picture and centre the command window instead of
# docking it near where the picture would have sat. A full Scene::Title can be
# built here (unlike RPG2k itself, which needs a real RPG_RT.ldb/.lmt) with a
# minimal stand-in parent that only answers what Scene::Title reads.
TitleParent = Struct.new(:db, :map_tree, :hide_title_flag, :save_exists_flag) do
  def hide_title?; hide_title_flag; end
  def save_exists?; save_exists_flag; end
  def continue_calls; @continue_calls || 0; end
  def continue_game; @continue_calls = continue_calls + 1; end
end

check 'HideTitle hides the title picture and centres the command window' do
  parent = TitleParent.new(fake_db, nil, true)
  scene = RPG2k::Scene::Title.new(parent)
  title = scene.instance_variable_get(:@title)
  window = scene.instance_variable_get(:@window)
  ok title.bitmap.nil?, 'no title picture is drawn'
  eq (RPG2k::HEIGHT - window.height) / 2, window.y,
     'the command window is centred vertically'
end

check 'without HideTitle the picture shows and the window docks near its foot' do
  parent = TitleParent.new(fake_db, nil, false)
  scene = RPG2k::Scene::Title.new(parent)
  title = scene.instance_variable_get(:@title)
  window = scene.instance_variable_get(:@window)
  ok !title.bitmap.nil?, 'the title picture is drawn'
  bottom_num = RPG2k::Scene::Title::BOTTOM_NUM
  bottom_den = RPG2k::Scene::Title::BOTTOM_DEN
  eq RPG2k::HEIGHT * bottom_num / bottom_den - window.height, window.y,
     'the command window docks near the picture, as RPG_RT does'
end

# -- Continue disabled without save data --------------------------------------
#
# RPG_RT grays out Continue on the title screen when there is no save to
# resume; `save_exists?` (main.rb) is the source of truth, routed through
# Scene::Title's own `continue_available?` (ADR 0012). The cursor can still
# reach the grayed-out entry -- only its selection key is ignored.

check 'no save data: Continue is flagged unavailable and reachable by the cursor' do
  parent = TitleParent.new(fake_db, nil, false, false)
  scene = RPG2k::Scene::Title.new(parent)
  ok !scene.instance_variable_get(:@continue_available), 'Continue is flagged unavailable'
  scene.send(:move_selection, 1)
  eq 1, scene.instance_variable_get(:@selected_index),
     'moving down from New Game still lands on Continue'
end

check 'no save data: pressing the selection key on Continue does nothing' do
  parent = TitleParent.new(fake_db, nil, false, false)
  scene = RPG2k::Scene::Title.new(parent)
  scene.instance_variable_set(:@selected_index, 1)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 0, parent.continue_calls,
     'a grayed-out Continue never reaches parent.continue_game'
  eq 1, scene.instance_variable_get(:@selected_index), 'the selection is left untouched'
end

check 'a save exists: Continue is flagged available and its selection key resumes it' do
  parent = TitleParent.new(fake_db, nil, false, true)
  scene = RPG2k::Scene::Title.new(parent)
  ok scene.instance_variable_get(:@continue_available), 'Continue is flagged available'
  scene.instance_variable_set(:@selected_index, 1)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 1, parent.continue_calls, 'pressing the selection key on Continue calls parent.continue_game'
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
  st.screen.erase(Game::Transition::FADE_OUT, 1) # fade fully out over one frame
  4.times { scene.update }
  eq 255, fade.opacity, 'a completed Erase Screen leaves the screen black'

  st.screen.show(Game::Transition::FADE_IN, 1)
  4.times { scene.update }
  eq 0, fade.opacity, 'Show Screen brings it back'
end

check 'a shaped transition paints a mask into the fade layer' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)

  # Blinds close: the overlay goes fully opaque and the bands still showing the
  # map are punched back out of it, rather than the whole screen dimming.
  st.screen.erase(Game::Transition::BLIND_CLOSE)
  fade.bitmap.fill_calls.clear if fade.bitmap.fill_calls
  scene.update
  eq 255, fade.opacity, 'the mask itself carries the shape, not the opacity'
  fills = fade.bitmap.fill_calls || []
  eq 31, fills.length, 'one full-screen black fill, then 30 band holes'
  eq [0, 0, 320, 240], fills.first[0, 4], 'blacked out first'
  eq [0, 1, 320, 7], fills[1][0, 4], 'then the open part of band 0'

  # Once it finishes the overlay is solid black again, so the next plain fade
  # does not inherit the holes.
  st.screen.update until !st.screen.fading?
  fade.bitmap.fill_calls.clear
  scene.update
  eq 1, (fade.bitmap.fill_calls || []).length, 'repainted solid for the fade path'
  eq 255, fade.opacity, 'and the screen stays erased'
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

# -- newly-wired event commands -----------------------------------------------

IC2 = Game::Interpreter::Cmd

# A parallel event whose page runs `cmds` every frame, so a check can drive any
# command through the real scene without pressing buttons.
def parallel_event(cmds, x = 2, y = 2)
  pg = page(trigger: 4)
  pg.event_commands = cmds
  { 1 => event(x, y, pg) }
end

check 'Flash Sprite tones the flashed event and decays away' do
  pg = page(trigger: 4, charset_name: 'Hero')
  # Flash event 1 white at full power for 2 tenths (12 frames), no wait.
  pg.event_commands = [ECmd.new(IC2::FLASH_SPRITE, [1, 31, 31, 31, 31, 2, 0])]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  scene.update
  ev = event_hashes(scene)[1]
  ok ev[:flash], 'the event carries a running flash'
  out = scene.instance_variable_get(:@flash_out_buffer)
  ok out && (out.tone_calls || []).length > 0, 'the flash reached tone_blt'
  tone = out.tone_calls.last[1]
  ok tone.red > 0 && tone.gray == 0, "flash tone brightens: #{tone.inspect}"
end

check 'Flash Sprite on the hero holds a waiting event until it decays' do
  # 1 tenth (6 frames) with the wait flag set, then a variable bump that only
  # runs once the flash is over.
  cmds = [ECmd.new(IC2::FLASH_SPRITE, [10001, 31, 0, 0, 31, 1, 1]),
          add_var_cmd(5)]
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.instance_variable_get(:@interpreter).start(cmds)
  scene.update
  ok scene.instance_variable_get(:@player_flash), 'the hero is flashing'
  eq 0, st.variables[5], 'the event is held while the flash runs'
  10.times { scene.update }
  ok !scene.instance_variable_get(:@player_flash), 'the flash decayed away'
  eq 1, st.variables[5], 'the event resumed once the flash finished'
end

check 'Tile Substitution rewrites the map the scene walks on' do
  cmds = [ECmd.new(IC2::TILE_SUBSTITUTION, [0, 0, 41])]
  scene = new_scene(parallel_event(cmds), player: [0, 0])
  scene.update
  eq 41, scene.instance_variable_get(:@state).map.lower(3, 3)
end

check 'Tile Substitution does not survive leaving and returning to the map' do
  # RPG_RT re-reads the map fresh on every Teleport (see #perform_teleport's
  # own chipset/parallax/pan comments for the sibling per-visit overrides this
  # matches); a substitution recorded on the old Game::Map object does not
  # follow the new one it builds, even when the destination is the same map.
  cmds = [ECmd.new(IC2::TILE_SUBSTITUTION, [0, 0, 41])]
  scene = new_scene(parallel_event(cmds), player: [0, 0])
  scene.update
  st = scene.instance_variable_get(:@state)
  eq 41, st.map.lower(3, 3), 'the substitution took on the original map'

  scene.send(:perform_teleport, [st.map_id, 0, 0, 0]) # leave and return to the same map
  eq 0, st.map.lower(3, 3),
     'a fresh map load on Teleport drops the substitution'
end

check 'Enter/Exit Vehicle boards the vehicle the party stands on' do
  cmds = [ECmd.new(IC2::ENTER_EXIT_VEHICLE, [])]
  scene = new_scene(parallel_event(cmds), player: [0, 0])
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = st.x
  boat.y = st.y
  scene.update
  eq :boat, st.boarded
  scene.update # the command runs again next loop and steps back off
  eq nil, st.boarded
end

check 'Open Main Menu pushes the field menu and resumes when it closes' do
  # A foreground event, not a parallel one: a background process resumes every
  # UI wait itself, and Open Main Menu is a UI wait.
  cmds = [ECmd.new(IC2::OPEN_MAIN_MENU, []), add_var_cmd(6)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  scene.instance_variable_get(:@interpreter).start(cmds)
  scene.update # runs the command and raises the :menu wait
  scene.update # the wait opens the menu
  eq 1, parent.pushed.length, 'the menu scene was pushed'
  eq 0, st.variables[6], 'the event is paused while the menu is open'
  scene.update # back from the menu: the wait is released...
  scene.update # ...and the next frame runs the rest of the event
  eq 1, st.variables[6], 'the event resumed after the menu closed'
end

check 'Open Save Menu saves through the parent and resumes the event' do
  cmds = [ECmd.new(IC2::OPEN_SAVE_MENU, []), add_var_cmd(7)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  scene.instance_variable_get(:@interpreter).start(cmds)
  3.times { scene.update }
  eq 1, parent.saved.length, 'the save went through the app'
  eq 1, st.variables[7], 'the event continued afterwards'
end

check 'Open Save Menu honours a Change Save Access lock' do
  cmds = [ECmd.new(IC2::OPEN_SAVE_MENU, []), add_var_cmd(8)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  st.save_access = false
  scene.instance_variable_get(:@interpreter).start(cmds)
  3.times { scene.update }
  eq 0, parent.saved.length, 'saving was disabled, so nothing was written'
  eq 1, st.variables[8], 'the event still continues past the locked save'
end

check 'a BGM position that jumps backwards counts as one play-through' do
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.current_bgm = { name: 'Town', volume: 100, tempo: 100 }
  RGSS::Audio.pos = 5000
  scene.update
  ok !st.bgm_looped, 'still on the first play-through'
  RGSS::Audio.pos = 10 # SDL_mixer seeks back to the start to loop
  scene.update
  ok st.bgm_looped, 'the wrap counted as a completed play-through'
  RGSS::Audio.pos = 0
end

check 'the action key marks the event it started for the type-8 branch' do
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_SAME)
  pg.event_commands = [
    ECmd.new(IC2::CONDITIONAL, [8], indent: 0),
    ECmd.new(Game::Interpreter::Cmd::CONTROL_SWITCHES, [0, 9, 9, 0], indent: 1),
    ECmd.new(IC2::END_BRANCH, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.direction = 6 # face the event
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update }
  ok st.switches[9], 'the decision-key branch ran'
end

# -- battle-event pages --------------------------------------------------------

# A troop battle-event page. The default condition is the turn test at base 0 /
# multiple 0, so the page fires on turn 0 as the fight opens -- an entirely
# unticked condition box would never fire at all, which is how RPG_RT reads it
# (see Game::BattlePage.active?).
def troop_page(cmds, flags = Game::BattlePage::TURN, opts = {})
  cond = OpenStruct.new({ flags: flags, switch_a_id: 1, switch_b_id: 1,
                          variable_id: 1, variable_value: 0, turn_a: 0,
                          turn_b: 0, fatigue_min: 0, fatigue_max: 100,
                          enemy_id: 0, enemy_hp_min: 0,
                          enemy_hp_max: 100, actor_id: 1, actor_hp_min: 0,
                          actor_hp_max: 100 }.merge(opts))
  OpenStruct.new(condition: cond, event: cmds)
end

# Open a battle whose troop carries `pages`, running frames until the fight is
# up. Returns [scene, state].
def battle_scene_with_pages(pages)
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) }, troop_pages: pages)
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  [scene, st]
end

check 'a turn-0 battle-event page runs as the fight opens' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CONTROL_SWITCHES, [0, 12, 12, 0])]) }
  scene, st = battle_scene_with_pages(pages)
  10.times do
    scene.update
    break if st.switches[12]
  end
  ok st.switches[12], 'the page ran before the command phase'
  scene.update # the exhausted page hands the turn back
  ui = scene.instance_variable_get(:@battle_ui)
  ok ui, 'the battle is still open'
  eq :command, ui[:phase], 'and control returned to the party'
end

check 'a battle page gated on an unmet condition does not fire' do
  ic = Game::Interpreter::Cmd
  # Gated on switch 13, which is never set.
  pages = { 1 => troop_page([ECmd.new(ic::CONTROL_SWITCHES, [0, 14, 14, 0])],
                            Game::BattlePage::SWITCH_A, switch_a_id: 13) }
  scene, st = battle_scene_with_pages(pages)
  10.times { scene.update }
  ok !st.switches[14], 'the gated page stayed put'
end

check 'a battle page with no condition ticked at all never fires' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CONTROL_SWITCHES, [0, 15, 15, 0])], 0) }
  scene, st = battle_scene_with_pages(pages)
  10.times { scene.update }
  ok !st.switches[15], 'RPG_RT reads an unticked condition box as never, not always'
end

check 'Terminate Battle from a page ends the fight and resumes the event' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::TERMINATE_BATTLE, [])]) }
  scene, _st = battle_scene_with_pages(pages)
  12.times do
    scene.update
    break if scene.instance_variable_get(:@battle_ui).nil?
  end
  eq nil, scene.instance_variable_get(:@battle_ui),
     'the battle closed without a result window'
end

check 'a page can wound a monster through Change Monster HP' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_MONSTER_HP, [0, 1, 0, 7, 1])]) }
  scene, _st = battle_scene_with_pages(pages)
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:phase] == :command
  end
  ui = scene.instance_variable_get(:@battle_ui)
  foe = ui[:battle].enemy(0)
  eq foe.max_hp - 7, foe.hp, 'the page took 7 HP off the first troop member'
end

check 'Change Battle Background from a page rebuilds the backdrop sprite' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_BATTLE_BG, [], string: 'Cave')]) }
  scene, _st = battle_scene_with_pages(pages)
  before = nil
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    before ||= ui && ui[:back_sprite]
    break if ui && ui[:phase] == :command
  end
  ui = scene.instance_variable_get(:@battle_ui)
  ok ui[:back_sprite], 'a backdrop is still in place'
  ok !ui[:back_sprite].equal?(before), 'and it was rebuilt for the new name'
end

check 'a battle page shows its message in a battle panel and waits for a key' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_MESSAGE, [], string: 'It appears!'),
                             ECmd.new(ic::CONTROL_SWITCHES, [0, 15, 15, 0])]) }
  scene, st = battle_scene_with_pages(pages)
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:event_win]
  end
  ui = scene.instance_variable_get(:@battle_ui)
  ok ui[:event_win], 'the message panel is up'
  ok !st.switches[15], 'the page is held at the message'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update }
  ok st.switches[15], 'the button dismissed it and the page ran on'
  eq nil, scene.instance_variable_get(:@battle_ui)[:event_win],
     'the panel closed with the message'
end

check 'a hidden troop member is not targetable until it is revealed' do
  scene, _st = battle_scene_with_pages(nil)
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:phase] == :command
  end
  ui = scene.instance_variable_get(:@battle_ui)
  eq 2, ui[:foes].length
  # Hide the second member the way an invisible troop entry would have.
  ui[:foes][1].hidden = true
  ui[:troop].members[1].hidden = true
  targets = scene.send(:living_foes)
  eq 1, targets.length, 'the target cursor skips the hidden member'
  ok !targets.include?(ui[:foes][1])

  scene.send(:reveal_battle_monster, 1)
  ok !ui[:foes][1].hidden, 'revealing clears the combatant flag, not just the sprite'
  eq 2, scene.send(:living_foes).length, 'and it becomes targetable'
  ok ui[:enemy_sprites][1], 'with a sprite built for it'
end

# Every string a window's contents had drawn into it, whichever path drew it:
# `draw_text(x, y, w, h, text, align)` and `blend_text(x, y, w, h, text, skin,
# ...)` both carry the text at index 4.
def window_texts(win)
  c = win && win.contents
  return [] unless c
  ((c.draw_calls || []) + (c.blend_calls || [])).map { |a| a[4] }
end

check 'Open Shop scene: the shopkeeper terms show greeting, regreeting and each screen prompt' do
  ic = Game::Interpreter::Cmd
  db = fake_db
  db.term.shop_greeting1 = 'いらっしゃいませ！'
  db.term.shop_regreeting1 = '他に何かご入用ですか？'
  db.term.shop_buy1 = '買う'
  db.term.shop_sell1 = '売る'
  db.term.shop_leave1 = 'やめる'
  db.term.shop_buy_select1 = '何をお求めですか？'
  db.term.shop_buy_number1 = 'いくつ買いますか？'
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::OPEN_SHOP, [0, 0, 0, 0, 3, 5], indent: 0)]
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  state.instance_variable_set(:@party, ShopStubParty.new(500))
  3.times { scene.update } # the command menu opens (mode 0: buy+sell)
  shop = scene.instance_variable_get(:@shop)
  eq :command, shop[:screen]
  texts = window_texts(shop[:window])
  ok texts.any? { |t| t.include?('いらっしゃいませ！') }, 'the first-visit greeting shows'
  ok texts.any? { |t| t.include?('買う') } && texts.any? { |t| t.include?('売る') } &&
     texts.any? { |t| t.include?('やめる') }, 'the command row labels use the database terms'

  RGSS::Input.triggered = [RGSS::Input::C] # choose Buy
  scene.update
  RGSS::Input.triggered = []
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen]
  ok window_texts(shop[:window]).any? { |t| t.include?('何をお求めですか？') },
     'the buy list shows its own prompt above the goods'

  RGSS::Input.triggered = [RGSS::Input::C] # open the quantity counter for the first good
  scene.update
  RGSS::Input.triggered = []
  shop = scene.instance_variable_get(:@shop)
  eq :quantity, shop[:screen]
  ok window_texts(shop[:window]).any? { |t| t.include?('いくつ買いますか？') },
     'the quantity screen shows its own prompt'

  RGSS::Input.triggered = [RGSS::Input::B] # back to the buy list
  scene.update
  RGSS::Input.triggered = []
  RGSS::Input.triggered = [RGSS::Input::B] # back to the command menu
  scene.update
  RGSS::Input.triggered = []
  shop = scene.instance_variable_get(:@shop)
  eq :command, shop[:screen]
  ok window_texts(shop[:window]).any? { |t| t.include?('他に何かご入用ですか？') },
     'having browsed once, the shopkeeper asks "anything else?" rather than greeting again'
end

check 'Enemy Encounter scene: the result window shows the database Victory term' do
  ic = Game::Interpreter::Cmd
  db = fake_db
  db.term.victory = '戦いに勝利した！' # left blank in fake_db's own term table
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  state.instance_variable_set(:@party, BattleStubParty.new)
  scene.update
  battle_attack_to_end(scene)
  texts = window_texts(scene.instance_variable_get(:@battle_ui)[:result_win])
  ok texts.any? { |t| t.include?('戦いに勝利した！') }, 'the database term is shown'
  ok !texts.any? { |t| t.include?('Victory!') }, 'not the composed English fallback'
end

check 'Enemy Encounter scene: a blank database Victory/Defeat term falls back to English' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, second_switch_code: ic::DEFEAT_HANDLER)
  scene = new_scene({ 1 => event(2, 2, auto) }) # fake_db leaves term.defeat blank
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party,
                           BattleStubParty.new(BattleStubActor.new(atk: 6, dfn: 0, agi: 3, hp: 10)))
  scene.update
  battle_attack_to_end(scene)
  texts = window_texts(scene.instance_variable_get(:@battle_ui)[:result_win])
  ok texts.any? { |t| t.include?('The party was defeated...') },
     'a blank database term still falls back to the composed English'
end

check 'Enemy Encounter scene: a successful Flee shows the database escape_success term' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  2.times { scene.update }
  RGSS::Input.triggered = [RGSS::Input::B] # Flee
  scene.update
  RGSS::Input.triggered = []
  ui = scene.instance_variable_get(:@battle_ui)
  eq :result, ui[:phase]
  texts = window_texts(ui[:result_win])
  ok texts.any? { |t| t.include?('Escaped!') },
     'fake_db leaves escape_success blank, so this is the composed English fallback'
end

# Open a battle and run it up to the command phase, answering [scene, ui].
def battle_at_command(pages = nil)
  scene, = battle_scene_with_pages(pages)
  ui = nil
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:phase] == :command
  end
  [scene, ui]
end

# -- battle animations ---------------------------------------------------------
# RPG2000 keeps the animation on the skill and on the item, not on the action.
# Every skill and item row in both test beds names one and none of them played.

check 'a skill that names an animation plays it over the targeted enemy' do
  scene, ui = battle_at_command
  entry = { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
            skill_id: 8, target_index: 0, target_ally: false }
  ok scene.send(:start_battle_animation, entry), 'an animation started'
  ma = scene.instance_variable_get(:@map_animation)
  ok ma, 'the player was armed'
  ok ma[:battle], 'and flagged as a battle animation'
  spr = ui[:enemy_sprites][0]
  eq [spr.x + spr.bitmap.width / 2, spr.y + spr.bitmap.height / 2],
     [ma[:tx], ma[:ty]], 'centred on the enemy sprite'
end

check 'a skill that names none plays nothing' do
  scene, = battle_at_command
  ok !scene.send(:start_battle_animation,
                 { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Heal',
                   skill_id: 9, target_index: 0, target_ally: false })
  eq nil, scene.instance_variable_get(:@map_animation)
end

# RPG2000's battle is first-person: no sprite is drawn for a party member, so an
# action aimed at one has nowhere to centre on.
check 'an action on a party member plays over the middle of the screen' do
  scene, = battle_at_command
  entry = { attacker: 'Slime', target: 'Hero', damage: 7, skill: 'Fire',
            skill_id: 8, target_index: nil, target_ally: true }
  ok scene.send(:start_battle_animation, entry)
  ma = scene.instance_variable_get(:@map_animation)
  eq [RPG2k::Scene::Map::SCREEN_W / 2, RPG2k::Scene::Map::SCREEN_H / 2],
     [ma[:tx], ma[:ty]]
end

check 'the round waits for the animation instead of the banner timer' do
  scene, ui = battle_at_command
  ui[:phase] = :animate
  scene.send(:start_battle_animation,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
               skill_id: 8, target_index: 0, target_ally: false })
  ok scene.send(:battle_animation_playing?), 'the round is held'
  # It plays out frame by frame and clears itself; nothing else advances while
  # it does, and no interpreter is resumed (a battle animation has no event
  # waiting on it, unlike the map's Show Battle Animation).
  200.times do
    break if scene.instance_variable_get(:@map_animation).nil?
    scene.send(:drive_battle_animate)
  end
  eq nil, scene.instance_variable_get(:@map_animation), 'it finished'
  ok !scene.send(:battle_animation_playing?)
end

check 'an item names its animation the same way a skill does' do
  scene, = battle_at_command
  eq nil, scene.send(:battle_animation_id,
                     { item_id: 3, recover: true }),
     'the fixture Potion names none'
  eq 8, scene.send(:battle_animation_id, { skill_id: 8 })
  eq nil, scene.send(:battle_animation_id, { attacker: 'Hero' }),
     'a plain attack carries no animation yet'
end

check 'the battle animation draws in screen pixels, not map ones' do
  scene, = battle_at_command
  scene.send(:start_battle_animation,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
               skill_id: 8, target_index: 0, target_ally: false })
  ma = scene.instance_variable_get(:@map_animation)
  bmp = scene.instance_variable_get(:@animation_bmp)
  bmp.clear_blt_calls
  # A camera far from the origin must not move a battle animation.
  scene.send(:draw_map_animation, 500, 400)
  ok !bmp.blt_calls.empty?, 'a cell was laid down'
  call = bmp.blt_calls.first
  eq [ma[:tx] - 48, ma[:ty] - 48], [call[0], call[1]],
     'placed from the target pixel itself, ignoring the camera'
end

check 'the battle status window shows each battler condition, or the normal term' do
  scene, ui = battle_at_command
  texts = window_texts(ui[:status_win])
  eq 3, texts.count { |t| t == 'Normal' },
     'two foes and one ally all start clear, showing the database normal term'

  ui[:foes][0].states = [3]                      # Poison
  ui[:allies][0].states = [4]                    # Sleep
  scene.send(:refresh_battle_status)
  texts = window_texts(ui[:status_win])
  ok texts.include?('Poison'), 'the afflicted foe shows its state'
  ok texts.include?('Sleep'), 'and so does the afflicted ally'
  eq 1, texts.count { |t| t == 'Normal' }, 'only the untouched foe is normal'
end

check 'the condition shown is the significant state, in the state colour' do
  scene, ui = battle_at_command
  # Sleep (priority 80) outranks Silence (10) whichever order they landed in.
  ui[:foes][0].states = [4, 5]
  scene.send(:refresh_battle_status)
  ok window_texts(ui[:status_win]).include?('Sleep'), 'the higher priority wins'
  ui[:foes][0].states = [5, 4]
  scene.send(:refresh_battle_status)
  ok window_texts(ui[:status_win]).include?('Sleep'), 'regardless of order'

  # The state's own palette colour reaches the draw call. This project ships no
  # windowskin in the fake database, so the flat path runs and the colour is
  # carried as the font colour rather than a blend swatch -- what matters here
  # is that battle_state_segment resolved it from the row at all.
  eq 2, Game::States.color(3, scene.db.situation), 'Poison draws in colour 2'
  eq 4, Game::States.color(4, scene.db.situation), 'Sleep in colour 4'
end

check 'Change Monster Condition on a battle page shows on the status window' do
  ic = Game::Interpreter::Cmd
  # Inflict state 3 (Poison) on troop member 0 the moment the fight opens.
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_MONSTER_CONDITION, [0, 0, 3])]) }
  scene, ui = battle_at_command(pages)
  eq true, ui[:foes][0].state?(3), 'the page inflicted the state'
  # ...and the panel says so without waiting for the next action to redraw it.
  ok window_texts(ui[:status_win]).include?('Poison'),
     'the status window was rebuilt after the page ran'
end

# -- the battle log in the game's own words ------------------------------------

check 'a plain attack reads as RPG_RT words it: the attack, then the damage' do
  scene, = battle_at_command
  lines = scene.send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 42,
                       target_ally: false })
  eq ['Heroの攻撃！', 'Slimeに 42 のダメージを与えた！'], lines
end

check 'and from the other side, with the other predicate and particle' do
  scene, = battle_at_command
  lines = scene.send(:battle_action_lines,
                     { attacker: 'Slime', target: 'Hero', damage: 7,
                       target_ally: true })
  eq ['Slimeの攻撃！', 'Heroは 7 のダメージを受けた！'], lines
end

check 'a miss reads as the target dodging' do
  scene, = battle_at_command
  lines = scene.send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 0,
                       missed: true, target_ally: false })
  eq ['Heroの攻撃！', 'Slimeは身をかわした！'], lines
end

check 'a blow that gets through for nothing says so' do
  scene, = battle_at_command
  lines = scene.send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 0,
                       target_ally: false })
  eq ['Heroの攻撃！', 'Slimeにダメージを与えられない！'], lines
end

check 'the basic actions with no target are one line each' do
  scene, = battle_at_command
  eq ['Slimeは身を守っている'],
     scene.send(:battle_action_lines, { attacker: 'Slime', defend: true })
  eq ['Slimeは力をためている・・・'],
     scene.send(:battle_action_lines, { attacker: 'Slime', charge: true })
  eq ['Slimeは逃げてしまった！'],
     scene.send(:battle_action_lines, { attacker: 'Slime', fled: true })
  eq ['Slimeは変身した！'],
     scene.send(:battle_action_lines, { attacker: 'Slime', transform: true,
                                        target: 'Bat' })
end

check 'an autodestruct names itself and then the damage it did' do
  scene, = battle_at_command
  eq ['Slimeは自爆した！', 'Heroは 20 のダメージを受けた！'],
     scene.send(:battle_action_lines,
                { attacker: 'Slime', target: 'Hero', damage: 20,
                  autodestruct: true, target_ally: true })
end

# A database that leaves a battle term blank must not produce a half-sentence.
check 'a blank term drops the whole entry back to the composed wording' do
  scene, = battle_at_command
  # `observing` is blank in the fixture, so Observe cannot be worded from the
  # table and the entry falls back whole rather than printing a bare name.
  eq ['Slime watches closely'],
     scene.send(:battle_action_lines, { attacker: 'Slime', observe: true })
end

check 'a skill keeps its composed line until its own sentence is read' do
  scene, = battle_at_command
  # using_message1 / use_item are still unread; dropping to the bare damage line
  # would lose the only thing naming what was cast.
  eq ["Hero's Venom hits Slime for 7"],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Venom',
                  target_ally: false })
end

check 'the state sentences still follow the action ones' do
  scene, = battle_at_command
  lines = scene.send(:battle_action_lines,
                     { attacker: 'Slime', target: 'Hero', damage: 7,
                       inflicted: [3], target_ally: true })
  eq ['Slimeの攻撃！', 'Heroは 7 のダメージを受けた！', 'Hero is poisoned!'], lines
end

check 'a skill announces itself with its own two sentences, then the damage' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 42 のダメージを与えた！'],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 42, skill: 'Fire',
                  skill_id: 8, target_ally: false })
end

check 'a skill with only a first sentence gives one line before the damage' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'Slimeに 5 のダメージを与えた！'],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 5, skill: 'Heal',
                  skill_id: 9, target_ally: false })
end

check 'a skill row with no sentence keeps the composed line' do
  scene, = battle_at_command
  eq ["Hero's Mute hits Slime for 5"],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 5, skill: 'Mute',
                  skill_id: 10, target_ally: false })
end

check 'a skill that misses takes its own failure sentence, not the damage line' do
  scene, = battle_at_command
  eq ['Heroは呪文を唱えた！', 'Slimeは眠らなかった！'],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 0, missed: true,
                  skill: 'Sleep', skill_id: 11, target_ally: false })
end

check 'a heal that restored nothing reads as a failure' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'Heroには効かなかった！'],
     scene.send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Heal', skill_id: 9,
                  target: 'Hero', recover_hp: 0, recover_mp: 0,
                  cured: [], target_ally: true })
end

check 'a heal that worked says what it restored, in the game own words' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'HeroのＨＰが 30 回復した！'],
     scene.send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Heal', skill_id: 9,
                  target: 'Hero', recover_hp: 30, recover_mp: 0,
                  cured: [], target_ally: true })
end

check 'a heal that filled both pools says so once per pool' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'HeroのＨＰが 30 回復した！',
      'HeroのＭＰが 12 回復した！'],
     scene.send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Heal', skill_id: 9,
                  target: 'Hero', recover_hp: 30, recover_mp: 12,
                  cured: [], target_ally: true })
end

check 'an item names itself with the caster, the item and the term' do
  scene, = battle_at_command
  eq ['HeroはPotionを使った！', 'HeroのＨＰが 30 回復した！'],
     scene.send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Potion', item_id: 3,
                  target: 'Hero', recover_hp: 30, recover_mp: 0,
                  cured: [], target_ally: true })
end

check 'an item that only cured says so through the state sentence' do
  scene, = battle_at_command
  eq ['HeroはAntidoteを使った！', 'Hero is cured.'],
     scene.send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Antidote', item_id: 5,
                  target: 'Hero', recover_hp: 0, recover_mp: 0,
                  cured: [3], target_ally: true })
end

check 'an item that did nothing keeps the composed line' do
  scene, = battle_at_command
  # RPG2000 gives an item no failure sentence to choose from -- unlike a skill,
  # it has no failure_message -- so the composed wording still says more.
  ok scene.send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Potion', item_id: 3,
                  target: 'Hero', recover_hp: 0, recover_mp: 0,
                  cured: [], target_ally: true })
     .first.include?('no effect')
end

check 'a drain adds its own line after the damage' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 20 のダメージを与えた！', 'SlimeのＨＰを 20 奪った！'],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 20, skill: 'Fire',
                  skill_id: 8, absorbed_hp: 20, target_ally: false })
end

check 'a drain on a party member is worded from their side' do
  scene, = battle_at_command
  eq ['Slimeは炎を放った！', 'あたりが真っ赤に染まる！',
      'Heroは 20 のダメージを受けた！', 'HeroはＨＰを 20 奪われた！'],
     scene.send(:battle_action_lines,
                { attacker: 'Slime', target: 'Hero', damage: 20, skill: 'Fire',
                  skill_id: 8, absorbed_hp: 20, target_ally: true })
end

check 'a skill that drained nothing adds no line' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 20 のダメージを与えた！'],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 20, skill: 'Fire',
                  skill_id: 8, absorbed_hp: 0, target_ally: false })
end

check 'a skill still trails the states it landed' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 7 のダメージを与えた！', 'Slime looks ill!'],
     scene.send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
                  skill_id: 8, inflicted: [3], target_ally: false })
end

check 'the action banner announces the states an action landed and lifted' do
  scene, = battle_at_command
  # The database's own sentences, printed straight after the target's name.
  scene.send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Venom',
               inflicted: [3], target_ally: false })
  ui = scene.instance_variable_get(:@battle_ui)
  texts = window_texts(ui[:action_win])
  ok texts.any? { |t| t.include?('Venom') }, 'the action itself still reads'
  ok texts.include?('Slime looks ill!'), 'with the enemy wording for the state'

  # The same state on a party member takes the actor wording.
  scene.send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 7,
               inflicted: [3], target_ally: true })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Hero is poisoned!'), 'and the actor wording for an ally'

  # A cure reads the recovery sentence.
  scene.send(:show_battle_action,
             { recover: true, actor: 'Hero', source: 'Antidote', target: 'Hero',
               recover_hp: 0, recover_mp: 0, cured: [3], target_ally: true })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Hero is cured.'), 'the recovery sentence'

  # So does a state a blow shook off (`woke`, a state's release_by_attack) --
  # the state lifting is the same event however it happened.
  scene.send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 9,
               woke: [3], target_ally: false })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Slime is cured.'), 'a state shaken off by a blow reads the same'
end

check 'being downed is announced with the death state own sentence' do
  scene, = battle_at_command
  # State 1 is death; the fake database words it from the speaker's side, the
  # way a real one does.
  scene.send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 30,
               defeated: true, target_ally: false })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Slime is struck down!'), 'the enemy wording'
  scene.send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 30,
               defeated: true, target_ally: true })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Hero falls!'), 'and the actor wording'
end

check 'a status the target already had is announced, in the state own words' do
  scene, = battle_at_command
  scene.send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               already: [3], target_ally: true })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Hero is already poisoned!'),
     'one wording, whichever side the target is on'
  scene.send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 3,
               already: [3], target_ally: false })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Slime is already poisoned!')
end

check 'an already-carried state with no sentence still gets announced' do
  scene, = battle_at_command
  # State 4 (Sleep) has a name but no message_already, which is what an
  # English-release database looks like.
  scene.send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               already: [4], target_ally: true })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Hero is already Sleep'), 'the scene composes its own wording'
end

check 'a state the database gives no sentence still gets announced' do
  scene, = battle_at_command
  # State 5 (Silence) has a name but no message_actor / message_enemy, which is
  # what an English-release database looks like.
  scene.send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               inflicted: [5], target_ally: true })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Hero is Silence'), 'the scene composes its own wording'

  # An id the table does not define at all still reads as something.
  scene.send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               inflicted: [99], target_ally: true })
  ok window_texts(scene.instance_variable_get(:@battle_ui)[:action_win])
      .include?('Hero is state 99'), 'falling back to the id'
end

# -- conditions on the field windows ------------------------------------------
# RPG_RT shows an actor's condition in three field windows as well as in battle
# (its Window_MenuStatus, Window_ActorTarget and Window_ActorInfo), which is
# where a player finds out who needs the antidote.

# A party the field menus can render: one actor exposing everything the menu
# party list, the item / skill target list and the status screen read. The item
# and skill lists are empty — what these checks are about is the condition,
# not the lists.
class MenuStubActor
  attr_reader :name, :title, :level, :hp, :max_hp, :mp, :max_mp,
              :atk, :def, :int, :agi, :exp, :states, :equipment
  def initialize
    @name = 'Hero'; @title = 'Wanderer'; @level = 5
    @hp = 80; @max_hp = 120; @mp = 10; @max_mp = 30
    @atk = 20; @def = 12; @int = 9; @agi = 14; @exp = 300
    @states = []
    @equipment = [0, 0, 0, 0, 0]
  end
  def exp_to_next; 120; end
  def add_state(id); @states.push(id) unless @states.include?(id); end
  attr_accessor :equipment_fixed_flag
  def equipment_fixed?; !!@equipment_fixed_flag; end
end

class MenuStubParty
  attr_reader :actors, :gold, :revision
  attr_accessor :leader
  def initialize
    @actors = [MenuStubActor.new]; @gold = 0; @leader = nil; @revision = 0
  end
  def field_items; []; end
  def field_skills(_actor, _state = nil); []; end
end

def menu_scene(klass, state)
  klass.new(fake_parent(fake_db), state)
end

def menu_state
  Game::State.new(MenuStubParty.new, 1, 0, 0)
end

# A two-actor party carrying a couple of usable items, skills and equip
# candidates -- MenuStubParty above is a deliberately bare single actor with
# empty lists (all the condition checks need), but the cursor-wrap checks
# below need more than one row/actor to wrap across.
class WrapMenuParty < MenuStubParty
  def initialize
    super
    @actors = [MenuStubActor.new, MenuStubActor.new]
  end
  def field_items; [[1, 3], [2, 1]]; end
  def field_skills(_actor, _state = nil); [[10, 2], [11, 4]]; end
  def db_item(id); OpenStruct.new(name: "Item#{id}"); end
  def db_skill(id); OpenStruct.new(name: "Skill#{id}"); end
  def equip_candidates(_slot, _actor = nil); [[7, 2], [8, 1]]; end
end

def wrap_menu_state
  Game::State.new(WrapMenuParty.new, 1, 0, 0)
end

check 'the menu party list shows each member condition' do
  st = menu_state
  hero = st.party.actors.first
  win = menu_scene(RPG2k::Scene::Menu, st).instance_variable_get(:@status)
  ok window_texts(win).include?('Normal'),
     'a clear member shows the database normal term'

  hero.add_state(3)                                     # Poison
  texts = window_texts(menu_scene(RPG2k::Scene::Menu, st)
                         .instance_variable_get(:@status))
  ok texts.include?('Poison'), 'and an afflicted one shows the state'
  ok !texts.include?('Normal'), 'the normal term is replaced, not added to'
end

check 'Scene::Menu: the main command cursor wraps around' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@index), 'starts on the first command'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 5, scene.instance_variable_get(:@index), 'Up from the first command wraps to the last (6 commands)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@index), 'Down from the last command wraps to the first'
end

check 'the item / skill target list shows who is afflicted' do
  st = menu_state
  st.party.actors.first.add_state(4)                    # Sleep
  [RPG2k::Scene::ItemMenu, RPG2k::Scene::SkillMenu].each do |klass|
    scene = menu_scene(klass, st)
    scene.send(:build_target_window)
    texts = window_texts(scene.instance_variable_get(:@target_window))
    ok texts.include?('Sleep'), "the #{klass} target list shows the condition"
  end
end

check 'Scene::ItemMenu: the item list and target cursors wrap around' do
  scene = menu_scene(RPG2k::Scene::ItemMenu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@item_index), 'starts on the first item'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@item_index), 'Up from the first item wraps to the last (2 items)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@item_index), 'Down from the last item wraps to the first'

  # Enter target mode (a two-actor party) and wrap that cursor too.
  scene.send(:prompt_item_target, 1)
  eq 0, scene.instance_variable_get(:@target_index), 'target starts on the first ally'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@target_index), 'Up from the first ally wraps to the last (2 actors)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@target_index), 'Down from the last ally wraps to the first'
end

check 'Scene::SkillMenu: the skill list, caster and target cursors wrap around' do
  scene = menu_scene(RPG2k::Scene::SkillMenu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@skill_index), 'starts on the first skill'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@skill_index), 'Up from the first skill wraps to the last (2 skills)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@skill_index), 'Down from the last skill wraps to the first'

  eq 0, scene.instance_variable_get(:@caster_index), 'starts on the first caster'
  RGSS::Input.triggered = [RGSS::Input::LEFT]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@caster_index), 'Left from the first caster wraps to the last (2 actors)'
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@caster_index), 'Right from the last caster wraps to the first'

  # Target mode (single-ally scope skill) has its own cursor over the party.
  scene.instance_variable_set(:@mode, :target)
  scene.instance_variable_set(:@target_index, 0)
  scene.send(:build_target_window)
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@target_index), 'Up from the first ally wraps to the last (2 actors)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@target_index), 'Down from the last ally wraps to the first'
end

# A party whose only two skills are Escape (30) and Teleport (31), each
# offered once #escape_access / #teleport_access and a target are set on the
# real Game::State that holds it -- Game::Party's own decision logic
# (#field_skill? / #cast_escape_skill / #cast_teleport_skill) is covered by
# scripts/rpg2k_logic_check.rb; this stub only has to hand the scene something
# that behaves the same way, so the checks below stay about the RGSS wiring
# (does casting queue a teleport and close the menu?) rather than repeating
# that coverage under RGSS stubs.
class EscapeTeleportStubParty < MenuStubParty
  ESCAPE_SID = 30
  TELEPORT_SID = 31

  def field_skills(_actor, state = nil)
    return [] unless state
    rows = []
    rows << [ESCAPE_SID, 5] if state.escape_access && state.escape_target
    if state.teleport_access && !state.teleport_targets.empty?
      rows << [TELEPORT_SID, 3]
    end
    rows
  end

  def db_skill(id)
    case id
    when ESCAPE_SID then OpenStruct.new(name: 'Escape', type: Game::Party::SKILL_ESCAPE)
    when TELEPORT_SID then OpenStruct.new(name: 'Warp', type: Game::Party::SKILL_TELEPORT)
    end
  end

  def cast_escape_skill(_caster, sid, state)
    return nil unless sid == ESCAPE_SID && state.escape_target
    state.escape_target
  end

  def cast_teleport_skill(_caster, sid, state, map_id)
    return nil unless sid == TELEPORT_SID
    target = state.teleport_targets[map_id]
    return nil unless target
    { map_id: map_id, x: target[:x], y: target[:y] }
  end
end

def escape_teleport_state
  st = Game::State.new(EscapeTeleportStubParty.new, 1, 0, 0)
  st.escape_access = true
  st.escape_target = { map_id: 9, x: 1, y: 2, switch_id: nil }
  st.teleport_access = true
  st.teleport_targets[10] = { x: 11, y: 12, switch_id: nil }
  st.teleport_targets[20] = { x: 21, y: 22, switch_id: nil }
  st
end

check 'Scene::SkillMenu: an Escape skill queues its target and closes the menu' do
  parent = fake_parent(fake_db)
  state = escape_teleport_state
  scene = RPG2k::Scene::SkillMenu.new(parent, state)
  eq [[30, 5], [31, 3]], scene.send(:skills), 'Escape (registered target) then Teleport'
  RGSS::Input.triggered = [RGSS::Input::C]           # confirm the first row, Escape
  scene.update
  RGSS::Input.reset
  eq [9, 1, 2, 0], state.pending_teleport, 'queued straight from the one registered escape target'
  ok parent.pop_to_map_called, 'the whole menu stack closes rather than staying open'
end

check 'Scene::SkillMenu: a Teleport skill opens a destination list and queues the chosen one' do
  parent = fake_parent(fake_db)
  state = escape_teleport_state
  scene = RPG2k::Scene::SkillMenu.new(parent, state)
  RGSS::Input.triggered = [RGSS::Input::DOWN]        # move onto Teleport (row 2)
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]           # confirm -- opens the destination list
  scene.update
  RGSS::Input.reset
  eq :teleport_target, scene.instance_variable_get(:@mode)
  eq [[10, 'Map 10'], [20, 'Map 20']], scene.send(:teleport_targets),
     'both registered destinations, ascending by map id, named by their bare id ' \
     '(this fixture parent carries no map tree)'
  ok state.pending_teleport.nil?, 'opening the list does not warp yet'

  RGSS::Input.triggered = [RGSS::Input::DOWN]        # move onto the second destination (map 20)
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]           # confirm it
  scene.update
  RGSS::Input.reset
  eq [20, 21, 22, 0], state.pending_teleport
  ok parent.pop_to_map_called
end

check 'Scene::SkillMenu: cancelling the destination list returns to the skill list' do
  parent = fake_parent(fake_db)
  state = escape_teleport_state
  scene = RPG2k::Scene::SkillMenu.new(parent, state)
  RGSS::Input.triggered = [RGSS::Input::DOWN]        # move onto Teleport (row 2)
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]           # confirm -- opens the destination list
  scene.update
  RGSS::Input.reset
  eq :teleport_target, scene.instance_variable_get(:@mode)
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.reset
  eq :skills, scene.instance_variable_get(:@mode)
  ok state.pending_teleport.nil?
  ok !parent.pop_to_map_called
end

check 'Scene::Map: a pending teleport queued by the field skill menu is applied' do
  scene = new_scene({}, player: [0, 0])
  state = scene.instance_variable_get(:@state)
  state.pending_teleport = [1, 3, 4, 6] # same map id, elsewhere on it, facing left
  scene.update
  eq 1, state.map_id
  eq 3, state.x
  eq 4, state.y
  eq 6, state.direction
  ok state.pending_teleport.nil?, 'the request is consumed, not reapplied every frame'
end

# One map-tree node's save/teleport/escape tri-states (parent_map_id left nil
# -- MapAccess#allowed? reads a missing one as 0, the tree root). Mirrors
# scripts/rpg2k_logic_check.rb's own fixture of the same name; reused here to
# prove Scene::Map actually reaches Game::MapAccess, not just that the module
# answers correctly in isolation.
FakeAccessNode = Struct.new(:save, :teleport, :escape, :parent_map_id)

def fake_map_tree(props)
  Struct.new(:map_properties).new(props)
end

check 'Scene::Map re-derives Save/Teleport/Escape access from the map tree ' \
     'on load and on Teleport, but leaves Menu access alone' do
  parent = fake_parent(fake_db)
  parent.map_tree = fake_map_tree(
    1 => FakeAccessNode.new(2, 2, 1), # map 1: save+teleport forbidden, escape allowed
    2 => FakeAccessNode.new(1, 1, 2)  # map 2: save+teleport allowed, escape forbidden
  )
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, {})
  scene = RPG2k::Scene::Map.new(parent, state)
  eq false, state.save_access, 'map 1 forbids Save'
  eq false, state.teleport_access, 'map 1 forbids Teleport'
  eq true, state.escape_access, 'map 1 allows Escape'

  # A Control Menu Access override mid-visit -- unlike Save/Teleport/Escape,
  # Menu access has no map-tree setting at all (RPG2000 never offers one) and
  # so is never re-derived; it must still read false after the transfer below.
  state.menu_access = false
  scene.send(:perform_teleport, [2, 0, 0, 0])
  eq true, state.save_access, 'map 2 allows Save'
  eq true, state.teleport_access, 'map 2 allows Teleport'
  eq false, state.escape_access, 'map 2 forbids Escape'
  eq false, state.menu_access,
     'Menu access is not re-derived from the tree; it persists across the transfer'
end

check 'Scene::EquipMenu: the slot list, actor and candidate cursors wrap around' do
  scene = menu_scene(RPG2k::Scene::EquipMenu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@slot_index), 'starts on the first slot'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 4, scene.instance_variable_get(:@slot_index), 'Up from the first slot wraps to the last (5 slots)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@slot_index), 'Down from the last slot wraps to the first'

  eq 0, scene.instance_variable_get(:@actor_index), 'starts on the first actor'
  RGSS::Input.triggered = [RGSS::Input::LEFT]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@actor_index), 'Left from the first actor wraps to the last (2 actors)'
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@actor_index), 'Right from the last actor wraps to the first'

  # The equip-candidate list (Remove + the two fitting bag items = 3 rows).
  scene.instance_variable_set(:@mode, :items)
  scene.instance_variable_set(:@cand_index, 0)
  scene.send(:build_cand_window)
  eq 3, scene.send(:candidates).size, 'Remove plus the two candidates'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 2, scene.instance_variable_get(:@cand_index), 'Up from the first candidate wraps to the last'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@cand_index), 'Down from the last candidate wraps to the first'
end

check 'Scene::EquipMenu: 装備固定 refuses to open the item list for that actor' do
  state = wrap_menu_state
  state.party.actors.first.equipment_fixed_flag = true
  scene = menu_scene(RPG2k::Scene::EquipMenu, state)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :slots, scene.instance_variable_get(:@mode), 'the slot list stays up, not the item list'

  # The second party member is not locked -- switching to them and pressing C
  # opens the list as normal, so the gate really is per-actor.
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :items, scene.instance_variable_get(:@mode)
end

check 'the status screen gives the condition a labelled row' do
  st = menu_state
  texts = window_texts(menu_scene(RPG2k::Scene::StatusMenu, st)
                         .instance_variable_get(:@window))
  ok texts.include?('State'), 'the row is labelled'
  ok texts.include?('Normal'), 'and reads normal for a clear actor'

  st.party.actors.first.add_state(1)                    # the death state
  texts = window_texts(menu_scene(RPG2k::Scene::StatusMenu, st)
                         .instance_variable_get(:@window))
  ok texts.include?('Down'), 'a downed actor reads as such, not merely HP 0'
end

check 'Scene::StatusMenu: the actor cursor wraps around' do
  scene = menu_scene(RPG2k::Scene::StatusMenu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@actor_index), 'starts on the first actor'
  RGSS::Input.triggered = [RGSS::Input::LEFT]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@actor_index), 'Left from the first actor wraps to the last (2 actors)'
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@actor_index), 'Right from the last actor wraps to the first'
end

check 'the field windows resolve the same condition the battle panel does' do
  # Both go through Scene::Base#state_display, so a state that outranks another
  # in battle outranks it in the menu too.
  st = menu_state
  hero = st.party.actors.first
  hero.add_state(5)                                     # Silence, priority 10
  hero.add_state(4)                                     # Sleep, priority 80
  texts = window_texts(menu_scene(RPG2k::Scene::Menu, st)
                         .instance_variable_get(:@status))
  ok texts.include?('Sleep'), 'the significant state wins here as well'
  ok !texts.include?('Silence'), 'and the outranked one is not shown'
end

# Frames one walked tile takes: TILE / SPEED of movement, plus the frame that
# starts the step. Walking `n` tiles needs a little slack on top, and the fixture
# map is 6 wide, so a rightward walk has room for four.
def walk(scene, tiles, dir = 6)
  RGSS::Input.dir_value = dir
  ((RPG2k::Scene::Map::TILE / RPG2k::Scene::Map::SPEED + 1) * tiles + 2).times do
    scene.update
  end
  RGSS::Input.reset
end

check 'walking slips HP from a poisoned member every fourth tile' do
  # The fixture's Poison carries mtf-meido-action's map-step fields. Nothing
  # showed a field ailment doing anything before this: it sat on the actor and
  # the party walked on untouched.
  hero = SlipActor.new([3])                             # Poison
  scene = new_scene({}, player: [0, 0], members: [hero])
  st = scene.instance_variable_get(:@state)

  walk(scene, 3)
  eq 3, st.steps, 'three tiles walked'
  eq 100, hero.hp, 'not a multiple of the interval yet'

  walk(scene, 1)
  eq 4, st.steps
  eq 99, hero.hp, 'the fourth tile slips 1 HP'
end

check 'walking a damaging terrain takes HP every tile' do
  # 地形ダメージ: unlike the status slip this is a property of the ground, and it
  # bites on every tile rather than on an interval. Nepheshel's ダメージ床 set and
  # mtf-meido-action's Poison Swamp are the real ones, both at 1 HP.
  hero = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [hero], terrain_damage: 3)
  st = scene.instance_variable_get(:@state)

  walk(scene, 1)
  eq 1, st.steps
  eq 97, hero.hp, 'the first tile already hurts'
  walk(scene, 2)
  eq 91, hero.hp, 'and so does every one after it'
end

check 'gear flagged 地形ダメージ無効 walks the damaging ground unharmed' do
  hero = SlipActor.new([])
  hero.prevents_terrain_damage = true
  scene = new_scene({}, player: [0, 0], members: [hero], terrain_damage: 3)
  walk(scene, 4)
  eq 100, hero.hp, 'the boots blocked all four tiles'
end

check 'terrain damage cannot kill, and skips a member already down' do
  hurt = SlipActor.new([], 2)
  scene = new_scene({}, player: [0, 0], members: [hurt], terrain_damage: 5)
  walk(scene, 3)
  eq 1, hurt.hp, 'worn to 1 HP and left standing'
  ok !hurt.dead?

  down = SlipActor.new([], 0)
  scene2 = new_scene({}, player: [0, 0], members: [down], terrain_damage: 5)
  walk(scene2, 2)
  eq 0, down.hp, 'a member already down is skipped'
end

check 'harmless ground takes nothing' do
  hero = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [hero])   # damage 0
  walk(scene, 4)
  eq 100, hero.hp
end

# -- bush depth (下半身消去) ---------------------------------------------------

# Every tile of the synthetic map is terrain 42, so `bush_depth:` sets what the
# ground under everyone does.

check 'the tile under the party decides how deep the hero sinks' do
  { 0 => 0, 1 => 10, 2 => 16, 3 => 32 }.each do |depth, px|
    scene = new_scene({}, player: [1, 1], bush_depth: depth)
    eq px, scene.send(:player_bush_depth), "terrain bush_depth #{depth}"
  end
end

check 'a hero over the tile rather than in it does not sink' do
  scene = new_scene({}, player: [1, 1], bush_depth: 2)
  eq 16, scene.send(:player_bush_depth), 'standing in it'
  scene.instance_variable_set(:@player_jumping, true)
  eq 0, scene.send(:player_bush_depth), 'mid-jump, over the grass'
end

check 'a boarded party draws its vehicle, so the hero does not sink' do
  scene = new_scene({}, player: [1, 1], bush_depth: 3)
  st = scene.instance_variable_get(:@state)
  eq 32, scene.send(:player_bush_depth)
  st.boarded = :boat
  eq 0, scene.send(:player_bush_depth)
end

check 'an event sinks only on the hero\'s own layer' do
  same  = event(1, 1, page(charset_name: 'c', layer: 1))
  below = event(2, 1, page(charset_name: 'c', layer: 0))
  above = event(3, 1, page(charset_name: 'c', layer: 2))
  scene = new_scene({ 1 => same, 2 => below, 3 => above },
                    player: [5, 4], bush_depth: 1)
  eh = event_hashes(scene)
  eq 10, scene.send(:event_bush_depth, eh[1]), 'same layer wades'
  eq 0, scene.send(:event_bush_depth, eh[2]), 'below-hero is scenery'
  eq 0, scene.send(:event_bush_depth, eh[3]), 'above-hero is a treetop'
  eh[1][:jumping] = true
  eq 0, scene.send(:event_bush_depth, eh[1]), 'and a jumping event clears it'
end

check 'a tile-graphic event scales the sink to its own 16px frame' do
  ev = event(1, 1, page(charset_name: '', layer: 1))
  scene = new_scene({ 1 => ev }, player: [5, 4], bush_depth: 2)
  eq 8, scene.send(:event_bush_depth, event_hashes(scene)[1], 16)
end

# The blit itself: one call when nothing sinks, a split pair when part of the
# frame does, and a single half-opacity call when all of it does.
check 'blt_bushed lays the frame down in one piece when nothing sinks' do
  scene = new_scene({})
  dst = RGSS::Bitmap.new(24, 32)
  src = RGSS::Bitmap.new(240, 256)
  dst.clear_blt_calls
  scene.send(:blt_bushed, dst, 0, 0, src, RGSS::Rect.new(0, 0, 24, 32), 255, 0)
  eq 1, dst.blt_calls.size
  eq 255, dst.blt_calls[0][4], 'at full opacity'
end

check 'blt_bushed splits the frame at the water line' do
  scene = new_scene({})
  dst = RGSS::Bitmap.new(24, 32)
  src = RGSS::Bitmap.new(240, 256)
  dst.clear_blt_calls
  # A depth-2 sink on a frame lifted from (48, 64): the top 16 rows stay solid
  # and the bottom 16 go half-transparent, both from the matching source rows.
  scene.send(:blt_bushed, dst, 5, 7, src, RGSS::Rect.new(48, 64, 24, 32), 255, 16)
  eq 2, dst.blt_calls.size
  top, bottom = dst.blt_calls
  eq [5, 7], [top[0], top[1]]
  eq [48, 64, 24, 16], [top[3].x, top[3].y, top[3].width, top[3].height]
  eq 255, top[4], 'the dry half is untouched'
  eq [5, 23], [bottom[0], bottom[1]], 'the wet half lands 16px lower'
  eq [48, 80, 24, 16], [bottom[3].x, bottom[3].y, bottom[3].width, bottom[3].height]
  eq 128, bottom[4], 'and draws at half opacity'
end

check 'a frame that sinks entirely is one half-opacity blit, not a split' do
  scene = new_scene({})
  dst = RGSS::Bitmap.new(24, 32)
  src = RGSS::Bitmap.new(240, 256)
  dst.clear_blt_calls
  scene.send(:blt_bushed, dst, 0, 0, src, RGSS::Rect.new(0, 0, 24, 32), 255, 32)
  eq 1, dst.blt_calls.size
  eq 128, dst.blt_calls[0][4]
end

check 'an already-translucent event halves again as it wades' do
  scene = new_scene({})
  dst = RGSS::Bitmap.new(24, 32)
  src = RGSS::Bitmap.new(240, 256)
  dst.clear_blt_calls
  scene.send(:blt_bushed, dst, 0, 0, src, RGSS::Rect.new(0, 0, 24, 32), 128, 10)
  eq [128, 64], dst.blt_calls.map { |c| c[4] }
end

# End to end: the real draw path, not the helper in isolation.
check 'drawing a same-layer event on a bush tile emits the split pair' do
  ev = event(1, 1, page(charset_name: 'Villager', layer: 1))
  scene = new_scene({ 1 => ev }, player: [5, 4], bush_depth: 1)
  e = event_hashes(scene)[1]
  buf = scene.send(:event_target_buffer, e)
  buf.clear_blt_calls
  scene.send(:draw_event, e, 0, 0)
  eq 2, buf.blt_calls.size, 'a split pair reached the buffer'
  eq [255, 128], buf.blt_calls.map { |c| c[4] }
  eq [22, 10], buf.blt_calls.map { |c| c[3].height }, 'the lower 10 of 32 sink'
end

check 'drawing the same event on plain ground emits one blit' do
  ev = event(1, 1, page(charset_name: 'Villager', layer: 1))
  scene = new_scene({ 1 => ev }, player: [5, 4]) # bush_depth 0
  e = event_hashes(scene)[1]
  buf = scene.send(:event_target_buffer, e)
  buf.clear_blt_calls
  scene.send(:draw_event, e, 0, 0)
  eq 1, buf.blt_calls.size
  eq 255, buf.blt_calls[0][4]
end

check 'a clear member walks the same ground untouched' do
  hero = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [hero])
  st = scene.instance_variable_get(:@state)
  walk(scene, 4)
  eq 4, st.steps
  eq 100, hero.hp, 'no state, no slip'
  eq false, st.screen.flashing?, 'and nothing flashes'
end

check 'a step that slips flashes the screen' do
  # The map shows no HP, so without this the drain would be silent.
  hero = SlipActor.new([3])
  scene = new_scene({}, player: [0, 0], members: [hero])
  st = scene.instance_variable_get(:@state)
  walk(scene, 3)
  eq false, st.screen.flashing?, 'a step that drains nothing does not flash'
  walk(scene, 1)
  ok st.screen.flashing?, 'the draining step does'
end

check 'a teleport is not a walked step' do
  # The party arrives without walking, so RPG_RT does not count it. Counting it
  # would let an event chain drain a poisoned party by moving it around.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::TELEPORT, [1, 4, 3])]
  hero = SlipActor.new([3])
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0], members: [hero])
  st = scene.instance_variable_get(:@state)
  20.times { scene.update }
  eq [4, 3], [st.x, st.y], 'the teleport landed'
  eq 0, st.steps, 'and counted no steps'
  eq 100, hero.hp
end

# A page that forces a route on the player: target 10001, freq 8, repeat off,
# skippable on, then the route's own commands.
def player_route_page(*cmds)
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(Game::Interpreter::Cmd::MOVE_EVENT,
                                [10001, 8, 0, 1, *cmds])]
  pg
end

check 'a forced player route slides the party instead of snapping it' do
  # It used to write the tile straight onto the state, so a cutscene walking the
  # hero across a room teleported it a tile at a time while its own input-driven
  # walking interpolated. The party is drawn between tiles now.
  scene = new_scene({ 1 => event(3, 3, player_route_page(R::MOVE_RIGHT)) },
                    player: [0, 0])
  st = scene.instance_variable_get(:@state)
  between = 0
  30.times do
    scene.update
    px, = scene.send(:player_pixel)
    between += 1 unless (px % Game::TILE).zero?
  end
  ok between > 0, 'the party was drawn part-way between two tiles'
  eq 1, st.x, 'and it still arrives on the destination tile'
  eq 0, st.y
end

check 'a forced route step lands before the next one starts' do
  # The route character runs ahead of the party -- it is what the route steps --
  # so a second step taken mid-slide would leave the two more than a tile apart
  # and stretch one slide across the gap.
  scene = new_scene({ 1 => event(3, 3, player_route_page(R::MOVE_RIGHT,
                                                         R::MOVE_RIGHT)) },
                    player: [0, 0])
  st = scene.instance_variable_get(:@state)
  60.times do
    scene.update
    dest = scene.instance_variable_get(:@dest_x)
    ok (dest - st.x).abs <= 1,
       "the slide never spans more than a tile (#{st.x} -> #{dest})"
  end
  eq 2, st.x, 'both steps ran'
end

check 'a forced player jump arcs the hero the way it arcs an event' do
  scene = new_scene({ 1 => event(3, 3, player_route_page(R::BEGIN_JUMP,
                                                         R::MOVE_RIGHT,
                                                         R::MOVE_RIGHT,
                                                         R::END_JUMP)) },
                    player: [0, 0])
  st = scene.instance_variable_get(:@state)
  heights = []
  40.times do
    scene.update
    h = scene.send(:player_jump_offset)
    heights << h if scene.instance_variable_get(:@player_jumping)
  end
  eq 2, st.x, 'the hop cleared two tiles'
  eq 21, heights.max, 'and rose to the same peak an event does'
  peak = heights.index(heights.max)
  ok heights[0...peak] == heights[0...peak].sort,
     "rises to the peak: #{heights.inspect}"
  # The ends of the arc, read off the shared curve rather than off a sampling
  # frame -- the first frame after an update is already two pixels into the step.
  eq 0, scene.send(:jump_offset_for, 0), 'the hop begins on the ground'
  eq 0, scene.send(:jump_offset_for, Game::TILE), 'and ends on it'
  eq 0, scene.send(:player_jump_offset), 'and the hero is back on it once landed'
end

check 'a forced player walk is never lifted' do
  scene = new_scene({ 1 => event(3, 3, player_route_page(R::MOVE_RIGHT)) },
                    player: [0, 0])
  30.times do
    scene.update
    eq 0, scene.send(:player_jump_offset), 'a step is not a hop'
  end
end

# yado.tk: move-route "Change Graphic" (hero or vehicle) applies visibly but
# does not persist like the dedicated Change Hero Graphic command — it reverts
# on Transfer Player (and, being scene-only state, on save/load too, since
# Continue always builds a fresh Scene::Map).
check 'a forced route Change Graphic overrides the hero sprite, reverting on Transfer Player' do
  ic = Game::Interpreter::Cmd
  name = 'other'
  # Move Event params: target 10001, freq 8, repeat off, skippable on, then the
  # packed move command -- Change Graphic carries its filename length + the
  # graphic index, with the filename bytes in the command's own string field
  # (see Interpreter#decode_move_route).
  params = [10001, 8, 0, 1, R::CHANGE_GRAPHIC, name.length, 3]
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::MOVE_EVENT, params, string: name)]
  scene = new_scene({ 1 => event(3, 3, pg) }, player: [0, 0])
  5.times { scene.update }
  charset, index = scene.send(:player_draw_charset)
  ok charset, 'the overridden charset bitmap loaded'
  eq 3, index, 'the overridden graphic index applied'
  ok !charset.equal?(scene.instance_variable_get(:@charset)),
     'the override bitmap is not the leader\'s own charset'

  scene.send(:perform_teleport, [1, 0, 0, 0])
  charset2, index2 = scene.send(:player_draw_charset)
  eq scene.instance_variable_get(:@charset), charset2,
     'Transfer Player reverted to the leader\'s own charset'
  eq scene.instance_variable_get(:@charset_index), index2
end

check 'a teleport lands the party on its tile, not mid-slide' do
  # A teleport can land while a forced route has a step in flight: the route
  # advances between events, and an auto-start page can fire on the very next
  # frame. The party must arrive standing on the destination, not still sliding
  # toward the tile it was walking to on the old map.
  scene = new_scene({ 1 => event(3, 3, player_route_page(R::MOVE_RIGHT)) },
                    player: [0, 0])
  40.times do
    break if scene.instance_variable_get(:@moving)
    scene.update
  end
  ok scene.instance_variable_get(:@moving), 'a step really is in flight'

  scene.send(:perform_teleport, [1, 4, 3, 0])
  st = scene.instance_variable_get(:@state)
  eq [4, 3], [st.x, st.y], 'the teleport landed'
  eq false, scene.instance_variable_get(:@moving), 'and nothing is still sliding'
  eq [4, 3], scene.send(:player_pixel).map { |v| v / Game::TILE },
     'the sprite is drawn on that tile'
  eq 0, scene.send(:player_jump_offset)
end

check 'Proceed With Movement finishes a sliding player route' do
  # The interpreter parks on :movement until every forced route has finished,
  # and the normal movement step is skipped while it waits -- so that path has to
  # advance the slide itself. Without it the route starts a step, then waits
  # forever for a landing nothing is driving, and the event never resumes.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [
    ECmd.new(ic::MOVE_EVENT, [10001, 8, 0, 1, R::MOVE_RIGHT, R::MOVE_RIGHT]),
    ECmd.new(ic::PROCEED_WITH_MOVEMENT, []),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 9, 9, 0]),
  ]
  scene = new_scene({ 1 => event(3, 3, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  120.times { scene.update }
  eq 2, st.x, 'the route walked the party two tiles east'
  ok st.switches[9], 'and the event resumed once the movement was done'
end

check 'a forced player route walks the party, and its steps count' do
  # A route moves the party as surely as the player does, so its landings count
  # too -- an event that walks a poisoned party across a field should drain it.
  ic = Game::Interpreter::Cmd
  # target 10001 (player), freq 8, repeat off, skippable on, one step east.
  route_page = lambda do |cmd|
    pg = page(trigger: 3)
    pg.event_commands = [ECmd.new(ic::MOVE_EVENT, [10001, 8, 0, 1, cmd])]
    pg
  end

  scene = new_scene({ 1 => event(3, 3, route_page.call(R::MOVE_RIGHT)) },
                    player: [0, 0], members: [SlipActor.new([3])])
  st = scene.instance_variable_get(:@state)
  40.times { scene.update }
  eq 1, st.x, 'the route stepped the party one tile east'
  eq 1, st.steps, 'and that landing counted'

  # A route command that only turns moves nothing, so it counts nothing.
  scene2 = new_scene({ 1 => event(3, 3, route_page.call(R::FACE_LEFT)) },
                     player: [0, 0], members: [SlipActor.new([3])])
  st2 = scene2.instance_variable_get(:@state)
  40.times { scene2.update }
  eq [0, 0], [st2.x, st2.y], 'the party did not move'
  eq 0, st2.steps
end

check 'a transformed monster is redrawn with its new battler graphic' do
  scene, _st = battle_scene_with_pages(nil)
  10.times do
    scene.update
    ui = scene.instance_variable_get(:@battle_ui)
    break if ui && ui[:phase] == :command
  end
  ui = scene.instance_variable_get(:@battle_ui)
  before = ui[:enemy_sprites][0]
  ok before, 'the monster is on the field'
  # What Game::Battle's transform action does to the combatant.
  ui[:foes][0].battler_name = 'Dragon'
  ui[:foes][0].name = 'Dragon'
  scene.send(:refresh_battle_sprites)
  ok !ui[:enemy_sprites][0].equal?(before), 'its sprite is rebuilt'
  eq 'Dragon', ui[:sprite_names][0], 'and tracked against the new battler'
  ok ui[:enemy_sprites][0].visible, 'still on the field'
  # A second refresh with nothing changed must not churn the sprite again.
  same = ui[:enemy_sprites][0]
  scene.send(:refresh_battle_sprites)
  ok ui[:enemy_sprites][0].equal?(same), 'an unchanged battler is left alone'
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k scene check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k scene check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
