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
require 'stringio'
require 'tmpdir'

# -- RGSS stubs (just enough for Scene::Map to build, render and tick) --------

module RGSS
  Rect = Struct.new(:x, :y, :width, :height)

  # The real Profiler is a native mruby module (mruby-rgss/src/profiler.cxx),
  # so it does not exist under this CRuby host. Scene::Map#render and #update
  # time their phases through it, and the native implementation is itself a
  # plain yield when profiling is off -- so stubbing it as exactly that keeps
  # the measured code path identical here.
  module Profiler
    def self.section(_name)
      yield
    end
  end

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
    # The `"Dir/name"` a file-loading construction asked for, and whether it
    # asked for the colour-keyed (palette index 0 transparent) decode -- the
    # real Bitmap's own second argument. Recorded so a check can assert *how* a
    # graphic was loaded, not only that something was: an RPG2000 sprite sheet
    # loaded opaque draws its whole transparent background as solid pixels.
    # The real Bitmap overloads its second argument the same way: it is the
    # height for `Bitmap.new(w, h)` and the transparency flag for
    # `Bitmap.new("Dir/name", trans)` (mruby-rgss/src/lib.cxx, `bmp_init`'s
    # `"z|b"` vs the two-integer form), so it is read here as whichever the
    # first argument makes it.
    attr_reader :load_name, :load_transparent
    def initialize(w = 1, h = nil)
      if w.is_a?(String)
        @load_name = w
        @load_transparent = h ? true : false
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
    # The non-blending copy the map renderer moves its cached tile grid with
    # (see Bitmap#copy_blt in mruby-rgss/src/lib.cxx). Recorded apart from
    # #blt_calls so a check counting *tile* draws is not confused by the one
    # whole-grid copy per frame.
    def copy_blt(*a); (@copy_blt_calls ||= []) << a; end
    attr_reader :copy_blt_calls
    def clear_copy_blt_calls; @copy_blt_calls = []; end
    # Recorded so the picture layering check can assert *which order* sources
    # were composited in, not only that drawing happened.
    def stretch_blt(*a); (@stretch_calls ||= []) << a; end
    attr_reader :stretch_calls
    def clear_stretch_calls; @stretch_calls = []; end
    # Recorded so the Mosaic/Wave transition checks can assert the native
    # resample was reached with the right per-frame parameters, mirroring how
    # #stretch_calls covers zoom.
    def mosaic_blt(*a); (@mosaic_calls ||= []) << a; end
    attr_reader :mosaic_calls
    def clear_mosaic_calls; @mosaic_calls = []; end
    def wave_blt(*a); (@wave_calls ||= []) << a; end
    attr_reader :wave_calls
    def clear_wave_calls; @wave_calls = []; end
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
    # Records the hue(s) applied, mirroring the real RGSS::Bitmap#hue_change
    # (mruby-rgss/src/lib.cxx) contract: mutates this bitmap in place, no
    # return value asserted on. #battler_bitmap (mruby-rpg2k/mrblib/scene/
    # map.rb) calls this on a freshly decoded, not-yet-cached bitmap only, so
    # a nonempty log here is only ever this decode's own hue.
    def hue_change(h); (@hue_calls ||= []) << h; end
    attr_reader :hue_calls
    def dispose; end
  end

  # A readable colour (the real Color stub above swallows its args); get_pixel
  # returns one of these so tests can inspect the sampled components.
  Color2 = Struct.new(:red, :green, :blue, :alpha)

  # RGSS Tone, as tone_blt (the Flash Sprite pass) takes it.
  Tone = Struct.new(:red, :green, :blue, :gray)

  class Sprite
    attr_accessor :bitmap, :x, :y, :z, :visible, :opacity, :src_rect, :tone
    # Which viewport the sprite was built in, so the tone checks can assert that
    # the map layers share one and the overlays do not.
    attr_reader :viewport
    def initialize(viewport = nil, *); @viewport = viewport; end
    # Tracked (not just a no-op) so the mid-battle roster-sync rendering
    # checks can assert a departed actor's specific sprite was actually
    # disposed, and that a rejoin never hands back an already-disposed one.
    def dispose; @disposed = true; end
    def disposed?; !!@disposed; end
    # #flash/#update, as the target-scope Battle Animation flash
    # (Scene::Map#fire_target_flash/#update_enemy_flashes) uses them: mirrors
    # the real native contract (mruby-rgss/src/lib.cxx's spr_flash/spr_update)
    # closely enough for the wiring checks -- #flash records the colour/duration
    # requested, #update decays it by one frame and clears it once the
    # duration runs out, the same "fades over the duration, then gone" shape
    # the real Sprite gives a caller who drives it every frame.
    attr_reader :flash_color, :flash_calls
    def flash(color, duration)
      (@flash_calls ||= []) << [color, duration]
      @flash_color = color
      @flash_count = duration
    end
    def update
      return unless @flash_count && @flash_count > 0
      @flash_count -= 1
      @flash_color = nil if @flash_count == 0
    end
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
    CTRL = 8; F9 = 9; L = 10; R = 11
    # RPG2003 Key Input Processing's Numbers/Operators groups (see
    # Scene::Map::NUMBER_KEY_BUTTONS / OPERATOR_KEY_BUTTONS).
    N0 = 20; N1 = 21; N2 = 22; N3 = 23; N4 = 24
    N5 = 25; N6 = 26; N7 = 27; N8 = 28; N9 = 29
    PLUS = 30; MINUS = 31; MULTIPLY = 32; DIVIDE = 33; PERIOD = 34
    class << self
      attr_accessor :dir_value, :triggered, :repeated
    end
    def self.reset; @dir_value = 0; @triggered = []; @repeated = []; end
    def self.trigger?(k); Array(@triggered).include?(k); end
    # A genuinely independent signal from #trigger? -- a check can simulate a
    # key held across several frames via `Input.repeated = [...]` without it
    # also reading as a fresh #trigger? on that same frame, mirroring how the
    # real RGSS::Input (mruby-rgss/mrblib/lib.rb) keeps its own
    # @pressed/@count-driven @repeated array apart from @triggered. Used to be
    # a bare alias of #trigger?'s own `@triggered` set, which made it
    # impossible for a check to exercise the repeat-only branch a widget's own
    # `Input.trigger?(k) || Input.repeat?(k)` gate takes once a key has been
    # held long enough to auto-repeat.
    def self.repeat?(k); Array(@repeated).include?(k); end
    def self.press?(k); Array(@triggered).include?(k); end
    def self.dir4; @dir_value || 0; end
    def self.update; end
  end

  module Graphics
    def self.frame_rate; 60; end
    def self.update; end
    # A captured-transition check swaps this out for a Bitmap instance it can
    # inspect (or nil, to exercise the "backend cannot snapshot" fallback);
    # other checks never call it, since only a captured transition does.
    class << self; attr_accessor :snapshot; end
    def self.snap_to_bitmap; @snapshot; end
  end

  module Audio
    # Record bgm_play calls so BGM checks (the vehicle music, the Game Over
    # screen) can assert which track started.
    class << self; attr_accessor :bgm_calls; end
    def self.bgm_play(*a); (@bgm_calls ||= []) << a; end
    def self.reset_bgm
      @bgm_calls = []
      @bgm_volume_calls = []
      @bgm_pan_calls = []
      @bgm_fade_calls = []
      @me_calls = []
      @me_stop_calls = 0
    end
    # Recorded separately from bgm_calls: a same-file Play BGM re-trigger
    # calls this instead of bgm_play (see Game::Interpreter#play_audio /
    # Scene::Map#play_bgm), so the two checks stay distinguishable.
    class << self; attr_accessor :bgm_volume_calls; end
    def self.bgm_volume(v); (@bgm_volume_calls ||= []) << v; end
    # Recorded separately again: the balance/pan re-apply that now
    # accompanies every Play BGM command (see
    # Game::Interpreter#play_audio's :bgm branch).
    class << self; attr_accessor :bgm_pan_calls; end
    def self.bgm_pan(v); (@bgm_pan_calls ||= []) << v; end
    # Record bgm_fade calls (the fade-length ms) so a check can assert one
    # fired -- e.g. the End Game confirmation's Game_System::BgmFade(400).
    class << self; attr_accessor :bgm_fade_calls; end
    def self.bgm_fade(*a); (@bgm_fade_calls ||= []) << a; end
    def self.bgm_stop(*); end
    # Scriptable playback position, so the "BGM played once" watcher can be
    # driven: a value that jumps backwards is how SDL_mixer reports a loop.
    class << self; attr_accessor :pos; end
    def self.bgm_pos; @pos || 0; end
    # Record me_play/me_stop calls (the victory fanfare, #play_victory_bgm /
    # #restore_pre_battle_bgm) separately from bgm_calls -- the whole point of
    # the fix they cover is that the fanfare goes through the one-shot ME
    # channel rather than the ordinary looping BGM one, so a check needs to
    # tell the two apart.
    class << self; attr_accessor :me_calls, :me_stop_calls; end
    def self.me_play(*a); (@me_calls ||= []) << a; end
    def self.me_stop; @me_stop_calls = (@me_stop_calls || 0) + 1; end
    # Record se_play calls so system-SFX checks can assert which sound fired.
    class << self; attr_accessor :se_calls; end
    def self.se_play(*a); (@se_calls ||= []) << a; end
    def self.reset_se; @se_calls = []; end
  end

  # Zundamon message-window narration (Scene::Map#speak_message). available?
  # false is the real "no --zundamon_tts / no backend installed" state, so
  # this matches production with the flag off -- speak is never actually
  # called by the stub, but is recorded (and made callable) so a future check
  # can flip `available` on and assert what got spoken.
  module Tts
    class << self; attr_accessor :available, :speak_calls; end
    def self.available?; !!@available; end
    def self.speak(*a); (@speak_calls ||= []) << a; end
    def self.reset; @available = false; @speak_calls = []; end
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

# The fight's own live state (RPG2k::Scene::Battle#ui) is a plain hash again,
# same shape a check written against the old Scene::Map#@battle_ui already
# expects -- reached through the scene's own @battle (nil between
# encounters), so this is the one place a check has to know the fight moved
# out to its own scene object at all.
def battle_ui(scene)
  b = scene.instance_variable_get(:@battle)
  b && b.ui
end

# Fabricate a running fight directly, the way a handful of checks below poke
# @battle_ui without ever driving a real encounter open (a parallel-process
# pause check, the F9-during-battle checks, ...). Bypasses Scene::Battle#start
# entirely -- `ui` only needs to carry whatever keys the check itself reads.
def fake_battle(scene, ui)
  battle = RPG2k::Scene::Battle.allocate
  battle.instance_variable_set(:@map, scene)
  battle.instance_variable_set(:@ui, ui)
  scene.instance_variable_set(:@battle, battle)
  battle
end

# Runs the block with $stderr redirected to a StringIO and returns everything
# written to it, for checks that assert on a "[RPG2k] ..." diagnostic line.
def capture_stderr
  old_stderr = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old_stderr
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
            airship_land: true, airship_pass: true, boat_pass: false, ship_pass: false,
            rpg2003: false, menu_commands: nil, footstep: '', on_damage_se: false,
            battleranimations: nil, battlecommands: nil)
  OpenStruct.new(
    rpg2003?: rpg2003,
    system: OpenStruct.new(system_graphic: '', title: 'TitleGraphic',
                           menu_commands: menu_commands,
                           battle_music: OpenStruct.new(file: 'BattleBGM', volume: 70, pitch: 110),
                           inn_music: OpenStruct.new(file: 'InnBGM', volume: 75, pitch: 105),
                           boat_music: OpenStruct.new(file: 'BoatBGM', volume: 80, pitch: 100),
                           ship_music: OpenStruct.new(file: 'ShipBGM', volume: 80, pitch: 100),
                           airship_music: OpenStruct.new(file: 'AirBGM', volume: 80, pitch: 100),
                           cursor_se: OpenStruct.new(file: 'Cursor1', volume: 100, pitch: 100),
                           decision_se: OpenStruct.new(file: 'Decision1', volume: 100, pitch: 100),
                           cancel_se: OpenStruct.new(file: 'Cancel1', volume: 100, pitch: 100),
                           buzzer_se: OpenStruct.new(file: 'Buzzer1', volume: 100, pitch: 100),
                           escape_se: OpenStruct.new(file: 'Escape1', volume: 100, pitch: 100),
                           battle_se: OpenStruct.new(file: 'BattleStart1', volume: 100, pitch: 100),
                           # The battle per-hit sounds (Scene::Base::DB_SE_FIELD).
                           enemy_attack_se: OpenStruct.new(file: 'EnemyAttack', volume: 100, pitch: 100),
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
                         actor_critical: '痛恨の一撃！！', enemy_critical: '会心の一撃！！',
                         skill_failure_a: 'には効かなかった！',
                         skill_failure_b: 'は平気だった！',
                         skill_failure_c: 'は眠らなかった！',
                         use_item: 'を使った！', hp_recovery: '回復した！',
                         hp: 'ＨＰ', mp: 'ＭＰ',
                         enemy_hp_absorbed: '奪った！',
                         actor_hp_absorbed: '奪われた！',
                         # An affect_attack/defense/spirit/agility skill's stat-mod
                         # message and an affect_attr_defence skill's resistance-shift
                         # message (EasyRPG's GetParameterChangeMessage /
                         # GetAttributeShiftMessage) -- see #battle_state_lines.
                         parameter_increase: '上がった！', parameter_decrease: '下がった！',
                         resistance_increase: '耐性が上がった！',
                         resistance_decrease: '耐性が下がった！',
                         attack: '攻撃力', defense: '防御力', mind: '精神力',
                         agility: '敏捷性'),
    # The Attribute (elemental) table a resistance-shift skill's `attribute_effects`
    # names, read by #battle_state_lines for the shifted attribute's own name.
    property: { 1 => OpenStruct.new(name: '火') },
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
                 # `restriction: 1` (do-nothing) + a nonzero auto_release_prob mirrors
                 # RPG2000's own Sleep row -- a state that skips the afflicted
                 # battler's turn entirely but can still wear off on its own, unlike
                 # the always-comatose Stone row the battle-command-skip checks use.
                 4 => OpenStruct.new(name: 'Sleep', color: 4, priority: 80,
                                     restriction: 1, auto_release_prob: 50),
                 # Do-nothing with 0% auto-release: never wears off on its own -- the
                 # "everyone permanently incapacitated" battle-command-skip check
                 # uses this one instead of Sleep so the round has no chance of
                 # waking anyone back up mid-test.
                 6 => OpenStruct.new(name: 'Stone', color: 8, priority: 90,
                                     restriction: 1, auto_release_prob: 0),
                 5 => OpenStruct.new(name: 'Silence', color: 5, priority: 10),
                 # RPG2003's `hp_change_type` GAIN counterpart to Poison above:
                 # the same map-step interval/amount fields, but healing --
                 # exercises the flash-suppression half of
                 # Game::Party#map_step_damaged?.
                 7 => OpenStruct.new(name: 'Regen', color: 3, priority: 20,
                                     hp_change_map_steps: 4, hp_change_map_val: 1,
                                     hp_change_type: 1) },
    # A tiny item table the Open Shop window prices its goods from.
    item: { 3 => OpenStruct.new(name: 'Potion', price: 100),
            5 => OpenStruct.new(name: 'Herb', price: 40) },
    # An enemy and a troop of two, for the placeholder Enemy Encounter victory.
    # Enemy 3 (Bat) carries the "airborne" flag (field 28, `levitate`) for the
    # RPG2003 flying-offset checks; its own troop (group 2) is a lone member
    # so those checks never disturb enemy_group 1's two-Slime assertions.
    enemy: { 2 => OpenStruct.new(name: 'Slime', battler_name: 'Slime',
                                 max_hp: 30, max_sp: 0, attack: 8,
                                 defense: 4, spirit: 3, agility: 5, exp: 5,
                                 gold: 10),
             3 => OpenStruct.new(name: 'Bat', battler_name: 'Bat',
                                 max_hp: 20, max_sp: 0, attack: 6,
                                 defense: 2, spirit: 2, agility: 8, exp: 4,
                                 gold: 8, levitate: true),
             # "Appear Transparent" (field 10) fixture for the enemy-opacity
             # checks; its own lone-member troop (group 3) keeps it from
             # disturbing the two-Slime/lone-Bat troops' own assertions.
             4 => OpenStruct.new(name: 'Ghost', battler_name: 'Ghost',
                                 max_hp: 15, max_sp: 0, attack: 5,
                                 defense: 2, spirit: 2, agility: 6, exp: 3,
                                 gold: 6, transparent: true),
             # Battle-graphic hue shift (field 3, `Game::Enemy#battler_hue`)
             # fixture: reuses Slime's own "Slime" battler file with a
             # nonzero hue, the way a real game palette-swaps one monster
             # bitmap into several -- its own lone-member troop (group 4)
             # keeps it from disturbing the two-Slime troop's own
             # (un-hue-shifted) battler-cache assertions.
             5 => OpenStruct.new(name: 'Red Slime', battler_name: 'Slime',
                                 max_hp: 30, max_sp: 0, attack: 8,
                                 defense: 4, spirit: 3, agility: 5, exp: 5,
                                 gold: 10, battler_hue: 120) },
    enemy_group: { 1 => OpenStruct.new(name: 'Slimes', members: {
      1 => OpenStruct.new(enemy_id: 2, x: 100, y: 80, invisible: false),
      2 => OpenStruct.new(enemy_id: 2, x: 200, y: 80, invisible: false) },
      pages: troop_pages),
      2 => OpenStruct.new(name: 'Bats', members: {
        1 => OpenStruct.new(enemy_id: 3, x: 100, y: 80, invisible: false) },
        pages: nil),
      3 => OpenStruct.new(name: 'Ghosts', members: {
        1 => OpenStruct.new(enemy_id: 4, x: 100, y: 80, invisible: false) },
        pages: nil),
      4 => OpenStruct.new(name: 'Red Slimes', members: {
        1 => OpenStruct.new(enemy_id: 5, x: 100, y: 80, invisible: false) },
        pages: nil) },
    # A drawable battle animation (id 8): four frames, with a screen flash timing
    # on frame 1. (Id 7 is intentionally absent so that test exercises the
    # 0-frame invalid-id wait, see #missing_animation_wait.)
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
    ),
    # A second drawable animation (id 9), identical to id 8's frames but with a
    # flash_scope 1 ("target") timing instead of a screen flash -- for the
    # map-triggered target-flash checks below.
    9 => OpenStruct.new(
      animation_name: 'Anim', position: 1,
      frames: {
        1 => OpenStruct.new(cells: { 1 => OpenStruct.new(visible: true, cell_id: 0, x: 0, y: 0) }),
        2 => OpenStruct.new(cells: { 1 => OpenStruct.new(visible: true, cell_id: 1, x: 0, y: 0) }),
        3 => OpenStruct.new(cells: {}),
        4 => OpenStruct.new(cells: {})
      },
      timings: { 1 => OpenStruct.new(frame: 1, flash_scope: 1, flash_red: 31,
                                     flash_green: 0, flash_blue: 0, flash_power: 20) }
    ),
    # A third animation (id 10): real frame data (12 frames, a long real
    # duration at 2 ticks/frame) under its own animation_name so a test can
    # poison just its own @animation_cache entry (simulating an unloadable
    # Battle/<name> sheet) without affecting id 8/9's shared 'Anim' cache
    # entry. Exercises #missing_animation_wait's "real frame data, sheet
    # failed to load" branch -- a real duration, not the invalid-id 0-wait.
    10 => OpenStruct.new(
      animation_name: 'GhostAnim', position: 1,
      frames: (1..12).each_with_object({}) { |n, h| h[n] = OpenStruct.new(cells: {}) },
      timings: {}
    ) },
    # Every tile of the synthetic map is chip 0, which the fake chipset tags as
    # terrain 42 — so this one row decides whether walking hurts, and (for the
    # airship checks) whether it may fly over / land on any tile.
    terrain: { 42 => OpenStruct.new(damage: terrain_damage, bush_depth: bush_depth,
                                    airship_land: airship_land, airship_pass: airship_pass,
                                    boat_pass: boat_pass, ship_pass: ship_pass,
                                    footstep: footstep, on_damage_se: on_damage_se) },
    common_event: common,
    # Database actor rows carry the *original* names, which a \N[n] must not
    # use once the actor has been renamed in play (see the \N[n] check).
    player: { 1 => OpenStruct.new(name: 'DbHero'),
              2 => OpenStruct.new(name: 'DbAlly'),
              3 => OpenStruct.new(name: 'DbStranger') },
    # RPG2003's Battler Animation table (chunk 32, db.battleranimations) --
    # nil (the default, an RPG2000 database never carries chunk 32) unless a
    # check passes its own id => entry hash (#battle_pose, #battle_pose_set
    # below build the shape #build_actor_sprite reads).
    battleranimations: battleranimations,
    # RPG2003's Battle Commands table (chunk 0x1D, db.battlecommands) -- nil
    # (the default, an RPG2000 database never carries it) unless a check passes
    # its own table, e.g. `OpenStruct.new(battle_type: 2, placement: 1)` for a
    # gauge-presentation fight. Scene::Battle#start reads
    # `db.battlecommands.battle_type` off it to seed the fight's timing, and
    # `battle_scene_class(db)` routes the fight to RPG2k3::Scene::Battle on
    # `db.rpg2003?` -- so the two must agree in a gauge check.
    battlecommands: battlecommands
  )
end

# A `db.battleranimations[id]` entry: a name, plus a poses hash keyed by
# Pose id (0 idle, matching schema.rb's own comment on chunk 32) -- pass
# `poses: { 0 => battle_pose(...) }` for the common one-pose case.
def battle_pose_set(name: 'Fighter', poses: {})
  OpenStruct.new(name: name, speed: 20, poses: poses)
end

# A single `poses[id]` row: `animation_type` 0 is a BattleCharSet sheet
# (`battler_name`/`battler_index` frame it), 1 a Battle/<name> (CBA)
# animation sequence (#build_actor_sprite does not implement this format --
# see the diagnostic check below).
def battle_pose(name: 'Idle', battler_name: 'Hero', battler_index: 0,
                animation_type: 0, battle_animation_id: 1)
  OpenStruct.new(name: name, battler_name: battler_name, battler_index: battler_index,
                animation_type: animation_type, battle_animation_id: battle_animation_id)
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

# Gate an auto-start page so it fires at most once per map visit. The scene's
# Scene::Map#start_autostart skips it on later frames once it has run, without
# deactivating the page (which would otherwise trigger an event-page rebuild
# that wipes an unrelated event's in-flight forced route -- see the 5 map-event
# Move Event checks this used to break). This mirrors how a real auto-start
# guards itself so it does not re-fire every frame under the per-frame
# auto-start re-trigger (Scene::Map#update clears @started_auto each frame), but
# avoids the rebuild a page-condition gate would cause. The flag is this
# harness's own: no RPG2000/2003 page has a `guarded` field, so Scene::Map reads
# it `respond_to?`-guarded (#page_guarded) and every auto-start on real game
# data is unguarded. The `var_id` argument is accepted for call-site
# compatibility but unused.
def one_shot_auto(page, _var_id = nil)
  page.guarded = true
  page
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
  # Mirrors RPG2k::Game#test_play (see mruby-rpg2k/mrblib/main.rb). Writable
  # so a check can exercise the Test-Play-only behaviour it gates (the hero's
  # missing-graphic debug marker; Ctrl/Shift/F9's debug behaviour); every
  # other check wants the same default (false) a plainly-launched game gets.
  attr_accessor :test_play
  def initialize(db, &map_maker)
    @db = db
    @map_tree = nil
    @test_play = false
    @map_maker = map_maker
    @pushed = []
  end

  def load_map(id); @map_maker.call(id); end
  # Scene::Map#try_open_menu pushes a Scene::Menu; record it instead.
  def push(scene); @pushed << scene; end
  # Scene::SaveLoad (and every field submenu) pops itself on cancel / once its
  # save confirmation banner is dismissed; count the calls rather than
  # modelling a real scene stack here.
  attr_reader :pop_called
  def pop; @pop_called = (pop_called || 0) + 1; end
  # An Escape / Teleport field skill closes the whole menu stack at once;
  # record that it fired rather than modelling a real scene stack here.
  attr_reader :pop_to_map_called
  def pop_to_map; @pop_to_map_called = true; end
  # Return to Title Screen (12510) hands control back here; record that it fired.
  attr_reader :returned_to_title
  def return_to_title; @returned_to_title = true; end
  # Game Over (12420) and a game-over battle defeat put up Scene::GameOver,
  # which returns to the title once dismissed. Record that it was reached
  # along with whatever Game::State it was handed (nil from a bare fixture
  # test that never sets one up).
  attr_reader :game_over_shown, :game_over_state
  def show_game_over(state = nil)
    @game_over_shown = true
    @game_over_state = state
  end
  # Open Save Menu (11910) saves through the app; record the calls. Also what
  # Scene::SaveLoad calls (with an explicit slot) once a :save confirm picks
  # one -- `save_ok` lets a check force a failed save without faking a broken
  # state.
  attr_accessor :save_ok
  def saved; @saved ||= []; end
  def save_game(state, slot = 1)
    saved << [state, slot]
    @save_ok.nil? ? true : @save_ok
  end
  # Scene::SaveLoad reads one of these per slot to build its file-select list
  # (RPG2k#load_save_state); a check sets `save_states[slot]` to a
  # Game::State to have that row show as occupied, or leaves a slot unset for
  # "no data" (the default -- most checks want an all-empty list to start
  # from).
  def save_states; @save_states ||= {}; end
  def load_save_state(slot = 1); save_states[slot]; end
  # Scene::SaveLoad's :load mode resumes a confirmed occupied slot through
  # this; record which slots were asked for.
  def continue_calls; @continue_calls ||= []; end
  def continue_game(slot = 1); continue_calls << slot; end
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

def fake_party(members = [], rpg2003: false)
  # A real Game::Party rather than a stand-in: Scene::Map runs the party through
  # Party#apply_map_step_damage on every walked tile, so the fixture has to
  # answer the real interface. It starts empty -- `system.party` is [] and the
  # movement / event checks have no members to care about -- and takes any it
  # needs from the caller. This db is deliberately its own bare OpenStruct, not
  # the scene's own `fake_db` (built separately by `new_scene`) -- so
  # `enemy_group` defaults to "every id exists" (Hash.new(true)), the same
  # permissive default the other stub parties in this file use, since these
  # movement/event checks are not exercising the missing-troop-id diagnostic
  # path (covered in scripts/rpg2k_logic_check.rb instead). `rpg2003:` mirrors
  # Game::Party#rpg2003? (`@db.rpg2003?`) for checks that need the RPG2003
  # branch of a command's parameter decoding (e.g. Key Input Processing's
  # Numbers/Operators layout).
  party = Game::Party.new(OpenStruct.new(system: OpenStruct.new(party: []),
                                          enemy_group: Hash.new(true),
                                          rpg2003?: rpg2003))
  members.each { |m| party.actors << m }
  party
end

def new_scene(events, player: [0, 0], common: nil, parallax: nil, troop_pages: nil,
              members: [], terrain_damage: 0, bush_depth: 0,
              airship_land: true, airship_pass: true, boat_pass: false, ship_pass: false,
              map_tree: nil, test_play: false, rpg2003: false,
              footstep: '', on_damage_se: false, battleranimations: nil,
              battlecommands: nil)
  db = fake_db(common, troop_pages, terrain_damage, bush_depth,
               airship_land: airship_land, airship_pass: airship_pass,
               boat_pass: boat_pass, ship_pass: ship_pass, rpg2003: rpg2003,
               footstep: footstep, on_damage_se: on_damage_se,
               battleranimations: battleranimations, battlecommands: battlecommands)
  state = Game::State.new(fake_party(members, rpg2003: rpg2003), 1, player[0], player[1])
  state.map = fake_map(1, events, parallax: parallax)
  parent = fake_parent(db)
  parent.map_tree = map_tree if map_tree
  parent.test_play = test_play
  RPG2k::Scene::Map.new(parent, state)
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
  eq 16, heights.max, "RPG_RT's arc peaks at exactly 16px on a 16px tile, never past it"
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
# The subset of MAP_LAYER_IVARS the map's own tone must actually reach --
# @animation_sprite is deliberately excluded: it sits at its own z between
# @player_sprite and @upper_sprite (so the order test above still holds), but
# it is Show Battle Animation's shared renderer, and yado.tk documents battle
# animations as tone-exempt just like a picture -- it lives outside both
# @map_viewport and @upper_viewport for exactly this reason (see
# Scene::Map#setup_sprites).
MAP_TONED_IVARS = (MAP_LAYER_IVARS - %i[@animation_sprite]).freeze
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

  # A previously "still open" question, now settled directly rather than only
  # transitively through the two checks above: a map's Show Battle Animation
  # (@animation_sprite) must draw *under* the picture layer, not over it.
  # EasyRPG Player's own Priority enum (src/drawable.h) puts
  # Priority_PictureOld (120) above Priority_BattleAnimation (110) for every
  # standard RPG2000/RPG2003 database -- see the citation next to
  # @animation_sprite.z in Scene::Map#setup_sprites.
  ok sprite_z(scene, :@animation_sprite) < sprite_z(scene, :@picture_sprite),
     'a map animation draws under the picture layer, not over it'

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

# An event whose page 2 is gated on Timer1 having counted down to
# `timer_sec` seconds or below (flags bit 0x20 -- see Game::EventPage::TIMER).
def timer_gated_event(x, y, timer_sec, page1, page2)
  page2.condition = OpenStruct.new(flags: Game::EventPage::TIMER, timer_sec: timer_sec)
  OpenStruct.new(x: x, y: y, pages: { 1 => page1, 2 => page2 })
end

check "Timer1 counting down past a page's threshold re-selects it mid-map" do
  # Page 1 (trigger 0) is active above 5 s left; page 2 (trigger 4) takes over
  # once Timer1 reads 5 s or below.
  p1 = page(trigger: 0, charset_name: 'Villager')
  p2 = page(trigger: 4, charset_name: 'Ghost')
  scene = new_scene({ 1 => timer_gated_event(2, 2, 5, p1, p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.timer(0).set(7) # 7 s left -- above the 5 s threshold
  st.timer(0).start(false)

  scene.update
  ev = event_hashes(scene)[1]
  eq 0, ev[:trigger], 'still above the threshold: page 1 stays active'

  130.times { scene.update } # ticks Timer1 down from 7 s to 5 s (< 60*2 frames)
  ev = event_hashes(scene)[1]
  eq 4, ev[:trigger], 'Timer1 counted down to the threshold: page 2 takes over'
  eq 5, st.timer_seconds
end

check "an unrelated event's page change does not reset another event's " \
      'Through Mode / Direction Fix / Stop Animation / Transparency' do
  # Event 1 (the bystander) never changes page; event 2 is the one gated on
  # switch 3. #pages_changed? is a map-wide check, so flipping the switch
  # rebuilds *every* event's Game::Character, event 1's included, even though
  # event 1's own page selection never moves. These four fields are only ever
  # set by a Move Route sub-command (Through Mode / Direction Fix / Stop
  # Animation / Transparency Up-Down) -- a page never assigns them -- so a
  # fresh Game::Character always starts back at their defaults; carrying
  # position across the rebuild but not these would silently wipe them.
  bystander = page(trigger: 0, charset_name: 'Bystander')
  p1 = page(trigger: 0, charset_name: 'Villager')
  p2 = page(trigger: 4, charset_name: 'Ghost')
  scene = new_scene({ 1 => event(1, 1, bystander),
                      2 => two_page_event(2, 2, 3, p1, p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update

  ch = event_hashes(scene)[1][:char]
  ch.through = true
  ch.facing_locked = true
  ch.animation_stopped = true
  ch.transparency = 5

  st.switches[3] = true # only event 2's page condition is gated on this
  5.times { scene.update }

  ev2 = event_hashes(scene)[2]
  eq 4, ev2[:trigger], "event 2's page did flip (switch 3 went on)"

  ch = event_hashes(scene)[1][:char]
  ok ch.through, "event 1's Through Mode survived event 2's page rebuild"
  ok ch.facing_locked, "event 1's Direction Fix survived it too"
  ok ch.animation_stopped, 'as did Stop Animation'
  eq 5, ch.transparency, 'and Transparency Up/Down'
end

check "an unrelated event's page change does not reset another event's Move " \
      "Route Change Graphic override, but the event's own page change still wins" do
  # Event 1 is the bystander (own page never changes) and carries a Move
  # Route Change Graphic override, poked directly onto its Character the same
  # way the Through Mode check above pokes its four flags -- equivalent to
  # what a Set Move Route Change Graphic sub-command applies via
  # Character#set_graphic. Event 2 flips to a page gated on switch 3, the
  # same map-wide #pages_changed? trigger that rebuilds every event's
  # Character. Event 3 *also* changes its own page (same switch) to one with
  # a different base charset and carries no override of its own: that page's
  # own new graphic must still win outright, since #build_event always
  # derives graphic_name/graphic_index fresh from whichever page is selected
  # -- unlike Through Mode et al., a page *does* set this field, so only a
  # bystander whose own page selection did not move gets its override carried
  # forward.
  bystander = page(trigger: 0, charset_name: 'Bystander')
  p1 = page(trigger: 0, charset_name: 'Villager')
  p2 = page(trigger: 4, charset_name: 'Ghost')
  own_p1 = page(trigger: 0, charset_name: 'OwnBefore')
  own_p2 = page(trigger: 0, charset_name: 'OwnAfter')
  scene = new_scene({ 1 => event(1, 1, bystander),
                      2 => two_page_event(2, 2, 3, p1, p2),
                      3 => two_page_event(3, 3, 3, own_p1, own_p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update

  event_hashes(scene)[1][:char].set_graphic('Override', 4)

  st.switches[3] = true # flips event 2's own page and event 3's own page alike
  5.times { scene.update }

  ev2 = event_hashes(scene)[2]
  eq 4, ev2[:trigger], "event 2's page did flip (switch 3 went on)"

  ch1 = event_hashes(scene)[1][:char]
  eq 'Override', ch1.graphic_name,
     "event 1's Move Route Change Graphic override survived event 2's page rebuild"
  eq 4, ch1.graphic_index

  ch3 = event_hashes(scene)[3][:char]
  eq 'OwnAfter', ch3.graphic_name,
     "event 3's own page change still wins over whatever it was drawing before"
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

check "a fixed-direction event's own explicit Face Direction sub-command still " \
      'turns its drawn sprite, even though ordinary movement never does' do
  # yado.tk: "Face Direction always overrides Fixed Direction/Animation Type" --
  # verified against EasyRPG Player's actual C++ source (see the pure-logic
  # checks in scripts/rpg2k_logic_check.rb for the exact citations). This is the
  # full-stack version: Scene::Map#build_event now wires a page's own
  # Game::EventGraphic.fixed_direction? into Character#fixed_facing, and
  # Game::EventGraphic.frame reads the character's own live facing instead of
  # hardcoding the page's base_dir for every fixed-direction anim_type.
  pg = page(x_move_type: Game::MoveType::CUSTOM, direction: 2, # south
            animation_type: Game::EventGraphic::FIXED_NON_CONTINUOUS,
            route: move_route([R::MOVE_RIGHT, R::FACE_UP], repeat: false))
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [5, 4])
  frame_of = lambda do
    e = event_hashes(scene)[1]
    Game::EventGraphic.frame(e[:anim_type], e[:base_dir], e[:base_pattern],
                              e[:char].direction, e[:anim_phase], e[:moving])
  end

  # Move Right fires once move_timer (EVENT_MOVE_DELAY[frequency 6] == 6)
  # elapses; Face Up fires 6 frames after that.
  8.times { scene.update }
  ok event_hashes(scene)[1][:char].x > 2, 'the Move Right step landed first'
  ok !event_hashes(scene)[1][:route].done?, "Face Up hasn't run yet"
  dir, = frame_of.call
  eq 2, dir, "ordinary movement never turns a fixed-direction event's sprite"

  10.times { scene.update }
  ok event_hashes(scene)[1][:route].done?, 'the Face Up step ran too'
  dir, = frame_of.call
  eq 8, dir, 'an explicit Face Direction sub-command still turns it, though'
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
  # Two events collide whenever their layers match exactly (see the LAYER_*
  # comment in map.rb) -- #page's own default (LAYER_BELOW for both) already
  # satisfies that, so no explicit layer is needed here.
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
  # route straight through its column. #char_passable? gates layer on an
  # *exact* match between the mover's own layer and the blocker's
  # (matching EasyRPG Player's `WouldCollide`, `src/game_map.cpp`:
  # `self.GetLayer() == other.GetLayer()`), so a below-layer blocker never
  # stops an above-layer mover -- the layers simply don't match.
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

check 'a below-layer mover passes through a same-layer event via Move Route' do
  # The flip side of the check above: #char_passable?'s layer gate is an
  # exact match on both sides (`self.GetLayer() == other.GetLayer()`, see
  # its comment) -- not "the blocker is LAYER_SAME" alone -- so a
  # below-layer mover crosses a same-layer blocker's tile freely, the
  # layers not matching, the same way it crosses an above-layer one.
  blocker = event(3, 2, page(layer: RPG2k::Scene::Map::LAYER_SAME))
  mover = event(1, 2, page(x_move_type: Game::MoveType::CUSTOM,
                           route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false),
                           layer: RPG2k::Scene::Map::LAYER_BELOW))
  scene = new_scene({ 1 => blocker, 2 => mover }, player: [0, 0])
  ch = chars(scene)[2]
  40.times { scene.update }
  eq [3, 2], [ch.x, ch.y],
     "a below-layer mover should cross a same-layer event, got #{[ch.x, ch.y]}"
end

check 'two below-layer events collide with each other via Move Route' do
  # Both sides share LAYER_BELOW, an exact match, so #char_passable?'s
  # layer gate fires the same way it would for two same-layer events --
  # "only LAYER_SAME is ever solid" describes the hero specifically (whose
  # own layer is always effectively LAYER_SAME), not the general
  # event-vs-event rule, which is an exact match on whatever layer either
  # side happens to carry (see the comment on #char_passable?).
  below = event(3, 2, page(layer: RPG2k::Scene::Map::LAYER_BELOW))
  mover = event(1, 2, page(x_move_type: Game::MoveType::CUSTOM,
                           route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false),
                           layer: RPG2k::Scene::Map::LAYER_BELOW))
  scene = new_scene({ 1 => below, 2 => mover }, player: [0, 0])
  ch = chars(scene)[2]
  40.times { scene.update }
  eq [2, 2], [ch.x, ch.y],
     "two below-layer events should still collide with each other, got #{[ch.x, ch.y]}"
end

check 'overlap_forbidden does not block the hero on an ordinary step' do
  # The "doesn't overlap" page flag (LCF field 35) only ever fires between
  # two map events in real RPG_RT (`WouldCollide`, `src/game_map.cpp`:
  # `self.GetType() == Event && other.GetType() == Event && (self.
  # IsOverlapForbidden() || other.IsOverlapForbidden())`) -- the party's own
  # GetType() is Player, never Event, so the flag can never be what blocks
  # the hero, regardless of the mismatched layer. See the check below for
  # confirmation it still blocks a same-layer *event*.
  pg = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW, overlap_forbidden: true)
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6 # hold right, toward the event at (1,0)
  12.times { scene.update }
  RGSS::Input.dir_value = 0
  ok st.x >= 1, "overlap_forbidden should not stop the hero, stuck at x=#{st.x}"
end

check 'overlap_forbidden does not stop a below-layer event from walking onto the hero' do
  # The mirror image of the check above, on #char_passable?'s own
  # "stepping onto the hero's tile" branch: a below-layer mover with
  # overlap_forbidden set still walks straight onto/through the party, the
  # same as if the flag were not set at all -- overlap_forbidden and the
  # hero's Player type are mutually exclusive in real RPG_RT, whichever
  # side of the collision the party is on.
  mover = event(0, 2, page(x_move_type: Game::MoveType::CUSTOM,
                           route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false),
                           layer: RPG2k::Scene::Map::LAYER_BELOW, overlap_forbidden: true))
  scene = new_scene({ 1 => mover }, player: [2, 2])
  ch = chars(scene)[1]
  40.times { scene.update }
  eq [2, 2], [ch.x, ch.y],
     "a below-layer overlap_forbidden mover should cross the hero's own tile, got #{[ch.x, ch.y]}"
end

check 'overlap_forbidden does not block the hero while under a forced Set Move Route' do
  # The check above drives the hero through ordinary input, which always
  # goes through #passable? and always honours overlap_forbidden. A Set
  # Move Route targeting the player instead drives `@player_char` through
  # #char_passable?, which exempts the hero specifically from
  # overlap_forbidden gating (see #char_passable?'s comment) -- so the same
  # blocker that stops ordinary walking does not stop a forced route.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # auto-start: force the player right, twice
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT,
                                  [RPG2k::Scene::Map::MOVE_TARGET_PLAYER, 8, 0, 1,
                                   R::MOVE_RIGHT, R::MOVE_RIGHT])]
  one_shot_auto(auto, 9002)
  blocker = page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW, overlap_forbidden: true)
  scene = new_scene({ 1 => event(5, 5, auto), 2 => event(1, 0, blocker) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  30.times { scene.update }
  eq [2, 0], [st.x, st.y],
     "the forced route should have crossed the overlap_forbidden blocker, got #{[st.x, st.y]}"
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

check 'a same-layer blocker stacked under a below-layer decal still blocks the hero' do
  # Two events can legitimately share a tile in RPG2000 when their priority
  # types differ -- a below-characters decal drawn under a same-as-characters
  # NPC, say. Collision used to cache only one event per tile (last write
  # wins), so whichever of the two got indexed last silently decided the
  # whole tile's blocking answer; here that used to be the decal (layer
  # BELOW, id 2), which masked the NPC (layer SAME, id 1) underneath it and
  # let the hero walk straight through. #blockers_at now asks every event on
  # the tile, so the same-layer one still blocks regardless of build order.
  blocker = event(1, 0, page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_SAME))
  decal   = event(1, 0, page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW))
  scene = new_scene({ 1 => blocker, 2 => decal }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6 # hold right, toward the shared tile at (1, 0)
  12.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 0], [st.x, st.y],
     "the same-layer event should still block despite the stacked decal, got #{[st.x, st.y]}"
end

check 'a below-layer event moving off a shared tile leaves the same-layer event still blocking' do
  # The same stacked start as above, but the below-layer half of the pair now
  # wanders away on a custom route. Its own #reoccupy used to overwrite the
  # single-event cache with itself, dropping the stationary same-layer event
  # from the tile it never left; deindex/index now keep both companions'
  # entries in @event_tiles_by_pos independent, so the stationary one keeps
  # blocking after the other one moves off.
  blocker = event(2, 0, page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_SAME))
  mover   = event(2, 0, page(x_move_type: Game::MoveType::CUSTOM,
                             route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false),
                             layer: RPG2k::Scene::Map::LAYER_BELOW))
  scene = new_scene({ 1 => blocker, 2 => mover }, player: [1, 0])
  st = scene.instance_variable_get(:@state)
  40.times { scene.update } # let the below-layer event finish wandering off
  RGSS::Input.dir_value = 6 # hold right, toward the blocker at (2, 0)
  30.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [1, 0], [st.x, st.y],
     "the hero should still be blocked by the same-layer event, got #{[st.x, st.y]}"
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

# A map every tile of which disallows departure in every direction (chip
# index 0, with no direction bits set) -- ordinary movement goes nowhere no
# matter which way the player tries to walk, so only Through Mode gets
# anywhere. Takes an events hash the same way new_scene does, since the
# Through Mode checks below need an event to issue the forced route.
def walled_in_scene(events, player)
  db = fake_db
  data = Array.new(162, 0) # chip index 0: every direction closed
  db.chipset = { 1 => OpenStruct.new(name: 'walls', chipset_name: 'walls',
                                     passable_data_lower: data,
                                     passable_data_upper: nil, terrain_data: nil) }
  state = Game::State.new(fake_party, 1, player[0], player[1])
  state.map = fake_map(1, events) # fake_map's lower layer is already chip 0 throughout
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

check 'event-touch (trigger 2): a custom-route event stepping into the ' \
      'player runs it too, not just an autonomous Approach move' do
  # docs/TODO.md, "Running a hero-targeted Parallel-Process Set Move Route...
  # can suppress that event's touch trigger" -- the real, broader gap this
  # surfaced: a Set Move Route / page-authored custom route (Game::MoveRoute,
  # driven through Game::MoveRoute#do_move) never fired Event Touch at all
  # when it stepped a map event onto the party's tile, unlike an autonomous
  # Random/Approach/Away-type move (#move_autonomous's own dedicated check,
  # already covered by the check just above). Verified against EasyRPG
  # Player's actual C++ source: `Game_Character::Move`'s
  # `CheckCollisonOnMoveFailure` starts a Trigger_collision page the same way
  # regardless of whether a move route is driving the character, with no
  # `IsMoveRouteOverwritten`-style guard the way the *player's* own touch
  # check has.
  ic = Game::Interpreter::Cmd
  # layer 1 (LAYER_SAME): a below-characters event walks straight through the
  # party (a separate, already-correct rule -- see #char_passable?), so this
  # needs the ordinary same-layer NPC priority to actually collide at all.
  pg = page(x_move_type: Game::MoveType::CUSTOM, trigger: 2, layer: 1,
           route: move_route([R::MOVE_RIGHT], repeat: false))
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])]
  scene = new_scene({ 1 => event(0, 0, pg) }, player: [1, 0])
  ch = chars(scene)[1]
  20.times { scene.update }
  st = scene.instance_variable_get(:@state)
  ok st.switches[5], "a custom-route event's own Event Touch trigger ran"
  eq [0, 0], [ch.x, ch.y], 'the event stayed put, it did not step onto the player'
end

# docs/TODO.md, "Map Event" bullet, case (c): the party and an event trading
# tiles in one step -- the event's target this frame is the party's *current*
# tile while the party's own target this frame is the event's *current*
# tile, both mid-move toward each other rather than one walking onto an
# already-stationary other (that's case (b), the two tests just above). Real
# RPG_RT invalidates the hit-test for this configuration entirely (no trigger
# fires either way), but this codebase's frame order (#step_events, which
# decides the event's move and so its case-(b) hero-tile refusal, always
# runs before #step_movement, which decides and applies the party's own move
# for the same frame) used to see only the event's *stale, pre-move* refusal
# and the party's own subsequent walk onto that same tile -- collapsing a
# genuine crossing into an ordinary "party walks onto a stationary touch
# event" outcome. Fixed via Scene::Map#player_intended_target, snapshotted
# before #step_events runs each frame precisely so #move_autonomous /
# Game::MoveRoute#do_move's hero-tile refusal can recognise this same-frame
# configuration and flag it (e[:crossed_hero_this_frame]) for
# #step_movement's own #event_at check to consult.
check 'hero and event crossing paths (case (c)): trading tiles suppresses ' \
      'Hero Touch' do
  ic = Game::Interpreter::Cmd
  # Same-layer, so the party is actually blocked from stepping onto the
  # event's tile once the touch check itself is (correctly) suppressed --
  # otherwise a below-characters event's tile is walkable anyway and the
  # blocked-vs-not distinction this check wants would not show up.
  pg = page(x_move_type: Game::MoveType::TOWARD, trigger: 1, frequency: 8,
           layer: RPG2k::Scene::Map::LAYER_SAME)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  ch = chars(scene)[1]
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6 # hold right, toward the event -- same frame the
                            # event (frequency 8: decides every frame) is
                            # itself heading left, toward the party
  10.times { scene.update }
  ok !st.switches[6], 'Hero Touch never fired -- the hit-test is invalidated'
  eq [0, 0], [st.x, st.y], 'the party never stepped onto the event'
  eq [1, 0], [ch.x, ch.y], "the event never stepped onto the party (case (b), unchanged)"
end

check 'hero and event crossing paths (case (c)): trading tiles also ' \
      "suppresses the event's own Event Touch -- no trigger fires either way" do
  ic = Game::Interpreter::Cmd
  pg = page(x_move_type: Game::MoveType::TOWARD, trigger: 2, frequency: 8,
           layer: RPG2k::Scene::Map::LAYER_SAME)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  ch = chars(scene)[1]
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6
  10.times { scene.update }
  ok !st.switches[5], 'Event Touch never fired either, same crossing'
  eq [0, 0], [st.x, st.y], 'the party never stepped onto the event'
  eq [1, 0], [ch.x, ch.y], 'the event never stepped onto the party'
end

check 'hero and event crossing paths (case (c)): a Set Move Route / custom-' \
      'route event crossing the party is suppressed the same way as an ' \
      'autonomous Approach move' do
  ic = Game::Interpreter::Cmd
  pg = page(x_move_type: Game::MoveType::CUSTOM, trigger: 1, frequency: 8,
           layer: RPG2k::Scene::Map::LAYER_SAME,
           route: move_route([R::MOVE_LEFT], repeat: true))
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  ch = chars(scene)[1]
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6
  10.times { scene.update }
  ok !st.switches[6], 'Hero Touch never fired for the crossing custom-route event'
  eq [0, 0], [st.x, st.y], 'the party never stepped onto the event'
  eq [1, 0], [ch.x, ch.y], 'the event never stepped onto the party'
end

check 'hero and event crossing paths (case (c)) requires an actual same-' \
      "frame crossing -- an event's earlier, separate-frame refusal does " \
      'not suppress a later ordinary Hero Touch' do
  ic = Game::Interpreter::Cmd
  pg = page(x_move_type: Game::MoveType::TOWARD, trigger: 1, frequency: 8,
           layer: RPG2k::Scene::Map::LAYER_SAME)
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0])]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  # The party holds still for this frame: the event (case (b)) still refuses
  # to step onto the party's tile, but since the party attempted no move at
  # all this frame, it is not a crossing.
  scene.update
  e = event_hashes(scene)[1]
  ok !e[:crossed_hero_this_frame], 'not a crossing: the party was not moving'
  # Freeze the event's own move cadence so its next decision cannot coincide
  # with the party's move below -- isolating "does an old refusal leak into
  # suppressing a later frame" from the crossing detection itself.
  e[:move_timer] = 999
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6 # only now does the party start walking in
  6.times { scene.update }
  ok st.switches[6], 'Hero Touch still fires -- this was never a same-frame crossing'
  eq [0, 0], [st.x, st.y], 'and the party did not step onto it, same as any touch event'
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

check 'parallel (trigger 4) also answers hero touch, independent of its own ' \
      'background loop (yado.tk)' do
  # yado.tk: setting a page's trigger to Parallel Process also answers hero
  # contact -- instantly on overlap for a below/above-characters page (the
  # default layer here), same as the two dedicated touch triggers. Distinguish
  # the foreground touch-triggered run from the event's own always-running
  # background loop with a Show Message: a background interpreter's message
  # request is silently ignored (#drive_parallel_wait's "background: ignore
  # message/choice/teleport requests" branch), so @message only ever opens
  # through the foreground #start_event/#drive_event path this fix adds.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 4) # parallel process
  pg.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi')]
  scene = new_scene({ 1 => event(1, 0, pg) }, player: [0, 0])
  RGSS::Input.dir_value = 6 # hold right, into the parallel event at (1,0)
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'walking into a Parallel Process event opened a message window ' \
          'through the foreground touch path'
  st = scene.instance_variable_get(:@state)
  eq [0, 0], [st.x, st.y], 'the party did not step onto the event'
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

# RPG2003's own Wait dialog adds a "wait until the Decision key is pressed"
# mode (Interpreter#do_wait's own `:wait_key_enter`, param1 nonzero) that
# ignores the timed duration in param0 entirely -- confirmed against
# EasyRPG's actual `CommandWait` (src/game_interpreter.cpp). Drives the
# same #message_window_open?-gated convention every other suppressed
# command in this file already uses (Show/Move/Erase Picture while a
# message is open, above); not re-proven here, just reused.
check 'RPG2003 Wait-for-Decision-key mode blocks the event until the key is pressed, ignoring the duration' do
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
                       ECmd.new(ic::WAIT, [50, 1]), # param0 (5s) irrelevant; param1 arms key-wait
                       ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0])]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0], rpg2003: true)
  st = scene.instance_variable_get(:@state)
  scene.update
  ok st.switches[1], 'ran up to the Wait'
  ok !st.switches[2], 'held at the Wait -- no key pressed yet'
  20.times { scene.update } # well past param0's own 3-second duration
  ok !st.switches[2], 'still held: the timed duration plays no part in this mode'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  ok st.switches[2], 'resumed the instant the Decision key was pressed'
end

# yado.tk "Untriaged backlog": "Autorun cascading within one frame" -- if the
# lowest-id eligible Autorun map event's content contains no wait-including
# command, real RPG_RT lets the next-lowest-id eligible Autorun event start
# immediately in the same frame. Verified against EasyRPG Player's actual C++
# source: `Game_Map::UpdateForegroundEvents` drives the shared foreground
# interpreter inside a `while (!interp.IsRunning() && ...)` loop that rescans
# for another eligible event the instant one's own command list drains, all
# within the same real-frame call -- see `Scene::Map#drive_autostart_cascade`.
check 'a second, distinct auto-start map event starts the same frame the ' \
      'first one finishes with no Wait (Autorun cascading)' do
  ic = Game::Interpreter::Cmd
  p1 = page(trigger: 3) # auto-start, no Wait: just flips switch 1
  p1.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0])]
  p2 = page(trigger: 3) # auto-start: flips switch 2
  p2.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0])]
  scene = new_scene({ 1 => event(1, 1, p1), 2 => event(2, 2, p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update
  ok st.switches[1], 'the first auto-start event ran'
  ok st.switches[2], 'a second, distinct auto-start event cascaded into the ' \
                      'very same frame instead of waiting for the next one'
end

check 'a second auto-start map event does NOT cascade in while the first ' \
      'one is still parked on its own Wait' do
  ic = Game::Interpreter::Cmd
  p1 = page(trigger: 3) # auto-start: flips switch 1, then waits
  p1.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
                       ECmd.new(ic::WAIT, [2])] # 0.2s = 12 frames
  one_shot_auto(p1, 9001) # fire once: a re-firing auto-start would re-wait every frame and starve p2
  p2 = page(trigger: 3) # auto-start: flips switch 2
  p2.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0])]
  scene = new_scene({ 1 => event(1, 1, p1), 2 => event(2, 2, p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update
  ok st.switches[1], 'the first event\'s pre-wait command ran'
  ok !st.switches[2], 'a still-running (waiting) first event must not let a ' \
                       'second one cascade in on top of it'
  20.times { scene.update }
  ok st.switches[2], 'the second event eventually runs once the first one\'s Wait clears'
end

check 'a distinct auto-start common event cascades in behind a finishing ' \
      'auto-start map event within the same frame' do
  ic = Game::Interpreter::Cmd
  p1 = page(trigger: 3) # auto-start, no Wait
  p1.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0])]
  ce = OpenStruct.new(start_term: 3, need_flag: false,
                      event: [ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0])])
  scene = new_scene({ 1 => event(1, 1, p1) }, player: [0, 0], common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  scene.update
  ok st.switches[1], 'the auto-start map event ran'
  ok st.switches[2], 'the auto-start common event cascaded in the same frame'
end

# The cascade above (and Game::Interpreter#update generally) used to give
# *every* #update call its own fresh MAX_STEPS budget -- a local `steps = 0`
# reset at the top of the method -- rather than sharing one budget across a
# whole real frame's worth of calls. Verified against EasyRPG Player's actual
# C++ source rather than assumed from the cascading fix's own already-correct
# writeup above: `Game_Interpreter::loop_count`/`loop_limit`
# (src/game_interpreter.h) are member variables, not a local, and
# `Game_Map::UpdateForegroundEvents` (src/game_map.cpp) resets `loop_count`
# to 0 exactly once per real frame (`interp.Update(!resume_fg)`) and then
# keeps calling `Update(false)` -- no reset -- as it cascades through every
# Auto-Start event that starts and finishes within that same frame. So a
# chain of several heavy, no-Wait Auto-Start events could burn up to
# `N * 10000` steps in one real frame instead of a combined 10000, spilling
# the rest into later frames the way a single heavy event already does.
# Fixed by moving the counter onto `Game::Interpreter` as `@frame_steps`
# (mruby-rpg2k/mrblib/interpreter.rb), reset only once per real frame
# (`#reset_frame_steps`, called from `Scene::Map#update` for the foreground
# interpreter and from `#step_parallel` for each Parallel Process's own,
# independent budget), and checking it *before* running each command rather
# than after, matching EasyRPG's `for (; loop_count < loop_limit; ...)`
# exactly -- otherwise a same-frame call arriving after the budget is already
# spent would still sneak in one more command apiece.
check "an Auto-Start cascade shares one real frame's step budget, not a " \
      "fresh one each (yado.tk's 10000-step budget is per frame, not per event)" do
  Game::Interpreter.send(:remove_const, :MAX_STEPS)
  Game::Interpreter.const_set(:MAX_STEPS, 3)
  begin
    p1 = page(trigger: 3) # auto-start: 3 single-cost commands, exactly the budget
    p1.event_commands = [add_var_cmd(1), add_var_cmd(1), add_var_cmd(1)]
    one_shot_auto(p1, 9001) # fire once: else it would win the race again next frame too
    p2 = page(trigger: 3) # auto-start: a second, distinct event, cascaded in behind it
    p2.event_commands = [add_var_cmd(2)]
    scene = new_scene({ 1 => event(1, 1, p1), 2 => event(2, 2, p2) }, player: [0, 0])
    st = scene.instance_variable_get(:@state)
    scene.update
    eq 3, st.variables[1], 'the first event ran to completion, spending the whole budget'
    eq 0, st.variables[2],
       'the cascaded second event must not get a fresh budget of its own -- ' \
       'nothing was left this frame'
    scene.update # a fresh real frame resets the shared budget
    eq 1, st.variables[2], "it runs once the next frame's budget has reset"
  ensure
    Game::Interpreter.send(:remove_const, :MAX_STEPS)
    Game::Interpreter.const_set(:MAX_STEPS, 10_000)
  end
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

# yado.tk "Full-site sweep": "Multiple simultaneous parallel processes are not
# concurrent -- the engine advances one command block at a time, round-robin,
# ... in definition/event-ID order." Settled precisely against EasyRPG
# Player's actual C++ source rather than guessed at: `Game_Map::Update`
# (src/game_map.cpp) always calls `UpdateCommonEvents()` before
# `UpdateMapEvents()`, every real frame, with no interleaving by id across the
# two groups -- `Game_CommonEvent` (src/game_commonevent.cpp) only ever builds
# an interpreter for a Parallel-trigger common event, so `UpdateCommonEvents`
# is this engine's exact counterpart to `#step_parallels`' common-event half.
# `Scene::Map#build_parallels` (mruby-rpg2k/mrblib/scene/map.rb) used to push
# every *map* event's own parallel process into `@parallels` before any
# *common* event's, the opposite order -- `#step_parallels`/`#step_parallel`
# simply walk `@parallels` in array order, so a common event's write this
# frame (a gate switch, a shared variable) was not visible to a map event's
# own parallel process reading it until the *next* frame, one tick later than
# real RPG_RT. Fixed by pushing the common-event loop first in
# `#build_parallels`, ahead of the map-event loop, with no other change to
# either loop's own internal (ascending id) ordering.
check "a common event's Parallel Process write is visible to a map event's " \
      'own Parallel Process the very same frame it happens (yado.tk)' do
  ic = Game::Interpreter::Cmd
  # Common event 1: turns switch 10 on, then parks on a long Wait -- one
  # non-blocking command, so it fully executes (switch write included) the
  # instant #step_parallel first drives it, well before parking.
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [ECmd.new(ic::CONTROL_SWITCHES, [0, 10, 10, 0], indent: 0),
                              ECmd.new(ic::WAIT, [60], indent: 0)])
  # Map event 2 (Parallel Process): checks switch 10 exactly once, sets switch
  # 20 on if it is already on, then also parks on a long Wait -- it never
  # loops back to re-check, so this only ever catches a same-frame write, not
  # one that merely lands a frame or two later.
  pg = page(trigger: 4)
  pg.event_commands = [
    ECmd.new(ic::CONDITIONAL, [0, 10, 0], indent: 0), # switch 10 == on ?
    ECmd.new(ic::CONTROL_SWITCHES, [0, 20, 20, 0], indent: 1),
    ECmd.new(ic::END_BRANCH, [], indent: 0),
    ECmd.new(ic::WAIT, [60], indent: 0),
  ]
  scene = new_scene({ 2 => event(3, 3, pg) }, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  scene.update
  ok st.switches[10], "the common event's own switch write must land this same frame"
  ok st.switches[20],
     "the map event's Parallel Process must observe switch 10 already on within " \
     'this same #step_parallels sweep -- common events run first, matching ' \
     "Game_Map::Update's UpdateCommonEvents-before-UpdateMapEvents order"
end

# yado.tk (01_shoshin/011_siyou, "Call Event"): a Call Event always bypasses
# the target common event's own condition-switch state entirely, regardless
# of whether the common event is configured Parallel Process, Auto-Start, or
# call-only, and regardless of its gate switch's live value. Confirmed
# already correct: Scene::Map#build_resolver (mruby-rpg2k/mrblib/scene/
# map.rb) hands the Call Event resolver a plain `id => commands` hash built
# from `@common`, discarding `:trigger`/`:need_flag`/`:switch_id` in the same
# line -- the resolver Game::Interpreter#do_call_event reads from structurally
# has no gate/trigger to consult, so nothing could conditionally block it even
# if a future change tried to add such a check without also plumbing it
# through here.
check "Call Event bypasses a target common event's own gate switch" do
  ic = Game::Interpreter::Cmd
  # Common event 1 is a Parallel Process gated on switch 9, which stays off
  # for this entire check -- Scene::Map#step_parallels would never run it on
  # its own while that holds.
  ce = OpenStruct.new(start_term: 4, need_flag: true, switch_id: 9,
                      event: [add_var_cmd(3)])
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::CALL_EVENT, [0, 1, 0])] # call common event 1
  scene = new_scene({ 1 => event(2, 2, pg) }, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  10.times { scene.update }
  ok !st.switches[9], 'the gate switch never turned on during this check'
  ok st.variables[3] > 0,
     "Call Event should run the gated common event's content regardless of its own switch"
end

# A Common Event's own Parallel Process, unlike a Map Event's, is supposed to
# keep running from wherever it was across a Transfer Player and a save/load
# (docs/TODO.md's "Common-event Parallel Process state should survive map
# changes and saves, unlike a map event's"). The three checks below pin the
# fix: full fidelity across a Transfer Player (the live interpreter object is
# kept), a coarser index-only continuation across a save/load (Game::State
# #common_event_progress), and that a map event's own parallel process is left
# exactly as before -- always a fresh restart, per visit.

check "a common event's Parallel Process interpreter survives a Transfer Player" do
  ic = Game::Interpreter::Cmd
  # Marker A, a multi-frame Wait, marker B: parks mid-list on the Wait, so a
  # teleport mid-countdown can be told apart from a fresh restart (which would
  # bump marker A a second time and reset the countdown).
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [add_var_cmd(3), ECmd.new(ic::WAIT, [3]), add_var_cmd(4)])
  scene = new_scene({}, common: { 7 => ce })
  st = scene.instance_variable_get(:@state)
  scene.update # marker A runs, then parks on the Wait (18 frames: Wait 0.3s)
  eq 1, st.variables[3], 'marker A ran once, before the wait'
  eq 0, st.variables[4], 'the wait has not elapsed yet'

  # Scene::Map is reused in place across a Transfer Player (#perform_teleport
  # mutates @map/@state in place, unlike Continue's fresh Scene::Map.new), so
  # the fix only has to keep #build_parallels from discarding the still-live
  # Game::Interpreter -- and its own in-flight wait countdown -- for this
  # common event.
  scene.send(:perform_teleport, [2, 0, 0, 0])
  eq 1, st.variables[3], 'the teleport must not have restarted the process from the top'
  eq 0, st.variables[4], 'nor reset the in-flight wait to a fresh countdown'

  # The wait's countdown had not yet been touched pre-teleport (its timer only
  # initialises on the next tick after the Wait command runs, see
  # #drive_parallel_wait, which also spends that first tick), so it takes
  # exactly 19 more ticks post-teleport to elapse (18 frames counted down plus
  # the tick that observes zero and resumes) -- proving the countdown itself
  # carried over untouched, not just the command index. One tick later the
  # process loops and marker A legitimately runs again, so this stops short of
  # that.
  19.times { scene.update }
  eq 1, st.variables[3], 'marker A still has not re-run'
  eq 1, st.variables[4], 'the wait elapsed after exactly its original countdown'
end

check "Transfer Player reuses a common event's Parallel Process interpreter " \
      "object, but always rebuilds a map event's" do
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 4)
  pg.event_commands = [add_var_cmd(1)]
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [add_var_cmd(2), ECmd.new(ic::WAIT, [3])])
  events = { 1 => event(2, 2, pg) }
  db = fake_db({ 7 => ce })
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, events)
  # A custom map_maker that hands back the same event table on every load, so
  # the map event's own parallel process still exists post-teleport to compare
  # against -- new_scene's default fake_parent always teleports into an empty
  # map (see the "Tile Substitution does not survive..." check above), which
  # would make this comparison vacuous for the map-event side.
  parent = FakeParent.new(db) { |id| fake_map(id, events) }
  scene = RPG2k::Scene::Map.new(parent, state)

  scene.update
  parallels_before = scene.instance_variable_get(:@parallels)
  common_before = parallels_before.find { |p| p[:common_event_id] == 7 }[:interp]
  map_before = parallels_before.find { |p| p[:event] }[:interp]

  scene.send(:perform_teleport, [1, 0, 0, 0]) # leave and return to the same map

  parallels_after = scene.instance_variable_get(:@parallels)
  common_after = parallels_after.find { |p| p[:common_event_id] == 7 }[:interp]
  map_after = parallels_after.find { |p| p[:event] }[:interp]
  ok common_before.equal?(common_after),
     "a common event's parallel process keeps its own interpreter across a teleport"
  ok !map_before.equal?(map_after),
     "a map event's parallel process still gets a brand-new interpreter every " \
     'visit -- unaffected by the reuse above, unchanged from before this fix'
  ok map_after.instance_variable_get(:@index).zero?,
     "the rebuilt map event's parallel process starts over at the top"
end

check "a common event's Parallel Process's own Transfer Player command " \
      'actually warps the party, then keeps running on the new map' do
  ic = Game::Interpreter::Cmd
  # Marker A, a Transfer Player to map 2, marker B: before this fix,
  # #drive_parallel_wait had no :teleport case, so a Parallel Process's own
  # Transfer Player fell into the generic "background: ignore ... teleport
  # requests" #resume branch -- the warp itself never happened at all (not
  # merely mistimed), and the process looped straight back to marker A
  # instead of ever reaching marker B. yado.tk (01_shoshin/011_siyou,
  # "Parallel Process"): "a Transfer Player command inside one lets
  # subsequent commands run while the new map is still loading." A Parallel
  # Process's own command list loops forever once it reaches the end (by
  # design, unrelated to this fix), so this only checks the first pass --
  # three frames is exactly enough for marker A, the teleport landing, and
  # marker B to each take effect one frame apart.
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [add_var_cmd(3), ECmd.new(ic::TELEPORT, [2, 0, 0, 0]),
                              add_var_cmd(4)])
  scene = new_scene({}, common: { 7 => ce })
  st = scene.instance_variable_get(:@state)
  eq 1, st.map_id, 'starts on map 1'

  3.times { scene.update }
  eq 1, st.variables[3], "marker A ran once, on the process's first pass"
  eq 2, st.map_id, "the process's own Transfer Player actually warped the party"
  eq 1, st.variables[4],
     "the SAME Parallel Process interpreter kept running past the teleport " \
     'and reached marker B on the new map'
end

check "an unrelated event's page change does not restart another event's " \
      'own Parallel Process' do
  ic = Game::Interpreter::Cmd
  # Event 1's own page never changes -- it is a bystander -- but its Parallel
  # Process runs marker A, parks on a 0.3s Wait, then runs marker B, so a
  # restart (which would re-run marker A instead of resuming the same
  # countdown) can be told apart from a genuine resume, mirroring this same
  # section's own "Transfer Player reuses a common event's ... interpreter"
  # check's timing setup above -- the difference here is nothing changes maps
  # at all, only an *unrelated* event's own page selection flips.
  par = page(trigger: 4)
  par.event_commands = [add_var_cmd(1), ECmd.new(ic::WAIT, [3]), add_var_cmd(2)]
  p1 = page(trigger: 0, charset_name: 'Villager')
  p2 = page(trigger: 0, charset_name: 'Ghost')
  scene = new_scene({ 1 => event(2, 2, par),
                      2 => two_page_event(5, 5, 3, p1, p2) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)

  scene.update # marker A runs, then event 1 parks on the 0.3s Wait
  eq 1, st.variables[1], 'marker A ran once, before the wait'
  eq 0, st.variables[2], 'the wait has not elapsed yet'

  # Flipping switch 3 only changes event 2's own page selection -- event 1's
  # page (and its already-running Parallel Process) never moves -- but
  # #pages_changed? is a map-wide check, so this still runs
  # #rebuild_events_preserving_positions, which used to discard and rebuild
  # *every* map event's Parallel Process interpreter, event 1's included.
  st.switches[3] = true
  scene.update
  ok event_hashes(scene)[2][:page].equal?(p2),
     "event 2's own page did flip (switch 3 went on)"
  eq 1, st.variables[1],
     "event 1's Parallel Process must not have restarted -- marker A would " \
     're-run and bump this to 2'
  eq 0, st.variables[2], 'nor reset the in-flight wait to a fresh countdown'

  # The common-event Transfer Player check above needs 19 more ticks because
  # `perform_teleport` itself does not tick the wait timer -- only the
  # `scene.update` calls that follow do. Here, unlike there, the switch-flip
  # frame just above *is* a full `scene.update`, so it already spent the
  # first of those 19 ticks (the one that initialises the timer from nil and
  # takes its first decrement, per #drive_parallel_wait) -- 18 more are
  # exactly enough for the remaining countdown to elapse.
  18.times { scene.update }
  eq 1, st.variables[1], 'marker A still has not re-run'
  eq 1, st.variables[2], 'the wait elapsed after exactly its original countdown'
end

check "a map event's own Parallel Process keeps running after its own page " \
      'stops matching mid-run, instead of being torn down' do
  ic = Game::Interpreter::Cmd
  # The event has a single page, gated on switch 4; its own Parallel Process
  # runs marker A, waits 0.3s, turns switch 4 off itself (its own condition,
  # so the very next page refresh drops it out of @events/@event_tiles
  # entirely -- #build_events skips an event with no page whose conditions
  # are satisfied -- with no other page to fall back to), waits another
  # 0.3s, then runs marker B. yado.tk, multiply corroborated: real RPG_RT
  # keeps a Parallel Process like this running to completion once started,
  # rather than aborting it the instant nothing selects its owning event any
  # more -- marker B must still fire even though the event itself is gone.
  pg = page(trigger: 4)
  pg.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 4)
  pg.event_commands = [add_var_cmd(1), ECmd.new(ic::WAIT, [3]),
                       ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 1]),
                       ECmd.new(ic::WAIT, [3]), add_var_cmd(2)]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.switches[4] = true # the page is satisfied from the start

  25.times { scene.update } # runs marker A, clears the first 0.3s wait
  eq 1, st.variables[1], 'marker A ran once, before the first wait'
  ok !st.switches[4], 'the process turned its own gating switch off'
  ok event_hashes(scene)[1].nil?,
     "the event itself is gone from @events -- no page's condition matches " \
     'any more'
  eq 0, st.variables[2], 'marker B has not run yet -- still parked at the second wait'

  25.times { scene.update } # let the second 0.3s wait elapse
  eq 1, st.variables[2],
     'the Parallel Process kept running to completion once hidden, instead ' \
     'of being torn down the moment its own page stopped matching'
end

check "a common event's Parallel Process resumes where it left off after a " \
      'save/load, not from the top' do
  ic = Game::Interpreter::Cmd
  # This is the TODO's own example: a Common Event's Parallel Process whose
  # gate switch turns off mid-run. Marker A / Wait / marker B / Wait / marker C
  # tells apart "resumed right after the wait it was parked at" from "restarted
  # at the top" (which would bump marker A again instead of leaving it alone).
  ce = OpenStruct.new(start_term: 4, need_flag: true, switch_id: 2,
                      event: [add_var_cmd(3), ECmd.new(ic::WAIT, [1]),
                              add_var_cmd(4), ECmd.new(ic::WAIT, [1]),
                              add_var_cmd(5)])
  db = fake_db({ 7 => ce })
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, {})
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)

  state.switches[2] = true # the gate opens
  scene.update # marker A runs, then parks at the first Wait
  eq 1, state.variables[3], 'marker A ran before the wait'
  state.switches[2] = false # "its switch turns off mid-run" -- ticking stops here

  # A Marshal round trip stands in for an actual save/load, exactly like the
  # other State round-trip checks in scripts/rpg2k_logic_check.rb.
  restored = Game::State.load(db, Marshal.load(Marshal.dump(state.to_h)))
  restored.map = fake_map(1, {})
  eq false, restored.switches[2], 'the save preserved the gate switch off'
  eq 1, restored.variables[3], 'and the run-so-far progress'

  fresh = RPG2k::Scene::Map.new(fake_parent(db), restored)
  restored.switches[2] = true # re-enable it, as the TODO's own example does
  fresh.update
  eq 1, restored.variables[3],
     'must NOT restart from the top (that would bump this a second time)'
  eq 1, restored.variables[4], 'instead it resumes right where the save left it'
  eq 0, restored.variables[5], 'and parks again at the second wait, same as before the save'
end

# A lightweight party for the inn tests: resume_inn only needs gold + a party
# roster whose members respond to full_heal, and Scene::Map reads party.leader.
 class InnStubActor
  attr_accessor :hp, :mp
  attr_reader :max_hp, :max_mp, :name
  def initialize(name); @name = name; @hp = 1; @mp = 0; @max_hp = 100; @max_mp = 30; end
  def full_heal; @hp = @max_hp; @mp = @max_mp; end
  def display_max_hp; hp && hp > max_hp ? hp : max_hp; end
  def display_max_mp; mp && mp > max_mp ? mp : max_mp; end
 end

class InnStubParty
  attr_reader :actors, :gold
  attr_accessor :leader
  def initialize(gold); @gold = gold; @actors = [InnStubActor.new('Hero')]; @leader = nil; end
  def gain_gold(n); @gold += n; end
end

# A party the placeholder battle grants rewards to: gold plus actors that bank
# EXP, with the leader Scene::Map reads while rendering.
# A database-wide Battle Command entry (chunk 29's `commands` table --
# `Game::Actor#battle_command_row`'s own return shape): just the two fields
# `#custom_battle_commands` (Scene::Map) reads, `name` and `type`.
BattleCommandDef = Struct.new(:name, :type)

class BattleStubActor
  attr_accessor :exp, :hp, :mp, :battle_row
  attr_reader :id, :name, :atk, :def, :agi, :int, :max_hp, :max_mp, :skills, :states,
              :level, :learn_table
  # Defaults are strong enough to beat the two-Slime troop the scene db defines;
  # a defeat test passes weaker stats. `states` seeds the Combatant Game::Battle
  # ::from_actor builds (Game::Battle.actor_states reads it off any source that
  # responds to `:states`), so a battle-command-skip check can start the fight
  # with an ally already afflicted, without reaching into the built battle's
  # own Combatant list after the fact.
  #
  # `level_up_at`/`learn_table` are opt-in (default nil/[]): a check that never
  # sets `level_up_at` gets a stub whose #level never moves, exactly like every
  # check predating #battle_result_lines's own level-up/skill-learned lines
  # (mirrors Game::Actor's real growth curve/learn table only as far as a
  # single EXP-threshold level-up needs, not the full RPG2000 curve).
  # `battler_animation_id`/`battle_x`/`battle_y` mirror Game::Actor's own
  # RPG2003 alternate-battle-sprite interface (#build_actor_sprite,
  # Scene::Map): the pre-resolved `db.battleranimations` id to draw from (nil
  # -- the default -- reads as 0/"no sprite data", the same answer a bare
  # actor with no battler_animation at all gives) and the raw manual-mode
  # screen position. The full id-resolution fallback chain itself
  # (Game::Actor#battler_animation_id) is exercised directly against a real
  # Game::Actor in scripts/rpg2k_logic_check.rb, not re-derived here.
  def initialize(atk: 40, dfn: 20, agi: 20, hp: 200, mp: 20, int: 20, skills: [], id: 1,
                 rename_skill: false, skill_name: '', states: [], force_ai: false,
                 battle_commands: nil, battle_command_table: {},
                 level: 1, level_up_at: nil, learn_table: [],
                 battler_animation_id: nil, battle_x: 0, battle_y: 0,
                 faceset_name: nil, faceset_index: 0, name: 'Hero')
    @exp = 0; @id = id; @name = name
    @atk = atk; @def = dfn; @agi = agi; @hp = hp; @max_hp = hp
    @mp = mp; @max_mp = mp; @int = int; @skills = skills
    @rename_skill = rename_skill; @skill_name = skill_name; @states = states
    @force_ai = force_ai
    @battle_commands = battle_commands
    @battle_command_table = battle_command_table
    @level = level; @level_up_at = level_up_at; @learn_table = learn_table
    @battler_animation_id = battler_animation_id
    @battle_x = battle_x; @battle_y = battle_y
    @faceset_name = faceset_name; @faceset_index = faceset_index
    # Mirrors Game::Actor's own RPG2003 battle-row state (#battle_row/
    # #battle_row=): front by default, flipped by the in-battle Row command
    # the same way a real actor's would be.
    @battle_row = Game::Battle::ROW_FRONT
  end
  attr_reader :battler_animation_id, :battle_x, :battle_y
  # RPG2003 gauge-card status panel fixture (#draw_battle_gauge_face,
  # Scene::Map): a nil `faceset_name` (the default) draws no face, the same
  # answer a real Game::Actor with no faceset row gives.
  attr_reader :faceset_name, :faceset_index
  # Mirrors Game::Actor's own RPG2003 battle-command-customization interface
  # (`#battle_commands` / `#battle_command_row`), so a stub battle can drive
  # `Scene::Map#custom_battle_commands` the same way a real actor row would.
  # nil (the default) means "no customization", same as an actor whose class
  # sets no such list.
  attr_reader :battle_commands
  def battle_command_row(id); @battle_command_table[id]; end
  # Bumps #level once @exp crosses @level_up_at (nil disables this entirely),
  # learning whatever @learn_table names for the new level -- the shape
  # #battle_level_up_lines (Scene::Map) needs to exercise the real Game::Actor
  # code path it mirrors (Game::Actor#gain_exp -> #set_level -> #learn_level_skills)
  # without the full RPG2000 EXP curve.
  def gain_exp(n)
    @exp += n
    return unless @level_up_at && @exp >= @level_up_at
    @level += 1
    @learn_table.each { |sid, at| @skills.push(sid) if at == @level && !@skills.include?(sid) }
  end
  # Battle write-back (Game::Battle#apply_to_party) sets the actor's post-battle
  # HP absolutely; the stub has no state model beyond the starting `states`
  # above, so just clamp to [0, max].
  def set_hp(value); @hp = value < 0 ? 0 : (value > @max_hp ? @max_hp : value); end
  def dead?; @hp <= 0; end
  # Change HP (Game::Interpreter#do_change_hp), so a "Lose: Branch" recovery
  # command (see the "Battle Lose: Branch" race check below) can revive this
  # stub the same way it would a real Game::Actor.
  def change_hp(amount, allow_death = true)
    @hp += amount
    floor = allow_death ? 0 : 1
    @hp = floor if @hp < floor
    @hp = @max_hp if @hp > @max_hp
  end
  # Mirrors Game::Actor's own RPG2000 "custom battle command" interface
  # (database fields 66/67), so a stub battle can drive the Skill-label rename
  # the same way a real actor row would.
  def rename_skill?; @rename_skill; end
  def skill_command_name; @skill_name; end
  # 強制AI -- Game::Actor#force_ai?'s own reader, mirrored here so a scene
  # check can drive a Forced-AI actor through a real battle command loop.
  def force_ai?; @force_ai; end
end

class BattleStubParty
  attr_reader :actors, :gold, :roster
  attr_accessor :leader
  # `rpg2003` stands in for the real `Game::Party#rpg2003?` (`Scene::Map
  # #flying_offset` reads it off `@state.party`, not the database directly, so
  # a battle scene check needs its stub party to answer it too) -- false by
  # default, matching every other check's plain RPG2000 fixture.
  # `enemy_group` defaults to "every id exists" (Hash.new(true)) -- these
  # checks drive an already-opening or already-open battle, not the
  # missing-troop-id diagnostic path (covered in scripts/rpg2k_logic_check.rb),
  # so an Enemy Encounter command's real troop id should never be rejected here.
  # `alternate_layout`/`automatic_placement` mirror Game::Party's own RPG2003
  # battle-screen-presentation reads (#alternate_battle_layout?/
  # #automatic_battle_placement?, both keyed off `db.battlecommands` there) --
  # false by default, matching every other check's plain RPG2000 fixture and
  # (for `respond_to?` gating) every check predating the alternate-battle-
  # sprite renderer, which never set either. `gauge_layout` mirrors
  # #gauge_battle_layout? the same way -- distinct from `alternate_layout`,
  # which is also true for the plain sprite-only layout (battle_type 1); a
  # check exercising the gauge card status panel sets this one instead/as well.
  # `actors:`/`roster_actors:` back the mid-battle roster-sync rendering
  # checks (Interpreter#do_change_party -> Scene::Map#on_battle_party_changed):
  # `actors:` overrides the single-`actor` default as the starting party,
  # `roster_actors:` names actors known but not (yet) a member, mirroring a
  # real Game::Party's roster always knowing an actor #add_actor can bring
  # in. Every check predating this stays on the plain `[actor]`/roster-of-one
  # shape.
  def initialize(actor = BattleStubActor.new, rpg2003: false, item_db: nil, skill_db: nil,
                 enemy_group: Hash.new(true), alternate_layout: false,
                 automatic_placement: false, gauge_layout: false,
                 actors: nil, roster_actors: nil)
    @actors = actors || [actor]
    @gold = 0
    @leader = nil
    @rpg2003 = rpg2003
    @items = {}
    @item_db = item_db
    @skill_db = skill_db
    @enemy_group = enemy_group
    @alternate_layout = alternate_layout
    @automatic_placement = automatic_placement
    @gauge_layout = gauge_layout
    @roster = {}
    (@actors + (roster_actors || [])).each { |a| @roster[a.id] = a }
  end
  def gain_gold(n); @gold += n; end
  def any_alive?; @actors.any? { |a| !a.dead? }; end
  def all_dead?; !any_alive?; end
  def rpg2003?; @rpg2003; end
  def alternate_battle_layout?; @alternate_layout; end
  def automatic_battle_placement?; @automatic_placement; end
  def gauge_battle_layout?; @gauge_layout; end
  # Interpreter#do_change_party's own interface (#add_actor/#remove_actor/
  # #include_actor?), mirroring Game::Party's real semantics closely enough
  # for these checks: add is a no-op for an already-present or unknown-roster
  # id, remove drops whichever actor (if any) currently holds that id.
  def include_actor?(id); @actors.any? { |a| a.id == id }; end
  def add_actor(id)
    return if include_actor?(id)
    a = @roster[id]
    return unless a
    @actors.push(a)
  end
  def remove_actor(id); @actors.reject! { |a| a.id == id }; end
  # A troop victory drop (Game::Troop#drops -> Scene::Map#battle_result_lines)
  # both grants the item and names it in the result window -- mirrors
  # ShopStubParty's own #gain_item, plus a #db_item lookup against whatever
  # item table `item_db` (typically the scene's own fake_db.item) was given.
  attr_reader :items
  def gain_item(id, n = 1); @items[id] = (@items[id] || 0) + n; end
  # A newly-learned skill (#battle_level_up_lines, Scene::Map) is named from
  # whatever skill table `skill_db` (typically the scene's own fake_db.skill)
  # was given, mirroring #db_item above.
  def db_skill(id); @skill_db && @skill_db[id]; end
  def db_item(id); @item_db && @item_db[id]; end
  def db_enemy_group(id); @enemy_group[id]; end
end

# A minimal party member for the shop status panel's equipped-count check --
# just an equipment slot array, mirroring Game::Actor#equipment.
class ShopStubActor
  attr_reader :equipment
  def initialize(equipment); @equipment = equipment; end
end

# A party the shop can charge and stock: gold plus an item-count bag, with the
# leader Scene::Map reads while rendering.
class ShopStubParty
  attr_accessor :actors
  attr_reader :gold, :items
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
  def equipped_item_count(id)
    @actors.reduce(0) { |n, a| n + a.equipment.count(id) }
  end
end

# Build an auto-start event running `commands`, with a stub party holding `gold`.
def inn_scene(gold, commands, guard: false)
  auto = page(trigger: 3)
  auto.event_commands = commands
  one_shot_auto(auto, 9003) if guard
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
  scene.update # accept: fades the screen to black instead of resuming at once
  ok st.screen.fading?, 'the accepted stay fades out before the heal'
  eq 1000, st.party.gold, 'not charged yet -- the heal waits for the fade to land'
  40.times { scene.update } # drain the fade-out (35 frames) and the Stay branch after
  eq 900, st.party.gold, 'the price was deducted once the screen went black'
  eq st.party.actors.first.max_hp, st.party.actors.first.hp, 'party healed'
  ok st.switches[1], 'the Stay branch ran'
  ok !st.switches[2], 'the No Stay branch was skipped'
end

check 'Show Inn scene: an accepted stay fades to black, holds through the heal, ' \
      'then fades back in over the RPG_RT default 35 frames' do
  # Real RPG_RT (EasyRPG's Scene_Map::UpdateInn / FinishInn, the async
  # eCallInn path CommandShowInn's accepted-stay continuation triggers) fades
  # out the instant a stay is accepted -- before the heal, not after -- holds
  # black while the party is healed, then starts the fade back in the same
  # beat, all in the plain FADE_OUT / FADE_IN styles Erase/Show Screen use at
  # their own default length (Game::Transition.default_frames), not some
  # inn-specific duration.
  eq 35, Game::Transition.default_frames(Game::Transition::FADE_OUT)
  eq 35, Game::Transition.default_frames(Game::Transition::FADE_IN)

  scene, st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 100), guard: true)
  5.times { scene.update } # inn command runs; the greeting prompt opens
  RGSS::Input.triggered = [RGSS::Input::C] # cursor starts on Accept (affordable)
  scene.update # accept: the fade-out starts this same frame, not an immediate resume
  ok st.screen.fading?, 'fading out the instant the stay is accepted'
  eq 1000, st.party.gold, 'not charged yet -- the heal waits for the fade to land'
  34.times { scene.update } # the remaining fade-out frames (35 total)
  ok st.screen.fading?, 'one frame short of the fade-out landing, still holding'
  eq 1000, st.party.gold, 'still not charged -- the screen has not gone fully black yet'
  scene.update # the 35th fade-out frame: lands fully black, heals, starts the fade back in
  eq 900, st.party.gold, 'charged the moment the screen went fully black'
  eq st.party.actors.first.max_hp, st.party.actors.first.hp, 'healed the same frame'
  ok st.screen.fading?, 'the fade back in starts immediately, not a separate wait'
  34.times { scene.update } # the fade-in's own remaining frames (35 total)
  ok st.screen.fading?, 'one frame short of the fade-in landing'
  scene.update # the fade-in's 35th frame lands fully visible again
  ok !st.screen.fading?, 'the fade-in has landed'
  eq 0, st.screen.fade_level, 'screen fully visible again'
end

check 'Show Inn scene: cancelling with B spends nothing, runs No Stay, and never fades' do
  scene, st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 100))
  5.times { scene.update }
  eq 0, st.screen.fade_level, 'screen fully visible while the prompt is up'
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update # resumes with no stay
  ok !st.screen.fading?, 'a cancelled stay never starts a fade -- real RPG_RT never reaches ' \
                         'its eCallInn path when the prompt is declined'
  eq 0, st.screen.fade_level, 'still fully visible'
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
  ok !st.screen.fading?, 'an ignored Accept never starts a fade either'
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

check 'Show Inn scene: inn BGM plays on entry, field BGM resumes after a stay' do
  scene, st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 100))
  st.current_bgm = { name: 'Field', volume: 100, tempo: 100 } # the map's own BGM
  RGSS::Audio.reset_bgm
  5.times { scene.update } # inn command runs; the greeting prompt opens
  eq [['InnBGM', 75, 105]], RGSS::Audio.bgm_calls,
     'the database inn BGM played the moment the greeting opened'
  eq 'InnBGM', st.current_bgm[:name], 'and is now the tracked current BGM'
  RGSS::Audio.reset_bgm
  RGSS::Input.triggered = [RGSS::Input::C] # cursor starts on Accept (affordable)
  scene.update # accept: starts the fade-out, the BGM swap waits for it to land
  35.times { scene.update } # drain the 35-frame fade-out
  eq [['Field', 100, 100]], RGSS::Audio.bgm_calls,
     'the field BGM that was playing before the stay replays once the fade lands'
  eq 'Field', st.current_bgm[:name]
end

check 'Show Inn scene: a Change System BGM inn override beats the database default' do
  scene, st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 100))
  # System BGM slot 2 is inn -- see the Game::Interpreter::Cmd note near
  # VEHICLE_SYSTEM_BGM_SLOT / SYSTEM_BGM_INN in scene/map.rb.
  st.system_bgm[2] = { name: 'CustomInn', fadein: 0, volume: 60, tempo: 130, balance: 50 }
  RGSS::Audio.reset_bgm
  5.times { scene.update }
  eq [['CustomInn', 60, 130]], RGSS::Audio.bgm_calls,
     'the Change System BGM override played instead of the database inn_music'
  eq 'CustomInn', st.current_bgm[:name]
end

check 'Show Inn scene: a free stay (price 0) still plays and restores the inn BGM' do
  scene, st = inn_scene(1000, inn_commands(Game::Interpreter::Cmd, 0), guard: true) # price 0 skips the prompt
  st.current_bgm = { name: 'Field', volume: 100, tempo: 100 }
  RGSS::Audio.reset_bgm
  # No greeting window opens for a free stay, so this reaches the inn BGM in a
  # couple of frames of ordinary event processing (unlike the priced-prompt
  # tests, no player input is needed) -- but a free stay still auto-accepts,
  # so it still fades to black (35 frames) before the field BGM restores and
  # the resolved Stay branch runs, same as a prompted Accept.
  3.times { scene.update }
  eq [['InnBGM', 75, 105]], RGSS::Audio.bgm_calls, 'the inn BGM played'
  ok st.screen.fading?, 'a free stay auto-accepts, so it fades out too'
  40.times { scene.update } # drain the fade-out (35 frames) and the Stay branch after
  eq [['InnBGM', 75, 105], ['Field', 100, 100]], RGSS::Audio.bgm_calls,
     'the field BGM was restored once the fade landed'
  eq 'Field', st.current_bgm[:name]
  ok st.switches[1], 'the Stay branch ran (a free stay always stays)'
end

# EasyRPG's `Game_Interpreter_Map::CommandShowInn`
# (src/game_interpreter_map.cpp) is the exact same method for the foreground
# and every Parallel Process's own interpreter, like Open Shop/Enter Hero
# Name -- but it carries one extra, deliberately-preserved nuance of its own
# (EasyRPG's own comment: "Emulates RPG_RT behavior (Bug?) Inn's called by
# parallel events overwrite the current message"): a *priced* stay is gated
# `main_flag && !Game_Message::CanShowMessage(main_flag)`, which is always
# false for a non-foreground interpreter, so the message-active check is
# skipped entirely -- unlike Open Shop, which keeps the ordinary
# `IsMessageActive()` gate for every caller alike. Before `Scene::Map
# #drive_parallel_wait` had an `:inn` branch at all, a Parallel Process's own
# Show Inn fell into the generic "background: resume" default and read as a
# complete no-op, the same defect Open Shop/Enter Hero Name had before their
# own fixes -- so this covers both halves: the missing branch, and the
# priced-vs-free asymmetry once it exists.
check 'Show Inn (priced) issued from a Parallel Process barges over an open ' \
      'message window instead of waiting for it' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4) # Parallel Process
  par.event_commands = inn_commands(ic, 100)
  scene = new_scene({ 1 => event(2, 2, par) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, InnStubParty.new(1000))
  scene.send(:open_message, ['an unrelated message window is up'], false)
  inn_window = nil
  6.times { scene.update; inn_window = scene.instance_variable_get(:@inn_window); break if inn_window }
  ok inn_window, 'the priced inn prompt opened for a Parallel-Process-issued ' \
                 'command despite an open, unrelated message window -- matches ' \
                 "EasyRPG's own documented RPG_RT quirk rather than silently " \
                 'no-opping (the pre-fix behavior) or blocking on the message ' \
                 '(a plausible-looking but wrong fix)'
end

check 'Show Inn (free stay) issued from a Parallel Process still waits for an ' \
      'open message window to clear, unlike the priced case just above' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4) # Parallel Process
  par.event_commands = inn_commands(ic, 0) # price 0: free stay, no prompt
  scene = new_scene({ 1 => event(2, 2, par) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, InnStubParty.new(1000))
  scene.send(:open_message, ['an unrelated message window is up'], false)
  5.times { scene.update }
  ok !st.screen.fading?, 'a free stay must not auto-accept while a message window is still open'
  ok !st.switches[1], 'the Stay branch has not run yet either'
  scene.send(:close_message)
  40.times { scene.update } # the free stay proceeds, fades out (35 frames) and resolves
  ok st.switches[1], 'the free stay ran through to its Stay branch once the message cleared'
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

check 'Key Input Proc (RPG2003 Numbers layout) resolves a digit key press' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # RPG2003's own 9-param layout: var, wait, arrows off, decision on, cancel
  # off, numbers on, operators off, time-var/timed unused.
  auto.event_commands = [
    ECmd.new(ic::KEY_INPUT_PROC, [1, 1, 0, 1, 0, 1, 0, 0, 0]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, rpg2003: true)
  st = scene.instance_variable_get(:@state)
  5.times { scene.update } # no key pressed yet: the proc keeps waiting
  eq 0, st.variables[1]
  ok !st.switches[5]
  RGSS::Input.triggered = [RGSS::Input::N3] # digit 3
  scene.update # this frame resumes the proc and stores the code
  eq 13, st.variables[1], 'digit 3 -> RPG2000 code 13 (10 + the digit)'
  scene.update # the following command runs once the proc has resumed
  ok st.switches[5]
end

check 'Key Input Proc (RPG2003 Operators layout) resolves an operator key press' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Same 9-param layout, but with operators (not numbers) accepted.
  auto.event_commands = [
    ECmd.new(ic::KEY_INPUT_PROC, [1, 1, 0, 1, 0, 0, 1, 0, 0]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, rpg2003: true)
  st = scene.instance_variable_get(:@state)
  5.times { scene.update } # no key pressed yet: the proc keeps waiting
  eq 0, st.variables[1]
  ok !st.switches[5]
  RGSS::Input.triggered = [RGSS::Input::PERIOD] # decimal point
  scene.update
  eq 24, st.variables[1], 'Period is the highest-priority operator code'
  scene.update
  ok st.switches[5]
end

check 'Key Input Proc (RPG2003 Numbers layout) ignores a digit key when Numbers is not accepted' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Decision only; Numbers off.
  auto.event_commands = [
    ECmd.new(ic::KEY_INPUT_PROC, [1, 1, 0, 1, 0, 0, 0, 0, 0]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, rpg2003: true)
  st = scene.instance_variable_get(:@state)
  RGSS::Input.triggered = [RGSS::Input::N3] # not accepted: Numbers is off
  3.times { scene.update }
  ok !st.switches[5], 'an unaccepted digit must not resume the proc'
  eq 0, st.variables[1]
  RGSS::Input.triggered = [RGSS::Input::C] # Decision: accepted
  scene.update
  eq 5, st.variables[1]
  scene.update
  ok st.switches[5]
end

check 'parallel processes keep running while a message window is open (yado.tk)' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi')]
  par = page(trigger: 4)
  par.event_commands = [add_var_cmd(1)]
  scene = new_scene({ 1 => event(2, 2, auto), 2 => event(4, 4, par) })
  10.times { scene.update }
  # The autostart event opens a message and waits for input we never give, but
  # per yado.tk a message box is not a pause condition for parallel processes
  # -- only the Menu/Battle screens are (and Menu already is, structurally:
  # Scene::Map#update does not run while it sits on top).
  ok scene.instance_variable_get(:@state).variables[1] > 0,
     'the parallel process advances despite the open message window'
end

check 'Show Picture is suppressed even for the foreground interpreter whose own window is open (yado.tk)' do
  # A foreground event can never naturally reach a picture command while
  # parked on its own Show Text wait (the interpreter is blocked until the
  # window closes), so this pokes the interpreter directly to prove the
  # suppression rule lives on the command itself (shared by every
  # interpreter, foreground or parallel) and not just on the natural
  # scheduling that happens to keep a foreground event from self-colliding.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi')]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)

  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'

  interp = scene.instance_variable_get(:@interpreter)
  interp.send(:do_show_picture,
             ECmd.new(ic::SHOW_PICTURE, [1, 0, 100, 100, 0, 100, 0, 0, 100, 100, 100, 100],
                      string: 'pic'))
  ok !st.pictures.key?(1),
     'a picture command reaching the interpreter while its own message window is open must not apply'
end

check 'Show Picture is suppressed while a choice list is open (yado.tk)' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_CHOICES, [0], indent: 0), # cancel forbidden
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes'),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'no'),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)

  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'choice list opened'
  ok msg[:choice], 'it is a choice window, not a plain message'

  interp = scene.instance_variable_get(:@interpreter)
  interp.send(:do_show_picture,
             ECmd.new(ic::SHOW_PICTURE, [1, 0, 100, 100, 0, 100, 0, 0, 100, 100, 100, 100],
                      string: 'pic'))
  ok !st.pictures.key?(1), 'a picture command must not apply while a choice list is open'
end

check 'Show/Move/Erase Picture from an independently-running parallel process are ' \
      'suppressed while a message window is open, and apply once it closes (yado.tk)' do
  ic = Game::Interpreter::Cmd

  # Each sub-case opens the message window directly (via the same #open_message
  # the foreground driver itself calls) instead of racing an autostart trigger
  # against the parallel process's very first frame -- #step_parallels already
  # runs before #start_autostart each frame (see Scene::Map#update), so a
  # naturally-triggered message would not be open yet for the parallel
  # process's first lap, and these commands are non-blocking no-ops once
  # applied, not something a later suppression could retract.

  # -- Show Picture ---------------------------------------------------------
  par = page(trigger: 4)
  par.event_commands = [
    ECmd.new(ic::SHOW_PICTURE, [1, 0, 100, 100, 0, 100, 0, 0, 100, 100, 100, 100],
             string: 'pic'),
    add_var_cmd(1),
  ]
  scene = new_scene({ 1 => event(4, 4, par) })
  st = scene.instance_variable_get(:@state)
  scene.send(:open_message, ['hi'], false)

  10.times { scene.update }
  ok !st.pictures.key?(1),
     'Show Picture from a still-running parallel process must not apply while a message window is open'
  ok st.variables[1] > 0,
     'the parallel process keeps advancing its non-picture commands regardless -- the sibling ' \
     '"parallel processes were paused too broadly" fix must stay intact'

  scene.send(:close_message)
  5.times { scene.update }
  ok st.pictures.key?(1), 'Show Picture applies once the window closes'

  # -- Move Picture -----------------------------------------------------------
  par2 = page(trigger: 4)
  par2.event_commands = [ECmd.new(ic::MOVE_PICTURE,
                                  [1, 0, 200, 200, 0, 100, 0, 0, 100, 100, 100, 100, 0, 0, 0, 0])]
  scene2 = new_scene({ 1 => event(4, 4, par2) })
  st2 = scene2.instance_variable_get(:@state)
  st2.pictures[1] = Game::Picture.new(1, x: 100, y: 100)
  scene2.send(:open_message, ['hi'], false)

  10.times { scene2.update }
  eq [100, 100], [st2.pictures[1].x, st2.pictures[1].y],
     'Move Picture from the parallel process must not relocate it while the window is open'

  scene2.send(:close_message)
  5.times { scene2.update }
  eq [200, 200], [st2.pictures[1].x, st2.pictures[1].y],
     'Move Picture applies once the window closes'

  # -- Erase Picture ----------------------------------------------------------
  par3 = page(trigger: 4)
  par3.event_commands = [ECmd.new(ic::ERASE_PICTURE, [1])]
  scene3 = new_scene({ 1 => event(4, 4, par3) })
  st3 = scene3.instance_variable_get(:@state)
  st3.pictures[1] = Game::Picture.new(1, x: 100, y: 100)
  scene3.send(:open_message, ['hi'], false)

  10.times { scene3.update }
  ok st3.pictures.key?(1), 'Erase Picture from the parallel process must not apply while the window is open'

  scene3.send(:close_message)
  5.times { scene3.update }
  ok !st3.pictures.key?(1), 'Erase Picture applies once the window closes'
end

check 'parallel processes pause during battle' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4)
  par.event_commands = [add_var_cmd(1)]
  scene = new_scene({ 1 => event(4, 4, par) })
  fake_battle(scene, { phase: :command })
  10.times { scene.update }
  eq 0, scene.instance_variable_get(:@state).variables[1],
     'a parallel process must not advance while a battle is in progress'
end

check 'parallels_paused? treats a still-bursting foreground interpreter as busy' do
  # A command list heavy enough to spill past one frame's MAX_STEPS budget
  # without reaching a wait leaves the interpreter running? but not waiting? --
  # exactly the "executes non-blocking commands" case yado.tk says pauses
  # parallel processes (unlike being parked on a blocking wait, which does not).
  scene = new_scene({})
  interp = scene.instance_variable_get(:@interpreter)
  interp.instance_variable_set(:@running, true)
  interp.instance_variable_set(:@waiting, false)
  ok scene.send(:parallels_paused?), 'still-bursting (running, not waiting) pauses parallels'
  interp.instance_variable_set(:@waiting, true)
  ok !scene.send(:parallels_paused?), 'parked on a wait (running and waiting) does not'
end

check 'Move Event forces a target map event onto a route' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # auto-start: on load, tell event 2 to walk east
  # target event 2, freq 8, repeat on, skippable on, MOVE_RIGHT.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [2, 8, 1, 1, R::MOVE_RIGHT])]
  one_shot_auto(auto, 9004)
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
  one_shot_auto(auto, 9005)
  scene = new_scene({ 1 => event(2, 0, auto) }, player: [5, 4])
  c = chars(scene)[1]
  30.times { scene.update }
  ok c.y > 0, "the event moved itself downward, at y=#{c.y}"
  eq 2, c.x, 'it stayed on its column'
end

check 'Move Frequency reasserts the page value once a forced route finishes' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target event 2, freq 8 (route pacing), repeat off, skippable on: bump
  # frequency twice then take one step, so the route finishes rather than
  # looping forever.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT,
    [2, 8, 0, 1, R::FREQ_UP, R::FREQ_UP, R::MOVE_RIGHT])]
  one_shot_auto(auto, 9006)
  target_page = page(frequency: 3) # the page's own configured frequency
  mover = event(1, 1, target_page)
  scene = new_scene({ 1 => event(0, 4, auto), 2 => mover }, player: [5, 0])
  eq 3, chars(scene)[2].move_frequency, 'starts at the page frequency'
  40.times { scene.update }
  ok chars(scene)[2].x > 1, 'the forced route ran and moved the event'
  eq 3, chars(scene)[2].move_frequency,
     'the page frequency reasserts itself once the forced route finishes, ' \
     'not the Frequency Up value the route left it at'
end

check 'a forced player route suppresses input while it runs' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target 10001 (player), freq 8, repeat on, skippable on, MOVE_DOWN.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10001, 8, 1, 1, R::MOVE_DOWN])]
  one_shot_auto(auto, 9007)
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
  one_shot_auto(auto, 9008)
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

check "an event's occupied tile updates the instant it steps, before the " \
      "sprite finishes sliding (yado.tk: \"hero touches event\" case (a))" do
  # A same-layer event stepping right once. RPG_RT's hit-test (what a
  # touch-trigger or the player's own passability check reads) is grid-based
  # on the character's *logical* tile, updated the moment the step commits --
  # not the sprite's on-screen position, which eases toward it over several
  # more frames (#event_sliding? / #reoccupy).
  pg = page(x_move_type: Game::MoveType::CUSTOM,
            route: move_route([R::MOVE_RIGHT], repeat: false, skippable: false),
            frequency: 8)
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [5, 5])
  tiles = scene.instance_variable_get(:@event_tiles)
  ok tiles[[2, 2]] && tiles[[2, 2]][:id] == 1, 'starts on its own tile'

  # Advance to the first frame the character's logical tile reads (3, 2).
  ev = nil
  20.times do
    scene.update
    ev = event_hashes(scene)[1]
    break if [ev[:char].x, ev[:char].y] == [3, 2]
  end
  eq [3, 2], [ev[:char].x, ev[:char].y], 'the character stepped to (3, 2)'
  ok ev[:moving], 'and the sprite is still easing toward it, not there yet'

  tiles = scene.instance_variable_get(:@event_tiles)
  ok tiles[[2, 2]].nil?,
     "the vacated tile's hit-test cleared the instant the step committed, " \
     'even though the sprite is still drawn overlapping it'
  ok tiles[[3, 2]] && tiles[[3, 2]][:id] == 1,
     'and the destination tile is claimed for hit-testing immediately too'
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

check 'Through Mode set by a player route outlives the route, and Halt All Movement does not clear it' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Turn Through Mode on, then take the one step a through route can make
  # through a wall no ordinary move could cross.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT,
                                  [10001, 8, 0, 1, R::THROUGH_ON, R::MOVE_DOWN])]
  one_shot_auto(auto, 9009)
  scene = walled_in_scene({ 1 => event(5, 0, auto) }, [2, 2])
  st = scene.instance_variable_get(:@state)

  40.times { scene.update }
  eq [2, 3], [st.x, st.y], 'the through route stepped through the wall once'
  ok scene.instance_variable_get(:@player_route).nil?, 'the one-shot route finished'

  # Ordinary input-driven walking now also passes through the same wall --
  # Through Mode carried over instead of resetting when the route ended. (Not
  # asserting an exact landing tile: walking speed means holding the key down
  # for a fixed frame count can land mid-tile-count either side of one step,
  # which isn't the thing under test.)
  RGSS::Input.dir_value = 2 # down
  20.times { scene.update }
  eq 2, st.x, 'only moved along the column it was already walking'
  ok st.y > 3, "Through Mode outlived the route that set it -- walked further " \
               "through the same wall (was at y=3, now #{st.y})"
end

check "Halt All Movement lands an in-progress jump but drops the route's trailing steps" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # A two-tile jump (Begin/End Jump around two Move Down) followed by a
  # trailing Move Down that a halt right after landing should never reach.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT,
                                   [10001, 8, 0, 0, R::BEGIN_JUMP, R::MOVE_DOWN,
                                    R::MOVE_DOWN, R::END_JUMP, R::MOVE_DOWN])]
  one_shot_auto(auto, 9010)
  scene = new_scene({ 1 => event(5, 0, auto) }, player: [2, 0])
  st = scene.instance_variable_get(:@state)

  # Advance until the jump has landed on-screen (the party's own position
  # catches up to the slide's destination) but before the route's next paced
  # step -- the trailing Move Down -- has had a chance to run: that step
  # happens on the frame *after* the landing frame (see #advance_player_slide
  # / #step_player_route), so stopping the instant st.y reaches 2 is still one
  # frame ahead of it.
  40.times do
    break if st.y == 2
    scene.update
  end
  eq 2, st.y, 'the jump landed two tiles down'
  ok scene.instance_variable_get(:@player_route),
     "the route has not finished -- the trailing step is still queued"

  # Halt All Movement now, injected directly (rather than scripted into the
  # route's own event) so the timing lands exactly on this frame.
  scene.instance_variable_get(:@interpreter).start(
    [ECmd.new(ic::HALT_ALL_MOVEMENT, [])])
  5.times { scene.update }

  eq 2, st.y,
     "the jump's landing was not undone -- Halt All Movement aborts the " \
     'route without unwinding what it already did'
  ok scene.instance_variable_get(:@player_route).nil?, 'the route itself is cancelled'
end

check 'Set Transparent Flag hides and shows the player sprite' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::PLAYER_VISIBILITY, [1])] # transparent ON
  one_shot_auto(auto, 9011)
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

# EasyRPG's `Game_Interpreter::CommandReturnToTitleScreen`
# (src/game_interpreter.cpp) is a plain `Game_Interpreter` method with no
# `main_flag` gate at all, so every interpreter -- foreground or a Parallel
# Process's own -- reaches it identically. Before this fix,
# `Scene::Map#drive_parallel_wait` had no `:return_title` branch, so it fell
# into the generic "background: resume" default and a Parallel Process's own
# Return to Title Screen silently never happened at all.
check 'Return to Title Screen issued from a Parallel Process also hands control back' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4) # Parallel Process
  par.event_commands = [ECmd.new(ic::RETURN_TO_TITLE, [])]
  scene = new_scene({ 1 => event(2, 2, par) }, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  5.times { scene.update }
  ok parent.returned_to_title,
     'the app was told to return to the title screen from a Parallel Process too'
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

check "Change Event Location's RPG2003 facing sub-parameter snaps another " \
      'event to face too' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # auto-start: place event 2 at (5, 3), facing down
  auto.event_commands = [ECmd.new(ic::CHANGE_EVENT_LOCATION, [2, 0, 5, 3, 3])]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(1, 1, page) },
                    player: [5, 5])
  c = chars(scene)[2]
  c.direction = 8 # start facing up, so a no-op would be obvious
  5.times { scene.update }
  eq [5, 3], [c.x, c.y], 'the event was moved to the target tile'
  eq 2, c.direction, 'and snapped to face down (facing param 3 -> numpad 2)'
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

# Change Event Location / Trade Event Locations are #event_position's write-
# side siblings, both routed through #char_location/#set_char_location, and
# had the identical gap: only @events (the live/active-page list) was
# searched, so targeting a hidden (page condition unmet) or temporarily-
# erased event silently did nothing at all -- worse for Trade Event
# Locations, whose #apply_location_request aborts the *entire* swap
# (`return unless a && b`) the moment either side resolves to nil, so even
# the live participant failed to move. Verified against EasyRPG Player's
# actual C++ source: CommandChangeEventLocation and
# CommandTradeEventLocations (src/game_interpreter.cpp) both resolve their
# target(s) through the same unconditional-by-id Game_Interpreter::
# GetCharacter -> Game_Character::GetCharacter -> Game_Map::GetEvent chain
# #event_position's own fix already relies on, so RPG_RT genuinely
# repositions such an event's single, persistent backing object. Fixed by
# giving #char_location/#set_char_location the same @event_last_position
# fallback #event_id_at/#event_position already use, keeping
# @erased_event_positions in sync too for an erased target so #event_id_at
# answers correctly at the new tile afterward.
check 'Change Event Location repositions a hidden event, not just a live one' do
  ic = Game::Interpreter::Cmd
  hidden = page(trigger: 0)
  hidden.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 5)
  auto = page(trigger: 3) # auto-start: move hidden event 2 to (6, 6)
  auto.event_commands = [ECmd.new(ic::CHANGE_EVENT_LOCATION, [2, 0, 6, 6])]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(2, 2, hidden) },
                    player: [5, 5])
  5.times { scene.update }
  ok event_hashes(scene)[2].nil?, 'event 2 has no active page, so it is not on the map'
  eq 2, scene.event_id_at(6, 6), 'it was still repositioned, to its new tile'
  eq 0, scene.event_id_at(2, 2), 'and no longer answers at its old tile'
  pos = scene.event_position(2)
  eq [6, 6], [pos[:x], pos[:y]], 'and #event_position agrees'
end

check 'Trade Event Locations swaps a live event with a hidden one' do
  ic = Game::Interpreter::Cmd
  hidden = page(trigger: 0)
  hidden.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 5)
  auto = page(trigger: 3) # auto-start: swap this event (1) with hidden event 2
  auto.event_commands = [ECmd.new(ic::TRADE_EVENT_LOCATIONS, [10005, 2])]
  scene = new_scene({ 1 => event(2, 2, auto), 2 => event(6, 6, hidden) },
                    player: [5, 5])
  5.times { scene.update }
  a = chars(scene)[1]
  eq [6, 6], [a.x, a.y], "the live event took the hidden event's old tile " \
                         '(pre-fix, the whole swap silently aborted)'
  ok event_hashes(scene)[2].nil?, 'event 2 is still hidden'
  eq 2, scene.event_id_at(2, 2), "and now answers at event 1's old tile instead"
  eq 1, scene.event_id_at(6, 6),
     "its own old tile now answers for the live event that moved onto it"
end

check 'Change Event Location repositions an already-erased event too' do
  ic = Game::Interpreter::Cmd
  erasing = page(trigger: 3)
  erasing.event_commands = [
    ECmd.new(ic::ERASE_EVENT, []),
    ECmd.new(ic::WAIT, [0]), # let Erase Event actually apply before moving on
    ECmd.new(ic::CHANGE_EVENT_LOCATION, [1, 0, 7, 7]),
  ]
  scene = new_scene({ 1 => event(2, 1, erasing) }, player: [5, 5])
  10.times { scene.update }
  ok event_hashes(scene)[1].nil?, 'the event is erased'
  eq 1, scene.event_id_at(7, 7), 'it was still repositioned after erasure, to its new tile'
  eq 0, scene.event_id_at(2, 1), 'and no longer answers at the tile it was erased on'
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

check 'Change Map Tileset override does not survive save/Continue' do
  # Continue reconstructs a fresh Scene::Map from the saved Game::State alone
  # (RPG2k#continue_game); the override lives only on the old scene's
  # @tileset_id, which Game::State#to_h/#to_lsd have no field for, so it
  # cannot follow into the new scene -- the destination reverts to the map's
  # own configured tileset, matching RPG_RT.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::CHANGE_MAP_TILESET, [2])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  5.times { scene.update }
  eq 'cs2', scene.instance_variable_get(:@chipset).name, 'the override took effect'

  fresh = RPG2k::Scene::Map.new(scene.parent, scene.instance_variable_get(:@state))
  eq nil, fresh.instance_variable_get(:@tileset_id), 'no override on the fresh scene'
  eq 'cs', fresh.instance_variable_get(:@chipset).name,
     "the fresh scene rebuilds the chipset from the map's own tileset id"
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

check 'a message longer than four lines paginates' do
  scene = new_scene({})
  # Six 4-char lines: four fit on page one, two on page two.
  lines = %w[aaaa bbbb cccc dddd eeee ffff]
  scene.send(:open_message, lines, false)
  msg = scene.instance_variable_get(:@message)
  reveal = msg[:reveal]
  eq 2, msg[:pages], 'six lines make two pages'
  # Reveal up to the first page boundary (the synthetic :page pause).
  reveal.reveal_all
  pause = reveal.pending_pause
  ok pause && pause[:kind] == :page, 'the reveal stops at a page boundary'
  eq 16, reveal.revealed, 'the first four 4-char lines show before paging'
  eq 0, msg[:page], 'still on the first page'
  # A confirm advances to the next page and releases the boundary pause.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.send(:drive_message)
  RGSS::Input.reset
  eq 1, msg[:page], 'confirm paged to the second page'
  ok !reveal.pending_pause, 'no more page pauses after the last page'
  reveal.reveal_all
  ok reveal.done?, 'the whole message is revealed on the last page'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.send(:drive_message)
  RGSS::Input.reset
  ok !scene.instance_variable_get(:@message), 'the final confirm dismisses'
end

check 'a message of exactly four lines does not paginate' do
  scene = new_scene({})
  scene.send(:open_message, %w[aaaa bbbb cccc dddd], false)
  msg = scene.instance_variable_get(:@message)
  eq 1, msg[:pages], 'four lines is exactly one page'
  reveal = msg[:reveal]
  reveal.reveal_all
  ok !reveal.pending_pause, 'no page pause for a single-screen message'
end

check 'a paginated message only draws the current page' do
  scene = new_scene({})
  lines = %w[aaaa bbbb cccc dddd eeee ffff]
  scene.send(:open_message, lines, false)
  msg = scene.instance_variable_get(:@message)
  reveal = msg[:reveal]
  reveal.reveal_all # sit on page one's boundary
  # On page zero only the first four lines are drawn; #draw_message_contents
  # slices the reveal to the page, so line five (index 4) is not yet shown.
  scene.send(:draw_message_contents)
  eq 16, reveal.revealed, 'page one holds the first four lines'
  # Page forward and confirm the reveal point does not regress.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.send(:drive_message)
  RGSS::Input.reset
  eq 1, msg[:page], 'paged to two'
  reveal.reveal_all
  eq 24, reveal.revealed, 'page two reveals the remaining two lines'
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

def show_text_then_choices(text)
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_MESSAGE, [], indent: 0, string: text),
    ECmd.new(ic::SHOW_CHOICES, [0], indent: 0), # cancel forbidden
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes'),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'no'),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  12.times { scene.update; break if scene.instance_variable_get(:@message) }
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # completes the reveal; window stays open
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # a Show Choices follows directly, so it keeps the window open
  RGSS::Input.reset
  choice_msg = nil
  8.times do
    scene.update
    choice_msg = scene.instance_variable_get(:@message)
    break if choice_msg && choice_msg[:choice]
  end
  choice_msg
end

check "a colour left open in a Show Text bleeds into an attached Show Choices list (yado.tk)" do
  choice_msg = show_text_then_choices('\c[2]hi')
  ok choice_msg && choice_msg[:choice], 'the choices appeared, merged into the same window'
  choice_segs = choice_msg[:seg_lines][choice_msg[:choice_start]..]
  ok choice_segs.all? { |segs| segs.all? { |s| s[:color] == 2 } },
     "both choice labels inherit the text's trailing colour with no reset in either"
end

check 'an explicit \c[0] in the Show Text stops the colour bleeding into Show Choices' do
  choice_msg = show_text_then_choices('\c[2]hi\c[0]')
  choice_segs = choice_msg[:seg_lines][choice_msg[:choice_start]..]
  ok choice_segs.all? { |segs| segs.all? { |s| s[:color] == 0 } },
     'the reset before the text ends carries a colour 0 into the choices, not 2'
end

check 'a \\^ in a standalone Show Choices label is confirmed already inert (yado.tk)' do
  # yado.tk: "\^ doesn't work inside Show Choices even though other codes
  # do." A standalone choice window (no preceding Show Text) is what
  # Game::Message.scan's own :auto_close flag is computed from (open_message
  # sums it across every label's scan) -- but #drive_message dispatches a
  # `choice: true` message straight into the Down/Up/C/B navigation branch
  # and never reaches #drive_text_message, the only place `reveal.auto_close?`
  # is ever read. A choice list can only ever close on player input, matching
  # real RPG_RT (choices always wait for a pick), so this stays open here too.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_CHOICES, [0], indent: 0),
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes\\^'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'no'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'the choice window opened'
  5.times { RGSS::Input.reset; scene.update }
  ok scene.instance_variable_get(:@message),
     'the \\^ in the first label did not auto-close the window with no input'
  eq 2, scene.instance_variable_get(:@message)[:count], 'both options are still listed'

  RGSS::Input.triggered = [RGSS::Input::C] # confirm option 0 ("yes\^")
  scene.update
  ok !scene.instance_variable_get(:@message),
     'the window closes on an actual player pick, same as any other choice'
end

check 'a \\^ in a choice merged onto a preceding Show Text stays inert there too' do
  # The merged path (Show Text immediately followed by Show Choices, kept in
  # one window -- see #append_choice_lines) never even records auto_close
  # from the choice labels' own scans, so the same yado.tk finding holds
  # there for a different structural reason than the standalone case above.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_MESSAGE, [], indent: 0, string: 'hi'),
    ECmd.new(ic::SHOW_CHOICES, [0], indent: 0),
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes\\^'),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'no'),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  12.times { scene.update; break if scene.instance_variable_get(:@message) }
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # completes the reveal; window stays open
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # a Show Choices follows directly, so it keeps the window open
  RGSS::Input.reset
  merged = nil
  8.times do
    scene.update
    merged = scene.instance_variable_get(:@message)
    break if merged && merged[:choice]
  end
  ok merged, 'the choices merged onto the still-open text window'
  5.times { RGSS::Input.reset; scene.update }
  ok scene.instance_variable_get(:@message),
     'the \\^ in the merged choice label did not auto-close the window either'
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

check 'a \\. pause holds the reveal for RPG_RT\'s real 16 frames, not the documented 15' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'a\\.b')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  frames = 0
  until reveal.pending_pause
    scene.update
    frames += 1
    break if frames > 20
  end
  ok reveal.pending_pause, 'the \\. pause is reached'
  # EasyRPG's own port comment: "Despite documentation saying 1/4 second,
  # RPG_RT waits for 16 frames" -- one frame past the documented/naive 15
  # (a quarter of 60fps), the same "natural reading is wrong" shape this
  # codebase already tracks for other RPG_RT quirks.
  held = 0
  until reveal.pending_pause.nil?
    scene.update
    held += 1
    break if held > 30
  end
  eq 16, held, 'RPG_RT holds a \\. pause for 16 frames, not the documented 15'
end

check 'a \\. pause at typing speed 20 holds for 20 frames, not a flat 16' do
  # EasyRPG's own comment calls this "a bug(??)": `SetWaitForNonPrintable(16
  # + Utils::Clamp(speed - 16, 0, 4))`, where `speed` is whatever `\s[n]`
  # (1..20) is in effect when the `\.` is reached, not a fixed 16. Speed 20
  # stretches the quarter-pause by its full +4 (`clamp(20-16, 0, 4) = 4`).
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: '\\s[20]a\\.b')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  frames = 0
  until reveal.pending_pause
    scene.update
    frames += 1
    break if frames > 30
  end
  ok reveal.pending_pause, 'the \\. pause is reached'
  held = 0
  until reveal.pending_pause.nil?
    scene.update
    held += 1
    break if held > 30
  end
  eq 20, held, 'speed 20 stretches the quarter-pause to 20 frames (16 + 4), not a flat 16'
end

check 'a \\| pause holds the reveal for RPG_RT\'s real 61 frames, not the documented 60' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'a\\|b')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  frames = 0
  until reveal.pending_pause
    scene.update
    frames += 1
    break if frames > 20
  end
  ok reveal.pending_pause, 'the \\| pause is reached'
  # EasyRPG's own port comment: "Despite documentation saying 1 second,
  # RPG_RT waits for 61 frames" -- one frame past the documented/naive 60.
  held = 0
  until reveal.pending_pause.nil?
    scene.update
    held += 1
    break if held > 70
  end
  eq 61, held, 'RPG_RT holds a \\| pause for 61 frames, not the documented 60'
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

check '\\s[n] slows the message typewriter; a higher n takes longer to fully reveal' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # "ab" reveals at the default speed, then \s[4] slows the rest ("cdefgh").
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'ab\\s[4]cdefgh')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  # At the plain 2 chars/frame rate all 8 characters would be fully revealed
  # within 4 frames; a message that drops \s[] outright (the pre-fix
  # behaviour) reveals at that same flat rate regardless of the code, so it
  # would already be done here too.
  6.times { RGSS::Input.reset; scene.update }
  ok !reveal.done?, '\\s[4] slows the reveal well past where the plain rate would finish'
  30.times { RGSS::Input.reset; scene.update }
  ok reveal.done?, 'the slowed reveal still finishes given enough frames'
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

check 'a bystander event holds still during an open message by default' do
  # yado.tk: "Autorun blocks other events too, unless 'move other events
  # during message wait' is on" -- Message Options' own continue_events flag
  # (LCF field 44) defaults off, so a bystander's own custom route must not
  # advance at all while the message stays open (no input pressed).
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi')]
  mover = page(x_move_type: Game::MoveType::CUSTOM,
              route: move_route([R::MOVE_RIGHT] * 3, repeat: false))
  scene = new_scene({ 1 => event(2, 2, auto), 2 => event(0, 4, mover) },
                    player: [5, 5])
  msg = open_msg(scene)
  ok msg, 'message window opened'
  start_x = chars(scene)[2].x
  20.times { scene.update }
  eq start_x, chars(scene)[2].x,
     'a bystander event must hold still while the message is open by default'
  ok scene.instance_variable_get(:@message), 'the message should still be open (no input pressed)'
end

check 'Message Options "move other events" lets a bystander event keep walking while the message stays open' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MESSAGE_OPTIONS, [0, 0, 0, 1]), # continue_events on (param3 = 1)
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
  ]
  mover = page(x_move_type: Game::MoveType::CUSTOM,
              route: move_route([R::MOVE_RIGHT] * 3, repeat: false))
  scene = new_scene({ 1 => event(2, 2, auto), 2 => event(0, 4, mover) },
                    player: [5, 5])
  msg = open_msg(scene)
  ok msg, 'message window opened'
  start_x = chars(scene)[2].x
  20.times { scene.update }
  ok chars(scene)[2].x > start_x,
     "the bystander event should have advanced east while the message stayed " \
     "open, got #{chars(scene)[2].x}"
  ok scene.instance_variable_get(:@message), 'the message should still be open (no input pressed)'
end

check '"move other events" during a message never lets a bystander start a second event' do
  # There is only one foreground @interpreter, already busy with this
  # message -- an event-touch (trigger 2) bystander approaching the player
  # while continue_events is on must still stop adjacent without starting its
  # own commands (see #move_autonomous's allow_trigger), the same way a plain
  # event-touch approach behaves when nothing else is running (see 'event-
  # touch (trigger 2): an event walking into the player runs it' above).
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MESSAGE_OPTIONS, [0, 0, 0, 1]), # continue_events on
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
  ]
  toucher = page(x_move_type: Game::MoveType::TOWARD, trigger: 2, frequency: 8)
  toucher.event_commands = [ECmd.new(ic::CONTROL_SWITCHES, [0, 9, 9, 0])]
  scene = new_scene({ 1 => event(5, 4, auto), 2 => event(3, 0, toucher) },
                    player: [0, 0])
  st = scene.instance_variable_get(:@state)
  msg = open_msg(scene)
  ok msg, 'message window opened'
  20.times { scene.update }
  ok !st.switches[9],
     "the toucher's own commands must not run while the message interpreter is still busy"
  ch = chars(scene)[2]
  eq [1, 0], [ch.x, ch.y], 'the toucher still approached and stopped adjacent to the player'
  ok scene.instance_variable_get(:@message), 'the original message must still be the one open'
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
  # The face is cropped once out of the FaceSet sheet at message-open time
  # (see #build_face_cell): a single blit of cell 2 (the third 48x48 tile,
  # x=96) into the dedicated 48x48 face bitmap, not a per-frame crop.
  calls = msg[:face].blt_calls
  eq 1, calls.length, 'an unmirrored face is cropped in one blit'
  x, y, _src, rect = calls.first
  eq [0, 0, 96, 0, 48, 48], [x, y, rect.x, rect.y, rect.width, rect.height],
     'cropped cell 2 straight into the corner of the dedicated face bitmap'
  ok msg[:text_x] > 0, 'text is inset to the right of a left-side face'
end

check 'Change Face Graphic with the mirror flag draws a horizontally-flipped face' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::CHANGE_FACE, [0, 0, 1], string: 'Faces1'), # cell 0, left side, mirrored
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = open_msg(scene)
  ok msg, 'message window opened'
  calls = msg[:face].blt_calls
  # RGSS::Bitmap#blt has no flip of its own, so a mirrored face is built one
  # source column at a time instead of a single crop (see #build_face_cell).
  eq 48, calls.length, 'a mirrored face is built one column at a time, not one crop'
  first_x, _y, _src, first_rect = calls.first
  last_x, _ly, _lsrc, last_rect = calls.last
  eq 47, first_x, 'the sheet\'s leftmost column lands at the rightmost destination column'
  eq 0, first_rect.x, 'the sheet\'s leftmost column lands at the rightmost destination column'
  eq 0, last_x, 'the sheet\'s rightmost column lands at the leftmost destination column'
  eq 47, last_rect.x, 'the sheet\'s rightmost column lands at the leftmost destination column'
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

# yado.tk: text beyond a line's own display-limit width is silently truncated,
# not wrapped. #clip_text_to_width is what now enforces that boundary itself
# (see its own comment on #draw_message_run) rather than relying on the
# contents bitmap's own edge, which -- unlike here -- this stub's own
# #text_size (always a flat 0px) can't exercise directly, so this drives the
# helper with its own small fixed-width stand-in canvas instead.
check '#clip_text_to_width slices a run at the exact character its own text_size stops fitting' do
  scene = new_scene({})
  canvas = Object.new
  def canvas.text_size(s); RGSS::Rect.new(0, 0, s.length * 6, 0); end
  eq 'Hello', scene.send(:clip_text_to_width, canvas, 'Hello, World!', 30),
     'exactly 5 characters (30px) fit; the 6th would overflow'
  eq 'Hello, World!', scene.send(:clip_text_to_width, canvas, 'Hello, World!', 999),
     'a run that already fits is returned unchanged, untouched'
  eq '', scene.send(:clip_text_to_width, canvas, 'Hello', 0), 'no width at all clips to nothing'
end

# The end-to-end case #clip_text_to_width exists for: a right-side Face
# Graphic leaves FACE_SIZE + FACE_MARGIN (52px) of *bitmap* width beyond the
# message layout's own intended text boundary for the portrait -- before this
# fix, an overflowing run kept drawing straight through that gap and over the
# face instead of disappearing at the boundary. Re-renders with a realistic
# fixed-width #text_size patched onto the message's own contents bitmap (the
# shared stub's own #text_size is a flat 0px, which would never trigger a
# clip either way) and a fully-revealed 60-character line, well past the
# window's own available text width at 6px/character.
check "a message line beyond its own display width is truncated, not left to bleed onto a right-side face" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  long_line = 'A' * 60
  auto.event_commands = [
    ECmd.new(ic::CHANGE_FACE, [0, 1, 0], string: 'Faces1'), # right-side face
    ECmd.new(ic::SHOW_MESSAGE, [], string: long_line),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  msg = open_msg(scene)
  ok msg, 'message window opened'
  c = msg[:contents]
  def c.text_size(s); RGSS::Rect.new(0, 0, s.length * 6, 0); end
  msg[:reveal].reveal_all
  scene.send(:draw_message_contents)
  drawn = c.draw_calls.last
  ok drawn, 'the line was actually drawn'
  text = drawn[4]
  eq msg[:text_w] / 6, text.length,
     "clipped to exactly as many characters as fit #{msg[:text_w]}px, not the full #{long_line.length}"
  ok text.length < long_line.length, 'the overflowing tail was dropped, not left to draw over the face'
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

check 'a Change Encounter Rate override does not survive a teleport' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::CHANGE_ENCOUNTER_RATE, [4]),
    ECmd.new(ic::TELEPORT, [1, 4, 3]),
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  scene.update
  eq 4, st.encounter_rate, 'the override took effect before the teleport'
  20.times { scene.update }
  eq 1, st.map_id, 'teleported'
  eq nil, st.encounter_rate,
     'the destination reverts to the map\'s own encount_steps, matching Chipset/' \
     'Panorama/Tile Replacement -- an override does not survive any map change'
  eq 25, scene.send(:current_encounter_steps),
     "current_encounter_steps falls back to the map tree node's own setting again"
end

# A parent whose load_map raises for one specific "deleted" map id (mirroring
# RPG2k#load_map's bare File.open against a stale/removed Map####.lmu) and
# otherwise behaves like fake_parent's normal empty-map stub.
def missing_map_parent(db, missing_id)
  FakeParent.new(db) do |id|
    if id == missing_id
      raise Errno::ENOENT, "Map#{format('%04d', missing_id)}.lmu"
    else
      fake_map(id, {})
    end
  end
end

check 'a Transfer Player naming a deleted map reports a diagnostic and stays put' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::TELEPORT, [999, 4, 3])]
  db = fake_db(nil, nil, 0, 0)
  state = Game::State.new(fake_party([]), 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  parent = missing_map_parent(db, 999)
  scene = RPG2k::Scene::Map.new(parent, state)
  out = capture_stderr { 20.times { scene.update } }
  ok out.include?('[RPG2k] Teleport:') && out.include?('Map0999.lmu'),
     "expected a [RPG2k] Teleport diagnostic naming the missing file, got: #{out.inspect}"
  eq 1, state.map_id, 'the party never left the map it was already on'
  eq [0, 0], [state.x, state.y], 'the player position is untouched by the failed teleport'
end

check 'Recall to Location naming a deleted map reports a diagnostic and stays put' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::CONTROL_VARS, [0, 1, 1, 0, 0, 999]), # var1 = the deleted map id
    ECmd.new(ic::CONTROL_VARS, [0, 2, 2, 0, 0, 4]),   # var2 = x 4
    ECmd.new(ic::CONTROL_VARS, [0, 3, 3, 0, 0, 3]),   # var3 = y 3
    ECmd.new(ic::RECALL_LOCATION, [1, 2, 3]),
  ]
  db = fake_db(nil, nil, 0, 0)
  state = Game::State.new(fake_party([]), 1, 5, 6)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  parent = missing_map_parent(db, 999)
  scene = RPG2k::Scene::Map.new(parent, state)
  out = capture_stderr { 20.times { scene.update } }
  ok out.include?('[RPG2k] Teleport:') && out.include?('Map0999.lmu'),
     "expected a [RPG2k] Teleport diagnostic naming the missing file, got: #{out.inspect}"
  eq 1, state.map_id, 'the party never left the map it was already on'
  eq [5, 6], [state.x, state.y], 'the player position is untouched by the failed recall'
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

check 'Store Event ID resolves two events on the same tile to the highest id' do
  # A real map's event table is id-indexed and always iterates ascending
  # (LCF::Array2D#each), so #rebuild_event_tiles -- last write to a shared
  # tile wins -- always leaves the *highest*-id event as what a query
  # resolves to, matching yado.tk's "Get Event ID at coordinates on
  # overlapping events returns the highest id, not lowest/topmost-drawn".
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::STORE_EVENT_ID, [0, 3, 1, 2])]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(3, 1, page),
                      5 => event(3, 1, page) },
                    player: [5, 5])
  10.times { scene.update }
  st = scene.instance_variable_get(:@state)
  eq 5, st.variables[2], 'the higher-id event wins the shared tile, not the lower one'
end

check 'Store Event ID still resolves a temporarily-erased event at its last tile' do
  # yado.tk: "Get Event ID at Location" still returns an id for a
  # temporarily-erased event, unlike collision/drawing, which #erase_event
  # already drops it from (@event_tiles). Event 2 erases itself on its own
  # autostart page; nothing else ever stands on (3, 1).
  ic = Game::Interpreter::Cmd
  erasing = page(trigger: 3)
  erasing.event_commands = [ECmd.new(ic::ERASE_EVENT, [])]
  scene = new_scene({ 2 => event(3, 1, erasing) }, player: [5, 5])
  10.times { scene.update }
  eq 0, event_hashes(scene).size, 'the event is gone from the live list'
  eq 2, scene.event_id_at(3, 1), 'its id still answers the query at its last tile'
  eq 0, scene.event_id_at(0, 0), 'an ordinary empty tile still answers 0'
end

check 'a temporarily-erased event still outranks a lower-id live event on the same tile' do
  ic = Game::Interpreter::Cmd
  erasing = page(trigger: 3)
  erasing.event_commands = [ECmd.new(ic::ERASE_EVENT, [])]
  scene = new_scene({ 5 => event(3, 1, erasing), 2 => event(3, 1, page) },
                    player: [5, 5])
  10.times { scene.update }
  eq 5, scene.event_id_at(3, 1),
     'the erased higher id still wins over the live lower-id event'
end

check 'a live event still outranks a lower-id temporarily-erased event on the same tile' do
  ic = Game::Interpreter::Cmd
  erasing = page(trigger: 3)
  erasing.event_commands = [ECmd.new(ic::ERASE_EVENT, [])]
  scene = new_scene({ 2 => event(3, 1, erasing), 5 => event(3, 1, page) },
                    player: [5, 5])
  10.times { scene.update }
  eq 5, scene.event_id_at(3, 1),
     'the live higher id wins over the erased lower-id event'
end

check 'Store Event ID resolves an event whose page conditions have never been met' do
  # yado.tk's "Get Event ID at Location" claim had a second, previously-open
  # half: an event whose current page conditions simply aren't met never gets
  # a Game::Character built at all (#build_events skips it outright), so
  # there was no position to answer from. Verified against EasyRPG Player's
  # actual C++ source rather than guessed at: real RPG_RT keeps one
  # Game_Event object per map event for the whole visit regardless of page
  # state (Game_Event::RefreshPage, src/game_event.cpp, clears the active
  # page on a no-match but never touches x/y), and
  # Game_Interpreter::CommandStoreEventID's own lookup,
  # Game_Map::GetEventAt(x, y, /* require_active */ false) (src/game_map.cpp),
  # explicitly passes false so an inactive event still matches by position.
  hidden = page(trigger: 0)
  hidden.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 5)
  scene = new_scene({ 2 => event(2, 2, hidden) }, player: [0, 0])
  5.times { scene.update }
  ok event_hashes(scene)[2].nil?, 'the condition never held, so nothing is on the map'
  eq 2, scene.event_id_at(2, 2), 'it still answers at its raw map placement'
  eq 0, scene.event_id_at(0, 0), 'an ordinary empty tile still answers 0'
end

check 'Store Event ID resolves a hidden event at wherever it stood before its page stopped matching' do
  # Distinguishes the fallback from a naive "always answer at the raw spawn
  # tile": the event walks two tiles east via a Custom move route while its
  # page is active, then the page's own gating switch turns off -- it should
  # answer at its last-known (4, 2), not back at its (2, 2) spawn tile.
  gated = page(trigger: 0, x_move_type: Game::MoveType::CUSTOM,
               route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false))
  gated.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 5)
  scene = new_scene({ 2 => event(2, 2, gated) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.switches[5] = true
  40.times { scene.update } # walks right twice and settles at (4, 2)
  eq [4, 2], [chars(scene)[2].x, chars(scene)[2].y], 'the route finished'

  st.switches[5] = false
  5.times { scene.update }
  ok event_hashes(scene)[2].nil?, 'the condition no longer holds, so it drops off the map'
  eq 2, scene.event_id_at(4, 2), 'it still answers at its last-known tile, not its spawn tile'
  eq 0, scene.event_id_at(2, 2), 'its old spawn tile does not still answer for it'
end

check 'a hidden event still outranks a lower-id live event sharing its old tile' do
  gated = page(trigger: 0)
  gated.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 5)
  scene = new_scene({ 5 => event(3, 1, gated), 2 => event(3, 1, page) }, player: [0, 0])
  5.times { scene.update }
  eq 5, scene.event_id_at(3, 1),
     'the higher-id hidden event still wins over the live lower-id event'
end

# #event_position (Control Variables' "Characters" X/Y/Direction operand and
# Conditional Branch's "Character Direction is" test) used to search only
# @events -- the live/active-page list -- and answer nil for anything else,
# unlike its sibling #event_id_at just above, which already falls back to
# @event_last_position for the identical reason. Verified against EasyRPG
# Player's actual C++ source: Game_Interpreter::GetCharacter ->
# Game_Character::GetCharacter -> Game_Map::GetEvent (src/game_map.cpp) is an
# unconditional lookup by id with no active-state filter, and
# CommandEraseEvent (src/game_interpreter.cpp) only flips the event's own
# active flag -- it never removes the Game_Event from the map's own event
# list -- so ControlVariables::Event's X/Y/Direction cases
# (src/game_interpreter_control_variables.cpp) and Conditional Branch's own
# "Orientation of char" case keep reading a real, frozen last position/facing
# off it rather than nothing.
check '#event_position resolves a hidden event at wherever it stood before ' \
      'its page stopped matching, not nil' do
  gated = page(trigger: 0, x_move_type: Game::MoveType::CUSTOM,
               route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false))
  gated.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 5)
  scene = new_scene({ 2 => event(2, 2, gated) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.switches[5] = true
  40.times { scene.update } # walks right twice and settles at (4, 2), facing right
  eq [4, 2], [chars(scene)[2].x, chars(scene)[2].y], 'the route finished'

  st.switches[5] = false
  5.times { scene.update }
  ok event_hashes(scene)[2].nil?, 'the condition no longer holds, so it drops off the map'
  pos = scene.event_position(2)
  ok pos, 'still answers instead of nil'
  eq [4, 2], [pos[:x], pos[:y]], 'at its last-known tile, not its spawn tile'
  eq 6, pos[:direction], 'and its last-known facing (right, from the MOVE_RIGHT route)'
end

check '#event_position resolves a temporarily-erased event at its frozen ' \
      'position for the rest of the visit' do
  ic = Game::Interpreter::Cmd
  erasing = page(trigger: 3)
  erasing.event_commands = [ECmd.new(ic::ERASE_EVENT, [])]
  scene = new_scene({ 3 => event(2, 1, erasing) }, player: [5, 5])
  10.times { scene.update }
  ok event_hashes(scene)[3].nil?, 'the event is erased'
  pos = scene.event_position(3)
  ok pos, 'still answers instead of nil'
  eq [2, 1], [pos[:x], pos[:y]], 'at the tile it was erased on'
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
  one_shot_auto(auto, 9012)
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

check 'Set Move Route targeting a currently-hidden map event freezes Proceed With Movement (yado.tk)' do
  ic = Game::Interpreter::Cmd
  hidden = page(trigger: 0)
  hidden.condition = OpenStruct.new(flags: Game::EventPage::SWITCH_A, switch_a_id: 5)
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MOVE_EVENT,
             [2, 4, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]),
    ECmd.new(ic::PROCEED_WITH_MOVEMENT, []),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(0, 1, hidden) },
                    player: [5, 5])
  st = scene.instance_variable_get(:@state)
  ok event_hashes(scene)[2].nil?, "event 2's own page never satisfies its condition"

  300.times { scene.update } # far more than the freq-4 route would ever need
  ok !st.switches[1],
     'Proceed With Movement never resumes -- the target never existed to move'

  st.switches[5] = true # the event's own condition becomes true too late to help
  scene.send(:refresh_event_pages)
  50.times { scene.update }
  ok !st.switches[1],
     'the freeze does not clear once the event later appears -- the request was dropped, not queued'
end

check 'Set Move Route targeting a genuinely nonexistent event id does not freeze' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MOVE_EVENT,
             [99, 4, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]),
    ECmd.new(ic::PROCEED_WITH_MOVEMENT, []),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(0, 4, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)

  20.times { scene.update }
  ok st.switches[1],
     'a Move Event with no matching event id at all is a plain no-op, not the hidden-event freeze'
end

check "Proceed With Movement also waits on a vehicle's forced route" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MOVE_EVENT,
             [10002, 4, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]),
    ECmd.new(ic::PROCEED_WITH_MOVEMENT, []),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  one_shot_auto(auto, 9013)
  scene = new_scene({ 1 => event(0, 4, auto) }, player: [5, 5], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1

  10.times { scene.update } # mid-route: still sailing, switch not yet flipped
  ok boat.x < 3, "route still in progress, at x=#{boat.x}"
  ok !st.switches[1],
     "the command after Proceed With Movement waits on the vehicle's own route"

  200.times { scene.update } # enough frames for the freq-4 route to finish
  eq 3, boat.x, 'the boat reached the end of its route'
  ok st.switches[1], 'the interpreter resumed and ran the next command'
end

check "a wandered map event's position and facing survive a save/load, but " \
      'reset to their own page default on an ordinary map re-visit' do
  # docs/TODO.md's "Save / Load persistence -- consolidated master list":
  # runtime state that does *not* survive a plain map re-visit (leave and
  # return, no save involved) explicitly includes "map event positions
  # (reset to their default page-1 placement)" -- but the same list's "does
  # not survive a save/load specifically" half never names event positions,
  # meaning they are expected to survive one, matching real RPG_RT's own
  # SaveMapEvent chunk (x/y/direction, confirmed against EasyRPG's
  # Game_Event -- see Game::State#map_event_positions). This codebase had no
  # mechanism at all for the save/load half: Scene::Map#build_event always
  # built a fresh Game::Character from the map's own ev.x/ev.y, so even a
  # same-map Save-then-Continue snapped every wandered NPC back to its
  # editor spawn tile.
  ic = Game::Interpreter::Cmd
  # Auto-start event 1 forces event 2 to walk two tiles east and turn to
  # face down, blocking on Proceed With Movement so the route has actually
  # landed by the time #update returns control.
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MOVE_EVENT,
             [2, 8, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::FACE_DOWN]),
    ECmd.new(ic::PROCEED_WITH_MOVEMENT, []),
  ]
  one_shot_auto(auto, 9014)
  events = { 1 => event(0, 4, auto), 2 => event(1, 1, page) }
  db = fake_db
  state = Game::State.new(fake_party, 1, 5, 5)
  state.map = fake_map(1, events)
  # A map_maker that hands back the same event table on every load (rather
  # than the default fake_parent's empty map), so event 2 still exists post-
  # teleport for part two's reset assertion to mean anything.
  parent = FakeParent.new(db) { |id| fake_map(id, events) }
  scene = RPG2k::Scene::Map.new(parent, state)
  40.times { scene.update }
  c = chars(scene)[2]
  eq 3, c.x, 'the forced route walked event 2 two tiles east'
  eq 1, c.y, 'staying on its row'
  eq 2, c.direction, 'and turned to face down at the end of the route'

  # Part one: a save/load restores exactly that wandered spot.
  restored = Game::State.load(db, Marshal.load(Marshal.dump(state.to_h)))
  restored.map = fake_map(1, events)
  fresh = RPG2k::Scene::Map.new(FakeParent.new(db) { |id| fake_map(id, events) },
                                restored)
  rc = chars(fresh)[2]
  eq [3, 1, 2], [rc.x, rc.y, rc.direction],
     'a fresh Scene::Map built from the saved state keeps the wandered spot, ' \
     'not the map default'

  # Part two: an ordinary re-visit (leave and return, no save involved) is
  # documented to reset every event to its own page default instead -- a
  # Transfer Player to this same map id must not carry the wandered position
  # over the way a save/load does.
  scene.send(:perform_teleport, [1, 5, 5, 0]) # leave and return to the same map
  tc = chars(scene)[2]
  eq [1, 1], [tc.x, tc.y],
     'an ordinary map re-visit resets the event to its own default ' \
     'placement, unlike a genuine save/load'
end

check "a page's own custom move route resumes at its saved cursor across a save/load, not from the top" do
  # docs/TODO.md's "Save / Load persistence -- consolidated master list": "a
  # map event's move route/execution point if paused mid-way" is documented
  # to survive a save/load -- Game::State#map_event_positions' own comment
  # explicitly flagged the move-route index as "this codebase does not
  # attempt to round-trip yet" even after the position/facing half was
  # fixed. Scene::Map#build_event always built a fresh Game::MoveRoute at
  # index 0 from the page's own move_route field, with no override path at
  # all, so a save taken mid-way through a non-repeating custom route
  # restarted it from the very first command on Continue instead of
  # resuming where it actually left off.
  ic = Game::Interpreter::Cmd
  ev = event(0, 1, page(x_move_type: Game::MoveType::CUSTOM,
                        route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT,
                                           R::MOVE_RIGHT, R::MOVE_RIGHT],
                                          repeat: false)))
  db = fake_db
  events = { 1 => ev }
  state = Game::State.new(fake_party, 1, 5, 5)
  state.map = fake_map(1, events)
  parent = FakeParent.new(db) { |id| fake_map(id, events) }
  scene = RPG2k::Scene::Map.new(parent, state)

  15.times { scene.update } # partway through the 4-tile route
  e = scene.instance_variable_get(:@events).first
  c = e[:char]
  ok c.x > 0 && c.x < 4, "expected partial progress into the route, got x=#{c.x}"
  ok !e[:route].done?, 'the route has not finished yet'
  saved_index = e[:route].index

  restored = Game::State.load(db, Marshal.load(Marshal.dump(state.to_h)))
  restored.map = fake_map(1, events)
  fresh = RPG2k::Scene::Map.new(FakeParent.new(db) { |id| fake_map(id, events) },
                                restored)
  re = fresh.instance_variable_get(:@events).first
  eq saved_index, re[:route].index,
     'the restored route resumes at the exact command it was on, not index 0'
  eq c.x, re[:char].x, 'the character position agrees (the already-fixed position half)'

  # Driving the restored scene onward finishes only the *remaining* distance,
  # not the full 4-tile route replayed from scratch.
  40.times { fresh.update }
  fc = fresh.instance_variable_get(:@events).first[:char]
  eq 4, fc.x, 'the route completes to its actual endpoint from the resumed cursor'
end

check "a page's own custom-route index does not leak onto an unrelated page's " \
      'different route during a live, in-place page reselection' do
  # The save/load restore above must not also fire during Scene::Map's own
  # *live* rebuild (#rebuild_events_preserving_positions, triggered whenever
  # any event's page selection changes mid-visit): that path already
  # restores a bystander event's own *unchanged* route with full live
  # fidelity a few lines further down in the very same method (the real
  # running Game::MoveRoute object, not a coarser saved index), and a route
  # that genuinely changed this rebuild -- a different page entirely -- must
  # restart at its own index 0, not seek into Game::State
  # #map_event_route_index's most recently recorded index for the event id,
  # which still describes the *old* page's route, not the new one.
  page1 = page(x_move_type: Game::MoveType::CUSTOM,
              route: move_route([R::MOVE_RIGHT, R::MOVE_RIGHT,
                                 R::MOVE_RIGHT, R::MOVE_RIGHT], repeat: false))
  page2 = page(x_move_type: Game::MoveType::CUSTOM,
              route: move_route([R::MOVE_LEFT], repeat: true))
  ev = two_page_event(0, 1, 5, page1, page2)
  scene = new_scene({ 1 => ev }, player: [5, 4])
  st = scene.instance_variable_get(:@state)

  20.times { scene.update } # partway through page 1's own route
  e = scene.instance_variable_get(:@events).first
  ok e[:route].index > 0, "expected partial progress into page 1's route, got index #{e[:route].index}"

  st.switches[5] = true
  scene.update # page 2's condition now holds: an in-place page reselection runs

  e2 = scene.instance_variable_get(:@events).first
  ok !e2[:page].equal?(e[:page]), 'page 2 is now the active page'
  eq 0, e2[:route].index,
     "page 2's own different route starts at its own index 0, not a stale " \
     "index carried over from page 1's unrelated route"
end

check "Proceed With Movement blocks a Parallel Process's own interpreter, not just the foreground's" do
  # docs/TODO.md, `2k/09_bug/017_heiretu_totyu_end/hei_mukou.htm`: Set Move
  # Route + "wait for completion" is documented to block whichever event's
  # own Event Content issued it until every targeted character's route
  # finishes -- the same rule already covered above for a foreground
  # Autorun's own Proceed With Movement, but #drive_parallel_wait had no
  # :movement case at all, so a Common Event Parallel Process issuing the
  # identical command fell into the generic "background: ignore message/
  # choice/teleport requests" #resume branch instead and read it as a plain
  # fire-and-forget no-op regardless of "wait for completion".
  ic = Game::Interpreter::Cmd
  # Gated on switch 2, which the process itself turns off right after Proceed
  # With Movement resumes -- otherwise a Parallel Process loops its command
  # list forever by design, and a second lap's own Move Event would replace
  # the still-settling forced route with a fresh one before the 200-frame
  # budget below could tell "resumed on time" apart from "resumed early".
  ce = OpenStruct.new(start_term: 4, need_flag: true, switch_id: 2,
                      event: [
                        ECmd.new(ic::MOVE_EVENT,
                                 [2, 4, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]),
                        ECmd.new(ic::PROCEED_WITH_MOVEMENT, []),
                        ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 1]), # gate off: one lap only
                        ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
                      ])
  scene = new_scene({ 2 => event(0, 1, page) }, common: { 1 => ce }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  st.switches[2] = true
  c = chars(scene)[2]

  10.times { scene.update } # mid-route: still moving, switch not yet flipped
  ok c.x < 3, "route still in progress, at x=#{c.x}"
  ok !st.switches[1],
     'Proceed With Movement issued by a Parallel Process must wait too, not resume immediately'

  200.times { scene.update } # enough frames for the freq-4 route to finish
  eq 3, c.x, 'the forced event reached the end of its route'
  ok st.switches[1], 'the Parallel Process resumed once the route actually finished'
end

check "Erase Screen's own wait flag blocks a Parallel Process's own interpreter, " \
      'not just the foreground\'s' do
  # Same defect class as Proceed With Movement/Transfer Player above:
  # #drive_parallel_wait had no :screen case at all, so Erase/Show/Tint/
  # Flash/Pan/Shake Screen issued from a Parallel Process fell into the
  # generic "background: ignore ..." #resume branch and read as fire-and-
  # forget regardless of the command's own wait flag -- the fade itself
  # already ran (#apply_interpreter_requests applies a parallel process's
  # own screen writes too, unaffected by this fix), only the wait never
  # actually held the process up.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 4)
  pg.event_commands = [
    ECmd.new(ic::ERASE_SCREEN, [0]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, pg) })
  st = scene.instance_variable_get(:@state)

  scene.update # runs Erase Screen -> suspends on :screen
  ok !st.switches[1],
     'the Parallel Process must wait too, not resume immediately'
  ok st.screen.fading?, 'the fade is in progress'

  40.times { scene.update } # the scene advances Game::Screen each frame
  ok st.screen.erased?, 'the screen fully erased'
  ok st.switches[1], 'the Parallel Process resumed once the fade settled'
end

check "Move Picture's own wait flag blocks a Parallel Process's own interpreter, " \
      'not just the foreground\'s' do
  # Same defect class as the Erase Screen check just above, for the :picture
  # wait kind #drive_parallel_wait also had no case for.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 4)
  pg.event_commands = [
    ECmd.new(ic::MOVE_PICTURE,
             [1, 0, 200, 200, 0, 100, 0, 0, 100, 100, 100, 100, 0, 0, 10, 1]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, pg) })
  st = scene.instance_variable_get(:@state)
  st.pictures[1] = Game::Picture.new(1, x: 100, y: 100)

  scene.update # runs Move Picture -> suspends on :picture
  ok !st.switches[1],
     'the Parallel Process must wait too, not resume immediately'
  ok st.pictures[1].moving?, 'the picture is still moving toward its target'

  70.times { scene.update } # 10 tenths (60 frames) is plenty
  eq [200, 200], [st.pictures[1].x, st.pictures[1].y],
     'the picture reached its target'
  ok st.switches[1], 'the Parallel Process resumed once the move settled'
end

check "Flash Sprite's own wait flag blocks a Parallel Process's own interpreter, " \
      'not just the foreground\'s' do
  # Same defect class as the two checks just above, for the :sprite_flash
  # wait kind #drive_parallel_wait also had no case for.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 4)
  # 1 tenth (6 frames) with the wait flag set, then a switch flip that only
  # runs once the flash is over. The page has no gate of its own, so once the
  # switch flips the loop immediately re-issues the same Flash Sprite for its
  # next lap -- fine here, since only the *first* lap's timing is asserted,
  # not that the hero stops flashing for good.
  pg.event_commands = [
    ECmd.new(ic::FLASH_SPRITE, [10001, 31, 0, 0, 31, 1, 1]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)

  scene.update # runs Flash Sprite -> suspends on :sprite_flash
  ok scene.instance_variable_get(:@player_flash), 'the hero is flashing'
  ok !st.switches[1], 'the Parallel Process must wait too, not resume immediately'

  4.times { scene.update } # still mid-flash (6-frame duration)
  ok !st.switches[1], 'still waiting partway through the flash'

  10.times { scene.update } # comfortably past the 6-frame decay
  ok st.switches[1], 'the Parallel Process resumed once the flash finished'
end

check "a Common Event Parallel Process's own Show Text now actually opens the shared message window" do
  # docs/TODO.md "Two message windows can never be shown simultaneously -- a
  # hard engine limit": #drive_parallel_wait had no :message case at all, so
  # a Parallel Process's own Show Text fell into the generic "background:
  # ignore message/choice requests" #resume branch and the interpreter
  # sailed straight past it -- no window ever appeared, and the command right
  # after it ran on the very next tick as if Show Text had been a no-op.
  ic = Game::Interpreter::Cmd
  ce = OpenStruct.new(start_term: 4, need_flag: false,
                      event: [
                        ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
                        ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
                      ])
  scene = new_scene({}, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)

  msg = open_msg(scene)
  ok msg, "the Parallel Process's own Show Text opened the shared message window"
  ok !st.switches[1],
     'the command after Show Text has not run yet -- the process is blocked on the window'

  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # complete the (short) reveal
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # dismiss
  ok !scene.instance_variable_get(:@message), 'message dismissed'
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[1], 'the Parallel Process resumed and ran the command after Show Text'
end

check "a Map Event Parallel Process's own Show Choices now actually opens the shared message window" do
  # Same defect class as Show Text just above, for the :choice wait kind.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 4)
  pg.event_commands = [
    ECmd.new(ic::SHOW_CHOICES, [0], indent: 0), # cancel forbidden
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'yes'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'no'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::END_BRANCH, [], indent: 0),
  ]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)

  msg = open_msg(scene)
  ok msg, "the Parallel Process's own Show Choices opened the shared message window"
  ok msg[:choice], 'the window is showing a choice list, not plain text'

  RGSS::Input.triggered = [RGSS::Input::C] # pick "yes" (index 0)
  scene.update
  ok !scene.instance_variable_get(:@message), 'the choice window closed on pick'
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[1], "the Parallel Process resumed into the picked choice's own branch"
  ok !st.switches[2], 'the other branch never ran'
end

check "a Parallel Process's own Show Text waits for the foreground's already-open " \
      'message window, then opens its own and resumes the right interpreter' do
  # The cross-interpreter half of the "two message windows" rule: whichever
  # interpreter -- foreground or a Parallel Process -- currently owns @message
  # holds it until dismissed; a second, different interpreter reaching its own
  # Show Text in the meantime must neither steal the window nor be dropped
  # (the pre-fix generic #resume branch's bug) but block and retry, then open
  # its own and resume *itself*, not whichever interpreter the window
  # happened to belong to first (#open_message's `interp:` -- see there).
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'first'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  parallel = page(trigger: 4)
  parallel.event_commands = [
    ECmd.new(ic::WAIT, [5]), # half a second: comfortably after 'first' opens
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'second'),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0]),
  ]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(0, 1, parallel) },
                    player: [5, 5])
  st = scene.instance_variable_get(:@state)

  msg = open_msg(scene)
  ok msg, "the foreground's own Show Text opened the message window first"

  40.times { scene.update } # the Parallel Process's own Wait elapses meanwhile
  ok scene.instance_variable_get(:@message),
     "the foreground's window is still the one open"
  ok !st.switches[2],
     "the Parallel Process's own Show Text must wait for the open window, not " \
     'be silently dropped'

  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # complete the reveal of 'first'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # dismiss 'first', resume the foreground
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[1], 'the foreground resumed and ran its own command after Show Text'

  msg2 = open_msg(scene)
  ok msg2, "the Parallel Process's own Show Text finally opened, now that the window is free"

  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # complete the reveal of 'second'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # dismiss 'second'
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[2],
     'the Parallel Process itself resumed (not the foreground) and ran its own command'
end

check "a Common Event Parallel Process's own standalone Input Number now actually opens the widget" do
  # docs/TODO.md "Left open: Input Number (:number) issued from a Parallel
  # Process is still silently dropped" -- #drive_parallel_wait had no :number
  # case at all (unlike the already-fixed :message/:choice above), so the
  # request fell into the generic "background: ignore..." #resume branch and
  # the interpreter sailed straight past it, the command right after it
  # running on the very next tick as if Input Number had been a no-op.
  ic = Game::Interpreter::Cmd
  ce = OpenStruct.new(start_term: 4, need_flag: false,
                      event: [
                        ECmd.new(ic::INPUT_NUMBER, [2, 5]),
                        ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
                      ])
  scene = new_scene({}, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)

  ni = nil
  12.times do
    scene.update
    ni = scene.instance_variable_get(:@number_input)
    break if ni
  end
  ok ni, "the Parallel Process's own Input Number opened the shared widget"
  ok !ni[:embedded], 'a standalone Input Number opens its own compact panel'
  ok !st.switches[1],
     'the command after Input Number has not run yet -- the process is blocked on the widget'

  RGSS::Input.triggered = [RGSS::Input::UP] # tens digit 0 -> 1 (value 10)
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C] # confirm
  scene.update
  ok !scene.instance_variable_get(:@number_input), 'the widget closed on confirm'
  5.times { RGSS::Input.reset; scene.update }
  eq 10, st.variables[5], 'the entered value landed in variable 5'
  ok st.switches[1], 'the Parallel Process resumed and ran the command after Input Number'
end

check "a Map Event Parallel Process's own Show Text + Input Number merges into the same window" do
  # The merged shape docs/TODO.md's same "Left open" note names explicitly:
  # "#open_number_input's standalone ... panel and its embedded-in-@message
  # follow-up are both foreground-only machinery." @message is not nil once
  # the process's own Show Text is still open awaiting this follow-up, so the
  # plain "block until @message is nil" guard the standalone case alone would
  # need is not enough here -- #open_message's own `@message[:interp].equal?
  # (it)` check (mirrored for Input Number) is what lets it recognise this as
  # its *own* window's follow-up rather than someone else's still-open one.
  ic = Game::Interpreter::Cmd
  pg = page(trigger: 4)
  pg.event_commands = [
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'enter a value'),
    ECmd.new(ic::INPUT_NUMBER, [2, 5]),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(2, 2, pg) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)

  msg = open_msg(scene)
  ok msg, "the Parallel Process's own Show Text opened the shared message window"

  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # complete the (short) reveal
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update # advance past the finished text into the Input Number follow-up
  RGSS::Input.reset # the still-held C from the dismiss above must not confirm the widget too

  ni = nil
  6.times do
    scene.update
    ni = scene.instance_variable_get(:@number_input)
    break if ni
  end
  ok ni, "the Input Number follow-up opened, merged into the process's own still-open window"
  ok ni[:embedded], 'merged onto the preceding Show Text, not a fresh standalone panel'
  ok scene.instance_variable_get(:@message), 'the message window is still the one carrying it'

  RGSS::Input.triggered = [RGSS::Input::UP] # tens digit 0 -> 1 (value 10)
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C] # confirm
  scene.update
  ok !scene.instance_variable_get(:@number_input), 'the widget closed on confirm'
  ok !scene.instance_variable_get(:@message), 'the merged message window closed with it'
  5.times { RGSS::Input.reset; scene.update }
  eq 10, st.variables[5], 'the entered value landed in variable 5'
  ok st.switches[1], 'the Parallel Process resumed and ran the command after Input Number'
end

check "a forced route auto-runs to completion before an immediately-following Show Text opens (yado.tk)" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # Force event 2 to walk right 3 tiles (freq 4, repeat off), with no Proceed
  # With Movement -- yado.tk: hitting a Show Text implicitly auto-runs any
  # still-pending forced route to completion first, the same as an explicit
  # Proceed With Movement would, before the window actually opens.
  auto.event_commands = [
    ECmd.new(ic::MOVE_EVENT,
             [2, 4, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]),
    ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi'),
  ]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(0, 1, page) },
                    player: [5, 5])
  c = chars(scene)[2]

  10.times { scene.update } # mid-route: still moving, message not yet opened
  ok c.x < 3, "route still in progress, at x=#{c.x}"
  ok !scene.instance_variable_get(:@message),
     'Show Text waits for the pending forced route to finish first'

  200.times { scene.update } # enough frames for the freq-4 route to finish
  eq 3, c.x, 'the forced event reached the end of its route'
  ok scene.instance_variable_get(:@message),
     'the message window opens only once the route has completed'
end

check "a forced route auto-runs to completion before an immediately-following Wait starts counting down (yado.tk)" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::MOVE_EVENT,
             [2, 4, 0, 0, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT]),
    ECmd.new(ic::WAIT, [5]), # half a second, once the route lets it start
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0]),
  ]
  scene = new_scene({ 1 => event(0, 4, auto), 2 => event(0, 1, page) },
                    player: [5, 5])
  st = scene.instance_variable_get(:@state)
  c = chars(scene)[2]

  10.times { scene.update } # mid-route: the Wait must not have started yet
  ok c.x < 3, "route still in progress, at x=#{c.x}"

  # Stop the instant the route lands, so the half-second Wait has had no
  # chance yet to also elapse within the same budget.
  300.times { scene.update; break if c.x == 3 }
  eq 3, c.x, 'the forced event reached the end of its route'
  ok !st.switches[1], 'the half-second Wait only starts once the route is done'

  40.times { scene.update } # enough for the half-second Wait itself to elapse
  ok st.switches[1],
     'the interpreter resumed once the Wait (started after the route) elapsed'
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
  one_shot_auto(auto, 9015)
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
  one_shot_auto(auto, 9016)
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

# Unlike the battle screen (a genuinely separate scene whose own backdrop
# sits *below* @picture_sprite's z, needing an explicit hide -- see "pictures
# are hidden while the battle screen is up" above) and the Menu screen (an
# opaque panel painted *above* the picture layer, per Scene::Base
# #build_field_background), a message window is not a scene push and does not
# blank the screen -- it is itself a z=300 Window sitting above the z=250
# picture layer (see the "below the message window" assertion just above).
# RPG_RT's own Draw() carries no message-window check for pictures either
# (verified against EasyRPG Player's Sprite_Picture::Draw and Scene_Map --
# `Priority_PictureOld` sits below `Priority_Window` in src/drawable.h, and
# neither file gates picture visibility on message state), so an already-shown
# picture keeps compositing and animating under an open message window exactly
# like it does under any other window; the window's own z-order is what covers
# it, the same way it covers the map tiles beneath it.
check 'a shown picture keeps rendering and moving while a message window is open' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3) # autostart
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hi')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  st.show_picture(1, name: 'pic', x: 160, y: 120, zoom: 100, opacity: 255)
  st.move_picture(1, 160, 60, 200, 128, 100, 100, 100, 100, 6)
  sprite = scene.instance_variable_get(:@picture_sprite)

  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'the message window opened'
  ok sprite.visible, 'the picture layer is not hidden while the message window is up'
  bmp = scene.instance_variable_get(:@picture_bmp)
  bmp.clear_stretch_calls
  scene.update
  eq 1, bmp.stretch_calls.size, 'the picture still composites every frame under the message window'
  ok st.pictures_moving?, 'the picture keeps advancing its move while the message window is up'

  # Complete the reveal, then dismiss, the same two-press sequence the
  # "types out gradually" check above uses.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  ok !scene.instance_variable_get(:@message), 'the message window closed'
  ok sprite.visible, 'the picture layer is still visible once the message window closes'
end

check 'pictures composite in ascending id order, independent of show order' do
  # yado.tk: 50 concurrent picture slots, higher id always draws on top,
  # independent of show order. Shown here in the opposite order (2 then 1) so
  # a pass that composited by show/insertion order instead of by id would
  # fail this.
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  st.show_picture(2, name: 'picB', x: 160, y: 120, zoom: 100, opacity: 255)
  st.show_picture(1, name: 'picA', x: 160, y: 120, zoom: 100, opacity: 255)
  bmp = scene.instance_variable_get(:@picture_bmp)
  bmp.clear_stretch_calls
  scene.update
  srcs = bmp.stretch_calls.map { |c| c[1] } # stretch_blt(dest, src, src_rect, opacity)
  eq 2, srcs.size, 'both pictures drew'
  # Picture 1 (id 1) composites first, so picture 2 (higher id) ends up on top.
  pic_a_src = scene.send(:picture_src, 'picA', false)
  pic_b_src = scene.send(:picture_src, 'picB', false)
  eq [pic_a_src, pic_b_src], srcs,
     'lower id drawn first, higher id drawn last (on top), regardless of show order'
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

check 'battle backdrop receives the screen tone under a Tint Screen' do
  scene = new_scene({})
  back = RGSS::Sprite.new
  fake_battle(scene, back_sprite: back)
  # A non-default tint, applied twice so the "unchanged tint" early-return in
  # #update_map_tone does not skip the push to the backdrop.
  tint = [120, 80, 100, 100]
  scene.send(:update_map_tone, tint)
  scene.send(:update_map_tone, tint)
  eq scene.send(:current_map_tone), back.tone,
     'the live battle backdrop carries the map layer tone'
  # And a mid-fight tint change is tracked onto the backdrop too.
  tint2 = [80, 120, 100, 100]
  scene.send(:update_map_tone, tint2)
  eq scene.send(:current_map_tone), back.tone,
     'a tint change during the fight re-tints the backdrop'
  # The push is gated on @battle: with the fight closed, a tint change still
  # updates the map layer but leaves a (now-detached) backdrop untouched.
  expected = back.tone
  scene.instance_variable_set(:@battle, nil)
  scene.send(:update_map_tone, [100, 100, 100, 100])
  eq expected, back.tone, 'no fight open means no backdrop re-tint'
end

# Scene::Map#current_map_tone must be *public*, not merely reachable through
# #send: Scene::Battle#build_battle_back seeds its backdrop with it through a
# plain `@map.current_map_tone` call. Under CRuby the old `respond_to?` guard
# hid the fact that it was private (CRuby's respond_to? excludes private
# methods), but mruby's does not -- so every native battle raised NoMethodError
# there. See the private-method fix next to #build_battle_back.
check 'Scene::Map#current_map_tone is a public service the battle scene can call' do
  scene = new_scene({})
  ok scene.respond_to?(:current_map_tone),
     'the battle backdrop can reach it without #send'
  # And it answers, not just responds.
  vp = RGSS::Viewport.new
  vp.tone = [10, 20, 30, 40]
  scene.instance_variable_set(:@map_viewport, vp)
  eq vp.tone, scene.current_map_tone, 'a real Scene::Map answers the live tone'
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
  one_shot_auto(auto, 9017)
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [3, 3])
  st = scene.instance_variable_get(:@state)

  5.times { scene.update } # mid-scroll: renders with a locked, panned camera
  ok st.screen.pan_locked?, 'the camera is locked'
  ok st.screen.panning?, 'still scrolling (80 px at speed 2, 0.5 px/frame)'
  ok !st.switches[1], 'the command after the pan waits'

  170.times { scene.update } # 80 px at 0.5 px/frame -> 160 frames, plenty
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
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the "purchased" confirmation
  scene.update
  RGSS::Input.triggered = []
  scene.update
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

check 'Open Shop scene: the counter steps by one on the horizontal axis and ' \
      'clamps to its bounds' do
  scene, _st = shop_quantity_scene(500)
  shop = scene.instance_variable_get(:@shop)
  press(scene, RGSS::Input::RIGHT)
  eq 2, shop[:quantity][:count]
  press(scene, RGSS::Input::LEFT)
  eq 1, shop[:quantity][:count]
  press(scene, RGSS::Input::LEFT)
  eq 1, shop[:quantity][:count], 'never below one'
  5.times { press(scene, RGSS::Input::RIGHT) }
  eq 5, shop[:quantity][:count], 'never past what the party can afford'
end

check 'Open Shop scene: the counter steps by ten on the vertical axis' do
  # Confirmed against EasyRPG's Window_ShopNumber::Update
  # (src/window_shopnumber.cpp): RIGHT/LEFT step by one, UP/DOWN by ten -- the
  # tens step is vertical, not horizontal.
  scene, _st = shop_quantity_scene(999_999)
  shop = scene.instance_variable_get(:@shop)
  eq 99, shop[:quantity][:max], 'rich enough to hit the item cap'
  press(scene, RGSS::Input::UP)
  eq 11, shop[:quantity][:count], '1 + 10'
  press(scene, RGSS::Input::DOWN)
  eq 1, shop[:quantity][:count]
  20.times { press(scene, RGSS::Input::UP) }
  eq 99, shop[:quantity][:count], 'clamped at the cap'
end

check 'Open Shop scene: confirming the counter buys the whole stack at once' do
  scene, st = shop_quantity_scene(500)
  press(scene, RGSS::Input::RIGHT)
  press(scene, RGSS::Input::RIGHT)   # three
  press(scene, RGSS::Input::C)
  eq 200, st.party.gold, '500 - 3*100'
  eq 3, st.party.item_count(3), 'three bought in one confirm'
  shop = scene.instance_variable_get(:@shop)
  eq :purchased, shop[:screen], 'the "purchased" confirmation shows first'
  press(scene, RGSS::Input::C)
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen], 'and dismissing it returns to the buy list'
end

check 'Open Shop scene: cancelling the counter buys nothing' do
  scene, st = shop_quantity_scene(500)
  press(scene, RGSS::Input::RIGHT)
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
  press(scene, RGSS::Input::RIGHT)
  press(scene, RGSS::Input::RIGHT)      # three
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

# EasyRPG's `Game_Interpreter_Map::CommandOpenShop`
# (src/game_interpreter_map.cpp) is the exact same method for the foreground
# and every Parallel Process's own interpreter -- gated only on
# `Game_Message::IsMessageActive()`, no "foreground only" restriction. Before
# this fix, `Scene::Map#drive_parallel_wait` had no `:shop` branch at all, so
# a Parallel Process's own Open Shop silently never opened the screen -- the
# command fell into the generic "background: resume" default and read as a
# complete no-op, the same defect Enter Hero Name (10740) had before its own
# fix.
check 'Open Shop issued from a Parallel Process opens the shop screen too' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4) # Parallel Process
  par.event_commands = [
    ECmd.new(ic::OPEN_SHOP, [1, 0, 0, 0, 3, 5], indent: 0), # buy-only, goods 3/5
    ECmd.new(ic::SHOP_TRANSACTION, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0], indent: 1),
    ECmd.new(ic::SHOP_NO_TRANSACTION, [], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 2, 2, 0], indent: 1),
    ECmd.new(ic::SHOP_END, [], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, par) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, ShopStubParty.new(500))
  shop = nil
  6.times { scene.update; shop = scene.instance_variable_get(:@shop); break if shop }
  ok shop, 'the shop screen opened for a Parallel-Process-issued command'
  ok !st.switches[1] && !st.switches[2], 'still shopping'

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
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the "purchased" confirmation
  scene.update
  RGSS::Input.triggered = []
  scene.update
  RGSS::Input.triggered = [RGSS::Input::B] # leave the shop
  scene.update
  scene.update
  eq nil, scene.instance_variable_get(:@shop), 'the shop screen closed'
  ok st.switches[1], 'the parallel process resumed into its Transaction branch, not stuck forever'
  ok !st.switches[2], 'the No Transaction branch was skipped'
end

# Battle command / result command lists for the encounter tests below.
def battle_event_commands(ic, escape_mode: 0, second_switch_code: nil, troop_id: 1,
                          first_strike: false)
  handler2 = second_switch_code || ic::ESCAPE_HANDLER
  [
    ECmd.new(ic::ENEMY_ENCOUNTER,
             [0, troop_id, 0, escape_mode, 1, first_strike ? 1 : 0], indent: 0),
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
# Budgeted for a several-round fight at BATTLE_ANIM_FRAMES=90 (each
# no-animation action) plus the encounter banner's BATTLE_ENCOUNTER_MSG_FRAMES
# hold -- both slower than this file's old defaults, so a fight that used to
# finish well inside 600 frames can now run past it.
def battle_attack_to_end(scene, max = 2000)
  max.times do
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :result
    # A pressed C on :battle_options picks the cursor's default row 0,
    # "Battle" -- dismissing the once-per-battle automatic options window
    # exactly the way a player who ignores Auto Battle/Escape would.
    RGSS::Input.triggered = [RGSS::Input::C] if ui && %i[command target battle_options].include?(ui[:phase])
    scene.update # a nil ui just means the battle is still opening
    RGSS::Input.triggered = []
  end
end

# Run `scene` until its battle UI's phase becomes `phase`, budgeted to `max`
# frames -- used by the options-window checks below, which need to catch the
# battle right when a phase first appears rather than run it through to a
# later one the way #battle_attack_to_end does. `:battle_options` (every
# call site's actual target) only opens once the encounter banner's own
# BATTLE_ENCOUNTER_MSG_FRAMES hold has run out, so the default budget needs
# enough room for that hold plus the frames battle-open itself takes.
def battle_until_phase(scene, phase, max = 90)
  ui = nil
  max.times do
    scene.update
    ui = battle_ui(scene)
    break if ui && ui[:phase] == phase
  end
  ui
end

# Every string a window's contents had drawn into it, whichever path drew it:
# `draw_text(x, y, w, h, text, align)` and `blend_text(x, y, w, h, text, skin,
# ...)` both carry the text at index 4.
def window_texts(win)
  c = win && win.contents
  return [] unless c
  ((c.draw_calls || []) + (c.blend_calls || [])).map { |a| a[4] }
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

# EasyRPG's own EXP-granting loop (Scene_Battle_Rpg2k::
# ProcessSceneActionVictory) iterates Game_Party_Base::GetActiveBattlers, not
# the raw party roster, and GetActiveBattlers excludes anyone failing
# Game_Battler::Exists() (`!IsHidden() && !IsDead() && IsInParty()`) -- a
# fallen ally still enrolled in the party at the moment of victory gets
# nothing.
check "Enemy Encounter scene: a KO'd party member earns no EXP from the victory" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  alive = BattleStubActor.new(id: 1)
  fallen = BattleStubActor.new(id: 2, hp: 0) # already KO'd going into the fight
  st.instance_variable_set(:@party, BattleStubParty.new(actors: [alive, fallen]))
  scene.update
  battle_attack_to_end(scene) # only the living actor's Attack drives it to victory
  eq 10, alive.exp, 'the surviving actor still gains the troop EXP (2 Slimes x 5)'
  eq 0, fallen.exp, "a KO'd party member earns nothing from the victory"
end

# `Game::Battle` already tracks the fight's own round count live (`@rounds`,
# `#turn`), but nothing captured it before `#close_battle` discarded the
# `Battle` object once the fight ended -- see docs/TODO.md's "turns passed in
# latest battle" entry. `#finish_battle` (mruby-rpg2k/mrblib/scene/map.rb) now
# reads `@battle_ui[:battle].turn` onto `Game::State#last_battle_turns` right
# alongside the existing `apply_to_party` call, so it survives past
# `close_battle` for the `.lsd`'s inventory chunk 109 `turns` field (41) to
# round-trip (see the `to_lsd`/`from_lsd` check in rpg2k_logic_check.rb).
check 'Enemy Encounter scene: finish_battle captures the round count as last_battle_turns' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  eq nil, st.last_battle_turns, 'no battle has ever finished yet'
  scene.update # opens the per-actor command menu (Attack / Defend)
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the Victory result -> finish_battle
  scene.update
  RGSS::Input.triggered = []
  ok st.last_battle_turns && st.last_battle_turns > 0,
     "finish_battle captured the fought battle's own round count " \
     "(got #{st.last_battle_turns.inspect})"
end

# RPG_RT's own `Scene_Battle` constructor (src/scene_battle.cpp) plays the
# database's Battle Start system SE (`SFX_BeginBattle`) as its very first act,
# unconditionally, before even swapping to the battle BGM -- `Scene::Map
# #open_battle` (mruby-rpg2k/mrblib/scene/map.rb) already had every other
# system-SE slot wired up (cursor/decision/cancel/buzzer, escape, the per-hit
# sounds) but never called `#play_system_se(SFX_BATTLE)` at all, so the
# database's own Battle Start sound never played on any encounter -- a
# foreground Enemy Encounter command, one issued from a Parallel Process, or a
# random/wandering-monster encounter alike, since they all share this one
# entry point.
check 'Enemy Encounter scene: opening a battle plays the database Battle Start SE' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  RGSS::Audio.reset_se
  10.times do
    scene.update
    break if battle_ui(scene)
  end
  ok battle_ui(scene), 'the battle actually opened'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'BattleStart1' },
     'the database Battle Start SE played the instant the fight opened'
end

check 'Enemy Encounter scene: a Change System SFX battle-start override wins over the database default' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  # System SFX slot 4 is Battle Start (Scene::Base::SFX_BATTLE).
  st.system_sfx[4] = { name: 'CustomBattleStart', volume: 60, tempo: 120 }
  RGSS::Audio.reset_se
  10.times do
    scene.update
    break if battle_ui(scene)
  end
  ok battle_ui(scene), 'the battle actually opened'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'CustomBattleStart' },
     'the override plays instead of the database BattleStart1'
  ok !RGSS::Audio.se_calls.any? { |c| c[0] == 'BattleStart1' },
     'the database default is fully superseded, not layered alongside it'
end

# EasyRPG Player's `Scene_Battle_Rpg2k::ProcessSceneActionStart`
# (`src/scene_battle_rpg2k.cpp`) narrates the encounter before the party is
# ever asked for a command: `GetActiveBattlers` (not dead or hidden) feeds one
# `PushWithSubject(terms.encounter, enemy->GetName())` per visible member --
# stock RPG2000's `PushWithSubject` concatenates `subject + message`, no
# placeholder -- and `Scene::Map#open_battle` used to skip straight past this
# into `phase: :command` with no message at all.
check 'Enemy Encounter scene: opening a battle narrates each visible enemy with ' \
      'the database encounter term before any command menu shows' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  scene.db.term.encounter = 'があらわれた！'
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :encounter_message)
  ok ui, 'the encounter-message phase was reached'
  eq ['Slimeがあらわれた！', 'Slimeがあらわれた！'], window_texts(ui[:action_win]),
     'both troop members are named, once each, using the database term'
end

# `ProcessSceneActionStart`'s `eFirstStrike` substate pushes `terms.
# special_combat` (no subject, a fixed line) *after* every per-enemy
# `encounter` line, only when the encounter is a first-strike ambush -- it is
# appended to the same narration, not a replacement for it.
check 'Enemy Encounter scene: a first-strike encounter appends the special_combat ' \
      'line after the per-enemy encounter lines' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, first_strike: true)
  scene = new_scene({ 1 => event(2, 2, auto) })
  scene.db.term.encounter = 'があらわれた！'
  scene.db.term.special_combat = '先制攻撃！'
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :encounter_message)
  ok ui, 'the encounter-message phase was reached'
  eq ['Slimeがあらわれた！', 'Slimeがあらわれた！', '先制攻撃！'],
     window_texts(ui[:action_win]),
     'special_combat trails the per-enemy lines rather than replacing them, ' \
     "matching EasyRPG Player's own ordering"
end

# `GetActiveBattlers` is the "not dead or hidden" subset (`Game_Battler::
# Exists`) -- a troop member the editor placed but flagged invisible
# (`Game::Enemy#hidden`, the same flag Show Hidden Monster clears) never gets
# an arrival line, matching the sprite-build skip in #build_battle_sprites.
check 'Enemy Encounter scene: a hidden troop member gets no encounter line' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  scene.db.term.encounter = 'があらわれた！'
  scene.db.enemy_group[1].members[2].invisible = true # the second Slime starts hidden
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :encounter_message)
  ok ui, 'the encounter-message phase was reached'
  eq ['Slimeがあらわれた！'], window_texts(ui[:action_win]),
     'only the still-visible Slime is narrated'
  ok ui[:troop].members[1].hidden, 'and the troop model agrees the second member is hidden'
end

# yado.tk: "the built-in random-number operand is a genuine non-seeded RNG --
# two New Games produce different sequences," i.e. real RPG_RT's randomness is
# one continuously-advancing stream for the whole session, never reset mid-game.
# `Scene::Map#open_battle` (mruby-rpg2k/mrblib/scene/map.rb) used to build each
# fight's combat math on a brand-new `Game::Rng.new(0x2000)`, discarding
# whatever the scene's own already-advancing `@rng` (the same stream random
# encounters and NPC wandering already draw from) had reached -- so every
# battle's hit/miss/crit/damage rolls started over from the exact same point
# regardless of how much other randomness the playthrough had already
# consumed, and two battles against the same troop played out identically
# given the same player inputs. Fixed by passing the scene's own `@rng`
# straight through instead of a disposable fresh one.
check "Enemy Encounter scene: battle math reuses the scene's own advancing " \
      'RNG stream, not a fresh one reseeded to the same constant every fight' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  2.times { scene.update } # opens the battle UI (see battle_attack_to_end above)
  ui = battle_ui(scene)
  rng = scene.instance_variable_get(:@rng)
  ok ui[:battle].rng.equal?(rng),
     "the battle's own combat math should draw from the scene's single, " \
     'already-advancing RNG object, not a freshly constructed one'
end

check 'Enemy Encounter scene: rolls already spent by earlier map activity change ' \
      'how the ensuing battle plays out' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)

  scene_a = new_scene({ 1 => event(2, 2, auto) })
  scene_a.instance_variable_get(:@state)
          .instance_variable_set(:@party, BattleStubParty.new)
  battle_attack_to_end(scene_a)
  log_a = battle_ui(scene_a)[:battle].log.dup

  scene_b = new_scene({ 1 => event(2, 2, auto) })
  scene_b.instance_variable_get(:@state)
          .instance_variable_set(:@party, BattleStubParty.new)
  # Stand in for ordinary map play before this same scripted fight is ever
  # reached -- random-encounter rolls, NPC wandering steps, an earlier fight
  # entirely -- all of which draw from this same per-scene RNG stream.
  7.times { scene_b.instance_variable_get(:@rng).next_int }
  battle_attack_to_end(scene_b)
  log_b = battle_ui(scene_b)[:battle].log.dup

  ok log_a != log_b,
     'a fight reached after other map-side rolls should not replay the exact ' \
     'same hit/miss/damage sequence as one reached with none spent'
end

check 'Enemy Encounter scene: battle BGM plays on entry, field BGM resumes after' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  st.current_bgm = { name: 'Field', volume: 100, tempo: 100 } # the map's own BGM
  RGSS::Audio.reset_bgm
  # One update steps the Autorun's interpreter onto the :battle wait; a
  # second is what actually opens the battle UI (like battle_attack_to_end's
  # own "a nil ui just means the battle is still opening" allowance above).
  2.times { scene.update }
  eq [['BattleBGM', 70, 110]], RGSS::Audio.bgm_calls,
     'the database battle BGM played, at its configured vol/tempo'
  eq 'BattleBGM', st.current_bgm[:name], 'and is now the tracked current BGM'
  RGSS::Audio.reset_bgm
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the Victory result
  scene.update
  RGSS::Input.triggered = []
  eq [['Field', 100, 100]], RGSS::Audio.bgm_calls,
     'the field BGM that was playing before the fight replays once it ends'
  eq 'Field', st.current_bgm[:name]
end

check 'Enemy Encounter scene: a Change System BGM battle override beats the database default' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  # System BGM slot 0 is battle -- see the matching rpg2k_logic_check.rb note.
  st.system_bgm[0] = { name: 'CustomBattle', fadein: 0, volume: 85, tempo: 120,
                       balance: 50 }
  RGSS::Audio.reset_bgm
  2.times { scene.update } # opens the battle UI (see battle_attack_to_end above)
  eq [['CustomBattle', 85, 120]], RGSS::Audio.bgm_calls,
     'the Change System BGM override played instead of the database BattleBGM'
  eq 'CustomBattle', st.current_bgm[:name]
end

check 'Enemy Encounter scene: a battle BGM matching the already-playing field track ' \
      'does not restart it, and neither does restoring it back after the fight' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  # The field track already playing is the exact file the database's own
  # battle_music names ('BattleBGM', see new_scene's system fixture above),
  # just at different vol/tempo -- the scenario yado.tk's "field and battle
  # BGM sharing the same file continue seamlessly across the transition"
  # describes.
  st.current_bgm = { name: 'BattleBGM', volume: 50, tempo: 90 }
  RGSS::Audio.reset_bgm
  2.times { scene.update } # opens the battle UI (see battle_attack_to_end above)
  eq [], RGSS::Audio.bgm_calls,
     'entering battle does not break and restart a track that is already playing'
  eq 'BattleBGM', st.current_bgm[:name]
  eq 70, st.current_bgm[:volume], "the battle track's own vol/tempo are still tracked"
  eq 110, st.current_bgm[:tempo]
  eq [70], RGSS::Audio.bgm_volume_calls,
     'the still-playing track had its volume re-applied live rather than left alone'
  RGSS::Audio.reset_bgm
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the Victory result
  scene.update
  RGSS::Input.triggered = []
  eq [], RGSS::Audio.bgm_calls,
     'restoring the field BGM after the fight does not restart it either -- ' \
     'this scene never actually stopped it in the first place'
  eq 'BattleBGM', st.current_bgm[:name]
  eq 50, st.current_bgm[:volume], "the restored pre-battle vol/tempo snapshot wins back"
  eq 90, st.current_bgm[:tempo]
  eq [50], RGSS::Audio.bgm_volume_calls,
     'the restore also re-applied its own volume live, not just the tracked state'
end

check 'Enemy Encounter scene: victory plays the database battle_end_music over the result screen' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  scene.db.system.battle_end_music =
    OpenStruct.new(file: 'VictoryBGM', volume: 90, pitch: 105)
  st.current_bgm = { name: 'Field', volume: 100, tempo: 100 } # the map's own BGM
  2.times { scene.update } # opens the battle UI (see battle_attack_to_end above)
  RGSS::Audio.reset_bgm
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  eq [], RGSS::Audio.bgm_calls,
     'the fanfare is a one-shot ME, not an ordinary looping BGM play'
  eq [['VictoryBGM', 90, 105]], RGSS::Audio.me_calls,
     'the victory fanfare played over the result screen through the ME channel'
  eq 'BattleBGM', st.current_bgm[:name],
     "the ME is not tracked as the ongoing BGM -- #current_bgm still names " \
     'whatever the last actual BGM play was (the battle track)'
  RGSS::Audio.reset_bgm
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the Victory result
  scene.update
  RGSS::Input.triggered = []
  eq 1, RGSS::Audio.me_stop_calls,
     'the fanfare is ended through its own ME stop path rather than a bare BGM play ' \
     'yanking the shared music stream out from under it'
  eq [['Field', 100, 100]], RGSS::Audio.bgm_calls,
     'the field BGM that was playing before the fight replays once the result is dismissed'
  eq 'Field', st.current_bgm[:name]
end

check 'Enemy Encounter scene: a Change System BGM victory override beats the database battle_end_music' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  scene.db.system.battle_end_music =
    OpenStruct.new(file: 'VictoryBGM', volume: 90, pitch: 105)
  # System BGM slot 1 is victory -- see the matching rpg2k_logic_check.rb note.
  st.system_bgm[1] = { name: 'CustomVictory', fadein: 0, volume: 60, tempo: 130,
                       balance: 50 }
  2.times { scene.update } # opens the battle UI (see battle_attack_to_end above)
  RGSS::Audio.reset_bgm
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  eq [], RGSS::Audio.bgm_calls,
     'the fanfare is a one-shot ME, not an ordinary looping BGM play'
  eq [['CustomVictory', 60, 130]], RGSS::Audio.me_calls,
     'the Change System BGM override played instead of the database battle_end_music'
  eq 'BattleBGM', st.current_bgm[:name]
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

# viprpg-dev wiki (200X共通/基本的な仕様, 09_bug/016_ikinari_end,
# 017_heiretu_totyu_end/hei_mukou): a Battle "Lose: Branch" handler's own
# recovery (a Full Heal / Change HP right after the encounter) races a
# still-running Parallel Process's own Game Over check. #finish_battle
# (mruby-rpg2k/mrblib/scene/map.rb) already clears @battle_ui *before*
# resuming the event into the Defeat handler -- so #parallels_paused? no
# longer holds a Parallel Process back -- but nothing used to drive the
# handler's own commands any further this same frame: #drive_event's `:battle`
# case just called #drive_battle and returned, leaving the interpreter merely
# off its `:battle` wait until *next* frame's ordinary "not waiting" branch
# happened to reach it. #step_parallels runs before that at the top of
# #update, so a Parallel Process gets exactly one whole frame -- with the
# party still sitting at 0 HP and unrevived -- to notice the wipe and raise
# Game Over first. Fixed by driving the interpreter one step further
# immediately once it comes off the `:battle` wait, the same "spend this
# frame's own step budget immediately" idiom the `:wait` branch already uses
# right below for "Wait 0.0 sec costs one frame, not two".
check 'Enemy Encounter scene: a Lose-branch recovery beats a racing ' \
      "Parallel Process's Game Over check" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::ENEMY_ENCOUNTER, [0, 1, 0, 0, 1, 0], indent: 0), # troop 1, custom Defeat handler
    ECmd.new(ic::VICTORY_HANDLER, [], indent: 0),
    ECmd.new(ic::DEFEAT_HANDLER, [], indent: 0),
    # The "Lose: Branch" recovery: heal the whole party back up...
    ECmd.new(ic::CHANGE_HP, [0, 0, 0, 0, 999, 1], indent: 1),
    # ...then prove the rest of the branch still ran too, not just the heal.
    ECmd.new(ic::CONTROL_SWITCHES, [0, 3, 3, 0], indent: 1),
    ECmd.new(ic::END_BATTLE, [], indent: 0)
  ]
  # A Common Event Parallel Process that pokes a harmless Change HP +0 every
  # lap it gets to run -- its only purpose is to reach
  # Game::Interpreter#check_game_over on whichever frame it is next allowed
  # to run, exactly the way a real game's own HP-regen/status-tick parallel
  # process would incidentally do.
  ce = OpenStruct.new(start_term: 4, need_flag: false,
                      event: [ECmd.new(ic::CHANGE_HP, [0, 0, 0, 0, 0, 1], indent: 0)])
  scene = new_scene({ 1 => event(2, 2, auto) }, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  # A frail hero the two Slimes overwhelm.
  st.instance_variable_set(:@party,
                           BattleStubParty.new(BattleStubActor.new(atk: 6, dfn: 0, agi: 3, hp: 10)))
  parent = scene.instance_variable_get(:@parent)
  scene.update
  battle_attack_to_end(scene)
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the defeat result -> finish_battle
  scene.update
  RGSS::Input.triggered = []
  ok st.switches[3],
     "the Defeat handler's recovery must run this same frame, not a frame later"
  ok !st.party.all_dead?, 'the party was revived by the Defeat handler before anything else ran'
  ok !parent.game_over_shown, 'no Game Over yet -- the branch already revived the party'
  2.times { scene.update } # give the racing Parallel Process every chance to run
  ok !parent.game_over_shown,
     "the Parallel Process's own Game Over check must never win this race"
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

# The real RPG2k Battle/Auto Battle/Escape options window (EasyRPG's
# `scene_battle_rpg2k.cpp`, `State_SelectOption` /
# `ProcessSceneActionFightAutoEscape`), traced verbatim in docs/TODO.md's
# "SelectPreviousActor" writeup: shown automatically once per battle, right
# after the encounter/turn-0-event messages resolve
# (`ProcessSceneActionStart`'s final substate: unconditional
# `SetState(State_SelectOption)`), and reopened whenever B/Cancel lands on
# the very first commandable actor's command list
# (`SelectPreviousActor()`'s `allies[0] == active_actor` branch), instead of
# this engine's old direct-B-press Escape shortcut.

check 'Enemy Encounter scene: the Battle/Auto Battle/Escape options window opens ' \
      'automatically once at the very start of every fight' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :battle_options)
  ok ui, 'the battle opened'
  eq :battle_options, ui[:phase], 'the options window shows before any per-actor command menu'
  eq 0, ui[:opt], 'the cursor starts on the first row, Battle'
  eq %w[Fight AutoBattle Escape].map { |s| s == 'AutoBattle' ? 'Auto Battle' : s },
     scene.instance_variable_get(:@battle).send(:battle_option_rows).map { |r| r[:label] },
     'fake_db leaves the battle_fight/battle_auto/battle_escape terms blank, so these are ' \
     'the composed English fallbacks'
end

check 'Enemy Encounter scene: B/Cancel does nothing while the options window is open' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :battle_options)
  eq :battle_options, ui[:phase]
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.triggered = []
  eq :battle_options, ui[:phase], 'B/Cancel is a no-op here -- there is no parent state to cancel to'
  eq 0, ui[:opt], 'the cursor did not move either'
  eq [], RGSS::Audio.se_calls, 'and no SE played, matching a real cancel-into-nothing'
end

check 'Enemy Encounter scene: selecting Battle from the options window returns to the ' \
      'ordinary per-actor command menu' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :battle_options)
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::C] # Battle -- the default cursor row 0
  scene.update
  RGSS::Input.triggered = []
  eq :command, ui[:phase], 'Battle dismisses the window and opens the normal command menu'
  eq 0, ui[:actor_i], 'still commanding the same first actor'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'Decision1' }, 'choosing Battle plays Decision'
end

check "Enemy Encounter scene: B-cancel on the first commandable actor's command list " \
      'reopens the options window instead of escaping directly' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :battle_options)
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss via Battle first
  scene.update
  RGSS::Input.triggered = []
  eq :command, ui[:phase]
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::B] # cancel on the very first actor
  scene.update
  RGSS::Input.triggered = []
  eq :battle_options, ui[:phase],
     'reopens the options window rather than attempting Escape directly, ' \
     'the deliberate simplification this replaces'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'Cancel1' },
     'B always plays Cancel first, matching a real re-command, before landing on the window'
end

check 'Enemy Encounter scene: selecting Escape from the options window runs Escape, exactly ' \
      'as the old direct-B shortcut did' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2) # custom escape handler
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :battle_options)
  2.times { RGSS::Input.triggered = [RGSS::Input::DOWN]; scene.update } # Fight -> Auto Battle -> Escape
  RGSS::Input.triggered = []
  eq 2, ui[:opt], 'the cursor landed on Escape'
  RGSS::Input.triggered = [RGSS::Input::C] # confirm Escape
  scene.update
  RGSS::Input.triggered = []
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

# EasyRPG's Scene_Battle::TryEscape checks its own `first_strike` flag first,
# before ever touching `escape_chance` -- so a first-strike encounter's
# opening Escape always succeeds, even against enemies fast enough to floor
# the roll at 0%. Scene::Battle#try_battle_escape used to call
# Game::Battle#attempt_escape with no argument at all (defaulting `preemptive`
# to false), so it silently fell back to the ordinary roll regardless of
# first_strike, and a 0%-chance escape here could never succeed.
check 'Enemy Encounter scene: a first-strike encounter always escapes on the ' \
      'opening Escape, even against enemies fast enough to floor the roll at 0%' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2, first_strike: true)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  # Both Slimes are agi 5 (fake_db); a far slower hero floors escape_chance
  # at 0, so only the first-strike guarantee -- never the roll -- can succeed.
  st.instance_variable_set(:@party, BattleStubParty.new(BattleStubActor.new(agi: 1)))
  ui = battle_until_phase(scene, :battle_options)
  ok ui, 'the options window opened'

  2.times { RGSS::Input.triggered = [RGSS::Input::DOWN]; scene.update } # Fight -> Auto Battle -> Escape
  RGSS::Input.triggered = []
  eq 2, ui[:opt], 'the cursor landed on Escape'
  RGSS::Input.triggered = [RGSS::Input::C] # confirm Escape
  scene.update
  RGSS::Input.triggered = []
  eq :result, ui[:phase], 'the escape attempt resolved immediately, no failure banner'
  eq :escape, ui[:result], 'and it succeeded -- the ambush round guarantees it'
end

check 'Enemy Encounter scene: selecting Auto Battle queues the AI pick for every ' \
      'commandable living ally and starts the round without further input' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  st.party.instance_variable_set(:@actors, [BattleStubActor.new(id: 1), BattleStubActor.new(id: 2)])
  ui = battle_until_phase(scene, :battle_options)
  RGSS::Input.triggered = [RGSS::Input::DOWN] # Fight -> Auto Battle
  scene.update
  RGSS::Input.triggered = []
  eq 1, ui[:opt], 'the cursor landed on Auto Battle'
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::C] # confirm Auto Battle
  scene.update
  RGSS::Input.triggered = []
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'Decision1' }, 'choosing Auto Battle plays Decision'
  ok ui[:allies][0].action || ui[:allies][0].command,
     "Game::Battle#choose_auto_battle_command queued the first ally's action"
  ok ui[:allies][1].action || ui[:allies][1].command,
     "and the second ally's too -- the whole party, not just one"
  ok ui[:phase] != :command,
     'the round started on its own -- no per-actor command menu was ever shown'
end

check 'Enemy Encounter scene: the options window does not reappear automatically at round 2+' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  # A tough hero the two Slimes cannot fell in one round, so the fight is
  # still going once round 2 opens its own command phase.
  st.instance_variable_set(:@party,
                           BattleStubParty.new(BattleStubActor.new(atk: 1, hp: 500)))
  ui = battle_until_phase(scene, :battle_options)
  RGSS::Input.triggered = [RGSS::Input::C] # Battle
  scene.update
  RGSS::Input.triggered = []
  eq :command, ui[:phase], 'round 1 command phase, options window already dismissed'
  saw_options_again = false
  40.times do
    RGSS::Input.triggered = [RGSS::Input::C] if %i[command target].include?(ui[:phase])
    scene.update
    ui = battle_ui(scene)
    RGSS::Input.triggered = []
    saw_options_again ||= ui && ui[:phase] == :battle_options
    break if ui.nil? || ui[:phase] == :result
  end
  ok !saw_options_again, 'round 2 (and beyond) opens the command phase directly, never the options window'
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

check 'the Game Over screen plays a Change System BGM override instead of the database gameover_music' do
  parent = fake_parent(fake_db)
  Audio.reset_bgm
  Input.reset
  state = OpenStruct.new(
    system_bgm: { RPG2k::Scene::GameOver::SYSTEM_BGM_GAMEOVER =>
                  { name: 'OverrideGameOverBGM', volume: 33, tempo: 66 } }
  )
  RPG2k::Scene::GameOver.new(parent, state)
  eq [['OverrideGameOverBGM', 33, 66]], Audio.bgm_calls,
     'the override plays, not the database GameOverBGM'
  Input.reset
end

check 'a bare Game Over (no Game::State) still falls back to the database gameover_music' do
  parent = fake_parent(fake_db)
  Audio.reset_bgm
  Input.reset
  RPG2k::Scene::GameOver.new(parent) # state omitted, as every pre-existing caller does
  eq [['GameOverBGM', 90, 100]], Audio.bgm_calls, 'unaffected by the new optional state arg'
  Input.reset
end

check 'a game-over battle defeat hands its Game::State to the Game Over screen' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # A bare encounter with defeat mode 0 (game over) and no handler block, the
  # same setup the "returns to the title" check above uses.
  auto.event_commands = [ECmd.new(ic::ENEMY_ENCOUNTER, [0, 1, 0, 0, 0, 0], indent: 0)]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party,
                           BattleStubParty.new(BattleStubActor.new(atk: 6, dfn: 0, agi: 3, hp: 10)))
  scene.update
  battle_attack_to_end(scene)
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the defeat result window
  scene.update
  RGSS::Input.triggered = []
  parent = scene.instance_variable_get(:@parent)
  ok parent.game_over_shown, 'the defeat reached Game Over'
  eq st, parent.game_over_state, 'carrying the very Game::State the battle ran on'
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

# Verified against EasyRPG Player's actual C++ source rather than assumed
# from this screen's own resemblance to a message/choice/menu window (every
# one of which does accept Cancel): `Scene_Gameover::vUpdate`
# (src/scene_gameover.cpp) checks only `Input::IsTriggered(Input::DECISION)`
# -- there is no reference to `Input::CANCEL` anywhere in the file. Pressing
# Cancel on the real Game Over screen does nothing at all.
check 'the Cancel button does not dismiss the Game Over screen -- only Decision does' do
  parent = fake_parent(fake_db)
  Input.reset
  scene = RPG2k::Scene::GameOver.new(parent)
  scene.update # arm: no key held yet
  Input.triggered = [Input::B]
  scene.update
  ok !parent.returned_to_title, 'Cancel is not a dismiss trigger for this screen'
  Input.reset
  scene.update
  Input.triggered = [Input::C]
  scene.update
  ok parent.returned_to_title, 'Decision still dismisses it, right after'
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
  Input.triggered = [Input::C]
  scene.update
  ok parent.returned_to_title, 'and it still dismisses to the title'
  Input.reset
end

# yado.tk ("Common events... never run during battle") describes what
# happens to *other* events while a fight is up; the more basic half it
# implies -- a Parallel Process's own Battle Processing (Enemy Encounter)
# command, the shape a scripted/threshold-triggered fight actually takes in
# a real game (a Common Event whose Parallel Process trigger checks a
# variable, then runs the encounter) -- was never modelled at all.
# #drive_parallel_wait's wait-kind dispatch had cases for :wait/:key_input/
# :animation/:game_over/:movement/:teleport/:message/:choice/:number/
# :screen/:picture/:sprite_flash -- every other wait kind reachable from a
# Parallel Process, each earning its own case over earlier rounds of this
# same defect class -- but none for :battle, so it fell into the generic
# "background: ignore ... requests" #resume and cleared the wait
# unconditionally the very next frame: @battle_request sat on the parallel
# process's own interpreter unread (#drive_battle used to only ever consult
# the foreground @interpreter's copy), no battle screen ever opened, and the
# process just fell straight through into whatever followed the Enemy
# Encounter command (its own [Victory] handler marker) as though the fight
# had been skipped outright.
check "a Common Event Parallel Process's own Battle Processing now actually opens and drives a real fight" do
  ic = Game::Interpreter::Cmd
  ce = OpenStruct.new(start_term: Game::CommonEvent::PARALLEL, need_flag: false,
                      switch_id: nil, event: battle_event_commands(ic))
  scene = new_scene({}, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  eq nil, battle_ui(scene), 'no battle before the process reaches it'
  battle_attack_to_end(scene) # Attack the Slimes each round until they fall
  ui = battle_ui(scene)
  ok ui, "the parallel process's own Enemy Encounter actually opened a real battle screen"
  eq :result, ui[:phase]
  fg = scene.instance_variable_get(:@interpreter)
  ok !ui[:owner].equal?(fg),
     "the parallel process's own interpreter owns this fight, not the (idle) foreground"
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the Victory result
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update }
  ok st.switches[1], "the Victory handler ran, on the parallel process's own command list"
  ok !st.switches[2], 'the Escape handler was skipped'
end

# A battle a Parallel Process opened owns the single @battle_ui slot exactly
# the way one the foreground opened does -- ordinary player movement/menu
# access must freeze for its whole duration regardless of which interpreter
# is driving it, the same freeze every *other* parallel process already gets
# from #parallels_paused? during any battle. Before this fix, #event_busy?
# only ever consulted the foreground @interpreter's own running?/waiting?
# state, so an otherwise-idle foreground (nothing of its own running) never
# noticed a Parallel-Process-opened fight at all: the player could freely
# walk around underneath the battle screen.
check "a battle a Parallel Process opened blocks player movement, just like one the foreground opened" do
  ic = Game::Interpreter::Cmd
  ce = OpenStruct.new(start_term: Game::CommonEvent::PARALLEL, need_flag: false,
                      switch_id: nil,
                      event: [ECmd.new(ic::ENEMY_ENCOUNTER, [0, 1, 0, 0, 0, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  RGSS::Input.dir_value = 6 # hold right the whole time
  12.times { scene.update }
  RGSS::Input.dir_value = 0
  ok battle_ui(scene), 'the fight is open by now'
  eq 0, st.x, "the party must not walk anywhere while a Parallel Process's own fight is up"
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

# EasyRPG's `Game_Interpreter_Map::CommandEnterHeroName`
# (src/game_interpreter_map.cpp) is the exact same method for the foreground
# and every Parallel Process's own interpreter -- gated only on
# `Game_Message::IsMessageActive()`, no "foreground only" restriction. Before
# this fix, `Scene::Map#drive_parallel_wait` had no `:name_input` branch at
# all, so a Parallel Process's own Enter Hero Name silently never opened the
# screen -- the command fell into the generic "background: resume" default
# and read as a complete no-op.
check 'Enter Hero Name issued from a Parallel Process opens the entry widget too' do
  ic = Game::Interpreter::Cmd
  par = page(trigger: 4) # Parallel Process
  par.event_commands = [
    ECmd.new(ic::NAME_INPUT, [1, 2, 0], indent: 0), # actor 1, letters, no seed
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, par) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, NameStubParty.new)
  ui = nil
  6.times { scene.update; ui = scene.instance_variable_get(:@name_ui); break if ui }
  ok ui, 'the name-entry widget opened for a Parallel-Process-issued command'
  eq '', ui[:name], 'starts empty (no seed)'

  RGSS::Input.triggered = [RGSS::Input::C] # confirm the first cell, 'A'
  scene.update
  RGSS::Input.triggered = []
  eq 'A', ui[:name]

  ui[:sel] = RPG2k::Scene::Map::NAME_CELLS.length - 1 # jump to OK and confirm
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 'A', st.party.actor_by_id(1).name, 'the actor was renamed on confirm'
  eq nil, scene.instance_variable_get(:@name_ui), 'the widget closed'
  3.times { scene.update }
  ok st.switches[5], 'the parallel process resumed after entry, not stuck forever'
end

check 'Enter Hero Name: draws a full-screen background behind the widget' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::NAME_INPUT, [1, 2, 0], indent: 0)] # actor 1, letters, no seed
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, NameStubParty.new)
  6.times do
    scene.update
    break if scene.instance_variable_get(:@name_ui)
  end
  ui = scene.instance_variable_get(:@name_ui)
  ok ui, 'the name-entry widget opened'
  ok ui[:background], 'a field background sprite is drawn behind the widget'
  eq RPG2k::WIDTH, ui[:background].bitmap.width, 'the backdrop covers the full screen width'
  eq RPG2k::HEIGHT, ui[:background].bitmap.height, 'the backdrop covers the full screen height'
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

check 'Enter Hero Name: hiragana/katakana grid opens on the requested page, seeded' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::NAME_INPUT, [1, 1, 1], indent: 0), # actor 1, katakana, seeded
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
  ok ui[:kana], 'opens the kana widget, not the letters grid'
  eq :katakana, ui[:page], 'charset 1 opens on the katakana page'
  eq 'Hero', ui[:name], 'seeded with the actor current name'
  eq 0, ui[:sel], 'cursor starts on the first cell'

  ok ui[:background], 'a field background sprite is drawn behind the kana widget'
  eq RPG2k::WIDTH, ui[:background].bitmap.width, 'the backdrop covers the full screen width'
  eq RPG2k::HEIGHT, ui[:background].bitmap.height, 'the backdrop covers the full screen height'

  field_text = ui[:name_win].contents.draw_calls.map { |c| c[4] }
  eq %w[H e r o _ _], field_text,
     'the name-so-far field shows the seeded characters, underscored past them'
end

check 'Enter Hero Name: typing a kana and confirming renames the actor' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::NAME_INPUT, [1, 0, 0], indent: 0), # actor 1, hiragana, no seed
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
  eq '', ui[:name], 'starts empty (no seed)'

  rows = RPG2k::Scene::Map::NAME_HIRAGANA_ROWS
  cols = RPG2k::Scene::Map::NAME_KANA_COLS
  eq 'あ', rows[0][0], 'the first cell is あ'

  # The cursor starts on あ; C types it.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 'あ', ui[:name], 'confirming the first cell types あ'

  # Jump the cursor to the confirm cell (last row, last logical column) and
  # confirm to commit.
  last_row = rows.length - 1
  ui[:sel] = last_row * cols + (rows[last_row].length - 1)
  eq :confirm, rows[last_row][rows[last_row].length - 1], 'landed on the confirm cell'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 'あ', st.party.actor_by_id(1).name, 'the actor was renamed on confirm'
  eq nil, scene.instance_variable_get(:@name_ui), 'the widget closed'
  3.times { scene.update }
  ok st.switches[5], 'the event resumed after entry'
end

check 'Enter Hero Name: the toggle cell swaps the hiragana/katakana page' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::NAME_INPUT, [1, 0, 0], indent: 0)]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, NameStubParty.new)
  6.times do
    scene.update
    break if scene.instance_variable_get(:@name_ui)
  end
  ui = scene.instance_variable_get(:@name_ui)
  ok ui, 'the name-entry widget opened'
  eq :hiragana, ui[:page], 'opens hiragana (charset 0)'

  rows = RPG2k::Scene::Map::NAME_HIRAGANA_ROWS
  cols = RPG2k::Scene::Map::NAME_KANA_COLS
  last_row = rows.length - 1
  toggle_col = rows[last_row].index(:toggle)
  ui[:sel] = last_row * cols + toggle_col
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :katakana, ui[:page], 'toggling from hiragana switches to katakana'
  ok scene.instance_variable_get(:@name_ui), 'the widget stays open after toggling'

  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :hiragana, ui[:page], 'toggling again switches back to hiragana'
end

check 'Enter Hero Name: the kana field stops at NAME_KANA_MAX characters' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::NAME_INPUT, [1, 0, 0], indent: 0)]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, NameStubParty.new)
  6.times do
    scene.update
    break if scene.instance_variable_get(:@name_ui)
  end
  ui = scene.instance_variable_get(:@name_ui)
  ok ui, 'the name-entry widget opened'
  max = RPG2k::Scene::Map::NAME_KANA_MAX
  eq 6, max, 'RPG2000 default name length is 6 kana'
  (max + 2).times do
    RGSS::Input.triggered = [RGSS::Input::C]
    scene.update
    RGSS::Input.triggered = []
  end
  eq max, ui[:name].length, 'typing past the limit stops adding characters'
end

check 'Enter Hero Name: the kana grid cursor wraps around' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::NAME_INPUT, [1, 0, 0], indent: 0)]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, NameStubParty.new)
  6.times do
    scene.update
    break if scene.instance_variable_get(:@name_ui)
  end
  ui = scene.instance_variable_get(:@name_ui)
  ok ui, 'the name-entry widget opened'
  cols = RPG2k::Scene::Map::NAME_KANA_COLS
  rows = RPG2k::Scene::Map::NAME_HIRAGANA_ROWS
  eq 10, cols
  eq 9, rows.length, '8 full rows plus a ragged last row'
  eq 8, rows.last.length, '6 kana plus the double-width toggle/confirm cells'

  # Row-local wrap: Right past the end of a full (10-cell) row wraps to that
  # same row's start.
  ui[:sel] = 9 # row 0, col 9 (last cell of row 0)
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.triggered = []
  eq 0, ui[:sel], 'Right from the last cell of row 0 wraps to its first cell'

  # ...and respects the ragged last row's narrower width (8 cells).
  last_row = rows.length - 1
  ui[:sel] = last_row * cols + (rows[last_row].length - 1) # the confirm cell
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.triggered = []
  eq last_row * cols, ui[:sel], 'Right from the last cell of the ragged row wraps to its own first cell'

  # Column wrap: Down from the last row wraps to row 0, keeping the column.
  ui[:sel] = last_row * cols + 1
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.triggered = []
  eq 1, ui[:sel], 'Down from the last row wraps to row 0, same column (1)'

  # Up from row 0 wraps to the last row, column clamped modulo its narrower
  # width (col 9 in a 10-wide row becomes col 1 of the 8-wide last row).
  ui[:sel] = 9
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.triggered = []
  eq last_row * cols + 1, ui[:sel], 'Up from row 0 wraps to the last row, column 9 % 8 == 1'
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

check 'a boarded boat cannot overlap a below-characters event unless it has Through Mode on' do
  # yado.tk: a below-characters, passable-graphic event lets the *walking*
  # hero overlap it fine (LAYER_BELOW is not LAYER_SAME, see the priority-type
  # checks above) -- but a ship ignores that gating entirely and just asks
  # whether the blocking event's own move route has Through Mode on. Put a
  # LAYER_BELOW event one tile past a boarded boat, on a boat_pass tile, and
  # confirm the boat is stopped cold by it despite the layer mismatch that
  # would let the hero glide over it.
  blocker = event(0, 2, page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW))
  scene = new_scene({ 1 => blocker }, player: [0, 0], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  st.direction = 2 # face down, toward (0, 1)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  RGSS::Input.triggered = [RGSS::Input::C] # board the boat ahead
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded, 'boarded the boat ahead'
  eq [0, 1], [st.x, st.y], 'stepped onto the boat tile'

  RGSS::Input.dir_value = 2 # hold down, toward the below-characters event
  20.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 1], [st.x, st.y],
     'a below-characters event stops a boat even though its layer would let ' \
     "the hero overlap it (got #{[st.x, st.y]})"

  # Turn the blocking event's own Through Mode on and try again: now the boat
  # passes it, matching real RPG_RT's ship-specific rule.
  chars(scene)[1].through = true
  RGSS::Input.dir_value = 2
  20.times { scene.update }
  RGSS::Input.dir_value = 0
  eq 0, st.x, 'only moved along the column it was already sailing'
  ok st.y > 1,
     "Through Mode on the blocking event let the boat pass it (was at y=1, now #{st.y})"
end

check 'Move Event drives an unboarded boat along a route, respecting vehicle_passable?' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target 10002 (boat), freq 8, repeat off, skippable on, MOVE_RIGHT.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10002, 8, 0, 1, R::MOVE_RIGHT])]
  one_shot_auto(auto, 9018)
  scene = new_scene({ 1 => event(0, 4, auto) }, player: [5, 0], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  40.times { scene.update }
  ok boat.x > 0, "the boat should have sailed east under its own route, at x=#{boat.x}"
  eq 1, boat.y, 'it stayed on its row'
  eq 6, boat.direction, 'facing the direction it moved (MOVE_RIGHT)'
end

check "a boat's move route is blocked by terrain the same way ordinary sailing is" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10002, 8, 0, 1, R::MOVE_RIGHT])]
  # boat_pass left false (the default): the whole map is unsailable.
  scene = new_scene({ 1 => event(0, 4, auto) }, player: [5, 0])
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  20.times { scene.update }
  eq 0, boat.x, 'terrain blocked it before it ever moved'
end

# EasyRPG's own Game_Player::MakeWay (src/game_player.cpp) unconditionally
# delegates to the ridden vehicle's own MakeWay whenever IsAboard(), with no
# separate branch for move-route-driven movement vs. ordinary input
# movement -- #try_move (the input path) already reads #vehicle_passable?
# once boarded (see the boat/below-characters-event checks above), but
# #step_player_route used to always step the player's route mirror against
# the plain on-foot @world regardless of @state.boarded?, so a boarded
# hero's own Set Move Route (Dash, Jump, plain movement, all alike) checked
# on-foot chipset passability instead of the ridden vehicle's own
# boat_pass/ship_pass/airship_pass clearance.
check "a boarded hero's own Set Move Route respects the ridden vehicle's " \
      'passability, not on-foot' do
  # boat_pass left false (the default): the whole map is unsailable for the
  # boat, exactly like "a boat's move route is blocked by terrain the same
  # way ordinary sailing is" above -- but every tile is still ordinarily
  # walkable on foot, so the pre-fix bug (checking on-foot passability while
  # boarded) would have let this route sail through anyway.
  scene = new_scene({}, player: [0, 1])
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  RGSS::Input.triggered = [RGSS::Input::C] # board the boat in place (same tile)
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded, 'boarded the boat'
  route = Game::MoveRoute.new([Game::MoveCommand.new(R::MOVE_RIGHT)],
                              repeat: false, skippable: true)
  scene.send(:start_player_route, route, 8)
  20.times { scene.update }
  eq [0, 1], [st.x, st.y],
     "the boarded hero's own Set Move Route must not sail where the boat itself " \
     "can't -- ended at (#{st.x}, #{st.y})"
end

check 'a Move Route request targeting a currently-ridden vehicle is ignored' do
  scene = new_scene({}, player: [0, 0], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  st.direction = 2 # face down, toward (0, 1)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  RGSS::Input.triggered = [RGSS::Input::C] # board the boat ahead
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded, 'boarded the boat'
  route = Game::MoveRoute.new([Game::MoveCommand.new(R::MOVE_RIGHT)],
                              repeat: false, skippable: true)
  scene.send(:force_vehicle_route, :boat, route, 8)
  eq nil, scene.instance_variable_get(:@vehicle_routes)[:boat],
     'the route request was dropped rather than fighting #follow_vehicle'
end

# EasyRPG's own Game_Interpreter::CommandMoveEvent (code 11330,
# src/game_interpreter.cpp): "If the event is a vehicle in use, push the
# commands to the player instead" -- a Move Event targeting a boat the party
# is currently riding drives the *player*, which the ridden boat already
# mirrors every frame (#follow_vehicle), producing a scripted "sail the boat
# across the map while the party stands on it" cutscene. #apply_move_request
# used to route this straight into #force_vehicle_route above, which
# deliberately no-ops while ridden -- so the whole move route was silently
# dropped instead of redirected onto the player.
check 'Move Event targeting a currently-ridden vehicle redirects onto the ' \
      'player instead of being dropped' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target 10002 (boat), freq 8, repeat off, skippable on, MOVE_RIGHT.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT, [10002, 8, 0, 1, R::MOVE_RIGHT])]
  one_shot_auto(auto, 9019)
  scene = new_scene({ 1 => event(0, 4, auto) }, player: [0, 1], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  st.boarded = :boat
  20.times { scene.update }
  ok st.x > 0,
     "the player (and the vehicle riding along with it) should have sailed " \
     "east under the redirected route, at x=#{st.x}"
  eq boat.x, st.x, "the ridden boat mirrors the player it was redirected onto"
  eq nil, scene.instance_variable_get(:@vehicle_routes)[:boat],
     'no separate vehicle-character route was ever armed for the boat itself'
end

# EasyRPG's own CommandSetVehicleLocation (src/game_interpreter.cpp): "Check
# if the party is in the current vehicle and transfer the party together with
# it" -- boarding the boat and issuing Set Vehicle Location for the *same*
# vehicle, on the current map, moves the whole party there too, not just the
# vehicle. Without this, rendering while boarded follows the player's own
# position, so the command had no visible effect at all, and the party's
# still-unmoved tile silently overwrote the vehicle right back on the very
# next completed step (#follow_vehicle).
check 'Set Vehicle Location moves the boarded party along with the vehicle' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # boat (0), literal mode, map 1 (the current one), x=8, y=6.
  auto.event_commands = [ECmd.new(ic::SET_VEHICLE_LOCATION, [0, 0, 1, 8, 6])]
  scene = new_scene({ 1 => event(0, 4, auto) }, player: [0, 0], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 0
  st.boarded = :boat
  3.times { scene.update }
  eq [8, 6], [boat.x, boat.y], 'the boat itself was repositioned'
  eq [8, 6], [st.x, st.y], 'and the boarded party rode along with it'
end

check 'Change Event Location repositions a vehicle' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # target 10002 (boat), absolute mode, x=3, y=2.
  auto.event_commands = [ECmd.new(ic::CHANGE_EVENT_LOCATION, [10002, 0, 3, 2])]
  scene = new_scene({ 1 => event(0, 4, auto) }, player: [5, 0])
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 0
  3.times { scene.update }
  eq [3, 2], [boat.x, boat.y], 'the boat was repositioned by Change Event Location'
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

check 'boarding the airship doubles the party\'s per-frame slide speed; boat/ship do not' do
  # Confirmed against EasyRPG's actual C++ source: Game_Vehicle's constructor
  # (src/game_vehicle.cpp) gives Boat/Ship `MoveSpeed_normal` -- identical to
  # the player's own on-foot default -- but the Airship `MoveSpeed_double`,
  # twice the per-frame step. #player_slide_speed is the port target.
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  # Default on-foot move_speed (3) advances 8 quarter-tile units/frame; the
  # Airship doubles that to 16. player_slide_step returns quarter-tile units.
  eq 8, scene.send(:player_slide_step), 'on foot: the ordinary speed'
  st.boarded = :boat
  eq 8, scene.send(:player_slide_step), 'boat: the ordinary speed too'
  st.boarded = :ship
  eq 8, scene.send(:player_slide_step), 'ship: the ordinary speed too'
  st.boarded = :airship
  eq 16, scene.send(:player_slide_step), 'airship: double the ordinary speed'
end

check 'Move Speed is no longer dead: it drives the per-frame slide, jump and anim' do
  scene = new_scene({}, player: [0, 0])
  # walk_slide_step returns quarter-tile units/frame. Default (3) -> 8 -> 8
  # frames/tile (unchanged baseline); fastest (6) -> 64 -> 1 frame/tile;
  # slowest (1) -> 2 -> 32 frames/tile. Before this fix every speed ignored
  # move_speed and advanced a hardcoded 2 TILE-units (= 8 quarter-units)/frame.
  eq 2,  scene.send(:walk_slide_step, 1)
  eq 8,  scene.send(:walk_slide_step, 3)
  eq 64, scene.send(:walk_slide_step, 6)
  # Jump uses its own table (default 3 -> 6 quarter-units/frame, ~11 frames),
  # not the walk rate.
  eq 6,  scene.send(:jump_slide_step, 3)
  # Animation cadence is move_speed-dependent; default (3) keeps the prior 6.
  eq 6,  scene.send(:anim_frame_period, 3)
  eq 4,  scene.send(:anim_frame_period, 5)
end

check 'the airship crosses a tile in half the frames walking on foot takes' do
  on_foot = new_scene({}, player: [0, 0])
  RGSS::Input.dir_value = 6 # east
  frames_on_foot = 0
  st_foot = on_foot.instance_variable_get(:@state)
  until st_foot.x == 1
    on_foot.update
    frames_on_foot += 1
    break if frames_on_foot > 30
  end
  RGSS::Input.dir_value = 0
  ok st_foot.x == 1, 'walked the tile'

  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 0
  air.y = 0
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded

  RGSS::Input.dir_value = 6
  frames_flying = 0
  until st.x == 1
    scene.update
    frames_flying += 1
    break if frames_flying > 30
  end
  RGSS::Input.dir_value = 0
  ok st.x == 1, 'flew the tile'
  # One frame registers the input and starts the slide (the same on foot or
  # flying -- this fixed frame doesn't scale with speed); the remaining
  # frames cover the tile's 16px at SPEED px/frame walking, or 2*SPEED
  # flying, so the *slide* portion halves even though the totals don't.
  eq 1 + (frames_on_foot - 1) / 2, frames_flying,
     "the airship's slide is exactly half the length of the on-foot one"
end

check 'the airship cannot land on a tile a map event occupies unless it has Through Mode on' do
  # yado.tk: an airship can never land on a tile a map event occupies,
  # regardless of terrain. Flying itself ignores events entirely
  # (#vehicle_passable?'s airship branch never reads @event_tiles), so the
  # airship can cruise -- and be boarded -- directly over a below-characters
  # event a walking hero would just as happily overlap; landing there must
  # still refuse it, the same vehicle-specific "any layer, only the blocking
  # event's own Through Mode lets it through" rule already confirmed for a
  # boarded boat/ship (see the boat/below-characters-event check above).
  blocker = event(0, 0, page(trigger: 0, layer: RPG2k::Scene::Map::LAYER_BELOW))
  scene = new_scene({ 1 => blocker }, player: [0, 0], airship_land: true)
  st = scene.instance_variable_get(:@state)
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 0
  air.y = 0
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'boarded the airship in place, directly over the event'
  # Try to land: the below-characters event on this tile still blocks it,
  # despite airship_land: true and despite its layer being one the hero's own
  # passability would happily overlap.
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'a below-characters event on the tile still blocked landing'

  # Turn the blocking event's own Through Mode on and try again: now it lands.
  chars(scene)[1].through = true
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  ok !st.boarded?, 'Through Mode on the blocking event let the airship land'
  eq [0, 0], [st.x, st.y], 'the party stands where the airship touched down'
end

check 'an unridden boat/ship blocks the hero on foot, but an unridden airship does not' do
  # Verified against EasyRPG Player's actual C++ source: Game_Map::
  # CheckOrMakeWayEx blocks every character type (the player included) on a
  # parked Boat/Ship's own tile, but only checks the Airship when
  # self.GetType() != Player -- a walking hero passes clean over one.
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 1
  boat.y = 0
  RGSS::Input.dir_value = 6 # hold right, straight into the parked boat
  10.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 0], [st.x, st.y], 'an unridden boat blocks the hero on foot, same as a same-layer event'

  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 0
  air.y = 1
  RGSS::Input.dir_value = 2 # hold down, straight into the parked airship
  10.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 1], [st.x, st.y], 'an unridden airship never blocks the hero on foot'
end

check 'an unridden boat/ship/airship all block a map event\'s own custom-route movement' do
  # Unlike the hero (checked above), an event's own movement has no Player
  # exemption for the Airship: EasyRPG's CheckOrMakeWayEx only skips the
  # Airship check when self.GetType() == Player, so every other mover -- a
  # map event's autonomous/custom route, and the player's own forced Set
  # Move Route mirror -- is blocked by all three vehicle types alike.
  east = event(0, 1, page(x_move_type: Game::MoveType::CUSTOM,
                          route: move_route([R::MOVE_RIGHT])))
  scene = new_scene({ 1 => east }, player: [5, 5])
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 1
  boat.y = 1
  200.times { scene.update }
  eq 0, chars(scene)[1].x, 'an unridden boat stops the event dead before its first step'

  south = event(2, 0, page(x_move_type: Game::MoveType::CUSTOM,
                           route: move_route([R::MOVE_DOWN])))
  scene2 = new_scene({ 1 => south }, player: [5, 5])
  st2 = scene2.instance_variable_get(:@state)
  air = st2.vehicle(:airship)
  air.map_id = st2.map_id
  air.x = 2
  air.y = 1
  200.times { scene2.update }
  eq 0, chars(scene2)[1].y,
     'an unridden airship stops the event too, unlike its hero-on-foot exemption above'
end

# Real RPG_RT lets a moving Boat/Ship collide with a *different*, parked
# vehicle, and refuses an Airship landing on top of one -- the direction the
# checks above never exercised (an unridden vehicle blocking a walking hero
# or a map event), and one this codebase's own #vehicle_passable? /
# #airship_landable? never checked at all before this fix: neither ever
# consulted another vehicle's own position, so a party riding a Boat could
# sail straight through a parked Ship or a grounded Airship, and a landing
# Airship could set down right on top of a parked Boat/Ship. Verified
# against RPG_RT's actual behavior via EasyRPG Player's own C++ source
# (src/game_map.cpp): `Game_Map::CheckOrMakeWayEx` loops `{ Boat, Ship }` for
# any non-Airship mover, then also checks a grounded Airship whenever the
# mover is not the on-foot Player -- true for a ridden Boat/Ship, which
# moves as its own `Vehicle`-typed character, never `Player` -- and
# `Game_Map::CanLandAirship` separately loops `{ Boat, Ship }` and refuses a
# landing on either's tile. Fixed by reusing `#vehicle_blocks?` (already
# used for the opposite direction, tested above) from both
# `#vehicle_passable?` and `#airship_landable?`.
check 'a moving boat collides with a different parked ship, and with a ' \
      'grounded airship' do
  scene = new_scene({}, player: [0, 0], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 0 # under the party; board in place
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded, 'boarded the boat in place'

  ship = st.vehicle(:ship)
  ship.map_id = st.map_id
  ship.x = 1
  ship.y = 0
  RGSS::Input.dir_value = 6 # hold right, straight into the parked ship
  10.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 0], [st.x, st.y], 'a different parked vehicle (the ship) blocks the boat'

  # Move the ship out of the way and put a grounded airship there instead.
  ship.map_id = 0
  air = st.vehicle(:airship)
  air.map_id = st.map_id
  air.x = 1
  air.y = 0
  RGSS::Input.dir_value = 6
  10.times { scene.update }
  RGSS::Input.dir_value = 0
  eq [0, 0], [st.x, st.y], 'a grounded airship blocks the boat too'
end

check 'the airship cannot land on a parked boat/ship\'s tile' do
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

  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 0 # right where the airship would land in place
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq :airship, st.boarded, 'a parked boat under the airship blocks the landing'

  boat.map_id = 0 # move it away: landing now succeeds
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  ok !st.boarded?, 'landing succeeds once the tile is clear'
end

check 'Show Battle Animation with the wait flag holds the event then resumes' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # animation 10 has real frame data (a real, non-zero #missing_animation_wait
  # duration) but its own 'GhostAnim' cache entry is poisoned below to
  # simulate an unloadable Battle/<name> sheet, so this exercises the
  # timed-wait fallback path without depending on animation id 7's own
  # (now instant, 0-frame) invalid-id wait.
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [10, 10001, 1], indent: 0), # animation, player, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  scene.instance_variable_get(:@animation_cache)['GhostAnim'] = nil
  st = scene.instance_variable_get(:@state)
  3.times { scene.update }
  ok !st.switches[5], 'the event is held while the animation plays'
  60.times { scene.update } # outlast the fallback animation length
  ok st.switches[5], 'the event resumes once the animation finishes'
end

# #missing_animation_wait's own two branches, pinned directly (see its own
# doc comment in mruby-rpg2k/mrblib/scene/map.rb): an invalid/unknown
# animation id waits 0 real frames -- no one-frame floor, matching
# EasyRPG's Game_Interpreter wait_time == 0 fallthrough -- while a valid row
# with real frame data waits that row's own real duration regardless of
# whether its graphic sheet loads (the sheet is never consulted here at
# all).
check "#missing_animation_wait waits 0 for an invalid/unknown animation id" do
  scene = new_scene({})
  eq 0, scene.send(:missing_animation_wait, 7), 'animation 7 is absent from the fake db'
  eq 0, scene.send(:missing_animation_wait, nil), 'a nil animation id is also invalid'
end

check "#missing_animation_wait waits the row's own real duration for a valid animation, sheet aside" do
  scene = new_scene({})
  eq 8, scene.send(:missing_animation_wait, 8),
     'animation 8 has 4 real frames * ANIM_CELL_FRAMES (2) = 8, whether or not its sheet ever loads'
  eq 24, scene.send(:missing_animation_wait, 10),
     'animation 10 has 12 real frames * ANIM_CELL_FRAMES (2) = 24'
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

# EasyRPG's own Game_Interpreter_Map::CommandShowBattleAnimation
# (src/game_interpreter_map.cpp) always starts the animation through
# Game_Screen::ShowBattleAnimation regardless of the wait flag -- the flag only
# gates whether the interpreter's own wait_time is set afterwards. This
# codebase used to only ever start an animation from the :animation wait
# dispatch (#drive_map_animation), which a non-waiting command never reaches
# at all, so a "wait until it finishes" flag left unchecked silently dropped
# the play instead of firing it in the background.
check 'Show Battle Animation with the wait flag off still plays, without blocking the event' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # animation 8 (the same drawable one the wait=1 check above uses) on the
  # player, wait flag OFF this time.
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 0], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  one_shot_auto(auto, 9020)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  spr = scene.instance_variable_get(:@animation_sprite)
  shown = false
  flashed = false
  not_blocked = nil
  40.times do |i|
    scene.update
    shown ||= spr.visible
    flashed ||= st.screen.flashing?
    not_blocked = st.switches[6] if i == 2
  end
  ok not_blocked, 'the event is not held by a fire-and-forget Show Battle Animation'
  ok shown, 'the animation sprite was shown even though the wait flag was off'
  ok flashed, 'a screen-flash timing fired during the fire-and-forget animation'
  ok !spr.visible, 'the animation sprite is hidden once it finishes'
end

# yado.tk (corroborated independently against EasyRPG's own C++ source, see
# #hold_animation_screen_flash's comment): Screen Flash is capped to 1/30s of
# display while a Battle Animation is playing, since the animation
# continuously re-asserts its own per-frame flash state -- overwriting an
# unrelated, still-ticking Screen Flash the very next real frame, regardless
# of that flash's own configured duration. Fired here with wait off (so the
# event moves straight on to the animation instead of blocking on the flash's
# own long duration) and a 20-tenths-of-a-second (120-frame) duration --
# animation 8's own frame 0 carries no timing at all (its one flash_scope-2
# timing is on frame 1), so the very first real frames the animation drives
# have nothing of their own to show and must be stomping the unrelated flash
# to nothing on their own.
check 'A Screen Flash concurrent with a Show Battle Animation is capped to the current frame' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::FLASH_SCREEN, [31, 31, 31, 20, 20, 0], indent: 0), # r g b power duration wait=0
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),       # animation, player, wait=1
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  stomped_at_frame_0 = false
  saw_the_flash_at_all = false
  40.times do
    scene.update
    saw_the_flash_at_all ||= st.screen.flashing?
    anim = scene.instance_variable_get(:@map_animation)
    stomped_at_frame_0 ||= (anim && anim[:frame_i] == 0 && !st.screen.flashing?)
    break if st.switches[6]
  end
  ok saw_the_flash_at_all, 'the independently-fired Flash Screen command did take effect at some point'
  ok stomped_at_frame_0, "the battle animation's own per-frame state stomps the unrelated flash to " \
                         "nothing during its own timing-less opening frames, capping it well short of " \
                         'its own configured 120-frame duration'
  ok st.switches[6], 'the event resumed after the animation'
end

# yado.tk's own "Character Flash" half of the same claim, capped the same way
# and for the same reason (corroborated independently against EasyRPG's own
# C++ source, see #hold_animation_target_flash's comment):
# `BattleAnimation::Update` calls `UpdateTargetFlash()` unconditionally right
# alongside `UpdateScreenFlash()` on every real frame, and it always ends in
# an unconditional `FlashTargets(r, g, b, p)` the same way `FlashOnce` is for
# the screen. Fired here with a Flash Sprite (11320) on the player (wait off,
# so the event moves straight on to the animation instead of blocking on the
# flash's own long duration), then animation 8 -- the screen-flash-only
# fixture, no flash_scope-1 timing at all -- targeting the player: its own
# timing-less opening frames must stomp the unrelated Character Flash to
# nothing the same way they already do the unrelated Screen Flash above.
check 'A Character Flash concurrent with a Show Battle Animation targeting the same character is capped ' \
      'to the current frame' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::FLASH_SPRITE, [10001, 31, 0, 0, 31, 20, 0], indent: 0), # player, r g b power, 2s, wait=0
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),            # animation 8, player, wait=1
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  stomped_at_frame_0 = false
  saw_the_flash_at_all = false
  40.times do
    scene.update
    pf = scene.instance_variable_get(:@player_flash)
    saw_the_flash_at_all ||= !pf.nil?
    anim = scene.instance_variable_get(:@map_animation)
    stomped_at_frame_0 ||= (anim && anim[:frame_i] == 0 &&
                            scene.instance_variable_get(:@player_flash).nil?)
    break if st.switches[6]
  end
  ok saw_the_flash_at_all, 'the independently-fired Flash Sprite command did take effect at some point'
  ok stomped_at_frame_0, "the battle animation's own per-frame state stomps the unrelated Character Flash " \
                         "to nothing during its own timing-less opening frames, capping it well short of " \
                         'its own configured 120-frame duration'
  ok st.switches[6], 'the event resumed after the animation'
end

# yado.tk: Show Battle Animation targeting a Vehicle position reads that
# vehicle's real, currently-live x/y (the same source the Control Variables
# vehicle-position fix reads), not the player's or the triggering event's own
# tile. #animation_target_pixel had no branch for a vehicle's Move-Event-style
# target id (10002-10004) at all, so it fell through to the generic "map event
# by id" lookup, found none, and silently defaulted to the player's own
# position.
check "Show Battle Animation targeting a vehicle uses the vehicle's own live position" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # animation 8 (a drawable one in the fake db) targeting the boat (10002).
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10002, 1], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  # Placed well away from both the player (0,0) and the triggering event
  # (2,2), so either one substituting for the boat would be caught.
  st.vehicle(:boat).map_id = st.map_id
  st.vehicle(:boat).x = 5
  st.vehicle(:boat).y = 7
  tile = RPG2k::Scene::Map::TILE
  anim = nil
  40.times do
    scene.update
    anim = scene.instance_variable_get(:@map_animation)
    break if anim || st.switches[6]
  end
   ok anim, 'the animation actually started'
   eq [5 * tile, 7 * tile], [anim[:targets][0][:tx], anim[:targets][0][:ty]],
      "targeted the boat's own live position, not the player's or the event's"
end

# A map-triggered Show Battle Animation's target is always drawn from a
# Game::CharSet frame -- the player, a map event or a vehicle, see
# #draw_vehicles sizing a vehicle sprite off the same constant -- so
# #start_map_animation can hand #animation_position_offset a real height
# unconditionally, unlike the battle path's ally-side "no sprite" fallback.
# That height is ANIM_MAP_TARGET_HEIGHT (24), not Game::CharSet::HEIGHT
# (32) -- confirmed against EasyRPG's own BattleAnimationMap::DrawSingle
# (`const int character_height = 24;`, src/battle_animation.cpp), a
# hardcoded constant unrelated to the actual CharSet frame's pixel height
# despite reading like it should be the same thing.
check "a map-triggered Show Battle Animation carries RPG_RT's own 24px map-target height" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0), # animation, player, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  anim = nil
  40.times do
    scene.update
    anim = scene.instance_variable_get(:@map_animation)
    break if anim
  end
   ok anim, 'the animation actually started'
   eq RPG2k::Scene::Map::ANIM_MAP_TARGET_HEIGHT, anim[:targets][0][:height],
      "RPG_RT's own hardcoded 24px map-target height, not the CharSet frame's 32px " \
      'or the battle-only nil fallback'
end

# A map-triggered Show Battle Animation's flash_scope-1 timing used to be
# silently dropped: #fire_animation_flashes only ever reached
# #fire_target_flash's battle-only enemy-sprite mechanism, which a map scene
# (no @battle_ui at all) can never populate, so the flash simply never fired.
# #fire_map_target_flash reuses the Flash Sprite command's own CharSet-tone
# mechanism (@player_flash / an @events entry's [:flash]) instead of
# inventing a second one. Animation 9 in the fake db carries a flash_scope 1
# timing (see the fake-db comment above) rather than id 8's flash_scope 2, so
# this is isolated from the screen-flash check above.
check "a map-triggered Show Battle Animation's target-scope flash pulses the player" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [9, 10001, 1], indent: 0), # animation, player, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  seen = false
  40.times do
    scene.update
    pf = scene.instance_variable_get(:@player_flash)
    seen ||= (pf && pf[:red] == 248 && pf[:green] == 0 && pf[:blue] == 0)
    break if st.switches[6]
  end
  ok seen, "the player's flash was armed, scaled from the LCF 0..31 fixture fields the same *8 way " \
           'the battle-side enemy flash already is'
  ok st.switches[6], 'the event resumed after the animation'
end

# screen_shaking (LCF database field 8 on an animation timing: 0 none / 1
# target / 2 screen, decoded by mruby-lcf/mrblib/schema.rb) was decoded but
# never read by #fire_animation_flashes at all. Verified against EasyRPG
# Player's actual C++ source, `BattleAnimation::ProcessAnimationTiming`
# (src/battle_animation.cpp, fetched verbatim): screen_shaking 2 fires
# `screen->ShakeOnce(3, 5, 32)` from the shared base class, with no
# `ma[:battle]` gate the way the target case just below needs one -- so a
# map-triggered Show Battle Animation shakes the whole screen exactly the
# same way a battle-round one does (see the battle-round check further down),
# reusing the exact Game::Screen#shake call/argument order the Shake Screen
# event command (11050, #do_shake_screen) already drives rather than
# inventing a second shake mechanism. A hand-built timing (rather than a
# fixture animation) isolates it the same way the flash_scope-1 check above
# does.
check 'a map-context screen-scope animation shake triggers the same Game::Screen#shake state as Shake Screen' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  ok !st.screen.shaking?, 'not shaking to start with'
  timing = OpenStruct.new(frame: 0, screen_shaking: 2)
  ma = { frame_i: 0, timings: [timing] } # no :battle key -- the map path
  scene.send(:fire_animation_flashes, ma)
  ok st.screen.shaking?, 'the screen shake started on the map path too'
end

# screen_shaking 1 ("target") on a map-triggered Show Battle Animation is a
# genuine no-op, not a dropped feature: EasyRPG's own `BattleAnimationMap::
# ShakeTargets` (src/battle_animation.cpp, fetched verbatim) is an empty
# method body -- `void BattleAnimationMap::ShakeTargets(int, int, int) {}` --
# unlike `BattleAnimationBattle`/`BattleAnimationBattler`'s real per-battler
# shake (see the battle-round check further down). #fire_animation_flashes
# only calls #fire_target_shake when `ma[:battle]`, matching that real split
# rather than treating the map path as an oversight to fill in.
check 'a map-context target-scope animation shake is a real no-op, matching BattleAnimationMap::ShakeTargets' do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  timing = OpenStruct.new(frame: 0, screen_shaking: 1)
  ma = { frame_i: 0, timings: [timing] } # no :battle key -- the map path
  scene.send(:fire_animation_flashes, ma) # must not raise
  ok !st.screen.shaking?, 'never touches the whole-screen shake either'
end

# The same timing aimed at a named map event instead pulses *that* event's own
# flash, not the player's -- #map_animation_flash_target resolves a plain
# event id the same way #animation_target_pixel already does for centring the
# animation itself.
check "a map-triggered Show Battle Animation's target-scope flash pulses the named map event, not the player" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [9, 2, 1], indent: 0), # animation, event 2, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  target_pg = page(trigger: 0) # stationary, never triggers on its own
  scene = new_scene({ 1 => event(2, 2, auto), 2 => event(4, 4, target_pg) })
  st = scene.instance_variable_get(:@state)
  seen_target = false
  seen_player = false
  40.times do
    scene.update
    ev2 = event_hashes(scene)[2]
    seen_target ||= (ev2[:flash] && ev2[:flash][:red] == 248)
    seen_player ||= !scene.instance_variable_get(:@player_flash).nil?
    break if st.switches[6]
  end
  ok seen_target, "the targeted map event's own flash was armed"
  ok !seen_player, 'the player, who was not the target, was never flashed'
  ok st.switches[6], 'the event resumed after the animation'
end

# #map_animation_flash_target's own target-id decoding, isolated from the
# full event pipeline above: a vehicle resolves to its own Game::Vehicle::TYPES
# symbol (see #fire_map_target_flash / #clear_map_target_flash below -- this
# used to be a bare nil, "a vehicle has no CharSet-tone flash mechanism to
# hook," which was true of the player/event mechanism specifically but wrongly
# treated as "no mechanism at all": a vehicle already draws through a real
# Sprite, which #fire_map_target_flash now pulses directly instead), an id no
# live event matches resolves to nothing, and "this event" (0 / MOVE_TARGET_THIS)
# mirrors #animation_target_pixel's own fallback to the player when there is no
# active event (a common event Parallel Process's own Show Battle Animation has
# none).
check '#map_animation_flash_target resolves vehicle, unknown-id and "this event" targets' do
  scene = new_scene({ 3 => event(1, 1, page) })
  mt = RPG2k::Scene::Map
  eq :player, scene.send(:map_animation_flash_target, mt::MOVE_TARGET_PLAYER)
  eq :boat, scene.send(:map_animation_flash_target, mt::MOVE_TARGET_BOAT),
     "a vehicle target resolves to its own Game::Vehicle::TYPES symbol, not nil"
  eq :ship, scene.send(:map_animation_flash_target, mt::MOVE_TARGET_SHIP)
  eq :airship, scene.send(:map_animation_flash_target, mt::MOVE_TARGET_AIRSHIP)
  eq nil, scene.send(:map_animation_flash_target, 999), 'an id no live event matches'
  eq :player, scene.send(:map_animation_flash_target, 0),
     '"this event" with no active event (a common event Parallel Process) falls back to the player'
  ev3 = event_hashes(scene)[3]
  scene.instance_variable_set(:@active_event, ev3)
  eq ev3, scene.send(:map_animation_flash_target, mt::MOVE_TARGET_THIS),
     '"this event" with an active event resolves to it'
end

# A map-triggered Show Battle Animation's flash_scope-1 timing aimed at a
# vehicle now actually pulses that vehicle's own on-screen sprite, instead of
# being silently dropped as an "unsupported target." Verified against EasyRPG
# Player's actual C++ source rather than assumed unsupported:
# Game_Character::GetCharacter (src/game_character.cpp) resolves
# CharBoat/CharShip/CharAirship straight to the live Game_Vehicle object -- a
# Game_Character subclass -- so BattleAnimationMap::FlashTargets's own
# target->Flash(...) call (src/battle_animation.cpp) reaches a vehicle exactly
# like it reaches the player or a map event; nothing in real RPG_RT exempts
# it. Unlike the player/event case (a CharSet tint mixed into the drawn
# frame), a vehicle already draws through a real Sprite (#draw_vehicles), so
# #fire_map_target_flash reaches @vehicle_sprites[:boat] directly with the
# native RGSS Sprite#flash primitive #fire_target_flash already uses for a
# battle enemy sprite -- exercised directly here (mirroring the battle-side
# "a target-scope animation flash pulses the hit enemy" check above), isolated
# from the full animation/event pipeline the player/event checks above cover.
check '#fire_map_target_flash/#update_vehicle_flashes pulse a targeted vehicle sprite and decay it' do
  scene = new_scene({})
  sprites = scene.instance_variable_get(:@vehicle_sprites)
  spr = sprites[:boat]
  bystander = sprites[:ship]
  timing = OpenStruct.new(flash_red: 31, flash_green: 0, flash_blue: 0, flash_power: 20)
  scene.send(:fire_map_target_flash, :boat, timing)
  ok spr.flash_color, 'the targeted vehicle sprite was flashed'
  eq [248, 0, 0, 160],
     [spr.flash_color.red, spr.flash_color.green, spr.flash_color.blue, spr.flash_color.alpha],
     'scaled from the LCF 0..31 fixture fields the same *8 way the player/enemy flash already is'
  anim_flash_frames = RPG2k::Scene::Map::ANIM_FLASH_FRAMES
  eq anim_flash_frames, spr.flash_calls.last[1],
     'held for the same duration a battle-side target flash gets'
  eq nil, bystander.flash_color, 'a different, untargeted vehicle is untouched'
  # Before this fix nothing ever called Sprite#update on a vehicle sprite at
  # all -- the real native Sprite#flash only decays (and its visible
  # intensity only fades) when driven by an explicit #update each frame
  # (mruby-rgss/src/lib.cxx's spr_flash/spr_update, the same contract
  # #update_enemy_flashes already drives for battle-only enemy sprites), so a
  # vehicle's flash would have stayed at full intensity forever in the real
  # renderer. #update_vehicle_flashes closes that gap, called unconditionally
  # every real frame from #update.
  anim_flash_frames.times { scene.send(:update_vehicle_flashes) }
  eq nil, spr.flash_color, 'the flash faded out after its duration'
end

# The same timing, driven through the full event/animation pipeline this time
# (mirroring "a map-triggered Show Battle Animation's target-scope flash
# pulses the player" above), confirming #map_animation_flash_target's new
# vehicle resolution and #fire_map_target_flash's new vehicle dispatch are
# actually wired together end to end, not just individually correct.
check "a map-triggered Show Battle Animation's target-scope flash pulses a targeted vehicle" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [9, 10002, 1], indent: 0), # animation, boat, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.vehicle(:boat).map_id = st.map_id
  st.vehicle(:boat).x = 5
  st.vehicle(:boat).y = 7
  spr = scene.instance_variable_get(:@vehicle_sprites)[:boat]
  seen = false
  40.times do
    scene.update
    seen ||= (spr.flash_color && spr.flash_color.red == 248 && spr.flash_color.green == 0 &&
              spr.flash_color.blue == 0)
    break if st.switches[6]
  end
  ok seen, "the boat's own sprite was flashed via the full event pipeline"
  ok st.switches[6], 'the event resumed after the animation'
end

# yado.tk: only one Battle Animation is ever on screen at once -- true of the
# map-level Show Battle Animation command (11210) same as an in-battle one.
# That only means anything if a *parallel process* can show one at all: before
# this fix, #drive_parallel_wait's wait-kind dispatch had no :animation branch,
# so it fell into the generic "background: ignore message/choice/teleport
# requests" case and called #resume immediately -- the animation was never
# built or drawn, and the "wait until it finishes" flag did nothing.
check "a Common Event Parallel Process's Show Battle Animation (wait) actually plays and blocks it" do
  ic = Game::Interpreter::Cmd
  # animation 10 has real frame data but its own 'GhostAnim' cache entry is
  # poisoned below to simulate an unloadable sheet, so this exercises the
  # timed-wait fallback path (see the fallback-wait check above).
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [ECmd.new(ic::SHOW_BATTLE_ANIM, [10, 10001, 1], indent: 0),
                              ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce })
  scene.instance_variable_get(:@animation_cache)['GhostAnim'] = nil
  st = scene.instance_variable_get(:@state)
  3.times { scene.update }
  ok !st.switches[5],
     'the parallel process must be held while the animation plays, not resumed at once'
  60.times { scene.update } # outlast the fallback animation length
  ok st.switches[5], 'the parallel process resumes once the animation finishes'
end

check "a Common Event Parallel Process's Show Battle Animation draws a sprite and flash" do
  ic = Game::Interpreter::Cmd
  # animation 8 is the drawable one in the fake db (see the foreground check
  # above) -- this pins that a parallel process's request reaches the same
  # renderer, not just that its own wait resolves.
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),
                              ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce })
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
  ok shown, 'the animation sprite was shown while the parallel process\'s animation played'
  ok flashed, 'a screen-flash timing fired during it'
  ok st.switches[6], 'the parallel process resumed after the animation'
end

# yado.tk: only one Battle Animation is ever on screen, and a *second* one
# forcibly cuts the first off rather than queueing behind it -- confirmed
# against EasyRPG Player's actual C++ source (Game_Screen::ShowBattleAnimation,
# src/game_screen.cpp, a bare unconditional unique_ptr::reset()), see
# #drive_map_animation's own comment. Before this fix a second request while
# the shared slot was held simply sat there doing nothing every frame until
# the first one finished naturally -- never cutting it off, and (worse) had
# no way to notice being torn down either, since ownership never changed
# hands mid-flight.
check 'a second Show Battle Animation forcibly cuts off a still-playing first one' do
  ic = Game::Interpreter::Cmd
  # CE1's animation 10 has real frame data but its own 'GhostAnim' cache
  # entry is poisoned below to simulate an unloadable sheet, so it parks on
  # its own real (24-tick) timed-wait fallback -- long enough that CE2's own
  # animation can cut it off well before it would ever finish naturally.
  ce1 = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                       event: [ECmd.new(ic::SHOW_BATTLE_ANIM, [10, 10001, 1], indent: 0),
                               ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)])
  # CE2 waits a moment first (so CE1's animation is already in flight), then
  # fires its own -- animation 8, the fake db's drawable one.
  ce2 = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                       event: [ECmd.new(ic::WAIT, [1], indent: 0),
                               ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),
                               ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce1, 2 => ce2 })
  scene.instance_variable_get(:@animation_cache)['GhostAnim'] = nil
  st = scene.instance_variable_get(:@state)
  3.times { scene.update }
  ok !st.switches[5], 'CE1 is still parked on its own long fallback wait'
  ok scene.instance_variable_get(:@anim_wait), "CE1 has claimed the shared slot (fallback path)"
  # CE2's own Wait[1] (~6 frames) elapses well before CE1's ~24-frame fallback
  # would ever finish naturally, so bound the search to comfortably less than
  # that: if the slot is still showing CE1's fallback wait by frame 15, CE2
  # never cut it off at all -- it is still queued behind CE1, the pre-fix bug.
  15.times do
    scene.update
    break if scene.instance_variable_get(:@map_animation)
  end
  ok scene.instance_variable_get(:@map_animation),
     "the shared slot now shows CE2's own (drawable) animation instead of CE1's fallback wait, " \
     "well before CE1's own ~24-frame duration could have finished it naturally"
  ok !st.switches[6], 'CE2 has not resumed yet -- its own animation only just started'
  # CE1 was resumed the instant it was cut off (this same pass), but its own
  # trailing Control Switches command only runs on the *next* step_parallel
  # call for it (only a :wait wait-kind gets the same-frame "spend this
  # frame's own budget immediately" treatment) -- give it one more frame to
  # actually reach it, well short of the fallback's own ~24-frame duration.
  scene.update
  ok st.switches[5],
     "CE1 resumed the instant its animation was cut off, well short of the fallback's own ~24-frame duration"
  60.times { scene.update }
  ok st.switches[6], 'CE2 resumes once its own animation finishes'
end

# The same "second cuts off the first" rule as the check just above, but for
# the *no-wait* half of Show Battle Animation, verified against EasyRPG's
# actual C++ source rather than guessed at: `Game_Screen::ShowBattleAnimation`
# is a bare unconditional `animation.reset(...)` with no branch on the *new*
# request's own wait flag at all -- only the *issuing* interpreter's resulting
# wait is conditional on that. `#drive_map_animation`'s own cut-off fix is
# only ever reachable through the `:animation` wait dispatch, so it only ever
# ran for a *waited-for* second request; a fire-and-forget one -- routed
# through `#apply_battle_animation_request` instead, since it never parks on
# a wait of its own -- used to just check whether the shared slot was free
# and silently drop itself otherwise, leaving CE1's animation running
# untouched and CE1 itself stuck waiting out its own fallback naturally
# instead of being cut off.
check 'a fire-and-forget Show Battle Animation also forcibly cuts off a still-playing first one' do
  ic = Game::Interpreter::Cmd
  # CE1's animation 10 has real frame data but its own 'GhostAnim' cache
  # entry is poisoned below to simulate an unloadable sheet, so it parks on
  # its own real (24-tick) timed-wait fallback -- long enough that CE2's own
  # fire-and-forget animation can cut it off well before it would ever
  # finish naturally.
  ce1 = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                       event: [ECmd.new(ic::SHOW_BATTLE_ANIM, [10, 10001, 1], indent: 0),
                               ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)])
  # CE2 waits a moment first (so CE1's animation is already in flight), then
  # fires its own -- animation 8, the fake db's drawable one -- with the
  # "wait until it finishes" flag *off* (the third SHOW_BATTLE_ANIM parameter
  # is 0, unlike the waited-for check above).
  ce2 = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                       event: [ECmd.new(ic::WAIT, [1], indent: 0),
                               ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 0], indent: 0),
                               ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce1, 2 => ce2 })
  scene.instance_variable_get(:@animation_cache)['GhostAnim'] = nil
  st = scene.instance_variable_get(:@state)
  3.times { scene.update }
  ok !st.switches[5], 'CE1 is still parked on its own long fallback wait'
  ok scene.instance_variable_get(:@anim_wait), 'CE1 has claimed the shared slot (fallback path)'
  # CE2's own Wait[1] (~6 frames) elapses well before CE1's ~24-frame fallback
  # would ever finish naturally, so bound the search to comfortably less than
  # that: if the slot never shows CE2's own drawable animation by frame 15,
  # CE2's fire-and-forget request was dropped instead of cutting CE1 off --
  # the pre-fix bug (CE2's request is lost forever in that case, not merely
  # delayed, since nothing keeps retrying it the way a waiting interpreter
  # implicitly does).
  15.times do
    scene.update
    break if scene.instance_variable_get(:@map_animation)
  end
  ok scene.instance_variable_get(:@map_animation),
     "the shared slot now shows CE2's own (drawable) animation instead of CE1's fallback wait, " \
     "well before CE1's own ~24-frame duration could have finished it naturally"
  ok scene.instance_variable_get(:@map_animation_interp).nil?,
     "CE2's own request is fire-and-forget -- nothing is parked waiting on it"
  # CE1 was resumed the instant it was cut off (this same pass, during CE2's
  # own turn later in the same step_parallels sweep), but its own trailing
  # Control Switches command only runs on the *next* step_parallel call for
  # it -- give it one more frame to actually reach it, well short of the
  # fallback's own ~24-frame duration (mirrors the waited-for check above).
  scene.update
  ok st.switches[5],
     "CE1 resumed the instant its animation was cut off, well short of the fallback's own ~24-frame duration"
  40.times { scene.update }
  ok st.switches[6], "CE2's own command list reached its trailing Control Switches (it was never blocked by its own no-wait animation)"
end

# yado.tk: "Battle Animation... chaining two Show Battle Animation calls
# back-to-back produces a visible one-frame stutter." Settled against
# EasyRPG's actual C++ source rather than guessed at: `Game_Interpreter::
# Update`'s own per-frame loop is `if (_state.wait_time > 0) { _state.wait_time
# --; break; }` -- it only breaks early *while* wait_time is still above zero,
# so the exact real frame a waited-for Show Battle Animation's own countdown
# reaches 0 falls straight through into whatever command follows instead of
# costing a further frame. `#drive_event`'s `:animation` case used to just call
# `#drive_map_animation` and stop -- unlike the `:wait`/`:battle` cases right
# above it, which already spend the rest of the frame's own step budget the
# instant they come off their wait -- so a command chained right after a
# finished Show Battle Animation (a second one included) always ran one real
# frame later than real RPG_RT.
check 'a Show Battle Animation resumes its own event/process and runs the next command the same real ' \
      'frame it finishes, not one frame later' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # animation 8 then a marker, chained straight into a second Show Battle
  # Animation (animation 9) then a second marker -- the literal "chaining two
  # Show Battle Animation calls back-to-back" case.
  auto.event_commands = [
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0),
    ECmd.new(ic::SHOW_BATTLE_ANIM, [9, 10001, 1], indent: 0),
    ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  spr = scene.instance_variable_get(:@animation_sprite)
  finish_frame = nil
  switch_frame = nil
  40.times do |i|
    was_visible = spr.visible
    scene.update
    finish_frame ||= i if was_visible && !spr.visible
    switch_frame ||= i if st.switches[5]
    break if st.switches[6]
  end
  ok finish_frame, 'the first animation actually finished'
  ok switch_frame, 'the command right after it (marking switch 5) ran'
  eq finish_frame, switch_frame,
     "the trailing command runs the exact same real frame the first animation finishes, not one frame " \
     'later'
  ok st.switches[6], 'the second (chained) animation played through to its own trailing command too'
end

# Same fact, for a Common Event Parallel Process's own chained calls -- the
# `#step_parallel` counterpart to the foreground fix directly above. Before
# this fix, only a `:wait` wait-kind got the same-frame "spend this frame's
# own step budget immediately" treatment there; `:animation` kept the old
# one-frame-per-call pacing even when the process's own animation had just
# finished naturally (as opposed to being cut off by a *different* process,
# which resumes that other process from its own turn and is unaffected by
# this).
#
# The "starts the same real frame the command runs" fix below (see
# `#init_map_animation_this_frame`) tightens this further for a Parallel
# Process specifically -- unlike the foreground path, EasyRPG's own
# `Game_Map::Update` calls `Game_Screen::Update` (the only thing that ever
# advances a just-built animation) *after* `UpdateCommonEvents`/
# `UpdateMapEvents`, so a Parallel Process's own freshly-armed second
# animation gets its first advance the very same real frame it is built, not
# merely built. The animation sprite's own `visible` flag consequently never
# dips false between the two chained plays any more (the second one replaces
# the first before this frame's own render pass ever runs), so the "first
# animation finished" moment is detected here by its underlying frame data
# actually changing rather than by a visibility dip that no longer happens.
check "a Common Event Parallel Process's own chained Show Battle Animation calls run back-to-back too" do
  ic = Game::Interpreter::Cmd
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),
                              ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0),
                              ECmd.new(ic::SHOW_BATTLE_ANIM, [9, 10001, 1], indent: 0),
                              ECmd.new(ic::CONTROL_SWITCHES, [0, 6, 6, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  first_frames = nil
  handoff_frame = nil
  switch_frame = nil
  40.times do |i|
    scene.update
    ma = scene.instance_variable_get(:@map_animation)
    first_frames ||= ma && ma[:frames]
    handoff_frame ||= i if ma && first_frames && !ma[:frames].equal?(first_frames)
    switch_frame ||= i if st.switches[5]
    break if st.switches[6]
  end
  ok handoff_frame, "the parallel process's second animation actually started"
  ok switch_frame, 'the command right after the first animation (marking switch 5) ran'
  eq handoff_frame, switch_frame,
     "a parallel process's own second (chained) animation starts the exact same real frame its trailing " \
     'command runs, not one frame later, matching the foreground fix above'
  ok st.switches[6], 'the second (chained) animation played through to its own trailing command too'
end

# docs/TODO.md's own "still open" note on the chained-animation fixes above:
# this codebase's own extra, structural one-frame startup latency was not
# touched by either one. Settled against EasyRPG's actual C++ source rather
# than left a guess: `Game_Interpreter_Map::CommandShowBattleAnimation`
# (src/game_interpreter_map.cpp) always calls `Game_Screen::ShowBattleAnimation`
# in-line -- building the animation -- *before* it ever touches its own
# wait_time, so a waited-for play's sprite is visible the exact same real
# frame the command runs. `Game::Interpreter#do_show_battle_animation` only
# ever arms the `:animation` wait itself; `#drive_map_animation` (the one
# place anything actually builds/steps the animation) used to only ever be
# reached the *next* time `#drive_event` found the interpreter already parked
# on that wait, so a waited-for play always missed its own frame 0 by a full
# frame -- a foreground event just reaching the command for the first time
# stayed invisible for one extra real frame before ever showing anything.
check 'a Show Battle Animation with the wait flag set shows its sprite the same real frame the command ' \
      'runs, not one frame later' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  # A marker right before the command pins the exact real frame the
  # interpreter reaches it (both run in the same #update burst, since Control
  # Switches is non-blocking and only Show Battle Animation itself arms a
  # wait) -- animation 8 is the same drawable fixture the tests above use.
  auto.event_commands = [
    ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 0], indent: 0),
    ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0), # animation, player, wait
    ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)
  ]
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  spr = scene.instance_variable_get(:@animation_sprite)
  reached_frame = nil
  visible_frame = nil
  10.times do |i|
    scene.update
    reached_frame ||= i if st.switches[4]
    visible_frame ||= i if spr.visible
    break if visible_frame
  end
  ok reached_frame, 'the event actually reached the Show Battle Animation command'
  ok visible_frame, 'the animation sprite eventually shows'
  eq reached_frame, visible_frame,
     'the animation sprite is visible the exact same real frame the command runs, not one frame later'
  ok !st.switches[5], 'the event is still held on its own wait that same frame, not resumed already'
end

# Same fact, for a Common Event Parallel Process's own waited-for play --
# #step_parallel's counterpart to the foreground fix directly above.
check "a Common Event Parallel Process's own waited-for Show Battle Animation shows its sprite the same " \
      'real frame the command runs, not one frame later' do
  ic = Game::Interpreter::Cmd
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [ECmd.new(ic::CONTROL_SWITCHES, [0, 4, 4, 0], indent: 0),
                              ECmd.new(ic::SHOW_BATTLE_ANIM, [8, 10001, 1], indent: 0),
                              ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  spr = scene.instance_variable_get(:@animation_sprite)
  reached_frame = nil
  visible_frame = nil
  10.times do |i|
    scene.update
    reached_frame ||= i if st.switches[4]
    visible_frame ||= i if spr.visible
    break if visible_frame
  end
  ok reached_frame, "the process actually reached the Show Battle Animation command"
  ok visible_frame, 'the animation sprite eventually shows'
  eq reached_frame, visible_frame,
     'the animation sprite is visible the exact same real frame the command runs, not one frame later'
  ok !st.switches[5], "the process is still held on its own wait that same frame, not resumed already"
end

# yado.tk: RPG_RT drops straight into Game Over the instant a wipe-triggering
# command finds the whole party dead outside battle, regardless of which
# event noticed it -- a Simulated Attack floor trap on a background Parallel
# Process is exactly as fatal as an identical trap on a foreground event (see
# the "an event that wipes the party drops into Game Over" check above for the
# foreground half of the same fact). Before this fix #drive_parallel_wait's
# wait-kind dispatch had no :game_over branch, so a Parallel Process's own
# Game::Interpreter#check_game_over call fell into the generic "background:
# ignore message/choice/teleport requests" #resume case -- the wait was
# silently cleared and the process carried on, leaving a fully-dead party
# free to keep wandering the map with no Game Over screen ever shown.
check 'a Parallel Process that wipes the party drops into Game Over too' do
  ic = Game::Interpreter::Cmd
  ce = OpenStruct.new(start_term: 4, need_flag: false, switch_id: nil,
                      event: [ECmd.new(ic::CHANGE_HP, [0, 0, 1, 0, 9999, 1], indent: 0), # party, lethal
                              ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0], indent: 0)])
  scene = new_scene({}, common: { 1 => ce })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, WipeStubParty.new)
  parent = scene.instance_variable_get(:@parent)
  5.times do
    scene.update
    break if parent.game_over_shown
  end
  ok parent.game_over_shown, 'a Parallel Process wiping the party put up the Game Over screen'
  ok !st.switches[5], 'and the rest of the parallel process never ran'
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
  # shadow.y carries no feet-alignment offset (it sits flat on the tile), but
  # the airship sprite's own y is drawn CharSet::HEIGHT - TILE pixels above
  # that already (every vehicle/character sprite's own feet-alignment,
  # unrelated to floating), plus AIRSHIP_ALTITUDE on top of that -- a full
  # tile (16px), not half. EasyRPG's own Game_Vehicle::GetAltitude() is
  # SCREEN_TILE_SIZE / (SCREEN_TILE_SIZE / TILE_SIZE) once fully airborne,
  # 256 / (256 / 16) = 16 with RPG_RT's own real constants.
  base_offset = Game::CharSet::HEIGHT - Game::TILE
  eq 16, shadow.y - sprites[:airship].y - base_offset,
     "the airship floats a full 16px tile above its shadow, not half"
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

check 'a ridden vehicle walk-cycles with the party; an unridden one holds its standing pose' do
  scene = new_scene({}, player: [0, 0], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  boat.charset_name = 'Boat'
  RGSS::Input.triggered = [RGSS::Input::C] # board the boat ahead (facing down by default)
  scene.update
  RGSS::Input.reset
  eq :boat, st.boarded

  RGSS::Input.dir_value = 2 # hold down -- sail further south
  scene.update
  pat = scene.send(:player_walk_pattern)
  5.times do
    break if pat != 1
    scene.update
    pat = scene.send(:player_walk_pattern)
  end
  RGSS::Input.dir_value = 0
  ok scene.instance_variable_get(:@moving), 'the party (and the boat under it) is mid-slide'
  ok pat != 1, 'a walk-cycle frame, not the standing pose'
  frame = scene.instance_variable_get(:@vehicle_last_frame)[:boat]
  eq [st.direction, pat], [frame[1], frame[3]],
     'the ridden boat draws the same direction/walk-cycle frame the hero would have shown'

  # An unridden vehicle always holds the standing pose 1, even while placed on
  # the map: it snaps tile to tile rather than sliding, so it has no in-tile
  # progress to walk-cycle against (see #draw_vehicle_frame's comment).
  ship = st.vehicle(:ship)
  ship.map_id = st.map_id
  ship.x = 5
  ship.y = 4
  ship.charset_name = 'Ship'
  scene.update
  eq 1, scene.instance_variable_get(:@vehicle_last_frame)[:ship][3]
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
  vp2 = scene.instance_variable_get(:@upper_viewport)
  ok vp2, 'the upper chip layer has its own viewport'
  ok vp2.tone, 'a tone reached the upper viewport too'
  eq vp.tone, vp2.tone,
     'the upper chip layer takes the identical tone as the rest of the map'
  MAP_TONED_IVARS.each do |i|
    spr = scene.instance_variable_get(i)
    next unless spr # a layer this scene did not build
    ok spr.viewport.equal?(vp) || spr.viewport.equal?(vp2),
       "#{i} is tinted with the map"
  end
  ABOVE_MAP_IVARS.each do |i|
    spr = scene.instance_variable_get(i)
    next unless spr
    ok !spr.viewport.equal?(vp) && !spr.viewport.equal?(vp2),
       "#{i} must not be tinted -- it draws over the map"
  end
  scene.instance_variable_get(:@vehicle_sprites).each_value do |spr|
    ok spr.viewport.equal?(vp), 'a vehicle is tinted with the map it sits on'
  end
end

# yado.tk: "Change Screen Tone affects only the map tile+character layer --
# pictures, screen/character flash, battle animations, and message text are
# all completely unaffected even at a maximal dark tone." @animation_sprite
# (Show Battle Animation's shared renderer, field/parallel-process and
# in-battle alike, see Scene::Map#step_map_animation) used to live inside
# @map_viewport along with the tiles and hero, so an active map tone wrongly
# tinted every animation play too. Confirmed to fail against the pre-fix code
# (the sprite's viewport equalled @map_viewport).
check "an active map tone does not reach Show Battle Animation's sprite" do
  scene = tint_scene(0, 0, 0, 100, 0, 0)
  vp = scene.instance_variable_get(:@map_viewport)
  vp2 = scene.instance_variable_get(:@upper_viewport)
  spr = scene.instance_variable_get(:@animation_sprite)
  ok spr, 'the animation sprite exists'
  ok !spr.viewport, 'it is a top-level sprite, not a child of any toned viewport'
  ok !spr.viewport.equal?(vp) && !spr.viewport.equal?(vp2),
     'either way, it does not share a viewport with the tinted map layers'
  # And it still draws in the same slot it always has: over the hero, under
  # the upper (above-character) chip layer -- the tone fix must not have
  # reordered anything.
  ok spr.z > sprite_z(scene, :@player_sprite),
     'still drawn over the player sprite'
  ok spr.z < sprite_z(scene, :@upper_sprite),
     'still drawn under the upper chip layer'
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

check "a vehicle's screen position now reads through the same operand a map event's does" do
  # yado.tk: a vehicle's x/y/map id/facing can already be read via Control
  # Variables from a different map than the one it currently occupies (see the
  # vehicle_operand fix), but its *screen* x/y (attr 4/5) needs a live camera,
  # which only the currently-loaded map's own scene has -- that half was left
  # reading the same degenerate 0 an unresolvable map event gets. Ref 10002 is
  # the boat, matching Scene::Map::MOVE_TARGET_BOAT.
  scene = new_scene({}, player: [1, 2])
  st = scene.instance_variable_get(:@state)
  tile = RPG2k::Scene::Map::TILE
  eq [0, 0], scene.camera_position, 'a map smaller than the view cannot scroll'

  boat = st.vehicle(:boat)
  eq nil, scene.character_screen_position(10002), 'an unplaced vehicle has nowhere on screen to report'

  # Parked on this map, off to the side: reads exactly like a map event would
  # at that same tile (the shared tile-centre/tile-bottom asymmetry included).
  boat.map_id = st.map_id
  boat.x = 3
  boat.y = 4
  parked = scene.character_screen_position(10002)
  eq 3 * tile + tile / 2, parked[:x]
  eq 4 * tile + tile, parked[:y]

  boat.map_id = st.map_id + 1
  eq nil, scene.character_screen_position(10002), "a vehicle parked on a different map isn't on this camera"
  boat.map_id = st.map_id

  # Boarded: it rides along with the hero's own interpolated pixel position,
  # not wherever it was left parked.
  st.boarded = :boat
  ridden = scene.character_screen_position(10002)
  hero = scene.character_screen_position(10001)
  eq hero, ridden, 'a boarded vehicle reports the same screen position as the hero riding it'
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

check 'auto-relocation uses RPG_RT\'s real 112px/160px zone thresholds and ' \
      'the feet position, not the earlier SCREEN_H/2 approximation' do
  # Confirmed against EasyRPG's own Game_Message::GetRealPosition() (fetched
  # verbatim): the zone boundaries are 16*7=112 and 16*10=160 real pixels --
  # not this build's old SCREEN_H/2=120 guess -- measured off the hero's
  # *feet* (Game_Character::GetScreenY(), the tile's bottom edge), not its
  # centre. A map exactly one screen tall (15 tiles * 16px = 240px) never
  # scrolls, so #hero_screen_y tracks `st.y * 16 + 16` directly with no
  # camera-clamp interference, letting these boundaries be hit exactly.
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  cfg = st.message_config
  w = 6; h = 15
  flat = Game::Map.new(1, OpenStruct.new(
    width: w, height: h, chipset_id: 1,
    lower_layer: Array.new(w * h, 0), upper_layer: Array.new(w * h, 0),
    events: {}))
  scene.instance_variable_set(:@map, flat)
  st.map = flat
  amp = ->(configured) { scene.send(:auto_message_position, configured) }

  # Configured Down (RPG2000's own default): >=160 -> Top, else Bottom.
  st.y = 9 # feet at 9*16+16 = 160, exactly on the threshold
  eq Game::MessageConfig::POS_TOP, amp.call(Game::MessageConfig::POS_BOTTOM),
     'feet exactly at 160 already counts as clearing the hero -- Top'
  st.y = 8 # feet at 144
  eq Game::MessageConfig::POS_BOTTOM, amp.call(Game::MessageConfig::POS_BOTTOM),
     'one tile short of the threshold -- still Bottom'

  # Configured Up: >112 (strictly) -> Top, else Bottom.
  st.y = 7 # feet at 128
  eq Game::MessageConfig::POS_TOP, amp.call(Game::MessageConfig::POS_TOP),
     'feet past 112 -- Top'
  st.y = 6 # feet at 112, exactly on the threshold -- Up's own check is `>`, not `>=`
  eq Game::MessageConfig::POS_BOTTOM, amp.call(Game::MessageConfig::POS_TOP),
     'feet exactly at 112 does not clear Up\'s own strict threshold -- Bottom'

  # Configured Center: a real three-way split, not just top-or-bottom.
  st.y = 6 # feet at 112
  eq Game::MessageConfig::POS_BOTTOM, amp.call(Game::MessageConfig::POS_MIDDLE),
     'at or below 112 -- Bottom'
  st.y = 9 # feet at 160
  eq Game::MessageConfig::POS_TOP, amp.call(Game::MessageConfig::POS_MIDDLE),
     'at or above 160 -- Top'
  st.y = 7 # feet at 128, strictly between the two thresholds
  eq Game::MessageConfig::POS_MIDDLE, amp.call(Game::MessageConfig::POS_MIDDLE),
     'strictly between the two thresholds -- Middle, the one outcome only ' \
     'the Center-configured case can ever produce'
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
  # EasyRPG's own num_rain_or_snow_particles table (src/weather.cpp) is the
  # literal { 20, 60, 100 } for strength 0/1/2 -- a real, non-uniform step
  # (+40, +40), not a fixed multiple of the lightest strength's own count.
  eq 100, scene.send(:weather_particle_count, st.weather), 'strength 2 (heavy)'
  st.weather.set(1, 1) # medium rain
  eq 60, scene.send(:weather_particle_count, st.weather), 'strength 1 (medium)'
  st.weather.set(1, 0) # light rain
  eq 20, scene.send(:weather_particle_count, st.weather), 'strength 0 (light)'
  st.weather.set(2, 1) # snow
  scene.update
  ok wsp.visible, 'snow draws an overlay too'
  st.weather.set(0, 0) # clear
  scene.update
  ok !wsp.visible, 'clearing weather hides the overlay'
end

check 'the timer draws M:SS as digit-sprite cells cut from the System graphic, and hides when never shown' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, RGSS::Bitmap.new('System/skin'))
  st = scene.instance_variable_get(:@state)
  scene.update
  eq [nil, nil], scene.instance_variable_get(:@timer_sprites),
     'no sprite until shown'
  # Show a 75 s timer (Start with the show flag on) at a frame count that lands
  # in the colon's "on" half of the blink (see the dedicated blink check below
  # for the "off" half).
  st.timer(0).frames = 75 * 60 + 30
  st.timer(0).visible = true
  scene.update
  spr = scene.instance_variable_get(:@timer_sprites)[0]
  ok spr, 'the sprite is built on first display'
  ok spr.visible, 'and shown'
  eq 4, spr.x, 'parked at the screen'"'"'s left edge'
  eq 4, spr.y, 'parked at the top outside of battle'
  # 75 s = 1:15 -> cells [0, 1, :, 1, 5], each an 8x16 blit from the System
  # graphic's digit row (Sprite_Timer::Draw, src/sprite_timer.cpp).
  calls = spr.bitmap.blt_calls
  eq [[0, 0, 32, 32, 8, 16], [8, 0, 40, 32, 8, 16], [16, 0, 112, 32, 8, 16],
      [24, 0, 40, 32, 8, 16], [32, 0, 72, 32, 8, 16]],
     calls.map { |x, y, src, r| [x, y, r.x, r.y, r.width, r.height] },
     'draws minute-tens, minute-ones, colon, second-tens, second-ones'
  ok calls.all? { |c| c[2].equal?(scene.instance_variable_get(:@windowskin)) },
     'every cell is cut from the System graphic'
  # Hiding the timer hides the sprite.
  st.timer(0).visible = false
  scene.update
  ok !spr.visible, 'clearing visibility hides the timer sprite'
end

check 'the timer colon blinks off for the first half of each second' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, RGSS::Bitmap.new('System/skin'))
  st = scene.instance_variable_get(:@state)
  st.timer(0).frames = 30 * 60 # exactly on a second boundary: frames % 60 == 0
  st.timer(0).visible = true
  scene.update
  spr = scene.instance_variable_get(:@timer_sprites)[0]
  eq 4, spr.bitmap.blt_calls.size, 'the colon cell is skipped -- only 4 digit cells drawn'
  spr.bitmap.clear_blt_calls
  st.timer(0).frames = 30 * 60 + 30 # halfway through the second: frames % 60 == 30
  scene.update
  eq 5, spr.bitmap.blt_calls.size, 'the colon cell draws once the blink turns back on'
end

check 'the timer never draws with no System graphic loaded' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, nil)
  st = scene.instance_variable_get(:@state)
  st.timer(0).set(30)
  st.timer(0).start(true)
  scene.update
  ok scene.instance_variable_get(:@timer_sprites)[0].nil?,
     'RPG_RT never displays a timer without a System graphic to cut digits from'
end

check "RPG2003's second timer draws in its own sprite, at the screen's right edge" do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, RGSS::Bitmap.new('System/skin'))
  st = scene.instance_variable_get(:@state)
  st.timer(1).set(30)
  st.timer(1).start(true)
  scene.update
  sprs = scene.instance_variable_get(:@timer_sprites)
  eq nil, sprs[0], 'the first timer was never shown, so has no sprite'
  ok sprs[1], 'the second one does'
  eq RPG2k::Scene::Map::SCREEN_W - RPG2k::Scene::Map::TIMER_INNER_W - 4, sprs[1].x,
     'sits flush against the right edge, the way RPG_RT parks it'
end

check 'the timer drops to the bottom edge once a message resolves to the ' \
      'top, and it stays there after the message closes' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, RGSS::Bitmap.new('System/skin'))
  st = scene.instance_variable_get(:@state)
  st.timer(0).set(30)
  st.timer(0).start(true)
  scene.update
  spr = scene.instance_variable_get(:@timer_sprites)[0]
  eq 4, spr.y, 'nothing has opened a message yet -- normal top position'
  # Hero low on screen -> the (unpinned, RPG2000's default) message resolves
  # to the top, matching #message_window_y's own already-tested logic.
  st.y = 28
  scene.send(:open_message, ['Hi'], false)
  ok scene.instance_variable_get(:@message_window_top),
     'the sticky flag is set the instant the message opens, not when it closes'
  scene.update
  eq RPG2k::Scene::Map::SCREEN_H - 20, spr.y,
     'the timer slides down to keep clear of the top-parked message'
  # Closing the message does not undo it -- EasyRPG's own Window_Message#y
  # is never reset on FinishMessageProcessing either.
  scene.send(:close_message, animate: false)
  scene.update
  eq RPG2k::Scene::Map::SCREEN_H - 20, spr.y,
     'still at the bottom edge after the message that caused it has closed'
end

check 'the timer stays at the top when the last message resolved elsewhere, ' \
      'and a fresh map visit resets the sticky flag' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, RGSS::Bitmap.new('System/skin'))
  st = scene.instance_variable_get(:@state)
  st.timer(0).set(30)
  st.timer(0).start(true)
  # Hero high on screen -> the message resolves to the bottom, not the top.
  st.y = 0
  scene.send(:open_message, ['Hi'], false)
  ok !scene.instance_variable_get(:@message_window_top),
     'a bottom-resolved message never sets the sticky flag'
  scene.update
  spr = scene.instance_variable_get(:@timer_sprites)[0]
  eq 4, spr.y, 'the timer stays at its normal top position'
  scene.send(:close_message, animate: false)
  # Force the sticky flag on directly (as a top-resolved message would), then
  # confirm a fresh map visit clears it -- matching a genuine RPG_RT
  # `Scene_Map::Start` rebuilding `Window_Message` from scratch, unlike
  # `Scene_Map::Continue`'s reuse when merely returning from a pushed scene.
  scene.instance_variable_set(:@message_window_top, true)
  scene.send(:perform_teleport, [1, 0, 0, 0])
  scene.update
  eq 4, scene.instance_variable_get(:@timer_sprites)[0].y,
     'a Teleport to a fresh map resets the sticky flag back to the normal top position'
end

check 'a timer without the battle flag pauses and hides for the fight, and drops to the mid-screen battle position' do
  scene = new_scene({})
  scene.instance_variable_set(:@windowskin, RGSS::Bitmap.new('System/skin'))
  st = scene.instance_variable_get(:@state)
  st.timer(0).set(30)
  st.timer(0).start(true, false)  # visible, but not during battle
  scene.update
  spr = scene.instance_variable_get(:@timer_sprites)[0]
  ok spr.visible
  eq 4, spr.y, 'parked at the top outside of battle'

  frames = st.timer(0).frames
  fake_battle(scene, { phase: :command })
  scene.update
  eq frames, st.timer(0).frames, 'it stopped counting for the fight'
  ok !spr.visible, 'and is hidden'

  st.timer(0).in_battle = true
  scene.update
  ok st.timer(0).frames < frames, 'with the battle flag it keeps counting'
  ok spr.visible, 'and drawing'
  eq RPG2k::Scene::Map::SCREEN_H * 2 / 3 - 20, spr.y,
     'and repositioned to the mid-screen battle slot (Sprite_Timer::Draw)'
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

check 'boarding a vehicle plays a Change System BGM override instead of the database default' do
  scene = new_scene({}, player: [0, 0])
  st = scene.instance_variable_get(:@state)
  st.current_bgm = { name: 'Field', volume: 100, tempo: 100 }
  st.direction = 2
  # System BGM slot 3 is boat -- see the matching interpreter.rb note.
  st.system_bgm[3] = { name: 'CustomBoat', fadein: 0, volume: 55, tempo: 90, balance: 50 }
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  boat.charset_name = 'Boat'
  RGSS::Input.triggered = [RGSS::Input::C] # board the boat ahead
  scene.update
  RGSS::Input.triggered = []
  eq :boat, st.boarded
  eq 'CustomBoat', st.current_bgm[:name], 'the override plays instead of the database BoatBGM'
  eq 55, st.current_bgm[:volume]
  eq 90, st.current_bgm[:tempo]
end

check 'Enemy Encounter scene: the round animates action by action, not at once' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  # Let the encounter open the per-actor command menu (it takes a frame or two),
  # dismissing the once-per-battle automatic options window (C on its default
  # cursor row 0, "Battle") along the way.
  ui = nil
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  # Command the sole hero to Attack the first enemy: C picks Attack, C confirms
  # the target; with one ally that starts the round animation.
  2.times do
    RGSS::Input.triggered = [RGSS::Input::C]
    scene.update
    RGSS::Input.triggered = []
  end
  ui = battle_ui(scene)
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
  # The battle scene spends a *use* rather than a copy (Game::Party#
  # consume_item_use, whose 使用回数 arithmetic rpg2k_logic_check covers); this
  # stub's potion is an ordinary single-use one, so a use costs a copy.
  def consume_item_use(id); lose_item(id, 1); end

  # Battle sub-menu hooks the scene calls (Game::Party provides these for real):
  def battle_skills(actor, _caster); actor.skills.include?(1) ? [[1, 3]] : []; end
  def db_skill(id); id == 1 ? OpenStruct.new(name: 'Fire', scope: 0) : nil; end
  def battle_skill_target(sk); sk.scope == 0 ? :enemy : :ally; end
  def battle_skill_command(_sk, _caster, _target, free: false); { cost: free ? 0 : 3, hp: -15, mp: 0 }; end
  # A skill's weapon-type Attribute requirement -- true (unrestricted) by
  # default, so every check predating the equip-gate stays on its own path;
  # see BattleWeaponGateParty below for a check that flips this.
  def weapon_attribute_ready?(_caster, _sk); true; end
  def battle_items
    @items.keys.sort.select { |id| item_count(id) > 0 }.map { |id| [id, item_count(id)] }
  end
  def db_item(id); id == 5 ? OpenStruct.new(name: 'Potion') : nil; end
  def battle_item_command(_it, _target); { hp: 20, mp: 0 }; end
  def item_all_allies?(it); it.respond_to?(:scope) && it.scope == 1; end
  def switch_item?(_id); false; end
  # This stub's one item (Potion) is a plain medicine, never skill-invoking;
  # see BattleSkillItemParty below for a stub covering the opposite case.
  def skill_invoking_item?(_it); false; end
  # These checks drive an already-opening or already-open battle, not the
  # missing-troop-id diagnostic path -- every id reads as present.
  def db_enemy_group(_id); true; end
end

# BattleMagicParty built around a caller-supplied actor instead of always
# constructing its own -- lets a check outfit the lone actor with a
# customized RPG2003 battle-command list while keeping the Skill/Item
# sub-menu backing (`battle_skills` / `db_skill` / `battle_items` / `db_item`)
# those commands need to actually open.
class BattleCustomCommandParty < BattleMagicParty
  def initialize(actor)
    super()
    @actors = [actor]
  end
end

# Open a battle and step to the per-actor command menu, dismissing the
# once-per-battle automatic Battle/Auto Battle/Escape options window along
# the way (a C press on its default cursor row 0, "Battle").
def battle_to_command(scene)
  ui = nil
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
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

# EasyRPG's Scene_Battle::UpdateUi (src/scene_battle.cpp), called
# unconditionally every frame from Scene_Battle_Rpg2k::vUpdate, calls
# .Update() on every one of command_window/status_window/item_window/
# skill_window/target_window/options_window -- all genuine
# Window_Selectables, whose own Update() drives the cursor via the
# standard trigger-then-repeat, before SetActive/GetActive ever gates which
# one's Decision/Cancel handling runs (see Scene::Order's identical shape).
# `RGSS::Input.repeated` (distinct from `.triggered`) lets this check hold
# a key across frames without it also reading as a fresh trigger.
check 'Enemy Encounter scene: holding Down auto-repeats the battle options, ' \
      'command and enemy-target cursors alike' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleMagicParty.new)
  ui = battle_until_phase(scene, :battle_options)
  ok ui, 'the options window opened'

  RGSS::Input.repeated = [RGSS::Input::DOWN] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, ui[:opt], 'a held (repeated, not triggered) Down still moves the options cursor'

  RGSS::Input.triggered = [RGSS::Input::UP] # back onto Fight
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss with Fight -> command phase
  scene.update
  RGSS::Input.reset
  eq :command, ui[:phase]

  RGSS::Input.repeated = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 1, ui[:cmd], 'a held (repeated, not triggered) Down still moves the command cursor'

  RGSS::Input.triggered = [RGSS::Input::C] # Skill -> Fire (enemy-scope) -> target
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :target, ui[:phase]

  RGSS::Input.repeated = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 1, ui[:target_i], 'a held (repeated, not triggered) Down still moves the enemy-target cursor'
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
  press_key(scene, RGSS::Input::DOWN)   # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN)   # Defend -> Item
  eq 3, ui[:cmd]
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

# SFX_ENEMY_ATTACK (Scene::Base::DB_SE_FIELD slot 6): confirmed against
# EasyRPG Player's source (scene_battle_rpg2k.cpp's ProcessBattleActionUsage)
# to fire once, at the very start of an *enemy's* plain Attack action, never
# for a skill/item hit or for an ally's own Attack -- see the doc comment on
# `SFX_ENEMY_ATTACK` in mruby-rpg2k/mrblib/scene/base.rb.
check 'Enemy Encounter scene: the enemy-attack SE plays for an enemy Attack, ' \
      'not an ally one' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)

  2.times { press_key(scene, RGSS::Input::C) } # Attack -> the first Slime -> animate
  eq :animate, ui[:phase]

  RGSS::Audio.reset_se
  scene.update # the (faster) Hero's own attack lands first
  eq 1, ui[:battle].log.length
  ok !RGSS::Audio.se_calls.any? { |c| c[0] == 'EnemyAttack' },
     "an ally's own Attack does not play the enemy-attack SE"

  # The Slime survives the Hero's hit (19 damage against 30 HP), so it is
  # still alive to take its own turn next and swing back.
  RGSS::Audio.reset_se
  120.times do
    scene.update
    break if ui[:battle].log.length >= 2
  end
  eq 2, ui[:battle].log.length, "the Slime's counter-attack landed"
  entry = ui[:battle].log.last
  eq false, entry[:attacker_ally], 'the attacker is the enemy, not an ally'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'EnemyAttack' },
     "and the enemy's own Attack plays the enemy-attack SE"
end

# The battle command/target/skill/item flow's own system SE -- confirmed
# against EasyRPG Player's source the same way the field menu and title
# screen already were (Scene_Battle::AttackSelected/DefendSelected/
# ItemSelected/SkillSelected, Window_Selectable::Update() for cursor moves,
# ProcessSceneActionCommand/EnemyTarget/Escape for Cancel/Buzzer/Escape).
check 'Enemy Encounter scene: the command/skill/target flow plays cursor, ' \
      'decision and cancel SE' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleMagicParty.new)
  ui = battle_to_command(scene)

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  eq 'Cursor1', RGSS::Audio.se_calls.last[0], 'moving the command cursor plays Cursor SE'

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::C) # open the (non-empty) skill list
  eq :skill, ui[:phase]
  eq 'Decision1', RGSS::Audio.se_calls.last[0], 'opening a non-empty skill list plays Decision SE'

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::C) # choose Fire (affordable) -> enemy target
  eq :target, ui[:phase]
  eq 'Decision1', RGSS::Audio.se_calls.last[0],
     'choosing an affordable skill plays Decision SE again'

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::B) # cancel the target list
  eq :skill, ui[:phase]
  eq 'Cancel1', RGSS::Audio.se_calls.last[0], 'cancelling the target list plays Cancel SE'

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::B) # cancel the skill list
  eq :command, ui[:phase]
  eq 'Cancel1', RGSS::Audio.se_calls.last[0], 'cancelling the skill list plays Cancel SE too'
end

check 'Enemy Encounter scene: confirming an unaffordable skill plays Buzzer, ' \
      'not Decision, and stays on the list' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  party = BattleMagicParty.new
  party.actors.first.mp = 0 # Fire costs 3
  st.instance_variable_set(:@party, party)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::C)    # open the skill list
  eq :skill, ui[:phase]

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::C) # try Fire, can't afford it
  eq :skill, ui[:phase], 'an unaffordable skill leaves the player on the list'
  eq 'Buzzer1', RGSS::Audio.se_calls.last[0], 'and plays Buzzer instead of Decision'
end

# A party whose Fire skill requires a weapon-type Attribute the Hero starts
# without -- `weapon_ready` flips what Game::Party#weapon_attribute_ready?
# answers, standing in for equipping the matching weapon (the real equip
# mechanics are covered by rpg2k_logic_check.rb's own "can_cast?: a
# weapon-type Attribute skill needs a weapon carrying it equipped" check;
# this only asserts Scene::Map#confirm_battle_skill wires the answer in).
class BattleWeaponGateParty < BattleMagicParty
  attr_accessor :weapon_ready
  def initialize(hurt: false)
    super(hurt: hurt)
    @weapon_ready = false
  end
  def weapon_attribute_ready?(_caster, _sk); @weapon_ready; end
end

check 'Enemy Encounter scene: confirming a skill missing its required weapon ' \
      'Attribute plays Buzzer, not Decision, and stays on the list -- equipping ' \
      'the matching weapon makes it castable again' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  party = BattleWeaponGateParty.new
  st.instance_variable_set(:@party, party)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::C)    # open the skill list
  eq :skill, ui[:phase]

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::C) # try Fire, missing the required weapon Attribute
  eq :skill, ui[:phase], 'a skill missing its weapon Attribute leaves the player on the list'
  eq 'Buzzer1', RGSS::Audio.se_calls.last[0], 'and plays Buzzer instead of Decision'

  party.weapon_ready = true # the matching weapon is now equipped
  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::C) # try Fire again
  eq :target, ui[:phase], 'the very same skill casts once the weapon requirement is met'
  eq 'Decision1', RGSS::Audio.se_calls.last[0]
end

check 'Enemy Encounter scene: an item-triggered heal bypasses the weapon-Attribute ' \
      'gate -- no skill-eligibility check runs for it at all' do
  # Regression guard: #confirm_battle_skill's new weapon-Attribute check lives
  # entirely on the Skill sub-menu path -- the Item sub-menu never calls
  # #weapon_attribute_ready? (Game::Party#battle_item_command is pure HP/SP
  # arithmetic, matching the field menu's own free: item-cast bypass covered
  # in rpg2k_logic_check.rb).
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  party = BattleWeaponGateParty.new(hurt: true) # weapon_ready stays false throughout
  st.instance_variable_set(:@party, party)
  ui = battle_to_command(scene)

  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN) # Defend -> Item
  press_key(scene, RGSS::Input::C)    # open the item list
  eq :item, ui[:phase]
  press_key(scene, RGSS::Input::C)    # choose Potion -> ally target
  eq :ally_target, ui[:phase]
  press_key(scene, RGSS::Input::C)    # heal the Hero -> round animates
  eq :animate, ui[:phase], 'the item cast went through with the weapon requirement still unmet'
end

# A party whose bag also holds a type-9 special item invoking an enemy-scope
# attack skill (Nepheshel's own thrown-bomb line, per docs/TODO.md) --
# Game::Party's own decision logic (#skill_invoking_item?/
# #battle_skill_command's `free:`) is covered by rpg2k_logic_check.rb; this
# stub only has to hand the scene something that behaves the same way, so
# this check stays about the RGSS wiring: does confirming the item in the
# battle Item menu route to *enemy* target selection and deal real skill
# damage, instead of the pre-fix behaviour of prompting for an *ally* and
# running the plain #battle_item_command medicine math (which this item's
# database row carries none of, so it silently did nothing at all).
class BattleSkillItemParty < BattleMagicParty
  BOMB_ID = 7

  def initialize(hurt: false)
    super
    @items[BOMB_ID] = 2
  end

  def db_item(id)
    return OpenStruct.new(name: 'Fire Bomb', type: Game::Party::ITEM_SPECIAL, skill_id: 2) if id == BOMB_ID

    super
  end

  def skill_invoking_item?(it)
    it.respond_to?(:type) && it.type == Game::Party::ITEM_SPECIAL
  end

  def db_skill(id)
    return OpenStruct.new(name: 'Firebolt', scope: 0) if id == 2

    super
  end

  def battle_skill_command(sk, caster, target, free: false)
    return { cost: free ? 0 : 5, hp: -25, mp: 0, attack: true } if sk.respond_to?(:name) && sk.name == 'Firebolt'

    super(sk, caster, target, free: free)
  end
end

check 'Enemy Encounter scene: a special item invoking an enemy-scope skill ' \
      'routes to enemy target selection and deals real damage, not an inert ' \
      'ally-targeted medicine cast' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleSkillItemParty.new)
  ui = battle_to_command(scene)

  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN) # Defend -> Item
  press_key(scene, RGSS::Input::C)    # open the item list
  eq :item, ui[:phase]
  press_key(scene, RGSS::Input::DOWN) # Potion (id 5) -> Fire Bomb (id 7, sorted second)
  press_key(scene, RGSS::Input::C)    # choose the Fire Bomb
  eq :target, ui[:phase], 'an enemy-scope item skill prompts for an enemy, not an ally'

  foe_hp = ui[:foes].first.hp
  press_key(scene, RGSS::Input::C)    # confirm the first foe -> round animates
  eq :animate, ui[:phase]
  eq 2, st.party.item_count(BattleSkillItemParty::BOMB_ID),
     'not spent yet -- an item action is only consumed once it lands'

  scene.update                        # the Hero's action lands
  entry = ui[:battle].log.first
  eq 25, foe_hp - ui[:foes].first.hp, 'the skill\'s real damage landed, not a 0-effect medicine cast'
  eq 1, st.party.item_count(BattleSkillItemParty::BOMB_ID), 'one Fire Bomb consumed'
  eq 10, ui[:allies].first.mp, 'the caster\'s own MP is untouched -- the item paid, not the caster'
  ok entry[:item_id] == BattleSkillItemParty::BOMB_ID, "the log entry carries the item's id"
end

# A party whose Hero knows no battle skill at all, so Skill's own list opens
# empty -- Buzzer here mirrors real RPG_RT's own Buzzer on a Skill/Item
# confirm that finds nothing usable (this engine instead never opens an empty
# list, so the same Buzzer fires at the one point that outcome is known --
# see #open_battle_skill's comment).
class BattleNoSkillParty < BattleMagicParty
  def battle_skills(_actor, _caster); []; end
end

check 'Enemy Encounter scene: opening Skill with nothing to cast plays Buzzer, ' \
      'not Decision, and never opens the list' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleNoSkillParty.new)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill

  RGSS::Audio.reset_se
  press_key(scene, RGSS::Input::C)
  eq :command, ui[:phase], 'no skill list opens'
  eq 'Buzzer1', RGSS::Audio.se_calls.last[0], 'Buzzer plays instead of Decision'
end

# A party whose only battle item is a switch (type 10) one -- battle-usability
# and #use_switch_item's own consumption are Game::Party logic covered by
# scripts/rpg2k_logic_check.rb; this stub only has to hand the scene something
# that behaves the same way, so the check below stays about the RGSS wiring
# (does choosing it skip ally targeting, and does landing actually flip the
# switch and consume one -- the battle-side gap the field menu never had).
class BattleSwitchItemParty < BattleMagicParty
  SWITCH_ITEM_ID = 6
  ITEM_SWITCH_ID = 42

  def initialize
    super()
    @items = { SWITCH_ITEM_ID => 1 }
  end

  def db_item(id)
    return OpenStruct.new(name: 'Whistle', switch_id: ITEM_SWITCH_ID) if id == SWITCH_ITEM_ID
    nil
  end

  def switch_item?(id); id == SWITCH_ITEM_ID; end
end

check 'Enemy Encounter scene: using a switch item skips ally targeting, then ' \
      'flips its switch and consumes one when the action lands' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleSwitchItemParty.new)
  ui = battle_to_command(scene)

  press_key(scene, RGSS::Input::DOWN)   # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN)   # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN)   # Defend -> Item
  press_key(scene, RGSS::Input::C)      # open the item list
  eq :item, ui[:phase]
  press_key(scene, RGSS::Input::C)      # choose the switch item
  eq :animate, ui[:phase],
     'a switch item has no target -- it queues straight into the round, unlike the Potion above'
  eq 1, st.party.item_count(BattleSwitchItemParty::SWITCH_ITEM_ID), 'not spent until the action lands'
  ok !st.switches[BattleSwitchItemParty::ITEM_SWITCH_ID], 'not flipped yet either'

  RGSS::Audio.reset_se
  scene.update                          # the Hero's action lands
  eq 0, st.party.item_count(BattleSwitchItemParty::SWITCH_ITEM_ID), 'one consumed when it landed'
  ok st.switches[BattleSwitchItemParty::ITEM_SWITCH_ID], 'the switch is flipped'
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
  eq 3, ui[:cmd], 'Up from Attack wraps to Item (the last of the four commands)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:cmd], 'Down from Item wraps back to Attack'

  press_key(scene, RGSS::Input::C) # open the enemy target list (2 Slimes)
  eq :target, ui[:phase]
  eq 0, ui[:target_i], 'starts on the first foe'
  press_key(scene, RGSS::Input::UP)
  eq 1, ui[:target_i], 'Up from the first foe wraps to the last (2 Slimes)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:target_i], 'Down from the last foe wraps to the first'
end

check 'Enemy Encounter scene: the command menu is drawn Attack / Skill / Defend / Item' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq %w[Attack Skill Defend Item], labels,
     "EasyRPG's own CreateBattleCommandWindow order, not Item ahead of Defend"
end

check 'Enemy Encounter scene: cmd 2 commits Defend at once (not the Item list)' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  eq 2, ui[:cmd]
  press_key(scene, RGSS::Input::C)    # Defend commits at once, no sub-menu
  # The lone actor's only command; committing it advances straight past the
  # command phase into the round (Defend never opens a list the way Item does).
  eq :animate, ui[:phase],
     'Defend at cmd 2 committed and started the round instead of opening Item'
end

check "Enemy Encounter scene: an actor's RPG2000 custom battle command name replaces Skill" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party,
    BattleStubParty.new(BattleStubActor.new(rename_skill: true, skill_name: 'Magic')))
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq %w[Attack Magic Defend Item], labels,
     'database field 66/67 (custom_battle_command / _name) renames just the Skill slot'
end

check 'Enemy Encounter scene: an actor without the custom name keeps the Skill term' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq 'Skill', labels[1], 'no rename set (the default) falls back to the database term'
end

check "Enemy Encounter scene: an actor's RPG2003 skill-only battle-command list drives the menu" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  actor = BattleStubActor.new(atk: 40, agi: 20, mp: 10, skills: [1],
    battle_commands: [10, 0, -1, -1, -1, -1, -1],
    battle_command_table: { 10 => BattleCommandDef.new('Cast Magic', Game::Actor::BATTLE_COMMAND_SUBSKILL) })
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(actor))
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq ['Cast Magic'], labels,
     "a customized list of just one Subskill entry (plus id 0, Row -- skipped " \
     "within the customizable list itself, see #custom_battle_commands) " \
     'shows that one row alone, not the fixed four (this fixture is not ' \
     'rpg2003?-flagged, so the appended Row row -- #row_command_available? -- ' \
     'never shows either)'
  press_key(scene, RGSS::Input::C) # the only row, cmd 0, is a Skill-type command
  eq :skill, ui[:phase], 'a Subskill entry opens the Skill list the same as the generic Skill command'
end

check "Enemy Encounter scene: an actor's shortened, reordered battle-command list draws in its own order" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  actor = BattleStubActor.new(
    battle_commands: [4, 3, 0, -1, -1, -1, -1],
    battle_command_table: {
      4 => BattleCommandDef.new('Bag', Game::Actor::BATTLE_COMMAND_ITEM),
      3 => BattleCommandDef.new('Guard', Game::Actor::BATTLE_COMMAND_DEFENSE)
    })
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(actor))
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq %w[Bag Guard], labels, 'Item first then Defense, the database order, not Attack/Skill/Defend/Item'
  press_key(scene, RGSS::Input::C) # cmd 0 here is the Item-type command
  eq :item, ui[:phase], 'the reordered list still opens the Item sub-menu, not Attack'
end

check "Enemy Encounter scene: a reordered Defense command still commits at once, not just at cmd 2" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  actor = BattleStubActor.new(
    battle_commands: [4, 3, 0, -1, -1, -1, -1],
    battle_command_table: {
      4 => BattleCommandDef.new('Bag', Game::Actor::BATTLE_COMMAND_ITEM),
      3 => BattleCommandDef.new('Guard', Game::Actor::BATTLE_COMMAND_DEFENSE)
    })
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(actor))
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Bag (cmd 0) -> Guard (cmd 1)
  eq 1, ui[:cmd]
  press_key(scene, RGSS::Input::C)    # Defense commits at once, no sub-menu, despite sitting at cmd 1
  eq :animate, ui[:phase],
     "cmd 1's own action (:defend) drove this, not the fixed four's cmd-2-is-Defend rule"
end

check 'selecting a battle command records its command id on the acting Combatant, ' \
      'the way EasyRPG sets SetLastBattleAction' do
  # The fixed four map to EasyRPG's default command ids 1..4 (attack, skill,
  # defense, item) -- what the RPG2003 battle combo (Enable Combo) and the
  # `command_actor` page condition compare against. This pins the recording,
  # not the spending (the model-side combo math lives in rpg2k_logic_check.rb).
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(BattleStubActor.new(agi: 20)))
  ui = battle_to_command(scene)
  hero = ui[:allies][0]
  eq nil, hero.last_battle_action, 'nothing recorded before a command is chosen'
  press_key(scene, RGSS::Input::C) # Attack (cmd 0, the default cursor row)
  eq 1, hero.last_battle_action, 'the fixed Attack row records command id 1'
end

check 'selecting a customized battle command records its own command-table ref' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  actor = BattleStubActor.new(agi: 20,
    battle_commands: [10, 0, -1, -1, -1, -1, -1],
    battle_command_table: { 10 => BattleCommandDef.new('Cast Magic', Game::Actor::BATTLE_COMMAND_SUBSKILL) })
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(actor))
  ui = battle_to_command(scene)
  hero = ui[:allies][0]
  press_key(scene, RGSS::Input::C) # the only row, cmd 0: the Subskill at ref 10
  eq 10, hero.last_battle_action, 'a customized row records its own db.commands ref'
end

check "Enemy Encounter scene: a Special battle command draws a row and forfeits the actor's turn" do
  # RPG2003's Special (type 6) command resolves to a turn that does nothing --
  # EasyRPG's `Scene_Battle_Rpg2k3::SpecialSelected` queues
  # `Game_BattleAlgorithm::DoNothing`. It must be offered as a menu row (this
  # engine used to skip it along with Escape) and, once chosen, commit at once
  # like Defend -- no target/skill/item submenu -- and pass the actor's turn
  # with no action: `Game::Battle#command_skip` sets the Combatant's skip
  # flag, #strike returns nil for it, and the round machine moves on.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  actor = BattleStubActor.new(agi: 20,
    battle_commands: [12, 0, -1, -1, -1, -1, -1],
    battle_command_table: { 12 => BattleCommandDef.new('Stall', Game::Actor::BATTLE_COMMAND_SPECIAL) })
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(actor))
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq ['Stall'], labels, 'a customized list with just a Special entry shows that one row, not the fixed four'
  hero = ui[:allies][0]
  press_key(scene, RGSS::Input::C) # the only row, cmd 0: the Special at ref 12
  eq 12, hero.last_battle_action, 'a Special row records its own db.commands ref (never multiplied by a combo)'
  eq :animate, ui[:phase], 'Special commits at once -- no target/skill/item submenu, like Defend'
  # The hero's turn is skipped, so after the round resolves the only log
  # entries are the Slimes' attacks, never a Hero one.
  8.times { scene.update }
  hero_attacked = ui[:battle].log.any? { |e| e[:attacker] == 'Hero' }
  eq false, hero_attacked, 'the Special turn produced no attack entry for the hero'
end

check "Enemy Encounter scene: an RPG2003 fight offers Row after the fixed four " \
      "and refuses to empty the front row" do
  # A lone party member can never leave the front row (Game::Battle
  # #can_leave_front_row?, ported from EasyRPG's `RowSelected` guard) --
  # RPG_RT buzzes and stays on the command menu rather than spending the
  # turn, exactly like the reference's own "nothing to pick" Buzzer cases.
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) }, rpg2003: true)
  st = scene.instance_variable_get(:@state)
  actor = BattleStubActor.new(agi: 20)
  st.instance_variable_set(:@party, BattleStubParty.new(actor, rpg2003: true))
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq %w[Attack Skill Defend Item Row], labels,
     'a 2003 fight appends the fixed Row row after the ordinary fixed four'
  4.times { press_key(scene, RGSS::Input::DOWN) } # Attack -> Skill -> Defend -> Item -> Row
  eq 4, ui[:cmd], 'the cursor lands on the appended Row row'
  hero = ui[:allies][0]
  press_key(scene, RGSS::Input::C)
  eq :command, ui[:phase], 'a refused toggle stays on the command menu, not a committed turn'
  eq Game::Battle::ROW_FRONT, hero.row, 'the sole ally is still front row'
  eq Game::Battle::ROW_FRONT, actor.battle_row, 'the real actor was never written back to either'
end

check 'Enemy Encounter scene: Row flips a front-row ally to the back and spends the turn' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) }, rpg2003: true)
  st = scene.instance_variable_get(:@state)
  a1 = BattleStubActor.new(id: 1, name: 'Hero', agi: 20)
  a2 = BattleStubActor.new(id: 2, name: 'Ally', agi: 15)
  st.instance_variable_set(:@party, BattleStubParty.new(rpg2003: true, actors: [a1, a2]))
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq %w[Attack Skill Defend Item Row], labels
  4.times { press_key(scene, RGSS::Input::DOWN) } # Attack -> Skill -> Defend -> Item -> Row
  hero = ui[:allies][0]
  press_key(scene, RGSS::Input::C)
  # Row commits at once, like Special -- no target/skill/item submenu -- but
  # with a second party member still to command, that only advances to
  # *their* menu, not straight to the round's animation.
  eq :command, ui[:phase], "Row spends only the acting ally's turn, moving on to the next ally's menu"
  eq Game::Battle::ROW_BACK, hero.row, 'the fight-scoped Combatant moved to the back row'
  eq Game::Battle::ROW_BACK, a1.battle_row, 'the real actor is written back so it outlives the battle'
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  press_key(scene, RGSS::Input::C)    # Ally defends, committing the round
  eq :animate, ui[:phase], "the round animates once both allies have committed"
  # The row change cost Hero's own turn like Special does: only Ally's
  # attacks show up in the round's log.
  8.times { scene.update }
  hero_attacked = ui[:battle].log.any? { |e| e[:attacker] == 'Hero' }
  eq false, hero_attacked, 'the Row turn produced no attack entry for the hero'
end

check "Enemy Encounter scene: a battle-command list of Row alone falls back to the fixed four" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party,
    BattleStubParty.new(BattleStubActor.new(battle_commands: [0, -1, -1, -1, -1, -1, -1])))
  ui = battle_to_command(scene)
  labels = ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  eq %w[Attack Skill Defend Item], labels,
     'Row alone (the same shape an actor with no customization at all reads from the database) ' \
     'is not a usable list on its own, so this falls back to the fixed four'
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
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN) # Defend -> Item
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
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN) # Defend -> Item
  press_key(scene, RGSS::Input::C)    # open the item list
  press_key(scene, RGSS::Input::C)    # choose the Potion -> ally target
  eq :ally_target, ui[:phase]
  eq 0, ui[:ally_i], 'starts on the first ally'
  press_key(scene, RGSS::Input::UP)
  eq 1, ui[:ally_i], 'Up from the first ally wraps to the last (2 actors)'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:ally_i], 'Down from the last ally wraps to the first'
end

# Two actors (distinct ids) with an item_usable_by? that restricts the
# Potion (item 5) to actor 1 only -- a real Game::Party derives this from the
# item's 使用可能キャラ / actor_set field (Game::Party#item_usable_by?); this
# stub hardcodes the same answer so the scene-level wiring can be checked
# without building a full item database.
class BattleRestrictedItemParty < BattleMagicParty
  def initialize(hurt: false)
    super(hurt: hurt)
    @hero2 = BattleStubActor.new(atk: 10, agi: 5, mp: 5, hp: 150, id: 2)
    @actors = [@hero, @hero2]
  end
  def item_usable_by?(_it, actor_id); actor_id != 2; end
end

check "Enemy Encounter scene: a restricted item's ally-target picker skips the actor it excludes" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleRestrictedItemParty.new)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN) # Defend -> Item
  press_key(scene, RGSS::Input::C)    # open the item list
  press_key(scene, RGSS::Input::C)    # choose the Potion -> ally target
  eq :ally_target, ui[:phase]
  eq 2, ui[:allies].reject(&:dead?).length, 'both actors are alive and in the fight'
  targets = scene.instance_variable_get(:@battle).send(:battle_ally_targets)
  eq 1, targets.length, 'the restricted actor never appears as a choice'
  eq 1, targets.first.actor.id, 'only the allowed actor is offered'
  eq 0, ui[:ally_i], 'starts on the sole remaining candidate'
  press_key(scene, RGSS::Input::DOWN)
  eq 0, ui[:ally_i], 'a single candidate has nowhere to move to, unlike the ' \
                     'unrestricted two-actor cursor above'
  press_key(scene, RGSS::Input::C) # confirm -> queues the item on the allowed actor
  eq :command, ui[:phase], 'hero 2 still has to pick their own action'
  eq ui[:allies].first, ui[:allies].first.command[:target],
     'the queued Item command targets actor 1, never the restricted actor 2'
end

# A second actor already down (hp 0) when the fight starts -- exactly the
# combatant a 蘇生専用 (`ko_only`) revive item exists to target.
class BattleDownedAllyParty < BattleMagicParty
  def initialize(hurt: false)
    super(hurt: hurt)
    @hero2 = BattleStubActor.new(atk: 10, agi: 5, mp: 5, hp: 150, id: 2)
    @hero2.hp = 0
    @actors = [@hero, @hero2]
  end
end

check "Enemy Encounter scene: a downed ally is offered as a Battle Item target, not skipped" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleDownedAllyParty.new)
  ui = battle_to_command(scene)
  press_key(scene, RGSS::Input::DOWN) # Attack -> Skill
  press_key(scene, RGSS::Input::DOWN) # Skill -> Defend
  press_key(scene, RGSS::Input::DOWN) # Defend -> Item
  press_key(scene, RGSS::Input::C)    # open the item list
  press_key(scene, RGSS::Input::C)    # choose the Potion -> ally target
  eq :ally_target, ui[:phase]
  targets = scene.instance_variable_get(:@battle).send(:battle_ally_targets)
  eq 2, targets.length, 'the downed ally is still offered, not excluded from the picker'
  ok targets.any?(&:dead?), 'one of the offered targets is the downed ally'
  press_key(scene, RGSS::Input::DOWN)
  eq 1, ui[:ally_i], 'the cursor can reach the downed ally, which used to be unreachable'
  press_key(scene, RGSS::Input::C) # confirm on the downed ally
  # The only other roster slot is the downed ally itself, which never gets a
  # command of its own, so the round starts right away rather than moving to
  # a second actor's command phase (unlike the restricted-item check above,
  # whose second actor is merely restricted, not dead, and still gets a turn).
  eq :animate, ui[:phase]
  eq ui[:allies][1], ui[:allies][0].command[:target],
     'the queued Item command targets the downed ally, not just the living one'
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
  eq 255, sprites[0].opacity, 'a plain (non-"Appear Transparent") enemy draws fully opaque'
  ok sprites[0].z < 300, 'battlers sit below the UI windows (z >= 300)'
  ok ui[:back_sprite].z < sprites[0].z, 'the backdrop sits behind the battlers'
  # yado.tk: troop members are numbered by add-order and the *lower*-numbered
  # one renders in front (closer to camera) -- member 0 here, added first.
  ok sprites[0].z > sprites[1].z, 'the lower-numbered troop member renders on top'

  battle_attack_to_end(scene) # both Slimes fall
  ok sprites.all? { |s| !s.visible }, 'a defeated enemy sprite is hidden'
end

# RPG2003's alternative/gauge battle layouts (Game::Party#
# alternate_battle_layout?) draw each living party member as a sprite too,
# on top of the existing party status window -- unlike RPG2000's
# status-window-only layout, which draws none. Scoped to the plain Idle pose
# (character/BattleCharSet format) only; see #build_actor_sprite
# (mruby-rpg2k/mrblib/scene/map.rb) for the other three checks covering its
# documented gaps.
check 'Enemy Encounter scene: the alternative/gauge layout draws a positioned Idle-pose sprite per living party member' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose(battler_name: 'Hero', battler_index: 2) }) }
  scene = new_scene({ 1 => event(2, 2, auto) }, battleranimations: anims)
  st = scene.instance_variable_get(:@state)
  hero = BattleStubActor.new(id: 1, battler_animation_id: 5, battle_x: 40, battle_y: 120)
  st.instance_variable_set(:@party, BattleStubParty.new(hero, alternate_layout: true))
  ui = battle_to_command(scene)

  sprites = ui[:actor_sprites]
  ok sprites, 'built when the layout is alternative/gauge'
  eq 1, sprites.compact.length, 'one sprite for the sole living party member'
  spr = sprites[0]
  eq 40, spr.x, "the actor's raw database battle_x, used literally"
  eq 120, spr.y, "the actor's raw database battle_y, used literally"
  eq RGSS::Rect.new(0, 96, 48, 48), spr.src_rect,
     'cell battler_index 2 of the 48x48-framed BattleCharSet sheet'
  ok spr.z < 300, 'sits below the UI windows (z >= 300)'
end

# EasyRPG's Sprite_Actor::DoIdleAnimation resolves a monster's Knockout state
# straight to AnimationState_Dead rather than hiding it; a party member is
# treated the same way here (#build_actor_sprite's `dead:` keyword, Pose id
# 4) -- so a member already KO'd the instant the fight opens gets that pose
# rather than no sprite at all, the gap this check pins.
check "Enemy Encounter scene: a party member already KO'd going into the fight draws the Dead pose, not no sprite" do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose(battler_name: 'Hero', battler_index: 2),
                                          4 => battle_pose(battler_name: 'Hero', battler_index: 6) }) }
  scene = new_scene({ 1 => event(2, 2, auto) }, battleranimations: anims)
  st = scene.instance_variable_get(:@state)
  fallen = BattleStubActor.new(id: 1, battler_animation_id: 5, hp: 0)
  alive = BattleStubActor.new(id: 2, battler_animation_id: 5)
  st.instance_variable_set(:@party, BattleStubParty.new(actors: [fallen, alive], alternate_layout: true))
  ui = battle_to_command(scene)

  sprites = ui[:actor_sprites]
  ok sprites, 'built when the layout is alternative/gauge'
  eq 2, sprites.compact.length, 'both members get a sprite, including the already-fallen one'
  cell = RPG2k::Scene::Battle::ACTOR_CHARSET_CELL
  eq RGSS::Rect.new(0, 6 * cell, cell, cell), sprites[0].src_rect,
     "the fallen member's sprite uses the entry's Dead pose cell (battler_index 6), not Idle"
  eq RGSS::Rect.new(0, 2 * cell, cell, cell), sprites[1].src_rect,
     'the living member still gets the Idle pose'
end

check 'Enemy Encounter scene: the traditional (RPG2000) layout draws no actor sprites' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new) # alternate_layout: false, the default
  ui = battle_to_command(scene)
  eq nil, ui[:actor_sprites], 'no actor-sprite layer at all, matching current (pre-change) behaviour'
end

# Out of scope for this step: the pose's `animation_type == 1` (a full
# Battle/<name> CBA animation sequence in place of a static sprite). Logs a
# diagnostic and draws nothing rather than guessing at animation playback --
# this codebase's established "reported gap, not silently invented"
# convention.
check 'Enemy Encounter scene: an Idle pose using the battle-animation (CBA) format logs a diagnostic and draws no sprite' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose(animation_type: 1) }) }
  scene = new_scene({ 1 => event(2, 2, auto) }, battleranimations: anims)
  st = scene.instance_variable_get(:@state)
  hero = BattleStubActor.new(id: 1, battler_animation_id: 5)
  st.instance_variable_set(:@party, BattleStubParty.new(hero, alternate_layout: true))
  ui = nil
  out = capture_stderr { ui = battle_to_command(scene) }
  eq [nil], ui[:actor_sprites], 'no sprite drawn for the unimplemented CBA pose format'
  ok out.include?('[RPG2k]'), 'the gap is reported, not silently invented'
end

# A dangling/missing battle-animation reference must never crash or change
# behaviour, the same convention every other database lookup in this
# codebase follows (see #battler_bitmap's own missing-graphic handling) --
# covers both a database with no Battler Animation table at all, and one
# whose table simply does not define the id the actor names.
check 'Enemy Encounter scene: an actor with no resolvable battle animation entry draws no sprite and does not crash' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) }) # no battleranimations table at all
  st = scene.instance_variable_get(:@state)
  hero = BattleStubActor.new(id: 1) # battler_animation_id left unresolved (nil)
  st.instance_variable_set(:@party, BattleStubParty.new(hero, alternate_layout: true))
  ui = battle_to_command(scene)
  ok ui, 'the battle still reaches the command phase without raising'
  eq [nil], ui[:actor_sprites], 'no sprite for an actor with no battle animation data at all'

  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose }) }
  auto2 = page(trigger: 3)
  auto2.event_commands = battle_event_commands(ic)
  scene2 = new_scene({ 1 => event(2, 2, auto2) }, battleranimations: anims)
  st2 = scene2.instance_variable_get(:@state)
  hero2 = BattleStubActor.new(id: 1, battler_animation_id: 99) # names no entry in `anims`
  st2.instance_variable_set(:@party, BattleStubParty.new(hero2, alternate_layout: true))
  ui2 = battle_to_command(scene2)
  ok ui2, 'a dangling id reaches the command phase without raising too'
  eq [nil], ui2[:actor_sprites], 'no sprite for a battle animation id the table does not define'
end

# The "Appear Transparent" flag (field 10, `Game::Enemy#transparent`) was
# parsed by the schema but read nowhere in mruby-rpg2k -- the same
# "parsed but unused" shape as the `levitate` flag above, and every enemy
# battler sprite drew fully opaque regardless. Verified against EasyRPG
# Player's actual C++ source: `Sprite_Enemy::Draw` (`src/sprite_enemy.cpp`)
# computes `alpha = 160 * alpha / 255` whenever `Game_Enemy::IsTransparent`
# is set, with no accuracy/evasion effect of any kind -- purely cosmetic,
# like `levitate`. Troop 3's lone Ghost (enemy id 4) is the dedicated
# fixture, kept off the two-Slime/lone-Bat troops so this never disturbs
# their own opacity-agnostic assertions (now pinned at a plain 255 above).
check 'Enemy Encounter scene: an "Appear Transparent" enemy draws at reduced ' \
      'opacity everywhere its sprite is (re)built' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, troop_id: 3)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  member = ui[:troop].members[0]
  ok member.transparent, 'the fixture enemy (id 4, Ghost) carries the flag'
  eq 160, ui[:enemy_sprites][0].opacity,
     'build_battle_sprites draws it at 160/255 opacity, matching EasyRPG exactly'

  # A mid-fight transformation redraw (#rebuild_battler_sprite) keeps the
  # reduced opacity, not just the initial build.
  ui[:foes][0].battler_name = 'Wraith'
  ui[:foes][0].name = 'Wraith'
  scene.instance_variable_get(:@battle).send(:refresh_battle_sprites)
  eq 160, ui[:enemy_sprites][0].opacity,
     'a transformation redraw keeps the reduced opacity'

  # Show Hidden Monster (#reveal_battle_monster) builds a fresh sprite too.
  ui[:foes][0].hidden = true
  ui[:troop].members[0].hidden = true
  scene.instance_variable_get(:@battle).send(:reveal_battle_monster, 0)
  eq 160, ui[:enemy_sprites][0].opacity,
     'Show Hidden Monster also draws it at the reduced opacity'
end

# The battle-graphic hue shift (field 3, `Game::Enemy#battler_hue`) was parsed
# by the schema but read nowhere in mruby-rpg2k -- the same "parsed but
# unused" shape as `levitate`/`transparent` above, so a game reusing one
# Monster/<name> bitmap for several palette-swapped monsters (a common
# RPG2000 authoring trick) always drew every one of them in the file's own
# unshifted colour. Verified against EasyRPG Player's actual C++ source:
# `Game_Enemy::GetHue` (`src/game_enemy.h`) is a bare `enemy->battler_hue`
# passthrough, and `Sprite_Enemy::OnMonsterSpriteReady`/`Refresh`
# (`src/sprite_enemy.cpp`) rotate the decoded bitmap through
# `Bitmap::HueChangeBlit` whenever it is nonzero and rebuild whenever either
# the sprite name or the hue changes. Troop 4's lone Red Slime (enemy id 5,
# reusing Slime's own "Slime" battler file at hue 120) is the dedicated
# fixture, kept off the two-Slime troop so this never disturbs its own
# zero-hue battler-cache assertions.
check 'Enemy Encounter scene: a battle-graphic hue shift rotates the battler ' \
      'bitmap, keyed separately from a same-named zero-hue battler' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, troop_id: 4)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  member = ui[:troop].members[0]
  eq 120, member.battler_hue, 'the fixture enemy (id 5, Red Slime) carries the hue'
  eq [120], ui[:enemy_sprites][0].bitmap.hue_calls,
     'build_battle_sprites rotates the decoded battler bitmap by the database hue'

  # The plain (hue 0) Slime shares this same scene's @monster_cache and the
  # very same "Slime" battler file -- its own decode must stay unrotated
  # rather than being mutated by the Red Slime's #hue_change call above,
  # since #battler_bitmap keys the cache by name+hue rather than name alone.
  plain = scene.instance_variable_get(:@battle).send(:battler_bitmap, Game::Enemy.new(scene.db, 2))
  ok plain.hue_calls.nil? || plain.hue_calls.empty?,
     'a same-file, zero-hue enemy decodes its own unrotated bitmap'

  # A mid-fight transformation redraw (#rebuild_battler_sprite) picks up the
  # new hue too, matching EasyRPG's `Sprite_Enemy::Refresh` rebuilding on
  # either the sprite name or the hue changing -- not just the initial build.
  ui[:foes][0].battler_name = 'Slime'
  ui[:foes][0].battler_hue = 0
  ui[:foes][0].name = 'Slime'
  scene.instance_variable_get(:@battle).send(:refresh_battle_sprites)
  ok ui[:enemy_sprites][0].bitmap.hue_calls.nil? ||
     ui[:enemy_sprites][0].bitmap.hue_calls.empty?,
     'transforming into the zero-hue battler redraws with no hue rotation'
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
  scene.instance_variable_get(:@battle).send(:refresh_battle_sprites)
  ok !sprites[0].visible, 'a monster that fled is taken off the field'
  ok !ui[:foes][0].dead?, 'without counting as a kill'
  ok sprites[1].visible, 'its companion is untouched'
  # #refresh_battle_sprites also mirrors the combatant's `hidden` onto the
  # *troop* member -- the flag #total_exp/#total_gold/#drops actually key off
  # -- since neither an AI Escape action nor Game::Battle#enemy_autodestruct
  # runs through the interpreter's Force-Flee queue (#remove_fled_monster).
  # Without this a self-fled/self-destructed monster would still pay full
  # rewards on victory.
  ok ui[:troop].members[0].hidden, 'the troop member is marked hidden too'
  ok !ui[:troop].members[1].hidden, 'its companion is untouched'
end

# 2000_battle_bot / デフォ戦bot trivia: 自爆した敵は、経験値・お金・アイテムを落と
# さない。しかもデータ内部では逃走した状態と同じ扱いになっており、敵ＨＰを変数に
# 代入してみると0になっていない。更に自爆後にイベントコマンド「敵キャラの出現」で
# 指定すると何喰わぬ顔で元に戻る。Verified against EasyRPG Player's actual C++
# source (see Game::Battle#enemy_autodestruct's own comment in mrblib/game.rb):
# Game_BattleAlgorithm::SelfDestruct never writes the caster's own HP, only
# SetHidden(true) -- so this scene-level check exercises the same "hidden, not
# killed" path a real self-destruct takes through #refresh_battle_sprites, and
# that Show Hidden Monster ("Enemy Appears") brings it right back unharmed.
check 'Enemy Encounter scene: a self-destructed monster drops no reward and ' \
      '"Enemy Appears" brings it back exactly as before (デフォ戦bot trivia)' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_to_command(scene)
  starting_hp = ui[:foes][0].hp
  # What Game::Battle#enemy_autodestruct now does to its own caster: hide it,
  # leave its HP untouched (no `b.hp = 0`).
  ui[:foes][0].hidden = true
  scene.instance_variable_get(:@battle).send(:refresh_battle_sprites)
  ok !ui[:foes][0].dead?, 'the caster does not die'
  eq starting_hp, ui[:foes][0].hp,
     'its HP reads unchanged, exactly as a variable assignment would show in real RPG_RT'
  ok ui[:troop].members[0].hidden, 'excluded from the troop reward roll'
  eq [ui[:troop].members[1]], ui[:troop].send(:live_members),
     'only the untouched companion still counts toward EXP/gold/drops'

  # "Enemy Appears" (Show Hidden Monster, 13150) targeting the exploded slot
  # brings it right back -- same path a genuinely-fled monster already uses.
  scene.instance_variable_get(:@battle).send(:reveal_battle_monster, 0)
  ok !ui[:troop].members[0].hidden, 'visible again'
  ok !ui[:foes][0].hidden, 'back in play'
  eq starting_hp, ui[:foes][0].hp, 'with the same HP it had before it blew up'
  eq [ui[:troop].members[0], ui[:troop].members[1]], ui[:troop].send(:live_members),
     'and it counts toward rewards again, same as any other live member'
end

# yado.tk's own text on the "airborne" enemy flag names no pixel offset or
# animation shape, only that it "changes its Y position on screen" -- but
# EasyRPG's `Game_Enemy::GetFlyingOffset` supplies both the missing magnitude
# (+/-4px) and period (256 frames) *and* an edition gate the site never
# mentions at all: real RPG2000 never renders it ("2k does not support
# flying, albeit mentioned in the help file" -- their comment), only RPG2003
# does. Troop 2 (Bats) is the lone-`levitate`-member fixture these exercise;
# troop 1's two Slimes (neither flagged) are untouched by any of this, which
# the existing battler-sprite checks above already pin.
check 'Scene::Map#flying_offset: RPG2003 + levitate is a +/-4px, 256-frame sine bob' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, troop_id: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new(rpg2003: true))
  ui = battle_to_command(scene)
  member = ui[:troop].members[0]
  ok member.levitate, 'the fixture enemy (id 3, Bat) carries the flag'

  ui[:frame] = 0
  eq 0, scene.instance_variable_get(:@battle).send(:flying_offset, member), 'frame 0: sin(0) = 0'
  ui[:frame] = 64 # a quarter period: sin(pi/2) = 1
  eq 4, scene.instance_variable_get(:@battle).send(:flying_offset, member), 'a quarter period in: the +4px peak'
  ui[:frame] = 128 # half period: sin(pi) = 0
  eq 0, scene.instance_variable_get(:@battle).send(:flying_offset, member), 'half a period in: back through 0'
  ui[:frame] = 192 # three-quarter period: sin(3pi/2) = -1
  eq(-4, scene.instance_variable_get(:@battle).send(:flying_offset, member), 'three-quarters in: the -4px trough')
end

check 'Scene::Map#update_enemy_positions: an RPG2003 fight actually bobs the sprite ' \
      'as frames pass, an RPG2000 one never does' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, troop_id: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new(rpg2003: true))
  ui = battle_to_command(scene)
  spr = ui[:enemy_sprites][0]
  member = ui[:troop].members[0]
  base_y = member.y - spr.bitmap.height / 2
  frame_before = ui[:frame]
  # Drive to the next frame landing exactly on a sine peak (frame % 256 ==
  # 64) so the expected offset is an exact, easily-asserted +4 rather than a
  # fraction -- computed from whatever `frame_before` actually is (the
  # once-per-battle options window's own dismiss press adds a frame before
  # reaching :command, so this cannot assume battle_to_command always lands
  # on frame 0) rather than a fixed multiple-of-64 offset, which only lands
  # on a peak one time in four.
  target = (frame_before / 256) * 256 + 64
  target += 256 while target <= frame_before
  (target - frame_before).times { scene.update }
  eq target, ui[:frame], 'the per-battle frame counter ticks once per scene.update'
  eq base_y + 4, spr.y, "the sprite's own y actually moved with it, not just " \
                        '#flying_offset in isolation'

  # The identical troop and flag, fought with no rpg2003? flag on the party,
  # never bobs at all -- matching EasyRPG's own edition gate, not merely a
  # missing test.
  scene2 = new_scene({ 1 => event(2, 2, auto) })
  st2 = scene2.instance_variable_get(:@state)
  st2.instance_variable_set(:@party, BattleStubParty.new(rpg2003: false))
  ui2 = battle_to_command(scene2)
  spr2 = ui2[:enemy_sprites][0]
  member2 = ui2[:troop].members[0]
  ok member2.levitate, 'still the same flagged enemy row'
  base_y2 = member2.y - spr2.bitmap.height / 2
  eq base_y2, spr2.y, 'RPG2000: no bob at battle open'
  target.times { scene2.update }
  eq base_y2, spr2.y, 'RPG2000: still no bob after the same number of frames ' \
                      '-- the database flag is parsed but the engine never ' \
                      'draws it, a real RPG_RT quirk, not a missing feature'
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

# -- --rpg2k_preview_map (map preview, see README.md's "Map exploration") ----
#
# RPG2k#preview_map_id reads the RPG2K_PREVIEW_MAP constant main.cxx sets from
# the flag (0 = unset, since map ids start at 1); Scene::Title#auto_new_game?
# then also fires on it, exactly like --rpg2k_new_game, so a preview needs
# only the one flag. #start_new_game itself (which loads the chosen map and
# centres the party on it) needs a real database and .lmu, so it is only
# exercised by the native boot check against real game data -- these two pin
# just the flag plumbing, in CRuby, without either.
check 'RPG2k#preview_map_id reads RPG2K_PREVIEW_MAP, 0 meaning unset' do
  read = lambda do |v|
    Object.send(:remove_const, :RPG2K_PREVIEW_MAP) if Object.const_defined?(:RPG2K_PREVIEW_MAP)
    Object.const_set(:RPG2K_PREVIEW_MAP, v) unless v.nil?
    RPG2k.allocate.send(:preview_map_id)
  end
  eq nil, read.call(nil), 'undefined constant (the CRuby-only checks) -> nil'
  eq nil, read.call(0), '0, the flag default -> nil'
  eq 7, read.call(7)
  Object.send(:remove_const, :RPG2K_PREVIEW_MAP) if Object.const_defined?(:RPG2K_PREVIEW_MAP)
end

check '--rpg2k_preview_map auto-selects New Game, like --rpg2k_new_game' do
  clear_title_flags
  parent = Struct.new(:preview_map_id).new(7)
  scene = RPG2k::Scene::Title.allocate
  scene.instance_variable_set(:@auto_started, false)
  scene.instance_variable_set(:@selected_index, 0)
  scene.instance_variable_set(:@parent, parent)
  ok scene.send(:auto_select?), 'the first frame fires the auto-select'
  eq 0, scene.instance_variable_get(:@selected_index), 'New Game is entry 1'
  ok !scene.send(:auto_select?), 'it does not fire again on the next frame'
end

# --rpg2k_battle_troop also implies New Game (a headless battle needs the map
# up first), the same way --rpg2k_preview_map does.
check '--rpg2k_battle_troop auto-selects New Game, like --rpg2k_new_game' do
  clear_title_flags
  parent = Struct.new(:headless_battle_troop).new(14)
  scene = RPG2k::Scene::Title.allocate
  scene.instance_variable_set(:@auto_started, false)
  scene.instance_variable_set(:@selected_index, 0)
  scene.instance_variable_set(:@parent, parent)
  ok scene.send(:auto_select?), 'the first frame fires the auto-select'
  eq 0, scene.instance_variable_get(:@selected_index), 'New Game is entry 1'
  ok !scene.send(:auto_select?), 'it does not fire again on the next frame'
end

# RPG2k#headless_battle_troop reads the RPG2K_BATTLE_TROOP constant main.cxx
# sets from the --rpg2k_battle_troop flag (0 = unset, since troop ids start at
# 1); Scene::Map#headless_battle then opens a fight against it once New Game's
# map is up. The full drive (New Game -> map -> battle scene) is exercised by
# the native boot check against real game data -- these pin just the flag
# plumbing, in CRuby, without a database or .lmu.
check 'RPG2k#headless_battle_troop reads RPG2K_BATTLE_TROOP, 0 meaning unset' do
  read = lambda do |v|
    Object.send(:remove_const, :RPG2K_BATTLE_TROOP) if Object.const_defined?(:RPG2K_BATTLE_TROOP)
    Object.const_set(:RPG2K_BATTLE_TROOP, v) unless v.nil?
    RPG2k.allocate.send(:headless_battle_troop)
  end
  eq nil, read.call(nil), 'undefined constant (the CRuby-only checks) -> nil'
  eq nil, read.call(0), '0, the flag default -> nil'
  eq 14, read.call(14)
  Object.send(:remove_const, :RPG2K_BATTLE_TROOP) if Object.const_defined?(:RPG2K_BATTLE_TROOP)
end

# Scene::Map#headless_battle (the --rpg2k_battle boot drive) arms the same
# :battle wait a random encounter does, marked `headless: true` so
# Scene::Battle#start fires the [RPG2k-BATTLE] marker the boot check asserts
# on. The request rides the map's own foreground interpreter and opens on the
# next frame via the ordinary #drive_battle path.
check 'Scene::Map#headless_battle arms a headless battle request on the interpreter' do
  scene = new_scene({})
  scene.headless_battle(14)
  it = scene.instance_variable_get(:@interpreter)
  eq :battle, it.wait_kind, 'the interpreter waits on the battle'
  eq 14, it.battle_request[:troop_id], 'the requested troop id'
  eq true, it.battle_request[:headless], 'the boot-drive marker rides the request'
  eq true, it.battle_request[:random], 'otherwise a random-encounter-shaped request'
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
TitleParent = Struct.new(:db, :map_tree, :hide_title_flag, :any_save_flag) do
  def hide_title?; hide_title_flag; end
  def any_save_exists?; any_save_flag; end
  # Scene::SaveLoad reads one of these per slot when Continue opens it; every
  # slot answers empty here since these checks only care whether Continue
  # opens the picker at all, not what it shows once open (Scene::SaveLoad has
  # its own checks for that, built through fake_parent like the rest of the
  # menu scenes).
  def load_save_state(_slot = 1); nil; end
  def pushed; @pushed ||= []; end
  def push(scene); pushed << scene; end
  # Kept for parity with the real RPG2k#continue_game the --rpg2k_continue
  # headless flag still calls directly (Scene::Title#update), even though no
  # check here drives that path through a TitleParent.
  def continue_calls; @continue_calls || 0; end
  def continue_game(_slot = 1); @continue_calls = continue_calls + 1; end
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
# resume; `any_save_exists?` (main.rb) is the source of truth, routed through
# Scene::Title's own `continue_available?` (ADR 0012, extended by ADR 0045 to
# cover every slot rather than just slot 1). The cursor can still reach the
# grayed-out entry, and confirming it is not silent -- it plays Buzzer
# (confirmed against EasyRPG's own Scene_Title::CommandContinue) rather than
# doing nothing at all, but still never opens the file-select screen.

check 'no save data: Continue is flagged unavailable and reachable by the cursor' do
  parent = TitleParent.new(fake_db, nil, false, false)
  scene = RPG2k::Scene::Title.new(parent)
  ok !scene.instance_variable_get(:@continue_available), 'Continue is flagged unavailable'
  scene.send(:move_selection, 1)
  eq 1, scene.instance_variable_get(:@selected_index),
     'moving down from New Game still lands on Continue'
end

# See Scene::ItemMenu's identical check for the fuller writeup
# (Window_Selectable::Update falls through to Input::IsRepeated right after
# IsTriggered). `RGSS::Input.repeated` (distinct from `.triggered`) lets
# this check hold a key across frames without it also reading as a fresh
# trigger.
check 'holding Down auto-repeats the title command cursor, not just a ' \
      'single step per tap' do
  parent = TitleParent.new(fake_db, nil, false, false)
  scene = RPG2k::Scene::Title.new(parent)
  RGSS::Input.repeated = [RGSS::Input::DOWN] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@selected_index),
     'a held (repeated, not triggered) Down still moves the cursor one step'
end

check 'no save data: pressing the selection key on Continue plays Buzzer and opens nothing' do
  parent = TitleParent.new(fake_db, nil, false, false)
  scene = RPG2k::Scene::Title.new(parent)
  scene.instance_variable_set(:@selected_index, 1)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 0, parent.pushed.size,
     'a grayed-out Continue never opens the save/load file-select screen'
  eq 1, scene.instance_variable_get(:@selected_index), 'the selection is left untouched'
end

# EasyRPG's Window_Command::DrawItem (src/window_command.cpp) draws every
# command through the windowskin's own system-colour palette, chosen by
# Font::ColorDisabled (index 3, src/font.h) once Scene_Title disables
# Continue (command_window->SetItemEnabled(1, continue_enabled),
# src/scene_title.cpp) -- never a hardcoded flat gray. A custom windowskin
# whose disabled swatch is tinted shows that tint on real RPG_RT, with the
# same drop-shadow every other label gets.
check 'no save data, with a windowskin loaded: the disabled Continue label ' \
      'blends from the windowskin\'s own disabled-colour swatch (index 3), ' \
      'not a hardcoded flat gray' do
  db = fake_db
  db.system.system_graphic = 'Skin1' # non-empty -> load_windowskin returns a real Bitmap
  parent = TitleParent.new(db, nil, false, false)
  scene = RPG2k::Scene::Title.new(parent)
  bc = scene.instance_variable_get(:@window).contents.blend_calls || []
  # colour 3 -> swatch cell (3%10*16, 3/10*16+48) = (48, 48), the same
  # geometry the message-text swatch check above pins.
  ok bc.any? { |call| call[6] == 48 && call[7] == 48 },
     'the disabled Continue label blends from swatch index 3 (48, 48), ' \
     'the same convention every other disabled command uses in real RPG_RT'
end

check 'a save exists: Continue is flagged available and its selection key opens ' \
      'the file-select screen' do
  # Continue used to call parent.continue_game straight from the title screen
  # (ADR 0012); it now opens Scene::SaveLoad in :load mode instead, so the
  # player picks which of the MAX_SAVE_SLOTS slots to resume rather than
  # always landing on slot 1 (ADR 0045).
  parent = TitleParent.new(fake_db, nil, false, true)
  scene = RPG2k::Scene::Title.new(parent)
  ok scene.instance_variable_get(:@continue_available), 'Continue is flagged available'
  scene.instance_variable_set(:@selected_index, 1)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  eq 1, parent.pushed.size, 'pressing the selection key on Continue opens exactly one screen'
  pushed = parent.pushed.first
  ok pushed.is_a?(RPG2k::Scene::SaveLoad), "the pushed scene is Scene::SaveLoad, got #{pushed.class}"
  eq :load, pushed.instance_variable_get(:@mode), 'opened in :load mode'
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

# A captured transition's blt calls are [dx, dy, src, src_rect]; this is the
# [dx, dy] destination alone, which is what the geometry checks below compare.
def blt_dest(call); call[0, 2]; end

check 'a captured transition snapshots the screen once and blits it sliding into place' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)
  # Show is a no-op on an already-visible screen (#show / #erase both settle
  # instantly onto their own target), so erase first -- same as a real Show
  # Screen always follows some earlier Erase.
  st.screen.erase(Game::Transition::FADE_OUT, 1)
  2.times { scene.update }

  snap = RGSS::Bitmap.new(320, 240)
  RGSS::Graphics.snapshot = snap
  st.screen.show(Game::Transition::SCROLL_UP_IN)
  fade.bitmap.clear_blt_calls
  scene.update
  eq 255, fade.opacity, 'a captured style paints, so it is fully opaque like a mask'
  blts = fade.bitmap.blt_calls || []
  eq 1, blts.length, 'scroll pastes the whole capture in one piece'
  dx, dy, src, rect = blts.first
  eq 0, dx, 'scrolling up only moves along y'
  ok dy > 0, 'frame 0 of scroll-up-in starts below the screen'
  ok src.equal?(snap), 'blitted from the captured snapshot, not a fresh bitmap'
  eq [0, 0, 320, 240], [rect.x, rect.y, rect.width, rect.height],
     'the whole capture is the source, for a plain scroll'

  # Advancing to the last frame the transition is still alive on settles it at
  # (0, 0) -- flush, not still sliding. (One update further and Game::Screen
  # nils the transition entirely, same as any other style once it completes;
  # #update already spent one call above, hence frames - 3 here.)
  mid = Game::Transition.default_frames(Game::Transition::SCROLL_UP_IN) - 3
  mid.times { scene.update }
  fade.bitmap.clear_blt_calls
  scene.update
  eq [0, 0], blt_dest(fade.bitmap.blt_calls.first), 'lands flush on the last live frame'

  # The snapshot is taken exactly once per transition instance, not every frame.
  st.screen.erase(Game::Transition::VERTICAL_DIVISION)
  first_snap = RGSS::Bitmap.new(320, 240)
  RGSS::Graphics.snapshot = first_snap
  scene.update
  RGSS::Graphics.snapshot = RGSS::Bitmap.new(320, 240) # a second snapshot, unused if caching works
  fade.bitmap.clear_blt_calls
  scene.update
  ok fade.bitmap.blt_calls.all? { |c| c[2].equal?(first_snap) },
     're-uses the snapshot taken when this transition started'
ensure
  RGSS::Graphics.snapshot = nil
end

check 'vertical division splits the capture into two pieces sliding apart' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)
  RGSS::Graphics.snapshot = RGSS::Bitmap.new(320, 240)

  st.screen.erase(Game::Transition::VERTICAL_DIVISION)
  fade.bitmap.clear_blt_calls
  scene.update
  blts = fade.bitmap.blt_calls
  eq 2, blts.length, 'top half and bottom half, each their own piece'
  top, bottom = blts
  # Frame 1 (the first rendered frame -- #update already advanced once before
  # drawing): barely split apart yet, close to the still-combined origin.
  eq [0, -3], blt_dest(top), 'top half has only just started sliding up'
  eq [0, 123], blt_dest(bottom), 'bottom half has only just started sliding down'
  eq [0, 0, 320, 120], [top[3].x, top[3].y, top[3].width, top[3].height],
     "the top half's own share of the capture"
  eq [0, 120, 320, 120], [bottom[3].x, bottom[3].y, bottom[3].width, bottom[3].height],
     "the bottom half's own share"

  mid = Game::Transition.default_frames(Game::Transition::VERTICAL_DIVISION) - 3
  mid.times { scene.update }
  fade.bitmap.clear_blt_calls
  scene.update
  top, bottom = fade.bitmap.blt_calls
  eq [0, -120], blt_dest(top), 'finished: the top half has slid fully off the top edge'
  eq [0, 240], blt_dest(bottom), 'and the bottom half fully off the bottom edge'
ensure
  RGSS::Graphics.snapshot = nil
end

check 'cross combine assembles four quadrants from the screen corners' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)
  st.screen.erase(Game::Transition::FADE_OUT, 1) # show is a no-op unless erased first
  2.times { scene.update }
  RGSS::Graphics.snapshot = RGSS::Bitmap.new(320, 240)

  st.screen.show(Game::Transition::CROSS_COMBINE)
  fade.bitmap.clear_blt_calls
  scene.update
  blts = fade.bitmap.blt_calls
  eq 4, blts.length, 'top-left/top-right/bottom-left/bottom-right'
  dests = blts.map { |c| blt_dest(c) }
  # Frame 1: each quadrant has only just started sliding in from its corner.
  eq [[-156, -117], [316, -117], [-156, 237], [316, 237]], dests,
     'each quadrant is still almost entirely off-screen past its own corner'

  mid = Game::Transition.default_frames(Game::Transition::CROSS_COMBINE) - 3
  mid.times { scene.update }
  fade.bitmap.clear_blt_calls
  scene.update
  dests = fade.bitmap.blt_calls.map { |c| blt_dest(c) }
  eq [[0, 0], [160, 0], [0, 120], [160, 120]], dests,
     'finished: the four quadrants tile the screen exactly'
ensure
  RGSS::Graphics.snapshot = nil
end

check 'a captured transition falls back to a plain fade when the backend cannot snapshot' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)

  RGSS::Graphics.snapshot = nil # e.g. the Wio/PSP builds, LV_USE_SNAPSHOT off
  st.screen.erase(Game::Transition::SCROLL_LEFT_OUT, 4)
  4.times { scene.update }
  eq 255, fade.opacity, 'still lands on the right end state via the fade fallback'
  ok (fade.bitmap.blt_calls || []).empty?, 'nothing to blit without a snapshot'
end

check 'zoom in resamples a shrinking crop of the capture, stretched full-screen' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)
  snap = RGSS::Bitmap.new(320, 240)
  RGSS::Graphics.snapshot = snap

  st.screen.erase(Game::Transition::ZOOM_IN)
  fade.bitmap.clear_stretch_calls
  scene.update
  eq 255, fade.opacity, 'a captured style paints, so it is fully opaque like a mask'
  ok (fade.bitmap.blt_calls || []).empty?, 'zoom resamples, it never uses the 1:1 paste path'
  stretches = fade.bitmap.stretch_calls || []
  eq 1, stretches.length, 'zoom is a single resampled piece'
  drect, src, srect = stretches.first
  eq [0, 0, 320, 240], [drect.x, drect.y, drect.width, drect.height],
     'the destination always fills the whole screen -- zoom crops the source, not the drawn size'
  ok src.equal?(snap), 'resampled from the captured snapshot'
  eq [4, 3, 312, 234], [srect.x, srect.y, srect.width, srect.height],
     'frame 0 of zoom-in has barely cropped in from the full capture yet'

  mid = Game::Transition.default_frames(Game::Transition::ZOOM_IN) - 3
  mid.times { scene.update }
  fade.bitmap.clear_stretch_calls
  scene.update
  srect = fade.bitmap.stretch_calls.first[2]
  eq [160, 120, 0, 0], [srect.x, srect.y, srect.width, srect.height],
     'finished: cropped down to nothing at the screen centre, so nothing paints over the black fill'
ensure
  RGSS::Graphics.snapshot = nil
end

check 'zoom out resamples a growing crop of the capture, stretched full-screen' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)
  st.screen.erase(Game::Transition::FADE_OUT, 1) # show is a no-op unless erased first
  2.times { scene.update }
  RGSS::Graphics.snapshot = RGSS::Bitmap.new(320, 240)

  st.screen.show(Game::Transition::ZOOM_OUT)
  fade.bitmap.clear_stretch_calls
  scene.update
  srect = fade.bitmap.stretch_calls.first[2]
  eq [156, 117, 8, 6], [srect.x, srect.y, srect.width, srect.height],
     'frame 0 of zoom-out starts as a sliver at the screen centre'

  mid = Game::Transition.default_frames(Game::Transition::ZOOM_OUT) - 3
  mid.times { scene.update }
  fade.bitmap.clear_stretch_calls
  scene.update
  srect = fade.bitmap.stretch_calls.first[2]
  eq [0, 0, 320, 240], [srect.x, srect.y, srect.width, srect.height],
     'finished: the crop has grown back out to the whole capture'
ensure
  RGSS::Graphics.snapshot = nil
end

check 'mosaic transitions resample the capture through a shrinking/growing block size' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)
  snap = RGSS::Bitmap.new(320, 240)
  RGSS::Graphics.snapshot = snap

  # Erase (MOSAIC_OUT): starts sharp (block size 1) and gets chunkier --
  # EasyRPG's `m_size = current_frame + 1`, confirmed against
  # src/transition.cpp's TransitionMosaicOut case.
  st.screen.erase(Game::Transition::MOSAIC_OUT)
  fade.bitmap.clear_mosaic_calls
  scene.update
  eq 255, fade.opacity, 'a captured style paints, so it is fully opaque like a mask'
  ok (fade.bitmap.blt_calls || []).empty?, 'mosaic never uses the 1:1 paste path'
  ok (fade.bitmap.stretch_calls || []).empty?, 'mosaic never uses the resize path either'
  calls = fade.bitmap.mosaic_calls || []
  eq 1, calls.length, 'mosaic resamples the whole capture in one native call'
  cap, size = calls.first
  ok cap.equal?(snap), 'resampled from the captured snapshot'
  eq 2, size, 'frame 1 (the first rendered frame) is barely chunkier than sharp'

  mid = Game::Transition.default_frames(Game::Transition::MOSAIC_OUT) - 3
  mid.times { scene.update }
  fade.bitmap.clear_mosaic_calls
  scene.update
  size = fade.bitmap.mosaic_calls.first[1]
  eq 41, size, 'finished: as chunky as the transition ever gets'

  # Show (MOSAIC_IN): starts fully mosaic'd and sharpens -- `m_size =
  # total_frames - current_frame`, the same ramp run backwards.
  st.screen.erase(Game::Transition::FADE_OUT, 1) # show is a no-op unless erased first
  2.times { scene.update }

  st.screen.show(Game::Transition::MOSAIC_IN)
  fade.bitmap.clear_mosaic_calls
  scene.update
  size = fade.bitmap.mosaic_calls.first[1]
  eq 40, size, 'frame 1 of a show starts almost as chunky as it gets'

  mid = Game::Transition.default_frames(Game::Transition::MOSAIC_IN) - 3
  mid.times { scene.update }
  fade.bitmap.clear_mosaic_calls
  scene.update
  size = fade.bitmap.mosaic_calls.first[1]
  eq 1, size, 'finished: sharpened all the way down to 1px blocks'
ensure
  RGSS::Graphics.snapshot = nil
end

check 'wave transitions resample the capture through the depth/phase ramp' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)
  snap = RGSS::Bitmap.new(320, 240)
  RGSS::Graphics.snapshot = snap

  # Erase (WAVE_OUT): depth/phase grow as the screen prepares to vanish --
  # EasyRPG's `p = current_frame + 1`, confirmed against src/transition.cpp's
  # TransitionWaveOut case (itself Bitmap::WaverBlit's depth/phase args).
  st.screen.erase(Game::Transition::WAVE_OUT)
  fade.bitmap.clear_wave_calls
  scene.update
  ok (fade.bitmap.blt_calls || []).empty?, 'wave never uses the 1:1 paste path'
  ok (fade.bitmap.stretch_calls || []).empty?, 'wave never uses the resize path either'
  calls = fade.bitmap.wave_calls || []
  eq 1, calls.length, 'wave resamples the whole capture in one native call'
  cap, depth, phase = calls.first
  ok cap.equal?(snap), 'resampled from the captured snapshot'
  eq 2, depth, 'frame 1 (the first rendered frame) has barely started waving'
  eq 1.25 * Math::PI, phase

  mid = Game::Transition.default_frames(Game::Transition::WAVE_OUT) - 3
  mid.times { scene.update }
  fade.bitmap.clear_wave_calls
  scene.update
  depth, phase = fade.bitmap.wave_calls.first[1, 2]
  eq 41, depth, 'finished: the widest the wave ever gets'
  eq 6.125 * Math::PI, phase

  # Show (WAVE_IN): the same ramp run backwards, settling flat.
  st.screen.erase(Game::Transition::FADE_OUT, 1) # show is a no-op unless erased first
  2.times { scene.update }

  st.screen.show(Game::Transition::WAVE_IN)
  fade.bitmap.clear_wave_calls
  scene.update
  depth, phase = fade.bitmap.wave_calls.first[1, 2]
  eq 40, depth, 'frame 1 of a show starts almost as wide as it gets'
  eq 6 * Math::PI, phase

  mid = Game::Transition.default_frames(Game::Transition::WAVE_IN) - 3
  mid.times { scene.update }
  fade.bitmap.clear_wave_calls
  scene.update
  depth, phase = fade.bitmap.wave_calls.first[1, 2]
  eq 1, depth, 'finished: settled down to a near-flat wave'
  eq 1.125 * Math::PI, phase
ensure
  RGSS::Graphics.snapshot = nil
end

check 'random blocks paint incrementally: solid black once, then only new blocks' do
  scene = new_scene({}, player: [5, 5])
  fade, = overlay(scene)
  scene.update
  st = scene.instance_variable_get(:@state)

  st.screen.erase(Game::Transition::RANDOM_BLOCKS)
  fade.bitmap.fill_calls.clear if fade.bitmap.fill_calls
  scene.update
  eq 255, fade.opacity, 'the mask itself carries the shape, not the opacity'
  # #update already advanced once before this first draw (same "frame 1 is
  # the first rendered frame" quirk the capture tests above rely on), so the
  # very first paint has to catch up on everything due by frame 1, not just
  # frame 1's own delta -- Game::Transition#revealed_block_rects, not
  # #new_block_rects. 4800 * 2 / 40 = 240 blocks due by frame 1.
  fills = fade.bitmap.fill_calls || []
  eq 241, fills.length, 'one full-screen black fill, then every block due by frame 1'
  eq [0, 0, 320, 240], fills.first[0, 4], 'blacked out first'
  fills.drop(1).each { |f| eq [4, 4], f[2, 2], 'every punched block is 4x4' }

  # The next frame only punches its own newly revealed blocks -- no repeat
  # full-screen fill, and nothing already punched is painted again.
  fade.bitmap.fill_calls.clear
  scene.update
  fills = fade.bitmap.fill_calls || []
  ok fills.none? { |f| f[0, 4] == [0, 0, 320, 240] },
     'no repeat full-screen fill once the overlay has already started black'
  eq 120, fills.length, "one frame's worth of newly revealed blocks"
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

# EasyRPG's `Game_Interpreter_Map::CommandOpenMainMenu`
# (src/game_interpreter_map.cpp) is gated only on
# `Game_Message::IsMessageActive()`, no `main_flag` restriction, so a
# Parallel Process can trigger it exactly like the foreground can. Before
# this fix, `Scene::Map#drive_parallel_wait` had no `:menu` branch, so it
# fell into the generic "background: resume" default and a Parallel
# Process's own Open Main Menu silently never opened the menu at all.
check 'Open Main Menu issued from a Parallel Process also pushes the field menu' do
  par = page(trigger: 4) # Parallel Process
  par.event_commands = [ECmd.new(IC2::OPEN_MAIN_MENU, []), add_var_cmd(6)]
  scene = new_scene({ 1 => event(2, 2, par) }, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  2.times { scene.update } # raises the :menu wait, then opens the menu
  eq 1, parent.pushed.length, 'the menu scene was pushed for a Parallel-Process-issued command'
  eq 0, st.variables[6], 'the process is paused while the menu is open'
  2.times { scene.update } # back from the menu: the wait releases, then the process continues
  eq 1, st.variables[6], 'the process resumed after the menu closed'
end

check 'Open Main Menu ignores a Change Main Menu Access lock -- unlike the ' \
      "player's own Cancel-key shortcut, the event-triggered menu still opens" do
  # A yado.tk-catalogued quirk (docs/TODO.md's "Menu screen" bullet, Untriaged
  # backlog): Prohibit Menu (Change Main Menu Access) only blocks the
  # player's own Cancel-key shortcut for opening the field menu -- it does
  # not gate this event command at all, the same way Change Save Access does
  # not gate Open Save Menu (see that check just above). `perform_event_menu`
  # (mruby-rpg2k/mrblib/scene/map.rb) already never reads `@state.menu_access`
  # at all, so this was already correct -- this check just closes the gap
  # where nothing exercised that specific claim.
  cmds = [ECmd.new(IC2::OPEN_MAIN_MENU, [])]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  st.menu_access = false
  scene.instance_variable_get(:@interpreter).start(cmds)
  2.times { scene.update } # raises the :menu wait, then opens the menu
  eq 1, parent.pushed.length, 'the menu opens even though menu_access is false'
  ok parent.pushed.first.is_a?(RPG2k::Scene::Menu),
     "pushed Scene::Menu, got #{parent.pushed.first.class}"
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
# up. Returns [scene, state]. `party` defaults to the plain fixture every
# check predating the gauge-card status panel used; a check exercising a
# non-default battle-screen presentation (BattleStubParty's `gauge_layout:`)
# passes its own instead.
def battle_scene_with_pages(pages, party: BattleStubParty.new, battleranimations: nil,
                            rpg2003: false, battlecommands: nil)
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) }, troop_pages: pages,
                    battleranimations: battleranimations,
                    rpg2003: rpg2003, battlecommands: battlecommands)
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, party)
  [scene, st]
end

# The per-battler `source` the boundary page check runs with: a troop page
# gated on `command_actor` fires when the *acting* battler chose the command
# (Game::Battle#actor_command with the scene-passed #acting_battler) -- the
# ADR 0054 follow-up that made the condition satisfiable at all. The
# model-side gating is pinned in rpg2k_logic_check.rb; this drives a real
# gauge battle through the 2003 scene so the boundary check actually hands
# the acting battler over.
check 'a command_actor troop page fires at the acting battler\'s turn in a gauge battle' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CONTROL_SWITCHES, [0, 5, 5, 0])],
                            Game::BattlePage::COMMAND_ACTOR,
                            command_actor_id: 1, command_id: 1) }
  scene, st = battle_scene_with_pages(pages, rpg2003: true,
                                      battlecommands: OpenStruct.new(battle_type: 2, placement: 1))
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(BattleStubActor.new(agi: 20)))
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the gauge battle opened to the ready actor\'s menu'
  eq false, st.switches[5], 'the page has not fired yet'
  press_key(scene, RGSS::Input::C) # Attack -- the fixed-four command id 1
  eq :target, ui[:phase], 'Attack opens the target cursor'
  press_key(scene, RGSS::Input::C) # the first Slime: the action begins
  # The action's boundary check runs the troop's pages for the acting battler
  # (the hero, who chose Attack = command id 1), so the command_actor page
  # fires and its event toggles switch 5.
  5.times { scene.update }
  eq true, st.switches[5], 'the command_actor page fired at the acting hero\'s turn'
end

# The Special command in a gauge fight: choosing it forfeits the ready actor's
# turn (EasyRPG's DoNothing), spending the held gauge and returning to the ATB
# idle loop without any action -- the active-time counterpart to the round-
# based Special check above.
check "a gauge battle: the Special command spends the ready actor's turn and returns to the ATB loop" do
  scene, st = battle_scene_with_pages({}, rpg2003: true,
                                      battlecommands: OpenStruct.new(battle_type: 2, placement: 1))
  actor = BattleStubActor.new(agi: 20,
    battle_commands: [12, 0, -1, -1, -1, -1, -1],
    battle_command_table: { 12 => BattleCommandDef.new('Stall', Game::Actor::BATTLE_COMMAND_SPECIAL) })
  st.instance_variable_set(:@party, BattleCustomCommandParty.new(actor))
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the gauge battle opened to the ready actor\'s menu'
  hero = ui[:allies][0]
  eq true, hero.gauge_full?, 'the actor\'s gauge is held full while the menu is open'
  press_key(scene, RGSS::Input::C) # the only row: the Special at ref 12
  eq :animate, ui[:phase], 'Special commits at once -- no target/skill/item submenu'
  scene.update
  eq :atb, ui[:phase], 'the consumed turn returns to the active-time idle loop'
  ok !hero.gauge_full?, 'the Special turn spent the hero\'s held-full gauge (it refills from the ATB loop)'
  hero_attacked = ui[:battle].log.any? { |e| e[:attacker] == 'Hero' }
  eq false, hero_attacked, 'the Special turn produced no action entry'
end

# -- automatic battler placement (`battlecommands.placement == 1`) -------------
#
# Port of EasyRPG's Calculate2k3BattlePosition (src/game_battle.cpp): a
# placement-1 database computes each party member's battle sprite position
# from a grid keyed by party index/size and the encounter terrain, instead of
# the manual battle_x/battle_y. The fixture terrain (fake_db's tile tag 42)
# names no grid fields, so the reference's no-terrain defaults (112 / 392 /
# 16000) apply; half a 48px BattleCharSet cell (24) is the row/width offset.

# A placement-1 gauge battle whose actor sprites build, for the placement
# checks. `ids` become the party (one BattleStubActor each, carrying its own
# BattlerAnimation id so `build_actor_sprite` draws a sprite -- the harness
# Bitmap stub stands in for the BattleCharSet sheet). The fixture terrain the
# party stands on (tag 42) is given the reference's own no-terrain grid
# parameters (112 / 392 / 16000) so the checks' expected coordinates are
# explicit; `battle_xy:` supplies per-actor manual coordinates for the
# placement-0 check.
def placement_battle(ids, placement: 1, battle_xy: {}, battle_type: 2, poses: nil)
  members = ids.map do |id|
    xy = battle_xy[id] || [0, 0]
    BattleStubActor.new(id: id, agi: 20, battler_animation_id: id,
                        battle_x: xy[0], battle_y: xy[1])
  end
  anims = {}
  members.each do |a|
    anims[a.id] = battle_pose_set(name: 'Fighter',
                                  poses: poses || { 0 => battle_pose(battler_name: 'Party', battler_index: 0) })
  end
  party = BattleStubParty.new(members.first, alternate_layout: true,
                              automatic_placement: placement == 1, actors: members)
  scene, = battle_scene_with_pages({}, party: party, rpg2003: true,
                                   battlecommands: OpenStruct.new(placement: placement, battle_type: battle_type),
                                   battleranimations: anims)
  grid = scene.db.terrain[42]
  grid.grid_top_y = 112
  grid.grid_elongation = 392
  grid.grid_inclination = 16000
  # Drive the battle open (the actor sprites are built in Scene::Battle#start).
  # A round-based (battle_type 0) command phase commands actor 0 first and
  # deterministically, unlike a gauge fight's ready-first ordering, which is
  # what the Row/row_x_offset check below needs.
  battle_type == 0 ? battle_to_command(scene) : battle_until_phase(scene, :command, 250)
  scene
end

def placement_sprites(scene)
  ui = battle_ui(scene)
  ui && ui[:actor_sprites]
end

check 'automatic battler placement seats a lone party member on the grid, not battle_x/battle_y' do
  scene = placement_battle([1])
  sprites = placement_sprites(scene)
  ok sprites && sprites[0], 'the actor sprite was built'
  eq [264, 110], [sprites[0].x, sprites[0].y],
     'the no-terrain grid for a party of one: 320 - (grid.x 8 + 24 + 24), grid.y 134 - 24'
end

check 'automatic battler placement seats a two-member party on its two grid slots' do
  scene = placement_battle([1, 2])
  sprites = placement_sprites(scene)
  eq [[256, 88], [272, 133]],
     [[sprites[0].x, sprites[0].y], [sprites[1].x, sprites[1].y]],
     'member 0 at grid slot (16, 112), member 1 at (0, 157), each minus a 24px half-cell'
end

check 'manual battler placement keeps the database battle_x/battle_y, unchanged' do
  scene = placement_battle([1], placement: 0, battle_xy: { 1 => [120, 90] })
  sprites = placement_sprites(scene)
  eq [120, 90], [sprites[0].x, sprites[0].y],
     'placement 0 reads the actor\'s own coordinates, no grid involved'
end

check 'the Row command moves an automatic-placement actor sprite by row_x_offset' do
  # A two-member party's own grid slots (the "seats a two-member party"
  # check above): member 0 starts front row at x=256 (320 - (grid.x 16 + a
  # 24px half-cell + the front-row row_x_offset, also 24)). Flipping it to
  # the back row drops row_x_offset to 0, moving the sprite to x=280 -- the
  # same reposition #reposition_actor_sprite now drives right when the Row
  # command's toggle succeeds, rather than leaving the old front-row sprite
  # on screen until an unrelated redraw happens to catch it up.
  scene = placement_battle([1, 2], battle_type: 0)
  sprites = placement_sprites(scene)
  eq [256, 88], [sprites[0].x, sprites[0].y], 'member 0 starts on its front-row grid slot'
  ui = battle_ui(scene)
  eq %w[Attack Skill Defend Item Row], ui[:cmd_win].contents.draw_calls.map { |c| c[4] }
  4.times { press_key(scene, RGSS::Input::DOWN) } # Attack -> Skill -> Defend -> Item -> Row
  press_key(scene, RGSS::Input::C)
  hero = ui[:allies][0]
  eq Game::Battle::ROW_BACK, hero.row, 'member 0 moved to the back row'
  sprites = placement_sprites(scene)
  eq [280, 88], [sprites[0].x, sprites[0].y],
     'the sprite followed the row change: same grid slot, row_x_offset now 0 instead of 24'
end

check 'a defending actor draws the Defend pose, reverting to Idle once the round ends' do
  # EasyRPG's Sprite_Actor::DoIdleAnimation checks IsDefending() before
  # anything else -- ported as #build_actor_sprite's `defending:` keyword
  # (Pose id 7), driven by #reposition_actor_sprite right when Defend
  # commits and again once Game::Battle#end_round clears the flag.
  poses = { 0 => battle_pose(battler_name: 'Party', battler_index: 0),
           7 => battle_pose(battler_name: 'Party', battler_index: 3) }
  scene = placement_battle([1, 2], placement: 0, battle_type: 0, poses: poses)
  ui = battle_ui(scene)
  # The sprite's src_rect Y is `pose.battler_index * ACTOR_CHARSET_CELL`
  # (the sheet row the pose itself names, `poses` above) -- not the pose id
  # (7 for Defend) directly.
  idle_y = 0 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL
  defend_y = 3 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL

  sprites = placement_sprites(scene)
  eq [idle_y, idle_y], [sprites[0].src_rect.y, sprites[1].src_rect.y], 'both start on the Idle pose'

  2.times { press_key(scene, RGSS::Input::DOWN) } # Attack -> Skill -> Defend
  press_key(scene, RGSS::Input::C)                # member 0 defends
  sprites = placement_sprites(scene)
  eq defend_y, sprites[0].src_rect.y, "member 0's sprite swaps to Defend the instant it commits"
  eq idle_y, sprites[1].src_rect.y, "member 1 hasn't acted yet, still Idle"

  # #finish_round_animation itself (not the many real frames a full round of
  # message banners and enemy turns takes to animate out) is what reverts
  # the sprite -- called directly, the same way other checks drive a scene's
  # private step methods rather than re-proving the whole round machine's
  # own timing here.
  ui[:allies][1].defending = true # member 1 defends too, without driving its own menu
  scene.instance_variable_get(:@battle).send(:finish_round_animation)
  sprites = placement_sprites(scene)
  eq [idle_y, idle_y], [sprites[0].src_rect.y, sprites[1].src_rect.y],
     "both revert to Idle once the round ends and Game::Battle#end_round clears defending"
end

check 'a gauge battle: Defend swaps the sprite too, via the RPG2k3 scene\'s own #finish_round_animation' do
  # `RPG2k3::Scene::Battle#finish_round_animation` fully overrides the base
  # (calling `super` only when `!gauge_battle?`) and calls `Game::Battle
  # #end_round` itself -- needs the identical defenders-snapshot fix, not
  # just the base class.
  poses = { 0 => battle_pose(battler_name: 'Party', battler_index: 0),
           7 => battle_pose(battler_name: 'Party', battler_index: 3) }
  scene = placement_battle([1], battle_type: 2, poses: poses)
  ui = battle_ui(scene)
  idle_y = 0 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL
  defend_y = 3 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL

  eq idle_y, placement_sprites(scene)[0].src_rect.y

  2.times { press_key(scene, RGSS::Input::DOWN) } # Attack -> Skill -> Defend
  press_key(scene, RGSS::Input::C)
  eq defend_y, placement_sprites(scene)[0].src_rect.y, 'Defend swaps the pose in a gauge fight too'

  scene.instance_variable_get(:@battle).send(:finish_round_animation)
  eq idle_y, placement_sprites(scene)[0].src_rect.y,
     "the RPG2k3 scene's own override reverts it once the gauge turn ends"
end

check 'a party member killed mid-round switches to the Dead pose once the round ends' do
  # #finish_round_animation's own dead-select-after-#end_round addition
  # (mirrors its existing defenders snapshot, but read after rather than
  # before since `dead?` survives `#end_round` untouched) is what catches a
  # felled ally's sprite up -- `hp` is set directly here rather than driving
  # a full damage exchange, the same "simulate the moment, not the whole
  # pipeline" idiom the Defend checks above use for `defending`.
  poses = { 0 => battle_pose(battler_name: 'Party', battler_index: 0),
           4 => battle_pose(battler_name: 'Party', battler_index: 6) }
  scene = placement_battle([1, 2], placement: 0, battle_type: 0, poses: poses)
  idle_y = 0 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL
  dead_y = 6 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL

  sprites = placement_sprites(scene)
  eq [idle_y, idle_y], [sprites[0].src_rect.y, sprites[1].src_rect.y], 'both start on the Idle pose'

  ui = battle_ui(scene)
  ui[:allies][1].hp = 0 # felled mid-round
  scene.instance_variable_get(:@battle).send(:finish_round_animation)
  sprites = placement_sprites(scene)
  eq idle_y, sprites[0].src_rect.y, 'the survivor stays on the Idle pose'
  eq dead_y, sprites[1].src_rect.y, 'the felled member switches to the Dead pose'
end

check 'a gauge battle: a felled ally switches to the Dead pose too, via the RPG2k3 scene\'s own #finish_round_animation' do
  poses = { 0 => battle_pose(battler_name: 'Party', battler_index: 0),
           4 => battle_pose(battler_name: 'Party', battler_index: 6) }
  scene = placement_battle([1, 2], battle_type: 2, poses: poses)
  idle_y = 0 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL
  dead_y = 6 * RPG2k::Scene::Battle::ACTOR_CHARSET_CELL

  ui = battle_ui(scene)
  ui[:allies][0].hp = 0 # the other member stays alive, so the fight (and @ui) survives
  scene.instance_variable_get(:@battle).send(:finish_round_animation)
  sprites = placement_sprites(scene)
  eq dead_y, sprites[0].src_rect.y, "the RPG2k3 scene's own override catches the Dead pose up too"
  eq idle_y, sprites[1].src_rect.y, 'the survivor is untouched'
end

# yado.tk / 01_shoshin's 011_siyou: "Empty party doesn't itself Game Over, but
# battling with one is instant defeat; all-KO'd ... is instant Game Over the
# same way." #draw_battle_command's current_actor (living_allies[actor_i]) is
# nil for both an empty party and an all-KO'd one -- it already declines to
# open a command window rather than crash (`return unless actor`) -- but
# nothing then advanced the battle: a round only ever starts once the player
# picks a command for *someone*, so the command phase sat frozen forever
# (never reaching the `battle.finished?` check every other round settles
# through) instead of resolving as a defeat.
check 'entering a battle with an empty party is instant defeat, not a frozen command menu' do
  scene, st = battle_scene_with_pages({})
  st.party.instance_variable_set(:@actors, [])
  90.times do
    scene.update
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :result
  end
  ui = battle_ui(scene)
  ok ui, 'the battle is open'
  eq :result, ui[:phase], 'no living ally settles the fight immediately instead of stalling in :command'
  eq :defeat, ui[:result], 'an empty party reads the same as a wipeout'
end

check 'entering a battle with an all-KO\'d party is instant defeat too' do
  scene, st = battle_scene_with_pages({})
  st.party.instance_variable_set(:@actors, [BattleStubActor.new(hp: 0)])
  90.times do
    scene.update
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :result
  end
  ui = battle_ui(scene)
  ok ui, 'the battle is open'
  eq :result, ui[:phase], 'no living ally settles the fight immediately instead of stalling in :command'
  eq :defeat, ui[:result]
end

# The "unrecoverable input-blocking state lock" case flagged as still open next
# to the two fixes above: a living ally under a "do nothing" restriction
# (asleep/paralysed) or a forced attack-ally/attack-enemy restriction
# (confused/berserk) is not merely dead-or-alive -- #living_allies (rejects
# only #dead?) used to still open the ordinary Attack/Skill/Defend/Item prompt
# for one, waiting on a choice that #apply_turn_states/#strike (see
# Game::Battle#command_restricted?) discard or override regardless of what
# gets picked. EasyRPG's Scene_Battle_Rpg2k::SelectNextActor recurses straight
# past exactly these two cases (`!CanAct()` / `GetSignificantRestriction() !=
# Restriction_normal`) with no manual prompt shown at all.
check 'an asleep ally is skipped straight to the next commandable one, no command prompt for it' do
  scene, st = battle_scene_with_pages({})
  st.party.instance_variable_set(:@actors, [BattleStubActor.new(id: 1, states: [4]),
                                            BattleStubActor.new(id: 2)])
  ui = nil
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ok ui, 'the battle opened'
  eq :command, ui[:phase], 'a still-commandable ally is left to open the prompt'
  eq ui[:allies][1], scene.instance_variable_get(:@battle).send(:current_actor),
     'the asleep ally at index 0 was skipped straight to the awake one at index 1'
end

check 'a lone ally under a do-nothing state (asleep) never gets a command prompt -- the round starts on its own' do
  scene, st = battle_scene_with_pages({})
  st.party.instance_variable_set(:@actors, [BattleStubActor.new(id: 1, states: [4])])
  saw_animate = false
  ui = nil
  200.times do
    scene.update
    ui = battle_ui(scene)
    saw_animate ||= ui && ui[:phase] == :animate
    break if ui && ui[:phase] == :result
  end
  ok ui, 'the battle opened'
  ok saw_animate || ui[:phase] == :result,
     'the round left :command and started animating on its own -- no player input was ever supplied'
  ok ui[:phase] != :command, 'the sole ally being asleep does not freeze the command phase forever'
end

# 強制AI (mruby-lcf/mrblib/schema.rb, player/job field 23, force_ai) --
# parsed but never read anywhere in mruby-rpg2k before this fix. Mirrors the
# two restricted-actor checks directly above: EasyRPG's own
# `Scene_Battle_Rpg2k::SelectNextActor` checks `GetAutoBattle()` right after
# the CanAct()/forced-restriction gates and, if set, queues an action via the
# default AutoBattle algorithm instead of ever opening `State_SelectCommand`
# -- see `Game::Battle#choose_auto_battle_command`'s own header comment for
# the full port. `BattleStubActor#force_ai?` here has no skills at all
# (`skills: []`, the default), so every check below exercises the "no good
# skill found, fall back to an automatic plain Attack" branch specifically --
# `Game::Battle#choose_auto_battle_command`'s own logic-level checks already
# cover the skill-vs-attack ranking and revive-branch shapes in isolation.
check 'a lone Forced-AI ally never gets a command prompt -- the round starts on its own with an automatic Attack' do
  scene, st = battle_scene_with_pages({})
  st.party.instance_variable_set(:@actors, [BattleStubActor.new(id: 1, force_ai: true)])
  saw_animate = false
  ui = nil
  200.times do
    scene.update
    ui = battle_ui(scene)
    saw_animate ||= ui && ui[:phase] == :animate
    break if ui && ui[:phase] == :result
  end
  ok ui, 'the battle opened'
  ok saw_animate || ui[:phase] == :result,
     'the round left :command and started animating on its own -- no player input was ever supplied'
  ok ui[:phase] != :command, 'a lone Forced-AI ally does not freeze the command phase waiting on a prompt'
end

check 'a Forced-AI ally is skipped straight to the next manually-commandable one, with its own action already queued' do
  scene, st = battle_scene_with_pages({})
  st.party.instance_variable_set(:@actors, [BattleStubActor.new(id: 1, force_ai: true),
                                            BattleStubActor.new(id: 2)])
  ui = nil
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ok ui, 'the battle opened'
  eq :command, ui[:phase], 'the still-manually-commandable second ally is left to open the prompt'
  eq ui[:allies][1], scene.instance_variable_get(:@battle).send(:current_actor),
     'the Forced-AI ally at index 0 was skipped straight to the manual one at index 1'
  ok ui[:allies][0].action || ui[:allies][0].command,
     'the skipped Forced-AI ally already has its own action queued automatically'
end

check 'a turn-0 battle-event page runs as the fight opens' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CONTROL_SWITCHES, [0, 12, 12, 0])]) }
  scene, st = battle_scene_with_pages(pages)
  90.times do
    scene.update
    break if st.switches[12]
  end
  ok st.switches[12], 'the page ran before the command phase'
  scene.update # the exhausted page hands the turn back
  ui = battle_ui(scene)
  ok ui, 'the battle is still open'
  # Control returns to the party through the options window first -- its own
  # once-per-battle automatic appearance, the same one a bare encounter with
  # no turn-0 page shows immediately -- not straight to the ordinary
  # per-actor command menu.
  eq :battle_options, ui[:phase], 'and control returned to the party via the options window'
  RGSS::Input.triggered = [RGSS::Input::C] # Battle (default cursor row 0)
  scene.update
  RGSS::Input.triggered = []
  eq :command, ui[:phase], 'dismissing Battle reaches the ordinary per-actor command menu'
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

# EasyRPG's CheckBattleEndAndScheduleEvents runs "before each battler acts and
# also right after the last battler acts", not just once between rounds --
# Scene::Map#drive_battle_animate now checks between every acting battler
# (see @battle_ui[:battler_boundary]).
check 'a battle page conditioned on enemy HP fires mid-round, before the round settles' do
  ic = Game::Interpreter::Cmd
  # True only once the first troop member's HP falls to half or less -- which
  # only happens once the hero's own attack lands this round, never before.
  pages = { 1 => troop_page([ECmd.new(ic::CONTROL_SWITCHES, [0, 20, 20, 0])],
                            Game::BattlePage::ENEMY_HP, enemy_hp_max: 50) }
  scene, st = battle_scene_with_pages(pages)
  phase_when_fired = nil
  300.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && %i[command target battle_options].include?(ui[:phase])
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    if st.switches[20] && phase_when_fired.nil?
      phase_when_fired = ui && ui[:phase]
    end
    break if phase_when_fired
  end
  ok phase_when_fired, 'the page fired at all'
  ok phase_when_fired != :command,
     "fired mid-round (phase was #{phase_when_fired.inspect} when the switch " \
     'landed), not only once the round settled back to :command for the next one'
end

# yado.tk (`2k/01_shoshin/011_siyou/`, Enemy Appearance / Show Hidden Monster):
# a scripted reinforcement can be lost if all *currently-present* enemies die
# before its own appearance command fires -- the battle would just end. This
# is already avoided here as a side effect of the "checked far more often"
# fix above: #run_battle_events fires at the battler boundary right after the
# killing blow, strictly before drive_battle_animate's next step_action call
# (finding nothing pending) reaches #finish_round_animation's own
# `battle.finished?` check -- so a Show Hidden Monster queued by that page has
# already cleared the reinforcement's `hidden` flag (via
# #apply_battle_event_requests, driven every frame the page is running) well
# before the round could settle into a premature victory.
check 'a battle page reveals a reinforcement before the round can end in a premature victory (yado.tk)' do
  ic = Game::Interpreter::Cmd
  # Fires the instant troop member 0's HP hits 0, showing hidden troop member
  # 1 -- the "boss dies, a fresh enemy steps in" script the site describes.
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_HIDDEN_MONSTER, [1])],
                            Game::BattlePage::ENEMY_HP, enemy_id: 0, enemy_hp_max: 0) }
  scene, st = battle_scene_with_pages(pages)
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ui = battle_ui(scene)
  # Troop member 1 stands in for a placed-but-invisible reinforcement.
  ui[:foes][1].hidden = true
  ui[:troop].members[1].hidden = true
  # The killing blow that ends member 0's HP at exactly 0, matching a 0%..0%
  # Enemy HP page condition -- this build's battle HP is not floor-clamped
  # mid-fight, only written back through Battle#apply_to_party at battle end,
  # so an *overkill* hit landing well past 0 would never satisfy a 0% window;
  # exactly 0 sidesteps that separate, unverified question and isolates the
  # one this check is actually about.
  ui[:battle].enemy(0).hp = 0
  # Simulate the exact moment drive_battle_animate lands right after the
  # battler whose action just landed that blow: the battler-boundary flag it
  # sets (see @battle_ui[:battler_boundary]) is what gives every battle page
  # one more chance to fire before step_action next finds nothing pending and
  # the round settles via #finish_round_animation's own `battle.finished?`
  # check.
  ui[:phase] = :animate
  ui[:battler_boundary] = true
  revealed_before_victory = nil
  20.times do
    ui = battle_ui(scene)
    break unless ui
    scene.update
    ui = battle_ui(scene)
    break unless ui
    next if ui[:foes][1].hidden
    revealed_before_victory = ui[:phase] != :result
    break
  end
  ok !revealed_before_victory.nil?, 'the reinforcement was revealed within the budget'
  ok revealed_before_victory,
     'it was revealed before the round could settle into a premature victory, not after'
  # Enemy Appearance targeting an already-appeared enemy is a silent no-op:
  # #reveal_battle_monster returns immediately once `hidden` is already false,
  # so a second reveal neither rebuilds the sprite nor errors.
  sprite_before = ui[:enemy_sprites][1]
  scene.instance_variable_get(:@battle).send(:reveal_battle_monster, 1)
  eq sprite_before, battle_ui(scene)[:enemy_sprites][1],
     'revealing an already-visible member again is a no-op, not a sprite rebuild'
end

# Run `scene` until @battle_ui first appears (asserting it does within
# `open_budget` frames), then continue until it goes away again (asserting
# that too within `close_budget` more frames). A single "break the instant
# @battle_ui.nil?" loop is a trap here: @battle_ui reads exactly the same
# (nil) before the battle has opened as it does after it has cleanly closed,
# so a naive loop can "pass" by breaking on frame 0, before any battle-event
# page -- Terminate Battle included -- ever actually ran.
# A turn-0 battle page (Terminate Battle included) only runs once the
# encounter banner's own BATTLE_ENCOUNTER_MSG_FRAMES hold has run out, so
# close_budget needs enough room for that hold plus the page's own work.
def open_then_close_battle(scene, open_budget: 10, close_budget: 100)
  open_budget.times do
    scene.update
    break if battle_ui(scene)
  end
  ok battle_ui(scene), 'the battle opened'
  close_budget.times do
    scene.update
    break if battle_ui(scene).nil?
  end
  eq nil, battle_ui(scene), 'the battle closed again'
end

check 'Terminate Battle from a page ends the fight and resumes the event' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::TERMINATE_BATTLE, [])]) }
  scene, _st = battle_scene_with_pages(pages)
  open_then_close_battle(scene)
end

# yado.tk / 01_shoshin's 011_siyou: "Picture -- none show on Menu/Battle
# screens." The Menu half was already correct (Scene::Base#build_field_background
# paints an opaque panel above the picture layer); the battle screen had no
# equivalent -- the battle backdrop sits well below @picture_sprite's z, so a
# picture shown before the encounter (or by a still-running Parallel Process)
# used to draw straight over the battle UI.
check 'pictures are hidden while the battle screen is up (yado.tk: none show on Menu/Battle screens)' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::TERMINATE_BATTLE, [])]) }
  scene, _st = battle_scene_with_pages(pages)
  st = scene.instance_variable_get(:@state)
  st.show_picture(1, name: 'pic', x: 160, y: 120, zoom: 100, opacity: 255)
  sprite = scene.instance_variable_get(:@picture_sprite)
  bmp = scene.instance_variable_get(:@picture_bmp)

  10.times do
    scene.update
    break if battle_ui(scene)
    ok sprite.visible, 'the picture layer draws normally before any fight opens'
  end
  ok battle_ui(scene), 'the battle opened'
  ok !sprite.visible, 'the picture layer is hidden the instant the battle screen is up'
  bmp.clear_stretch_calls
  scene.update
  eq 0, bmp.stretch_calls.size, 'and stops compositing pictures entirely while the fight runs'

  100.times do
    scene.update
    break if battle_ui(scene).nil?
  end
  eq nil, battle_ui(scene), 'the battle closed again'
  ok sprite.visible, 'the picture layer reappears the instant the fight ends'
end

# RPG_RT's Scene_Battle replaces Scene_Map outright, so the map is not on
# screen during a fight at all -- the Backdrop/<name> image is the whole
# background. This port runs the fight inline on Scene::Map, and #render used
# to keep compositing the map every frame underneath it: the backdrop sprite's
# z 5 (EasyRPG's Priority_Background) is outranked by @map_viewport (z 100) and
# @upper_viewport (z 200), and the lower tile layer is opaque, so the correctly
# resolved backdrop was drawn entirely behind the map graphics.
check 'the map is hidden while the battle screen is up, so the backdrop actually shows' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::TERMINATE_BATTLE, [])]) }
  scene, _st = battle_scene_with_pages(pages)
  vp = scene.instance_variable_get(:@map_viewport)
  upper = scene.instance_variable_get(:@upper_viewport)
  lower_bmp = scene.instance_variable_get(:@lower_bmp)

  10.times do
    scene.update
    break if battle_ui(scene)
    # `!= false` rather than a plain truth test: RGSS::Viewport#visible
    # defaults to true on the real backend but nil on this stub, so a bare
    # `ok vp.visible` here would be asserting the stub's default, not the
    # behaviour. The fight's own hide/show below is checked exactly instead.
    ok vp.visible != false, 'the map view draws normally before any fight opens'
    ok upper.visible != false, 'and so does the above-character layer'
    # The tile layers reach the frame buffer as the cached grid's #copy_blt
    # (see Scene::Map#draw_layers), so that -- not #blt, which now only carries
    # the events drawn over it -- is what says compositing happened at all.
    ok !(lower_bmp.copy_blt_calls || []).empty?, 'and the tile layers do composite'
  end
  ui = battle_ui(scene)
  ok ui, 'the battle opened'
  ok ui[:back_sprite], 'the fight has a battle background sprite'
  ok ui[:back_sprite].z < vp.z, 'whose z sits below the map viewport ...'
  ok ui[:back_sprite].z < upper.z, '... and below the upper-layer viewport'
  eq false, vp.visible, 'so the map view is hidden the instant the battle screen is up'
  eq false, upper.visible, 'and so is the above-character layer'
  lower_bmp.clear_blt_calls
  lower_bmp.clear_copy_blt_calls
  scene.update
  eq 0, (lower_bmp.copy_blt_calls || []).size,
     'and the tile layers stop compositing entirely while the fight runs'
  eq 0, (lower_bmp.blt_calls || []).size,
     'and nothing draws over them either'

  100.times do
    scene.update
    break if battle_ui(scene).nil?
  end
  eq nil, battle_ui(scene), 'the battle closed again'
  eq true, vp.visible, 'the map view reappears the instant the fight ends'
  eq true, upper.visible, 'and so does the above-character layer'
  ok !(lower_bmp.copy_blt_calls || []).empty?, 'and the tile layers composite again'
end

# yado.tk: a Battle Interrupt (Terminate Battle, 13410) satisfies neither the
# enclosing Enemy Encounter's [Victory] nor [Escape]/[Defeat] handler branch --
# it resumes right after Branch End, an unlabeled third outcome -- and only
# the "a battle was entered" tally (Control Variables operand "Other" type 4,
# battle_count) counts it; win/escape/defeat counts, each scoped to their own
# matching outcome, do not.
check 'Terminate Battle matches neither Win/Escape/Defeat and only bumps the battle-entry count' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::TERMINATE_BATTLE, [])]) }
  scene, st = battle_scene_with_pages(pages)
  eq 0, st.battle_count, 'not yet entered'
  open_then_close_battle(scene)
  ok !st.switches[1], 'the [Victory] handler (switch 1) did not run'
  ok !st.switches[2], 'the [Escape] handler (switch 2) did not run either'
  eq 1, st.battle_count, 'the encounter was entered exactly once'
  eq 0, st.win_count
  eq 0, st.escape_count
  eq 0, st.defeat_count
end

check 'a battle-valid Timer reaching 0:00 force-ends the fight (yado.tk)' do
  scene, st = battle_scene_with_pages({})
  10.times do
    scene.update
    break if battle_ui(scene)
  end
  ok battle_ui(scene), 'the battle opened'
  # A timer already at 0:00-next-tick, marked to count during battle.
  t = st.timer(0)
  t.frames = 1
  t.running = true
  t.visible = true
  t.in_battle = true
  scene.update
  eq nil, battle_ui(scene),
     'the battle force-ends the instant the timer reaches 0:00, mid-command-phase'
  ok !st.switches[1] && !st.switches[2] && !st.switches[3],
     'no Win/Escape/Defeat handler matched -- an unlabeled third outcome, same as Terminate Battle'
end

check 'a page can wound a monster through Change Monster HP' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_MONSTER_HP, [0, 1, 0, 7, 1])]) }
  scene, _st = battle_scene_with_pages(pages)
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ui = battle_ui(scene)
  foe = ui[:battle].enemy(0)
  eq foe.max_hp - 7, foe.hp, 'the page took 7 HP off the first troop member'
end

check 'Change Battle Background from a page rebuilds the backdrop sprite' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_BATTLE_BG, [], string: 'Cave')]) }
  scene, _st = battle_scene_with_pages(pages)
  before = nil
  90.times do
    ui = battle_ui(scene)
    before ||= ui && ui[:back_sprite]
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ui = battle_ui(scene)
  ok ui[:back_sprite], 'a backdrop is still in place'
  ok !ui[:back_sprite].equal?(before), 'and it was rebuilt for the new name'
end

# Show Battle Animation (13260), the battle-page form of 11210 (see
# do_show_battle_animation_b in interpreter.rb): drive_battle_event_wait's
# dispatch used to have no :animation case at all, so a battle page's own
# Show Battle Animation -- wait flag on or off -- fell into the generic
# "release the request, resume unconditionally" else branch on the very
# next frame: never built, never drawn, never actually waited on, the exact
# same silently-ignored shape the already-fixed Common Event Parallel
# Process gap had for the map-level command (11210). Fixed by adding an
# :animation case that reuses #drive_map_animation, generalized (see
# #start_battle_page_animation and #step_map_animation's finish check) to
# also build a battle-round-styled animation -- keyed by troop *member
# index*, per this command's own param1, not a map target id -- for a
# request carrying the `battle:` flag do_show_battle_animation_b sets.
check "a battle page's Show Battle Animation actually holds the page, not resuming immediately" do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_BATTLE_ANIM_B, [8, 0, 1], indent: 0), # anim 8, member 0, wait
                             ECmd.new(ic::CONTROL_SWITCHES, [0, 21, 21, 0], indent: 0)]) }
  scene, st = battle_scene_with_pages(pages)
  # Drive until the page's interpreter is actually parked on the :animation
  # wait the command sets (rather than counting frames blindly, since the
  # battle itself takes a few frames to open first).
  it = nil
  150.times do
    scene.update
    ui = battle_ui(scene)
    it = ui && ui[:events]
    break if it && it.waiting? && it.wait_kind == :animation
  end
  ok it && it.wait_kind == :animation, 'the page reached the :animation wait'
  ok !st.switches[21], 'the trailing Control Switches has not run yet'
  # The pre-fix bug resumed unconditionally the very next frame regardless of
  # the wait it just set (drive_battle_event_wait's missing :animation case
  # fell into the generic else branch), landing the trailing Control
  # Switches within two frames of this point -- well short of animation 8's
  # own ~8-frame play (4 frames * ANIM_CELL_FRAMES 2).
  2.times { scene.update }
  ok !st.switches[21], 'still held two frames later: not resumed unconditionally on the next tick'
  40.times { scene.update }
  ok st.switches[21], 'the page ran on once the animation actually finished'
end

check "a battle page's Show Battle Animation draws over the targeted troop member's own sprite position" do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_BATTLE_ANIM_B, [8, 1, 1], indent: 0), # anim 8, member 1, wait
                             ECmd.new(ic::CONTROL_SWITCHES, [0, 22, 22, 0], indent: 0)]) }
  scene, st = battle_scene_with_pages(pages)
  spr_shown = false
  ma_seen = nil
  150.times do
    scene.update
    ui = battle_ui(scene)
    anim_spr = scene.instance_variable_get(:@animation_sprite)
    spr_shown ||= anim_spr && anim_spr.visible
    ma = scene.instance_variable_get(:@map_animation)
    ma_seen ||= ma
    break if st.switches[22]
  end
  ok spr_shown, 'the animation sprite actually drew'
  ok ma_seen, 'the request was recorded as a live animation, not silently dropped'
  ok ma_seen[:battle], 'positioned in screen space, like a battle-round animation'
  ui = battle_ui(scene)
  spr = ui[:enemy_sprites][1]
   eq [spr.x + spr.bitmap.width / 2, spr.y + spr.bitmap.height / 2],
      [ma_seen[:targets][0][:tx], ma_seen[:targets][0][:ty]], "centred on troop member 1's sprite, the command's own target param"
  ok st.switches[22], 'and the page still ran on once it finished'
end

check "a battle page's Show Battle Animation target-scope flash pulses the named troop member, not a bystander" do
  ic = Game::Interpreter::Cmd
  # Animation 9 carries a flash_scope-1 ("target") timing on frame 0 -- see
  # fake_db -- rather than 8's flash_scope-2 (screen) one. Targets troop
  # member 0; member 1 is the untargeted bystander.
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_BATTLE_ANIM_B, [9, 0, 1], indent: 0),
                             ECmd.new(ic::CONTROL_SWITCHES, [0, 23, 23, 0], indent: 0)]) }
  scene, st = battle_scene_with_pages(pages)
  ui = nil
  target_flashed = false
  bystander_flashed = false
  150.times do
    scene.update
    ui = battle_ui(scene)
    next unless ui && ui[:enemy_sprites]
    target_flashed ||= !!ui[:enemy_sprites][0].flash_color
    bystander_flashed ||= !!ui[:enemy_sprites][1].flash_color
    break if st.switches[23]
  end
  ok target_flashed, 'the targeted troop member (index 0) was flashed at some point during the play'
  ok !bystander_flashed, 'the untargeted troop member (index 1) was never flashed'
  ok !st.screen.flashing?, 'a flash_scope-1 timing never touches the screen flash'
  ok st.switches[23], 'and the page still ran on once the animation finished'
end

# RPG2003's Ally/Enemy target-type flag on Show Battle Animation
# (Interpreter#do_show_battle_animation_b's param3, matching EasyRPG's
# `Game_Interpreter_Battle::CommandShowBattleAnimation`) used to be dropped
# entirely: an "Ally #1" target still indexed straight into
# `@ui[:enemy_sprites]` -- the troop's own *second* monster in any troop
# with 2+ members, not any party member at all. Fixed by carrying the flag
# through to #start_battle_page_animation, which now falls back to the same
# ally-side screen-centre positioning (and no `target_index`, so no enemy
# sprite is ever flashed/shaken) every ally-targeted battle-round entry
# already uses.
check "a battle page's Show Battle Animation targets the party, not a troop member, when the RPG2003 ally flag is set" do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_BATTLE_ANIM_B, [9, 1, 1, 1], indent: 0), # anim 9, ally #1, wait, allies=1
                             ECmd.new(ic::CONTROL_SWITCHES, [0, 24, 24, 0], indent: 0)]) }
  scene, st = battle_scene_with_pages(pages, party: BattleStubParty.new(rpg2003: true))
  ma_seen = nil
  150.times do
    scene.update
    ui = battle_ui(scene)
    ma = scene.instance_variable_get(:@map_animation)
    ma_seen ||= ma
    if ui && ui[:enemy_sprites]
      ui[:enemy_sprites].each { |s| ok !s.flash_color, 'no enemy sprite was flashed -- the target is an ally' }
    end
    break if st.switches[24]
  end
   ok ma_seen, 'the request was recorded as a live animation, not silently dropped'
   eq [RPG2k::WIDTH / 2, RPG2k::HEIGHT / 2], [ma_seen[:targets][0][:tx], ma_seen[:targets][0][:ty]],
      'the ally-side screen-centre fallback, not any enemy sprite position'
   ok !ma_seen[:targets][0][:index], 'no enemy troop-member index -- an ally target has no on-screen sprite'
   ok st.switches[24], 'and the page still ran on once it finished'
end

check "a battle page's Show Battle Animation with target -1 plays over every living enemy (the whole-side case)" do
  ic = Game::Interpreter::Cmd
  # anim 9 carries a flash_scope-1 ("target") timing on frame 0 (see fake_db),
  # so each enemy sprite should be pulsed by the whole-side play.
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_BATTLE_ANIM_B, [9, -1, 1], indent: 0), # anim 9, whole side, wait
                           ECmd.new(ic::CONTROL_SWITCHES, [0, 25, 25, 0], indent: 0)]) }
  scene, st = battle_scene_with_pages(pages)
  ma_seen = nil
  flashed = {}
  150.times do
    scene.update
    ui = battle_ui(scene)
    ma = scene.instance_variable_get(:@map_animation)
    ma_seen ||= ma
    if ui && ui[:enemy_sprites]
      ui[:enemy_sprites].each_with_index { |s, i| flashed[i] = true if s && s.flash_color }
    end
    break if st.switches[25]
  end
  ok ma_seen, 'the request was recorded as a live animation, not silently dropped'
  ui = battle_ui(scene)
  living = ui[:enemy_sprites].reject(&:nil?)
  eq living.size, ma_seen[:targets].size, 'one target descriptor per living enemy sprite'
  ma_seen[:targets].each { |t| ok !t[:index].nil?, 'each whole-side target names a troop-member sprite index' }
  living.each_index { |i| ok flashed[i], "enemy #{i} was flashed by the flash_scope-1 timing" }
  ok !st.screen.flashing?, 'a flash_scope-1 timing never touches the screen flash'
  ok st.switches[25], 'and the page still ran on once it finished'
end

check "a battle page's Show Battle Animation with target -1 and the ally flag plays a single screen-centre animation" do
  ic = Game::Interpreter::Cmd
  # RPG2000's front-view battle draws no ally sprite, so an ally whole-side
  # animation collapses to the same single screen-centre fallback a single
  # ally target already uses -- no enemy sprite is ever flashed.
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_BATTLE_ANIM_B, [9, -1, 1, 1], indent: 0), # anim 9, whole side, wait, allies=1
                           ECmd.new(ic::CONTROL_SWITCHES, [0, 26, 26, 0], indent: 0)]) }
  scene, st = battle_scene_with_pages(pages, party: BattleStubParty.new(rpg2003: true))
  ma_seen = nil
  150.times do
    scene.update
    ma = scene.instance_variable_get(:@map_animation)
    ma_seen ||= ma
    ui = battle_ui(scene)
    if ui && ui[:enemy_sprites]
      ui[:enemy_sprites].each { |s| ok !s.flash_color, 'no enemy sprite flashed -- the ally whole-side targets none' }
    end
    break if st.switches[26]
  end
  ok ma_seen, 'the request was recorded as a live animation, not silently dropped'
  eq 1, ma_seen[:targets].size, 'a single target, not one per ally'
  eq [RPG2k::WIDTH / 2, RPG2k::HEIGHT / 2], [ma_seen[:targets][0][:tx], ma_seen[:targets][0][:ty]],
     'the ally-side screen-centre fallback, not any enemy sprite position'
  ok ma_seen[:targets][0][:index].nil?, 'no enemy troop-member index -- an ally target has no on-screen sprite'
  ok st.switches[26], 'and the page still ran on once it finished'
end

check 'a battle page shows its message in a battle panel and waits for a key' do
  ic = Game::Interpreter::Cmd
  pages = { 1 => troop_page([ECmd.new(ic::SHOW_MESSAGE, [], string: 'It appears!'),
                             ECmd.new(ic::CONTROL_SWITCHES, [0, 15, 15, 0])]) }
  scene, st = battle_scene_with_pages(pages)
  90.times do
    scene.update
    ui = battle_ui(scene)
    break if ui && ui[:event_win]
  end
  ui = battle_ui(scene)
  ok ui[:event_win], 'the message panel is up'
  ok !st.switches[15], 'the page is held at the message'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = []
  3.times { scene.update }
  ok st.switches[15], 'the button dismissed it and the page ran on'
  eq nil, battle_ui(scene)[:event_win],
     'the panel closed with the message'
end

check 'a hidden troop member is not targetable until it is revealed' do
  scene, _st = battle_scene_with_pages(nil)
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ui = battle_ui(scene)
  eq 2, ui[:foes].length
  # Hide the second member the way an invisible troop entry would have.
  ui[:foes][1].hidden = true
  ui[:troop].members[1].hidden = true
  targets = scene.instance_variable_get(:@battle).send(:living_foes)
  eq 1, targets.length, 'the target cursor skips the hidden member'
  ok !targets.include?(ui[:foes][1])

  scene.instance_variable_get(:@battle).send(:reveal_battle_monster, 1)
  ok !ui[:foes][1].hidden, 'revealing clears the combatant flag, not just the sprite'
  eq 2, scene.instance_variable_get(:@battle).send(:living_foes).length, 'and it becomes targetable'
  ok ui[:enemy_sprites][1], 'with a sprite built for it'
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

check 'Open Shop scene: buying shows the shop_purchased confirmation, then returns ' \
      'to the buy list' do
  ic = Game::Interpreter::Cmd
  db = fake_db
  db.term.shop_purchased1 = '毎度あり！'
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::OPEN_SHOP, [1, 0, 0, 0, 3], indent: 0)] # buy-only
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  state.instance_variable_set(:@party, ShopStubParty.new(500))
  3.times { scene.update } # the shop opens straight to the buy list (buy-only)

  RGSS::Input.triggered = [RGSS::Input::C] # select the first good -> the counter
  scene.update
  RGSS::Input.triggered = []
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C] # confirm the default quantity of 1
  scene.update
  RGSS::Input.triggered = []
  scene.update

  shop = scene.instance_variable_get(:@shop)
  eq :purchased, shop[:screen], 'the purchase confirms before the list reappears'
  ok window_texts(shop[:window]).any? { |t| t.include?('毎度あり！') },
     'the confirmation line uses the database shop_purchased term'

  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the confirmation
  scene.update
  RGSS::Input.triggered = []
  scene.update
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen], 'a button press returns to the buy list, same as EasyRPG\'s ' \
                          'Bought -> Buy transition'
end

check 'Open Shop scene: selling shows the shop_sold confirmation, then returns ' \
      'to the sell list' do
  ic = Game::Interpreter::Cmd
  db = fake_db
  db.term.shop_sold1 = '毎度！'
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::OPEN_SHOP, [2, 0, 0, 0, 3], indent: 0)] # sell-only
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  party = ShopStubParty.new(0)
  party.gain_item(3, 5)
  state.instance_variable_set(:@party, party)
  3.times { scene.update } # the shop opens straight to the sell list (sell-only)

  RGSS::Input.triggered = [RGSS::Input::C] # select the held good -> the counter
  scene.update
  RGSS::Input.triggered = []
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C] # confirm the default quantity of 1
  scene.update
  RGSS::Input.triggered = []
  scene.update

  shop = scene.instance_variable_get(:@shop)
  eq :sold, shop[:screen], 'the sale confirms before the list reappears'
  ok window_texts(shop[:window]).any? { |t| t.include?('毎度！') },
     'the confirmation line uses the database shop_sold term'

  RGSS::Input.triggered = [RGSS::Input::B] # dismiss the confirmation (B works too)
  scene.update
  RGSS::Input.triggered = []
  scene.update
  shop = scene.instance_variable_get(:@shop)
  eq :sell, shop[:screen], 'and returns to the sell list, same as EasyRPG\'s Sold -> Sell'
end

check 'Open Shop scene: the status panel shows the highlighted item\'s possessed ' \
      'and equipped counts, and disappears off the buy/sell list' do
  ic = Game::Interpreter::Cmd
  db = fake_db
  db.term.possessed_items = '所持数'
  db.term.equipped_items = '装備数'
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::OPEN_SHOP, [0, 0, 0, 0, 3, 5], indent: 0)] # buy+sell
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  party = ShopStubParty.new(500)
  party.gain_item(3, 2)                                # two Potions already in the bag
  party.actors = [ShopStubActor.new([3, 0, 0, 0, 0])]  # one of them equipped
  state.instance_variable_set(:@party, party)
  3.times { scene.update } # the command menu opens (mode 0: buy+sell)

  shop = scene.instance_variable_get(:@shop)
  eq :command, shop[:screen]
  ok shop[:status].nil?, 'the command menu highlights no single item -- no panel'

  RGSS::Input.triggered = [RGSS::Input::C] # choose Buy
  scene.update
  RGSS::Input.triggered = []
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen]
  texts = window_texts(shop[:status])
  ok texts.include?('所持数'), 'the possessed_items term labels the first row'
  ok texts.include?('装備数'), 'the equipped_items term labels the second row'
  ok texts.include?('2'), 'two Potions already held'
  ok texts.include?('1'), 'one Potion equipped across the party'

  RGSS::Input.triggered = [RGSS::Input::DOWN] # move to the second good (Herb, id 5)
  scene.update
  RGSS::Input.triggered = []
  texts = window_texts(scene.instance_variable_get(:@shop)[:status])
  ok texts.include?('0'), 'no Herbs held or equipped'
  ok !texts.include?('2') && !texts.include?('1'),
     'the stale Potion counts are gone once the cursor moves to a different good'

  RGSS::Input.triggered = [RGSS::Input::C] # open the quantity counter for the Herb
  scene.update
  RGSS::Input.triggered = []
  shop = scene.instance_variable_get(:@shop)
  eq :quantity, shop[:screen]
  ok shop[:status].nil?, 'the quantity counter highlights no single list row -- no panel'

  RGSS::Input.triggered = [RGSS::Input::B] # back to the buy list
  scene.update
  RGSS::Input.triggered = []
  shop = scene.instance_variable_get(:@shop)
  eq :buy, shop[:screen]
  ok !shop[:status].nil?, 'the panel returns once a good is highlighted again'
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
  texts = window_texts(battle_ui(scene)[:result_win])
  ok texts.any? { |t| t.include?('戦いに勝利した！') }, 'the database term is shown'
  ok !texts.any? { |t| t.include?('Victory!') }, 'not the composed English fallback'
end

check 'Enemy Encounter scene: the result window composes the database EXP/gold/item ' \
      'received terms around the granted numbers/names, not hardcoded English' do
  ic = Game::Interpreter::Cmd
  db = fake_db
  db.term.exp_received = 'の経験値を得た！'
  db.term.gold_received_a = '仲間は'
  db.term.gold = 'ゴールド'
  db.term.gold_received_b = 'を手に入れた！'
  db.term.item_received = 'を手に入れた！'
  # Both Slimes in fake_db's own two-member troop now carry a certain drop.
  db.enemy[2].drop_id = 3   # Potion, fake_db's own item table
  db.enemy[2].drop_prob = 100
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  state.instance_variable_set(:@party, BattleStubParty.new(item_db: db.item))
  scene.update
  battle_attack_to_end(scene)
  texts = window_texts(battle_ui(scene)[:result_win])
  ok texts.any? { |t| t.include?('10の経験値を得た！') },
     'the EXP term is composed as amount-then-term (GetExperienceGainedMessage)'
  ok texts.any? { |t| t.include?('仲間は 20ゴールドを手に入れた！') },
     'the two-part gold term sandwiches the amount and the gold unit (GetGoldReceivedMessage)'
  ok texts.count { |t| t.include?('Potionを手に入れた！') } == 2,
     'both dead Slimes roll their certain drop, each named by the database item term'
end

check 'Enemy Encounter scene: blank database EXP/gold/item received terms fall back to ' \
      'composed English' do
  ic = Game::Interpreter::Cmd
  db = fake_db # leaves exp_received/gold_received_a/_b/item_received blank
  db.enemy[2].drop_id = 3
  db.enemy[2].drop_prob = 100
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  state.instance_variable_set(:@party, BattleStubParty.new(item_db: db.item))
  scene.update
  battle_attack_to_end(scene)
  texts = window_texts(battle_ui(scene)[:result_win])
  ok texts.any? { |t| t.include?('10 EXP gained.') }, 'a blank exp_received term falls back'
  ok texts.any? { |t| t.include?('Found 20G.') }, 'blank gold_received_a/gold/gold_received_b fall back'
  ok texts.count { |t| t.include?('Potion obtained.') } == 2, 'a blank item_received term falls back'
end

check 'Enemy Encounter scene: the result window announces a level-up and the skill it ' \
      'teaches, the same way Change EXP/Change Level do' do
  ic = Game::Interpreter::Cmd
  db = fake_db
  db.term.level = 'レベル'
  db.term.level_up = 'に上がった！'
  db.skill[42] = OpenStruct.new(name: 'Meteor')
  db.term.skill_learned = 'を覚えた！'
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  # Troop 1 (two Slimes, 5 EXP each -- see the EXP/gold/item checks above)
  # awards exactly 10 EXP; the stub crosses its one level threshold right at
  # 10 and learns skill 42 at that level, mirroring
  # Game::Interpreter#queue_level_up_messages's own before/after skill diff.
  actor = BattleStubActor.new(level_up_at: 10, learn_table: [[42, 2]])
  state.instance_variable_set(:@party, BattleStubParty.new(actor, skill_db: db.skill))
  scene.update
  battle_attack_to_end(scene)
  texts = window_texts(battle_ui(scene)[:result_win])
  eq 2, actor.level, 'the EXP gain crossed the one threshold configured'
  ok texts.any? { |t| t.include?('Heroはレベル 2 に上がった！') },
     'the level-up line reads name + level term + number + level_up term ' \
     '(GetLevelUpMessage stock/CP932 branch)'
  ok texts.any? { |t| t.include?('Meteorを覚えた！') },
     'the newly-learned skill names itself (GetLearningMessage), right after the level-up line'
end

check 'Enemy Encounter scene: blank database level_up/skill_learned terms fall back to ' \
      'composed English' do
  ic = Game::Interpreter::Cmd
  db = fake_db # leaves level_up/skill_learned blank
  db.skill[42] = OpenStruct.new(name: 'Meteor')
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, { 1 => event(2, 2, auto) })
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  actor = BattleStubActor.new(level_up_at: 10, learn_table: [[42, 2]])
  state.instance_variable_set(:@party, BattleStubParty.new(actor, skill_db: db.skill))
  scene.update
  battle_attack_to_end(scene)
  texts = window_texts(battle_ui(scene)[:result_win])
  ok texts.any? { |t| t.include?('Hero is now level 2!') }, 'a blank level_up term falls back'
  ok texts.any? { |t| t.include?('Hero learned Meteor!') }, 'a blank skill_learned term falls back'
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
  texts = window_texts(battle_ui(scene)[:result_win])
  ok texts.any? { |t| t.include?('The party was defeated...') },
     'a blank database term still falls back to the composed English'
end

check 'Enemy Encounter scene: a successful Flee shows the database escape_success term ' \
      'and plays the dedicated Escape SE, not Decision' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic, escape_mode: 2)
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :battle_options)
  2.times { RGSS::Input.triggered = [RGSS::Input::DOWN]; scene.update } # Fight -> Auto Battle -> Escape
  RGSS::Input.triggered = []
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::C] # confirm Escape
  scene.update
  RGSS::Input.triggered = []
  eq :result, ui[:phase]
  texts = window_texts(ui[:result_win])
  ok texts.any? { |t| t.include?('Escaped!') },
     'fake_db leaves escape_success blank, so this is the composed English fallback'
  # Decision plays first (choosing Escape from the options window is a
  # confirm action), then the dedicated Escape SE right before the battle
  # actually ends -- see #try_battle_escape's comment.
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'Decision1' }, 'choosing Escape plays Decision'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'Escape1' },
     'a successful escape also plays the dedicated Escape SE'
end

check 'Enemy Encounter scene: Escape forbidden (the default escape_mode 0) plays ' \
      'Buzzer on Escape, and the options window stays open' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic) # default escape_mode: 0 -> allow_escape false
  scene = new_scene({ 1 => event(2, 2, auto) })
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  ui = battle_until_phase(scene, :battle_options)
  2.times { RGSS::Input.triggered = [RGSS::Input::DOWN]; scene.update } # Fight -> Auto Battle -> Escape
  RGSS::Input.triggered = []
  eq 2, ui[:opt], 'the cursor landed on Escape'
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::C] # attempt Escape
  scene.update
  RGSS::Input.triggered = []
  eq :battle_options, ui[:phase], 'the battle is not left -- escape stays refused, the window stays open'
  eq 'Buzzer1', RGSS::Audio.se_calls.last[0],
     'a disallowed escape attempt plays Buzzer, matching a disallowed Save/Continue elsewhere'
end

# Open a battle and run it up to the command phase, answering [scene, ui].
# Dismisses the once-per-battle automatic options window (a C press on its
# default cursor row 0, "Battle") along the way -- see #battle_to_command.
def battle_at_command(pages = nil, party: BattleStubParty.new, battleranimations: nil)
  scene, = battle_scene_with_pages(pages, party: party, battleranimations: battleranimations)
  ui = nil
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
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
  ok scene.instance_variable_get(:@battle).send(:start_battle_animation, entry), 'an animation started'
  ma = scene.instance_variable_get(:@map_animation)
  ok ma, 'the player was armed'
  ok ma[:battle], 'and flagged as a battle animation'
  spr = ui[:enemy_sprites][0]
   eq [spr.x + spr.bitmap.width / 2, spr.y + spr.bitmap.height / 2],
      [ma[:targets][0][:tx], ma[:targets][0][:ty]], 'centred on the enemy sprite'
end

# flash_scope 1 ("target") -- previously dropped outright, since
# #fire_animation_flashes only ever handled flash_scope 2 (the whole screen).
# yado.tk / the LCF schema's own flash_scope enum (0 none / 1 target / 2
# screen) both name this as a distinct case from the screen flash already
# covered by the check above; a hand-built timing entry (rather than a
# fixture animation) isolates it from the screen-flash timing that check
# already exercises on the shared fixture animation.
check 'a target-scope animation flash pulses the hit enemy, not the screen or a bystander' do
  scene, ui = battle_at_command
  spr = ui[:enemy_sprites][0]
  bystander = ui[:enemy_sprites][1]
  timing = OpenStruct.new(frame: 0, flash_scope: 1, flash_red: 31, flash_green: 0,
                          flash_blue: 0, flash_power: 20)
  ma = { frame_i: 0, battle: true, target_index: 0,
         targets: [{ index: 0, flash_target: nil, tx: 0, ty: 0, height: nil }],
         timings: [timing] }
  scene.send(:fire_animation_flashes, ma)
  ok spr.flash_color, 'the targeted enemy sprite was flashed'
  eq [248, 0, 0, 160],
     [spr.flash_color.red, spr.flash_color.green, spr.flash_color.blue, spr.flash_color.alpha],
     'scaled from the LCF 0..31 fixture fields the same *8 way the screen flash already is'
  anim_flash_frames = RPG2k::Scene::Map::ANIM_FLASH_FRAMES
  eq anim_flash_frames, spr.flash_calls.last[1],
     'held for the same duration a screen flash from an animation gets'
  st = scene.instance_variable_get(:@state)
  ok !st.screen.flashing?, 'flash_scope 1 never touches the screen flash, unlike flash_scope 2'
  eq nil, bystander.flash_color, 'the other, untargeted enemy sprite is untouched'
  # Driven every frame the way #drive_battle already does (#update_enemy_flashes),
  # the flash fades out and clears after its own duration -- not left stuck on.
  anim_flash_frames.times { scene.instance_variable_get(:@battle).send(:update_enemy_flashes) }
  eq nil, spr.flash_color, 'the flash faded out after its duration'
end

# screen_shaking 2 ("screen") on a battle-round animation. Verified against
# EasyRPG Player's actual C++ source, `BattleAnimation::ProcessAnimationTiming`
# (src/battle_animation.cpp, fetched verbatim): `screen->ShakeOnce(3, 5, 32)`
# -- the exact same Game::Screen#shake call and (power, speed, frames)
# argument order the Shake Screen event command (11050) already drives (see
# the 'Shake Screen with a wait...' check above), so this reuses it rather
# than inventing a second shake mechanism.
check 'a screen-scope animation shake triggers the same Game::Screen#shake state as Shake Screen' do
  scene, = battle_at_command
  st = scene.instance_variable_get(:@state)
  ok !st.screen.shaking?, 'not shaking to start with'
  timing = OpenStruct.new(frame: 0, screen_shaking: 2)
  ma = { frame_i: 0, battle: true, target_index: 0,
         targets: [{ index: 0, flash_target: nil, tx: 0, ty: 0, height: nil }],
         timings: [timing] }
  scene.send(:fire_animation_flashes, ma)
  ok st.screen.shaking?, 'the screen shake started'
  RPG2k::Scene::Map::ANIM_SHAKE_FRAMES.times { st.screen.update }
  ok !st.screen.shaking?, "settled after EasyRPG's own fixed 32-frame duration"
end

# The default (0, "none") screen_shaking must stay a regression-safe no-op --
# #fire_animation_flashes already runs unconditionally on every timing, so a
# frame with no screen_shaking data at all (the schema default) must never
# start a shake nobody asked for.
check 'a screen_shaking-0 (default) timing triggers no shake' do
  scene, = battle_at_command
  st = scene.instance_variable_get(:@state)
  timing = OpenStruct.new(frame: 0, flash_scope: 0, screen_shaking: 0)
  ma = { frame_i: 0, battle: true, target_index: 0,
         targets: [{ index: 0, flash_target: nil, tx: 0, ty: 0, height: nil }],
         timings: [timing] }
  scene.send(:fire_animation_flashes, ma)
  ok !st.screen.shaking?, 'screen_shaking 0 (the schema default) never touches the screen shake'
end

# screen_shaking 1 ("target"): EasyRPG's own `BattleAnimationBattle::
# ShakeTargets`/`BattleAnimationBattler::ShakeTargets` (src/battle_animation.cpp,
# fetched verbatim) shake every one of the animation's own battler targets
# with the same (3, 5, 32) triple as the screen case, via `battler->
# ShakeOnce(...)` -- #fire_target_shake/#update_enemy_shakes port that to this
# codebase's own per-sprite x, since there is no native per-sprite shake
# primitive the way Sprite#flash exists for the colour pulse.
check 'a target-scope animation shake jitters the hit enemy sprite, not a bystander, and settles back' do
  scene, ui = battle_at_command
  spr = ui[:enemy_sprites][0]
  bystander = ui[:enemy_sprites][1]
  base_x = spr.x
  bystander_x = bystander.x
  timing = OpenStruct.new(frame: 0, screen_shaking: 1)
  ma = { frame_i: 0, battle: true, target_index: 0,
         targets: [{ index: 0, flash_target: nil, tx: 0, ty: 0, height: nil }],
         timings: [timing] }
  scene.send(:fire_animation_flashes, ma)
  moved = false
  RPG2k::Scene::Map::ANIM_SHAKE_FRAMES.times do
    scene.instance_variable_get(:@battle).send(:update_enemy_shakes)
    moved ||= spr.x != base_x
  end
  ok moved, "the targeted enemy sprite's x moved off its base position at some point during the shake"
  eq base_x, spr.x, 'settled back to its base x once the shake duration elapsed'
  eq bystander_x, bystander.x, 'the untargeted bystander sprite was never touched'
  st = scene.instance_variable_get(:@state)
  ok !st.screen.shaking?, 'screen_shaking 1 never touches the whole-screen shake, unlike screen_shaking 2'
end

# An ally-targeted entry (RPG2000's battle is front-view: no sprite for a
# party member, so target_index is nil there -- see #battle_animation_pixel)
# has nothing to shake; #fire_target_shake must not raise reaching for a
# nonexistent sprite, the same shape #fire_target_flash's own no-target check
# above already covers.
check 'a target-scope shake with no resolvable target sprite is a silent no-op' do
  scene, = battle_at_command
  timing = OpenStruct.new(frame: 0, screen_shaking: 1)
  ma = { frame_i: 0, battle: true, target_index: nil,
         targets: [{ index: nil, flash_target: nil, tx: 0, ty: 0, height: nil }],
         timings: [timing] }
  scene.send(:fire_animation_flashes, ma) # must not raise
  ok true, 'no exception targeting nothing'
end

# ANIM_FLASH_FRAMES itself, pinned against EasyRPG's actual C++ source rather
# than against its own value (the checks above derive their expectations from
# the constant, so a wrong constant would still "pass" them). EasyRPG's
# `BattleAnimation::UpdateFlashGeneric` (src/battle_animation.cpp) computes
# `delta_frames = GetFrame() - start_frame` and keeps a fired timing's own
# colour/power alive for `delta_frames <= 10` -- 11 raw ticks (0 through 10
# inclusive) from the tick it fires, not some other guess -- before
# `UpdateScreenFlash` falls back to an unconditional all-zero. Hand-drives
# #hold_animation_screen_flash (the per-real-frame reassertion loop
# `#step_map_animation` calls, once per real tick, right alongside
# #fire_animation_flashes on the very same tick the timing fires and every
# tick after) to land on delta_frames 10 and 11 without needing a full fixture
# animation or 60 real `scene.update` calls.
check 'a fired animation screen flash stays alive for exactly 11 real frames, matching ' \
      "EasyRPG's UpdateFlashGeneric delta_frames <= 10" do
  scene = new_scene({})
  st = scene.instance_variable_get(:@state)
  timing = OpenStruct.new(frame: 0, flash_scope: 2, flash_red: 31, flash_green: 0,
                          flash_blue: 0, flash_power: 20)
  ma = { frame_i: 0, timings: [timing] }
  scene.send(:fire_animation_flashes, ma) # delta_frames 0: fires, sets the hold counter
  # #step_map_animation calls #hold_animation_screen_flash on this exact same
  # tick too (right after #fire_animation_flashes), so 11 calls here cover
  # delta_frames 0 through 10 -- the tick that fired plus 10 more.
  11.times { scene.send(:hold_animation_screen_flash, ma) }
  ok st.screen.flashing?, 'still alive through delta_frames 10 (still <= 10)'
  scene.send(:hold_animation_screen_flash, ma) # delta_frames 11
  ok !st.screen.flashing?, 'cleared at delta_frames 11, matching the C++ falling back to all-zero'
end

# An ally-targeted entry (RPG2000's battle is front-view: no sprite for a
# party member, so target_index is nil there -- see #battle_animation_pixel)
# has nothing to flash; #fire_target_flash must not raise reaching for a
# nonexistent sprite.
check 'a target-scope flash with no resolvable target sprite is a silent no-op' do
  scene, = battle_at_command
  timing = OpenStruct.new(frame: 0, flash_scope: 1, flash_red: 31, flash_green: 0,
                          flash_blue: 0, flash_power: 20)
  ma = { frame_i: 0, battle: true, target_index: nil,
         targets: [{ index: nil, flash_target: nil, tx: 0, ty: 0, height: nil }],
         timings: [timing] }
  scene.send(:fire_animation_flashes, ma) # must not raise
  ok true, 'no exception targeting nothing'
end

# The battle-round half of the Character Flash cap (see the map-triggered
# check above and #hold_animation_target_flash's own comment): an unrelated
# flash already in flight on an animation's own target enemy -- simulating an
# earlier hit's own target-scope timing still decaying when a second, later
# animation with no flash_scope-1 timing of its own starts playing over the
# same enemy -- gets forcibly cleared the moment #hold_animation_target_flash
# runs with nothing of its own to hold, mirroring #hold_animation_screen_flash
# exactly but scoped to just this one sprite: the untargeted bystander is left
# alone.
check 'a Character Flash concurrent with a battle-round animation on the same enemy is capped, a bystander is not' do
  scene, ui = battle_at_command
  spr = ui[:enemy_sprites][0]
  bystander = ui[:enemy_sprites][1]
  spr.flash(Color.new(200, 0, 0, 200), 60)
  bystander.flash(Color.new(0, 200, 0, 200), 60)
  ok spr.flash_color && bystander.flash_color, 'both unrelated flashes are in flight to start with'
  ma = { frame_i: 0, battle: true, target_index: 0,
         targets: [{ index: 0, flash_target: nil, tx: 0, ty: 0, height: nil }],
         timings: [] } # no target_flash_hold armed
  scene.send(:hold_animation_target_flash, ma)
  eq nil, spr.flash_color, "the animation's own target sprite had its unrelated flash stomped to nothing"
  ok bystander.flash_color, 'the untargeted bystander sprite is untouched'
end

check 'a skill that names none plays nothing' do
  scene, = battle_at_command
  ok !scene.instance_variable_get(:@battle).send(:start_battle_animation,
                 { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Heal',
                   skill_id: 9, target_index: 0, target_ally: false })
  eq nil, scene.instance_variable_get(:@map_animation)
end

# -- dangling battle-animation id (database shrink) ---------------------------
# The "battle animation" case from docs/TODO.md's runtime error catalog:
# #animation_row is the single choke point every battle-animation lookup goes
# through (Show Battle Animation, and a skill/item's own animation via
# #build_animation), so this is exercised once at that choke point rather than
# once per caller.

check '#animation_row reports a dangling animation id, stays silent for a ' \
      'valid id, a nil id, id 0 or a db with no battle_anime table at all' do
  scene = new_scene({})
  # Id 7 is intentionally absent from the fake db (see its own fixture
  # comment) -- a stand-in for a database shrink leaving a Show Battle
  # Animation / skill / item naming a deleted battle_anime row.
  out = capture_stderr { eq nil, scene.send(:animation_row, 7) }
  ok out.include?('[RPG2k] battle animation #7 not found in database, ' \
                  'nothing drawn'), out

  out2 = capture_stderr do
    ok scene.send(:animation_row, 8), 'a real id still resolves its row'
    eq nil, scene.send(:animation_row, nil), 'a nil id is the ordinary no-animation case'
    eq nil, scene.send(:animation_row, 0), 'id 0 is the ordinary no-animation case'
  end
  ok out2.empty?, "a valid id, nil or 0 must stay silent, got: #{out2.inspect}"

  # A bare fixture with no battle_anime table at all (respond_to? false) must
  # not be mistaken for a dangling reference either.
  bare_db = OpenStruct.new
  scene.instance_variable_set(:@db, bare_db)
  out3 = capture_stderr { eq nil, scene.send(:animation_row, 7) }
  ok out3.empty?, "a db with no battle_anime table at all must stay silent, got: #{out3.inspect}"
end

check 'a skill naming a since-deleted battle animation plays nothing, but reports the gap' do
  scene, = battle_at_command
  scene.db.battle_anime.delete(8) # simulate the database shrink Fire's animation_id (8) now dangles from
  entry = { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
            skill_id: 8, target_index: 0, target_ally: false }
  out = capture_stderr do
    ok !scene.instance_variable_get(:@battle).send(:start_battle_animation, entry), 'nothing plays -- unchanged from before this diagnostic'
  end
  eq nil, scene.instance_variable_get(:@map_animation), 'draws nothing, same as always'
  ok out.include?('[RPG2k] battle animation #8 not found in database, nothing drawn'), out
end

# RPG2000's battle is first-person: no sprite is drawn for a party member, so an
# action aimed at one has nowhere to centre on.
check 'an action on a party member plays over the middle of the screen' do
  scene, = battle_at_command
  entry = { attacker: 'Slime', target: 'Hero', damage: 7, skill: 'Fire',
            skill_id: 8, target_index: nil, target_ally: true }
  ok scene.instance_variable_get(:@battle).send(:start_battle_animation, entry)
  ma = scene.instance_variable_get(:@map_animation)
   eq [RPG2k::Scene::Map::SCREEN_W / 2, RPG2k::Scene::Map::SCREEN_H / 2],
      [ma[:targets][0][:tx], ma[:targets][0][:ty]]
end

check 'the round waits for the animation instead of the banner timer' do
  scene, ui = battle_at_command
  ui[:phase] = :animate
  scene.instance_variable_get(:@battle).send(:start_battle_animation,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
               skill_id: 8, target_index: 0, target_ally: false })
  ok scene.instance_variable_get(:@battle).send(:battle_animation_playing?), 'the round is held'
  # It plays out frame by frame and clears itself; nothing else advances while
  # it does, and no interpreter is resumed (a battle animation has no event
  # waiting on it, unlike the map's Show Battle Animation).
  200.times do
    break if scene.instance_variable_get(:@map_animation).nil?
    scene.instance_variable_get(:@battle).send(:drive_battle_animate)
  end
  eq nil, scene.instance_variable_get(:@map_animation), 'it finished'
  ok !scene.instance_variable_get(:@battle).send(:battle_animation_playing?)
end

# Real RPG_RT (EasyRPG's BattleAnimation::Update, src/battle_animation.cpp)
# ticks an internal frame counter once per logical 60fps update and shows
# `GetFrame() / 2` as the current cell -- so every real (LCF) animation frame
# is held for exactly 2 ticks (1/30s), whether or not that frame's own cell
# list is empty ("Wait"), before the next one shows. See the ANIM_CELL_FRAMES
# comment in scene/map.rb for the fuller citation.
check 'each battle animation frame is held for exactly ANIM_CELL_FRAMES ticks (2, 1/30s)' do
  scene, = battle_at_command
  scene.instance_variable_get(:@battle).send(:start_battle_animation,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
               skill_id: 8, target_index: 0, target_ally: false })
  ma = scene.instance_variable_get(:@map_animation)
  ok ma, 'the fixture animation (id 8, 4 frames) armed'
  eq 2, RPG2k::Scene::Map::ANIM_CELL_FRAMES,
     'matches EasyRPG BattleAnimation::Update -- GetRealFrame() == GetFrame() / 2'
  eq 0, ma[:frame_i], 'starts on the first frame'
  2.times { scene.send(:step_map_animation) }
  eq 0, ma[:frame_i], 'still the first frame after 2 ticks'
  scene.send(:step_map_animation)
  eq 1, ma[:frame_i], 'advances to the second frame on tick 3'
end

check 'an item names its animation the same way a skill does' do
  scene, = battle_at_command
  eq nil, scene.instance_variable_get(:@battle).send(:battle_animation_id,
                     { item_id: 3, recover: true }),
     'the fixture Potion names none'
  eq 8, scene.instance_variable_get(:@battle).send(:battle_animation_id, { skill_id: 8 })
  eq nil, scene.instance_variable_get(:@battle).send(:battle_animation_id, { attacker: 'Hero' }),
     'a plain attack with no attack_animation_id resolved (a bare fixture Combatant, or an enemy) carries none'
  eq 5, scene.instance_variable_get(:@battle).send(:battle_animation_id, { attacker: 'Hero', attack_animation_id: 5 }),
     'a plain attack falls back to the id Game::Battle#deal_attack already resolved onto the entry'
end

# A plain Attack now plays its attacker's own weapon/unarmed animation too,
# not just a Skill/Item -- Game::Battle#deal_attack resolves
# Actor#attack_animation_id onto the log entry, and #battle_animation_id reads
# it once neither skill_id nor item_id claims the entry (see the check above).
check 'a plain attack with a resolved weapon animation plays it over the targeted enemy' do
  scene, ui = battle_at_command
  entry = { attacker: 'Hero', target: 'Slime', damage: 7,
            attack_animation_id: 8, target_index: 0, target_ally: false }
  ok scene.instance_variable_get(:@battle).send(:start_battle_animation, entry), 'an animation started, same as a skill would'
  ma = scene.instance_variable_get(:@map_animation)
  ok ma, 'the player was armed'
  spr = ui[:enemy_sprites][0]
   eq [spr.x + spr.bitmap.width / 2, spr.y + spr.bitmap.height / 2],
      [ma[:targets][0][:tx], ma[:targets][0][:ty]], 'centred on the targeted enemy sprite, same as a skill/item animation'
end

check 'a plain attack with nothing resolved plays no animation' do
  scene, = battle_at_command
  ok !scene.instance_variable_get(:@battle).send(:start_battle_animation,
                 { attacker: 'Hero', target: 'Slime', damage: 7, target_index: 0 }),
     'an unarmed attacker with no unarmed_animation configured, or an enemy, carries no id'
  eq nil, scene.instance_variable_get(:@map_animation)
end

check 'the battle animation draws in screen pixels, not map ones' do
  scene, = battle_at_command
  scene.instance_variable_get(:@battle).send(:start_battle_animation,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
               skill_id: 8, target_index: 0, target_ally: false })
  ma = scene.instance_variable_get(:@map_animation)
  bmp = scene.instance_variable_get(:@animation_bmp)
  bmp.clear_blt_calls
  # A camera far from the origin must not move a battle animation.
  scene.send(:draw_map_animation, 500, 400)
  ok !bmp.blt_calls.empty?, 'a cell was laid down'
  call = bmp.blt_calls.first
   eq [ma[:targets][0][:tx] - 48, ma[:targets][0][:ty] - 48], [call[0], call[1]],
      'placed from the target pixel itself, ignoring the camera'
end

# The battle_anime row's own `position` field (0 head / 1 center / 2 feet,
# LCF chunk 19 field 10 -- mruby-lcf/mrblib/schema.rb) was decoded into
# build_animation's `position:` and then never read anywhere, so an animation
# authored to play at a target's head or feet drew centred exactly like one
# left at the default. #animation_position_offset is the pure-logic half:
# symmetric around the plain centre pixel, split at the target's own known
# sprite height (nil, as every caller passed before this fix, always reads as
# "no offset", so an old caller/fixture that never learned a height keeps the
# exact old behaviour).
check 'animation_position_offset splits head/center/feet around the target sprite' do
  scene, = battle_at_command
  eq 0, scene.send(:animation_position_offset, { height: 32 }, 1),
     'center is the plain centre pixel, unmoved'
  eq(-16, scene.send(:animation_position_offset, { height: 32 }, 0),
     'head rises half the sprite height above centre')
  eq 16, scene.send(:animation_position_offset, { height: 32 }, 2),
     'feet sink half the sprite height below centre'
  eq 0, scene.send(:animation_position_offset, { height: nil }, 0),
     'no known height (the ally-side screen-centre fallback) is never offset'
  # The real map-target value every #start_map_animation caller actually
  # hands this (ANIM_MAP_TARGET_HEIGHT, 24 -- RPG_RT's own hardcoded
  # constant, not the 32px CharSet frame), split at its own halves.
  eq(-12, scene.send(:animation_position_offset,
                     { height: RPG2k::Scene::Map::ANIM_MAP_TARGET_HEIGHT }, 0))
  eq 12, scene.send(:animation_position_offset,
                    { height: RPG2k::Scene::Map::ANIM_MAP_TARGET_HEIGHT }, 2)
end

check 'a head/feet Show Battle Animation position offsets where it draws over the enemy sprite' do
  scene, = battle_at_command
  scene.instance_variable_get(:@battle).send(:start_battle_animation,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
               skill_id: 8, target_index: 0, target_ally: false })
  ma = scene.instance_variable_get(:@map_animation)
  bmp = scene.instance_variable_get(:@animation_bmp)
   ok ma[:targets][0][:height], 'start_battle_animation carried the enemy sprite\'s real height through'
   half_height = ma[:targets][0][:height] / 2

   ma[:position] = 0
   bmp.clear_blt_calls
   scene.send(:draw_map_animation, 500, 400)
   call = bmp.blt_calls.first
   eq [ma[:targets][0][:tx] - 48, ma[:targets][0][:ty] - 48 - half_height], [call[0], call[1]],
      'position 0 (head) draws half the sprite height above the plain centre'

   ma[:position] = 2
   bmp.clear_blt_calls
   scene.send(:draw_map_animation, 500, 400)
   call = bmp.blt_calls.first
   eq [ma[:targets][0][:tx] - 48, ma[:targets][0][:ty] - 48 + half_height], [call[0], call[1]],
      'position 2 (feet) draws half the sprite height below the plain centre'

   ma[:position] = 1
   bmp.clear_blt_calls
   scene.send(:draw_map_animation, 500, 400)
   call = bmp.blt_calls.first
   eq [ma[:targets][0][:tx] - 48, ma[:targets][0][:ty] - 48], [call[0], call[1]],
      'position 1 (center), the schema default, is unchanged from the plain centre pixel'
end

# An RPG2000 animation sheet is a grid of 96x96 cells whose whole background is
# the palette's transparent colour, so it has to be decoded colour-keyed
# (`Bitmap.new`'s second argument) the same way every other sprite sheet this
# runtime loads is. `Battle/` was the one sheet directory asking for an opaque
# decode, which made every cell blit a solid 96x96 rectangle of background over
# its target. EasyRPG's own material table (`src/cache.cpp`) sets
# `Spec::transparent` true for Battle, and false only for the four full-screen
# backdrops this runtime already loads opaque.
check 'the Battle/ animation sheet is loaded colour-keyed, like every other sprite sheet' do
  scene, = battle_at_command
  sheet = scene.send(:animation_sheet, 'Anim')
  ok sheet, 'the sheet loaded'
  eq 'Battle/Anim', sheet.load_name
  eq true, sheet.load_transparent,
     'palette index 0 must decode transparent, or every cell paints an opaque 96x96 block'
  # The four full-screen backdrops are the deliberate exceptions, and stay
  # opaque -- they have no transparent colour to key out.
  eq false, scene.instance_variable_get(:@battle).send(:battle_back_bitmap, 'Back').load_transparent,
     'Backdrop/ is a full-screen image and stays opaque'
end

# Each animation cell carries its own `transparency` (LCF battle_anime chunk
# 19's per-cell field 10 -- mruby-lcf/mrblib/schema.rb), decoded all along and
# never read, so every cell drew fully opaque no matter what its author asked
# for. #animation_cell_opacity is the pure-logic half, mirroring EasyRPG's own
# `BattleAnimation::DrawAt`: `SetOpacity(255 * (100 - cell.transparency) / 100)`.
check 'animation_cell_opacity converts a cell transparency percentage to a blit opacity' do
  scene, = battle_at_command
  op = ->(t) { scene.send(:animation_cell_opacity, OpenStruct.new(cell_id: 0, transparency: t)) }
  eq 255, op.call(0), '0% transparent is fully opaque, the schema default'
  eq 0, op.call(100), '100% transparent is fully invisible'
  eq 127, op.call(50), 'half transparent is half opacity (255 * 50 / 100, truncated)'
  eq 191, op.call(25)
  eq 63, op.call(75)
  eq 255, scene.send(:animation_cell_opacity, OpenStruct.new(cell_id: 0)),
     'a cell carrying no transparency field at all reads as the 0 default, not as nil'
  # A real Array1D only ever decodes an unsigned BER here, but a hand-authored
  # or corrupt row must not be able to ask for an out-of-range opacity.
  eq 255, op.call(-10), 'a negative transparency clamps to fully opaque'
  eq 0, op.call(150), 'a transparency past 100 clamps to fully invisible'
end

check 'a battle animation cell blits at its own transparency' do
  scene, = battle_at_command
  scene.instance_variable_get(:@battle).send(:start_battle_animation,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
               skill_id: 8, target_index: 0, target_ally: false })
  ma = scene.instance_variable_get(:@map_animation)
  bmp = scene.instance_variable_get(:@animation_bmp)
  cell = ma[:frames][0].cells[1]

  bmp.clear_blt_calls
  scene.send(:draw_map_animation, 500, 400)
  eq 255, bmp.blt_calls.first[4],
     'a cell with no transparency set goes down fully opaque, exactly as before this fix'

  cell.transparency = 60
  bmp.clear_blt_calls
  scene.send(:draw_map_animation, 500, 400)
  eq 1, bmp.blt_calls.size, 'still one cell'
  eq 102, bmp.blt_calls.first[4], '60% transparent blits at 255 * 40 / 100'
   eq [ma[:targets][0][:tx] - 48, ma[:targets][0][:ty] - 48], bmp.blt_calls.first[0, 2],
      'and lands in exactly the same place -- opacity is the only thing that changed'

  cell.transparency = 100
  bmp.clear_blt_calls
  scene.send(:draw_map_animation, 500, 400)
  ok bmp.blt_calls.empty?,
     'a fully transparent cell is skipped outright rather than blitted at opacity 0'
  # The fixture database is rebuilt per scene (#new_scene -> #fake_db), so the
  # mutated cell does not leak into the next check.
end

check 'the battle status window shows each ally condition, or the normal term' do
  scene, ui = battle_at_command
  texts = window_texts(ui[:status_win])
  eq 1, texts.count { |t| t == 'Normal' },
     'the one ally starts clear, showing the database normal term'

  ui[:allies][0].states = [4]                    # Sleep
  scene.instance_variable_get(:@battle).send(:refresh_battle_status)
  texts = window_texts(ui[:status_win])
  ok texts.include?('Sleep'), 'the afflicted ally shows its state'
  # RPG2000 is front-view: EasyRPG's Scene_Battle_Rpg2k builds exactly one
  # Window_BattleStatus, defaulted to `enemy: false` -- the troop is never
  # listed on this panel, only shown through its battler sprites.
  ok !texts.include?(ui[:foes][0].name), "the enemy troop has no row here"
end

check 'the condition shown is the significant state, in the state colour' do
  scene, ui = battle_at_command
  # Sleep (priority 80) outranks Silence (10) whichever order they landed in.
  ui[:allies][0].states = [4, 5]
  scene.instance_variable_get(:@battle).send(:refresh_battle_status)
  ok window_texts(ui[:status_win]).include?('Sleep'), 'the higher priority wins'
  ui[:allies][0].states = [5, 4]
  scene.instance_variable_get(:@battle).send(:refresh_battle_status)
  ok window_texts(ui[:status_win]).include?('Sleep'), 'regardless of order'

  # The state's own palette colour reaches the draw call. This project ships no
  # windowskin in the fake database, so the flat path runs and the colour is
  # carried as the font colour rather than a blend swatch -- what matters here
  # is that battle_state_segment resolved it from the row at all.
  eq 2, Game::States.color(3, scene.db.situation), 'Poison draws in colour 2'
  eq 4, Game::States.color(4, scene.db.situation), 'Sleep in colour 4'
end

check 'Change Monster Condition on a battle page updates the troop, off-panel' do
  ic = Game::Interpreter::Cmd
  # Inflict state 3 (Poison) on troop member 0 the moment the fight opens.
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_MONSTER_CONDITION, [0, 0, 3])]) }
  scene, ui = battle_at_command(pages)
  eq true, ui[:foes][0].state?(3), 'the page inflicted the state'
  # The status window is party-only (see above), so a troop condition change
  # has nowhere to show on it -- RPG_RT has no persistent enemy status panel
  # either, only the battle log's own wording when a state lands.
  ok !window_texts(ui[:status_win]).include?('Poison'),
     'the troop never reaches the party-only status window'
end

# -- the RPG2003 gauge card status panel (battle_type 2) -----------------------
#
# `Game::Party#gauge_battle_layout?`/`BattleStubParty#gauge_layout` is true
# specifically for battle_type 2, distinct from `#alternate_battle_layout?`
# (true for both 1 and 2) -- see #refresh_battle_status's own comment,
# scene/map.rb. These checks exercise the dispatch and the card's own
# drawing, ported from EasyRPG's real `Window_BattleStatus::Refresh`/
# `RefreshGauge`/`DrawGaugeSystem2`/`DrawNumberSystem2`.

check 'battle_type 0 (no gauge layout) still draws the plain text status row' do
  scene, ui = battle_at_command
  ok !scene.instance_variable_get(:@battle).send(:gauge_battle_layout?), 'the plain fixture answers false'
  texts = window_texts(ui[:status_win])
  ok texts.include?('Hero'), 'the text status row is unchanged'
  eq [], ui[:status_win].contents.blt_calls || [],
     'and nothing else touched its contents via #blt (no gauge card drawing)'
end

check 'battle_type 1 (alternative) keeps the unchanged text status row too, ' \
      'even when the database also carries a System2 graphic' do
  actor = BattleStubActor.new
  party = BattleStubParty.new(actor, alternate_layout: true, gauge_layout: false)
  scene, ui = battle_at_command(nil, party: party)
  scene.db.system.system2_name = 'BattleStatus'
  scene.instance_variable_get(:@battle).send(:refresh_battle_status)
  ok !scene.instance_variable_get(:@battle).send(:gauge_battle_layout?),
     'battle_type 1 answers false to #gauge_battle_layout? -- only 2 does'
  texts = window_texts(ui[:status_win])
  ok texts.include?('Hero'), 'the text status row is still what battle_type 1 draws'
end

check 'battle_type 2 (gauge) with no System2 graphic falls back to the text ' \
      'status row instead of crashing' do
  actor = BattleStubActor.new
  party = BattleStubParty.new(actor, gauge_layout: true)
  scene, ui = battle_at_command(nil, party: party)
  ok scene.instance_variable_get(:@battle).send(:gauge_battle_layout?), 'the fixture asks for the gauge layout'
  ok !scene.db.system.respond_to?(:system2_name), 'and the database names no System2 graphic'
  scene.instance_variable_get(:@battle).send(:refresh_battle_status)
  texts = window_texts(ui[:status_win])
  ok texts.include?('Hero'), 'falls back to the plain text row rather than an empty/crashed panel'
end

check 'battle_type 2 (gauge) draws the gauge card: face, HP/SP bars, digit numbers' do
  actor = BattleStubActor.new(hp: 200, mp: 20, faceset_name: 'HeroFace', faceset_index: 2)
  party = BattleStubParty.new(actor, gauge_layout: true)
  scene, ui = battle_at_command(nil, party: party)
  scene.db.system.system2_name = 'BattleStatus'
  # A non-full HP (so this same window also exercises the normal, not
  # "full", fill tile) alongside SP's still-full 20/20.
  ui[:allies][0].hp = 100
  scene.instance_variable_get(:@battle).send(:refresh_battle_status)
  win = ui[:status_win]

  ok window_texts(win).empty?,
     'the gauge card never calls draw_text/blend_text -- it fully replaces the text row'
  eq 0, win.cursor_rect.width,
     'never gets a cursor rect, even on the acting actor -- matching UpdateCursorRect' \
     "'s unconditional empty rect for this battle_type"

  c = win.contents
  face_call = c.blt_calls[0]
  eq [0, 24], face_call[0, 2], 'the face lands at column 0, actor_face_height (24)'
  eq 'FaceSet/HeroFace', face_call[2].load_name, 'loaded from the actor faceset_name'
  eq [96, 0, 48, 48], [face_call[3].x, face_call[3].y, face_call[3].width, face_call[3].height],
     'cropped at faceset_index 2 -- (2 % 4) * 48, (2 / 4) * 48'

  left_cap, right_cap = c.blt_calls[1, 2]
  eq [32, 24], left_cap[0, 2], 'left bar cap at x = 32 + 80*i'
  eq [0, 32, 16, 48], [left_cap[3].x, left_cap[3].y, left_cap[3].width, left_cap[3].height]
  eq [73, 24], right_cap[0, 2], 'right bar cap at 32 + 16 (cap) + 25 (centre) = 73'
  eq [32, 32, 16, 48], [right_cap[3].x, right_cap[3].y, right_cap[3].width, right_cap[3].height]

  eq 3, c.stretch_calls.size, 'one bar-centre stretch, plus one fill each for HP and SP'
  center, hp_fill, sp_fill = c.stretch_calls
  eq [48, 24, 25, 48], [center[0].x, center[0].y, center[0].width, center[0].height],
     'the bar centre stretches to fill the full 25px slot between the caps'
  eq [48, 24, 12, 16], [hp_fill[0].x, hp_fill[0].y, hp_fill[0].width, hp_fill[0].height],
     'HP fill: 25 * 100 / 200 = 12px wide -- the normal tile, since 100 != max 200'
  eq [48, 32, 16, 16], [hp_fill[2].x, hp_fill[2].y, hp_fill[2].width, hp_fill[2].height],
     'reading the normal (gauge_x 0) HP fill tile'
  eq [48, 40, 25, 16], [sp_fill[0].x, sp_fill[0].y, sp_fill[0].width, sp_fill[0].height],
     'SP fill: exactly full (20/20) still stretches to the maximum 25px'
  eq [64, 48, 16, 16], [sp_fill[2].x, sp_fill[2].y, sp_fill[2].width, sp_fill[2].height],
     'an exactly-full gauge reads the distinct "full" tile (gauge_x 16), on the SP row (y+16)'

  # Numbers: HP "100" draws all three digit cells (hundreds carries a real,
  # nonzero digit), SP "20" draws only its own two.
  hp_digits = c.blt_calls[3, 3].map { |call| [call[0], call[3].x / 8] }
  eq [[48, 1], [56, 0], [64, 0]], hp_digits, 'HP 100 -> hundreds=1, tens=0, ones=0'
  sp_digits = c.blt_calls[6, 2].map { |call| [call[0], call[3].x / 8] }
  eq [[56, 2], [64, 0]], sp_digits, 'SP 20 -> tens=2, ones=0, no hundreds/thousands cell'
end

check 'DrawGaugeSystem2 stretches the fill by 25 * cur / max, and reads the ' \
      'distinct "full" tile only when cur == max' do
  # A pure function of its own arguments (no @ui / fight state touched), so a
  # bare, never-#start'ed Scene::Battle is enough to call it on.
  battle = RPG2k::Scene::Battle.allocate
  system2 = RGSS::Bitmap.new(80, 96)
  c = RGSS::Bitmap.new(64, 16)
  draw = lambda do |cur, max, which|
    c.clear_stretch_calls
    battle.send(:draw_gauge_system2, c, system2, 100, 200, cur, max, which)
    c.stretch_calls.last
  end

  call = draw.call(100, 200, 0)
  eq [100, 200, 12, 16], [call[0].x, call[0].y, call[0].width, call[0].height],
     'width is 25 * cur / max, truncated -- 25 * 100 / 200 = 12.5 -> 12'
  eq [48, 32, 16, 16], [call[2].x, call[2].y, call[2].width, call[2].height],
     'the normal (gauge_x 0) fill tile, which=0 -> HP row'

  call = draw.call(200, 200, 0)
  eq 25, call[0].width, 'an exactly-full gauge still stretches to the maximum 25px width'
  eq [64, 32], [call[2].x, call[2].y], 'but reads the "full" tile, 16px over (gauge_x 16)'

  call = draw.call(0, 200, 0)
  eq 0, call[0].width, 'zero current value stretches to 0 width'

  call = draw.call(20, 20, 1)
  eq [64, 48], [call[2].x, call[2].y],
     'which=1 (SP) reads its own row, 16px down -- still the "full" tile at cur == max'

  c.clear_stretch_calls
  battle.send(:draw_gauge_system2, c, system2, 100, 200, 5, 0, 0)
  eq nil, c.stretch_calls.last, 'max == 0 draws nothing at all, matching the real max_value guard'
end

check 'DrawNumberSystem2 leading-zero cascade matches EasyRPG exactly (7, 42, 100, 999)' do
  battle = RPG2k::Scene::Battle.allocate
  system2 = RGSS::Bitmap.new(80, 96)
  c = RGSS::Bitmap.new(64, 16)
  glyphs = lambda do |value|
    c.clear_blt_calls
    battle.send(:draw_number_system2, c, system2, 0, 0, value)
    c.blt_calls.map { |call| [call[0], call[3].x / 8] }
  end

  eq [[24, 7]], glyphs.call(7),
     '7 draws only the ones cell -- the hundreds/tens cells stay blank, never a drawn "0"'
  eq [[16, 4], [24, 2]], glyphs.call(42), '42 draws tens+ones only, no hundreds/thousands cell'
  eq [[8, 1], [16, 0], [24, 0]], glyphs.call(100),
     'a hundreds digit that carries down still draws its own zero tens/ones cells'
  eq [[8, 9], [16, 9], [24, 9]], glyphs.call(999), 'three 9s, still no (blank) thousands cell'
end

# -- the active-time (gauge) turn cycle (ADR 0053 Phase 2, scene integration) --
#
# A gauge-presentation battle (battle_type 2, routed to RPG2k3::Scene::Battle
# by `battle_scene_class`) replaces "whose turn is it" with "whose gauge is
# full": every combatant's gauge fills each frame, a full gauge opens the
# command menu for a controllable party member or fires the action of anyone
# else (enemy AI included) automatically, and acting resets it. These checks
# drive a real gauge battle through the 2003 scene and poke the gauges
# directly to control whose turn is up.

# A real gauge battle for the turn-cycle checks: the fixture database is
# RPG2003 with a Battle Commands table asking for the gauge presentation, so
# the fight opens in RPG2k3::Scene::Battle (not the 2000 scene) and its model
# is seeded battle_type 2.
def gauge_battle_scene(party = BattleStubParty.new, pages = {})
  scene, = battle_scene_with_pages(pages, party: party, rpg2003: true,
                                   battlecommands: OpenStruct.new(battle_type: 2, placement: 1))
  scene
end

check 'a gauge battle opens the ready actor\'s command menu on its own -- no Fight/Auto/Escape window' do
  scene = gauge_battle_scene
  seen_options = false
  ui = nil
  250.times do
    scene.update
    ui = battle_ui(scene)
    seen_options = true if ui && ui[:phase] == :battle_options
    break if ui && ui[:phase] == :command
  end
  ok ui, 'the battle opened'
  ok scene.instance_variable_get(:@battle).is_a?(RPG2k3::Scene::Battle),
     'the gauge database routes the fight to the 2003 scene'
  eq :command, ui[:phase], 'the first full-gauge party member\'s menu appears on its own'
  eq ui[:allies][0], scene.instance_variable_get(:@battle).send(:current_actor),
     'and it is that ready member being commanded'
  eq false, seen_options, 'the once-per-fight Fight/Auto/Escape window never shows for a gauge battle'
end

check 'committing the ready actor\'s command starts that one action, consuming its gauge' do
  scene = gauge_battle_scene
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the battle opened to the ready actor\'s menu'
  # Empty every gauge so the fight has nothing else queued behind this action.
  ui[:battle].all_combatants.each { |c| c.gauge = 0 }
  RGSS::Input.triggered = [RGSS::Input::C] # Attack
  scene.update
  RGSS::Input.triggered = []
  ui = battle_ui(scene)
  eq :target, ui[:phase], 'Attack opens the target cursor'
  RGSS::Input.triggered = [RGSS::Input::C] # the first Slime
  scene.update
  RGSS::Input.triggered = []
  ui = battle_ui(scene)
  eq :animate, ui[:phase], 'confirming the target starts the action'
  eq 0, ui[:battle].all_combatants.first.gauge,
     'the committed actor\'s gauge was consumed the moment its turn began'
end

check 'canceling the ready actor\'s menu returns to the active-time idle loop, and ' \
      'a ready enemy\'s gauge fires its action automatically there' do
  scene = gauge_battle_scene
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the battle opened to the ready actor\'s menu'
  ui[:battle].all_combatants.each { |c| c.gauge = 0 }
  RGSS::Input.triggered = [RGSS::Input::B] # cancel the menu
  scene.update
  RGSS::Input.triggered = []
  ui = battle_ui(scene)
  eq :atb, ui[:phase], 'cancel returns to the active-time idle loop, not to a Fight/Auto/Escape window'
  # Make a Slime ready: its gauge fires the enemy's action with no menu.
  ui[:battle].enemy(0).gauge = Game::Battle::GAUGE_MAX
  scene.update
  ui = battle_ui(scene)
  eq :animate, ui[:phase], 'a ready enemy acts immediately instead of opening a menu'
  eq 0, ui[:battle].enemy(0).gauge, 'the acting enemy\'s gauge was consumed'
end

check 'a ready but restricted (asleep) party member\'s gauge fires a silent no-op, never a command prompt' do
  scene = gauge_battle_scene(BattleStubParty.new(BattleStubActor.new(id: 1, states: [4])))
  ui = battle_until_phase(scene, :atb, 150)
  ok ui, 'the battle opened to the active-time idle loop'
  hero = ui[:battle].all_combatants.first
  # The restricted ally never *charges* under the real fill curve (EasyRPG's
  # CanAct() gate -- the new rpg2k3_battle_gauge_check.rb check pins that), so
  # seed its gauge directly: a full gauge it somehow holds still fires its
  # turn, and the restriction resolves it to a silent no-op, never a prompt.
  hero.gauge = Game::Battle::GAUGE_MAX
  scene.update
  ui = battle_ui(scene)
  eq 0, hero.gauge, 'the asleep member\'s ready gauge was consumed by its (no-op) turn'
  eq true, hero.queued_no_act, 'the do-nothing restriction was locked in for the turn'
end

# -- Wait-off (active) mode: the command menu and the atb_mode toggle --------
#
# ADR 0054's follow-up: the gauge fight's Wait/active presentation. The toggle
# is the save-system `atb_mode` field (LSD chunk 140), flipped by the field
# menu's Wait command -- *not* a Battle Commands database field, correcting
# the ADR's own premise. In wait mode (default) the gauges freeze while any
# command menu is open; in active mode they keep filling and a ready
# non-controllable combatant's action interrupts the menu (EasyRPG's
# `ProcessSceneActionCommand`'s `GetAtbMode() == active && IsBattleActionPending()`
# gate). These checks drive both through the 2003 scene.

check 'wait mode: the command menu freezes every gauge, enemy gauges included' do
  scene, st = battle_scene_with_pages({}, rpg2003: true,
                                      battlecommands: OpenStruct.new(battle_type: 2, placement: 1))
  st.atb_mode = 0 # wait mode -- also the default
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the battle opened to the ready actor\'s menu'
  hero = ui[:allies][0]
  eq true, hero.gauge_full?, 'the commanded actor\'s gauge is held full'
  enemy = ui[:battle].enemy(0)
  # Park the enemy mid-fill so the freeze is measurable: under wait mode its
  # gauge must not move while the menu stays up.
  enemy.gauge = Game::Battle::GAUGE_MAX / 2
  20.times { scene.update }
  eq Game::Battle::GAUGE_MAX / 2, enemy.gauge,
     'wait mode: the enemy\'s gauge does not fill while the command menu is open'
end

check 'active mode: the command menu keeps the gauges filling, and a ready ' \
      'enemy\'s action interrupts it' do
  scene, st = battle_scene_with_pages({}, rpg2003: true,
                                      battlecommands: OpenStruct.new(battle_type: 2, placement: 1))
  st.atb_mode = 1 # Wait-off (active)
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the battle opened to the ready actor\'s menu'
  enemy = ui[:battle].enemy(0)
  enemy.gauge = Game::Battle::GAUGE_MAX / 2
  20.times { scene.update }
  ok enemy.gauge > Game::Battle::GAUGE_MAX / 2,
     'active mode: the enemy\'s gauge keeps filling while the command menu is open'
  ui = battle_ui(scene)
  eq :command, ui[:phase], 'the menu is still up (no interrupt yet -- the enemy is not ready)'
  # Make the enemy ready: in active mode its full gauge fires *now*, mid-menu.
  enemy.gauge = Game::Battle::GAUGE_MAX
  scene.update
  ui = battle_ui(scene)
  eq :animate, ui[:phase], 'a ready enemy\'s action interrupts the open command menu'
  eq 0, enemy.gauge, 'the interrupting enemy\'s gauge was consumed'
  # The interrupting turn plays out -- its action banner holds for
  # BATTLE_ANIM_FRAMES (90) frames -- then, because the commanded actor's
  # gauge is still held full, the idle loop reopens its menu.
  ui = nil
  150.times do
    scene.update
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  eq :command, ui[:phase], 'after the interrupt resolves, the ready actor\'s menu returns'
end

check 'wait mode: a ready enemy waits behind the command menu, no interrupt' do
  scene, st = battle_scene_with_pages({}, rpg2003: true,
                                      battlecommands: OpenStruct.new(battle_type: 2, placement: 1))
  st.atb_mode = 0 # wait mode
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the battle opened to the ready actor\'s menu'
  enemy = ui[:battle].enemy(0)
  enemy.gauge = Game::Battle::GAUGE_MAX
  scene.update
  ui = battle_ui(scene)
  eq :command, ui[:phase], 'wait mode: a ready enemy does not interrupt the open menu'
  eq Game::Battle::GAUGE_MAX, enemy.gauge,
     'and its gauge is left full, waiting for the menu to close'
end

check 'a battle-page Toggle ATB Mode (5003) flips the live fight to active' do
  ic = Game::Interpreter::Cmd
  # A TURN-gated page runs at the first turn boundary; its 5003 flips the
  # same save-system `atb_mode` the field menu Wait command flips, live.
  pages = { 1 => troop_page([ECmd.new(ic::TOGGLE_ATB_MODE, [])]) }
  scene, st = battle_scene_with_pages(pages, rpg2003: true,
                                      battlecommands: OpenStruct.new(battle_type: 2, placement: 1))
  eq 0, st.atb_mode, 'the fight begins in wait mode'
  ui = battle_until_phase(scene, :command, 250)
  ok ui, 'the gauge battle opened to the ready actor\'s menu'
  eq 1, st.atb_mode, 'the 5003 page flipped the fight to active'
  # And the flip is live: the enemy gauge now fills behind the menu, the
  # active-mode behaviour pinned by the checks above.
  enemy = ui[:battle].enemy(0)
  enemy.gauge = Game::Battle::GAUGE_MAX / 2
  20.times { scene.update }
  ok enemy.gauge > Game::Battle::GAUGE_MAX / 2,
     'and the flipped-to-active fight keeps the gauges filling behind the menu'
end

check 'an RPG2003 battle_type 0 (traditional) fight still runs the round machine, never the gauge idle loop' do
  scene, = battle_scene_with_pages({}, rpg2003: true,
                                   battlecommands: OpenStruct.new(battle_type: 0, placement: 1))
  seen_atb = false
  ui = nil
  120.times do
    ui = battle_ui(scene)
    # The same tap-before-update pattern #battle_at_command uses: dismissing
    # the Fight/Auto/Escape window is the only way the round machine gets to
    # its :command phase, and the tap must survive into the update that reads it.
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    seen_atb = true if ui && ui[:phase] == :atb
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ok ui, 'the battle opened'
  eq :command, ui[:phase], 'the traditional 2003 fight opens the ordinary round command phase'
  eq false, seen_atb, 'and never enters the active-time idle loop'
end

# -- mid-battle party roster sync: the screen (step 2 of the roster-sync ------
# initiative; step 1, ADR 0050, fixed the mechanic -- Game::Battle now
# re-derives its own turn order/targeting from the live party every round/
# action) --------------------------------------------------------------------
#
# Interpreter#do_change_party notifies the open battle screen the moment a
# Change Party Member battle event actually adds or removes a member (see
# Scene::Map#on_battle_party_changed, reached via `@battle_ui[:events].
# battle_screen`) -- these checks drive it through a real battle-event page,
# the same path production code takes, except where noted.

check 'a Change Party Member add on a battle page builds that actor\'s sprite ' \
      'immediately and updates the status window' do
  ic = Game::Interpreter::Cmd
  hero = BattleStubActor.new(id: 1, name: 'Hero', battler_animation_id: 5)
  ally = BattleStubActor.new(id: 2, name: 'Ally', battler_animation_id: 5, hp: 50)
  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose(battler_name: 'Party', battler_index: 0) }) }
  party = BattleStubParty.new(hero, alternate_layout: true, roster_actors: [ally])
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_PARTY, [0, 0, 2])]) } # add actor 2
  scene, ui = battle_at_command(pages, party: party, battleranimations: anims)

  eq 2, ui[:allies].length, 'the newcomer joined @battle_ui[:allies] the instant the page ran'
  newcomer = ui[:allies].find { |c| c.actor && c.actor.id == 2 }
  ok newcomer, 'as their own Combatant'
  eq 50, newcomer.hp

  sprites = ui[:actor_sprites]
  eq 2, sprites.length, 'a sprite slot for the newcomer too'
  ok sprites[0] && sprites[1], "both members' idle-pose sprites were built"

  texts = window_texts(ui[:status_win])
  ok texts.include?('Hero') && texts.include?('Ally'), 'both members show in the status window'
end

check 'a Change Party Member remove on a battle page disposes only that ' \
      'actor\'s sprite, and drops just them from @battle_ui[:allies]/the status window' do
  ic = Game::Interpreter::Cmd
  hero = BattleStubActor.new(id: 1, name: 'Hero', battler_animation_id: 5)
  ally = BattleStubActor.new(id: 2, name: 'Ally', battler_animation_id: 5)
  third = BattleStubActor.new(id: 3, name: 'Third', battler_animation_id: 5)
  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose(battler_name: 'Party', battler_index: 0) }) }
  party = BattleStubParty.new(actors: [hero, ally, third], alternate_layout: true)
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_PARTY, [1, 0, 2])]) } # remove actor 2
  scene, = battle_scene_with_pages(pages, party: party, battleranimations: anims)

  # Capture the pristine, pre-page sprite objects: #build_actor_sprites runs
  # synchronously inside #open_battle, before the turn-0 page's own command
  # ever gets a chance to run (it waits out the encounter-narration banner
  # first -- see #drive_battle_encounter_message).
  ui = nil
  10.times do
    scene.update
    ui = battle_ui(scene)
    break if ui
  end
  ok ui, 'the battle opened'
  eq :encounter_message, ui[:phase], 'still narrating -- the page has not run its command yet'
  eq 3, ui[:allies].length, 'all three start in @battle_ui[:allies]'
  hero_sprite, ally_sprite, third_sprite = ui[:actor_sprites]
  ok hero_sprite && ally_sprite && third_sprite, 'all three built a sprite up front'

  150.times do
    RGSS::Input.triggered = [RGSS::Input::C] if ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui[:phase] == :command
  end
  eq :command, ui[:phase], 'the page ran (and handed control back) along the way'

  eq 2, ui[:allies].length, 'the removed member dropped out of @battle_ui[:allies]'
  ok ui[:allies].none? { |c| c.actor && c.actor.id == 2 }
  ok ui[:allies].any? { |c| c.actor && c.actor.id == 1 }
  ok ui[:allies].any? { |c| c.actor && c.actor.id == 3 }

  eq 2, ui[:actor_sprites].length
  ok ui[:actor_sprites].include?(hero_sprite), "Hero's original sprite object is untouched"
  ok ui[:actor_sprites].include?(third_sprite), "Third's original sprite object is untouched"
  ok !ui[:actor_sprites].include?(ally_sprite), "the removed actor's sprite slot is gone"
  ok ally_sprite.disposed?, "the removed actor's specific sprite was disposed"
  ok !hero_sprite.disposed?, "a bystander's sprite was never disposed"
  ok !third_sprite.disposed?, "a bystander's sprite was never disposed"

  texts = window_texts(ui[:status_win])
  ok !texts.include?('Ally'), 'the removed member dropped off the status window'
  ok texts.include?('Hero') && texts.include?('Third'), 'the remaining members still show'
end

check 'a Change Party Member add reaches the gauge-card status panel ' \
      '(battle_type 2) too, not just the plain text row' do
  ic = Game::Interpreter::Cmd
  hero = BattleStubActor.new(id: 1, name: 'Hero', hp: 100, mp: 20, faceset_name: 'HeroFace')
  ally = BattleStubActor.new(id: 2, name: 'Ally', hp: 80, mp: 10, faceset_name: 'AllyFace')
  party = BattleStubParty.new(hero, gauge_layout: true, roster_actors: [ally])
  pages = { 1 => troop_page([ECmd.new(ic::CHANGE_PARTY, [0, 0, 2])]) } # add actor 2
  scene, = battle_scene_with_pages(pages, party: party)
  # Set before the fight ever opens, so #on_battle_party_changed's own
  # #refresh_battle_status call (triggered by the page below) already draws
  # the gauge card, not just a later manually-forced redraw.
  scene.db.system.system2_name = 'BattleStatus'

  ui = nil
  150.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  eq :command, ui[:phase]
  eq 2, ui[:allies].length, 'both members reached the gauge-card roster'

  faces = ui[:status_win].contents.blt_calls.select do |call|
    call[2].respond_to?(:load_name) && call[2].load_name.to_s.start_with?('FaceSet/')
  end
  eq [[0, 24], [80, 24]], faces.map { |call| call[0, 2] },
     'a face column at x = 80*i for each member -- the newcomer got their own at i=1'
end

check 'leaving and rejoining the same fight reuses the same Combatant (and ' \
      'its accumulated battle-only state) but always rebuilds a fresh sprite -- ' \
      'never a leaked duplicate, never a disposed-and-reused one' do
  hero = BattleStubActor.new(id: 1, name: 'Hero', battler_animation_id: 5)
  ally = BattleStubActor.new(id: 2, name: 'Ally', battler_animation_id: 5)
  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose(battler_name: 'Party', battler_index: 0) }) }
  party = BattleStubParty.new(actors: [hero, ally], alternate_layout: true)
  scene, ui = battle_at_command(nil, party: party, battleranimations: anims)

  eq 2, ui[:allies].length
  original_combatant = ui[:allies].find { |c| c.actor.id == 2 }
  original_sprite = ui[:actor_sprites][ui[:allies].index(original_combatant)]
  ok original_combatant && original_sprite

  original_combatant.states = [5] # an accumulated battle-only status
  scene.instance_variable_get(:@battle).send(:on_battle_party_changed, ally, false) # leaves
  eq 1, ui[:allies].length, 'dropped from the render roster'
  ok !ui[:actor_sprites].include?(original_sprite)
  ok original_sprite.disposed?, 'their sprite was disposed on the way out'

  scene.instance_variable_get(:@battle).send(:on_battle_party_changed, ally, true) # rejoins the same fight
  eq 2, ui[:allies].length, 'back in the render roster, not duplicated'
  eq 1, ui[:allies].count { |c| c.actor && c.actor.id == 2 }, 'no leaked duplicate Combatant'
  rejoined_combatant = ui[:allies].find { |c| c.actor.id == 2 }
  ok rejoined_combatant.equal?(original_combatant), 'the exact same Combatant object is reused'
  eq [5], rejoined_combatant.states, 'their accumulated battle-only state survived the round trip'

  new_sprite = ui[:actor_sprites][ui[:allies].index(rejoined_combatant)]
  ok new_sprite, 'a sprite was rebuilt for the rejoin'
  ok !new_sprite.equal?(original_sprite), 'a fresh Sprite object, never the disposed one'
  eq 2, ui[:actor_sprites].compact.length, 'no leaked extra sprite either'
end

check 'actor sprite Z stays collision-free across a remove-then-add cycle, ' \
      'matching EasyRPG\'s ResetAllBattlerZ' do
  hero = BattleStubActor.new(id: 1, name: 'Hero', battler_animation_id: 5)
  ally = BattleStubActor.new(id: 2, name: 'Ally', battler_animation_id: 5)
  third = BattleStubActor.new(id: 3, name: 'Third', battler_animation_id: 5)
  newcomer = BattleStubActor.new(id: 4, name: 'New', battler_animation_id: 5)
  anims = { 5 => battle_pose_set(poses: { 0 => battle_pose(battler_name: 'Party', battler_index: 0) }) }
  party = BattleStubParty.new(actors: [hero, ally, third], alternate_layout: true,
                              roster_actors: [newcomer])
  scene, ui = battle_at_command(nil, party: party, battleranimations: anims)
  eq [200, 201, 202], ui[:actor_sprites].map(&:z), 'starting Z per index (#actor_sprite_z)'

  scene.instance_variable_get(:@battle).send(:on_battle_party_changed, ally, false) # remove the middle member
  eq [200, 201], ui[:actor_sprites].map(&:z),
     "Third's Z was recomputed for its new index (1), not left stale at 202"

  scene.instance_variable_get(:@battle).send(:on_battle_party_changed, newcomer, true) # a brand new member joins
  zs = ui[:actor_sprites].map(&:z)
  eq [200, 201, 202], zs
  eq zs.uniq.length, zs.length, 'no two actor sprites end up sharing a Z'
end

# -- the battle log in the game's own words ------------------------------------

check 'a plain attack reads as RPG_RT words it: the attack, then the damage' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 42,
                       target_ally: false })
  eq ['Heroの攻撃！', 'Slimeに 42 のダメージを与えた！'], lines
end

check 'and from the other side, with the other predicate and particle' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Slime', target: 'Hero', damage: 7,
                       target_ally: true })
  eq ['Slimeの攻撃！', 'Heroは 7 のダメージを受けた！'], lines
end

check 'a miss reads as the target dodging' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 0,
                       missed: true, target_ally: false })
  eq ['Heroの攻撃！', 'Slimeは身をかわした！'], lines
end

check 'a blow that gets through for nothing says so' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 0,
                       target_ally: false })
  eq ['Heroの攻撃！', 'Slimeにダメージを与えられない！'], lines
end

# A critical hit inserts the game's own 会心/痛恨 line between the attack and
# the damage (Scene_Battle_Rpg2k::ProcessBattleActionCritical runs before
# ProcessBattleActionApply), keyed on the target taking the crit like the
# damage predicates themselves, not on which side dealt it.
check 'a critical hit adds the game\'s own line between the attack and the damage' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 42,
                       critical: true, target_ally: false })
  eq ['Heroの攻撃！', '会心の一撃！！', 'Slimeに 42 のダメージを与えた！'], lines
end

check 'and from the other side, the term keyed on the party member taking it' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Slime', target: 'Hero', damage: 7,
                       critical: true, target_ally: true })
  eq ['Slimeの攻撃！', '痛恨の一撃！！', 'Heroは 7 のダメージを受けた！'], lines
end

check 'a blank critical term drops the whole entry back to the composed ' \
      'wording, "(critical!)" included' do
  scene, = battle_at_command
  scene.db.term.enemy_critical = ''
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Hero', target: 'Slime', damage: 42,
                       critical: true, target_ally: false })
  eq ['Hero hits Slime for 42 (critical!)'], lines
end

check 'the basic actions with no target are one line each' do
  scene, = battle_at_command
  eq ['Slimeは身を守っている'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines, { attacker: 'Slime', defend: true })
  eq ['Slimeは力をためている・・・'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines, { attacker: 'Slime', charge: true })
  eq ['Slimeは逃げてしまった！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines, { attacker: 'Slime', fled: true })
  eq ['Slimeは変身した！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines, { attacker: 'Slime', transform: true,
                                        target: 'Bat' })
end

check 'an autodestruct names itself and then the damage it did' do
  scene, = battle_at_command
  eq ['Slimeは自爆した！', 'Heroは 20 のダメージを受けた！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Slime', target: 'Hero', damage: 20,
                  autodestruct: true, target_ally: true })
end

# A database that leaves a battle term blank must not produce a half-sentence.
check 'a blank term drops the whole entry back to the composed wording' do
  scene, = battle_at_command
  # `observing` is blank in the fixture, so Observe cannot be worded from the
  # table and the entry falls back whole rather than printing a bare name.
  eq ['Slime watches closely'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines, { attacker: 'Slime', observe: true })
end

check 'a skill keeps its composed line until its own sentence is read' do
  scene, = battle_at_command
  # using_message1 / use_item are still unread; dropping to the bare damage line
  # would lose the only thing naming what was cast.
  eq ["Hero's Venom hits Slime for 7"],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Venom',
                  target_ally: false })
end

check 'the state sentences still follow the action ones' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Slime', target: 'Hero', damage: 7,
                       inflicted: [3], target_ally: true })
  eq ['Slimeの攻撃！', 'Heroは 7 のダメージを受けた！', 'Hero is poisoned!'], lines
end

# -- ability-value / attribute-resistance messages (term fields 30/31/34/35) --
#
# An affect_attack/defense/spirit/agility skill (Game::Battle#apply_stat_mods)
# and an affect_attr_defence skill (Game::Battle#apply_attr_shift) both already
# moved the target's numbers with no line ever announcing it -- RPG_RT's own
# GetParameterChangeMessage / GetAttributeShiftMessage read `term.
# parameter_increase` / `_decrease` and `term.resistance_increase` / `_decrease`
# for exactly this, matching every other landed-condition sentence above.

check 'an affect_attack/defense/spirit/agility skill announces the stat rise ' \
      'or drop, in the game\'s own words' do
  scene, = battle_at_command
  up = scene.instance_variable_get(:@battle).send(:battle_state_lines, { target: 'Hero', target_ally: true,
                                         stat_changed: { atk: 10 } })
  eq ['Heroの攻撃力が 10 上がった！'], up

  down = scene.instance_variable_get(:@battle).send(:battle_state_lines, { target: 'Slime', target_ally: false,
                                           stat_changed: { def: -4 } })
  eq ['Slimeの防御力が 4 下がった！'], down

  # Every ability-value key the mechanic can touch, and in the order
  # #apply_stat_mods reports them.
  all_four = scene.instance_variable_get(:@battle).send(:battle_state_lines,
                        { target: 'Hero', target_ally: true,
                          stat_changed: { atk: 3, def: -2, spi: 1, agi: -5 } })
  eq ['Heroの攻撃力が 3 上がった！', 'Heroの防御力が 2 下がった！',
      'Heroの精神力が 1 上がった！', 'Heroの敏捷性が 5 下がった！'], all_four
end

check 'a zero-delta stat entry (already pinned at its cap) says nothing' do
  scene, = battle_at_command
  eq [], scene.instance_variable_get(:@battle).send(:battle_state_lines,
                    { target: 'Hero', target_ally: true, stat_changed: { atk: 0 } })
end

check 'an affect_attr_defence skill announces which way the target\'s ' \
      'resistance moved, by the attribute\'s own name -- no magnitude, ' \
      'matching EasyRPG\'s GetAttributeShiftMessage' do
  scene, = battle_at_command
  raised = scene.instance_variable_get(:@battle).send(:battle_state_lines,
                      { target: 'Hero', target_ally: true,
                        attr_shifted: [1], attr_shift_dir: 1 })
  eq ['Heroは火 耐性が上がった！'], raised

  lowered = scene.instance_variable_get(:@battle).send(:battle_state_lines,
                       { target: 'Slime', target_ally: false,
                         attr_shifted: [1], attr_shift_dir: -1 })
  eq ['Slimeは火 耐性が下がった！'], lowered
end

check 'the stat and attribute-shift lines follow the damage line, like every ' \
      'other landed condition' do
  scene, = battle_at_command
  lines = scene.instance_variable_get(:@battle).send(:battle_action_lines,
                     { attacker: 'Slime', target: 'Hero', damage: 7,
                       target_ally: true, stat_changed: { def: -5 },
                       attr_shifted: [1], attr_shift_dir: -1 })
  eq ['Slimeの攻撃！', 'Heroは 7 のダメージを受けた！',
      'Heroの防御力が 5 下がった！', 'Heroは火 耐性が下がった！'], lines
end

check 'a skill announces itself with its own two sentences, then the damage' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 42 のダメージを与えた！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 42, skill: 'Fire',
                  skill_id: 8, target_ally: false })
end

check 'a skill with only a first sentence gives one line before the damage' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'Slimeに 5 のダメージを与えた！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 5, skill: 'Heal',
                  skill_id: 9, target_ally: false })
end

check 'a skill row with no sentence keeps the composed line' do
  scene, = battle_at_command
  eq ["Hero's Mute hits Slime for 5"],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 5, skill: 'Mute',
                  skill_id: 10, target_ally: false })
end

check 'a skill that misses takes its own failure sentence, not the damage line' do
  scene, = battle_at_command
  eq ['Heroは呪文を唱えた！', 'Slimeは眠らなかった！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 0, missed: true,
                  skill: 'Sleep', skill_id: 11, target_ally: false })
end

check 'a heal that restored nothing reads as a failure' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'Heroには効かなかった！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Heal', skill_id: 9,
                  target: 'Hero', recover_hp: 0, recover_mp: 0,
                  cured: [], target_ally: true })
end

check 'a heal that worked says what it restored, in the game own words' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'HeroのＨＰが 30 回復した！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Heal', skill_id: 9,
                  target: 'Hero', recover_hp: 30, recover_mp: 0,
                  cured: [], target_ally: true })
end

check 'a heal that filled both pools says so once per pool' do
  scene, = battle_at_command
  eq ['Heroは光をまとった！', 'HeroのＨＰが 30 回復した！',
      'HeroのＭＰが 12 回復した！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Heal', skill_id: 9,
                  target: 'Hero', recover_hp: 30, recover_mp: 12,
                  cured: [], target_ally: true })
end

check 'an item names itself with the caster, the item and the term' do
  scene, = battle_at_command
  eq ['HeroはPotionを使った！', 'HeroのＨＰが 30 回復した！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Potion', item_id: 3,
                  target: 'Hero', recover_hp: 30, recover_mp: 0,
                  cured: [], target_ally: true })
end

check 'an item that only cured says so through the state sentence' do
  scene, = battle_at_command
  eq ['HeroはAntidoteを使った！', 'Hero is cured.'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Antidote', item_id: 5,
                  target: 'Hero', recover_hp: 0, recover_mp: 0,
                  cured: [3], target_ally: true })
end

check 'an item that did nothing keeps the composed line' do
  scene, = battle_at_command
  # RPG2000 gives an item no failure sentence to choose from -- unlike a skill,
  # it has no failure_message -- so the composed wording still says more.
  ok scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { recover: true, actor: 'Hero', source: 'Potion', item_id: 3,
                  target: 'Hero', recover_hp: 0, recover_mp: 0,
                  cured: [], target_ally: true })
     .first.include?('no effect')
end

check 'a drain adds its own line after the damage' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 20 のダメージを与えた！', 'SlimeのＨＰを 20 奪った！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 20, skill: 'Fire',
                  skill_id: 8, absorbed_hp: 20, target_ally: false })
end

check 'a drain on a party member is worded from their side' do
  scene, = battle_at_command
  eq ['Slimeは炎を放った！', 'あたりが真っ赤に染まる！',
      'Heroは 20 のダメージを受けた！', 'HeroはＨＰを 20 奪われた！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Slime', target: 'Hero', damage: 20, skill: 'Fire',
                  skill_id: 8, absorbed_hp: 20, target_ally: true })
end

check 'a skill that drained nothing adds no line' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 20 のダメージを与えた！'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 20, skill: 'Fire',
                  skill_id: 8, absorbed_hp: 0, target_ally: false })
end

check 'a skill still trails the states it landed' do
  scene, = battle_at_command
  eq ['Heroは炎を放った！', 'あたりが真っ赤に染まる！',
      'Slimeに 7 のダメージを与えた！', 'Slime looks ill!'],
     scene.instance_variable_get(:@battle).send(:battle_action_lines,
                { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Fire',
                  skill_id: 8, inflicted: [3], target_ally: false })
end

check 'the action banner announces the states an action landed and lifted' do
  scene, = battle_at_command
  # The database's own sentences, printed straight after the target's name.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 7, skill: 'Venom',
               inflicted: [3], target_ally: false })
  ui = battle_ui(scene)
  texts = window_texts(ui[:action_win])
  ok texts.any? { |t| t.include?('Venom') }, 'the action itself still reads'
  ok texts.include?('Slime looks ill!'), 'with the enemy wording for the state'

  # The same state on a party member takes the actor wording.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 7,
               inflicted: [3], target_ally: true })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Hero is poisoned!'), 'and the actor wording for an ally'

  # A cure reads the recovery sentence.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { recover: true, actor: 'Hero', source: 'Antidote', target: 'Hero',
               recover_hp: 0, recover_mp: 0, cured: [3], target_ally: true })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Hero is cured.'), 'the recovery sentence'

  # So does a state a blow shook off (`woke`, a state's release_by_attack) --
  # the state lifting is the same event however it happened.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 9,
               woke: [3], target_ally: false })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Slime is cured.'), 'a state shaken off by a blow reads the same'
end

check 'being downed is announced with the death state own sentence' do
  scene, = battle_at_command
  # State 1 is death; the fake database words it from the speaker's side, the
  # way a real one does.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 30,
               defeated: true, target_ally: false })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Slime is struck down!'), 'the enemy wording'
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 30,
               defeated: true, target_ally: true })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Hero falls!'), 'and the actor wording'
end

check 'a status the target already had is announced, in the state own words' do
  scene, = battle_at_command
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               already: [3], target_ally: true })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Hero is already poisoned!'),
     'one wording, whichever side the target is on'
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Hero', target: 'Slime', damage: 3,
               already: [3], target_ally: false })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Slime is already poisoned!')
end

check 'an already-carried state with no sentence still gets announced' do
  scene, = battle_at_command
  # State 4 (Sleep) has a name but no message_already, which is what an
  # English-release database looks like.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               already: [4], target_ally: true })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Hero is already Sleep'), 'the scene composes its own wording'
end

check 'a state the database gives no sentence still gets announced' do
  scene, = battle_at_command
  # State 5 (Silence) has a name but no message_actor / message_enemy, which is
  # what an English-release database looks like.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               inflicted: [5], target_ally: true })
  ok window_texts(battle_ui(scene)[:action_win])
      .include?('Hero is Silence'), 'the scene composes its own wording'

  # An id the table does not define at all still reads as something.
  scene.instance_variable_get(:@battle).send(:show_battle_action,
             { attacker: 'Slime', target: 'Hero', damage: 3,
               inflicted: [99], target_ally: true })
  ok window_texts(battle_ui(scene)[:action_win])
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
  # Mirrors Game::Actor's own RPG2003 battle-row state, for the field-menu
  # Row command check below (Game::Party#toggle_actor_row reads/writes this).
  attr_accessor :battle_row
  attr_accessor :faceset_name, :faceset_index
  def initialize
    @name = 'Hero'; @title = 'Wanderer'; @level = 5
    @hp = 80; @max_hp = 120; @mp = 10; @max_mp = 30
    @atk = 20; @def = 12; @int = 9; @agi = 14; @exp = 300
    @states = []
    @equipment = [0, 0, 0, 0, 0]
    @faceset_name = ''; @faceset_index = 0
    @battle_row = Game::Battle::ROW_FRONT
  end
  def exp_to_next; 120; end
  def add_state(id); @states.push(id) unless @states.include?(id); end
  attr_accessor :can_act_flag
  def can_act?; @can_act_flag.nil? ? true : @can_act_flag; end
  attr_accessor :equipment_fixed_flag
  def equipment_fixed?; !!@equipment_fixed_flag; end
  attr_accessor :cursed_slot
  def slot_cursed?(slot); @cursed_slot == slot; end
  # No item in this bare fixture is ever 両手持ち (two-handed) -- a check
  # exercising that needs its own richer stub, same as the item/skill tables
  # below.
  def two_handed?(_item_id); false; end
  # Mirror Game::Actor#display_max_hp / #display_max_mp for the RGSS stubs.
  def display_max_hp; hp && hp > max_hp ? hp : max_hp; end
  def display_max_mp; mp && mp > max_mp ? mp : max_mp; end
 end

class MenuStubParty
  attr_reader :actors, :gold, :revision
  attr_accessor :leader
  def initialize
    @actors = [MenuStubActor.new]; @gold = 0; @leader = nil; @revision = 0
  end
  def field_items(_state = nil); []; end
  def field_skills(_actor, _state = nil); []; end
  def reorder(new_order); @actors = new_order.map { |i| @actors[i] }; end
  # Mirrors Game::Party#toggle_actor_row's own guard (see rpg2k_logic_check.rb
  # for that method's own coverage) -- this scene-check only needs to prove
  # Scene::Menu's `:row` dispatch actually reaches it, not re-prove the guard.
  def toggle_actor_row(actor)
    if actor.battle_row == Game::Battle::ROW_FRONT
      back = @actors.count { |a| a != actor && a.battle_row == Game::Battle::ROW_BACK }
      return if back >= @actors.size - 1
      actor.battle_row = Game::Battle::ROW_BACK
    else
      actor.battle_row = Game::Battle::ROW_FRONT
    end
  end
end

def menu_scene(klass, state, db = fake_db)
  klass.new(fake_parent(db), state)
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
  def field_items(_state = nil); [[1, 3], [2, 1]]; end
  def field_skills(_actor, _state = nil); [[10, 2], [11, 4]]; end
  def db_item(id); OpenStruct.new(name: "Item#{id}"); end
  def db_skill(id); OpenStruct.new(name: "Skill#{id}", description: "Description of skill #{id}."); end
  def equip_candidates(_slot, _actor = nil); [[7, 2], [8, 1]]; end
end

def wrap_menu_state
  Game::State.new(WrapMenuParty.new, 1, 0, 0)
end

# A two-actor party with distinct names (WrapMenuParty's two MenuStubActors are
# both unavoidably named "Hero") -- what the Scene::Order checks need in order
# to tell the left/right columns' rows apart by name rather than only by index.
class OrderStubActor < MenuStubActor
  def initialize(name)
    super()
    @name = name
  end
end

class OrderStubParty < MenuStubParty
  def initialize
    super
    @actors = [OrderStubActor.new('Hero'), OrderStubActor.new('Ally')]
  end
end

def order_state
  Game::State.new(OrderStubParty.new, 1, 0, 0)
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

check 'opening Scene::Menu auto-cancels an Erase Screen black-out (yado.tk)' do
  st = menu_state
  st.screen.erase(Game::Transition::FADE_OUT, 1) # settle fully erased
  eq 255, st.screen.fade_level, 'erased before the menu opens'
  menu_scene(RPG2k::Scene::Menu, st)
  eq 0, st.screen.fade_level,
     'opening the menu instantly clears the black-out with no Show Screen'
  ok !st.screen.fading?, 'no fade animation left running'
end

check 'opening Scene::Menu leaves an already-visible screen alone' do
  st = menu_state
  eq 0, st.screen.fade_level, 'starts fully visible'
  menu_scene(RPG2k::Scene::Menu, st)
  eq 0, st.screen.fade_level, 'still fully visible'
end

check 'Scene::Menu: the main command cursor wraps around' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@index), 'starts on the first command'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 4, scene.instance_variable_get(:@index),
     'Up from the first command wraps to the last (RPG2000\'s fixed 5 commands: ' \
     'Item/Skill/Equip/Save/End Game -- no Status, see RPG2K_COMMAND_KEYS)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@index), 'Down from the last command wraps to the first'
end

# EasyRPG's Window_Selectable::Update (the base every real RPG2000 command
# list is built on) falls through to Input::IsRepeated right after its own
# IsTriggered check, so holding Down/Up auto-scrolls the cursor after the
# initial delay -- see Scene::SaveLoad's identical fix for the fuller
# writeup. `RGSS::Input.repeated` (distinct from `.triggered`) lets this
# check hold a key across frames without it also reading as a fresh
# trigger, exercising the `#repeat?` half of the gate on its own.
check 'Scene::Menu: holding Down auto-repeats the main command cursor, not ' \
      'just a single step per tap' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@index), 'starts on the first command'
  RGSS::Input.repeated = [RGSS::Input::DOWN] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@index),
     'a held (repeated, not triggered) Down still moves the cursor one step'
end

check 'Scene::Menu: choosing Item pushes Scene::ItemMenu directly' do
  # RPG2K_COMMAND_KEYS order is Item, Skill, Equip, Save, End Game -- RPG2000
  # has no Status entry at all (see Scene::Menu's own doc comment, ported from
  # EasyRPG's Scene_Menu::CreateCommandWindow). Item acts on one confirm,
  # unlike Skill/Equip/Status below, which hand focus to the party-status
  # panel first -- confirm Item actually reaches Scene::ItemMenu rather than
  # falling into the generic "not implemented yet" message.
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  scene.instance_variable_set(:@index, 0)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  pushed = scene.parent.pushed.last
  ok pushed.is_a?(RPG2k::Scene::ItemMenu), "command #0 pushes a live Scene::ItemMenu, got #{pushed.class}"
end

check 'Scene::Menu: choosing Skill/Equip hands focus to the party-status panel, ' \
      'a second confirm there opens the scene for the picked actor' do
  # Confirmed against EasyRPG's own Scene_Menu::UpdateCommand /
  # UpdateActorSelection: Skill/Equipment/Status don't open immediately --
  # the command list goes inactive, the party-status panel goes active, and
  # only confirming an actor there pushes the real scene (constructed with
  # that actor's index, the third constructor argument).
  {
    1 => RPG2k::Scene::SkillMenu,
    2 => RPG2k::Scene::EquipMenu,
  }.each do |index, klass|
    scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
    scene.instance_variable_set(:@index, index)
    RGSS::Input.triggered = [RGSS::Input::C]
    scene.update
    RGSS::Input.reset
    eq :actors, scene.instance_variable_get(:@focus),
       "command ##{index} hands focus to the party-status panel, not an immediate push"
    ok scene.parent.pushed.empty?, 'nothing pushed yet'

    RGSS::Input.triggered = [RGSS::Input::DOWN]        # move onto the second party member
    scene.update
    RGSS::Input.reset
    eq 1, scene.instance_variable_get(:@actor_index)

    RGSS::Input.triggered = [RGSS::Input::C]
    scene.update
    RGSS::Input.reset
    pushed = scene.parent.pushed.last
    ok pushed.is_a?(klass), "confirming the actor pushes a live #{klass}, got #{pushed.class}"
    eq :command, scene.instance_variable_get(:@focus), 'back to command focus once pushed'
  end
end

check 'Scene::Menu: cancelling actor selection returns focus to the command list' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  scene.instance_variable_set(:@index, 1)              # Skill
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :actors, scene.instance_variable_get(:@focus)

  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.reset
  eq :command, scene.instance_variable_get(:@focus)
  ok scene.parent.pushed.empty?, 'nothing was ever pushed'
end

check 'Scene::Menu: holding Down auto-repeats the party-status actor cursor too' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  scene.instance_variable_set(:@index, 1) # Skill -> hands focus to the actor list
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :actors, scene.instance_variable_get(:@focus)

  RGSS::Input.repeated = [RGSS::Input::DOWN] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@actor_index),
     'a held (repeated, not triggered) Down still moves the actor cursor one step'
end

check 'Scene::Menu: a restricted actor cannot be given the Skill command, ' \
      'unlike Equip' do
  # Confirmed against EasyRPG's own Scene_Menu::UpdateActorSelection: its
  # Skill case alone gates on actor->CanAct(); Equipment/Status do not.
  st = wrap_menu_state
  st.party.actors.first.can_act_flag = false
  scene = menu_scene(RPG2k::Scene::Menu, st)
  scene.instance_variable_set(:@index, 1)              # Skill
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]             # confirm the (restricted) first actor
  scene.update
  RGSS::Input.reset
  ok scene.parent.pushed.empty?, 'nothing pushed for a restricted actor'
  eq :actors, scene.instance_variable_get(:@focus), 'stays in actor selection -- pick someone else'

  RGSS::Input.triggered = [RGSS::Input::B]             # cancel back, try Equip instead
  scene.update
  RGSS::Input.reset
  scene.instance_variable_set(:@index, 2)              # Equip
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]             # confirm the (restricted) first actor
  scene.update
  RGSS::Input.reset
  ok scene.parent.pushed.last.is_a?(RPG2k::Scene::EquipMenu),
     'Equip has no CanAct gate, so the restricted actor still opens it'
end

check 'Scene::Menu: End Game opens a Yes/No confirmation instead of quitting ' \
      'outright' do
  # Confirmed against EasyRPG's own Scene_Menu::UpdateCommand (`case Quit:`
  # plays the Decision SE and pushes Scene_End, never touching the title
  # directly) and Scene_End::CreateCommandWindow (cursor defaults to index
  # 1, "No" -- a stray confirm press must not quit the game).
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  scene.instance_variable_set(:@index, 4)  # End Game, last of RPG2K_COMMAND_KEYS
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  ok !scene.parent.returned_to_title,
     'selecting End Game alone must not hand control back to the app'
  eq :end_game_confirm, scene.instance_variable_get(:@focus),
     'a Yes/No prompt opens instead'
  eq 1, scene.instance_variable_get(:@confirm_index),
     'the cursor starts on "No" (index 1), matching Scene_End::CreateCommandWindow'
end

check 'Scene::Menu: confirming "No" on the End Game prompt returns to the ' \
      'command list, not the title' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  scene.instance_variable_set(:@index, 4)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update                                    # open the prompt (cursor on No)
  RGSS::Input.reset
  RGSS::Audio.reset_bgm
  RGSS::Input.triggered = [RGSS::Input::C]         # confirm "No"
  scene.update
  RGSS::Input.reset
  ok !scene.parent.returned_to_title, '"No" must not quit the game'
  eq [], RGSS::Audio.bgm_fade_calls, 'and must not fade the BGM either'
  eq :command, scene.instance_variable_get(:@focus),
     'focus is back on the command list'
end

check 'Scene::Menu: cancelling the End Game prompt also returns to the ' \
      'command list, not the title' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  scene.instance_variable_set(:@index, 4)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::B]         # Cancel, same as Scene_End's own Input::CANCEL
  scene.update
  RGSS::Input.reset
  ok !scene.parent.returned_to_title, 'Cancel must not quit the game'
  eq :command, scene.instance_variable_get(:@focus)
end

check 'Scene::Menu: confirming "Yes" on the End Game prompt fades the BGM ' \
      'and returns to the title' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  scene.instance_variable_set(:@index, 4)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update                                    # open the prompt (cursor on No)
  RGSS::Input.reset
  RGSS::Audio.reset_bgm

  RGSS::Input.triggered = [RGSS::Input::UP]        # move the cursor to "Yes"
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@confirm_index)

  RGSS::Input.triggered = [RGSS::Input::C]         # confirm "Yes"
  scene.update
  RGSS::Input.reset
  ok scene.parent.returned_to_title,
     '"Yes" hands control back to the app, same as before this prompt existed'
  eq [[400]], RGSS::Audio.bgm_fade_calls,
     'Game_System::BgmFade(400) runs before the handoff'
end

check 'Scene::Menu: RPG2000 (no rpg2003? flag) never offers Status at all' do
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state)
  keys = scene.instance_variable_get(:@commands).map(&:first)
  eq [:item, :skill, :equip, :save, :end_game], keys,
     'the fixed RPG2000 five, matching EasyRPG\'s Player::IsRPG2k() branch -- ' \
     'no Status, since a real RPG2000 database never customizes the menu'
end

check 'Scene::Menu: an RPG2003 database drives the command list from ' \
      'System.menu_commands, Status, Row and Order included' do
  # mtf-meido-action's own array, id-for-id (confirmed by loading its real
  # RPG_RT.ldb): every one of RPG2003's eight customizable ids, in ascending
  # order. Every id is modelled now: Row (6) toggles the picked actor's row
  # on the same actor-selection panel Skill/Equipment/Status use
  # (`Game::Party#toggle_actor_row`); Wait (8) -- the ATB toggle -- flips the
  # save-system `atb_mode` field (ADR 0054's follow-up) and is offered with
  # its current-mode label; Order (7) has no battle-system dependency at all,
  # just party reordering; End Game is appended unconditionally, matching
  # EasyRPG's own unconditional Quit push outside the customized loop.
  db = fake_db(rpg2003: true, menu_commands: [1, 2, 3, 4, 5, 6, 7, 8])
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state, db)
  keys = scene.instance_variable_get(:@commands).map(&:first)
  eq [:item, :skill, :equip, :save, :status, :row, :order, :wait, :end_game], keys,
     'Status (id 5), Row (id 6), Order (id 7) and Wait (id 8) are all offered'
end

check 'Scene::Menu: the Wait command shows the current atb_mode, and toggling ' \
      'it flips the field and relabels the row' do
  db = fake_db(rpg2003: true, menu_commands: [1, 8])
  st = wrap_menu_state
  eq 0, st.atb_mode, 'a fresh state starts in wait mode'
  scene = menu_scene(RPG2k::Scene::Menu, st, db)
  cmds = scene.instance_variable_get(:@commands)
  eq :wait, cmds[1].first, 'the Wait command (id 8) is offered'
  eq ['Wait On'], [cmds[1][1]], 'wait mode labels the row with wait_on'
  scene.instance_variable_set(:@index, 1)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq 1, st.atb_mode, 'confirming Wait flips atb_mode to active'
  cmds = scene.instance_variable_get(:@commands)
  eq ['Wait Off'], [cmds[1][1]], 'the row relabels to wait_off after the flip'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq 0, st.atb_mode, 'confirming again flips back to wait'
  eq ['Wait On'], [cmds[1][1]], 'and the row relabels back to wait_on'
end

check 'Scene::Menu: RPG2003 System.menu_commands can reorder and omit commands' do
  # An arbitrary game that put Status first, dropped Item and Skill entirely,
  # and never touched Save: #build_commands must reproduce the game's own
  # order and omissions, not fall back to the RPG2000 default shape.
  db = fake_db(rpg2003: true, menu_commands: [5, 3])
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state, db)
  keys = scene.instance_variable_get(:@commands).map(&:first)
  eq [:status, :equip, :end_game], keys,
     'Status then Equip, in the game\'s own order, End Game still appended last'
  scene.instance_variable_set(:@index, 0)
  RGSS::Input.triggered = [RGSS::Input::C]         # Status hands focus to the party-status panel
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]         # confirming the first actor there opens it
  scene.update
  RGSS::Input.reset
  ok scene.parent.pushed.last.is_a?(RPG2k::Scene::StatusMenu),
     'selecting the reordered Status command actually opens Scene::StatusMenu'
end

check 'Scene::Menu: choosing Order pushes Scene::Order directly, no actor-' \
      'selection step' do
  # Unlike Skill/Equip/Status, Order acts on the whole party at once --
  # confirmed against EasyRPG's own Scene_Menu::UpdateCommand, whose `case
  # Order:` pushes Scene_Order straight away, the same shape as Item/Save,
  # not the Skill/Equipment/Status/Row actor-selection branch.
  db = fake_db(rpg2003: true, menu_commands: [1, 7])
  scene = menu_scene(RPG2k::Scene::Menu, wrap_menu_state, db)
  eq [:item, :order, :end_game], scene.instance_variable_get(:@commands).map(&:first)
  scene.instance_variable_set(:@index, 1)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  pushed = scene.parent.pushed.last
  ok pushed.is_a?(RPG2k::Scene::Order), "Order pushes a live Scene::Order, got #{pushed.class}"
  eq :command, scene.instance_variable_get(:@focus),
     'no actor-selection focus change, unlike Skill/Equip/Status'
end

check 'Scene::Menu: choosing Row hands focus to the actor-selection panel, ' \
      'and confirming an actor toggles their row with no scene pushed' do
  # Unlike Order, Row shares Skill/Equipment/Status' actor-selection shape
  # (the class comment, and EasyRPG's own UpdateCommand grouping) -- but
  # unlike those three, confirming an actor never opens anything: the toggle
  # happens right on the panel and focus falls straight back to the command
  # list (EasyRPG's UpdateActorSelection Row case ends with the same
  # SetActive/SetIndex(-1) every other case does).
  db = fake_db(rpg2003: true, menu_commands: [6])
  st = wrap_menu_state
  scene = menu_scene(RPG2k::Scene::Menu, st, db)
  hero, ally = st.party.actors
  eq Game::Battle::ROW_FRONT, hero.battle_row

  RGSS::Input.triggered = [RGSS::Input::C]  # Row -> actor-selection panel
  scene.update
  RGSS::Input.reset
  eq :actors, scene.instance_variable_get(:@focus), 'Row hands focus to the party-status panel'

  RGSS::Input.triggered = [RGSS::Input::C]  # confirm the first (highlighted) actor
  scene.update
  RGSS::Input.reset
  eq Game::Battle::ROW_BACK, hero.battle_row, 'the picked actor toggled to the back row'
  eq Game::Battle::ROW_FRONT, ally.battle_row, 'the other party member is untouched'
  ok scene.parent.pushed.empty?, 'no sub-scene opens for Row, unlike Skill/Equip/Status'
  eq :command, scene.instance_variable_get(:@focus),
     'focus returns to the command list after one toggle, not another pick'
end

check 'Scene::Menu: Order refuses a single-member party with the buzzer, ' \
      'no scene pushed' do
  # Confirmed against EasyRPG's own Scene_Menu::UpdateCommand's `Order`
  # branch, which gates on `GetActors().size() <= 1` rather than the plain
  # empty-party check every other command here uses -- reordering a single
  # member is meaningless.
  db = fake_db(rpg2003: true, menu_commands: [7])
  scene = menu_scene(RPG2k::Scene::Menu, menu_state, db) # menu_state: one actor
  scene.instance_variable_set(:@index, 0)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  ok scene.parent.pushed.empty?, 'nothing pushed for a one-member party'
end

# -- Scene::Order: RPG2003's party-reordering screen --------------------------
#
# Confirmed against EasyRPG Player's own `Scene_Order::UpdateOrder`/
# `UpdateConfirm`/`Redo`/`Confirm`: the player picks party members one at a
# time from a left column (building a right column in the picked order), then
# confirms or redoes the whole pick from a two-option prompt. This is *not* a
# swap or drag-drop -- see mruby-rpg2k/mrblib/scene/order.rb's own class
# comment.

def order_scene(state = order_state, db = fake_db)
  [RPG2k::Scene::Order.new(fake_parent(db), state), state]
end

check 'Scene::Order: picking a member moves them from the left column to ' \
      'the next right-column slot' do
  scene, = order_scene
  eq [nil, nil], scene.instance_variable_get(:@picked), 'nobody picked yet'
  RGSS::Input.triggered = [RGSS::Input::C] # pick cursor row 0 (Hero)
  scene.update
  RGSS::Input.reset
  eq [0, nil], scene.instance_variable_get(:@picked), 'index 0 picked into the first slot'
  eq 1, scene.instance_variable_get(:@counter)
  left_texts = window_texts(scene.instance_variable_get(:@left_window))
  ok !left_texts.include?('Hero'), 'the picked member\'s name disappears from the left column'
  ok left_texts.include?('Ally'), 'an unpicked member is still listed there'
  ok window_texts(scene.instance_variable_get(:@right_window)).include?('Hero'),
     'and appears in the right column'
end

check 'Scene::Order: re-picking an already-picked slot is rejected with ' \
      'the Cancel SE, not Decision' do
  scene, = order_scene
  RGSS::Input.triggered = [RGSS::Input::C] # pick row 0
  scene.update
  RGSS::Input.reset
  scene.instance_variable_set(:@cursor_index, 0) # land back on the now-picked row
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@counter), 'the duplicate pick did not register'
  eq 'Cancel1', RGSS::Audio.se_calls.last[0],
     'Scene_Order::UpdateOrder\'s own duplicate guard plays the Cancel SE'
end

check 'Scene::Order: Cancel undoes the most recent pick, one at a time' do
  scene, = order_scene
  RGSS::Input.triggered = [RGSS::Input::C] # pick row 0
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.reset
  eq [nil, nil], scene.instance_variable_get(:@picked), 'the pick was undone'
  eq 0, scene.instance_variable_get(:@counter)
  ok window_texts(scene.instance_variable_get(:@left_window)).include?('Hero'),
     'the undone member\'s name is back in the left column'
  ok scene.parent.pushed.empty? && !scene.parent.pop_called, 'still on this screen'
end

check 'Scene::Order: Cancel with nothing picked leaves the screen' do
  scene, = order_scene
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.reset
  ok scene.parent.pop_called, 'popped with no picks made yet'
end

check 'Scene::Order: picking every member opens the Confirm/Redo prompt, ' \
      'Confirm applies the new order to Game::Party#reorder and closes' do
  scene, state = order_scene
  RGSS::Input.triggered = [RGSS::Input::DOWN] # move onto the second (last) actor
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C] # pick index 1 first
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::UP] # back onto index 0
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C] # pick index 0 second
  scene.update
  RGSS::Input.reset
  eq :confirm, scene.instance_variable_get(:@focus), 'both picked -- prompt opens'
  eq 0, scene.instance_variable_get(:@confirm_index), 'defaults to Confirm'

  before = state.party.actors.map(&:object_id)
  RGSS::Input.triggered = [RGSS::Input::C] # confirm
  scene.update
  RGSS::Input.reset
  eq before.reverse, state.party.actors.map(&:object_id),
     'the party was reordered to the picked order (second actor first)'
  ok scene.parent.pop_called, 'the screen closes on Confirm'
end

check 'Scene::Order: Redo clears every pick and returns to the left column, ' \
      'without touching the party' do
  scene, state = order_scene
  original_order = state.party.actors.map(&:object_id)
  RGSS::Input.triggered = [RGSS::Input::C] # pick index 0
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::DOWN] # move onto the only unpicked row
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C] # pick index 1 -- both picked, prompt opens
  scene.update
  RGSS::Input.reset
  eq :confirm, scene.instance_variable_get(:@focus)

  RGSS::Input.triggered = [RGSS::Input::DOWN] # move onto "Redo"
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@confirm_index)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset

  eq :left, scene.instance_variable_get(:@focus), 'back to picking'
  eq [nil, nil], scene.instance_variable_get(:@picked), 'every pick cleared'
  eq 0, scene.instance_variable_get(:@counter)
  ok scene.parent.pushed.empty? && !scene.parent.pop_called, 'still on this screen'
  eq original_order, state.party.actors.map(&:object_id), 'the party is untouched'
end

# EasyRPG's Scene_Order::vUpdate (src/scene_order.cpp) calls window_left->
# Update()/window_confirm->Update() unconditionally, every frame -- both
# genuine Window_Selectables whose own Update() drives the cursor
# (trigger-then-repeat), before GetActive() ever gates which of
# UpdateOrder/UpdateConfirm runs. So both cursors here auto-repeat, unlike
# equip_menu.rb's/status_menu.rb's discrete-only actor switches.
# `RGSS::Input.repeated` (distinct from `.triggered`) lets this check hold
# a key across frames without it also reading as a fresh trigger.
check 'Scene::Order: holding Down auto-repeats both the left-column pick ' \
      'cursor and the Confirm/Redo prompt cursor' do
  scene, = order_scene
  RGSS::Input.repeated = [RGSS::Input::DOWN] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@cursor_index),
     'a held (repeated, not triggered) Down still moves the pick cursor one row'

  scene.instance_variable_set(:@cursor_index, 0)
  RGSS::Input.triggered = [RGSS::Input::C] # pick Hero
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::DOWN] # onto the only unpicked row
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C] # pick Ally -- both picked, prompt opens
  scene.update
  RGSS::Input.reset
  eq :confirm, scene.instance_variable_get(:@focus)
  eq 0, scene.instance_variable_get(:@confirm_index), 'defaults to Confirm'

  RGSS::Input.repeated = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@confirm_index),
     'a held (repeated, not triggered) Down still flips the prompt cursor to Redo'
end

# -- Scene::SaveLoad: the save/load file-select screen -------------------------
#
# Scene::Menu's Save command and Scene::Title's Continue entry both used to
# act on a single hardcoded slot directly; they now push this screen (in
# :save / :load mode respectively) so the player picks from all
# RPG2k::MAX_SAVE_SLOTS slots instead (ADR 0045). See the Continue checks
# above for the title-screen half of this wiring.

check 'Scene::Menu: choosing Save opens Scene::SaveLoad in :save mode' do
  st = wrap_menu_state
  scene = menu_scene(RPG2k::Scene::Menu, st)
  scene.instance_variable_set(:@index, 3) # Save, in RPG2K_COMMAND_KEYS order
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  pushed = scene.parent.pushed.last
  ok pushed.is_a?(RPG2k::Scene::SaveLoad), "Save pushes Scene::SaveLoad, got #{pushed.class}"
  eq :save, pushed.instance_variable_get(:@mode), 'opened in :save mode'
  eq st, pushed.instance_variable_get(:@state), 'carrying the running game state to write out'
end

check 'Scene::Menu: Save access forbidden refuses the selection silently, no message' do
  # Confirmed against EasyRPG's own Scene_Menu::UpdateCommand: a disabled
  # Save command just refuses the selection (plays a buzzer SE this engine
  # does not yet model any menu SE for), no message of any kind -- unlike
  # this screen's old hardcoded English "You cannot save right now.".
  st = wrap_menu_state
  st.save_access = false
  scene = menu_scene(RPG2k::Scene::Menu, st)
  scene.instance_variable_set(:@index, 3)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  ok scene.parent.pushed.empty?, 'no picker opens while save access is off'
  ok scene.instance_variable_get(:@message).nil?, 'no message shown at all'
end

def save_load_scene(mode, state = nil, db = fake_db, parent: nil)
  parent ||= fake_parent(db)
  [RPG2k::Scene::SaveLoad.new(parent, state, mode), parent]
end

check 'Scene::SaveLoad: an empty slot shows only the file label, no placeholder text' do
  # Confirmed against genuine RPG_RT under wine: each slot is its own box
  # (file label / leader name / level+HP), and an empty one draws only the
  # label line -- no "No Data" text at all, unlike this screen's old
  # single-list-window layout.
  scene, = save_load_scene(:load)
  texts = window_texts(scene.instance_variable_get(:@slot_windows)[0])
  ok texts.include?('File 1'), 'slot 1 is labelled with a plain, non-zero-padded number'
  ok !texts.any? { |t| t.include?('No Data') }, 'no placeholder text for an empty slot'
end

check 'Scene::SaveLoad: an occupied slot shows the leader, level and HP -- no gold or map' do
  st = menu_state
  st.party.leader = st.party.actors.first # Hero, Lv5, 80/120 HP (MenuStubActor)
  st.party.instance_variable_set(:@gold, 250)
  parent = fake_parent(fake_db)
  parent.save_states[1] = st
  scene, = save_load_scene(:load, nil, fake_db, parent: parent)
  texts = window_texts(scene.instance_variable_get(:@slot_windows)[0])
  ok texts.include?('Hero'), 'the leader name gets its own line'
  ok texts.any? { |t| t.include?('Lv5') && t.include?('HP80') },
     'level and current HP together on the third line'
  ok !texts.any? { |t| t.include?('250G') }, 'no gold shown -- confirmed absent from the ' \
                                              'reference capture, unlike this screen\'s old layout'
end

# EasyRPG's Window_SaveFile::Refresh (src/window_savefile.cpp) draws every
# text element through TextDraw(x, y, fc, text) -- never a flat colour --
# with `fc` itself `has_save ? Font::ColorDefault : Font::ColorDisabled`
# (system-colour swatch index 0 or 3, src/font.h) for the file label. The
# same disabled-swatch convention Scene::Title's own Continue entry already
# reads (see the title checks above).
check 'Scene::SaveLoad: an empty slot\'s file label blends from the windowskin\'s ' \
      'own disabled-colour swatch (index 3); an occupied slot\'s uses the default ' \
      '(index 0)' do
  db = fake_db
  db.system.system_graphic = 'Skin1' # non-empty -> a real (fixture) windowskin loads
  st = menu_state
  st.party.leader = st.party.actors.first
  parent = fake_parent(db)
  parent.save_states[1] = st # slot 1 (window index 0) occupied; slot 2 (index 1) stays empty
  scene, = save_load_scene(:load, nil, nil, parent: parent)
  occupied_bc = scene.instance_variable_get(:@slot_windows)[0].contents.blend_calls || []
  empty_bc = scene.instance_variable_get(:@slot_windows)[1].contents.blend_calls || []
  # colour idx -> swatch cell (idx%10*16, idx/10*16+48): 0 -> (0, 48), 3 -> (48, 48).
  ok occupied_bc.any? { |call| call[6] == 0 && call[7] == 48 },
     "the occupied slot's label blends from swatch index 0 (the default)"
  ok empty_bc.any? { |call| call[6] == 48 && call[7] == 48 },
     "the empty slot's label blends from swatch index 3 (disabled), not the default"
end

check 'Scene::SaveLoad: an occupied slot draws each party member\'s own face thumbnail, ' \
      'right-anchored in seat order' do
  # Game::State#to_lsd already exports up to four faceset_name/faceset_index
  # pairs into the save's title chunk for a real RPG_RT to show (see
  # docs/TODO.md); this screen used to read none of it back.
  st = wrap_menu_state # WrapMenuParty: two MenuStubActor members
  st.party.actors[0].faceset_name = 'Faces1'
  st.party.actors[0].faceset_index = 2 # third cell: x=96, y=0
  st.party.actors[1].faceset_name = 'Faces2'
  st.party.actors[1].faceset_index = 5 # sixth cell: x=48, y=48
  st.party.leader = st.party.actors.first
  parent = fake_parent(fake_db)
  parent.save_states[1] = st
  scene, = save_load_scene(:load, nil, fake_db, parent: parent)
  contents = scene.instance_variable_get(:@slot_windows)[0].contents
  calls = contents.blt_calls
  eq 2, calls.length, 'one face thumbnail blitted per party member'

  x0, y0, cell0, rect0 = calls[0]
  eq [80, 0, 0, 0, 48, 48], [x0, y0, rect0.x, rect0.y, rect0.width, rect0.height],
     'first member lands at the box\'s own right-anchored start (304 - 4*56)'
  eq [[0, 0, 96, 0, 48, 48]],
     cell0.blt_calls.map { |cx, cy, _s, r| [cx, cy, r.x, r.y, r.width, r.height] },
     'cropped straight from Faces1 cell 2 (x=96,y=0), no scaling'

  x1, y1, cell1, rect1 = calls[1]
  eq [136, 0, 0, 0, 48, 48], [x1, y1, rect1.x, rect1.y, rect1.width, rect1.height],
     'second member sits one 56px pitch to the right of the first'
  eq [[0, 0, 48, 48, 48, 48]],
     cell1.blt_calls.map { |cx, cy, _s, r| [cx, cy, r.x, r.y, r.width, r.height] },
     'cropped from Faces2 cell 5 (x=48,y=48), the sheet\'s second row'
end

check 'Scene::SaveLoad: a member with no FaceSet draws no thumbnail; only the first four ' \
      'members ever draw one' do
  st = wrap_menu_state
  st.party.actors[0].faceset_name = '' # blank name -- no face set for this member
  st.party.actors[1].faceset_name = 'Faces2'
  st.party.actors[1].faceset_index = 0
  3.times { st.party.actors << MenuStubActor.new } # 5 members total
  st.party.actors[2].faceset_name = 'Faces3'
  st.party.actors[3].faceset_name = 'Faces4'
  st.party.actors[4].faceset_name = 'Faces5' # a 5th member, never drawn
  st.party.leader = st.party.actors.first
  parent = fake_parent(fake_db)
  parent.save_states[1] = st
  scene, = save_load_scene(:load, nil, fake_db, parent: parent)
  contents = scene.instance_variable_get(:@slot_windows)[0].contents
  eq 3, contents.blt_calls.length,
     'the blank-named first member is skipped, and a 5th member never gets a slot -- ' \
     'only members 2/3/4 (of 5) draw a face'
end

check 'Scene::SaveLoad :save mode: confirming a slot saves through the parent, shows a ' \
      'message, and returns to the menu once dismissed' do
  st = wrap_menu_state
  scene, parent = save_load_scene(:save, st)
  RGSS::Input.triggered = [RGSS::Input::C] # confirm slot 1
  scene.update
  RGSS::Input.reset
  eq [[st, 1]], parent.saved, 'RPG2k#save_game was called for slot 1 with the running state'
  ok window_texts(scene.instance_variable_get(:@message)[:window]).include?('Game saved.'),
     'the confirmation banner shows'
  ok parent.pop_called.nil?, 'the screen has not popped back to the menu yet -- the ' \
                             'banner is still up'
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the banner
  scene.update
  RGSS::Input.reset
  eq 1, parent.pop_called, 'dismissing the banner pops back to the menu'
end

check 'Scene::SaveLoad :save mode: a failed save shows "Save failed." instead' do
  st = wrap_menu_state
  parent = fake_parent(fake_db)
  parent.save_ok = false
  scene, = save_load_scene(:save, st, fake_db, parent: parent)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  ok window_texts(scene.instance_variable_get(:@message)[:window]).include?('Save failed.'),
     'the failure banner shows instead of the success one'
end

check 'Scene::SaveLoad :load mode: an empty slot ignores the selection key' do
  scene, parent = save_load_scene(:load)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq 0, parent.continue_calls.length, 'no continue_game call for an empty slot'
end

check 'Scene::SaveLoad :load mode: confirming an occupied slot resumes it' do
  st = menu_state
  parent = fake_parent(fake_db)
  parent.save_states[1] = st
  scene, = save_load_scene(:load, nil, fake_db, parent: parent)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq [1], parent.continue_calls, 'RPG2k#continue_game was called for the confirmed slot'
end

check 'Scene::SaveLoad: Down/Up move and wrap across all MAX_SAVE_SLOTS' do
  scene, = save_load_scene(:load)
  RPG2k::MAX_SAVE_SLOTS.times do
    RGSS::Input.triggered = [RGSS::Input::DOWN]
    scene.update
    RGSS::Input.reset
  end
  eq 0, scene.instance_variable_get(:@index), 'DOWN pressed MAX_SAVE_SLOTS times wraps back to 0'
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq RPG2k::MAX_SAVE_SLOTS - 1, scene.instance_variable_get(:@index),
     'UP from slot 1 wraps to the last slot'
end

# EasyRPG's Window_Selectable::Update (src/window_selectable.cpp) falls
# through to Input::IsRepeated(DOWN/UP) right after its own IsTriggered
# check, so holding a direction auto-scrolls the cursor after the initial
# delay, not just once per tap. `RGSS::Input.repeated` (distinct from
# `.triggered`, mirroring the real engine's own separate trigger/repeat
# signals) lets this check hold a key across frames without it also reading
# as a fresh trigger, exercising the `#repeat?` half of the gate on its own.
check 'Scene::SaveLoad: holding Down auto-repeats the cursor, not just a ' \
      'single step per tap' do
  scene, = save_load_scene(:load)
  RGSS::Input.repeated = [RGSS::Input::DOWN] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@index),
     'a held (repeated, not triggered) Down still moves the cursor one slot'
end

check 'Scene::SaveLoad: cancelling (B) pops back without touching the parent app' do
  scene, parent = save_load_scene(:load)
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.reset
  eq 1, parent.pop_called, 'B pops the screen'
  eq 0, parent.pushed.size, 'and never pushes another scene'
  eq [], parent.continue_calls, 'or resumes anything'
end

# The scroll indicator: two independent blinking arrow sprites, not a
# scrollbar -- see the class comment above Scene::SaveLoad::VISIBLE_SLOTS.
# Confirmed against EasyRPG's own Scene_File (MakeArrowSprite/UpdateArrows).
check 'Scene::SaveLoad: at the top of the list, only the down arrow can show, ' \
      'blinking on a 20-frame cycle' do
  scene, = save_load_scene(:load)
  up = scene.instance_variable_get(:@up_arrow)
  down = scene.instance_variable_get(:@down_arrow)
  ok !up.visible, 'no slot is hidden above the first, so the up arrow starts hidden'
  ok down.visible, 'more slots are hidden below, so the down arrow starts on'
  19.times { RGSS::Input.triggered = []; scene.update }
  ok down.visible, 'still on 19 frames into the 20-frame "on" half'
  RGSS::Input.triggered = []
  scene.update
  ok !down.visible, 'the 20th frame flips it to the "off" half of the blink'
  ok !up.visible, 'the up arrow never turns on while still at the top'
end

check 'Scene::SaveLoad: scrolled to the bottom, only the up arrow can show' do
  scene, = save_load_scene(:load)
  (RPG2k::MAX_SAVE_SLOTS - 1).times do
    RGSS::Input.triggered = [RGSS::Input::DOWN]
    scene.update
    RGSS::Input.reset
  end
  up = scene.instance_variable_get(:@up_arrow)
  down = scene.instance_variable_get(:@down_arrow)
  eq RPG2k::MAX_SAVE_SLOTS - 1, scene.instance_variable_get(:@index),
     'moved all the way down to the last slot'
  ok up.visible, 'slots are hidden above the now-scrolled viewport'
  ok !down.visible, 'the last slot is on screen, nothing hidden below'
end

# -- Open Save Menu / Open Load Menu (event commands) driving the same picker --
#
# RPG2003's Open Save Menu (11910) and Open Load Menu (5001) event commands
# open this same Scene::SaveLoad picker rather than acting on a single slot
# directly, mirroring Open Main Menu's own push-and-wait-for-it-to-close shape
# (Scene::Map#perform_event_menu, `@event_menu`) via a matching
# `@event_save_load` flag -- see the two checks named "... pushes the field
# menu and resumes when it closes" above for the twin of this pattern. Timing
# note: opening the picker costs two frames (one to raise the wait, one for
# #drive_event to dispatch it and push the scene) and resuming costs two more
# (one to see the picker already open and resume, one for the interpreter to
# actually run the command after Open Save/Load Menu) -- four `scene.update`
# calls end to end, with the picker's own interaction happening in between (it
# runs independently of `scene`'s own frame count in this fixture, since
# FakeParent#push only records the pushed Scene::SaveLoad instance rather than
# modelling a real, shared scene stack).

check 'Open Save Menu pushes Scene::SaveLoad in :save mode and resumes the event ' \
      'once it closes' do
  cmds = [ECmd.new(IC2::OPEN_SAVE_MENU, []), add_var_cmd(7)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  scene.instance_variable_get(:@interpreter).start(cmds)
  scene.update # runs the command and raises the :save_menu wait
  scene.update # the wait opens the picker
  eq 1, parent.pushed.length, 'the save/load picker was pushed exactly once'
  pushed = parent.pushed.first
  ok pushed.is_a?(RPG2k::Scene::SaveLoad), "pushed Scene::SaveLoad, got #{pushed.class}"
  eq :save, pushed.instance_variable_get(:@mode), 'opened in :save mode'
  eq st, pushed.instance_variable_get(:@state), 'carrying the running game state to write out'
  eq 0, st.variables[7], 'the event is paused while the picker is open'
  scene.update # back from the picker: the wait is released...
  scene.update # ...and the next frame runs the rest of the event
  eq 1, st.variables[7], 'the event resumed after the picker closed'
end

# EasyRPG's `Game_Interpreter_Map::CommandOpenSaveMenu`
# (src/game_interpreter_map.cpp) is gated only on
# `Game_Message::IsMessageActive()`, no `main_flag` restriction, so a
# Parallel Process can trigger it exactly like the foreground can. Before
# this fix, `Scene::Map#drive_parallel_wait` had no `:save_menu` branch, so
# it fell into the generic "background: resume" default and a Parallel
# Process's own Open Save Menu silently never opened the picker at all.
check 'Open Save Menu issued from a Parallel Process also pushes the save picker' do
  par = page(trigger: 4) # Parallel Process
  par.event_commands = [ECmd.new(IC2::OPEN_SAVE_MENU, []), add_var_cmd(7)]
  scene = new_scene({ 1 => event(2, 2, par) }, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  2.times { scene.update } # raises the :save_menu wait, then opens the picker
  eq 1, parent.pushed.length,
     'the save/load picker was pushed for a Parallel-Process-issued command'
  pushed = parent.pushed.first
  ok pushed.is_a?(RPG2k::Scene::SaveLoad), "pushed Scene::SaveLoad, got #{pushed.class}"
  eq :save, pushed.instance_variable_get(:@mode), 'opened in :save mode'
  eq 0, st.variables[7], 'the process is paused while the picker is open'
  2.times { scene.update } # back from the picker: the wait releases, then the process continues
  eq 1, st.variables[7], 'the process resumed after the picker closed'
end

check 'Open Save Menu: confirming a slot in the pushed picker really saves through ' \
      'the app' do
  cmds = [ECmd.new(IC2::OPEN_SAVE_MENU, []), add_var_cmd(7)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  scene.instance_variable_get(:@interpreter).start(cmds)
  2.times { scene.update } # raises the :save_menu wait, then opens the picker
  picker = parent.pushed.first
  RGSS::Input.triggered = [RGSS::Input::C] # confirm slot 1
  picker.update
  RGSS::Input.reset
  eq [[st, 1]], parent.saved, 'RPG2k#save_game was called for slot 1 with the running state'
  ok window_texts(picker.instance_variable_get(:@message)[:window]).include?('Game saved.'),
     'the picker shows its own confirmation banner'
  RGSS::Input.triggered = [RGSS::Input::C] # dismiss the banner
  picker.update
  RGSS::Input.reset
  eq 1, parent.pop_called, 'the picker popped itself once dismissed'
end

check 'Open Save Menu ignores a Change Save Access lock -- unlike Scene::Menu\'s ' \
      'own Save command, the event-triggered picker still opens' do
  # Ported from a real bug: Nepheshel's own save-point event (a Crystal Gate,
  # map 12) sits on a map the map tree flags Save-forbidden
  # (Game::MapAccess::TRISTATE_FORBID) -- "save only at a gate" is exactly the
  # design that relies on Open Save Menu bypassing that flag, the same way
  # perform_event_menu's Open Main Menu ignores Change Main Menu Access. The
  # old version of this check asserted the *opposite* (no picker while access
  # is locked) and was itself wrong -- it passed against the pre-fix code,
  # which is exactly why the real event never opened anything in Nepheshel.
  cmds = [ECmd.new(IC2::OPEN_SAVE_MENU, []), add_var_cmd(8)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  st.save_access = false
  scene.instance_variable_get(:@interpreter).start(cmds)
  2.times { scene.update } # raises the :save_menu wait, then opens the picker
  eq 1, parent.pushed.length, 'the picker opens even though save_access is false'
  pushed = parent.pushed.first
  ok pushed.is_a?(RPG2k::Scene::SaveLoad), "pushed Scene::SaveLoad, got #{pushed.class}"
  eq :save, pushed.instance_variable_get(:@mode), 'opened in :save mode'
  eq 0, st.variables[8], 'the event stays paused while the picker is open'
  2.times { scene.update } # back from the picker: the wait releases, then the event continues
  eq 1, st.variables[8], 'the event resumed and continued past Open Save Menu'
end

check 'Open Load Menu pushes Scene::SaveLoad in :load mode' do
  cmds = [ECmd.new(IC2::OPEN_LOAD_MENU, []), add_var_cmd(9)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  scene.instance_variable_get(:@interpreter).start(cmds)
  scene.update # raises the :load_menu wait
  scene.update # opens the picker
  eq 1, parent.pushed.length, 'the save/load picker was pushed exactly once'
  pushed = parent.pushed.first
  ok pushed.is_a?(RPG2k::Scene::SaveLoad), "pushed Scene::SaveLoad, got #{pushed.class}"
  eq :load, pushed.instance_variable_get(:@mode), 'opened in :load mode'
  eq 0, st.variables[9], 'the event is paused while the picker is open'
end

check 'Open Load Menu: cancelling the picker resumes the event -- unlike the old ' \
      'single-slot version, a cancelled load does not abandon it' do
  cmds = [ECmd.new(IC2::OPEN_LOAD_MENU, []), add_var_cmd(9)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  scene.instance_variable_get(:@interpreter).start(cmds)
  2.times { scene.update } # raises the wait, then opens the picker
  picker = parent.pushed.first
  RGSS::Input.triggered = [RGSS::Input::B]
  picker.update
  RGSS::Input.reset
  eq 1, parent.pop_called, 'the picker popped itself on cancel'
  eq [], parent.continue_calls, 'nothing was loaded'
  # Same two frames "opening" took: one for #drive_event to see the picker
  # already up and resume, one more for the interpreter to actually run the
  # command after Open Load Menu.
  2.times { scene.update }
  eq 1, st.variables[9], 'the event resumed rather than being abandoned'
end

check 'Open Load Menu: confirming an occupied slot resumes the app through continue_game' do
  cmds = [ECmd.new(IC2::OPEN_LOAD_MENU, []), add_var_cmd(9)]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  parent.save_states[3] = menu_state
  scene.instance_variable_get(:@interpreter).start(cmds)
  2.times { scene.update } # raises the wait, then opens the picker
  picker = parent.pushed.first
  # Slot 3 has data (the other 14 are empty); move the cursor onto it and confirm.
  picker.instance_variable_set(:@index, 2)
  RGSS::Input.triggered = [RGSS::Input::C]
  picker.update
  RGSS::Input.reset
  eq [3], parent.continue_calls, 'RPG2k#continue_game was called for the confirmed slot'
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

check 'Scene::ItemMenu: the item grid cursor does not wrap, the target cursor does' do
  scene = menu_scene(RPG2k::Scene::ItemMenu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@item_index), 'starts on the first item'
  # The item list is a two-column grid (confirmed against genuine RPG_RT
  # under wine, see Scene::ItemMenu::COLUMN_MAX): with only two items, both
  # sit in the same row, so UP/DOWN have no cell to move to and RPG_RT
  # leaves the cursor put rather than wrapping -- unlike the flat
  # actor-target list below, which does wrap.
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@item_index), 'Up from the first item is a no-op (nothing above it)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@item_index), 'Down from the first item is a no-op (nothing below it)'
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@item_index), 'Right moves onto the second item, same row'
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@item_index), 'Right again is a no-op (row edge)'
  RGSS::Input.triggered = [RGSS::Input::LEFT]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@item_index), 'Left moves back onto the first item'

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

# EasyRPG's Window_Selectable::Update (the base every real RPG2000 list is
# built on) falls through to Input::IsRepeated for all four directions
# right after its own IsTriggered check, so holding a direction
# auto-repeats the cursor after the initial delay -- see Scene::SaveLoad's
# identical fix for the fuller writeup. `RGSS::Input.repeated` (distinct
# from `.triggered`) lets this check hold a key across frames without it
# also reading as a fresh trigger, exercising the `#repeat?` half of the
# gate on its own.
check 'Scene::ItemMenu: holding Right auto-repeats the item grid cursor, and ' \
      'holding Down auto-repeats the actor-target cursor' do
  scene = menu_scene(RPG2k::Scene::ItemMenu, wrap_menu_state)
  RGSS::Input.repeated = [RGSS::Input::RIGHT] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@item_index),
     'a held (repeated, not triggered) Right still moves the item cursor one cell'

  scene.send(:prompt_item_target, 1)
  RGSS::Input.repeated = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@target_index),
     'a held (repeated, not triggered) Down still moves the target cursor one step'
end

# A party whose only item is a switch (type 10) one -- Game::Party's own
# decision logic (#use_switch_item) is covered by scripts/rpg2k_logic_check.rb;
# this stub only has to hand the scene something that behaves the same way, so
# the checks below stay about the RGSS wiring (does using it actually flip the
# switch, consume one, and close the menu stack?).
class SwitchItemStubParty < MenuStubParty
  SWITCH_ID = 60
  ITEM_SWITCH_ID = 77

  attr_reader :use_switch_item_calls

  def initialize
    super
    @use_switch_item_calls = []
  end

  def field_items(_state = nil); [[SWITCH_ID, 1]]; end

  def db_item(id)
    return nil unless id == SWITCH_ID
    OpenStruct.new(name: 'Whistle', type: Game::Party::ITEM_SWITCH, switch_id: ITEM_SWITCH_ID)
  end

  def use_switch_item(id)
    return nil unless id == SWITCH_ID
    @use_switch_item_calls << id
    ITEM_SWITCH_ID
  end
end

check 'Scene::ItemMenu: a switch item flips its switch, consumes one, and closes ' \
      'the whole menu stack, with no confirmation message' do
  parent = fake_parent(fake_db)
  state = Game::State.new(SwitchItemStubParty.new, 1, 0, 0)
  scene = RPG2k::Scene::ItemMenu.new(parent, state)
  RGSS::Input.triggered = [RGSS::Input::C] # confirm the only item
  scene.update
  RGSS::Input.reset
  eq [SwitchItemStubParty::SWITCH_ID], state.party.use_switch_item_calls, 'exactly one use, consuming one'
  ok state.switches[SwitchItemStubParty::ITEM_SWITCH_ID], 'the switch is turned on'
  ok parent.pop_to_map_called, 'the whole menu stack closes rather than staying open'
  ok scene.instance_variable_get(:@message).nil?, 'no confirmation message, matching Escape/Teleport'
end

check 'Scene::ItemMenu: a switch item that consumed nothing reports "no effect" and ' \
      'leaves the menu open' do
  parent = fake_parent(fake_db)
  state = Game::State.new(SwitchItemStubParty.new, 1, 0, 0)
  scene = RPG2k::Scene::ItemMenu.new(parent, state)
  scene.send(:apply_switch_item, 999) # not a switch item this stub recognises -- #use_switch_item returns nil
  ok state.party.use_switch_item_calls.empty?, 'nothing consumed'
  ok !parent.pop_to_map_called, 'the menu stays open'
  ok !scene.instance_variable_get(:@message).nil?, 'a message is shown'
end

# A party whose only item is a special (type 9) one invoking an all-ally scope
# skill -- Game::Party's own decision logic (#use_special_item /
# #field_usable?) is covered by scripts/rpg2k_logic_check.rb; this stub only
# has to hand the scene something that behaves the same way, so the check
# below stays about the RGSS wiring (does confirming the item actually cast
# it, and who as?) rather than repeating that coverage under RGSS stubs.
class SpecialItemStubParty < MenuStubParty
  SPECIAL_ID = 40

  attr_reader :use_item_calls

  def initialize
    super
    @use_item_calls = []
  end

  def leader; @actors.first; end
  def field_items(_state = nil); [[SPECIAL_ID, 3]]; end

  def db_item(id)
    return nil unless id == SPECIAL_ID
    OpenStruct.new(name: 'Vial', type: Game::Party::ITEM_SPECIAL, skill_id: 90)
  end

  def db_skill(id)
    return nil unless id == 90
    OpenStruct.new(name: 'Heal All', type: 0, scope: 4) # an all-ally skill
  end

  # `actor` here is the *caster* #use_special_item casts the skill from (see
  # the class comment above), not a chosen target -- recorded so the check
  # can tell a real actor from the nil the pre-fix scene passed.
  def use_item(id, actor = nil)
    @use_item_calls << [id, actor]
    actor ? [actor] : []
  end
end

check 'Scene::ItemMenu: an all-ally special item is cast by the party leader, ' \
      'not left uncastable with no actor at all' do
  st = Game::State.new(SpecialItemStubParty.new, 1, 0, 0)
  scene = menu_scene(RPG2k::Scene::ItemMenu, st)
  RGSS::Input.triggered = [RGSS::Input::C] # confirm the only item -- no target prompt
  scene.update
  RGSS::Input.reset
  eq [[SpecialItemStubParty::SPECIAL_ID, st.party.leader]], st.party.use_item_calls,
     'the party leader casts it, rather than a nil actor #use_special_item rejects outright'
end

# A party whose only item is an *equipment* item (type 1) flagged `use_skill`
# (schema field 71) invoking an all-ally scope skill -- the same "item triggers
# a skill" shape a type-9 special item already gets in #choose_item, just gated
# on a flag instead of a dedicated type. #choose_item used to send every
# equipment item (use_skill or not) down the generic "prompt for a target"
# branch, so a self/all-ally-scope use_skill weapon asked for a target it did
# not need -- this check pins the now-symmetric dispatch. Game::Party's own
# decision logic (#field_usable? / #use_equip_skill_item) is covered by
# scripts/rpg2k_logic_check.rb; the stub only has to hand the scene something
# that behaves the same way, so this stays about the RGSS wiring.
class EquipUseSkillItemStubParty < MenuStubParty
  EQUIP_ID = 60

  attr_reader :use_item_calls

  def initialize
    super
    @use_item_calls = []
  end

  def leader; @actors.first; end
  def field_items(_state = nil); [[EQUIP_ID, 1]]; end

  def db_item(id)
    return nil unless id == EQUIP_ID
    OpenStruct.new(name: 'Holy Blade', type: Game::Actor::ITEM_WEAPON, use_skill: true, skill_id: 95)
  end

  def db_skill(id)
    return nil unless id == 95
    OpenStruct.new(name: 'Bless All', type: 0, scope: 4) # an all-ally skill
  end

  def use_item(id, actor = nil)
    @use_item_calls << [id, actor]
    actor ? [actor] : []
  end
end

check 'Scene::ItemMenu: a use_skill equipment item is cast like a special item ' \
      '(all-ally scope needs no target prompt, leader is the caster)' do
  st = Game::State.new(EquipUseSkillItemStubParty.new, 1, 0, 0)
  scene = menu_scene(RPG2k::Scene::ItemMenu, st)
  RGSS::Input.triggered = [RGSS::Input::C] # confirm the only item -- no target prompt
  scene.update
  RGSS::Input.reset
  eq [[EquipUseSkillItemStubParty::EQUIP_ID, st.party.leader]], st.party.use_item_calls,
     'the leader casts it, exactly as a type-9 special item of the same scope would'
end

# A party whose only item is a special (type 9) one invoking either an Escape
# or a Teleport skill -- Game::Party's own decision logic
# (#field_usable? / #use_special_escape_item / #use_special_teleport_item) is
# covered by scripts/rpg2k_logic_check.rb; this stub only has to hand the
# scene something that behaves the same way, mirroring
# EscapeTeleportStubParty below for Scene::SkillMenu, so these checks stay
# about the RGSS wiring (does confirming the item actually warp the party and
# close the menu stack?) rather than repeating that coverage under RGSS stubs.
class EscapeTeleportItemStubParty < MenuStubParty
  ESCAPE_ID = 50
  TELEPORT_ID = 51

  def field_items(state = nil)
    return [] unless state
    rows = []
    rows << [ESCAPE_ID, 1] if state.escape_access && state.escape_target
    rows << [TELEPORT_ID, 1] if state.teleport_access && !state.teleport_targets.empty?
    rows
  end

  def db_item(id)
    case id
    when ESCAPE_ID
      OpenStruct.new(name: 'Escape Scroll', type: Game::Party::ITEM_SPECIAL, skill_id: 30)
    when TELEPORT_ID
      OpenStruct.new(name: 'Warp Scroll', type: Game::Party::ITEM_SPECIAL, skill_id: 31)
    end
  end

  def db_skill(id)
    case id
    when 30 then OpenStruct.new(name: 'Escape', type: Game::Party::SKILL_ESCAPE)
    when 31 then OpenStruct.new(name: 'Warp', type: Game::Party::SKILL_TELEPORT)
    end
  end

  def use_special_escape_item(id, _actor, state)
    return nil unless id == ESCAPE_ID && state.escape_target
    state.escape_target
  end

  def use_special_teleport_item(id, _actor, state, map_id)
    return nil unless id == TELEPORT_ID
    target = state.teleport_targets[map_id]
    return nil unless target
    { map_id: map_id, x: target[:x], y: target[:y] }
  end
end

def escape_teleport_item_state
  st = Game::State.new(EscapeTeleportItemStubParty.new, 1, 0, 0)
  st.escape_access = true
  st.escape_target = { map_id: 9, x: 1, y: 2, switch_id: nil }
  st.teleport_access = true
  st.teleport_targets[10] = { x: 11, y: 12, switch_id: nil }
  st.teleport_targets[20] = { x: 21, y: 22, switch_id: nil }
  st
end

check 'Scene::ItemMenu: a special item invoking Escape queues its target and ' \
      'closes the menu, with no confirmation message' do
  parent = fake_parent(fake_db)
  state = escape_teleport_item_state
  scene = RPG2k::Scene::ItemMenu.new(parent, state)
  eq [[EscapeTeleportItemStubParty::ESCAPE_ID, 1],
      [EscapeTeleportItemStubParty::TELEPORT_ID, 1]], scene.send(:items)
  RGSS::Input.triggered = [RGSS::Input::C]           # confirm the first row, Escape
  scene.update
  RGSS::Input.reset
  eq [9, 1, 2, 0], state.pending_teleport, 'queued straight from the one registered escape target'
  ok parent.pop_to_map_called, 'the whole menu stack closes rather than staying open'
  ok scene.instance_variable_get(:@message).nil?, 'no "Used on ..." message, matching Scene::SkillMenu'
end

check 'Scene::ItemMenu: a special item invoking Teleport opens a destination ' \
      'list and queues the chosen one' do
  parent = fake_parent(fake_db)
  state = escape_teleport_item_state
  scene = RPG2k::Scene::ItemMenu.new(parent, state)
  # The item list is a two-column grid (confirmed against genuine RPG_RT
  # under wine): with only two items, the second sits beside the first in
  # the same row, reached by RIGHT rather than DOWN.
  RGSS::Input.triggered = [RGSS::Input::RIGHT]       # move onto the Teleport item
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]           # confirm -- opens the destination list
  scene.update
  RGSS::Input.reset
  eq :teleport_target, scene.instance_variable_get(:@mode)
  eq [[10, 'Map 10'], [20, 'Map 20']], scene.send(:teleport_targets),
     'both registered destinations, ascending by map id (this fixture parent carries no map tree)'
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

check 'Scene::ItemMenu: cancelling the Teleport destination list returns to the item list' do
  parent = fake_parent(fake_db)
  state = escape_teleport_item_state
  scene = RPG2k::Scene::ItemMenu.new(parent, state)
  RGSS::Input.triggered = [RGSS::Input::RIGHT]       # move onto the Teleport item (see the grid test above)
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :teleport_target, scene.instance_variable_get(:@mode)
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  RGSS::Input.reset
  eq :items, scene.instance_variable_get(:@mode)
  ok state.pending_teleport.nil?
  ok !parent.pop_to_map_called
end

check 'Scene::SkillMenu: the skill grid cursor does not wrap, caster is fixed, ' \
      'the target cursor does wrap' do
  scene = menu_scene(RPG2k::Scene::SkillMenu, wrap_menu_state)
  eq 0, scene.instance_variable_get(:@skill_index), 'starts on the first skill'
  # The skill list is a two-column grid (confirmed against EasyRPG's own
  # Window_Skill, see Scene::SkillMenu::COLUMN_MAX): with only two skills,
  # both sit in the same row, so UP/DOWN have no cell to move to.
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@skill_index), 'Up from the first skill is a no-op (nothing above it)'
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@skill_index), 'Down from the first skill is a no-op (nothing below it)'
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@skill_index), 'Right moves onto the second skill, same row'
  RGSS::Input.triggered = [RGSS::Input::LEFT]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@skill_index), 'Left moves back onto the first skill'

  # There is no way to switch caster inside this screen -- confirmed
  # against EasyRPG's own Scene_Skill, whose actor_index is fixed at
  # construction (see the class comment); LEFT/RIGHT above are grid
  # navigation now, not a caster switch.
  eq 0, scene.instance_variable_get(:@caster_index), 'caster stays fixed regardless of LEFT/RIGHT'

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

# See Scene::ItemMenu's identical check for the fuller writeup
# (Window_Selectable::Update falls through to Input::IsRepeated for all
# four directions right after IsTriggered). `RGSS::Input.repeated`
# (distinct from `.triggered`) lets this check hold a key across frames
# without it also reading as a fresh trigger.
check 'Scene::SkillMenu: holding Right auto-repeats the skill grid cursor, and ' \
      'holding Down auto-repeats the actor-target cursor' do
  scene = menu_scene(RPG2k::Scene::SkillMenu, wrap_menu_state)
  RGSS::Input.repeated = [RGSS::Input::RIGHT] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@skill_index),
     'a held (repeated, not triggered) Right still moves the skill cursor one cell'

  scene.instance_variable_set(:@mode, :target)
  scene.instance_variable_set(:@target_index, 0)
  scene.send(:build_target_window)
  RGSS::Input.repeated = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@target_index),
     'a held (repeated, not triggered) Down still moves the target cursor one step'
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
  # The skill list is a two-column grid (confirmed against EasyRPG's own
  # Window_Skill, see Scene::SkillMenu::COLUMN_MAX): with only two skills,
  # the second sits beside the first in the same row, reached by RIGHT.
  RGSS::Input.triggered = [RGSS::Input::RIGHT]       # move onto Teleport
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
  # The skill list is a two-column grid (confirmed against EasyRPG's own
  # Window_Skill, see Scene::SkillMenu::COLUMN_MAX): with only two skills,
  # the second sits beside the first in the same row, reached by RIGHT.
  RGSS::Input.triggered = [RGSS::Input::RIGHT]       # move onto Teleport
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

# A party whose four field skills exercise #apply_switch_skill /
# #apply_escape_skill's own `sound_effect` playback (schema.rb field 16) --
# one Switch skill with a configured SE, one Switch skill with a blank one
# (no filename set), one Switch skill that always fails (Buzzer only, no
# skill SE), and an Escape skill with a configured SE. Confirmed against
# EasyRPG's `Scene_Skill::Update`: Switch/Escape play `skill->sound_effect`
# on a successful cast; Teleport does not (it keeps the ordinary decision SE
# played earlier in #update_teleport_target, already covered above), so it
# is not repeated here.
class SkillSoundEffectStubParty < MenuStubParty
  SWITCH_SID = 40
  SWITCH_SID_BLANK = 41
  ESCAPE_SID = 42
  SWITCH_SID_FAIL = 43

  SE = OpenStruct.new(file: 'SwitchOn', volume: 90, pitch: 110, balance: 30)
  BLANK_SE = OpenStruct.new(file: '', volume: 100, pitch: 100, balance: 50)

  def field_skills(_actor, state = nil)
    return [] unless state
    [[SWITCH_SID, 2], [SWITCH_SID_BLANK, 2], [ESCAPE_SID, 5], [SWITCH_SID_FAIL, 2]]
  end

  def db_skill(id)
    case id
    when SWITCH_SID then OpenStruct.new(name: 'Summon', type: Game::Party::SKILL_SWITCH, sound_effect: SE)
    when SWITCH_SID_BLANK
      OpenStruct.new(name: 'Silent Switch', type: Game::Party::SKILL_SWITCH, sound_effect: BLANK_SE)
    when ESCAPE_SID then OpenStruct.new(name: 'Escape', type: Game::Party::SKILL_ESCAPE, sound_effect: SE)
    when SWITCH_SID_FAIL
      OpenStruct.new(name: 'Failing Switch', type: Game::Party::SKILL_SWITCH, sound_effect: SE)
    end
  end

  def cast_switch_skill(_caster, sid)
    case sid
    when SWITCH_SID then 17
    when SWITCH_SID_BLANK then 18
    end
  end

  def cast_escape_skill(_caster, sid, state)
    return nil unless sid == ESCAPE_SID
    state.escape_target
  end
end

def skill_sound_effect_state
  st = Game::State.new(SkillSoundEffectStubParty.new, 1, 0, 0)
  st.escape_target = { map_id: 9, x: 1, y: 2, switch_id: nil }
  st
end

check 'Scene::SkillMenu: a Switch skill plays its own sound_effect on a successful cast' do
  parent = fake_parent(fake_db)
  state = skill_sound_effect_state
  scene = RPG2k::Scene::SkillMenu.new(parent, state)
  RGSS::Audio.reset_se
  RGSS::Input.triggered = [RGSS::Input::C]           # confirm the first row, the switch skill with an SE
  scene.update
  RGSS::Input.reset
  eq true, state.switches[17], 'the switch turned on'
  eq [['Decision1', 100, 100], ['SwitchOn', 90, 110]], RGSS::Audio.se_calls,
     "the ordinary Decision SE (confirming the choice) then the skill's own sound_effect"
end

check 'Scene::SkillMenu: a Switch skill with a blank sound_effect plays nothing extra and does not error' do
  parent = fake_parent(fake_db)
  state = skill_sound_effect_state
  scene = RPG2k::Scene::SkillMenu.new(parent, state)
  RGSS::Input.triggered = [RGSS::Input::RIGHT]       # move onto the second row, the blank-SE switch skill
  scene.update
  RGSS::Input.reset
  RGSS::Audio.reset_se                               # after the cursor-move SE, before the confirm
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq true, state.switches[18], 'the switch still turned on'
  eq [['Decision1', 100, 100]], RGSS::Audio.se_calls,
     'only the ordinary Decision SE -- the blank sound_effect filename makes #play_sound no-op silently'
end

check 'Scene::SkillMenu: a failed Switch cast plays only Buzzer, not the skill\'s own sound_effect' do
  parent = fake_parent(fake_db)
  state = skill_sound_effect_state
  scene = RPG2k::Scene::SkillMenu.new(parent, state)
  RGSS::Input.triggered = [RGSS::Input::DOWN]        # move onto the fourth skill, row 1 col 1 (always fails)
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  RGSS::Audio.reset_se                               # after the cursor-move SEs, before the confirm
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  ok !state.switches[17] && !state.switches[18], 'no switch flipped'
  eq [['Decision1', 100, 100], ['Buzzer1', 100, 100]], RGSS::Audio.se_calls,
     "Decision then Buzzer -- the configured sound_effect never plays on a failed cast"
end

check 'Scene::SkillMenu: an Escape skill plays its own sound_effect on a successful cast' do
  parent = fake_parent(fake_db)
  state = skill_sound_effect_state
  scene = RPG2k::Scene::SkillMenu.new(parent, state)
  RGSS::Input.triggered = [RGSS::Input::DOWN]        # move onto the third skill, row 1 col 0 (Escape)
  scene.update
  RGSS::Input.reset
  RGSS::Audio.reset_se                               # after the cursor-move SE, before the confirm
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq [9, 1, 2, 0], state.pending_teleport, 'queued straight from the one registered escape target'
  eq [['Decision1', 100, 100], ['SwitchOn', 90, 110]], RGSS::Audio.se_calls,
     "the ordinary Decision SE then the skill's own sound_effect, before the warp closes the menu"
end

# EasyRPG's Window_Skill::UpdateHelp (src/window_skill.cpp) feeds the
# database skill's own `description` straight to Scene_Skill's Window_Help
# banner every time the selection changes -- the exact mechanism
# Scene::ItemMenu/EquipMenu already reproduce for their own item description
# banner. Scene::SkillMenu never grew the equivalent: the field's own
# skill.description was parsed by the schema and never read anywhere in
# mruby-rpg2k (confirmed with scripts/rpg2k_field_audit.rb against a real
# game's database), so the Skill screen showed no flavour text at all.
check 'Scene::SkillMenu: the description banner shows the highlighted skill\'s own text, ' \
      'follows the cursor, and keeps the pending skill\'s text in target mode' do
  scene = menu_scene(RPG2k::Scene::SkillMenu, wrap_menu_state)
  ok window_texts(scene.instance_variable_get(:@desc_window)).include?('Description of skill 10.'),
     'starts on the first skill (id 10)'

  RGSS::Input.triggered = [RGSS::Input::RIGHT]       # move onto the second skill (id 11)
  scene.update
  RGSS::Input.reset
  ok window_texts(scene.instance_variable_get(:@desc_window)).include?('Description of skill 11.'),
     'the banner follows the cursor onto the second skill'

  RGSS::Input.triggered = [RGSS::Input::C]           # confirm skill 11 (scope defaults to single-ally)
  scene.update
  RGSS::Input.reset
  eq :target, scene.instance_variable_get(:@mode)
  ok window_texts(scene.instance_variable_get(:@desc_window)).include?('Description of skill 11.'),
     'the pending skill\'s own description is still shown while picking a target'
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

check 'a Teleport/Escape field skill warp does not clear shown pictures' do
  # Unlike the Transfer Player event command ('a teleport clears every shown
  # picture' above), yado.tk documents the Teleport/Escape field skill's own
  # warp as a deliberate exception -- pictures survive it.
  scene = new_scene({}, player: [0, 0])
  state = scene.instance_variable_get(:@state)
  state.show_picture(1, name: 'pic', x: 160, y: 120, zoom: 100, opacity: 255)
  state.pending_teleport = [1, 3, 4, 6] # same map id, elsewhere on it, facing left
  scene.update
  eq 1, state.map_id, 'teleported'
  ok state.pictures.key?(1), 'the picture survived the field-skill warp'
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

# One map-tree node's BGM settings (Game::MapBgm, fields 11 bgm_type / 12 bgm).
FakeBgmChunk = Struct.new(:file, :volume, :pitch)
FakeBgmTreeNode = Struct.new(:bgm_type, :bgm, :parent_map_id)

check 'Scene::Map auto-plays the map own BGM on load and on Teleport' do
  parent = fake_parent(fake_db)
  parent.map_tree = fake_map_tree(
    1 => FakeBgmTreeNode.new(2, FakeBgmChunk.new('Town', 90, 105), 0),
    2 => FakeBgmTreeNode.new(2, FakeBgmChunk.new('Cave', 80, 95), 0),
    3 => FakeBgmTreeNode.new(1, FakeBgmChunk.new('unused', 0, 0), 0) # none
  )
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, {})
  RGSS::Audio.reset_bgm
  scene = RPG2k::Scene::Map.new(parent, state)
  eq [['Town', 90, 105]], RGSS::Audio.bgm_calls, 'map 1 own BGM played on load'
  eq 'Town', state.current_bgm[:name]

  RGSS::Audio.reset_bgm
  scene.send(:perform_teleport, [2, 0, 0, 0])
  eq [['Cave', 80, 95]], RGSS::Audio.bgm_calls, 'map 2 own BGM played on Teleport'

  RGSS::Audio.reset_bgm
  scene.send(:perform_teleport, [1, 0, 0, 0])
  eq [['Town', 90, 105]], RGSS::Audio.bgm_calls,
     'and teleporting back to map 1 plays it again (a fresh Setup, not a same-visit no-op)'

  RGSS::Audio.reset_bgm
  scene.send(:perform_teleport, [3, 0, 0, 0])
  eq [], RGSS::Audio.bgm_calls,
     'map 3 is type 1 (none): the still-playing map-1 track is left alone, nothing restarts'
  eq 'Town', state.current_bgm[:name], 'so the tracked current BGM is untouched too'
end

check 'Scene::Map does not auto-play the map BGM while the party is boarded' do
  parent = fake_parent(fake_db)
  parent.map_tree = fake_map_tree(
    1 => FakeBgmTreeNode.new(2, FakeBgmChunk.new('Field', 100, 100), 0)
  )
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, {})
  state.boarded = :ship
  RGSS::Audio.reset_bgm
  RPG2k::Scene::Map.new(parent, state)
  eq [], RGSS::Audio.bgm_calls,
     "boarded: the ship's own BGM owns the audio, not the map's default"
end

check 'Scene::Map resumes the saved BGM on Continue (apply_access: false) ' \
     'instead of recomputing it from the map tree' do
  parent = fake_parent(fake_db)
  parent.map_tree = fake_map_tree(
    1 => FakeBgmTreeNode.new(2, FakeBgmChunk.new('Town', 90, 105), 0)
  )
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, {})
  # A save resumed mid-visit with a Play BGM override still in effect --
  # different from the destination map's own tree default ('Town' above).
  state.current_bgm = { name: 'Boss Theme', volume: 70, tempo: 120 }
  RGSS::Audio.reset_bgm
  scene = RPG2k::Scene::Map.new(parent, state, apply_access: false)
  eq [['Boss Theme', 70, 120]], RGSS::Audio.bgm_calls,
     "Continue replays the save's own current_bgm, not the map's default"
  eq 'Boss Theme', state.current_bgm[:name], 'and the tracked current BGM is unchanged'

  # Confirms the map-tree default really would have played instead, if this
  # were an ordinary (non-Continue) map entry -- pinning that the branch
  # above is Continue-specific, not a change to #play_map_bgm itself.
  state2 = Game::State.new(fake_party, 1, 0, 0)
  state2.map = fake_map(1, {})
  state2.current_bgm = { name: 'Boss Theme', volume: 70, tempo: 120 }
  RGSS::Audio.reset_bgm
  RPG2k::Scene::Map.new(parent, state2)
  eq [['Town', 90, 105]], RGSS::Audio.bgm_calls,
     'an ordinary (apply_access: true) entry recomputes from the tree instead'
end

check 'Scene::Map resumes the saved BGM on Continue even while boarded, ' \
     'and plays nothing when no BGM was playing at save time' do
  parent = fake_parent(fake_db)
  parent.map_tree = fake_map_tree(
    1 => FakeBgmTreeNode.new(2, FakeBgmChunk.new('Field', 100, 100), 0)
  )
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = fake_map(1, {})
  state.boarded = :ship
  state.current_bgm = { name: 'Sea Voyage', volume: 60, tempo: 100 }
  RGSS::Audio.reset_bgm
  RPG2k::Scene::Map.new(parent, state, apply_access: false)
  eq [['Sea Voyage', 60, 100]], RGSS::Audio.bgm_calls,
     "the save's own boat BGM resumes verbatim -- #play_map_bgm's boarded " \
     'skip does not apply to this, separate, resume path'

  state2 = Game::State.new(fake_party, 1, 0, 0)
  state2.map = fake_map(1, {})
  state2.current_bgm = nil
  RGSS::Audio.reset_bgm
  RPG2k::Scene::Map.new(parent, state2, apply_access: false)
  eq [], RGSS::Audio.bgm_calls, 'nothing was playing at save time, so nothing plays now'
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

# The slot and candidate cursors live on genuine Window_Selectable
# subclasses (Window_Equip/Window_EquipItem) whose own Update() auto-repeats
# DOWN/UP the same as every other list -- see Scene::ItemMenu#update_items's
# fuller writeup. The actor switch (RIGHT/LEFT) is confirmed NOT to: real
# EasyRPG's Scene_Equip::UpdateEquipSelection (src/scene_equip.cpp) checks
# Input::IsTriggered(RIGHT/LEFT) only, no IsRepeated, since each switch
# pushes a whole new Scene_Equip rather than moving a cursor.
check 'Scene::EquipMenu: holding Down auto-repeats the slot and candidate ' \
      'cursors, but holding Right does not switch actors' do
  scene = menu_scene(RPG2k::Scene::EquipMenu, wrap_menu_state)
  RGSS::Input.repeated = [RGSS::Input::DOWN] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@slot_index),
     'a held (repeated, not triggered) Down still moves the slot cursor one step'

  RGSS::Input.repeated = [RGSS::Input::RIGHT]
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@actor_index),
     'a held (repeated, not triggered) Right does NOT switch actors -- matches ' \
     'the real engine\'s own discrete-only IsTriggered gate'

  scene.instance_variable_set(:@mode, :items)
  scene.instance_variable_set(:@cand_index, 0)
  scene.send(:build_cand_window)
  RGSS::Input.repeated = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  eq 1, scene.instance_variable_get(:@cand_index),
     'a held (repeated, not triggered) Down still moves the candidate cursor one step'
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

check 'Scene::EquipMenu: a cursed item refuses to open the item list for its own slot' do
  state = wrap_menu_state
  state.party.actors.first.cursed_slot = 0                # the weapon slot
  scene = menu_scene(RPG2k::Scene::EquipMenu, state)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :slots, scene.instance_variable_get(:@mode), 'the cursed slot stays closed'

  # The shield slot is not cursed -- moving down to it and pressing C opens
  # the list as normal, so the gate really is per-slot, not per-actor.
  RGSS::Input.triggered = [RGSS::Input::DOWN]
  scene.update
  RGSS::Input.reset
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.reset
  eq :items, scene.instance_variable_get(:@mode)
end

# A party whose db_item rows carry the four RPG2000 "points1" equip-bonus
# fields, so the comparison-arrow math has real numbers to add up. Item 1
# is what the weapon slot already holds; 2/3/4 strictly beat, strictly fall
# short of and exactly match its single non-zero field (atk_points1).
class EquipCompareParty < MenuStubParty
  ITEMS = {
    1 => OpenStruct.new(name: 'Worn', atk_points1: 10),
    2 => OpenStruct.new(name: 'Better', atk_points1: 15),
    3 => OpenStruct.new(name: 'Worse', atk_points1: 5),
    4 => OpenStruct.new(name: 'Same', atk_points1: 10)
  }.freeze
  def db_item(id); ITEMS[id]; end
  def equip_candidates(_slot, _actor = nil); [[2, 1], [3, 1], [4, 1]]; end
end

check 'Scene::EquipMenu: the candidate arrow sums all four stat deltas against the worn item (yado.tk)' do
  state = Game::State.new(EquipCompareParty.new, 1, 0, 0)
  state.party.actors.first.equipment[0] = 1 # weapon slot already holds item 1 (atk 10)
  scene = menu_scene(RPG2k::Scene::EquipMenu, state)
  scene.instance_variable_set(:@mode, :items)
  scene.send(:build_cand_window)
  texts = window_texts(scene.instance_variable_get(:@cand_window))
  # Row 0 is "(Remove)" (one draw_text call); each candidate row after it is
  # three calls -- name, arrow, count -- so the arrows land at 2, 5, 8.
  eq '^', texts[2], 'a candidate with strictly more combined points draws Up'
  eq 'v', texts[5], 'one with strictly fewer draws Down'
  eq '-', texts[8], 'an exact match draws Same, not counted per-stat'
end

# An actor whose weapon-slot Claymore (id 2) is 両手持ち; MenuStubActor's own
# stub always answers false, so a check exercising the forced-unequip side
# effect needs this richer one instead.
class TwoHandedActor < MenuStubActor
  TWO_HANDED_IDS = [2].freeze
  def two_handed?(item_id); TWO_HANDED_IDS.include?(item_id); end
end

class TwoHandedEquipParty < MenuStubParty
  ITEMS = {
    1 => OpenStruct.new(name: 'Sword', atk_points1: 20),    # worn, weapon slot
    2 => OpenStruct.new(name: 'Claymore', atk_points1: 40), # 両手持ち candidate
    5 => OpenStruct.new(name: 'Shield', def_points1: 25)    # worn, shield slot
  }.freeze
  def initialize
    super
    @actors = [TwoHandedActor.new]
  end
  def db_item(id); ITEMS[id]; end
  def equip_candidates(_slot, _actor = nil); [[2, 1]]; end
end

check 'Scene::EquipMenu: a 両手持ち candidate also drops the other hand\'s ' \
      'stat bonus from the preview, matching what actually equipping it does' do
  # Confirmed against EasyRPG's actual C++ source: Scene_Equip::
  # UpdateStatusWindow (src/scene_equip.cpp) also subtracts the *other*
  # hand's item when either it or the candidate is 両手持ち, since equipping
  # either one forces the opposite slot empty -- the exact side effect
  # Actor#equip_item / #free_two_handed_slot already applies for real. A
  # preview that only diffs the two items landing in the browsed slot would
  # show the Claymore's own +20 Atk (40 - 20) and draw Up, even though the
  # true net (+20 Atk, -25 Def from the forced-off Shield) is -5.
  state = Game::State.new(TwoHandedEquipParty.new, 1, 0, 0)
  actor = state.party.actors.first
  actor.equipment[0] = 1 # weapon slot: Sword, atk 20
  actor.equipment[1] = 5 # shield slot: Shield, def 25
  scene = menu_scene(RPG2k::Scene::EquipMenu, state)
  scene.instance_variable_set(:@mode, :items)
  scene.send(:build_cand_window)
  texts = window_texts(scene.instance_variable_get(:@cand_window))
  # Row 0 is "(Remove)"; the one candidate (Claymore) follows it, arrow at 2.
  eq 'v', texts[2],
     'net -5 (claymore +40 atk, sword -20 atk, forced-off shield -25 def), ' \
     'not a naive +20 that ignores the shield the claymore forces off'
end

check "Scene::EquipMenu: browsing the shield slot with a 両手持ち weapon " \
      'already worn shows the same forced-unequip side effect' do
  # Symmetric case: any candidate landing in the shield slot forces the
  # weapon slot's own 両手持ち weapon off, even an ordinary (non-two-handed)
  # shield candidate -- EasyRPG's guard is `other_old_item->two_handed ||
  # current_item->two_handed`, either side qualifies.
  state = Game::State.new(TwoHandedEquipParty.new, 1, 0, 0)
  actor = state.party.actors.first
  actor.equipment[0] = 2 # weapon slot: Claymore (two-handed), atk 40
  scene = menu_scene(RPG2k::Scene::EquipMenu, state)
  scene.instance_variable_set(:@slot_index, Game::Actor::SHIELD_SLOT)
  scene.instance_variable_set(:@mode, :items)
  # An ordinary (non-two-handed) shield candidate landing in the shield slot.
  eq(-15, scene.send(:equip_delta, 5),
     'the shield itself (+25 def) against nothing (empty slot), minus the ' \
     "forced-off claymore's own -40 atk: 25 - 0 - 40 = -15")
end

check "Scene::EquipMenu: Remove never triggers the 両手持ち forced-unequip " \
      'side effect' do
  # EasyRPG's own guard is `current_item && ...` -- id 0 (Remove) has no
  # candidate item at all, so the other hand is never touched by removing
  # this slot's own item.
  state = Game::State.new(TwoHandedEquipParty.new, 1, 0, 0)
  actor = state.party.actors.first
  actor.equipment[0] = 2 # weapon slot: Claymore (two-handed), atk 40
  scene = menu_scene(RPG2k::Scene::EquipMenu, state)
  eq(-40, scene.send(:equip_delta, 0), 'just the claymore\'s own -40 atk, no extra subtraction')
end

# A party whose weapon slot equips a dangling item id (a database shrink
# removed row 99) -- db_item(99) misses while db_item(1) resolves normally,
# so a check can tell "reported gap" apart from an ordinary equipped item.
class DanglingItemParty < MenuStubParty
  ITEMS = { 1 => OpenStruct.new(name: 'Bronze Sword') }.freeze
  def db_item(id); ITEMS[id]; end
end

check 'Scene::EquipMenu: a dangling equipped item id logs once, not per rebuild, ' \
      'while the slot still shows the "Item #<id>" placeholder' do
  state = Game::State.new(DanglingItemParty.new, 1, 0, 0)
  state.party.actors.first.equipment[0] = 99 # weapon slot: dangling id, no database row
  scene = nil
  out = capture_stderr { scene = menu_scene(RPG2k::Scene::EquipMenu, state) }
  eq 1, out.scan('[RPG2k] Equip screen:').size,
     "expected exactly one diagnostic for the one dangling id, got: #{out.inspect}"
  ok out.include?('[RPG2k] Equip screen: item #99 not found in the database, ' \
                   'showing a placeholder label'), out

  texts = window_texts(scene.instance_variable_get(:@slot_window))
  ok texts.include?('Item 99'), "the placeholder label still shows, got: #{texts.inspect}"

  # Switching actors and back rebuilds the slot window (#rebuild_for_actor)
  # without a fresh database shrink -- the same dangling id re-renders every
  # time, and must not add a second line to the console.
  out2 = capture_stderr { 3.times { scene.send(:build_slot_window) } }
  ok out2.empty?, "re-rendering the already-warned id must stay silent, got: #{out2.inspect}"
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

# Confirmed already correct, no code change needed -- checked while auditing
# this screen for the same key-repeat gap already fixed on every other menu
# screen (see docs/TODO.md). Unlike a genuine cursor inside a
# Window_Selectable list, this screen has no list at all: LEFT/RIGHT just
# rebuild the whole panel for a different party member, and EasyRPG's real
# Scene_Status::vUpdate (src/scene_status.cpp) checks
# Input::IsTriggered(RIGHT/LEFT) only -- no IsRepeated fallthrough anywhere
# in the method -- so holding the key never auto-cycles members in the real
# engine either. This check pins that as a checked invariant rather than an
# unverified assumption.
check 'Scene::StatusMenu: holding Right does NOT auto-cycle the actor -- ' \
      'confirmed matching the real engine\'s own discrete-only gate' do
  scene = menu_scene(RPG2k::Scene::StatusMenu, wrap_menu_state)
  RGSS::Input.repeated = [RGSS::Input::RIGHT] # held, but not a fresh trigger
  scene.update
  RGSS::Input.reset
  eq 0, scene.instance_variable_get(:@actor_index),
     'a held (repeated, not triggered) Right does not cycle the actor'
end

check 'Scene::StatusMenu: a dangling equipped item id logs once, not per rebuild, ' \
      'while the slot still shows the "Item #<id>" placeholder' do
  state = Game::State.new(DanglingItemParty.new, 1, 0, 0)
  state.party.actors.first.equipment[0] = 99 # weapon slot: dangling id, no database row
  scene = nil
  out = capture_stderr { scene = menu_scene(RPG2k::Scene::StatusMenu, state) }
  eq 1, out.scan('[RPG2k] Status screen:').size,
     "expected exactly one diagnostic for the one dangling id, got: #{out.inspect}"
  ok out.include?('[RPG2k] Status screen: item #99 not found in the database, ' \
                   'showing a placeholder label'), out

  texts = window_texts(scene.instance_variable_get(:@window))
  ok texts.any? { |t| t.include?('Item 99') }, "the placeholder label still shows, got: #{texts.inspect}"

  # Switching actors and back rebuilds the whole window (#build_window)
  # without a fresh database shrink -- the same dangling id re-renders every
  # time, and must not add a second line to the console.
  out2 = capture_stderr { 3.times { scene.send(:build_window) } }
  ok out2.empty?, "re-rendering the already-warned id must stay silent, got: #{out2.inspect}"
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

# Frames one walked tile takes at the default on-foot move_speed (3): TILE / 2
# of movement (8 frames), plus the frame that starts the step. Walking `n`
# tiles needs a little slack on top, and the fixture map is 6 wide, so a
# rightward walk has room for four.
def walk(scene, tiles, dir = 6)
  RGSS::Input.dir_value = dir
  ((RPG2k::Scene::Map::TILE / 2 + 1) * tiles + 2).times do
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

# Ports EasyRPG's `Game_Party::ApplyStateDamage` (src/game_party.cpp): its
# `damage` bool is only ever set inside a `ChangeType_lose` branch, never a
# `ChangeType_gain` one, and `Game_Player::UpdateNextMovementAction` gates the
# red step-damage flash on exactly that bool. Regen's map-step tick heals, so
# it must never redden the screen the way Poison's does.
check "walking a GAIN-type state's own map-step tick heals without flashing the screen" do
  hero = SlipActor.new([7], 90)                         # Regen
  scene = new_scene({}, player: [0, 0], members: [hero])
  st = scene.instance_variable_get(:@state)

  walk(scene, 3)
  eq 90, hero.hp, 'not a multiple of the interval yet'
  ok !st.screen.flashing?

  walk(scene, 1)
  eq 91, hero.hp, 'the fourth tile heals 1 HP'
  ok !st.screen.flashing?, 'a GAIN-type tick never flashes the screen, unlike a LOSE one'
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

check 'a negative terrain damage heals every tile instead of hurting' do
  # Confirmed against EasyRPG's actual C++ source: Game_Player::Move applies
  # `hero->ChangeHp(-terrain->damage, ...)` regardless of sign, so a terrain
  # row with a negative `damage` field (a "recovery floor") heals rather than
  # hurts -- `-(-3) = +3`. Party#apply_terrain_damage's own doc comment is the
  # port target.
  hero = SlipActor.new([], 70)
  scene = new_scene({}, player: [0, 0], members: [hero], terrain_damage: -3)
  walk(scene, 1)
  eq 73, hero.hp, 'the first tile already heals'
  walk(scene, 2)
  eq 79, hero.hp, 'and so does every one after it'
end

check '地形ダメージ無効 gear does NOT block a healing tile -- only a damaging one' do
  # EasyRPG's own gate is `terrain->damage < 0 || !hero->PreventsTerrainDamage()`
  # -- a negative damage value short-circuits the immunity check entirely, so
  # gear that blocks a damage floor does not also block a recovery floor.
  hero = SlipActor.new([], 70)
  hero.prevents_terrain_damage = true
  scene = new_scene({}, player: [0, 0], members: [hero], terrain_damage: -3)
  walk(scene, 2)
  eq 76, hero.hp, "the immunity gear didn't stop the heal"
end

check 'a healing tile never flashes the screen, unlike a damaging one' do
  # EasyRPG's Game_Player::Move only sets `red_flash` for positive `damage`
  # (`if (terrain->damage > 0) red_flash = true`) -- a heal never flashes.
  hero = SlipActor.new([], 70)
  scene = new_scene({}, player: [0, 0], members: [hero], terrain_damage: -3)
  walk(scene, 1)
  st = scene.instance_variable_get(:@state)
  ok !st.screen.flashing?, 'no flash for a heal, even though HP changed'
end

# -- footstep SE (RPG2003 歩行音, ADR 0034 follow-up) --------------------------
#
# EasyRPG's Game_Player::Move plays terrain->footstep behind a
# Player::IsRPG2k3() gate -- RPG2000 never plays it -- and on_damage_se
# repurposes the same field into a damage-tick-only SE instead of an
# ordinary per-step one: `!terrain->on_damage_se || red_flash`. See
# #play_terrain_footstep_se's comment (mruby-rpg2k/mrblib/scene/map.rb).

check 'RPG2003 terrain footstep plays every ordinary step onto that tile' do
  RGSS::Audio.reset_se
  hero = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [hero], rpg2003: true, footstep: 'Step1')
  walk(scene, 3)
  eq 3, RGSS::Audio.se_calls.count { |c| c[0] == 'Step1' }, 'one footstep per tile walked'
end

check 'RPG2000 never plays a terrain footstep, even when one is set' do
  RGSS::Audio.reset_se
  hero = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [hero], rpg2003: false, footstep: 'Step1')
  walk(scene, 3)
  ok RGSS::Audio.se_calls.none? { |c| c[0] == 'Step1' },
     'footstep is an RPG2003-only feature (EasyRPG gates it on Player::IsRPG2k3())'
end

check 'on_damage_se withholds the footstep on a harmless step, and plays it on a damaging one' do
  RGSS::Audio.reset_se
  harmless = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [harmless], rpg2003: true,
                     footstep: 'Hurt1', on_damage_se: true)   # terrain_damage 0 -> harmless
  walk(scene, 2)
  ok RGSS::Audio.se_calls.none? { |c| c[0] == 'Hurt1' },
     'on_damage_se suppresses the footstep on a step that dealt no damage'

  RGSS::Audio.reset_se
  hurt = SlipActor.new([])
  scene2 = new_scene({}, player: [0, 0], members: [hurt], rpg2003: true, terrain_damage: 3,
                      footstep: 'Hurt1', on_damage_se: true)
  walk(scene2, 2)
  eq 2, RGSS::Audio.se_calls.count { |c| c[0] == 'Hurt1' }, 'and plays it on every step that does'
end

# Riding the airship skips terrain damage and the footstep SE entirely --
# EasyRPG's `Game_Player::Move` returns via `InAirship()`'s own early check
# *before* it ever looks up the stepped-on tile's terrain row, so neither
# fires while airborne. `InAirship()` alone, not a general `boarded?`
# check: a boat/ship still sails the water layer's own terrain and is not
# exempted (`check_random_encounter`'s own "riding the airship skips the
# roll entirely" check above is the same exemption for a different step
# effect). #note_party_step's status-condition slip damage has no such
# gate in the reference (`UpdateNextMovementAction`'s `ApplyStateDamage`
# call is unconditional), so it is untouched by this and not exercised here.
check 'riding the airship skips terrain damage and the RPG2003 footstep SE' do
  RGSS::Audio.reset_se
  grounded = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [grounded], rpg2003: true,
                     terrain_damage: 3, footstep: 'Step1')
  walk(scene, 2)
  ok grounded.hp < 100, 'on foot, the damaging terrain hurts as usual'
  ok RGSS::Audio.se_calls.any? { |c| c[0] == 'Step1' }, 'and the footstep plays'

  RGSS::Audio.reset_se
  airborne = SlipActor.new([])
  scene2 = new_scene({}, player: [0, 0], members: [airborne], rpg2003: true,
                      terrain_damage: 3, footstep: 'Step1')
  scene2.instance_variable_get(:@state).boarded = :airship
  walk(scene2, 2)
  eq 100, airborne.hp, 'riding the airship, the same terrain does nothing'
  ok RGSS::Audio.se_calls.none? { |c| c[0] == 'Step1' }, 'and no footstep plays either'
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

# -- stale terrain id (database shrink) ---------------------------------------

check 'stepping onto a chipset cell whose terrain id has no row logs once, ' \
      'not per frame, and falls back to defaults' do
  hero = SlipActor.new([])
  scene = new_scene({}, player: [0, 0], members: [hero], terrain_damage: 5, bush_depth: 3)
  # Simulate a database shrink: every tile of the fixture map's chip 0 is
  # tagged terrain 42 (see fake_chipset), but the row itself is now gone, the
  # same "chipset cell still points at an id the database no longer has"
  # dangling reference docs/TODO.md's runtime error catalog describes.
  scene.db.terrain.delete(42)

  # One step lands on (1, 0). Both #note_party_step (terrain damage) and
  # #check_random_encounter (encounter rate) look the same tile's terrain row
  # up in that single landing frame -- two call sites hitting the one stale
  # tile -- so this alone already exercises the "log once" dedup, not just
  # the "not every frame while stationary" half of it.
  out = capture_stderr { walk(scene, 1) }
  eq 1, out.scan('[RPG2k] Terrain:').size,
     "expected exactly one diagnostic for the one stale tile, got: #{out.inspect}"
  ok out.include?('[RPG2k] Terrain: tile (1, 0) references terrain #42, ' \
                   'which no longer exists in the database'), out
  eq 100, hero.hp, 'no row resolves -> no terrain damage, the default fallback'

  # Querying the very same tile again (from any of #terrain_row_at's other
  # callers, and however many more frames pass while the party simply stands
  # there) must not add a second line.
  out2 = capture_stderr do
    3.times { scene.send(:terrain_row_at, 1, 0) }
    scene.send(:bush_depth_at, 1, 0)
  end
  ok out2.empty?, "re-querying the already-warned tile must stay silent, got: #{out2.inspect}"
  eq 0, scene.send(:bush_depth_at, 1, 0), 'no row resolves -> bush depth falls back to 0'
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

# A map tile's *own* draw path (not an event's): only a starred (ABOVE_BIT)
# upper tile belongs in the buffer that composites over the player, matching
# Game::ChipSet#elevated?. See its comment for why this matters -- an
# unstarred upper tile (most of a chipset's furniture/counters) has always
# been treated as always-above here, which hid Nepheshel's sleeping hero
# completely instead of showing him through the bed's own unstarred tiles.
check 'draw_layers routes an unstarred upper tile behind the player, a starred one in front' do
  up = Array.new(144, 0)
  # Index 2, not 0: index 0 is the id BLOCK_F itself, the reserved blank chip
  # the renderer skips outright (ChipsetLayout.upper_blank?), so it cannot
  # stand in for a real unstarred tile here.
  up[2] = Game::ChipSet::ALL_DIRS                             # unstarred (e.g. a headboard)
  up[1] = Game::ChipSet::ALL_DIRS | Game::ChipSet::ABOVE_BIT  # starred
  row_class = Struct.new(:name, :chipset_name, :passable_data_lower,
                         :passable_data_upper, :terrain_data,
                         :animation_type, :animation_speed)
  db = fake_db
  db.chipset[1] = row_class.new('cs', 'cs', nil, up, nil, 0, 0)
  w = 6; h = 5
  upper = Array.new(w * h, 0)
  bf = Game::ChipsetLayout::BLOCK_F
  upper[0] = bf + 2   # (0, 0): unstarred
  upper[1] = bf + 1   # (1, 0): starred
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = Game::Map.new(1, OpenStruct.new(width: w, height: h, chipset_id: 1,
                                              lower_layer: Array.new(w * h, 0),
                                              upper_layer: upper, events: {}))
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  # The tiles are blitted into the *cached* grids, which #draw_layers then
  # copies into @lower_bmp / @upper_bmp at the sub-tile scroll offset. The
  # routing under test (Game::ChipSet#elevated? picking the grid) happens on
  # the way into these, so this is where it is observable; @lower_bmp only ever
  # sees the one whole-grid copy plus whatever events draw over it.
  lower = scene.instance_variable_get(:@lower_tiles)
  upper_bmp = scene.instance_variable_get(:@upper_tiles)
  lower.clear_blt_calls
  upper_bmp.clear_blt_calls
  scene.send(:invalidate_tile_cache)
  scene.send(:draw_layers, 0, 0)
  tile = RPG2k::Scene::Map::TILE
  at = ->(calls, x, y) { calls.count { |c| c[0] == x && c[1] == y } }
  # (0, 0) always gets one blit for its own (plain, id 0) lower tile; the
  # unstarred upper tile at the same spot is a *second* blit into the same
  # grid, not one into the upper grid.
  eq 2, at.call(lower.blt_calls, 0, 0),
     'the plain floor and the unstarred upper tile both land in the lower buffer'
  eq 0, at.call(upper_bmp.blt_calls, 0, 0), 'the unstarred tile never reaches the upper buffer'
  # (TILE, 0) also gets its own plain lower tile, but the starred upper tile
  # there is the one that must reach the upper (above-player) buffer.
  eq 1, at.call(upper_bmp.blt_calls, tile, 0), 'the starred tile lands in the upper buffer'
  # Every other cell of this map is the blank first id, which draws nothing at
  # all -- so the lower buffer is exactly the map's own tiles plus the one
  # unstarred upper tile that landed in it. Cells outside the map draw nothing
  # either (#lower answers nil there), and id 0 is a block A/B autotile, so
  # each tile is its four quarters rather than one blit -- both taken from the
  # code rather than written out, so this says "no extra blit" and not "121".
  per_tile = Game::ChipsetLayout.quads(0, 0, 0).size
  eq w * h * per_tile + 1, lower.blt_calls.size,
     'the blank upper id adds no blit anywhere'
end

# RPG2000's upper layer is overwhelmingly the reserved blank chip -- 98% of the
# upper cells across Nepheshel's 543 maps -- and drawing it blitted a
# fully-transparent chipset cell once per tile for nothing. It is a *drawing*
# sentinel only: it still indexes entry 0 of the chipset's upper passability
# table, which is a real lookup, so skipping the draw must not leak into
# passability.
check 'the reserved blank upper id draws nothing but still answers passability' do
  up = Array.new(144, 0)
  up[0] = 0                      # BLOCK_F itself: blocked on every side
  up[3] = Game::ChipSet::ALL_DIRS
  row_class = Struct.new(:name, :chipset_name, :passable_data_lower,
                         :passable_data_upper, :terrain_data,
                         :animation_type, :animation_speed)
  db = fake_db
  db.chipset[1] = row_class.new('cs', 'cs', nil, up, nil, 0, 0)
  w = 4; h = 4
  bf = Game::ChipsetLayout::BLOCK_F
  upper = Array.new(w * h, bf)   # every cell blank, as a real map very nearly is
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = Game::Map.new(1, OpenStruct.new(width: w, height: h, chipset_id: 1,
                                              lower_layer: Array.new(w * h, 0),
                                              upper_layer: upper, events: {}))
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  lower = scene.instance_variable_get(:@lower_tiles)
  upper_bmp = scene.instance_variable_get(:@upper_tiles)
  lower.clear_blt_calls
  upper_bmp.clear_blt_calls
  scene.send(:invalidate_tile_cache)
  scene.send(:draw_layers, 0, 0)
  # The lower layer's own tiles, and nothing more. (Only the map's own cells
  # draw -- the grid is bigger than this 4x4 map and #lower answers nil past
  # its edge -- and id 0 is an autotile, so each is its four quarters.)
  eq w * h * Game::ChipsetLayout.quads(0, 0, 0).size, lower.blt_calls.size,
     'a blank upper layer costs exactly the lower layer'
  eq 0, upper_bmp.blt_calls.size, 'and nothing reaches the above-player buffer'
  # ... while the passability table still reads through it: entry 0 here blocks
  # every direction, so the blank id is not silently treated as "no tile".
  cs = scene.instance_variable_get(:@chipset)
  eq false, cs.passable_tile?(0, bf, 2), 'the blank id still blocks per its passability entry'
end

# The tile grid is cached across frames (see Scene::Map#tile_cache_valid?), so
# what needs pinning down is not that a tile is drawn but *when* it is redrawn:
# too eager and the cache buys nothing, too lazy and a change never reaches the
# screen. Each case below counts blits into the cached grid across a second
# #draw_layers, which is zero exactly when the cache was reused.
def tile_cache_probe(map: nil, &change)
  w = 8; h = 8
  db = fake_db
  state = Game::State.new(fake_party, 1, 0, 0)
  state.map = map || Game::Map.new(1, OpenStruct.new(
    width: w, height: h, chipset_id: 1,
    lower_layer: Array.new(w * h, 0), upper_layer: Array.new(w * h, 0),
    events: {}))
  scene = RPG2k::Scene::Map.new(fake_parent(db), state)
  scene.send(:draw_layers, 0, 0) # prime the cache
  grid = scene.instance_variable_get(:@lower_tiles)
  grid.clear_blt_calls
  cam = change ? change.call(scene, state) : [0, 0]
  scene.send(:draw_layers, cam[0], cam[1])
  grid.blt_calls.size
end

check 'a frame that changed nothing reuses the cached tile grid' do
  eq 0, tile_cache_probe, 'an identical frame must not re-blit a single tile'
end

check 'scrolling within a tile reuses the cache, crossing a tile rebuilds it' do
  # A sub-tile scroll is applied when the cached grid is copied out, so the grid
  # itself is untouched; stepping onto the next tile changes which tiles it holds.
  eq 0, tile_cache_probe { |_s, _st| [RPG2k::Scene::Map::TILE - 1, 0] }
  ok tile_cache_probe { |_s, _st| [RPG2k::Scene::Map::TILE, 0] } > 0,
     'crossing a tile boundary must rebuild the grid'
end

check 'a Tile Substitution rebuilds the cached tile grid' do
  # The map answers lookups differently from now on, and Game::Map#revision is
  # what tells the cache so -- without that bump the swap would never be drawn.
  ok(tile_cache_probe do |_s, st|
    st.map.substitute_tile(0, 0, Game::ChipsetLayout::BLOCK_E)
    [0, 0]
  end > 0, 'a substituted tile must reach the screen')
end

check 'stepping the tile animation rebuilds the cached tile grid' do
  # Water and the block-C animated tiles cycle off @anim_frame, so a frame that
  # advances the animation column is a different picture even standing still.
  # The probe map is all tile id 0, a block A/B autotile, so it moves with
  # .anim_ab -- frame 24 is that input's first step at the default speed. Note
  # a *cycle* is not a step: .anim_ab(96) is back to 0, so a probe there would
  # see, correctly, no rebuild at all.
  ok(tile_cache_probe do |s, _st|
    s.instance_variable_set(:@anim_frame, 24)
    [0, 0]
  end > 0, 'an animation step must reach the screen')
end

check 'an animation step the visible tiles do not follow leaves the cache alone' do
  # .anim_c steps every 6 frames but drives only the block C animated chips. A
  # grid holding none of them -- all id 0 here, which is block A/B -- is the
  # same picture either way, and rebuilding it ten times a second for an input
  # nothing on screen reads was most of the cache's remaining cost.
  eq 0, tile_cache_probe { |s, _st|
    s.instance_variable_set(:@anim_frame, 6)
    [0, 0]
  }, 'a grid with no block C tile must not rebuild for .anim_c'
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
# skippable on, then the route's own commands. Guarded so it fires once.
def player_route_page(*cmds)
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(Game::Interpreter::Cmd::MOVE_EVENT,
                                [10001, 8, 0, 1, *cmds])]
  one_shot_auto(pg, 9000)
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
  eq 16, heights.max, 'and rose to the same peak an event does'
  peak = heights.index(heights.max)
  ok heights[0...peak] == heights[0...peak].sort,
     "rises to the peak: #{heights.inspect}"
  # The ends of the arc, read off the shared curve rather than off a sampling
  # frame -- the first frame after an update is already two pixels into the step.
  eq 0, scene.send(:jump_offset_for, 0), 'the hop begins on the ground'
  eq 0, scene.send(:jump_offset_for, Game::TILE), 'and ends on it'
  eq 0, scene.send(:player_jump_offset), 'and the hero is back on it once landed'
end

# EasyRPG's own Game_Character::GetJumpHeight (src/game_character.cpp) is
# `jump_height &lt; 5 ? jump_height * 2 : jump_height &lt; 13 ? jump_height + 4 :
# 16` -- doubled while small, offset by 4 through h < 13, and capped at a
# flat 16 beyond that. #jump_offset_for used to mis-port this as an
# uncapped `h + 5`, peaking at 21px instead of the real arc's own 16px
# ceiling (a full tile, never past it).
check "#jump_offset_for's piecewise arc matches EasyRPG's GetJumpHeight exactly" do
  scene = new_scene({})
  jh = ->(move_count) { scene.send(:jump_offset_for, move_count) }
  eq 0, jh.call(0), 'move_count 0: the hop begins on the ground'
  eq 0, jh.call(Game::TILE), 'move_count 16: and ends on it'
  eq 4, jh.call(15), 'move_count 15: h=2, the doubled branch (2*2)'
  eq 4, jh.call(1), 'move_count 1: the symmetric doubled-branch point'
  eq 12, jh.call(12), 'move_count 12: h=8, the +4 branch (8+4)'
  eq 12, jh.call(4), 'move_count 4: the symmetric +4-branch point'
  # The cap flattens the true peak into a 3-frame plateau at exactly 16, not
  # a single sharp point -- h=14 at move_count 7 and 9 is already >= 13 and
  # caps the same as h=16's own move_count 8, matching "hang near the top."
  eq 16, jh.call(9), 'move_count 9: h=14, already capped'
  eq 16, jh.call(8), 'move_count 8: h=16, the true midpoint'
  eq 16, jh.call(7), 'move_count 7: h=14, capped again, symmetric'
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
  one_shot_auto(pg, 9021)
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

check 'a vehicle Change Graphic overrides its sprite without persisting to Game::Vehicle' do
  ic = Game::Interpreter::Cmd
  name = 'other'
  params = [10002, 8, 0, 1, R::CHANGE_GRAPHIC, name.length, 3]
  pg = page(trigger: 3) # auto-start
  pg.event_commands = [ECmd.new(ic::MOVE_EVENT, params, string: name)]
  one_shot_auto(pg, 9022)
  scene = new_scene({ 1 => event(3, 3, pg) }, player: [5, 5], boat_pass: true)
  st = scene.instance_variable_get(:@state)
  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x = 0
  boat.y = 1
  5.times { scene.update }
  charset = scene.send(:vehicle_charset, boat)
  index = scene.send(:vehicle_charset_index, boat)
  ok charset, 'the overridden charset bitmap loaded'
  eq 3, index, 'the overridden graphic index applied'
  eq '', boat.charset_name, 'not written to the persisted Game::Vehicle, only the route mirror'
  eq 0, boat.charset_index

  scene.send(:perform_teleport, [1, 0, 0, 0])
  ok scene.instance_variable_get(:@vehicle_chars)[:boat].nil?,
     'Transfer Player drops the mirror, reverting the override'
end

# EasyRPG Player's actual C++ source: Game_Vehicle::Game_Vehicle
# (src/game_vehicle.cpp) seeds a fresh vehicle with
# `SetSpriteGraphic(ToString(lcf::Data::system.boat_name), lcf::Data::system.
# boat_index)` (and the ship_/airship_ equivalents) -- the database's System
# boat_index/ship_index/airship_index seed the on-map CharSet cell exactly
# like their _name counterparts seed the graphic file, until Change Vehicle
# Graphic (or Set Move Route's own override) says otherwise. A vehicle whose
# graphic was never customized must draw that cell, not always cell 0.
check 'an uncustomized vehicle draws the database System boat/ship/airship_index, not always cell 0' do
  scene = new_scene({}, player: [5, 5], boat_pass: true, ship_pass: true)
  scene.db.system.boat_index = 4
  scene.db.system.ship_index = 7
  scene.db.system.airship_index = 2
  st = scene.instance_variable_get(:@state)

  boat = st.vehicle(:boat)
  boat.map_id = st.map_id
  boat.x, boat.y = 0, 1
  eq 4, scene.send(:vehicle_charset_index, boat),
     "an unset boat graphic falls back to System's boat_index"

  ship = st.vehicle(:ship)
  ship.map_id = st.map_id
  ship.x, ship.y = 0, 2
  eq 7, scene.send(:vehicle_charset_index, ship),
     "an unset ship graphic falls back to System's ship_index"

  airship = st.vehicle(:airship)
  airship.map_id = st.map_id
  airship.x, airship.y = 0, 3
  eq 2, scene.send(:vehicle_charset_index, airship),
     "an unset airship graphic falls back to System's airship_index"

  # Change Vehicle Graphic writes both charset_name and charset_index
  # together; once the vehicle has its own graphic, the database default no
  # longer applies -- even when the chosen index is 0.
  boat.charset_name = 'CustomBoat'
  boat.charset_index = 0
  eq 0, scene.send(:vehicle_charset_index, boat),
     'an explicit Change Vehicle Graphic keeps its own index, even index 0'
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
  one_shot_auto(pg, 9023)
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
    one_shot_auto(pg, 9024)
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
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ui = battle_ui(scene)
  before = ui[:enemy_sprites][0]
  ok before, 'the monster is on the field'
  # What Game::Battle's transform action does to the combatant.
  ui[:foes][0].battler_name = 'Dragon'
  ui[:foes][0].name = 'Dragon'
  scene.instance_variable_get(:@battle).send(:refresh_battle_sprites)
  ok !ui[:enemy_sprites][0].equal?(before), 'its sprite is rebuilt'
  eq 'Dragon', ui[:sprite_names][0], 'and tracked against the new battler'
  ok ui[:enemy_sprites][0].visible, 'still on the field'
  # A second refresh with nothing changed must not churn the sprite again.
  same = ui[:enemy_sprites][0]
  scene.instance_variable_get(:@battle).send(:refresh_battle_sprites)
  ok ui[:enemy_sprites][0].equal?(same), 'an unchanged battler is left alone'
end

# A Transform repoints the combatant at a new database enemy row
# (Game::Battle#enemy_transform_action), but the troop's own Enemy object at
# the same slot -- the one #total_exp/#total_gold/#drops actually read
# exp/gold/drop_id/drop_prob from -- is a separate object nothing else keeps
# in sync. EasyRPG's own Game_Enemy::Transform repoints a single backing
# data pointer, so reward accessors read the new monster too; this port's
# parallel Combatant/Troop::Enemy split needs an explicit mirror, which
# #refresh_battle_sprites now performs (#sync_troop_member_rewards) right
# alongside its existing battler-swap detection.
check 'a transformed monster pays out its new form\'s EXP/gold/drop, not its original form\'s' do
  scene, _st = battle_scene_with_pages(nil)
  90.times do
    ui = battle_ui(scene)
    RGSS::Input.triggered = [RGSS::Input::C] if ui && ui[:phase] == :battle_options
    scene.update
    RGSS::Input.triggered = []
    ui = battle_ui(scene)
    break if ui && ui[:phase] == :command
  end
  ui = battle_ui(scene)
  member = ui[:troop].members[0]
  eq 5, member.exp, "starts as the default fixture's Slime (id 2)"
  eq 10, member.gold
  # What Game::Battle's transform action does to the combatant: repoint it at
  # enemy id 3, the default fixture's own Bat (exp 4, gold 8, no drop).
  ui[:foes][0].battler_name = 'Bat'
  ui[:foes][0].name = 'Bat'
  ui[:foes][0].enemy_id = 3
  scene.instance_variable_get(:@battle).send(:refresh_battle_sprites)
  eq 4, member.exp, "the troop member's own reward fields follow the transform"
  eq 8, member.gold
  eq 0, member.drop_id, 'Bat carries no drop, unlike Slime'
end

# -- random ("wandering monster") encounters ----------------------------------
#
# Map-tree node field 41 (enemy_groups) / 44 (encount_steps), read the same
# way #fake_map_tree already feeds Game::MapAccess's own per-node lookup.

FakeEncounterNode = Struct.new(:enemy_groups, :encount_steps)

check 'a random encounter opens a battle with the map-tree node\'s own troop' do
  # encount_steps 1 with the default terrain rate (100) is a guaranteed roll
  # on the very first step: ratio = 100/1 = 100, which lands on the table's
  # pmod-2.0 row, and 2.0 * 100 / (100 * 1) is a 100% chance.
  tree = fake_map_tree(1 => FakeEncounterNode.new({ 1 => OpenStruct.new(enemy_group_id: 1) }, 1))
  scene = new_scene({}, player: [0, 0], map_tree: tree)
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 6 # hold right
  ui = nil
  20.times do
    scene.update
    ui = battle_ui(scene)
    break if ui
  end
  RGSS::Input.dir_value = 0
  ok ui, 'ordinary walking with a guaranteed roll opened a battle'
  eq 1, ui[:troop].id, "the map tree node's own troop (id 1, the default Slimes)"
  eq 0, st.encounter_total, 'the accumulator resets once a fight actually starts'
end

check 'an empty encounter list never starts a random battle' do
  tree = fake_map_tree(1 => FakeEncounterNode.new({}, 1)) # same guaranteed roll, no troops
  scene = new_scene({}, player: [0, 0], map_tree: tree)
  RGSS::Input.dir_value = 6
  15.times { scene.update }
  RGSS::Input.dir_value = 0
  ok battle_ui(scene).nil?,
     'the roll succeeds but there is nothing to fight, so no battle opens'
end

check 'riding the airship skips the random-encounter roll entirely' do
  tree = fake_map_tree(1 => FakeEncounterNode.new({ 1 => OpenStruct.new(enemy_group_id: 1) }, 1))
  scene = new_scene({}, player: [0, 0], map_tree: tree)
  st = scene.instance_variable_get(:@state)
  st.boarded = :airship
  scene.send(:check_random_encounter)
  ok battle_ui(scene).nil?, 'flying is RPG_RT\'s one blanket exemption'
  eq 0, st.encounter_total, 'the accumulator never even started'
end

check 'a forced move route does not roll for a random encounter' do
  # A Move Event route driving the player is a forced step (@player_forced_step),
  # not ordinary input-driven walking -- EasyRPG's UpdateEncounterSteps only
  # ever runs from the latter (see the comment on @player_forced_step).
  ic = Game::Interpreter::Cmd
  tree = fake_map_tree(1 => FakeEncounterNode.new({ 1 => OpenStruct.new(enemy_group_id: 1) }, 1))
  auto = page(trigger: 3)
  # target 10001 (player), freq 8, repeat off, skippable on, three MOVE_RIGHTs.
  auto.event_commands = [ECmd.new(ic::MOVE_EVENT,
                                  [10001, 8, 0, 1, R::MOVE_RIGHT, R::MOVE_RIGHT, R::MOVE_RIGHT])]
  one_shot_auto(auto, 9025)
  scene = new_scene({ 1 => event(3, 3, auto) }, player: [0, 0], map_tree: tree)
  st = scene.instance_variable_get(:@state)
  30.times { scene.update }
  ok st.x > 0, "the forced route actually moved the player, at x=#{st.x}"
  ok battle_ui(scene).nil?,
     'the whole forced route ran without ever rolling for an encounter'
end

check 'standing on a Hero Touch event tile suppresses the random-encounter roll' do
  # yado.tk quirk, multiply corroborated: the tile under a Hero Touch
  # (trigger 1) event answers random encounters too, not just the event
  # itself. Without the fix, this guaranteed-roll setup (encount_steps 1,
  # default terrain rate -- see the "opens a battle" check above) would
  # start a battle on the very first check regardless.
  tree = fake_map_tree(1 => FakeEncounterNode.new({ 1 => OpenStruct.new(enemy_group_id: 1) }, 1))
  touch = page(trigger: 1)
  touch.event_commands = [ECmd.new(0)] # a real page needs *a* command list
  scene = new_scene({ 1 => event(0, 0, touch) }, player: [0, 0], map_tree: tree)
  st = scene.instance_variable_get(:@state)
  scene.send(:check_random_encounter)
  scene.update # give it a frame too, in case a battle wait was queued anyway
  ok battle_ui(scene).nil?,
     "the party is standing on a Hero Touch event's own tile: no roll"
  eq 0, st.encounter_total, 'the step never accumulated, matching the flying early-out above'
end

check 'standing on an Event Touch tile still rolls for a random encounter' do
  # Control for the Hero Touch check above: an otherwise-identical setup,
  # but the event on the party's tile uses a different trigger (Event
  # Touch, 2) -- the guaranteed roll must still fire, proving the
  # suppression is keyed to the trigger type and not "any event is here".
  tree = fake_map_tree(1 => FakeEncounterNode.new({ 1 => OpenStruct.new(enemy_group_id: 1) }, 1))
  other = page(trigger: 2)
  other.event_commands = [ECmd.new(0)]
  scene = new_scene({ 1 => event(0, 0, other) }, player: [0, 0], map_tree: tree)
  scene.send(:check_random_encounter)
  scene.update # the roll only queues a :battle wait; a frame turns it into @battle_ui
  ui = battle_ui(scene)
  ok ui, 'an Event Touch event on the tile does not suppress the roll'
  eq 1, ui[:troop].id, "the map tree node's own troop"
end

check "current_encounter_steps reads the map tree node's own setting, " \
     'overridden by Change Encounter Rate' do
  tree = fake_map_tree(1 => FakeEncounterNode.new({}, 25))
  scene = new_scene({}, map_tree: tree)
  st = scene.instance_variable_get(:@state)
  eq 25, scene.send(:current_encounter_steps), "the map tree node's own encount_steps"
  st.encounter_rate = 4
  eq 4, scene.send(:current_encounter_steps), 'Change Encounter Rate (11740) overrides it'
end

check 'a map with no tree data defaults to 25 encounter steps' do
  scene = new_scene({})
  eq 25, scene.send(:current_encounter_steps)
end

check 'an encounter-steps of 0 disables random encounters and resets the accumulator' do
  tree = fake_map_tree(1 => FakeEncounterNode.new({ 1 => OpenStruct.new(enemy_group_id: 1) }, 0))
  scene = new_scene({}, map_tree: tree)
  st = scene.instance_variable_get(:@state)
  st.encounter_total = 55
  scene.send(:check_random_encounter)
  eq 0, st.encounter_total, 'the accumulator resets rather than piling up while encounters are off'
  ok battle_ui(scene).nil?
end

# -- Debug keys (RPG2k#test_play only -- see mruby-rpg2k/mrblib/scene/map.rb
# #debug_through? and #try_open_debug_menu, and scene/debug_menu.rb) ---------

check 'Ctrl during Test Play walks through a wall no ordinary move could cross' do
  scene = walled_in_scene({}, [2, 2])
  scene.parent.test_play = true
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 2 # down
  RGSS::Input.triggered = [RGSS::Input::CTRL]
  20.times { scene.update }
  ok st.y > 2, "Ctrl bypassed collision the same way Through Mode does (y=#{st.y})"
end

check 'Ctrl only bypasses collision during Test Play -- an ordinary run stays walled in' do
  scene = walled_in_scene({}, [2, 2]) # test_play defaults false
  st = scene.instance_variable_get(:@state)
  RGSS::Input.dir_value = 2
  RGSS::Input.triggered = [RGSS::Input::CTRL]
  20.times { scene.update }
  eq 2, st.y, 'a released game never sees Ctrl do anything: the wall holds'
end

check 'Ctrl during Test Play suppresses the random-encounter roll' do
  tree = fake_map_tree(1 => FakeEncounterNode.new({ 1 => OpenStruct.new(enemy_group_id: 1) }, 1))
  scene = new_scene({}, map_tree: tree, test_play: true)
  st = scene.instance_variable_get(:@state)
  RGSS::Input.triggered = [RGSS::Input::CTRL]
  scene.send(:check_random_encounter)
  ok battle_ui(scene).nil?,
     'Ctrl held: a guaranteed roll (encount_steps 1, default terrain rate) never fires'
  eq 0, st.encounter_total, 'the accumulator never even started'
end

check 'holding Shift during Test Play fast-forwards a message\'s typing, but still waits ' \
     'once it is fully shown' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hello'),
                         ECmd.new(ic::CONTROL_SWITCHES, [0, 1, 1, 0])]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5], test_play: true)
  st = scene.instance_variable_get(:@state)

  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  ok !reveal.done?, 'text is not fully revealed as soon as it opens'

  RGSS::Input.triggered = [RGSS::Input::SHIFT]
  scene.update
  ok reveal.done?, 'holding Shift completed the reveal, like a C/B press'
  ok scene.instance_variable_get(:@message), 'message stays open on the completing frame'

  # Unlike a C/B tap, Shift alone never advances past the now-fully-shown
  # message -- it waits there (one paragraph at a time) no matter how long
  # Shift stays held, until an actual confirm arrives.
  10.times { scene.update }
  ok scene.instance_variable_get(:@message), 'Shift alone never dismisses a finished message'
  ok !st.switches[1], 'the interpreter has not resumed past the message yet'

  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  ok !scene.instance_variable_get(:@message), 'an actual confirm dismisses it'
  5.times { RGSS::Input.reset; scene.update }
  ok st.switches[1], 'the interpreter resumed and ran the next command'
end

check 'Shift only fast-forwards messages during Test Play' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = [ECmd.new(ic::SHOW_MESSAGE, [], string: 'hello')]
  scene = new_scene({ 1 => event(2, 2, auto) }, player: [5, 5]) # test_play defaults false
  msg = nil
  12.times { scene.update; msg = scene.instance_variable_get(:@message); break if msg }
  ok msg, 'message window opened'
  reveal = msg[:reveal]
  RGSS::Input.triggered = [RGSS::Input::SHIFT]
  scene.update
  ok !reveal.done?, 'a released game never sees Shift fast-forward the reveal'
end

check 'F9 opens the debug menu during Test Play, and B returns to the map' do
  scene = new_scene({}, test_play: true)
  RGSS::Input.triggered = [RGSS::Input::F9]
  scene.update
  pushed = scene.parent.pushed
  eq 1, pushed.size, 'F9 pushed exactly one scene'
  ok pushed.first.is_a?(RPG2k::Scene::DebugMenu), 'the pushed scene is the debug menu'
end

check 'F9 does nothing outside Test Play' do
  scene = new_scene({}) # test_play defaults false
  RGSS::Input.triggered = [RGSS::Input::F9]
  scene.update
  ok scene.parent.pushed.empty?, 'a released game never sees F9 open anything'
end

# yado.tk / community RPG_RT trivia (@2000_battle_bot / デフォ戦bot):
# "テストプレイ中にＦ９キーを押せば スイッチ・変数の値を好きに変えられる。
# これは戦闘中でも行える。" -- F9 during Test Play works during battle too,
# unlike every other #event_busy? condition (see #try_open_debug_menu).
check 'F9 opens the debug menu during Test Play even with a battle open' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) }, test_play: true)
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  10.times do
    scene.update
    break if battle_ui(scene)
  end
  ok battle_ui(scene), 'the battle actually opened'

  RGSS::Input.triggered = [RGSS::Input::F9]
  scene.update
  pushed = scene.parent.pushed
  eq 1, pushed.size, 'F9 pushed exactly one scene, mid-battle'
  ok pushed.first.is_a?(RPG2k::Scene::DebugMenu), 'the pushed scene is the debug menu'
  ok battle_ui(scene), 'the battle stays open behind the debug menu'
end

check 'F9 does nothing during a battle outside Test Play' do
  ic = Game::Interpreter::Cmd
  auto = page(trigger: 3)
  auto.event_commands = battle_event_commands(ic)
  scene = new_scene({ 1 => event(2, 2, auto) }) # test_play defaults false
  st = scene.instance_variable_get(:@state)
  st.instance_variable_set(:@party, BattleStubParty.new)
  10.times do
    scene.update
    break if battle_ui(scene)
  end
  ok battle_ui(scene), 'the battle actually opened'

  RGSS::Input.triggered = [RGSS::Input::F9]
  scene.update
  ok scene.parent.pushed.empty?, 'a released game never sees F9 open anything, mid-battle either'
end

check 'the debug menu toggles a switch on C and flips to Variable on Left/Right' do
  st = menu_state
  st.switches[1] = false
  scene = menu_scene(RPG2k::Scene::DebugMenu, st)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  ok st.switches[1], 'C toggled switch 1 (the cursor starts on row 1) on'
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  ok !st.switches[1], 'a second C toggles it back off'

  RGSS::Input.triggered = [RGSS::Input::RIGHT]
  scene.update
  eq :variable, scene.instance_variable_get(:@mode), 'Left/Right flips to the Variable page'
end

check 'the debug menu edits a variable through the signed number editor' do
  st = menu_state
  st.variables[1] = 5
  scene = menu_scene(RPG2k::Scene::DebugMenu, st)
  scene.instance_variable_set(:@mode, :variable)
  scene.send(:refresh)

  RGSS::Input.triggered = [RGSS::Input::C] # open the editor on variable 1
  scene.update
  ok scene.instance_variable_get(:@editor), 'C on a Variable row opens the editor'

  RGSS::Input.triggered = [RGSS::Input::RIGHT] # sign cell -> the leftmost digit
  scene.update
  RGSS::Input.triggered = [RGSS::Input::UP] # that digit 0 -> 1 (5 -> 100005)
  scene.update
  RGSS::Input.triggered = [RGSS::Input::LEFT] # back to the sign cell
  scene.update
  RGSS::Input.triggered = [RGSS::Input::UP] # sign -> negative
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C] # confirm
  scene.update

  ok !scene.instance_variable_get(:@editor), 'confirming closes the editor'
  eq(-100_005, st.variables[1], 'the edited, now-negative value landed in the variable')
end

check 'B cancels the debug menu variable editor without changing the value' do
  st = menu_state
  st.variables[1] = 5
  scene = menu_scene(RPG2k::Scene::DebugMenu, st)
  scene.instance_variable_set(:@mode, :variable)
  scene.send(:refresh)
  RGSS::Input.triggered = [RGSS::Input::C]
  scene.update
  RGSS::Input.triggered = [RGSS::Input::UP]
  scene.update # bump a digit, then cancel instead of confirming
  RGSS::Input.triggered = [RGSS::Input::B]
  scene.update
  ok !scene.instance_variable_get(:@editor), 'B closed the editor'
  eq 5, st.variables[1], 'cancelling left the variable untouched'
end

# EasyRPG's own Game_Variables::GetMaxDigits (src/game_variables.cpp) derives
# the debug menu's own Window_NumberInput width from the same edition-gated
# range Game::Variables::MAX/RPG2003_MAX already carries -- 6 digits on
# RPG2000, 7 on RPG2003, not a flat 6 regardless of database.
class Rpg2003MenuStubParty < MenuStubParty
  def rpg2003?; true; end
end

check "the debug menu variable editor widens to 7 digits on an RPG2003 database" do
  st = Game::State.new(Rpg2003MenuStubParty.new, 1, 0, 0)
  st.variables[1] = 5
  scene = menu_scene(RPG2k::Scene::DebugMenu, st)
  scene.instance_variable_set(:@mode, :variable)
  scene.send(:refresh)
  eq 7, scene.send(:editor_digits), 'RPG2003 widens the editor to 7 digits'

  RGSS::Input.triggered = [RGSS::Input::C] # open the editor on variable 1
  scene.update
  eq 7, scene.instance_variable_get(:@editor)[:digits].size,
     'the digit array itself is 7 cells wide, not 6'
  # Digits are most-significant-first, so the new, RPG2003-only millions
  # place is digit index 0 -- cursor cell 1, right after the sign cell (0).
  RGSS::Input.triggered = [RGSS::Input::RIGHT]; scene.update
  RGSS::Input.triggered = [RGSS::Input::UP] # the millions digit 0 -> 1
  scene.update
  RGSS::Input.triggered = [RGSS::Input::C] # confirm
  scene.update
  eq 1_000_005, st.variables[1],
     'the millions digit only the RPG2003-widened editor exposes landed in the variable'
end

check "a troop's terrain_set excludes it from a tile it does not cover" do
  scene = new_scene({})
  scene.db.enemy_group[9] = OpenStruct.new(name: 'Wolves', members: {}, terrain_set: [0])
  ok !scene.send(:troop_allowed_on_terrain?, 9, 1), 'terrain_set[0] (tag 1) is 0: forbidden'
  ok scene.send(:troop_allowed_on_terrain?, 9, 2),
     'terrain_set is only one entry long: an omitted tag defaults to allowed'
  ok scene.send(:troop_allowed_on_terrain?, 1, 1),
     'the default Slimes group carries no terrain_set at all: always allowed'
end

check 'Nepheshel-shaped Save choice event: a Show Choices "SAVE" branch reaches ' \
      'Open Save Menu through a real choice selection, even with save_access ' \
      'locked' do
  # The exact command shape (opcodes, indentation, choice count) of Nepheshel's
  # own Crystal Gate event -- the real-world event the save/load picker
  # originally failed to open for, on a map the tree flags Save-forbidden.
  # Reproduced end to end here: opening the choice window, selecting "SAVE" by
  # pressing the confirm key (not calling Game::Interpreter#choose directly --
  # that skips Scene::Map#drive_message's own close_message pairing and gives
  # a false pass/fail), and confirming the picker opens.
  ic = Game::Interpreter::Cmd
  cmds = [
    ECmd.new(ic::SHOW_CHOICES, [4], indent: 0, string: 'SAVE/Enter Game Space/Remove Crystal/Do nothing'),
    ECmd.new(ic::CHOICE_OPTION, [0], indent: 0, string: 'SAVE'),
    ECmd.new(IC2::OPEN_SAVE_MENU, [], indent: 1),
    ECmd.new(0, [], indent: 1), # blank
    ECmd.new(ic::CHOICE_OPTION, [1], indent: 0, string: 'Enter Game Space'),
    ECmd.new(0, [], indent: 1),
    ECmd.new(ic::CHOICE_OPTION, [2], indent: 0, string: 'Remove Crystal'),
    ECmd.new(0, [], indent: 1),
    ECmd.new(ic::CHOICE_OPTION, [3], indent: 0, string: 'Do nothing'),
    ECmd.new(0, [], indent: 1),
    ECmd.new(ic::CHOICE_END, [], indent: 0),
  ]
  scene = new_scene({}, player: [0, 0])
  parent = scene.instance_variable_get(:@parent)
  st = scene.instance_variable_get(:@state)
  st.save_access = false # Nepheshel's own Crystal Gate map forbids Save at the tree level
  scene.instance_variable_get(:@interpreter).start(cmds)
  msg = open_msg(scene)
  ok msg && msg[:choice], 'the choice window opened'
  RGSS::Input.triggered = [RGSS::Input::C] # confirm the first choice, "SAVE"
  scene.update # closes the choice window and calls Game::Interpreter#choose
  RGSS::Input.reset
  scene.update # steps the interpreter past the choice, into Open Save Menu's wait
  scene.update # dispatches the wait and opens the picker
  eq 1, parent.pushed.size, 'the SAVE branch reaches Open Save Menu, which opens the picker'
  ok parent.pushed.first.is_a?(RPG2k::Scene::SaveLoad), 'the pushed scene is the picker'
end

# -- window title -------------------------------------------------------------

# RPG2k#read_ini_title reads the caption RPG_RT.exe puts on its own window out
# of RPG_RT.ini, which the boot hands to RGSS.window_title (mruby-rpg2k/mrblib/
# main.rb; include/terminal.hxx's window title bridge). The rest of the boot
# needs a real .ldb/.lmt, so the reader is exercised on its own here, against
# real ini files on disk -- including a CP932 one, since that is what the
# Japanese editor writes and what every game in the test beds ships.
check 'the window title comes from RPG_RT.ini, decoded from CP932' do
  # The engine decodes the ini through LCF.cp932_to_utf8 (native; mruby-lcf/
  # src/lcf.cxx). Stand in for it with CRuby's own encoding conversion, so this
  # asserts the reader's parsing and hand-off, not the table.
  unless Object.const_defined?(:LCF) && LCF.respond_to?(:cp932_to_utf8)
    mod = Object.const_defined?(:LCF) ? LCF : Object.const_set(:LCF, Module.new)
    mod.define_singleton_method(:cp932_to_utf8) do |s|
      s.dup.force_encoding(Encoding::CP932).encode(Encoding::UTF_8)
    end
  end

  read_title = lambda do |dir|
    Object.send(:remove_const, :GAME_DIR) if Object.const_defined?(:GAME_DIR)
    Object.const_set(:GAME_DIR, dir)
    RPG2k.allocate.send(:read_ini_title)
  end

  Dir.mktmpdir('rpg2k-title') do |root|
    # A Japanese title as the editor writes it: CP932 bytes, CRLF line ends,
    # and GameTitle sitting among the other [RPG_RT] keys.
    jp = File.join(root, 'jp')
    Dir.mkdir jp
    File.binwrite(File.join(jp, 'RPG_RT.ini'),
                  "[RPG_RT]\r\nGameTitle=#{'ネフェシエル'.encode(Encoding::CP932)}\r\n" \
                  "MapEditMode=1\r\nFullPackageFlag=1\r\n")
    eq 'ネフェシエル', read_title.call(jp), 'the CP932 title, decoded and stripped of its CR'

    # An ASCII title passes through the same conversion unchanged.
    ascii = File.join(root, 'ascii')
    Dir.mkdir ascii
    File.binwrite(File.join(ascii, 'RPG_RT.ini'), "[RPG_RT]\nGameTitle=Meido Action\n")
    eq 'Meido Action', read_title.call(ascii), 'an ASCII title'

    # A project whose ini has no GameTitle (or no ini at all -- a game unpacked
    # without it) still names the window something: the folder it was loaded
    # from, never a blank caption.
    bare = File.join(root, 'Bare Project')
    Dir.mkdir bare
    File.binwrite(File.join(bare, 'RPG_RT.ini'), "[RPG_RT]\nFullPackageFlag=0\n")
    eq 'Bare Project', read_title.call(bare), 'the folder name when GameTitle is missing'

    none = File.join(root, 'No Ini')
    Dir.mkdir none
    eq 'No Ini', read_title.call(none), 'the folder name when there is no ini at all'

    # An empty GameTitle= is the same as none: fall back rather than clearing
    # the caption to nothing.
    empty = File.join(root, 'Empty Title')
    Dir.mkdir empty
    File.binwrite(File.join(empty, 'RPG_RT.ini'), "[RPG_RT]\nGameTitle=\r\n")
    eq 'Empty Title', read_title.call(empty), 'the folder name when GameTitle is empty'
  end
end

check 'battle_scene_class routes a 2003 database to the RPG2k3 battle scene' do
  rpg2003_db = OpenStruct.new
  def rpg2003_db.rpg2003?; true; end
  eq RPG2k3::Scene::Battle, RPG2k::Scene.battle_scene_class(rpg2003_db),
     'an RPG2003 database boots the gauge-capable 2003 scene'

  rpg2000_db = OpenStruct.new
  def rpg2000_db.rpg2003?; false; end
  eq RPG2k::Scene::Battle, RPG2k::Scene.battle_scene_class(rpg2000_db),
     'an RPG2000 database keeps the turn-based 2000 scene'
end

# A database that does not implement #rpg2003? at all (a bare fixture) is
# treated as RPG2000, never as the 2003 scene, so the gauge engine stays dark
# for every fixture-driven check.
check 'battle_scene_class treats an edition-less database as RPG2000' do
  eq RPG2k::Scene::Battle, RPG2k::Scene.battle_scene_class(OpenStruct.new),
     'a fixture database with no #rpg2003? keeps the 2000 scene'
end

# -- summary ------------------------------------------------------------------

if $failures.zero?
  puts "rpg2k scene check: #{$checks} checks passed"
  exit 0
else
  warn "rpg2k scene check: #{$failures} of #{$checks} checks FAILED"
  exit 1
end
