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
