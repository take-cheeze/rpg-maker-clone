# In-memory game state built from the parsed LCF database and map data.
#
# These classes deliberately hold only plain data derived from LCF::Database /
# LCF::MapUnit; nothing here touches RGSS or draws to the screen. That keeps the
# "New Game" logic (building a party and locating the start map) independent of
# the not-yet-implemented map renderer, and unit-testable on its own.
module Game
  TILE = 16 # tile size in pixels

  # Pixel geometry of a character-set (CharSet/*.png) graphic. A charset holds
  # 4x2 = 8 character templates; each template is 3 walk frames wide by 4
  # directions tall, and each frame is 24x32. `pattern` is the walk frame (the
  # standing pose is 1); direction uses RPG2000's numpad convention.
  module CharSet
    WIDTH = 24
    HEIGHT = 32
    # numpad direction -> row within a character template (top to bottom:
    # up, right, down, left).
    DIR_ROW = { 8 => 0, 6 => 1, 2 => 2, 4 => 3 }.freeze
    # Walk animation: middle, right, middle, left.
    WALK_PATTERNS = [1, 2, 1, 0].freeze

    # Source rectangle [x, y, w, h] of one frame for character `index` (0..7).
    def self.frame_rect(index, dir, pattern)
      col = index % 4
      row = index / 4
      bx = col * (WIDTH * 3)
      by = row * (HEIGHT * 4)
      [bx + pattern * WIDTH, by + (DIR_ROW[dir] || 2) * HEIGHT, WIDTH, HEIGHT]
    end
  end

  def self.clamp(v, lo, hi)
    return lo if v < lo
    return hi if v > hi
    v
  end

  # Top-left pixel of the view so the player is centred, clamped so the camera
  # never scrolls past the edges of a map smaller/larger than the screen.
  def self.camera_offset(player_px, screen_px, map_px)
    max = map_px - screen_px
    max = 0 if max < 0
    clamp(player_px - screen_px / 2, 0, max)
  end

  # A chipset: its tile graphic name plus the lower-layer passability table.
  # Passability is keyed by a chip index derived from the tile id following the
  # EasyRPG block layout; unknown/out-of-range tiles are treated as passable so
  # collision degrades safely.
  class ChipSet
    # numpad direction -> passability bit.
    DIR_BIT = { 2 => 0x01, 4 => 0x02, 6 => 0x04, 8 => 0x08 }.freeze

    attr_reader :name, :graphic

    def initialize(db, id)
      c = db.chipset[id]
      @name = c ? c.name : ''
      @graphic = c ? c.chipset_name : ''
      @passable_lower = c ? c.passable_data_lower : nil
    end

    # Chip index into the lower passability table for a lower-layer tile id.
    def self.lower_index(tile_id)
      return nil if tile_id.nil?
      if tile_id >= 10000 then 18 + (tile_id - 10000)
      elsif tile_id >= 5000 then 6 + (tile_id - 5000) / 50
      elsif tile_id >= 3000 then 3 + (tile_id - 3000) / 50
      else tile_id / 1000
      end
    end

    # Can a character enter a tile with the given lower-layer id moving in `dir`?
    def passable?(tile_id, dir)
      return true if @passable_lower.nil?
      idx = ChipSet.lower_index(tile_id)
      return true if idx.nil? || idx < 0 || idx >= @passable_lower.size
      flags = @passable_lower[idx]
      return true if flags.nil?
      (flags & (DIR_BIT[dir] || 0)) != 0
    end
  end

  # One party member, snapshotted from the database's actor (player) table.
  class Actor
    attr_reader :id, :name, :level, :charset_name, :charset_index
    attr_accessor :hp, :mp
    attr_reader :max_hp, :max_mp, :atk, :def, :int, :agi

    def initialize(db, id)
      @id = id
      a = db.player[id]
      raise "No such actor: #{id}" if a.nil?

      @name = a.name
      @charset_name = a.charset_name
      @charset_index = a.charset_index
      @level = a.initial_level
      st = a.status || {}
      @max_hp = st[:max_hp] || 0
      @max_mp = st[:max_mp] || 0
      @atk = st[:atk] || 0
      @def = st[:def] || 0
      @int = st[:int] || 0
      @agi = st[:agi] || 0
      # A fresh actor starts at full health.
      @hp = @max_hp
      @mp = @max_mp
    end
  end

  # The active party. On a new game it is seeded from the database's initial
  # party list (System.party).
  class Party
    include Enumerable

    attr_reader :actors

    def initialize(db)
      ids = db.system.party || []
      @actors = ids.reject { |i| i.nil? || i <= 0 }.map { |i| Actor.new(db, i) }
    end

    def each(&blk); @actors.each(&blk); end
    def size; @actors.size; end
    def leader; @actors.first; end
  end

  # A loaded map (.lmu) plus convenience accessors for the two tile layers.
  # Tiles are addressed in tile coordinates; out-of-bounds lookups return nil.
  class Map
    attr_reader :id, :unit, :width, :height, :chipset_id

    def initialize(id, unit)
      @id = id
      @unit = unit
      @width = unit.width
      @height = unit.height
      @chipset_id = unit.chipset_id
      @lower = unit.lower_layer || []
      @upper = unit.upper_layer || []
    end

    def in_bounds?(x, y)
      x >= 0 && y >= 0 && x < @width && y < @height
    end

    def lower(x, y); tile(@lower, x, y); end
    def upper(x, y); tile(@upper, x, y); end

    private

    def tile(layer, x, y)
      return nil unless in_bounds?(x, y)
      layer[y * @width + x]
    end
  end

  # The overall running-game state: who is in the party and where they are.
  # The current Map is attached once loaded; direction follows RPG2000's numpad
  # convention (2 down, 4 left, 6 right, 8 up).
  class State
    attr_reader :party
    attr_accessor :map, :map_id, :x, :y, :direction

    def initialize(party, map_id, x, y)
      @party = party
      @map_id = map_id
      @x = x
      @y = y
      @direction = 2
      @map = nil
    end
  end
end
