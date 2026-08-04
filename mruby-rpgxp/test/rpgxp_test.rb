# Unit tests for the RPG Maker XP runtime pieces that do not need a display:
# the RGSS data schema's Marshal round-trip (the real games load the same classes
# via mruby-marshal), tileset passability, the follow camera, CharSet frame
# geometry and the save/load state serialisation. The full data layer is also
# smoke-tested against a real project by scripts/rpgxp_testbed_check.rb.

# The scene sources touch GAME_DIR when loading graphics; the logic under test
# here never does, but define stand-ins so nothing is undefined.
GAME_DIR = "" unless Object.const_defined?(:GAME_DIR)
RTP_DIR = "" unless Object.const_defined?(:RTP_DIR)

# Minimal database stand-in exposing just the accessors the runtime reads.
class FakeDB
  def initialize(actors: [], tilesets: [], classes: [])
    @actors = actors
    @tilesets = tilesets
    @classes = classes
  end
  attr_reader :actors, :tilesets, :classes
end

assert "RPG schema Marshal round-trip" do
  sys = RPG::System.new
  sys.title_name = "001-Title01"
  sys.windowskin_name = "001-Blue01"
  sys.start_map_id = 1
  sys.start_x = 9
  sys.start_y = 7
  sys.party_members = [1, 2, 7, 8]

  bgm = RPG::AudioFile.new
  bgm.name = "064-Slow07"
  bgm.volume = 80
  bgm.pitch = 100
  sys.title_bgm = bgm

  words = RPG::System::Words.new
  words.gold = "G"
  words.hp = "HP"
  sys.words = words

  loaded = Marshal.load(Marshal.dump(sys))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "001-Title01", loaded.title_name
  assert_equal [1, 2, 7, 8], loaded.party_members
  assert_equal 1, loaded.start_map_id
  assert_true loaded.title_bgm.is_a?(RPG::AudioFile)
  assert_equal "064-Slow07", loaded.title_bgm.name
  assert_equal 80, loaded.title_bgm.volume
  assert_true loaded.words.is_a?(RPG::System::Words)
  assert_equal "G", loaded.words.gold
end

assert "RPG::Map + Table Marshal round-trip" do
  map = RPG::Map.new
  map.width = 2
  map.height = 2
  map.tileset_id = 1
  data = Table.new(2, 2, 3)
  data[0, 0, 0] = 384
  data[1, 1, 2] = 400
  map.data = data
  map.events = {}

  loaded = Marshal.load(Marshal.dump(map))
  assert_equal 2, loaded.width
  assert_true loaded.data.is_a?(Table)
  assert_equal 384, loaded.data[0, 0, 0]
  assert_equal 400, loaded.data[1, 1, 2]
  assert_equal 0, loaded.data[1, 0, 0]
end

assert "Game::TileSet passability from the passages table" do
  passages = Table.new(528)
  passages[10] = 0x00        # freely passable
  passages[20] = 0x0f        # fully impassable
  passages[30] = 0x01        # blocks moving down only

  ts = RPG::Tileset.new
  ts.id = 1
  ts.passages = passages
  db = FakeDB.new(tilesets: [nil, ts])
  tileset = RPGXP::Game::TileSet.new(db, 1)

  map = RPG::Map.new
  map.width = 4
  map.height = 1
  data = Table.new(4, 1, 3)
  data[0, 0, 0] = 10         # passable ground
  data[1, 0, 0] = 20         # impassable ground
  data[2, 0, 0] = 10         # passable ground ...
  data[2, 0, 1] = 30         # ... with a "block down" tile on layer 1
  # cell 3 left empty (all layers 0) -> void, not walkable
  map.data = data

  assert_true  tileset.passable?(map, 0, 0, 2) # onto plain ground: ok
  assert_false tileset.passable?(map, 1, 0, 2) # onto impassable: blocked
  assert_false tileset.passable?(map, 2, 0, 2) # blocked moving down
  assert_true  tileset.passable?(map, 2, 0, 8) # but passable moving up
  assert_false tileset.passable?(map, 3, 0, 2) # void cell: not walkable
end

assert "Game.camera_offset clamps to the map edges" do
  # Map narrower than the screen never scrolls.
  assert_equal 0, RPGXP::Game.camera_offset(100, 640, 320)
  # Near the left edge clamps to 0.
  assert_equal 0, RPGXP::Game.camera_offset(100, 640, 2000)
  # In the middle centres the focus.
  assert_equal 1180, RPGXP::Game.camera_offset(1500, 640, 2000)
  # Near the right edge clamps to (world - screen).
  assert_equal 1360, RPGXP::Game.camera_offset(1900, 640, 2000)
end

assert "Game::CharSet frame geometry (4x4 sheet)" do
  sheet = Bitmap.new(128, 128) # 32x32 cells
  assert_equal 32, RPGXP::Game::CharSet.cell_width(sheet)
  assert_equal 32, RPGXP::Game::CharSet.cell_height(sheet)

  # Facing left (row 1), pattern 2 -> src rect (64, 32, 32, 32).
  r = RPGXP::Game::CharSet.frame_rect(sheet, 4, 2)
  assert_equal 64, r.x
  assert_equal 32, r.y
  assert_equal 32, r.width
  assert_equal 32, r.height

  # Facing down (row 0), pattern 0 -> origin.
  r0 = RPGXP::Game::CharSet.frame_rect(sheet, 2, 0)
  assert_equal 0, r0.x
  assert_equal 0, r0.y
end

assert "Game::NumberInput edits digits and reads the value back" do
  ni = RPGXP::Game::NumberInput.new(3)
  assert_equal 3, ni.digits
  assert_equal 0, ni.cursor
  assert_equal 0, ni.value

  ni.inc                     # leftmost digit -> 1
  ni.right                   # move to middle
  ni.inc; ni.inc            # middle -> 2
  ni.right                   # rightmost
  ni.inc; ni.inc; ni.inc; ni.inc; ni.inc # -> 5
  assert_equal 125, ni.value

  # Down wraps 0 -> 9; cursor clamps at both ends.
  z = RPGXP::Game::NumberInput.new(2)
  z.dec                      # 0 -> 9
  assert_equal 90, z.value
  z.left                     # already at 0: no move
  assert_equal 0, z.cursor
  z.right; z.right           # clamps at the last digit
  assert_equal 1, z.cursor

  # Digit count is clamped to a sane range.
  assert_equal 1, RPGXP::Game::NumberInput.new(0).digits
  assert_equal RPGXP::Game::NumberInput::MAX_DIGITS,
               RPGXP::Game::NumberInput.new(99).digits
end

assert "Game::State save/load round-trip" do
  db = FakeDB.new(actors: [nil, "a1", "a2"])
  state = RPGXP::Game::State.new(db, [1, 2], 5, 9, 7, 4)
  state.switches[3] = true
  state.variables[10] = 42
  state.gain_item(1, 3)
  state.gain_weapon(2, 1)
  state.gain_armor(4, 5)

  h = state.to_h
  loaded = RPGXP::Game::State.load(db, Marshal.load(Marshal.dump(h)))
  assert_equal 5, loaded.map_id
  assert_equal 9, loaded.x
  assert_equal 7, loaded.y
  assert_equal 4, loaded.direction
  assert_equal [1, 2], loaded.party
  assert_true loaded.switches[3]
  assert_equal 42, loaded.variables[10]
  assert_equal 3, loaded.item_count(1)
  assert_equal 1, loaded.weapon_count(2)
  assert_equal 5, loaded.armor_count(4)
  # Default-valued stores still behave after load.
  assert_false loaded.switches[999]
  assert_equal 0, loaded.variables[999]
  assert_equal 0, loaded.item_count(999)
end

# ---- Event system: page selection + interpreter ---------------------------

# Build an RPG::EventCommand (code / indent / parameters).
def cmd(code, params = [], indent = 0)
  c = RPG::EventCommand.new
  c.code = code
  c.indent = indent
  c.parameters = params
  c
end

# Resolver stand-in for Call Common Event.
class TestResolver
  def initialize(commons)
    @commons = commons
  end

  def common_event_list(id)
    ce = @commons[id]
    ce && ce.list
  end
end

def new_state
  RPGXP::Game::State.new(FakeDB.new, [1], 1, 0, 0)
end

def run_to_end(state, list, resolver = nil)
  it = RPGXP::Game::Interpreter.new(state)
  it.resolver = resolver
  it.start(list, 1, 7)
  it.update
  it
end

def make_condition(fields = {})
  c = RPG::Event::Page::Condition.new
  c.switch1_valid = fields[:switch1_valid] || false
  c.switch1_id = fields[:switch1_id] || 1
  c.switch2_valid = fields[:switch2_valid] || false
  c.switch2_id = fields[:switch2_id] || 1
  c.variable_valid = fields[:variable_valid] || false
  c.variable_id = fields[:variable_id] || 1
  c.variable_value = fields[:variable_value] || 0
  c.self_switch_valid = fields[:self_switch_valid] || false
  c.self_switch_ch = fields[:self_switch_ch] || "A"
  c
end

def make_page(condition)
  p = RPG::Event::Page.new
  p.condition = condition
  p
end

assert "EventPage.select picks the highest satisfied page" do
  no_self = ->(_ch) { false }
  p0 = make_page(make_condition)                                   # always on
  p1 = make_page(make_condition(switch1_valid: true, switch1_id: 5))
  pages = [p0, p1]

  sw = Hash.new(false)
  vars = Hash.new(0)
  # Switch 5 off: page 1's condition fails, so page 0 is active.
  assert_equal p0, RPGXP::Game::EventPage.select(pages, sw, vars, no_self)
  # Switch 5 on: page 1 (higher) wins.
  sw[5] = true
  assert_equal p1, RPGXP::Game::EventPage.select(pages, sw, vars, no_self)
end

assert "EventPage.select honours variable and self-switch conditions" do
  vars = Hash.new(0)
  sw = Hash.new(false)
  var_page = make_page(make_condition(variable_valid: true, variable_id: 3, variable_value: 10))
  base = make_page(make_condition)
  pages = [base, var_page]
  assert_equal base, RPGXP::Game::EventPage.select(pages, sw, vars, ->(_c) { false })
  vars[3] = 10
  assert_equal var_page, RPGXP::Game::EventPage.select(pages, sw, vars, ->(_c) { false })

  self_page = make_page(make_condition(self_switch_valid: true, self_switch_ch: "B"))
  pages2 = [base, self_page]
  assert_equal base, RPGXP::Game::EventPage.select(pages2, sw, vars, ->(ch) { ch == "A" })
  assert_equal self_page, RPGXP::Game::EventPage.select(pages2, sw, vars, ->(ch) { ch == "B" })
end

assert "Interpreter: control switches / variables / gold" do
  s = new_state
  run_to_end(s, [
    cmd(121, [5, 5, 0]),          # switch 5 ON
    cmd(121, [6, 7, 0]),          # switches 6..7 ON
    cmd(122, [1, 1, 0, 0, 42]),   # var 1 = 42
    cmd(122, [1, 1, 1, 0, 8]),    # var 1 += 8
    cmd(125, [0, 0, 100])         # gold += 100
  ])
  assert_true s.switches[5]
  assert_true s.switches[6]
  assert_true s.switches[7]
  assert_equal 50, s.variables[1]
  assert_equal 100, s.gold
end

assert "Interpreter: change items / weapons / armor (const + variable)" do
  s = new_state
  s.variables[4] = 7
  run_to_end(s, [
    cmd(126, [3, 0, 0, 5], 0),   # item 3 += 5
    cmd(126, [3, 1, 0, 2], 0),   # item 3 -= 2  -> 3
    cmd(126, [9, 0, 1, 4], 0),   # item 9 += var4 (7)
    cmd(127, [1, 0, 0, 1], 0),   # weapon 1 += 1
    cmd(128, [2, 0, 0, 4], 0)    # armor 2 += 4
  ])
  assert_equal 3, s.item_count(3)
  assert_equal 7, s.item_count(9)
  assert_equal 1, s.weapon_count(1)
  assert_equal 4, s.armor_count(2)
  # Possession clamps to 0..99.
  s.gain_item(3, -100)
  assert_equal 0, s.item_count(3)
  s.gain_item(5, 250)
  assert_equal 99, s.item_count(5)
end

assert "Interpreter: item / weapon / armor conditional branches" do
  list = [
    cmd(111, [8, 3], 0),        # if has item 3
    cmd(121, [1, 1, 0], 1),     #   switch 1 ON
    cmd(412, [], 0),
    cmd(111, [9, 1], 0),        # if has weapon 1
    cmd(121, [2, 2, 0], 1),     #   switch 2 ON
    cmd(412, [], 0),
    cmd(111, [10, 2], 0),       # if has armor 2
    cmd(121, [3, 3, 0], 1),     #   switch 3 ON
    cmd(412, [], 0)
  ]
  s = new_state
  s.gain_item(3, 1)
  s.gain_weapon(1, 1)
  run_to_end(s, list)
  assert_true s.switches[1]     # holds item 3
  assert_true s.switches[2]     # holds weapon 1
  assert_false s.switches[3]    # lacks armor 2
end

assert "Interpreter: control variable from item count" do
  s = new_state
  s.gain_item(5, 12)
  run_to_end(s, [cmd(122, [1, 1, 0, 3, 5], 0)]) # var1 = count of item 5
  assert_equal 12, s.variables[1]
end

assert "Interpreter: change party member and actor-in-party condition" do
  s = new_state # party starts as [1]
  run_to_end(s, [
    cmd(129, [2, 0, 0], 0),   # add actor 2
    cmd(129, [3, 0, 0], 0),   # add actor 3
    cmd(129, [1, 1, 0], 0)    # remove actor 1
  ])
  assert_equal [2, 3], s.party
  run_to_end(s, [cmd(129, [2, 0, 0], 0)]) # adding a duplicate is a no-op
  assert_equal [2, 3], s.party

  s2 = new_state # party [1]
  run_to_end(s2, [
    cmd(111, [4, 1, 0], 0),   # if actor 1 in party
    cmd(121, [1, 1, 0], 1),   #   switch 1 ON
    cmd(412, [], 0),
    cmd(111, [4, 9, 0], 0),   # if actor 9 in party
    cmd(121, [2, 2, 0], 1),   #   switch 2 ON
    cmd(412, [], 0)
  ])
  assert_true s2.switches[1]   # actor 1 is in party
  assert_false s2.switches[2]  # actor 9 is not
end

# A FakeDB whose actor 1 (Aluxes) is level 3 of class 1, wearing weapon 7 and
# armor 11, with the class teaching skill 50 at level 2 and skill 60 at level 4.
def xp_actor_db
  a = RPG::Actor.new
  a.id = 1; a.name = "Aluxes"; a.class_id = 1
  a.initial_level = 3; a.final_level = 5
  a.weapon_id = 7; a.armor1_id = 11
  a.armor2_id = 0; a.armor3_id = 0; a.armor4_id = 0
  prm = Table.new(6, 6)                 # 6 params x levels 0..5
  prm[0, 3] = 100; prm[1, 3] = 30; prm[2, 3] = 12
  prm[3, 3] = 10;  prm[4, 3] = 8;  prm[5, 3] = 6
  a.parameters = prm
  cls = RPG::Class.new; cls.id = 1
  l1 = RPG::Class::Learning.new; l1.level = 2; l1.skill_id = 50
  l2 = RPG::Class::Learning.new; l2.level = 4; l2.skill_id = 60
  cls.learnings = [l1, l2]
  FakeDB.new(actors: [nil, a], classes: [nil, cls])
end

assert "Game::Actor derives stats, skills and equipment from the database" do
  a = RPGXP::Game::Actor.new(xp_actor_db, 1)
  assert_equal 3, a.level
  assert_equal 100, a.max_hp
  assert_equal 30, a.max_sp
  assert_equal 12, a.str
  assert_equal 6, a.int
  assert_equal "Aluxes", a.name
  assert_equal 100, a.hp                 # HP/SP start full
  assert_equal 30, a.sp
  assert_equal [50], a.skills            # only the learning at level <= 3
  assert_true  a.knows_skill?(50)
  assert_false a.knows_skill?(60)
  assert_true  a.weapon_equipped?(7)
  assert_false a.weapon_equipped?(8)
  assert_true  a.armor_equipped?(11)
  assert_false a.armor_equipped?(12)
end

assert "Interpreter: actor skill / weapon / armor / name conditionals" do
  s = RPGXP::Game::State.new(xp_actor_db, [1], 1, 0, 0)
  # State#actor memoises one live actor per id.
  assert_true s.actor(1).equal?(s.actor(1))
  assert_nil s.actor(99)
  run_to_end(s, [
    cmd(111, [4, 1, 2, 50], 0), cmd(121, [1, 1, 0], 1), cmd(412, [], 0), # knows skill 50
    cmd(111, [4, 1, 2, 60], 0), cmd(121, [2, 2, 0], 1), cmd(412, [], 0), # not skill 60
    cmd(111, [4, 1, 3, 7], 0),  cmd(121, [3, 3, 0], 1), cmd(412, [], 0), # weapon 7
    cmd(111, [4, 1, 4, 11], 0), cmd(121, [4, 4, 0], 1), cmd(412, [], 0), # armor 11
    cmd(111, [4, 1, 1, "Aluxes"], 0), cmd(121, [5, 5, 0], 1), cmd(412, [], 0), # name is
    cmd(111, [4, 1, 4, 99], 0), cmd(121, [6, 6, 0], 1), cmd(412, [], 0)  # not armor 99
  ])
  assert_true  s.switches[1]   # skill 50 learned
  assert_false s.switches[2]   # skill 60 not learned (class teaches it at level 4)
  assert_true  s.switches[3]   # weapon 7 equipped
  assert_true  s.switches[4]   # armor 11 equipped
  assert_true  s.switches[5]   # name matches
  assert_false s.switches[6]   # armor 99 not equipped
end

# Like xp_actor_db but with a full parameters table (levels 0..7, max HP =
# 50 + 20/level) and a class that teaches skill 50 at level 2 and 60 at level 5,
# for exercising the Change Actor commands (level-ups, stat regrowth).
def xp_change_db
  a = RPG::Actor.new
  a.id = 1; a.name = "Aluxes"; a.class_id = 1
  a.initial_level = 3; a.final_level = 6
  a.exp_basis = 30; a.exp_inflation = 30      # so the EXP curve is non-trivial
  a.weapon_id = 7; a.armor1_id = 11
  a.armor2_id = 0; a.armor3_id = 0; a.armor4_id = 0
  prm = Table.new(6, 8)
  lv = 0
  while lv < 8
    prm[0, lv] = 50 + lv * 20; prm[1, lv] = 10 + lv * 5; prm[2, lv] = 5 + lv
    prm[3, lv] = 4; prm[4, lv] = 3; prm[5, lv] = 2
    lv += 1
  end
  a.parameters = prm
  cls = RPG::Class.new; cls.id = 1
  l1 = RPG::Class::Learning.new; l1.level = 2; l1.skill_id = 50
  l2 = RPG::Class::Learning.new; l2.level = 5; l2.skill_id = 60
  cls.learnings = [l1, l2]
  FakeDB.new(actors: [nil, a], classes: [nil, cls])
end

assert "Interpreter: Change HP / SP / Recover All" do
  s = RPGXP::Game::State.new(xp_change_db, [1], 1, 0, 0)
  a = s.actor(1)                                   # level 3: max HP 110, max SP 25
  run_to_end(s, [cmd(311, [0, 1, 1, 0, 40, false], 0)])  # HP -40
  assert_equal 70, a.hp
  run_to_end(s, [cmd(311, [0, 1, 1, 0, 999, false], 0)]) # can't knock out -> floor 1
  assert_equal 1, a.hp
  run_to_end(s, [cmd(311, [0, 1, 1, 0, 999, true], 0)])  # knockout allowed -> 0
  assert_equal 0, a.hp
  run_to_end(s, [cmd(312, [0, 1, 1, 0, 20], 0)])         # SP -20 (25 -> 5)
  assert_equal 5, a.sp
  run_to_end(s, [cmd(314, [0, 1], 0)])                   # Recover All
  assert_equal 110, a.hp
  assert_equal 25, a.sp
end

assert "Interpreter: Change Level learns skills and regrows stats" do
  s = RPGXP::Game::State.new(xp_change_db, [1], 1, 0, 0)
  a = s.actor(1)
  assert_false a.knows_skill?(60)
  run_to_end(s, [cmd(316, [0, 1, 0, 0, 2], 0)])          # level +2 -> 5
  assert_equal 5, a.level
  assert_true a.knows_skill?(50)                          # kept
  assert_true a.knows_skill?(60)                          # learned at level 5
  assert_equal 150, a.max_hp                              # 50 + 5*20
  # Change Level realigns EXP to the new level's threshold (RMXP level=).
  assert_equal a.exp_for_level(5), a.exp
end

assert "Interpreter: Change EXP levels up (learning skills) and down (keeping them)" do
  s = RPGXP::Game::State.new(xp_change_db, [1], 1, 0, 0)
  a = s.actor(1)                                           # starts level 3
  need = a.exp_for_level(5) - a.exp                        # EXP to reach level 5
  run_to_end(s, [cmd(315, [0, 1, 0, 0, need], 0)])         # gain EXP
  assert_equal 5, a.level
  assert_true a.knows_skill?(60)                           # learned at level 5
  # Losing that EXP drops the level again; learned skills are kept (RMXP).
  run_to_end(s, [cmd(315, [0, 1, 1, 0, need], 0)])         # lose the same EXP
  assert_equal 3, a.level
  assert_true a.knows_skill?(60)
end

assert "Interpreter: Change Skills / Change Equipment (via a variable-held id)" do
  s = RPGXP::Game::State.new(xp_change_db, [1], 1, 0, 0)
  a = s.actor(1)
  s.variables[9] = 1                                      # actor id in variable 9
  run_to_end(s, [cmd(318, [1, 9, 0, 99], 0)])            # learn skill 99 (variable target)
  assert_true a.knows_skill?(99)
  run_to_end(s, [cmd(318, [0, 1, 1, 50], 0)])            # forget skill 50
  assert_false a.knows_skill?(50)
  run_to_end(s, [cmd(319, [0, 1, 0, 8], 0)])             # weapon slot 0 -> 8
  assert_equal 8, a.weapon_id
  run_to_end(s, [cmd(319, [0, 1, 3, 33], 0)])            # armor slot 3 -> 33
  assert_equal 33, a.armor3_id
  run_to_end(s, [cmd(319, [0, 1, 0, 0], 0)])             # remove the weapon
  assert_equal 0, a.weapon_id
end

assert "Game::State save round-trip preserves mutated actor state" do
  s = RPGXP::Game::State.new(xp_change_db, [1], 1, 0, 0)
  a = s.actor(1)
  run_to_end(s, [cmd(316, [0, 1, 0, 0, 2], 0)])          # level 5
  run_to_end(s, [cmd(311, [0, 1, 1, 0, 30, true], 0)])   # HP -30
  run_to_end(s, [cmd(318, [0, 1, 0, 77], 0)])            # learn skill 77
  run_to_end(s, [cmd(319, [0, 1, 1, 44], 0)])            # armor1 -> 44
  loaded = RPGXP::Game::State.load(xp_change_db, Marshal.load(Marshal.dump(s.to_h)))
  b = loaded.actor(1)
  assert_equal a.level, b.level
  assert_equal a.hp, b.hp
  assert_equal a.sp, b.sp
  assert_equal a.skills.sort, b.skills.sort
  assert_equal a.weapon_id, b.weapon_id
  assert_equal a.armor1_id, b.armor1_id
end

assert "Interpreter: control variables from game quantities" do
  s = new_state # map_id 1, party [1]
  s.gold = 250
  run_to_end(s, [
    cmd(122, [1, 1, 0, 7, 0], 0),   # var1 = map id (1)
    cmd(122, [2, 2, 0, 7, 1], 0),   # var2 = party size (1)
    cmd(122, [3, 3, 0, 7, 2], 0)    # var3 = gold (250)
  ])
  assert_equal 1, s.variables[1]
  assert_equal 1, s.variables[2]
  assert_equal 250, s.variables[3]
end

assert "Interpreter: erase event surfaces a one-shot request without pausing" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(116, [], 0),          # erase this event
    cmd(121, [4, 4, 0], 0)    # then switch 4 ON (proves it kept running)
  ], 1, 7)
  it.update
  assert_true s.switches[4]           # ran the command after the erase
  assert_true it.take_erase_request   # the erase was requested
  assert_false it.take_erase_request  # ... and the flag cleared on read

  # A common event with no event context requests no erase.
  it2 = RPGXP::Game::Interpreter.new(s)
  it2.start([cmd(116, [], 0)], 1, nil)
  it2.update
  assert_false it2.take_erase_request
end

assert "Interpreter: conditional branch true and else" do
  # Switch 5 ON -> true branch sets switch 1; else sets switch 2.
  list = [
    cmd(111, [0, 5, 0], 0),
    cmd(121, [1, 1, 0], 1),
    cmd(411, [], 0),
    cmd(121, [2, 2, 0], 1),
    cmd(412, [], 0)
  ]
  on = new_state
  on.switches[5] = true
  run_to_end(on, list)
  assert_true on.switches[1]
  assert_false on.switches[2]

  off = new_state
  run_to_end(off, list)
  assert_false off.switches[1]
  assert_true off.switches[2]
end

assert "Interpreter: show choices runs the chosen branch" do
  list = [
    cmd(102, [["Yes", "No"], 1], 0),
    cmd(402, [0, "Yes"], 0),
    cmd(121, [1, 1, 0], 1),         # Yes -> switch 1
    cmd(402, [1, "No"], 0),
    cmd(121, [2, 2, 0], 1),         # No  -> switch 2
    cmd(404, [], 0),
    cmd(121, [3, 3, 0], 0)          # after: switch 3 (always)
  ]

  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start(list, 1, 7)
  it.update
  assert_true it.waiting?
  assert_equal :choice, it.wait_kind
  assert_equal ["Yes", "No"], it.choice_labels
  it.choose(0)
  assert_true s.switches[1]
  assert_false s.switches[2]
  assert_true s.switches[3]

  s2 = new_state
  it2 = RPGXP::Game::Interpreter.new(s2)
  it2.start(list, 1, 7)
  it2.update
  it2.choose(1)
  assert_false s2.switches[1]
  assert_true s2.switches[2]
  assert_true s2.switches[3]
end

# Battle Processing (301) with all three result branches (601/602/603) at the
# command's own indent, terminated by 604, then an always-run command after.
def battle_list
  [
    cmd(301, [1, true, true], 0),   # Battle Processing troop 1, can escape/lose
    cmd(601, [], 0),                # If Win
    cmd(121, [1, 1, 0], 1),         #   switch 1 ON
    cmd(602, [], 0),                # If Escape
    cmd(121, [2, 2, 0], 1),         #   switch 2 ON
    cmd(603, [], 0),                # If Lose
    cmd(121, [3, 3, 0], 1),         #   switch 3 ON
    cmd(604, [], 0),                # Branch End
    cmd(121, [4, 4, 0], 0)          # after the block (always runs)
  ]
end

def run_battle(outcome)
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.battle_outcome = outcome
  it.start(battle_list, 1, 7)
  it.update
  s
end

assert "Interpreter: battle processing runs only the matching result branch" do
  # Default outcome is a win: only the win branch runs, then the after command.
  win = run_battle(:win)
  assert_true  win.switches[1]
  assert_false win.switches[2]
  assert_false win.switches[3]
  assert_true  win.switches[4]

  esc = run_battle(:escape)
  assert_false esc.switches[1]
  assert_true  esc.switches[2]
  assert_false esc.switches[3]
  assert_true  esc.switches[4]

  lose = run_battle(:lose)
  assert_false lose.switches[1]
  assert_false lose.switches[2]
  assert_true  lose.switches[3]
  assert_true  lose.switches[4]

  # A fresh interpreter defaults to :win without setting battle_outcome.
  s = new_state
  run_to_end(s, battle_list)
  assert_true  s.switches[1]
  assert_false s.switches[2]
  assert_true  s.switches[4]
end

assert "Interpreter: battle processing skips a block missing the branch" do
  # can_lose off -> no 603 branch; resolving as :lose skips the whole block but
  # still runs the command after 604.
  list = [
    cmd(301, [1, true, false], 0),  # can escape, cannot lose
    cmd(601, [], 0),                # If Win
    cmd(121, [1, 1, 0], 1),         #   switch 1 ON
    cmd(602, [], 0),                # If Escape
    cmd(121, [2, 2, 0], 1),         #   switch 2 ON
    cmd(604, [], 0),                # Branch End (no If Lose)
    cmd(121, [4, 4, 0], 0)          # after the block
  ]
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.battle_outcome = :lose
  it.start(list, 1, 7)
  it.update
  assert_false s.switches[1]
  assert_false s.switches[2]
  assert_true  s.switches[4]       # fell through to after the block
  assert_false it.running?
end

assert "Interpreter: loop with break counts to a threshold" do
  s = new_state
  run_to_end(s, [
    cmd(122, [1, 1, 0, 0, 0], 0),     # var1 = 0
    cmd(112, [], 0),                  # loop
    cmd(122, [1, 1, 1, 0, 1], 1),     #   var1 += 1
    cmd(111, [1, 1, 0, 3, 3], 1),     #   if var1 > 3
    cmd(113, [], 2),                  #     break
    cmd(412, [], 1),                  #   end
    cmd(413, [], 0)                   # repeat
  ])
  assert_equal 4, s.variables[1]
end

assert "Interpreter: label and jump" do
  s = new_state
  run_to_end(s, [
    cmd(122, [1, 1, 0, 0, 0], 0),     # var1 = 0
    cmd(118, ["top"], 0),             # label top
    cmd(122, [1, 1, 1, 0, 1], 0),     # var1 += 1
    cmd(111, [1, 1, 0, 3, 4], 0),     # if var1 < 3
    cmd(119, ["top"], 1),             #   jump top
    cmd(412, [], 0)
  ])
  assert_equal 3, s.variables[1]
end

assert "Interpreter: call common event" do
  common = RPG::CommonEvent.new
  common.id = 1
  common.list = [cmd(121, [9, 9, 0], 0)]     # switch 9 ON
  resolver = TestResolver.new([nil, common])
  s = new_state
  run_to_end(s, [cmd(117, [1], 0)], resolver)
  assert_true s.switches[9]
end

assert "Interpreter: self switch set and read back" do
  s = new_state
  run_to_end(s, [cmd(123, ["A", 0])])         # self switch A ON for event 7
  assert_true s.self_switch(1, 7, "A")
  assert_false s.self_switch(1, 7, "B")
end

assert "Interpreter: show text surfaces message lines" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(101, ["Hello"], 0),
    cmd(401, ["World"], 0)
  ], 1, 7)
  it.update
  assert_true it.waiting?
  assert_equal :message, it.wait_kind
  assert_equal ["Hello", "World"], it.message_lines
  it.resume
  assert_false it.running?
end

assert "Interpreter: transfer player surfaces a teleport request" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([cmd(201, [0, 3, 8, 9, 2, 0], 0)], 1, 7)
  it.update
  assert_true it.waiting?
  assert_equal :teleport, it.wait_kind
  assert_equal [3, 8, 9, 2], it.teleport
end

# Build an RPG::MoveCommand (code / parameters).
def mv(code, params = [])
  c = RPG::MoveCommand.new
  c.code = code
  c.parameters = params
  c
end

# Build an RPG::MoveRoute (list of MoveCommands + repeat/skippable flags).
def move_route(list, repeat = false, skippable = false)
  r = RPG::MoveRoute.new
  r.list = list
  r.repeat = repeat
  r.skippable = skippable
  r
end

assert "Interpreter: set move route queues a request without pausing" do
  s = new_state
  route = move_route([mv(1)]) # Move Down
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(209, [-1, route], 0),      # Set Move Route -> player
    cmd(121, [5, 5, 0], 0)         # then switch 5 ON (proves it did not pause)
  ], 1, 7)
  it.update
  assert_false it.waiting?          # a move route does not suspend the interpreter
  assert_true s.switches[5]         # ran the command after it
  reqs = it.take_move_route_requests
  assert_equal 1, reqs.size
  assert_equal :player, reqs[0][:target]
  assert_equal route, reqs[0][:route]
  # Draining empties the queue.
  assert_true it.take_move_route_requests.empty?
end

assert "Interpreter: set move route resolves the target" do
  s = new_state
  # Target 0 ("this event") resolves to the running event id (7).
  it = RPGXP::Game::Interpreter.new(s)
  it.start([cmd(209, [0, move_route([mv(4)])], 0)], 1, 7)
  it.update
  reqs = it.take_move_route_requests
  assert_equal 1, reqs.size
  assert_equal 7, reqs[0][:target]

  # A positive id passes straight through.
  it2 = RPGXP::Game::Interpreter.new(s)
  it2.start([cmd(209, [3, move_route([mv(4)])], 0)], 1, 7)
  it2.update
  assert_equal 3, it2.take_move_route_requests[0][:target]

  # "This event" from a common event with no event context is dropped.
  it3 = RPGXP::Game::Interpreter.new(s)
  it3.start([cmd(209, [0, move_route([mv(4)])], 0)], 1, nil)
  it3.update
  assert_true it3.take_move_route_requests.empty?

  # A request with no route object is dropped.
  it4 = RPGXP::Game::Interpreter.new(s)
  it4.start([cmd(209, [-1, nil], 0)], 1, 7)
  it4.update
  assert_true it4.take_move_route_requests.empty?
end

assert "Interpreter: input number surfaces a request and stores the result" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(103, [4, 3], 0),           # input into variable 4, 3 digits
    cmd(121, [1, 1, 0], 0)         # then switch 1 ON
  ], 1, 7)
  it.update
  assert_true it.waiting?
  assert_equal :number, it.wait_kind
  assert_equal 4, it.input_variable
  assert_equal 3, it.input_digits
  it.resume_number(275)
  assert_equal 275, s.variables[4]  # stored into the variable
  assert_true s.switches[1]         # resumed past the input command
  assert_false it.running?
end

# ---- RGSSAD encrypted archive reader --------------------------------------

assert "RGSSAD v1 round-trips entries (names, binary data, key advances)" do
  files = [
    ["Data\\System.rxdata", "sys\x00\x01\xfe\xff data"],
    ["Data\\Map001.rxdata", (("A".."Z").to_a.join) * 100], # spans 4-byte key steps
    ["Graphics\\Titles\\001-Title01.png", "\x89PNG\r\n\x1a\n"]
  ]
  archive = RPGXP::RGSSAD.pack_v1(files)
  a = RPGXP::RGSSAD.new(archive)

  assert_equal 1, a.version
  assert_equal 3, a.names.size
  files.each do |name, data|
    # Compare bytes so the check is encoding-agnostic (mruby strings are bytes;
    # CRuby would otherwise flag a binary vs UTF-8 literal mismatch).
    assert_equal data.bytes, a.read(name).bytes
  end
  # '/'-style lookups normalise to the archive's '\' names.
  assert_equal files[0][1].bytes, a.read("Data/System.rxdata").bytes
  assert_true a.include?("Data/Map001.rxdata")
  assert_false a.include?("Data/Missing.rxdata")
  assert_true a.read("Data/Missing.rxdata").nil?
end

assert "RGSSAD carries real Marshal data through the archive" do
  sys = RPG::System.new
  sys.title_name = "001-Title01"
  sys.start_map_id = 7
  blob = Marshal.dump(sys)

  a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.pack_v1([["Data\\System.rxdata", blob]]))
  loaded = Marshal.load(a.read("Data\\System.rxdata"))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "001-Title01", loaded.title_name
  assert_equal 7, loaded.start_map_id
end

assert "RGSSAD rejects a bad header and an unsupported version" do
  assert_raise(RuntimeError) { RPGXP::RGSSAD.new("NOTRGSS\x01") }
  # An unknown version (only 1 and 3 are supported) is rejected.
  v4 = "RGSSAD\x00\x04rest"
  assert_raise(RuntimeError) { RPGXP::RGSSAD.new(v4) }
end

assert "RGSSAD v3 (.rgss3a) round-trips entries" do
  files = [
    ["Data\\System.rxdata", "sys\x00\x01\xfe\xff data"],
    ["Data\\Map001.rxdata", (("A".."Z").to_a.join) * 100], # spans 4-byte key steps
    ["Graphics\\Titles\\001-Title01.png", "\x89PNG\r\n\x1a\n"]
  ]
  archive = RPGXP::RGSSAD.pack_v3(files)
  a = RPGXP::RGSSAD.new(archive)

  assert_equal 3, a.version
  assert_equal 3, a.names.size
  files.each do |name, data|
    assert_equal data.bytes, a.read(name).bytes
  end
  # '/'-style lookups normalise to the archive's '\' names.
  assert_equal files[0][1].bytes, a.read("Data/System.rxdata").bytes
  assert_true a.include?("Data/Map001.rxdata")
  assert_false a.include?("Data/Missing.rxdata")
  assert_true a.read("Data/Missing.rxdata").nil?
end

assert "RGSSAD v3 carries real Marshal data through the archive" do
  sys = RPG::System.new
  sys.title_name = "001-Title01"
  sys.start_map_id = 7
  blob = Marshal.dump(sys)

  a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.pack_v3([["Data\\System.rxdata", blob]]))
  loaded = Marshal.load(a.read("Data\\System.rxdata"))
  assert_true loaded.is_a?(RPG::System)
  assert_equal "001-Title01", loaded.title_name
  assert_equal 7, loaded.start_map_id
end

# An entry larger than mruby's array-length cap (MRB_ARY_LENGTH_MAX, 131072) must
# still pack and read back byte-for-byte: real games ship maps, Animations.rxdata
# and graphics well past that, and accumulating one integer per byte used to
# overflow the Array. Build the payload with String#* (not a big Array literal,
# which would hit the same cap here) and compare with == / bytesize so the check
# itself never materialises an over-cap Array.
assert "RGSSAD round-trips an entry larger than the mruby array cap" do
  pattern = (0..255).to_a.pack("C*")           # 256 bytes, every value
  big = pattern * 900                            # 230400 bytes, over the cap
  assert_true big.bytesize > 131072
  [:pack_v1, :pack_v3].each do |packer|
    files = [
      ["Data\\Small.rxdata", "hi\x00\xff"],
      ["Data\\Big.rxdata", big]
    ]
    a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.send(packer, files))
    got = a.read("Data\\Big.rxdata")
    assert_equal big.bytesize, got.bytesize
    assert_true big == got
    assert_equal "hi\x00\xff".bytes, a.read("Data\\Small.rxdata").bytes
  end
end

# ---- Autonomous event movement: Character / MoveRoute / MoveType -----------

# World stand-in for the movement engine.
class FakeWorld
  def initialize(passable: true, hero: [0, 0], rng: 0)
    @passable = passable
    @hero = hero
    @rng = rng
    @switches = {}
    @sounds = 0
  end
  attr_reader :switches, :sounds
  def passable?(_ch, _dir); @passable; end
  def hero_position; @hero; end
  def set_switch(id, on); @switches[id] = on; end
  def play_sound(_audio); @sounds += 1; end
  def random(n); @rng % n; end
end

assert "Game::Character move / face / turns / toward" do
  c = RPGXP::Game::Character.new(3, 4, 2)
  c.move(6)
  assert_equal 4, c.x
  assert_equal 4, c.y
  assert_equal 6, c.direction
  c.turn_right # clockwise: 6 -> 2
  assert_equal 2, c.direction
  # Direction-fix locks facing.
  c.direction_fix = true
  c.face(8)
  assert_equal 2, c.direction
  c.direction_fix = false
  assert_equal [3, 5], RPGXP::Game::Character.step_tile(3, 4, 2)
  # Toward a tile to the right.
  d = RPGXP::Game::Character.new(4, 4).direction_toward(10, 4)
  assert_equal 6, d
  assert_equal 4, RPGXP::Game::Character.new(4, 4).direction_away(10, 4)
end

assert "Game::MoveRoute moves forward and repeats" do
  route = RPGXP::Game::MoveRoute.new([mv(12)], true, false) # Move Forward, repeat
  c = RPGXP::Game::Character.new(0, 0, 6) # facing right
  assert_equal :moved, route.step(c, FakeWorld.new(passable: true))
  assert_equal 1, c.x
  assert_false route.done? # repeats
end

assert "Game::MoveRoute blocked non-skippable retries and faces the wall" do
  route = RPGXP::Game::MoveRoute.new([mv(1), mv(4)], false, false) # Down, then Up
  c = RPGXP::Game::Character.new(0, 0, 8)
  assert_equal :blocked, route.step(c, FakeWorld.new(passable: false))
  assert_equal 2, c.direction # turned to face the blocked Down move
  assert_equal 0, c.y         # did not move
  assert_false route.done?    # cursor held on the blocked command
end

assert "Game::MoveRoute side effects: switch, speed, play SE, done" do
  world = FakeWorld.new
  route = RPGXP::Game::MoveRoute.new([mv(27, [5]), mv(29, [6]), mv(44, [nil])], false, false)
  c = RPGXP::Game::Character.new(0, 0)
  route.step(c, world) # Switch 5 ON
  route.step(c, world) # Change Speed -> 6
  route.step(c, world) # Play SE
  assert_true world.switches[5]
  assert_equal 6, c.move_speed
  assert_equal 1, world.sounds
  assert_true route.done? # non-repeating route exhausted
end

assert "Game::MoveType picks a direction per move type" do
  c = RPGXP::Game::Character.new(0, 0)
  # RANDOM: rng 2 -> CARDINALS[2 % 4] = 6.
  assert_equal 6, RPGXP::Game::MoveType.next_direction(1, c, FakeWorld.new(rng: 2))
  # APPROACH: toward a hero to the right -> 6.
  assert_equal 6, RPGXP::Game::MoveType.next_direction(2, c, FakeWorld.new(hero: [5, 0]))
  # FIXED / CUSTOM: no autonomous step.
  assert_true RPGXP::Game::MoveType.next_direction(0, c, FakeWorld.new).nil?
  assert_true RPGXP::Game::MoveType.next_direction(3, c, FakeWorld.new).nil?
end

# ---- Message control-code expansion ---------------------------------------

assert "Game::Message.expand handles variable / name / literal / dropped codes" do
  vars = Hash.new(0)
  vars[3] = 42
  names = { 1 => "Aluxes", 2 => "Basil" }

  m = RPGXP::Game::Message
  assert_equal "You have 42 gold.", m.expand("You have \\V[3] gold.", vars, names)
  assert_equal "Hi, Aluxes!", m.expand("Hi, \\N[1]!", vars, names)
  # Lower-case codes work too.
  assert_equal "Basil / 42", m.expand("\\n[2] / \\v[3]", vars, names)
  # A literal backslash, and a missing name -> empty.
  assert_equal "path\\to", m.expand("path\\\\to", vars, names)
  assert_equal "", m.expand("\\N[9]", vars, names)
  # Colour (\C[n]) and gold (\G) are display-only: consumed, no visible text.
  assert_equal "red text", m.expand("\\C[2]red text", vars, names)
  assert_equal "gold", m.expand("\\Ggold", vars, names)
  # Plain text and nil.
  assert_equal "plain", m.expand("plain", vars, names)
  assert_equal "", m.expand(nil, vars, names)
end

assert "Game::Message.expand accepts a Proc name lookup" do
  vars = Hash.new(0)
  lookup = ->(id) { id == 1 ? "Hero" : nil }
  assert_equal "Hero speaks", RPGXP::Game::Message.expand("\\N[1] speaks", vars, lookup)
end

# ---- RGSS script host -------------------------------------------------------

# Fake project DB for the script host: serves pre-decoded [name, source]
# sections and answers the Kernel built-ins load_data / save_data out of an
# in-memory store, so a save round-trips through the same instance.
class FakeScriptDB
  def initialize(sections)
    @sections = sections
    @store = {}
  end

  def scripts?; !@sections.empty?; end
  def scripts;  @sections; end
  def read_object(path); @store[path]; end
  def save_object(obj, path); @store[path] = obj; end
end

assert "ScriptHost.available? is true (eval present)" do
  assert_true RPGXP::ScriptHost.available?
end

assert "ScriptHost.run evaluates sections in order and sets $RGSS_SCRIPTS" do
  db = FakeScriptDB.new([
    ["Setup", "$rgss_host_probe = 41"],
    ["Main", "$rgss_host_probe += 1"]
  ])
  assert_true RPGXP::ScriptHost.run(db)
  assert_equal 42, $rgss_host_probe
  # $RGSS_SCRIPTS mirrors RGSS's [id, name, source] triples in load order.
  assert_equal 2, $RGSS_SCRIPTS.size
  assert_equal 0, $RGSS_SCRIPTS[0][0]
  assert_equal "Setup", $RGSS_SCRIPTS[0][1]
  assert_equal "Main", $RGSS_SCRIPTS[1][1]
end

assert "ScriptHost.run defines classes at the top level" do
  db = FakeScriptDB.new([["Def", "class RgssHostProbe; def hi; 7; end; end"]])
  assert_true RPGXP::ScriptHost.run(db)
  assert_true Object.const_defined?(:RgssHostProbe)
  assert_equal 7, RgssHostProbe.new.hi
end

assert "ScriptHost.run returns false when the project ships no scripts" do
  assert_false RPGXP::ScriptHost.run(FakeScriptDB.new([]))
end

assert "ScriptHost.install_kernel wires load_data / save_data round-trip" do
  db = FakeScriptDB.new([["x", "0"]])
  RPGXP::ScriptHost.install_kernel(db)
  # The built-ins are private Kernel methods (RGSS scripts call them bare);
  # save then load of a fresh path round-trips through the bound database.
  probe = Object.new
  probe.send(:save_data, { "hp" => 30 }, "ScriptHostProbe.rxdata")
  assert_equal({ "hp" => 30 }, probe.send(:load_data, "ScriptHostProbe.rxdata"))
end

# The RGSS script host needs Kernel#sprintf / #format / String#% (mruby-sprintf)
# to run the stock scripts that format numbers; confirm the gem is linked into
# the build and the integer/string specs the scripts use produce the right text.
assert "Kernel#sprintf / #format / String#% are available for the script host" do
  assert_equal "05", sprintf("%02d", 5)
  assert_equal "id=007", format("id=%03d", 7)
  assert_equal "0007", ("%0*d" % [4, 7])   # dynamic width, as the clock uses
  assert_equal "+5", sprintf("%+d", 5)
  assert_equal "S [0012-3456]", sprintf("S [%04d-%04d]", 12, 3456)
  assert_equal "  hi", ("%4s" % "hi")
end
