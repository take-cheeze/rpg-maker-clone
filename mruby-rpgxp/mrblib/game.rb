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

    # A movable grid entity (a map event, or the player). Directions are the
    # numpad convention shared with RPG2000: 2 down, 4 left, 6 right, 8 up.
    class Character
      DIR_DELTA = { 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0], 8 => [0, -1] }.freeze
      # 90-degree clockwise / counter-clockwise turns and the 180-degree flip.
      TURN_RIGHT = { 8 => 6, 6 => 2, 2 => 4, 4 => 8 }.freeze
      TURN_LEFT  = { 8 => 4, 4 => 2, 2 => 6, 6 => 8 }.freeze
      TURN_180   = { 8 => 2, 2 => 8, 4 => 6, 6 => 4 }.freeze
      CARDINALS = [2, 4, 6, 8].freeze

      attr_accessor :x, :y, :direction, :move_speed, :move_frequency,
                    :through, :direction_fix, :walk_anime, :step_anime,
                    :always_on_top, :opacity, :blend_type
      attr_reader :graphic_name, :graphic_hue, :pattern

      def initialize(x = 0, y = 0, direction = 2)
        @x = x
        @y = y
        @direction = direction
        @move_speed = 3
        @move_frequency = 3
        @through = false
        @direction_fix = false
        @walk_anime = true
        @step_anime = false
        @always_on_top = false
        @opacity = 255
        @blend_type = 0
        @graphic_name = nil
        @graphic_hue = 0
        @pattern = 0
      end

      def set_graphic(name, hue = 0, direction = nil, pattern = nil)
        @graphic_name = name
        @graphic_hue = hue || 0
        face(direction) if direction && direction > 0
        @pattern = pattern if pattern
      end

      def self.step_tile(px, py, dir)
        dx, dy = DIR_DELTA[dir] || [0, 0]
        [px + dx, py + dy]
      end

      def front_tile(dir = @direction)
        Character.step_tile(@x, @y, dir)
      end

      # Turn to face `dir` (a no-op while facing is locked / direction-fixed).
      def face(dir)
        @direction = dir unless @direction_fix || dir.nil?
      end

      def move(dir)
        face(dir)
        dx, dy = DIR_DELTA[dir] || [0, 0]
        @x += dx
        @y += dy
      end

      # Move one tile diagonally; RMXP keeps a cardinal facing, favouring the
      # vertical part unless already facing one of the two component directions.
      def move_diagonal(horizontal, vertical)
        face(vertical) unless @direction == horizontal || @direction == vertical
        hx, = DIR_DELTA[horizontal] || [0, 0]
        _, vy = DIR_DELTA[vertical] || [0, 0]
        @x += hx
        @y += vy
      end

      def turn_right;  @direction = TURN_RIGHT[@direction] || @direction; end
      def turn_left;   @direction = TURN_LEFT[@direction]  || @direction; end
      def turn_around; @direction = TURN_180[@direction]   || @direction; end

      # Direction pointing from this character toward (tx, ty); ties resolve to
      # the horizontal axis. Returns the current facing when already on the tile.
      def direction_toward(tx, ty)
        dx = tx - @x
        dy = ty - @y
        if dx.abs >= dy.abs && dx != 0
          dx > 0 ? 6 : 4
        elsif dy != 0
          dy > 0 ? 2 : 8
        else
          @direction
        end
      end

      def direction_away(tx, ty)
        TURN_180[direction_toward(tx, ty)] || @direction
      end
    end

    # Runtime execution of an RMXP move route (an RPG::MoveRoute: a list of
    # RPG::MoveCommand with the XP move-command codes, plus repeat / skippable
    # flags). A MoveRoute is a cursor over that list; `step` runs the command
    # under the cursor against a Character and advances. Movement commands ask
    # the `world` whether the destination is passable; a non-repeating route
    # reports `done?` once every command has run.
    #
    # `world` responds to: passable?(character, dir), hero_position -> [x, y],
    # set_switch(id, on), play_sound(audio), random(n) -> 0...n.
    class MoveRoute
      # XP move-command codes (RPG::MoveCommand#code).
      DOWN = 1; LEFT = 2; RIGHT = 3; UP = 4
      LOWER_LEFT = 5; LOWER_RIGHT = 6; UPPER_LEFT = 7; UPPER_RIGHT = 8
      RANDOM = 9; TOWARD = 10; AWAY = 11; FORWARD = 12; BACKWARD = 13
      JUMP = 14; WAIT = 15
      TURN_DOWN = 16; TURN_LEFT = 17; TURN_RIGHT = 18; TURN_UP = 19
      TURN_90R = 20; TURN_90L = 21; TURN_180 = 22; TURN_90RL = 23
      TURN_RANDOM = 24; TURN_TOWARD = 25; TURN_AWAY = 26
      SWITCH_ON = 27; SWITCH_OFF = 28; CHANGE_SPEED = 29; CHANGE_FREQ = 30
      WALK_ON = 31; WALK_OFF = 32; STEP_ON = 33; STEP_OFF = 34
      DIRFIX_ON = 35; DIRFIX_OFF = 36; THROUGH_ON = 37; THROUGH_OFF = 38
      TOP_ON = 39; TOP_OFF = 40
      CHANGE_GRAPHIC = 41; CHANGE_OPACITY = 42; CHANGE_BLEND = 43
      PLAY_SE = 44; SCRIPT = 45

      MOVE_DIR = { DOWN => 2, LEFT => 4, RIGHT => 6, UP => 8 }.freeze
      DIAGONAL = { LOWER_LEFT => [4, 2], LOWER_RIGHT => [6, 2],
                   UPPER_LEFT => [4, 8], UPPER_RIGHT => [6, 8] }.freeze
      TURN_DIR = { TURN_DOWN => 2, TURN_LEFT => 4, TURN_RIGHT => 6, TURN_UP => 8 }.freeze

      def self.from_page(route)
        route && new(route.list || [], route.repeat, route.skippable)
      end

      def initialize(list, repeat, skippable)
        @list = list || []
        @repeat = repeat
        @skippable = skippable
        @index = 0
        @done = @list.empty?
      end

      def done?; @done; end

      # Run the command under the cursor. Returns a status symbol; a blocked,
      # non-skippable move keeps the cursor so it retries next step.
      def step(character, world)
        return :done if @done
        cmd = @list[@index]
        return advance_done(true) if cmd.nil? || cmd.code == 0
        status, advance = execute(cmd, character, world)
        advance_cursor if advance
        status
      end

      private

      def advance_done(advance)
        advance_cursor if advance
        :done
      end

      def advance_cursor
        @index += 1
        return if @index < @list.size
        if @repeat
          @index = 0
        else
          @done = true
        end
      end

      def params(cmd)
        cmd.parameters || []
      end

      def execute(cmd, character, world)
        code = cmd.code
        case code
        when DOWN, LEFT, RIGHT, UP
          do_move(character, world, MOVE_DIR[code])
        when LOWER_LEFT, LOWER_RIGHT, UPPER_LEFT, UPPER_RIGHT
          do_diagonal(character, world, code)
        when RANDOM   then do_move(character, world, Character::CARDINALS[world.random(4)])
        when TOWARD   then do_move(character, world, toward(character, world))
        when AWAY     then do_move(character, world, away(character, world))
        when FORWARD  then do_move(character, world, character.direction)
        when BACKWARD then do_move(character, world, Character::TURN_180[character.direction])
        when JUMP     then [:jumped, true] # pixel jump is cosmetic; treat as a beat
        when WAIT     then [:waited, true]
        when TURN_DOWN, TURN_LEFT, TURN_RIGHT, TURN_UP
          character.face(TURN_DIR[code]); [:turned, true]
        when TURN_90R  then character.turn_right;  [:turned, true]
        when TURN_90L  then character.turn_left;   [:turned, true]
        when TURN_180  then character.turn_around; [:turned, true]
        when TURN_90RL
          world.random(2) == 0 ? character.turn_right : character.turn_left
          [:turned, true]
        when TURN_RANDOM then character.face(Character::CARDINALS[world.random(4)]); [:turned, true]
        when TURN_TOWARD then character.face(toward(character, world)); [:turned, true]
        when TURN_AWAY   then character.face(away(character, world));   [:turned, true]
        when SWITCH_ON  then world.set_switch(params(cmd)[0], true);  [:effect, true]
        when SWITCH_OFF then world.set_switch(params(cmd)[0], false); [:effect, true]
        when CHANGE_SPEED then character.move_speed = params(cmd)[0] || character.move_speed; [:effect, true]
        when CHANGE_FREQ  then character.move_frequency = params(cmd)[0] || character.move_frequency; [:effect, true]
        when WALK_ON    then character.walk_anime = true;  [:effect, true]
        when WALK_OFF   then character.walk_anime = false; [:effect, true]
        when STEP_ON    then character.step_anime = true;  [:effect, true]
        when STEP_OFF   then character.step_anime = false; [:effect, true]
        when DIRFIX_ON  then character.direction_fix = true;  [:effect, true]
        when DIRFIX_OFF then character.direction_fix = false; [:effect, true]
        when THROUGH_ON  then character.through = true;  [:effect, true]
        when THROUGH_OFF then character.through = false; [:effect, true]
        when TOP_ON     then character.always_on_top = true;  [:effect, true]
        when TOP_OFF    then character.always_on_top = false; [:effect, true]
        when CHANGE_GRAPHIC
          p = params(cmd)
          character.set_graphic(p[0], p[1], p[2], p[3]); [:effect, true]
        when CHANGE_OPACITY then character.opacity = params(cmd)[0] || character.opacity; [:effect, true]
        when CHANGE_BLEND   then character.blend_type = params(cmd)[0] || character.blend_type; [:effect, true]
        when PLAY_SE then world.play_sound(params(cmd)[0]); [:effect, true]
        else [:effect, true] # SCRIPT and any unsupported code: no-op, advance
        end
      end

      # One-tile move in `dir`. A blocked move on a non-skippable route keeps the
      # cursor (advance == false) so it retries; it still turns to face the wall.
      def do_move(character, world, dir)
        return [:turned, true] if dir.nil?
        if character.through || world.passable?(character, dir)
          character.move(dir)
          [:moved, true]
        else
          character.face(dir)
          @skippable ? [:blocked, true] : [:blocked, false]
        end
      end

      def do_diagonal(character, world, code)
        horizontal, vertical = DIAGONAL[code]
        passable = character.through ||
                   (world.passable?(character, horizontal) &&
                    world.passable?(character, vertical))
        if passable
          character.move_diagonal(horizontal, vertical)
          [:moved, true]
        else
          character.face(vertical)
          @skippable ? [:blocked, true] : [:blocked, false]
        end
      end

      def toward(character, world)
        hx, hy = world.hero_position
        character.direction_toward(hx, hy)
      end

      def away(character, world)
        hx, hy = world.hero_position
        character.direction_away(hx, hy)
      end
    end

    # Autonomous (non-custom) event movement: given a page's move_type, pick the
    # direction the character should try next. Returns a numpad direction, or nil
    # for "no autonomous movement" (fixed) and for the custom-route type (driven
    # by a MoveRoute instead). RMXP has four types.
    module MoveType
      FIXED    = 0
      RANDOM   = 1
      APPROACH = 2
      CUSTOM   = 3

      def self.next_direction(type, character, world)
        case type
        when RANDOM   then Character::CARDINALS[world.random(4)]
        when APPROACH
          hx, hy = world.hero_position
          character.direction_toward(hx, hy)
        else nil # FIXED / CUSTOM: no autonomous step
        end
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
