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
  def initialize(actors: [], tilesets: [])
    @actors = actors
    @tilesets = tilesets
  end
  attr_reader :actors, :tilesets
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

  h = state.to_h
  loaded = RPGXP::Game::State.load(db, Marshal.load(Marshal.dump(h)))
  assert_equal 5, loaded.map_id
  assert_equal 9, loaded.x
  assert_equal 7, loaded.y
  assert_equal 4, loaded.direction
  assert_equal [1, 2], loaded.party
  assert_true loaded.switches[3]
  assert_equal 42, loaded.variables[10]
  # Default-valued stores still behave after load.
  assert_false loaded.switches[999]
  assert_equal 0, loaded.variables[999]
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
  # A version-3 (.rgss3a) header is recognised but not yet supported.
  v3 = "RGSSAD\x00\x03rest"
  assert_raise(RuntimeError) { RPGXP::RGSSAD.new(v3) }
end

# ---- Autonomous event movement: Character / MoveRoute / MoveType -----------

# Build an RPG::MoveCommand (code / parameters).
def mv(code, params = [])
  c = RPG::MoveCommand.new
  c.code = code
  c.parameters = params
  c
end

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
