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
      ce = db.common_events
      return list unless ce
      ce.each do |id, c|
        list.push(id: id, trigger: c.start_term, need_flag: c.need_flag,
                  switch_id: c.switch_id, commands: c.event_commands)
      end
      list
    rescue StandardError
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
