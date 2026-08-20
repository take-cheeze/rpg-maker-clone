#!/usr/bin/env ruby
# encoding: UTF-8
#
# Smoke-test the RPG Maker VX / VX Ace data layer.
#
# The schema (mruby-rpgvx/mrblib/rgss2_data.rb) and the database loader
# (mruby-rpgvx/mrblib/rgss_data.rb) are written in the mruby/CRuby common subset,
# so this harness loads those exact files under CRuby and drives
# RPGVX::RGSSData over real project trees — the same trick
# scripts/rpgxp_testbed_check.rb plays for XP. In the real build the
# `.rvdata`/`.rvdata2` streams are read by mruby-marshal and the RGSS value types
# (Table/Color/Tone/Rect) are the native C classes; here CRuby's own Marshal does
# the reading and the value types are the shims below.
#
# Neither VX nor VX Ace has a fetchable open-source test bed the way XP
# (OpenGame) and MV (Lunatic-Core) do — the editors and their RTPs are
# commercial, and no equivalent project is redistributable — so this check
# *builds* a project of its own for each edition, covering every Data/ table, and
# drives the loader over it: loose on disk, then repacked into the edition's
# encrypted archive (Game.rgss2a / Game.rgss3a). A generated bed cannot prove a
# field *name* (only real editor output can), which is why every name is
# transcribed from the RGSS2/RGSS3 references — see
# docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md. What it does prove is that the
# whole path works end to end and stays working.
#
# Point it at a real game and it checks that too, including an audit that every
# instance variable in the real data has an accessor in our schema — the check
# that would catch a field the schema misses:
#
#   ruby scripts/rpgvx_testbed_check.rb [GAME_DIR ...]
#
# With no arguments it also scans ./data for VX/VX Ace projects. Use
# `--write DIR` to materialise the two generated sample projects on disk (handy
# for pointing the built engine at one). Exits non-zero on any failure.

require "tmpdir"
require "fileutils"
require "zlib"

# --- RGSS value-type shims (native classes in the real build) --------------

# RGSS Table: an N-dimensional grid of int16s. Marshal payload is five int32
# little-endian header words (dim, xsize, ysize, zsize, item count) followed by
# that many int16s. Matches mruby-rgss's src/lib.cxx table_load/table_dump.
class Table
  attr_reader :dim, :xsize, :ysize, :zsize, :data

  def initialize(xsize, ysize = nil, zsize = nil)
    @dim = ysize.nil? ? 1 : (zsize.nil? ? 2 : 3)
    @xsize = xsize
    @ysize = ysize || 1
    @zsize = zsize || 1
    @data = Array.new(@xsize * @ysize * @zsize, 0)
  end

  def self._load(s)
    dim, x, y, z, count = s[0, 20].unpack("l<5")
    t = allocate
    t.instance_variable_set(:@dim, dim)
    t.instance_variable_set(:@xsize, x)
    t.instance_variable_set(:@ysize, y)
    t.instance_variable_set(:@zsize, z)
    t.instance_variable_set(:@data, s[20, count * 2].unpack("s<#{count}"))
    t
  end

  def _dump(_limit = -1)
    [@dim, @xsize, @ysize, @zsize, @data.size].pack("l<5") + @data.pack("s<*")
  end

  def [](x, y = 0, z = 0)
    @data[x + @xsize * (y + @ysize * z)]
  end

  def []=(*args)
    value = args.pop
    x, y, z = args[0], args[1] || 0, args[2] || 0
    @data[x + @xsize * (y + @ysize * z)] = value
  end
end

# Color / Tone: four doubles. Rect: four int32s.
class Color
  def initialize(r = 0, g = 0, b = 0, a = 255)
    @v = [r.to_f, g.to_f, b.to_f, a.to_f]
  end
  attr_reader :v
  def _dump(_limit = -1) = @v.pack("E4")
  def self._load(s)
    c = allocate
    c.instance_variable_set(:@v, s.unpack("E4"))
    c
  end
end

class Tone < Color; end

class Rect
  def initialize(x = 0, y = 0, width = 0, height = 0)
    @v = [x, y, width, height]
  end
  def x = @v[0]
  def y = @v[1]
  def width = @v[2]
  def height = @v[3]
  def _dump(_limit = -1) = @v.pack("l<4")
  def self._load(s)
    r = allocate
    r.instance_variable_set(:@v, s.unpack("l<4"))
    r
  end
end

# The script bundle is zlib-deflated per section; the real build inflates it
# through the native RGSS.zlib_inflate (mruby-rgss). Graphics and the frame
# timeout are native too — the boot check below needs them because the script
# host's per-frame driver yields inside Graphics.update.
module RGSS
  def self.zlib_inflate(bytes) = Zlib::Inflate.inflate(bytes)

  class Timeout < StandardError; end

  # The packed archive the asset loaders read through. Native Bitmap/Audio
  # consult this after a loose file misses (mruby-rgss/mrblib/lib.rb); here it
  # only has to exist so the boot shell's registration can be asserted.
  class << self
    attr_accessor :asset_archive
    # The window caption is native too (mruby-rgss/src/window_title.cxx puts it
    # on the SDL window). Here it only has to be settable and readable back, so
    # the boot's "name the window after the game" step can be asserted.
    attr_accessor :window_title
  end

  # The default UI font is native too: mruby-rgss/src/default_font.cxx locates
  # the downloaded assets/fonts file, and the VX boot shell points
  # Font.default_path at it for projects that ship no font of their own. This
  # harness rasterises nothing, so the shim only has to carry the two entry
  # points the boot touches, and reports no font (a normal state — the font is
  # downloaded, not committed).
  def self.default_font_path = nil

  class Font
    class << self
      attr_accessor :default_path
    end
  end

  # Graphics is native. These stand-ins mirror the parts of mruby-rgss's module
  # the VX path touches (the real ones are unit-tested in mruby-rgss/test):
  # counting frames so the per-frame driver can be asserted, RGSS2's frame wait,
  # and the screen size the boot shell declares.
  module Graphics
    @frames = 0
    @width = 640
    @height = 480
    class << self
      attr_reader :frames, :width, :height
      def update = @frames += 1
      def reset_frames = @frames = 0
      def wait(duration) = duration.to_i.times { update }
      def resize_screen(width, height)
        @width = width
        @height = height
      end
    end
  end

  # The audio backend is native (SDL_mixer); record what the RPG::BGM/SE/ME
  # records route to it so the boot check can assert the game's own scripts
  # actually reached it.
  module Audio
    @played = []
    class << self
      attr_reader :played
      def reset = @played = []
      def bgm_play(name, volume = 100, pitch = 100, pos = 0) = @played << [:bgm_play, name, volume, pitch, pos]
      def bgm_stop = @played << [:bgm_stop]
      def bgm_fade(time) = @played << [:bgm_fade, time]
      def bgm_pos = 0
      def bgs_play(name, volume = 100, pitch = 100) = @played << [:bgs_play, name, volume, pitch]
      def bgs_stop = @played << [:bgs_stop]
      def bgs_fade(time) = @played << [:bgs_fade, time]
      def bgs_pos = 0
      def me_play(name, volume = 100, pitch = 100) = @played << [:me_play, name, volume, pitch]
      def me_stop = @played << [:me_stop]
      def me_fade(time) = @played << [:me_fade, time]
      def se_play(name, volume = 100, pitch = 100) = @played << [:se_play, name, volume, pitch]
      def se_stop = @played << [:se_stop]
    end
  end
end

# The real build pulls RGSS into the top level (mruby-rpgxp's lib.rb) so the
# bundled scripts can say `Graphics.update`; mirror that here.
class Object
  include RGSS
end

# --- Load the real sources -------------------------------------------------

ROOT = File.expand_path("..", __dir__)
# The XP archive reader is shared: VX's Game.rgss2a is the same version-1 format
# as XP's Game.rgssad, and VX Ace's Game.rgss3a is the version-3 one.
load File.join(ROOT, "mruby-rpgxp", "mrblib", "rgssad.rb")
# The VX shell runs a project's own scripts through the shared RGSS script host.
load File.join(ROOT, "mruby-rpgxp", "mrblib", "script_host.rb")
# mruby-rpgxp/mrblib/rgss_data.rb declares the RPG:: schema first (Actor,
# Class, Item, Skill, Weapon, Armor, State, Enemy, and — since a genuine VX
# Ace project's own script sections reassert it — the real BaseItem/
# UsableItem/EquipItem superclass chain over them); mruby-rpgvx/mrbgem.rake
# depends on mruby-rpgxp for exactly this load-order reason, so this harness
# has to mirror it or these classes come out flat, missing the fields their
# real superclass would have carried. See the comment on `class BaseItem` in
# that file.
load File.join(ROOT, "mruby-rpgxp", "mrblib", "rgss_data.rb")
load File.join(ROOT, "mruby-rpgvx", "mrblib", "lib.rb")
load File.join(ROOT, "mruby-rpgvx", "mrblib", "rgss2_data.rb")
load File.join(ROOT, "mruby-rpgvx", "mrblib", "rgss2_runtime.rb")
load File.join(ROOT, "mruby-rpgvx", "mrblib", "rgss_data.rb")

# --- A generated project, one per edition ----------------------------------

# Builds a small but complete project: every Data/ table an editor writes, a map
# with an event, a common event and a script bundle. The values are chosen to be
# recognisable (and edition-correct) rather than realistic.
module Sample
  module_function

  def build(dir, edition)
    ext = RPGVX.data_ext(edition)
    ace = edition == :vxace
    FileUtils.mkdir_p(File.join(dir, "Data"))
    File.write(File.join(dir, "Game.ini"),
               "[Game]\nRTP=\nLibrary=System\\RGSS#{ace ? 300 : 200}.dll\n" \
               "Scripts=Data/Scripts#{ext}\nTitle=Sample\n")

    write(dir, "System", ext, system(ace))
    write(dir, "MapInfos", ext, { 1 => map_info })
    write(dir, "Map001", ext, map(ace))
    write(dir, "Actors", ext, [nil, actor(ace)])
    write(dir, "Classes", ext, [nil, klass(ace)])
    write(dir, "Skills", ext, [nil, skill(ace)])
    write(dir, "Items", ext, [nil, item(ace)])
    write(dir, "Weapons", ext, [nil, weapon(ace)])
    write(dir, "Armors", ext, [nil, armor(ace)])
    write(dir, "Enemies", ext, [nil, enemy(ace)])
    write(dir, "Troops", ext, [nil, troop])
    write(dir, "States", ext, [nil, state(ace)])
    write(dir, "Animations", ext, [nil, animation])
    write(dir, "CommonEvents", ext, [nil, common_event])
    if ace
      write(dir, "Tilesets", ext, [nil, tileset])
    else
      write(dir, "Areas", ext, [nil, area])
    end
    write(dir, "Scripts", ext, scripts(ext))
    dir
  end

  def write(dir, base, ext, obj)
    File.binwrite(File.join(dir, "Data", "#{base}#{ext}"), Marshal.dump(obj))
  end

  def audio(cls, name)
    a = cls.new
    a.name = name
    a.volume = 100
    a.pitch = 100
    a
  end

  def system(ace)
    s = RPG::System.new
    s.game_title = ace ? "Ace Sample" : "VX Sample"
    s.version_id = 12_345
    s.party_members = [1]
    s.elements = [nil, "Physical", "Fire"]
    s.switches = [nil, "opened"]
    s.variables = [nil, "counter"]
    s.start_map_id = 1
    s.start_x = 5
    s.start_y = 5
    s.title_bgm = audio(RPG::BGM, "Theme1")
    s.battle_bgm = audio(RPG::BGM, "Battle1")
    s.battle_end_me = audio(RPG::ME, "Victory1")
    s.gameover_me = audio(RPG::ME, "Gameover1")
    s.sounds = [audio(RPG::SE, "Cursor1"), audio(RPG::SE, "Decision1")]
    s.boat = vehicle("Vehicle", 0)
    s.ship = vehicle("Vehicle", 1)
    s.airship = vehicle("Vehicle", 2)
    s.test_battlers = [test_battler(ace)]
    s.test_troop_id = 1
    s.battler_name = ""
    s.battler_hue = 0
    s.edit_map_id = 1
    s.terms = terms(ace)
    if ace
      s.japanese = false
      s.currency_unit = "G"
      s.skill_types = [nil, "Special", "Magic"]
      s.weapon_types = [nil, "Dagger", "Sword"]
      s.armor_types = [nil, "General Armor", "Magic Armor"]
      s.title1_name = "Book"
      s.title2_name = ""
      s.opt_draw_title = true
      s.opt_use_midi = false
      s.opt_transparent = false
      s.opt_followers = true
      s.opt_slip_death = false
      s.opt_floor_death = false
      s.opt_display_tp = true
      s.opt_extra_exp = false
      s.window_tone = Tone.new(0, 0, 0)
      s.battleback1_name = "Grassland"
      s.battleback2_name = "Grassland"
    else
      # VX's single game-wide tileset: 8192 passage/priority words.
      passages = Table.new(8192)
      passages[16] = 0x0f
      s.passages = passages
    end
    s
  end

  def vehicle(name, index)
    v = RPG::System::Vehicle.new
    v.character_name = name
    v.character_index = index
    v.bgm = audio(RPG::BGM, "Ship1")
    v.start_map_id = 0
    v.start_x = 0
    v.start_y = 0
    v
  end

  def test_battler(ace)
    b = RPG::System::TestBattler.new
    b.actor_id = 1
    b.level = 1
    if ace
      b.equips = [1, 0, 2, 0, 0]
    else
      b.weapon_id = 1
      b.armor1_id = 0
      b.armor2_id = 2
      b.armor3_id = 0
      b.armor4_id = 0
    end
    b
  end

  def terms(ace)
    t = RPG::System::Terms.new
    if ace
      t.basic = ["Level", "LV", "HP", "HP", "MP", "MP", "TP", "TP"]
      t.params = ["Max HP", "Max MP", "Attack", "Defense",
                  "M.Attack", "M.Defense", "Agility", "Luck"]
      t.etypes = ["Weapon", "Shield", "Head", "Body", "Accessory"]
      t.commands = ["Fight", "Escape", "Attack", "Guard", "Item",
                    "Skill", "Equip", "Status", "Sort", "Save",
                    "Game End", "Weapon", "Armor", "Key Item", "Equip",
                    "Optimize", "Clear", "New Game", "Continue", "Shutdown",
                    "To Title", "Cancel", ""]
    else
      t.level = "Level"
      t.level_a = "LV"
      t.hp = "HP"
      t.hp_a = "HP"
      t.mp = "MP"
      t.mp_a = "MP"
      t.attack = "Attack"
      t.guard = "Guard"
      t.item = "Item"
      t.skill = "Skill"
      t.equip = "Equip"
      t.status = "Status"
      t.save = "Save"
      t.game_end = "End Game"
      t.new_game = "New Game"
      t.continue = "Continue"
      t.shutdown = "Shutdown"
      t.to_title = "To Title"
      t.cancel = "Cancel"
      t.gold = "G"
    end
    t
  end

  def map_info
    i = RPG::MapInfo.new
    i.name = "Field"
    i.parent_id = 0
    i.order = 1
    i.expanded = false
    i.scroll_x = 0
    i.scroll_y = 0
    i
  end

  def map(ace)
    m = RPG::Map.new
    m.width = 17
    m.height = 13
    m.scroll_type = 0
    m.autoplay_bgm = false
    m.bgm = audio(RPG::BGM, "")
    m.autoplay_bgs = false
    m.bgs = audio(RPG::BGS, "")
    m.disable_dashing = false
    m.encounter_step = 30
    m.parallax_name = ""
    m.parallax_loop_x = false
    m.parallax_loop_y = false
    m.parallax_sx = 0
    m.parallax_sy = 0
    m.parallax_show = false
    # VX Ace maps carry a fourth layer of region ids; VX maps have three.
    layers = ace ? 4 : 3
    data = Table.new(m.width, m.height, layers)
    m.height.times { |y| m.width.times { |x| data[x, y, 0] = 2048 } }
    data[3, 3, 1] = 4352
    data[4, 4, layers - 1] = 1
    m.data = data
    m.events = { 1 => event }
    if ace
      m.display_name = "Field"
      m.tileset_id = 1
      m.specify_battleback = false
      m.battleback1_name = ""
      m.battleback2_name = ""
      m.note = ""
      enc = RPG::Map::Encounter.new
      enc.troop_id = 1
      enc.weight = 10
      enc.region_set = []
      m.encounter_list = [enc]
    else
      m.encounter_list = [1]
    end
    m
  end

  def event
    e = RPG::Event.new
    e.id = 1
    e.name = "EV001"
    e.x = 8
    e.y = 6
    e.pages = [event_page]
    e
  end

  def event_page
    p = RPG::Event::Page.new
    c = RPG::Event::Page::Condition.new
    c.switch1_valid = false
    c.switch2_valid = false
    c.variable_valid = false
    c.self_switch_valid = false
    c.item_valid = false
    c.actor_valid = false
    c.switch1_id = 1
    c.switch2_id = 1
    c.variable_id = 1
    c.variable_value = 0
    c.self_switch_ch = "A"
    c.item_id = 1
    c.actor_id = 1
    p.condition = c

    g = RPG::Event::Page::Graphic.new
    g.tile_id = 0
    g.character_name = "People1"
    g.character_index = 2
    g.direction = 2
    g.pattern = 0
    p.graphic = g

    p.move_type = 0
    p.move_speed = 3
    p.move_frequency = 3
    p.move_route = move_route
    p.walk_anime = true
    p.step_anime = false
    p.direction_fix = false
    p.through = false
    p.priority_type = 1
    p.trigger = 0
    p.list = [command(101, ["People1", 2, 0, 2]), command(401, ["Hello."]),
              command(0, [])]
    p
  end

  def move_route
    r = RPG::MoveRoute.new
    r.repeat = true
    r.skippable = false
    r.wait = false
    c = RPG::MoveCommand.new
    c.code = 0
    c.parameters = []
    r.list = [c]
    r
  end

  def command(code, parameters, indent = 0)
    c = RPG::EventCommand.new
    c.code = code
    c.indent = indent
    c.parameters = parameters
    c
  end

  def actor(ace)
    a = RPG::Actor.new
    a.id = 1
    a.name = "Ralph"
    a.class_id = 1
    a.initial_level = 1
    a.character_name = "Actor1"
    a.character_index = 0
    a.face_name = "Actor1"
    a.face_index = 0
    a.note = ""
    if ace
      a.icon_index = 0
      a.description = ""
      a.nickname = "Rookie"
      a.max_level = 99
      a.equips = [1, 0, 2, 0, 0]
      a.features = [feature(22, 0, 0.95)]
    else
      a.exp_basis = 25
      a.exp_inflation = 35
      a.two_swords_style = false
      a.fix_equipment = false
      a.auto_battle = false
      a.super_guard = false
      a.pharmacology = false
      a.critical_bonus = false
      a.weapon_id = 1
      a.armor1_id = 0
      a.armor2_id = 2
      a.armor3_id = 0
      a.armor4_id = 0
      params = Table.new(6, 100)
      (0...100).each do |lv|
        params[0, lv] = 400 + lv * 50
        params[1, lv] = 80 + lv * 10
        (2...6).each { |i| params[i, lv] = 10 + lv }
      end
      a.parameters = params
    end
    a
  end

  def feature(code, data_id, value)
    f = RPG::BaseItem::Feature.new
    f.code = code
    f.data_id = data_id
    f.value = value
    f
  end

  def klass(ace)
    k = RPG::Class.new
    k.id = 1
    k.name = "Hero"
    k.note = ""
    learning = RPG::Class::Learning.new
    learning.level = 3
    learning.skill_id = 1
    learning.note = "" if ace
    k.learnings = [learning]
    if ace
      k.icon_index = 0
      k.description = ""
      k.exp_params = [30, 20, 30, 30]
      params = Table.new(8, 100)
      (0...100).each do |lv|
        params[0, lv] = 400 + lv * 50
        params[1, lv] = 80 + lv * 10
        (2...8).each { |i| params[i, lv] = 10 + lv }
      end
      k.params = params
      k.features = [feature(23, 0, 1), feature(51, 1, 0)]
    else
      k.position = 0
      k.weapon_set = [1]
      k.armor_set = [1, 2, 3, 4]
      k.element_ranks = Table.new(3)
      k.state_ranks = Table.new(3)
      k.skill_name_valid = false
      k.skill_name = ""
    end
    k
  end

  def skill(ace)
    s = RPG::Skill.new
    s.id = 1
    s.name = "Heal"
    s.icon_index = 128
    s.description = "Restores HP."
    s.note = ""
    s.scope = 3
    s.occasion = 0
    s.speed = 0
    s.animation_id = 1
    s.mp_cost = 5
    s.message1 = " casts"
    s.message2 = ""
    if ace
      s.features = []
      s.stype_id = 1
      s.tp_cost = 0
      s.required_wtype_id1 = 0
      s.required_wtype_id2 = 0
      s.success_rate = 100
      s.repeats = 1
      s.tp_gain = 0
      s.hit_type = 0
      s.damage = damage(3, "100 + a.mat * 2")
      s.effects = [effect(11, 0, 0.0, 100)]
    else
      s.hit = 100
      s.common_event_id = 0
      s.base_damage = -100
      s.variance = 20
      s.atk_f = 0
      s.spi_f = 100
      s.physical_attack = false
      s.damage_to_mp = false
      s.absorb_damage = false
      s.ignore_defense = false
      s.element_set = []
      s.plus_state_set = []
      s.minus_state_set = [1]
    end
    s
  end

  def damage(type, formula)
    d = RPG::UsableItem::Damage.new
    d.type = type
    d.element_id = 0
    d.formula = formula
    d.variance = 20
    d.critical = false
    d
  end

  def effect(code, data_id, value1, value2)
    e = RPG::UsableItem::Effect.new
    e.code = code
    e.data_id = data_id
    e.value1 = value1
    e.value2 = value2
    e
  end

  def item(ace)
    i = RPG::Item.new
    i.id = 1
    i.name = "Potion"
    i.icon_index = 176
    i.description = "Restores HP."
    i.note = ""
    i.scope = 7
    i.occasion = 0
    i.speed = 0
    i.animation_id = 1
    i.price = 50
    i.consumable = true
    if ace
      i.features = []
      i.itype_id = 1
      i.success_rate = 100
      i.repeats = 1
      i.tp_gain = 0
      i.hit_type = 0
      i.damage = damage(3, "0")
      i.effects = [effect(11, 0, 0.0, 500)]
    else
      i.common_event_id = 0
      i.base_damage = 0
      i.variance = 0
      i.atk_f = 0
      i.spi_f = 0
      i.physical_attack = false
      i.damage_to_mp = false
      i.absorb_damage = false
      i.ignore_defense = false
      i.element_set = []
      i.plus_state_set = []
      i.minus_state_set = []
      i.hp_recovery_rate = 0
      i.hp_recovery = 500
      i.mp_recovery_rate = 0
      i.mp_recovery = 0
      i.parameter_type = 0
      i.parameter_points = 0
    end
    i
  end

  def weapon(ace)
    w = RPG::Weapon.new
    w.id = 1
    w.name = "Bronze Sword"
    w.icon_index = 96
    w.description = ""
    w.note = ""
    w.price = 300
    w.animation_id = 1
    if ace
      w.etype_id = 0
      w.wtype_id = 2
      w.params = [0, 0, 12, 0, 0, 0, 0, 0]
      w.features = [feature(31, 1, 0)]
    else
      w.hit = 95
      w.atk = 12
      w.def = 0
      w.spi = 0
      w.agi = 0
      w.two_handed = false
      w.fast_attack = false
      w.dual_attack = false
      w.critical_bonus = false
      w.element_set = []
      w.state_set = []
    end
    w
  end

  def armor(ace)
    a = RPG::Armor.new
    a.id = 2
    a.name = "Leather Shield"
    a.icon_index = 128
    a.description = ""
    a.note = ""
    a.price = 300
    if ace
      a.etype_id = 1
      a.atype_id = 1
      a.params = [0, 0, 0, 6, 0, 0, 0, 0]
      a.features = []
    else
      a.kind = 0
      a.eva = 0
      a.atk = 0
      a.def = 6
      a.spi = 0
      a.agi = 0
      a.prevent_critical = false
      a.half_mp_cost = false
      a.double_exp_gain = false
      a.auto_hp_recover = false
      a.element_set = []
      a.state_set = []
    end
    a
  end

  def enemy(ace)
    e = RPG::Enemy.new
    e.id = 1
    e.name = "Slime"
    e.battler_name = "Slime"
    e.battler_hue = 0
    e.exp = 10
    e.gold = 5
    e.note = ""
    action = RPG::Enemy::Action.new
    action.skill_id = 1
    action.condition_type = 0
    action.condition_param1 = 0
    action.condition_param2 = 0
    action.rating = 5
    if ace
      e.icon_index = 0
      e.description = ""
      e.params = [100, 0, 10, 10, 10, 10, 10, 10]
      drop = RPG::Enemy::DropItem.new
      drop.kind = 1
      drop.data_id = 1
      drop.denominator = 4
      e.drop_items = [drop, RPG::Enemy::DropItem.new, RPG::Enemy::DropItem.new]
      e.features = [feature(22, 0, 0.95)]
    else
      e.maxhp = 100
      e.maxmp = 0
      e.atk = 10
      e.def = 10
      e.spi = 10
      e.agi = 10
      e.hit = 95
      e.eva = 5
      e.levitate = false
      e.has_critical = false
      e.element_ranks = Table.new(3)
      e.state_ranks = Table.new(3)
      drop = RPG::Enemy::DropItem.new
      drop.kind = 1
      drop.item_id = 1
      drop.weapon_id = 1
      drop.armor_id = 1
      drop.denominator = 4
      e.drop_item1 = drop
      e.drop_item2 = RPG::Enemy::DropItem.new
      action.kind = 0
      action.basic = 0
    end
    e.actions = [action]
    e
  end

  def troop
    t = RPG::Troop.new
    t.id = 1
    t.name = "Slime*1"
    member = RPG::Troop::Member.new
    member.enemy_id = 1
    member.x = 250
    member.y = 200
    member.hidden = false
    t.members = [member]
    page = RPG::Troop::Page.new
    cond = RPG::Troop::Page::Condition.new
    cond.turn_ending = false
    cond.turn_valid = false
    cond.enemy_valid = false
    cond.actor_valid = false
    cond.switch_valid = false
    cond.turn_a = 0
    cond.turn_b = 0
    cond.enemy_index = 0
    cond.enemy_hp = 50
    cond.actor_id = 1
    cond.actor_hp = 50
    cond.switch_id = 1
    page.condition = cond
    page.span = 0
    page.list = [command(0, [])]
    t.pages = [page]
    t
  end

  def state(ace)
    s = RPG::State.new
    s.id = 1
    s.name = "Knockout"
    s.icon_index = 1
    s.restriction = 4
    s.priority = ace ? 100 : 5
    s.note = ""
    s.message1 = " has fallen."
    s.message2 = ""
    s.message3 = ""
    s.message4 = ""
    if ace
      s.description = ""
      s.features = []
      s.remove_at_battle_end = false
      s.remove_by_restriction = false
      s.auto_removal_timing = 0
      s.min_turns = 1
      s.max_turns = 1
      s.remove_by_damage = false
      s.chance_by_damage = 100
      s.remove_by_walking = false
      s.steps_to_remove = 100
    else
      s.atk_rate = 100
      s.def_rate = 100
      s.spi_rate = 100
      s.agi_rate = 100
      s.nonresistance = false
      s.offset_by_opposite = false
      s.slip_damage = false
      s.reduce_hit_ratio = false
      s.battle_only = false
      s.release_by_damage = false
      s.hold_turn = 0
      s.auto_release_prob = 0
      s.element_set = []
      s.state_set = []
    end
    s
  end

  def animation
    a = RPG::Animation.new
    a.id = 1
    a.name = "Hit"
    a.animation1_name = "Special1"
    a.animation1_hue = 0
    a.animation2_name = ""
    a.animation2_hue = 0
    a.position = 1
    a.frame_max = 1
    frame = RPG::Animation::Frame.new
    frame.cell_max = 1
    frame.cell_data = Table.new(1, 8)
    a.frames = [frame]
    timing = RPG::Animation::Timing.new
    timing.frame = 0
    timing.se = audio(RPG::SE, "Blow1")
    timing.flash_scope = 0
    timing.flash_color = Color.new(255, 255, 255, 255)
    timing.flash_duration = 5
    a.timings = [timing]
    a
  end

  def common_event
    c = RPG::CommonEvent.new
    c.id = 1
    c.name = "Autorun"
    c.trigger = 0
    c.switch_id = 1
    c.list = [command(0, [])]
    c
  end

  def tileset
    t = RPG::Tileset.new
    t.id = 1
    t.mode = 1
    t.name = "Field"
    t.tileset_names = ["TileA1", "TileA2", "TileA3", "TileA4", "TileA5",
                       "TileB", "TileC", "TileD", "TileE"]
    flags = Table.new(8192)
    flags[2048] = 0x000f
    t.flags = flags
    t.note = ""
    t
  end

  def area
    a = RPG::Area.new
    a.id = 1
    a.name = "Plains"
    a.map_id = 1
    a.rect = Rect.new(0, 0, 8, 8)
    a.encounter_list = [1]
    a.order = 1
    a
  end

  # The script bundle: [id, name, zlib-deflated source] sections, exactly as XP
  # stores them. A real VX Ace game's Main is `rgss_main { SceneManager.run }`;
  # this one has the same shape and calls the RGSS2/RGSS3 built-ins a real boot
  # reaches in its first frames — the Kernel#load_data the host installs, the
  # title BGM playing itself, and a frame wait — so running it exercises the
  # whole boot path (see Checker#check_boot).
  def scripts(ext)
    main = "rgss_main do\n" \
           "  system = load_data(\"Data/System#{ext}\")\n" \
           "  $rgss_sample_title = system.game_title\n" \
           "  system.title_bgm.play\n" \
           "  Graphics.wait(3)\n" \
           "  $rgss_sample_booted = true\n" \
           "end\n"
    [[1, "Main", Zlib::Deflate.deflate(main)],
     [2, "", Zlib::Deflate.deflate("# empty section\n")]]
  end
end

# --- Checks ----------------------------------------------------------------

class Checker
  def initialize
    @errors = 0
    @projects = 0
    @events = 0
    @commands = 0
  end

  attr_reader :errors

  def fail(msg)
    @errors += 1
    warn "  FAIL #{msg}"
  end

  def expect(cond, msg)
    fail(msg) unless cond
  end

  # Every check a project must pass, whether generated or real.
  def check_project(dir, expected_edition = nil)
    puts "== #{dir} =="
    edition = RPGVX.detect(dir)
    expect(!edition.nil?, "#{dir}: not detected as a VX / VX Ace project")
    return unless edition
    expect(expected_edition.nil? || edition == expected_edition,
           "#{dir}: detected #{edition}, expected #{expected_edition}")

    db = RPGVX::RGSSData.new(dir)
    expect(db.edition == edition, "#{dir}: database edition mismatch")
    expect(db.ext == RPGVX.data_ext(edition), "#{dir}: wrong data extension")
    check_system(db)
    check_tables(db)
    check_maps(db)
    check_scripts(db)
    audit(db)
    puts "  #{RPGVX.edition_name(edition)}: #{db.summary}"
    @projects += 1
    db
  rescue StandardError => ex
    fail "#{dir}: #{ex.class}: #{ex.message}"
    nil
  end

  def check_system(db)
    sys = db.system
    expect(sys.is_a?(RPG::System), "System is #{sys.class}, not RPG::System")
    expect(sys.start_map_id.to_i > 0, "System.start_map_id must be positive")
    expect(sys.party_members.is_a?(Array) && !sys.party_members.empty?,
           "System.party_members must be a non-empty Array")
    expect(sys.terms.is_a?(RPG::System::Terms), "System.terms missing")
    expect(sys.title_bgm.is_a?(RPG::AudioFile),
           "System.title_bgm must be an AudioFile")
    [sys.boat, sys.ship, sys.airship].each_with_index do |v, i|
      expect(v.is_a?(RPG::System::Vehicle), "System vehicle #{i} missing")
    end
    if db.vxace?
      expect(sys.terms.basic.is_a?(Array) && sys.terms.basic.size >= 8,
             "VX Ace Terms#basic must hold at least 8 entries")
      expect(sys.terms.etypes.is_a?(Array),
             "VX Ace Terms#etypes must be an Array")
    else
      # VX's one game-wide tileset keeps its flags here (VX Ace moved them onto
      # RPG::Tileset#flags), which is the clearest structural difference.
      expect(sys.passages.is_a?(Table), "VX System#passages must be a Table")
      expect(sys.terms.hp.is_a?(String), "VX Terms#hp must be a String")
    end
  end

  def check_tables(db)
    expect(db.actors.is_a?(Array), "Actors must be an Array")
    expect(db.actors[0].nil?, "Actors[0] should be nil (1-based table)")
    db.actors.compact.each do |a|
      expect(a.is_a?(RPG::Actor), "actor #{a.inspect} is not an RPG::Actor")
      expect(a.name.is_a?(String), "actor #{a.id} has no name")
      expect(db.classes[a.class_id.to_i].is_a?(RPG::Class),
             "actor #{a.id}: class_id #{a.class_id} does not resolve")
      if db.vxace?
        expect(a.equips.is_a?(Array), "VX Ace actor #{a.id} needs an equips array")
      else
        expect(a.parameters.is_a?(Table),
               "VX actor #{a.id} parameters must be a Table")
      end
    end

    db.classes.compact.each do |k|
      expect(k.learnings.is_a?(Array), "class #{k.id} learnings must be an Array")
      expect(k.params.is_a?(Table),
             "VX Ace class #{k.id} params must be a Table") if db.vxace?
    end

    db.skills.compact.each do |s|
      if db.vxace?
        expect(s.damage.is_a?(RPG::UsableItem::Damage),
               "VX Ace skill #{s.id} needs a damage formula")
        expect(s.effects.is_a?(Array), "VX Ace skill #{s.id} effects must be an Array")
      end
    end

    # Edition-specific tables: exactly one of them is present.
    if db.vxace?
      expect(db.tilesets.is_a?(Array), "VX Ace needs a Tilesets table")
      expect(db.areas.nil?, "VX Ace has no Areas table")
      db.tilesets.compact.each do |t|
        expect(t.flags.is_a?(Table), "tileset #{t.id} flags must be a Table")
        expect(t.tileset_names.is_a?(Array) && t.tileset_names.size == 9,
               "tileset #{t.id} must name 9 sheets (A1-A5, B-E)")
      end
    else
      expect(db.areas.is_a?(Array), "VX needs an Areas table")
      expect(db.tilesets.nil?, "VX has no Tilesets table")
      db.areas.compact.each do |a|
        expect(a.rect.is_a?(Rect), "area #{a.id} rect must be a Rect")
        expect(db.map_infos.key?(a.map_id) || a.map_id.to_i.zero?,
               "area #{a.id}: map_id #{a.map_id} does not resolve")
      end
    end
  end

  def check_maps(db)
    db.map_infos.each do |id, info|
      expect(info.is_a?(RPG::MapInfo), "MapInfos[#{id}] is not an RPG::MapInfo")
      map = db.load_map(id)
      expect(map.is_a?(RPG::Map), "Map#{id} is not an RPG::Map")
      w = map.width.to_i
      h = map.height.to_i
      expect(w > 0 && h > 0, "Map#{id}: non-positive dimensions #{w}x#{h}")

      tbl = map.data
      expect(tbl.is_a?(Table), "Map#{id}: data is not a Table")
      if tbl.is_a?(Table)
        expect(tbl.xsize == w && tbl.ysize == h,
               "Map#{id}: data #{tbl.xsize}x#{tbl.ysize} != map #{w}x#{h}")
        expect(tbl.data.size == tbl.xsize * tbl.ysize * tbl.zsize,
               "Map#{id}: data payload #{tbl.data.size} != " \
               "#{tbl.xsize}x#{tbl.ysize}x#{tbl.zsize}")
        # VX maps have three layers; VX Ace added a fourth for region ids.
        expect(tbl.zsize == (db.vxace? ? 4 : 3),
               "Map#{id}: #{tbl.zsize} layers, expected #{db.vxace? ? 4 : 3}")
      end

      if db.vxace?
        expect(db.tilesets[map.tileset_id.to_i].is_a?(RPG::Tileset),
               "Map#{id}: tileset_id #{map.tileset_id} does not resolve")
        (map.encounter_list || []).each do |enc|
          expect(enc.is_a?(RPG::Map::Encounter),
                 "Map#{id}: encounter #{enc.inspect} is not an RPG::Map::Encounter")
          expect(db.troops[enc.troop_id.to_i].is_a?(RPG::Troop),
                 "Map#{id}: encounter troop #{enc.troop_id} does not resolve")
        end
      else
        (map.encounter_list || []).each do |troop_id|
          expect(db.troops[troop_id.to_i].is_a?(RPG::Troop),
                 "Map#{id}: encounter troop #{troop_id} does not resolve")
        end
      end

      check_events(id, map)
    end
  end

  def check_events(map_id, map)
    (map.events || {}).each do |eid, ev|
      expect(ev.is_a?(RPG::Event), "Map#{map_id} event #{eid} is not an RPG::Event")
      expect(ev.pages.is_a?(Array) && !ev.pages.empty?,
             "Map#{map_id} event #{eid} has no pages")
      (ev.pages || []).each do |page|
        @events += 1
        expect(page.condition.is_a?(RPG::Event::Page::Condition),
               "Map#{map_id} event #{eid}: page condition missing")
        expect(page.graphic.is_a?(RPG::Event::Page::Graphic),
               "Map#{map_id} event #{eid}: page graphic missing")
        expect(page.move_route.is_a?(RPG::MoveRoute),
               "Map#{map_id} event #{eid}: page move route missing")
        (page.list || []).each do |cmd|
          expect(cmd.is_a?(RPG::EventCommand),
                 "Map#{map_id} event #{eid}: command #{cmd.inspect} is not an " \
                 "RPG::EventCommand")
          @commands += 1
        end
      end
    end
  end

  # The bundle decodes into named sections of Ruby source (the script host runs
  # exactly this).
  def check_scripts(db)
    expect(db.scripts?, "project reports no script bundle")
    sections = db.scripts
    expect(!sections.empty?, "script bundle decoded to nothing")
    sections.each do |name, source|
      expect(name.is_a?(String), "script section name #{name.inspect} is not a String")
      expect(source.is_a?(String), "script section #{name.inspect} did not inflate")
    end
  end

  # Boot the project the way src/main.cxx does: construct the shell (which
  # detects the edition and loads the database) and let the RGSS script host —
  # the default boot path — drive the game's own scripts to completion, then do
  # it again with the RGSS_SCRIPT_HOST opt-out set. The sample's Main section
  # reads the database back through the host's Kernel#load_data and drives three
  # frames, so this covers detection -> database -> host -> per-frame Fiber
  # driver end to end.
  def check_boot(dir, edition, title)
    $rgss_sample_booted = nil
    $rgss_sample_title = nil
    RGSS::Graphics.reset_frames
    RGSS::Audio.reset
    previous = ENV["RGSS_SCRIPT_HOST"]

    # Host explicitly off (RGSS_SCRIPT_HOST=0, the opt-out from its default-on):
    # the shell must load the database, report the pending built-in flow and
    # return — not run anything, and not hang.
    ENV["RGSS_SCRIPT_HOST"] = "0"
    RGSS.window_title = nil
    with_game_dir(dir) do
      game = RPGVX.new([])
      expect(game.db.is_a?(RPGVX::RGSSData), "boot: no database without the script host")
      game.start
    end
    expect($rgss_sample_booted.nil?,
           "boot: the bundled scripts ran even though the host is disabled")

    # Host on because nothing said otherwise — the default a real boot gets.
    ENV.delete("RGSS_SCRIPT_HOST")
    with_game_dir(dir) do
      game = RPGVX.new([])
      expect(game.edition == edition,
             "boot: shell detected #{game.edition.inspect}, expected #{edition.inspect}")
      expect(game.title == title,
             "boot: shell title #{game.title.inspect}, expected #{title.inspect}")
      game.start
    end
    # The window is named after the loaded game, not left as the engine's own
    # caption (mruby-rpgvx/mrblib/lib.rb, include/terminal.hxx's window title
    # bridge).
    expect(RGSS.window_title == title,
           "boot: window title #{RGSS.window_title.inspect}, expected #{title.inspect}")
    expect($rgss_sample_booted == true, "boot: the bundled Main section did not run")
    expect($rgss_sample_title == title,
           "boot: Kernel#load_data returned #{$rgss_sample_title.inspect} " \
           "from inside the scripts")
    expect(RGSS::Graphics.frames == 3,
           "boot: #{RGSS::Graphics.frames} frames driven, expected 3")
    # The RGSS2/RGSS3 built-ins the scripts called on the way: the title BGM
    # played itself through RPG::BGM#play (rgss2_runtime.rb) and is remembered
    # as the channel's last record.
    expect(RGSS::Audio.played == [[:bgm_play, "Theme1", 100, 100, 0]],
           "boot: title BGM did not reach Audio (got #{RGSS::Audio.played.inspect})")
    expect(RPG::BGM.last.name == "Theme1",
           "boot: RPG::BGM.last is #{RPG::BGM.last.name.inspect}, expected \"Theme1\"")
    expect(RGSS::Graphics.width == RPGVX::WIDTH &&
           RGSS::Graphics.height == RPGVX::HEIGHT,
           "boot: the shell did not declare VX's screen size to Graphics")
    puts "  boot: script host ran the bundled scripts over " \
         "#{RGSS::Graphics.frames} frames (rgss_main, load_data, " \
         "RPG::BGM#play, Graphics.wait)"
  rescue StandardError => ex
    fail "#{dir}: boot raised: #{ex.class}: #{ex.message}"
  ensure
    previous.nil? ? ENV.delete("RGSS_SCRIPT_HOST") : ENV["RGSS_SCRIPT_HOST"] = previous
  end

  # GAME_DIR is a load-time constant in the real build (src/main.cxx defines it
  # per run); rebind it around a boot so several projects can be checked in one
  # process.
  def with_game_dir(dir)
    Object.send(:remove_const, :GAME_DIR) if Object.const_defined?(:GAME_DIR)
    Object.const_set(:GAME_DIR, dir)
    yield
  end

  # Walk the loaded database and check that every instance variable the data
  # carries has a reader in our schema. This is the check that catches a field
  # the RGSS2/RGSS3 transcription missed — trivially true for the generated beds,
  # and the whole point when this is pointed at a real game.
  def audit(db)
    seen = {}
    missing = {}
    roots = [db.system, db.map_infos] +
            RPGVX::RGSSData::ALL_FILES.map { |name| db.send(name) }
    db.map_infos.each_key { |id| roots << db.load_map(id) }
    roots.each { |root| audit_value(root, seen, missing) }
    missing.each do |klass, fields|
      fail "#{klass} has no accessor for #{fields.keys.sort.join(", ")}"
    end
  end

  def audit_value(value, seen, missing)
    case value
    when Array then value.each { |v| audit_value(v, seen, missing) }
    when Hash then value.each_value { |v| audit_value(v, seen, missing) }
    else
      return unless value.class.name.to_s.start_with?("RPG::")
      return if seen.key?(value.object_id)
      seen[value.object_id] = true
      value.instance_variables.each do |ivar|
        reader = ivar.to_s[1..-1]
        unless value.respond_to?(reader)
          (missing[value.class.name] ||= {})[reader] = true
        end
        audit_value(value.instance_variable_get(ivar), seen, missing)
      end
    end
  end

  # Pack a loose project into its edition's encrypted archive and load the whole
  # database back through it: a packed release ships no loose Data/ at all, so
  # this is the only path such a game has.
  def check_archive(dir, disk)
    return unless disk
    edition = disk.edition
    ext = disk.ext
    files = Dir[File.join(dir, "Data", "*#{ext}")].sort.map do |f|
      ["Data\\#{File.basename(f)}", File.binread(f)]
    end
    # A released game packs its Graphics/ tree in the same archive as its Data/,
    # and that is the only copy — nothing is loose on disk. Pack one so the
    # asset side of the archive is covered too. (A 3x2 XYZ: palette 0 is
    # (10,20,30), 1 red, 2 green. Decoding it is mruby-rgss's job and is tested
    # there; what matters here is that a game's own '/'-spelled name resolves.)
    graphic = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
              "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
              "\x8b\x02\x41".b
    graphic_entry = "Graphics\\System\\Window.xyz"
    files += [[graphic_entry, graphic]]
    archive_name = RPGVX.info(edition)[:archive]
    archive = edition == :vxace ? RPGXP::RGSSAD.pack_v3(files)
                                : RPGXP::RGSSAD.pack_v1(files)

    reader = RPGXP::RGSSAD.new(archive)
    expect(reader.version == (edition == :vxace ? 3 : 1),
           "#{archive_name}: unexpected archive version #{reader.version}")
    files.each do |name, bytes|
      expect(reader.read(name) == bytes,
             "#{archive_name} entry #{name} did not round-trip byte-for-byte")
    end

    Dir.mktmpdir do |tmp|
      File.binwrite(File.join(tmp, archive_name), archive)
      File.write(File.join(tmp, "Game.ini"), "[Game]\nTitle=Packed\n")
      packed = RPGVX::RGSSData.new(tmp) # no loose Data/ -> uses the archive
      expect(packed.archived?, "#{archive_name}: packed project should report archived?")
      expect(packed.edition == edition,
             "#{archive_name}: packed project detected as #{packed.edition}")
      expect(packed.system.game_title == disk.system.game_title,
             "#{archive_name}: System.game_title differs from on-disk")
      expect(packed.actors.compact.size == disk.actors.compact.size,
             "#{archive_name}: Actors count differs from on-disk")
      expect(packed.scripts.size == disk.scripts.size,
             "#{archive_name}: script section count differs from on-disk")
      disk.map_infos.each_key do |id|
        pm = packed.load_map(id)
        dm = disk.load_map(id)
        expect(pm.width == dm.width && pm.height == dm.height,
               "#{archive_name}: Map#{id} dimensions differ from on-disk")
      end
      # RGSS never writes into the archive: save_data always lands on disk.
      packed.save_object({ "slot" => 1 }, "Save1#{ext}")
      expect(packed.read_object("Save1#{ext}") == { "slot" => 1 },
             "#{archive_name}: save_object/read_object round-trip failed")

      # The asset half. A game asks for a graphic by its bare, '/'-spelled name
      # (`Cache.system("Window")` -> `Bitmap.new("Graphics/System/Window")`), so
      # the archive has to answer that spelling, and the boot shell has to have
      # registered the archive for the loaders to reach at all — nothing else
      # threads a handle down to Bitmap.new.
      expect(packed.archive.read("Graphics/System/Window.xyz") == graphic,
             "#{archive_name}: a packed graphic did not read back by its " \
             "'/'-spelled name")
      RGSS.asset_archive = nil
      begin
        with_game_dir(tmp) { RPGVX.new([]) }
        expect(RGSS.asset_archive.equal?(packed.archive) ||
               (!RGSS.asset_archive.nil? &&
                RGSS.asset_archive.read("Graphics/System/Window.xyz") == graphic),
               "#{archive_name}: booting a packed project did not register the " \
               "archive with RGSS.asset_archive, so its Graphics/ is unreachable")
      ensure
        RGSS.asset_archive = nil
      end
    end
    puts "  archive: packed #{files.size} entries (Data/ + a graphic); DB and " \
         "assets both load through #{archive_name}"
  rescue StandardError => ex
    fail "#{dir}: archive check raised: #{ex.class}: #{ex.message}"
  end

  def report
    puts "checked #{@projects} project(s), #{@events} event pages, " \
         "#{@commands} event commands"
    if @errors.zero?
      puts "OK: all VX / VX Ace data parsed cleanly"
    else
      warn "#{@errors} error(s)"
    end
  end
end

# --- Entry point -----------------------------------------------------------

def discover_games(root)
  return [] unless Dir.exist?(root)
  %w[rvdata rvdata2].flat_map do |ext|
    Dir.glob(File.join(root, "**", "Data", "System.#{ext}"))
  end.map { |f| File.dirname(File.dirname(f)) }.sort.uniq
end

if ARGV[0] == "--write"
  out = ARGV[1] || File.join(ROOT, "data")
  [[:vx, "vx-sample"], [:vxace, "vxace-sample"]].each do |edition, name|
    dir = File.join(out, name)
    Sample.build(dir, edition)
    puts "wrote #{RPGVX.edition_name(edition)} sample to #{dir}"
  end
  exit 0
end

checker = Checker.new

# The generated beds: one per edition, loose then packed.
Dir.mktmpdir("rpgvx-check") do |tmp|
  { vx: "VX Sample", vxace: "Ace Sample" }.each do |edition, title|
    dir = Sample.build(File.join(tmp, edition.to_s), edition)
    db = checker.check_project(dir, edition)
    checker.check_archive(dir, db)
    checker.check_boot(dir, edition, title)
  end
end

# Any real project handed to us, plus whatever is unpacked under ./data.
games = ARGV.dup
games = discover_games(File.join(ROOT, "data")) if games.empty?
games.each do |dir|
  db = checker.check_project(dir)
  checker.check_archive(dir, db)
end
puts "no real VX / VX Ace test bed found (pass a GAME_DIR to check one)" if games.empty?

checker.report
exit(checker.errors.zero? ? 0 : 1)
