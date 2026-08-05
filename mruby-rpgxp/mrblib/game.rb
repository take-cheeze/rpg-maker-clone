# Runtime game model for the RPG Maker XP scenes: the running State (party,
# position, switches/variables) plus small helpers for CharSet frame geometry,
# Tileset passability and the follow camera. Kept deliberately compact — this is
# the first walkable slice, matching the RPG2000 side's early map milestone.

class RPGXP
  module Game
    # Expansion of RMXP message control codes. `\V[n]` (or `\v[n]`) inserts the
    # value of variable n, `\N[n]` the name of actor n, `\\` a literal backslash;
    # the display-only codes `\C[n]` (colour) and `\G` (gold window) produce no
    # characters and are consumed. `names` is any object responding to `[]`
    # (an id -> name lookup). Written in the mruby/CRuby common subset.
    module Message
      def self.expand(text, variables, names)
        return "" if text.nil?
        out = ""
        i = 0
        n = text.length
        while i < n
          ch = text[i]
          if ch == "\\" && i + 1 < n
            code = text[i + 1]
            i += 2
            arg, i = read_bracket(text, i)
            case code
            when "v", "V" then out << variables[arg.to_i].to_s if arg
            when "n", "N" then out << (names[arg.to_i] || "").to_s if arg
            when "\\"     then out << "\\"
            # \C[n] colour and \G gold window have no visible text: dropped
            # (the bracketed arg after \C is already consumed above).
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
        return [nil, i] unless i < text.length && text[i] == "["
        j = i + 1
        j += 1 while j < text.length && text[j] != "]"
        val = text[(i + 1)...j]
        j += 1 if j < text.length # consume ']'
        [val, j]
      end
    end

    # RMXP's `$game_system`, narrowed to the fields an event command writes: the
    # three access switches, the battle-music overrides and the message-box
    # options. They live apart from the switches and variables because a game
    # treats them as configuration -- "no saving inside this dungeon", "this
    # boss brings its own music" -- and expects them to persist the way progress
    # does, so they are part of the save (see State#to_h).
    #
    # The rest of Game_System (play time, the timer, the save count) is
    # bookkeeping no command sets and the runtime does not keep.
    class System
      # Change Text Options (104), parameter 0: where the message box sits.
      MSG_TOP    = 0
      MSG_MIDDLE = 1
      MSG_BOTTOM = 2
      # ... parameter 1: whether the windowskin panel is drawn behind the text.
      MSG_FRAMED    = 0
      MSG_FRAMELESS = 1

      def initialize
        @save_disabled = false
        @menu_disabled = false
        @encounter_disabled = false
        # nil means "not overridden", so a reader falls back to the database's
        # own battle_bgm / battle_end_me. Change Battle BGM (132) carrying an
        # empty RPG::AudioFile means *silence*, which is a different thing, so
        # the two cannot share one representation.
        @battle_bgm = nil
        @battle_end_me = nil
        @message_position = MSG_BOTTOM
        @message_frame = MSG_FRAMED
      end

      attr_accessor :save_disabled, :menu_disabled, :encounter_disabled,
                    :battle_bgm, :battle_end_me,
                    :message_position, :message_frame

      # An RPG::AudioFile reduced to the three plain fields anything that plays
      # it needs. The overrides are held this way rather than as the data object
      # itself because they go into the save, which is our own portable hash
      # (State#to_h) -- putting an RGSS data object in there would tie a save
      # file to the schema. nil in, nil out.
      def self.audio_fields(audio)
        return nil unless audio && audio.respond_to?(:name) && audio.name
        { name: audio.name,
          volume: audio.respond_to?(:volume) ? (audio.volume || 100) : 100,
          pitch: audio.respond_to?(:pitch) ? (audio.pitch || 100) : 100 }
      end

      def to_h
        { save_disabled: @save_disabled, menu_disabled: @menu_disabled,
          encounter_disabled: @encounter_disabled,
          battle_bgm: @battle_bgm, battle_end_me: @battle_end_me,
          message_position: @message_position, message_frame: @message_frame }
      end

      def load_h(h)
        return self unless h
        @save_disabled = h[:save_disabled] ? true : false
        @menu_disabled = h[:menu_disabled] ? true : false
        @encounter_disabled = h[:encounter_disabled] ? true : false
        @battle_bgm = h[:battle_bgm]
        @battle_end_me = h[:battle_end_me]
        @message_position = h[:message_position] || MSG_BOTTOM
        @message_frame = h[:message_frame] || MSG_FRAMED
        self
      end
    end

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
        # Party possessions, mirroring $game_party's separate item / weapon /
        # armor stores (id => count, each capped at 99 like RMXP).
        @items = Hash.new(0)
        @weapons = Hash.new(0)
        @armors = Hash.new(0)
        # RMXP's Game_Player#transparent, set by Change Transparent Flag (208):
        # the party leader is not drawn while it is on. Games use it to hand a
        # cutscene over to an event that stands where the hero does.
        @player_transparent = false
        # The Game_System settings the event commands write (access switches,
        # battle music overrides, message options).
        @system = System.new
      end

      MAX_ITEMS = 99

      attr_reader :db, :system
      attr_accessor :map_id, :x, :y, :direction, :map, :party, :gold,
                    :switches, :variables, :self_switches,
                    :items, :weapons, :armors, :player_transparent

      # Possession counts, clamped to 0..MAX_ITEMS. `store` is one of :items /
      # :weapons / :armors.
      def item_count(id);   @items[id];   end
      def weapon_count(id); @weapons[id]; end
      def armor_count(id);  @armors[id];  end

      def gain_item(id, n = 1);   change_possession(@items, id, n);   end
      def gain_weapon(id, n = 1); change_possession(@weapons, id, n); end
      def gain_armor(id, n = 1);  change_possession(@armors, id, n);  end

      # Read/write a self switch for a specific event on a specific map.
      def self_switch(map_id, event_id, ch)
        @self_switches[[map_id, event_id, ch]]
      end

      def set_self_switch(map_id, event_id, ch, on)
        @self_switches[[map_id, event_id, ch]] = on
      end

      # The lead party member as a live Game::Actor (nil when the party is empty
      # or the id is unknown), used for the on-map character graphic.
      #
      # Live rather than the raw RPG::Actor record so Change Actor Graphic (322)
      # is visible: the command overrides the actor's charset, and reading the
      # database record straight would keep drawing the graphic the editor
      # shipped no matter what the event set.
      def leader
        actor(@party.first)
      end

      # The live Game::Actor for actor `id` (any database actor, not only party
      # members), built from the database on first use and memoised so its
      # mutable state -- once the Change Actor commands mutate it -- persists
      # across the game, the way RMXP's `$game_actors[id]` does. Returns nil for
      # an unknown id.
      def actor(id)
        return nil if id.nil? || id == 0 || @db.actors[id].nil?
        @actors ||= {}
        @actors[id] ||= Actor.new(@db, id)
      end

      # Portable save payload (our own Marshal format, not the RMXP .rxdata save).
      # `actors` holds only the actors whose live state has been touched (built via
      # #actor); untouched actors re-derive from the database identically on load.
      def to_h
        { map_id: @map_id, x: @x, y: @y, direction: @direction,
          party: @party, gold: @gold, switches: hash_to_plain(@switches),
          variables: hash_to_plain(@variables),
          self_switches: hash_to_plain(@self_switches),
          items: hash_to_plain(@items), weapons: hash_to_plain(@weapons),
          armors: hash_to_plain(@armors), actors: actor_states,
          player_transparent: @player_transparent, system: @system.to_h }
      end

      def self.load(db, h)
        s = new(db, h[:party], h[:map_id], h[:x], h[:y], h[:direction] || 2)
        s.gold = h[:gold] || 0
        (h[:switches] || {}).each { |k, v| s.switches[k] = v }
        (h[:variables] || {}).each { |k, v| s.variables[k] = v }
        (h[:self_switches] || {}).each { |k, v| s.self_switches[k] = v }
        (h[:items] || {}).each { |k, v| s.items[k] = v }
        (h[:weapons] || {}).each { |k, v| s.weapons[k] = v }
        (h[:armors] || {}).each { |k, v| s.armors[k] = v }
        (h[:actors] || {}).each { |id, ah| a = s.actor(id); a && a.load_h(ah) }
        s.player_transparent = h[:player_transparent] ? true : false
        s.system.load_h(h[:system])
        s
      end

      # The saved live state of every actor built so far (id => Game::Actor#to_h).
      def actor_states
        out = {}
        (@actors || {}).each { |id, a| out[id] = a.to_h }
        out
      end

      private

      # Adjust a possession store by `n`, clamped to 0..MAX_ITEMS.
      def change_possession(store, id, n)
        c = store[id] + n
        c = 0 if c < 0
        c = MAX_ITEMS if c > MAX_ITEMS
        store[id] = c
      end

      # Default-valued Hashes do not round-trip their default through Marshal in a
      # useful way, so persist a plain copy of the set entries only.
      def hash_to_plain(h)
        out = {}
        h.each { |k, v| out[k] = v }
        out
      end
    end

    # A party actor's live menu/battle state, wrapping its RPG::Actor database
    # record (and RPG::Class). Level-derived stats come straight from the actor's
    # `parameters` Table (kind 0 max HP, 1 max SP, 2 str, 3 dex, 4 agi, 5 int),
    # the known skills from the class's learnings up to the current level, and the
    # equipment from the actor's default weapon and four armor slots. The Change
    # Actor event commands will mutate this object rather than the shared database
    # record; for now it exposes what the actor Conditional Branch sub-conditions
    # (skill learned / weapon / armor equipped) need to read.
    class Actor
      # Parameter kinds indexing the RPG::Actor#parameters Table.
      PARAM_MAXHP = 0
      PARAM_MAXSP = 1
      PARAM_STR   = 2
      PARAM_DEX   = 3
      PARAM_AGI   = 4
      PARAM_INT   = 5

      attr_reader :id, :exp
      attr_accessor :level, :hp, :sp, :skills,
                    :weapon_id, :armor1_id, :armor2_id, :armor3_id, :armor4_id,
                    :character_name, :character_hue, :battler_name, :battler_hue

      def initialize(db, id)
        @db = db
        @id = id
        @record = db.actors[id]
        raise "No such actor: #{id}" if @record.nil?
        @class = db.classes[@record.class_id]
        @level = @record.initial_level
        make_exp_list
        @exp = @exp_list[@level] || 0
        @weapon_id = @record.weapon_id
        @armor1_id = @record.armor1_id
        @armor2_id = @record.armor2_id
        @armor3_id = @record.armor3_id
        @armor4_id = @record.armor4_id
        @skills = learnable_skills(@level)
        @hp = max_hp
        @sp = max_sp
        # The graphics start as the database's and are overwritten by Change
        # Actor Graphic (322); they are held here rather than read back off the
        # record so the override is per-save, not a mutation of the database
        # every later State would inherit.
        @character_name = @record.character_name
        @character_hue = @record.character_hue
        @battler_name = @record.battler_name
        @battler_hue = @record.battler_hue
      end

      # The actor's database display name.
      def name; @record.name; end

      # Total EXP required to *be at* `level` (0 at level 1, 0 beyond
      # final_level). nil for an out-of-range level.
      def exp_for_level(level); @exp_list[level]; end

      # A level-derived stat read from the parameters table (`parameters[kind,
      # level]`); level is 1-based, matching the table the editor writes.
      def param(kind); @record.parameters[kind, @level]; end
      def max_hp; param(PARAM_MAXHP); end
      def max_sp; param(PARAM_MAXSP); end
      def str;    param(PARAM_STR);   end
      def dex;    param(PARAM_DEX);   end
      def agi;    param(PARAM_AGI);   end
      def int;    param(PARAM_INT);   end

      # -- Conditional Branch actor predicates --------------------------------
      # Matched to RMXP's command_111 actor tests (exact-match on the equipped
      # weapon / any of the four armor slots), so they mirror the editor's
      # behaviour including its quirks (an id of 0 tests the empty slot).

      def knows_skill?(skill_id); @skills.include?(skill_id); end

      def weapon_equipped?(weapon_id); @weapon_id == weapon_id; end

      def armor_equipped?(armor_id)
        armor_id == @armor1_id || armor_id == @armor2_id ||
          armor_id == @armor3_id || armor_id == @armor4_id
      end

      # -- mutators (the Change Actor event commands) -------------------------

      # Add `delta` to current HP, clamped to [floor, max HP]. `allow_death` (the
      # command's "allow knockout" flag) lets HP reach 0; otherwise the floor is 1.
      def change_hp(delta, allow_death = false)
        @hp = clamp(@hp + delta, allow_death ? 0 : 1, max_hp)
      end

      # Add `delta` to current SP, clamped to [0, max SP].
      def change_sp(delta); @sp = clamp(@sp + delta, 0, max_sp); end

      # Fully restore HP and SP (RMXP Recover All also clears states, which are
      # not modelled yet).
      def recover_all
        @hp = max_hp
        @sp = max_sp
      end

      # Add `delta` to total EXP (Change EXP), re-deriving the level.
      def gain_exp(delta); self.exp = @exp + delta; end

      # Move the level by `delta` (Change Level); routed through the level setter.
      def change_level(delta); self.level = @level + delta; end

      # Set the total EXP (clamped to RMXP's 0..9,999,999) and re-derive the level
      # from the exp curve: climb while the next level's threshold is met (learning
      # the skills the class teaches at each level reached), then drop while below
      # the current level's threshold (skills are kept on the way down). Current
      # HP/SP are re-clamped to the new maxima. Mirrors RGSS's Game_Actor#exp=.
      def exp=(value)
        @exp = clamp(value, 0, 9_999_999)
        while @level < 100 && @exp_list[@level + 1] && @exp_list[@level + 1] > 0 &&
              @exp >= @exp_list[@level + 1]
          @level += 1
          learn_level_skills(@level)
        end
        while @level > 1 && @exp < (@exp_list[@level] || 0)
          @level -= 1
        end
        @hp = max_hp if @hp > max_hp
        @sp = max_sp if @sp > max_sp
      end

      # Set the level (Change Level), clamped to 1..final_level: RMXP realigns EXP
      # to that level's threshold, which re-derives the level and learns any skills
      # reached along the way. Mirrors RGSS's Game_Actor#level=.
      def level=(level)
        level = clamp(level, 1, @record.final_level || 99)
        self.exp = @exp_list[level] || 0
      end

      def learn_skill(skill_id)
        return if skill_id.nil? || skill_id == 0 || @skills.include?(skill_id)
        @skills.push(skill_id)
      end

      def forget_skill(skill_id); @skills.delete(skill_id); end

      # Equip an item into a slot: 0 weapon, 1..4 the four armor slots. An id of 0
      # empties the slot. Other slot numbers are ignored.
      def equip(slot, item_id)
        case slot
        when 0 then @weapon_id = item_id
        when 1 then @armor1_id = item_id
        when 2 then @armor2_id = item_id
        when 3 then @armor3_id = item_id
        when 4 then @armor4_id = item_id
        end
      end

      # Change Actor Graphic (322): the walking charset and the battler, each
      # with its hue. Mirrors RGSS's Game_Actor#set_graphic, which likewise
      # writes all four in one go -- the command always carries all four, and an
      # empty name is a real value (the actor becomes invisible on the map).
      def set_graphic(character_name, character_hue, battler_name, battler_hue)
        @character_name = character_name
        @character_hue = character_hue
        @battler_name = battler_name
        @battler_hue = battler_hue
      end

      # -- save round-trip ----------------------------------------------------

      # The mutable state to persist (the fields the Change Actor commands touch);
      # everything else is re-derived from the database on load.
      def to_h
        { level: @level, exp: @exp, hp: @hp, sp: @sp, skills: @skills.dup,
          weapon_id: @weapon_id, armor1_id: @armor1_id, armor2_id: @armor2_id,
          armor3_id: @armor3_id, armor4_id: @armor4_id,
          character_name: @character_name, character_hue: @character_hue,
          battler_name: @battler_name, battler_hue: @battler_hue }
      end

      # Restore mutable state from #to_h (missing keys keep the database defaults).
      # Level and EXP are restored verbatim (not re-derived), so an exact saved
      # state comes back exactly.
      def load_h(h)
        return self unless h
        @level = h[:level] if h[:level]
        @exp = h[:exp] if h[:exp]
        @skills = h[:skills].dup if h[:skills]
        @weapon_id = h[:weapon_id] if h.key?(:weapon_id)
        @armor1_id = h[:armor1_id] if h.key?(:armor1_id)
        @armor2_id = h[:armor2_id] if h.key?(:armor2_id)
        @armor3_id = h[:armor3_id] if h.key?(:armor3_id)
        @armor4_id = h[:armor4_id] if h.key?(:armor4_id)
        @hp = h[:hp] if h[:hp]
        @sp = h[:sp] if h[:sp]
        @character_name = h[:character_name] if h.key?(:character_name)
        @character_hue = h[:character_hue] if h.key?(:character_hue)
        @battler_name = h[:battler_name] if h.key?(:battler_name)
        @battler_hue = h[:battler_hue] if h.key?(:battler_hue)
        self
      end

      private

      def clamp(v, lo, hi); v < lo ? lo : (v > hi ? hi : v); end

      # Build @exp_list: the total EXP required to *be at* each level 1..100.
      # Level 1 is 0; each further level (up to final_level) adds
      # `Integer(exp_basis * (level + 3)**pow / 5**pow)`, `pow = 2.4 +
      # exp_inflation / 100`. Levels past final_level are 0 (unreachable). A direct
      # port of RGSS's Game_Actor#make_exp_list.
      def make_exp_list
        final = @record.final_level || 99
        basis = @record.exp_basis || 0
        inflation = @record.exp_inflation || 0
        pow = 2.4 + inflation / 100.0
        denom = 5.0 ** pow
        @exp_list = Array.new(101, 0)
        i = 2
        while i <= 100
          if i > final
            @exp_list[i] = 0
          else
            n = basis * ((i + 3).to_f ** pow) / denom
            @exp_list[i] = @exp_list[i - 1] + n.to_i
          end
          i += 1
        end
      end

      # Learn every skill the class teaches exactly at `level` (called for each
      # level gained), matching RGSS's per-level learning on the way up.
      def learn_level_skills(level)
        learnings = @class && @class.learnings
        (learnings || []).each { |l| learn_skill(l.skill_id) if l.level == level }
      end

      # The skill ids the class has taught by `level` (every learning at or below
      # it). RMXP seeds an actor's known skills this way at its starting level.
      def learnable_skills(level)
        out = []
        learnings = @class && @class.learnings
        (learnings || []).each do |l|
          out.push(l.skill_id) if l.skill_id && l.level && l.level <= level
        end
        out
      end
    end

    # Digit-entry model for the Input Number (103) command: a fixed number of
    # decimal digits with a cursor. Up/down change the digit under the cursor
    # (wrapping 0..9), left/right move the cursor (clamped). `value` reads the
    # whole number back. Pure logic so the scene's number widget is unit-testable
    # without a display.
    class NumberInput
      MAX_DIGITS = 8

      attr_reader :digits, :cursor

      def initialize(digits)
        d = digits.to_i
        d = 1 if d < 1
        d = MAX_DIGITS if d > MAX_DIGITS
        @digits = d
        @values = Array.new(d, 0)
        @cursor = 0
      end

      # The digit shown at position i (0 = most significant, leftmost).
      def digit(i)
        @values[i] || 0
      end

      def inc
        @values[@cursor] = (@values[@cursor] + 1) % 10
      end

      def dec
        @values[@cursor] = (@values[@cursor] + 9) % 10
      end

      def left
        @cursor -= 1 if @cursor > 0
      end

      def right
        @cursor += 1 if @cursor < @digits - 1
      end

      def value
        v = 0
        @values.each { |d| v = v * 10 + d }
        v
      end
    end

    # The two RMXP globals a game's inline Ruby (Script, command 355) is most
    # likely to reach for, backed by this runtime's State.
    #
    # RMXP's `$game_switches` and `$game_variables` are whole classes; all a
    # script ever uses of them is `[]` and `[]=`, which is all these expose. They
    # are how a Script command talks to the same switches and variables the
    # Control Switches / Control Variables commands write, instead of to a
    # parallel set of its own.
    class SwitchStore
      def initialize(state)
        @state = state
      end

      def [](id); @state.switches[id]; end

      def []=(id, value)
        @state.switches[id] = value ? true : false
      end
    end

    class VariableStore
      def initialize(state)
        @state = state
      end

      def [](id); @state.variables[id]; end

      def []=(id, value)
        @state.variables[id] = value.to_i
      end
    end

    # Playback state for one Show Animation (207): which frame of an
    # `RPG::Animation` is on screen and what its cells say to draw. Pure logic —
    # the scene turns each cell into a sprite.
    #
    # RMXP's `Sprite_Base` runs an animation for `frame_max * 4 + 1` game frames
    # and reads the frame back out of that countdown, so every animation frame is
    # held for four game frames. A frame's `cell_data` is a Table of up to
    # sixteen cells by eight columns: the sheet pattern, x and y offsets from the
    # anchor, zoom in percent, angle, a mirror flag, opacity and blend type. A
    # pattern of -1 (or a missing row) means that cell draws nothing.
    class Animation
      CELLS = 16          # RMXP allocates exactly sixteen cell sprites
      CELL_SIZE = 192     # each cell is a 192x192 square of the sheet
      SHEET_COLUMNS = 5   # ... laid out five to a row
      FRAME_TICKS = 4     # game frames per animation frame
      NO_CELL = -1

      # RPG::Animation#position: over the target's head, on it, at its feet, or
      # fixed to the screen.
      POSITION_TOP = 0
      POSITION_MIDDLE = 1
      POSITION_BOTTOM = 2
      POSITION_SCREEN = 3

      # Timing#flash_scope: none, the target, the whole screen, or hide target.
      FLASH_NONE = 0
      FLASH_TARGET = 1
      FLASH_SCREEN = 2

      def initialize(record)
        @record = record
        @duration = record.frame_max.to_i * FRAME_TICKS + 1
      end

      attr_reader :record

      def playing?; @duration > 0; end
      def position; @record.position.to_i; end
      def sheet_name; @record.animation_name; end
      def sheet_hue; @record.animation_hue.to_i; end

      # The animation frame to draw this tick, or nil once it is over.
      #
      # The countdown is one longer than the frames need, and RMXP's own formula
      # yields -1 on that leading tick — so it reads `frames[-1]`, the *last*
      # frame, for one game frame before the animation starts. That is a bug in
      # the original, visible as a flash of the end of the animation; clamping to
      # the first frame holds it for five ticks instead.
      def frame_index
        return nil unless playing?
        i = @record.frame_max.to_i - (@duration + FRAME_TICKS - 1) / FRAME_TICKS
        i < 0 ? 0 : i
      end

      # One tick. Call after drawing the current frame, as RMXP does.
      def update
        @duration -= 1
      end

      # The drawable cells of `index` as [pattern, x, y, zoom, angle, mirror,
      # opacity, blend] rows, skipping the blank ones.
      def cells(index)
        frame = index && @record.frames && @record.frames[index]
        return [] unless frame
        data = frame.cell_data
        return [] unless data
        count = frame.cell_max.to_i
        count = CELLS if count > CELLS
        out = []
        i = 0
        while i < count
          pattern = data[i, 0]
          out << [pattern, data[i, 1], data[i, 2], data[i, 3], data[i, 4],
                  data[i, 5], data[i, 6], data[i, 7]] if pattern && pattern != NO_CELL
          i += 1
        end
        out
      end

      # The source rect of a cell pattern on the sheet, as [x, y, w, h].
      def self.cell_rect(pattern)
        [pattern % SHEET_COLUMNS * CELL_SIZE, pattern / SHEET_COLUMNS * CELL_SIZE,
         CELL_SIZE, CELL_SIZE]
      end

      # The timings that fire on `index` (sound effects and flashes).
      def timings_at(index)
        return [] if index.nil? || @record.timings.nil?
        @record.timings.select { |t| t.frame.to_i == index }
      end
    end

    # Scroll Map (203): the camera pushed off the party leader for a cutscene.
    #
    # RMXP has no separate notion here — `$game_map.display_x/y` *is* the camera,
    # and Game_Player scrolls it as the hero walks — but ours derives the camera
    # from the leader every frame, so a commanded scroll is carried as an offset
    # on top of that. It persists until another scroll moves it (which is how
    # games use it: scroll out, play the scene, scroll back), and the scene
    # clamps the result to the map the same way the follow camera is clamped.
    class Scroll
      # Distance is in tiles; RMXP moves 2**speed pixels a frame.
      attr_reader :x, :y

      def initialize
        @x = 0
        @y = 0
        @rest = 0
        @step_x = 0
        @step_y = 0
      end

      def scrolling?; @rest > 0; end

      # `direction` is an RPG direction (2 down, 4 left, 6 right, 8 up).
      def start(direction, distance, speed, tile)
        step = 1 << speed.to_i
        step = 1 if step < 1
        @rest = distance.to_i * tile
        dx, dy = Character::DIR_DELTA[direction.to_i] || [0, 0]
        @step_x = dx * step
        @step_y = dy * step
        @rest = 0 if dx.zero? && dy.zero?
      end

      def update
        return if @rest <= 0
        # The last frame moves only what is left, so the scroll lands on a whole
        # number of tiles however the speed divides it.
        move = @step_x.abs + @step_y.abs
        move = @rest if move > @rest
        @x += @step_x.zero? ? 0 : (@step_x > 0 ? move : -move)
        @y += @step_y.zero? ? 0 : (@step_y > 0 ? move : -move)
        @rest -= move
      end
    end

    # The screen-wide effects of RMXP's `Game_Screen` that are not the tone:
    # Screen Flash (224) and Screen Shake (225). Pure data plus RMXP's own
    # per-frame maths, so the scene only has to hand the results to a viewport
    # (`color` for the flash, `ox` for the shake).
    class Screen
      # Flash colour as [red, green, blue, alpha]; alpha decays to zero over the
      # flash's duration. Shake is a signed pixel offset.
      attr_reader :flash_color, :shake

      def initialize
        @flash_color = [0.0, 0.0, 0.0, 0.0]
        @flash_duration = 0
        @shake = 0.0
        @shake_power = 0
        @shake_speed = 0
        @shake_duration = 0
        @shake_direction = 1
      end

      def flashing?; @flash_duration >= 1 || @flash_color[3] > 0; end
      def shaking?;  @shake_duration >= 1 || @shake != 0; end

      # Screen Flash (224): `color` is [r, g, b, a], `duration` in frames.
      def start_flash(color, duration)
        @flash_color = [color[0], color[1], color[2], color[3]]
        @flash_duration = duration.to_i
        return if @flash_duration >= 1
        @flash_color[3] = 0.0
      end

      # Screen Shake (225): power and speed 1..9, duration in frames.
      def start_shake(power, speed, duration)
        @shake_power = power.to_i
        @shake_speed = speed.to_i
        @shake_duration = duration.to_i
      end

      def update
        step_flash
        step_shake
      end

      private

      # RMXP fades the flash by scaling its alpha by (d - 1) / d each frame, so
      # it reaches zero exactly as the duration runs out.
      def step_flash
        return if @flash_duration < 1
        d = @flash_duration
        @flash_color[3] = @flash_color[3] * (d - 1) / d
        @flash_duration = d - 1
      end

      # RMXP's shake is a spring: the offset moves by power*speed/10 a frame and
      # reverses whenever it passes twice the power, and on the last frame it
      # snaps to zero rather than being left off-centre (the `@shake * (@shake +
      # delta) < 0` test — the step that would cross the middle).
      def step_shake
        return if @shake_duration < 1 && @shake == 0
        delta = (@shake_power * @shake_speed * @shake_direction) / 10.0
        if @shake_duration <= 1 && @shake * (@shake + delta) < 0
          @shake = 0.0
        else
          @shake += delta
        end
        @shake_direction = -1 if @shake > @shake_power * 2
        @shake_direction = 1 if @shake < -@shake_power * 2
        @shake_duration -= 1 if @shake_duration >= 1
      end
    end

    # One slot of RMXP's `$game_screen.pictures`: what Show Picture (231) put on
    # screen, and where a Move Picture (232) / Rotate Picture (233) / Change
    # Picture Tone (234) is taking it. Pure data plus the per-frame easing, the
    # way `Game_Picture` is; the map scene turns each one into a Sprite.
    #
    # The eases are RMXP's own weighted average -- `v = (v * (d - 1) + target) /
    # d` with d counting down -- which lands exactly on the target on the last
    # frame without accumulating error.
    #
    # `tone` is kept as the four numbers rather than an RGSS::Tone so this class
    # stays loadable under CRuby (scripts/rpgxp_testbed_check.rb drives the same
    # sources with only a Marshal shim for the value types); the scene builds the
    # Tone.
    class Picture
      attr_reader :number, :name, :origin, :x, :y, :zoom_x, :zoom_y, :opacity,
                  :blend_type, :angle, :tone

      def initialize(number)
        @number = number
        erase
      end

      # RMXP's Game_Picture#initialize defaults, which `erase` returns to.
      def erase
        @name = ""
        @origin = 0
        @x = 0.0
        @y = 0.0
        @zoom_x = 100.0
        @zoom_y = 100.0
        @opacity = 255.0
        @blend_type = 1 # RMXP's default for a picture is 1, not 0
        @duration = 0
        @target_x = 0.0
        @target_y = 0.0
        @target_zoom_x = 100.0
        @target_zoom_y = 100.0
        @target_opacity = 255.0
        @tone = [0.0, 0.0, 0.0, 0.0]
        @tone_target = [0.0, 0.0, 0.0, 0.0]
        @tone_duration = 0
        @angle = 0.0
        @rotate_speed = 0
      end

      # Whether anything should be drawn for this slot.
      def shown?; !@name.nil? && !@name.empty?; end

      def show(name, origin, x, y, zoom_x, zoom_y, opacity, blend_type)
        @name = name.to_s
        @origin = origin.to_i
        @x = x.to_f
        @y = y.to_f
        @zoom_x = zoom_x.to_f
        @zoom_y = zoom_y.to_f
        @opacity = opacity.to_f
        @blend_type = blend_type.to_i
        @duration = 0
        @target_x = @x
        @target_y = @y
        @target_zoom_x = @zoom_x
        @target_zoom_y = @zoom_y
        @target_opacity = @opacity
        @tone = [0.0, 0.0, 0.0, 0.0]
        @tone_target = [0.0, 0.0, 0.0, 0.0]
        @tone_duration = 0
        @angle = 0.0
        @rotate_speed = 0
      end

      def move(duration, origin, x, y, zoom_x, zoom_y, opacity, blend_type)
        @origin = origin.to_i
        @blend_type = blend_type.to_i
        @target_x = x.to_f
        @target_y = y.to_f
        @target_zoom_x = zoom_x.to_f
        @target_zoom_y = zoom_y.to_f
        @target_opacity = opacity.to_f
        @duration = duration.to_i
        return unless @duration <= 0
        # A zero-frame move is a snap, not a no-op.
        @x = @target_x
        @y = @target_y
        @zoom_x = @target_zoom_x
        @zoom_y = @target_zoom_y
        @opacity = @target_opacity
      end

      # Rotate Picture (233): degrees per two frames, signed. 0 stops it.
      def rotate(speed)
        @rotate_speed = speed.to_i
      end

      # Change Picture Tone (234). `tone` is [red, green, blue, gray].
      def start_tone_change(tone, duration)
        @tone_target = tone
        @tone_duration = duration.to_i
        return if @tone_duration > 0
        @tone = [tone[0], tone[1], tone[2], tone[3]]
      end

      def update
        step_move
        step_tone
        step_rotation
      end

      private

      def step_move
        return if @duration < 1
        d = @duration
        @x = (@x * (d - 1) + @target_x) / d
        @y = (@y * (d - 1) + @target_y) / d
        @zoom_x = (@zoom_x * (d - 1) + @target_zoom_x) / d
        @zoom_y = (@zoom_y * (d - 1) + @target_zoom_y) / d
        @opacity = (@opacity * (d - 1) + @target_opacity) / d
        @duration = d - 1
      end

      def step_tone
        return if @tone_duration < 1
        d = @tone_duration
        i = 0
        while i < 4
          @tone[i] = (@tone[i] * (d - 1) + @tone_target[i]) / d
          i += 1
        end
        @tone_duration = d - 1
      end

      def step_rotation
        return if @rotate_speed == 0
        @angle += @rotate_speed / 2.0
        @angle += 360.0 while @angle < 0
        @angle -= 360.0 while @angle >= 360.0
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
    #
    # A character's *tile* is where it is going: taking a step moves (x, y) at
    # once and leaves the drawn position, (real_x, real_y), to catch up a little
    # every frame -- which is how RGSS models it, and why an event occupies its
    # destination for collision the instant it sets off.
    class Character
      DIR_DELTA = { 2 => [0, 1], 4 => [-1, 0], 6 => [1, 0], 8 => [0, -1] }.freeze
      # Sub-tile units RGSS counts a position in: real_x == x * UNIT means the
      # character has arrived. A step covers UNIT units at 2**move_speed a
      # frame, so speed 4 (the editor's default) crosses a tile in 8 frames.
      UNIT = 128
      # 90-degree clockwise / counter-clockwise turns and the 180-degree flip.
      TURN_RIGHT = { 8 => 6, 6 => 2, 2 => 4, 4 => 8 }.freeze
      TURN_LEFT  = { 8 => 4, 4 => 2, 2 => 6, 6 => 8 }.freeze
      TURN_180   = { 8 => 2, 2 => 8, 4 => 6, 6 => 4 }.freeze
      CARDINALS = [2, 4, 6, 8].freeze

      attr_accessor :direction, :move_speed, :move_frequency,
                    :through, :direction_fix, :walk_anime, :step_anime,
                    :always_on_top, :opacity, :blend_type
      attr_reader :x, :y, :graphic_name, :graphic_hue, :pattern,
                  :real_x, :real_y, :stop_count

      # Assigning a tile directly is a placement (a spawn or a teleport), not a
      # step: the drawn position goes with it instead of gliding across the map.
      def x=(v)
        @x = v
        @real_x = v * UNIT
      end

      def y=(v)
        @y = v
        @real_y = v * UNIT
      end

      def initialize(x = 0, y = 0, direction = 2)
        @x = x
        @y = y
        @real_x = x * UNIT
        @real_y = y * UNIT
        @anime_count = 0
        @stop_count = 0
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
        @original_pattern = 0
      end

      def set_graphic(name, hue = 0, direction = nil, pattern = nil)
        @graphic_name = name
        @graphic_hue = hue || 0
        face(direction) if direction && direction > 0
        @pattern = pattern if pattern
        @original_pattern = @pattern
      end

      # Still short of the tile it is walking to.
      def moving?
        @real_x != @x * UNIT || @real_y != @y * UNIT
      end

      # The drawn position, in pixels, for a `tile`-pixel grid.
      def pixel_x(tile)
        @real_x * tile / UNIT
      end

      def pixel_y(tile)
        @real_y * tile / UNIT
      end

      # One frame of this character: close the gap to the tile it stepped onto,
      # and run the walk cycle. RMXP's Game_Character#update -- the walk row
      # advances every `18 - move_speed * 2` animation ticks, counted at 1.5 a
      # frame while walking and 1 a frame for a page that animates on the spot,
      # and a character that has come to rest falls back to its page's own
      # frame.
      def update
        moving? ? update_move : update_stop
        return if @anime_count <= 18 - @move_speed * 2
        @pattern = if !@step_anime && @stop_count > 0
                     @original_pattern || 0
                   else
                     (@pattern + 1) % 4
                   end
        @anime_count = 0
      end

      def update_move
        d = 2**@move_speed
        @real_x = approach(@real_x, @x * UNIT, d)
        @real_y = approach(@real_y, @y * UNIT, d)
        if @walk_anime
          @anime_count += 1.5
        elsif @step_anime
          @anime_count += 1
        end
      end

      def update_stop
        if @step_anime
          @anime_count += 1
        elsif @pattern != (@original_pattern || 0)
          @anime_count += 1.5
        end
        @stop_count += 1
      end

      # Start the wait before this character's next autonomous step over again,
      # as taking a step does.
      def hold_still
        @stop_count = 0
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
        @stop_count = 0
      end

      # Move one tile diagonally; RMXP keeps a cardinal facing, favouring the
      # vertical part unless already facing one of the two component directions.
      def move_diagonal(horizontal, vertical)
        face(vertical) unless @direction == horizontal || @direction == vertical
        hx, = DIR_DELTA[horizontal] || [0, 0]
        _, vy = DIR_DELTA[vertical] || [0, 0]
        @x += hx
        @y += vy
        @stop_count = 0
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

      private

      # Step `pos` toward `goal` by at most `d`, never overshooting it.
      def approach(pos, goal, d)
        return [pos + d, goal].min if pos < goal
        return [pos - d, goal].max if pos > goal
        pos
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
