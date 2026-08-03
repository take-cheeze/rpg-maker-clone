# Runtime game model for the RPG Maker XP scenes: the running State (party,
# position, switches/variables) plus small helpers for CharSet frame geometry,
# Tileset passability and the follow camera. Kept deliberately compact — this is
# the first walkable slice, matching the RPG2000 side's early map milestone.

class RPGXP
  module Game
    # The mutable game state: which map/tile the player stands on and the global
    # switch/variable stores. `party` is the list of actor ids; the database is
    # kept for name/graphic lookups. `map` is the currently loaded RPG::Map.
    class State
      def initialize(db, party_ids, map_id, x, y, direction = 2)
        @db = db
        @party = (party_ids || []).dup
        @map_id = map_id
        @x = x
        @y = y
        @direction = direction
        @map = nil
        @gold = 0
        @switches = Hash.new(false)
        @variables = Hash.new(0)
        # Self switches are per (map_id, event_id, channel). Global across the
        # game (they persist when you leave and re-enter a map), keyed the way
        # RMXP's $game_self_switches is.
        @self_switches = Hash.new(false)
      end

      attr_reader :db
      attr_accessor :map_id, :x, :y, :direction, :map, :party, :gold,
                    :switches, :variables, :self_switches

      # Read/write a self switch for a specific event on a specific map.
      def self_switch(map_id, event_id, ch)
        @self_switches[[map_id, event_id, ch]]
      end

      def set_self_switch(map_id, event_id, ch, on)
        @self_switches[[map_id, event_id, ch]] = on
      end

      # The lead actor's RPG::Actor record (nil when the party is empty or the id
      # is unknown), used for the on-map character graphic.
      def leader
        id = @party.first
        id && @db.actors[id]
      end

      # Portable save payload (our own Marshal format, not the RMXP .rxdata save).
      def to_h
        { map_id: @map_id, x: @x, y: @y, direction: @direction,
          party: @party, gold: @gold, switches: hash_to_plain(@switches),
          variables: hash_to_plain(@variables),
          self_switches: hash_to_plain(@self_switches) }
      end

      def self.load(db, h)
        s = new(db, h[:party], h[:map_id], h[:x], h[:y], h[:direction] || 2)
        s.gold = h[:gold] || 0
        (h[:switches] || {}).each { |k, v| s.switches[k] = v }
        (h[:variables] || {}).each { |k, v| s.variables[k] = v }
        (h[:self_switches] || {}).each { |k, v| s.self_switches[k] = v }
        s
      end

      private

      # Default-valued Hashes do not round-trip their default through Marshal in a
      # useful way, so persist a plain copy of the set entries only.
      def hash_to_plain(h)
        out = {}
        h.each { |k, v| out[k] = v }
        out
      end
    end

    # RPG Maker XP character sheets are a 4x4 grid: four columns (walk patterns)
    # by four rows (facing down/left/right/up, top to bottom). One frame is a
    # quarter of the sheet in each axis.
    module CharSet
      # RPG direction (2/4/6/8) -> sheet row.
      ROWS = { 2 => 0, 4 => 1, 6 => 2, 8 => 3 }.freeze
      # Column order walked while stepping. RMXP steps 0,1,2,3 and holds 0 when
      # idle; a plain 4-cycle reads fine for the placeholder movement.
      PATTERNS = [0, 1, 2, 3].freeze

      def self.cell_width(bitmap);  bitmap.width / 4;  end
      def self.cell_height(bitmap); bitmap.height / 4; end

      def self.frame_rect(bitmap, direction, pattern)
        cw = cell_width(bitmap)
        ch = cell_height(bitmap)
        row = ROWS[direction] || 0
        Rect.new(pattern * cw, row * ch, cw, ch)
      end
    end

    # Tileset passability. RMXP stores a passage flag per tile id in a 1-D Table:
    # the low nibble marks the sides a character may NOT cross (down/left/right/up
    # = 0x01/0x02/0x04/0x08); 0x0f is fully impassable. Tile ids run 0..383 for
    # the eight autotiles (48 each) then 384+ for the tileset tiles, indexing the
    # passages Table directly.
    class TileSet
      # RPG direction -> the passage bit that blocks moving that way.
      DIR_BIT = { 2 => 0x01, 4 => 0x02, 6 => 0x04, 8 => 0x08 }.freeze

      def initialize(db, tileset_id)
        ts = db.tilesets[tileset_id]
        @passages = ts && ts.passages
      end

      # Passage byte for a tile id (0 when unknown / out of range / empty).
      def passage(tile_id)
        return 0 if tile_id.nil? || tile_id == 0
        p = @passages
        return 0 unless p
        return 0 if tile_id >= p.xsize
        p[tile_id] || 0
      end

      # May a character leave the given cell in `dir`, considering all three map
      # layers of the destination? Blocked when any non-empty layer tile blocks
      # that side, or when the destination has no ground at all (all layers 0).
      def passable?(map, x, y, dir)
        bit = DIR_BIT[dir] || 0
        any_tile = false
        (0..2).each do |z|
          tid = map.data[x, y, z]
          next if tid.nil? || tid == 0
          any_tile = true
          return false if (passage(tid) & bit) != 0
          return false if (passage(tid) & 0x0f) == 0x0f
        end
        any_tile
      end
    end

    # Edge-clamped follow camera: centre `focus` in a `screen`-wide view over a
    # `world`-wide map, never scrolling past either edge (matches the RPG2000
    # camera helper).
    def self.camera_offset(focus, screen, world)
      return 0 if world <= screen
      off = focus - screen / 2
      off = 0 if off < 0
      max = world - screen
      off = max if off > max
      off
    end
  end
end
