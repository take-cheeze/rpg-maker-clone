# In-memory game state built from the parsed LCF database and map data.
#
# These classes deliberately hold only plain data derived from LCF::Database /
# LCF::MapUnit; nothing here touches RGSS or draws to the screen. That keeps the
# "New Game" logic (building a party and locating the start map) independent of
# the not-yet-implemented map renderer, and unit-testable on its own.
module Game
  TILE = 16 # tile size in pixels
  # Denominator a critical-hit chance is expressed over -- basis points, so
  # 10000 is certainty and an actor's 1/30 row rate is 333. RPG_RT adds a
  # weapon's own percentage to the wielder's rate, which a 1-in-N denominator
  # cannot express, so the chance is carried as a probability and the whole
  # damage path stays on integer arithmetic. See Actor#crit_chance.
  CRIT_SCALE = 10_000
  # ... and what one percentage point of it is worth.
  CRIT_PERCENT = CRIT_SCALE / 100
  # The RPG2000 screen, in pixels. `RPG2k::WIDTH`/`HEIGHT` are the same numbers
  # on the scene side; the pure-logic half needs them for the screen-transition
  # geometry, which cannot reach the scene.
  SCREEN_W = 320
  SCREEN_H = 240

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

    # How many pixel rows at the **bottom** of a character frame a tile of the
    # given terrain `bush_depth` sinks into (RPG2000's 下半身消去 / 半透明表示 —
    # the tall grass or shallow water a character wades through).
    #
    # RPG_RT expresses it as a divisor rather than a fraction: `4 - depth`, and
    # a divisor above 3 means no effect at all, so only depths 1..3 do anything
    # (EasyRPG's `Sprite_Character::Draw`). On the standard 32px frame that is
    # 10, 16 and 32 rows — which is exactly what Nepheshel's own terrain names
    # promise: 下半身3/1消去 ("erase the lower 1/3") is depth 1, 下半身2/1消去
    # ("the lower 1/2") is depth 2, and 全身半透明 ("the whole body") is depth 3.
    def self.bush_pixels(depth, height = HEIGHT)
      return 0 if depth.nil?
      split = 4 - depth
      return 0 if split > 3 || split <= 0
      height / split
    end

    # The opacity those sunken rows draw at: half, rounded up, of whatever the
    # character was already being drawn with (RPG_RT's `opacity_bottom` default
    # of `(opacity_top + 1) / 2`), so a translucent event wading through grass
    # ends up fainter still rather than snapping back to a fixed 128.
    def self.bush_opacity(opacity = 255)
      (opacity + 1) / 2
    end
  end

  # Expansion of RPG2000 message control codes. `\v[n]` inserts variable n,
  # `\n[n]` the name of actor n, `\\` a literal backslash, `\_` a space; `\c[n]`
  # changes colour. The pacing codes `\.`/`\|`/`\!` (waits), `\^` (auto-close),
  # `\>`/`\<` (instant span) and `\$` (show the gold window) are surfaced by #scan
  # for the scene to act on; the remaining display code (`\s` speed) is dropped.
  # `names` may be a Hash or any object responding to `[]`.
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
    # backslash and `\_` a space; the pacing / display codes (`\s` speed,
    # `\.`/`\|`/`\!` waits, `\>`/`\<`, `\^`, `\$`) produce no characters here (see
    # #scan for the pacing ones). Runs with no text (e.g. a colour change before
    # any character) are omitted, so a line that renders nothing yields an empty
    # array.
    def self.parse(text, variables, names)
      scan(text, variables, names)[:segments]
    end

    # One pass over a message line, returning both its colour `:segments` (as
    # #parse) and the pacing control codes found, positioned in *revealed-
    # character* coordinates so the typewriter can act on them:
    #   :pauses  — [{ at:, kind: }] for `\!` (:key, wait for a button), `\.`
    #              (:quarter) and `\|` (:full) timed holds;
    #   :auto_close — `\^` (close the window without a keypress once revealed);
    #   :instants — [[start, end)] spans that reveal at once (`\>` … `\<`);
    #   :show_gold — `\$` (show the party's gold in a small window);
    #   :length  — the visible character count (what the reveal counts);
    #   :end_color — the colour still in effect once the line ends, for a
    #                caller that wants to carry it into the next scan (a Show
    #                Choices list merged onto a preceding Show Text, e.g. —
    #                see Scene::Map#append_choice_lines — inherits the text's
    #                trailing colour, yado.tk). `start_color` seeds the run in
    #                effect from the very first character.
    def self.scan(text, variables, names, start_color = 0)
      segs = []
      pauses = []
      instants = []
      instant_start = nil # character index where an open `\>` span began
      auto_close = false
      show_gold = false
      cur = ''
      color = start_color
      count = 0 # visible characters emitted so far (pause positions index this)
      i = 0
      n = text.nil? ? 0 : text.length
      while i < n
        ch = text[i]
        if ch == "\\" && i + 1 < n
          code = text[i + 1]
          i += 2
          arg, i = read_bracket(text, i)
          case code
          when 'v', 'V' then (s = variables[resolve_arg(arg, variables)].to_s; cur << s; count += s.length) if arg
          when 'n', 'N' then (s = (names[resolve_arg(arg, variables)] || '').to_s; cur << s; count += s.length) if arg
          when "\\"     then cur << "\\"; count += 1
          when '_'      then cur << ' '; count += 1 # half-width space
          when 'c', 'C' # colour change: close the current run, switch colour
            segs << { text: cur, color: color } unless cur.empty?
            cur = ''
            color = arg ? arg.to_i : 0
          when '.'      then pauses << { at: count, kind: :quarter }
          when '|'      then pauses << { at: count, kind: :full }
          when '!'      then pauses << { at: count, kind: :key }
          # `\^`, `\$` and the closing `\<` render nothing but still burn one
          # tick of display time, same as a revealed character would (yado.tk);
          # `\>` (span open) stays free, as does `\c[]`/`\s[]`.
          when '^'      then auto_close = true; count += 1
          when '$'      then show_gold = true; count += 1 # show the gold window
          when '>'      then instant_start = count if instant_start.nil?
          when '<'
            if instant_start
              instants << [instant_start, count]
              instant_start = nil
              count += 1
            end
          # the remaining display code (`\s` speed) produces no characters and no
          # pacing here: dropped.
          end
        else
          cur << ch
          count += 1
          i += 1
        end
      end
      segs << { text: cur, color: color } unless cur.empty?
      instants << [instant_start, count] if instant_start # unclosed `\>` runs to EOL
      { segments: segs, pauses: pauses, auto_close: auto_close,
        instants: instants, show_gold: show_gold, length: count,
        end_color: color }
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
    # Brackets nest (yado.tk: `\N[]`/`\V[]` accept a `\V[n]` argument in place
    # of a literal number, e.g. `\N[\V[1]]`), so an inner `[`/`]` pair widens
    # the scan rather than closing it early -- otherwise `\N[\V[1]]` would read
    # its argument as only `\V[1` (stopping at the *inner* `]`) and leave the
    # outer `]` behind as stray literal text.
    def self.read_bracket(text, i)
      return [nil, i] unless i < text.length && text[i] == '['
      j = i + 1
      depth = 1
      while j < text.length && depth > 0
        depth += 1 if text[j] == '['
        depth -= 1 if text[j] == ']'
        j += 1 if depth > 0
      end
      val = text[(i + 1)...j]
      j += 1 if j < text.length # consume the matching ']'
      [val, j]
    end

    # Resolve a control code's bracket argument to the integer it names,
    # recursively unwrapping a nested `\v[]`/`\V[]` (yado.tk: `\N[\V[1]]`
    # substitutes variable 1's *value* as the actor id, not the literal text
    # "\V[1]"; `\V[\V[1]]` reads the same way for indirect variable display).
    # A plain numeric argument resolves the same as before (`"3".to_i`).
    def self.resolve_arg(arg, variables)
      return 0 if arg.nil?
      m = /\A\\[vV]\[(.*)\]\z/m.match(arg)
      m ? variables[resolve_arg(m[1], variables)].to_i : arg.to_i
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
    # `pauses` are pacing stops ({ at:, kind: }) in revealed-character
    # coordinates, sorted ascending; the reveal will not advance past the next
    # unreleased one until the owner calls #release_pause. `auto_close` is the
    # `\^` flag (close the window without a keypress once fully revealed).
    # `instants` are [start, end) spans (`\>` … `\<`) that appear in one frame.
    def initialize(lines, revealed = 0, pauses = [], auto_close = false,
                   instants = [])
      @lines = lines || []
      @total = 0
      @lines.each { |l| @total += l.length }
      @revealed = Game.clamp(revealed, 0, @total)
      # Sort with an explicit block, not sort_by: this mruby build's gembox
      # has no Array#sort_by (the native engine aborts on it).
      @pauses = (pauses || []).sort { |a, b| a[:at] <=> b[:at] }
      @auto_close = auto_close ? true : false
      @instants = instants || []
      @released = 0 # how many leading pauses the owner has let through
    end

    attr_reader :revealed, :total

    def auto_close?; @auto_close; end
    def done?; @revealed >= @total; end

    # Reveal everything up to the next gating pause (a keypress fast-forwards the
    # current run but still honours an intervening `\!` / `\.` / `\|`).
    def reveal_all
      stop = next_pause
      @revealed = stop ? stop[:at] : @total
    end

    # Reveal `n` more characters (default 1), never past the total nor past the
    # next unreleased pause. When the newly revealed position lands inside an
    # instant (`\>` … `\<`) span, the whole span appears at once (still capped at
    # the pause limit).
    def advance(n = 1)
      n = 0 if n < 0
      stop = next_pause
      limit = stop ? stop[:at] : @total
      pos = Game.clamp(@revealed + n, 0, limit)
      pos = through_instant(pos) if pos > @revealed
      @revealed = Game.clamp(pos, 0, limit)
    end

    # If the next character to reveal (`pos`) falls inside an instant span, jump
    # to that span's end so it shows in one frame; otherwise return `pos`.
    def through_instant(pos)
      @instants.each { |a, b| return b if pos >= a && pos < b }
      pos
    end

    # The next pause that still gates advancement (unreleased), or nil.
    def next_pause; @pauses[@released]; end

    # The pause the reveal is currently blocked on — its `at` has been reached
    # and it has not been released yet — or nil.
    def pending_pause
      p = @pauses[@released]
      p && @revealed >= p[:at] ? p : nil
    end

    # Let the current pause through so the reveal can continue past it.
    def release_pause; @released += 1 if pending_pause; end

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
  # Change Face Graphic (10130) event commands. Both are *global* game-system
  # settings shared across every event and persisted in the save (as RPG_RT does
  # it): a Show Message is displayed with whatever configuration is in effect at
  # the time. The two differ in how long they live, though (yado.tk): Message
  # Options are sticky for the rest of the game once set, with no auto-reset,
  # while the face graphic is scoped to the event that set it -- it persists
  # through that event's own remaining execution content (including a Call
  # Event it makes), and is auto-cleared once that event's command list
  # actually finishes, not just by an explicit clear. `Game::Interpreter`
  # enforces the face's shorter lifetime (`@face_owner`, `#do_change_face` /
  # `#update`); this class stays pure data either way — the owning scene reads
  # it when it opens a window.
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

  # A chipset: its tile graphic name plus the lower- and upper-layer
  # passability tables. Passability is keyed by a chip index derived from the
  # tile id following the EasyRPG block layout; unknown/out-of-range tiles are
  # treated as passable so collision degrades safely.
  class ChipSet
    # numpad direction -> passability bit.
    DIR_BIT = { 2 => 0x01, 4 => 0x02, 6 => 0x04, 8 => 0x08 }.freeze
    # The non-directional bits of the same passage byte (EasyRPG's `Passable`,
    # src/map_data.h: Down=0x01, Left=0x02, Right=0x04, Up=0x08, Above=0x10,
    # Wall=0x20, Counter=0x40). `ABOVE_BIT` is the editor's upper-layer "star"
    # toggle, and it decides two separate things, both keyed off the same bit:
    #   - Passability: an upper tile is *see-through* ground rather than a
    #     solid object in its own right when this bit is set. `IsPassableTile`
    #     only falls through to the lower layer's own passability when it is
    #     set, so a painted-on decoration (a rug, a patch of flowers) still
    #     collides with whatever the lower layer says underneath it, while a
    #     genuine obstacle (a boulder, a fence post, a shop counter) is
    #     decided by the upper tile alone.
    #   - Draw order (see Scene::Map#draw_layers / #elevated?): only a starred
    #     upper tile draws in front of characters; an unstarred one draws at
    #     the same z as the lower layer instead, so a character standing on or
    #     against it composites normally rather than being masked by it.
    #     Confirmed against a genuine RPG_RT.exe under wine: Nepheshel's
    #     opening lies the hero down across a 3-tile bed graphic (headboard /
    #     mattress / footer); only the footer is starred, so the headboard and
    #     mattress alone would show him in full, but a *separate* map event
    #     (layer: above, its own small pillow graphic) sits on the same tile
    #     and is what actually covers him from the neck down, drawn through
    #     the ordinary above-hero event path. Treating every upper tile as
    #     always-above, as this renderer previously did, hid the headboard
    #     tile's own contents as well and left him fully invisible instead of
    #     tucked in.
    # `COUNTER_BIT` marks a tile you may talk *across* — the shop counter an
    # NPC stands behind.
    ABOVE_BIT = 0x10
    COUNTER_BIT = 0x40
    # Every directional bit ORed together, for a jump's any-side landing check.
    ALL_DIRS = (DIR_BIT[2] | DIR_BIT[4] | DIR_BIT[6] | DIR_BIT[8]).freeze

    attr_reader :name, :graphic, :animation_type, :animation_speed

    def initialize(db, id)
      c = db.chipset[id]
      @name = c ? c.name : ''
      @graphic = c ? c.chipset_name : ''
      @passable_lower = c ? c.passable_data_lower : nil
      # The upper layer's own passage table, which is where the counter flag
      # lives (the lower table has no room for it).
      @passable_upper = c ? c.passable_data_upper : nil
      @terrain = c ? c.terrain_data : nil
      # Water-animation parameters (chipset chunks 11/12): the animation "type"
      # (0 = 3-frame back-and-forth, 1 = 3-frame cycle) and speed flag (0 slow,
      # non-zero fast). Consumed by ChipsetLayout when picking the animation
      # column for the water autotiles.
      @animation_type = c ? (c.animation_type || 0) : 0
      @animation_speed = c ? (c.animation_speed || 0) : 0
    end

    # Passage byte for an upper-layer tile id, or nil when there is none to
    # read: no table on this chipset, no id given, the id is 0 (RPG2000's "no
    # upper tile here" sentinel), or it falls outside the table.
    def upper_flags(upper_tile_id)
      return nil if @passable_upper.nil? || upper_tile_id.nil? || upper_tile_id == 0
      idx = upper_tile_id - ChipsetLayout::BLOCK_F
      return nil if idx < 0 || idx >= @passable_upper.size
      @passable_upper[idx]
    end
    private :upper_flags

    # Whether an upper-layer tile is starred (ABOVE_BIT) and so draws in front
    # of characters rather than behind them, per Scene::Map#draw_layers. A
    # tile with no passability entry at all (id 0, or a chipset with no
    # table) is not starred — see #upper_flags.
    def elevated?(upper_tile_id)
      flags = upper_flags(upper_tile_id)
      !flags.nil? && (flags & ABOVE_BIT) != 0
    end

    # Chip index into the lower passability table for a lower-layer tile id.
    def self.lower_index(tile_id)
      return nil if tile_id.nil?
      if tile_id >= 5000 then 18 + (tile_id - 5000)
      elsif tile_id >= 4000 then 6 + (tile_id - 4000) / 50
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

    # Can a character land on a tile with the given lower-layer id, jumping in
    # from any side? A jump's landing check has no single direction of entry
    # the way an ordinary step does, so RPG_RT only refuses a tile the chipset
    # blocks from *every* direction — the four direction bits ORed together,
    # not one specific bit.
    def landable?(tile_id)
      return true if @passable_lower.nil?
      idx = ChipSet.lower_index(tile_id)
      return true if idx.nil? || idx < 0 || idx >= @passable_lower.size
      flags = @passable_lower[idx]
      return true if flags.nil?
      (flags & ALL_DIRS) != 0
    end

    # Is this an upper-layer **counter** tile — one the action button reaches
    # across? RPG2000 marks shop and inn counters with it so the keeper can stand
    # behind an impassable tile and still be talked to. A chipset without the
    # table has no counters.
    def counter?(upper_tile_id)
      flags = upper_flags(upper_tile_id)
      !flags.nil? && (flags & COUNTER_BIT) != 0
    end

    # Can a character enter this cell, moving in `dir`, once the upper layer's
    # own passability is taken into account? Mirrors EasyRPG's
    # `Game_Map::IsPassableTile`: an upper tile that blocks `dir` wins outright
    # (this is how a counter, blocked on every side, refuses to be walked
    # onto); one that permits it but is not flagged `ABOVE_BIT` is solid
    # ground in its own right and the check stops there; otherwise — no upper
    # tile at all, or one flagged `ABOVE_BIT` — the lower layer's own
    # passability decides, exactly as `passable?` alone did before this upper
    # check existed.
    def passable_tile?(lower_tile_id, upper_tile_id, dir)
      flags = upper_flags(upper_tile_id)
      return passable?(lower_tile_id, dir) if flags.nil?
      return false if (flags & (DIR_BIT[dir] || 0)) == 0
      return true if (flags & ABOVE_BIT) == 0
      passable?(lower_tile_id, dir)
    end

    # The jump-landing counterpart of `passable_tile?`, following `landable?`'s
    # any-side rule for the upper layer too: an upper tile blocked from every
    # direction refuses the landing outright, and `ABOVE_BIT` decides — same as
    # `passable_tile?` — whether the lower layer also gets a say.
    def landable_tile?(lower_tile_id, upper_tile_id)
      flags = upper_flags(upper_tile_id)
      return landable?(lower_tile_id) if flags.nil?
      return false if (flags & ALL_DIRS) == 0
      return true if (flags & ABOVE_BIT) == 0
      landable?(lower_tile_id)
    end

    # Terrain id of a lower-layer tile (for the Store Terrain ID command), looked
    # up through the same chip index as passability.
    #
    # **A missing table means terrain 1, not terrain 0.** RPG_RT omits the whole
    # 162-entry array when every tile of the chipset is terrain 1, which is the
    # overwhelmingly common case: 96 of Nepheshel's 100 chipsets and 92 of
    # mtf-meido-action's ship without one. Reading that as 0 left almost every
    # tile in both games with no terrain row at all, so Store Terrain ID answered
    # 0, boats and ships fell back to on-foot passability, and the terrain battle
    # backdrop never resolved. EasyRPG's `Game_Map::GetTerrainTag` documents the
    # same optimisation and answers 1.
    #
    # An id the chip index cannot reach reads the **first** lower tile's terrain,
    # as RPG_RT does for out-of-bounds coordinates.
    def terrain(tile_id)
      return 1 if @terrain.nil? || @terrain.empty?
      idx = ChipSet.lower_index(tile_id)
      idx = 0 if idx.nil? || idx < 0 || idx >= @terrain.size
      @terrain[idx] || 1
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
    # :upper, or nil for an absent tile and ids outside every block.
    #
    # Id **0 is not empty**: it is water set 0's plain chip (set 0, no border and
    # no corner), and the genuine RPG_RT draws it as deep water. Only the *upper*
    # layer uses 0 to mean "no tile" -- its own ids start at BLOCK_F -- so that
    # layer's callers skip 0 before asking (see Scene::Map#draw_layers). Treating
    # 0 as empty here left holes: on Nepheshel's map 204 the sea rendered as
    # black where RPG_RT drew water, 90 of the 320 on-screen tiles.
    def self.block(id)
      return nil if id.nil? || id < 0
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
    # quarters. An absent tile and out-of-range ids return []; id 0 is water, not
    # empty (see .block). `abf` / `cf` are the current animation columns/frames
    # from #anim_ab / #anim_c.
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
    # Bumped on every change of value. An event page's conditions are read from
    # the switches, the variables, the party roster and its items, so the map
    # scene watches these counters to know when a page might have flipped and
    # its events need re-selecting (see Scene::Map#refresh_event_pages). Writing
    # the value a switch already holds does not count as a change — a parallel
    # process that sets the same flag every frame must not keep the map busy.
    attr_reader :revision

    def initialize; @data = {}; @revision = 0; end
    def [](id); @data[id] || false; end

    def []=(id, v)
      nv = v ? true : false
      return nv if self[id] == nv
      @data[id] = nv
      @revision += 1
      nv
    end

    def flip(id); self[id] = !self[id]; end
    def to_h; @data; end
    def replace(h); @data = h || {}; @revision += 1; end
  end

  # Game variables: a 1-indexed set of integers, defaulting to 0.
  class Variables
    # RPG_RT clamps a variable's value to a fixed range rather than letting it
    # overflow -- +-999999 in RPG2000 (mruby-lcf's LCF.var_min/max carry the
    # same figures for the schema side, but this file deliberately touches
    # neither RGSS nor the native LCF parser at load time, so the bound is
    # its own local constant rather than a cross-gem reference). Multiplying
    # before dividing (the standard `x1.5` = `x15/10` workaround) can
    # legitimately blow past +-999999 mid-expression, and Control Variables
    # can also assign an arbitrary Input Number / random / constant straight
    # past the range, so the clamp belongs on the single write path every
    # source funnels through, not on any one caller.
    MAX = 999_999
    MIN = -999_999

    # See Switches#revision: page conditions read variables too.
    attr_reader :revision

    def initialize; @data = {}; @revision = 0; end
    def [](id); @data[id] || 0; end

    def []=(id, v)
      v = MAX if v > MAX
      v = MIN if v < MIN
      return v if self[id] == v
      @data[id] = v
      @revision += 1
      v
    end

    def to_h; @data; end
    def replace(h); @data = h || {}; @revision += 1; end
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
    # The actor's default FaceSet portrait (chunk 15/16), shown by the Enter
    # Hero Name screen and, once a message picks it explicitly, by Show Text.
    attr_reader :face_name, :face_index
    attr_accessor :hp, :mp
    # Name and title (the status-screen subtitle) are mutable via the Change
    # Actor Name / Title event commands. `transparent` hides the actor's map
    # sprite (the Change Sprite Association transparency flag).
    attr_accessor :name, :title, :transparent
    attr_reader :max_hp, :max_mp, :atk, :def, :int, :agi
    # The unclamped shadow total #change_param accumulates deltas onto (see
    # #change_param and #restore_base) -- exposed so the save can carry it.
    attr_reader :base_raw

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
    # The two slots 両手持ち makes mutually exclusive, and the item type the flag
    # is read on.
    WEAPON_SLOT = 0
    SHIELD_SLOT = 1
    ITEM_WEAPON = 1

    # The equipped item ids, one per EQUIP_ORDER slot (0 = an empty slot), the
    # ids of the skills the actor knows, and the ids of the status conditions
    # (状態) currently afflicting the actor.
    attr_reader :equipment, :skills, :states

    # The actor's RPG2003 class (職業, database chunk 30 -- `db.job`), 0 for none.
    # RPG2000 databases carry no class table, so this stays 0 there. With a class
    # set, the class row -- not the actor row -- supplies the growth curve, the
    # skill learn table and the EXP curve, exactly as RPG_RT reads them
    # (EasyRPG's Game_Actor::GetBaseMaxHp / LearnLevelSkills / CalculateExp all
    # branch on `class_id > 0`).
    attr_reader :class_id

    def initialize(db, id)
      @db = db
      @id = id
      a = db.player[id]
      raise "No such actor: #{id}" if a.nil?

      @name = a.name
      @title = a.respond_to?(:title) ? (a.title || '') : ''
      @charset_name = a.charset_name
      @charset_index = a.charset_index
      @face_name = a.faceset_name || ''
      @face_index = a.faceset_index || 0
      @transparent = a.respond_to?(:semi_transparent) ? (a.semi_transparent ? true : false) : false
      @db_row = a
      set_class_id(a.respond_to?(:class_id) ? (a.class_id || 0) : 0)
      @battle_commands = nil # lazily taken from the database on the first change
      @battle_combo = nil
      @exp = 0
      @equipment = normalize_equipment(a.respond_to?(:initial_equipment) ? a.initial_equipment : nil)
      @skills = []
      @states = []
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
    # leaves a vital over its cap. A fresh level-derived base is a new baseline
    # for #change_param's unclamped tracking too -- see @base_raw there.
    def set_level(level)
      @level = level && level >= 1 ? level : 1
      @base = base_stats(@level)
      @base_raw = @base.dup
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
    # exposes no learn table, e.g. the test fixtures). Read from the class row
    # when the actor has one (see #class_id).
    def learn_table
      a = curve_row
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

    # The actor's FaceSet graphic (顔グラフィック), shown on the save-select
    # screen (the SAVE_TITLE face slots) -- distinct from the message face
    # configured per Show Message. Comes from the database row until a Change
    # Actor Face event command (10640) overrides it; defaults to none when the
    # database row (or edition) does not carry one.
    def faceset_name
      return @faceset_name if @faceset_name
      @db_row.respond_to?(:faceset_name) ? (@db_row.faceset_name || '') : ''
    end

    def faceset_index
      return @faceset_index if @faceset_index
      @db_row.respond_to?(:faceset_index) ? (@db_row.faceset_index || 0) : 0
    end

    # Replace the actor's FaceSet graphic (the Change Actor Face event command):
    # `name` is the file and `index` the cell within it. The override outlives
    # the database default for the rest of the session.
    def set_faceset(name, index)
      @faceset_name = name || ''
      @faceset_index = index || 0
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

    # -- status conditions (状態) -------------------------------------------

    # The incapacitation state (戦闘不能). RPG2000 hardcodes it as state id 1, and
    # it is coupled to HP: a downed actor (HP 0) carries it, and it is cleared the
    # moment HP is restored (matching EasyRPG's `lcf::rpg::State::kDeathID`).
    DEATH_STATE = 1

    # Whether the actor is knocked out. HP is authoritative and kept in sync with
    # the death state, so either signal reports it.
    def dead?; @hp <= 0 || @states.include?(DEATH_STATE); end

    # Whether the actor is still standing (a live party member).
    def alive?; !dead?; end

    # Whether `state_id` is currently afflicting the actor.
    def state?(state_id)
      return false if state_id.nil? || state_id == 0
      @states.include?(state_id)
    end

    # Inflict a status condition (no-ops for an absent/duplicate id). Inflicting
    # the death state (戦闘不能) knocks the actor out, zeroing HP.
    def add_state(state_id)
      return if state_id.nil? || state_id == 0 || @states.include?(state_id)
      @states.push(state_id)
      @hp = 0 if state_id == DEATH_STATE
    end

    # Cure a status condition. Removing the death state revives a downed actor
    # with 1 HP (RPG2000's revive floor); returns the removed id or nil.
    def remove_state(state_id)
      removed = @states.delete(state_id)
      @hp = 1 if removed == DEATH_STATE && @hp <= 0
      removed
    end

    # Cure every status condition (RPG2000 Full Recovery clears them). If the
    # actor was down, curing the death state revives it with 1 HP.
    def clear_states
      revive = @hp <= 0 && @states.include?(DEATH_STATE)
      @states = []
      @hp = 1 if revive && @hp <= 0
    end

    # Replace the state set (Continue restoring the saved conditions). The saved
    # HP is authoritative and restored separately, so this assigns without the
    # HP-coupling side effects.
    def states=(ids)
      @states = (ids || []).reject { |s| s.nil? || s == 0 }.uniq
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

    # Equip a database item into `slot`, defaulting to the one its own type
    # matches (weapon type 1 -> slot 0, shield 2 -> 1, armour 3 -> 2, helmet
    # 4 -> 3, accessory 5 -> 4), and recompute the boosted stats. An explicit
    # `slot` is what a 二刀流 actor's second weapon needs: its type still says
    # "weapon" (slot 0), but the equip menu is placing it in the shield slot
    # (1) as the candidate list `Party#equip_candidates` offered it for. A
    # non-equippable item, an unknown id, or a database without an item table
    # is ignored. Drives the Change Equipment event command's equip operation
    # (always by type, since that command names no slot).
    def equip_item(item_id, slot = nil)
      return if item_id.nil? || item_id == 0 || !@db.respond_to?(:item)
      it = @db.item[item_id]
      return unless it
      slot ||= it.type - 1
      return unless slot >= 0 && slot < EQUIP_ORDER.size
      @equipment[slot] = item_id
      freed = free_two_handed_slot(slot)
      recompute_stats
      freed
    end

    # 両手持ち — a weapon that needs both hands. RPG_RT keeps the weapon and the
    # shield slots mutually exclusive whenever either of them holds a two-handed
    # *weapon*: filling one clears the other (EasyRPG's `Game_Actor::
    # ChangeEquipment`, which does `ChangeEquipment(other_slot, 0)` after the
    # slot is written). 35 of Nepheshel's 104 weapons are two-handed and 14 of
    # mtf-meido-action's 26 -- more than half of that game's arsenal -- and
    # nothing read the field, so a claymore and a shield could be worn together
    # and both bonuses counted.
    #
    # `slot` is the one just filled; only the weapon (0) and shield (1) pair is
    # affected, and the check reads *both* of them because equipping a shield
    # over a two-handed weapon has to drop the weapon just as equipping the
    # weapon drops the shield.
    # Returns the item id it displaced, or nil -- the equip menu swaps through
    # the bag, so what the other hand was holding has to go back there rather
    # than vanish.
    def free_two_handed_slot(slot)
      return nil unless slot == WEAPON_SLOT || slot == SHIELD_SLOT
      other = slot == WEAPON_SLOT ? SHIELD_SLOT : WEAPON_SLOT
      held = @equipment[other]
      return nil if held.nil? || held == 0
      return nil unless two_handed?(@equipment[slot]) || two_handed?(held)
      @equipment[other] = 0
      held
    end

    # Is `item_id` a two-handed weapon? The flag only means anything on a weapon
    # (type 1): RPG_RT tests the type alongside it, so a shield that happens to
    # carry the bit does not claim the other hand.
    def two_handed?(item_id)
      return false if item_id.nil? || item_id == 0 || !@db.respond_to?(:item)
      it = @db.item[item_id]
      return false unless it && it.type == ITEM_WEAPON
      it.respond_to?(:two_handed) ? ((it.two_handed || 0) != 0) : false
    rescue StandardError
      false
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
    # as level-independent. With a class set the class row's curve wins.
    def base_stats(level)
      a = curve_row
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

    # Whether any equipped item guards against critical hits (the armour
    # `prevent_critical` flag, item field 25). A database with no item table
    # (the test fixtures) or an item lacking the flag contributes nothing.
    def prevents_critical?
      return false unless @db.respond_to?(:item)
      @equipment.any? do |iid|
        next false if iid.nil? || iid == 0
        it = @db.item[iid]
        it && it.respond_to?(:prevent_critical) && it.prevent_critical
      end
    end

    # The actor's per-attribute defence ranks as `{ attribute_id => rank }`, read
    # from the database row's `attribute_ranks` byte array (rank 0 = A, most
    # vulnerable .. 4 = E, immune). An attribute the row omits defaults to C
    # (100%) at the battle layer. A fixture row without the field yields {}.
    def attribute_ranks
      ranks = {}
      arr = @db_row.respond_to?(:attribute_ranks) ? @db_row.attribute_ranks : nil
      return ranks unless arr
      arr.each_with_index { |v, i| ranks[i + 1] = v }
      ranks
    end

    # The actor's per-state susceptibility ranks as `{ state_id => rank }`, read
    # from the database row's `state_ranks` byte array (rank 0 = A, most
    # susceptible .. 4 = E, immune). Scales how often a status effect lands on
    # this actor. A fixture row without the field yields {}.
    def state_ranks
      ranks = {}
      arr = @db_row.respond_to?(:state_ranks) ? @db_row.state_ranks : nil
      return ranks unless arr
      arr.each_with_index { |v, i| ranks[i + 1] = v }
      ranks
    end

    # The elemental attribute ids carried by the equipped weapon(s) — the item's
    # `attribute_set` bool array (field 66), a flag per attribute — used to scale
    # a basic attack's damage by the target's resistance. No item table (a
    # fixture) or an unarmed actor carries none.
    def weapon_attributes
      return [] unless @db.respond_to?(:item)
      ids = []
      @equipment.each do |iid|
        next if iid.nil? || iid == 0
        it = @db.item[iid]
        next unless it && it.respond_to?(:type) && it.type == 1 # weapon slot only
        set = it.respond_to?(:attribute_set) ? it.attribute_set : nil
        next unless set
        set.each_with_index { |on, i| ids << (i + 1) if on }
      end
      ids.uniq
    end

    # The actor's basic-attack base hit rate (percent): the highest `hit` among
    # the equipped weapons (item field 17), or the RPG2000 unarmed default of 90
    # when nothing is equipped or the row omits it. Feeds the battle's to-hit
    # roll (EasyRPG's Game_Actor::GetHitChance).
    def attack_hit_rate
      best = nil
      if @db.respond_to?(:item)
        @equipment.each do |iid|
          next if iid.nil? || iid == 0
          it = @db.item[iid]
          next unless it && it.respond_to?(:type) && it.type == 1 # weapon slot
          h = it.respond_to?(:hit) ? it.hit : nil
          best = h if h && (best.nil? || h > best)
        end
      end
      best && best > 0 ? best : 90
    end

    # The battle animation a basic Attack plays with this actor's current gear:
    # the primary weapon slot's own `animation_id` (item field 20 -- the
    # weapon editor's own "アニメーション" picker; the same field
    # Scene::Map#battle_animation_id already reads off a *used* skill/item,
    # reused here for a weapon's normal-attack swing) when one is worn and set,
    # or the actor row's `unarmed_animation` (field 56, 素手戦闘アニメID)
    # otherwise -- RPG2000 has no equivalent monster-side field (an enemy's
    # Attack plays no animation at all), so this is Actor-only by design, not
    # an oversight. Only the primary slot is read: RPG_RT keeps this as one
    # property per actor rather than one per weapon, and a 二刀流 actor's
    # second swing (the shield-slot weapon #attack_hit_rate's own scan already
    # picks up for hit/crit) plays the identical animation as the first, so
    # there is nothing here for that second weapon to override.
    def attack_animation_id
      iid = @equipment[WEAPON_SLOT]
      if iid && iid != 0 && @db.respond_to?(:item)
        it = @db.item[iid]
        if it && it.respond_to?(:type) && it.type == ITEM_WEAPON &&
           it.respond_to?(:animation_id) && it.animation_id && it.animation_id > 0
          return it.animation_id
        end
      end
      @db_row.respond_to?(:unarmed_animation) ? @db_row.unarmed_animation : nil
    end

    # Whether any equipped item carries boolean field `name`. The weapon combat
    # flags below all work this way — one piece of gear is enough to grant them.
    # `weapon_only` restricts the search to the weapon slot (item type 1), which
    # is where RPG2000 keeps the attack modifiers.
    def equipment_flag?(name, weapon_only = false)
      return false unless @db.respond_to?(:item)
      @equipment.any? do |iid|
        next false if iid.nil? || iid == 0
        it = @db.item[iid]
        next false unless it
        next false if weapon_only && !(it.respond_to?(:type) && it.type == 1)
        it.respond_to?(name) && it.send(name) ? true : false
      end
    end

    # 二刀流 — an equipped weapon that swings **twice** per basic attack
    # (EasyRPG's `GetNumberOfAttacks`: `weapon.dual_attack ? 2 : 1`). Nepheshel
    # gives 13 of its weapons this.
    def dual_attack?; equipment_flag?(:dual_attack, true); end

    # 必中 — an equipped weapon whose attack cannot be evaded. RPG_RT's
    # `CalcNormalAttackToHit` returns before it applies the agility / evasion
    # term for such a weapon. 13 of Nepheshel's weapons carry it.
    def ignores_evasion?; equipment_flag?(:ignore_evasion, true); end

    # 全体化 — an equipped weapon that turns a basic Attack into a strike
    # against every living member of the chosen target's side, rather than
    # just the one target (EasyRPG's `HasAttackAll` /
    # `Normal::vStart`: "if this weapon attacks all, then attack all enemies
    # regardless of original targeting" — "enemies" there means whichever
    # side the already-resolved target belongs to, so a forced attack-ally
    # restriction or confusion spreads across the *ally* side instead).
    def attack_all?; equipment_flag?(:attack_all, true); end

    # 先制攻撃 — an equipped weapon that jumps its wielder's basic Attack to
    # the front of the round's turn order (EasyRPG's `HasPreemptiveAttack` /
    # `Scene_Battle_Rpg2k::CreateExecutionOrder`, which adds 9999 to the
    # battler's computed order for exactly this case — effectively always
    # first, since ordinary agility values never approach that). Only a
    # basic Attack earns the jump; a Skill, Item or Defend with the same
    # weapon still equipped keeps its ordinary agility slot, matching
    # `CreateExecutionOrder`'s own `Type::Normal` guard.
    def preemptive?; equipment_flag?(:preemptive, true); end

    # MP消費半分 — gear that halves what a skill costs to cast. Any slot, not just
    # the weapon (Nepheshel's 賢者の指輪 is an accessory).
    def half_sp_cost?; equipment_flag?(:half_sp_cost); end

    # 地形ダメージ無効 — gear that makes its wearer immune to the damage a tile's
    # terrain deals as they walk over it (Party#apply_terrain_damage). Any slot:
    # mtf-meido-action's is a pair of boots, Nepheshel's four include a swimsuit.
    def prevents_terrain_damage?; equipment_flag?(:no_terrain_damage); end

    # 物理回避率アップ — a shield/armour/helmet/accessory that makes a normal
    # attack likelier to miss its wearer: RPG_RT subtracts a flat 25 from the
    # attacker's already agi-adjusted hit chance (EasyRPG's
    # `HasPhysicalEvasionUp`, consulted by `CalcNormalAttackToHit` right after
    # its AGI term). The weapon slot never counts — `ForEachEquipment<false,
    # true>` there excludes weapons by item *type*, not slot index, the same
    # way #equip_bonus already reads every equipped slot, so a 二刀流 actor's
    # second weapon (sitting in the shield slot) is correctly excluded too.
    def physical_evasion_up?
      return false unless @db.respond_to?(:item)
      @equipment.any? do |iid|
        next false if iid.nil? || iid == 0
        it = @db.item[iid]
        next false unless it
        next false if it.respond_to?(:type) && it.type == ITEM_WEAPON
        it.respond_to?(:raise_evasion) && it.raise_evasion ? true : false
      end
    end

    # 強力防御 — an actor whose Defend halves damage a *second* time (a quarter
    # rather than a half, per EasyRPG's `AdjustDamageForDefend`). This one is a
    # property of the actor row (field 24), not of gear, and an RPG2003 class can
    # override it the way it overrides the growth curves.
    def strong_defence?
      row = class_row_for(@class_id) if @class_id && @class_id > 0
      row ||= @db_row
      row.respond_to?(:strong_defence) ? (row.strong_defence ? true : false) : false
    end

    # 二刀流 — an actor (or RPG2003 class) trait that turns the *shield* slot
    # into a *second weapon* slot, unlike the item-row #dual_attack? above (a
    # weapon that makes one basic attack swing twice — an unrelated flag that
    # happens to share the same Japanese name). Same class-row-then-player-row
    # lookup as #strong_defence?, since RPG2003 lets a class override it too
    # (liblcf's `job` table carries the same field id). EasyRPG's
    # `Window_EquipItem` retargets the whole shield slot to `weapon` before
    # listing candidates for such an actor, and rejects a shield there
    # outright — #equip_candidates does the retargeting; #attack_hit_rate,
    # #weapon_crit_bonus and #equipment_flag?'s weapon-only search already
    # scan every equipped slot for an item whose own *type* is a weapon rather
    # than hard-coding slot 0, so once a second weapon sits in the shield slot
    # they pick it up (and the better of the two) with no change of their own.
    def double_hand?
      row = class_row_for(@class_id) if @class_id && @class_id > 0
      row ||= @db_row
      row.respond_to?(:double_hand) ? (row.double_hand ? true : false) : false
    end

    # 装備固定 — an actor (or RPG2003 class) whose equipment cannot be changed
    # from the field. Same class-row-then-player-row lookup as #strong_defence?
    # / #double_hand? (liblcf's `job` table carries the same field id, 22).
    # EasyRPG's `Game_Actor::IsEquipmentFixed` is `data.lock_equipment ||
    # (check_states && a currently-inflicted state is 呪い/cursed)` -- the
    # state-curse half has no test-bed evidence in either game (neither names
    # a `cursed` state) and is left unbuilt rather than guessed at; this reads
    # only the row's own flag, which is the half both games actually set.
    # `Scene::EquipMenu` is what has to act on it (`scene_equip.cpp`'s
    # `UpdateEquipSelection` refuses to even open the slot's item list, rather
    # than opening it and rejecting a choice), so nothing in `Game::Party`
    # reads this -- the bag-swapping methods stay usable for a caller that
    # already knows better, the same way they do not re-check `menu_access`.
    def equipment_fixed?
      row = class_row_for(@class_id) if @class_id && @class_id > 0
      row ||= @db_row
      row.respond_to?(:equipment_fixed) ? (row.equipment_fixed ? true : false) : false
    end

    # 呪われた装備 -- an item flagged `cursed` (item field 29, alongside the other
    # armour-property flags) refuses to leave the slot it is worn in: RPG_RT's
    # equip menu will not remove or replace it. Unlike #equipment_fixed? above
    # this is a property of the *item currently sitting in the slot*, not of
    # the actor, so it is read fresh from whatever `slot` holds rather than
    # cached. Same split as #equipment_fixed?: RPG_RT's Change Equipment event
    # command still forces it off (`Game_Actor::ChangeEquipment` does not
    # consult the flag either), so only the equip menu gates on this -- Game
    # ::Party's #equip_from_bag / #unequip_to_bag stay unguarded on purpose.
    def slot_cursed?(slot)
      return false unless slot >= 0 && slot < EQUIP_ORDER.size && @db.respond_to?(:item)
      item_id = @equipment[slot]
      return false if item_id.nil? || item_id == 0
      it = @db.item[item_id]
      it && it.respond_to?(:cursed) ? (it.cursed ? true : false) : false
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
    # flag. Reaching 0 with death allowed inflicts the death state (戦闘不能).
    # A downed actor is unaffected -- HP changes cannot revive it (that needs the
    # death state cured / Full Recovery), matching EasyRPG's ChangeHp. Returns the
    # new HP.
    def change_hp(delta, allow_death = true)
      return @hp if dead?
      floor = allow_death ? 0 : 1
      @hp = Game.clamp(@hp + delta, floor, @max_hp)
      add_state(DEATH_STATE) if @hp <= 0
      @hp
    end

    # The actor's critical-hit chance in basis points (0 = never): the row's own
    # 1-in-`critical_rate` rate, gated by `has_critical_rate`, **plus** the
    # equipped weapon's `critical_hit` percentage. RPG_RT adds the two, which is
    # why this is a probability rather than the 1-in-N denominator it used to
    # be -- there is no denominator that expresses "1/30 and 20% more".
    #
    # Basis points (1/10000) rather than a float, to stay with the integer
    # arithmetic the rest of the damage path uses. The base truncates there: a
    # 1/30 row is 333 bp, i.e. 3.33% against a true 3.333...%, which is one crit
    # fewer in roughly 300,000 swings.
    def crit_chance
      base = 0
      if @db_row.respond_to?(:has_critical_rate) && @db_row.has_critical_rate
        n = @db_row.respond_to?(:critical_rate) ? @db_row.critical_rate : 0
        base = CRIT_SCALE / n if n && n > 0
      end
      base + weapon_crit_bonus * CRIT_PERCENT
    end

    # 会心必殺 -- the best `critical_hit` percentage among the equipped weapons
    # (item field 18), the bonus #crit_chance adds to the actor's own rate.
    #
    # **Weapons only** (item type 1), like #attack_hit_rate and the other attack
    # modifiers. The field is one the editor shows for a weapon and no other kind
    # of item, and Nepheshel says so in its bytes: 69 of its 75 items carrying a
    # non-zero value are weapons with a spread of rates (2..100), while the other
    # six are armour and accessories carrying **exactly** 100 apiece -- alongside
    # a `hit` of 70, another weapon-only field. Six pieces of armour that always
    # critical is not a design; it is the editor leaving weapon fields untouched
    # in a record every item type shares.
    def weapon_crit_bonus
      return 0 unless @db.respond_to?(:item)
      best = 0
      @equipment.each do |iid|
        next if iid.nil? || iid == 0
        it = @db.item[iid]
        next unless it && it.respond_to?(:type) && it.type == 1
        c = it.respond_to?(:critical_hit) ? it.critical_hit : nil
        best = c if c && c > best
      end
      best
    end

    # Set HP to an absolute value, clamped to [0, max_hp], keeping the death
    # state (戦闘不能) in sync: 0 knocks the actor out, a positive value revives a
    # downed one. Unlike change_hp this is not blocked while dead -- it is the
    # write-back used to persist a battle's outcome (a wounded or KO'd survivor)
    # onto the party. Returns the new HP.
    def set_hp(value)
      @hp = Game.clamp(value, 0, @max_hp)
      if @hp <= 0
        add_state(DEATH_STATE)
      else
        remove_state(DEATH_STATE)
      end
      @hp
    end

    # Apply a MP (SP) change, clamped to [0, max_mp]. Returns the new MP.
    def change_mp(delta)
      @mp = Game.clamp(@mp + delta, 0, @max_mp)
    end

    # Restore HP and MP to their maxima and cure every status condition
    # (RPG2000 Full Recovery).
    def full_heal
      @hp = @max_hp
      @mp = @max_mp
      clear_states
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
    #
    # yado.tk's `2000/デフォ戦botまとめ`: the displayed/effective stat clamps to
    # that range, but RPG_RT keeps accumulating the *unclamped* running total
    # underneath -- lower Attack far past 1 with one call, then raise it back
    # only part way, and the effective value stays pinned at the old clamp
    # until the raw total genuinely climbs back past it, rather than reacting
    # to the partial raise immediately. @base_raw is that shadow total; @base
    # (read by #recompute_stats and everything else) stays the clamped,
    # display/effective value throughout.
    def change_param(type, delta)
      return unless type >= 0 && type < STAT_NAMES.size
      @base_raw[type] += delta
      @base[type] = Game.clamp(@base_raw[type], 1, base_param_limit(type))
      recompute_stats
    end

    # RPG2000's clamp ceiling for a base parameter: HP/MP go to 9999, the four
    # battle stats to 999. Shared by #change_param and #restore_base, which
    # both need to re-derive the clamped @base from an unclamped total.
    def base_param_limit(type)
      (type == PARAM_MAX_HP || type == PARAM_MAX_MP) ? 9999 : 999
    end

    # Restore the unclamped shadow total a Change Parameters command left
    # behind (#change_param's @base_raw) from a save. #set_exp/#set_level
    # already re-seeded @base/@base_raw from the level-derived baseline by
    # the time load_state calls this, discarding any live adjustment -- this
    # re-applies the saved total and re-derives the clamped @base from it the
    # same way #change_param itself does, rather than leaving a Change
    # Parameters edit to silently revert on Continue.
    def restore_base(base_raw)
      return unless base_raw
      @base_raw = base_raw.dup
      @base = @base_raw.each_with_index.map { |v, i| Game.clamp(v, 1, base_param_limit(i)) }
      recompute_stats
    end

    # -- RPG2003 class (職業) and battle commands ----------------------------

    # How Change Class (1008) treats the actor's skills, in the command's own
    # parameter order.
    CLASS_SKILL_NO_CHANGE = 0 # keep exactly the skills the actor already knows
    CLASS_SKILL_RESET     = 1 # forget everything, then learn the new class's
    CLASS_SKILL_ADD       = 2 # keep them and add the new class's on top

    # How Change Class treats the six base parameters.
    CLASS_PARAM_NO_CHANGE   = 0 # keep the values the actor had
    CLASS_PARAM_HALF        = 1 # halve them
    CLASS_PARAM_RESET_LV1   = 2 # take the new class's level-1 values
    CLASS_PARAM_RESET_LEVEL = 3 # take the new class's values at the new level

    # Change Class (event command 1008). Ported from EasyRPG's
    # Game_Actor::ChangeClass, which is where the order of operations comes from:
    #
    # * every equipment slot is stripped first (RPG_RT always does this),
    # * the base parameters in force *before* the change are captured, because
    #   the "no change" and "halve" modes carry them across the class swap,
    # * the class is swapped and the level set, which re-reads the growth curve,
    #   the learn table and the EXP curve from the new class row (#curve_row),
    # * EXP is reset to the new level's threshold -- RPG_RT does this even when
    #   the level is unchanged,
    # * and the skill mode is applied last, on top of whatever levelling learnt.
    #
    # Current HP/SP survive the change, re-clamped to the refreshed maxima.
    # Returns whether the class actually changed — false for a class id this
    # database does not define, which RPG_RT leaves entirely alone.
    def change_class(class_id, new_level, skill_mode, param_mode)
      return false if class_id > 0 && class_row_for(class_id).nil?

      unequip(EQUIP_ORDER.size)
      hp = @hp
      mp = @mp
      old_base = @base.dup
      old_skills = @skills.dup

      set_class_id(class_id)
      set_level(Game.clamp(new_level || 1, 1, max_level))
      @battle_commands = class_battle_commands
      @exp = exp_for_level(@level)

      case param_mode
      when CLASS_PARAM_NO_CHANGE then @base = old_base
      when CLASS_PARAM_HALF      then @base = old_base.map { |v| v / 2 }
      when CLASS_PARAM_RESET_LV1 then @base = base_stats(1)
      end
      # Whichever branch (or none, for CLASS_PARAM_RESET_LEVEL) ran, @base is
      # a fresh baseline -- reset #change_param's unclamped shadow to match,
      # the same rule set_level's own reset above already follows.
      @base_raw = @base.dup
      recompute_stats

      @hp = Game.clamp(hp, 0, @max_hp) if hp
      @mp = Game.clamp(mp, 0, @max_mp) if mp

      case skill_mode
      when CLASS_SKILL_NO_CHANGE then @skills = old_skills
      when CLASS_SKILL_RESET     then @skills = []; learn_level_skills
      end
      true
    end

    # The actor's RPG2003 battle-command ids (戦闘コマンド, database field 80 --
    # seven slots padded with -1, the 0 entry standing for the Row command).
    # Until a Change Battle Commands (1009) edits them they are read straight
    # from the database, which is also how RPG_RT defers materialising the list.
    def battle_commands
      @battle_commands ||= class_battle_commands
    end

    # Change Battle Commands (event command 1009). `add` inserts command `id`
    # ahead of the Row entry; otherwise it is removed, and id 0 clears the whole
    # list back to Row alone. Ported from EasyRPG's
    # Game_Actor::ChangeBattleCommands, including its capacity rule: the list
    # holds at most six real commands plus Row, so a seventh add is dropped.
    def change_battle_commands(add, id)
      cmds = battle_commands
      if add
        return if id.nil? || id <= 0 || cmds.include?(id)
        kept = cmds.reject { |c| c == 0 || c == -1 }
        return if kept.size >= 6
        @battle_commands = kept + [id, 0]
      elsif id == 0
        @battle_commands = [0]
      else
        idx = cmds.index(id)
        return unless idx
        kept = cmds.dup
        kept.delete_at(idx)
        @battle_commands = kept
      end
    end

    # Put the actor back into class `id` without any of Change Class's side
    # effects (Continue restoring a saved class): the curves are re-read at the
    # current level, but equipment, EXP and skills are restored separately from
    # the save and must not be reset here.
    def restore_class(id)
      set_class_id(id)
      set_level(@level)
      @battle_commands = nil
    end

    # Replace the battle-command list (Continue restoring a saved one). nil keeps
    # whatever the database / class defines.
    def battle_commands=(ids)
      @battle_commands = ids && !ids.empty? ? ids.dup : nil
    end

    # The RPG2003 battle combo an Enable Combo (1007) armed: the battle command
    # to repeat and how many times. nil until a battle page arms one.
    attr_reader :battle_combo

    # Enable Combo (event command 1007): make `command_id` repeat `multiple`
    # times when this actor uses it. Stored on the actor the way RPG_RT keeps it
    # (EasyRPG's Game_Actor::SetBattleCombo); the ATB battle system that spends
    # it is not modelled here, so this records the arming rather than acting.
    def set_battle_combo(command_id, multiple)
      @battle_combo = { command_id: command_id, multiple: multiple }
    end

    # Whether this actor uses the RPG2000 "custom battle command" name
    # (独自戦闘コマンド有効, database field 66) instead of the database's
    # generic Skill term. A class change never touches this — EasyRPG's own
    # `GetSkillName` reads it off the actor's own database row
    # (`lcf::Data::actors[id]`), which has no class-row counterpart at all
    # (only the RPG2003 `battle_commands` list, field 80, is defined on both
    # Actor and Class).
    def rename_skill?
      @db_row.respond_to?(:custom_battle_command) ? !!@db_row.custom_battle_command : false
    end

    # The renamed label itself (独自戦闘コマンド名称, field 67), read only when
    # #rename_skill? is set.
    def skill_command_name
      @db_row.respond_to?(:custom_battle_command_name) ? (@db_row.custom_battle_command_name || '') : ''
    end

    private

    # The battle-command list the actor's current class (or, class-less, its
    # database row) defines. An edition / fixture row without the field yields
    # the RPG2003 default of Row alone.
    def class_battle_commands
      row = @class_row || @db_row
      list = row.respond_to?(:battle_commands) ? row.battle_commands : nil
      list.is_a?(Array) && !list.empty? ? list.dup : [0]
    end

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
    # row (a test fixture) does not carry it. The class row wins when the actor
    # has a class, mirroring EasyRPG's CalculateExp.
    def db_exp_param(field)
      row = curve_row
      row.respond_to?(field) ? (row.__send__(field) || EXP_DEFAULT) : EXP_DEFAULT
    end

    # The database row the level-scaled tables are read from: the class row (職業)
    # when the actor has a class, the actor row otherwise. Only the growth curve,
    # the learn table and the EXP curve follow the class -- the attribute / state
    # ranks stay on the actor row, which is where RPG_RT keeps reading them.
    def curve_row
      @class_row || @db_row
    end

    # Point the actor at class `id` (0 = none), resolving its database row. A
    # database with no class table (every RPG2000 game) or an unknown id leaves
    # the actor class-less, so the actor row keeps supplying the curves.
    def set_class_id(id)
      @class_id = id && id > 0 ? id : 0
      @class_row = @class_id > 0 ? class_row_for(@class_id) : nil
      @class_id = 0 if @class_row.nil?
    end

    # The database class row for `id`, or nil when this database has no class
    # table (RPG2000) or does not define that id.
    def class_row_for(id)
      return nil unless @db.respond_to?(:job) && @db.job
      @db.job[id]
    end
  end

  # Every actor the game has instantiated, keyed by database id — RPG_RT's
  # `Game_Actors`. One `Game::Actor` exists per database row for the whole
  # session and the party is only a list of ids into this table, which is why
  # taking a member out of the party and putting them back keeps their level,
  # EXP, equipment, learned skills, statuses and renamed name instead of
  # rebuilding them from the database row.
  #
  # The save format says the same thing: `Save<N>.lsd`'s chunk 108
  # (`SAVE_PARTY_ACTOR`) holds one entry per actor the party has *ever* held,
  # not one per current member, so a roster is what that table serialises.
  # See ADR 0030.
  class Actors
    def initialize(db)
      @db = db
      @all = {}
      @missing = {} # ids already reported, so a bad id in a loop logs once
    end

    # The actor for `id`, built from the database on first request and cached
    # from then on (RPG_RT's `Game_Actors::GetActor`). nil for a non-positive id
    # or a row the database does not have — the miss is logged rather than
    # raised, so a game that references a missing actor keeps running. A command
    # in a parallel process can ask every frame, so each bad id is reported once
    # rather than filling the log.
    def [](id)
      return nil if id.nil? || id <= 0
      a = @all[id]
      return a if a
      @all[id] = Actor.new(@db, id)
    rescue RuntimeError => e
      unless @missing[id]
        @missing[id] = true
        $stderr.puts "[RPG2k] actor ##{id} could not be built: #{e.message}"
      end
      nil
    end

    # The actor for `id` only if it has already been instantiated, without
    # creating one. Read paths (a `\N[n]` message code) use this so merely
    # naming an actor does not enrol them in the roster the save writes out.
    def existing(id); id.nil? ? nil : @all[id]; end

    # Every instantiated actor, in ascending database id order.
    def all; @all.keys.sort.map { |i| @all[i] }; end

    def each(&blk); all.each(&blk); end
  end

  # The active party: an ordered subset of the `Actors` roster. On a new game it
  # is seeded from the database's initial party list (System.party).
  class Party
    include Enumerable

    # RPG2000's active party roster caps at four members (the editor never
    # offers a fifth slot); a Change Party Member "Add" beyond that no-ops.
    MAX_SIZE = 4

    attr_reader :actors, :items, :gold

    # The permanent actor roster this party draws from (see Game::Actors). The
    # party owns it, so `State#party.roster` reaches every actor the game has
    # met, including ones who have since left.
    attr_reader :roster

    # Bumped whenever the membership or the bag changes — the two halves of the
    # party an event page's conditions can test (see Switches#revision).
    attr_reader :revision

    def initialize(db, ids = nil, roster = nil)
      @db = db
      @roster = roster || Actors.new(db)
      ids ||= db.system.party || []
      @actors = ids.reject { |i| i.nil? || i <= 0 }.map { |i| @roster[i] }.compact
      @items = {}  # item id => count
      @gold = 0
      @revision = 0
    end

    # Serialise the mutable party state (see State#to_h). Beyond HP/MP this keeps
    # the fields the Change Actor Name / Title / Sprite commands mutate, so those
    # edits survive a Save / Continue instead of reverting to the database row.
    #
    # The per-actor tables cover the whole **roster**, not just the current
    # members: an actor the game has taken out of the party keeps their level,
    # gear and name for when they rejoin, so the save has to carry them too.
    # `actor_ids` is the party proper, in order.
    def to_h
      hp = {}
      mp = {}
      exp = {}
      meta = {}
      @roster.each do |a|
        hp[a.id] = a.hp
        mp[a.id] = a.mp
        exp[a.id] = a.exp
        meta[a.id] = { name: a.name, title: a.title,
                       charset_name: a.charset_name,
                       charset_index: a.charset_index,
                       transparent: a.transparent, states: a.states.dup,
                       # A Change Parameters command's unclamped shadow total
                       # (see Actor#change_param / #restore_base) -- without
                       # it a live adjustment reverts to the level-derived
                       # baseline the moment #load_state re-seeds it from EXP.
                       base_raw: a.base_raw.dup,
                       # RPG2003: a Change Class / Change Battle Commands is a
                       # permanent edit, so it has to outlive Save / Continue the
                       # way the name and sprite overrides do.
                       class_id: a.class_id,
                       battle_commands: a.battle_commands.dup }
      end
      { actor_ids: @actors.map { |a| a.id }, items: @items, gold: @gold,
        hp: hp, mp: mp, exp: exp, actor_meta: meta }
    end

    # Restore item/gold, per-actor exp/hp/mp and the name/title/sprite overrides
    # from a saved party hash. EXP is restored first (it re-derives the level and
    # its base stats), then a saved Change Parameters shadow total (base_raw)
    # is re-applied on top of that fresh baseline, then the saved HP/MP are
    # laid over the recomputed maxima. A save written before actor_meta (or
    # before base_raw) existed simply keeps the level-derived defaults.
    #
    # Every id the saved tables mention is restored, not just the current
    # members, so an actor waiting out of the party comes back as they left
    # (#to_h writes the whole roster). Actors are pulled through the roster, so
    # restoring one that is not in the party enrols them there.
    def load_state(data)
      @revision += 1
      @items = data[:items] || {}
      @gold = data[:gold] || 0
      exp = data[:exp] || {}
      hp = data[:hp] || {}
      mp = data[:mp] || {}
      meta = data[:actor_meta] || {}
      ids = @actors.map { |a| a.id }
      [exp, hp, mp, meta].each do |table|
        table.keys.each { |id| ids.push(id) unless ids.include?(id) }
      end
      ids.each do |id|
        a = @roster[id]
        next unless a
        # The class comes back first: it decides which growth and EXP curves the
        # restored EXP is then read against.
        m = meta[id]
        a.restore_class(m[:class_id]) if m && m[:class_id]
        a.set_exp(exp[id]) if exp[id]
        # #set_exp re-seeds @base/@base_raw from the level-derived baseline
        # whenever it changes the level, discarding a live Change Parameters
        # edit -- restore the saved shadow total after it, not before.
        a.restore_base(m[:base_raw]) if m && m[:base_raw]
        a.hp = hp[id] if hp[id]
        a.mp = mp[id] if mp[id]
        apply_actor_meta(a, m)
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
      actor.states = m[:states] if m[:states]
      actor.battle_commands = m[:battle_commands] if m[:battle_commands]
    end

    def each(&blk); @actors.each(&blk); end
    def size; @actors.size; end
    def leader; @actors.first; end

    def include_actor?(id); @actors.any? { |a| a.id == id }; end
    def actor_by_id(id); @actors.find { |a| a.id == id }; end

    # Whether any party member is still standing. An empty party counts as wiped.
    def any_alive?; @actors.any? { |a| !a.dead? }; end

    # Whether the whole party is knocked out (戦闘不能) -- the game-over condition.
    def all_dead?; !any_alive?; end

    # RPG2000 field slip damage: apply every afflicted member's map-step drain
    # for a party that has now walked `steps` tiles. Each state a member carries
    # is asked for its due HP / SP loss (Game::States.map_step_drain) and the
    # totals are applied once, so two slipping states stack rather than the
    # worse one winning -- unlike the battle-side effects, which pick a single
    # significant state.
    #
    # The HP drain **cannot kill**: it goes through change_hp with death
    # disallowed, so a poisoned party is worn down to 1 HP and left standing.
    # That is RPG_RT's rule, and it is why nothing on this path has to re-check
    # for a game over the way the twelve event commands that *can* wipe the party
    # do. A member who is already down slips nothing at all.
    #
    # `table` is the database `situation` array; a caller without one (the seeded
    # harness fixtures) drains nothing. Returns the actors that actually lost
    # something, so the scene can flash the screen only when there is something
    # to report.
    def apply_map_step_damage(table, steps)
      hit = []
      @actors.each do |actor|
        next if actor.nil? || actor.dead?
        hp = 0
        sp = 0
        actor.states.each do |id|
          dhp, dsp = States.map_step_drain(id, table, steps)
          hp += dhp
          sp += dsp
        end
        next if hp.zero? && sp.zero?
        actor.change_hp(-hp, false) if hp > 0
        actor.change_mp(-sp) if sp > 0
        hit << actor
      end
      hit
    end

    # Damage every standing member for walking onto a damaging tile: RPG2000's
    # 地形ダメージ, the `damage` field on the terrain a tile's chip belongs to.
    #
    # Like the status slip above it **cannot kill** — `change_hp` with death
    # disallowed, so a party crossing a lava floor is worn to 1 HP and left
    # standing — which is again why nothing here re-checks for a game over.
    #
    # A member wearing gear flagged `no_terrain_damage` is exempt, which is the
    # only reason that flag exists: Nepheshel puts it on four items and
    # mtf-meido-action on its Safety Boots, against damage floors of 1 HP a step
    # (Nepheshel's ダメージ床 set, mtf's Poison Swamp).
    #
    # Returns the actors that actually lost HP, so the scene can flash only when
    # there is something to report.
    def apply_terrain_damage(amount)
      return [] unless amount && amount > 0
      hit = []
      @actors.each do |actor|
        next if actor.nil? || actor.dead?
        next if actor.prevents_terrain_damage?
        actor.change_hp(-amount, false)
        hit << actor
      end
      hit
    end

    # Put an actor in the party. The actor comes from the roster, so one who has
    # been in the party before rejoins with the level, EXP, gear, skills, statuses
    # and name they left with rather than a fresh database row. A no-op once the
    # party already holds MAX_SIZE members, matching RPG_RT's Change Party
    # Member "Add" against a full party (yado.tk: 主人公・パーティー・乗り物).
    def add_actor(id)
      return if include_actor?(id)
      return if @actors.size >= MAX_SIZE
      a = @roster[id]
      return unless a
      @actors.push a
      @revision += 1
    end

    # Take an actor out of the party. They stay in the roster (and in the save),
    # which is what lets #add_actor give them back unchanged.
    def remove_actor(id)
      before = @actors.size
      @actors.reject! { |a| a.id == id }
      @revision += 1 unless @actors.size == before
    end

    def item_count(id); @items[id] || 0; end

    # RPG_RT's item-possession test (Conditional Branch's item condition and an
    # event page's item appearance condition, both routed through here) also
    # counts a copy currently equipped on any party member — even though
    # equipping an item removes it from the bag `item_count` reports. The
    # numeric "item possession count" operand (Control Variables, item_operand
    # above) stays bag-only, matching RPG_RT's own split between the two reads.
    def has_item?(id)
      item_count(id) > 0 || @actors.any? { |a| a.equipment.include?(id) }
    end

    def gain_item(id, n = 1)
      c = item_count(id) + n
      c = 0 if c < 0
      c = 99 if c > 99
      return c if @items[id] == c
      @items[id] = c
      @revision += 1
      c
    end

    def lose_item(id, n = 1); gain_item(id, -n); end

    def gain_gold(n)
      @gold += n
      @gold = 0 if @gold < 0
      @gold = 999_999 if @gold > 999_999
    end

    # RPG2000 database item types (liblcf's `RPG::Item::Type`). Types 1..5 are the
    # equipment slots (see Actor::EQUIP_ORDER); 6 is a healing medicine (薬);
    # 7 is a skill book (本) that teaches a skill; 8 is a seed (種, 素材) that
    # permanently raises a stat; **9 is a special item (特殊) that invokes a
    # skill** and **10 is a switch item (スイッチ)** that turns on a game switch.
    #
    # Those last two used to be numbered one lower, which put every one of them
    # on the wrong branch. Nepheshel settles it from the bytes: its 14 type-9
    # items each carry a *distinct* `skill_id` naming a skill of the same name
    # (item 天使の翼 → skill 天使の翼, 火炎玉 → 火炎玉) with `switch_id` left at
    # the default 1, while its 41 type-10 items are the mirror image — 41 distinct
    # `switch_id`s and `skill_id` left at the default. Reading 9 as "switch" made
    # the 14 special items flip switch **1** (the default they never set) and left
    # the 41 real switch items unrecognised, so they never appeared in the bag.
    ITEM_MEDICINE = 6
    ITEM_SKILL_BOOK = 7
    ITEM_SEED = 8
    ITEM_SPECIAL = 9
    ITEM_SWITCH = 10

    # The database row for a held item id, or nil when the database has no item
    # table (a bare test fixture) or no such row.
    def db_item(id)
      return nil unless @db.respond_to?(:item)
      @db.item[id]
    end

    # Whether this party's database is an RPG2003 project (see
    # `LCF::Schema::Database#rpg2003?`), exposed here the same way `db_item` /
    # `db_skill` reach into `@db` for other callers -- a bare test fixture with
    # no `#rpg2003?` of its own reads false, the same answer a genuine RPG2000
    # database gives.
    def rpg2003?
      @db.respond_to?(:rpg2003?) && @db.rpg2003?
    end

    # Whether item `id` can be used from the field (main-menu) item screen: a
    # medicine or switch item the party holds whose "usable in field" occasion is
    # set (a battle-only medicine is hidden here, mirroring #battle_usable?), or a
    # skill book / seed (always field-only, no occasion to gate on).
    #
    # A **special** item defers to the skill it invokes, as RPG_RT does
    # (`Game_Party::IsItemUsable` hands a Type_special straight to
    # `IsSkillUsable`): the item's own occasion flags say nothing useful about a
    # thrown bomb. That is what keeps Nepheshel's 火炎玉 out of the field menu —
    # its skill targets an enemy — while 天使の翼, whose skill targets an ally,
    # stays in.
    #
    # `state` is optional and threaded straight through to #field_skill? for the
    # same reason #field_skills takes it: a special item invoking an Escape or
    # Teleport skill needs `Game::State` to know whether one is actually
    # available (access flag + a registered target), which a bare item lookup
    # has no way to answer. Omitting it reads such an item as unusable, exactly
    # as the old hard-coded "no state" call always did.
    def field_usable?(id, state = nil)
      it = db_item(id)
      return false unless it && item_count(id) > 0
      case it.type
      when ITEM_MEDICINE, ITEM_SKILL_BOOK, ITEM_SEED then true
      when ITEM_SWITCH then item_field_occasion?(it)
      when ITEM_SPECIAL then field_skill?(db_skill(it.skill_id), state)
      else false
      end
    end

    # An item's occasion flags, read by the **field name the format actually
    # uses**. RPG2000 gives an item three of them and they are not
    # interchangeable (EasyRPG's `Game_Party::IsItemUsable`):
    #
    #   occasion_field1 (37) — set means "field only", i.e. **bars battle use**;
    #                          it is what gates a medicine in a fight.
    #   occasion_field2 (57) — a **switch** item's field flag.
    #   occasion_battle (58) — a **switch** item's battle flag.
    #
    # This build used to ask every item for `occasion_field`, which is not a
    # field either real row has — so the lookup fell through to its "no flag,
    # assume usable" default on every genuine item and the gate never once fired.
    # Only hand-built fixtures, which did define that name, ever exercised it.
    def item_field_occasion?(it)
      return it.occasion_field2 if it.respond_to?(:occasion_field2)
      true
    end

    def item_battle_occasion?(it)
      return it.occasion_battle if it.respond_to?(:occasion_battle)
      true
    end

    # Whether `it` is flagged field-only (occasion_field1), which is what keeps a
    # medicine out of a battle.
    def item_field_only?(it)
      it.respond_to?(:occasion_field1) ? it.occasion_field1 : false
    end

    # Whether item `id` is a switch item (turns on a game switch when used).
    def switch_item?(id)
      it = db_item(id)
      !it.nil? && it.type == ITEM_SWITCH
    end

    # Use a switch item from the field menu: consume one and return the id of the
    # switch to turn on (the caller owns the switch table). nil when `id` is not a
    # switch item the party holds, so nothing is consumed. Matches EasyRPG, where
    # UseItem consumes and the scene flips the switch.
    def use_switch_item(id)
      return nil unless switch_item?(id) && item_count(id) > 0
      lose_item(id, 1)
      db_item(id).switch_id
    end

    # The bag's field-usable items as `[id, count]` pairs in ascending id order,
    # for the item menu's list. `state` is optional, passed straight through to
    # #field_usable? (see there) for a special item invoking an Escape/Teleport
    # skill.
    def field_items(state = nil)
      @items.keys.sort.select { |id| field_usable?(id, state) }
            .map { |id| [id, item_count(id)] }
    end

    # The HP and SP a medicine restores to `actor`: the flat amount plus a
    # percentage of the actor's maximum, summed with RPG2000's integer math.
    def item_recovery(it, actor)
      hp = (it.recover_hp || 0) + (actor.max_hp * (it.recover_hp_rate || 0)) / 100
      mp = (it.recover_sp || 0) + (actor.max_mp * (it.recover_sp_rate || 0)) / 100
      [hp, mp]
    end

    # The status-condition ids a medicine cures. RPG2000 items list affected
    # states in `state_set` (a 0/1 byte per state, index i -> state id i+1), and a
    # medicine **cures** them; `reverse_state_effect` is what flips it into
    # inflicting them, exactly as it does for a skill (see #skill_state_ids).
    # Curing is unconditional, matching EasyRPG's item algorithm.
    #
    # The polarity used to be read the other way round -- cures only when the
    # flag is *set* -- which meant no shipped curative item cured anything.
    # Neither test bed sets the flag on any item at all, while Nepheshel has 13
    # medicines naming states without it and mtf-meido-action one: アンチドーテ
    # and ユニコーンの角 name all fifteen states, and 気付け薬 / ドラゴンブラッド
    # name state 1 alone, which is 戦闘不能 -- they are revives. Reading those as
    # "cures nothing" made every antidote and every revive item in both games
    # inert, in the menu and in a fight alike.
    #
    # A medicine that really does *inflict* (the flag set): see
    # #item_inflicted_states below, which mirrors this the same way
    # #skill_inflicted_states mirrors #skill_cured_states for a field skill.
    def item_cured_states(it)
      return [] if it.respond_to?(:reverse_state_effect) && it.reverse_state_effect
      item_state_ids(it)
    end

    # The states item `it` names in its `state_set` (a 0/1 byte per state, index
    # i -> state id i+1), regardless of polarity. Shared by #item_cured_states
    # and #item_inflicted_states, mirroring #skill_state_ids.
    def item_state_ids(it)
      set = it.state_set
      return [] unless set
      out = []
      set.each_index { |i| out.push(i + 1) if set[i] && set[i] != 0 }
      out
    end

    # The states item `it` inflicts (the reverse case, `reverse_state_effect`
    # set): the opposite polarity to #item_cured_states, exactly as
    # #skill_inflicted_states is to #skill_cured_states for a field skill (both
    # port EasyRPG's identical `reverse_state_effect` branch, `Item::vExecute`
    # for an item and `Game_Battler::UseSkill` for a skill). No item in either
    # test bed sets the flag, so this was previously left unbuilt entirely --
    # unlike the skill side, which already has the mechanism -- even though
    # using the item this way was reachable and silently did nothing at all.
    def item_inflicted_states(it)
      return [] unless it.respond_to?(:reverse_state_effect) && it.reverse_state_effect
      item_state_ids(it)
    end

    # 蘇生専用 (`ko_only`): an item that does nothing at all to a target who is
    # still standing. RPG_RT returns from the item algorithm *before* the HP and
    # the state effects are computed (EasyRPG's `Item::vExecute`, whose
    # `item.ko_only && !IsDead()` branch precedes both), so this is not "cures
    # nothing" -- the percentage HP restore does not land either.
    #
    # Every such item in both test beds is a revive: Nepheshel's ドラゴンブラッド,
    # ドラゴンハート and 気付け薬 and mtf-meido-action's Stimulant all cure
    # 戦闘不能 and restore 25 / 100 / 3 / 25 percent of max HP. Reading the flag
    # as nothing let all four be spent on a living, wounded ally for their HP.
    def ko_only_blocked?(it, actor)
      return false unless it.respond_to?(:ko_only) && it.ko_only
      return false if actor.nil?
      !actor.dead?
    end

    # 使用可能キャラ (`actor_set`, item field 62): whether item `it` names
    # `actor_id` among the specific characters allowed to use or equip it at
    # all. The one restriction list gates both uses (EasyRPG's
    # `Game_Actor::IsItemUsable`, read by `Game_Party::IsItemUsable`'s
    # per-target overload for using an item and by `ChangeEquipment` for
    # equipping one) — a book, seed, medicine or piece of gear can all be
    # limited to a named cast member this way, not just weapons/armour. An
    # actor id the array is too short to reach defaults to allowed, the same
    # "missing entry reads as the field's default" rule this runtime's other
    # bit-array fields (terrain_set, class_set-adjacent ones) already follow.
    def item_usable_by?(it, actor_id)
      return true unless it.respond_to?(:actor_set) && it.actor_set
      return true if actor_id.nil?
      set = it.actor_set
      idx = actor_id - 1
      return true if idx < 0 || set.size <= idx
      set[idx] ? true : false
    end

    # Whether using item `id` on `actor` would change anything, so the menu can
    # grey out a no-op. A medicine is effective when the target is below full
    # HP/SP and it restores some (RPG_RT forbids using a pure-recovery item on a
    # full target); a skill book is effective when the target does not already
    # know its skill.
    def item_effective?(id, actor)
      it = db_item(id)
      return false unless it && actor
      return false unless item_usable_by?(it, actor.id)
      case it.type
      when ITEM_MEDICINE
        return false if ko_only_blocked?(it, actor)
        hp, mp = item_recovery(it, actor)
        (hp > 0 && actor.hp < actor.max_hp) || (mp > 0 && actor.mp < actor.max_mp) ||
          item_cured_states(it).any? { |s| actor.state?(s) } ||
          item_inflicted_states(it).any? { |s| !actor.state?(s) }
      when ITEM_SKILL_BOOK
        s = it.skill_id
        !s.nil? && s != 0 && !actor.knows_skill?(s)
      when ITEM_SEED
        seed_boosts(it).any? { |b| b != 0 }
      when ITEM_SWITCH
        true # a switch item always flips its switch
      when ITEM_SPECIAL
        # Judged by the skill it invokes, exactly as casting that skill would be
        # -- but free: the item is the cost, and its user need not know the skill.
        skill_effective?(actor, it.skill_id, actor, true)
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
      when ITEM_SPECIAL then use_special_item(it, id, actor)
      else []
      end
    end

    # A special item (特殊) invokes the skill in its `skill_id` on `actor`, with
    # the item taking the place of the SP cost: the user pays nothing and need not
    # have learnt the skill. One is consumed only when the cast actually did
    # something, matching how the other item kinds here refuse to be wasted.
    #
    # Only for a skill #cast_skill can express -- one that changes HP/SP or a
    # status condition. An Escape or Teleport skill returns a warp destination
    # instead of a set of affected actors, which does not fit this method's
    # return shape (and needs `Game::State` besides), so those go through
    # #use_special_escape_item / #use_special_teleport_item instead -- the same
    # reason a switch item bypasses #use_item for #use_switch_item.
    def use_special_item(it, id, actor)
      return [] unless actor && item_usable_by?(it, actor.id)
      affected = cast_skill(actor, it.skill_id, actor, true)
      lose_item(id, 1) unless affected.empty?
      affected
    end

    # A special item (特殊) invoking an **Escape**-type skill: consumes the item
    # and returns the registered escape destination for the caller to warp to
    # (the same `{map_id:, x:, y:}` shape #cast_escape_skill returns), free —
    # mirroring #use_special_item's own "the item is the cost" rule via
    # #cast_escape_skill's `free` flag, so the user need not know the skill and
    # spends no SP for it. nil when `id` does not name a special item invoking
    # an Escape skill, `actor` may not use it (#item_usable_by?), or Escape is
    # not currently available (#escape_skill_available?) — and then nothing is
    # consumed, mirroring `Scene::SkillMenu#apply_escape_skill`'s own gate.
    def use_special_escape_item(id, actor, state)
      it = db_item(id)
      return nil unless it && it.type == ITEM_SPECIAL && actor && item_usable_by?(it, actor.id)
      target = cast_escape_skill(actor, it.skill_id, state, true)
      return nil unless target
      lose_item(id, 1)
      target
    end

    # The same for a special item invoking a **Teleport**-type skill, to the
    # registered destination named by `map_id` (the caller's own picker chooses
    # which — see `Scene::SkillMenu`'s teleport list, which this mirrors).
    def use_special_teleport_item(id, actor, state, map_id)
      it = db_item(id)
      return nil unless it && it.type == ITEM_SPECIAL && actor && item_usable_by?(it, actor.id)
      target = cast_teleport_skill(actor, it.skill_id, state, map_id, true)
      return nil unless target
      lose_item(id, 1)
      target
    end

    # A single-target medicine (scope 0) heals `actor`; an all-ally medicine
    # (scope 1) heals the whole party regardless of `actor`. Applies the recovery
    # (clamped to each target's maxima) and cures the item's status conditions,
    # and consumes one from the bag only when it actually did something to someone
    # (so using it on a full, unafflicted party wastes nothing).
    def use_medicine(it, id, actor)
      targets = it.scope == 1 ? @actors : [actor].compact
      cured = item_cured_states(it)
      inflicted = item_inflicted_states(it)
      affected = []
      targets.each do |t|
        # A 蘇生専用 item passes over anyone still standing without touching
        # them -- not even the HP restore -- which is what keeps an all-party
        # revive from topping up the members who never fell. An actor_set
        # restriction does the same for a member the item simply is not
        # usable on, even under an all-party scope.
        next if ko_only_blocked?(it, t) || !item_usable_by?(it, t.id)
        changed = false
        # Cure first: a revive item (curing 戦闘不能) stands the actor back up so
        # the HP recovery below lands instead of being blocked as a no-op.
        cured.each do |s|
          if t.state?(s)
            t.remove_state(s)
            changed = true
          end
        end
        landed = false
        inflicted.each do |s|
          unless t.state?(s)
            t.add_state(s)
            changed = true
            landed = true
          end
        end
        # RPG_RT's crowding-out rule (see Game::States::PRUNE_GAP): a state a
        # poison item just inflicted may itself immediately push out one
        # already held, or be pushed out by one already held that outranks it
        # -- the same prune #cast_skill applies for a skill's own inflicted
        # states.
        t.states = Game::States.prune(t.states, state_table) if landed
        hp, mp = item_recovery(it, t)
        before_hp = t.hp
        before_mp = t.mp
        t.change_hp(hp) if hp > 0
        t.change_mp(mp) if mp > 0
        changed ||= t.hp != before_hp || t.mp != before_mp
        affected.push(t) if changed
      end
      lose_item(id, 1) unless affected.empty?
      affected
    end

    # A skill book teaches its skill (item field 53) to `actor` if the actor does
    # not already know it, consuming one book. A book with no skill, or used on an
    # actor who already knows the skill, does nothing and is not consumed.
    def use_skill_book(it, id, actor)
      skill = it.skill_id
      return [] unless actor && item_usable_by?(it, actor.id) &&
                       skill && skill != 0 && !actor.knows_skill?(skill)
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
      return [] unless actor && item_usable_by?(it, actor.id)
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

    # Held items equippable in equipment `slot` (0..4) on `actor`, as
    # [id, count] pairs in ascending id order -- the candidate list for the
    # equip menu's chosen slot. `actor` matters two ways: for the shield slot
    # (1), a 二刀流 (double_hand) actor's shield slot is a second weapon slot,
    # so it lists weapons there instead of shields -- mirroring EasyRPG's
    # `Window_EquipItem`, which retargets the whole slot to `weapon` for such
    # an actor before filtering, rather than offering both kinds; and an
    # actor_set restriction (#item_usable_by?) drops an item this particular
    # actor cannot wear at all, matching `Game_Actor::IsItemUsable` (which
    # `ChangeEquipment` reads the same way). Both actor-dependent filters are
    # simply skipped when no `actor` is given.
    def equip_candidates(slot, actor = nil)
      slot = Actor::WEAPON_SLOT if slot == Actor::SHIELD_SLOT && actor && actor.double_hand?
      @items.keys.sort.select do |id|
        item_count(id) > 0 && equip_slot_for(id) == slot &&
          (actor.nil? || item_usable_by?(db_item(id), actor.id))
      end.map { |id| [id, item_count(id)] }
    end

    # Whether held item `id` is a genuine #equip_candidates entry for `slot` on
    # `actor` -- mirrors that method's own retargeting and actor_set filter
    # exactly, so a `slot` argument #equip_from_bag receives can never accept
    # anything the candidate list would not itself have offered (in either
    # direction: a 二刀流 actor's shield slot accepts a weapon, not a weapon
    # *and* a shield; an actor this item is not usable by accepts nothing).
    def equip_candidate_for?(actor, id, slot)
      base = equip_slot_for(id)
      return false if base.nil?
      return false if actor && !item_usable_by?(db_item(id), actor.id)
      if slot == Actor::SHIELD_SLOT && actor && actor.double_hand?
        base == Actor::WEAPON_SLOT
      else
        base == slot
      end
    end

    # Equip bag item `item_id` on `actor` into equipment `slot`, moving it
    # through the inventory the way the equip menu does: take one from the bag,
    # equip it into that slot, and return the previously-equipped item (if any)
    # to the bag. `slot` defaults to the one the item's own type dictates (so
    # the Item menu's field-usable-item paths that never pass one keep working
    # unchanged); the equip menu always passes the slot its candidate list
    # (#equip_candidates) was built for, which is what lets a 二刀流 actor's
    # second weapon land in the shield slot rather than overwriting the first.
    # A no-op returning false unless the party holds the item and it is a
    # genuine candidate for that slot on that actor (#equip_candidate_for?);
    # true on success. (Unlike the Change Equipment event command, which does
    # not touch the bag, the menu swaps through it.)
    def equip_from_bag(actor, item_id, slot = nil)
      return false unless actor && item_count(item_id) > 0
      slot ||= equip_slot_for(item_id)
      return false if slot.nil? || !equip_candidate_for?(actor, item_id, slot)
      previous = actor.equipment[slot]
      # A 両手持ち weapon empties the other hand; whatever it was holding comes
      # back to the bag alongside the item this slot displaced.
      freed = actor.equip_item(item_id, slot)
      lose_item(item_id, 1)
      gain_item(previous, 1) if previous && previous != 0
      gain_item(freed, 1) if freed && freed != 0
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
    # 2 escape, 3 switch. Skill scope (field 12): 0 single enemy, 1 all enemies,
    # 2 the caster, 3 a single ally, 4 all allies.
    SKILL_NORMAL = 0
    SKILL_TELEPORT = 1
    SKILL_ESCAPE = 2
    SKILL_SWITCH = 3
    # RPG2003 numbers its **subskill** categories from 4 up (liblcf's
    # `Skill::Type_subskill`): a 2003 game sorts its skills into custom battle
    # commands, and the category id lands in this same field. Such a skill is an
    # ordinary skill — the number only says which menu it is filed under.
    SKILL_SUBSKILL = 4

    # Whether `sk` behaves as an ordinary HP/SP/stat skill: type 0, or any RPG2003
    # subskill category. Testing `type == SKILL_NORMAL` instead hid **57 of
    # mtf-meido-action's 134 skills** — 43% of the game, including every one of
    # its healing lines (Heal / Recovery / Cure / Raise are category 5) and its
    # elemental attack lines — from both the field menu and the battle menu.
    def self.normal_skill?(sk)
      t = sk.type
      t == SKILL_NORMAL || t >= SKILL_SUBSKILL
    end

    # The database row for a skill id, or nil when the database has no skill table
    # (a bare fixture) or no such row.
    def db_skill(id)
      return nil unless @db.respond_to?(:skill)
      @db.skill[id]
    end

    # The database's state (`situation`) table, for Game::States lookups --
    # priority, display name/colour, message text. nil for a fixture without
    # one, which every Game::States accessor already tolerates.
    def state_table
      @db.respond_to?(:situation) ? @db.situation : nil
    end

    # The SP `caster` pays to cast skill `sk`: a fixed cost (sp_type 0) or a
    # percentage of the caster's max SP (sp_type 1). Mirrors EasyRPG's
    # CalculateSkillCost (the half-SP-cost modifier is a later refinement).
    def skill_cost(sk, caster)
      cost =
        if sk.sp_type == 1
          caster.max_mp * (sk.sp_percent || 0) / 100
        else
          sk.sp_cost || 0
        end
      # MP消費半分 gear halves the bill, rounding **up** so a 1-SP skill still
      # costs 1 (EasyRPG's `cost = (cost + 1) / 2`). Asked of whatever the caller
      # handed over — a Game::Actor in the menus, a battle snapshot in a fight.
      return cost unless caster.respond_to?(:half_sp_cost?) && caster.half_sp_cost?
      (cost + 1) / 2
    end

    # `caster`'s known skills usable from the field menu, as `[skill_id, cost]`
    # pairs in ascending id order: anything flagged `occasion_field` that either
    # behaves as an ordinary skill and targets the caster or an ally (scope >= 2,
    # since the field menu has no enemy to aim at) or is a **switch** skill, which
    # has no target at all — it just turns its switch on. Nepheshel's companions
    # are summoned and dismissed exactly this way (skills 120–125, "ファルを召還"
    # and friends, each flipping the switch its common event watches).
    #
    # `state` is optional and only read for the Escape / Teleport types below —
    # every other caller (the host-side fixture checks included) can omit it and
    # gets the old scope/occasion-only behaviour.
    def field_skills(caster, state = nil)
      return [] unless caster
      caster.skills.sort.select { |sid| field_skill?(db_skill(sid), state) }
            .map { |sid| [sid, skill_cost(db_skill(sid), caster)] }
    end

    # Whether skill row `sk` belongs in the field menu.
    #
    # The `occasion_field` / `occasion_battle` flags gate **switch skills only**.
    # That is not a simplification — it is what RPG_RT does (EasyRPG's
    # `Algo::IsSkillUsable` reads them in the `Type_switch` arm and nowhere
    # else), and the RPG2000 editor only offers the 使用可能な場面 checkboxes for
    # a スイッチ skill in the first place. The bytes agree exactly: Nepheshel
    # writes chunks 18/19 for 12 of its 306 skills and those 12 are precisely its
    # 12 switch skills, while mtf-meido-action, which has no switch skill, writes
    # neither chunk for any of its 134. Gating every skill on `occasion_battle`
    # (default false, so almost never set) is what used to leave the battle skill
    # menu holding 12 skills in one game and none at all in the other.
    #
    # An ordinary skill outside battle needs a target the field can offer (scope
    # >= 2, i.e. self or allies -- there is no enemy to aim at) and has to do
    # something once there: change HP/SP, or inflict a state.
    def field_skill?(sk, state = nil)
      return false unless sk
      case sk.type
      when SKILL_TELEPORT
        teleport_skill_available?(state)
      when SKILL_ESCAPE
        escape_skill_available?(state)
      when SKILL_SWITCH
        field_occasion?(sk)
      else
        return false unless sk.scope >= 2
        # The raw state set, not #skill_inflicted_states: a plain antidote cures
        # rather than inflicts (`reverse_state_effect` off), and curing poison
        # between fights is the whole point of the field skill menu.
        sk.affect_hp || sk.affect_sp || !skill_state_ids(sk).empty?
      end
    end

    # Whether the Escape skill type (1) is usable right now: the party's escape
    # access is on, a Set Escape Target has registered a destination, and the
    # party is not flying (boarded the airship). Mirrors EasyRPG's
    # `Algo::IsSkillUsable`'s `Type_escape` arm, minus the "not in battle" term —
    # #battle_skill? already excludes both types unconditionally, matching
    # RPG_RT's own field-only offer of them. `state` is nil for callers that
    # have none (bare fixtures, the fixture-only test harnesses), which reads as
    # unusable exactly like the old "always false" behaviour.
    def escape_skill_available?(state)
      return false unless state
      state.escape_access && !state.escape_target.nil? && !flying?(state)
    end

    # Whether the Teleport skill type (2) is usable right now: teleport access is
    # on, at least one destination has been registered by a Set Teleport Target,
    # and the party is not flying. Which registered destination is used is a
    # separate choice the field menu offers (see Scene::SkillMenu) — unlike
    # Escape, RPG_RT's Teleport type has more than one possible target and pops a
    # picker (EasyRPG's `Scene_Teleport` / `Window_Teleport`, which lists every
    # registered map by name and does not itself filter by the target's own
    # switch field — that field round-trips through the save but the reference
    # implementation never reads it back, so it is left unconsumed here too).
    def teleport_skill_available?(state)
      return false unless state
      state.teleport_access && !state.teleport_targets.empty? && !flying?(state)
    end

    # Whether the party is currently riding the airship — the one vehicle RPG_RT
    # bars Escape/Teleport from (a boat or ship is forced off first instead, see
    # #cast_escape_skill / #cast_teleport_skill).
    def flying?(state)
      state.respond_to?(:boarded) && state.boarded == :airship
    end

    # Cast an Escape (type 1) skill: spend `caster`'s SP and return the
    # registered escape destination as `{map_id:, x:, y:}` for the scene to jump
    # to, or nil when `sid` is not a castable, available Escape skill. Matches
    # EasyRPG's Scene_Skill, which jumps straight to `Game_Targets`' single
    # escape target with no picker.
    #
    # `free`, like #cast_skill's own flag, casts without the knows-it /
    # can-afford-it gate and without spending SP — used by
    # #use_special_escape_item for a special item invoking this type, where the
    # item is the cost.
    def cast_escape_skill(caster, sid, state, free = false)
      sk = db_skill(sid)
      return nil unless sk && sk.type == SKILL_ESCAPE
      return nil unless (free ? !caster.nil? : can_cast?(caster, sid)) &&
                         escape_skill_available?(state)
      target = state.escape_target
      return nil unless target
      caster.change_mp(-skill_cost(sk, caster)) unless free
      { map_id: target[:map_id], x: target[:x], y: target[:y] }
    end

    # Cast a Teleport (type 2) skill to the registered destination named by
    # `map_id`: spend `caster`'s SP and return `{map_id:, x:, y:}`, or nil when
    # `sid` is not a castable, available Teleport skill or `map_id` names no
    # registered target (the picker only offers ids that do, so this is a
    # defensive check rather than one real play can trigger).
    #
    # `free` mirrors #cast_escape_skill's own flag, for
    # #use_special_teleport_item.
    def cast_teleport_skill(caster, sid, state, map_id, free = false)
      sk = db_skill(sid)
      return nil unless sk && sk.type == SKILL_TELEPORT
      return nil unless (free ? !caster.nil? : can_cast?(caster, sid)) &&
                         teleport_skill_available?(state)
      target = state.teleport_targets[map_id]
      return nil unless target
      caster.change_mp(-skill_cost(sk, caster)) unless free
      { map_id: map_id, x: target[:x], y: target[:y] }
    end

    # Whether `sk`'s field-menu offer depends on runtime state (`Game::State`)
    # that a caller checking `#field_skill?` / `#battle_skill?` alone has no way
    # to supply — the Escape (1) and Teleport (2) types, whose availability
    # depends on the party's access flags and registered targets rather than the
    # skill row alone. Used by the testbed harness, which builds a party with no
    # running map/interpreter behind it, to tell "this skill type is legitimately
    # state-gated" apart from "no menu offers this skill at all".
    def unsupported_field_skill?(sk)
      !sk.nil? && (sk.type == SKILL_ESCAPE || sk.type == SKILL_TELEPORT)
    end

    # Whether a **switch** skill's field / battle occasion flag is set. Defaults
    # to usable when the row (a bare fixture) carries no flag.
    def field_occasion?(sk)
      sk.respond_to?(:occasion_field) ? sk.occasion_field : true
    end

    # Whether skill `sid` is a switch skill (turns a game switch on, no target).
    def switch_skill?(sid)
      sk = db_skill(sid)
      !sk.nil? && sk.type == SKILL_SWITCH
    end

    # Cast a switch skill: spend the caster's SP and return the id of the switch
    # to turn on, so the caller can flip it (the switch table lives on the state,
    # not the party -- the same split #use_switch_item already uses). nil when
    # `sid` is not a switch skill the caster can cast, and then nothing is spent.
    def cast_switch_skill(caster, sid)
      return nil unless switch_skill?(sid) && can_cast?(caster, sid)
      sk = db_skill(sid)
      caster.change_mp(-skill_cost(sk, caster))
      sk.switch_id
    end

    # Whether `caster` can cast skill `sid` right now: it knows the skill, can
    # pay its SP cost, and (see #weapon_attribute_ready?) is not missing a
    # required weapon-type Attribute.
    def can_cast?(caster, sid)
      sk = db_skill(sid)
      !sk.nil? && caster && caster.knows_skill?(sid) &&
        caster.mp >= skill_cost(sk, caster) && weapon_attribute_ready?(caster, sk)
    end

    # Whether `caster` satisfies `sk`'s weapon-type Attribute requirement, if
    # it has one: a skill whose Attack/Defense Attribute (`attribute_effects`,
    # the same field #skill_attributes reads for damage scaling) names an
    # attribute the database flags weapon-type (the `property` table's `type`
    # field, 0) can only be cast while a weapon carrying that same attribute
    # is equipped -- armour carrying it does not satisfy the requirement
    # (yado.tk 028_tokushu_huka, corroborated independently via the Attribute
    # database page). A magic-type attribute (`type` 1), or a skill with no
    # attribute at all, gates nothing. A skill naming more than one
    # weapon-type attribute needs all of them covered, one weapon or several
    # (dual-wield) between them -- there is no test-bed skill with two to
    # confirm that against, so it is the direct reading of "a weapon carrying
    # that same attribute" applied per attribute rather than a guess at
    # something looser.
    def weapon_attribute_ready?(caster, sk)
      return true unless sk
      ids = skill_attributes(sk).select { |aid| attribute_weapon_type?(aid) }
      return true if ids.empty?
      equipped = caster.respond_to?(:weapon_attributes) ? caster.weapon_attributes : []
      ids.all? { |aid| equipped.include?(aid) }
    end

    # Whether attribute `aid` is the database's weapon-type (field 2, value 0,
    # as opposed to magic-type 1). An id the `property` table does not define
    # (a fixture, or an id past what a real database ever leaves undefined)
    # reads as magic-type -- the permissive default, since gating a skill on
    # an attribute this build cannot look up would lock it out with no way
    # for the player to fix it.
    def attribute_weapon_type?(aid)
      return false unless @db.respond_to?(:property) && @db.property
      row = @db.property[aid]
      row && row.respond_to?(:type) && row.type == 0 ? true : false
    end

    # -- stat-affecting states (halve/double ATK/DEF/SPI/AGI), for skills -----
    #
    # A state's `affect_type` (0 halve / 1 double / 2 no change) and its
    # `affect_attack` / `affect_defense` / `affect_spirit` flags (see
    # Game::Battle's own copy of this, which #skill_effect / #skill_defence_term
    # used not to read at all) apply here too -- ported the same way, against
    # this class's own `@db.situation` rather than a Battle's `@states`, since
    # a skill's caster/target is sometimes a bare Game::Actor with no Battle
    # behind it at all (field/menu skill use, where states matter just as
    # much: a Weaken picked up mid-fight should blunt a Cure cast on the map
    # afterwards too, matching EasyRPG's Game_Battler::GetAtk() being the one
    # accessor every context reads through, not a battle-only variant).
    def stat_mode(b, stat_flag)
      return :normal unless @db.respond_to?(:situation) && @db.situation
      half = false; dbl = false
      (b.respond_to?(:states) ? (b.states || []) : []).each do |sid|
        d = @db.situation[sid]
        next unless d && d.respond_to?(stat_flag) && d.send(stat_flag)
        case d.respond_to?(:affect_type) ? d.affect_type : 2
        when 0 then half = true
        when 1 then dbl = true
        end
      end
      return :double if dbl && !half
      return :half if half && !dbl
      :normal
    end

    def adjust_stat(value, mode)
      case mode
      when :double then value * 2
      when :half then [value / 2, 1].max
      else value
      end
    end

    def effective_atk(b); adjust_stat(b.atk, stat_mode(b, :affect_attack)); end
    def effective_int(b); adjust_stat(b.int, stat_mode(b, :affect_spirit)); end

    def effective_def(b)
      adjust_stat((b.respond_to?(:def) ? b.def : 0) || 0, stat_mode(b, :affect_defense))
    end

    def effective_spi(b)
      adjust_stat((b.respond_to?(:spi) ? b.spi : 0) || 0, stat_mode(b, :affect_spirit))
    end

    # The base HP/SP amount a recovery skill restores, per RPG2000's formula
    # `power + physical_rate*attack/20 + magical_rate*spirit/40` (spirit is the
    # `int` stat), computed from the caster deterministically -- battle applies a
    # +/- variance, but field/menu use does not. Confirmed against EasyRPG's
    # Algo::CalcSkillEffect (the ally-heal path has no target-defence term).
    def skill_effect(sk, caster)
      (sk.power || 0) +
        (sk.physical_rate || 0) * effective_atk(caster) / 20 +
        (sk.magical_rate || 0) * effective_int(caster) / 40
    end

    # How much of an enemy-scope skill's effect the target's own stats absorb.
    #
    # RPG_RT scales the defence by the *same two rates* that built the effect --
    # `physical_rate * def / 40 + magical_rate * spi / 80` (EasyRPG's
    # `Algo::CalcSkillEffect`) -- so a physical skill is blunted by armour and a
    # magical one by the target's spirit. This used to be a flat `def / 4`, which
    # only coincides with the real term when the skill is purely physical at rate
    # 10: 211 of Nepheshel's 276 enemy-scope skills and 112 of mtf's 116 differ
    # from it against a def-40 / spirit-40 target, and 141 and 81 of them are
    # *purely magical*, so they were being blunted by armour the caster's spell
    # should not have cared about at all.
    #
    # 0 when the skill ignores defence (RPG_RT skips the whole subtraction) or
    # there is no target to read stats from.
    def skill_defence_term(sk, target)
      return 0 if target.nil? || skill_ignores_defence?(sk)
      dfn = effective_def(target)
      spi = effective_spi(target)
      (sk.physical_rate || 0) * dfn / 40 + (sk.magical_rate || 0) * spi / 80
    end

    # 防御無視 (`ignore_defense`): the effect lands undiminished. 13 of
    # Nepheshel's skills and 7 of mtf's set it, and nothing read it, so every
    # armour-piercing spell in both games was being blunted like any other.
    def skill_ignores_defence?(sk)
      sk.respond_to?(:ignore_defense) ? (sk.ignore_defense ? true : false) : false
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

    # The states a field skill changes, from its `state_effects` (a 0/1 byte per
    # state, index i -> state id i+1). Per EasyRPG's Game_Battler::UseSkill, the
    # field path is deterministic (no accuracy roll): with `reverse_state_effect`
    # cleared (the default) the skill *cures* those states, with it set it
    # *inflicts* them -- the opposite polarity to items, where the reverse flag
    # marks the cure.
    def skill_state_ids(sk)
      set = sk.respond_to?(:state_effects) ? sk.state_effects : nil
      return [] unless set
      out = []
      set.each_index { |i| out.push(i + 1) if set[i] && set[i] != 0 }
      out
    end

    # The states a field skill cures (the default, non-reverse case).
    def skill_cured_states(sk)
      return [] if sk.respond_to?(:reverse_state_effect) && sk.reverse_state_effect
      skill_state_ids(sk)
    end

    # The states a field skill inflicts (the reverse case).
    def skill_inflicted_states(sk)
      return [] unless sk.respond_to?(:reverse_state_effect) && sk.reverse_state_effect
      skill_state_ids(sk)
    end

    # Whether casting skill `sid` on `target` would change anything -- used to grey
    # out a no-op (e.g. a heal on an already-full ally). Requires the caster to be
    # able to cast it at all. A skill that cures a condition the target actually
    # has (or inflicts one it lacks) is usable even when HP/SP are full.
    def skill_effective?(caster, sid, target, free = false)
      sk = db_skill(sid)
      return false unless sk && (free ? !caster.nil? : can_cast?(caster, sid))
      amount = skill_effect(sk, caster)
      cured = skill_cured_states(sk)
      inflicted = skill_inflicted_states(sk)
      skill_targets(sk, caster, target).any? do |t|
        (amount > 0 && sk.affect_hp && t.hp < t.max_hp) ||
          (amount > 0 && sk.affect_sp && t.mp < t.max_mp) ||
          cured.any? { |s| t.state?(s) } ||
          inflicted.any? { |s| !t.state?(s) }
      end
    end

    # Cast field skill `sid` from `caster` on `target` (scope-dependent). Applies
    # the skill's status changes then restores HP and/or SP by the skill effect to
    # each target (clamped), then spends the caster's SP -- but only when it
    # actually helped someone, so a wasted cast (everyone full and unafflicted)
    # costs nothing. States are applied before HP so a cure that clears the death
    # state revives the target and the recovery then lands. Returns the affected
    # actors.
    #
    # `free` casts without the knows-it / can-afford-it gate and without spending
    # SP: a **special item** invokes its skill that way, since the item is the
    # cost and the user need not have learnt the skill at all.
    def cast_skill(caster, sid, target = nil, free = false)
      sk = db_skill(sid)
      return [] unless sk && (free ? !caster.nil? : can_cast?(caster, sid))
      amount = skill_effect(sk, caster)
      cured = skill_cured_states(sk)
      inflicted = skill_inflicted_states(sk)
      affected = []
      skill_targets(sk, caster, target).each do |t|
        changed = false
        cured.each do |s|
          if t.state?(s)
            t.remove_state(s)
            changed = true
          end
        end
        landed = false
        inflicted.each do |s|
          unless t.state?(s)
            t.add_state(s)
            changed = true
            landed = true
          end
        end
        # RPG_RT's crowding-out rule (see Game::States::PRUNE_GAP): a state
        # just landed may itself immediately push out one already held, or
        # be pushed out by one already held that outranks it.
        t.states = Game::States.prune(t.states, state_table) if landed
        before_hp = t.hp
        before_mp = t.mp
        t.change_hp(amount) if sk.affect_hp && amount > 0
        t.change_mp(amount) if sk.affect_sp && amount > 0
        changed ||= t.hp != before_hp || t.mp != before_mp
        affected.push(t) if changed
      end
      caster.change_mp(-skill_cost(sk, caster)) unless free || affected.empty?
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

    # Battle skill scopes the menu offers: 0 single enemy, 1 all enemies, 2 the
    # caster, 3 a single ally, 4 all allies.
    BATTLE_SKILL_SCOPES = [0, 1, 2, 3, 4].freeze

    # `actor`'s known skills usable in battle, as `[skill_id, cost]` pairs in
    # ascending id order: those flagged `occasion_battle` that either behave as an
    # ordinary skill with a scope the battle menu can aim, or are a **switch**
    # skill (no target — Nepheshel's 突撃準備 / 呪文詠唱 charge-ups are these).
    # `caster` is the battle snapshot the SP cost is figured from.
    def battle_skills(actor, caster)
      return [] unless actor && caster
      actor.skills.sort.select { |sid| battle_skill?(db_skill(sid)) }
           .map { |sid| [sid, skill_cost(db_skill(sid), caster)] }
    end

    # Whether skill row `sk` belongs in the battle menu. Mirrors #field_skill?:
    # the occasion flags gate switch skills only, an escape / teleport skill is
    # never usable in a fight, and an ordinary skill always is — RPG_RT asks
    # nothing else of it once a battle is running.
    def battle_skill?(sk)
      return false unless sk
      case sk.type
      when SKILL_ESCAPE, SKILL_TELEPORT then false
      when SKILL_SWITCH then battle_occasion?(sk)
      else BATTLE_SKILL_SCOPES.include?(sk.scope)
      end
    end

    # Whether a **switch** skill's battle occasion flag is set (see
    # #field_skill? for why only switch skills consult these). Defaults to usable
    # when the row (a bare fixture) carries no flag.
    def battle_occasion?(sk)
      sk.respond_to?(:occasion_battle) ? sk.occasion_battle : true
    end

    # Whom a battle skill targets: :enemy (scope 0), :all_enemy (1), :self (2),
    # :all_ally (4) or a single :ally (3, the default).
    def battle_skill_target(sk)
      case sk.scope
      when 0 then :enemy
      when 1 then :all_enemy
      when 2 then :self
      when 4 then :all_ally
      else :ally
      end
    end

    # A skill's state-infliction accuracy (its `hit` field, default 100), used as
    # the per-state roll when an attack skill inflicts its `state_effects`.
    # 吸収 (`absorb_damage`): the caster gains the HP the skill takes. 13 of
    # Nepheshel's skills and 5 of mtf-meido-action's set it, and nothing read it,
    # so every drain spell in both games was a plain attack spell.
    def skill_absorbs?(sk)
      sk.respond_to?(:absorb_damage) ? (sk.absorb_damage ? true : false) : false
    end

    def skill_hit(sk)
      sk.respond_to?(:hit) ? (sk.hit || 100) : 100
    end

    # A skill's damage variance (its `variance` field on the 0-10 scale, default
    # 4), the spread applied to its battle damage when the fight rolls variance.
    def skill_variance(sk)
      sk.respond_to?(:variance) ? (sk.variance || 4) : 4
    end

    # The elemental attribute ids a skill applies — its `attribute_effects` bool
    # array (field 44), a flag per attribute — used to scale the skill's battle
    # damage by the target's resistance. A fixture without the field applies none.
    def skill_attributes(sk)
      set = sk.respond_to?(:attribute_effects) ? sk.attribute_effects : nil
      return [] unless set
      ids = []
      set.each_with_index { |on, i| ids << (i + 1) if on }
      ids
    end

    # Whether skill `sk` is flagged "attribute defence up/down" (`affect_attr_
    # defence`, field 45) and, if so, which direction: +1 (the rank index
    # moves toward E, a *smaller* attr_rate% -- better resistance, less
    # damage taken from that attribute later) or -1 (toward A, a *larger*
    # attr_rate% -- worse resistance, more damage taken; see #attr_rate's own
    # 300/200/100/50/0 table, where a lower-lettered rank means a bigger
    # multiplier). This used to reuse `reverse_state_effect` (field 20) as an
    # unconfirmed guess; EasyRPG Player's actual C++ source settles it
    # instead: `Game_BattleAlgorithm::Skill::vExecute` (src/
    # game_battlealgorithm.cpp) computes `auto shift = IsPositive() ? 1 : -1;`
    # right where it applies `affect_attr_defence`, and `IsPositive()` was set
    # a few lines earlier from `Algo::SkillTargetsAllies(skill)` (src/algo.h),
    # which is simply `!SkillTargetsEnemies(skill)` -- true for every scope
    # except Scope_enemy(0)/Scope_enemies(1). `reverse_state_effect` plays no
    # part in this at all (that flag's own state-cure/inflict role is,
    # per the same function, `IsPositive() ^ (Player::IsRPG2k3() &&
    # skill.reverse_state_effect)` -- gated behind an RPG2003 check this
    # runtime does not model either way, a separate, wider question left
    # untouched here). So the direction is purely the skill's own target
    # scope: an ally-scoped skill (self/single ally/all allies, the "buff"
    # shape) always raises resistance, an enemy-scoped one (single/all
    # enemies, the "curse" shape) always lowers it -- matching
    # #battle_skill_target's own enemy-scope test (`scope == 0 || scope ==
    # 1`). nil when the skill does not touch attribute defence at all.
    def skill_attr_shift(sk)
      return nil unless sk.respond_to?(:affect_attr_defence) && sk.affect_attr_defence
      sk.scope == 0 || sk.scope == 1 ? -1 : 1
    end

    # The command numbers for casting `sk` from `caster` on `target` (both
    # Combatant snapshots): the caster's SP `cost`, and the signed HP / SP deltas
    # to the target — negative HP for an attack skill (base effect less a quarter
    # of the target's defence, min 1), positive HP / SP for a recovery skill. An
    # attack skill also carries the states it may inflict and the roll chance.
    # Both branches carry the skill's own `variance` now — `Game::Battle#apply_
    # skill_hit` is what actually spreads either sign of effect by it, this
    # method just reports the number the skill row names.
    def battle_skill_command(sk, caster, target)
      cost = skill_cost(sk, caster)
      base = skill_effect(sk, caster)
      # Attribute-defence shifting isn't scoped to attack skills -- a "raise
      # my own resistance" buff and a "lower the enemy's" debuff are both this
      # same flag, just cast on a different side -- so it rides on both
      # branches below rather than only the attack one.
      shift = skill_attr_shift(sk)
      shift_ids = shift ? skill_attributes(sk) : []
      if sk.scope == 0 || sk.scope == 1 # single or all enemies: an attack skill
        dmg = base - skill_defence_term(sk, target)
        dmg = 1 if dmg < 1
        { cost: cost, hp: -dmg, mp: 0,
          inflict: skill_state_ids(sk), chance: skill_hit(sk),
          variance: skill_variance(sk), attributes: skill_attributes(sk),
          # 吸収 — the caster takes what the target loses. RPG_RT reads the flag
          # only on an *offensive* skill (EasyRPG's `skill.absorb_damage &&
          # !IsPositive()`), so it rides only on this branch: a healing skill
          # that sets it drains nothing.
          absorb: skill_absorbs?(sk), attr_shift: shift, attr_ids: shift_ids }
      else
        { cost: cost, hp: sk.affect_hp ? base : 0, mp: sk.affect_sp ? base : 0,
          variance: skill_variance(sk), attr_shift: shift, attr_ids: shift_ids }
      end
    end

    # Whether item `id` can be used in battle: a medicine flagged occasion_battle
    # the party actually holds, or a **special** item whose skill is battle-usable
    # (the same deferral #field_usable? makes). Nepheshel's whole thrown-bomb line
    # — 火炎玉, 爆裂玉, 氷結玉, 雷撃玉 and the rest — is special items, so this is
    # what puts them in the battle item list at all.
    def battle_usable?(id)
      it = db_item(id)
      return false unless it && item_count(id) > 0
      case it.type
      when ITEM_MEDICINE then !item_field_only?(it)
      when ITEM_SWITCH then item_battle_occasion?(it)
      when ITEM_SPECIAL then battle_skill?(db_skill(it.skill_id))
      else false
      end
    end

    # The bag's battle-usable items as `[id, count]` pairs in ascending id order.
    def battle_items
      @items.keys.sort.select { |id| battle_usable?(id) }
            .map { |id| [id, item_count(id)] }
    end

    # The HP / SP a medicine restores to a battle `target` (Combatant snapshot)
    # plus the status conditions it cures, as `{ hp:, mp:, cured: [ids] }` — the
    # same recovery and (antidote / herb) cure the field menu applies. Pure
    # arithmetic: an actor_set (使用可能キャラ) restriction is a question of
    # which target may be *offered* at all, not of what this formula computes
    # once one legitimately is — see `Scene::Map#battle_ally_targets`, which is
    # where that gate actually lives for a battle-cast item.
    def battle_item_command(it, target)
      hp, mp = item_recovery(it, target)
      { hp: hp, mp: mp, cured: item_cured_states(it) }
    end

    # Whether medicine `it` targets the whole party (item scope 1) rather than a
    # single ally (scope 0). The battle menu casts an all-party item on every
    # living member at once, skipping target selection.
    def item_all_allies?(it)
      it.respond_to?(:scope) && it.scope == 1
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
      # Tile Substitution (11750) rewrites, per layer: { old_id => new_id }. Kept
      # as a lookup applied on read rather than as an edit of the layer arrays,
      # the way RPG_RT does it — the map data stays pristine, a second
      # substitution of the same tile replaces (not chains with) the first, and
      # passability follows the substituted tile because every reader goes
      # through #lower / #upper. Cleared with the map, so leaving resets it.
      @substitutions = [{}, {}]
    end

    def in_bounds?(x, y)
      x >= 0 && y >= 0 && x < @width && y < @height
    end

    def lower(x, y); tile(@lower, 0, x, y); end
    def upper(x, y); tile(@upper, 1, x, y); end

    # Tile Substitution: from now on draw (and treat) every `old_id` tile on
    # `layer` (0 lower, 1 upper) as `new_id`. Substituting a tile back to itself
    # drops the rewrite.
    def substitute_tile(layer, old_id, new_id)
      table = @substitutions[layer == 0 ? 0 : 1]
      if old_id == new_id
        table.delete(old_id)
      else
        table[old_id] = new_id
      end
    end

    # Whether any tile on either layer is currently rewritten.
    def substituted?
      !@substitutions[0].empty? || !@substitutions[1].empty?
    end

    private

    def tile(layer, index, x, y)
      return nil unless in_bounds?(x, y)
      id = layer[y * @width + x]
      table = @substitutions[index]
      table.empty? ? id : (table[id] || id)
    end
  end

  # A tiny deterministic pseudo-random generator. `Kernel#rand` does exist in
  # this build (mruby-random, added for the RGSS script host — a game's own
  # scripts call it), but it is unseeded: move routes and autonomous movement
  # are diffed frame by frame against the genuine runtime
  # (scripts/compare-nepheshel-wine.bash), which needs the same rolls every run,
  # so they keep this one. This is a small LCG (multiplier 75, modulus the prime 65537)
  # whose arithmetic stays within a signed 32-bit `mrb_int` — no value ever
  # reaches 2**31 — so it never has to promote to a bigint on this target. The
  # period (65536) and quality are more than enough for picking a walk
  # direction, and seeding it makes NPC wandering reproducible.
  class Rng
    # The generator's period. Prime, which is what makes #scaled necessary.
    PERIOD = 65_537

    def initialize(seed = 1)
      @state = (seed & 0xFFFF) + 1
    end

    def next_int
      @state = (@state * 75 + 74) % PERIOD
    end

    # An integer in 0...n (0 when n <= 0).
    def random(n)
      return 0 if n <= 0
      next_int % n
    end

    # An integer in 0...scale, taken by scaling the generator's whole period
    # rather than by taking a modulus of it.
    #
    # `PERIOD` is prime, so `next_int % scale` never divides evenly: the lowest
    # `PERIOD % scale` values come up once more often than the rest. At the sizes
    # #random is used with — `random(100)`, `random(30)` — that surplus is a
    # handful of draws in thousands and nothing notices.
    #
    # At `scale` 10000 it is 5537 values, and they sit at the **bottom** of the
    # range, which is exactly where a "roll under a small threshold" test looks.
    # Every such threshold then fires about 7% more often than it should — a
    # 333 bp chance lands 3.56% of the time rather than 3.33%. Scaling is
    # monotonic, so the same unavoidable unevenness is spread across the range
    # instead of piling up under the threshold: measured over 200k draws it puts
    # 1/30 at 3.335% and 1/3 at 33.338%.
    #
    # #random is deliberately left as it is. Every existing caller passes a small
    # `n` where it is correct enough, and changing it would reshuffle every
    # seeded result in the project to no purpose.
    def scaled(scale)
      return 0 if scale <= 0
      next_int * scale / PERIOD
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

    attr_accessor :direction, :move_speed, :move_frequency
    attr_accessor :through, :facing_locked, :animation_stopped, :transparency
    attr_accessor :layer, :overlap_forbidden
    attr_reader :graphic_name, :graphic_index, :x, :y

    # The direction actually walked/jumped by the last successful move,
    # distinct from #direction (the displayed sprite facing): a Direction
    # Fix lock or an explicit Face command can turn the sprite without the
    # character having moved a step in that direction, and the reverse --
    # a locked move steps somewhere the sprite never turns to face. Only
    # #move / #jump / #move_diagonal update this; #face!/#turn_* (no
    # movement) and a blocked #do_move (turns to face an obstruction but
    # never steps) leave it alone. yado.tk: a move-route "One Step Forward"
    # continues in *this* direction, not the sprite's #direction.
    attr_reader :last_move_direction

    # Placing a character outright -- Change Event Location, a page refresh
    # restoring where an event stood -- is not a move, so it clears #jumped.
    # Without this a character that had jumped would arc again the next time
    # something snapped it to a tile.
    def x=(v); @x = v; @jumped = false; end
    def y=(v); @y = v; @jumped = false; end

    def initialize(x = 0, y = 0, direction = 2)
      @x = x
      @y = y
      @direction = direction
      @last_move_direction = direction
      @move_speed = 3
      @move_frequency = 3
      @through = false          # ignore collision while moving
      @facing_locked = false    # keep facing fixed while moving
      @animation_stopped = false
      @transparency = 0         # 0 opaque .. 7 fully transparent
      @graphic_name = nil
      @graphic_index = 0
      @jumped = false
      @layer = 1                # priority type: same as normal characters
      @overlap_forbidden = false # LCF page field 35: collide regardless of layer
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

    # Turn to face `dir` without moving (a no-op while facing is locked) --
    # movement-driven facing only (#move, #jump, #move_diagonal). An explicit
    # Face Direction / Turn move-route sub-command always wins over a prior
    # Direction Fix ON in the same route (yado.tk); see #face!.
    def face(dir)
      @direction = dir unless @facing_locked || dir.nil?
    end

    # Turn to face `dir`, ignoring the Direction Fix lock. The move-route
    # "Face Up/Right/Down/Left/Random/Hero/Away from Hero" sub-commands use
    # this (Turn Right/Left/180/Random already bypassed the lock by writing
    # @direction directly) -- Direction Fix only suppresses the facing change
    # that would otherwise happen from an ordinary move, not an explicit
    # facing command issued later in the same route.
    def face!(dir)
      @direction = dir unless dir.nil?
    end

    # Whether the move just made was a jump (a Begin Jump / End Jump block)
    # rather than a step. The renderer reads it to lift the sprite along an arc
    # instead of sliding it flat, so it describes the *last* move and every
    # ordinary move clears it. A jump that lands where it started still sets it:
    # RPG_RT hops in place, and the flag rather than the distance is what says
    # so.
    attr_reader :jumped

    # Move one tile in `dir`, updating facing (subject to the lock).
    def move(dir)
      face(dir)
      @last_move_direction = dir
      dx, dy = DIR_DELTA[dir] || [0, 0]
      @x += dx
      @y += dy
      @jumped = false
    end

    # Land on (x, y) in one hop — the move-route Begin Jump / End Jump pair,
    # whose enclosed moves name a destination rather than a path.
    #
    # RPG_RT faces the jump's **dominant axis**, vertical winning a tie, which is
    # not the direction of the last enclosed move: a jump two right and two down
    # lands facing down. A jump that ends where it started leaves both the
    # facing and #last_move_direction alone -- there is no axis to be
    # dominant when neither one moved.
    def jump(x, y)
      dx = x - @x
      dy = y - @y
      unless dx == 0 && dy == 0
        dir = dy.abs >= dx.abs ? (dy >= 0 ? 2 : 8) : (dx >= 0 ? 6 : 4)
        face(dir)
        @last_move_direction = dir
      end
      @x = x
      @y = y
      @jumped = true
    end

    # Move one tile diagonally, combining a horizontal and a vertical direction.
    # RPG2000 keeps a cardinal facing on diagonals, so we face the vertical part.
    def move_diagonal(horizontal, vertical)
      face(vertical)
      @last_move_direction = vertical
      hx, = DIR_DELTA[horizontal] || [0, 0]
      _, vy = DIR_DELTA[vertical] || [0, 0]
      @x += hx
      @y += vy
      @jumped = false
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

    # True when two event pages' raw `move_route` fields (as read by
    # #from_page — commands/repeat/skippable) describe the byte-identical
    # route. This is RPG_RT's own test for whether a route executing when an
    # event's active page switches continues seamlessly from where it left
    # off (identical route) or restarts from the top (anything else,
    # including no custom route at all).
    def self.same_route?(a, b)
      return true if a.nil? && b.nil?
      return false if a.nil? || b.nil?
      return false unless a.repeat == b.repeat && a.skippable == b.skippable
      ca = a.commands || []
      cb = b.commands || []
      return false unless ca.size == cb.size
      ca.each_index do |i|
        x = ca[i]; y = cb[i]
        return false unless x.command_id == y.command_id &&
                             x.parameter_string == y.parameter_string &&
                             x.parameter_a == y.parameter_a &&
                             x.parameter_b == y.parameter_b &&
                             x.parameter_c == y.parameter_c
      end
      true
    rescue StandardError
      false
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
        # yado.tk: continues in the direction actually last walked/jumped,
        # not the sprite's displayed facing -- the two can diverge under a
        # Direction Fix lock or an explicit Face command (see
        # Character#last_move_direction).
        do_move(character, world, character.last_move_direction)
      # A Face Direction sub-command always turns the sprite, even right after
      # a Direction Fix ON earlier in the same route (yado.tk) -- #face!, not
      # the lock-respecting #face movement uses.
      when FACE_UP, FACE_RIGHT, FACE_DOWN, FACE_LEFT
        character.face!(FACE_DIR[id]); [:turned, true]
      when TURN_RIGHT then character.turn_right;  [:turned, true]
      when TURN_LEFT  then character.turn_left;   [:turned, true]
      when TURN_180   then character.turn_around; [:turned, true]
      when TURN_RANDOM
        world.random(2) == 0 ? character.turn_right : character.turn_left
        [:turned, true]
      when FACE_RANDOM
        character.face!(Character::CARDINALS[world.random(4)]); [:turned, true]
      when FACE_HERO      then character.face!(toward_hero(character, world)); [:turned, true]
      when FACE_AWAY_HERO then character.face!(away_hero(character, world));  [:turned, true]
      when WAIT       then [:waited, true]
      when BEGIN_JUMP then do_jump(character, world)
      when END_JUMP   then [:effect, true] # an End Jump with no Begin: skipped
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

    # Begin Jump: the commands up to the matching End Jump do **not** step. They
    # name the jump's *destination* — each move command contributes its direction
    # as one tile of offset, each face / turn command only steers what the next
    # move contributes — and the character then hops there in a single move,
    # clearing whatever lies between. A port of EasyRPG's
    # `Game_Character::BeginMoveRouteJump`.
    #
    # Only the landing tile is tested (`world.can_land?`), because the genuine
    # runtime skips the "may I leave this tile" half of its passability check
    # while jumping — that is what lets a jump cross a wall or a chasm at all.
    # A blocked landing behaves like a blocked move: retried on a non-skippable
    # route, stepped past on a skippable one.
    def do_jump(character, world)
      dx = 0
      dy = 0
      dir = character.direction
      i = @index + 1
      while i < @commands.size
        id = @commands[i].command_id
        if id >= MOVE_UP && id <= MOVE_FORWARD
          dir = jump_move_direction(id, dir, character, world)
          ddx, ddy = jump_delta(id, dir)
          dx += ddx
          dy += ddy
        elsif id >= FACE_UP && id <= FACE_AWAY_HERO
          dir = jump_face_direction(id, dir, character, world)
        elsif id == END_JUMP
          return land_jump(character, world, dx, dy, i)
        end
        # Any other command inside the block (a switch, a graphic change) is
        # skipped, as RPG_RT skips it.
        i += 1
      end
      # No End Jump before the route ran out: the jump is abandoned and the rest
      # of the route goes with it, which is how RPG_RT unwinds the scan.
      @index = @commands.size - 1
      [:effect, true]
    end

    # Finish a jump scanned out to the End Jump at `end_index`.
    def land_jump(character, world, dx, dy, end_index)
      tx = character.x + dx
      ty = character.y + dy
      if character.through || world.can_land?(character, tx, ty)
        character.jump(tx, ty)
        @index = end_index
        [:moved, true]
      elsif @skippable
        @index = end_index
        [:blocked, true]
      else
        [:blocked, false] # retried from the Begin Jump next step
      end
    end

    # The direction a move command inside a jump block contributes. The moves
    # that would pick a direction at run time (random, toward / away from the
    # hero) still pick one; Move Forward keeps the direction in hand.
    def jump_move_direction(id, dir, character, world)
      case id
      when MOVE_UP, MOVE_RIGHT, MOVE_DOWN, MOVE_LEFT then MOVE_DIR[id]
      when MOVE_RANDOM then Character::CARDINALS[world.random(4)]
      when MOVE_TOWARD_HERO then toward_hero(character, world)
      when MOVE_AWAY_HERO then away_hero(character, world)
      else dir # Move Forward, and the diagonals (which carry their own delta)
      end
    end

    # The tile offset a move command inside a jump block adds. A diagonal moves
    # on both axes at once; everything else moves one tile along `dir`.
    def jump_delta(id, dir)
      if (pair = DIAGONAL[id])
        horizontal, vertical = pair
        hx, = Character::DIR_DELTA[horizontal] || [0, 0]
        _, vy = Character::DIR_DELTA[vertical] || [0, 0]
        [hx, vy]
      else
        Character::DIR_DELTA[dir] || [0, 0]
      end
    end

    # The direction a face / turn command inside a jump block leaves in hand. It
    # contributes no offset of its own — it only steers the next move command.
    def jump_face_direction(id, dir, character, world)
      case id
      when FACE_UP, FACE_RIGHT, FACE_DOWN, FACE_LEFT then FACE_DIR[id]
      when TURN_RIGHT then Character::TURN_RIGHT[dir] || dir
      when TURN_LEFT  then Character::TURN_LEFT[dir]  || dir
      when TURN_180   then Character::TURN_180[dir]   || dir
      when TURN_RANDOM
        world.random(2).zero? ? (Character::TURN_LEFT[dir] || dir)
                             : (Character::TURN_RIGHT[dir] || dir)
      when FACE_RANDOM then Character::CARDINALS[world.random(4)]
      when FACE_HERO then toward_hero(character, world)
      when FACE_AWAY_HERO then away_hero(character, world)
      else dir
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

  # Evaluation of RPG2000 *battle*-event page conditions (troop chunk 11). A
  # page fires when every sub-condition its `flags` bitfield enables holds.
  #
  # The bit values follow liblcf's `TroopPageCondition::Flags` declaration
  # order (switch_a, switch_b, variable, turn, fatigue, enemy_hp, actor_hp,
  # turn_enemy, turn_actor, command_actor) packed LSB-first — the same
  # convention Game::EventPage above uses for map pages.
  #
  # Four of those bits are confirmed against real bytes (Nepheshel, 3265 troop
  # pages, 2819 of them conditional — `ruby scripts/analyze_game.rb --troops`):
  #
  #   * bit 0 SWITCH_A (2650 pages) and bit 1 SWITCH_B (468) — bit 1 only ever
  #     appears together with bit 0, as `flags=0x003`, and those pages carry a
  #     *pair* of plausible switch ids (11/5, 12/6, 13/7), which is what two
  #     switch conditions look like and not what any other field would.
  #   * bit 3 TURN (165) — 156 pages are base 0 / multiple 0 (fire on turn 0,
  #     the opening page) and 9 are base 0 / multiple 1 (fire every turn),
  #     exactly the two shapes #check_turns produces.
  #   * bit 5 ENEMY_HP (4) — every one carries a non-default `0..30%` window
  #     ("the boss enrages below 30% HP"). A default window would prove nothing;
  #     a deliberate one could not survive a wrong bit.
  #
  # Bits 2 (VARIABLE), 4 (FATIGUE), 6 (ACTOR_HP) and 7-9 (the per-battler turn
  # and command tests) are unused by that game, so their positions rest on the
  # liblcf declaration order alone. What the data does establish is that the
  # order is not shifted: a shift would have moved the confirmed four.
  #
  # Only the sub-conditions the battle context can answer are tested; one it
  # cannot answer (see `ctx`) is treated as unmet rather than silently passing,
  # so a page never fires on a condition we did not actually check.
  module BattlePage
    SWITCH_A      = 0x001
    SWITCH_B      = 0x002
    VARIABLE      = 0x004
    TURN          = 0x008
    FATIGUE       = 0x010
    ENEMY_HP      = 0x020
    ACTOR_HP      = 0x040
    TURN_ENEMY    = 0x080
    TURN_ACTOR    = 0x100
    COMMAND_ACTOR = 0x200

    # RPG2000's turn matcher: with no `multiple` the turn must equal `base`
    # exactly; otherwise it must be at or past `base` and an exact number of
    # `multiple` steps beyond it. So base 0 / multiple 2 fires on turns 0, 2,
    # 4, ...
    #
    # Both the body and the argument order are taken from EasyRPG Player, not
    # from guesswork: `Game_Battle::CheckTurns(int turns, int base, int
    # multiple)` is `turns >= base && (turns - base) == 0` when multiple is 0
    # (which is just `turns == base`, written that way below) and
    # `turns >= base && (turns - base) % multiple == 0` otherwise; and
    # `Game_Interpreter_Battle::AreConditionsMet` calls it as
    # `CheckTurns(GetTurn(), condition.turn_b, condition.turn_a)` — so `base` is
    # the page's `turn_b` and `multiple` its `turn_a`, which reads backwards
    # from the field names and is exactly why it is worth writing down.
    #
    # Real data agrees but cannot by itself pin the order down: every turn-gated
    # page in the games checked so far has `turn_b == 0` (156 pages at
    # multiple 0, firing on turn 0; 9 at multiple 1, firing every turn), and a
    # swapped order would produce the same two behaviours for those values. A
    # game with a "from turn N, every M" page would settle it independently.
    def self.check_turns(turn, base, multiple)
      return turn == base if multiple.nil? || multiple == 0
      turn >= base && (turn - base) % multiple == 0
    end

    # Whether a battler's HP sits within a percentage window of its maximum
    # (the enemy-HP / actor-HP conditions are expressed in percent).
    def self.hp_within?(battler, min, max)
      return false if battler.nil? || battler.max_hp.nil? || battler.max_hp <= 0
      pct = battler.hp * 100 / battler.max_hp
      pct >= min && pct <= max
    end

    # `ctx` is the battle context the interpreter also runs against; it answers
    # `turn`, `enemy(index)`, `ally_by_actor_id(id)`, `enemy_turn(index)`,
    # `actor_turn(id)`, `fatigue` and `actor_command(id)`. A context that cannot
    # answer a tested sub-condition fails the page.
    def self.active?(cond, switches, variables, ctx)
      # A page whose condition box is entirely unticked never runs — RPG_RT
      # treats "no trigger" as "never", not as "always" (EasyRPG's
      # AreConditionsMet opens with exactly this test). Worth stating because the
      # opposite reading is the natural one: every other page kind in RPG2000
      # runs when its conditions are vacuously satisfied. Both test beds do have
      # such pages (446 of Nepheshel's 3265, all 88 of mtf-meido-action's), and
      # every one of them is empty, so the rule costs those games nothing.
      return false if cond.nil?
      flags = cond.flags || 0
      return false if flags == 0
      return false if (flags & SWITCH_A) != 0 && !switches[cond.switch_a_id]
      return false if (flags & SWITCH_B) != 0 && !switches[cond.switch_b_id]
      if (flags & VARIABLE) != 0
        return false if variables[cond.variable_id] < cond.variable_value
      end
      return false if (flags & TURN) != 0 &&
                      !check_turns(ctx.turn, cond.turn_b, cond.turn_a)
      if (flags & ENEMY_HP) != 0
        return false unless hp_within?(ctx.enemy(cond.enemy_id),
                                       cond.enemy_hp_min, cond.enemy_hp_max)
      end
      if (flags & ACTOR_HP) != 0
        return false unless hp_within?(ctx.ally_by_actor_id(cond.actor_id),
                                       cond.actor_hp_min, cond.actor_hp_max)
      end
      if (flags & TURN_ENEMY) != 0
        t = ctx.enemy_turn(cond.turn_enemy_id)
        return false if t.nil?
        return false unless check_turns(t, cond.turn_enemy_b, cond.turn_enemy_a)
      end
      if (flags & TURN_ACTOR) != 0
        t = ctx.actor_turn(cond.turn_actor_id)
        return false if t.nil?
        return false unless check_turns(t, cond.turn_actor_b, cond.turn_actor_a)
      end
      if (flags & COMMAND_ACTOR) != 0
        return false unless ctx.actor_command(cond.command_actor_id) == cond.command_id
      end
      if (flags & FATIGUE) != 0
        f = ctx.fatigue
        return false if f.nil?
        return false if f < cond.fatigue_min || f > cond.fatigue_max
      end
      true
    end

    # Every [id, page] whose condition currently holds, in page order — unlike
    # a map event (where the highest active page wins) RPG2000 runs *each*
    # matching battle page.
    def self.select_all(pages, switches, variables, ctx)
      out = []
      return out if pages.nil?
      pages.each { |id, page| out << [id, page] if active?(page.condition, switches, variables, ctx) }
      out
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
        list.push({ id: id, trigger: c.start_term, need_flag: c.need_flag,
                    switch_id: c.switch_id, commands: c.event })
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

  # The RPG2000 screen **transition** an Erase Screen (11010) / Show Screen
  # (11020) runs, and the geometry it paints frame by frame.
  #
  # RPG_RT composites two full screens: the one being left and the one being
  # arrived at, one of which is solid black (an erase ends black, a show starts
  # black). Every transition is therefore a **black mask over the live scene** —
  # the erase grows it, the show shrinks it — which is exactly what
  # `Scene::Map`'s existing full-screen black overlay can express. This class
  # owns the mask: `#visible_rects` returns the regions of the live scene showing
  # through on the current frame, and the scene paints the overlay opaque and
  # punches those out. The uniform fades stay a plain opacity ramp
  # (`#black_alpha`), the cheap path they already were.
  #
  # Ported from EasyRPG Player's `Transition` (src/transition.{h,cpp}): the style
  # ids are its `Transition::Type` enum in order, the command-parameter tables
  # are its `Game_Interpreter::CommandEraseScreen` / `CommandShowScreen`
  # switches, and the durations are its `GetDefaultFrames`.
  class Transition
    FADE_IN                 = 0
    FADE_OUT                = 1
    RANDOM_BLOCKS           = 2
    RANDOM_BLOCKS_DOWN      = 3
    RANDOM_BLOCKS_UP        = 4
    BLIND_OPEN              = 5
    BLIND_CLOSE             = 6
    VERTICAL_STRIPES_IN     = 7
    VERTICAL_STRIPES_OUT    = 8
    HORIZONTAL_STRIPES_IN   = 9
    HORIZONTAL_STRIPES_OUT  = 10
    BORDER_TO_CENTER_IN     = 11
    BORDER_TO_CENTER_OUT    = 12
    CENTER_TO_BORDER_IN     = 13
    CENTER_TO_BORDER_OUT    = 14
    SCROLL_UP_IN            = 15
    SCROLL_DOWN_IN          = 16
    SCROLL_LEFT_IN          = 17
    SCROLL_RIGHT_IN         = 18
    SCROLL_UP_OUT           = 19
    SCROLL_DOWN_OUT         = 20
    SCROLL_LEFT_OUT         = 21
    SCROLL_RIGHT_OUT        = 22
    VERTICAL_COMBINE        = 23
    VERTICAL_DIVISION       = 24
    HORIZONTAL_COMBINE      = 25
    HORIZONTAL_DIVISION     = 26
    CROSS_COMBINE           = 27
    CROSS_DIVISION          = 28
    ZOOM_IN                 = 29
    ZOOM_OUT                = 30
    MOSAIC_IN               = 31
    MOSAIC_OUT              = 32
    WAVE_IN                 = 33
    WAVE_OUT                = 34
    CUT_IN                  = 35
    CUT_OUT                 = 36
    NONE                    = 37

    # RPG2000's own transition **setting** numbering, 0..20, shared by three
    # places: an Erase / Show Screen's parameter 0, the database System tab's six
    # transition fields (chunks 61-66) and the Change Screen Transitions (10690)
    # slots the save keeps (chunks 111-116). The same index means a different
    # style depending on which direction it is read in, which is why there are
    # two tables — EasyRPG's `Game_System::GetTransition` picks between them with
    # `fades[which % 2]`, the erase slots being the even ones.
    #
    # Erase Screen's parameter 0 / an erase setting -> style. Anything past the
    # table is NONE, RPG_RT's own `default:` arm (setting 20 is exactly that).
    ERASE_STYLES = [
      FADE_OUT, RANDOM_BLOCKS, RANDOM_BLOCKS_DOWN, RANDOM_BLOCKS_UP,
      BLIND_CLOSE, VERTICAL_STRIPES_OUT, HORIZONTAL_STRIPES_OUT,
      BORDER_TO_CENTER_OUT, CENTER_TO_BORDER_OUT, SCROLL_UP_OUT,
      SCROLL_DOWN_OUT, SCROLL_LEFT_OUT, SCROLL_RIGHT_OUT, VERTICAL_DIVISION,
      HORIZONTAL_DIVISION, CROSS_DIVISION, ZOOM_IN, MOSAIC_OUT, WAVE_OUT,
      CUT_OUT
    ].freeze

    # Show Screen's parameter 0 / a show setting -> style: the same list in its
    # "in" polarity.
    SHOW_STYLES = [
      FADE_IN, RANDOM_BLOCKS, RANDOM_BLOCKS_DOWN, RANDOM_BLOCKS_UP,
      BLIND_OPEN, VERTICAL_STRIPES_IN, HORIZONTAL_STRIPES_IN,
      BORDER_TO_CENTER_IN, CENTER_TO_BORDER_IN, SCROLL_UP_IN, SCROLL_DOWN_IN,
      SCROLL_LEFT_IN, SCROLL_RIGHT_IN, VERTICAL_COMBINE, HORIZONTAL_COMBINE,
      CROSS_COMBINE, ZOOM_OUT, MOSAIC_IN, WAVE_IN, CUT_IN
    ].freeze

    # The scroll and combine / division styles: a black mask cannot express them
    # (the true old/new pixels have to move), so Scene::Map instead snapshots the
    # screen once via RGSS::Graphics.snap_to_bitmap when one of these starts and
    # blits that capture per #capture_ops every frame -- see docs/TODO.md's
    # "Screen effects" entry. This class stays pure logic (no Graphics access,
    # per the SCREEN_W/H comment above): it only computes where each piece of
    # the capture goes.
    CAPTURED = [SCROLL_UP_IN, SCROLL_DOWN_IN, SCROLL_LEFT_IN, SCROLL_RIGHT_IN,
                SCROLL_UP_OUT, SCROLL_DOWN_OUT, SCROLL_LEFT_OUT,
                SCROLL_RIGHT_OUT, VERTICAL_COMBINE, VERTICAL_DIVISION,
                HORIZONTAL_COMBINE, HORIZONTAL_DIVISION, CROSS_COMBINE,
                CROSS_DIVISION].freeze

    # Styles this build paints for real. Zoom / mosaic / wave still fall through
    # to a plain fade: mosaic and wave want a native per-pixel resample and zoom's
    # own IN/OUT direction (which way the picture scales) has nothing in either
    # test bed to confirm it against, so it is left rather than guessed. Random
    # blocks wants RPG_RT's incremental per-frame block paint, which a mask can
    # express but this does not do yet either.
    DRAWN = [FADE_IN, FADE_OUT, BLIND_OPEN, BLIND_CLOSE, VERTICAL_STRIPES_IN,
             VERTICAL_STRIPES_OUT, HORIZONTAL_STRIPES_IN,
             HORIZONTAL_STRIPES_OUT, BORDER_TO_CENTER_IN, BORDER_TO_CENTER_OUT,
             CENTER_TO_BORDER_IN, CENTER_TO_BORDER_OUT, CUT_IN, CUT_OUT,
             NONE, *CAPTURED].freeze

    # The highest setting index the numbering defines (20 = "no transition").
    MAX_SETTING = 20

    # Whether `v` is a usable setting index. A slot that is not — nil, or the
    # "same as the database" marker RPG_RT saves — means "ask the database".
    def self.setting?(v)
      !v.nil? && v >= 0 && v <= MAX_SETTING
    end

    # The style an Erase Screen selects. `param` is the command's parameter 0 and
    # `configured` the setting a **-1** ("use the configured transition") falls
    # back to: the teleport-erase slot, itself seeded from the database. Both are
    # setting indices, so the fallback goes through the same table.
    def self.erase_style(param, configured)
      style_for(ERASE_STYLES, param, configured)
    end

    def self.show_style(param, configured)
      style_for(SHOW_STYLES, param, configured)
    end

    def self.style_for(table, param, configured)
      setting = param < 0 ? configured : param
      return NONE unless setting?(setting)
      table[setting] || NONE
    end

    # How long a style runs, in frames (EasyRPG's `GetDefaultFrames`): the plain
    # fades take 35, the instant cuts 1, NONE none at all, everything else 41 —
    # which is why the stripe transitions tile the screen exactly (40 steps of a
    # 6px / 8px pitch over 240 / 320 pixels).
    def self.default_frames(style)
      case style
      when FADE_IN, FADE_OUT then 35
      when CUT_IN, CUT_OUT   then 1
      when NONE              then 0
      else 41
      end
    end

    attr_reader :style, :frames, :frame

    # `erase` says which way the mask runs: true when black is arriving (Erase
    # Screen), false when it is leaving (Show Screen).
    def initialize(style, frames, width, height, erase)
      @style = style
      @frames = frames
      @width = width
      @height = height
      @erase = erase
      @frame = 0
    end

    def advance; @frame += 1 if @frame < @frames; end
    def done?; @frame >= @frames; end

    # Whether this style is drawn as a uniform black overlay (the fade family and
    # every unported style) rather than as a mask of rectangles.
    def uniform?
      !DRAWN.include?(@style) || @style == FADE_IN || @style == FADE_OUT
    end

    # The overlay opacity for a uniform style, 0 (clear) .. 255 (black).
    #
    # EasyRPG ramps the arriving screen in over `total_frames - 2`, so the fade
    # lands a couple of frames before the transition formally ends; that early
    # landing is part of how an RPG2000 fade looks, so it is ported rather than
    # tidied into a straight ramp.
    def black_alpha
      span = @frames - 2
      level = span <= 0 ? 255 : 255 * (@frame + 1) / span
      level = 255 if level > 255
      @erase ? level : 255 - level
    end

    # The rectangles of the live scene showing through the black overlay this
    # frame, each `[x, y, w, h]`. Only called for a non-uniform style; an empty
    # list means the screen is entirely black.
    #
    # RPG_RT draws the screen being left, then the screen being arrived at over
    # part of it — so the live regions are the arriving screen's on a Show and
    # everything *else* on an Erase. For the two window transitions that means
    # one polarity is a rectangle and the other is the four bands around it.
    def visible_rects
      case @style
      when BLIND_OPEN, BLIND_CLOSE then blind_rects
      when VERTICAL_STRIPES_IN, VERTICAL_STRIPES_OUT then vertical_stripe_rects
      when HORIZONTAL_STRIPES_IN, HORIZONTAL_STRIPES_OUT then horizontal_stripe_rects
      when BORDER_TO_CENTER_OUT then clip([border_to_center_rect])
      when BORDER_TO_CENTER_IN  then around(border_to_center_rect)
      when CENTER_TO_BORDER_IN  then clip([center_to_border_rect])
      when CENTER_TO_BORDER_OUT then around(center_to_border_rect)
      else [[0, 0, @width, @height]] # the cuts show the live screen for their one frame
      end
    end

    # Whether this style is composited from a captured screen (see CAPTURED)
    # rather than punched as a mask of the live one.
    def captured?
      CAPTURED.include?(@style)
    end

    # The captured screen's pieces for this frame, each `[dx, dy, sx, sy, sw,
    # sh]` -- paste the capture's `[sx, sy, sw, sh]` region at `(dx, dy)`. Only
    # called for a captured style; Scene::Map paints these over a black fill, so
    # a piece that has slid off-screen just leaves black behind it.
    def capture_ops
      case @style
      when SCROLL_UP_IN, SCROLL_DOWN_IN, SCROLL_LEFT_IN, SCROLL_RIGHT_IN,
           SCROLL_UP_OUT, SCROLL_DOWN_OUT, SCROLL_LEFT_OUT, SCROLL_RIGHT_OUT
        ox, oy = scroll_offset
        [[ox, oy, 0, 0, @width, @height]]
      when VERTICAL_COMBINE, VERTICAL_DIVISION
        vertical_split_ops(@style == VERTICAL_COMBINE)
      when HORIZONTAL_COMBINE, HORIZONTAL_DIVISION
        horizontal_split_ops(@style == HORIZONTAL_COMBINE)
      when CROSS_COMBINE, CROSS_DIVISION
        cross_split_ops(@style == CROSS_COMBINE)
      else
        []
      end
    end

    private

    # The frame index the geometry is drawn at, and the span it runs over —
    # EasyRPG's `current_frame` and `total_frames - 1`.
    def span; @frames - 1; end

    # `[p, d]` for the same frame0..1 linear ramp `border_to_center_rect` etc.
    # use below, factored out for the capture-geometry helpers.
    def frame_ratio
      d = span
      d <= 0 ? [1, 1] : [@frame, d]
    end

    # Scroll: the whole capture slides in from (or out to) one edge in a
    # straight line, landing flush at (0, 0) -- RPG2000's curtain-style
    # transition. "In" starts off-screen and ends in place (Show Screen, the
    # arriving picture); "out" starts in place and ends off-screen (Erase
    # Screen, the departing one), each direction sliding the way its name says.
    def scroll_offset
      p, d = frame_ratio
      case @style
      when SCROLL_UP_IN    then [0, @height - @height * p / d]
      when SCROLL_DOWN_IN  then [0, -(@height - @height * p / d)]
      when SCROLL_LEFT_IN  then [@width - @width * p / d, 0]
      when SCROLL_RIGHT_IN then [-(@width - @width * p / d), 0]
      when SCROLL_UP_OUT   then [0, -(@height * p / d)]
      when SCROLL_DOWN_OUT then [0, @height * p / d]
      when SCROLL_LEFT_OUT then [-(@width * p / d), 0]
      when SCROLL_RIGHT_OUT then [@width * p / d, 0]
      end
    end

    # Combine / division: the capture splits along one axis into two pieces
    # that slide together (combine, a Show) or apart (division, an Erase).
    # `top_h` / `left_w` is the first piece's share of the axis (integer half,
    # remainder to the second piece so an odd dimension still tiles exactly).
    def half(total)
      h = total / 2
      [h, total - h]
    end

    # Vertical split: a top piece and a bottom piece, sliding along y.
    def vertical_split_ops(combine)
      top_h, bottom_h = half(@height)
      p, d = frame_ratio
      if combine
        top_dy = -top_h + top_h * p / d
        bottom_dy = @height - bottom_h * p / d
      else
        top_dy = -(top_h * p / d)
        bottom_dy = top_h + bottom_h * p / d
      end
      [[0, top_dy, 0, 0, @width, top_h],
       [0, bottom_dy, 0, top_h, @width, bottom_h]]
    end

    # Horizontal split: a left piece and a right piece, sliding along x.
    def horizontal_split_ops(combine)
      left_w, right_w = half(@width)
      p, d = frame_ratio
      if combine
        left_dx = -left_w + left_w * p / d
        right_dx = @width - right_w * p / d
      else
        left_dx = -(left_w * p / d)
        right_dx = left_w + right_w * p / d
      end
      [[left_dx, 0, 0, 0, left_w, @height],
       [right_dx, 0, left_w, 0, right_w, @height]]
    end

    # Cross split: both axes at once, four quadrants each sliding diagonally
    # from (combine) or to (division) their own screen corner. The exact
    # quadrant motion is this build's own reading of "cross" -- reasoned from
    # the vertical/horizontal pair rather than confirmed against RPG_RT, since
    # neither test bed exercises this specific style.
    def cross_split_ops(combine)
      top_h, bottom_h = half(@height)
      left_w, right_w = half(@width)
      p, d = frame_ratio
      if combine
        top_dy = -top_h + top_h * p / d
        bottom_dy = @height - bottom_h * p / d
        left_dx = -left_w + left_w * p / d
        right_dx = @width - right_w * p / d
      else
        top_dy = -(top_h * p / d)
        bottom_dy = top_h + bottom_h * p / d
        left_dx = -(left_w * p / d)
        right_dx = left_w + right_w * p / d
      end
      [[left_dx, top_dy, 0, 0, left_w, top_h],
       [right_dx, top_dy, left_w, 0, right_w, top_h],
       [left_dx, bottom_dy, 0, top_h, left_w, bottom_h],
       [right_dx, bottom_dy, left_w, top_h, right_w, bottom_h]]
    end

    # Blinds: 8-pixel bands, each closing (or opening) from its top edge by one
    # pixel every five frames. The live band is what is left of the 8.
    BLIND_BAND = 8

    def blind_rects
      shut = (@frame + 5) / 5
      shut = BLIND_BAND if shut > BLIND_BAND
      open_h = BLIND_BAND - shut
      rects = []
      bands = @height / BLIND_BAND
      bands.times do |i|
        # Closing shows the bottom of each band, opening the top of it.
        if @style == BLIND_CLOSE
          rects.push [0, i * BLIND_BAND + shut, @width, open_h] if open_h > 0
        elsif shut > 0
          rects.push [0, i * BLIND_BAND + open_h, @width, shut]
        end
      end
      rects
    end

    # Vertical stripes: 3-pixel rows on a 6-pixel pitch, marching in from the top
    # and the bottom at once. The arriving screen takes the rows at `i * 6` /
    # `h - 3 - i * 6`, the leaving one keeps those at `i * 6 + 3` / `h - i * 6`.
    STRIPE_H = 3
    STRIPE_PITCH = 6

    def vertical_stripe_rects
      rects = []
      if @erase
        (span - (@frame + 1)).times do |i|
          rects.push [0, i * STRIPE_PITCH + STRIPE_H, @width, STRIPE_H]
          rects.push [0, @height - i * STRIPE_PITCH, @width, STRIPE_H]
        end
      else
        (@frame + 1).times do |i|
          rects.push [0, i * STRIPE_PITCH, @width, STRIPE_H]
          rects.push [0, @height - STRIPE_H - i * STRIPE_PITCH, @width, STRIPE_H]
        end
      end
      clip(rects)
    end

    # Horizontal stripes: the same march in columns, 4 pixels wide on an 8-pixel
    # pitch, closing in from the left and right edges.
    STRIPE_W = 4
    STRIPE_COL_PITCH = 8

    def horizontal_stripe_rects
      rects = []
      if @erase
        (span - (@frame + 1)).times do |i|
          rects.push [i * STRIPE_COL_PITCH + STRIPE_W, 0, STRIPE_W, @height]
          rects.push [@width - i * STRIPE_COL_PITCH, 0, STRIPE_W, @height]
        end
      else
        (@frame + 1).times do |i|
          rects.push [i * STRIPE_COL_PITCH, 0, STRIPE_W, @height]
          rects.push [@width - STRIPE_W - i * STRIPE_COL_PITCH, 0, STRIPE_W, @height]
        end
      end
      clip(rects)
    end

    # Border to centre: the live scene shrinks toward the middle (erase) or the
    # arriving one is revealed by that same shrinking window closing on it.
    def border_to_center_rect
      p = span <= 0 ? 1 : @frame
      d = span <= 0 ? 1 : span
      [(@width / 2) * p / d, (@height / 2) * p / d,
       @width - @width * p / d, @height - @height * p / d]
    end

    # Centre to border: a window growing out of the middle onto which the
    # arriving screen is drawn.
    def center_to_border_rect
      p = span <= 0 ? 1 : @frame
      d = span <= 0 ? 1 : span
      [@width / 2 - (@width / 2) * p / d, @height / 2 - (@height / 2) * p / d,
       @width * p / d, @height * p / d]
    end

    # The four bands of screen left outside `rect` — the live scene when the
    # arriving screen is the one inside the window rather than around it.
    def around(rect)
      x, y, w, h = rect
      clip([[0, 0, @width, y],                              # above
            [0, y + h, @width, @height - (y + h)],          # below
            [0, y, x, h],                                   # left
            [x + w, y, @width - (x + w), h]])               # right
    end

    # Drop rectangles that fell off the screen (the stripe marches overrun by a
    # row or two at the end) and clamp the rest into it.
    def clip(rects)
      out = []
      rects.each do |x, y, w, h|
        next if w <= 0 || h <= 0 || x >= @width || y >= @height
        x2 = x < 0 ? 0 : x
        y2 = y < 0 ? 0 : y
        w2 = x + w > @width ? @width - x2 : w - (x2 - x)
        h2 = y + h > @height ? @height - y2 : h - (y2 - y)
        out.push [x2, y2, w2, h2] if w2 > 0 && h2 > 0
      end
      out
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
    # a black overlay at this opacity. While a shaped transition is running the
    # overlay is a mask instead (see #transition), and this holds the level the
    # screen settles at once it finishes.
    def fade_level
      return @fade unless @transition && @transition.uniform?
      @transition.black_alpha
    end

    # The RPG2000 transition style the last Erase / Show Screen selected (a
    # Game::Transition constant).
    def fade_transition; @fade_transition; end

    # The running Game::Transition, or nil between transitions. The scene reads
    # it to paint the overlay: a uniform style is just #fade_level, a shaped one
    # punches #visible_rects out of an opaque black overlay.
    def transition; @transition && !@transition.done? ? @transition : nil; end

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

    # Erase Screen: take the screen to black in the given Game::Transition style,
    # over that style's own length unless `frames` overrides it. Held black
    # afterwards until #show. A no-op (settles immediately) when the screen is
    # already fully erased — RPG_RT skips an erase-onto-erase outright.
    def erase(style, frames = nil)
      fade_to(255, style, frames, true)
    end

    # Show Screen: bring the screen back from black in the given style. A no-op
    # when the screen is already fully visible.
    def show(style, frames = nil)
      fade_to(0, style, frames, false)
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

    # Start a transition toward `target` (0 visible / 255 black) in `style`,
    # running for `frames` frames or, when that is nil, the style's own length.
    # Already at the target -> settle immediately so the command does not wait.
    #
    # Game::Transition::NONE is RPG_RT's "no transition at all": it neither
    # animates nor changes whether the screen is erased, so it is dropped here
    # rather than treated as an instant fade.
    def fade_to(target, style, frames, erase)
      style = Game::Transition::FADE_OUT if style.nil?
      @fade_transition = style
      return if style == Game::Transition::NONE
      @fade_target = target
      frames = Game::Transition.default_frames(style) if frames.nil?
      if frames <= 0 || @fade == target
        @fade = target
        @fade_frames = 0
        @transition = nil
      else
        @fade_frames = frames
        @transition = Game::Transition.new(style, frames, Game::SCREEN_W,
                                           Game::SCREEN_H, erase)
      end
    end

    def update_fade
      return if @fade_frames <= 0
      # A shaped transition owns its own frame counter and paints a mask; a
      # uniform one rides the plain level ramp. Either way the level lands on the
      # target on the final frame, so the screen holds the right end state.
      @transition.advance if @transition
      @fade += (@fade_target - @fade) / @fade_frames
      @fade_frames -= 1
      return unless @fade_frames.zero?
      @fade = @fade_target # land exactly on the target
      @transition = nil
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

    # The RPG2000 per-item stack cap: a party holds at most 99 of anything.
    ITEM_CAP = 99

    # How many of `id` the party could buy right now — what the quantity
    # selector's cursor is bounded by. The binding constraint is whichever of
    # affordability and the 99-item cap runs out first; a free item (price 0,
    # which RPG2000 does allow a shop to stock) is limited only by the cap.
    # 0 when the shop will not sell it at all.
    def max_buy(id)
      return 0 unless @allow_buy && @goods.include?(id)
      room = ITEM_CAP - @party.item_count(id)
      return 0 if room <= 0
      cost = price(id)
      return room if cost <= 0
      affordable = @party.gold / cost
      affordable < room ? affordable : room
    end

    # How many of `id` the party could sell — everything it holds, or 0 when the
    # item cannot be sold here at all.
    def max_sell(id)
      @allow_sell && sellable?(id) ? @party.item_count(id) : 0
    end

    # Buy `n` units of `id` in one transaction: must be stocked, buying allowed,
    # affordable and within the 99 cap. All-or-nothing — a count beyond what
    # #max_buy allows buys nothing rather than silently buying fewer, so the
    # caller cannot overspend by asking for too many. Returns whether it happened.
    def buy(id, n = 1)
      n = n.to_i
      return false if n < 1 || n > max_buy(id)
      @party.gain_gold(-price(id) * n)
      @party.gain_item(id, n)
      @did_transaction = true
      true
    end

    # Sell `n` units of `id` at half price each, all-or-nothing like #buy.
    def sell(id, n = 1)
      n = n.to_i
      return false if n < 1 || n > max_sell(id)
      @party.gain_gold(sell_price(id) * n)
      @party.gain_item(id, -n)
      @did_transaction = true
      true
    end
  end

  # Which battle backdrop (Backdrop/<name>) a fight on a given map uses.
  #
  # RPG2000 does not store the backdrop on the map itself: each map-tree node
  # (RPG_RT.lmt `map_properties`) carries a `backdrop_type` choosing between the
  # three options the editor's map-properties dialog offers, and the type is a
  # tri-state that has to be walked, not read:
  #
  #   0 親マップと同じ  inherit whatever the parent map resolves to
  #   1 地形で指定      the backdrop named by the terrain being fought on
  #   2 指定する        the map's own `backdrop_file`, for every fight on it
  #
  # (liblcf spells these BGMType_parent / _terrain / _specific — `background_type`
  # reuses the BGM enum.) Both test beds need the walk: 491 of Nepheshel's 537
  # maps and 4 of mtf-meido-action's 13 are type 0 and answer only through a
  # parent. Nepheshel pins 24 maps to a file ("black" for its dark interiors, a
  # boss backdrop for one fight) while naming no terrain backdrops at all;
  # mtf-meido-action is the other way round, leaving its 9 type-1 maps to 10
  # named terrains (Grassland, Snow Field, Desert, ...).
  module Backdrop
    TYPE_PARENT   = 0
    TYPE_TERRAIN  = 1
    TYPE_SPECIFIC = 2

    # The backdrop name for a fight on `map_id` standing on terrain whose own
    # backdrop is `terrain_name`. `properties` is the map tree's map_properties
    # table (`[map_id]` -> a row exposing backdrop_type / backdrop_file /
    # parent_map_id). Returns '' when nothing names one, which the scene draws as
    # its flat field.
    #
    # An inheriting map walks up its parents; the walk is bounded and remembers
    # where it has been, so a tree that loops (or a node that parents itself)
    # ends at the terrain rather than hanging the battle.
    def self.name_for(map_id, properties, terrain_name = '')
      terrain_name = terrain_name.to_s
      seen = {}
      id = map_id.to_i
      while id > 0 && !seen[id]
        seen[id] = true
        row = properties ? properties[id] : nil
        return terrain_name unless row
        case int_field(row, :backdrop_type)
        when TYPE_SPECIFIC
          return row.respond_to?(:backdrop_file) ? row.backdrop_file.to_s : ''
        when TYPE_TERRAIN
          return terrain_name
        else
          id = int_field(row, :parent_map_id)
        end
      end
      # The root (or a loop): RPG_RT has nothing left to inherit, so the terrain
      # answers.
      terrain_name
    end

    def self.int_field(row, name)
      return 0 unless row.respond_to?(name)
      v = row.send(name)
      v.nil? ? 0 : v.to_i
    end
  end

  # Whether the menu's Save command, and the Escape / Teleport field skill
  # types, are usable on a given map.
  #
  # Each map-tree node (RPG_RT.lmt `map_properties` field 33 `:save`, 31
  # `:teleport`, 32 `:escape`) is a tri-state, same shape as Backdrop's
  # `backdrop_type`: 0 inherits whatever the parent map resolves to, 1
  # explicitly allows it, 2 forbids it. RPG_RT re-derives all three from
  # scratch on every map load -- the initial map and every Teleport --
  # walking "same as parent" nodes up until one pins Allow/Forbid; a walk that
  # runs off the root (or loops) defaults to Allow, the schema's own default
  # for an unset field (EasyRPG's `Game_Map::Setup` does the identical walk
  # for all three fields, feeding `Game_System::SetAllowSave` /
  # `SetAllowTeleport` / `SetAllowEscape`). This sits *underneath* the
  # `Control Save/Teleport/Escape Access` event commands: those commands'
  # runtime toggles (`Game::State#save_access` / `#teleport_access` /
  # `#escape_access`) still win for the rest of the current map's visit, but
  # the next map load recomputes from the tree again, exactly as RPG_RT does.
  module MapAccess
    TRISTATE_PARENT = 0
    TRISTATE_ALLOW  = 1
    TRISTATE_FORBID = 2

    def self.save_allowed?(map_id, properties)
      allowed?(map_id, properties, :save)
    end

    def self.teleport_allowed?(map_id, properties)
      allowed?(map_id, properties, :teleport)
    end

    def self.escape_allowed?(map_id, properties)
      allowed?(map_id, properties, :escape)
    end

    # The tree walk shared by all three: read tri-state `field` off `map_id`'s
    # node, following "same as parent" up until a node pins Allow/Forbid.
    def self.allowed?(map_id, properties, field)
      seen = {}
      id = map_id.to_i
      while id > 0 && !seen[id]
        seen[id] = true
        row = properties ? properties[id] : nil
        return true unless row
        v = row.respond_to?(field) ? row.send(field) : nil
        v = TRISTATE_ALLOW if v.nil? # schema default for an unset field
        return v != TRISTATE_FORBID unless v == TRISTATE_PARENT
        id = row.respond_to?(:parent_map_id) ? row.parent_map_id.to_i : 0
      end
      true
    end
  end

  # One entry of an enemy's 行動パターン (action pattern) table — the database
  # enemy row's chunk 42, decoded off the LCF row into plain data so the battle
  # simulation can pick an action without holding a database row.
  #
  # An enemy does not simply attack: each turn RPG_RT walks this table, keeps the
  # entries whose `condition` currently holds, and picks one at random weighted
  # by `rating` (see Game::Battle#choose_enemy_action). `kind` says what the
  # chosen entry does — a basic action, a skill, or a transformation into another
  # enemy — and an entry may also flip a switch once it has run.
  #
  # The field names and values are liblcf's RPG::EnemyAction. Real data uses
  # nearly all of them: across the two test beds 510 of 959 actions are skills
  # (which is why an enemy that only ever swung its fists was so far off), and
  # every condition type except `sp` appears.
  class EnemyAction
    # `kind`: what the action does.
    KIND_BASIC     = 0
    KIND_SKILL     = 1
    KIND_TRANSFORM = 2

    # `basic`: which basic action, when kind is KIND_BASIC.
    BASIC_ATTACK       = 0
    BASIC_DUAL_ATTACK  = 1
    BASIC_DEFEND       = 2
    BASIC_OBSERVE      = 3
    BASIC_CHARGE       = 4
    BASIC_AUTODESTRUCT = 5
    BASIC_ESCAPE       = 6
    BASIC_NOTHING      = 7

    # `condition_type`: what gates the action. The two `condition_param`s are the
    # inclusive bounds of a range for the numeric conditions, and the turn
    # condition's base / multiple pair.
    COND_ALWAYS    = 0
    COND_SWITCH    = 1
    COND_TURN      = 2
    COND_ACTORS    = 3
    COND_HP        = 4
    COND_SP        = 5
    COND_PARTY_LVL = 6
    COND_FATIGUE   = 7

    attr_reader :kind, :basic, :skill_id, :enemy_id, :condition_type,
                :condition_param1, :condition_param2, :switch_id, :switch_on,
                :switch_on_id, :switch_off, :switch_off_id, :rating

    # Read one action off an LCF row, tolerating a fixture that omits a field
    # (the check harnesses build these by hand).
    def initialize(row)
      @kind             = int_of(row, :kind, 0)
      @basic            = int_of(row, :basic, 0)
      @skill_id         = int_of(row, :skill_id, 0)
      @enemy_id         = int_of(row, :enemy_id, 0)
      @condition_type   = int_of(row, :condition_type, 0)
      @condition_param1 = int_of(row, :condition_param1, 0)
      @condition_param2 = int_of(row, :condition_param2, 0)
      @switch_id        = int_of(row, :switch_id, 0)
      @switch_on_id     = int_of(row, :switch_on_id, 0)
      @switch_off_id    = int_of(row, :switch_off_id, 0)
      @switch_on        = bool_of(row, :switch_on)
      @switch_off       = bool_of(row, :switch_off)
      # The editor's default priority is 50; a row without one still competes.
      @rating           = int_of(row, :rating, 50)
    end

    def skill?;     @kind == KIND_SKILL; end
    def transform?; @kind == KIND_TRANSFORM; end
    def basic?;     @kind == KIND_BASIC; end

    private

    def int_of(row, name, dflt)
      return dflt unless row.respond_to?(name)
      v = row.send(name)
      v.nil? ? dflt : v.to_i
    end

    def bool_of(row, name)
      row.respond_to?(name) && row.send(name) ? true : false
    end
  end

  # A single enemy instantiated from the database (chunk 14) for a battle: its
  # combat stats plus the EXP / gold it is worth and its battle-screen position.
  # Current HP / SP start full. The turn-based battle that would reduce them is
  # not built yet, so for now this backs the Enemy Encounter reward model.
  class Enemy
    attr_reader :id, :name, :battler_name, :max_hp, :max_sp, :atk, :def, :spi,
                :agi, :exp, :gold, :x, :y, :drop_id, :drop_prob
    attr_accessor :hp, :sp
    # Whether the member starts the fight off-screen. Writable because the Show
    # Hidden Monster battle-event command (13150) brings one in mid-fight.
    attr_accessor :hidden

    def initialize(db, id, x = 0, y = 0, hidden = false)
      row = db.enemy[id]
      @id = id
      @name    = row ? row.name.to_s : ''
      # The Monster/<name> battle graphic (blank for a fixture that omits it);
      # the battle screen draws it, falling back to a placeholder block.
      @battler_name = row && row.respond_to?(:battler_name) ? (row.battler_name || '') : ''
      @max_hp  = row ? row.max_hp : 1
      @max_sp  = row ? row.max_sp : 0
      @atk     = row ? row.attack : 0
      @def     = row ? row.defense : 0
      @spi     = row ? row.spirit : 0
      @agi     = row ? row.agility : 0
      @exp     = row ? row.exp : 0
      @gold    = row ? row.gold : 0
      # The item this enemy may drop on defeat (field 13, 0 = none) and its drop
      # probability as a percentage (field 14; 0 for a fixture lacking it).
      @drop_id   = row && row.respond_to?(:drop_id) ? (row.drop_id || 0) : 0
      @drop_prob = row && row.respond_to?(:drop_prob) ? (row.drop_prob || 0) : 0
      @x = x
      @y = y
      @hidden = hidden ? true : false
      @hp = @max_hp
      @sp = @max_sp
      # Critical-hit chance in basis points (0 = never), from the enemy's
      # critical_hit flag and its 1-in-`critical_hit_chance` rate. An enemy has
      # no equipment, so unlike an actor's this is the whole of it.
      @crit_chance = if row && row.respond_to?(:critical_hit) && row.critical_hit
                       n = row.respond_to?(:critical_hit_chance) ? row.critical_hit_chance : 0
                       n && n > 0 ? CRIT_SCALE / n : 0
                     else
                       0
                     end
      # Per-attribute defence ranks ({ attribute_id => rank 0..4 }) from the
      # enemy's attribute_ranks byte array, so an elemental attack scales its
      # damage by this monster's resistance. Captured now since `row` isn't kept.
      @attribute_ranks = {}
      arr = row && row.respond_to?(:attribute_ranks) ? row.attribute_ranks : nil
      arr.each_with_index { |v, i| @attribute_ranks[i + 1] = v } if arr
      # Per-state susceptibility ranks ({ state_id => rank 0..4 }) from the
      # enemy's state_ranks byte array, scaling how often a status lands on it.
      @state_ranks = {}
      sr = row && row.respond_to?(:state_ranks) ? row.state_ranks : nil
      sr.each_with_index { |v, i| @state_ranks[i + 1] = v } if sr
      # The "miss" flag (field 26): a flagged enemy is clumsier and attacks at a
      # 70% base hit rate rather than the usual 90% (EasyRPG's GetHitChance).
      @miss = row && row.respond_to?(:miss) ? (row.miss ? true : false) : false
      # The 行動パターン table (field 42), decoded now since `row` isn't kept. An
      # enemy whose row lists none falls back to plain attacking.
      @actions = []
      list = row && row.respond_to?(:actions) ? row.actions : nil
      list.each { |_i, a| @actions << EnemyAction.new(a) } if list
    end

    # This enemy's action pattern (Game::EnemyAction list, possibly empty).
    attr_reader :actions

    attr_reader :crit_chance, :attribute_ranks, :state_ranks

    # Base to-hit percentage for this enemy's normal attack (70 when the "miss"
    # flag is set, otherwise 90); fed into the battle's to-hit roll.
    def attack_hit_rate; @miss ? 70 : 90; end

    def dead?; @hp <= 0; end
  end

  # An enemy troop (敵グループ, chunk 15) instantiated for a battle: the live
  # Enemy members at their positions. Also totals the EXP / gold the troop is
  # worth, which the Enemy Encounter command grants on victory. The battle
  # simulation itself is still to come.
  class Troop
    attr_reader :id, :name, :members
    # The troop's battle-event pages (chunk 11), each entry carrying a
    # `condition` (see Game::BattlePage) and an `event` command list the battle
    # interpreter runs. nil / empty for a troop that scripts nothing.
    attr_reader :pages

    def initialize(db, id)
      row = db.enemy_group[id]
      @id = id
      @name = row ? row.name.to_s : ''
      @members = []
      # Array2D#each yields (id, entry); a plain Hash test double does the same.
      row.members.each { |_, m| @members << member(db, m) } if row && row.members
      @pages = row && row.respond_to?(:pages) ? row.pages : nil
    end

    def total_exp;  @members.reduce(0) { |s, e| s + e.exp } end
    def total_gold; @members.reduce(0) { |s, e| s + e.gold } end

    # The item ids the troop yields on victory: each member carrying a drop item
    # rolls its `drop_prob` percentage against `rng` (0..99 < prob, EasyRPG's
    # Rand::PercentChance), so a 100% drop is certain, a 0% never lands, and the
    # same item can drop from several members. Returns the ids in member order.
    def drops(rng)
      @members.each_with_object([]) do |e, out|
        next unless e.drop_id && e.drop_id > 0
        out << e.drop_id if rng.random(100) < e.drop_prob
      end
    end

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
  # The outside world an enemy's 行動パターン needs, which Game::Battle itself
  # deliberately does not hold: it works on Combatant snapshots and keeps no
  # database. A skill action needs the skill table (and the party's own casting
  # formulas, so an enemy's fireball is costed and scaled exactly like a hero's),
  # a transformation needs the enemy table, and the switch / party-level
  # conditions read live game state.
  #
  # Passed to Game::Battle as its `ai` collaborator. Every accessor tolerates a
  # partial source so the check harnesses can hand in a stub (or nothing at all,
  # in which case the enemies fall back to plain attacking as before).
  class EnemyAi
    def initialize(db, state)
      @db = db
      @state = state
    end

    # The database row for a skill / enemy id, or nil.
    def skill(id)
      @db && @db.respond_to?(:skill) ? @db.skill[id] : nil
    end

    # A freshly instantiated Game::Enemy for `id` — what a transformation turns
    # into, read through the same constructor a troop member is built with (so it
    # decodes its stats, ranks and its own action pattern). nil when unknown.
    def enemy(id)
      return nil unless @db && @db.respond_to?(:enemy) && id && id > 0
      return nil unless @db.enemy[id]
      Enemy.new(@db, id)
    end

    # The cast numbers for `sk` from `caster` on `target`, reusing Game::Party's
    # own battle_skill_command so an enemy's skill costs and scales identically.
    def skill_command(sk, caster, target)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return nil unless party && party.respond_to?(:battle_skill_command)
      party.battle_skill_command(sk, caster, target)
    end

    def switch?(id)
      sw = @state && @state.respond_to?(:switches) ? @state.switches : nil
      sw ? sw[id] : false
    end

    def set_switch(id, on)
      sw = @state && @state.respond_to?(:switches) ? @state.switches : nil
      sw[id] = on if sw && id && id > 0
    end

    # The party's average level, which the party_lvl action condition ranges
    # over (EasyRPG's Game_Party::GetAverageLevel). 0 with no party.
    def party_level
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      actors = party && party.respond_to?(:actors) ? party.actors : nil
      return 0 if actors.nil? || actors.empty?
      total = 0
      actors.each { |a| total += (a.respond_to?(:level) ? (a.level || 0) : 0) }
      total / actors.size
    end
  end

  # Read-only helpers over the database's state table (the `situation` array,
  # id -> row). The battle simulation acts on state *ids*; showing one needs its
  # name, its palette colour and the sentences RPG_RT prints when it lands or
  # lifts, and all of those live on the row.
  #
  # Every accessor tolerates a row that omits a field — the table is a fixture in
  # the unit checks and an English game leaves the message strings blank — so a
  # caller can always ask and decide what to do with a nil answer.
  module States
    # State 1 is 戦闘不能 (death) in every RPG2000 database; it is the one state
    # whose priority is not consulted.
    DEATH_ID = 1
    # The `situation` table's own default colour (schema element 3).
    DEFAULT_COLOR = 6

    def self.row(id, table)
      return nil if id.nil? || id <= 0 || table.nil?
      table[id]
    rescue StandardError
      nil
    end

    # The one state a battler *shows*, from the ids it carries: death outranks
    # everything, otherwise the highest `priority` wins, ties going to the later
    # id. A port of EasyRPG's State::GetSignificantState, whose `>=` comparison
    # is what makes the tie go to the later one. nil when the battler is clear.
    def self.significant(ids, table)
      return nil if ids.nil? || ids.empty?
      best = nil
      best_priority = -1
      # Ascending id order, because the tie rule depends on it: EasyRPG walks the
      # table from id 1 upward and keeps a state whose priority merely *equals*
      # the best so far, so among equal priorities the highest id wins. A
      # battler's own list is in the order the states landed, which is not that.
      ids.compact.sort.each do |id|
        next if id <= 0
        return DEATH_ID if id == DEATH_ID
        r = row(id, table)
        priority = r && r.respond_to?(:priority) ? (r.priority || 0) : 0
        next if priority < best_priority
        best = id
        best_priority = priority
      end
      best
    end

    # A state's own `priority` field (0 for an unknown id or a fixture row
    # that omits it), the same lookup #significant makes per-id.
    def self.priority_of(id, table)
      r = row(id, table)
      r && r.respond_to?(:priority) ? (r.priority || 0) : 0
    end

    # How far below the current top priority a state may sit before RPG_RT
    # drops it outright (yado.tk: multiple active states all still apply
    # mechanically, but one 10+ priority below the current highest is
    # auto-removed).
    PRUNE_GAP = 10

    # `ids` after RPG_RT's crowding-out rule: any state 10+ priority below the
    # current highest-priority state it carries is dropped. Only the *value*
    # of the top priority matters here (unlike #significant, no id is singled
    # out), so ties do not change what survives -- everything within the gap
    # of the top, however many states share it, stays. Death (DEATH_ID) is
    # exempt on both sides: it never gets pruned, and (matching #significant,
    # which never even reads its priority) it does not count toward "the
    # current highest" either -- knockout is tracked through HP/#dead?, not
    # through this ranking. `ids` with one or fewer non-death entries has
    # nothing to compare, and comes back unchanged.
    def self.prune(ids, table)
      return ids if ids.nil? || ids.size <= 1
      ranked = ids.reject { |id| id == DEATH_ID }
      return ids if ranked.size <= 1
      top = ranked.map { |id| priority_of(id, table) }.max
      ids.select { |id| id == DEATH_ID || priority_of(id, table) > top - PRUNE_GAP }
    end

    # The state's display name, or nil when the table does not name it (a
    # fixture, or an id the database does not define).
    def self.name(id, table)
      r = row(id, table)
      n = r && r.respond_to?(:name) ? r.name : nil
      n.nil? || n.empty? ? nil : n
    end

    # The message-palette colour index the name is drawn in.
    def self.color(id, table)
      r = row(id, table)
      c = r && r.respond_to?(:color) ? r.color : nil
      c.nil? ? DEFAULT_COLOR : c
    end

    # RPG_RT's sentence for a state landing on `battler_name`. The database
    # stores the *predicate* only ("は毒にかかった！"), which RPG2000 prints
    # straight after the battler's name — EasyRPG's GetStateMessage, whose
    # placeholder form is RPG2003-only. Actors and enemies get different
    # wordings (message_actor / message_enemy). nil when the database has no
    # sentence, so the caller can compose its own.
    def self.inflict_message(id, table, battler_name, ally)
      message(battler_name,
              field(id, table, ally ? :message_actor : :message_enemy))
    end

    # ... and for a state lifting, which has one wording for both sides.
    def self.recovery_message(id, table, battler_name)
      message(battler_name, field(id, table, :message_recovery))
    end

    # ... and for one the target **already** carried when something tried to
    # inflict it again ("はすでに毒に冒されている！"). One wording for both sides,
    # like the recovery line. RPG_RT treats this as a result worth announcing
    # rather than a silent no-op, which is why the field exists at all: 15 of
    # Nepheshel's 25 states and 7 of mtf-meido-action's 10 fill it in.
    def self.already_message(id, table, battler_name)
      message(battler_name, field(id, table, :message_already))
    end

    def self.field(id, table, name)
      r = row(id, table)
      v = r && r.respond_to?(name) ? r.send(name) : nil
      v.nil? || v.empty? ? nil : v
    end

    def self.message(battler_name, predicate)
      return nil unless predicate
      "#{battler_name}#{predicate}"
    end

    # The 用語 (term) table's battle sentences, composed the way RPG2000 does.
    #
    # Every one of these fields is a *predicate*, not a template: the database
    # stores 「の攻撃！」 and RPG_RT puts the battler's name in front of it. The
    # `%S`-style placeholders EasyRPG supports are an RPG2003 / 2k3E feature, so
    # this side of it is pure concatenation with one Japanese particle.
    #
    # Both test beds fill in 126 of the 127 term fields, and until now the
    # runtime read two of them (`gold`, `normal_status`): the battle log spoke
    # invented English while the game's own words sat unread in the table.
    #
    # Each builder returns nil when the field is blank, so the caller can keep
    # its composed English for a database that leaves one out.
    module BattleText
      # The particle between a battler's name and the number of a damage line.
      # RPG_RT picks it by side -- は for one of yours, に for one of theirs --
      # and follows the number with a space. This is the CP932 branch of
      # EasyRPG's `GetDamagedMessage`; the Western-encoding branch uses a plain
      # space for both, and this build decodes every string as CP932 (see
      # LCF.cp932_to_utf8), so there is no second branch to take.
      ALLY_PARTICLE = 'は '.freeze
      ENEMY_PARTICLE = 'に '.freeze

      def self.term(terms, name)
        v = terms && terms.respond_to?(name) ? terms.send(name) : nil
        v.nil? || v.to_s.empty? ? nil : v.to_s
      end

      # `name + predicate` — the shape of every "so-and-so did a thing" line:
      # the attack itself (`attacking`), Defend (`defending`), Observe
      # (`observing`), Charge (`focus`), an enemy blowing itself up
      # (`autodestruction`), one fleeing (`enemy_escape`) and one transforming
      # (`enemy_transform`).
      def self.action(terms, battler_name, field)
        t = term(terms, field)
        t && "#{battler_name}#{t}"
      end

      # 「スライムに 42 のダメージを与えた！」 / 「リトは 42 のダメージを受けた！」
      # — the same sentence from the two sides, which is why the table holds two
      # predicates and one particle rule rather than two whole templates.
      def self.damage(terms, target_name, value, ally)
        t = term(terms, ally ? :actor_damaged : :enemy_damaged)
        return nil unless t
        "#{target_name}#{ally ? ALLY_PARTICLE : ENEMY_PARTICLE}#{value} #{t}"
      end

      # A blow that got through for nothing: no number and no particle.
      def self.undamaged(terms, target_name, ally)
        action(terms, target_name, ally ? :actor_undamaged : :enemy_undamaged)
      end

      # A miss. RPG2000 words it from the target's side ("...は身をかわした！"),
      # which is why one term serves both sides.
      def self.dodge(terms, target_name)
        action(terms, target_name, :dodge)
      end

      # A skill announces itself with its **own** two sentences rather than with
      # a term, which is why a skill has a voice and a plain attack does not.
      # `using_message1` follows the caster's name the way every other predicate
      # does; `using_message2` stands alone as a second line (EasyRPG's
      # `GetSkillSecondStartMessage2k` returns the field with no name in front),
      # so a skill can read 「リトは炎を放った！」 / 「あたりが真っ赤に染まる！」.
      #
      # Returns [] when the skill sets neither, so the caller keeps its own line.
      # 351 of the test beds' skills set the first and 18 the second.
      def self.skill_start(skill_row, caster_name)
        return [] unless skill_row
        first = term(skill_row, :using_message1)
        second = term(skill_row, :using_message2)
        lines = []
        lines << "#{caster_name}#{first}" if first
        lines << second if second
        lines
      end

      # A skill that achieved nothing. Which sentence says so is the skill row's
      # own choice: `failure_message` indexes the three 用語 failure lines, and 3
      # borrows the dodge line (EasyRPG's `GetSkillFailureMessage`). Worded from
      # the target's side, like the dodge it can become.
      FAILURE_TERMS = [:skill_failure_a, :skill_failure_b, :skill_failure_c,
                       :dodge].freeze

      # An item has no sentence of its own — it borrows the `use_item` term, and
      # is the one line RPG2000 builds from *two* names: 「リトはポーションを使っ
      # た！」 is the caster, は, the item, and the term. (`item.using_message` is
      # an int selecting a battle animation layout, not a string; no RPG2000 item
      # carries a sentence.)
      def self.item_start(terms, caster_name, item_name)
        t = term(terms, :use_item)
        t && "#{caster_name}#{ALLY_PARTICLE.strip}#{item_name}#{t}"
      end

      # 「リトのＨＰが 30 回復した！」 — what a potion or a cure spell restored.
      # `points` is the 用語 name of the pool (`hp` / `mp`, which Nepheshel writes
      # full-width as ＨＰ / ＭＰ and mtf-meido-action as HP / MP), and the shape
      # is EasyRPG's `GetHpSpRecoveredMessage`: name, の, pool, "が ", the amount,
      # a space, then the term.
      def self.recovered(terms, target_name, value, points)
        t = term(terms, :hp_recovery)
        pool = term(terms, points)
        return nil unless t && pool
        "#{target_name}の#{pool}が #{value} #{t}"
      end

      # 「スライムのＨＰを 20 奪った！」 / 「リトはＨＰを 20 奪われた！」 — what a
      # 吸収 skill took. Close to the recovery line but not the same shape: the
      # particle before the pool name is の for one of theirs and は for one of
      # yours (the recovery line always takes の), the pool is followed by を
      # rather than が, and the two sides have their own predicate.
      def self.absorbed(terms, target_name, value, points, ally)
        t = term(terms, ally ? :actor_hp_absorbed : :enemy_hp_absorbed)
        pool = term(terms, points)
        return nil unless t && pool
        "#{target_name}#{ally ? 'は' : 'の'}#{pool}を #{value} #{t}"
      end

      def self.skill_failure(terms, skill_row, target_name)
        i = skill_row && skill_row.respond_to?(:failure_message) ?
              skill_row.failure_message : nil
        f = FAILURE_TERMS[i || 0]
        f && action(terms, target_name, f)
      end
    end

    # Map-step slip damage: RPG2000's field poison. A state drains HP every
    # `hp_change_map_steps` tiles the party walks, by `hp_change_map_val` --
    # and SP through the matching `sp_change_map_steps` / `sp_change_map_val`
    # pair. Returns `[hp_loss, sp_loss]` for a party that has now walked `steps`
    # tiles: each is the state's own amount when this step lands on a multiple of
    # its interval, and 0 otherwise.
    #
    # Both halves need a positive interval *and* a positive amount. A row
    # carrying one without the other is not configured for slip at all (every
    # state in both test beds leaves both at 0 bar one), and guarding the
    # interval is also what keeps the modulo off zero. `steps` of 0 drains
    # nothing, so the counter must be advanced before this is asked -- otherwise
    # the party's very first frame on a map would be a multiple of every
    # interval.
    def self.map_step_drain(id, table, steps)
      r = row(id, table)
      return [0, 0] if r.nil? || steps.nil? || steps <= 0
      [drain(r, steps, :hp_change_map_steps, :hp_change_map_val),
       drain(r, steps, :sp_change_map_steps, :sp_change_map_val)]
    end

    def self.drain(row, steps, steps_field, val_field)
      interval = int_field(row, steps_field)
      amount = int_field(row, val_field)
      return 0 if interval <= 0 || amount <= 0
      (steps % interval).zero? ? amount : 0
    end

    def self.int_field(row, name)
      v = row.respond_to?(name) ? row.send(name) : nil
      v.nil? ? 0 : v
    end
  end

  # resolution. It works on Combatant snapshots, so the caller can resolve a
  # battle without mutating the real party. This is a deliberately simple first
  # cut — escape and enemy-cast state infliction are still to come, and the
  # turn-based battle *screen* wires the refinements (skills, items, criticals,
  # elemental attributes, damage variance) into a live fight.
  class Battle
    # A battler reduced to what the fight needs. Snapshotting Game::Actor /
    # Game::Enemy keeps the real party untouched by a resolved battle.
    # `action` is the ally's chosen attack target for the round (nil = none /
    # auto), `defending` halves damage taken that round, and `command` is a
    # queued Skill / Item action (see Battle#apply_command); these are
    # cleared each round. `skip` forfeits the turn outright (a failed escape).
    # Enemies leave them nil and attack a random party
    # member. `mp` / `max_mp` carry SP (skills spend it) and `spi` is the spirit
    # stat the skill formulas read as `int`.
    Combatant = Struct.new(:name, :atk, :def, :agi, :hp, :max_hp,
                           :action, :defending, :mp, :max_mp, :spi, :command,
                           :actor, :states, :state_turns, :crit_chance,
                           :prevents_crit, :attr_ranks, :atk_attrs, :skip,
                           :hit_rate, :state_ranks, :hidden, :battle_turn,
                           :actions, :charged, :enemy_id, :battler_name,
                           # Equipment-granted combat modifiers (ADR 0033):
                           # how many times a basic attack swings, whether it
                           # can be evaded, whether Defend halves twice, and
                           # whether skills cost half.
                           :strikes, :ignores_evasion, :strong_defence,
                           :half_sp_cost,
                           # Whether this battler's own gear makes a normal
                           # attack likelier to miss it (Actor#physical_evasion_up?,
                           # a flat -25 to the attacker's to_hit -- see
                           # Battle#to_hit). Enemy Combatants leave it nil/false;
                           # monsters equip nothing.
                           :evasion_up,
                           # A basic Attack spread across the target's whole
                           # side (attack_all?) or jumped to the front of the
                           # round's turn order (preemptive?) -- see #turn_order
                           # and #strike. Actor-only; an enemy Combatant leaves
                           # both nil/false, so it never qualifies for either.
                           :attack_all, :preemptive,
                           # The ranks #attr_ranks started the battle at --
                           # never itself written to, only read to cap how far
                           # an "attribute defence up/down" skill (see
                           # #skill_attr_shift) may move #attr_ranks in either
                           # direction. Since #attr_ranks is a fresh Hash per
                           # Combatant (Game::Actor#attribute_ranks builds one
                           # from the database row on every call, not a cached
                           # one) and #apply_to_party never writes it back to
                           # the actor, a shift is battle-scoped for free: it
                           # dies with the Combatant, no separate reset needed.
                           :attr_base_ranks) do
      def dead?; hp <= 0; end

      # Swings per basic attack: 2 with a 二刀流 weapon, 1 otherwise. Struct
      # members start nil, so the reader normalises.
      def strike_count; n = strikes; n && n > 1 ? n : 1; end
      # Whether this battler's gear halves what a skill costs (Party#skill_cost
      # asks whatever it is handed, actor or snapshot).
      def half_sp_cost?; half_sp_cost ? true : false; end

      # RPG2003 counts turns per battler as well as per battle: this is how many
      # turns *this* battler has taken, which the troop pages' turn_enemy /
      # turn_actor conditions are written against. Mirrors EasyRPG's
      # Game_Battler::GetBattleTurn, which Scene_Battle's NextTurn(battler)
      # increments as that battler's own turn begins (and ResetBattle zeroes).
      # Struct members start nil, so the reader normalises rather than every
      # construction site having to pass 0.
      def turns_taken; battle_turn || 0; end
      def next_battle_turn; self.battle_turn = turns_taken + 1; end
      # A troop member the editor placed but flagged invisible has not entered
      # the fight yet: it does not act, cannot be targeted and does not keep the
      # battle going. Show Hidden Monster (13150) clears the flag and brings it
      # in. Distinct from `dead?`, which is purely about HP.
      def out_of_play?; dead? || hidden ? true : false; end
      # Spirit under the name Game::Party's skill formulas (#skill_effect,
      # #skill_cost) read on a caster.
      def int; spi; end
      # Whether `id` is currently afflicting this battler.
      def state?(id); (states || []).include?(id); end
    end

    # Seed the combatant's status set from the actor, so a member who walked into
    # the fight afflicted (a map Change Condition) is still afflicted in battle,
    # and a cure applied here can be written back. A bare fixture without #states
    # starts clean.
    def self.actor_states(a); a.respond_to?(:states) ? (a.states || []).dup : []; end

    # A battler's critical-hit chance in basis points (0 when it never crits, or
    # the source lacks the field).
    def self.crit_chance_of(b); b.respond_to?(:crit_chance) ? b.crit_chance : 0; end

    # Whether a battler's gear guards against critical hits.
    def self.prevents_crit_of(b); b.respond_to?(:prevents_critical?) && b.prevents_critical?; end

    # A battler's per-attribute defence ranks ({ attribute_id => rank 0..4 }), or
    # {} when the source (a bare fixture) doesn't model them.
    def self.attr_ranks_of(b); b.respond_to?(:attribute_ranks) ? b.attribute_ranks : {}; end

    # The elemental attribute ids a battler's basic attack carries (its equipped
    # weapon's attribute_set); [] for an enemy or an unarmed / fixture attacker.
    def self.atk_attrs_of(b); b.respond_to?(:weapon_attributes) ? b.weapon_attributes : []; end

    # A battler's basic-attack base hit rate (percent), or 90 (the RPG2000
    # default) when the source (a bare fixture) doesn't model one.
    def self.hit_rate_of(b); b.respond_to?(:attack_hit_rate) ? b.attack_hit_rate : 90; end

    # A battler's per-state susceptibility ranks ({ state_id => rank 0..4 }), or
    # {} when the source (a bare fixture) doesn't model them.
    def self.state_ranks_of(b); b.respond_to?(:state_ranks) ? b.state_ranks : {}; end

    def self.from_actor(a)
      c = Combatant.new(a.name, a.atk, a.def, a.agi, a.hp, a.max_hp,
                    nil, false, a.mp, a.max_mp, a.int, nil, a, actor_states(a),
                    nil, crit_chance_of(a), prevents_crit_of(a),
                    attr_ranks_of(a), atk_attrs_of(a), nil, hit_rate_of(a),
                    state_ranks_of(a))
      c.strikes = flag_of(a, :dual_attack?) ? 2 : 1
      c.ignores_evasion = flag_of(a, :ignores_evasion?)
      c.attack_all = flag_of(a, :attack_all?)
      c.preemptive = flag_of(a, :preemptive?)
      c.strong_defence = flag_of(a, :strong_defence?)
      c.half_sp_cost = flag_of(a, :half_sp_cost?)
      c.evasion_up = flag_of(a, :physical_evasion_up?)
      c.attr_base_ranks = c.attr_ranks.dup
      c
    end

    # A boolean predicate on the source row, false for a fixture without it.
    def self.flag_of(b, name); b.respond_to?(name) && b.send(name) ? true : false; end

    # Enemies have no source actor (that field stays nil), so the post-battle
    # write-back skips them; they carry no status set into this simple sim.
    def self.from_enemy(e)
      c = Combatant.new(e.name, e.atk, e.def, e.agi, e.hp, e.max_hp,
                        nil, false, e.sp, e.max_sp, e.spi, nil, nil, [], nil,
                        crit_chance_of(e), prevents_crit_of(e),
                        attr_ranks_of(e), atk_attrs_of(e), nil, hit_rate_of(e),
                        state_ranks_of(e))
      # A member the troop flagged invisible starts out of play until a Show
      # Hidden Monster command brings it in (see Combatant#out_of_play?).
      c.hidden = e.respond_to?(:hidden) && e.hidden ? true : false
      # The 行動パターン the AI picks from each turn, and the database id it was
      # built from (which a transformation re-points at another enemy row).
      c.actions = e.respond_to?(:actions) ? (e.actions || []) : []
      c.enemy_id = e.respond_to?(:id) ? e.id : nil
      # The Monster/<name> graphic, carried so the battle screen can redraw a
      # combatant whose transformation swapped it.
      c.battler_name = e.respond_to?(:battler_name) ? e.battler_name : nil
      c.attr_base_ranks = c.attr_ranks.dup
      c
    end

    # RPG2000-style physical damage: half the attacker's attack less a quarter of
    # the defender's defence, floored at 1 so a fight always terminates.
    def self.attack_damage(atk, dfn)
      d = atk / 2 - dfn / 4
      d < 1 ? 1 : d
    end

    MAX_ROUNDS = 1000 # safety net against a stalemate (should never be reached)

    # RPG_RT's battle damage popup is a fixed three digits, so every single hit
    # -- normal attack, dual-wield swing, attack-skill, self-destruct, and
    # per-turn state slip damage alike -- is hard-clamped to 999 before it is
    # subtracted from the target's HP, no matter how large the underlying ATK/
    # DEF/attribute math computes. A yado.tk-quirks build with no cap could
    # one-shot a target well past what the original engine could ever display
    # or apply in a single blow.
    DAMAGE_CAP = 999

    # Same fixed-width-popup reasoning as DAMAGE_CAP, for the opposite
    # direction: RPG_RT's HP-recovery popup is the same fixed 3-digit widget
    # as the damage one, so a single heal can't display (or apply) more than
    # 999 either, no matter how large `recover_hp_rate` x max_hp computes it.
    RECOVER_CAP = 999

    attr_reader :allies, :enemies, :rounds, :result, :log, :rng, :escape_chance

    # `states` is an optional state-definition lookup (`[id]` -> a row exposing
    # `restriction` / `hp_change_val` / `hp_change_max` / `sp_change_val` /
    # `sp_change_max`, e.g. the database's `situation` table). When given, a
    # battler's afflicted states take effect each turn (slip damage, skip if it
    # cannot act); omitted, states are inert as before.
    # `variance`, when true, applies RPG2000's +/- spread to each basic attack's
    # damage (a `var` of 4, per EasyRPG's Algo::VarianceAdjustEffect). `criticals`,
    # when true, lets a basic attack land a 3x critical at the attacker's
    # `crit_chance` (basis points). `accuracy`, when true, rolls each basic attack's
    # to-hit chance so it can miss (see #to_hit). All three are off by default so
    # a seeded fight is exactly reproducible; the live game turns them on.
    # `first_strike`, when true, gives the party a pre-emptive opening round: the
    # enemies are caught off guard and skip their turn in round 1 only.
    # `attributes` is an optional attribute-definition lookup (`[id]` -> a row
    # exposing `a_rate` .. `e_rate`, e.g. the database's `property` table) so
    # elemental damage reads each attribute's own rank rates; omitted, the
    # RPG2000 default table applies.
    # `ai` is an optional Game::EnemyAi giving the enemies' action patterns the
    # database and game state they need (skill / enemy tables, switches, the
    # party's average level). Without one an enemy can still run the basic
    # actions its pattern lists, but a skill or transformation it cannot resolve
    # falls back to a plain attack — which is exactly the old behaviour, so every
    # existing fixture keeps its results.
    def initialize(allies, enemies, rng = nil, states = nil, variance = false,
                   criticals = false, accuracy = false, first_strike = false,
                   attributes = nil, ai = nil)
      @allies = allies
      @enemies = enemies
      @rng = rng || Rng.new(0x2000)
      @states = states
      @variance = variance
      @criticals = criticals
      @accuracy = accuracy
      @first_strike = first_strike
      @attributes = attributes
      @ai = ai
      @rounds = 0
      @result = nil
      @escaped = false # set once the party successfully flees (#attempt_escape)
      # Computed once, right here at battle start -- EasyRPG's Scene_Battle::Start
      # calls InitEscapeChance() exactly once, before any turn runs, and
      # #attempt_escape only ever adds to that one fixed starting value on a
      # failure (Scene_Battle::TryEscape's `escape_chance += 10`); nothing
      # re-derives it from the agilities again later. Computing it lazily on
      # the first #attempt_escape call instead (as this used to) reads
      # whatever a state has done to someone's agility by that point in the
      # fight rather than what the roster carried when the fight began.
      @escape_chance = compute_escape_chance
      @force_flee = false  # a battle page granted the party a guaranteed escape
      @log = []      # one entry per landed attack, in order (see #strike)
      @queue = []    # battlers still to act this round, in agility order
      @pending = []  # extra hits of an all-target action, drained one per #step
    end

    # RPG2000 normal-attack damage variance on the 0-10 `var` scale.
    NORMAL_ATTACK_VARIANCE = 4

    # State `restriction` values (lcf::rpg::State::Restriction): the battler
    # cannot act (asleep / paralysed), is forced to attack a random enemy
    # (berserk / provoke), or attacks a random member of its own side (confused).
    RESTRICTION_DO_NOTHING   = 1
    RESTRICTION_ATTACK_ENEMY = 2
    RESTRICTION_ATTACK_ALLY  = 3

    # True once one side has been wiped out, or the party has fled — the battle
    # is decided.
    def finished?; @escaped || !alive?(@allies) || !alive?(@enemies); end

    # Whether the party successfully escaped this fight.
    def escaped?; @escaped; end

    # -- battle-event context -------------------------------------------------
    #
    # The protocol the troop's battle-event pages run against: Game::BattlePage
    # tests their conditions through it and Game::Interpreter's battle commands
    # (Change Monster HP / MP / Condition, the battle Conditional Branch, ...)
    # act on it. Enemies are addressed by their 0-based index within the troop,
    # the way the editor numbers them.

    # Turns elapsed, counted from 0 before the first round has run — RPG2000's
    # battle turn number, which the pages' turn conditions are written against.
    def turn; @rounds; end

    # The live combatant for troop member `index`, or nil when out of range.
    def enemy(index)
      return nil unless index.is_a?(Integer) && index >= 0
      @enemies[index]
    end

    # The live combatant for the party member whose database actor id is `id`
    # (nil when that actor is not in this fight).
    def ally_by_actor_id(id)
      @allies.find { |a| a.actor && a.actor.respond_to?(:id) && a.actor.id == id }
    end

    # Turns taken by troop member `index` / by the party member whose database
    # actor id is `id` — the RPG2003 per-battler turn counters the pages'
    # turn_enemy / turn_actor conditions test (Combatant#turns_taken). nil for a
    # battler that is not in this fight, which fails the page rather than
    # answering a condition about someone who is not here.
    def enemy_turn(index)
      foe = enemy(index)
      foe && foe.turns_taken
    end

    def actor_turn(id)
      ally = ally_by_actor_id(id)
      ally && ally.turns_taken
    end

    # The party's exhaustion, 0 (untouched) to 100 (wiped out) — the RPG2003
    # `fatigue` page condition. Ported from EasyRPG's Game_Party::GetFatigue:
    # HP is two thirds of the weight and SP one third, so a party at full HP with
    # no SP left still only reaches 33. Written in integer arithmetic (mruby has
    # no rounding helper here) with the same round-half-up the C++ does; an
    # SP-less party divides by 1 rather than 0, exactly as the original notes.
    def fatigue
      return 0 if @allies.empty?
      hp = 0; total_hp = 0; sp = 0; total_sp = 0
      @allies.each do |a|
        hp += a.hp
        total_hp += a.max_hp || 0
        sp += a.mp || 0
        total_sp += a.max_mp || 0
      end
      return 0 if total_hp <= 0
      total_sp = 1 if total_sp <= 0
      num = 100 * (2 * hp * total_sp + sp * total_hp)
      den = 3 * total_hp * total_sp
      100 - (2 * num + den) / (2 * den)
    end

    # The `command_actor` page condition (which battle command an actor just
    # chose) is answered "unknown" (nil), which Game::BattlePage reads as
    # "fails the page" rather than firing it unchecked — and this is not a
    # gap to close, it is what RPG_RT itself does for RPG2000's battle system.
    # EasyRPG's `AreConditionsMet` only evaluates the condition when it is
    # handed a `source` battler (`if (!source) return false;`), and
    # `Scene_Battle_Rpg2k::CheckBattleEndAndScheduleEvents` — the *only* call
    # site `Scene_Battle_Rpg2k` has — always calls `ScheduleNextPage(nullptr)`.
    # A per-actor `source` only ever exists in `Scene_Battle_Rpg2k3`, the
    # separate ATB scene this runtime does not model (see the Toggle ATB Mode
    # note); a page gated on `command_actor` is therefore *never satisfiable*
    # under RPG2000's own battle system, not merely unimplemented here.
    def actor_command(_id); nil; end

    # Force Flee (1006), target 0: let the party leave whenever it next tries.
    # RPG_RT grants the escape rather than performing it, so the player still has
    # to pick Flee — #attempt_escape then always succeeds.
    def force_flee_party; @force_flee = true; end

    # Whether a Force Flee has granted the party its guaranteed escape.
    def force_flee?; @force_flee; end

    # Force Flee, target 2: troop member `index` runs from the fight. The
    # combatant is hidden, which takes it out of play (Combatant#out_of_play?)
    # without counting as a kill. Returns whether anyone actually left, so the
    # caller only plays the escape sound when one did.
    def flee_enemy(index)
      foe = enemy(index)
      return false if foe.nil? || foe.dead? || foe.hidden
      foe.hidden = true
      true
    end

    # Force Flee, target 1: every troop member still standing runs. Returns the
    # indices that left.
    def flee_all_enemies
      fled = []
      @enemies.each_index { |i| fled.push(i) if flee_enemy(i) }
      fled
    end

    # Terminate Battle (13410): abandon the fight outright. Unlike a victory or
    # defeat this has no outcome to process, so it is kept as its own flag the
    # scene polls rather than folded into #finished? / #result.
    def terminate; @terminated = true; end
    def terminated?; @terminated ? true : false; end

    # Persist the fight's outcome onto the real party: write each ally combatant's
    # final status set, HP and SP back to its source actor, so damage taken in
    # battle sticks, a status cured (or inflicted) in battle carries out, and a
    # combatant reduced to 0 comes out knocked out (戦闘不能). Combatants without a
    # source actor -- enemies, or bare test snapshots -- are skipped. States are
    # written before HP so `set_hp` gets the last word on the death state.
    def apply_to_party
      @allies.each do |c|
        next unless c.actor
        c.actor.states = c.states if c.states && c.actor.respond_to?(:states=)
        c.actor.set_hp(c.hp)
        c.actor.mp = Game.clamp(c.mp, 0, c.actor.max_mp) if c.mp
      end
    end

    # Perform the next single action and return its log entry, or nil when the
    # battle is already decided (or has hit the round cap). Living battlers act
    # in agility order; a new round refills the queue.
    def step
      return @pending.shift unless @pending.empty?
      loop do
        return nil if finished?
        refill_queue if @queue.empty?
        return nil if @queue.empty? # hit MAX_ROUNDS
        b = @queue.shift
        next if b.dead?
        # The battler's own turn starts here, whether or not it ends up able to
        # act — RPG_RT bumps the per-battler counter as the turn begins, not
        # once the action lands (EasyRPG's Scene_Battle::NextTurn).
        b.next_battle_turn
        can_act = apply_turn_states(b)
        next if b.dead? || !can_act
        entry = record_action(strike(b))
        next unless entry # attacker had no living target; try the next
        return entry
      end
    end

    # Log the result of a battler's action and return its first entry, buffering
    # the rest. A basic attack / single-target skill returns one entry; an
    # all-target skill returns an array — every entry is logged now (the effects
    # all landed at once) but surfaced one per #step so the screen animates them
    # in turn. nil (no living target) passes straight through.
    def record_action(result)
      return nil if result.nil?
      entries = result.is_a?(Array) ? result : [result]
      return nil if entries.empty?
      entries.each { |e| @log << e }
      @pending.concat(entries[1..-1])
      entries.first
    end

    # Step the fight to completion and return :victory, :defeat or (if the party
    # fled via #attempt_escape) :escaped.
    def run
      step until finished? || @rounds > MAX_ROUNDS
      @result ||= alive?(@allies) ? :victory : :defeat
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

    # Forfeit `ally`'s action for the round — it neither attacks nor gains a
    # defend's damage cut — used when a failed escape costs the party its turn.
    # Cleared with the other commands at #end_round.
    def command_skip(ally)
      ally.action = nil; ally.defending = false; ally.command = nil; ally.skip = true
    end

    # Average agility of every battler on `side` (EasyRPG's
    # Game_Party_Base::GetAverageAgility, an int-truncating sum / count), 1 for
    # an empty side (its own `battlers.empty() ? 1 : ...` fallback, so a
    # division downstream never sees a zero party). **A fallen battler still
    # counts**: GetAverageAgility sums over GetBattlers (every member) rather
    # than GetActiveBattlers (the not-dead-or-hidden subset one might reach for
    # here) -- there is no live/dead branch in it at all -- so a fight where two
    # of four party members are already down still divides by four and adds
    # their agility in, not the two survivors'. Each battler's own #effective_agi
    # already folds in any agi-affecting state (GetAgi()'s own AdjustParam),
    # which a death itself does not reset or exclude.
    def avg_agi(side)
      return 1 if side.empty?
      side.reduce(0) { |s, b| s + effective_agi(b) } / side.size
    end

    # The escape chance this fight started with, as a percentage (0..100)
    # (see the class's own `attr_reader` above) -- fixed at construction by
    # #compute_escape_chance and only ever bumped by +10 per failed
    # #attempt_escape from there, ported from EasyRPG's
    # Scene_Battle::InitEscapeChance() / TryEscape(), neither of which touches
    # the agilities again once the fight is under way.
    #
    # EasyRPG's InitEscapeChance: 150 - round(100 * enemyAgi / partyAgi),
    # clamped 0..100, so a nimbler party flees more often and a slower one
    # struggles; an agility-less party falls back to a coin toss (partyAgi is
    # never actually 0 here -- #avg_agi floors at 1 -- so this branch is a
    # defensive guard against a Ruby ZeroDivisionError rather than a case
    # InitEscapeChance itself has to handle). **The ratio is rounded to the
    # nearest percent, not truncated**: InitEscapeChance computes it in
    # `double` and finishes with `Utils::RoundTo<int>` (`std::lrint`, "RPG_RT /
    # Delphi compatible rounding"), unlike this same battle's own #to_hit
    # agility term, which RPG_RT computes in `float` and truncates on its
    # implicit int conversion -- the two nearby agility-ratio formulas round
    # differently in the reference itself, not just here.
    def compute_escape_chance
      pa = avg_agi(@allies)
      ea = avg_agi(@enemies)
      base = pa > 0 ? (100.0 * ea / pa).round : 100
      Game.clamp(150 - base, 0, 100)
    end

    # Attempt to flee the fight. A `preemptive` first strike always succeeds, as
    # does an escape a Force Flee battle page has granted; otherwise a 0..99 roll
    # under #escape_chance wins. Success ends the battle as :escaped (#finished? /
    # #escaped?); a failure raises the next attempt's chance by 10 (per EasyRPG)
    # and returns false, leaving the fight running so the enemies still take
    # their round.
    def attempt_escape(preemptive = false)
      return false if finished?
      if preemptive || @force_flee || @rng.random(100) < escape_chance
        @escaped = true
        @result = :escaped
        true
      else
        @escape_chance = escape_chance + 10
        false
      end
    end

    # `attacker`'s to-hit percentage against `target` for a basic attack: the
    # attacker's base hit rate (weapon / unarmed 90, a "miss" enemy 70), adjusted
    # by the agility ratio — EasyRPG's CalcToHitAgiAdjustment, which simplifies to
    # `100 - (100 - base) * (srcAgi + tgtAgi) / (2 * srcAgi)` — so a nimbler
    # target dodges more. Clamped to 0..100. Only consulted when the fight has
    # accuracy enabled (see #initialize).
    def to_hit(attacker, target)
      base = attacker.hit_rate || 90
      # 必中: a weapon flagged `ignore_evasion` skips the agility term entirely —
      # RPG_RT's `CalcNormalAttackToHit` returns before it applies evasion for
      # such a weapon. The attacker's own statuses still spoil its aim, since
      # what the flag ignores is the *target's* evasion, not the wielder's blind.
      raw =
        if attacker.ignores_evasion
          Game.clamp(base, 0, 100)
        else
          src = effective_agi(attacker)
          src = 1 if src < 1
          tgt = effective_agi(target)
          agi_adjusted = 100 - (100 - base) * (src + tgt) / (2 * src)
          # 物理回避率アップ: a shield/armour/helmet/accessory flagged
          # `raise_evasion` (Actor#physical_evasion_up?) subtracts a further
          # flat 25 from the already agi-adjusted chance, right where
          # EasyRPG's `CalcNormalAttackToHit` applies it -- after the AGI
          # term, and never reached at all by a 必中 attacker (the branch
          # above already returned).
          agi_adjusted -= 25 if target.evasion_up
          Game.clamp(agi_adjusted, 0, 100)
        end
      raw * hit_modifier(attacker) / 100
    end

    # How much the attacker's own statuses cut its accuracy: the **lowest**
    # `reduce_hit_ratio` among the states afflicting it, not the product of them
    # (EasyRPG's `Game_Battler::GetHitChanceModifierFromStates` takes a running
    # `std::min`). 100 means unhindered.
    #
    # Nothing read this field before, which made 盲目 / Blind — a status whose
    # entire purpose is to make its victim miss — a status that did nothing at
    # all. Nine of Nepheshel's 25 states carry a reduced ratio (Blind halves it,
    # the poisons take 15% off) and two of mtf-meido-action's ten do, its Blind
    # cutting accuracy to a fifth.
    def hit_modifier(b)
      m = 100
      (b.states || []).each do |sid|
        r = state_hit_ratio(state_def(sid))
        m = r if r < m
      end
      m
    end

    # A state's `reduce_hit_ratio`, defaulting to 100 (no reduction) for an
    # unknown state or a fixture row without the field. Distinct from
    # #state_field, whose 0 default would read a missing field as "always miss".
    def state_hit_ratio(d)
      return 100 unless d.respond_to?(:reduce_hit_ratio)
      v = d.reduce_hit_ratio
      v.nil? ? 100 : v
    end

    # -- stat-affecting states (halve/double ATK/DEF/SPI/AGI) ----------------
    #
    # A state can carry an `affect_type` (0 halve / 1 double / 2 no change,
    # the schema's own default) alongside four independent flags naming which
    # stat(s) it touches (`affect_attack` / `affect_defense` / `affect_spirit`
    # / `affect_agility`). Ported from EasyRPG's `Game_Battler::AdjustParam`,
    # minus its `mod` term: that is a battle-only ATK/DEF/SPI/AGI offset this
    # runtime has no equivalent of (the closest thing, an attribute-defence
    # shift skill, moves #attr_ranks instead of a raw stat).
    #
    # #deal_attack / #enemy_autodestruct (basic-attack and self-destruct
    # damage), #to_hit / #avg_agi (accuracy and escape chance) and #turn_order
    # all read the adjusted value here. A battle **Skill**'s power formula
    # (`Game::Party#skill_effect` / `#skill_defence_term`) reads it too, but
    # through its own copy of this same logic (`Game::Party#stat_mode` and
    # friends) rather than this one, since a skill's caster/target is
    # sometimes a bare `Game::Actor` with no `Battle` -- and no `@states` --
    # behind it at all (field/menu skill use).

    # :half, :double or :normal for `stat_flag` (:affect_attack and friends)
    # on `b` right now. A battler carrying both a halving and a doubling state
    # for the same stat cancels out to :normal, exactly as AdjustParam's own
    # `dbl != half` guard reads -- so Berserk (double ATK) and Weaken (halve
    # ATK) on the same battler net out to its ordinary attack.
    def stat_mode(b, stat_flag)
      half = false; dbl = false
      (b.states || []).each do |sid|
        d = state_def(sid)
        next unless d && state_flag(d, stat_flag)
        case d.respond_to?(:affect_type) ? d.affect_type : 2
        when 0 then half = true
        when 1 then dbl = true
        end
      end
      return :double if dbl && !half
      return :half if half && !dbl
      :normal
    end

    # `value` halved (floored at 1, matching every other halving path in this
    # class) or doubled per `mode`, unchanged for :normal.
    def adjust_stat(value, mode)
      case mode
      when :double then value * 2
      when :half then [value / 2, 1].max
      else value
      end
    end

    def effective_atk(b); adjust_stat(b.atk, stat_mode(b, :affect_attack)); end
    def effective_def(b); adjust_stat(b.def, stat_mode(b, :affect_defense)); end
    def effective_spi(b); adjust_stat(b.spi, stat_mode(b, :affect_spirit)); end
    def effective_agi(b); adjust_stat(b.agi, stat_mode(b, :affect_agility)); end

    # Queue a single-target Skill for `ally`: cast on `target` (an enemy for an
    # attack skill, an ally / the caster for a recovery skill), spending `cost`
    # SP and applying the signed HP / SP deltas (negative HP = damage, positive =
    # recovery) computed by Game::Party#battle_skill_command. Resolved in agility
    # order by #apply_command when the round runs.
    def command_skill(ally, target, name:, cost:, hp: 0, mp: 0, inflict: nil,
                      chance: 100, variance: 0, attributes: nil, skill_id: nil,
                      absorb: false, attr_shift: nil, attr_ids: nil)
      ally.command = { kind: :skill, target: target, name: name,
                       skill_id: skill_id, absorb: absorb,
                       cost: cost, hp: hp, mp: mp,
                       inflict: inflict || [], chance: chance, variance: variance,
                       attributes: attributes || [],
                       attr_shift: attr_shift, attr_ids: attr_ids || [] }
      ally.action = nil; ally.defending = false
    end

    # Queue an all-target Skill for `ally` (scope 1 all enemies / 4 all allies):
    # `targets` is a list of per-target `{ target:, hp:, mp: }` effects (the same
    # signed HP / SP deltas #command_skill takes, one per target, since attack
    # damage varies with each target's defence). The SP `cost` is spent once when
    # the action resolves; the shared `inflict` / `chance` / `variance` /
    # `attributes` / `attr_shift` / `attr_ids` apply to every target -- unlike
    # damage, which attribute (or none) a skill affects and which way is a
    # property of the skill itself, not of who it lands on. #apply_command
    # produces one log entry per living target, drained one at a time by
    # #step_action.
    def command_skill_all(ally, targets, name:, cost:, inflict: nil, chance: 100,
                          variance: 0, attributes: nil, skill_id: nil,
                          absorb: false, attr_shift: nil, attr_ids: nil)
      ally.command = { kind: :skill, all: true, targets: targets, name: name,
                       skill_id: skill_id, absorb: absorb, cost: cost, inflict: inflict || [], chance: chance,
                       variance: variance, attributes: attributes || [],
                       attr_shift: attr_shift, attr_ids: attr_ids || [] }
      ally.action = nil; ally.defending = false
    end

    # Queue a single-target Item for `ally` on `target`: restore the HP / SP and
    # cure the status conditions from Game::Party#battle_item_command. `item_id`
    # rides along on the log entry so the scene consumes one from the bag when the
    # action lands.
    def command_item(ally, target, item_id:, name:, hp: 0, mp: 0, cured: nil)
      ally.command = { kind: :item, target: target, item_id: item_id,
                       name: name, hp: hp, mp: mp, cured: cured || [] }
      ally.action = nil; ally.defending = false
    end

    # Queue an all-ally Item for `ally` (an item scope 1, the whole party):
    # `targets` is a list of per-member `{ target:, hp:, mp: }` recoveries. The
    # shared `cured` states apply to each. One item is consumed for the volley
    # (only the first produced entry carries `item_id`, so the scene's per-entry
    # bag deduction fires once).
    def command_item_all(ally, targets, item_id:, name:, cured: nil)
      ally.command = { kind: :item, all: true, item_id: item_id, targets: targets,
                       name: name, cured: cured || [] }
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
      @pending = []
      refill_queue
    end

    # Perform the next single action of the round primed by #begin_round and
    # return its log entry, skipping battlers that are dead or (allies) defending.
    # Returns nil once the round's queue is exhausted or the battle is decided —
    # the caller then clears commands with #end_round and either shows the result
    # or asks for the next round. Unlike #step it never starts a new round.
    def step_action
      return @pending.shift unless @pending.empty? # drain a buffered all-target hit
      loop do
        return nil if finished? || @queue.empty?
        b = @queue.shift
        next if b.dead?
        # Afflicted states act at the start of the battler's turn: slip damage
        # (which may knock it out) and, if it cannot act (asleep / paralysed), its
        # turn is skipped.
        can_act = apply_turn_states(b)
        next if b.dead? || !can_act
        entry = record_action(strike(b))
        next unless entry
        return entry
      end
    end

    # Whether the entry #step_action just returned was the last buffered hit
    # of its battler's action (a dual-wield swing or an all-target Skill/Item
    # both queue several) -- true once nothing more of that battler's action
    # remains to drain. The battle screen uses this to know when a *whole
    # battler's turn* has finished, not just one hit of it, since a battle
    # page is checked once per acting battler (see Scene::Map#run_battle_events),
    # not once per hit.
    def pending_empty?; @pending.empty?; end

    # Close a round begun with #begin_round: clear each ally's chosen action (so
    # the next round starts fresh) and settle the result once a side is wiped.
    def end_round
      @allies.each do |a|
        a.action = nil; a.defending = false; a.command = nil; a.skip = false
      end
      @result = alive?(@allies) ? :victory : :defeat if finished? && !@escaped
    end

    # Whether one of `b`'s statuses seals skill row `sk`. RPG2000 gives a state
    # two independent seals, each with a threshold: `restrict_skill` bars any
    # skill whose `physical_rate` reaches `restrict_skill_level`, and
    # `restrict_magic` bars any whose `magical_rate` reaches
    # `restrict_magic_level` (EasyRPG's `Game_Actor::IsSkillUsable`). A threshold
    # of 1, which is what both test beds use, therefore seals everything with any
    # magic in it while leaving a purely physical skill alone.
    #
    # This is what 封印 / Silence are *for*, and nothing consulted either field —
    # Nepheshel seals magic with 恐怖 and 封印, mtf-meido-action with Silence, and
    # all three left the victim casting freely.
    def skill_sealed?(b, sk)
      return false unless sk
      (b.states || []).each do |sid|
        d = state_def(sid)
        next unless d
        return true if state_flag(d, :restrict_skill) &&
                       (sk.physical_rate || 0) >= state_field(d, :restrict_skill_level)
        return true if state_flag(d, :restrict_magic) &&
                       (sk.magical_rate || 0) >= state_field(d, :restrict_magic_level)
      end
      false
    end

    private

    # The state definition for `id` from the lookup, or nil (no lookup / unknown).
    def state_def(id); @states ? @states[id] : nil; end

    # Which side a combatant is on. Only a party member carries the live
    # Game::Actor it was snapshotted from, so that is the test. Recorded on a log
    # entry because a state's message is worded differently for an actor and an
    # enemy, and the entry only carries the target's *name*.
    def ally?(battler)
      battler.respond_to?(:actor) && !battler.actor.nil?
    end

    # A field off a state row, tolerating a fixture that omits it.
    def state_field(d, name); d.respond_to?(name) ? (d.send(name) || 0) : 0; end

    # Apply `b`'s afflicted states at the start of its turn: first roll each state
    # for auto-recovery (once it has held longer than its `hold_turn`, an
    # `auto_release_prob`% roll cures it), then, for the states that remain, slip
    # HP/SP damage (fixed val + a percentage of the max, per EasyRPG's
    # ApplyConditions) and report whether the battler may act (a "do nothing"
    # restriction skips its turn). Returns true if `b` may act.
    def apply_turn_states(b)
      can_act = true
      b.state_turns ||= {}
      (b.states || []).dup.each do |id|
        d = state_def(id)
        next unless d
        b.state_turns[id] = (b.state_turns[id] || 0) + 1
        if recovers_from_state?(b, id, d)
          b.states = b.states - [id]
          b.state_turns.delete(id)
          next
        end
        hp = state_field(d, :hp_change_val) + b.max_hp * state_field(d, :hp_change_max) / 100
        hp = DAMAGE_CAP if hp > DAMAGE_CAP # 999 hard-cap applies to slip damage too
        b.hp -= hp if hp > 0
        if b.max_mp && b.mp
          sp = state_field(d, :sp_change_val) + b.max_mp * state_field(d, :sp_change_max) / 100
          b.mp = [b.mp - sp, 0].max if sp > 0
        end
        can_act = false if state_field(d, :restriction) == RESTRICTION_DO_NOTHING
      end
      can_act
    end

    # Whether `b` shakes off state `id` this turn: only once it has held for more
    # than the state's `hold_turn`, then an `auto_release_prob`% roll (0 = never
    # auto-releases). Grounded on EasyRPG's BattleStateHeal.
    def recovers_from_state?(b, id, d)
      prob = state_field(d, :auto_release_prob)
      return false if prob <= 0
      return false unless b.state_turns[id] > state_field(d, :hold_turn)
      @rng.random(100) < prob
    end

    # Whether `b` counts as out of the fight for win/loss purposes: dead or
    # hidden (#out_of_play?), or locked into a "do nothing" restriction by a
    # state with zero chance of ever shaking itself off. デフォ戦botまとめ:
    # "party wipe" for game-over purposes means every member is both unable
    # to act *and* does not recover naturally, not literally "every member's
    # HP is 0" -- why a fully-Stoned party loses instantly even though nobody
    # was ever damaged. A do-nothing state that *can* still clear itself
    # (Sleep, Paralysis with a nonzero auto_release_prob) does not count: the
    # fight keeps running, the same way #recovers_from_state? would
    # eventually stand that battler back up on its own.
    def incapacitated?(b)
      return true if b.out_of_play?
      (b.states || []).any? do |id|
        d = state_def(id)
        d && state_field(d, :restriction) == RESTRICTION_DO_NOTHING &&
          state_field(d, :auto_release_prob) <= 0
      end
    end

    def alive?(side); side.any? { |b| !incapacitated?(b) }; end

    def refill_queue
      @rounds += 1
      return if @rounds > MAX_ROUNDS
      @queue = turn_order
      # A pre-emptive first strike catches the enemies off guard: they skip the
      # opening round, so only the party acts in round 1.
      @queue = @queue.reject { |b| side_of(b) == :enemy } if @first_strike && @rounds == 1
    end

    # Battlers ordered by agility (highest first) -- except a battler whose
    # round is about to be a basic Attack with a `preemptive` weapon equipped
    # sorts before everyone else (EasyRPG's `CreateExecutionOrder` adding
    # 9999 to such a battler's computed order, which in practice always
    # outruns ordinary agility). Ties between two preemptive battlers still
    # fall back to agility. On an agility tie, an ally always acts before an
    # enemy (whether `Combatant#actor` is set ranks 0 below an unset one's 1,
    # independent of either's magnitude, rather than relying on array
    # position happening to list every ally before every enemy); among tied
    # allies specifically, the
    # **lower actor id** acts first -- not party seat/join order, which can
    # diverge from id order once a member has left and rejoined in a
    # different slot (`Game::Party#add_actor` appends to `@actors` in join
    # order, not id order -- see the "seat order" note on `Party#actors`).
    # An enemy tie has no documented ordering rule, so it keeps its troop
    # (definition) order via `i`, same as before.
    def turn_order
      (@allies + @enemies).reject(&:out_of_play?).each_with_index
                          .sort_by { |b, i| [preemptive_boost?(b) ? 0 : 1, -effective_agi(b),
                                              b.actor ? 0 : 1, b.actor ? b.actor.id : i] }
                          .map { |b, _| b }
    end

    # Whether `b`'s action this round earns the `preemptive` weapon's
    # turn-order jump: only a basic Attack qualifies (a Skill, Item or Defend
    # with the same weapon equipped keeps its ordinary agility slot, matching
    # `CreateExecutionOrder`'s own `Type::Normal` guard). A forced
    # attack-ally restriction (confusion) still counts, since the confused
    # battler is still swinging a basic Attack under the hood; a forced
    # attack-enemy restriction (berserk) does not -- per the site's own
    # デフォ戦botまとめ trivia, berserk specifically drops the weapon's
    # preemptive jump on top of forcing the target. `preemptive` is
    # actor-only (see Combatant), so an enemy never qualifies either way.
    def preemptive_boost?(b)
      return false unless b.preemptive
      r = battler_restriction(b)
      return false if r == RESTRICTION_ATTACK_ENEMY
      return true if r == RESTRICTION_ATTACK_ALLY
      b.command.nil? && !b.defending && !b.skip
    end

    # `b` attacks its target, returning a log entry (or nil when it defends or
    # has no living target). A defending target takes half damage (min 1). An
    # ally with a queued Skill / Item command resolves that instead.
    def strike(b)
      # A battler that forfeited its turn (a failed escape) does nothing.
      return nil if b.skip
      # A "forced action" restriction (berserk / confused) overrides the chosen
      # command / defend with a basic attack on a forced target -- still an
      # ordinary basic Attack under the hood otherwise, so dual-wield's extra
      # swing and 必中's evasion-skip both still apply (デフォ戦botまとめ:
      # forced restrictions "override target selection but still honour
      # 'hits twice'/'ignores evasion'"), via the same #swing an unforced
      # Attack uses rather than a bare #deal_attack.
      r = battler_restriction(b)
      if r == RESTRICTION_ATTACK_ENEMY || r == RESTRICTION_ATTACK_ALLY
        target = restricted_target(b, r)
        return nil unless target
        # Berserk (attack-enemy) forces a single target even with an
        # attack_all weapon in hand; confusion (attack-ally) still spreads
        # one, same as an unforced Attack would (デフォ戦botまとめ: "Berserk
        # additionally collapses an 'attack all' weapon down to a single
        # target").
        return swing_side(b, side_targets(target)) if r == RESTRICTION_ATTACK_ALLY && b.attack_all
        return swing(b, target)
      end
      return apply_command(b) if b.command
      return nil if side_of(b) == :ally && b.defending # defending = no attack
      # An enemy with a 行動パターン chooses from it rather than always swinging.
      if side_of(b) == :enemy
        # A guard raised last turn expires as this one begins (the allies' is
        # cleared by #end_round; an enemy acts on its own schedule).
        b.defending = false
        act = choose_enemy_action(b)
        return perform_enemy_action(b, act) if act
      end
      target = attack_target(b)
      return nil unless target
      return swing_side(b, side_targets(target)) if b.attack_all
      swing(b, target)
    end

    # The living members of `target`'s own side -- what an `attack_all`
    # weapon spreads a basic Attack across (EasyRPG's `Normal::vStart`:
    # "attack all enemies regardless of original targeting", where "enemies"
    # means whichever side the already-resolved single target belongs to, so
    # a forced attack-ally restriction or confusion spreads across the
    # *ally* side instead of the usual one).
    def side_targets(target)
      (side_of(target) == :ally ? @allies : @enemies).reject(&:out_of_play?)
    end

    # attack_all under an ordinary Attack: every target swings (dual-wield
    # included, matching a single-target #swing), flattened into one array of
    # log entries for #record_action to drain one hit at a time.
    def swing_side(b, targets)
      # Not Array(swing(...)) -- Array() on a Hash (an ordinary single swing's
      # log entry) explodes it into [key, value] pairs rather than wrapping
      # it, since Hash is Enumerable. Same guard #record_action already uses.
      targets.flat_map { |t| r = swing(b, t); r.is_a?(Array) ? r : [r] }
    end

    # -- enemy AI (行動パターン) ------------------------------------------------

    # Pick the action `b` takes this turn from its pattern, or nil to fall back
    # to a plain attack (no pattern, or nothing currently valid).
    #
    # Port of EasyRPG's EnemyAi::AlgorithmRatingBased: collect the ratings of the
    # actions whose condition holds, find the highest, then drop every action
    # more than 10 below it (`rating - max + 10`, floored at 0) and pick from
    # what remains at random, weighted by the adjusted rating. So a boss's
    # rating-50 attack and rating-48 spell both stay in the mix, while a
    # rating-40 desperation move is excluded until the moves above it stop being
    # valid — which is how an RPG2000 enemy's behaviour shifts as a fight goes on.
    def choose_enemy_action(b)
      list = b.actions
      return nil if list.nil? || list.empty?
      prios = []
      max_prio = 0
      list.each do |a|
        r = enemy_action_valid?(b, a) ? a.rating : 0
        r = 0 if r < 0
        prios << r
        max_prio = r if r > max_prio
      end
      return nil if max_prio <= 0
      total = 0
      prios = prios.map do |pr|
        v = pr > 0 ? pr - max_prio + 10 : 0
        v = 0 if v < 0
        total += v
        v
      end
      return nil if total <= 0
      which = @rng.random(total)
      chosen = nil
      list.each_with_index do |a, i|
        chosen = a
        which -= prios[i]
        break if which < 0
      end
      chosen
    end

    # Whether action `a`'s condition currently holds for enemy `b`. The condition
    # types and their arithmetic are EasyRPG's EnemyAi::IsActionValid; the ranges
    # are inclusive on both ends.
    def enemy_action_valid?(b, a)
      return false if a.skill? && !enemy_skill_ready?(b, a)
      case a.condition_type
      when EnemyAction::COND_ALWAYS
        true
      when EnemyAction::COND_SWITCH
        @ai ? @ai.switch?(a.switch_id) : false
      when EnemyAction::COND_TURN
        # Same argument order as the battle pages' turn condition: the base is
        # condition_param2 and the multiple condition_param1 (see
        # BattlePage.check_turns, which documents why it reads backwards).
        BattlePage.check_turns(turn, a.condition_param2, a.condition_param1)
      when EnemyAction::COND_ACTORS
        n = @allies.reject(&:out_of_play?).size
        n >= a.condition_param1 && n <= a.condition_param2
      when EnemyAction::COND_HP
        within_percent?(b.hp, b.max_hp, a)
      when EnemyAction::COND_SP
        within_percent?(b.mp, b.max_mp, a)
      when EnemyAction::COND_PARTY_LVL
        return false unless @ai
        lvl = @ai.party_level
        lvl >= a.condition_param1 && lvl <= a.condition_param2
      when EnemyAction::COND_FATIGUE
        f = fatigue
        f >= a.condition_param1 && f <= a.condition_param2
      else
        # An operand this build does not know stays out of the running rather
        # than firing unchecked.
        false
      end
    end

    # Whether `cur` as a percentage of `max` falls inside the action's range.
    def within_percent?(cur, max, a)
      return false if max.nil? || max <= 0
      pct = (cur || 0) * 100 / max
      pct >= a.condition_param1 && pct <= a.condition_param2
    end

    # Whether `b` can actually cast the skill action `a`: the skill exists and it
    # can pay the SP. An enemy that cannot afford its spell falls through to its
    # other actions, the way RPG_RT skips an unusable one.
    def enemy_skill_ready?(b, a)
      return false unless @ai
      sk = @ai.skill(a.skill_id)
      return false unless sk
      return false if skill_sealed?(b, sk) # silenced: this entry cannot fire
      cmd = @ai.skill_command(sk, b, nil)
      return false unless cmd
      cost = cmd[:cost] || 0
      cost <= 0 || (b.mp || 0) >= cost
    end

    # Run the action `b` chose and return its log entry (or entries). Any switch
    # the action flips is applied once it has run.
    def perform_enemy_action(b, act)
      entry = if act.skill?
                enemy_skill_action(b, act)
              elsif act.transform?
                enemy_transform_action(b, act)
              else
                enemy_basic_action(b, act)
              end
      apply_action_switches(act)
      entry
    end

    # An action may switch a game switch on and/or off once it has run — how an
    # enemy's move signals a troop's battle-event pages.
    def apply_action_switches(act)
      return unless @ai
      @ai.set_switch(act.switch_on_id, true) if act.switch_on
      @ai.set_switch(act.switch_off_id, false) if act.switch_off
    end

    # The basic actions (kind 0). Attack and dual attack go through the ordinary
    # attack path (so accuracy, criticals, elements and variance all apply);
    # the rest have no damage of their own and read as a plain note on the log.
    def enemy_basic_action(b, act)
      case act.basic
      when EnemyAction::BASIC_DUAL_ATTACK
        target = attack_target(b)
        return nil unless target
        first = deal_attack(b, target)
        # The second swing only lands if the first did not fell the target.
        return [first] if target.dead?
        [first, deal_attack(b, target)]
      when EnemyAction::BASIC_DEFEND
        b.defending = true
        { attacker: b.name, defend: true }
      when EnemyAction::BASIC_OBSERVE
        { attacker: b.name, observe: true }
      when EnemyAction::BASIC_CHARGE
        # The next attack this enemy lands does double damage (EasyRPG's
        # IsCharged, spent in #deal_attack).
        b.charged = true
        { attacker: b.name, charge: true }
      when EnemyAction::BASIC_AUTODESTRUCT
        enemy_autodestruct(b)
      when EnemyAction::BASIC_ESCAPE
        # The enemy runs: out of play without counting as a kill, exactly as a
        # battle page's Force Flee removes one.
        b.hidden = true
        { attacker: b.name, fled: true }
      when EnemyAction::BASIC_NOTHING
        { attacker: b.name, nothing: true }
      else
        target = attack_target(b)
        target ? deal_attack(b, target) : nil
      end
    end

    # Self-destruction (basic 5): the enemy blows itself up, hitting every living
    # party member for `atk - def/2` (EasyRPG's CalcSelfDestructEffect, floored at
    # 0 and spread by the usual variance), and dies doing it.
    def enemy_autodestruct(b)
      targets = @allies.reject(&:out_of_play?)
      entries = targets.map do |t|
        dmg = effective_atk(b) - effective_def(t) / 2
        dmg = 0 if dmg < 0
        dmg = varied(dmg, NORMAL_ATTACK_VARIANCE) if @variance && dmg > 0
        dmg = [dmg / 2, 1].max if t.defending && dmg > 0
        dmg = DAMAGE_CAP if dmg > DAMAGE_CAP
        t.hp -= dmg
        { attacker: b.name, target: t.name, damage: dmg, critical: false,
          autodestruct: true, target_hp: t.hp < 0 ? 0 : t.hp, defeated: t.dead?,
          target_ally: ally?(t) }
      end
      # The blast kills the caster whether or not it found anyone to hit.
      b.hp = 0
      entries.empty? ? { attacker: b.name, autodestruct: true } : entries
    end

    # A skill action (kind 1): cast through the same command pipeline the party
    # uses, so an enemy's attack spell scales, rolls its accuracy and inflicts its
    # states exactly like a hero's — which is what finally lets an enemy poison or
    # sleep the party. A skill whose scope names the caster's own side heals /
    # buffs a fellow monster instead.
    def enemy_skill_action(b, act)
      sk = @ai && @ai.skill(act.skill_id)
      return enemy_fallback_attack(b) unless sk
      targets = enemy_skill_targets(b, sk)
      return enemy_fallback_attack(b) if targets.empty?
      cmd = @ai.skill_command(sk, b, targets.first)
      return enemy_fallback_attack(b) unless cmd
      b.command = skill_command_hash(sk, cmd, targets.first)
      b.command[:skill_id] = act.skill_id
      if targets.size > 1
        # An all-target skill carries one effect per target, since attack damage
        # is computed against each target's own defence.
        per = targets.map do |t|
          c = @ai.skill_command(sk, b, t)
          c ? { target: t, hp: c[:hp] || 0, mp: c[:mp] || 0 } : nil
        end.compact
        return enemy_fallback_attack(b) if per.empty?
        b.command[:all] = true
        b.command[:targets] = per
        b.command[:target] = nil
      end
      entry = apply_command(b)
      b.command = nil
      entry
    end

    # Wrap the party's cast numbers in the command hash #apply_command consumes.
    def skill_command_hash(sk, cmd, target)
      { kind: :skill, target: target, name: skill_name_of(sk),
        absorb: cmd[:absorb] ? true : false,
        cost: cmd[:cost] || 0, hp: cmd[:hp] || 0, mp: cmd[:mp] || 0,
        inflict: cmd[:inflict] || [], chance: cmd[:chance] || 100,
        variance: cmd[:variance] || 0, attributes: cmd[:attributes] || [] }
    end

    def skill_name_of(sk)
      sk.respond_to?(:name) ? sk.name.to_s : ''
    end

    # Who an enemy's skill hits, read from the caster's side of the field: a
    # scope aimed at "enemies" (0 single / 1 all) means the party, and one aimed
    # at "allies" (2 the caster / 3 single / 4 all) means the troop.
    def enemy_skill_targets(b, sk)
      scope = sk.respond_to?(:scope) ? sk.scope.to_i : 0
      case scope
      when 1 then @allies.reject(&:out_of_play?)
      when 2 then [b]
      when 3
        own = @enemies.reject(&:out_of_play?)
        own.empty? ? [] : [own[@rng.random(own.size)]]
      when 4 then @enemies.reject(&:out_of_play?)
      else
        foes = @allies.reject(&:out_of_play?)
        foes.empty? ? [] : [foes[@rng.random(foes.size)]]
      end
    end

    # A transformation (kind 2): the monster becomes another database enemy,
    # taking on its name, stats and battle graphic (and its action pattern) while
    # keeping its place in the fight. Current HP / SP carry over clamped to the
    # new maxima, matching RPG_RT's Game_Enemy::Transform.
    def enemy_transform_action(b, act)
      into = @ai && @ai.enemy(act.enemy_id)
      return enemy_fallback_attack(b) unless into
      b.name = into.name
      b.atk = into.atk; b.def = into.def; b.agi = into.agi; b.spi = into.spi
      b.max_hp = into.max_hp; b.max_mp = into.max_sp
      b.hp = b.hp > into.max_hp ? into.max_hp : b.hp
      b.mp = (b.mp || 0) > into.max_sp ? into.max_sp : b.mp
      b.crit_chance = Battle.crit_chance_of(into)
      b.attr_ranks = Battle.attr_ranks_of(into)
      b.state_ranks = Battle.state_ranks_of(into)
      b.hit_rate = Battle.hit_rate_of(into)
      b.actions = into.actions
      b.enemy_id = act.enemy_id
      b.battler_name = into.battler_name
      { attacker: b.name, transform: true, target: into.name }
    end

    # A skill / transformation that could not be resolved (no database to hand)
    # degrades to a plain attack rather than costing the enemy its turn.
    def enemy_fallback_attack(b)
      target = attack_target(b)
      target ? deal_attack(b, target) : nil
    end

    # `b` lands a basic attack on `target`: the base damage (scaled by the
    # target's elemental resistance, optionally spread by variance), tripled on a
    # critical hit, then halved (min 1) if the target defends. A target immune to
    # the weapon's element (0% rate) takes no damage. The crit note rides on the
    # log entry.
    # One basic attack, which a 二刀流 weapon makes land **twice** (EasyRPG's
    # `GetNumberOfAttacks`). Returns a single log entry for the ordinary case and
    # an array when the weapon swings again, so the log reads the same as the
    # enemy's own dual-attack action — whose "the second swing only lands if the
    # first did not fell the target" rule this follows too.
    def swing(b, target)
      first = deal_attack(b, target)
      return first if b.strike_count < 2 || target.dead?
      [first, deal_attack(b, target)]
    end

    def deal_attack(b, target)
      # A plain attack's own battle animation -- the attacking actor's current
      # gear (Actor#attack_animation_id), or nil for an enemy (b.actor is nil;
      # see #attack_animation_id's own doc comment for why enemies have none
      # to read) or a bare fixture Combatant with no #actor field at all. The
      # animation plays on a miss too -- the swing itself always happens, only
      # its damage is what a miss zeroes -- so this is computed once and
      # attached to both branches below.
      anim = b.respond_to?(:actor) && b.actor.respond_to?(:attack_animation_id) ? b.actor.attack_animation_id : nil
      # Where it plays: over the targeted enemy's sprite, the same
      # `@enemies.index(target)` lookup #apply_command already attaches to a
      # skill/item entry -- nil when the target is a party member (RPG2000
      # draws no ally sprite; #battle_animation_pixel's screen-centre
      # fallback covers that case exactly as it does for a skill/item).
      target_index = @enemies.index(target)
      # When accuracy is on, roll the attacker's to-hit chance: a miss deals no
      # damage and reads as `missed` on the log entry.
      if @accuracy && !hits?(b, target)
        return { attacker: b.name, target: target.name, damage: 0, missed: true,
                 critical: false, target_hp: target.hp < 0 ? 0 : target.hp,
                 defeated: false, target_ally: ally?(target), attack_animation_id: anim,
                 target_index: target_index }
      end
      dmg = Battle.attack_damage(effective_atk(b), effective_def(target))
      # An elemental weapon scales its damage by the target's resistance before
      # variance / criticals (EasyRPG's ApplyAttributeNormalAttackMultiplier).
      dmg = apply_attr_multiplier(dmg, b.atk_attrs, target)
      dmg = varied(dmg, NORMAL_ATTACK_VARIANCE) if @variance && dmg > 0
      # No critical on a same-side hit (e.g. a confused ally striking an ally) or
      # against a target whose gear prevents criticals, matching EasyRPG.
      crit = critical?(b) && side_of(b) != side_of(target) && !target.prevents_crit
      # A charged-up attack (the enemy's Charge basic action) hits twice as hard,
      # but a critical takes precedence over it — EasyRPG's CalcNormalAttackEffect
      # applies one or the other, never both. The charge is spent either way.
      charged = b.charged ? true : false
      b.charged = false if charged
      if crit
        dmg *= 3
      elsif charged
        dmg *= 2
      end
      # Defending halves the blow, and 強力防御 halves it again — a quarter, not a
      # half (EasyRPG's `AdjustDamageForDefend` applies the second `dmg /= 2`
      # for a battler with strong defence). Seven of Nepheshel's 50 actors have
      # it, including its hero.
      if target.defending && dmg > 0
        dmg = [dmg / 2, 1].max
        dmg = [dmg / 2, 1].max if target.strong_defence
      end
      # RPG_RT's damage popup tops out at three digits -- a crit/charge blow
      # that would compute past it still only ever takes 999.
      dmg = DAMAGE_CAP if dmg > DAMAGE_CAP
      target.hp -= dmg
      woke = target.dead? ? [] : shake_off_states(target)
      entry = { attacker: b.name, target: target.name, damage: dmg, critical: crit,
                charged: charged, target_hp: target.hp < 0 ? 0 : target.hp,
                defeated: target.dead?, target_ally: ally?(target),
                attack_animation_id: anim, target_index: target_index }
      entry[:woke] = woke unless woke.empty?
      entry
    end

    # Statuses a **normal attack** knocks its target out of: each state carrying
    # a `release_by_attack` percentage rolls against it, and a hit that lands
    # wakes the sleeper. Returns the ids removed, so the log can report them.
    #
    # Normal attacks only — EasyRPG calls `BattlePhysicalStateHeal` from
    # `Normal::vExecute` and from nowhere else, so a skill never shakes a status
    # loose — and only when the target lives through the blow. A normal attack is
    # wholly physical (`physical_rate` 100), which reduces EasyRPG's
    # `release_by_damage * physical_rate / 100` to the stored percentage.
    #
    # Without this, "asleep" meant asleep until the state's own timer expired, no
    # matter how hard it was hit: Nepheshel's 睡眠 wakes on 80% of blows and its
    # 混乱 clears on 30%; mtf-meido-action's Sleep is 50% and Provoke / Confuse
    # 25%.
    def shake_off_states(target)
      woke = []
      (target.states || []).dup.each do |sid|
        d = state_def(sid)
        chance = d ? state_field(d, :release_by_attack) : 0
        next unless chance > 0 && @rng.random(100) < chance
        target.states.delete(sid)
        (target.state_turns || {}).delete(sid) if target.state_turns
        woke.push(sid)
      end
      woke
    end

    # Whether `b`'s attack criticals: enabled for the fight, the attacker has a
    # non-zero `crit_chance`, and a 0..9999 roll lands under it. A chance at or
    # above CRIT_SCALE always crits, which is what a weapon carrying 100% means.
    def critical?(b)
      return false unless @criticals
      chance = b.crit_chance
      # Drawn with Rng#scaled, not #random: at CRIT_SCALE a modulus of the
      # generator's prime period over-represents the low values a small
      # threshold tests against, and pays out every crit chance about 7% more
      # often than the number says.
      chance && chance > 0 && @rng.scaled(CRIT_SCALE) < chance
    end

    # Whether `attacker`'s basic attack lands on `target`: a 0..99 roll under the
    # #to_hit chance.
    def hits?(attacker, target)
      @rng.random(100) < to_hit(attacker, target)
    end

    # Spread `base` by a `var` (0-10) amount: an adjustment of `var*base/10` (min
    # 1) is centred on the base with a random offset, floored at 1. Port of
    # EasyRPG's Algo::VarianceAdjustEffect.
    def varied(base, var)
      return base unless var > 0 && base > 0
      adj = var * base / 10
      adj = 1 if adj < 1
      d = base + @rng.random(adj + 1) - adj / 2
      d < 1 ? 1 : d
    end

    # RPG2000's default attribute rate table (liblcf's RPG::Attribute defaults):
    # a defence rank of A..E (index 0..4) scales damage to 300 / 200 / 100 / 50 /
    # 0 percent. Used as the fallback when the fight carries no attribute table
    # (a bare fixture); a real database's per-attribute `a_rate` .. `e_rate`
    # override it (see #attr_rate).
    ATTR_RATE_PCT = [300, 200, 100, 50, 0].freeze

    # The percentage a defence `rank` (0..4) scales damage for attribute `aid`:
    # the attribute's own `a_rate` .. `e_rate` from the database `property` table
    # when known, else the RPG2000 default table.
    def attr_rate(aid, rank)
      row = @attributes ? @attributes[aid] : nil
      if row && row.respond_to?(:a_rate)
        r = [row.a_rate, row.b_rate, row.c_rate, row.d_rate, row.e_rate][rank]
        return r if r
      end
      ATTR_RATE_PCT[rank]
    end

    # Whether attribute `aid` is the database's weapon-type (property field 2,
    # value 0) rather than magic-type (1) -- the same reading
    # Game::Party#attribute_weapon_type? uses (for skill-usability gating),
    # duplicated here since Battle reaches the property table through its own
    # `@attributes` rather than a database reference shared with Party. An id
    # the table doesn't define reads as magic-type, the permissive default
    # #attribute_weapon_type? also falls back to.
    def attribute_physical?(aid)
      row = @attributes ? @attributes[aid] : nil
      row && row.respond_to?(:type) && row.type == 0 ? true : false
    end

    # Scale `dmg` by `attr_ids`'s rate against `target`'s per-attribute
    # defence ranks: EasyRPG's Attribute::ApplyAttributeMultiplier. Each
    # attribute is either weapon-type (physical) or magic-type; the
    # strongest (largest) rate *within* each type is kept, and an attack
    # carrying both types at once multiplies the two rates as two successive
    # percentage scalings of `dmg` -- not an average, and not just the
    # single strongest rate across every attribute regardless of type (a
    # 200%-physical, 50%-magical attack nets 100%, not 200%). Ported
    # truncation-order and all (`magical * (physical * dmg / 100) / 100`)
    # rather than precomputing a combined percentage first, since the two
    # can round differently -- a combined-percentage shortcut
    # ((weapon_best || 100) * (magic_best || 100) / 100, applied by the
    # caller as `dmg * combined / 100`) was tried and dropped in an earlier
    # revision of this method for exactly that reason. Unchanged for an
    # attribute-less attack; a rank the target doesn't list defaults to C
    # (100%). RPG2000 attribute rates never go negative, so EasyRPG's "one
    # side is negative" fallback branch (2003's `attribute.type` add-on)
    # never applies here.
    def apply_attr_multiplier(dmg, attr_ids, target)
      return dmg if attr_ids.nil? || attr_ids.empty?
      ranks = target.attr_ranks || {}
      physical = nil
      magical = nil
      attr_ids.each do |aid|
        rank = ranks[aid] || 2
        rank = 0 if rank < 0
        rank = 4 if rank > 4
        pct = attr_rate(aid, rank)
        if attribute_physical?(aid)
          physical = pct if physical.nil? || pct > physical
        else
          magical = pct if magical.nil? || pct > magical
        end
      end
      if physical && magical
        magical * (physical * dmg / 100) / 100
      elsif physical
        physical * dmg / 100
      elsif magical
        magical * dmg / 100
      else
        dmg
      end
    end

    # The most disruptive "forced action" restriction among `b`'s states (0 = act
    # normally). A "do nothing" state has already skipped the turn upstream, so
    # only the attack-enemy / attack-ally restrictions matter here; the higher
    # value (attack-ally) wins when several are present.
    def battler_restriction(b)
      r = 0
      (b.states || []).each do |id|
        v = state_field(state_def(id), :restriction)
        r = v if v > r && (v == RESTRICTION_ATTACK_ENEMY || v == RESTRICTION_ATTACK_ALLY)
      end
      r
    end

    # A state's boolean field, false for an unknown state or a fixture row that
    # does not model it.
    def state_flag(d, name)
      d.respond_to?(name) ? (d.send(name) ? true : false) : false
    end

    # A random living target for a forced attack: an enemy (attack-enemy) or a
    # member of the battler's own side including itself (attack-ally / confusion).
    def restricted_target(b, r)
      own = side_of(b) == :ally ? @allies : @enemies
      pool = r == RESTRICTION_ATTACK_ALLY ? own : (side_of(b) == :ally ? @enemies : @allies)
      living = pool.reject(&:out_of_play?)
      living.empty? ? nil : living[@rng.random(living.size)]
    end

    # The living target `b` attacks: an ally uses its chosen target while it
    # lives, otherwise a random living foe; enemies always pick a random party
    # member.
    def attack_target(b)
      if side_of(b) == :ally && b.action && !b.action.dead?
        return b.action
      end
      foes = (side_of(b) == :ally ? @enemies : @allies).reject(&:out_of_play?)
      foes.empty? ? nil : foes[@rng.random(foes.size)]
    end

    def side_of(b); @allies.any? { |a| a.equal?(b) } ? :ally : :enemy; end

    # Resolve `b`'s queued Skill / Item command and return its log entry, or nil
    # when the chosen target has already fallen this round (the action fizzles —
    # no SP is spent and nothing animates). A skill first spends the caster's SP;
    # then a negative-HP command (an attack skill) subtracts HP and reads like an
    # attack (`skill:` names it), while a recovery command (heal skill / medicine)
    # restores HP / SP clamped to the target's maxima and reads as a `recover`.
    #
    # This `target.dead?` gate is also what keeps a plain heal from reviving a
    # downed (0 HP) combatant: a fizzled command never reaches #apply_skill_hit
    # at all, so its HP-raising branch never runs against a dead target in the
    # first place -- the in-battle mirror of Game::Actor#change_hp's own
    # `return @hp if dead?` guard on the field. An explicit state-cure (Full
    # Recovery, a revive item/skill) is the only thing modelled here that can
    # stand a combatant back up, and it does so by writing HP directly rather
    # than through this command path.
    def apply_command(b)
      cmd = b.command
      return apply_command_all(b, cmd) if cmd[:all]
      target = cmd[:target]
      return nil if target.nil? || target.dead?
      b.mp = [b.mp - cmd[:cost], 0].max if cmd[:cost] && cmd[:cost] > 0
      apply_skill_hit(b, target, cmd[:hp] || 0, cmd[:mp] || 0, cmd)
    end

    # An all-target Skill (scope 1 all enemies / 4 all allies): spend the SP once,
    # then apply the per-target effect to every living target, returning one log
    # entry per hit (which #step_action surfaces one at a time). Fizzles — nil, no
    # SP spent — when every listed target has already fallen this round. Same
    # per-target `dead?` filter as #apply_command, and for the same reason: a
    # downed member of an all-ally heal is skipped rather than topped up back to
    # life (see #apply_command's comment).
    def apply_command_all(b, cmd)
      live = (cmd[:targets] || []).select { |t| t[:target] && !t[:target].dead? }
      return nil if live.empty?
      b.mp = [b.mp - cmd[:cost], 0].max if cmd[:cost] && cmd[:cost] > 0
      entries = live.map { |t| apply_skill_hit(b, t[:target], t[:hp] || 0, t[:mp] || 0, cmd) }
      # An all-ally item is consumed once for the whole volley: keep item_id on
      # the first hit only, so the scene's per-entry bag deduction fires once.
      entries.each_with_index { |e, i| e[:item_id] = nil unless i.zero? } if cmd[:item_id]
      entries
    end

    # Apply one skill / item effect from `b` to `target`: a negative `hp` is an
    # attack (elemental scaling, variance, then state infliction, reading as a
    # `skill:` hit), a non-negative one restores HP / SP and cures states (reading
    # as a `recover`). Returns the log entry. Shared by single- and all-target
    # commands.
    def apply_skill_hit(b, target, hp, mp, cmd)
      if hp < 0
        dmg = -hp
        # An elemental skill scales its damage by the target's resistance first
        # (EasyRPG's ApplyAttributeSkillMultiplier), then spreads by variance.
        dmg = apply_attr_multiplier(dmg, cmd[:attributes], target)
        # Spread the skill's damage by its own variance when the fight rolls it.
        dmg = varied(dmg, cmd[:variance]) if @variance && dmg > 0 && cmd[:variance] && cmd[:variance] > 0
        # Same 999 hard-cap as a normal attack (#deal_attack), applied before
        # absorption so a drain skill can't smuggle a bigger hit past it either.
        dmg = DAMAGE_CAP if dmg > DAMAGE_CAP
        # 吸収: the caster takes what the target loses, and can take no more than
        # the target has. EasyRPG clamps the effect to the target's current HP
        # *before* applying it ("Only absorb the hp that were left"), so a
        # 200-damage drain on a 30 HP foe deals 30 and returns 30 -- the drain is
        # weaker against a nearly-dead target, not merely capped in what it gives.
        absorbed = 0
        if cmd[:absorb] && dmg > 0
          dmg = target.hp if dmg > target.hp
          absorbed = dmg
        end
        target.hp -= dmg
        b.hp = [b.hp + absorbed, b.max_hp].min if absorbed > 0
        # An attack skill may inflict its states -- and shift attribute
        # defence ranks -- on a surviving target, each rolled/applied only if
        # it lived through the damage.
        if target.dead?
          inflicted = already = shifted = []
        else
          inflicted, already = roll_inflict(target, cmd)
          shifted = apply_attr_shift(target, cmd)
        end
        { attacker: b.name, target: target.name, damage: dmg,
          target_hp: target.hp < 0 ? 0 : target.hp, defeated: target.dead?,
          inflicted: inflicted, already: already, attr_shifted: shifted,
          target_ally: ally?(target), skill: cmd[:name],
          skill_id: cmd[:skill_id], target_index: @enemies.index(target),
          absorbed_hp: absorbed }
      else
        # Spread the recovery by the skill's own variance when the fight rolls
        # it, the same way the attack branch above does: EasyRPG's
        # `Algo::VarianceAdjustEffect` is one function applied to whichever
        # signed effect `CalcSkillEffect` produced, not a damage-only step, so
        # a Cure spell's heal wobbles exactly like a Fire spell's damage does.
        # HP and SP roll independently (`#varied` draws its own random offset
        # each call) since a skill can restore both from the same base effect
        # and RPG_RT does not correlate the two rolls. An item's fixed effect
        # never carries a `variance` (items have no such field), so this is a
        # no-op there; a 0 (or absent) `hp`/`mp` clears #varied's own `base >
        # 0` guard, so a skill that only restores one of the two leaves the
        # other alone.
        if @variance && cmd[:variance] && cmd[:variance] > 0
          hp = varied(hp, cmd[:variance])
          mp = varied(mp, cmd[:variance])
        end
        before_hp = target.hp
        before_mp = target.mp || 0
        hp = RECOVER_CAP if hp > RECOVER_CAP
        target.hp = [target.hp + hp, target.max_hp].min if hp > 0
        target.mp = [before_mp + mp, target.max_mp].min if mp > 0 && target.max_mp
        # Cure the item's status conditions from the target (an antidote / herb),
        # unconditionally, matching the field item cure.
        cured = (cmd[:cured] || []).select { |s| target.state?(s) }
        target.states = (target.states || []) - cured unless cured.empty?
        shifted = target.dead? ? [] : apply_attr_shift(target, cmd)
        { recover: true, actor: b.name, source: cmd[:name],
          item_id: cmd[:item_id], skill_id: cmd[:skill_id], target: target.name,
          target_index: @enemies.index(target),
          recover_hp: target.hp - before_hp, recover_mp: (target.mp || 0) - before_mp,
          cured: cured, target_ally: ally?(target), attr_shifted: shifted,
          target_hp: target.hp, target_mp: target.mp }
      end
    end

    # Shift `target`'s attribute-defence ranks per `cmd[:attr_shift]` (see
    # #skill_attr_shift): one step per landing, capped at +-1 from the rank
    # the battle started with (Combatant#attr_base_ranks) rather than
    # stacking further on repeat casts, and always inside the valid 0..4
    # (A..E) range. Returns the attribute ids actually moved -- an attribute
    # already at its cap, or a skill that doesn't touch attribute defence at
    # all, moves nothing.
    def apply_attr_shift(target, cmd)
      shift = cmd[:attr_shift]
      ids = cmd[:attr_ids]
      return [] unless shift && ids && !ids.empty?
      target.attr_ranks ||= {}
      base = target.attr_base_ranks || {}
      moved = []
      ids.each do |aid|
        b = Game.clamp(base[aid] || 2, 0, 4)
        cur = target.attr_ranks[aid] || b
        nxt = Game.clamp(cur + shift, Game.clamp(b - 1, 0, 4), Game.clamp(b + 1, 0, 4))
        next if nxt == cur
        target.attr_ranks[aid] = nxt
        moved << aid
      end
      moved
    end

    # RPG2000's default state rate table (liblcf's RPG::State defaults): a
    # susceptibility rank of A..E (index 0..4) scales an infliction chance to
    # 100 / 80 / 60 / 30 / 0 percent. Used as the fallback; a state row that
    # carries its own `a_rate` .. `e_rate` (the `situation` table) overrides it.
    STATE_RATE_PCT = [100, 80, 60, 30, 0].freeze

    # The percentage a susceptibility `rank` (0..4) scales an infliction of state
    # `sid`: the state's own `a_rate` .. `e_rate` from the situation table when
    # known, else the RPG2000 default table.
    def state_rate(sid, rank)
      row = state_def(sid)
      if row && row.respond_to?(:a_rate)
        r = [row.a_rate, row.b_rate, row.c_rate, row.d_rate, row.e_rate][rank]
        return r if r
      end
      STATE_RATE_PCT[rank]
    end

    # The percentage a target's susceptibility scales an infliction of `sid`: its
    # rank in the target's `state_ranks` (default C / 60% for a listed-but-absent
    # state, EasyRPG's GetStateProbability). 100 (unscaled) when the target (a
    # bare fixture) models no ranks, so a plain sim keeps landing every status.
    # The Knockout state (id 1, `Game::Actor::DEATH_STATE`) is exempt from rank
    # scaling entirely -- a skill's "state change" effect list can name it
    # directly (RPG2000 has no separate instant-death mechanic), and yado.tk
    # documents its infliction chance as governed solely by the skill's own
    # occurrence-rate operand, never reduced by the target's A-E resistance rank.
    def state_susceptibility(target, sid)
      return 100 if sid == Game::Actor::DEATH_STATE
      ranks = target.state_ranks
      return 100 if ranks.nil? || ranks.empty?
      rank = ranks[sid] || 2
      rank = 0 if rank < 0
      rank = 4 if rank > 4
      state_rate(sid, rank)
    end

    # Inflict a skill command's `inflict` states on `target`, each landing only if
    # a 0..99 roll comes in under the skill's `chance` (its accuracy) scaled by
    # the target's per-state susceptibility.
    #
    # Returns `[inflicted, already]`: the states that landed, and the ones the
    # target was already carrying. The second list is not a list of failures —
    # RPG_RT counts a state the target already has as a **success** and says so
    # ("X is already poisoned!"), *without* rolling the accuracy first
    # (EasyRPG's `AddAffectedState(... AlreadyInflicted)`, which `continue`s
    # before the `PercentChance`). A Poison Sting on a poisoned foe therefore
    # always reports, where a roll would sometimes have gone quiet.
    def roll_inflict(target, cmd)
      chance = cmd[:chance] || 100
      inflicted = []
      already = []
      (cmd[:inflict] || []).each do |sid|
        if target.state?(sid)
          already << sid
          next
        end
        prob = chance * state_susceptibility(target, sid) / 100
        next unless @rng.random(100) < prob
        # RPG_RT's crowding-out rule (Game::States::PRUNE_GAP): the state
        # that just landed may itself immediately push out one already
        # held, or be pushed out by one already held that outranks it.
        target.states = Game::States.prune((target.states || []) + [sid], @states)
        inflicted << sid
      end
      [inflicted, already]
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

  # A boat / ship / airship's saved location. RPG2000 stores one per vehicle in
  # its own `.lsd` chunk (105 boat, 106 ship, 107 airship, each a SAVE_MOVABLE):
  # the map it sits on, its tile position and facing, and its on-map graphic.
  # This is plain data, not a Game::Character -- boarding (Scene::Map#board_vehicle
  # et al.) and a Move Route driving one (Scene::Map#force_vehicle_route) both
  # write straight into it (or a Game::Character mirror that writes back into
  # it) rather than growing it into the Character protocol itself. `map_id` 0
  # means it has never been placed.
  class Vehicle
    TYPES = [:boat, :ship, :airship].freeze

    attr_accessor :map_id, :x, :y, :direction, :charset_name, :charset_index
    attr_reader :type

    def initialize(type, map_id = 0, x = 0, y = 0, direction = 2)
      @type = type
      @map_id = map_id || 0
      @x = x || 0
      @y = y || 0
      @direction = direction || 2
      @charset_name = ''
      @charset_index = 0
    end

    # Whether the vehicle has been placed on a map (0 = never positioned).
    def placed?; @map_id > 0; end

    def to_h
      { map_id: @map_id, x: @x, y: @y, direction: @direction,
        charset_name: @charset_name, charset_index: @charset_index }
    end

    def load_h(h)
      return unless h
      @map_id = h[:map_id] || 0
      @x = h[:x] || 0
      @y = h[:y] || 0
      @direction = h[:direction] || 2
      @charset_name = h[:charset_name] || ''
      @charset_index = h[:charset_index] || 0
    end

    # Populate from a parsed SAVE_MOVABLE chunk (a vehicle location in a `.lsd`).
    def load_movable(m)
      return unless m
      @map_id = m.map_id || 0
      @x = m.x || 0
      @y = m.y || 0
      @direction = m.direction || 2
      @charset_name = m.charset_name || ''
      @charset_index = m.charset_index || 0
    end
  end

  # One of RPG_RT's countdown timers, driven by the Timer Operation command
  # (10230). RPG2000 has a single one; RPG2003 adds a second, selected by that
  # command's sixth parameter. Ported from EasyRPG's Game_Party timer block,
  # which is where the two details this used to get wrong come from:
  #
  # * **Set** seeds `seconds * 60 + 59`, not `seconds * 60`. The display shows
  #   `frames / 60`, so the extra 59 makes a freshly-set timer hold the number it
  #   was given for a whole second before ticking down — seeded exactly, it would
  #   drop a second after a single frame.
  # * **Stop hides it.** `StopTimer` clears the visible flag as well as the
  #   running one, and the countdown reaching zero goes through that same stop —
  #   which is how a timer that runs out disappears rather than sitting at 0:00.
  class Timer
    FPS = 60

    # RPG_RT's timer display never grows past two minute digits, so 99:59
    # (5999 s) is the largest value it can show; a Timer Operation "set"
    # sourced from a Control Variables value (arbitrary, player-reachable —
    # e.g. an accidental or intentional overflowed computation) is clamped to
    # this ceiling rather than wrapping or overflowing the frame counter.
    MAX_SECONDS = 5999

    # Remaining time in frames; whether it is counting; whether it is drawn; and
    # whether it keeps counting (and drawing) during a battle — the Timer
    # Operation start command's second flag.
    attr_accessor :frames, :running, :visible, :in_battle

    def initialize
      @frames = 0
      @running = false
      @visible = false
      @in_battle = false
    end

    # Timer Operation, "set": load the timer with `seconds` (see the note above
    # about the extra 59 frames). Clamped to MAX_SECONDS (99:59) since this can
    # be fed an out-of-range Variable value via Control Variables.
    def set(seconds)
      seconds = MAX_SECONDS if seconds > MAX_SECONDS
      @frames = seconds * FPS + (FPS - 1)
    end

    # Timer Operation, "start": begin counting, drawn or not, and in battle or
    # not.
    def start(visible, in_battle = false)
      @running = true
      @visible = visible
      @in_battle = in_battle
    end

    # Timer Operation, "stop" — and where a finished countdown ends up.
    def stop
      @running = false
      @visible = false
    end

    # Advance one frame, `battle` telling it whether a fight is running. Returns
    # true on the frame the countdown reaches zero (RPG_RT counts that as the
    # displayed seconds hitting 0, not the frame counter, so the last 59 frames
    # of 0:00 never show).
    def tick(battle = false)
      return false unless @running && @frames > 0
      return false if battle && !@in_battle
      @frames -= 1
      return false if seconds > 0
      stop
      true
    end

    # Remaining whole seconds — what every read of the timer reports.
    def seconds; @frames / FPS; end

    # Whether the timer should be drawn right now; a timer without the battle
    # flag is hidden for the duration of a fight rather than stopped.
    def drawn?(battle = false)
      @visible && (!battle || @in_battle)
    end

    # The timer as RPG2000 draws it: whole minutes, a colon, then zero-padded
    # seconds (e.g. 90 s -> "1:30"). Minutes are not capped at two digits. The
    # seconds are padded by hand: this mruby build bundles no sprintf.
    def display_text
      s = seconds
      secs = s % 60
      "#{s / 60}:#{secs < 10 ? "0#{secs}" : secs}"
    end

    def to_h
      { frames: @frames, running: @running, visible: @visible,
        in_battle: @in_battle }
    end

    def load_h(h)
      return unless h
      @frames = h[:frames] || 0
      @running = h[:running] || false
      @visible = h[:visible] || false
      @in_battle = h[:in_battle] || false
    end
  end

  class State
    # RPG2000's Show Picture editor field only offers picture numbers 1-50 (a
    # fixed-size internal slot array); an id outside that range is not a real
    # picture and Show Picture on one is a no-op (yado.tk).
    MAX_PICTURE_ID = 50

    attr_reader :party, :switches, :variables, :message_config, :screen, :weather
    attr_accessor :map, :map_id, :x, :y, :direction
    # Whether the player may open the main menu / save, toggled by the Change
    # Main Menu Access (11960) and Change Save Access (11930) event commands;
    # both default on and are persisted in the save.
    attr_accessor :menu_access, :save_access
    # Whether the Teleport and Escape skills are usable. Toggled directly by
    # the Change Teleport Access (11820) and Change Escape Access (11840)
    # event commands, but also recomputed from the current map's own tree
    # setting on every map load and Teleport (`Scene::Map#apply_map_access`,
    # `Game::MapAccess.teleport_allowed?` / `#escape_allowed?`) -- so a value
    # set here is only the *initial* one (before any map has loaded), matching
    # `#save_access`. Persisted in the save. Read by
    # Game::Party#escape_skill_available? / #teleport_skill_available? to gate
    # the field skill menu.
    attr_accessor :teleport_access, :escape_access
    # A `{map_id:, x:, y:}` destination queued by an Escape / Teleport field
    # skill (see Game::Party#cast_escape_skill / #cast_teleport_skill), picked up
    # and cleared by Scene::Map#update on the next frame it runs. The menu
    # scenes that cast these skills are not the map scene and have none of its
    # map-load machinery, so — like the interpreter's own Teleport command — the
    # actual jump happens back in Scene::Map, just queued from a different
    # source. Transient: never persisted, since nothing can be mid-menu at a
    # save (Save is a main-menu command, one level up from the skill screen).
    attr_accessor :pending_teleport
    # The BGM currently playing and the one stashed by Memorize BGM (11530),
    # each nil or a `{ name:, volume:, tempo: }` hash. Play Memorized BGM (11540)
    # restores the stash. Persisted in the save so the memory survives a reload.
    attr_accessor :current_bgm, :memorized_bgm
    # Whether the current BGM has wrapped back to its start at least once — the
    # "BGM played once" conditional-branch test (12010 type 9). Cleared whenever
    # a new BGM starts; set by Scene::Map, which watches `RGSS::Audio.bgm_pos`
    # and treats a playback position that jumped backwards as a loop.
    attr_accessor :bgm_looped
    # Whether the party leader's map sprite is hidden, toggled by the Set
    # Transparent Flag / Change Player Visibility (11310) event command. Defaults
    # off (the hero is shown) and is persisted in the save.
    attr_accessor :player_transparent
    # Random-encounter step rate set by Change Encounter Rate (11740); nil until
    # a command overrides it (the map's own rate then applies).
    attr_accessor :encounter_rate
    # The wandering-monster accumulator Scene::Map's #check_random_encounter
    # builds up each step (EasyRPG's Game_Player::total_encounter_rate) —
    # persisted so a save mid-walk does not quietly reroll the chance of the
    # next few steps. The table index that reads it (EasyRPG's
    # last_encounter_idx) is deliberately *not* persisted, matching EasyRPG:
    # it is a plain runtime counter, not part of the save.
    attr_accessor :encounter_total
    # How many tiles the party has walked. RPG2000 divides this into each
    # status condition's own step interval to decide when a field ailment slips
    # HP / SP (see Party#apply_map_step_damage), which is the only thing reading
    # it so far -- the encounter system that would share it is not built. It
    # persists in the Marshal save; the `.lsd` keeps its step counter in the
    # inventory chunk (109), whose step / turn fields are deliberately still
    # undecoded (see LCF::Schema::SAVE_INVENTORY), so a resumed real save starts
    # its count from 0.
    attr_accessor :steps
    # Running tallies RPG2000 keeps and exposes through the Control Variables
    # "Other" operand: how many times the game was saved, and how many battles
    # were fought / won / lost / escaped. All persist in the save.
    attr_accessor :save_count, :battle_count, :win_count, :defeat_count,
                  :escape_count
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
    # Screen-transition styles set by Change Screen Transitions (10690): six
    # slots, in save order — 0 teleport-erase, 1 teleport-show, 2 battle-start-
    # erase, 3 battle-start-show, 4 battle-end-erase, 5 battle-end-show — each a
    # style id. Modelled for save fidelity (they round-trip through the save,
    # LSD chunks 111–116); the teleport / battle fades that would read them still
    # use their own transition, so nothing consumes these at runtime yet.
    attr_accessor :screen_transitions
    # The system windowskin graphic (System/<name>) and font id set by Change
    # System Graphics (10680), overriding the database defaults. `system_graphic`
    # is nil until a command sets it (the database's own graphic then applies)
    # and `font_id` defaults to 0. Both persist in the save (LSD SAVE_SYSTEM
    # chunks 15 / 17); Scene::Map reloads the windowskin when the override
    # changes.
    attr_accessor :system_graphic, :font_id
    # Last known-good resume position of each running Common Event Parallel
    # Process, id => a command-list index (see Game::Interpreter
    # #resumable_index). Unlike a Map Event's parallel process (which always
    # restarts fresh on every re-trigger, per visit -- deliberately untouched
    # here), a Common Event's own parallel-process position survives a map
    # transfer *and* a save/load, so this is what a fresh Scene::Map (built by
    # Continue, or after Return to Title -> New Game -> Continue) reads to
    # resume it instead of starting at the top -- see Scene::Map#new_parallel.
    # An ordinary Transfer Player, by contrast, does not go through this at
    # all: Scene::Map#build_parallels keeps the live Game::Interpreter object
    # across it, which preserves full fidelity (call stack, in-flight wait
    # timer, everything), not just this coarser checkpoint. Persisted in the
    # portable Marshal save; not yet in `.lsd` (chunks 113/114 are still
    # opaque, see LCF::Schema::SAVE_FOREGROUND_EVENT / SAVE_COMMON_EVENT).
    attr_accessor :common_event_progress

    def initialize(party, map_id, x, y)
      @party = party
      @map_id = map_id
      @x = x
      @y = y
      @direction = 2
      @map = nil
      @pending_teleport = nil
      @switches = Switches.new
      @variables = Variables.new
      @timers = [Timer.new, Timer.new]
      @message_config = MessageConfig.new
      @menu_access = true
      @save_access = true
      @teleport_access = false
      @escape_access = false
      @current_bgm = nil
      @memorized_bgm = nil
      @bgm_looped = false
      @player_transparent = false
      @encounter_rate = nil
      @encounter_total = 0
      @steps = 0
      @save_count = 0
      @battle_count = 0
      @win_count = 0
      @defeat_count = 0
      @escape_count = 0
      @teleport_targets = {}
      @escape_target = nil
      @common_event_progress = {}
      @system_bgm = {}
      @system_sfx = {}
      # nil = "not configured yet"; #seed_screen_transitions fills each slot in
      # from the database when the game starts.
      @screen_transitions = Array.new(SCREEN_TRANSITION_SLOTS, nil)
      @system_graphic = nil
      @font_id = 0
      @weather = Weather.new
      # The three vehicles' saved locations (boat / ship / airship), persisted in
      # `.lsd` chunks 105-107. Unplaced until a save restores them.
      @vehicles = { boat: Vehicle.new(:boat), ship: Vehicle.new(:ship),
                    airship: Vehicle.new(:airship) }
      @boarded = nil
      # Transient screen-effect state (tint transition); not serialised, so a
      # reloaded game starts with a neutral screen.
      @screen = Screen.new
      # Shown pictures, id => Game::Picture. Transient like @screen (RPG2000's
      # HUD pictures are re-shown by parallel events on load), so not serialised.
      @pictures = {}
      # Runtime parallax override from a Change Parallax Background command (nil =
      # use the map's own panorama). Transient like @pictures: RPG2000 resets it
      # to the map's default on every map change, so it is not serialised.
      @parallax = nil
    end

    # The Change Parallax Background override (a hash of name / loop / autoscroll
    # settings), or nil when the map's own panorama applies.
    attr_reader :parallax

    # Change Parallax Background: override the current map's panorama. `opts`
    # carries :name, :loop_x, :loop_y, :auto_x, :sx, :auto_y, :sy (see the
    # interpreter). An empty name leaves the backdrop blank. Scene::Map rebuilds
    # its parallax sprite from this override.
    def set_parallax(opts)
      @parallax = opts
    end

    # Drop any parallax override so the map's own panorama applies again. Called
    # on a map change, alongside erase_all_pictures.
    def clear_parallax; @parallax = nil; end

    attr_reader :pictures, :vehicles
    # The vehicle the party is currently riding (:boat / :ship / :airship), or
    # nil when on foot. Set by boarding on the map and persisted in the save.
    attr_accessor :boarded

    # The saved location of vehicle `type` (:boat / :ship / :airship), or nil.
    def vehicle(type); @vehicles[type]; end

    # Whether the party is aboard a vehicle.
    def boarded?; !@boarded.nil?; end

    # Record one walked tile and return the new step count. Called by Scene::Map
    # whenever the party lands on a new tile under its own movement -- a step the
    # player took, or one a forced move route made it take. A teleport is not a
    # step: the party arrives without walking, so RPG_RT does not count it and
    # neither does this.
    def walk_step; @steps += 1; end

    # Show (or replace) picture `id` with the given Picture options hash. An id
    # outside 1..MAX_PICTURE_ID does nothing -- #move_picture/#erase_picture
    # need no matching guard of their own, since neither can ever find such an
    # id shown in the first place.
    def show_picture(id, opts)
      @pictures[id] = Picture.new(id, opts) if id && id > 0 && id <= MAX_PICTURE_ID
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

    # Advance both countdown timers one frame (call once per frame), `battle`
    # telling them whether a fight is running. Returns true when either reached
    # zero on this frame.
    def tick_timer(battle = false)
      finished = false
      @timers.each { |t| finished = true if t.tick(battle) }
      finished
    end

    # The Game::Timer for slot `id` — 0 the RPG2000 timer, 1 the second one
    # RPG2003 adds. Any other id falls back to the first, so malformed data can
    # never address a timer that does not exist.
    def timer(id = 0)
      @timers[id] || @timers[0]
    end

    # -- single-timer shorthands ---------------------------------------------
    #
    # Everything written before the second timer existed talks to the first one,
    # so these keep reading and writing it by name.
    def timer_seconds; timer(0).seconds; end
    def timer_display_text; timer(0).display_text; end
    def timer_frames; timer(0).frames; end
    def timer_frames=(v); timer(0).frames = v; end
    def timer_running; timer(0).running; end
    def timer_running=(v); timer(0).running = v; end
    def timer_visible; timer(0).visible; end
    def timer_visible=(v); timer(0).visible = v; end

    # The six Change Screen Transitions (10690) slots (see #screen_transitions).
    SCREEN_TRANSITION_SLOTS = 6

    # The database System fields (chunks 61-66) backing those slots, in slot
    # order: teleport erase / show, battle start erase / show, battle end erase /
    # show. RPG_RT reads the database setting whenever the in-game slot has not
    # been overridden, so the two lists have to line up.
    DB_TRANSITION_FIELDS = [:transition_out, :transition_in,
                            :battle_start_fadeout, :battle_start_fadein,
                            :battle_end_fadeout, :battle_end_fadein].freeze

    # Change Screen Transitions: set slot `which` (0..5) to transition setting
    # `style`. An out-of-range slot is ignored.
    def set_screen_transition(which, style)
      return unless which >= 0 && which < SCREEN_TRANSITION_SLOTS
      @screen_transitions[which] = style
    end

    # Fill any transition slot that does not hold a real setting index from the
    # database's own System settings. Called when a game starts and after a save
    # is restored, so an Erase / Show Screen's "use the configured transition"
    # (-1) always has something to resolve against.
    #
    # A slot can arrive unset two ways: a fresh game has never had one, and a
    # genuine `.lsd` stores a not-overridden slot as a marker rather than a
    # setting (RPG_RT writes -1 when the value still matches the database, which
    # the chunk's unsigned byte reads back out of range). Both mean the same
    # thing — ask the database — so both are refilled here.
    def seed_screen_transitions(db)
      sys = db && db.respond_to?(:system) ? db.system : nil
      DB_TRANSITION_FIELDS.each_with_index do |field, i|
        next if Game::Transition.setting?(@screen_transitions[i])
        v = sys && sys.respond_to?(field) ? sys.send(field) : nil
        @screen_transitions[i] = Game::Transition.setting?(v) ? v : 0
      end
    rescue StandardError => e
      # A database without the fields is not fatal — every slot then falls back
      # to setting 0, the plain fade — but it should not pass unnoticed.
      $stderr.puts "[RPG2k] screen transition defaults unreadable: #{e.message}"
    end

    # Place each vehicle at the map tree's own boat/ship/airship starting
    # position — the editor's dedicated "set starting position" tool for each
    # vehicle (the map tree's `initial` chunk, fields 11-13/21-23/31-33),
    # RPG_RT's counterpart to the hero's own initial_map_id/x/y a few lines up
    # in `RPG2k#start_new_game`, which is the only caller: a vehicle's saved
    # position already carries this (or a later Set Vehicle Location's)
    # placement through `Vehicle#to_h`/`#load_h`/`#load_movable`, so Continue
    # does not call this and cannot clobber it. A vehicle the tree never
    # positions keeps `Vehicle.new`'s own unplaced default (map_id 0).
    def seed_vehicle_positions(map_tree)
      init = map_tree && map_tree.respond_to?(:initial) ? map_tree.initial : nil
      return unless init
      Vehicle::TYPES.each do |type|
        next unless init.respond_to?("#{type}_map_id")
        v = @vehicles[type]
        v.map_id = init.send("#{type}_map_id") || 0
        v.x = init.send("#{type}_x") || 0
        v.y = init.send("#{type}_y") || 0
      end
    rescue StandardError => e
      # A tree without the fields is not fatal — every vehicle then stays
      # unplaced, same as before this method existed — but it should not pass
      # unnoticed.
      $stderr.puts "[RPG2k] vehicle start positions unreadable: #{e.message}"
    end

    # Change System Graphics: override the windowskin graphic (System/<name>) and
    # font id. Scene::Map reloads the windowskin so windows created afterwards use
    # the new skin.
    def set_system_graphic(name, font)
      @system_graphic = name
      @font_id = font || 0
    end

    # Serialise to a plain hash of primitives (Marshal-friendly) for saving. The
    # map itself is not stored; it is reloaded from map_id on load.
    def to_h
      { map_id: @map_id, x: @x, y: @y, direction: @direction,
        switches: @switches.to_h, variables: @variables.to_h,
        party: @party.to_h,
        # Both timers, plus the first one's fields under their old names so a
        # save this build writes still loads in one that predates the second
        # timer.
        timers: @timers.map { |t| t.to_h },
        timer_frames: timer_frames,
        timer_running: timer_running, timer_visible: timer_visible,
        message_config: @message_config.to_h,
        menu_access: @menu_access, save_access: @save_access,
        current_bgm: @current_bgm, memorized_bgm: @memorized_bgm,
        player_transparent: @player_transparent, weather: @weather.to_h,
        teleport_access: @teleport_access, escape_access: @escape_access,
        encounter_rate: @encounter_rate, encounter_total: @encounter_total,
        teleport_targets: @teleport_targets,
        common_event_progress: @common_event_progress,
        steps: @steps,
        save_count: @save_count, battle_count: @battle_count,
        win_count: @win_count, defeat_count: @defeat_count,
        escape_count: @escape_count,
        escape_target: @escape_target, system_bgm: @system_bgm,
        system_sfx: @system_sfx, screen_transitions: @screen_transitions,
        system_graphic: @system_graphic, font_id: @font_id,
        vehicles: { boat: @vehicles[:boat].to_h, ship: @vehicles[:ship].to_h,
                    airship: @vehicles[:airship].to_h }, boarded: @boarded }
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
    # Both Timer Operation countdowns and every roster member's Change Actor
    # Name override round-trip now too (see LCF::Schema::SAVE_INVENTORY's
    # timer1_*/timer2_* fields and SAVE_PARTY_ACTOR's actor_name), so this is
    # a near-parity export; Change Actor Title still is not (see docs/TODO.md).
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

      # Vehicle locations (105 boat / 106 ship / 107 airship). Only a placed
      # vehicle is written, so a game that never positioned one leaves the chunk
      # absent, exactly as RPG_RT does.
      { 105 => :boat, 106 => :ship, 107 => :airship }.each do |chunk, type|
        v = @vehicles[type]
        next unless v.placed?
        mv = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
        mv[11] = v.map_id
        mv[12] = v.x
        mv[13] = v.y
        mv[22] = v.direction
        mv[73] = v.charset_name || ''
        mv[75] = v.charset_index || 0
        save[chunk] = mv
      end

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
      # Screen-transition slots 0..5 map to chunks 111..116 in order.
      @screen_transitions.each_with_index { |style, i| sys[111 + i] = style || 0 }
      # System windowskin / font override (Change System Graphics).
      sys[15] = @system_graphic if @system_graphic
      sys[17] = @font_id
      sys[131] = save_count
      sys[132] = 1
      save[101] = sys

      # Chunk 108 is the whole roster, one entry per actor the party has ever
      # held — that is what a genuine RPG_RT save carries, and it is what lets an
      # actor who is currently out of the party come back as they left.
      actors = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_PARTY_ACTOR })
      @party.roster.each do |a|
        e = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_PARTY_ACTOR })
        # Field 1 carries the actor's *current* name (renamed or not, matching
        # a genuine save), so a Change Actor Name override on any roster
        # member -- not just the leader, who also gets it via chunk 100's
        # title -- survives Save/Continue.
        e[1] = a.name
        e[31] = a.level
        e[32] = a.exp
        e[51] = a.skills.size
        e[52] = a.skills
        e[61] = a.equipment
        e[71] = a.hp
        e[72] = a.mp
        unless a.states.empty?
          e[81] = a.states.size
          e[82] = a.states
        end
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
      t1, t2 = @timers[0], @timers[1]
      inv[23] = t1.frames
      inv[24] = t1.running
      inv[25] = t1.visible
      inv[26] = t1.in_battle
      inv[27] = t2.frames
      inv[28] = t2.running
      inv[29] = t2.visible
      inv[30] = t2.in_battle
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
      member_ids = inv.party || []
      party = Party.new(db, member_ids)
      items = {}
      ids = inv.item_ids || []
      counts = inv.item_counts || []
      ids.each_index { |i| items[ids[i]] = counts[i] || 0 }
      # Per-actor state comes from the SAVE_PARTY_ACTOR table (chunk 108), keyed
      # by actor id. Restore each actor's saved level (which rescales its base
      # stats) and exp first, then its current HP/SP, so Continue resumes a
      # levelled, wounded party rather than a fresh full-health one.
      #
      # Every entry is restored, not only the current members: the chunk is the
      # roster (one row per actor the party has ever held), so an actor waiting
      # out of the party is rebuilt here and rejoins as they left. Reading them
      # through the roster is what enrols them.
      hp = {}
      mp = {}
      (save[108] || []).each do |aid, sa|
        actor = party.roster[aid]
        if actor
          actor.set_level(sa.level) if sa.level
          actor.exp = sa.exp if sa.exp
          actor.equip(sa.equipment) if sa.equipment
          actor.skills = sa.skills if sa.skills
          actor.states = sa.states if sa.states
          # A Change Actor Name override on *any* roster member, not just the
          # leader (whose name chunk 100's title also carries below).
          actor.name = sa.actor_name if sa.actor_name && !sa.actor_name.empty?
        end
        hp[aid] = sa.hp if sa.hp
        mp[aid] = sa.mp if sa.mp
      end
      party.load_state(items: items, gold: inv.gold, hp: hp, mp: mp)
      state = new(party, hero.map_id, hero.x, hero.y)
      state.direction = hero.direction || 2
      # Vehicle locations (chunks 105 boat / 106 ship / 107 airship), each a
      # SAVE_MOVABLE; an absent chunk leaves that vehicle unplaced.
      state.vehicle(:boat).load_movable(save.boat)
      state.vehicle(:ship).load_movable(save.ship)
      state.vehicle(:airship).load_movable(save.airship)
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
      # How many times the menu's Save command has been used (RPG_RT increments
      # this on every save; see #to_lsd's sys[131] write above).
      state.save_count = sys.save_count unless sys.save_count.nil?
      # Screen-transition slots (chunks 111..116). A slot the save left
      # un-overridden comes back out of range rather than as a setting, and
      # #seed_screen_transitions refills those from the database below.
      state.screen_transitions = [
        sys.teleport_erase_transition, sys.teleport_show_transition,
        sys.battle_start_erase_transition, sys.battle_start_show_transition,
        sys.battle_end_erase_transition, sys.battle_end_show_transition
      ]
      state.seed_screen_transitions(db)
      # System windowskin / font override; an empty graphic means "use the
      # database default" (left unset).
      sg = sys.system_graphic
      state.system_graphic = sg unless sg.nil? || sg.empty?
      state.font_id = sys.font || 0
      # The leader's display name from the file-screen title chunk. Redundant
      # with chunk 108 field 1 above (both hold the same live name in a
      # genuine save, and in our own #to_lsd output) but applied last so it
      # still wins for a foreign save that sets one and not the other.
      title = save[100]
      if title && party.leader
        nm = title.hero_name
        party.leader.name = nm if nm && !nm.empty?
      end
      restore_pictures(state, save[103])
      # Both Timer Operation countdowns (inventory chunk 109 fields 23-30); a
      # save written before this landed simply omits them, leaving the fresh
      # `Timer.new` defaults #initialize already seeded in place.
      state.timer(0).frames = inv.timer1_frames unless inv.timer1_frames.nil?
      state.timer(0).running = inv.timer1_active unless inv.timer1_active.nil?
      state.timer(0).visible = inv.timer1_visible unless inv.timer1_visible.nil?
      state.timer(0).in_battle = inv.timer1_battle unless inv.timer1_battle.nil?
      state.timer(1).frames = inv.timer2_frames unless inv.timer2_frames.nil?
      state.timer(1).running = inv.timer2_active unless inv.timer2_active.nil?
      state.timer(1).visible = inv.timer2_visible unless inv.timer2_visible.nil?
      state.timer(1).in_battle = inv.timer2_battle unless inv.timer2_battle.nil?
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
      # A save written since the second timer landed carries both; an older one
      # only has the first timer's three fields.
      if h[:timers]
        h[:timers].each_with_index { |th, i| state.timer(i).load_h(th) }
      else
        state.timer_frames = h[:timer_frames] || 0
        state.timer_running = h[:timer_running] || false
        state.timer_visible = h[:timer_visible] || false
      end
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
      state.encounter_total = h[:encounter_total] || 0
      state.steps = h[:steps] || 0
      state.save_count = h[:save_count] || 0
      state.battle_count = h[:battle_count] || 0
      state.win_count = h[:win_count] || 0
      state.defeat_count = h[:defeat_count] || 0
      state.escape_count = h[:escape_count] || 0
      state.teleport_targets = h[:teleport_targets] || {}
      state.common_event_progress = h[:common_event_progress] || {}
      state.escape_target = h[:escape_target]
      state.system_bgm = h[:system_bgm] || {}
      state.system_sfx = h[:system_sfx] || {}
      # A save written before screen transitions existed restores all-default,
      # which the seeding below then fills in from the database.
      stx = h[:screen_transitions]
      if stx && stx.length == SCREEN_TRANSITION_SLOTS
        state.screen_transitions = stx.dup
      end
      state.seed_screen_transitions(db)
      state.system_graphic = h[:system_graphic]
      state.font_id = h[:font_id] || 0
      if (v = h[:vehicles])
        state.vehicle(:boat).load_h(v[:boat])
        state.vehicle(:ship).load_h(v[:ship])
        state.vehicle(:airship).load_h(v[:airship])
      end
      state.boarded = h[:boarded]
      state
    end
  end
end
