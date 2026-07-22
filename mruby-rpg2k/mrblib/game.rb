# In-memory game state built from the parsed LCF database and map data.
#
# These classes deliberately hold only plain data derived from LCF::Database /
# LCF::MapUnit; nothing here touches RGSS or draws to the screen. That keeps the
# "New Game" logic (building a party and locating the start map) independent of
# the not-yet-implemented map renderer, and unit-testable on its own.
module Game
  # One party member, snapshotted from the database's actor (player) table.
  class Actor
    attr_reader :id, :name, :level
    attr_accessor :hp, :mp
    attr_reader :max_hp, :max_mp, :atk, :def, :int, :agi

    def initialize(db, id)
      @id = id
      a = db.player[id]
      raise "No such actor: #{id}" if a.nil?

      @name = a.name
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
