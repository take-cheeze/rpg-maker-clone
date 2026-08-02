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

  # Expansion of RPG2000 message control codes. `\v[n]` inserts variable n,
  # `\n[n]` the name of actor n, `\\` a literal backslash; the display-only codes
  # (`\c`/`\s` colour/speed, `\.`/`\|`/`\!` waits, `\>`/`\<`, `\^`, `\_`, `\$`)
  # are consumed. `names` may be a Hash or any object responding to `[]`.
  module Message
    def self.expand(text, variables, names)
      return '' if text.nil?
      out = ''
      i = 0
      n = text.length
      while i < n
        ch = text[i]
        if ch == "\\" && i + 1 < n
          code = text[i + 1]
          i += 2
          arg, i = read_bracket(text, i)
          case code
          when 'v', 'V' then out << variables[arg.to_i].to_s if arg
          when 'n', 'N' then out << (names[arg.to_i] || '').to_s if arg
          when "\\"     then out << "\\"
          # colour/speed/wait/etc. produce no visible characters: dropped.
          end
        else
          out << ch
          i += 1
        end
      end
      out
    end

    # Read an optional "[digits]" argument at position i; returns [value, new_i].
    def self.read_bracket(text, i)
      return [nil, i] unless i < text.length && text[i] == '['
      j = i + 1
      j += 1 while j < text.length && text[j] != ']'
      val = text[(i + 1)...j]
      j += 1 if j < text.length # consume ']'
      [val, j]
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

  # Game switches: a 1-indexed set of booleans, defaulting to false.
  class Switches
    def initialize; @data = {}; end
    def [](id); @data[id] || false; end
    def []=(id, v); @data[id] = v ? true : false; end
    def flip(id); self[id] = !self[id]; end
    def to_h; @data; end
    def replace(h); @data = h || {}; end
  end

  # Game variables: a 1-indexed set of integers, defaulting to 0.
  class Variables
    def initialize; @data = {}; end
    def [](id); @data[id] || 0; end
    def []=(id, v); @data[id] = v; end
    def to_h; @data; end
    def replace(h); @data = h || {}; end
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

    attr_reader :actors, :items, :gold

    def initialize(db, ids = nil)
      @db = db
      ids ||= db.system.party || []
      @actors = ids.reject { |i| i.nil? || i <= 0 }.map { |i| Actor.new(db, i) }
      @items = {}  # item id => count
      @gold = 0
    end

    # Serialise the mutable party state (see State#to_h).
    def to_h
      hp = {}
      mp = {}
      @actors.each { |a| hp[a.id] = a.hp; mp[a.id] = a.mp }
      { actor_ids: @actors.map { |a| a.id }, items: @items, gold: @gold,
        hp: hp, mp: mp }
    end

    # Restore item/gold and per-actor hp/mp from a saved party hash.
    def load_state(data)
      @items = data[:items] || {}
      @gold = data[:gold] || 0
      hp = data[:hp] || {}
      mp = data[:mp] || {}
      @actors.each do |a|
        a.hp = hp[a.id] if hp[a.id]
        a.mp = mp[a.id] if mp[a.id]
      end
    end

    def each(&blk); @actors.each(&blk); end
    def size; @actors.size; end
    def leader; @actors.first; end

    def include_actor?(id); @actors.any? { |a| a.id == id }; end

    def add_actor(id)
      return if include_actor?(id)
      @actors.push Actor.new(@db, id)
    end

    def remove_actor(id); @actors.reject! { |a| a.id == id }; end

    def item_count(id); @items[id] || 0; end
    def has_item?(id); item_count(id) > 0; end

    def gain_item(id, n = 1)
      c = item_count(id) + n
      c = 0 if c < 0
      c = 99 if c > 99
      @items[id] = c
    end

    def lose_item(id, n = 1); gain_item(id, -n); end

    def gain_gold(n)
      @gold += n
      @gold = 0 if @gold < 0
      @gold = 999_999 if @gold > 999_999
    end
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

  # A tiny deterministic pseudo-random generator. mruby is built here without
  # the `mruby-random` gem (see build_config.rb), so `Kernel#rand` is not
  # available; move routes and autonomous movement need *some* randomness, so we
  # supply our own. This is a small LCG (multiplier 75, modulus the prime 65537)
  # whose arithmetic stays within a signed 32-bit `mrb_int` — no value ever
  # reaches 2**31 — so it never has to promote to a bigint on this target. The
  # period (65536) and quality are more than enough for picking a walk
  # direction, and seeding it makes NPC wandering reproducible.
  class Rng
    def initialize(seed = 1)
      @state = (seed & 0xFFFF) + 1
    end

    def next_int
      @state = (@state * 75 + 74) % 65537
    end

    # An integer in 0...n (0 when n <= 0).
    def random(n)
      return 0 if n <= 0
      next_int % n
    end
  end

  # A movable map entity: its tile position, facing and the movement-related
  # flags a move route can toggle. Nothing here draws — Scene::Map reads the
  # position/direction to place the sprite. Directions use RPG2000's numpad
  # convention (2 = down, 4 = left, 6 = right, 8 = up).
  class Character
    # numpad direction -> [dx, dy] step in tiles.
    DIR_DELTA = { 8 => [0, -1], 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0] }.freeze
    # 90-degree clockwise / counter-clockwise rotations and the 180-degree flip.
    TURN_RIGHT = { 8 => 6, 6 => 2, 2 => 4, 4 => 8 }.freeze
    TURN_LEFT  = { 8 => 4, 4 => 2, 2 => 6, 6 => 8 }.freeze
    TURN_180   = { 8 => 2, 2 => 8, 4 => 6, 6 => 4 }.freeze
    # The four cardinal directions, indexable for random selection.
    CARDINALS = [2, 4, 6, 8].freeze

    attr_accessor :x, :y, :direction, :move_speed, :move_frequency
    attr_accessor :through, :facing_locked, :animation_stopped, :transparency
    attr_reader :graphic_name, :graphic_index

    def initialize(x = 0, y = 0, direction = 2)
      @x = x
      @y = y
      @direction = direction
      @move_speed = 3
      @move_frequency = 3
      @through = false          # ignore collision while moving
      @facing_locked = false    # keep facing fixed while moving
      @animation_stopped = false
      @transparency = 0         # 0 opaque .. 7 fully transparent
      @graphic_name = nil
      @graphic_index = 0
    end

    def set_graphic(name, index)
      @graphic_name = name
      @graphic_index = index
    end

    # Tile [x, y] one step from (px, py) in numpad direction `dir`.
    def self.step_tile(px, py, dir)
      dx, dy = DIR_DELTA[dir] || [0, 0]
      [px + dx, py + dy]
    end

    # The tile immediately ahead of the character in the given direction
    # (its current facing by default).
    def front_tile(dir = @direction)
      Character.step_tile(@x, @y, dir)
    end

    # Turn to face `dir` without moving (a no-op while facing is locked).
    def face(dir)
      @direction = dir unless @facing_locked || dir.nil?
    end

    # Move one tile in `dir`, updating facing (subject to the lock).
    def move(dir)
      face(dir)
      dx, dy = DIR_DELTA[dir] || [0, 0]
      @x += dx
      @y += dy
    end

    # Move one tile diagonally, combining a horizontal and a vertical direction.
    # RPG2000 keeps a cardinal facing on diagonals, so we face the vertical part.
    def move_diagonal(horizontal, vertical)
      face(vertical)
      hx, = DIR_DELTA[horizontal] || [0, 0]
      _, vy = DIR_DELTA[vertical] || [0, 0]
      @x += hx
      @y += vy
    end

    def turn_right;  @direction = TURN_RIGHT[@direction] || @direction; end
    def turn_left;   @direction = TURN_LEFT[@direction]  || @direction; end
    def turn_around; @direction = TURN_180[@direction]   || @direction; end

    # Direction pointing from this character toward (tx, ty). Ties (and equal
    # distance) resolve to the horizontal axis, matching RPG2000's toward-hero
    # behaviour; returns the current facing when already on the tile.
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

    # Direction pointing away from (tx, ty): the opposite of #direction_toward.
    def direction_away(tx, ty)
      TURN_180[direction_toward(tx, ty)] || @direction
    end
  end

  # Runtime execution of a decoded LCF move route (an array of LCF::MoveCommand,
  # as produced by LCF.parse_move_commands and stored on an event page's
  # `move_route`). A MoveRoute is a cursor over that list: `step` runs the
  # command under the cursor against a Character and advances. Movement commands
  # ask the `world` whether the destination is passable; parameterised commands
  # apply their side effect through the world (switches, sound). A non-repeating
  # route reports `done?` once every command has run; a repeating route wraps.
  #
  # `world` is any object responding to:
  #   passable?(character, dir) -> can the character step one tile in `dir`?
  #   hero_position             -> [x, y] of the player (toward/away/face hero)
  #   set_switch(id, on)        -> apply a switch side effect
  #   play_sound(name, volume, tempo, balance)
  #   random(n)                 -> integer in 0...n
  class MoveRoute
    # Move-command ids (RPG2000 move-route opcodes). 0..11 move, 12..22 turn,
    # 23..25 wait/jump, 26..41 toggle a character flag or apply a side effect.
    MOVE_UP = 0; MOVE_RIGHT = 1; MOVE_DOWN = 2; MOVE_LEFT = 3
    MOVE_UPRIGHT = 4; MOVE_DOWNRIGHT = 5; MOVE_DOWNLEFT = 6; MOVE_UPLEFT = 7
    MOVE_RANDOM = 8; MOVE_TOWARD_HERO = 9; MOVE_AWAY_HERO = 10; MOVE_FORWARD = 11
    FACE_UP = 12; FACE_RIGHT = 13; FACE_DOWN = 14; FACE_LEFT = 15
    TURN_RIGHT = 16; TURN_LEFT = 17; TURN_180 = 18; TURN_RANDOM = 19
    FACE_RANDOM = 20; FACE_HERO = 21; FACE_AWAY_HERO = 22
    WAIT = 23; BEGIN_JUMP = 24; END_JUMP = 25
    LOCK_FACING = 26; UNLOCK_FACING = 27
    SPEED_UP = 28; SPEED_DOWN = 29; FREQ_UP = 30; FREQ_DOWN = 31
    SWITCH_ON = 32; SWITCH_OFF = 33; CHANGE_GRAPHIC = 34; PLAY_SOUND = 35
    THROUGH_ON = 36; THROUGH_OFF = 37; STOP_ANIM = 38; START_ANIM = 39
    TRANSP_UP = 40; TRANSP_DOWN = 41

    # move-command id -> numpad direction, for the four cardinal moves.
    MOVE_DIR = { MOVE_UP => 8, MOVE_RIGHT => 6, MOVE_DOWN => 2, MOVE_LEFT => 4 }.freeze
    # diagonal move-command id -> [horizontal dir, vertical dir].
    DIAGONAL = { MOVE_UPRIGHT => [6, 8], MOVE_DOWNRIGHT => [6, 2],
                 MOVE_DOWNLEFT => [4, 2], MOVE_UPLEFT => [4, 8] }.freeze
    # face-command id -> direction to face.
    FACE_DIR = { FACE_UP => 8, FACE_RIGHT => 6, FACE_DOWN => 2, FACE_LEFT => 4 }.freeze

    def initialize(commands, repeat: true, skippable: false)
      @commands = commands || []
      @repeat = repeat ? true : false
      @skippable = skippable ? true : false
      @index = 0
      @done = @commands.empty?
    end

    attr_reader :index

    def done?; @done; end
    def empty?; @commands.empty?; end
    def repeat?; @repeat; end
    def skippable?; @skippable; end

    # Build a MoveRoute from an event page's parsed `move_route` field (an
    # LCF::Array1D exposing commands/repeat/skippable), or nil when the page
    # carries no custom route.
    def self.from_page(route)
      return nil if route.nil?
      cmds = route.commands
      return nil if cmds.nil? || cmds.empty?
      new(cmds, repeat: route.repeat, skippable: route.skippable)
    rescue StandardError => e
      $stderr.puts "[RPG2k] move route parse failed, event uses no custom route: #{e.message}"
      nil
    end

    # Run the command under the cursor against `character`. Returns a status
    # symbol: :moved, :blocked, :turned, :waited, :effect or :done. A blocked
    # move on a non-skippable route stays on the same command so the next `step`
    # retries it (it still turns to face the obstacle) and returns :blocked; a
    # skippable route advances past a blocked move instead.
    def step(character, world)
      return :done if @done
      status, advance = execute(@commands[@index], character, world)
      advance_cursor if advance
      status
    end

    private

    def advance_cursor
      @index += 1
      return if @index < @commands.size
      if @repeat
        @index = 0
      else
        @done = true
      end
    end

    def execute(cmd, character, world)
      id = cmd.command_id
      case id
      when MOVE_UP, MOVE_RIGHT, MOVE_DOWN, MOVE_LEFT
        do_move(character, world, MOVE_DIR[id])
      when MOVE_UPRIGHT, MOVE_DOWNRIGHT, MOVE_DOWNLEFT, MOVE_UPLEFT
        do_diagonal(character, world, id)
      when MOVE_RANDOM
        do_move(character, world, Character::CARDINALS[world.random(4)])
      when MOVE_TOWARD_HERO
        do_move(character, world, toward_hero(character, world))
      when MOVE_AWAY_HERO
        do_move(character, world, away_hero(character, world))
      when MOVE_FORWARD
        do_move(character, world, character.direction)
      when FACE_UP, FACE_RIGHT, FACE_DOWN, FACE_LEFT
        character.face(FACE_DIR[id]); [:turned, true]
      when TURN_RIGHT then character.turn_right;  [:turned, true]
      when TURN_LEFT  then character.turn_left;   [:turned, true]
      when TURN_180   then character.turn_around; [:turned, true]
      when TURN_RANDOM
        world.random(2) == 0 ? character.turn_right : character.turn_left
        [:turned, true]
      when FACE_RANDOM
        character.face(Character::CARDINALS[world.random(4)]); [:turned, true]
      when FACE_HERO      then character.face(toward_hero(character, world)); [:turned, true]
      when FACE_AWAY_HERO then character.face(away_hero(character, world));  [:turned, true]
      when WAIT, BEGIN_JUMP, END_JUMP then [:waited, true]
      when LOCK_FACING   then character.facing_locked = true;  [:effect, true]
      when UNLOCK_FACING then character.facing_locked = false; [:effect, true]
      when SPEED_UP   then character.move_speed = [character.move_speed + 1, 6].min; [:effect, true]
      when SPEED_DOWN then character.move_speed = [character.move_speed - 1, 1].max; [:effect, true]
      when FREQ_UP    then character.move_frequency = [character.move_frequency + 1, 8].min; [:effect, true]
      when FREQ_DOWN  then character.move_frequency = [character.move_frequency - 1, 1].max; [:effect, true]
      when SWITCH_ON  then world.set_switch(cmd.parameter_a, true);  [:effect, true]
      when SWITCH_OFF then world.set_switch(cmd.parameter_a, false); [:effect, true]
      when CHANGE_GRAPHIC
        character.set_graphic(cmd.parameter_string, cmd.parameter_a); [:effect, true]
      when PLAY_SOUND
        world.play_sound(cmd.parameter_string, cmd.parameter_a,
                         cmd.parameter_b, cmd.parameter_c)
        [:effect, true]
      when THROUGH_ON  then character.through = true;  [:effect, true]
      when THROUGH_OFF then character.through = false; [:effect, true]
      when STOP_ANIM   then character.animation_stopped = true;  [:effect, true]
      when START_ANIM  then character.animation_stopped = false; [:effect, true]
      when TRANSP_UP   then character.transparency = [character.transparency + 1, 7].min; [:effect, true]
      when TRANSP_DOWN then character.transparency = [character.transparency - 1, 0].max; [:effect, true]
      else [:effect, true] # unknown / unsupported id: no-op, advance past it
      end
    end

    # Attempt a one-tile move in `dir`. Returns [status, advance?]: a blocked
    # move on a non-skippable route returns advance == false so it is retried.
    def do_move(character, world, dir)
      return [:turned, true] if dir.nil?
      if character.through || world.passable?(character, dir)
        character.move(dir)
        [:moved, true]
      else
        character.face(dir) # an obstructed move still turns to face it
        @skippable ? [:blocked, true] : [:blocked, false]
      end
    end

    def do_diagonal(character, world, id)
      horizontal, vertical = DIAGONAL[id]
      character.face(vertical)
      passable = character.through ||
                 (world.passable?(character, horizontal) &&
                  world.passable?(character, vertical))
      if passable
        character.move_diagonal(horizontal, vertical)
        [:moved, true]
      else
        @skippable ? [:blocked, true] : [:blocked, false]
      end
    end

    def toward_hero(character, world)
      hx, hy = world.hero_position
      character.direction_toward(hx, hy)
    end

    def away_hero(character, world)
      hx, hy = world.hero_position
      character.direction_away(hx, hy)
    end
  end

  # Autonomous (non-custom) event movement: given a page's `move_type`, pick the
  # direction the character should try to step next. `random` picks a cardinal;
  # `vertical`/`horizontal` keep bouncing along one axis, reversing when the way
  # ahead is blocked; `toward`/`away` chase or flee the hero. Returns a numpad
  # direction, or nil for "no autonomous movement" (stationary) and for the
  # custom-route type (which is driven by a MoveRoute instead).
  module MoveType
    STATIONARY = 0
    RANDOM     = 1
    VERTICAL   = 2
    HORIZONTAL = 3
    TOWARD     = 4
    AWAY       = 5
    CUSTOM     = 6

    def self.next_direction(type, character, world)
      case type
      when RANDOM     then Character::CARDINALS[world.random(4)]
      when VERTICAL   then bounce(character, world, [8, 2])
      when HORIZONTAL then bounce(character, world, [4, 6])
      when TOWARD
        hx, hy = world.hero_position
        character.direction_toward(hx, hy)
      when AWAY
        hx, hy = world.hero_position
        character.direction_away(hx, hy)
      else nil
      end
    end

    # Continue along the current axis direction, reversing to the other end of
    # `pair` when the way ahead is blocked.
    def self.bounce(character, world, pair)
      cur = pair.include?(character.direction) ? character.direction : pair[0]
      return cur if world.passable?(character, cur)
      cur == pair[0] ? pair[1] : pair[0]
    end
  end

  # Evaluation of RPG2000 event-page conditions and page selection. A page is
  # active when every sub-condition enabled in its `flags` bitfield holds; the
  # active page for an event is the highest-numbered active page.
  module EventPage
    # flags bits (chunk 1 of the page condition).
    SWITCH_A = 0x01
    SWITCH_B = 0x02
    VARIABLE = 0x04
    ITEM     = 0x08
    ACTOR    = 0x10

    def self.active?(cond, switches, variables, party)
      return true if cond.nil?
      flags = cond.flags || 0
      return false if (flags & SWITCH_A) != 0 && !switches[cond.switch_a_id]
      return false if (flags & SWITCH_B) != 0 && !switches[cond.switch_b_id]
      if (flags & VARIABLE) != 0
        return false if variables[cond.variable_id] < cond.variable_value
      end
      if (flags & ITEM) != 0
        return false unless party && party.has_item?(cond.item_id)
      end
      if (flags & ACTOR) != 0
        return false unless party && party.include_actor?(cond.actor_id)
      end
      true
    end

    # Return [id, page] of the active page for an event, or nil when none apply.
    def self.select(pages, switches, variables, party)
      return nil if pages.nil?
      chosen = nil
      pages.each do |id, page|
        chosen = [id, page] if active?(page.condition, switches, variables, party)
      end
      chosen
    end
  end

  # Common events: shared command lists that can auto-start or run in parallel.
  # start_term selects how they run (3 auto-start, 4 parallel, 5 called only);
  # when need_flag is set a common event is gated on switch_id.
  module CommonEvent
    AUTO_START = 3
    PARALLEL   = 4

    # Load the common events from the database into plain hashes.
    def self.load(db)
      list = []
      ce = db.common_event
      return list unless ce
      ce.each do |id, c|
        list.push(id: id, trigger: c.start_term, need_flag: c.need_flag,
                  switch_id: c.switch_id, commands: c.event)
      end
      list
    rescue StandardError => e
      $stderr.puts "[RPG2k] common event load failed, none available: #{e.message}"
      []
    end

    # Common events eligible to run now (auto-start or parallel, and — when
    # gated — their switch is on).
    def self.eligible(events, switches)
      events.select do |e|
        next false unless e[:trigger] == AUTO_START || e[:trigger] == PARALLEL
        next true unless e[:need_flag]
        switches[e[:switch_id]]
      end
    end
  end

  # The overall running-game state: who is in the party and where they are,
  # plus the global switches and variables.
  class State
    attr_reader :party, :switches, :variables
    attr_accessor :map, :map_id, :x, :y, :direction, :timer_frames, :timer_running

    def initialize(party, map_id, x, y)
      @party = party
      @map_id = map_id
      @x = x
      @y = y
      @direction = 2
      @map = nil
      @switches = Switches.new
      @variables = Variables.new
      @timer_frames = 0
      @timer_running = false
    end

    # Advance the countdown timer one frame (call once per frame). Returns true
    # on the frame the timer reaches zero.
    def tick_timer
      return false unless @timer_running && @timer_frames > 0
      @timer_frames -= 1
      @timer_running = false if @timer_frames <= 0
      @timer_frames <= 0
    end

    # Remaining timer seconds (assuming 60 fps).
    def timer_seconds; @timer_frames / 60; end

    # Serialise to a plain hash of primitives (Marshal-friendly) for saving. The
    # map itself is not stored; it is reloaded from map_id on load.
    def to_h
      { map_id: @map_id, x: @x, y: @y, direction: @direction,
        switches: @switches.to_h, variables: @variables.to_h,
        party: @party.to_h, timer_frames: @timer_frames,
        timer_running: @timer_running }
    end

    # Rebuild a State from a saved hash. Actors are re-created from the database
    # by the saved ids, then their mutable state is restored.
    def self.load(db, h)
      pdata = h[:party] || {}
      party = Party.new(db, pdata[:actor_ids] || [])
      party.load_state(pdata)
      state = new(party, h[:map_id], h[:x], h[:y])
      state.direction = h[:direction] || 2
      state.switches.replace(h[:switches] || {})
      state.variables.replace(h[:variables] || {})
      state.timer_frames = h[:timer_frames] || 0
      state.timer_running = h[:timer_running] || false
      state
    end
  end
end
