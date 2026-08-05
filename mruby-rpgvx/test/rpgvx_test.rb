# Unit tests for the RPG Maker VX / VX Ace layer that need no display and no
# game on disk: edition detection, the per-edition file mapping and the
# RGSS2/RGSS3 schema's Marshal round-trip (the real games load the same classes
# through mruby-marshal). The on-disk and encrypted-archive paths — which need a
# project tree — are driven by scripts/rpgvx_testbed_check.rb.

# The boot shell reads GAME_DIR when a game is constructed; nothing tested here
# does, but define a stand-in so the constant is never missing.
GAME_DIR = "" unless Object.const_defined?(:GAME_DIR)

# ---- Edition detection ----------------------------------------------------

assert "RPGVX.edition_for identifies unpacked projects" do
  assert_equal :vxace, RPGVX.edition_for(["Game.ini", "Data/System.rvdata2"])
  assert_equal :vx, RPGVX.edition_for(["Game.ini", "Data/System.rvdata"])
  # An XP project (or anything else) is not ours.
  assert_nil RPGVX.edition_for(["Game.ini", "Data/System.rxdata"])
  assert_nil RPGVX.edition_for([])
end

assert "RPGVX.edition_for identifies packed releases by their archive" do
  # A packed release ships no loose Data/ at all, so the archive name is the
  # only edition marker.
  assert_equal :vxace, RPGVX.edition_for(["Game.ini", "Game.rgss3a"])
  assert_equal :vx, RPGVX.edition_for(["Game.ini", "Game.rgss2a"])
  # XP's own archive is not a VX marker.
  assert_nil RPGVX.edition_for(["Game.ini", "Game.rgssad"])
end

assert "RPGVX.edition_for prefers VX Ace when a project carries both" do
  present = ["Data/System.rvdata", "Data/System.rvdata2"]
  assert_equal :vxace, RPGVX.edition_for(present)
end

assert "RPGVX edition metadata" do
  assert_equal ".rvdata2", RPGVX.data_ext(:vxace)
  assert_equal ".rvdata", RPGVX.data_ext(:vx)
  assert_equal "RPG Maker VX Ace", RPGVX.edition_name(:vxace)
  assert_equal "Game.rgss2a", RPGVX.info(:vx)[:archive]
  assert_equal 3, RPGVX.info(:vxace)[:rgss]
  assert_raise(RuntimeError) { RPGVX.info(:mv) }
end

assert "RPGVX screen geometry is VX's 544x416" do
  assert_equal 544, RPGVX::WIDTH
  assert_equal 416, RPGVX::HEIGHT
  assert_equal 32, RPGVX::TILE
end

assert "RGSSData maps the edition-specific database tables" do
  # VX has areas and no tilesets (one game-wide tileset, flags in System);
  # VX Ace dropped areas and added per-map tilesets.
  assert_equal({ areas: "Areas" }, RPGVX::RGSSData::EDITION_FILES[:vx])
  assert_equal({ tilesets: "Tilesets" }, RPGVX::RGSSData::EDITION_FILES[:vxace])
  assert_true RPGVX::RGSSData::ALL_FILES.include?(:actors)
  assert_true RPGVX::RGSSData::ALL_FILES.include?(:areas)
  assert_true RPGVX::RGSSData::ALL_FILES.include?(:tilesets)
  # Every table is readable on the instance, whichever edition is loaded.
  RPGVX::RGSSData::ALL_FILES.each do |name|
    assert_true RPGVX::RGSSData.method_defined?(name), "no reader for #{name}"
  end
end

# ---- RGSS2 (VX) schema ----------------------------------------------------

assert "VX RPG::System Marshal round-trip" do
  sys = RPG::System.new
  sys.game_title = "VX Test"
  sys.start_map_id = 1
  sys.start_x = 8
  sys.start_y = 6
  sys.party_members = [1, 2]
  sys.passages = Table.new(8192)
  sys.passages[16] = 0x0f

  bgm = RPG::BGM.new
  bgm.name = "Theme1"
  bgm.volume = 100
  bgm.pitch = 100
  sys.title_bgm = bgm

  boat = RPG::System::Vehicle.new
  boat.character_name = "Vehicle"
  boat.character_index = 0
  boat.start_map_id = 1
  sys.boat = boat

  terms = RPG::System::Terms.new
  terms.hp = "HP"
  terms.new_game = "New Game"
  terms.gold = "G"
  sys.terms = terms

  loaded = Marshal.load(Marshal.dump(sys))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "VX Test", loaded.game_title
  assert_equal [1, 2], loaded.party_members
  assert_true loaded.title_bgm.is_a?(RPG::BGM)
  assert_true loaded.title_bgm.is_a?(RPG::AudioFile)
  assert_equal "Theme1", loaded.title_bgm.name
  assert_true loaded.passages.is_a?(Table)
  assert_equal 0x0f, loaded.passages[16]
  assert_equal 0, loaded.passages[17]
  assert_equal "Vehicle", loaded.boat.character_name
  assert_equal "New Game", loaded.terms.new_game
end

assert "VX RPG::Actor keeps its stats table and equipment ids" do
  actor = RPG::Actor.new
  actor.id = 1
  actor.name = "Ralph"
  actor.class_id = 1
  actor.initial_level = 1
  actor.character_name = "Actor1"
  actor.character_index = 0
  actor.face_name = "Actor1"
  actor.face_index = 0
  actor.weapon_id = 1
  actor.armor1_id = 2
  actor.parameters = Table.new(6, 100)
  actor.parameters[0, 1] = 450
  actor.parameters[1, 1] = 80

  loaded = Marshal.load(Marshal.dump(actor))
  assert_equal "Ralph", loaded.name
  assert_equal 0, loaded.character_index
  assert_equal 1, loaded.weapon_id
  assert_true loaded.parameters.is_a?(Table)
  assert_equal 450, loaded.parameters[0, 1]
  assert_equal 80, loaded.parameters[1, 1]
end

assert "VX RPG::Skill carries the fixed damage fields" do
  skill = RPG::Skill.new
  skill.id = 1
  skill.name = "Heal"
  skill.icon_index = 128
  skill.scope = 3
  skill.mp_cost = 5
  skill.base_damage = -100
  skill.spi_f = 100
  skill.variance = 20
  skill.plus_state_set = []
  skill.minus_state_set = [3]

  loaded = Marshal.load(Marshal.dump(skill))
  assert_equal "Heal", loaded.name
  assert_equal 128, loaded.icon_index
  assert_equal 5, loaded.mp_cost
  assert_equal(-100, loaded.base_damage)
  assert_equal [3], loaded.minus_state_set
  # RGSS3-only fields simply read back nil on a VX record.
  assert_nil loaded.damage
  assert_nil loaded.features
end

assert "VX RPG::Map is a three-layer table with plain troop encounters" do
  map = RPG::Map.new
  map.width = 3
  map.height = 2
  map.encounter_list = [1, 1, 2]
  map.encounter_step = 30
  map.parallax_name = "BlueSky"
  map.parallax_loop_x = true
  map.data = Table.new(3, 2, 3)
  map.data[0, 0, 0] = 1536
  map.data[2, 1, 2] = 20
  map.events = {}

  loaded = Marshal.load(Marshal.dump(map))
  assert_equal 3, loaded.width
  assert_equal [1, 1, 2], loaded.encounter_list
  assert_true loaded.parallax_loop_x
  assert_equal 1536, loaded.data[0, 0, 0]
  assert_equal 20, loaded.data[2, 1, 2]
  assert_nil loaded.tileset_id   # VX has one game-wide tileset
end

assert "VX RPG::Area round-trips its rectangle" do
  area = RPG::Area.new
  area.id = 1
  area.name = "Forest"
  area.map_id = 2
  area.order = 1
  area.rect = Rect.new(0, 0, 5, 4)
  area.encounter_list = [3]

  loaded = Marshal.load(Marshal.dump(area))
  assert_equal "Forest", loaded.name
  assert_equal 2, loaded.map_id
  assert_true loaded.rect.is_a?(Rect)
  assert_equal 5, loaded.rect.width
  assert_equal [3], loaded.encounter_list
end

# ---- RGSS3 (VX Ace) schema ------------------------------------------------

assert "VX Ace RPG::System Marshal round-trip" do
  sys = RPG::System.new
  sys.game_title = "Ace Test"
  sys.start_map_id = 1
  sys.start_x = 10
  sys.start_y = 8
  sys.party_members = [1]
  sys.currency_unit = "G"
  sys.title1_name = "Book"
  sys.title2_name = ""
  sys.opt_draw_title = true
  sys.window_tone = Tone.new(0, 0, 0)
  sys.skill_types = [nil, "Special", "Magic"]
  se = RPG::SE.new
  se.name = "Cursor1"
  se.volume = 80
  sys.sounds = [se]

  terms = RPG::System::Terms.new
  terms.basic = ["Level", "LV", "HP", "HP", "MP", "MP", "TP", "TP"]
  terms.params = ["Max HP", "Max MP", "Attack", "Defense",
                  "M.Attack", "M.Defense", "Agility", "Luck"]
  terms.etypes = ["Weapon", "Shield", "Head", "Body", "Accessory"]
  terms.commands = ["Fight", "Escape"]
  sys.terms = terms

  loaded = Marshal.load(Marshal.dump(sys))
  assert_equal "Ace Test", loaded.game_title
  assert_equal "Book", loaded.title1_name
  assert_true loaded.opt_draw_title
  assert_true loaded.window_tone.is_a?(Tone)
  assert_equal "Magic", loaded.skill_types[2]
  assert_true loaded.sounds[0].is_a?(RPG::SE)
  assert_equal "Cursor1", loaded.sounds[0].name
  assert_equal "HP", loaded.terms.basic[2]
  assert_equal "Accessory", loaded.terms.etypes[4]
end

assert "VX Ace records carry BaseItem features" do
  actor = RPG::Actor.new
  actor.id = 1
  actor.name = "Eric"
  actor.nickname = "Hero"
  actor.class_id = 1
  actor.initial_level = 1
  actor.max_level = 99
  actor.equips = [1, 0, 2, 0, 0]
  actor.note = "note"
  f = RPG::BaseItem::Feature.new
  f.code = 22
  f.data_id = 0
  f.value = 0.95
  actor.features = [f]

  loaded = Marshal.load(Marshal.dump(actor))
  assert_equal "Hero", loaded.nickname
  assert_equal 99, loaded.max_level
  assert_equal [1, 0, 2, 0, 0], loaded.equips
  assert_true loaded.features[0].is_a?(RPG::BaseItem::Feature)
  assert_equal 22, loaded.features[0].code
  assert_equal 0.95, loaded.features[0].value
end

assert "VX Ace RPG::Class holds the exp curve and the stat table" do
  klass = RPG::Class.new
  klass.id = 1
  klass.name = "Hero"
  klass.exp_params = [30, 20, 30, 30]
  klass.params = Table.new(8, 100)
  klass.params[0, 1] = 450
  klass.params[2, 1] = 22
  learning = RPG::Class::Learning.new
  learning.level = 3
  learning.skill_id = 5
  learning.note = ""
  klass.learnings = [learning]

  loaded = Marshal.load(Marshal.dump(klass))
  assert_equal [30, 20, 30, 30], loaded.exp_params
  assert_equal 450, loaded.params[0, 1]
  assert_equal 22, loaded.params[2, 1]
  assert_equal 3, loaded.learnings[0].level
  assert_equal 5, loaded.learnings[0].skill_id
end

assert "VX Ace usable items carry a damage formula and effects" do
  skill = RPG::Skill.new
  skill.id = 1
  skill.name = "Fire"
  skill.stype_id = 1
  skill.mp_cost = 5
  skill.tp_cost = 0
  skill.scope = 1
  skill.hit_type = 2
  damage = RPG::UsableItem::Damage.new
  damage.type = 1
  damage.element_id = 3
  damage.formula = "100 + a.mat * 2 - b.mdf * 2"
  damage.variance = 20
  damage.critical = false
  skill.damage = damage
  effect = RPG::UsableItem::Effect.new
  effect.code = 21   # add state
  effect.data_id = 4
  effect.value1 = 1.0
  effect.value2 = 0
  skill.effects = [effect]

  loaded = Marshal.load(Marshal.dump(skill))
  assert_true loaded.damage.is_a?(RPG::UsableItem::Damage)
  assert_equal "100 + a.mat * 2 - b.mdf * 2", loaded.damage.formula
  assert_equal 3, loaded.damage.element_id
  assert_false loaded.damage.critical
  assert_true loaded.effects[0].is_a?(RPG::UsableItem::Effect)
  assert_equal 21, loaded.effects[0].code
  assert_equal 4, loaded.effects[0].data_id
end

assert "VX Ace RPG::Tileset round-trips its sheet names and flags" do
  ts = RPG::Tileset.new
  ts.id = 1
  ts.mode = 1
  ts.name = "Field"
  ts.tileset_names = ["TileA1", "TileA2", "TileA3", "TileA4", "TileA5",
                      "TileB", "TileC", "TileD", "TileE"]
  ts.flags = Table.new(8192)
  ts.flags[2048] = 0x000f
  ts.note = ""

  loaded = Marshal.load(Marshal.dump(ts))
  assert_equal "Field", loaded.name
  assert_equal 9, loaded.tileset_names.size
  assert_equal "TileB", loaded.tileset_names[5]
  assert_true loaded.flags.is_a?(Table)
  assert_equal 0x000f, loaded.flags[2048]
end

assert "VX Ace RPG::Map keeps four layers and weighted encounters" do
  map = RPG::Map.new
  map.display_name = "Town"
  map.tileset_id = 1
  map.width = 2
  map.height = 2
  map.note = ""
  enc = RPG::Map::Encounter.new
  enc.troop_id = 1
  enc.weight = 10
  enc.region_set = [1, 2]
  map.encounter_list = [enc]
  map.data = Table.new(2, 2, 4)
  map.data[0, 0, 0] = 2048
  map.data[1, 1, 3] = 5     # region id, the fourth layer
  map.events = {}

  loaded = Marshal.load(Marshal.dump(map))
  assert_equal "Town", loaded.display_name
  assert_equal 1, loaded.tileset_id
  assert_true loaded.encounter_list[0].is_a?(RPG::Map::Encounter)
  assert_equal 10, loaded.encounter_list[0].weight
  assert_equal [1, 2], loaded.encounter_list[0].region_set
  assert_equal 2048, loaded.data[0, 0, 0]
  assert_equal 5, loaded.data[1, 1, 3]
end

assert "VX / VX Ace events select a character by index and priority type" do
  ev = RPG::Event.new
  ev.id = 1
  ev.name = "EV001"
  ev.x = 4
  ev.y = 5

  page = RPG::Event::Page.new
  cond = RPG::Event::Page::Condition.new
  cond.switch1_valid = true
  cond.switch1_id = 3
  cond.item_valid = false
  cond.actor_valid = false
  page.condition = cond

  gfx = RPG::Event::Page::Graphic.new
  gfx.character_name = "People1"
  gfx.character_index = 5
  gfx.direction = 2
  gfx.pattern = 0
  gfx.tile_id = 0
  page.graphic = gfx

  page.priority_type = 1
  page.trigger = 0
  cmd = RPG::EventCommand.new
  cmd.code = 101
  cmd.indent = 0
  cmd.parameters = ["Actor1", 0, 0, 2]
  page.list = [cmd]
  route = RPG::MoveRoute.new
  route.repeat = true
  route.skippable = false
  route.wait = false
  mc = RPG::MoveCommand.new
  mc.code = 1
  mc.parameters = []
  route.list = [mc]
  page.move_route = route
  ev.pages = [page]

  loaded = Marshal.load(Marshal.dump(ev))
  assert_equal "EV001", loaded.name
  assert_equal 5, loaded.pages[0].graphic.character_index
  assert_equal 1, loaded.pages[0].priority_type
  assert_true loaded.pages[0].condition.switch1_valid
  assert_equal 3, loaded.pages[0].condition.switch1_id
  assert_equal 101, loaded.pages[0].list[0].code
  assert_equal ["Actor1", 0, 0, 2], loaded.pages[0].list[0].parameters
  assert_equal 1, loaded.pages[0].move_route.list[0].code
end

assert "VX Ace enemies carry the params array and drop table" do
  enemy = RPG::Enemy.new
  enemy.id = 1
  enemy.name = "Slime"
  enemy.battler_name = "Slime"
  enemy.params = [100, 0, 10, 10, 10, 10, 10, 10]
  enemy.exp = 10
  enemy.gold = 5
  drop = RPG::Enemy::DropItem.new
  drop.kind = 1
  drop.data_id = 3
  drop.denominator = 4
  enemy.drop_items = [drop]
  action = RPG::Enemy::Action.new
  action.skill_id = 1
  action.condition_type = 0
  action.rating = 5
  enemy.actions = [action]

  loaded = Marshal.load(Marshal.dump(enemy))
  assert_equal [100, 0, 10, 10, 10, 10, 10, 10], loaded.params
  assert_equal 3, loaded.drop_items[0].data_id
  assert_equal 4, loaded.drop_items[0].denominator
  assert_equal 5, loaded.actions[0].rating
end

# ---- RGSS2 / RGSS3 built-ins ----------------------------------------------

# The audio records play themselves in RGSS2/RGSS3 ($game_system.battle_bgm.play).
# Capture what reaches RGSS::Audio; the native backend is absent here anyway, and
# what is under test is the routing, the volume/pitch defaults and the
# "last played" bookkeeping.
#
# The overrides only capture while a capture list is installed (inside
# vx_capture_audio) and otherwise call straight through, so this file can never
# disturb another gem's audio test whatever order the suites run in.
class << RGSS::Audio
  alias _vx_bgm_play_orig bgm_play
  alias _vx_bgm_stop_orig bgm_stop
  alias _vx_bgm_fade_orig bgm_fade
  alias _vx_se_play_orig se_play
  alias _vx_me_play_orig me_play

  def bgm_play(name, volume = 100, pitch = 100)
    return _vx_bgm_play_orig(name, volume, pitch) unless $vx_audio.is_a?(Array)
    $vx_audio << [:bgm_play, name, volume, pitch]
    nil
  end

  def bgm_stop
    return _vx_bgm_stop_orig unless $vx_audio.is_a?(Array)
    $vx_audio << [:bgm_stop]
    nil
  end

  def bgm_fade(time)
    return _vx_bgm_fade_orig(time) unless $vx_audio.is_a?(Array)
    $vx_audio << [:bgm_fade, time]
    nil
  end

  def se_play(name, volume = 100, pitch = 100)
    return _vx_se_play_orig(name, volume, pitch) unless $vx_audio.is_a?(Array)
    $vx_audio << [:se_play, name, volume, pitch]
    nil
  end

  def me_play(name, volume = 100, pitch = 100)
    return _vx_me_play_orig(name, volume, pitch) unless $vx_audio.is_a?(Array)
    $vx_audio << [:me_play, name, volume, pitch]
    nil
  end
end

# Run a block with the audio capture installed; answers what was played.
def vx_capture_audio
  $vx_audio = []
  yield
  $vx_audio
ensure
  $vx_audio = nil
end

def vx_bgm(name, volume = nil, pitch = nil)
  bgm = RPG::BGM.new
  bgm.name = name
  bgm.volume = volume
  bgm.pitch = pitch
  bgm
end

assert "RPG::BGM plays itself through RGSS::Audio" do
  played = vx_capture_audio { vx_bgm("Theme1", 80, 110).play }
  assert_equal [[:bgm_play, "Theme1", 80, 110]], played
  # The record's own volume/pitch are the defaults, and a record with neither
  # falls back to RGSS's 100/100.
  played = vx_capture_audio { vx_bgm("Theme2").play }
  assert_equal [[:bgm_play, "Theme2", 100, 100]], played
end

assert "RPG::BGM tracks the last played record" do
  vx_capture_audio { vx_bgm("Field1", 90, 100).play }
  assert_equal "Field1", RPG::BGM.last.name
  assert_equal 90, RPG::BGM.last.volume

  # #replay plays the same record again (RGSS3 resumes the map BGM this way).
  played = vx_capture_audio { RPG::BGM.last.replay }
  assert_equal [[:bgm_play, "Field1", 90, 100]], played

  # Fading or stopping the channel clears it, so `last.name` is readable and
  # empty rather than stale.
  played = vx_capture_audio { RPG::BGM.fade(1000) }
  assert_equal [[:bgm_fade, 1000]], played
  assert_equal "", RPG::BGM.last.name
end

assert "a nameless RPG::BGM stops the channel instead of playing silence" do
  assert_equal [[:bgm_stop]], vx_capture_audio { vx_bgm("").play }
  assert_equal [[:bgm_stop]], vx_capture_audio { vx_bgm(nil).play }
end

assert "RPG::SE and RPG::ME play through their own channels" do
  se = RPG::SE.new
  se.name = "Cursor1"
  se.volume = 60
  assert_equal [[:se_play, "Cursor1", 60, 100]], vx_capture_audio { se.play }
  # An SE is fire-and-forget: RGSS reports no "last SE".
  assert_equal "", RPG::SE.last.name

  me = RPG::ME.new
  me.name = "Victory1"
  assert_equal [[:me_play, "Victory1", 100, 100]], vx_capture_audio { me.play }
  assert_equal "Victory1", RPG::ME.last.name
end

assert "RGSS3 Kernel built-ins" do
  # `rgss_main { SceneManager.run }` is the whole Main section of a VX Ace
  # project, so the host must supply it.
  assert_equal 7, rgss_main { 7 }
  # rgss_stop ends the game loop (the driver treats RGSS::Timeout as a clean
  # end) rather than blocking the per-frame Fiber forever.
  assert_raise(RGSS::Timeout) { rgss_stop }
  # The RGSS2+ debug boxes have no dialog here; they log and return nil.
  assert_nil msgbox("hello ", 1)
  assert_nil msgbox_p([1, 2])
end

# ---- Encrypted archives ---------------------------------------------------

assert "a VX database survives its .rgss2a (v1) archive" do
  sys = RPG::System.new
  sys.game_title = "Packed VX"
  sys.start_map_id = 4
  blob = Marshal.dump(sys)

  a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.pack_v1([["Data\\System.rvdata", blob]]))
  assert_equal 1, a.version
  loaded = Marshal.load(a.read("Data/System.rvdata"))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "Packed VX", loaded.game_title
  assert_equal 4, loaded.start_map_id
end

assert "a VX Ace database survives its .rgss3a (v3) archive" do
  sys = RPG::System.new
  sys.game_title = "Packed Ace"
  sys.start_map_id = 7
  blob = Marshal.dump(sys)

  a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.pack_v3([["Data\\System.rvdata2", blob]]))
  assert_equal 3, a.version
  loaded = Marshal.load(a.read("Data/System.rvdata2"))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "Packed Ace", loaded.game_title
  assert_equal 7, loaded.start_map_id
end
