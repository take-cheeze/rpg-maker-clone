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

# Build an RPG::Animation with `frame_max` frames, each holding `cells` rows of
# the eight-column cell_data RMXP writes.
def make_animation(frame_max, cells_per_frame = 1)
  a = RPG::Animation.new
  a.id = 1
  a.animation_name = "malch8"
  a.animation_hue = 0
  a.position = RPGXP::Game::Animation::POSITION_MIDDLE
  a.frame_max = frame_max
  a.frames = (0...frame_max).map do |f|
    fr = RPG::Animation::Frame.new
    fr.cell_max = cells_per_frame
    data = Table.new(cells_per_frame, 8)
    cells_per_frame.times do |i|
      data[i, 0] = f * 10 + i   # pattern
      data[i, 1] = 4            # x
      data[i, 2] = -8           # y
      data[i, 3] = 100          # zoom %
      data[i, 4] = 0            # angle
      data[i, 5] = 0            # mirror
      data[i, 6] = 255          # opacity
      data[i, 7] = 1            # blend
    end
    fr.cell_data = data
    fr
  end
  a.timings = []
  a
end

assert "Game::Animation holds each frame for four game frames" do
  anim = RPGXP::Game::Animation.new(make_animation(3))
  assert_true anim.playing?
  # Read the frame, then tick — the order the scene draws in.
  seen = []
  while anim.playing?
    seen << anim.frame_index
    anim.update
  end
  # frame_max * 4 + 1 ticks. The "+ 1" all lands on the first frame, which is
  # held for five: RMXP's own index formula yields -1 on that leading tick — it
  # reads frames[-1], the *last* frame, for one game frame — and this clamps to
  # the first instead. Every other frame gets its four.
  assert_equal 13, seen.size
  assert_equal [0, 0, 0, 0, 0], seen[0, 5]
  assert_equal [1, 1, 1, 1], seen[5, 4]
  assert_equal [2, 2, 2, 2], seen[9, 4]
  assert_false anim.playing?
  assert_nil anim.frame_index
end

assert "Game::Animation reads a frame's drawable cells" do
  anim = RPGXP::Game::Animation.new(make_animation(2, 3))
  cells = anim.cells(1)
  assert_equal 3, cells.size
  # [pattern, x, y, zoom, angle, mirror, opacity, blend]
  assert_equal 10, cells[0][0]
  assert_equal 4, cells[0][1]
  assert_equal(-8, cells[0][2])
  assert_equal 1, cells[0][7]
  # A cell whose pattern is -1 draws nothing and is skipped.
  blank = make_animation(1, 2)
  blank.frames[0].cell_data[0, 0] = -1
  assert_equal 1, RPGXP::Game::Animation.new(blank).cells(0).size
  # Out-of-range frames are empty rather than an error.
  assert_equal 0, anim.cells(99).size
  assert_equal 0, anim.cells(nil).size
end

assert "Game::Animation maps a pattern onto the sheet grid" do
  # Five 192x192 cells to a row.
  assert_equal [0, 0, 192, 192], RPGXP::Game::Animation.cell_rect(0)
  assert_equal [768, 0, 192, 192], RPGXP::Game::Animation.cell_rect(4)
  assert_equal [0, 192, 192, 192], RPGXP::Game::Animation.cell_rect(5)
  assert_equal [384, 384, 192, 192], RPGXP::Game::Animation.cell_rect(12)
end

assert "Interpreter: script joins its continuation lines and queues them" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(355, ["$a = 1"], 0),
    cmd(655, ["$b = 2"], 0),
    cmd(655, ["$c = 3"], 0),
    cmd(121, [5, 5, 0], 0)     # the 655s must not be re-run as commands
  ], 1, 7)
  it.update
  assert_false it.waiting?
  assert_true s.switches[5]
  reqs = it.take_script_requests
  assert_equal 1, reqs.size
  assert_equal "$a = 1\n$b = 2\n$c = 3", reqs[0][:source]
  assert_equal 7, reqs[0][:event_id]
  assert_equal 1, reqs[0][:map_id]
  assert_true it.take_script_requests.empty?

  # An empty script is not queued at all.
  it2 = RPGXP::Game::Interpreter.new(s)
  it2.start([cmd(355, [""], 0)], 1, 7)
  it2.update
  assert_true it2.take_script_requests.empty?
end

assert "Interpreter: Exit Event Processing keeps the effects already queued" do
  # `stop` used to clear every request queue, so a list that ended with Exit
  # Event Processing (115) -- or was stopped by a teleport -- silently dropped
  # the move routes, tints, pictures, screen effects, animations and scripts the
  # commands before it had produced. They already ran; ending the list does not
  # un-run them, and the scene has not drained them yet at that point.
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(209, [-1, move_route([mv(1)])], 0),   # Set Move Route
    cmd(355, ["$probe = 1"], 0),              # Script
    cmd(115, [], 0)                           # Exit Event Processing
  ], 1, 7)
  it.update
  assert_false it.running?
  assert_equal 1, it.take_move_route_requests.size
  assert_equal 1, it.take_script_requests.size

  # A fresh run does start from an empty queue.
  it.start([cmd(121, [5, 5, 0], 0)], 1, 7)
  assert_true it.take_move_route_requests.empty?
  assert_true it.take_script_requests.empty?
end

assert "Game::SwitchStore and VariableStore reach the runtime state" do
  s = new_state
  sw = RPGXP::Game::SwitchStore.new(s)
  va = RPGXP::Game::VariableStore.new(s)
  # What a Script command sees is what Control Switches / Control Variables
  # wrote, and the other way round.
  s.switches[4] = true
  assert_true sw[4]
  assert_false sw[9]
  sw[9] = true
  assert_true s.switches[9]
  sw[9] = nil          # any falsy value clears it
  assert_false s.switches[9]

  s.variables[2] = 11
  assert_equal 11, va[2]
  va[3] = 7
  assert_equal 7, s.variables[3]
  assert_equal 0, va[99]
end

assert "Interpreter: show animation queues without pausing" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(207, [-1, 3], 0),          # on the player
    cmd(207, [0, 4], 0),           # on this event
    cmd(207, [2, 0], 0),           # animation 0 = "none", dropped
    cmd(121, [5, 5, 0], 0)
  ], 1, 7)
  it.update
  assert_false it.waiting?
  assert_true s.switches[5]
  reqs = it.take_animation_requests
  assert_equal 2, reqs.size
  assert_equal :player, reqs[0][:target]
  assert_equal 3, reqs[0][:animation_id]
  assert_equal 7, reqs[1][:target]   # "this event"
  assert_equal 4, reqs[1][:animation_id]
  assert_true it.take_animation_requests.empty?
end

assert "Game::Scroll moves a whole number of tiles and stops" do
  sc = RPGXP::Game::Scroll.new
  assert_false sc.scrolling?
  # Two tiles right (direction 6) at speed 4 -> 16 pixels a frame over a 32px
  # tile, so four frames.
  sc.start(6, 2, 4, 32)
  assert_true sc.scrolling?
  4.times { sc.update }
  assert_equal 64, sc.x
  assert_equal 0, sc.y
  assert_false sc.scrolling?
  # Further frames do not drift.
  sc.update
  assert_equal 64, sc.x

  # A speed that does not divide the distance still lands exactly, because the
  # last frame moves only what is left.
  s2 = RPGXP::Game::Scroll.new
  s2.start(8, 1, 5, 32) # up, 1 tile, 32px a frame
  s2.update
  assert_equal(-32, s2.y)
  assert_false s2.scrolling?

  # Offsets accumulate: scrolling back returns to where it started.
  s3 = RPGXP::Game::Scroll.new
  s3.start(4, 3, 5, 32)
  10.times { s3.update }
  assert_equal(-96, s3.x)
  s3.start(6, 3, 5, 32)
  10.times { s3.update }
  assert_equal 0, s3.x
end

assert "Interpreter: scroll map suspends until the scene can start it" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([cmd(203, [6, 2, 4], 0), cmd(121, [5, 5, 0], 0)], 1, 7)
  it.update
  assert_true it.waiting?
  assert_equal :scroll, it.wait_kind
  r = it.scroll_request
  assert_equal 6, r[:direction]
  assert_equal 2, r[:distance]
  assert_equal 4, r[:speed]
  assert_false s.switches[5]
  # The scene starts the scroll and resumes at once — the scroll itself does not
  # hold the list up.
  it.resume
  assert_false it.waiting?
  assert_true s.switches[5]
end

assert "Game::Screen decays a flash to nothing over its duration" do
  sc = RPGXP::Game::Screen.new
  assert_false sc.flashing?
  sc.start_flash([255, 255, 255, 255], 4)
  assert_true sc.flashing?
  4.times { sc.update }
  assert_equal 0.0, sc.flash_color[3]
  assert_false sc.flashing?
  # A zero duration is an immediate clear, not a permanent tint.
  sc.start_flash([255, 0, 0, 255], 0)
  assert_equal 0.0, sc.flash_color[3]
end

assert "Game::Screen shakes and settles back on centre" do
  sc = RPGXP::Game::Screen.new
  assert_equal 0.0, sc.shake
  sc.start_shake(5, 5, 20)
  sc.update
  # power * speed / 10 the first frame.
  assert_equal 2.5, sc.shake
  # It reverses once it passes twice the power, so it never runs away.
  40.times { sc.update }
  assert_true sc.shake.abs <= 5 * 2 + 2.5
  # And it ends centred rather than stuck off to one side.
  60.times { sc.update }
  assert_equal 0.0, sc.shake
  assert_false sc.shaking?
end

assert "Interpreter: flash and shake queue without pausing" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(224, [Color.new(255, 255, 255, 200), 10], 0),
    cmd(225, [6, 7, 30], 0),
    cmd(121, [5, 5, 0], 0)
  ], 1, 7)
  it.update
  assert_false it.waiting?
  assert_true s.switches[5]
  reqs = it.take_screen_requests
  assert_equal 2, reqs.size
  assert_equal :flash, reqs[0][:op]
  # The Color object is passed through untouched (the scene reads its channels).
  assert_equal 200.0, reqs[0][:color].alpha
  assert_equal 10, reqs[0][:duration]
  assert_equal :shake, reqs[1][:op]
  assert_equal 6, reqs[1][:power]
  assert_equal 7, reqs[1][:speed]
  assert_equal 30, reqs[1][:duration]
  assert_true it.take_screen_requests.empty?

  # A flash with no Color object is dropped rather than raising.
  it2 = RPGXP::Game::Interpreter.new(s)
  it2.start([cmd(224, [nil, 10], 0), cmd(121, [6, 6, 0], 0)], 1, 7)
  it2.update
  assert_true it2.take_screen_requests.empty?
  assert_true s.switches[6]
end

assert "Interpreter: prepare/execute transition freezes then suspends" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(221, [], 0),                # Prepare for Transition (does not pause)
    cmd(121, [5, 5, 0], 0),         # so this still runs this frame
    cmd(222, ["Blind"], 0),         # Execute Transition (pauses)
    cmd(121, [6, 6, 0], 0)          # must NOT run until the fade is over
  ], 1, 7)
  it.update
  assert_true s.switches[5]
  assert_true it.waiting?
  assert_equal :transition, it.wait_kind
  assert_equal "Blind", it.transition_name
  assert_false s.switches[6]
  # The scene takes the freeze once, then resumes when the still has faded.
  assert_true it.take_freeze_request
  assert_false it.take_freeze_request
  it.resume
  assert_false it.waiting?
  assert_true s.switches[6]
end

assert "Interpreter: a transition with no graphic name still suspends" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([cmd(222, [""], 0)], 1, 7)
  it.update
  assert_true it.waiting?
  assert_equal "", it.transition_name
  # No 221 ran, so there is nothing for the scene to dissolve.
  assert_false it.take_freeze_request
end

assert "Game::Picture eases a move onto its target and stops there" do
  p = RPGXP::Game::Picture.new(1)
  p.show("CG1", 0, 0, 0, 100, 100, 255, 0)
  assert_true p.shown?
  assert_equal 0.0, p.x
  # Four frames to (40, 20) at half opacity: RMXP's weighted average lands
  # exactly on the target on the last frame.
  p.move(4, 0, 40, 20, 200, 200, 128, 1)
  4.times { p.update }
  assert_equal 40.0, p.x
  assert_equal 20.0, p.y
  assert_equal 200.0, p.zoom_x
  assert_equal 128.0, p.opacity
  assert_equal 1, p.blend_type
  # Done: further frames do not overshoot.
  p.update
  assert_equal 40.0, p.x

  # A zero-frame move snaps instead of doing nothing.
  p.move(0, 0, 5, 6, 100, 100, 255, 0)
  assert_equal 5.0, p.x
  assert_equal 6.0, p.y
end

assert "Game::Picture eases its tone and wraps its rotation" do
  p = RPGXP::Game::Picture.new(2)
  p.show("CG2", 1, 10, 10, 100, 100, 255, 0)
  assert_equal [0.0, 0.0, 0.0, 0.0], p.tone
  p.start_tone_change([-68, 0, 68, 255], 2)
  p.update
  p.update
  assert_equal(-68.0, p.tone[0])
  assert_equal 255.0, p.tone[3]

  # A zero duration applies at once.
  p.start_tone_change([0, 0, 0, 0], 0)
  assert_equal [0, 0, 0, 0], p.tone

  # Rotation is degrees per two frames and stays in 0...360.
  p.rotate(-4)
  p.update            # -2
  p.update            # -4 -> wraps
  assert_true p.angle >= 0.0 && p.angle < 360.0
  assert_equal 356.0, p.angle
  p.rotate(0)
  before = p.angle
  p.update
  assert_equal before, p.angle

  # Erase returns the slot to its defaults, and it stops being drawn.
  p.erase
  assert_false p.shown?
  assert_equal 100.0, p.zoom_x
  assert_equal 0.0, p.angle
end

assert "Interpreter: picture commands queue without pausing" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    # Show Picture 1 "CG1", centred origin, direct (0) coords 320,240,
    # zoom 100/100, opacity 255, blend 0.
    cmd(231, [1, "CG1", 1, 0, 320, 240, 100, 100, 255, 0], 0),
    cmd(235, [1], 0),               # Erase Picture 1
    cmd(121, [5, 5, 0], 0)          # proves neither paused
  ], 1, 7)
  it.update
  assert_false it.waiting?
  assert_true s.switches[5]
  reqs = it.take_picture_requests
  assert_equal 2, reqs.size
  assert_equal :show, reqs[0][:op]
  assert_equal 1, reqs[0][:number]
  assert_equal "CG1", reqs[0][:name]
  assert_equal 1, reqs[0][:origin]
  assert_equal 320, reqs[0][:x]
  assert_equal 240, reqs[0][:y]
  assert_equal :erase, reqs[1][:op]
  assert_true it.take_picture_requests.empty?
end

assert "Interpreter: picture position can come from variables" do
  s = new_state
  s.variables[3] = 64
  s.variables[4] = 96
  it = RPGXP::Game::Interpreter.new(s)
  # appoint_with_variables = 1, so the x/y slots name variables 3 and 4.
  it.start([cmd(231, [2, "CG2", 0, 1, 3, 4, 100, 100, 255, 0], 0)], 1, 7)
  it.update
  r = it.take_picture_requests[0]
  assert_equal 64, r[:x]
  assert_equal 96, r[:y]

  # Move Picture puts a duration where Show has the name, then the same tail.
  it2 = RPGXP::Game::Interpreter.new(s)
  it2.start([cmd(232, [2, 20, 0, 0, 10, 12, 50, 50, 128, 1], 0)], 1, 7)
  it2.update
  m = it2.take_picture_requests[0]
  assert_equal :move, m[:op]
  assert_equal 20, m[:duration]
  assert_equal 10, m[:x]
  assert_equal 50, m[:zoom_x]
  assert_equal 128, m[:opacity]

  # Rotate carries its speed; a tone command with no Tone object is dropped.
  it3 = RPGXP::Game::Interpreter.new(s)
  it3.start([cmd(233, [2, -4], 0), cmd(234, [2, nil, 10], 0)], 1, 7)
  it3.update
  rots = it3.take_picture_requests
  assert_equal 1, rots.size
  assert_equal :rotate, rots[0][:op]
  assert_equal(-4, rots[0][:speed])
end

assert "Interpreter: set event location queues a snap without pausing" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  # Direct designation: player -> (8, 5) facing left.
  it.start([cmd(202, [-1, 0, 8, 5, 4], 0), cmd(121, [5, 5, 0], 0)], 1, 7)
  it.update
  assert_false it.waiting?
  assert_true s.switches[5]
  reqs = it.take_location_requests
  assert_equal 1, reqs.size
  assert_equal :player, reqs[0][:target]
  assert_equal 8, reqs[0][:x]
  assert_equal 5, reqs[0][:y]
  assert_equal 4, reqs[0][:direction]
  assert_true it.take_location_requests.empty?

  # Variable designation reads the two variables named by the parameters.
  s.variables[11] = 3
  s.variables[12] = 9
  it2 = RPGXP::Game::Interpreter.new(s)
  it2.start([cmd(202, [0, 1, 11, 12, 0], 0)], 1, 7)
  it2.update
  r2 = it2.take_location_requests[0]
  assert_equal 7, r2[:target] # "this event"
  assert_equal 3, r2[:x]
  assert_equal 9, r2[:y]

  # Exchange designation names the other event instead of a tile.
  it3 = RPGXP::Game::Interpreter.new(s)
  it3.start([cmd(202, [4, 2, 6, 0, 0], 0)], 1, 7)
  it3.update
  r3 = it3.take_location_requests[0]
  assert_equal 4, r3[:target]
  assert_equal 6, r3[:swap_with]
  assert_true r3[:x].nil?
end

assert "Interpreter: change transparent flag toggles the leader" do
  s = new_state
  assert_false s.player_transparent
  run_to_end(s, [cmd(208, [0], 0)])   # 0 = transparent
  assert_true s.player_transparent
  run_to_end(s, [cmd(208, [1], 0)])   # 1 = normal
  assert_false s.player_transparent
  # And it survives a save/load round-trip.
  s.player_transparent = true
  loaded = RPGXP::Game::State.load(s.db, Marshal.load(Marshal.dump(s.to_h)))
  assert_true loaded.player_transparent
end

assert "Interpreter: wait for move's completion suspends the list" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(209, [-1, move_route([mv(1)])], 0), # Set Move Route -> player
    cmd(210, [], 0),                        # Wait for Move's Completion
    cmd(121, [5, 5, 0], 0)                  # must NOT run until the route ends
  ], 1, 7)
  it.update
  assert_true it.waiting?
  assert_equal :move_completion, it.wait_kind
  assert_false s.switches[5]
  # The scene resumes it once no forced route is walking.
  it.resume
  assert_false it.waiting?
  assert_true s.switches[5]
end

assert "Interpreter: change screen tone queues a request without pausing" do
  s = new_state
  tone = Tone.new(-68, -68, 0, 0)
  it = RPGXP::Game::Interpreter.new(s)
  it.start([
    cmd(223, [tone, 20], 0),       # Change Screen Color Tone over 20 frames
    cmd(121, [5, 5, 0], 0)         # then switch 5 ON (proves it did not pause)
  ], 1, 7)
  it.update
  assert_false it.waiting?          # a tone change does not suspend the interpreter
  assert_true s.switches[5]
  reqs = it.take_tint_requests
  assert_equal 1, reqs.size
  assert_equal tone, reqs[0][:tone]
  assert_equal 20, reqs[0][:duration]
  # Draining empties the queue.
  assert_true it.take_tint_requests.empty?
end

assert "Interpreter: change screen tone without a tone object is dropped" do
  s = new_state
  it = RPGXP::Game::Interpreter.new(s)
  it.start([cmd(223, [nil, 20], 0), cmd(121, [5, 5, 0], 0)], 1, 7)
  it.update
  assert_true it.take_tint_requests.empty?
  assert_true s.switches[5]         # the rest of the list still runs
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

# The whole point of the archive for a released game: its Graphics/ tree is in
# there too, and `Cache.*` asks for those by name through Bitmap.new. mruby-rgss
# covers its half against a stand-in archive; this is the end-to-end one, a real
# packed archive decoded into a real Bitmap, for both archive versions.
#
# The picture is the 3x2 XYZ used in mruby-rgss's loader tests: palette
# 0 = (10,20,30), 1 = red, 2 = green. Note the entry name uses RGSSAD's native
# '\' separators while the lookup uses '/', which is how a game spells it.
assert "a packed graphic loads into a Bitmap through RGSS.asset_archive" do
  xyz = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
        "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
        "\x8b\x02\x41"
  [:pack_v1, :pack_v3].each do |packer|
    files = [
      ["Data\\System.rxdata", Marshal.dump([1, 2, 3])],
      ["Graphics\\Titles\\Castle.xyz", xyz]
    ]
    a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.send(packer, files))
    RGSS.asset_archive = a
    begin
      # No loose file anywhere: this can only have come out of the archive, and
      # only by trying the ".xyz" candidate against the bare name the game uses.
      b = RGSS::Bitmap.new("Graphics/Titles/Castle")
      assert_equal 3, b.width, "#{packer}: width"
      assert_equal 2, b.height, "#{packer}: height"
      assert_equal 10.0, b.get_pixel(0, 0).red, "#{packer}: pixel"
      assert_equal 255.0, b.get_pixel(2, 0).green, "#{packer}: pixel"
      # The data entries still read back, so registering the archive for assets
      # has not disturbed what it was already doing.
      assert_equal [1, 2, 3], Marshal.load(a.read("Data/System.rxdata"))
    ensure
      RGSS.asset_archive = nil
    end
  end
end

# The same for audio, which a release packs alongside its graphics. Whether the
# bytes then reach the mixer is native and needs a real audio device — that is
# the `audio_probe` ctest. What this pins is that a game's bare track name finds
# the entry and arrives *decrypted*, through a real archive of both versions.
assert "a packed track plays through RGSS.asset_archive" do
  wav = "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00" \
        "\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x00\x00\x00\x00"
  [:pack_v1, :pack_v3].each do |packer|
    files = [
      ["Data\\System.rxdata", Marshal.dump([1, 2, 3])],
      ["Audio\\BGM\\Theme1.wav", wav]
    ]
    a = RPGXP::RGSSAD.new(RPGXP::RGSSAD.send(packer, files))
    class << RGSS::Audio
      alias _bgm_play_mem_orig3 _bgm_play_mem
      alias _can_play_mem_orig3 _can_play_mem?
      def _bgm_play_mem(name, bytes, volume, pitch)
        $audio_arch_capture = [name, bytes, volume, pitch]
        nil
      end
      # The test binary installs no audio backend; pretend one is there so the
      # lookup is what is being measured.
      def _can_play_mem? = true
    end
    RGSS.asset_archive = a
    begin
      $audio_arch_capture = nil
      # No folder, no extension — how the database names a track.
      RGSS::Audio.bgm_play("Theme1", 70, 100)
      assert_false $audio_arch_capture.nil?, "#{packer}: packed BGM did not play"
      assert_equal "Audio/BGM/Theme1.wav", $audio_arch_capture[0]
      # Byte-for-byte through the encryption, or no decoder would take it.
      assert_equal wav.bytes, $audio_arch_capture[1].bytes
      assert_equal 70, $audio_arch_capture[2]
    ensure
      RGSS.asset_archive = nil
      class << RGSS::Audio
        alias _bgm_play_mem _bgm_play_mem_orig3
        alias _can_play_mem? _can_play_mem_orig3
      end
    end
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

assert "Game::Character glides to the tile it stepped onto" do
  c = RPGXP::Game::Character.new(1, 1)
  c.move_speed = 4 # 2**4 of 128 units a frame: eight frames a tile
  c.move(6)
  # The tile is taken at once (that is what collision sees) but the character
  # is still drawn on the one it left.
  assert_equal 2, c.x
  assert_equal 32, c.pixel_x(32)
  assert_true c.moving?
  7.times { c.update }
  assert_true c.moving?
  c.update
  assert_false c.moving?
  assert_equal 64, c.pixel_x(32)
  # Placing a character (a spawn or a teleport) is not a step: it does not glide.
  c.x = 9
  assert_false c.moving?
  assert_equal 288, c.pixel_x(32)
end

assert "Game::Character cycles its walk pattern and rests on the page's frame" do
  c = RPGXP::Game::Character.new(0, 0)
  # A page that stands on frame 1 (RMXP's Graphic#pattern).
  c.set_graphic("hero", 0, 2, 1)
  c.move_speed = 4 # animation ticks 1.5 a frame, cycling every 18 - 4 * 2
  assert_equal 1, c.pattern
  c.move(2)
  6.times { c.update } # 9.0 ticks: not there yet
  assert_equal 1, c.pattern
  c.update # 10.5 ticks
  assert_equal 2, c.pattern
  # Once it has arrived and stood still a moment it falls back to the page's
  # own frame, not to frame 0.
  20.times { c.update }
  assert_false c.moving?
  assert_equal 1, c.pattern
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

# The RGSS standard library (mrblib/rgss_library.rb) — the classes RGSS104E.dll
# supplies and no project ships. These tests run in the *built* engine, where
# RPG::Sprite really does subclass the native RGSS::Sprite; they are what would
# catch the library being dropped from the gem's rbfiles, or a native base class
# losing a method it is built on. Sprite/Viewport instances need a live display
# the headless test binary lacks (see mruby-rgss's own tests), so the behaviour
# of the effects is checked against fakes in scripts/rpgxp_script_host_check.rb
# and what is pinned here is the shape a game's scripts subclass.
assert "RPG::Sprite is the native Sprite plus the RGSS effect surface" do
  assert_equal RGSS::Sprite, RPG::Sprite.superclass
  methods = RPG::Sprite.instance_methods
  # Everything Sprite_Battler and Sprite_Character call on their superclass.
  %i[whiten appear escape collapse damage animation loop_animation
     blink_on blink_off blink? effect? update dispose].each do |name|
    assert_true methods.include?(name), "RPG::Sprite##{name} missing"
  end
end

# Errno, which mruby does not ship and every RGSS game's "Main" names:
#
#   begin ... $scene.main while $scene != nil ... rescue Errno::ENOENT
#
# A rescue clause is evaluated when an exception passes through it, so without
# the constant *any* exception leaving a game's main loop became
# "NameError: uninitialized constant Errno" — the boot check caught exactly that
# on a released game, where the ordinary end-of-run timeout was rewritten into a
# crash. What matters is that a foreign exception passes through the clause.
assert "Errno::ENOENT exists so a game's `rescue Errno::ENOENT` resolves" do
  assert_true Object.const_defined?(:Errno), "Errno missing"
  assert_true Errno::ENOENT.ancestors.include?(StandardError)
  # RGSS's message shape: the stock Main strips the prefix to name the file.
  assert_equal "No such file or directory - Data/Foo.rxdata",
               Errno::ENOENT.new("Data/Foo.rxdata").message
  passed_through = false
  begin
    begin
      raise "not a file error"
    rescue Errno::ENOENT
      # Unreachable — and before Errno existed, getting here raised NameError.
    end
  rescue StandardError => e
    passed_through = e.message == "not a file error"
  end
  assert_true passed_through, "a foreign exception did not survive the rescue clause"
end

assert "RPG::Weather offers the surface Spriteset_Map drives" do
  methods = RPG::Weather.instance_methods
  %i[type= max= ox= oy= update dispose type max ox oy].each do |name|
    assert_true methods.include?(name), "RPG::Weather##{name} missing"
  end
end

# RPG::Cache is the one part that runs headlessly: it only builds Bitmaps.
assert "RPG::Cache caches by path and stands in for what will not load" do
  RPG::Cache.clear
  # Nothing on disk under this name, and RGSS would raise; the cache reports it
  # and hands back a blank so a missing RTP cannot end a boot.
  missing = RPG::Cache.picture("NoSuchPictureHere")
  assert_equal 32, missing.width
  assert_equal 32, missing.height
  # An empty name is RGSS's own "no graphic", also a blank.
  assert_equal 32, RPG::Cache.character("", 0).width
  # Same path, same object — a map redrawing its charsets every frame must not
  # reload them.
  assert_true RPG::Cache.picture("NoSuchPictureHere").equal?(missing)
  RPG::Cache.clear
  assert_false RPG::Cache.picture("NoSuchPictureHere").equal?(missing)
end

# The host is the default boot path (ADR 0029): with neither the native binary's
# RGSS_SCRIPT_HOST constant nor an opt-out in the environment, enabled? is true.
# This runs in the *built* engine, which is where a divergence between the CRuby
# harness and mruby would show — including ENV being absent here, which must
# still leave the host on rather than raise.
assert "ScriptHost.enabled? defaults on" do
  assert_true RPGXP::ScriptHost.enabled?
  # The opt-out list the native runtime mirrors (src/main.cxx) — kept in the
  # test so a spelling cannot silently drop out of one side.
  assert_equal ["0", "false", "off", "no"], RPGXP::ScriptHost::DISABLED_VALUES
  assert_equal "RGSS_SCRIPT_HOST", RPGXP::ScriptHost::ENABLED_ENV
end

# The environment channel, when this build has an ENV to read (the native binary
# resolves the variable in C++ instead — see enabled?).
assert "ScriptHost.enabled? honours the RGSS_SCRIPT_HOST opt-out in ENV" do
  skip "no ENV in this build" unless Object.const_defined?(:ENV)
  previous = ENV[RPGXP::ScriptHost::ENABLED_ENV]
  begin
    ENV[RPGXP::ScriptHost::ENABLED_ENV] = ""      # unset, as a plain boot is
    assert_true RPGXP::ScriptHost.enabled?
    RPGXP::ScriptHost::DISABLED_VALUES.each do |off|
      ENV[RPGXP::ScriptHost::ENABLED_ENV] = off
      assert_false RPGXP::ScriptHost.enabled?, "#{off.inspect} should disable the host"
    end
    ENV[RPGXP::ScriptHost::ENABLED_ENV] = "1"
    assert_true RPGXP::ScriptHost.enabled?
  ensure
    ENV[RPGXP::ScriptHost::ENABLED_ENV] = previous.nil? ? "" : previous
  end
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

# The script host evals the game's scripts, runs their blocking Main inside a
# Fiber (ADR 0023) and ends the game when one calls `exit` (raised as a catchable
# SystemExit). Confirm all three gems are linked into the build — without
# invoking `exit`, which would terminate the test runner.
assert "eval, Fiber and Kernel#exit / SystemExit are available for the script host" do
  # mruby-eval is what makes the whole host possible; script_host.rb calls
  # Kernel#eval unconditionally because this gem is a hard dependency
  # (mruby-rpgxp/mrbgem.rake), so its absence has to fail here rather than at the
  # first booted game.
  assert_true Kernel.method_defined?(:eval), "Kernel#eval missing (mruby-eval)"
  assert_true Object.const_defined?(:Fiber), "Fiber missing (mruby-fiber)"
  # mruby-exit defines Kernel#exit (a private method) alongside SystemExit, so the
  # constant's presence proves the gem is linked. mruby's Module has no
  # #private_method_defined? (it is CRuby-only), so we do not reflect on the
  # private method here.
  assert_true Object.const_defined?(:SystemExit),
              "SystemExit / Kernel#exit missing (mruby-exit)"
  # A Fiber round-trips a value through yield/resume, the mechanism the driver
  # relies on to advance one frame per resume.
  f = Fiber.new { Fiber.yield(:frame); :done }
  assert_equal :frame, f.resume
  assert_equal :done, f.resume
end
