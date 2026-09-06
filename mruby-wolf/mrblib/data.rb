# The WOLF RPG Editor project files, one class per file, on top of the readers
# in wolf.rb. Each `parse` takes the whole file's bytes (so the same code runs
# over a loose Data/ tree, a CRuby host check, or a future .wolf archive) and
# builds plain attribute holders; nothing here knows about rendering or the
# interpreter. Every layout note names the reader it was confirmed against.
module Wolf
  # ---------------------------------------------------------------------------
  # Game.dat -- the "ゲームの基本設定" dialog: tile size, screen size, FPS,
  # character sheet layout, fonts, title. The tail of the file (~29 KB of
  # editor-generated random numbers, see wolf-rpg-formats' game_dat.ksy) is
  # kept as an opaque blob.
  class GameDat
    MAGIC = Wolf.bin("W\0\0OL\0FM")
    # Byte of MAGIC (+ version byte) that carries the UTF-8 marker: the 9-byte
    # magic is followed by a version byte, 0x00 (v2) or 0x55 (v3+).
    SEEDS = [0, 8, 6]

    # Indices into the u8 settings block (kaitai record_u8_settings).
    U8_TILE_SIZE = 0
    U8_CHARA_DIRECTIONS_IMAGE = 1
    U8_CHARA_DIRECTIONS_MOVE = 2
    U8_FPS = 4
    U8_CHARA_SHADOW = 5
    U8_CHARA_ANIMATION_PATTERNS = 7
    U8_CHARA_MOVEMENT_WIDTH = 8
    U8_CHARA_MOVEMENT_HITBOX = 9
    U8_ANTI_ALIASING = 14
    U8_MOVE_SPEED_EVENT = 15
    U8_MOVE_SPEED_HERO = 16
    U8_LANGUAGE = 17
    U8_IMAGE_SCALING = 18
    U8_SYSTEM_LANGUAGE = 20

    # Indices into the u16 settings block (kaitai record_u16_settings).
    U16_SCREEN_WIDTH = 16
    U16_SCREEN_HEIGHT = 17
    U16_VERSION = 18

    attr_reader :utf8, :encrypted, :u8_settings, :strings, :u16_settings,
                :file_size, :tail

    def self.parse(data)
      new(data)
    end

    def initialize(data)
      r, @encrypted = Wolf.open_envelope(data, SEEDS, "Game.dat")
      if @encrypted
        @utf8 = false
      else
        Wolf.read_magic(r, MAGIC, 0, "Game.dat")
        version = r.u8
        @utf8 = version == UTF8_MARK
        r.utf8 = @utf8
      end
      @u8_settings = r.byte_array
      @strings = r.str_array
      unless @strings[1] == "0000-0000"
        raise Error, "Game.dat: magic string #{@strings[1].inspect} != \"0000-0000\""
      end
      @file_size = r.int
      @unknown = r.int
      n = r.int
      @u16_settings = []
      n.times { @u16_settings.push r.u16 }
      @tail = r.bytes(r.remaining)
    end

    def u8_setting(i); @u8_settings[i] || 0; end
    def u16_setting(i); @u16_settings[i] || 0; end

    def title; @strings[0] || ""; end
    def subtitle; @strings[8] || ""; end
    # The primary UI font and the three fallbacks, by family name.
    def font; @strings[3] || ""; end
    def sub_fonts; [@strings[4], @strings[5], @strings[6]].map { |s| s || "" }; end
    # The hero's character sheet when the project does not use the Basic
    # System (which supplies its own from the changeable database).
    def hero_graphic; @strings[7] || ""; end

    def tile_size; u8_setting(U8_TILE_SIZE); end
    def fps; u8_setting(U8_FPS); end
    # 4 or 8: how many facing rows a character sheet has.
    def character_directions; u8_setting(U8_CHARA_DIRECTIONS_IMAGE); end
    # 4 or 8: how many directions the hero may walk in.
    def move_directions; u8_setting(U8_CHARA_DIRECTIONS_MOVE); end
    # 3 or 5 animation frames per facing.
    def animation_patterns; u8_setting(U8_CHARA_ANIMATION_PATTERNS); end
    # 0: half-tile steps, 1: whole-tile steps.
    def half_step?; u8_setting(U8_CHARA_MOVEMENT_WIDTH) == 0; end
    def character_shadow?; u8_setting(U8_CHARA_SHADOW) != 0; end

    # The logical screen size, in pixels. 320x240 games are shown doubled by
    # the real runtime; every other size is 1:1.
    def screen_width; w = u16_setting(U16_SCREEN_WIDTH); w > 0 ? w : 320; end
    def screen_height; h = u16_setting(U16_SCREEN_HEIGHT); h > 0 ? h : 240; end
    def doubled?; screen_width == 320 && screen_height == 240; end
    # Editor version the file was last saved by, times 100 (370 == 3.70).
    def editor_version; u16_setting(U16_VERSION); end
  end

  # ---------------------------------------------------------------------------
  # MapTree.dat -- the map list's tree shape: for every map in display order,
  # its parent map id (-1 at the root) and its id. Map ids index the system
  # database's "マップ設定" type, which holds the .mps file name.
  class MapTree
    HEADER_SIZE = 10
    TERMINATOR = 0xBC

    Entry = Struct.new(:parent_id, :map_id)

    attr_reader :version, :entries

    def self.parse(data)
      new(data)
    end

    def initialize(data)
      r = Reader.new(data, true)
      r.bytes(HEADER_SIZE)
      @version = r.u8
      n = r.int
      raise Error, "MapTree.dat: bad entry count #{n}" if n < 0
      @entries = []
      n.times { @entries.push Entry.new(r.int, r.int) }
      r.expect_u8(TERMINATOR, "MapTree.dat terminator")
      raise Error, "MapTree.dat: #{r.remaining} bytes trail the tree" unless r.eof?
    end

    def map_ids; @entries.map(&:map_id); end
    def children_of(parent_id); @entries.select { |e| e.parent_id == parent_id }.map(&:map_id); end
  end

  # ---------------------------------------------------------------------------
  # TileSetData.dat -- the "タイルセット設定" dialog: per tileset, the base chip
  # sheet, the autotile sheets, and per base chip a tag number and a
  # passability/priority bit set.
  class TileFlags
    NOT_DOWN = 0x01
    NOT_LEFT = 0x02
    NOT_RIGHT = 0x04
    NOT_UP = 0x08
    # ★: drawn above every character.
    ABOVE_CHARACTERS = 0x10
    # □: a character standing on it has its lower half made translucent.
    HALF_TRANSLUCENT = 0x40
    # ▲: passable, hides a character standing behind (above) it.
    CONCEAL_BEHIND = 0x100
    # ↓: passability follows the layer below.
    MATCH_BELOW = 0x200
    # The editor's counter attribute lives above these.
    COUNTER = 0x80

    attr_reader :raw, :tag

    def initialize(raw, tag)
      @raw = raw
      @tag = tag
    end

    def blocked_down?; (@raw & NOT_DOWN) != 0; end
    def blocked_left?; (@raw & NOT_LEFT) != 0; end
    def blocked_right?; (@raw & NOT_RIGHT) != 0; end
    def blocked_up?; (@raw & NOT_UP) != 0; end
    # × in the editor: blocked from every side.
    def impassable?; (@raw & 0x0f) == 0x0f; end
    def passable?; (@raw & 0x0f) == 0; end
    def above_characters?; (@raw & ABOVE_CHARACTERS) != 0; end
    def half_translucent?; (@raw & HALF_TRANSLUCENT) != 0; end
    def conceal_behind?; (@raw & CONCEAL_BEHIND) != 0; end
    def match_below?; (@raw & MATCH_BELOW) != 0; end
    def counter?; (@raw & COUNTER) != 0; end
  end

  class Tileset
    # Autotile slots: 15 in a v2 file (two rows of the palette minus the blank
    # first cell), 31 in a v3 one (four rows). The list has no count of its
    # own -- it runs up to the 0xFF byte that opens the tag table -- so it is
    # read until that byte. A string length prefix cannot start with 0xFF
    # (that would be a 255+ byte file name, which the editor's own dialog does
    # not allow), so the sentinel is unambiguous in practice.
    SEPARATOR = 0xFF

    attr_reader :index, :name, :base_file, :autotile_files, :flags

    def initialize(r, index)
      @index = index
      @name = r.str
      @base_file = r.str
      @autotile_files = []
      @autotile_files.push r.str while r.peek_u8 != SEPARATOR
      r.expect_u8(SEPARATOR, "TileSetData.dat tileset #{index} tag table")
      tags = r.byte_array
      r.expect_u8(SEPARATOR, "TileSetData.dat tileset #{index} flag table")
      n = r.int
      unless n == tags.size
        raise Error, "TileSetData.dat: tileset #{index} has #{tags.size} tags but #{n} flag words"
      end
      @flags = []
      n.times { |i| @flags.push TileFlags.new(r.uint, tags[i]) }
    end

    # The number of base chips the tileset knows flags for (8 per sheet row).
    def chip_count; @flags.size; end
    def flags_for(chip_id); @flags[chip_id]; end
    def autotile_count; @autotile_files.size; end
  end

  class TileSetData
    MAGIC = Wolf.bin("W\0\0OL\0FM\0")
    UTF8_INDEX = 5
    TERMINATOR = 0xCF

    attr_reader :utf8, :version, :tilesets

    def self.parse(data)
      new(data)
    end

    def initialize(data)
      r, _enc = Wolf.open_envelope(data, nil, "TileSetData.dat")
      @utf8 = Wolf.read_magic(r, MAGIC, UTF8_INDEX, "TileSetData.dat")
      @version = r.u8
      n = r.int
      raise Error, "TileSetData.dat: bad tileset count #{n}" if n < 0
      @tilesets = []
      n.times { |i| @tilesets.push Tileset.new(r, i) }
      r.expect_u8(TERMINATOR, "TileSetData.dat terminator")
      raise Error, "TileSetData.dat: #{r.remaining} bytes trail the data" unless r.eof?
    end

    def [](i); @tilesets[i]; end
    def size; @tilesets.size; end
  end

  # ---------------------------------------------------------------------------
  # The three databases (DataBase = user DB, CDataBase = changeable DB,
  # SysDatabase = system DB), each a `.project` (schema: type names, field
  # names, data names, field kinds) plus a `.dat` (the values). Field values
  # are numbers or strings; the .dat stores each datum's numbers then its
  # strings, in the order the property_position table maps them.
  class DBField
    # `kind` (the project's per-field type byte): 0 number, 1 file name,
    # 2 database reference, 3 manual options; `special` carries the
    # reference/option strings and values.
    attr_reader :index, :name, :kind, :special_strings, :special_values, :default

    def initialize(index, name)
      @index = index
      @name = name
      @kind = 0
      @special_strings = []
      @special_values = []
      @default = 0
    end

    attr_writer :kind, :special_strings, :special_values, :default

    # Where the field's value lives in a datum: [:number, i] or [:string, i].
    # Set while reading the .dat (positions are stored there, not in the
    # project).
    attr_accessor :slot

    def string?; @slot && @slot[0] == :string; end
    def number?; !string?; end
  end

  class DBDatum
    attr_reader :index, :name, :numbers, :strings

    def initialize(index, name)
      @index = index
      @name = name
      @numbers = []
      @strings = []
    end

    attr_writer :numbers, :strings

    # The value of `field` (a DBField) in this datum.
    def [](field)
      slot = field.slot
      return nil unless slot
      slot[0] == :string ? @strings[slot[1]] : @numbers[slot[1]]
    end
  end

  class DBType
    TYPE_SEPARATOR = Wolf.bin("\xFE\xFF\xFF\xFF")
    # Property position words: block * 1000 + index, block 1 = number, 2 =
    # string (wolf-rpg-formats database_dat.ksy).
    NUMBER_BLOCK = 1
    STRING_BLOCK = 2

    attr_reader :index, :name, :fields, :data, :memo, :data_id_method

    # Reads the schema half from the .project reader.
    def initialize(r, index)
      @index = index
      @name = r.str
      nf = r.int
      raise Error, "#{@name}: bad field count #{nf}" if nf < 0
      @fields = []
      nf.times { |i| @fields.push DBField.new(i, r.str) }
      nd = r.int
      raise Error, "#{@name}: bad data count #{nd}" if nd < 0
      @data = []
      nd.times { |i| @data.push DBDatum.new(i, r.str) }
      @memo = r.str
      # Field kinds: a fixed-size (100) byte table, one per field slot.
      kinds = r.byte_array
      @fields.each { |f| f.kind = kinds[f.index] || 0 }
      # Per-field string tables (three sections, each its own count), then the
      # default values. The counts equal the field count in every file seen.
      n = r.int
      n.times { |i| f = @fields[i]; s = r.str; f.special_strings = [s] if f }
      n = r.int
      n.times { |i| f = @fields[i]; a = r.str_array; f.special_strings = a if f }
      n = r.int
      n.times { |i| f = @fields[i]; a = r.int_array; f.special_values = a if f }
      n = r.int
      n.times { |i| f = @fields[i]; v = r.int; f.default = v if f }
    end

    # Reads the value half from the .dat reader.
    def read_dat(r)
      r.expect_bytes(TYPE_SEPARATOR, "#{@name}: type separator")
      @data_id_method = r.int
      nf = r.int
      if nf != @fields.size
        # The .dat is authoritative about how many properties a datum carries;
        # a project with more names than that stores no value for the extras.
        @fields = @fields[0, nf] if nf < @fields.size
        (@fields.size...nf).each { |i| @fields.push DBField.new(i, "") }
      end
      numbers = 0
      strings = 0
      @fields.each do |f|
        raw = r.int
        block = raw / 1000
        idx = raw % 1000
        case block
        when NUMBER_BLOCK
          f.slot = [:number, idx]
          numbers += 1
        when STRING_BLOCK
          f.slot = [:string, idx]
          strings += 1
        else
          raise Error, "#{@name}: field #{f.index} has property position #{raw}"
        end
      end
      nd = r.int
      if nd != @data.size
        @data = @data[0, nd] if nd < @data.size
        (@data.size...nd).each { |i| @data.push DBDatum.new(i, "") }
      end
      @data.each do |d|
        nums = []
        numbers.times { nums.push r.int }
        strs = []
        strings.times { strs.push r.str }
        d.numbers = nums
        d.strings = strs
      end
    end

    def field(i); @fields[i]; end
    def field_named(name); @fields.find { |f| f.name == name }; end
    def datum(i); @data[i]; end
    # Value of field `fi` in datum `di`, nil when either is out of range.
    def value(di, fi)
      d = @data[di]
      f = @fields[fi]
      d && f ? d[f] : nil
    end
  end

  class Database
    MAGIC = Wolf.bin("W\0\0OL\0FM\0")
    UTF8_INDEX = 5
    SEEDS = [0, 3, 9]
    # The version byte after the magic doubles as the footer. 0xC4 marks a
    # 3.5+ file whose body is LZ4-packed.
    PACKED_VERSION = 0xC4

    attr_reader :utf8, :encrypted, :version, :types

    # `project_data` is the .project file's bytes, `dat_data` the .dat's.
    def self.parse(project_data, dat_data, name = "DataBase")
      new(project_data, dat_data, name)
    end

    def initialize(project_data, dat_data, name)
      r, @encrypted = Wolf.open_envelope(dat_data, SEEDS, "#{name}.dat")
      if @encrypted
        @utf8 = false
        # An encrypted v2 .dat carries one extra byte where the version sits.
        @version = r.u8
      else
        @utf8 = Wolf.read_magic(r, MAGIC, UTF8_INDEX, "#{name}.dat")
        @version = r.u8
        r = Wolf.unpack_body(r, "#{name}.dat") if @version == PACKED_VERSION
      end

      pr = Reader.new(project_data, @utf8)
      nt = pr.int
      raise Error, "#{name}.project: bad type count #{nt}" if nt < 0
      @types = []
      nt.times { |i| @types.push DBType.new(pr, i) }
      raise Error, "#{name}.project: #{pr.remaining} bytes trail the schema" unless pr.eof?

      n = r.int
      if n != @types.size
        raise Error, "#{name}: project has #{@types.size} types, dat has #{n}"
      end
      @types.each { |t| t.read_dat(r) }
      r.expect_u8(@version, "#{name}.dat footer")
      raise Error, "#{name}.dat: #{r.remaining} bytes trail the data" unless r.eof?
    end

    def [](i); @types[i]; end
    def size; @types.size; end
    def type_named(name); @types.find { |t| t.name == name }; end
  end

  # ---------------------------------------------------------------------------
  # Event commands, shared by map events and common events. One command is:
  # a parameter count byte (arguments + 1), the command id, the integer
  # arguments, an indent byte, the string arguments, and a terminator that is
  # 1 when a move route follows (the "動作指定" command). 3.5+ files add a
  # length-prefixed byte array after every command.
  class RouteCommand
    TERMINATOR = Wolf.bin("\x01\x00")

    attr_reader :id, :args

    def initialize(id, args)
      @id = id
      @args = args
    end

    def self.read(r)
      id = r.u8
      n = r.u8
      args = []
      n.times { args.push r.int }
      r.expect_bytes(TERMINATOR, "move command terminator")
      new(id, args)
    end
  end

  class Command
    attr_reader :code, :args, :strings, :indent, :route, :route_flags, :extra

    def initialize(code, args, strings, indent)
      @code = code
      @args = args
      @strings = strings
      @indent = indent
      @route = nil
      @route_flags = nil
      @extra = nil
    end

    attr_writer :route, :route_flags, :extra

    def arg(i); @args[i] || 0; end
    def string(i); @strings[i] || ""; end
    def route?; !@route.nil?; end

    # `v35`: whether the file is the 3.5+ layout (trailing byte array).
    def self.read(r, v35)
      n = r.u8 - 1
      raise Error, "command with #{n} arguments at #{r.pos - 1}" if n < 0
      code = r.int
      args = []
      n.times { args.push r.int }
      indent = r.u8
      ns = r.u8
      strings = []
      ns.times { strings.push r.str }
      cmd = new(code, args, strings, indent)
      term = r.u8
      if term == 1
        # A move route: five bytes the readers agree are unknown, a flag byte
        # (repeat / skip-impossible / wait-until-done), then the commands.
        r.bytes(5)
        cmd.route_flags = r.u8
        cnt = r.int
        raise Error, "move route with #{cnt} commands" if cnt < 0
        route = []
        cnt.times { route.push RouteCommand.read(r) }
        cmd.route = route
      elsif term != 0
        raise Error, sprintf("command terminator 0x%02x at %d", term, r.pos - 1)
      end
      if v35
        en = r.u8
        cmd.extra = en > 0 ? r.bytes(en) : ""
      end
      cmd
    end
  end

  # ---------------------------------------------------------------------------
  # CommonEvent.dat -- the common events: the RPG Basic System lives here.
  class CommonEvent
    HEADER = 0x8E
    SEP_ARGS = 0x8F
    SEP_COLOR = 0x90
    SEP_END = 0x91
    SEP_RETURN = 0x92

    # Run conditions (kaitai run_condition).
    RUN_CALL_ONLY = 0
    RUN_AUTO = 1
    RUN_PARALLEL = 2
    RUN_PARALLEL_ALWAYS = 3

    attr_reader :index, :id, :run_condition, :condition_operator,
                :condition_variable, :condition_value, :number_arg_count,
                :string_arg_count, :name, :commands, :memo, :arg_names,
                :arg_specials, :arg_options, :arg_option_values, :arg_defaults,
                :color, :self_names, :return_name, :return_variable

    def initialize(r, index, v35)
      @index = index
      r.expect_u8(HEADER, "common event #{index} header")
      @id = r.int
      cond = r.u8
      @condition_operator = cond >> 4
      @run_condition = cond & 0x0f
      @condition_variable = r.int
      @condition_value = r.int
      @number_arg_count = r.u8
      @string_arg_count = r.u8
      @name = r.str
      n = r.int
      raise Error, "common event #{index}: bad command count #{n}" if n < 0
      @commands = []
      n.times { @commands.push Command.read(r, v35) }
      @unknown = r.str
      @memo = r.str
      r.expect_u8(SEP_ARGS, "common event #{index} argument block")
      @arg_names = r.str_array
      @arg_specials = r.byte_array
      n = r.int
      @arg_options = []
      n.times { @arg_options.push r.str_array }
      n = r.int
      @arg_option_values = []
      n.times { @arg_option_values.push r.int_array }
      @arg_defaults = r.int_array
      r.expect_u8(SEP_COLOR, "common event #{index} colour block")
      @color = r.int
      @self_names = []
      100.times { @self_names.push r.str }
      r.expect_u8(SEP_END, "common event #{index} trailer")
      @return_name = r.str
      @return_variable = nil
      sep = r.u8
      if sep == SEP_RETURN
        @return_name = r.str
        @return_variable = r.int
        r.expect_u8(SEP_RETURN, "common event #{index} return block")
      elsif sep != SEP_END
        raise Error, sprintf("common event %d: trailer byte 0x%02x", index, sep)
      end
    end

    def auto?; @run_condition == RUN_AUTO; end
    def parallel?; @run_condition == RUN_PARALLEL || @run_condition == RUN_PARALLEL_ALWAYS; end
  end

  class CommonEvents
    MAGIC = Wolf.bin("W\0\0OL\0FC\0")
    UTF8_INDEX = 5
    # Version bytes of a 3.5+ file (LZ4 body + per-command extras).
    PACKED_VERSIONS = [0x93, 0xCC]

    attr_reader :utf8, :version, :events, :v35

    def self.parse(data)
      new(data)
    end

    def initialize(data)
      r, enc = Wolf.open_envelope(data, nil, "CommonEvent.dat")
      raise Error, "CommonEvent.dat: encrypted common events are not supported" if enc
      @utf8 = Wolf.read_magic(r, MAGIC, UTF8_INDEX, "CommonEvent.dat")
      @version = r.u8
      @v35 = PACKED_VERSIONS.include?(@version)
      r = Wolf.unpack_body(r, "CommonEvent.dat") if @v35
      n = r.int
      raise Error, "CommonEvent.dat: bad event count #{n}" if n < 0
      @events = []
      n.times { |i| @events.push CommonEvent.new(r, i, @v35) }
      footer = r.u8
      raise Error, sprintf("CommonEvent.dat: footer 0x%02x", footer) if footer < 0x89
      raise Error, "CommonEvent.dat: #{r.remaining} bytes trail the events" unless r.eof?
    end

    def [](i); @events[i]; end
    def size; @events.size; end
    def named(name); @events.find { |e| e.name == name }; end
  end

  # ---------------------------------------------------------------------------
  # MapData/*.mps -- one map: its tileset id, size, tile layers and events.
  class Page
    START = 0x79
    END_MARK = 0x7A

    # Trigger kinds (the page's "起動条件").
    TRIGGER_CONFIRM = 0
    TRIGGER_AUTO = 1
    TRIGGER_PARALLEL = 2
    TRIGGER_PLAYER_TOUCH = 3
    TRIGGER_EVENT_TOUCH = 4

    # Movement kinds.
    MOVE_NONE = 0
    MOVE_CUSTOM = 1
    MOVE_RANDOM = 2
    MOVE_TOWARD_HERO = 3

    # Option bits.
    OPT_IDLE_ANIMATION = 0x01
    OPT_MOVE_ANIMATION = 0x02
    OPT_FIXED_DIRECTION = 0x04
    OPT_SLIP_THROUGH = 0x08
    OPT_ABOVE_HERO = 0x10
    OPT_SQUARE_HITBOX = 0x20
    OPT_HALF_STEP_UP = 0x40
    OPT_HALF_STEP_LEFT = 0x80

    Condition = Struct.new(:operator, :variable, :value) do
      # Condition byte: high nibble is the comparison operator (cross-checked
      # against the wolfrpg-map-parser crate's own independent `Condition`
      # struct -- `operator >> 4`, fed into a `CompareOperator` enum whose
      # 0-6 values match `Interpreter::OP_GT`.."OP_AND" byte-for-byte), low
      # bit 0 of the low nibble whether the condition is enabled.
      #
      # A disabled condition row still carries a real-looking `variable`
      # (the "変数呼び出し値" widget always stores *some* reference, even
      # unset -- empirically 1,000,000, decoding to map-event self-variable
      # 0 of event 0), so `variable`/`value` being non-zero must NOT be
      # treated as "enabled" too: confirmed against the sample game's own
      # events, where every untouched condition slot carries
      # `operator=0x20, variable=1_000_000, value=0` (bit 0 clear) and every
      # authored one carries bit 0 set (`operator=0x21`/`0x31`/...).
      def enabled?; (operator & 0x01) != 0; end
      def compare_operator; operator >> 4; end
    end

    attr_reader :index, :graphic, :direction, :frame, :opacity, :blend,
                :trigger, :conditions, :animation_speed, :move_speed,
                :move_frequency, :move_type, :options, :route_options, :route,
                :commands, :features, :shadow, :range_x, :range_y, :transfer

    def initialize(r, index, v35)
      @index = index
      @unknown = r.int
      @graphic = r.str
      # The direction byte is (row + 1) * 2 in every sample map.
      @direction = r.u8
      @frame = r.u8
      @opacity = r.u8
      @blend = r.u8
      @trigger = r.u8
      cond_bytes = r.byte_values(4)
      vars = []
      4.times { vars.push r.int }
      vals = []
      4.times { vals.push r.int }
      @conditions = []
      4.times { |i| @conditions.push Condition.new(cond_bytes[i], vars[i], vals[i]) }
      @animation_speed = r.u8
      @move_speed = r.u8
      @move_frequency = r.u8
      @move_type = r.u8
      @options = r.u8
      @route_options = r.u8
      n = r.int
      raise Error, "page #{index}: bad route length #{n}" if n < 0
      @route = []
      n.times { @route.push RouteCommand.read(r) }
      n = r.int
      raise Error, "page #{index}: bad command count #{n}" if n < 0
      @commands = []
      n.times { @commands.push Command.read(r, v35) }
      @features = r.int
      @shadow = r.u8
      @range_x = r.u8
      @range_y = r.u8
      @transfer = @features > 3 ? r.u8 : nil
      r.expect_u8(END_MARK, "page #{index} terminator")
    end

    # Row of the character sheet the page's graphic starts on.
    def graphic_row; (@direction / 2) - 1; end
    def option?(bit); (@options & bit) != 0; end
    def slip_through?; option?(OPT_SLIP_THROUGH); end
    def above_hero?; option?(OPT_ABOVE_HERO); end
    def auto?; @trigger == TRIGGER_AUTO; end
    def parallel?; @trigger == TRIGGER_PARALLEL; end
  end

  class Event
    MAGIC = Wolf.bin("\x39\x30\x00\x00")
    START = 0x6F
    END_MARK = 0x70
    EMPTY_PAGE_BLOCK = Wolf.bin("\0\0\0\0")

    attr_reader :id, :name, :x, :y, :pages

    def initialize(r, v35)
      r.expect_bytes(MAGIC, "event header")
      @id = r.int
      @name = r.str
      @x = r.int
      @y = r.int
      n = r.int
      r.expect_bytes(EMPTY_PAGE_BLOCK, "event page block")
      @pages = []
      while (b = r.u8) == Page::START
        @pages.push Page.new(r, @pages.size, v35)
      end
      unless b == END_MARK
        raise Error, sprintf("event %d: page terminator 0x%02x", @id, b)
      end
      unless @pages.size == n
        raise Error, "event #{@id}: #{n} pages declared, #{@pages.size} read"
      end
    end
  end

  class Map
    MAGIC = Wolf.bin("\0" * 10 + "WOLFM\0" + "\0" * 4)
    UTF8_INDEX = 16
    TERMINATOR = 0x66
    # Map version from which the body is LZ4-packed / carries a layer count.
    PACKED_VERSION = 0x65
    LAYERED_VERSION = 0x67

    # A layer value's meaning, per the editor's own "変数呼び出し値" rules for
    # チップ処理: values below AUTOTILE_BASE index the base sheet (8 chips per
    # row); from AUTOTILE_BASE on, value / AUTOTILE_BASE is the autotile slot
    # (1-based) and value % AUTOTILE_BASE encodes the four quarter-tile
    # variants as a 4-digit decimal number, one digit per corner
    # (top-left, top-right, bottom-left, bottom-right).
    AUTOTILE_BASE = 100000

    attr_reader :utf8, :version, :tileset_id, :width, :height, :layer_count,
                :layers, :events, :v35, :name

    def self.parse(data, name = "map")
      new(data, name)
    end

    def initialize(data, name)
      @name = name
      Crypt.refuse_protected!(data, name)
      r = Reader.new(data, true)
      @utf8 = Wolf.read_magic(r, MAGIC, UTF8_INDEX, name)
      unless data.getbyte(data.bytesize - 1) == TERMINATOR
        raise Error, sprintf("%s: last byte 0x%02x is not the map terminator", name, data.getbyte(data.bytesize - 1))
      end
      @version = r.int
      @unknown2 = r.u8
      r = Wolf.unpack_body(r, name) if @version >= PACKED_VERSION
      @v35 = @version >= LAYERED_VERSION
      @unknown3 = r.str
      @tileset_id = r.int
      @width = r.int
      @height = r.int
      n = r.int
      raise Error, "#{name}: bad event count #{n}" if n < 0
      @layer_count = 3
      if @version >= LAYERED_VERSION
        @unknown4 = r.int
        @layer_count = r.int
      end
      if @width < 0 || @height < 0 || @layer_count < 0
        raise Error, "#{name}: bad size #{@width}x#{@height}x#{@layer_count}"
      end
      @layers = []
      has_tiles = true
      if @utf8
        # A 3.x map may store no tile data at all (-1 in place of it).
        save = r.pos
        has_tiles = r.int != -1
        r.pos = save if has_tiles
      end
      if has_tiles
        cells = @width * @height
        @layer_count.times do
          layer = []
          cells.times { layer.push r.int }
          @layers.push layer
        end
      end
      @events = []
      while (b = r.u8) == Event::START
        @events.push Event.new(r, @v35)
      end
      unless b == TERMINATOR
        raise Error, sprintf("%s: event terminator 0x%02x", name, b)
      end
      unless @events.size == n
        raise Error, "#{name}: #{n} events declared, #{@events.size} read"
      end
      raise Error, "#{name}: #{r.remaining} bytes trail the events" unless r.eof?
    end

    def tile(layer, x, y)
      l = @layers[layer]
      return 0 unless l && x >= 0 && y >= 0 && x < @width && y < @height
      l[y * @width + x] || 0
    end

    def self.autotile?(value); value >= AUTOTILE_BASE; end
    # 0-based autotile slot of an autotile layer value.
    def self.autotile_slot(value); value / AUTOTILE_BASE - 1; end
    def self.autotile_shape(value); value % AUTOTILE_BASE; end

    def event(id); @events.find { |e| e.id == id }; end
  end

  # ---------------------------------------------------------------------------
  # A whole project: the BasicData files plus maps on demand, addressed the way
  # the runtime needs them (map id -> file through the system database).
  class Project
    BASIC = "Data/BasicData"
    DATABASES = [
      ["DataBase", :user],
      ["CDataBase", :changeable],
      ["SysDatabase", :system]
    ]
    # System database types the runtime relies on, by name (the editor
    # localises the names only in the English edition, which renames them; ids
    # are stable across editions, so they are the primary key).
    SYS_MAP_SETTINGS = 0
    SYS_POSITIONS = 7
    SYS_CHARACTER_IMAGES = 8

    attr_reader :dir, :game, :map_tree, :tilesets, :databases, :common_events

    # Whether `dir` holds a WOLF RPG Editor project: a loose Data/BasicData
    # tree with a Game.dat. (A packed release keeps everything in Data.wolf,
    # which this layer does not open yet -- see the ADR's follow-ups.)
    def self.project?(dir)
      File.exist?("#{dir}/#{BASIC}/Game.dat")
    end

    def initialize(dir)
      @dir = dir
      @game = GameDat.parse(read("#{BASIC}/Game.dat"))
      @map_tree = MapTree.parse(read("#{BASIC}/MapTree.dat"))
      @tilesets = TileSetData.parse(read("#{BASIC}/TileSetData.dat"))
      @databases = {}
      DATABASES.each do |base, key|
        @databases[key] = Database.parse(read("#{BASIC}/#{base}.project"),
                                         read("#{BASIC}/#{base}.dat"), base)
      end
      @common_events = CommonEvents.parse(read("#{BASIC}/CommonEvent.dat"))
      @maps = {}
    end

    def read(rel)
      path = "#{@dir}/#{rel}"
      File.open(path, "rb") { |f| f.read }
    end

    def system_db; @databases[:system]; end
    def user_db; @databases[:user]; end
    def changeable_db; @databases[:changeable]; end

    # The .mps path (project-relative) of map `id`, from the system database's
    # map settings; nil when the id has no file.
    def map_file(id)
      t = system_db[SYS_MAP_SETTINGS]
      return nil unless t
      f = t.field(0)
      d = t.datum(id)
      return nil unless f && d
      v = d[f]
      v.is_a?(String) && !v.empty? ? v : nil
    end

    def map(id)
      @maps[id] ||= begin
        file = map_file(id)
        raise Error, "map #{id} has no file in the system database" unless file
        Map.parse(read("Data/#{file}"), file)
      end
    end

    # [map_id, x, y] of the "初期位置" entry (position list datum 0), the
    # place New Game starts at.
    def start_position
      t = system_db[SYS_POSITIONS]
      return nil unless t
      d = t.datum(0)
      return nil unless d
      vals = [0, 1, 2].map { |i| f = t.field(i); f ? d[f] : nil }
      return nil if vals.any?(&:nil?)
      vals
    end

    # The hero's character sheet: the Basic System keeps it in the changeable
    # database; a project without it uses Game.dat's hero graphic.
    def hero_graphic
      g = @game.hero_graphic
      g.empty? ? nil : g
    end
  end
end
