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
    # Expand a line to its plain visible text (no colour information): the same
    # string the segments from #parse concatenate to.
    def self.expand(text, variables, names)
      parse(text, variables, names).map { |s| s[:text] }.join
    end

    # Parse a message line into coloured runs. Returns an array of segments
    # `{ text:, color: }`, where `color` is the `\c[n]` palette index in effect
    # for that run (0 = the default colour). `\v[n]` (variable) and `\n[n]`
    # (actor name) are expanded into the text and `\\` yields a literal
    # backslash; the display-only codes (`\s` speed, `\.`/`\|`/`\!` waits,
    # `\>`/`\<`, `\^`, `\_`, `\$`) produce no characters and are dropped. Runs
    # with no text (e.g. a colour change before any character) are omitted, so a
    # line that renders nothing yields an empty array.
    def self.parse(text, variables, names)
      return [] if text.nil?
      segs = []
      cur = ''
      color = 0
      i = 0
      n = text.length
      while i < n
        ch = text[i]
        if ch == "\\" && i + 1 < n
          code = text[i + 1]
          i += 2
          arg, i = read_bracket(text, i)
          case code
          when 'v', 'V' then cur << variables[arg.to_i].to_s if arg
          when 'n', 'N' then cur << (names[arg.to_i] || '').to_s if arg
          when "\\"     then cur << "\\"
          when 'c', 'C' # colour change: close the current run, switch colour
            segs << { text: cur, color: color } unless cur.empty?
            cur = ''
            color = arg ? arg.to_i : 0
          # other display codes produce no characters: dropped.
          end
        else
          cur << ch
          i += 1
        end
      end
      segs << { text: cur, color: color } unless cur.empty?
      segs
    end

    # Truncate per-line colour segments to the first `revealed` characters
    # across all lines (for the typewriter effect over coloured text). `seg_lines`
    # is an array of lines, each an array of `{ text:, color: }` segments (as
    # #parse returns). Returns the same shape with later text dropped: full
    # segments while the budget lasts, then a partial segment, then nothing.
    def self.visible_segments(seg_lines, revealed)
      remaining = revealed
      seg_lines.map do |segs|
        out = []
        segs.each do |seg|
          t = seg[:text]
          if remaining <= 0
            next
          elsif remaining >= t.length
            remaining -= t.length
            out << seg
          else
            out << { text: t[0, remaining], color: seg[:color] }
            remaining = 0
          end
        end
        out
      end
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

  # Geometry of the 20 message text colours (`\c[n]`) baked into a System
  # windowskin (`System/<name>.png`). RPG2000 stores them as a 10×2 grid of
  # 16×16 swatches in the lower part of the 160×80 image, starting at y = 48;
  # colour n sits at cell (n%10, n/10). The owning scene passes a swatch's cell
  # rect to `Bitmap#blend_text`, which fills the message glyphs from it so the
  # text takes the windowskin's own colour and shading. Pure geometry (a port of
  # EasyRPG Player's system-colour layout), exercised by
  # scripts/rpg2k_render_check.rb.
  module MessagePalette
    COUNT = 20   # colour indices 0..19
    CELL = 16    # swatch size in pixels
    COLS = 10    # swatches per row
    Y_OFFSET = 48 # top of the palette region within the System image

    def self.valid?(idx)
      idx.is_a?(Integer) && idx >= 0 && idx < COUNT
    end

    # Top-left [x, y] of colour idx's swatch cell in the System graphic.
    def self.cell_origin(idx)
      [(idx % COLS) * CELL, (idx / COLS) * CELL + Y_OFFSET]
    end

    # RPG2000 draws every glyph twice: first a shadow offset one pixel down and
    # right, filled from a dedicated 16x16 block of the System image, then the
    # glyph itself from the colour swatch. The shadow block sits immediately
    # right of the system-background block on the middle row.
    SHADOW_X = 16
    SHADOW_Y = 32
    SHADOW_OFFSET = 1

    # Top-left [x, y] of the shadow block in the System graphic.
    def self.shadow_origin
      [SHADOW_X, SHADOW_Y]
    end
  end

  # Geometry of the selection cursor RPG2000 draws inside a window, ported from
  # a genuine RPG_RT frame (see scripts/compare-nepheshel-wine.bash and ADR
  # 0021). The cursor art is a 32x32 block of the System windowskin with 8px
  # corners; RPG_RT draws it around the selected row four pixels wider on each
  # side than the window's content area, but exactly the row's height — it is
  # *not* inflated vertically the way the horizontal axis is.
  module WindowCursor
    SIZE = 32     # the cursor block is 32x32 in the System image
    CORNER = 8    # its corners are 8x8, the classic RPG2000 9-patch
    # Cursor frame 1 (the steady frame) and frame 2 (RPG_RT alternates between
    # them while a window is active; Nepheshel's skin draws both identically).
    FRAME1_X = 64
    FRAME2_X = 96
    FRAME_Y = 0
    # Pixels the cursor overhangs the content area on the left and right.
    OVERHANG = 4

    # Destination rect [x, y, w, h] of the cursor for a contents-space
    # `cursor_rect`, given the window's border thickness.
    def self.dest_rect(rect_x, rect_y, rect_w, rect_h, border)
      [border + rect_x - OVERHANG, border + rect_y,
       rect_w + OVERHANG * 2, rect_h]
    end
  end

  # Gradual message text reveal (RPG2000's typewriter effect): a cursor over a
  # set of already-expanded message lines that exposes them a few characters per
  # frame. Pure data — the owning scene reads #visible_lines to (re)draw the
  # window, calls #advance each frame, and #reveal_all to finish instantly when
  # the player presses a button.
  class TextReveal
    def initialize(lines, revealed = 0)
      @lines = lines || []
      @total = 0
      @lines.each { |l| @total += l.length }
      @revealed = Game.clamp(revealed, 0, @total)
    end

    attr_reader :revealed, :total

    def done?; @revealed >= @total; end
    def reveal_all; @revealed = @total; end

    # Reveal `n` more characters (default 1), never past the total.
    def advance(n = 1)
      n = 0 if n < 0
      @revealed = Game.clamp(@revealed + n, 0, @total)
    end

    # The lines truncated to however many characters are currently revealed:
    # earlier lines fill up before later ones start, so the result is a run of
    # full lines, then one partial line, then empty strings.
    def visible_lines
      remaining = @revealed
      @lines.map do |line|
        if remaining >= line.length
          remaining -= line.length
          line
        else
          shown = line[0, remaining] || ''
          remaining = 0
          shown
        end
      end
    end
  end

  # RPG2000 message-window configuration, set by the Message Options (10120) and
  # Change Face Graphic (10130) event commands. These are *global* game-system
  # settings shared across every event and persisted in the save (as RPG_RT does
  # it): a Show Message is displayed with whatever configuration is in effect at
  # the time, and the face persists until the next Change Face Graphic replaces
  # or clears it. Pure data — the owning scene reads it when it opens a window.
  class MessageConfig
    # Text display position (the Message Options `position` field).
    POS_TOP = 0
    POS_MIDDLE = 1
    POS_BOTTOM = 2

    # Window layout: transparent background, vertical position, whether the
    # window is pinned to `position` (vs. moving aside to avoid the hero), and
    # whether other events keep running while the message shows.
    attr_accessor :transparent, :position, :position_fixed, :continue_events
    # The face graphic shown beside the text: FaceSet file name, cell index
    # (0..15), which side it sits on and whether it is mirrored.
    attr_accessor :face_name, :face_index, :face_right, :face_flipped

    def initialize
      @transparent = false
      @position = POS_BOTTOM
      @position_fixed = false
      @continue_events = false
      clear_face
    end

    # Whether a face graphic is currently selected (a non-empty file name).
    def face?
      !@face_name.nil? && !@face_name.empty?
    end

    # Drop the face graphic (an empty name), so the next message shows none.
    def clear_face
      @face_name = ''
      @face_index = 0
      @face_right = false
      @face_flipped = false
    end

    # Serialise to a plain hash of primitives (Marshal-friendly) for saving.
    def to_h
      { transparent: @transparent, position: @position,
        position_fixed: @position_fixed, continue_events: @continue_events,
        face_name: @face_name, face_index: @face_index,
        face_right: @face_right, face_flipped: @face_flipped }
    end

    # Restore the fields from a saved hash (missing keys keep their defaults).
    def load_h(h)
      return self unless h
      @transparent = h[:transparent] ? true : false
      @position = h[:position] || POS_BOTTOM
      @position_fixed = h[:position_fixed] ? true : false
      @continue_events = h[:continue_events] ? true : false
      @face_name = h[:face_name] || ''
      @face_index = h[:face_index] || 0
      @face_right = h[:face_right] ? true : false
      @face_flipped = h[:face_flipped] ? true : false
      self
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

    attr_reader :name, :graphic, :animation_type, :animation_speed

    def initialize(db, id)
      c = db.chipset[id]
      @name = c ? c.name : ''
      @graphic = c ? c.chipset_name : ''
      @passable_lower = c ? c.passable_data_lower : nil
      @terrain = c ? c.terrain_data : nil
      # Water-animation parameters (chipset chunks 11/12): the animation "type"
      # (0 = 3-frame back-and-forth, 1 = 3-frame cycle) and speed flag (0 slow,
      # non-zero fast). Consumed by ChipsetLayout when picking the animation
      # column for the water autotiles.
      @animation_type = c ? (c.animation_type || 0) : 0
      @animation_speed = c ? (c.animation_speed || 0) : 0
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

    # Terrain id of a lower-layer tile (for the Store Terrain ID command), looked
    # up through the same chip index as passability. Returns 0 when the chipset
    # carries no terrain table or the tile is out of range.
    def terrain(tile_id)
      return 0 if @terrain.nil?
      idx = ChipSet.lower_index(tile_id)
      return 0 if idx.nil? || idx < 0 || idx >= @terrain.size
      @terrain[idx] || 0
    end
  end

  # Maps an RPG2000/2003 map tile id to the source rectangle(s) it occupies in a
  # chipset image (`ChipSet/<name>.png`, a fixed 480x256 grid of 16x16 tiles).
  #
  # This is a direct port of EasyRPG Player's `TilemapLayer` geometry. A tile id
  # names one of six blocks:
  #
  #   * A/B (0..2999)      water autotiles, animated (3 columns)
  #   * C   (3000..3149)   the two animated ground tiles (4 frames)
  #   * D   (4000..4599)   terrain autotiles (grass edges, cliffs, ...)
  #   * E   (5000..5143)   plain lower-layer tiles (one 16x16 chip each)
  #   * F   (10000..10143) upper-layer tiles (one 16x16 chip each)
  #
  # Autotiles (blocks A/B and D) are not stored as whole 16x16 chips: the id
  # encodes a *combination* the map editor picked from the tile's neighbours, and
  # the drawn tile is assembled from four 8x8 quarter-tiles, each copied from a
  # different chip of the chipset. #quads returns those four quarters (or the one
  # whole chip, for the non-autotile blocks) as blit rectangles.
  #
  # Pure geometry with no rendering dependency, so it is exercised directly by
  # scripts/rpg2k_render_check.rb under CRuby.
  module ChipsetLayout
    TS = 16      # tile size in pixels
    HTS = 8      # quarter (8x8) size
    CHIPSET_W = 480
    CHIPSET_H = 256

    BLOCK_C = 3000
    BLOCK_D = 4000
    BLOCK_E = 5000
    BLOCK_F = 10000
    BLOCK_E_TILES = 144
    BLOCK_F_TILES = 144

    # [a_subtile][row][col] -> block-A chipset row (0..3) for that quarter, or -1
    # to take the quarter from block B instead. (EasyRPG BlockA_Subtiles_IDS.)
    N = -1
    BLOCK_A_SUBTILES = [
      [[N, N], [N, N]], [[3, N], [N, N]], [[N, 3], [N, N]], [[3, 3], [N, N]],
      [[N, N], [N, 3]], [[3, N], [N, 3]], [[N, 3], [N, 3]], [[3, 3], [N, 3]],
      [[N, N], [3, N]], [[3, N], [3, N]], [[N, 3], [3, N]], [[3, 3], [3, N]],
      [[N, N], [3, 3]], [[3, N], [3, 3]], [[N, 3], [3, 3]], [[3, 3], [3, 3]],
      [[1, N], [1, N]], [[1, 3], [1, N]], [[1, N], [1, 3]], [[1, 3], [1, 3]],
      [[2, 2], [N, N]], [[2, 2], [N, 3]], [[2, 2], [3, N]], [[2, 2], [3, 3]],
      [[N, 1], [N, 1]], [[N, 1], [3, 1]], [[3, 1], [N, 1]], [[3, 1], [3, 1]],
      [[N, N], [2, 2]], [[3, N], [2, 2]], [[N, 3], [2, 2]], [[3, 3], [2, 2]],
      [[1, 1], [1, 1]], [[2, 2], [2, 2]], [[0, 2], [1, N]], [[0, 2], [1, 3]],
      [[2, 0], [N, 1]], [[2, 0], [3, 1]], [[N, 1], [2, 0]], [[3, 1], [2, 0]],
      [[1, N], [0, 2]], [[1, 3], [0, 2]], [[0, 0], [1, 1]], [[0, 2], [0, 2]],
      [[1, 1], [0, 0]], [[2, 0], [2, 0]], [[0, 0], [0, 0]]
    ].freeze

    # [subtile][row][col] -> [dx, dy] chipset-chip offset within the block-D cell.
    # (EasyRPG BlockD_Subtiles_IDS.)
    BLOCK_D_SUBTILES = [
      [[[1, 2], [1, 2]], [[1, 2], [1, 2]]], [[[2, 0], [1, 2]], [[1, 2], [1, 2]]],
      [[[1, 2], [2, 0]], [[1, 2], [1, 2]]], [[[2, 0], [2, 0]], [[1, 2], [1, 2]]],
      [[[1, 2], [1, 2]], [[1, 2], [2, 0]]], [[[2, 0], [1, 2]], [[1, 2], [2, 0]]],
      [[[1, 2], [2, 0]], [[1, 2], [2, 0]]], [[[2, 0], [2, 0]], [[1, 2], [2, 0]]],
      [[[1, 2], [1, 2]], [[2, 0], [1, 2]]], [[[2, 0], [1, 2]], [[2, 0], [1, 2]]],
      [[[1, 2], [2, 0]], [[2, 0], [1, 2]]], [[[2, 0], [2, 0]], [[2, 0], [1, 2]]],
      [[[1, 2], [1, 2]], [[2, 0], [2, 0]]], [[[2, 0], [1, 2]], [[2, 0], [2, 0]]],
      [[[1, 2], [2, 0]], [[2, 0], [2, 0]]], [[[2, 0], [2, 0]], [[2, 0], [2, 0]]],
      [[[0, 2], [0, 2]], [[0, 2], [0, 2]]], [[[0, 2], [2, 0]], [[0, 2], [0, 2]]],
      [[[0, 2], [0, 2]], [[0, 2], [2, 0]]], [[[0, 2], [2, 0]], [[0, 2], [2, 0]]],
      [[[1, 1], [1, 1]], [[1, 1], [1, 1]]], [[[1, 1], [1, 1]], [[1, 1], [2, 0]]],
      [[[1, 1], [1, 1]], [[2, 0], [1, 1]]], [[[1, 1], [1, 1]], [[2, 0], [2, 0]]],
      [[[2, 2], [2, 2]], [[2, 2], [2, 2]]], [[[2, 2], [2, 2]], [[2, 0], [2, 2]]],
      [[[2, 0], [2, 2]], [[2, 2], [2, 2]]], [[[2, 0], [2, 2]], [[2, 0], [2, 2]]],
      [[[1, 3], [1, 3]], [[1, 3], [1, 3]]], [[[2, 0], [1, 3]], [[1, 3], [1, 3]]],
      [[[1, 3], [2, 0]], [[1, 3], [1, 3]]], [[[2, 0], [2, 0]], [[1, 3], [1, 3]]],
      [[[0, 2], [2, 2]], [[0, 2], [2, 2]]], [[[1, 1], [1, 1]], [[1, 3], [1, 3]]],
      [[[0, 1], [0, 1]], [[0, 1], [0, 1]]], [[[0, 1], [0, 1]], [[0, 1], [2, 0]]],
      [[[2, 1], [2, 1]], [[2, 1], [2, 1]]], [[[2, 1], [2, 1]], [[2, 0], [2, 1]]],
      [[[2, 3], [2, 3]], [[2, 3], [2, 3]]], [[[2, 0], [2, 3]], [[2, 3], [2, 3]]],
      [[[0, 3], [0, 3]], [[0, 3], [0, 3]]], [[[0, 3], [2, 0]], [[0, 3], [0, 3]]],
      [[[0, 1], [2, 1]], [[0, 1], [2, 1]]], [[[0, 1], [0, 1]], [[0, 3], [0, 3]]],
      [[[0, 3], [2, 3]], [[0, 3], [2, 3]]], [[[2, 1], [2, 1]], [[2, 3], [2, 3]]],
      [[[0, 1], [2, 1]], [[0, 3], [2, 3]]], [[[1, 2], [1, 2]], [[1, 2], [1, 2]]],
      [[[1, 2], [1, 2]], [[1, 2], [1, 2]]], [[[0, 0], [0, 0]], [[0, 0], [0, 0]]]
    ].freeze

    # Animation column (0..2) for the water autotiles (blocks A/B), from a frame
    # counter and the chipset's animation_type / animation_speed. Fast chipsets
    # advance every 12 frames, slow ones every 24. Type 0 walks 0,1,2,1 (a
    # back-and-forth); type 1 cycles 0,1,2.
    def self.anim_ab(frame, animation_type, animation_speed)
      step = frame / (animation_speed != 0 ? 12 : 24)
      if animation_type != 0
        step % 3
      else
        step %= 4
        step == 3 ? 1 : step
      end
    end

    # Animation frame (0..3) for the block-C animated tiles (advances every 6
    # frames).
    def self.anim_c(frame)
      (frame / 6) % 4
    end

    # The coarse block a tile id belongs to: :water, :animated, :terrain, :lower,
    # :upper, or nil for the empty tile (0) and ids outside every block.
    def self.block(id)
      return nil if id.nil? || id <= 0
      if id >= BLOCK_F
        id < BLOCK_F + BLOCK_F_TILES ? :upper : nil
      elsif id >= BLOCK_E
        id < BLOCK_E + BLOCK_E_TILES ? :lower : nil
      elsif id >= BLOCK_D
        :terrain
      elsif id >= BLOCK_C
        :animated
      else
        :water
      end
    end

    # Source rectangles to draw for a tile id, as an array of
    # [dx, dy, sx, sy, w, h]: dx/dy are pixel offsets within the destination
    # 16x16 tile, and sx/sy/w/h the source rect in the chipset image. Non-
    # autotile blocks return a single 16x16 rect; autotiles return four 8x8
    # quarters. The empty tile (0) and out-of-range ids return []. `abf` / `cf`
    # are the current animation columns/frames from #anim_ab / #anim_c.
    def self.quads(id, abf = 0, cf = 0)
      case block(id)
      when :water    then water_quads(id, abf)
      when :animated then [full(3 + (id - BLOCK_C) / 50, 4 + cf)]
      when :terrain  then terrain_quads(id)
      when :lower    then [lower_quad(id - BLOCK_E)]
      when :upper    then [upper_quad(id - BLOCK_F)]
      else []
      end
    end

    # -- internals ----------------------------------------------------------

    # A whole 16x16 chip at chipset grid (col, row).
    def self.full(col, row)
      [0, 0, col * TS, row * TS, TS, TS]
    end

    # Four 8x8 quarters assembled from `quarters[j][i] = [chip_col, chip_row]`:
    # quarter (j, i) is copied from the matching 8x8 sub-quadrant of that chip.
    def self.quads_from_quarters(quarters)
      out = []
      2.times do |j|
        2.times do |i|
          qc, qr = quarters[j][i]
          out << [i * HTS, j * HTS, qc * TS + i * HTS, qr * TS + j * HTS, HTS, HTS]
        end
      end
      out
    end

    # Water autotile (blocks A/B). `set` (id/1000) selects the water set, then the
    # id's low digits select a block-B border combination and a block-A corner
    # combination; each quarter comes from block A or block B accordingly.
    def self.water_quads(id, anim)
      set = id / 1000
      b_subtile = (id % 1000) / 50
      a_subtile = id % 50
      return [] if a_subtile >= BLOCK_A_SUBTILES.size || b_subtile >= TS
      quarters = [[nil, nil], [nil, nil]]

      # Quarters the A table leaves open (-1) come from block B (rows 4..7).
      2.times do |j|
        2.times do |i|
          next unless BLOCK_A_SUBTILES[a_subtile][j][i] == N
          t = (b_subtile >> (j * 2 + i)) & 1
          t ^= 3 if set == 2
          quarters[j][i] = [anim, 4 + t]
        end
      end
      # The remaining quarters come from block A (rows given by the table; set 1
      # uses the second column trio, +3).
      2.times do |j|
        2.times do |i|
          row = BLOCK_A_SUBTILES[a_subtile][j][i]
          next if row == N
          quarters[j][i] = [anim + (set == 1 ? 3 : 0), row]
        end
      end
      # When both a border and a corner are set, the border quarters win.
      if b_subtile != 0 && a_subtile != 0
        2.times do |j|
          2.times do |i|
            t = (b_subtile >> (j * 2 + i)) & 1
            t *= 2 if set == 2
            next if t == 0
            quarters[j][i] = [anim, 4 + t]
          end
        end
      end
      quads_from_quarters(quarters)
    end

    # Terrain autotile (block D). Each block is a 3x4 chip cell; the id's low
    # digits pick one of 50 corner combinations within it.
    def self.terrain_quads(id)
      blk = (id - BLOCK_D) / 50
      subtile = (id - BLOCK_D) % 50
      return [] if blk < 0 || blk >= 12 || subtile >= BLOCK_D_SUBTILES.size
      if blk < 4
        base_col = (blk % 2) * 3
        base_row = 8 + (blk / 2) * 4
      else
        base_col = 6 + (blk % 2) * 3
        base_row = ((blk - 4) / 2) * 4
      end
      quarters = [[nil, nil], [nil, nil]]
      2.times do |j|
        2.times do |i|
          off = BLOCK_D_SUBTILES[subtile][j][i]
          quarters[j][i] = [base_col + off[0], base_row + off[1]]
        end
      end
      quads_from_quarters(quarters)
    end

    # Plain lower-layer chip (block E), laid out in two 6-wide columns.
    def self.lower_quad(idx)
      if idx < 96
        full(12 + idx % 6, idx / 6)
      else
        full(18 + (idx - 96) % 6, (idx - 96) / 6)
      end
    end

    # Upper-layer chip (block F), in two 6-wide columns of the right half.
    def self.upper_quad(idx)
      if idx < 48
        full(18 + idx % 6, 8 + idx / 6)
      else
        full(24 + (idx - 48) % 6, (idx - 48) / 6)
      end
    end

    # Source rect [sx, sy, w, h] in the chipset image for an event whose graphic
    # is a *chipset tile* rather than a CharSet character: an RPG2000 event with
    # an empty CharSet name draws tile `tile_id` (its stored graphic index) from
    # the chipset. This is a direct port of EasyRPG Player's Cache::Tile — the
    # event-tile palette occupies three 6-wide columns in the lower-right of the
    # 480x256 chipset (block E/F region), addressed differently from the map's
    # own lower/upper chips. tile_id 0 and out-of-range ids fall back to the
    # first (empty) tile.
    def self.event_tile_rect(tile_id)
      if tile_id > 0 && tile_id < 48
        sub = tile_id;      bx = 288; by = 128
      elsif tile_id >= 48 && tile_id < 96
        sub = tile_id - 48; bx = 384; by = 0
      elsif tile_id >= 96 && tile_id < 144
        sub = tile_id - 96; bx = 384; by = 128
      else
        sub = 0;            bx = 288; by = 128 # invalid -> first tile
      end
      [bx + sub % 6 * TS, by + sub / 6 * TS, TS, TS]
    end
  end

  # How an RPG2000 map event's graphic is drawn each frame: which CharSet frame
  # (facing row + walk-pattern column) or chipset tile to show, given the event
  # page's static graphic fields and the character's live movement state.
  #
  # Pure geometry / selection logic with no rendering dependency (like
  # ChipsetLayout), so it is exercised directly by scripts/rpg2k_render_check.rb.
  # The owning Scene::Map keeps a per-event walk `phase` counter and a `moving`
  # flag and asks #frame for the (direction, column) to blit.
  module EventGraphic
    # Event-page facing is stored 0..3 (0 up, 1 right, 2 down, 3 left); the
    # runtime characters use RPG2000's numpad convention (8/6/2/4). Map between
    # them so movement and the CharSet row (Game::CharSet::DIR_ROW) agree.
    LCF_DIR_TO_NUMPAD = { 0 => 8, 1 => 6, 2 => 2, 3 => 4 }.freeze

    # Event-page animation types (MAP_EVENT_PAGE field 36).
    NON_CONTINUOUS       = 0 # walk animation only while stepping, faces movement
    CONTINUOUS           = 1 # walk animation always runs, faces movement
    FIXED_NON_CONTINUOUS = 2 # facing fixed, walk animation only while stepping
    FIXED_CONTINUOUS     = 3 # facing fixed, walk animation always runs
    FIXED_GRAPHIC        = 4 # a single frame, facing fixed, never animates
    SPIN                 = 5 # facing cycles through the four directions

    # Walk-frame columns cycled by an animated character: standing middle, right
    # foot, middle, left foot. RPG2000 reads its 0,1,2,1 walk as CharSet columns
    # middle(1), right(2), middle(1), left(0); `phase` is a 0..3 counter.
    WALK_COLUMNS = [1, 2, 1, 0].freeze
    # Facings a spinning event steps through (clockwise: down, left, up, right).
    SPIN_DIRECTIONS = [2, 4, 8, 6].freeze

    def self.numpad_direction(lcf_dir)
      LCF_DIR_TO_NUMPAD[lcf_dir] || 2
    end

    # Whether the type keeps the sprite's facing pinned to the page direction
    # (movement does not turn it).
    def self.fixed_direction?(anim_type)
      anim_type == FIXED_NON_CONTINUOUS || anim_type == FIXED_CONTINUOUS ||
        anim_type == FIXED_GRAPHIC
    end

    # Whether the walk animation runs even while the event stands still.
    def self.continuous?(anim_type)
      anim_type == CONTINUOUS || anim_type == FIXED_CONTINUOUS ||
        anim_type == SPIN
    end

    # Whether the graphic animates at all (a fixed graphic never does).
    def self.animated?(anim_type)
      anim_type != FIXED_GRAPHIC
    end

    def self.pattern_column(phase)
      WALK_COLUMNS[phase % WALK_COLUMNS.size]
    end

    def self.spin_direction(phase)
      SPIN_DIRECTIONS[phase % SPIN_DIRECTIONS.size]
    end

    # The [direction, column] CharSet frame to draw for an event this render.
    # `char_dir` is the character's live facing (updated by movement),
    # `base_dir`/`base_pattern` the page's initial facing/pattern, `phase` the
    # walk counter and `moving` whether the event is currently stepping. Fixed
    # graphics stay on their page frame; spinning events derive facing from the
    # phase; the ordinary types walk (cycling columns) while moving/continuous
    # and rest on the page pattern when idle.
    def self.frame(anim_type, base_dir, base_pattern, char_dir, phase, moving)
      case anim_type
      when SPIN
        [spin_direction(phase), 1]
      when FIXED_GRAPHIC
        [base_dir, base_pattern]
      else
        dir = fixed_direction?(anim_type) ? base_dir : char_dir
        col = (moving || continuous?(anim_type)) ? pattern_column(phase)
                                                  : base_pattern
        [dir, col]
      end
    end
  end

  # Geometry of the map's parallax background (the `Panorama/<name>` image drawn
  # behind the tile layers, `MAP_UNIT` fields 31–38). Given the camera position,
  # the screen / map / image sizes and the per-axis loop + autoscroll settings,
  # #axis_offset returns the top-left offset (<= 0) at which to start tiling the
  # image for that axis. The behaviour follows EasyRPG Player's parallax model:
  #
  #   * A **looping** axis tiles the image and scrolls it at half the map's rate
  #     (the classic parallax factor), plus an optional autoscroll that drifts it
  #     over time at the speed field's rate.
  #   * A **non-looping** axis anchors the image: it stays fixed to the screen
  #     when it is no larger than the screen (the common RPG2000 full-screen
  #     backdrop), and pans across its excess width/height in step with the map
  #     when it is larger.
  #
  # Pure integer geometry with no rendering dependency, so it is exercised
  # directly by scripts/rpg2k_render_check.rb. The exact scroll *rate* mirrors
  # EasyRPG's formulae but has not been visually diffed against RPG_RT under
  # wine — that native comparison is the remaining validation.
  module Parallax

    # Per-frame autoscroll offset in pixels for an RPG2000 speed field, ported
    # from EasyRPG's `scroll_amt` with its pan->pixel (/32) scaling so small
    # speeds move a fraction of a pixel per frame: the fine delta is
    # -(1<<speed) for speed>0 and +(1<<-speed) for speed<0, accumulated over
    # `frame` frames and divided by 32.
    def self.autoscroll_px(speed, frame)
      return 0 if speed.nil? || speed == 0
      amt = speed > 0 ? -(1 << speed) : (1 << -speed)
      (frame * amt) / 32
    end

    # Top-left draw offset (in (-img_px, 0]) for one panorama axis.
    def self.axis_offset(loop, autoscroll, speed, frame, cam_px, screen_px, map_px, img_px)
      return 0 if img_px.nil? || img_px <= 0
      if loop
        base = cam_px / 2
        base += autoscroll_px(speed, frame) if autoscroll
        -(base % img_px)
      else
        anchored_offset(cam_px, screen_px, map_px, img_px)
      end
    end

    # A non-looping axis: fixed to the screen while the image is no larger than
    # it, otherwise panned across the image's excess as the camera sweeps the
    # map (0 at the west/north edge, -excess at the east/south edge).
    def self.anchored_offset(cam_px, screen_px, map_px, img_px)
      return 0 if img_px <= screen_px
      cam_max = map_px - screen_px
      return 0 if cam_max <= 0
      cam = Game.clamp(cam_px, 0, cam_max)
      -((img_px - screen_px) * cam / cam_max)
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

  # A digit-entry model backing the Input Number event command: `digits` cells,
  # a movable cursor, and per-cell 0..9 increment/decrement, exposing the entered
  # integer via #value. The scene draws it and feeds it input; the logic (cursor
  # bounds, wrap-around, place value) lives here so it is unit-testable.
  class NumberInput
    MAX_DIGITS = 7 # RPG2000 caps Input Number at seven digits (0..9,999,999)

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
    def digit(i); @values[i] || 0; end

    def inc; @values[@cursor] = (@values[@cursor] + 1) % 10; end
    def dec; @values[@cursor] = (@values[@cursor] + 9) % 10; end
    def left;  @cursor -= 1 if @cursor > 0; end
    def right; @cursor += 1 if @cursor < @digits - 1; end

    # The entered value as a base-10 integer (leftmost cell is most significant).
    def value
      v = 0
      @values.each { |d| v = v * 10 + d }
      v
    end
  end

  # One party member, snapshotted from the database's actor (player) table.
  class Actor
    attr_reader :id, :level, :exp, :charset_name, :charset_index
    attr_accessor :hp, :mp
    # Name and title (the status-screen subtitle) are mutable via the Change
    # Actor Name / Title event commands. `transparent` hides the actor's map
    # sprite (the Change Sprite Association transparency flag).
    attr_accessor :name, :title, :transparent
    attr_reader :max_hp, :max_mp, :atk, :def, :int, :agi

    # The six base stats in database parameter-curve order (chunk 31 stores six
    # shorts -- maxHP, maxSP, atk, def, int, agi -- per level).
    STAT_NAMES = [:max_hp, :max_mp, :atk, :def, :int, :agi].freeze
    # The item field carrying each stat's equipment bonus, in STAT_NAMES order.
    # RPG2000 keeps every equipped weapon/armour bonus in the "points1" set plus
    # the max HP/SP points, whatever the slot.
    EQUIP_BONUS_FIELD = [:max_hp_points, :max_sp_points, :atk_points1,
                         :def_points1, :spi_points1, :agi_points1].freeze
    # Equipment slots, in save/database order: weapon, shield, armour, helmet,
    # accessory.
    EQUIP_ORDER = [:weapon, :shield, :armor, :helmet, :accessory].freeze

    # The equipped item ids, one per EQUIP_ORDER slot (0 = an empty slot), and
    # the ids of the skills the actor knows.
    attr_reader :equipment, :skills

    def initialize(db, id)
      @db = db
      @id = id
      a = db.player[id]
      raise "No such actor: #{id}" if a.nil?

      @name = a.name
      @title = a.respond_to?(:title) ? (a.title || '') : ''
      @charset_name = a.charset_name
      @charset_index = a.charset_index
      @transparent = a.respond_to?(:semi_transparent) ? (a.semi_transparent ? true : false) : false
      @db_row = a
      @exp = 0
      @equipment = normalize_equipment(a.respond_to?(:initial_equipment) ? a.initial_equipment : nil)
      @skills = []
      # Base stats scale with level from the growth curve and equipment adds on
      # top, and levelling learns skills, so seed them all at the actor's initial
      # level, then start at full health.
      set_level(a.initial_level || 1)
      @exp = exp_for_level(@level) # EXP consistent with the starting level
      @hp = @max_hp
      @mp = @max_mp
    end

    attr_writer :exp

    # Set the actor's level and recompute the six base stats from the database
    # growth curve at that level (see #base_stats), then the equipment-boosted
    # effective stats. Current HP/MP are re-clamped so lowering the level never
    # leaves a vital over its cap.
    def set_level(level)
      @level = level && level >= 1 ? level : 1
      @base = base_stats(@level)
      learn_level_skills
      recompute_stats
    end

    # Learn every skill the database growth table grants at or below the current
    # level (RPG2000 never un-learns on the way down), on top of whatever the
    # actor already knows. Confirmed against a real save: the skills learnt up to
    # an actor's level match the saved skill list exactly.
    def learn_level_skills
      learn_table.each { |skill_id, at| learn_skill(skill_id) if at <= @level }
    end

    # The database learn table as [skill_id, level] pairs (empty for a row that
    # exposes no learn table, e.g. the test fixtures).
    def learn_table
      a = @db_row
      return [] unless a.respond_to?(:skills) && a.skills
      out = []
      a.skills.each { |_i, l| out.push([l.skill_id, l.level]) }
      out
    end

    # Replace the actor's CharSet graphic (the Change Sprite Association event
    # command): `name` is the file and `index` the cell within it.
    def set_charset(name, index)
      @charset_name = name
      @charset_index = index
    end

    # The actor's database FaceSet graphic (顔グラフィック), shown on the
    # save-select screen (the SAVE_TITLE face slots) -- distinct from the message
    # face configured per Show Message. Defaults to none when the database row
    # (or edition) does not carry one.
    def faceset_name
      @db_row.respond_to?(:faceset_name) ? (@db_row.faceset_name || '') : ''
    end

    def faceset_index
      @db_row.respond_to?(:faceset_index) ? (@db_row.faceset_index || 0) : 0
    end

    # Whether the actor knows `skill_id`.
    def knows_skill?(skill_id)
      return false if skill_id.nil? || skill_id == 0
      @skills.include?(skill_id)
    end

    # Learn / forget a skill (the Change Skill operations and levelling).
    def learn_skill(skill_id)
      return if skill_id.nil? || skill_id == 0 || @skills.include?(skill_id)
      @skills.push(skill_id)
    end

    def forget_skill(skill_id)
      @skills.delete(skill_id)
    end

    # Replace the known-skill set (Continue restoring the saved skills).
    def skills=(ids)
      @skills = (ids || []).reject { |s| s.nil? || s == 0 }.uniq
    end

    # Replace the equipped items (an array of up to five item ids in EQUIP_ORDER,
    # 0/nil for an empty slot) and recompute the boosted stats.
    def equip(ids)
      @equipment = normalize_equipment(ids)
      recompute_stats
    end

    # Whether `item_id` occupies any equipment slot.
    def equipped?(item_id)
      return false if item_id.nil? || item_id == 0
      @equipment.include?(item_id)
    end

    # Equip a database item into the slot matching its type (weapon type 1 ->
    # slot 0, shield 2 -> 1, armour 3 -> 2, helmet 4 -> 3, accessory 5 -> 4) and
    # recompute the boosted stats. A non-equippable item, an unknown id, or a
    # database without an item table is ignored. Drives the Change Equipment
    # event command's equip operation.
    def equip_item(item_id)
      return if item_id.nil? || item_id == 0 || !@db.respond_to?(:item)
      it = @db.item[item_id]
      return unless it
      slot = it.type - 1
      return unless slot >= 0 && slot < EQUIP_ORDER.size
      @equipment[slot] = item_id
      recompute_stats
    end

    # Clear an equipment slot: 0..4 empties that one slot, EQUIP_ORDER.size (5)
    # strips every slot, any other value is a no-op. Drives the Change Equipment
    # command's remove operation.
    def unequip(slot)
      if slot == EQUIP_ORDER.size
        @equipment = EQUIP_ORDER.map { 0 }
      elsif slot >= 0 && slot < EQUIP_ORDER.size
        @equipment[slot] = 0
      else
        return
      end
      recompute_stats
    end

    # The six base stats at `level`. Real database rows expose the full growth
    # curve (six shorts per level) via LCF::Array1D#int16_values; index it by
    # level, clamped to the curve's length. A row that only offers a single
    # `status` hash (the test fixtures, or a database without a curve) is treated
    # as level-independent.
    def base_stats(level)
      a = @db_row
      curve = a.respond_to?(:int16_values) ? a.int16_values(31) : nil
      if curve && curve.size >= STAT_NAMES.size
        levels = curve.size / STAT_NAMES.size
        lv = level > levels ? levels : level
        base = (lv - 1) * STAT_NAMES.size
        return STAT_NAMES.each_index.map { |i| curve[base + i] || 0 }
      end
      st = (a.respond_to?(:status) ? a.status : nil) || {}
      STAT_NAMES.map { |k| st[k] || 0 }
    end

    # Recompute the six effective stats (base + equipment) into their readers and
    # re-clamp current HP/MP to the refreshed maxima.
    def recompute_stats
      @max_hp = @base[0] + equip_bonus(0)
      @max_mp = @base[1] + equip_bonus(1)
      @atk = @base[2] + equip_bonus(2)
      @def = @base[3] + equip_bonus(3)
      @int = @base[4] + equip_bonus(4)
      @agi = @base[5] + equip_bonus(5)
      @hp = @max_hp if @hp && @hp > @max_hp
      @mp = @max_mp if @mp && @mp > @max_mp
    end

    # Total equipment bonus for stat index `i` (see EQUIP_BONUS_FIELD): the sum
    # over equipped items of that item's bonus field. A database that exposes no
    # item table (the test fixtures) contributes nothing.
    def equip_bonus(i)
      return 0 unless @db.respond_to?(:item)
      field = EQUIP_BONUS_FIELD[i]
      total = 0
      @equipment.each do |iid|
        next if iid.nil? || iid == 0
        it = @db.item[iid]
        total += (it.send(field) || 0) if it
      end
      total
    end

    # Coerce an equipment spec (an EQUIP_ORDER hash, an array of ids, or nil) to a
    # five-slot array of integer item ids.
    def normalize_equipment(spec)
      ids =
        if spec.is_a?(Hash) then EQUIP_ORDER.map { |k| spec[k] }
        elsif spec.is_a?(Array) then spec.dup
        else []
        end
      EQUIP_ORDER.each_index.map { |i| ids[i] || 0 }
    end

    # RPG2000 caps: total EXP maxes at 999_999; the EXP-curve fields default to
    # 30 when a database row does not carry them (e.g. a test fixture).
    EXP_MAX = 999_999
    EXP_DEFAULT = 30

    # The actor's maximum level (from the database row; 50 by RPG2000 default).
    def max_level
      ml = @db_row.respond_to?(:max_level) ? @db_row.max_level : nil
      ml && ml >= 1 ? ml : 50
    end

    # Total EXP required to *be at* `level` (0 at level 1). RPG2000's standard
    # curve, computed from the row's exp_basic / exp_increase / exp_correction —
    # a direct port of EasyRPG's CalculateExp(level - 1).
    def exp_for_level(level)
      return 0 if level <= 1
      calc_exp(level - 1)
    end

    # Set total EXP (clamped to 0..EXP_MAX) and re-derive the level from the curve
    # thresholds, recomputing the base stats via #set_level when the level
    # changes. Mirrors EasyRPG's Game_Actor::ChangeExp: raising EXP climbs while
    # the next level's threshold is reached; lowering it drops while below the
    # current level's threshold.
    def set_exp(new_exp)
      new_exp = Game.clamp(new_exp, 0, EXP_MAX)
      new_level = @level
      if new_exp > @exp
        while new_level < max_level && exp_for_level(new_level + 1) <= new_exp
          new_level += 1
        end
      elsif new_exp < @exp
        new_level -= 1 while new_level > 1 && new_exp < exp_for_level(new_level)
      end
      @exp = new_exp
      set_level(new_level) if new_level != @level
    end

    # Add `delta` EXP (negative removes it); the Change EXP command's effect.
    def gain_exp(delta)
      set_exp(@exp + delta)
    end

    # Total EXP needed to *be at* the next level, or nil at the maximum level
    # (where there is no next level).
    def next_level_exp
      return nil if @level >= max_level
      exp_for_level(@level + 1)
    end

    # EXP still required to reach the next level (0 once the threshold is met, so
    # a just-levelled actor reads 0 briefly), or nil at the maximum level. Drives
    # the status screen's "to next level" figure.
    def exp_to_next
      nxt = next_level_exp
      return nil unless nxt
      rem = nxt - @exp
      rem < 0 ? 0 : rem
    end

    # Change the level by `delta` (the Change Level command). Recomputes the base
    # stats via #set_level and re-aligns EXP to the new level, mirroring EasyRPG's
    # ChangeLevel: on a level up EXP rises to at least the new level's threshold;
    # on a level down that leaves EXP at/above the next threshold it drops to the
    # level's base. Current HP/MP are not refilled (set_level only re-clamps
    # them), matching RPG_RT.
    def change_level_by(delta)
      new_level = Game.clamp(@level + delta, 1, max_level)
      old = @level
      set_level(new_level)
      base = exp_for_level(new_level)
      if new_level > old
        @exp = base if @exp < base
      elsif new_level < old
        nxt = new_level < max_level ? exp_for_level(new_level + 1) : EXP_MAX + 1
        @exp = base if @exp >= nxt
      end
    end

    # Apply a HP change (positive heals, negative damages), clamped to
    # [floor, max_hp]. The floor is 0 when death is allowed (the actor may be
    # knocked out) or 1 otherwise, matching RPG2000's Change HP "allow death"
    # flag. Returns the new HP.
    def change_hp(delta, allow_death = true)
      floor = allow_death ? 0 : 1
      @hp = Game.clamp(@hp + delta, floor, @max_hp)
    end

    # Apply a MP (SP) change, clamped to [0, max_mp]. Returns the new MP.
    def change_mp(delta)
      @mp = Game.clamp(@mp + delta, 0, @max_mp)
    end

    # Restore HP and MP to their maxima (RPG2000 Full Recovery; state recovery
    # is not modelled yet).
    def full_heal
      @hp = @max_hp
      @mp = @max_mp
    end

    # Change Parameters base-stat types (the RPG2000 command's parameter field).
    PARAM_MAX_HP = 0
    PARAM_MAX_MP = 1
    PARAM_ATK    = 2
    PARAM_DEF    = 3
    PARAM_INT    = 4
    PARAM_AGI    = 5

    # Apply a base-parameter change (the Change Parameters command). `type` is
    # one of the PARAM_* constants; `delta` is signed. The change lands on the
    # base stat (the equipment bonus stays on top) and clamps to RPG2000's limits
    # (max HP/MP 1..9999, the four battle stats 1..999); recomputing re-clamps the
    # current HP/MP so a lowered maximum never leaves a vital over its cap.
    def change_param(type, delta)
      return unless type >= 0 && type < STAT_NAMES.size
      limit = (type == PARAM_MAX_HP || type == PARAM_MAX_MP) ? 9999 : 999
      @base[type] = Game.clamp(@base[type] + delta, 1, limit)
      recompute_stats
    end

    private

    # EasyRPG's CalculateExp(n): the RPG2000 standard EXP curve summed over n
    # steps. Float arithmetic mirrors RPG_RT; the running total truncates toward
    # zero each step (C's (int) cast) and the whole result caps at EXP_MAX.
    def calc_exp(n)
      base = db_exp_param(:exp_basic).to_f
      inflation = 1.5 + db_exp_param(:exp_increase) * 0.01
      correction = db_exp_param(:exp_correction).to_f
      result = 0
      n.times do
        result += (correction + base).to_i
        base *= inflation
        inflation = ((n + 1) * 0.002 + 0.8) * (inflation - 1) + 1
      end
      result > EXP_MAX ? EXP_MAX : result
    end

    # Read a numeric EXP-curve field from the database row, defaulting when the
    # row (a test fixture) does not carry it.
    def db_exp_param(field)
      @db_row.respond_to?(field) ? (@db_row.__send__(field) || EXP_DEFAULT) : EXP_DEFAULT
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

    # Serialise the mutable party state (see State#to_h). Beyond HP/MP this keeps
    # the fields the Change Actor Name / Title / Sprite commands mutate, so those
    # edits survive a Save / Continue instead of reverting to the database row.
    def to_h
      hp = {}
      mp = {}
      exp = {}
      meta = {}
      @actors.each do |a|
        hp[a.id] = a.hp
        mp[a.id] = a.mp
        exp[a.id] = a.exp
        meta[a.id] = { name: a.name, title: a.title,
                       charset_name: a.charset_name,
                       charset_index: a.charset_index,
                       transparent: a.transparent }
      end
      { actor_ids: @actors.map { |a| a.id }, items: @items, gold: @gold,
        hp: hp, mp: mp, exp: exp, actor_meta: meta }
    end

    # Restore item/gold, per-actor exp/hp/mp and the name/title/sprite overrides
    # from a saved party hash. EXP is restored first (it re-derives the level and
    # its base stats), then the saved HP/MP are laid over the recomputed maxima.
    # A save written before actor_meta existed simply keeps the database defaults.
    def load_state(data)
      @items = data[:items] || {}
      @gold = data[:gold] || 0
      exp = data[:exp] || {}
      hp = data[:hp] || {}
      mp = data[:mp] || {}
      meta = data[:actor_meta] || {}
      @actors.each do |a|
        a.set_exp(exp[a.id]) if exp[a.id]
        a.hp = hp[a.id] if hp[a.id]
        a.mp = mp[a.id] if mp[a.id]
        apply_actor_meta(a, meta[a.id])
      end
    end

    # Apply a saved name/title/sprite override hash to an actor (nil = no
    # override, keeping the database defaults).
    def apply_actor_meta(actor, m)
      return unless m
      actor.name = m[:name] if m[:name]
      actor.title = m[:title] unless m[:title].nil?
      if m[:charset_name]
        actor.set_charset(m[:charset_name], m[:charset_index] || actor.charset_index)
      end
      actor.transparent = m[:transparent] unless m[:transparent].nil?
    end

    def each(&blk); @actors.each(&blk); end
    def size; @actors.size; end
    def leader; @actors.first; end

    def include_actor?(id); @actors.any? { |a| a.id == id }; end
    def actor_by_id(id); @actors.find { |a| a.id == id }; end

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

    # RPG2000 database item types. Types 1..5 are the equipment slots (see
    # Actor::EQUIP_ORDER); 6 is a healing medicine (薬); 7 is a skill book (本)
    # that teaches a skill; 8 is a seed (種) that permanently raises a stat.
    # Switch (9) menu use is a later refinement.
    ITEM_MEDICINE = 6
    ITEM_SKILL_BOOK = 7
    ITEM_SEED = 8

    # The database row for a held item id, or nil when the database has no item
    # table (a bare test fixture) or no such row.
    def db_item(id)
      return nil unless @db.respond_to?(:item)
      @db.item[id]
    end

    # Whether item `id` can be used from the field (main-menu) item screen: a
    # medicine, a skill book or a seed the party actually holds.
    def field_usable?(id)
      it = db_item(id)
      return false unless it && item_count(id) > 0
      it.type == ITEM_MEDICINE || it.type == ITEM_SKILL_BOOK || it.type == ITEM_SEED
    end

    # The bag's field-usable items as `[id, count]` pairs in ascending id order,
    # for the item menu's list.
    def field_items
      @items.keys.sort.select { |id| field_usable?(id) }
            .map { |id| [id, item_count(id)] }
    end

    # The HP and SP a medicine restores to `actor`: the flat amount plus a
    # percentage of the actor's maximum, summed with RPG2000's integer math.
    def item_recovery(it, actor)
      hp = (it.recover_hp || 0) + (actor.max_hp * (it.recover_hp_rate || 0)) / 100
      mp = (it.recover_sp || 0) + (actor.max_mp * (it.recover_sp_rate || 0)) / 100
      [hp, mp]
    end

    # Whether using item `id` on `actor` would change anything, so the menu can
    # grey out a no-op. A medicine is effective when the target is below full
    # HP/SP and it restores some (RPG_RT forbids using a pure-recovery item on a
    # full target); a skill book is effective when the target does not already
    # know its skill.
    def item_effective?(id, actor)
      it = db_item(id)
      return false unless it && actor
      case it.type
      when ITEM_MEDICINE
        hp, mp = item_recovery(it, actor)
        (hp > 0 && actor.hp < actor.max_hp) || (mp > 0 && actor.mp < actor.max_mp)
      when ITEM_SKILL_BOOK
        s = it.skill_id
        !s.nil? && s != 0 && !actor.knows_skill?(s)
      when ITEM_SEED
        seed_boosts(it).any? { |b| b != 0 }
      else
        false
      end
    end

    # Use item `id` from the field menu, dispatching on its database type, and
    # return the actors it affected (empty when it did nothing -- then nothing is
    # consumed). A medicine heals; a skill book teaches its skill; a seed raises a
    # stat.
    def use_item(id, actor = nil)
      it = db_item(id)
      return [] unless it && item_count(id) > 0
      case it.type
      when ITEM_MEDICINE then use_medicine(it, id, actor)
      when ITEM_SKILL_BOOK then use_skill_book(it, id, actor)
      when ITEM_SEED then use_seed(it, id, actor)
      else []
      end
    end

    # A single-target medicine (scope 0) heals `actor`; an all-ally medicine
    # (scope 1) heals the whole party regardless of `actor`. Applies the recovery
    # (clamped to each target's maxima) and consumes one from the bag only when it
    # actually healed someone (so using it on a full party wastes nothing).
    def use_medicine(it, id, actor)
      targets = it.scope == 1 ? @actors : [actor].compact
      affected = []
      targets.each do |t|
        hp, mp = item_recovery(it, t)
        before_hp = t.hp
        before_mp = t.mp
        t.change_hp(hp) if hp > 0
        t.change_mp(mp) if mp > 0
        affected.push(t) if t.hp != before_hp || t.mp != before_mp
      end
      lose_item(id, 1) unless affected.empty?
      affected
    end

    # A skill book teaches its skill (item field 53) to `actor` if the actor does
    # not already know it, consuming one book. A book with no skill, or used on an
    # actor who already knows the skill, does nothing and is not consumed.
    def use_skill_book(it, id, actor)
      skill = it.skill_id
      return [] unless actor && skill && skill != 0 && !actor.knows_skill?(skill)
      actor.learn_skill(skill)
      lose_item(id, 1)
      [actor]
    end

    # The six permanent stat boosts a seed grants, in Actor::STAT_NAMES order
    # (max HP, max SP, attack, defence, spirit, agility). RPG2000 seeds use the
    # item's max_hp_points / max_sp_points and the *_points2 stat set -- distinct
    # from the *_points1 fields that carry equipment bonuses -- confirmed against
    # EasyRPG's Game_Actor seed handling.
    def seed_boosts(it)
      [it.max_hp_points || 0, it.max_sp_points || 0,
       it.atk_points2 || 0, it.def_points2 || 0,
       it.spi_points2 || 0, it.agi_points2 || 0]
    end

    # A seed permanently raises `actor`'s base stats by seed_boosts (each applied
    # through Actor#change_param, so RPG2000's stat caps hold). Consumes one when
    # it carries any boost; a seed with no boost does nothing and is not consumed.
    def use_seed(it, id, actor)
      return [] unless actor
      boosts = seed_boosts(it)
      return [] unless boosts.any? { |b| b != 0 }
      boosts.each_index { |i| actor.change_param(i, boosts[i]) if boosts[i] != 0 }
      lose_item(id, 1)
      [actor]
    end

    # The equipment slot index (0..4) a held item occupies by its database type
    # -- weapon(1)->0, shield(2)->1, armour(3)->2, helmet(4)->3, accessory(5)->4
    # -- or nil when the item is not equipment (or unknown). Mirrors
    # Actor#equip_item's `type - 1` mapping.
    def equip_slot_for(id)
      it = db_item(id)
      return nil unless it
      t = it.type
      (t >= 1 && t <= Actor::EQUIP_ORDER.size) ? t - 1 : nil
    end

    # Held items equippable in equipment `slot` (0..4), as [id, count] pairs in
    # ascending id order -- the candidate list for the equip menu's chosen slot.
    def equip_candidates(slot)
      @items.keys.sort.select { |id| item_count(id) > 0 && equip_slot_for(id) == slot }
            .map { |id| [id, item_count(id)] }
    end

    # Equip bag item `item_id` on `actor`, moving it through the inventory the way
    # the equip menu does: take one from the bag, equip it into the slot its type
    # dictates, and return the previously-equipped item (if any) to the bag. A
    # no-op returning false unless the party holds the item and it is equipment;
    # true on success. (Unlike the Change Equipment event command, which does not
    # touch the bag, the menu swaps through it.)
    def equip_from_bag(actor, item_id)
      return false unless actor && item_count(item_id) > 0
      slot = equip_slot_for(item_id)
      return false if slot.nil?
      previous = actor.equipment[slot]
      actor.equip_item(item_id)
      lose_item(item_id, 1)
      gain_item(previous, 1) if previous && previous != 0
      true
    end

    # Unequip `actor`'s `slot`, returning the removed item to the bag. Returns the
    # removed item id (0 when the slot was already empty or the slot is invalid).
    def unequip_to_bag(actor, slot)
      return 0 unless actor && slot >= 0 && slot < Actor::EQUIP_ORDER.size
      removed = actor.equipment[slot]
      actor.unequip(slot)
      gain_item(removed, 1) if removed && removed != 0
      removed || 0
    end

    # RPG2000 skill type (field 8): 0 normal (an HP/SP/stat effect), 1 teleport,
    # 2 escape, 3 switch. The field skill menu casts normal skills; the
    # teleport/escape/switch types are later refinements. Skill scope (field 12):
    # 0 single enemy, 1 all enemies, 2 the caster, 3 a single ally, 4 all allies.
    SKILL_NORMAL = 0

    # The database row for a skill id, or nil when the database has no skill table
    # (a bare fixture) or no such row.
    def db_skill(id)
      return nil unless @db.respond_to?(:skill)
      @db.skill[id]
    end

    # The SP `caster` pays to cast skill `sk`: a fixed cost (sp_type 0) or a
    # percentage of the caster's max SP (sp_type 1). Mirrors EasyRPG's
    # CalculateSkillCost (the half-SP-cost modifier is a later refinement).
    def skill_cost(sk, caster)
      if sk.sp_type == 1
        caster.max_mp * (sk.sp_percent || 0) / 100
      else
        sk.sp_cost || 0
      end
    end

    # `caster`'s known skills usable from the field menu -- normal skills flagged
    # `occasion_field` that target the caster or an ally (scope >= 2) -- as
    # `[skill_id, cost]` pairs in ascending id order.
    def field_skills(caster)
      return [] unless caster
      caster.skills.sort.select do |sid|
        sk = db_skill(sid)
        sk && sk.type == SKILL_NORMAL && sk.occasion_field && sk.scope >= 2
      end.map { |sid| [sid, skill_cost(db_skill(sid), caster)] }
    end

    # Whether `caster` can cast skill `sid` right now: it knows the skill and can
    # pay its SP cost.
    def can_cast?(caster, sid)
      sk = db_skill(sid)
      !sk.nil? && caster && caster.knows_skill?(sid) && caster.mp >= skill_cost(sk, caster)
    end

    # The base HP/SP amount a recovery skill restores, per RPG2000's formula
    # `power + physical_rate*attack/20 + magical_rate*spirit/40` (spirit is the
    # `int` stat), computed from the caster deterministically -- battle applies a
    # +/- variance, but field/menu use does not. Confirmed against EasyRPG's
    # Algo::CalcSkillEffect (the ally-heal path has no target-defence term).
    def skill_effect(sk, caster)
      (sk.power || 0) +
        (sk.physical_rate || 0) * caster.atk / 20 +
        (sk.magical_rate || 0) * caster.int / 40
    end

    # The actors a field skill affects: the caster (scope 2), a chosen single ally
    # (scope 3), or the whole party (scope 4).
    def skill_targets(sk, caster, target)
      case sk.scope
      when 4 then @actors
      when 2 then [caster]
      else [target].compact
      end
    end

    # Whether casting skill `sid` on `target` would change anything -- used to grey
    # out a no-op (e.g. a heal on an already-full ally). Requires the caster to be
    # able to cast it at all.
    def skill_effective?(caster, sid, target)
      sk = db_skill(sid)
      return false unless sk && can_cast?(caster, sid)
      amount = skill_effect(sk, caster)
      return false unless amount > 0
      skill_targets(sk, caster, target).any? do |t|
        (sk.affect_hp && t.hp < t.max_hp) || (sk.affect_sp && t.mp < t.max_mp)
      end
    end

    # Cast field skill `sid` from `caster` on `target` (scope-dependent). Restores
    # HP and/or SP by the skill effect to each target (clamped), then spends the
    # caster's SP -- but only when it actually helped someone, so a wasted cast
    # (everyone full) costs nothing. Returns the affected actors.
    def cast_skill(caster, sid, target = nil)
      sk = db_skill(sid)
      return [] unless sk && can_cast?(caster, sid)
      amount = skill_effect(sk, caster)
      affected = []
      skill_targets(sk, caster, target).each do |t|
        before_hp = t.hp
        before_mp = t.mp
        t.change_hp(amount) if sk.affect_hp && amount > 0
        t.change_mp(amount) if sk.affect_sp && amount > 0
        affected.push(t) if t.hp != before_hp || t.mp != before_mp
      end
      caster.change_mp(-skill_cost(sk, caster)) unless affected.empty?
      affected
    end

    # -- Battle-context skill / item use --------------------------------------
    #
    # The on-screen battle commands work on Game::Battle::Combatant snapshots but
    # reuse the field menu's cost / effect formulas (#skill_cost, #skill_effect,
    # #item_recovery). Scope is single-target for now: an attack skill hits one
    # enemy, a recovery skill / medicine restores one ally (or the caster). The
    # all-target scopes (1 all enemies, 4 all allies) and the battle SP / damage
    # variance are later refinements.

    # Single-target battle skill scopes: 0 single enemy, 2 the caster, 3 a single
    # ally. (1 all enemies and 4 all allies are deferred.)
    BATTLE_SKILL_SCOPES = [0, 2, 3].freeze

    # `actor`'s known normal skills usable in battle — flagged `occasion_battle`
    # with a single-target scope — as `[skill_id, cost]` pairs in ascending id
    # order. `caster` is the battle snapshot the SP cost is figured from.
    def battle_skills(actor, caster)
      return [] unless actor && caster
      actor.skills.sort.select do |sid|
        sk = db_skill(sid)
        sk && sk.type == SKILL_NORMAL && battle_occasion?(sk) &&
          BATTLE_SKILL_SCOPES.include?(sk.scope)
      end.map { |sid| [sid, skill_cost(db_skill(sid), caster)] }
    end

    # Whether skill `sk` may be used in battle. Defaults to usable when the row
    # (a bare fixture) carries no `occasion_battle` flag.
    def battle_occasion?(sk)
      sk.respond_to?(:occasion_battle) ? sk.occasion_battle : true
    end

    # Whom a battle skill targets: :enemy (scope 0), :self (scope 2) or :ally (3).
    def battle_skill_target(sk)
      case sk.scope
      when 0 then :enemy
      when 2 then :self
      else :ally
      end
    end

    # The command numbers for casting `sk` from `caster` on `target` (both
    # Combatant snapshots): the caster's SP `cost`, and the signed HP / SP deltas
    # to the target — negative HP for an attack skill (base effect less a quarter
    # of the target's defence, min 1), positive HP / SP for a recovery skill.
    def battle_skill_command(sk, caster, target)
      cost = skill_cost(sk, caster)
      base = skill_effect(sk, caster)
      if sk.scope == 0
        dmg = base - (target ? target.def / 4 : 0)
        dmg = 1 if dmg < 1
        { cost: cost, hp: -dmg, mp: 0 }
      else
        { cost: cost, hp: sk.affect_hp ? base : 0, mp: sk.affect_sp ? base : 0 }
      end
    end

    # Whether item `id` can be used in battle: a medicine flagged occasion_battle
    # the party actually holds.
    def battle_usable?(id)
      it = db_item(id)
      return false unless it && item_count(id) > 0
      it.type == ITEM_MEDICINE && battle_item_occasion?(it)
    end

    # Whether medicine `it` may be used in battle. Defaults to usable when the row
    # (a bare fixture) carries no `occasion_battle` flag.
    def battle_item_occasion?(it)
      it.respond_to?(:occasion_battle) ? it.occasion_battle : true
    end

    # The bag's battle-usable items as `[id, count]` pairs in ascending id order.
    def battle_items
      @items.keys.sort.select { |id| battle_usable?(id) }
            .map { |id| [id, item_count(id)] }
    end

    # The HP / SP a medicine restores to a battle `target` (Combatant snapshot),
    # as `{ hp:, mp: }` — the same recovery the field menu applies.
    def battle_item_command(it, target)
      hp, mp = item_recovery(it, target)
      { hp: hp, mp: mp }
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

  # One decoded move-route command: a command id plus the optional string /
  # integer parameters a handful of commands carry. This mirrors
  # LCF::MoveCommand (produced by the native parser for event-page routes) so a
  # MoveRoute can execute it, but is defined here in the pure-Ruby game layer so
  # the interpreter — which decodes the move route embedded in a Move Event
  # command's parameters, with no LCF parser loaded — can build them too.
  class MoveCommand
    attr_reader :command_id, :parameter_string,
                :parameter_a, :parameter_b, :parameter_c

    def initialize(command_id, string = '', a = 0, b = 0, c = 0)
      @command_id = command_id
      @parameter_string = string
      @parameter_a = a
      @parameter_b = b
      @parameter_c = c
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

  # Screen-effect state driven by the screen event commands. Models two effects
  # so far:
  #
  # * **Tint** (Tint Screen, 11030): a colour multiplier given as RPG2000's four
  #   0..200 channels (red / green / blue / saturation, 100 = neutral). `tint_to`
  #   starts a transition to a target over N frames and `update` steps the
  #   channels toward it with the classic RPG2000/RGSS
  #   `cur += (target - cur) / frames_left` interpolation, which lands exactly on
  #   the target on the final frame. Applying the tint as an `RGSS::Viewport`
  #   tone is the native (C++) half still to come, so the tint does not yet draw.
  # * **Shake** (Shake Screen, 11050): a horizontal camera offset that oscillates
  #   while active. `shake` starts a timed shake and `update` advances a float-
  #   free triangle wave (mruby here has no `Math`), amplitude scaled by power
  #   and rate by speed — an approximation of RPG_RT's shake. The scene reads
  #   `shake_offset` and offsets the camera by it, so the shake *is* visible.
  #
  # `update` (called once per frame by the scene) advances both. Flash will join
  # the class the same way.
  class Screen
    NEUTRAL = 100 # a channel value that leaves the screen unchanged

    def initialize
      @r = @g = @b = @sat = NEUTRAL
      @tr = @tg = @tb = @tsat = NEUTRAL
      @frames = 0 # frames left in the current tint transition (0 = settled)
      @shake_power = 0
      @shake_speed = 1
      @shake_frames = 0 # frames left in the current shake (0 = still)
      @shake_phase = 0
      @shake_offset = 0
      @flash_r = @flash_g = @flash_b = 0
      @flash_power = 0 # peak strength of the current flash
      @flash_strength = 0 # current strength, fading to 0 over the duration
      @flash_frames = 0 # frames left in the current flash (0 = faded out)
      @flash_total = 0
      @pan_x = 0        # current pan offset in pixels (added to the camera)
      @pan_y = 0
      @pan_tx = 0       # target pan offset the current pan/reset scrolls toward
      @pan_ty = 0
      @pan_step = 1     # pixels moved toward the target per frame
      @pan_locked = false # when true the scene stops the camera following the hero
      @fade = 0            # screen erasure: 0 fully visible .. 255 fully black
      @fade_target = 0     # the level the current transition eases toward
      @fade_frames = 0     # frames left in the current fade (0 = settled)
      @fade_transition = 0 # RPG2000 transition style (see Erase/Show Screen)
    end

    # Current tint as [red, green, blue, saturation] (each 0..200, 100 neutral).
    def tint; [@r, @g, @b, @sat]; end

    # True while a tint transition is still in progress.
    def tinting?; @frames > 0; end

    # The current horizontal shake offset in pixels (0 when not shaking).
    def shake_offset; @shake_offset; end

    # True while a timed shake is still running.
    def shaking?; @shake_frames > 0; end

    # The current flash as [red, green, blue, strength]; strength is 0 when not
    # flashing. The owning scene draws a full-screen colour overlay at `strength`
    # opacity (a later native refinement — see the tint note).
    def flash_color; [@flash_r, @flash_g, @flash_b, @flash_strength]; end

    # True while a flash is still fading out.
    def flashing?; @flash_frames > 0; end

    # The current pan offset [x, y] in pixels, added to the camera by the scene.
    def pan_offset; [@pan_x, @pan_y]; end

    # Whether a Lock operation has frozen the camera in place — the scene stops
    # following the hero while this holds. The pan offset (see #pan_offset) is
    # applied by the scene independently of this flag.
    def pan_locked?; @pan_locked; end

    # True while a pan/reset scroll has not yet reached its target.
    def panning?; @pan_x != @pan_tx || @pan_y != @pan_ty; end

    # Screen erasure level (0 fully visible .. 255 fully black). The scene draws
    # a black overlay at this opacity — the native half still to come, like the
    # tint and flash overlays — so the level is modelled but does not yet darken
    # the screen.
    def fade_level; @fade; end

    # The RPG2000 transition style requested by the last Erase / Show Screen
    # (0 = fade, higher = block / stripe / scroll variants). Recorded for
    # fidelity; only the fade is modelled.
    def fade_transition; @fade_transition; end

    # True while an erase / show fade is still in progress.
    def fading?; @fade_frames > 0; end

    # True once the screen is fully erased (held black until a Show Screen).
    def erased?; @fade >= 255; end

    # True while any screen effect is still animating (drives the wait flag).
    def busy?; tinting? || shaking? || flashing? || panning? || fading?; end

    # Begin a tint transition to the target channels over `frames` frames
    # (frames <= 0 applies it immediately). Values are clamped to 0..200.
    def tint_to(r, g, b, sat, frames)
      @tr = Game.clamp(r, 0, 200)
      @tg = Game.clamp(g, 0, 200)
      @tb = Game.clamp(b, 0, 200)
      @tsat = Game.clamp(sat, 0, 200)
      if frames <= 0
        @r = @tr; @g = @tg; @b = @tb; @sat = @tsat
        @frames = 0
      else
        @frames = frames
      end
    end

    # Begin a timed shake of the given power and speed for `frames` frames
    # (frames <= 0 stops the shake immediately). Power/speed clamp to sane ranges.
    def shake(power, speed, frames)
      @shake_power = Game.clamp(power, 0, 9)
      @shake_speed = Game.clamp(speed, 1, 9)
      @shake_phase = 0
      if frames <= 0
        @shake_frames = 0
        @shake_offset = 0
      else
        @shake_frames = frames
      end
    end

    # Begin a flash of colour (r, g, b) at peak strength `power`, fading linearly
    # to 0 over `frames` frames (frames <= 0 clears any flash immediately).
    def flash(r, g, b, power, frames)
      @flash_r = r
      @flash_g = g
      @flash_b = b
      @flash_power = power
      @flash_total = frames
      if frames <= 0
        @flash_frames = 0
        @flash_strength = 0
      else
        @flash_frames = frames
        @flash_strength = power
      end
    end

    # Erase Screen: fade the screen out to black over `frames` frames using the
    # given RPG2000 transition style. Held black afterwards until #show. A no-op
    # (settles immediately) when the screen is already fully erased.
    def erase(transition, frames)
      fade_to(255, transition, frames)
    end

    # Show Screen: fade the screen back in from black over `frames` frames. A
    # no-op when the screen is already fully visible.
    def show(transition, frames)
      fade_to(0, transition, frames)
    end

    # Pan-operation direction (RPG2000: 0 up, 1 right, 2 down, 3 left) -> unit
    # camera delta. A positive x pans the view right, a positive y pans it down.
    PAN_DELTA = { 0 => [0, -1], 1 => [1, 0], 2 => [0, 1], 3 => [-1, 0] }.freeze

    # Pan (scroll) the view `distance` tiles in `direction` at `speed`, adding
    # onto the current pan target — RPG2000's Pan Screen "pan" operation.
    def pan(direction, distance, speed)
      dx, dy = PAN_DELTA[direction] || [0, 0]
      d = distance * Game::TILE
      @pan_tx += dx * d
      @pan_ty += dy * d
      @pan_step = pan_step_for(speed)
    end

    # Scroll the pan back to the hero-centred origin at `speed` (Reset operation).
    def pan_reset(speed)
      @pan_tx = 0
      @pan_ty = 0
      @pan_step = pan_step_for(speed)
    end

    # Freeze / resume the camera following the hero (Lock / Unlock operations).
    def pan_lock; @pan_locked = true; end
    def pan_unlock; @pan_locked = false; end

    # Snap the pan back to the hero-centred origin and release the lock, with no
    # scrolling. RPG2000 does this on every map change: a cutscene that panned
    # the camera (and locked it) must not carry that offset into the map it
    # teleports to, or the new map is drawn from far outside its bounds.
    def pan_clear
      @pan_x = 0
      @pan_y = 0
      @pan_tx = 0
      @pan_ty = 0
      @pan_locked = false
    end

    # Advance every active effect one frame. Called once per frame by the scene.
    def update
      update_tint
      update_shake
      update_flash
      update_pan
      update_fade
    end

    private

    # Start a fade toward `target` (0 visible / 255 black) over `frames` frames.
    # Already at the target -> settle immediately so the command does not wait.
    def fade_to(target, transition, frames)
      @fade_transition = transition
      @fade_target = target
      if frames <= 0 || @fade == target
        @fade = target
        @fade_frames = 0
      else
        @fade_frames = frames
      end
    end

    def update_fade
      return if @fade_frames <= 0
      @fade += (@fade_target - @fade) / @fade_frames
      @fade_frames -= 1
      @fade = @fade_target if @fade_frames.zero? # land exactly on the target
    end

    def update_tint
      return if @frames <= 0
      @r += (@tr - @r) / @frames
      @g += (@tg - @g) / @frames
      @b += (@tb - @b) / @frames
      @sat += (@tsat - @sat) / @frames
      @frames -= 1
      return unless @frames.zero?
      @r = @tr; @g = @tg; @b = @tb; @sat = @tsat # land exactly on the target
    end

    def update_shake
      if @shake_frames <= 0
        @shake_offset = 0
        return
      end
      @shake_frames -= 1
      if @shake_frames <= 0
        @shake_offset = 0 # settle back to centre when the shake ends
        return
      end
      @shake_phase += @shake_speed
      @shake_offset = Screen.triangle_wave(@shake_phase, 16, @shake_power * 2)
    end

    def update_flash
      return if @flash_frames <= 0
      @flash_frames -= 1
      # Strength fades linearly from the peak power to 0 across the duration.
      @flash_strength = @flash_total > 0 ? @flash_power * @flash_frames / @flash_total : 0
    end

    # Step the pan offset toward its target, landing exactly on the last frame.
    def update_pan
      @pan_x = approach(@pan_x, @pan_tx, @pan_step)
      @pan_y = approach(@pan_y, @pan_ty, @pan_step)
    end

    # Move `cur` toward `target` by at most `step` (never overshooting).
    def approach(cur, target, step)
      return target if (target - cur).abs <= step
      cur < target ? cur + step : cur - step
    end

    # Pixels moved per frame for a pan speed (1..6): RPG2000's pan speeds roughly
    # double per step. An approximation — the exact subpixel rate is a native
    # refinement.
    def pan_step_for(speed)
      2**(Game.clamp(speed, 1, 6) - 1)
    end

    # A symmetric triangle wave in [-amp, amp] over `period` phase units (float-
    # free, so it runs on the mruby build without Math). 0 amplitude/period -> 0.
    def self.triangle_wave(phase, period, amp)
      return 0 if amp <= 0 || period <= 0
      half = period / 2
      half = 1 if half <= 0
      p = phase % period
      if p < half
        -amp + (2 * amp * p) / half
      else
        amp - (2 * amp * (p - half)) / half
      end
    end
  end

  # One on-screen picture shown by the Show Picture (11110) event command. Holds
  # its file name, the current visual parameters (centre position, zoom percent,
  # 0..255 opacity and the four RPG2000 tone channels) and, while a Move Picture
  # (11120) is in flight, linearly interpolates every parameter toward its target
  # over the move's duration. Pure data — the owning Scene::Map reads the current
  # values each frame to blit the picture; #update advances the interpolation.
  #
  # Positions are RPG2000 screen coordinates of the picture's *centre*; a picture
  # flagged `fixed_to_map` scrolls with the map (the scene subtracts the camera)
  # rather than staying put on screen. Tone channels are 0..200 (100 neutral);
  # applying them is deferred (needs native tone support), so they are carried
  # but not yet drawn.
  class Picture
    attr_reader :id, :name, :fixed_to_map, :use_transparent_color
    attr_reader :x, :y, :zoom, :opacity, :red, :green, :blue, :saturation

    def initialize(id, opts = {})
      @id = id
      @name = opts[:name] || ''
      @x = opts[:x] || 0
      @y = opts[:y] || 0
      @zoom = opts[:zoom] || 100
      @opacity = opts[:opacity] || 255
      @red = opts[:red] || 100
      @green = opts[:green] || 100
      @blue = opts[:blue] || 100
      @saturation = opts[:saturation] || 100
      @fixed_to_map = opts[:fixed_to_map] ? true : false
      @use_transparent_color = opts[:use_transparent_color] ? true : false
      @frames = 0
    end

    # Begin a move toward new visual parameters over `frames` frames; with
    # frames <= 0 the change applies immediately.
    def move_to(x, y, zoom, opacity, red, green, blue, saturation, frames)
      @tx = x; @ty = y; @tzoom = zoom; @topacity = opacity
      @tred = red; @tgreen = green; @tblue = blue; @tsat = saturation
      @frames = frames > 0 ? frames : 0
      finish_move if @frames == 0
    end

    def moving?; @frames > 0; end

    # Advance one frame of the in-flight move (a no-op when at rest). Every
    # parameter eases a `1/remaining` fraction toward its target, so integer
    # division still lands exactly on the target on the final frame.
    def update
      return unless moving?
      @x = step(@x, @tx); @y = step(@y, @ty)
      @zoom = step(@zoom, @tzoom); @opacity = step(@opacity, @topacity)
      @red = step(@red, @tred); @green = step(@green, @tgreen)
      @blue = step(@blue, @tblue); @saturation = step(@saturation, @tsat)
      @frames -= 1
    end

    private

    def step(cur, target); cur + (target - cur) / @frames; end

    def finish_move
      @x = @tx; @y = @ty; @zoom = @tzoom; @opacity = @topacity
      @red = @tred; @green = @tgreen; @blue = @tblue; @saturation = @tsat
    end
  end

  # The overall running-game state: who is in the party and where they are,
  # plus the global switches and variables.
  # An open shop (Open Shop, 10720). Holds the goods on offer and the buy / sell
  # rules, and performs the transactions against the party's gold and inventory.
  # RPG2000 buys at the item's database price and sells at half of it; the party
  # caps items at 99 and gold at 999999 (Party enforces both). `did_transaction`
  # records whether anything was actually bought or sold, which decides the
  # event's [Transaction] / [No Transaction] branch. The scene drives the UI and
  # calls #buy / #sell one unit at a time.
  class Shop
    attr_reader :goods, :did_transaction

    def initialize(db, party, goods, allow_buy, allow_sell)
      @db = db
      @party = party
      @goods = (goods || []).select { |id| id && id > 0 }
      @allow_buy = allow_buy
      @allow_sell = allow_sell
      @did_transaction = false
    end

    def allow_buy?;  @allow_buy;  end
    def allow_sell?; @allow_sell; end

    # Database price of item `id` (0 when the item is missing or free).
    def price(id)
      it = @db.item[id]
      it ? (it.price || 0) : 0
    end

    # Display name of item `id` ('' when missing).
    def name(id)
      it = @db.item[id]
      it ? it.name.to_s : ''
    end

    # Half the database price — what a sale returns (RPG2000 rounds down).
    def sell_price(id); price(id) / 2; end

    # Whether item `id` can be sold: the party owns at least one and it has a
    # non-zero price (RPG2000 marks price-0 / key items as unsellable).
    def sellable?(id); price(id) > 0 && @party.item_count(id) > 0; end

    # The party's sellable items, id-ordered, for the sell list.
    def sellable_items
      @party.items.keys.select { |id| sellable?(id) }.sort
    end

    # Buy one unit of `id`: must be stocked, buying allowed, affordable and not
    # already capped at 99. Returns whether the purchase happened.
    def buy(id)
      return false unless @allow_buy && @goods.include?(id)
      cost = price(id)
      return false if @party.gold < cost || @party.item_count(id) >= 99
      @party.gain_gold(-cost)
      @party.gain_item(id, 1)
      @did_transaction = true
      true
    end

    # Sell one unit of `id` at half price: must be allowed and sellable. Returns
    # whether the sale happened.
    def sell(id)
      return false unless @allow_sell && sellable?(id)
      @party.gain_gold(sell_price(id))
      @party.gain_item(id, -1)
      @did_transaction = true
      true
    end
  end

  # A single enemy instantiated from the database (chunk 14) for a battle: its
  # combat stats plus the EXP / gold it is worth and its battle-screen position.
  # Current HP / SP start full. The turn-based battle that would reduce them is
  # not built yet, so for now this backs the Enemy Encounter reward model.
  class Enemy
    attr_reader :id, :name, :max_hp, :max_sp, :atk, :def, :spi, :agi,
                :exp, :gold, :x, :y, :hidden
    attr_accessor :hp, :sp

    def initialize(db, id, x = 0, y = 0, hidden = false)
      row = db.enemy[id]
      @id = id
      @name    = row ? row.name.to_s : ''
      @max_hp  = row ? row.max_hp : 1
      @max_sp  = row ? row.max_sp : 0
      @atk     = row ? row.attack : 0
      @def     = row ? row.defense : 0
      @spi     = row ? row.spirit : 0
      @agi     = row ? row.agility : 0
      @exp     = row ? row.exp : 0
      @gold    = row ? row.gold : 0
      @x = x
      @y = y
      @hidden = hidden ? true : false
      @hp = @max_hp
      @sp = @max_sp
    end

    def dead?; @hp <= 0; end
  end

  # An enemy troop (敵グループ, chunk 15) instantiated for a battle: the live
  # Enemy members at their positions. Also totals the EXP / gold the troop is
  # worth, which the Enemy Encounter command grants on victory. The battle
  # simulation itself is still to come.
  class Troop
    attr_reader :id, :name, :members

    def initialize(db, id)
      row = db.enemy_group[id]
      @id = id
      @name = row ? row.name.to_s : ''
      @members = []
      # Array2D#each yields (id, entry); a plain Hash test double does the same.
      row.members.each { |_, m| @members << member(db, m) } if row && row.members
    end

    def total_exp;  @members.reduce(0) { |s, e| s + e.exp } end
    def total_gold; @members.reduce(0) { |s, e| s + e.gold } end

    private

    def member(db, m)
      Enemy.new(db, m.enemy_id, m.x, m.y, m.invisible)
    end
  end

  # A turn-stepped auto-battle that decides an Enemy Encounter by the combatants'
  # stats. Battlers act in agility order (highest first); each attacks a random
  # living opponent for `attack_damage`, and the fight resolves to :victory when
  # every enemy is down or :defeat when the whole party is. `#step` performs one
  # action at a time and appends a `#log` entry, so an on-screen battle can
  # animate it action-by-action; `#run` steps to completion for a headless
  # resolution. It works on Combatant snapshots, so the caller can resolve a
  # battle without mutating the real party. This is a deliberately simple first
  # cut — no skills, items, criticals, attributes, damage variance or escape yet
  # — the turn-based battle *screen* and those refinements are still to come.
  class Battle
    # A battler reduced to what the fight needs. Snapshotting Game::Actor /
    # Game::Enemy keeps the real party untouched by a resolved battle.
    # `action` is the ally's chosen attack target for the round (nil = none /
    # auto), `defending` halves damage taken that round, and `command` is a
    # queued Skill / Item action (see Battle#apply_command); all three are
    # cleared each round. Enemies leave them nil and attack a random party
    # member. `mp` / `max_mp` carry SP (skills spend it) and `spi` is the spirit
    # stat the skill formulas read as `int`.
    Combatant = Struct.new(:name, :atk, :def, :agi, :hp, :max_hp,
                           :action, :defending, :mp, :max_mp, :spi, :command) do
      def dead?; hp <= 0; end
      # Spirit under the name Game::Party's skill formulas (#skill_effect,
      # #skill_cost) read on a caster.
      def int; spi; end
    end

    def self.from_actor(a)
      Combatant.new(a.name, a.atk, a.def, a.agi, a.hp, a.max_hp,
                    nil, false, a.mp, a.max_mp, a.int, nil)
    end

    def self.from_enemy(e)
      Combatant.new(e.name, e.atk, e.def, e.agi, e.hp, e.max_hp,
                    nil, false, e.sp, e.max_sp, e.spi, nil)
    end

    # RPG2000-style physical damage: half the attacker's attack less a quarter of
    # the defender's defence, floored at 1 so a fight always terminates.
    def self.attack_damage(atk, dfn)
      d = atk / 2 - dfn / 4
      d < 1 ? 1 : d
    end

    MAX_ROUNDS = 1000 # safety net against a stalemate (should never be reached)

    attr_reader :allies, :enemies, :rounds, :result, :log

    def initialize(allies, enemies, rng = nil)
      @allies = allies
      @enemies = enemies
      @rng = rng || Rng.new(0x2000)
      @rounds = 0
      @result = nil
      @log = []      # one entry per landed attack, in order (see #strike)
      @queue = []    # battlers still to act this round, in agility order
    end

    # True once one side has been wiped out (the battle is decided).
    def finished?; !alive?(@allies) || !alive?(@enemies); end

    # Perform the next single action and return its log entry, or nil when the
    # battle is already decided (or has hit the round cap). Living battlers act
    # in agility order; a new round refills the queue.
    def step
      loop do
        return nil if finished?
        refill_queue if @queue.empty?
        return nil if @queue.empty? # hit MAX_ROUNDS
        b = @queue.shift
        next if b.dead?
        entry = strike(b)
        next unless entry # attacker had no living target; try the next
        @log << entry
        return entry
      end
    end

    # Step the fight to completion and return :victory or :defeat.
    def run
      step until finished? || @rounds > MAX_ROUNDS
      @result = alive?(@allies) ? :victory : :defeat
    end

    # Assign an ally's action for the coming round: attack `target`, or defend
    # (take half damage and not attack). Player-driven battles command each ally
    # before running the round; enemies choose their own action.
    def command_attack(ally, target)
      ally.action = target; ally.defending = false; ally.command = nil
    end

    def command_defend(ally)
      ally.action = nil; ally.defending = true; ally.command = nil
    end

    # Queue a single-target Skill for `ally`: cast on `target` (an enemy for an
    # attack skill, an ally / the caster for a recovery skill), spending `cost`
    # SP and applying the signed HP / SP deltas (negative HP = damage, positive =
    # recovery) computed by Game::Party#battle_skill_command. Resolved in agility
    # order by #apply_command when the round runs.
    def command_skill(ally, target, name:, cost:, hp: 0, mp: 0)
      ally.command = { kind: :skill, target: target, name: name,
                       cost: cost, hp: hp, mp: mp }
      ally.action = nil; ally.defending = false
    end

    # Queue a single-target Item for `ally` on `target`: restore the HP / SP from
    # Game::Party#battle_item_command. `item_id` rides along on the log entry so
    # the scene consumes one from the bag when the action lands.
    def command_item(ally, target, item_id:, name:, hp: 0, mp: 0)
      ally.command = { kind: :item, target: target, item_id: item_id,
                       name: name, hp: hp, mp: mp }
      ally.action = nil; ally.defending = false
    end

    # Execute one full round — living battlers act in agility order, allies using
    # their assigned action, enemies attacking a random party member — and return
    # the round's log entries. Ally commands are cleared afterwards for the next
    # round. `finished?` / `result` report the outcome once a side is wiped.
    def run_round
      begin_round
      entries = []
      while (entry = step_action)
        entries << entry
      end
      end_round
      entries
    end

    # Prime the agility-ordered queue for a fresh round so #step_action can walk
    # it one action at a time — the on-screen battle animates a round action by
    # action rather than applying it all at once (#run_round is just this three-
    # step sequence run to completion). Counts towards the MAX_ROUNDS cap.
    def begin_round
      refill_queue
    end

    # Perform the next single action of the round primed by #begin_round and
    # return its log entry, skipping battlers that are dead or (allies) defending.
    # Returns nil once the round's queue is exhausted or the battle is decided —
    # the caller then clears commands with #end_round and either shows the result
    # or asks for the next round. Unlike #step it never starts a new round.
    def step_action
      loop do
        return nil if finished? || @queue.empty?
        b = @queue.shift
        next if b.dead?
        entry = strike(b)
        next unless entry
        @log << entry
        return entry
      end
    end

    # Close a round begun with #begin_round: clear each ally's chosen action (so
    # the next round starts fresh) and settle the result once a side is wiped.
    def end_round
      @allies.each { |a| a.action = nil; a.defending = false; a.command = nil }
      @result = alive?(@allies) ? :victory : :defeat if finished?
    end

    private

    def alive?(side); side.any? { |b| !b.dead? }; end

    def refill_queue
      @rounds += 1
      @queue = turn_order unless @rounds > MAX_ROUNDS
    end

    # Battlers ordered by agility (highest first); ties keep their listed order.
    def turn_order
      (@allies + @enemies).each_with_index
                          .sort_by { |b, i| [-b.agi, i] }.map { |b, _| b }
    end

    # `b` attacks its target, returning a log entry (or nil when it defends or
    # has no living target). A defending target takes half damage (min 1). An
    # ally with a queued Skill / Item command resolves that instead.
    def strike(b)
      return apply_command(b) if b.command
      return nil if side_of(b) == :ally && b.defending # defending = no attack
      target = attack_target(b)
      return nil unless target
      dmg = Battle.attack_damage(b.atk, target.def)
      dmg = [dmg / 2, 1].max if target.defending
      target.hp -= dmg
      { attacker: b.name, target: target.name, damage: dmg,
        target_hp: target.hp < 0 ? 0 : target.hp, defeated: target.dead? }
    end

    # The living target `b` attacks: an ally uses its chosen target while it
    # lives, otherwise a random living foe; enemies always pick a random party
    # member.
    def attack_target(b)
      if side_of(b) == :ally && b.action && !b.action.dead?
        return b.action
      end
      foes = (side_of(b) == :ally ? @enemies : @allies).reject(&:dead?)
      foes.empty? ? nil : foes[@rng.random(foes.size)]
    end

    def side_of(b); @allies.any? { |a| a.equal?(b) } ? :ally : :enemy; end

    # Resolve `b`'s queued Skill / Item command and return its log entry, or nil
    # when the chosen target has already fallen this round (the action fizzles —
    # no SP is spent and nothing animates). A skill first spends the caster's SP;
    # then a negative-HP command (an attack skill) subtracts HP and reads like an
    # attack (`skill:` names it), while a recovery command (heal skill / medicine)
    # restores HP / SP clamped to the target's maxima and reads as a `recover`.
    def apply_command(b)
      cmd = b.command
      target = cmd[:target]
      return nil if target.nil? || target.dead?
      b.mp = [b.mp - cmd[:cost], 0].max if cmd[:cost] && cmd[:cost] > 0
      hp = cmd[:hp] || 0
      mp = cmd[:mp] || 0
      if hp < 0
        dmg = -hp
        target.hp -= dmg
        { attacker: b.name, target: target.name, damage: dmg,
          target_hp: target.hp < 0 ? 0 : target.hp, defeated: target.dead?,
          skill: cmd[:name] }
      else
        before_hp = target.hp
        before_mp = target.mp || 0
        target.hp = [target.hp + hp, target.max_hp].min if hp > 0
        target.mp = [before_mp + mp, target.max_mp].min if mp > 0 && target.max_mp
        { recover: true, actor: b.name, source: cmd[:name],
          item_id: cmd[:item_id], target: target.name,
          recover_hp: target.hp - before_hp, recover_mp: (target.mp || 0) - before_mp,
          target_hp: target.hp, target_mp: target.mp }
      end
    end
  end

  # Map weather set by the Weather Effects (11070) event command: a type (0 none,
  # 1 rain, 2 snow; the RPG2003 additions store as higher values) and a strength
  # (0 weak .. 2 strong). Like the picture / tint overlays this is the Ruby-half
  # model only — drawing the rain/snow particles is native renderer work still to
  # come — but it round-trips through the save so a reloaded game keeps its
  # weather.
  class Weather
    attr_reader :type, :strength

    def initialize(type = 0, strength = 0)
      @type = type
      @strength = strength
    end

    def set(type, strength)
      @type = type
      @strength = strength
    end

    # Whether no weather is active (type 0).
    def none?; @type == 0; end

    def to_h; { type: @type, strength: @strength }; end

    def load_h(h)
      return unless h
      @type = h[:type] || 0
      @strength = h[:strength] || 0
    end
  end

  class State
    attr_reader :party, :switches, :variables, :message_config, :screen, :weather
    attr_accessor :map, :map_id, :x, :y, :direction, :timer_frames, :timer_running
    # Whether the player may open the main menu / save, toggled by the Change
    # Main Menu Access (11960) and Change Save Access (11930) event commands;
    # both default on and are persisted in the save.
    attr_accessor :menu_access, :save_access
    # Whether the Teleport and Escape skills are usable, toggled by the Change
    # Teleport Access (11820) and Change Escape Access (11840) event commands.
    # Default off — RPG2000 games enable these once the skill's targets are set —
    # and persisted in the save. (The skills themselves are not executed yet, so
    # these gate nothing at runtime; they are modelled for save fidelity.)
    attr_accessor :teleport_access, :escape_access
    # The BGM currently playing and the one stashed by Memorize BGM (11530),
    # each nil or a `{ name:, volume:, tempo: }` hash. Play Memorized BGM (11540)
    # restores the stash. Persisted in the save so the memory survives a reload.
    attr_accessor :current_bgm, :memorized_bgm
    # Whether the party leader's map sprite is hidden, toggled by the Set
    # Transparent Flag / Change Player Visibility (11310) event command. Defaults
    # off (the hero is shown) and is persisted in the save.
    attr_accessor :player_transparent
    # Random-encounter step rate set by Change Encounter Rate (11740); nil until
    # a command overrides it (the map's own rate then applies). No encounter
    # subsystem consumes it yet — kept for save fidelity.
    attr_accessor :encounter_rate
    # Teleport / Escape skill destinations registered by Set Teleport Target
    # (11810) and Set Escape Target (11830). `teleport_targets` is a hash keyed
    # by map id → `{ x:, y:, switch_id: }`; `escape_target` is nil or one such
    # hash (with `map_id:`). The skills are not executed yet, so these are
    # modelled for save fidelity only, like the teleport / escape access flags.
    attr_accessor :teleport_targets, :escape_target
    # System music / sound overrides from Change System BGM (10660) and Change
    # System SFX (10670), each a hash keyed by context slot → an audio hash. The
    # battle / menu scenes that would play them are not built yet; stored for
    # save fidelity.
    attr_accessor :system_bgm, :system_sfx

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
      @message_config = MessageConfig.new
      @menu_access = true
      @save_access = true
      @teleport_access = false
      @escape_access = false
      @current_bgm = nil
      @memorized_bgm = nil
      @player_transparent = false
      @encounter_rate = nil
      @teleport_targets = {}
      @escape_target = nil
      @system_bgm = {}
      @system_sfx = {}
      @weather = Weather.new
      # Transient screen-effect state (tint transition); not serialised, so a
      # reloaded game starts with a neutral screen.
      @screen = Screen.new
      # Shown pictures, id => Game::Picture. Transient like @screen (RPG2000's
      # HUD pictures are re-shown by parallel events on load), so not serialised.
      @pictures = {}
    end

    attr_reader :pictures

    # Show (or replace) picture `id` with the given Picture options hash.
    def show_picture(id, opts)
      @pictures[id] = Picture.new(id, opts) if id && id > 0
    end

    # Start a move on picture `id` (a no-op if it is not shown). `args` are the
    # Picture#move_to arguments (x, y, zoom, opacity, r, g, b, s, frames).
    def move_picture(id, *args)
      pic = @pictures[id]
      pic.move_to(*args) if pic
    end

    def erase_picture(id); @pictures.delete(id); end

    # Drop every shown picture. RPG2000 does this on every map change, so a
    # cutscene's pictures never survive into the map it teleports to.
    def erase_all_pictures; @pictures = {}; end

    # Advance every shown picture's in-flight move one frame.
    def update_pictures; @pictures.each_value(&:update); end

    # Whether any picture is still interpolating a move (for the Move Picture
    # "wait until done" flag).
    def pictures_moving?; @pictures.values.any?(&:moving?); end

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
        timer_running: @timer_running, message_config: @message_config.to_h,
        menu_access: @menu_access, save_access: @save_access,
        current_bgm: @current_bgm, memorized_bgm: @memorized_bgm,
        player_transparent: @player_transparent, weather: @weather.to_h,
        teleport_access: @teleport_access, escape_access: @escape_access,
        encounter_rate: @encounter_rate, teleport_targets: @teleport_targets,
        escape_target: @escape_target, system_bgm: @system_bgm,
        system_sfx: @system_sfx }
    end

    # Serialise to a genuine RPG2000/2003 Save<N>.lsd (an LCF::SaveData) -- the
    # inverse of .from_lsd. It writes the chunks that path reads back:
    #
    #   * title (100): the save-select metadata -- a timestamp (a :double, hence
    #     the pack_double encoder) and the leader's name / level / current HP plus
    #     each party member's FaceSet, so real RPG_RT/EasyRPG tooling shows the
    #     party on the file screen;
    #   * system (101): switches, variables, save_count, the message-window
    #     configuration (position / transparency / face), the current and
    #     memorised BGM, the player-transparent flag and the
    #     menu/save/teleport/escape access flags;
    #   * hero (104): map position, facing and the leader's on-map CharSet (so a
    #     Change Sprite override survives);
    #   * actors (108): the per-actor level/exp/equipment/skills/HP/MP table;
    #   * inventory (109): the party roster / gold / item bag.
    #
    # Switch and variable ids are 1-indexed in-game but 0-indexed in the save, so
    # they shift down by one; unset entries default to false / 0. +save_count+
    # goes in the system chunk (RPG_RT increments it on every save); +timestamp+
    # is the OLE-automation date shown on the file screen, defaulting to now.
    #
    # That default used to be 0.0, and it is why the genuine RPG_RT refused to
    # load anything this wrote: a zero date is 1899-12-30, which RPG_RT reads as
    # an empty slot, so "Continue" stayed dead with no error at all. It was
    # found by stripping a real save down to exactly the chunks written here
    # (it still loaded, so nothing was missing), then swapping in one of ours at
    # a time until only the title chunk failed, then one field at a time within
    # it. See ADR 0021.
    #
    # The only live-state fields still dropped versus #to_h are the game timer
    # (which liblcf's SaveSystem has no field for) and per-actor name/title
    # overrides for non-leader members, so this is now a near-parity export.
    def to_lsd(save_count = 1, timestamp = nil)
      timestamp = State.ole_now if timestamp.nil?
      save = LCF::SaveData.new

      leader = @party.leader
      members = @party.actors
      if leader
        title = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TITLE })
        title[1] = timestamp.to_f
        title[11] = leader.name
        title[12] = leader.level
        title[13] = leader.hp
        # Up to four party faces fill the file-screen portrait slots (21/22 ..
        # 27/28), one FaceSet name+index pair per member.
        face_fields = [[21, 22], [23, 24], [25, 26], [27, 28]]
        members.each_index do |i|
          break if i >= face_fields.size
          nf, xf = face_fields[i]
          title[nf] = members[i].faceset_name
          title[xf] = members[i].faceset_index
        end
        save[100] = title
      end

      hero = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
      hero[11] = @map_id
      hero[12] = @x
      hero[13] = @y
      hero[22] = @direction || 2
      if leader
        hero[73] = leader.charset_name || ''
        hero[75] = leader.charset_index || 0
      end
      save[104] = hero

      sys = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_SYSTEM })
      sw = @switches.to_h
      sw_max = sw.empty? ? 0 : sw.keys.max
      switches = Array.new(sw_max, false)
      sw.each { |id, v| switches[id - 1] = v ? true : false }
      sys[31] = sw_max
      sys[32] = switches
      vr = @variables.to_h
      vr_max = vr.empty? ? 0 : vr.keys.max
      variables = Array.new(vr_max, 0)
      vr.each { |id, v| variables[id - 1] = v }
      sys[33] = vr_max
      sys[34] = variables
      # Message-window configuration (field 41 transparency is 0/1, 43 is the
      # inverse of our "pinned" flag: prevent-overlap true == not position_fixed,
      # 53 face side is 0 left / 1 right).
      mc = @message_config
      sys[41] = mc.transparent ? 1 : 0
      sys[42] = mc.position
      sys[43] = mc.position_fixed ? false : true
      sys[44] = mc.continue_events ? true : false
      sys[51] = mc.face_name || ''
      sys[52] = mc.face_index || 0
      sys[53] = mc.face_right ? 1 : 0
      sys[54] = mc.face_flipped ? true : false
      sys[55] = @player_transparent ? true : false
      sys[75] = bgm_chunk(@current_bgm) if @current_bgm
      sys[78] = bgm_chunk(@memorized_bgm) if @memorized_bgm
      sys[121] = @teleport_access ? true : false
      sys[122] = @escape_access ? true : false
      sys[123] = @save_access ? true : false
      sys[124] = @menu_access ? true : false
      sys[131] = save_count
      sys[132] = 1
      save[101] = sys

      actors = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_PARTY_ACTOR })
      @party.actors.each do |a|
        e = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_PARTY_ACTOR })
        e[31] = a.level
        e[32] = a.exp
        e[51] = a.skills.size
        e[52] = a.skills
        e[61] = a.equipment
        e[71] = a.hp
        e[72] = a.mp
        actors[a.id] = e
      end
      save[108] = actors

      inv = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_INVENTORY })
      inv[1] = @party.actors.map { |a| a.id }
      item_ids = @party.items.keys.sort
      inv[11] = item_ids.size
      inv[12] = item_ids
      inv[13] = item_ids.map { |i| @party.items[i] }
      inv[21] = @party.gold
      save[109] = inv

      save
    end

    # Build a BGM chunk (an LCF::Array1D over the BGM schema) from our stored
    # `{ name:, volume:, tempo: }` hash: file (1), volume (3) and pitch (4). Used
    # for the system chunk's current-BGM (75) and stored-BGM (78) slots.
    def bgm_chunk(bgm)
      b = LCF::Array1D.new('', { elements: LCF::Schema::BGM })
      b[1] = bgm[:name] || ''
      b[3] = bgm[:volume] || 100
      b[4] = bgm[:tempo] || 100
      b
    end

    # Rebuild a State from a parsed LCF::SaveData -- a real Save<N>.lsd written
    # by an actual editor, rather than our own Marshal hash. The modelled fields
    # are restored: the hero's map / tile position / facing and the leader's
    # on-map CharSet (chunk 104), the party roster / gold / items (inventory,
    # chunk 109), the per-actor level/exp/HP/MP/equipment/skills table (chunk
    # 108), the switches and variables plus the message-window configuration, the
    # current / memorised BGM, the player-transparent flag and the access flags
    # (system, chunk 101), and the leader's display name (title, chunk 100).
    # Switches and variables are 0-indexed arrays in the save but 1-indexed
    # in-game, so they shift by one. `save[101]` / `save[100]` are used instead of
    # `save.system` / `save.title` because the former collides with Kernel#system
    # under CRuby (where the loaders are unit-tested) and the latter is kept
    # parallel to it.
    def self.from_lsd(db, save)
      hero = save.hero
      inv = save.inventory
      roster = inv.party || []
      party = Party.new(db, roster)
      items = {}
      ids = inv.item_ids || []
      counts = inv.item_counts || []
      ids.each_index { |i| items[ids[i]] = counts[i] || 0 }
      # Per-actor state comes from the SAVE_PARTY_ACTOR table (chunk 108), keyed
      # by actor id. Restore each roster member's saved level (which rescales its
      # base stats) and exp first, then its current HP/SP, so Continue resumes a
      # levelled, wounded party rather than a fresh full-health one.
      hp = {}
      mp = {}
      (save[108] || []).each do |aid, sa|
        next unless roster.include?(aid)
        actor = party.actor_by_id(aid)
        if actor
          actor.set_level(sa.level) if sa.level
          actor.exp = sa.exp if sa.exp
          actor.equip(sa.equipment) if sa.equipment
          actor.skills = sa.skills if sa.skills
        end
        hp[aid] = sa.hp if sa.hp
        mp[aid] = sa.mp if sa.mp
      end
      party.load_state(items: items, gold: inv.gold, hp: hp, mp: mp)
      state = new(party, hero.map_id, hero.x, hero.y)
      state.direction = hero.direction || 2
      # The leader's on-map sprite override (a Change Sprite Association), stored
      # in the hero chunk's CharSet fields.
      if party.leader && hero.charset_name && !hero.charset_name.empty?
        party.leader.set_charset(hero.charset_name, hero.charset_index || 0)
      end
      sys = save[101]
      switches = {}
      (sys.switches || []).each_with_index { |v, i| switches[i + 1] = v if v }
      state.switches.replace(switches)
      variables = {}
      (sys.variables || []).each_with_index { |v, i| variables[i + 1] = v unless v == 0 }
      state.variables.replace(variables)
      # Message-window configuration (inverse of the mapping #to_lsd writes).
      mc = state.message_config
      mc.transparent = (sys.message_transparent || 0) != 0
      mc.position = sys.message_position || MessageConfig::POS_BOTTOM
      mc.position_fixed = sys.message_prevent_overlap ? false : true
      mc.continue_events = sys.message_continue_events ? true : false
      mc.face_name = sys.face_name || ''
      mc.face_index = sys.face_index || 0
      mc.face_right = (sys.face_right_position || 0) != 0
      mc.face_flipped = sys.face_flip ? true : false
      state.player_transparent = sys.transparent ? true : false
      # Overridden BGM playback state; an empty file name means "none".
      state.current_bgm = bgm_from_chunk(sys.current_bgm)
      state.memorized_bgm = bgm_from_chunk(sys.stored_bgm)
      # Access flags: only an explicitly-stored value overrides the constructor
      # default (so a foreign save that omits them keeps our defaults).
      state.teleport_access = sys.teleport_allowed unless sys.teleport_allowed.nil?
      state.escape_access = sys.escape_allowed unless sys.escape_allowed.nil?
      state.save_access = sys.save_allowed unless sys.save_allowed.nil?
      state.menu_access = sys.menu_allowed unless sys.menu_allowed.nil?
      # The leader's display name from the file-screen title chunk (a Change
      # Actor Name override survives for the leader).
      title = save[100]
      if title && party.leader
        nm = title.hero_name
        party.leader.name = nm if nm && !nm.empty?
      end
      restore_pictures(state, save[103])
      state
    end

    # Re-show the pictures the save was holding (chunk 103, one entry per picture
    # number). Only entries with a file name are live; the rest are the empty
    # slots RPG2000 always writes out.
    #
    # These used to be dropped, on the reasoning that a game's HUD pictures are
    # re-shown by parallel events right after a load. That is true of a HUD and
    # false of a save taken mid-cutscene, where the event that showed the picture
    # has already run and will not run again: resuming Nepheshel's opening, the
    # genuine RPG_RT drew the backdrop and we drew black. See ADR 0021.
    #
    # Only the fields the save actually pins down are restored -- the file name
    # and the centre position. Zoom, opacity and tone have their own save fields,
    # but this build has never had a sample where they are not at their defaults,
    # so reading them would be guesswork; they take Picture's defaults instead.
    def self.restore_pictures(state, pictures)
      return unless pictures
      pictures.each do |id, pic|
        next unless pic
        name = pic.name
        next if name.nil? || name.empty?
        state.show_picture(id, name: name,
                               x: (pic.current_x || 0).to_i,
                               y: (pic.current_y || 0).to_i)
      end
    end

    # Days from the OLE-automation epoch (1899-12-30) to the Unix epoch. RPG_RT
    # stores a save's date as days-since-1899-12-30 in a double, the fraction
    # being the time of day.
    OLE_EPOCH_OFFSET = 25569

    # A save date RPG_RT will accept, as of now. It must be non-zero: RPG_RT
    # treats a zero date as an empty file slot and will not offer the save (see
    # #to_lsd). Falls back to a fixed, plainly-synthetic date if this build has
    # no clock, since any valid date beats the one value that breaks loading.
    #
    # 2000-01-01, the sentinel: recognisable in a file screen as "not a real
    # play session" without being a value RPG_RT rejects.
    NO_CLOCK_TIMESTAMP = 36526.0

    def self.ole_now
      Time.now.to_i / 86400.0 + OLE_EPOCH_OFFSET
    rescue StandardError
      NO_CLOCK_TIMESTAMP
    end

    # Rebuild our `{ name:, volume:, tempo: }` BGM hash from a parsed BGM chunk
    # (an LCF::Array1D over the BGM schema). Returns nil for an absent chunk or an
    # empty file name (the "use the database value" sentinel).
    def self.bgm_from_chunk(chunk)
      return nil unless chunk
      name = chunk.file
      return nil if name.nil? || name.empty?
      { name: name, volume: chunk.volume || 100, tempo: chunk.pitch || 100 }
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
      state.message_config.load_h(h[:message_config])
      # Access flags default on; only an explicit stored value overrides them
      # (so a save written before these existed keeps the menu/save enabled).
      state.menu_access = h[:menu_access] unless h[:menu_access].nil?
      state.save_access = h[:save_access] unless h[:save_access].nil?
      state.current_bgm = h[:current_bgm]
      state.memorized_bgm = h[:memorized_bgm]
      state.player_transparent = h[:player_transparent] ? true : false
      state.weather.load_h(h[:weather])
      state.teleport_access = h[:teleport_access] ? true : false
      state.escape_access = h[:escape_access] ? true : false
      # Registries default empty / unset; a save written before these existed
      # simply restores nothing.
      state.encounter_rate = h[:encounter_rate]
      state.teleport_targets = h[:teleport_targets] || {}
      state.escape_target = h[:escape_target]
      state.system_bgm = h[:system_bgm] || {}
      state.system_sfx = h[:system_sfx] || {}
      state
    end
  end
end
