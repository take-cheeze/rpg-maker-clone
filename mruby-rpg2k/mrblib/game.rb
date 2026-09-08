# In-memory game state built from the parsed LCF database and map data.
#
# These classes deliberately hold only plain data derived from LCF::Database /
# LCF::MapUnit; nothing here touches RGSS or draws to the screen. That keeps the
# "New Game" logic (building a party and locating the start map) independent of
# the not-yet-implemented map renderer, and unit-testable on its own.
module Game
  TILE = 16 # tile size in pixels
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
    # (ported from a reference implementation, not independently confirmed
    # against genuine RPG_RT under wine). On the standard 32px frame that is
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
  # changes colour and `\s[n]` changes the typewriter speed (1..20, ported from
  # a reference implementation's clamp of the raw value to that range,
  # NOT independently confirmed against genuine RPG_RT under wine). The pacing
  # codes `\.`/`\|`/`\!` (waits), `\^` (auto-close), `\>`/`\<`
  # (instant span), `\$` (show the gold window) and `\s[n]` (speed change) are
  # surfaced by #scan for the scene to act on.
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
    # backslash and `\_` a space; the pacing / display codes (`\s[n]` speed,
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
    #   :speeds  — [{ at:, speed: }] for `\s[n]` speed changes, `speed` clamped
    #              to RPG_RT's 1..20 (1 = full speed, the default before the
    #              first one) and in effect from `at` until the next entry;
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
      speeds = []
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
          case code
          when 'v', 'V'
            if text[i] == '['
              val, i = parse_bracket_value(text, i, variables)
              s = variables[val].to_s
              cur << s
              count += s.length
            end
          when 'n', 'N'
            if text[i] == '['
              val, i, got_number = parse_bracket_value(text, i, variables)
              # `\N[]`'s id-0-means-party-leader convenience
              # (`Scene::Map#actor_name`) only applies when a digit or a
              # resolvable nested `\V[]` was actually read inside the
              # brackets -- gated on "a digit or resolvable nested `\V[]`
              # was read" (`got_number`), not on the value alone. A bracket
              # that parsed nothing at all (a bare `\N[]`, or `\N[x]` where
              # `x` is neither a digit nor `\V[]`/`\v[]`) leaves the id at 0,
              # which is not a valid 1-based actor id. `-1` here is simply a
              # value #actor_name's own `id.to_i.zero?` leader check will
              # never match, so an unresolved bracket falls through to its
              # own dangling-id blank-string path unchanged. This whole
              # gating design was ported from a reference implementation and
              # is NOT independently confirmed against genuine RPG_RT under
              # wine.
              s = (names[got_number ? val : -1] || '').to_s
              cur << s
              count += s.length
            end
          when "\\"     then cur << "\\"; count += 1
          when '_'      then cur << ' '; count += 1 # half-width space
          when 'c', 'C' # colour change: close the current run, switch colour
            segs << { text: cur, color: color } unless cur.empty?
            cur = ''
            # An out-of-range index (>19, the highest real palette colour)
            # resets to colour 0 rather than staying out of range (believed
            # to apply to every ordinary RPG2000/2003 game, ported from a
            # reference implementation and NOT independently confirmed
            # against genuine RPG_RT under wine). Left unclamped, an out-of-range
            # colour used to fail the renderer's own 0..19 validity check and
            # fall back to a flat approximation colour instead of the
            # windowskin's own (properly shaded) swatch 0 -- see
            # Scene::Map::MessagePalette.valid?/#message_color.
            # `#parse_bracket_value` (not a bare `arg.to_i`) so a
            # variable-driven `\C[\V[n]]` resolves the same way `\N[]`/`\V[]`
            # already do -- not special-cased. No bracket at all resets to 0
            # too (`\C` alone), matching the pre-existing default.
            if text[i] == '['
              v, i = parse_bracket_value(text, i, variables)
              color = v > 19 ? 0 : v
            else
              color = 0
            end
          when 's', 'S' # speed change: how fast the typewriter reveals from
            # here on, clamped to 1..20 (ported from a reference
            # implementation and NOT independently confirmed against genuine
            # RPG_RT under wine). `#parse_bracket_value`, not a bare `arg.to_i`, for the
            # same `\S[\V[n]]` reason as `\C[]` just above. No bracket at all
            # defaults to full speed (1), matching the pre-existing default.
            if text[i] == '['
              v, i = parse_bracket_value(text, i, variables)
              speeds << { at: count, speed: Game.clamp(v, 1, 20) }
            else
              speeds << { at: count, speed: 1 }
            end
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
        instants: instants, show_gold: show_gold, speeds: speeds, length: count,
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

    # Parse a `\N[]`/`\V[]`/`\C[]`/`\S[]` bracket argument to the integer it
    # names, starting at `text[i]` (which must be the opening `[` -- callers
    # check that themselves, since "no bracket at all" has a different
    # default per code and is not this method's concern). Returns
    # `[value, new_i]`, `new_i` positioned just past the matching `]`.
    #
    # Ported from a reference implementation's shared parameter-parsing
    # routine, which backs all four codes identically (thin wrappers over
    # the same function) -- this is a
    # straight port of its character-scanning loop, not the "extract a
    # balanced-bracket substring, then regex it" approach this used to take.
    # None of the specifics below are independently confirmed against
    # genuine RPG_RT under wine; they are carried over as believed-accurate
    # from the port:
    #
    # - Digits accumulate positionally (`value = value * 10 + digit`).
    # - A nested `\v[]`/`\V[]` reference (yado.tk: `\N[\V[1]]` substitutes
    #   variable 1's own *value* in place of a literal number) recurses one
    #   level deep at most (vs. a looser 8-level extension in the reference
    #   implementation that this port does not take); `\N[\V[\V[1]]]`'s inner `\V[1]` is simply never
    #   reached. The recursion resolves the *inner* bracket to a variable
    #   *index*, then reads that variable's own value and concatenates its
    #   decimal digits onto whatever was already accumulated -- `\N[1\V[2]]`
    #   with variable 2 = 45 becomes 145, not "1" or "45" -- via
    #   `m = 10; m *= 10 while m < var_val; value = value * m + var_val`
    #   arithmetic, ported verbatim (including its own quirk of only ever
    #   widening `m` in powers of 10 relative to the newly-read value, not
    #   the exact combined digit width).
    # - The first character that is neither a digit nor a recognised nested
    #   reference stops further accumulation but *keeps* whatever was
    #   already read ("stop parsing until the next closing bracket"), rather
    #   than resetting to 0 -- unlike this method's own predecessor, which
    #   fell through to `String#to_i` and silently dropped everything from
    #   the first non-leading-digit character on.
    #
    # Returns a third element, `got_number` -- whether a digit or a
    # resolvable nested `\V[]` was actually read -- callers besides `\N[]`
    # (`\V[]`/`\C[]`/`\S[]`) have no use for it and simply destructure the
    # first two elements, which Ruby allows without error.
    def self.parse_bracket_value(text, i, variables, depth = 1)
      n = text.length
      # No bracket at all (reachable recursively too -- a malformed nested
      # reference like `\N[\V]`, `\v` with no `[` following): returns 0
      # without consuming anything, matching a reference implementation's
      # equivalent early-return -- ported behavior, NOT independently
      # confirmed against genuine RPG_RT under wine.
      return [0, i, false] unless i < n && text[i] == '['
      i += 1
      value = 0
      stop_parsing = false
      got_number = false
      while i < n && text[i] != ']'
        if stop_parsing
          i += 1
          next
        end
        ch = text[i]
        if ch >= '0' && ch <= '9'
          value = value * 10 + ch.to_i
          i += 1
          got_number = true
        elsif depth > 0 && ch == '\\' && i + 1 < n && (text[i + 1] == 'V' || text[i + 1] == 'v')
          var_id, i = parse_bracket_value(text, i + 2, variables, depth - 1)
          var_val = variables[var_id].to_i
          m = 10
          m *= 10 while value != 0 && m < var_val
          value = value * m + var_val
          got_number = true
        else
          stop_parsing = true
        end
      end
      i += 1 if i < n # consume the matching ']'
      [value, i, got_number]
    end
  end

  # Geometry of the 20 message text colours (`\c[n]`) baked into a System
  # windowskin (`System/<name>.png`). RPG2000 stores them as a 10×2 grid of
  # 16×16 swatches in the lower part of the 160×80 image, starting at y = 48;
  # colour n sits at cell (n%10, n/10). The owning scene passes a swatch's cell
  # rect to `Bitmap#blend_text`, which fills the message glyphs from it so the
  # text takes the windowskin's own colour and shading. Pure geometry (ported
  # from a reference implementation's system-colour layout), exercised by
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
    # `speeds` are `\s[n]` speed changes ({ at:, speed: }), sorted ascending;
    # `speed` 1 (full speed, RPG_RT's default before the first one) reveals at
    # the caller's own per-frame rate unchanged, and each step up slows the
    # reveal proportionally (mirroring a reference implementation's own
    # per-character wait, scaled linearly by `speed`; not independently
    # confirmed against genuine RPG_RT under wine).
    def initialize(lines, revealed = 0, pauses = [], auto_close = false,
                   instants = [], speeds = [])
      @lines = lines || []
      @total = 0
      @lines.each { |l| @total += l.length }
      @revealed = Game.clamp(revealed, 0, @total)
      # Sort with an explicit block, not sort_by: this mruby build's gembox
      # has no Array#sort_by (the native engine aborts on it).
      @pauses = (pauses || []).sort { |a, b| a[:at] <=> b[:at] }
      @auto_close = auto_close ? true : false
      @instants = instants || []
      @speeds = (speeds || []).sort { |a, b| a[:at] <=> b[:at] }
      @released = 0 # how many leading pauses the owner has let through
      @carry = 0 # fractional per-frame budget banked while a \s[] slowdown is
                 # in effect, so a sub-1-character-per-frame rate still lands
                 # on whole characters over several frames instead of rounding
                 # every frame down to zero
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

    # Reveal up to `n` more characters (default 1) at the caller's own base
    # rate, never past the total nor past the next unreleased pause. The
    # `\s[n]` speed in effect at the current position throttles that budget:
    # at speed 1 (the default) the full `n` lands this frame, same as before
    # `\s[]` existed; a higher speed banks the unused fraction in `@carry`
    # instead of dropping it, so e.g. speed 3 reveals two characters every
    # three frames rather than never advancing. When the newly revealed
    # position lands inside an instant (`\>` … `\<`) span, the whole span
    # appears at once (still capped at the pause limit).
    def advance(n = 1)
      n = 0 if n < 0
      stop = next_pause
      limit = stop ? stop[:at] : @total
      return if @revealed >= limit # blocked on the pause: no time banked either
      s = speed_at(@revealed)
      @carry += n
      step = @carry / s
      @carry -= step * s
      pos = Game.clamp(@revealed + step, 0, limit)
      pos = through_instant(pos) if pos > @revealed
      @revealed = Game.clamp(pos, 0, limit)
    end

    # The `\s[n]` speed in effect at revealed-character position `pos`: the
    # most recent `\s[]` entry at or before it, or 1 (full speed) before the
    # first one -- RPG2000's own default (a reference implementation
    # resets `speed = 1` on every new page, only `\s[]` itself ever changes
    # it; ported from that source, NOT independently confirmed against
    # genuine RPG_RT under wine).
    def speed_at(pos)
      s = 1
      @speeds.each do |sp|
        break if sp[:at] > pos
        s = sp[:speed]
      end
      s
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

  # round(num.to_f / den), banker's rounding (ties go to the nearest *even*
  # integer, not always up) -- integer arithmetic standing in for C's
  # `std::lrint` under the default IEEE 754 `FE_TONEAREST` rounding mode,
  # which is round-half-to-even, not round-half-up. `num`/`den` are both
  # non-negative (every caller's own numerator/denominator are sums/products
  # of non-negative game values); `den` must be positive.
  def self.round_half_even(num, den)
    q, r = num.divmod(den)
    twice_r = 2 * r
    return q if twice_r < den
    return q + 1 if twice_r > den
    q.even? ? q : q + 1
  end

  # RPG2000 transparency (0 opaque .. 100 fully clear) -> a 0..255 opacity.
  # Shared by Interpreter#trans_to_opacity (Show/Move Picture's live param) and
  # Game::State.restore_pictures (the save's chunk 103 field 34), which use the
  # same 0..100 scale -- see restore_pictures' comment for how that was
  # confirmed.
  def self.trans_to_opacity(top_trans)
    (100 - clamp(top_trans, 0, 100)) * 255 / 100
  end

  # The inverse of .trans_to_opacity, for writing a live picture's current
  # `Game::Picture#opacity` (0..255) back to chunk 103 field 34's own 0..100
  # transparency scale on Save (Game::State#to_lsd).
  def self.opacity_to_trans(opacity)
    100 - clamp(opacity, 0, 255) * 100 / 255
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
  # tile id following the standard BlockA/B/C/D chipset layout; unknown/out-of-range tiles are
  # treated as passable so collision degrades safely.
  class ChipSet
    # numpad direction -> passability bit.
    DIR_BIT = { 2 => 0x01, 4 => 0x02, 6 => 0x04, 8 => 0x08 }.freeze
    # The non-directional bits of the same passage byte (bit values Down=0x01,
    # Left=0x02, Right=0x04, Up=0x08, Above=0x10, Wall=0x20, Counter=0x40,
    # ported from a reference implementation and NOT independently confirmed
    # against genuine RPG_RT under wine). `ABOVE_BIT` is the editor's upper-layer "star"
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

    # `id` a dangling reference (a database shrink, or a bad Change Map
    # Tileset override, can leave one behind -- see docs/TODO.md's runtime
    # error catalog) still degrades to a blank name/graphic and nil
    # passability/terrain tables, same as it always has, but is now reported
    # rather than silently rendering the map blank and fully passable with no
    # trace. `has_table` guards the diagnostic the same way `db_item` /
    # `db_enemy_group` do, so a bare test fixture with no chipset table at all
    # (rather than a real dangling id) stays quiet.
    def initialize(db, id)
      has_table = db.respond_to?(:chipset)
      c = has_table ? db.chipset[id] : nil
      if c.nil? && has_table && id && id > 0
        $stderr.puts "[RPG2k] chipset ##{id} not found in database, " \
                     'tiles treated as blank/passable'
      end
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
    # own passability is taken into account? Mirrors a reference
    # implementation's equivalent check (ported, NOT independently confirmed
    # against genuine RPG_RT under wine): an upper tile that blocks `dir` wins outright
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
    # backdrop never resolved. A reference implementation's terrain lookup documents the
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
  # This is a direct port of a reference implementation's tilemap-layer geometry. A tile id
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
    # to take the quarter from block B instead. (Ported from a reference
    # implementation's block-A subtile table.)
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
    # (Ported from a reference implementation's block-D subtile table.)
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
    # Memoised on (id, abf, cf), which is the whole of the input: the result is
    # pure geometry, the same six numbers per quad every time. Uncached this was
    # the single largest source of allocation in the engine -- the map renderer
    # calls it once per visible tile per layer (~670 times a frame), and an
    # autotile answers with five fresh arrays -- which measured as ~350k mruby
    # allocations/second on Nepheshel. The distinct key count is bounded by the
    # chipset (a few thousand tile ids x 4 animation columns x 3 frames) and
    # each entry is a handful of small arrays, so the table settles quickly
    # rather than growing with play time.
    #
    # The returned arrays are shared between callers and must not be mutated;
    # every caller only reads them (see Scene::Map#draw_tile).
    def self.quads(id, abf = 0, cf = 0)
      # Resolving the block first does double duty. It answers the inputs that
      # have no quads at all -- `nil` (Game::Map#lower/#upper out of bounds,
      # which the renderer hits on every map edge), a negative id, and an id
      # past the last block -- before anything does arithmetic on them. And it
      # is what bounds the key below: past this guard `id` is under
      # BLOCK_F + BLOCK_F_TILES, so `id << 16` stays well inside a signed 32-bit
      # mrb_int and cannot silently become a bignum on the Emscripten / PSP /
      # Wio builds (see AGENTS.md on 32-bit mrb_int).
      b = block(id)
      return [] if b.nil?
      # abf is 0..2 and cf is 0..3 (see .anim_ab / .anim_c), so eight bits each
      # is room to spare and the three pack without overlapping.
      @quads_cache ||= {}
      key = (id << 16) | (abf << 8) | cf
      cached = @quads_cache[key]
      return cached if cached
      @quads_cache[key] = uncached_quads(b, id, abf, cf)
    end

    # Whether an upper-layer id draws nothing, so the renderer can skip it.
    #
    # Two ids mean "no upper tile here". BLOCK_F -- the *first* upper id -- is
    # the reserved blank chip, and it is what upper-layer map data is very
    # nearly all made of: 98.45% of the 584,049 upper cells across Nepheshel's
    # 543 maps, with the other 1.55% spread over 141 real ids. Drawing it
    # blitted the chipset's blank cell ~330 times per grid rebuild for no
    # pixels. A raw 0 is the other sentinel; no real map here uses it (it does
    # not appear once in those 543 maps), but the lower layer's own ids start
    # at 0, so a stray one must not be fed to .quads as water set 0.
    #
    # Rendering only. The blank id still indexes entry 0 of the chipset's
    # upper *passability* table, which Game::ChipSet#upper_flags reads for
    # real -- so this must not be used to skip a passability lookup.
    def self.upper_blank?(id)
      id.nil? || id == 0 || id == BLOCK_F
    end

    # Which of the two animation inputs a tile id's quads actually move with:
    # :abf for the block A/B autotiles (every quarter takes its chipset column
    # from it -- see .water_quads), :cf for the block C animated chips, or nil
    # for a tile that never changes on its own.
    #
    # This is what lets the map renderer tell an animation step that changes
    # its picture from one that does not. The two inputs run at different
    # rates and .anim_c is the fast one (every 6 frames, against 12 or 24 for
    # .anim_ab), so a grid holding no block C tile at all -- which is most
    # maps -- would otherwise be rebuilt ten times a second for nothing.
    def self.anim_input(id)
      case block(id)
      when :water then :abf
      when :animated then :cf
      end
    end

    def self.uncached_quads(b, id, abf, cf)
      case b
      when :water    then water_quads(id, abf)
      when :animated then [full(3 + (id - BLOCK_C) / 50, 4 + cf)]
      when :terrain  then terrain_quads(id)
      when :lower    then [lower_quad(id - BLOCK_E)]
      else                [upper_quad(id - BLOCK_F)]
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
    # the chipset. This is a direct port of a reference implementation's
    # equivalent event-tile lookup, NOT independently confirmed against
    # genuine RPG_RT under wine — the
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

    # Whether the type keeps the sprite's facing pinned (movement does not
    # turn it) unless an explicit move-route Face Direction / Turn
    # sub-command overrides it -- see Character#fixed_facing/#face!, which
    # is what actually keeps a fixed-direction event's *drawn* facing at
    # #frame's char_dir equal to its page's base_dir until one runs.
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
    # `char_dir` is the character's live facing (updated by movement, subject
    # to Character#facing_locked/#fixed_facing -- so it already sits pinned
    # at the page's own base_dir for a fixed-direction type until an explicit
    # Face Direction / Turn move-route sub-command, which bypasses both locks
    # via Character#face!, turns it), `base_pattern` the page's initial
    # pattern, `phase` the walk counter and `moving` whether the event is
    # currently stepping.
    #
    # `base_dir` is unused here (kept for callers that also need the page's
    # own starting facing to seed a fresh Character#direction): every
    # anim_type, fixed-direction ones included, now draws `char_dir`, not a
    # hardcoded page facing -- real RPG_RT lets an explicit Face command turn
    # even a "statue" (fixed / never-animating) event's sprite, per a reference
    # implementation's move-route Face-command handling, which ends in
    # an unconditional facing update with no lock
    # check at all -- only ordinary movement's own facing update respects
    # the lock (ported from that source, NOT independently confirmed against
    # genuine RPG_RT under wine). Spinning events derive facing from the phase but keep the
    # page's own pattern column (a graphic that repurposes the 3 columns for
    # unrelated frames, like Nepheshel's Crystal Gate save point -- column 0
    # lit, column 2 unlit -- would show the wrong one of those for 3 out of 4
    # spin frames if the column were forced to a fixed "standing" index
    # instead); a fixed graphic never advances its column at all (see
    # #animated?, which stops #animate_event from ever ticking `phase`, so it
    # stays base_pattern by construction); the ordinary types walk (cycling
    # columns) while moving/continuous and rest on the page pattern when idle.
    def self.frame(anim_type, base_dir, base_pattern, char_dir, phase, moving)
      [frame_dir(anim_type, char_dir, phase),
       frame_col(anim_type, base_pattern, phase, moving)]
    end

    # The direction half of #frame, split out so a caller that only needs it
    # (map.rb's per-event redraw signature, checked every event every frame)
    # can skip building and immediately discarding the two-element array.
    def self.frame_dir(anim_type, char_dir, phase)
      anim_type == SPIN ? spin_direction(phase) : char_dir
    end

    # The column half of #frame, split out for the same reason as #frame_dir.
    def self.frame_col(anim_type, base_pattern, phase, moving)
      case anim_type
      when SPIN, FIXED_GRAPHIC
        base_pattern
      else
        (moving || continuous?(anim_type)) ? pattern_column(phase) : base_pattern
      end
    end
  end

  # Geometry of the map's parallax background (the `Panorama/<name>` image drawn
  # behind the tile layers, `MAP_UNIT` fields 31–38). Given the camera position,
  # the screen / map / image sizes and the per-axis loop + autoscroll settings,
  # #axis_offset returns the top-left offset (<= 0) at which to start tiling the
  # image for that axis. The behaviour follows a reference implementation's parallax model:
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
  # a reference implementation's formulae but has not been visually diffed
  # against RPG_RT under wine — that native comparison is the remaining validation.
  module Parallax

    # Per-frame autoscroll offset in pixels for an RPG2000 speed field, ported
    # from a reference implementation's autoscroll amount with its pan->pixel (/32) scaling so small
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
    # map (0 at the west/north edge, up to -excess at the east/south edge).
    #
    # The excess actually panned across is `[cam_max, img_px - screen_px].min`,
    # not always the image's own full excess -- ported from a reference
    # implementation's equivalent clamp (the map's own scrollable excess
    # capped by the panorama's excess width). Confirmed against genuine
    # RPG_RT.exe under wine (Nepheshel, Map0001): patched a custom
    # non-looping panorama (a plain red/blue split image, 1320px wide, far
    # wider than the map's own 320px scroll excess) onto a real map with an
    # already-visible panorama window (a lake), stood the party at the map's
    # far scroll edge, and read which color filled the screen. The clamped
    # formula and the naive "always the image's own full excess" alternative
    # predict different, non-overlapping source regions of the test image at
    # that camera position -- the clamped one entirely inside the red band,
    # the naive one entirely inside the blue -- and the screen came back
    # solid red, matching the clamp. Without this clamp, a panorama image
    # wider than the map's own scroll range would report an offset past what
    # `cam_max` worth of scrolling should ever reveal -- unreachable when the
    # image's excess happens to be no bigger than the map's own (every case
    # this codebase's own render checks exercised until now), but a real
    # divergence once it is: a small map with a wide panorama image.
    def self.anchored_offset(cam_px, screen_px, map_px, img_px)
      return 0 if img_px <= screen_px
      cam_max = map_px - screen_px
      return 0 if cam_max <= 0
      cam = Game.clamp(cam_px, 0, cam_max)
      span = [cam_max, img_px - screen_px].min
      -(span * cam / cam_max)
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

    def initialize; @data = {}; @revision = 0; @dirty = {}; end
    def [](id); @data[id] || false; end

    def []=(id, v)
      nv = v ? true : false
      return nv if self[id] == nv
      @data[id] = nv
      @revision += 1
      # nil stays nil: a bulk replace made every id dirty, which subsumes this
      # one, and writing into nil would crash.
      @dirty[id] = true unless @dirty.nil?
      nv
    end

    def flip(id); self[id] = !self[id]; end
    def to_h; @data; end
    def replace(h)
      @data = h || {}
      @revision += 1
      # Bulk loads (a save, a debug fill) carry an unknown id set: the next
      # page sweep must assume every switch-referencing page may have flipped.
      @dirty = nil
    end

    # Which ids changed since the page sweep last consumed them -- a Hash of
    # ids, or nil when the set is unknown (a bulk `replace`). Scene::Map's
    # page sweep re-selects only the events whose conditions reference a dirty
    # id; #clear_dirty closes the sweep.
    attr_reader :dirty

    def clear_dirty; @dirty = {}; end
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

    # RPG2003 widens the same clamp to +-9999999 (one more digit), matching
    # `LCF.var_max`/`var_min`'s own `MODE == 2003` branch -- a fixed edition
    # constant here rather than a call into mruby-lcf, for the same reason
    # MAX/MIN above are.
    RPG2003_MAX = 9_999_999
    RPG2003_MIN = -9_999_999

    # See Switches#revision: page conditions read variables too.
    attr_reader :revision

    def initialize(rpg2003 = false)
      @data = {}
      @revision = 0
      @dirty = {}
      @max = rpg2003 ? RPG2003_MAX : MAX
      @min = rpg2003 ? RPG2003_MIN : MIN
    end

    def [](id); @data[id] || 0; end

    def []=(id, v)
      v = @max if v > @max
      v = @min if v < @min
      return v if self[id] == v
      @data[id] = v
      @revision += 1
      @dirty[id] = true unless @dirty.nil? # nil stays nil, see Switches#[]=
      v
    end

    def to_h; @data; end
    def replace(h)
      @data = h || {}
      @revision += 1
      @dirty = nil # bulk load: unknown id set, see Switches#replace
    end

    # See Switches#dirty: the ids written since the page sweep last consumed
    # them, or nil after a bulk `replace`.
    attr_reader :dirty

    def clear_dirty; @dirty = {}; end
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
      # The rightmost (least significant) cell, not the leftmost -- ported
      # from a reference implementation's source, NOT independently confirmed
      # against genuine RPG_RT under wine: its number-input cursor reset
      # leaves the cursor at the last digit cell plus an optional sign cell,
      # and this class always leaves that sign cell
      # unused (the Input Number event command never shows a +/- sign cell) --
      # the last digit index is the last-drawn, rightmost digit.
      @cursor = d - 1
    end

    # The digit shown at position i (0 = most significant, leftmost).
    def digit(i); @values[i] || 0; end

    def inc; @values[@cursor] = (@values[@cursor] + 1) % 10; end
    def dec; @values[@cursor] = (@values[@cursor] + 9) % 10; end
    # Left/Right wrap cyclically rather than clamp at either end -- RPG_RT's
    # own `Update()` moves the cursor with `index = (index + 1) %
    # digits_max` (Right) and `index = (index + digits_max - 1) %
    # digits_max` (Left), never refusing to move past an edge cell.
    def left;  @cursor = (@cursor + @digits - 1) % @digits; end
    def right; @cursor = (@cursor + 1) % @digits; end

    # The entered value as a base-10 integer (leftmost cell is most significant).
    def value
      v = 0
      @values.each { |d| v = v * 10 + d }
      v
    end
  end

  # One party member, snapshotted from the database's actor (player) table.
  class Actor
    # RPG2003 front/back row (ADR 0053). Lives here, not on Battle, because
    # #battle_row=/#battle_row below and Party#toggle_actor_row's field-menu
    # Row command both need it whether or not a fight has ever started --
    # Battle's own copy is just an alias onto these same two values, kept for
    # every other RPG2003 combat formula's existing `ROW_FRONT`/`ROW_BACK`
    # call sites (see its own comment).
    ROW_FRONT = 0
    ROW_BACK = 1

    attr_reader :id, :level, :exp, :charset_name, :charset_index
    # The actor's default FaceSet portrait (chunk 15/16), shown by the Enter
    # Hero Name screen and, once a message picks it explicitly, by Show Text.
    attr_reader :face_name, :face_index
    attr_accessor :hp, :mp
    # The HP/MP maximum a status panel should display for this actor: the larger
    # of the live current value and the recomputed stat maximum. A resumed real
    # save (docs/TODO.md's "Save & Continue" entry) can carry a current HP/MP
    # that exceeds this engine's own growth-curve figure -- RPG_RT shows the
    # saved current as both value and ceiling, so a panel reads e.g. 600/600
    # rather than 600/<smaller max>. Display only: it must never feed the
    # damage/heal clamping in #change_hp / #change_mp / #recompute_stats, which
    # keep using the genuine recomputed maximum.
    def display_max_hp; hp && hp > max_hp ? hp : max_hp; end
    def display_max_mp; mp && mp > max_mp ? mp : max_mp; end
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
    # The item field carrying each stat's equipment bonus, in STAT_NAMES order,
    # nil for the two stats no equipped item can ever raise. RPG2000's editor
    # only offers an equip-bonus field for the four combat stats -- Attack,
    # Defence, Mind (Spirit), Agility -- stored in each item's "points1" set
    # (`atk_points1`/`def_points1`/`spi_points1`/`agi_points1`) and summed live
    # over every equipped slot every time gear changes; a weapon/armour/shield/
    # helmet/accessory has no "+Max HP"/"+Max SP" field to set at all. The
    # `max_hp_points`/`max_sp_points` fields exist on every item row (the LCF
    # schema does not split fields by item type), but they are semantically
    # part of a *different* six-field set together with `atk_points2`/
    # `def_points2`/`spi_points2`/`agi_points2` -- a Seed-type (材料, database
    # item type 8) item's own one-time, permanent stat-up amount, applied only
    # when the item is *consumed* (`Actor#seed_boosts`/`Party#use_seed`, via
    # `Actor#change_param`), never while merely worn. Ported from a reference
    # implementation's source: its max-HP/max-SP getters resolve to
    # the base stat with no per-equipment summation at all,
    # unlike the Attack/Defence/Spirit/Agility getters, which
    # each walk every equipped item reading exactly the
    # matching `*_points1` field; `max_hp_points`/`max_sp_points` are read
    # nowhere in that equip-time path, only inside the use-item Material branch
    # alongside `atk_points2`..`agi_points2`, the exact fields
    # `Game::Actor#seed_boosts` (`use_seed`, `Scene::ItemMenu`'s Seed handling
    # above) already reads for the one-time consumable boost. So indices 0/1
    # (max_hp/max_mp) carry no field here at all -- #equip_bonus returns 0 for
    # them unconditionally, regardless of what an item's own `max_hp_points`/
    # `max_sp_points` happen to hold. Confirmed via wine (2026-09-05): a
    # custom weapon with `max_hp_points` forced to 500 (atk_points1 left at
    # 0, isolating this from the separately-confirmed Attack equip-bonus
    # path) equipped through the actual in-game Equip menu left Rito's
    # status-panel HP reading a plain 50/50, not the roughly 550 a summed
    # bonus would show -- a jump far too large to miss.
    EQUIP_BONUS_FIELD = [nil, nil, :atk_points1,
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
    # (ported from a reference implementation, where the equivalent stat,
    # skill-learn and EXP-curve lookups all branch on `class_id > 0`; NOT
    # independently confirmed against genuine RPG_RT under wine).
    attr_reader :class_id

    # The class row's own display name ('' with no class row -- an RPG2000
    # database, or an unknown/class-less id). Unlike the growth-curve/
    # battler-animation readers below, this is *not* gated on
    # `@class_changed`: ported from a reference implementation's source, NOT
    # independently confirmed against genuine RPG_RT under wine --
    # its class-name reader reads straight
    # through the class lookup, which resolves `data.class_id` (falling back to
    # the database actor's own starting `class_id` when no Change Class
    # event has run yet) with no such gate at all -- `@class_changed` only
    # governs the separate "class settings" (`super_guard`/`lock_equipment`/
    # `battler_animation`/etc.) `ChangeClass` itself applies, per that
    # function's own comment already quoted above. `@class_row` is already
    # populated unconditionally at construction from the actor's starting
    # class id, so this just reads it straight.
    def class_name; @class_row ? @class_row.name.to_s : ''; end

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
      # The runtime battler-animation override and whether a Change Class
      # event has actually run this session -- see #battler_animation_id.
      # Both start unset even when the database gives this actor a starting
      # class (chunk 11 field 57): a reference implementation's own source
      # comment on this is explicit ("The class settings are not applied
      # when the actor has a class on startup but only when the 'Change
      # Class' event command is used") -- ported behavior, NOT
      # independently confirmed against genuine RPG_RT under wine -- and
      # #battler_animation_id mirrors it by keying on this flag rather than on `@class_id > 0` alone.
      @battler_animation_override = 0
      @class_changed = false
      # Whether a Change Sprite Association (10630) has actually run for this
      # actor, as opposed to @charset_name/@charset_index still being the
      # actor's own untouched database default set two lines up -- confirmed
      # against genuine RPG_RT.exe under wine (cycle #170): a save taken right
      # after Change Sprite Association wrote new fields 11 (sprite_name) / 12
      # (sprite_id) / 13 (sprite_transparent, absent unless the transparency
      # flag was set) onto that actor's own SAVE_PARTY_ACTOR entry (chunk
      # 108), while an otherwise identical actor whose *database* row already
      # carried that same non-blank graphic -- no Change Sprite Association
      # ever run -- left chunk 108 entirely without fields 11-13 (only the
      # hero's own live-sprite mirror on chunk 104, fields 73/74, reflected
      # it, elided only when blank). See SAVE_PARTY_ACTOR's own schema.rb
      # comment and #to_lsd/.from_lsd's own citations for the full writeup.
      @sprite_changed = false
      @battle_commands = nil # lazily taken from the database on the first change
      # RPG2003 battle front/back row (ADR 0053): purely runtime/save state,
      # never derived from the database's own `battle_x`/`battle_y` manual
      # placement -- a reference implementation seeds a fresh actor's
      # row/original-position from separate fields entirely, and
      # only the in-battle Row command (Combatant#toggle_row) or a restored
      # save (SAVE_PARTY_ACTOR field 0x5B/91) ever moves it off the front row.
      @row = ROW_FRONT
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
      # RPG2003 "cursed" starting gear (an item flagged Curse/
      # reverse_state_effect with its own state_set) inflicts its forced
      # states from the very first frame, not only once equipped through a
      # later Equip command. Ported from a reference implementation's source, NOT
      # independently confirmed against genuine RPG_RT under wine:
      # its actor constructor applies each of the five initial-equipment
      # slots through the exact same equip-effect path -- the exact same
      # function (and therefore the exact same equipment-state adjustment) an
      # ordinary mid-game equip change goes through -- so an actor whose
      # starting shield/armor/helmet/accessory is cursed begins the game
      # already afflicted, visible in the status window from turn one.
      # #equip_item/#unequip/#equip below already call
      # #adjust_equipment_states for every later change; only the
      # constructor's own starting loadout skipped it. Placed after HP/MP
      # are set to their max above, matching that reference implementation's
      # own ordering (HP/SP set before the equip loop there), so a (deliberately
      # extreme) cursed item whose state_set includes the Death state still
      # leaves the actor at 0 HP rather than being overwritten back to full.
      @equipment.each { |id| adjust_equipment_states(id, true) }
    end

    attr_writer :exp

    # Set the actor's level and recompute the six base stats from the database
    # growth curve at that level (see #base_stats), then the equipment-boosted
    # effective stats. Current HP/MP are re-clamped so lowering the level never
    # leaves a vital over its cap.
    #
    # An ordinary level change (EXP gain/loss, the Change Level command) does
    # NOT reset a live Change Parameters adjustment -- ported from a
    # reference implementation's source, NOT independently confirmed against
    # genuine RPG_RT under wine: its level-set routine
    # only clamps the level and re-clamps current HP/SP, never touching
    # the stat-modifier fields; those modifier fields are zeroed only inside
    # its class-change routine. Since this class tracks the mod as an
    # unclamped running total (@base_raw = curve + mod) rather than a separate
    # field, `preserve_mod` re-derives the mod by diffing @base_raw against
    # the curve at the *old* level/class (whichever was in force when this
    # actor last had its base set) and re-applies that same mod on top of the
    # new level's curve, so the delta survives level changes the way that
    # reference implementation's separate mod field does. #change_class passes `preserve_mod: false`,
    # matching its own explicit mod-zeroing before it reapplies
    # the class's own curve.
    def set_level(level, preserve_mod: true)
      mod = preserve_mod && @base_raw ? Array.new(@base_raw.size) { |i| @base_raw[i] - base_stats(@level)[i] } : nil
      @level = level && level >= 1 ? level : 1
      curve = base_stats(@level)
      @base_raw = mod ? Array.new(curve.size) { |i| curve[i] + mod[i] } : curve.dup
      @base = Array.new(@base_raw.size) { |i| Game.clamp(@base_raw[i], 1, base_param_limit(i)) }
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
    # command): `name` is the file and `index` the cell within it. Also called
    # while restoring a saved override (Game::State.from_lsd) -- both are a
    # real, persisted "changed" event, not the actor's own untouched database
    # default set at #initialize -- see @sprite_changed's own comment there.
    def set_charset(name, index)
      @charset_name = name
      @charset_index = index
      @sprite_changed = true
    end

    # Whether #set_charset has actually run for this actor (a live Change
    # Sprite Association, or one restored from a save) -- see @sprite_changed's
    # own comment at #initialize.
    def sprite_changed?; @sprite_changed; end

    # Whether #name/#title currently differ from this actor's own database
    # row -- the gate #to_lsd uses for chunk 108 fields 1/2, confirmed
    # against a genuine kk1.12 (RPG2003) save under wine: every actor in
    # that save's roster (no Change Actor Name/Title ever run against any of
    # them) carried the "\x01" placeholder byte ADR 0014 already documents,
    # not its own database name/title -- a value this codebase's own writer
    # used to ignore, unconditionally writing the actor's current (here,
    # untouched-from-default) name/title instead. This is a plain value
    # comparison, not a "did the command ever run" flag like
    # #sprite_changed?/#class_changed?: a reference implementation's own
    # name-setting logic (see #do_change_actor_name's own citation) collapses
    # "set back to exactly the database name" into the identical
    # no-override state as never having touched it at all, so comparing
    # against the database row's own value reproduces that same collapse
    # for free, with no separate "ever changed" bookkeeping to keep in sync.
    def name_changed?; @name != (@db_row.name || ''); end
    def title_changed?
      default = @db_row.respond_to?(:title) ? (@db_row.title || '') : ''
      @title != default
    end

    # Total number of states (状態) this game's database defines -- the fixed
    # length genuine RPG_RT.exe's own chunk 108 field 82 always uses, index
    # `state_id - 1`, one slot per database state id, confirmed against a
    # genuine kk1.12 save under wine: field 81 (its paired count) read
    # exactly 30, this test bed's own total state count, for every actor,
    # none of them afflicted with anything -- not "how many states are
    # currently active" as `#to_lsd` used to assume when it treated this
    # pair as a sparse list of only the afflicted ids (the same
    # count-then-data shape, but the wrong cardinality). A reference
    # implementation's own inflicted-states reader matches
    # the wire semantics too (ported from its source): it walks its own dense, database-sized status
    # vector and collects `i + 1` wherever `states[i] > 0` -- a per-state
    # turn counter, not a boolean -- so a slot's value is genuinely `0` for
    # "not afflicted" and *some* positive count for "afflicted", though this
    # codebase has no turn-counter of its own to round-trip once a state
    # survives past the battle that inflicted it, so `#to_lsd` below writes
    # a plain `1` for "afflicted" rather than a real duration.
    def total_state_count
      table = @db.respond_to?(:situation) ? @db.situation : nil
      table ? table.to_a.size : 0
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
    #
    # Ported from a reference implementation's source, NOT independently confirmed
    # against genuine RPG_RT under wine:
    # its learn-skill routine appends the new skill id and
    # re-sorts the whole skill list
    # -- every learn, from levelling, Change Class, or
    # the Change Skills event command alike, re-sorts the actor's skill
    # list into ascending id order immediately, so it is never in "learn
    # order". This matters beyond display (`#field_skills`/`#battle_skills`
    # already `.sort` before listing, so the menus never looked wrong):
    # `#choose_auto_battle_command` iterates the actor's own raw `#skills`
    # unsorted, and `#auto_battle_skill_rank` draws one `@rng.random(100)`
    # jitter roll per candidate skill -- so learning a low-id skill after a
    # higher-id one (an entirely ordinary Change Skills event, or a growth
    # table not monotonic in skill id) consumed the shared RNG stream in a
    # different order than real RPG_RT, drifting every roll for the rest of
    # a seeded fight, and could pick a different skill outright on a
    # near-tie.
    def learn_skill(skill_id)
      return if skill_id.nil? || skill_id == 0 || @skills.include?(skill_id)
      @skills.push(skill_id)
      @skills.sort!
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
    # moment HP is restored (matching the same hardcoded death-state id used
    # by reference implementations of the format).
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

    # Whether this actor may be handed a Skill command at all right now:
    # false only when a currently-inflicted state fully restricts action
    # (asleep, paralysed). Ports a reference implementation's own can-act
    # check (NOT independently confirmed against genuine RPG_RT under wine),
    # which (deliberately) does not check death separately, just this
    # restriction -- `Scene::Menu`'s own actor-selection panel is the one
    # caller, gating the Skill command the same way that reference
    # implementation's actor-selection Skill case does.
    def can_act?
      table = @db.respond_to?(:situation) ? @db.situation : nil
      !@states.any? do |id|
        row = Game::States.row(id, table)
        row && row.respond_to?(:restriction) && row.restriction == Battle::RESTRICTION_DO_NOTHING
      end
    end

    # Whether one of this actor's own currently-inflicted states seals skill
    # row `sk` -- RPG2000 gives a state two independent seals, each with a
    # threshold: `restrict_skill` bars any skill whose `physical_rate` reaches
    # `restrict_skill_level`, and `restrict_magic` bars any whose
    # `magical_rate` reaches `restrict_magic_level` (ported from a reference
    # implementation's skill-usable check, NOT independently confirmed against
    # genuine RPG_RT under wine -- the same check
    # `Game::Battle#skill_sealed?` already ports for the in-battle skill menu;
    # this is its field-side twin, since that check runs identically for
    # both -- the field and battle skill windows share one class there, and
    # nothing in that reference implementation gates this loop on being in a fight at all).
    # 封印 / Silence are what these fields are *for*.
    def skill_sealed?(sk)
      return false unless sk
      table = state_table
      @states.any? do |sid|
        d = Game::States.row(sid, table)
        next false unless d
        (d.respond_to?(:restrict_skill) && d.restrict_skill &&
         (sk.physical_rate || 0) >= (d.respond_to?(:restrict_skill_level) ? (d.restrict_skill_level || 0) : 0)) ||
        (d.respond_to?(:restrict_magic) && d.restrict_magic &&
         (sk.magical_rate || 0) >= (d.respond_to?(:restrict_magic_level) ? (d.restrict_magic_level || 0) : 0))
      end
    end

    # Inflict a status condition (no-ops for an absent/duplicate id). Inflicting
    # the death state (戦闘不能) knocks the actor out, zeroing HP.
    #
    # `allow_battle_states:` mirrors a reference implementation's own
    # equivalent identical-named parameter (ported from its source, NOT independently
    # confirmed against genuine RPG_RT under wine) -- `false` refuses
    # to add a state whose own database Persistence field is left at its
    # "Ends" default (`#state_persists_type?`'s own inverse), the same test
    # `#remove_state`'s `always_remove_battle_states:` already ports for the
    # cure side. Only `#adjust_equipment_states`' equip branch passes
    # `false`: ported from that reference implementation's equip routine, which
    # hard-codes the equivalent of `allow_battle_states: false` on every equip-triggered
    # state-adjustment call (the equip menu, Change Equipment, and
    # even an actor's own starting gear all funnel through it) -- so
    # equipping a cursed item whose forced state was left at its default
    # Persistence never actually inflicts it in real RPG_RT at all (NOT
    # independently confirmed against genuine RPG_RT under wine). Every
    # other caller (`#knock_out!`, `#full_heal`, `Party#cast_skill`'s target
    # loop) keeps the default `true`, matching that reference implementation's own ordinary
    # in-battle/skill infliction paths and
    # Change Condition -- ported from its
    # source, NOT independently confirmed against genuine RPG_RT under wine
    # -- neither of which this restriction ever applies to.
    def add_state(state_id, allow_battle_states: true)
      return if state_id.nil? || state_id == 0 || @states.include?(state_id)
      return if !allow_battle_states && !state_persists_type?(state_id)
      @states.push(state_id)
      @hp = 0 if state_id == DEATH_STATE
    end

    # Cure a status condition. Removing the death state revives a downed actor
    # with 1 HP (RPG2000's revive floor); returns the removed id or nil.
    # Refuses a state #permanent_states names -- RPG2003 cursed armor
    # currently forcing it -- the same way a reference implementation's
    # state-removal routine does, ported from its source and
    # NOT independently confirmed against genuine RPG_RT under wine.
    #
    # `always_remove_battle_states:` mirrors a reference implementation's own
    # state-removal routine's second parameter of the identical name:
    # the Change Condition event command
    # (`Interpreter#do_change_condition`) passes it true when run outside
    # battle, and that reference implementation's own state-removal routine then skips the cursed-armor
    # lock entirely -- but only for a state whose own database Persistence
    # field is "Ends" (0, the schema default for most non-Poison-style
    # ailments), never a "Continues after battle" one (1) -- ported from its
    # source, NOT independently confirmed against genuine RPG_RT under wine,
    # with that reference implementation's own
    # comment on the call site spelling out why it believes this matches
    # RPG_RT: "RPG_RT: On the map,
    # will remove battle states even if actor has state inflicted by
    # equipment." Every other cure path -- an item, a skill, Full Recovery,
    # or Change Condition while a fight is actually running -- always
    # passes `false` in real RPG_RT too, so this bypass is exactly as
    # narrow there as it is here.
    def remove_state(state_id, always_remove_battle_states: false)
      bypass = always_remove_battle_states && !state_persists_type?(state_id)
      return nil if !bypass && permanent_states.include?(state_id)
      removed = @states.delete(state_id)
      @hp = 1 if removed == DEATH_STATE && @hp <= 0
      removed
    end

    # Whether `state_id`'s own database row is flagged "Continues after
    # battle" (liblcf's `Persistence_persists`, matching `Battle::
    # STATE_PERSISTS_ON_MAP`) -- #remove_state's own
    # `always_remove_battle_states:` bypass only ever applies to the
    # opposite, schema-default case. A dangling/unknown state id, or a bare
    # fixture with no `:type` field at all, reads as persisting (never
    # bypassed) -- the same conservative refusal #remove_state already gave
    # before this parameter existed.
    def state_persists_type?(state_id)
      table = @db.respond_to?(:situation) ? @db.situation : nil
      row = Game::States.row(state_id, table)
      !(row && row.respond_to?(:type) && (row.type || 0) != Battle::STATE_PERSISTS_ON_MAP)
    end

    # Cure every status condition (RPG2000 Full Recovery clears them). If the
    # actor was down, curing the death state revives it with 1 HP. Leaves any
    # #permanent_states id in place, matching a reference implementation's
    # remove-all-states routine
    # (ported from its source, NOT independently confirmed against genuine
    # RPG_RT under wine): each id is only ever cleared through the same
    # permanent-states-respecting removal path every other cure path uses.
    def clear_states
      perm = permanent_states
      revive = @hp <= 0 && @states.include?(DEATH_STATE) && !perm.include?(DEATH_STATE)
      @states = @states.select { |s| perm.include?(s) }
      @hp = 1 if revive && @hp <= 0
    end

    # Replace the state set (Continue restoring the saved conditions). The saved
    # HP is authoritative and restored separately, so this assigns without the
    # HP-coupling side effects.
    def states=(ids)
      @states = (ids || []).reject { |s| s.nil? || s == 0 }.uniq
    end

    # Replace the equipped items (an array of up to five item ids in EQUIP_ORDER,
    # 0/nil for an empty slot) and recompute the boosted stats. Adjusts
    # #adjust_equipment_states for every slot whose item actually changes,
    # same as a single #equip_item/#unequip would -- every real caller
    # (Party#load_state's own actor-roster restore) immediately overwrites
    # `@states` afterward with the save's own authoritative list anyway, so
    # this only matters for a future bulk-equip caller that does not.
    def equip(ids)
      old_equipment = @equipment
      new_equipment = normalize_equipment(ids)
      @equipment = new_equipment
      EQUIP_ORDER.size.times do |slot|
        old_id = old_equipment[slot]
        new_id = new_equipment[slot]
        next if old_id == new_id
        adjust_equipment_states(old_id, false)
        adjust_equipment_states(new_id, true)
      end
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
    # too -- ~~always by type, since that command names no slot~~: since the
    # dual-wield redirect below, `Party#equip_item_from_bag` also passes an
    # explicit shield-slot for a 二刀流 actor's second weapon, the same way
    # the equip menu does.
    def equip_item(item_id, slot = nil)
      return if item_id.nil? || item_id == 0 || !@db.respond_to?(:item)
      it = @db.item[item_id]
      return unless it
      slot ||= it.type - 1
      return unless slot >= 0 && slot < EQUIP_ORDER.size
      old_id = @equipment[slot]
      @equipment[slot] = item_id
      freed = free_two_handed_slot(slot)
      adjust_equipment_states(old_id, false)
      adjust_equipment_states(freed, false) if freed
      adjust_equipment_states(item_id, true)
      recompute_stats
      freed
    end

    # 両手持ち — a weapon that needs both hands. RPG_RT keeps the weapon and the
    # shield slots mutually exclusive whenever either of them holds a two-handed
    # *weapon*: filling one clears the other (ported from a reference
    # implementation's equip routine, which clears the other slot after the
    # slot is written). Confirmed via wine (2026-09-05): Rito, with a real
    # shield (item 176) already equipped, was handed a real two-handed
    # weapon (item 66, 35 of Nepheshel's 104 weapons are two-handed) through
    # the actual in-game Equip menu -- the candidate-select screen's own
    # stat preview already showed defence dropping before confirming, and
    # confirming left the weapon slot holding the new sword with the shield
    # slot reading empty, not holding both. 14 of mtf-meido-action's 26
    # weapons are two-handed too -- more than half of that game's arsenal --
    # and before this method existed nothing read the field at all, so a
    # claymore and a shield could be worn together and both bonuses counted.
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
        old_equipment = @equipment
        @equipment = EQUIP_ORDER.map { 0 }
        old_equipment.each { |id| adjust_equipment_states(id, false) }
      elsif slot >= 0 && slot < EQUIP_ORDER.size
        old_id = @equipment[slot]
        @equipment[slot] = 0
        adjust_equipment_states(old_id, false)
      else
        return
      end
      recompute_stats
    end

    # The six base stats at `level`. Real database rows expose the full growth
    # curve via LCF::Array1D#int16_values(31) as six contiguous max_level-sized
    # blocks -- one block per stat in STAT_NAMES order (every level's max_hp,
    # then every level's max_mp, then atk, def, int, agi), NOT max_level rows of
    # six stats each. Confirmed against a genuine RPG_RT.exe: an actor whose
    # curve blocks were independently distinguishable (non-symmetric across
    # stats) was equipped and levelled identically in this engine and under
    # real RPG_RT, and only a stat-major (six-blocks-of-max_level) reading of
    # the raw shorts reproduced RPG_RT's displayed ATK/DEF/SPI/AGI exactly --
    # the previously-assumed row-major (max_level rows of six) reading was
    # correct only by coincidence on actors whose curve happens to be
    # level-count-1 (a single row, where the two layouts are indistinguishable)
    # and was off by as much as 2.3x on a real multi-level curve. A row that
    # only offers a single `status` hash (the test fixtures, or a database
    # without a curve) is treated as level-independent. With a class set the
    # class row's curve wins.
    def base_stats(level)
      a = curve_row
      curve = a.respond_to?(:int16_values) ? a.int16_values(31) : nil
      if curve && curve.size >= STAT_NAMES.size
        levels = curve.size / STAT_NAMES.size
        lv = level > levels ? levels : level
        return Array.new(STAT_NAMES.size) { |i| curve[(i * levels) + (lv - 1)] || 0 }
      end
      st = (a.respond_to?(:status) ? a.status : nil) || {}
      STAT_NAMES.map { |k| st[k] || 0 }
    end

    # Real RPG_RT's "displayed max HP capped 1-999" is not cosmetic -- the
    # clamp applies to the *effective* stat itself, equipment bonus included,
    # not just to the level-curve baseline #change_param's own 1..999/1..9999
    # floor (`#base_param_limit`, just below) already respects. Ported from
    # a reference implementation's source, NOT independently confirmed against genuine
    # RPG_RT under wine: its base-Attack/Defence/Spirit/Agility
    # getters each sum
    # the level curve, the Change-Parameters `*_mod` shadow, and every
    # equipped item's own `*_points1` bonus, THEN clamp the total to
    # that reference implementation's own max-stat-base value -- which
    # defaults to 999 for both RPG2000 and RPG2003, no
    # edition split -- so the equip bonus sits *inside* the same ceiling the
    # base value alone already respects, not stacked unclamped on top of it.
    # Its base-max-HP/max-SP getters clamp the same way to their own
    # per-edition maxima: HP is edition-gated (999 for RPG2000, 9999 for RPG2003,
    # matching the existing `#rpg2003?` accessor other RPG2003-widened
    # limits already key off), SP stays 999 in both editions with no such
    # split (RPG2000's own "9999 for max HP/MP" reading, baked into
    # `#base_param_limit` below, is only correct for HP on an RPG2003
    # database -- MP was never 9999 in either edition, a separate,
    # pre-existing mismatch left as-is here since it only ever over-widens a
    # ceiling nothing before this fix re-applied anyway).
    MAX_EFFECTIVE_STAT = 999
    MAX_EFFECTIVE_MP = 999
    MAX_EFFECTIVE_HP_2K = 999
    MAX_EFFECTIVE_HP_2K3 = 9999

    # Recompute the six effective stats (curve + Change-Parameters shadow +
    # equipment, one combined clamp) into their readers, and re-clamp current
    # HP/MP to the refreshed maxima.
    #
    # Reads `@base_raw` (the unclamped curve+mod shadow), not `@base` (the
    # pre-equipment clamped snapshot #change_param also derives) -- a prior
    # version summed `@base[i] + equip_bonus(i)`, clamping the curve+mod part
    # *before* equipment ever entered the formula, where a reference
    # implementation's own base-stat getters sum curve + mod + equip and
    # clamp the combined
    # total exactly once (ported from that source, NOT independently
    # confirmed against genuine RPG_RT under wine). The two only disagree once `@base_raw` has actually
    # been pushed outside 1..999/1..9999 (a heavy Change Parameters debuff or
    # buff) and equipment changes afterward: e.g. Attack debuffed by 100 (base
    # 50 -> raw -50, clamped display 1), then a +30-Attack weapon equipped --
    # this method used to compute `clamp(1 + 30, 1, 999) = 31`, letting the
    # weapon's whole bonus land on top of an already-bottomed-out stat that
    # real RPG_RT still reads as `clamp(-50 + 30, 1, 999) = 1`, the debuff
    # still fully in effect. `@base` itself is unaffected by this fix --
    # #change_param and #restore_base still maintain it as their own clamped
    # snapshot, just no longer the one #recompute_stats reads.
    def recompute_stats
      @max_hp = Game.clamp(@base_raw[0] + equip_bonus(0), 1, max_hp_cap)
      @max_mp = Game.clamp(@base_raw[1] + equip_bonus(1), 0, MAX_EFFECTIVE_MP)
      @atk = Game.clamp(@base_raw[2] + equip_bonus(2), 1, MAX_EFFECTIVE_STAT)
      @def = Game.clamp(@base_raw[3] + equip_bonus(3), 1, MAX_EFFECTIVE_STAT)
      @int = Game.clamp(@base_raw[4] + equip_bonus(4), 1, MAX_EFFECTIVE_STAT)
      @agi = Game.clamp(@base_raw[5] + equip_bonus(5), 1, MAX_EFFECTIVE_STAT)
      @hp = @max_hp if @hp && @hp > @max_hp
      @mp = @max_mp if @mp && @mp > @max_mp
    end

    # Whether this actor's database is an RPG2003 project -- the same
    # `@db.respond_to?(:rpg2003?) && @db.rpg2003?` test `Game::Party#rpg2003?`
    # already exposes, duplicated here since an `Actor` only ever holds `@db`
    # directly, not a `Party` back-reference; a bare test double with no
    # `#rpg2003?` of its own reads false, matching a genuine RPG2000 database.
    def rpg2003?
      @db.respond_to?(:rpg2003?) && @db.rpg2003?
    end

    # RPG2003's "cursed"/forced-state armor rule (a shield/armor/helmet/
    # accessory item whose `reverse_state_effect` flag is set): the state
    # ids `item_id`'s own `state_set` marks, or [] when the rule doesn't
    # apply at all -- a non-RPG2003 database, an unknown/absent item id, a
    # non-armor item (weapons never carry a state_set in the editor), or
    # one with the flag unset. Shared by #adjust_equipment_states and
    # #permanent_states below, matching how a reference implementation's own
    # armor-type test backs both its equip-state-adjustment and
    # permanent-states routines (ported from its source, NOT independently
    # confirmed against genuine RPG_RT under wine).
    # `Party::ITEM_SHIELD/ARMOR/HELMET/ACCESSORY`
    # name the same four item types that armor-type test covers, already used
    # elsewhere in this file for the identical distinction (see e.g.
    # #defensive_attribute_ids below).
    def cursed_armor_state_ids(item_id)
      return [] unless rpg2003?
      return [] if item_id.nil? || item_id == 0 || !@db.respond_to?(:item)
      it = @db.item[item_id]
      return [] unless it
      return [] unless [Party::ITEM_SHIELD, Party::ITEM_ARMOR, Party::ITEM_HELMET,
                        Party::ITEM_ACCESSORY].include?(it.type)
      return [] unless it.respond_to?(:reverse_state_effect) && it.reverse_state_effect
      return [] unless it.respond_to?(:state_set) && it.state_set
      ids = []
      it.state_set.each_with_index { |set, i| ids << (i + 1) if set && set != 0 }
      ids
    end

    # Equipping or unequipping RPG2003 cursed armor inflicts or cures every
    # state #cursed_armor_state_ids names for it, matching a reference
    # implementation's own equip-state-adjustment routine (ported from its
    # source, NOT
    # independently confirmed against genuine RPG_RT under wine), called from
    # every equip-mutation path there. #equip_item/#unequip/#equip below each write
    # `@equipment` *before* calling this, the same order that reference
    # implementation
    # itself uses (the equipment array is written before both
    # state-adjustment calls) -- #permanent_states, consulted by
    # #remove_state/#clear_states below, reads `@equipment` live, so
    # unequipping a cursed item has to stop counting it *before* this then
    # tries to cure the very state it inflicted, or the cure would refuse
    # itself.
    def adjust_equipment_states(item_id, add)
      cursed_armor_state_ids(item_id).each do |id|
        if add
          add_state(id, allow_battle_states: false)
          # A reference implementation's own add-state routine runs the
          # crowding-out pass after
          # *every* state it adds, with no caller-side opt-out -- it
          # funnels every infliction path through
          # it uniformly, equipment included: its own
          # equip-state-adjustment routine calls the identical add-state path
          # (ported from that source, NOT independently confirmed
          # against genuine RPG_RT under wine) --
          # `#knock_out!`/#cast_skill's own skill-infliction loop already
          # pairs with a prune call here. A cursed item forcing a
          # high-priority state onto an actor already carrying a
          # low-priority ailment must clear that ailment the instant the
          # cursed state lands, the same as a lethal hit or a landed skill
          # state already does here -- this was the one state-infliction
          # call site in this file that missed pairing #add_state with the
          # prune pass every other one already does.
          @states = Game::States.prune(@states, state_table, keep: permanent_states)
        else
          remove_state(id)
        end
      end
    end

    # The states an actor's currently-equipped cursed armor (see
    # #cursed_armor_state_ids) is forcing on right now, matching a reference
    # implementation's own permanent-states routine (ported from its source, NOT
    # independently confirmed against genuine RPG_RT under wine) -- scanned off
    # every equipment slot the same way its own shield/armor/helmet/
    # accessory readers are there (the weapon slot always reads [] anyway,
    # since #cursed_armor_state_ids excludes the weapon type). #remove_state
    # and #clear_states consult this so the same rule is meant to hold here
    # too: an Antidote, a curative skill, Full Recovery, or the Change
    # Condition event command all fail to cure a state a worn cursed item
    # is still actively forcing -- only taking the armor off actually
    # clears it.
    def permanent_states
      return [] unless rpg2003?
      @equipment.flat_map { |id| cursed_armor_state_ids(id) }.uniq
    end

    # The effective max HP ceiling #recompute_stats clamps against --
    # `MAX_EFFECTIVE_HP_2K3` on an RPG2003 database, `MAX_EFFECTIVE_HP_2K`
    # otherwise.
    def max_hp_cap
      rpg2003? ? MAX_EFFECTIVE_HP_2K3 : MAX_EFFECTIVE_HP_2K
    end

    # Total equipment bonus for stat index `i` (see EQUIP_BONUS_FIELD): the sum
    # over equipped items of that item's bonus field. Always 0 for max HP/MP
    # (index 0/1, `EQUIP_BONUS_FIELD[i]` nil there -- see its own comment): no
    # equipped item ever raises those two, only a consumed Seed does. A
    # database that exposes no item table (the test fixtures) contributes
    # nothing either.
    def equip_bonus(i)
      field = EQUIP_BONUS_FIELD[i]
      return 0 unless field
      return 0 unless @db.respond_to?(:item)
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
    # (100%) at the battle layer. A fixture row without the field, and no
    # resistance gear equipped either, yields {}.
    #
    # Equipped shield/armor/helmet/accessory gear (never a weapon) that flags
    # an attribute in its own `attribute_set` grants a flat +1 to that
    # attribute's defence rank -- ports a reference implementation's own
    # base-attribute-rate routine (NOT independently confirmed against genuine
    # RPG_RT under wine): every matching piece worn
    # is OR'd into a single one-step boost, not stacked per item, clamped at
    # E (4, immune). This is why the boost is baked in here rather than left
    # to the battle layer's own default: an attribute an actor's database row
    # never lists (no explicit rank) still resists once a matching item is
    # equipped, exactly as that routine computes the default rank before
    # ever consulting equipment.
    def attribute_ranks
      ranks = {}
      arr = @db_row.respond_to?(:attribute_ranks) ? @db_row.attribute_ranks : nil
      arr.each_with_index { |v, i| ranks[i + 1] = v } if arr
      defensive_attribute_ids.each do |aid|
        ranks[aid] = [(ranks[aid] || 2) + 1, 4].min
      end
      ranks
    end

    # The attribute ids an equipped shield/armor/helmet/accessory (never a
    # weapon) flags in its own `attribute_set` -- the defensive counterpart of
    # #weapon_attributes, which reads the same field off the weapon slot only,
    # for the opposite (offensive) purpose.
    def defensive_attribute_ids
      ids = []
      return ids unless @db.respond_to?(:item)
      @equipment.each do |iid|
        next if iid.nil? || iid == 0
        it = @db.item[iid]
        next unless it && it.respond_to?(:type) &&
                    [Party::ITEM_SHIELD, Party::ITEM_ARMOR, Party::ITEM_HELMET,
                     Party::ITEM_ACCESSORY].include?(it.type)
        set = it.respond_to?(:attribute_set) ? it.attribute_set : nil
        next unless set
        set.each_index { |i| ids << (i + 1) if set[i] && set[i] != 0 }
      end
      ids.uniq
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

    # The status conditions the actor's equipped weapon(s) carry into a basic
    # Attack -- item fields `state_set` (63/64, a flag per state) and
    # `state_chance` (67, a flat percent applied to every state the weapon
    # flags) -- split by whether the weapon inflicts or (RPG2003 only)
    # *heals* them, per `Game::Battle#deal_attack`'s own use.
    #
    # Ported from a reference implementation's own basic-attack weapon-effect
    # handling, NOT independently confirmed against genuine RPG_RT
    # under wine: a weapon with no `state_chance` (or none flagged in
    # `state_set`) contributes nothing, and a 二刀流 actor's second weapon
    # (`#weapon_attributes`' own `type == 1` filter already reaches the
    # shield slot when it holds a weapon, same as here) can name a *different*
    # state, or the same one at a different chance -- the ported behavior
    # takes the higher chance when both weapons flag the same state, which is
    # what the `< chance` compare below does per state id. `reverse_state_
    # effect` (field 68) flips a weapon's own states from inflicting to
    # curing, but **only on RPG2003** -- on RPG2000 the field has no effect
    # here. This is the one place the item table's `reverse_state_effect`
    # field actually does anything at all: a *medicine*'s identical field
    # (same chunk, same field number, read only when `item.type` is medicine
    # rather than weapon) is dead in the ported behavior, same as
    # #item_cured_states documents.
    #
    # No item table (a fixture) or an unarmed actor carries none of either.
    def weapon_states
      inflict = {}
      heal = {}
      return { inflict: inflict, heal: heal } unless @db.respond_to?(:item)
      heals_flip = rpg2003?
      @equipment.each do |iid|
        next if iid.nil? || iid == 0
        it = @db.item[iid]
        next unless it && it.respond_to?(:type) && it.type == 1 # weapon slot only
        set = it.respond_to?(:state_set) ? it.state_set : nil
        next unless set
        chance = it.respond_to?(:state_chance) ? (it.state_chance || 0) : 0
        next unless chance > 0
        heals = heals_flip && it.respond_to?(:reverse_state_effect) && it.reverse_state_effect
        bucket = heals ? heal : inflict
        set.each_index do |i|
          next unless set[i] && set[i] != 0
          sid = i + 1
          bucket[sid] = chance if (bucket[sid] || 0) < chance
        end
      end
      { inflict: inflict, heal: heal }
    end

    # The strongest defensive resistance the actor's equipped shield / armor /
    # helmet / accessory (never a weapon) offers against state `sid` landing,
    # as a percent multiplier (100 = no resistance). Ports a reference
    # implementation's own state-probability routine (NOT independently confirmed against
    # genuine RPG_RT under wine): an item that
    # flags `sid` in its own `state_set` contributes `100 - state_chance`, and
    # the *lowest* (strongest) contribution across every equipped defensive
    # item wins -- "takes the armor of the character with the most resistance
    # for that particular state", not a sum of every piece worn. An RPG2003
    # item with `reverse_state_effect` set plays no part here (that flag turns
    # a *weapon's* own states into cures, per #weapon_states -- it has no
    # meaning on defensive gear's state_set), matching a reference
    # implementation's own equivalent edition/flag guard (ported from that
    # source, NOT independently confirmed against genuine RPG_RT under wine).
    def state_resist_mul(sid)
      mul = 100
      return mul unless @db.respond_to?(:item)
      is2k3 = rpg2003?
      @equipment.each do |iid|
        next if iid.nil? || iid == 0
        it = @db.item[iid]
        next unless it && it.respond_to?(:type) &&
                    [Party::ITEM_SHIELD, Party::ITEM_ARMOR, Party::ITEM_HELMET,
                     Party::ITEM_ACCESSORY].include?(it.type)
        next if is2k3 && it.respond_to?(:reverse_state_effect) && it.reverse_state_effect
        set = it.respond_to?(:state_set) ? it.state_set : nil
        next unless set && set[sid - 1] && set[sid - 1] != 0
        chance = it.respond_to?(:state_chance) ? (it.state_chance || 0) : 0
        mul = 100 - chance if 100 - chance < mul
      end
      mul
    end

    # The actor's basic-attack base hit rate (percent): the highest `hit` among
    # the equipped weapons (item field 17), or the RPG2000 unarmed default of 90
    # when nothing is equipped or the row omits it. Feeds the battle's to-hit
    # roll. Ported from a reference implementation's source rather than
    # assumed, but NOT independently confirmed against genuine RPG_RT under
    # wine: its own hit-chance routine uses the minimum representable integer
    # as its own "nothing equipped" sentinel, so an equipped weapon whose own `hit`
    # field is a genuine 0 -- a real, intentional "never lands a hit" item, not
    # a missing field -- is returned as-is; only a truly empty weapon slot falls
    # back to 90. A prior version of this method instead folded that
    # found-but-zero case into the nothing-found one (`best && best > 0 ? best
    # : 90`), silently treating a 0%-hit weapon as if it were unequipped.
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
      best.nil? ? 90 : best
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

    # 二刀流 — a weapon flag genuine RPG_RT reads, but which does NOT by
    # itself make a lone equipped copy swing twice: confirmed by an actual
    # wine capture (2026-09-05, see #strike_count's own citation) with both
    # a custom probe weapon and Nepheshel's own real dual_attack weapon
    # (item 36, サクリファイス) equipped solo -- a plain basic Attack logged
    # exactly one damage line, in the same ~19-29 band a non-dual_attack
    # control weapon of matching stats produced, never a second line or a
    # roughly-doubled total. Kept readable (`#strike_count`'s own two-weapon
    # branch below still reads it) since a solo equip's own null effect
    # does not by itself say what a *second* equipped weapon's own flag
    # does.
    def dual_attack?; equipment_flag?(:dual_attack, true); end

    # A basic Attack's total swing count. A solo weapon's own #dual_attack?
    # does not double it -- confirmed by an actual wine capture (2026-09-05):
    # both a custom 100%-hit probe weapon and Nepheshel's own real
    # dual_attack weapon (item 36, サクリファイス, hit 100) equipped alone
    # against a passive, durable enemy logged exactly one
    # "Xに Yのダメージを与えた!" line per Attack command, in the same band a
    # matching non-dual_attack control weapon produced (27-29 vs 19-29) --
    # never a second line, and never roughly double the total. A
    # `#double_hand?` actor with a weapon in *both* the weapon and shield
    # slots is a genuinely different, NOT independently confirmed case: a
    # wine capture of a double_hand leader with the same real dual_attack
    # weapon in both slots logged a higher total (48) in a single line, not
    # two -- consistent with either two summed rolls or an entirely
    # different combined-damage formula, so that branch (ported from a
    # reference implementation's battle-algorithm init routine, sums each
    # weapon's own hit count -- RPG2003's dual-wield "multi-hit" style
    # whenever both equipped slots hold a real weapon, rather than taking
    # the higher of the two the way that reference implementation's
    # ordinary single-weapon max does) is left untouched pending further
    # wine work, not assumed correct.
    #
    # A follow-up capture (2026-09-05) muddies this further rather than
    # settling it: two custom, non-dual_attack, 100%-hit weapons (atk_points1
    # 100 each -- deliberately identical, like the original real-weapon
    # capture, so a "combine both weapons' atk into one swing" reading
    # predicts roughly double a solo swing's damage) equipped double_hand
    # against a passive enemy whose HP was set to exactly 75 -- comfortably
    # above a solo/unboosted swing's own top end (a 100-atk, 0-defence swing
    # varies roughly 30-70) but below a doubled-atk swing's own bottom end
    # (roughly 60-140) -- survived that first swing outright. That single
    # result leans toward "no boost" (consistent with a plain solo-band
    # roll, only weakly consistent with a doubled one, which would have
    # killed it about four times in five), the opposite lean from the
    # original identical-weapon capture's own higher (48) total. Neither
    # capture is more than one data point, and re-entering a second battle
    # in the same wine session to gather more (this same fixture, walking
    # back onto the encounter tile after the first fight ended) hung
    # indefinitely on the battle-transition screen and then exited with no
    # crash trace -- a repeat of this session's own established "re-
    # triggering an encounter mid-session is unreliable under wine" finding,
    # not a new data point about the formula itself. Still left untouched
    # pending further wine work: if anything, less settled now than before.
    def strike_count
      weapons = equipped_weapons
      return weapon_attack_multiplier(weapons.first) unless weapons.size >= 2
      weapons[0, 2].reduce(0) do |s, it|
        s + (it.respond_to?(:dual_attack) && it.dual_attack ? 2 : 1) * weapon_attack_multiplier(it)
      end
    end

    # The RPG2003-only 攻撃の回数 (Number of Attacks) multiplier `it` (an
    # equipped weapon, or nil when unarmed) contributes to this actor's own
    # basic-attack swing count -- ported from a reference implementation's
    # number-of-attacks routine,
    # NOT independently confirmed against genuine RPG_RT under wine:
    # an RPG2003 check gates a lookup into the weapon's
    # own per-actor Battle Animation table (`weapon.animation_data`, this
    # schema's `attack_times` field on each row, keyed by actor id) and
    # multiplies the swing count by `cba[actor_id - 1].attacks + 1` when this
    # actor has a row there. RPG2000 has no such table at all, and a weapon
    # naming no row for this actor (or no table at all) contributes no
    # multiplier -- both read as the neutral `1`, matching a project that
    # never touched the Battle Animation tab.
    def weapon_attack_multiplier(it)
      return 1 unless it && rpg2003?
      table = it.respond_to?(:animation_data) ? it.animation_data : nil
      row = table ? table[id] : nil
      row && row.respond_to?(:attack_times) ? (row.attack_times || 0) + 1 : 1
    end

    # The equipped weapon-type items, in slot order (the weapon slot first,
    # then the shield slot if it holds a weapon rather than a shield -- only
    # possible for a `#double_hand?` actor). Shared by `#strike_count` and
    # `#swing_weapon_data`.
    def equipped_weapons
      return [] unless @db.respond_to?(:item)
      @equipment.map { |iid| iid && iid != 0 ? @db.item[iid] : nil }
               .select { |it| it && it.respond_to?(:type) && it.type == ITEM_WEAPON }
    end

    # Which weapon governs swing index `i` (0-based) of a two-weapon actor's
    # basic Attack -- ported from a reference implementation's per-swing
    # weapon-selection logic,
    # NOT independently confirmed against genuine RPG_RT under wine:
    # it only picks a specific
    # slot per swing under the RPG2003 dual-weapon "multi-hit" battle style
    # -- RPG2000 (and an RPG2003
    # game running the legacy 2k battle system) instead combines both
    # weapons, so *every* swing reads the merged max/union
    # hit chance/etc. across both weapons, never one weapon's own data.
    # So this per-swing split only applies to RPG2003; nil for a non-2003
    # actor falls back to the ordinary merged Combatant fields, which is
    # correct there regardless of how many weapons are equipped.
    def swing_weapon_data(i)
      return nil unless rpg2003?
      weapons = equipped_weapons
      return nil unless weapons.size >= 2
      w1, w2 = weapons[0, 2]
      w1_hits = (w1.respond_to?(:dual_attack) && w1.dual_attack ? 2 : 1) * weapon_attack_multiplier(w1)
      weapon_roll_data(i < w1_hits ? w1 : w2)
    end

    # The hit rate / elemental attributes / weapon states / crit chance a
    # single equipped weapon item contributes on its own -- what
    # `#swing_weapon_data` hands a specific weapon-governed swing, as
    # opposed to `#attack_hit_rate`/`#weapon_attributes`/`#weapon_states`/
    # `#crit_chance`'s own merge across every equipped weapon-type item.
    #
    # Same sentinel distinction `#attack_hit_rate`'s own citation makes: a
    # reference implementation's hit-chance sentinel only ever
    # falls back to 90 when the queried slot holds no weapon at all --
    # the per-weapon call here visits exactly one item,
    # so a genuine `hit == 0` on it (an intentionally "never lands" weapon)
    # must return 0 as-is, not fold into the nothing-equipped default. `it`
    # is always a real equipped weapon by the time it reaches here (`#swing_
    # weapon_data`'s own `weapons.size >= 2` guard), so the only "absent"
    # case left is a row with no `hit` field at all.
    def weapon_roll_data(it)
      h = it.respond_to?(:hit) ? it.hit : nil
      hit = h.nil? ? 90 : h
      attrs = []
      set = it.respond_to?(:attribute_set) ? it.attribute_set : nil
      set.each_with_index { |on, i| attrs << (i + 1) if on } if set
      inflict = {}
      heal = {}
      sset = it.respond_to?(:state_set) ? it.state_set : nil
      chance = it.respond_to?(:state_chance) ? (it.state_chance || 0) : 0
      if sset && chance > 0
        heals = rpg2003? && it.respond_to?(:reverse_state_effect) && it.reverse_state_effect
        bucket = heals ? heal : inflict
        sset.each_index { |i| bucket[i + 1] = chance if sset[i] && sset[i] != 0 }
      end
      crit = it.respond_to?(:critical_hit) ? (it.critical_hit || 0) : 0
      { hit_rate: hit, atk_attrs: attrs, atk_states: { inflict: inflict, heal: heal },
        crit_chance: weapon_crit_chance(crit) }
    end

    # 必中 — an equipped weapon whose attack cannot be evaded. Ported from
    # a reference implementation's own to-hit calculation; confirmed against
    # genuine RPG_RT under wine, 2026-09-05: a hand-authored hit-90 weapon
    # against an agi-999 target (whose evasion alone clamps #to_hit's own
    # agi_adjusted formula to ~0%) landed 0 of 5 attacks without this flag
    # and 2 of 3 with it -- it returns before it applies the agility /
    # evasion term for such a weapon, exactly as ported. 13 of Nepheshel's
    # weapons carry it.
    def ignores_evasion?; equipment_flag?(:ignore_evasion, true); end

    # 全体化 — an equipped weapon whose own flag genuine RPG_RT reads (see
    # Game::Battle#strike), but does NOT actually spread a basic Attack
    # across every living member of the target's side: confirmed by an
    # actual wine capture (2026-09-05) that a reference implementation's own
    # "attack all enemies regardless of original targeting" claim does not
    # hold for genuine RPG_RT.exe, matching the already-confirmed
    # forced-restriction case (a berserk/confused attacker with this same
    # flag also only ever hits the one forced target). See #strike's own
    # citation for the fixture details.
    def attack_all?; equipment_flag?(:attack_all, true); end

    # 先制攻撃 — an equipped weapon that jumps its wielder's basic Attack to
    # the front of the round's turn order. Ported from a reference
    # implementation's own preemptive-attack / execution-order handling, NOT
    # independently confirmed against genuine RPG_RT under wine: it adds
    # 9999 to the battler's computed order for exactly this case —
    # effectively always first, since ordinary agility values never approach
    # that. Only a basic Attack earns the jump; a Skill, Item or Defend with
    # the same weapon still equipped keeps its ordinary agility slot,
    # matching that ported basic-attack-only guard.
    def preemptive?; equipment_flag?(:preemptive, true); end

    # MP消費半分 — gear that halves what a skill costs to cast. Any slot, not just
    # the weapon (Nepheshel's 賢者の指輪 is an accessory).
    def half_sp_cost?; equipment_flag?(:half_sp_cost); end

    # The SP a basic Attack itself costs -- ported from a reference
    # implementation's own weapon-SP-cost routine, which
    # it spends unconditionally
    # once per action, before
    # any swing resolves -- not per swing, so a 二刀流 weapon's extra hit
    # (`#strike_count`) never doubles the bill. Confirmed against genuine
    # RPG_RT under wine (2026-09-05): a solo actor with max_mp/mp forced to
    # exactly 20 and a custom weapon whose own sp_cost field was set to 20
    # had mp read exactly 0 off the status panel immediately after a single
    # basic Attack (90% weapon hit, so the swing may or may not have
    # actually landed on its enemy target -- the deduction did not wait to
    # find out either way). The weapon there is whichever
    # slot governs the action's very first swing: the weapon-slot item alone
    # for a `#double_hand?` two-weapon actor (this engine's only route to a
    # real per-swing weapon split, since ordinary single-weapon gear always
    # combines both slots, which reduces to that one weapon's own cost anyway) --
    # `#equipped_weapons`' own weapon-slot-first ordering, so `.first` is
    # always the right item either way. Halved (rounding up, matching
    # `#skill_cost`'s own fixed-cost branch) by the same MP消費半分 gear. 0 for
    # an unarmed actor.
    def weapon_sp_cost
      it = equipped_weapons.first
      return 0 unless it
      cost = it.respond_to?(:sp_cost) ? (it.sp_cost || 0) : 0
      half_sp_cost? ? (cost + 1) / 2 : cost
    end

    # 地形ダメージ無効 — gear that makes its wearer immune to the damage a tile's
    # terrain deals as they walk over it (Party#apply_terrain_damage). Any slot:
    # mtf-meido-action's is a pair of boots, Nepheshel's four include a swimsuit.
    def prevents_terrain_damage?; equipment_flag?(:no_terrain_damage); end

    # 物理回避率アップ — a shield/armour/helmet/accessory that makes a normal
    # attack likelier to miss its wearer: ported from a reference
    # implementation's own physical-evasion-up check, consulted right after
    # its AGI term in the to-hit calculation. Confirmed by an actual wine
    # capture (2026-09-05, see Game::Battle#to_hit's own citation) — the
    # ported behavior subtracts a flat 25 from the attacker's already
    # agi-adjusted hit chance. The weapon slot never counts — that check there
    # excludes weapons by item *type*, not slot index, the same
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
    # rather than a half, per a reference implementation's own
    # defend-damage-adjustment routine, ported from its
    # source and NOT independently confirmed against genuine RPG_RT under
    # wine). This one is a
    # property of the actor row (field 24), not of gear, and an RPG2003 class can
    # override it the way it overrides the growth curves -- but, like the growth
    # curves themselves (#curve_row), only once an actual Change Class event has
    # run: that reference implementation's class-change routine is where
    # this trait is copied in from the class row; the
    # constructor seeds it from the actor's own database row and never consults a
    # class row at all, so a class merely named on the actor's own row is inert
    # for this trait too until Change Class actually fires.
    def strong_defence?
      row = @class_row if @class_changed && @class_id && @class_id > 0
      row ||= @db_row
      row.respond_to?(:strong_defence) ? (row.strong_defence ? true : false) : false
    end

    # 強制AI — an actor (or RPG2003 class) permanently under AI control in
    # battle: the ordinary Attack/Skill/Defend/Item command menu never opens
    # for them, and the engine picks their action automatically every round
    # the same way an enemy's own 行動パターン does. Same class-row-then-
    # player-row lookup as #strong_defence?/#double_hand? (liblcf's `job`
    # table carries the same field id, 23) — parsed by the schema
    # (`mruby-lcf/mrblib/schema.rb`, `player`/`job` field 23, `force_ai`) but
    # never read anywhere in `mruby-rpg2k` before this fix. Ported from
    # a reference implementation's source rather than guessed at, but NOT independently
    # confirmed against genuine RPG_RT under wine:
    # its auto-battle reader is a bare
    # passthrough, seeded from the actor's own database row (or
    # the class row once a class overrides it) —
    # the identical row-then-class precedence this reader already follows for
    # every other actor/class-overridable trait, and, like every one of them
    # (#strong_defence?/#curve_row), only "once a class overrides it" via an
    # actual Change Class event -- the flag is seeded from
    # the database row at construction and only overwritten
    # inside the class-change routine itself, never merely because the
    # actor's own row names a starting class. That reference implementation's own
    # actor-selection routine checks it right after
    # the can-act/forced-restriction gates and, if set, calls the default
    # auto-battle algorithm instead of ever opening
    # the manual command menu — see `Game::Battle#choose_auto_battle_command`,
    # this codebase's own port of that same algorithm, the one real,
    # un-patched RPG_RT always runs.
    def force_ai?
      row = @class_row if @class_changed && @class_id && @class_id > 0
      row ||= @db_row
      row.respond_to?(:force_ai) ? (row.force_ai ? true : false) : false
    end

    # 二刀流 — an actor (or RPG2003 class) trait that turns the *shield* slot
    # into a *second weapon* slot, unlike the item-row #dual_attack? above (a
    # weapon that makes one basic attack swing twice — an unrelated flag that
    # happens to share the same Japanese name). Same class-row-then-player-row
    # lookup as #strong_defence?, since RPG2003 lets a class override it too
    # (liblcf's `job` table carries the same field id). A reference
    # implementation's own equip-item window retargets the whole shield slot to weapon before
    # listing candidates for such an actor, and rejects a shield there
    # outright — #equip_candidates does the retargeting; #attack_hit_rate,
    # #weapon_crit_bonus and #equipment_flag?'s weapon-only search already
    # scan every equipped slot for an item whose own *type* is a weapon rather
    # than hard-coding slot 0, so once a second weapon sits in the shield slot
    # they pick it up (and the better of the two) with no change of their own.
    # Like every other class-overridable trait here, inert until an actual
    # Change Class event runs (this trait is copied in from the class row
    # only inside the class-change routine, never merely because the actor's
    # own row names a starting class) -- see #curve_row.
    def double_hand?
      row = @class_row if @class_changed && @class_id && @class_id > 0
      row ||= @db_row
      row.respond_to?(:double_hand) ? (row.double_hand ? true : false) : false
    end

    # 装備固定 — an actor (or RPG2003 class) whose equipment cannot be changed
    # from the field, whether because the actor/class row itself is locked or
    # because a currently-inflicted state carries RPG2003's own 呪い/cursed flag
    # (situation/state field 38, `cursed` -- #state_cursed? below) for as long
    # as it lasts. Same class-row-then-player-row lookup as #strong_defence?
    # / #double_hand? for the row half (liblcf's `job` table carries the same
    # field id, 22). Ported from a reference implementation's source
    # rather than left unbuilt, but NOT independently confirmed against
    # genuine RPG_RT under wine: its equipment-fixed check is
    # the lock-equipment flag or-ed with (when checking states) any inflicted
    # state's own cursed flag, and the single caller this class
    # matters for, its own equip-menu remove-check --
    # which runs right before opening a slot's item list, refusing to even open
    # it rather than opening it and rejecting a choice, the exact point
    # `Scene::EquipMenu#update_slots` gates below -- always checks
    # states too, so both halves belong in this one predicate; the
    # state-curse half used to have "no test-bed evidence in either game...
    # left unbuilt rather than guessed at" here, now settled straight off that
    # source instead of left unread. RPG_RT's Change Equipment event command
    # still forces past both halves either way (a reference implementation's
    # own equip-change handling never consults this method at all), so
    # nothing in `Game::Party` reads
    # this -- the bag-swapping methods stay usable for a caller that already
    # knows better, the same way they do not re-check `menu_access`. The
    # class half is, like every other class-overridable trait here, inert
    # until an actual Change Class event runs (`data.lock_equipment` is
    # copied in from `cls->lock_equipment` only inside `ChangeClass`, never
    # merely because the actor's own row names a starting class) -- see
    # #curve_row.
    def equipment_fixed?
      row = @class_row if @class_changed && @class_id && @class_id > 0
      row ||= @db_row
      return true if row.respond_to?(:equipment_fixed) && row.equipment_fixed
      state_cursed?
    end

    # Whether any state currently inflicting the actor carries RPG2003's own
    # `cursed` flag (situation/state field 38) -- see #equipment_fixed?, the
    # only reader. Unlike #slot_cursed? below (a property of the item worn in
    # a slot) this is a property of the actor's own affliction list, so it is
    # read fresh from `@states` every call rather than cached, the same way
    # #state? is.
    def state_cursed?
      return false unless @db.respond_to?(:situation) && @db.situation
      @states.any? do |sid|
        d = @db.situation[sid]
        d && d.respond_to?(:cursed) && d.cursed
      end
    end

    # 呪われた装備 -- an item flagged `cursed` (item field 29, alongside the other
    # armour-property flags) refuses to leave the slot it is worn in: RPG_RT's
    # equip menu will not remove or replace it. Unlike #equipment_fixed? above
    # this is a property of the *item currently sitting in the slot*, not of
    # the actor, so it is read fresh from whatever `slot` holds rather than
    # cached. Same split as #equipment_fixed?: RPG_RT's Change Equipment event
    # command still forces it off, ported from a reference implementation's
    # own equip-change handling (not independently confirmed against genuine
    # RPG_RT under wine) which does not consult the flag either, so only the
    # equip menu gates on this -- Game
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
      Array.new(EQUIP_ORDER.size) { |i| ids[i] || 0 }
    end

    # Total EXP ceiling: 999_999 on an RPG2000 database, 9_999_999 on RPG2003
    # (ported from a reference implementation's own max-EXP-value constant,
    # NOT independently
    # confirmed against genuine RPG_RT under wine -- the same
    # edition split `#max_hp_cap`/`MAX_EFFECTIVE_HP_2K`/`_2K3` above already
    # applies to HP). The EXP-curve fields default to 30 when a database row
    # does not carry them (e.g. a test fixture).
    EXP_MAX_2K = 999_999
    EXP_MAX_2K3 = 9_999_999
    EXP_DEFAULT = 30

    # The effective total-EXP ceiling -- `EXP_MAX_2K3` on an RPG2003
    # database, `EXP_MAX_2K` otherwise. Mirrors `#max_hp_cap` exactly.
    def exp_max
      rpg2003? ? EXP_MAX_2K3 : EXP_MAX_2K
    end

    # The actor's maximum level (from the database row; 50 by RPG2000 default).
    def max_level
      ml = @db_row.respond_to?(:max_level) ? @db_row.max_level : nil
      ml && ml >= 1 ? ml : 50
    end

    # Total EXP required to *be at* `level` (0 at level 1), computed from the
    # row's exp_basic / exp_increase / exp_correction through the edition's
    # own curve (#calc_exp) — a direct port of a reference implementation's
    # own EXP-curve calculation for the previous level, NOT independently
    # confirmed against genuine RPG_RT under wine.
    def exp_for_level(level)
      return 0 if level <= 1
      calc_exp(level - 1)
    end

    # Set total EXP (clamped to 0..#exp_max) and re-derive the level from the
    # curve thresholds, recomputing the base stats via #set_level when the level
    # changes. Mirrors a reference implementation's own change-EXP routine
    # (NOT independently confirmed against genuine RPG_RT under wine):
    # raising EXP climbs while
    # the next level's threshold is reached; lowering it drops while below the
    # current level's threshold.
    def set_exp(new_exp)
      new_exp = Game.clamp(new_exp, 0, exp_max)
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
    # stats via #set_level and re-aligns EXP to the new level, mirroring a
    # reference implementation's own change-level routine (NOT independently
    # confirmed against genuine RPG_RT under wine): on a level up EXP rises to at least the new level's threshold;
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
        nxt = new_level < max_level ? exp_for_level(new_level + 1) : exp_max + 1
        @exp = base if @exp >= nxt
      end
    end

    # Apply a HP change (positive heals, negative damages), clamped to
    # [floor, max_hp]. The floor is 0 when death is allowed (the actor may be
    # knocked out) or 1 otherwise, matching RPG2000's Change HP "allow death"
    # flag. Reaching 0 with death allowed inflicts the death state (戦闘不能).
    # A downed actor is unaffected -- HP changes cannot revive it (that needs the
    # death state cured / Full Recovery), matching a reference implementation's
    # own change-HP routine (NOT independently confirmed against genuine
    # RPG_RT under wine). Returns the
    # new HP.
    def change_hp(delta, allow_death = true)
      return @hp if dead?
      floor = allow_death ? 0 : 1
      @hp = Game.clamp(@hp + delta, floor, @max_hp)
      knock_out! if @hp <= 0
      @hp
    end

    # The actor's critical-hit chance as a whole percent (0 = never): the row's
    # own 1-in-`critical_rate` rate, gated by `has_critical_rate`, **plus** the
    # equipped weapon's `critical_hit` percentage. Ported from a reference
    # implementation's source, NOT independently confirmed against genuine RPG_RT under wine:
    # the two are added together, which is why this is a percentage rather
    # than the 1-in-N denominator it used to be -- there is no denominator
    # that expresses "1/30 and 20% more".
    #
    # A whole percent, truncated, not a finer-grained probability: a
    # reference implementation's own critical-hit-chance routine sums the base rate and weapon bonus as
    # a float, and its one caller
    # immediately truncates that float to an integer percent -- the ported behavior throws away
    # everything past the first digit before ever rolling, rather than
    # preserving it. A previous version of this method kept the fraction
    # (basis points over 10000, so a 1/30 row read 333 rather than truncating
    # to a flat 3) on the theory that no integer percent could add a weapon's
    # bonus onto a 1-in-N rate cleanly -- true, but the ported source doesn't
    # attempt that either: it truncates the *sum*, not the base rate alone,
    # which lands on the same whole percent this method now computes directly
    # (`(100.0/n).to_i + bonus`, exactly equal to `((1.0/n + bonus/100.0) *
    # 100).to_i` since the bonus is already an integer). Keeping the
    # finer-grained probability made every critical roll land measurably more
    # often than this ported reference for almost any rate -- a plain 1-in-30
    # actor crit 3.33% of the time here against the reference's flat 3%, an
    # eleven percent relative inflation (this comparison is against that
    # reference implementation's own source, not a genuine RPG_RT measurement).
    def crit_chance
      weapon_crit_chance(weapon_crit_bonus)
    end

    # `#crit_chance`'s own bonus-plus-base-rate formula, but taking the
    # weapon bonus as a parameter rather than always `#weapon_crit_bonus`'s
    # merged max -- shared with `#weapon_roll_data`, which needs the same
    # composition for one specific weapon's own `critical_hit` bonus.
    def weapon_crit_chance(bonus)
      pct = bonus
      if @db_row.respond_to?(:has_critical_rate) && @db_row.has_critical_rate
        n = @db_row.respond_to?(:critical_rate) ? @db_row.critical_rate : 0
        pct += (100.0 / n).to_i if n && n > 0
      end
      pct
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
        knock_out!
      else
        remove_state(DEATH_STATE)
      end
      @hp
    end

    # Inflict the death state and immediately apply the same crowding-out
    # rule a reference implementation's own add-state routine runs (ported
    # from its source, NOT
    # independently confirmed against genuine RPG_RT under wine -- it applies
    # this same pass after *every* state it adds, not just Death) -- a
    # lethal hit does not merely add Death alongside whatever ailments the
    # actor already carried, it also clears any of them 10+ priority below
    # Death's own configured priority, the same instant Death lands. Shared
    # by #change_hp and #set_hp, RPG2000's two HP-changing entry points that
    # can inflict it (a raw #add_state elsewhere is never followed by this on
    # its own -- see #cast_skill/#roll_inflict/#roll_weapon_states, which
    # already call #Game::States.prune themselves right after inflicting a
    # non-death state, the identical rule from the other direction).
    def knock_out!
      add_state(DEATH_STATE)
      @states = Game::States.prune(@states, state_table, keep: permanent_states)
    end

    # The database's state (`situation`) table, for Game::States lookups.
    # nil for a fixture without one, which every Game::States accessor
    # already tolerates.
    def state_table
      @db.respond_to?(:situation) ? @db.situation : nil
    end

    # Apply a MP (SP) change, clamped to [0, max_mp]. Returns the new MP.
    def change_mp(delta)
      @mp = Game.clamp(@mp + delta, 0, @max_mp)
    end

    # Restore HP and MP to their maxima and cure every status condition
    # (RPG2000 Full Recovery). Then re-inflicts every #permanent_states id --
    # ported from a reference implementation's own full-heal routine, NOT independently
    # confirmed against genuine RPG_RT under wine: it is
    # remove all states, restore HP/MP to max, then
    # reset equipment states, and that trailing call (that reference
    # implementation's own
    # source comment claims: "Emulates RPG_RT behavior of resetting even
    # battle equipment states on
    # full heal") walks every equipped slot and unconditionally re-inflicts
    # each state a worn RPG2003 cursed item forces, regardless of whether it
    # was already present. `#clear_states` alone (mirroring that
    # remove-all-states routine)
    # can only ever *keep* an id already in `@states`, never re-add a missing
    # one -- so a state a map-side Change Condition had already lifted via
    # its own `always_remove_battle_states` exemption (still cursed-armor
    # locked in every other cure path) stayed gone through a Full Recovery
    # too, until now, diverging from this ported unconditional re-inflict
    # behavior.
    def full_heal
      @hp = @max_hp
      @mp = @max_mp
      clear_states
      permanent_states.each { |id| add_state(id) }
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
    # ~~yado.tk's `2000/デフォ戦botまとめ`: the displayed/effective stat clamps
    # to that range, but RPG_RT keeps accumulating the *unclamped* running
    # total underneath -- lower Attack far past 1 with one call, then raise
    # it back only part way, and the effective value stays pinned at the old
    # clamp until the raw total genuinely climbs back past it, rather than
    # reacting to the partial raise immediately.~~ This turned out to be
    # backwards -- ported from a reference implementation's source, NOT independently
    # confirmed against genuine RPG_RT under wine:
    # its base-Attack/Defence/Spirit/Agility setters
    # each clamp the *modifier itself* --
    # a shadow entirely separate from the level curve
    # -- to +/-999, on every single
    # call, before the base-stat getter ever adds the curve and equipment and clamps
    # the combined total again to `1..999`; the base-max-HP/max-SP setters
    # clamp their own modifiers the same way. So a deep debuff can never bank more magnitude in the
    # modifier than its own +/-999 ceiling, and a partial recovery afterward
    # reflects immediately once the (already-bounded) modifier crosses back
    # over the curve's own threshold -- it never has to "climb back" through
    # however deep the original delta was. `@base_raw` (curve + modifier, no
    # equipment -- see `#set_level`'s own `preserve_mod` diff) is this
    # codebase's combined shadow; `@base_raw[type] - base_stats(@level)[type]`
    # is the isolated modifier #set_level already computes this exact way,
    # clamped here to `+/-base_param_limit(type)` before being added back
    # onto the curve, matching `ClampStatMod`'s bound (the same ceiling
    # `#base_param_limit` already uses for the *displayed* clamp, since the
    # HP/MP edition-cap mismatch documented above this method already covers
    # why the two ceilings aren't perfectly split by edition here). `@base`
    # (read by #recompute_stats and everything else) stays the clamped,
    # display/effective value throughout.
    def change_param(type, delta)
      return unless type >= 0 && type < STAT_NAMES.size
      limit = base_param_limit(type)
      curve = base_stats(@level)[type]
      mod = Game.clamp(@base_raw[type] - curve + delta, -limit, limit)
      @base_raw[type] = curve + mod
      @base[type] = Game.clamp(@base_raw[type], 1, limit)
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
      @base = Array.new(@base_raw.size) { |i| Game.clamp(@base_raw[i], 1, base_param_limit(i)) }
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

    # Change Class (event command 1008). Ported from a reference
    # implementation's own change-class routine (NOT independently confirmed
    # against genuine RPG_RT under wine), which is where the order of operations comes from:
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
    # database does not define, which RPG_RT leaves entirely alone. A
    # database shrink deleting a class (chunk 30) an event still references
    # -- shown as "?" in the editor -- is now reported too, rather than
    # silently no-opping with no trace: docs/TODO.md's runtime error catalog
    # lists this exact shape for hero/skill/item/enemy/enemy-group/battle-
    # animation/terrain/chipset/common-event ids, but never named "class" as
    # one of them. `respond_to?`-guarded the same way those are, so a bare
    # test fixture (or any RPG2000 database, which carries no job table at
    # all) stays quiet -- this only fires for a genuine dangling id in a
    # database that does have one.
    def change_class(class_id, new_level, skill_mode, param_mode)
      if class_id > 0 && class_row_for(class_id).nil?
        if @db.respond_to?(:job) && @db.job
          $stderr.puts "[RPG2k] Change Class: class ##{class_id} not found " \
                       'in database, actor left unchanged'
        end
        return false
      end

      unequip(EQUIP_ORDER.size)
      hp = @hp
      mp = @mp
      old_base = @base.dup
      old_skills = @skills.dup

      set_class_id(class_id)
      # Mirrors a reference implementation's own battler-animation
      # assignment (class found) / reset to 0 (class removed) inside its
      # change-class routine itself --
      # see #battler_animation_id, and the comment on the ivars in #initialize
      # for why this is a separate flag from `@class_id`.
      @class_changed = true
      @battler_animation_override =
        @class_row && @class_row.respond_to?(:battler_animation) ? (@class_row.battler_animation || 0) : 0
      # preserve_mod: false -- Change Class always zeroes the Change
      # Parameters mod shadow before applying the new class's own curve
      # (a reference implementation's own change-class routine zeroes the
      # stat-modifier shadow unconditionally,
      # before the param_mode switch below ever runs), unlike an ordinary
      # level change, which #set_level's default carries the mod through.
      set_level(Game.clamp(new_level || 1, 1, max_level), preserve_mod: false)
      @battle_commands = class_battle_commands
      @exp = exp_for_level(@level)

      case param_mode
      when CLASS_PARAM_NO_CHANGE then @base = old_base
      when CLASS_PARAM_HALF      then @base = old_base.map { |v| v / 2 }
      when CLASS_PARAM_RESET_LV1 then @base = base_stats(1)
      end
      # Whichever branch (or none, for CLASS_PARAM_RESET_LEVEL, which keeps
      # set_level's own zero-mod curve value) ran, @base is a fresh baseline
      # -- reset #change_param's unclamped shadow to match.
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

    # `BattleCommand#type` (database chunk 0x1D, field 2) -- the kind of
    # action a database-wide Battle Command entry performs. A positive id in
    # `#battle_commands` refers to one of these by index; 0 (Row) and -1
    # (an empty slot) never do, and are never looked up here.
    BATTLE_COMMAND_ATTACK   = 0
    BATTLE_COMMAND_SKILL    = 1
    BATTLE_COMMAND_SUBSKILL = 2 # a single named skill, used as its own shortcut command
    BATTLE_COMMAND_DEFENSE  = 3
    BATTLE_COMMAND_ITEM     = 4
    BATTLE_COMMAND_ESCAPE   = 5
    BATTLE_COMMAND_SPECIAL  = 6

    # The database-wide Battle Command entry `cmd_id` (a positive value from
    # `#battle_commands`) refers to -- an object with `#name` and `#type`, the
    # RPG2003 database table `#battle_commands`' own ids index into. nil when
    # this database carries no such table at all (every RPG2000 file, and any
    # fixture that predates this chunk) or `cmd_id` names no entry in it.
    def battle_command_row(cmd_id)
      return nil unless @db.respond_to?(:battlecommands)
      table = @db.battlecommands
      return nil unless table
      cmds = table.commands
      cmds && cmds[cmd_id]
    end

    # Change Battle Commands (event command 1009). `add` inserts command `id`
    # ahead of the Row entry; otherwise it is removed, and id 0 clears the whole
    # list back to Row alone. Ported from a reference implementation's own
    # change-battle-commands routine (NOT independently confirmed against
    # genuine RPG_RT under wine), including its capacity rule: the list
    # holds at most six real commands plus Row, so a seventh add is dropped.
    #
    # An add also validates `id` against the database-wide Battle Commands
    # table first -- that reference implementation's own source validates the
    # id against the table and warns and bails out when it names no entry,
    # entirely before the capacity/duplicate checks. An id the
    # table doesn't define never occupies a slot, unlike this port's own
    # earlier version, which only checked `id > 0` and let any positive
    # integer through -- a handful of bogus adds could silently exhaust the
    # six-slot capacity, starving a later, genuinely valid add of a slot it
    # should have had. Reusing #battle_command_row (already the exact
    # existence check this needs) also makes the *add* branch inert on a
    # genuine RPG2000 database with no `battlecommands` table at all --
    # ~~matching a reference implementation's own gate on the real event
    # command, which #do_change_battle_commands does not separately
    # enforce~~ not true of the "clear to Row alone" branch below (`id ==
    # 0`, `add` false), which has no table lookup of its own and still
    # clears the list even without one; #do_change_battle_commands now
    # carries the real RPG2k3-commands gate itself instead.
    def change_battle_commands(add, id)
      cmds = battle_commands
      if add
        return if id.nil? || id <= 0 || cmds.include?(id) || !battle_command_row(id)
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
    # the save and must not be reset here. `@class_changed` is set the same
    # way #change_class itself sets it -- a restored non-default class is, by
    # definition, one a live Change Class already changed at some point in the
    # session that got saved, so #battler_animation_id's own "only once
    # Change Class has actually run" gate must see it as changed too.
    #
    # `preserve_mod: false`, matching #change_class's own call: #set_level's
    # default carries the *previous* base_raw forward as a delta from the
    # *new* class's curve, which is exactly backwards here -- it would
    # reproduce the pre-restore (wrong-class) numbers verbatim rather than
    # the new class's own baseline. The caller (Party#load_state /
    # State.from_lsd) re-applies the actual saved base_raw afterward
    # regardless, via #restore_base -- this only has to leave a sane
    # intermediate value for a caller that has none to restore.
    def restore_class(id)
      set_class_id(id)
      # Must be set before #set_level runs: #curve_row now reads it to decide
      # whether the class row is live at all, and #set_level's own
      # #base_stats call goes through #curve_row to rescale at the restored
      # level -- setting this after would compute the restored level's stats
      # off the actor's own row instead of the just-restored class's.
      @class_changed = true
      set_level(@level, preserve_mod: false)
      @battle_commands = nil
    end

    # Whether a Change Class (or a restored one, see #restore_class) has ever
    # run this session -- a reference implementation's own distinction
    # between an actor's
    # database-declared starting class and one actually switched at runtime
    # (see #battler_animation_id's citation of that reference
    # implementation's change-class comment). Exposed for #to_lsd, which only needs to persist a class
    # override that is genuinely a change, not every actor's inert starting
    # class id.
    def class_changed?; @class_changed; end

    # This actor's current RPG2003 battle row (ROW_FRONT / ROW_BACK), read by
    # Combatant.from_actor when a fight starts and written by the in-battle
    # Row command / a restored save.
    def battle_row; @row; end
    def battle_row=(row); @row = row == ROW_BACK ? ROW_BACK : ROW_FRONT; end

    # This actor's RPG2003 active-time (gauge) battle charge (0..
    # Battle::GAUGE_MAX), read by Combatant.from_actor when a fight starts and
    # written back by Battle#apply_to_party when it ends -- the same
    # persist-across-fights shape #battle_row already has, for a different,
    # RPG2003-gauge-presentation-only field. Ported from a reference
    # implementation's own
    # reset-battle routine, NOT independently confirmed against
    # genuine RPG_RT under wine -- it explicitly does
    # *not* reset the gauge, with a source comment claiming: "ATB gauge is
    # not reset here. This is on purpose
    # because RPG_RT will freeze the gauge and carry it between battles if
    # !CanActOrRecoverable()" -- only its own add-state Knockout branch zeroes
    # it, matched here
    # by #apply_to_party writing back 0 for an ally who ended the fight dead
    # rather than whatever gauge value it happened to be sitting at.
    def atb_gauge; @atb_gauge || 0; end
    def atb_gauge=(v); @atb_gauge = Game.clamp(v || 0, 0, Battle::GAUGE_MAX); end

    # Replace the battle-command list (Continue restoring a saved one). nil keeps
    # whatever the database / class defines.
    def battle_commands=(ids)
      @battle_commands = ids && !ids.empty? ? ids.dup : nil
    end

    # Whether #battle_commands has ever been materialized -- by a live Change
    # Class/Change Battle Commands, or by restoring a save that carried
    # either -- rather than still lazily deferring to the database/class
    # default. Mirrors a reference implementation's own changed-battle-
    # commands flag (its change-class and change-battle-commands routines
    # both set it unconditionally, NOT independently confirmed against
    # genuine RPG_RT under wine), the
    # same way #change_class/#change_battle_commands here always leave
    # `@battle_commands` non-nil once either has run). Reading the public
    # #battle_commands accessor instead would always answer true, since it
    # memoizes the class/database default into `@battle_commands` on first
    # read -- this checks the raw ivar before any such memoization.
    def battle_commands_changed?; !@battle_commands.nil?; end

    # The RPG2003 battle combo an Enable Combo (1007) armed: the battle command
    # to repeat and how many times. nil until a battle page arms one. Stored on
    # the actor the way RPG_RT keeps it;
    # the battle resolution spends it -- Battle#combo_hits multiplies the hits
    # of the armed command when it is the one the actor chose (ADR 0054).
    attr_reader :battle_combo

    # Enable Combo (event command 1007): make `command_id` repeat `multiple`
    # times when this actor uses it. Stored on the actor the way RPG_RT keeps it;
    # the combo is not decremented by a
    # use -- it stays armed for the whole fight until another Enable Combo
    # overwrites it (ADR 0054).
    def set_battle_combo(command_id, multiple)
      @battle_combo = { command_id: command_id, multiple: multiple }
    end

    # Clear a combo Enable Combo armed, at a fight's end -- ported from
    # a reference implementation's own reset-battle routine, NOT independently confirmed
    # against genuine RPG_RT under wine:
    # it resets the combo command id and multiplier to their unarmed
    # defaults, called for
    # every actor at both a battle's start and its end -- so a combo armed for
    # one fight never carries into the next. #set_battle_combo's own doc
    # comment already claimed the combo stays armed "until battle end", but
    # nothing actually enforced that boundary until this existed; see
    # `Game::Battle#apply_to_party`, the one place a fight's outcome is
    # written back onto the persistent Actor objects, for the call site.
    def clear_battle_combo
      @battle_combo = nil
    end

    # Whether this actor uses the RPG2000 "custom battle command" name
    # (独自戦闘コマンド有効, database field 66) instead of the database's
    # generic Skill term. A class change never touches this — a reference
    # implementation's own equivalent reader reads it off the actor's own
    # database row, which has no class-row counterpart at all
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

    # RPG2003's manual battle-sprite position (chunk 11 fields 59/60), ported
    # from a reference implementation's own manual-position accessor --
    # `{dbActor->battle_x, dbActor->
    # battle_y}` directly, no scaling (not independently confirmed against
    # genuine RPG_RT under wine), used as literal screen coordinates by
    # the alternative/gauge battle layouts. 0 (the database default) for
    # every RPG2000 row and any RPG2003 one that never set these.
    def battle_x
      @db_row.respond_to?(:battle_x) ? (@db_row.battle_x || 0) : 0
    end

    def battle_y
      @db_row.respond_to?(:battle_y) ? (@db_row.battle_y || 0) : 0
    end

    # The `db.battleranimations` (chunk 32) id this actor's battle sprite
    # draws its poses from -- ported from a reference implementation's own
    # battle-animation-id resolver,
    # NOT independently confirmed against genuine RPG_RT under wine (the
    # name is misleading, it resolves a *pose set*
    # id, not the id of a single animation). Fallback chain, in order:
    #
    # 1. `@battler_animation_override` (mirrors `data.battler_animation`) when
    #    positive -- set only by a Change Class event that actually ran this
    #    session (see #change_class), never by a database-default starting
    #    class.
    # 2. The current class's own `battler_animation` (chunk 30 field 62) when
    #    Change Class did run and left the actor in a real class.
    # 3. This actor's own database default (chunk 11 field 62), looked up as
    #    an id into `db.battleranimations` -- warns and returns 0 (no sprite
    #    data at all) if that *positive* id names no entry.
    #
    # A resolved id of 0 (the chunk was never written) falls back to
    # battleranimations id 1 instead of being reported as dangling.
    # **Confirmed against genuine RPG_RT.EXE under wine (cycle #255)** on
    # `data/kk1.12` (a real RPG2003 game): its actor 1 (ユーティル) writes no
    # chunk 11 field 62 at all, and the genuine runtime still draws it a
    # battler -- the BattleCharSet `勇者男b` row 2 that `battleranimations`
    # **entry 1** (勇者男) names, template-matched pixel-exact in the party's
    # side-view line-up. Zero is therefore "field absent, use the first
    # entry", not "dangling id": this branch used to run the entry lookup for
    # bid 0 too, fail it (every real table is 1-based), warn and return 0
    # before the tail `anim == 0 ? 1 : anim` below could ever fire, so an
    # actor authored this way got no battler sprite at all.
    def battler_animation_id
      return @battler_animation_override if @battler_animation_override && @battler_animation_override > 0

      anim =
        if @class_changed && @class_id > 0 && @class_row
          @class_row.respond_to?(:battler_animation) ? (@class_row.battler_animation || 0) : 0
        else
          bid = @db_row.respond_to?(:battler_animation) ? (@db_row.battler_animation || 0) : 0
          table = @db.respond_to?(:battleranimations) ? @db.battleranimations : nil
          if bid > 0
            entry = table ? table[bid] : nil
            unless entry
              $stderr.puts "[RPG2k] actor ##{@id}: invalid battle animation id #{bid}, no sprite drawn"
              return 0
            end
          end
          bid
        end
      anim == 0 ? 1 : anim
    end

    private

    # The battle-command list the actor's current class (or, class-less, its
    # database row) defines. An edition / fixture row without the field yields
    # the RPG2003 default of Row alone. Only ever called once an actual
    # Change Class has happened (from #change_class itself, after
    # `@class_changed` is already set) or from #battle_commands' own lazy
    # materialisation on first read -- gated on `@class_changed` the same way
    # #curve_row is, since an actor's database-declared starting class does
    # not make its command list live either: a reference implementation's
    # own equivalent field
    # is copied in from the class row only inside its change-class routine,
    # from the actor's own database row at plain construction and every other
    # time (NOT independently confirmed against genuine RPG_RT under wine).
    def class_battle_commands
      row = @class_changed && @class_id > 0 && @class_row ? @class_row : @db_row
      list = row.respond_to?(:battle_commands) ? row.battle_commands : nil
      list.is_a?(Array) && !list.empty? ? list.dup : [0]
    end

    # Ported from a reference implementation's own EXP-curve calculation,
    # NOT independently confirmed against genuine RPG_RT under wine: two
    # genuinely different curves picked by
    # edition, not a shared formula with an
    # edition-gated constant the way the HP/EXP *caps* are -- RPG2003's own
    # curve is linear in the level index, not the RPG2000 curve's compounding
    # multiply-by-inflation-each-step shape. A prior version of this method
    # ran the RPG2000 branch unconditionally regardless of database edition
    # (no `rpg2003?` check anywhere in it), even though `#rpg2003?` already
    # exists and is used elsewhere in this class. For the shared
    # `exp_basic`/`exp_increase`/`exp_correction` = 30/30/30 default fixture,
    # `calc_exp(1)` (the level 1->2 threshold) computed 60 under the RPG2000
    # curve but should be 90 under RPG2003's -- a full third off at the very
    # first level, diverging further at every level after since the two
    # curves have different shapes, not just different constants. Every actor
    # in an RPG2003 database levelled up on the wrong EXP thresholds
    # throughout the game.
    #
    # RPG2000: float arithmetic mirrors RPG_RT; the running total truncates
    # toward zero each step (C's (int) cast) and the whole result caps at
    # #exp_max. RPG2003: the three fields are summed as plain integers, `i`
    # times the increase field accumulating each step -- a reference
    # implementation's own
    # locals for this branch never leave integral values, so no
    # float arithmetic is needed to match it exactly.
    def calc_exp(n)
      if rpg2003?
        base = db_exp_param(:exp_basic)
        inflation = db_exp_param(:exp_increase)
        correction = db_exp_param(:exp_correction)
        result = 0
        (1..n).each { |i| result += base + i * inflation + correction }
        cap = exp_max
        return result > cap ? cap : result
      end
      base = db_exp_param(:exp_basic).to_f
      inflation = 1.5 + db_exp_param(:exp_increase) * 0.01
      correction = db_exp_param(:exp_correction).to_f
      result = 0
      n.times do
        result += (correction + base).to_i
        base *= inflation
        inflation = ((n + 1) * 0.002 + 0.8) * (inflation - 1) + 1
      end
      cap = exp_max
      result > cap ? cap : result
    end

    # Read a numeric EXP-curve field from the database row, defaulting when the
    # row (a test fixture) does not carry it. The class row wins when the actor
    # has a class, mirroring a reference implementation's own EXP-curve
    # calculation.
    def db_exp_param(field)
      row = curve_row
      row.respond_to?(field) ? (row.__send__(field) || EXP_DEFAULT) : EXP_DEFAULT
    end

    # The database row the level-scaled tables are read from: the class row (職業)
    # once an actual Change Class event has run, the actor row otherwise --
    # RPG_RT ignores a class merely *named* on the actor's own database row
    # (chunk 11 field 57, a game's "starting class") until Change Class (1008)
    # actually fires; see #battler_animation_id's own citation of a
    # reference implementation's change-class comment, which this mirrors via the identical
    # `@class_changed` gate rather than `@class_id > 0` alone. Only the growth
    # curve, the learn table and the EXP curve follow the class -- the
    # attribute / state ranks stay on the actor row, which is where RPG_RT
    # keeps reading them.
    def curve_row
      @class_changed && @class_id > 0 && @class_row ? @class_row : @db_row
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
    # from then on (mirroring a reference implementation's own lazy-actor
    # cache, not independently confirmed against genuine RPG_RT under wine).
    # nil for a non-positive id
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

    # Whether `id` is a genuinely dangling reference -- a positive id with no
    # matching database row at all -- **without** instantiating (and so
    # without enrolling) the actor the way #[] does. A caller that only needs
    # to tell "not currently relevant" apart from "this id doesn't even exist
    # in the database" (#remove_actor's own no-op case, below) must not
    # enroll a merely-never-met-but-otherwise-valid actor into the save data
    # as a side effect of asking. Logs and dedupes through the exact same
    # `@missing` table and message #[] uses, so an id already reported by one
    # path doesn't double-report through the other.
    def known_invalid?(id)
      return false if id.nil? || id <= 0 || @all[id]
      return false if @db.player[id]
      unless @missing[id]
        @missing[id] = true
        $stderr.puts "[RPG2k] actor ##{id} could not be built: No such actor: #{id}"
      end
      true
    end

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

    # Per-item 使用回数 progress: item id => uses already spent on the copy
    # currently being used up (see #consume_item_use). Exposed for the save
    # layer (#to_h) and for tests; the bag itself stays `items`.
    attr_reader :item_usage

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
      # 使用回数 bookkeeping: item id => how many uses the *current* copy has
      # already spent (see #consume_item_use). One tally per id, not per copy,
      # matching the save format's own `item_usage` array (chunk 109 field 14),
      # which runs parallel to `item_ids`/`item_counts`. An id absent here has
      # spent nothing.
      @item_usage = {}
      @gold = 0
      @revision = 0
      @leader_graphic_dirty = false
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
                       # Gates whether a restore actually calls #set_charset
                       # (see #apply_actor_meta below) -- without it, an actor
                       # whose charset_name is merely their own non-blank
                       # database default (never a real Change Sprite
                       # Association) would spuriously come back marked
                       # #sprite_changed?, the same "changed at all" flag
                       # Game::State#to_lsd now gates chunk 108's own
                       # sprite_name/sprite_id/sprite_transparent fields on
                       # (see that method's own citation) -- mirrors
                       # class_changed just below.
                       sprite_changed: a.sprite_changed?,
                       transparent: a.transparent, states: a.states.dup,
                       # A Change Parameters command's unclamped shadow total
                       # (see Actor#change_param / #restore_base) -- without
                       # it a live adjustment reverts to the level-derived
                       # baseline the moment #load_state re-seeds it from EXP.
                       base_raw: a.base_raw.dup,
                       # RPG2003: a Change Class / Change Battle Commands is a
                       # permanent edit, so it has to outlive Save / Continue the
                       # way the name and sprite overrides do. class_changed
                       # distinguishes that from an actor's ordinary
                       # database-assigned starting class, which #load_state
                       # must *not* restore through -- see its own comment.
                       class_id: a.class_id, class_changed: a.class_changed?,
                       battle_commands: a.battle_commands.dup,
                       # RPG2003 battle row (ADR 0053's Row command): outlives
                       # Save/Continue the same way a live Change Class does.
                       row: a.battle_row }
      end
      { actor_ids: @actors.map { |a| a.id }, items: @items,
        # Half-spent 使用回数 rides along with the bag, the way the save format
        # keeps `item_usage` beside `item_counts` -- without it a Save/Continue
        # silently refills every partly-used item.
        item_usage: @item_usage, gold: @gold,
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
      # A save written before 使用回数 was modelled carries no tally at all, so
      # every held item simply starts its uses over -- the same answer this
      # runtime gave for the whole of that save's life.
      @item_usage = data[:item_usage] || {}
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
        # restored EXP is then read against. Gated on class_changed, not merely
        # class_id being present: every actor's meta carries its current
        # class_id whether or not a Change Class event ever ran, and
        # #restore_class unconditionally flips @class_changed to true --
        # calling it for an actor still on their ordinary database-assigned
        # starting class would wrongly switch #curve_row from the actor's own
        # row to the class row (see #curve_row's own comment), silently
        # reinterpreting their EXP/level and skill-learn table after every
        # Save/Continue. A save written before class_changed existed carries no
        # such key, read as false -- the same "never changed" default the .lsd
        # format's own -1 sentinel gives an older save.
        m = meta[id]
        a.restore_class(m[:class_id]) if m && m[:class_changed]
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
      # `sprite_changed` false means the database default was never actually
      # overridden -- skip #set_charset so the actor's own #sprite_changed?
      # stays false too (see #to_h's own citation). A save written before
      # `sprite_changed` existed carries no such key (nil, not false), read
      # as "assume changed" -- the old behavior, gated on charset_name alone.
      if m[:charset_name] && m[:sprite_changed] != false
        actor.set_charset(m[:charset_name], m[:charset_index] || actor.charset_index)
      end
      actor.transparent = m[:transparent] unless m[:transparent].nil?
      actor.states = m[:states] if m[:states]
      actor.battle_commands = m[:battle_commands] if m[:battle_commands]
      actor.battle_row = m[:row] if m[:row]
    end

    def each(&blk); @actors.each(&blk); end
    def size; @actors.size; end
    def leader; @actors.first; end

    # RPG2003's Order menu command: reassign the party's front-to-back order
    # to `new_order`, a permutation of the current member indices (new_order[i]
    # is which existing member becomes the i'th). Ported from a reference
    # implementation's own order-scene routine, NOT independently confirmed against genuine RPG_RT under
    # wine: the player picks members one at a time from the original
    # roster to build exactly this array, then confirming removes every member and
    # re-adds them in that order -- #reorder applies the net effect directly
    # rather than replaying the remove/re-add dance. Membership is unchanged,
    # but the leader can be -- `#leader` is simply `@actors.first` -- which is
    # why this bumps @revision the same as #promote_to_leader above, the
    # existing precedent for a leader change with no membership change.
    #
    # Ported from a reference implementation's own add-actor/remove-actor
    # routines
    # -- the pair its confirm step calls once per member during the remove/re-add
    # dance -- which each unconditionally call its own graphic-reset routine
    # there as a side effect, re-reading slot 0's (the new leader's) CharSet
    # name/index/transparency onto the map sprite. Skipping the replay
    # (above) also skipped this side effect, so `@leader_graphic_dirty`
    # reproduces it directly: set unconditionally here, mirroring that
    # unconditional call rather than only firing when the leader actually
    # changed. This unconditional-refresh behavior is NOT independently
    # confirmed against genuine RPG_RT under wine.
    def reorder(new_order)
      @actors = new_order.map { |i| @actors[i] }
      @revision += 1
      @leader_graphic_dirty = true
    end

    # One-shot read of #reorder's own leader-graphic side effect -- the
    # `Interpreter#take_actor_graphic_changed` idiom (`mruby-rpg2k/mrblib/
    # interpreter.rb`), applied here since a reorder is driven entirely by
    # Scene::Order rather than an interpreter command.
    def take_leader_graphic_dirty
      v = @leader_graphic_dirty
      @leader_graphic_dirty = false
      v
    end

    # RPG2003's field-menu **Row** command (`RPG2K3_COMMAND_IDS` id 6,
    # `scene/menu.rb`): flip `actor`'s front/back row (`Game::Actor
    # #battle_row=`), refusing to leave the whole live party in the back row
    # -- a reference implementation's own field-menu actor-selection Row
    # case (NOT independently confirmed against genuine RPG_RT under wine)
    # counts how
    # many of `@actors` (the current party, not the full roster) are already
    # back-row and blocks only the toggle that would push the last front-row
    # member back, exactly `Game::Battle#can_leave_front_row?`'s in-battle
    # guard restated the other way around (no `IsDirectionFlipped` term here
    # -- the reference's field-menu Row case never has one either). Unlike
    # the in-battle Row command, the reference plays its Decision SE
    # regardless of whether the toggle actually took -- the caller's job, not
    # this method's; this only ever silently no-ops a refused toggle.
    def toggle_actor_row(actor)
      return unless actor.respond_to?(:battle_row) && actor.respond_to?(:battle_row=)
      if actor.battle_row == Actor::ROW_FRONT
        back_count = @actors.count { |a| a != actor && a.respond_to?(:battle_row) && a.battle_row == Actor::ROW_BACK }
        return if back_count >= @actors.size - 1
        actor.battle_row = Actor::ROW_BACK
      else
        actor.battle_row = Actor::ROW_FRONT
      end
    end

    # Plain while loops instead of #any?/#find blocks -- Conditional Branch's
    # "actor in party" sub-condition (actor_condition, interpreter.rb) calls
    # #include_actor? every time it runs, confirmed via a per-condition-type
    # RGSS::Profiler.stats[:object_types] pass to be the single largest
    # source of interpreter-side Proc/env churn in a real playthrough -- a
    # block literal allocates a Proc plus its closure env on every call in
    # this mruby, however small the block body.
    def include_actor?(id)
      i = 0
      n = @actors.size
      while i < n
        return true if @actors[i].id == id
        i += 1
      end
      false
    end

    def actor_by_id(id)
      i = 0
      n = @actors.size
      while i < n
        a = @actors[i]
        return a if a.id == id
        i += 1
      end
      nil
    end

    # Whether any party member is still standing. An empty party counts as wiped.
    def any_alive?
      i = 0
      n = @actors.size
      while i < n
        return true unless @actors[i].dead?
        i += 1
      end
      false
    end

    # Whether the whole party is knocked out (戦闘不能) -- the game-over condition.
    def all_dead?; !any_alive?; end

    # RPG2000 field slip damage: apply every afflicted member's map-step drain
    # for a party that has now walked `steps` tiles. Each state a member carries
    # is asked for its due signed HP / SP delta (Game::States.map_step_drain --
    # negative for the ordinary "lose" case, positive for a "gain"-type state,
    # see Game::States::CHANGE_TYPE_*) and the totals are applied once, so two
    # slipping states stack rather than the worse one winning -- unlike the
    # battle-side effects, which pick a single significant state for its
    # message (though not, per a reference implementation's own
    # apply-conditions routine, for the damage
    # math itself -- see Battle#apply_turn_states).
    #
    # A **loss cannot kill**: it goes through change_hp with death disallowed,
    # so a poisoned party is worn down to 1 HP and left standing. That is
    # RPG_RT's rule, and it is why nothing on this path has to re-check for a
    # game over the way the twelve event commands that *can* wipe the party
    # do. A **gain** clamps to max_hp/max_sp the same way change_hp/change_mp
    # already clamp an ordinary heal.
    #
    # A member who is already down does NOT slip nothing: ported from
    # a reference implementation's own apply-state-damage routine, NOT independently confirmed
    # against genuine RPG_RT under wine -- it iterates
    # every party member with no alive/dead filter at all, for both the HP and SP
    # loops, and its SP-change routine carries no
    # dead-guard of its own -- only its HP-change routine does (
    # matching this class's own `#change_hp`'s `return @hp if
    # dead?`). So a KO'd member's own HP loss silently no-ops (already true
    # via #change_hp), but an SP-draining/regenerating state on that same
    # member still applies in full, and that reference implementation's own
    # `damage` bool -- set
    # unconditionally in the lose branch regardless of whether `ChangeHp`
    # actually changed anything -- still fires there. This method mirrors that: it
    # must not skip a dead actor outright, only rely on #change_hp's own
    # internal no-op for the HP half.
    #
    # `table` is the database `situation` array; a caller without one (the seeded
    # harness fixtures) drains nothing. Returns the actors actually affected
    # (lost *or* gained something) -- #map_step_damaged? (see below) is the one
    # that answers whether the scene should flash the screen over it.
    def apply_map_step_damage(table, steps)
      hit = []
      @map_step_damaged = false
      @actors.each do |actor|
        next if actor.nil?
        hp = 0
        sp = 0
        actor.states.each do |id|
          dhp, dsp = States.map_step_drain(id, table, steps)
          @map_step_damaged ||= dhp < 0 || dsp < 0
          hp += dhp
          sp += dsp
        end
        next if hp.zero? && sp.zero?
        actor.change_hp(hp, false) unless hp.zero?
        actor.change_mp(sp) unless sp.zero?
        hit << actor
      end
      hit
    end

    # Whether the most recent #apply_map_step_damage call included at least one
    # state's own HP/SP *loss* landing on that step -- distinct from
    # #apply_map_step_damage's own return value, which reports every actor who
    # changed either way, gain included. Ports a reference implementation's
    # own apply-state-damage routine (NOT independently confirmed against
    # genuine RPG_RT under wine): its `damage` bool is
    # only ever set inside the lose-type branches, never the
    # gain-type ones, and its own player-movement update routine gates
    # the map-step-damage screen flash on exactly that bool -- a GAIN-type
    # "regen" state's tick alone must never redden the screen, even though the
    # actor it healed is still in the returned #apply_map_step_damage array.
    # Checked per state, not on the summed net delta: a LOSE and a GAIN state
    # landing on the same step both apply (RPG_RT applies each independently),
    # so a net-positive tile still counts as damaged if any single state on it
    # was a loss.
    def map_step_damaged?
      @map_step_damaged
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
    # Returns the actors actually touched (damaged *or* healed), so the scene
    # can flash only when there is something to report.
    #
    # A negative `amount` is a *healing* tile (RPG2000/2003 terrain rows carry
    # one plain signed damage field, no separate heal flag) -- ported from
    # a reference implementation's own player-movement terrain block, which guards
    # its per-actor loop with a check that lets negative damage through
    # regardless of the immunity flag, so a negative value heals *every*
    # party member unconditionally, bypassing `no_terrain_damage` gear
    # entirely in that design -- only positive damage respects that
    # immunity (NOT independently confirmed against genuine RPG_RT under
    # wine). The HP change is still applied with the negated amount either
    # way (`-(-1) = +1`, a heal), so the existing `-amount` formula already
    # produces the right sign; only which branch the immunity check gates
    # needed to change. This heal/immunity interaction is NOT independently
    # confirmed against genuine RPG_RT under wine.
    def apply_terrain_damage(amount)
      return [] unless amount && amount != 0
      hit = []
      @actors.each do |actor|
        next if actor.nil? || actor.dead?
        next if amount > 0 && actor.prevents_terrain_damage?
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
      return unless @actors.size == before
      # The id matched no current member -- the ordinary "not currently in
      # the party" case, harmless and silent. But #add_actor already reports
      # a positive id with no matching database row at all (a database
      # shrink leaving a stale Change Party Member target, the "invalid
      # hero" catalog case) via its own #roster[] lookup; #remove_actor had
      # no equivalent check at all, so the identical stale id silently did
      # nothing with no trace when the command's "Remove" radio button
      # happened to be selected instead of "Add". #known_invalid? reports
      # that exact same case without #[]'s side effect of building and
      # enrolling the actor into the save data -- unlike Add, a Remove of a
      # merely-never-met-but-otherwise-valid actor must not have that
      # side effect.
      @roster.known_invalid?(id)
    end

    # Make an already-rostered actor the leader (party slot 0). If they are
    # already a member elsewhere in the party, they are moved to the front
    # (everyone else's membership is untouched); otherwise they replace
    # whoever is currently in slot 0, since a mismatch here means chunk 109's
    # party list named the wrong actor for that slot, not that the party
    # grew an extra member. Used by State.from_lsd when a save's party list
    # disagrees with the title chunk's cached leader (see the comment
    # there). A no-op if +actor+ is nil or already leading.
    def promote_to_leader(actor)
      return unless actor && @actors.first != actor
      @actors.delete(actor)
      if @actors.empty?
        @actors.push(actor)
      else
        @actors[0] = actor
      end
      @revision += 1
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

    # How many of `id` sit equipped across the whole party right now -- every
    # slot on every member that holds it, so an id equipped in two slots at
    # once (nothing stops the same shield id filling both an off-hand and a
    # main-hand slot) counts twice. Ported from a reference implementation's
    # own equipped-item-count routines (a slot
    # equality scan), and backs both the Control Variables item-operand's
    # equipped mode (Interpreter#item_operand) and the shop status panel
    # (Scene::Map#draw_shop_status). Confirmed via wine (2026-09-05): a
    # double_hand actor with the same custom weapon id equipped in both the
    # weapon and shield slots, read through a real Control Variables
    # (item-operand, mode 1) command into a variable and displayed via a
    # Conditional Branch -- collapsing the read into a binary "TWO" vs
    # "NOTTWO" message rather than a raw digit, since this session's own
    # repeated attempts at reading multi-digit numbers off this pixel font
    # proved unreliable -- showed "TWO", not "NOTTWO".
    def equipped_item_count(id)
      @actors.reduce(0) { |n, a| n + a.equipment.count(id) }
    end

    def gain_item(id, n = 1)
      c = item_count(id) + n
      c = 0 if c < 0
      c = 99 if c > 99
      # **Losing** a copy wipes the part-used tally on that id, so the next copy
      # starts on a full set of uses; gaining one never touches it, even at the
      # 99 cap (a reference implementation's own add-item routine: "If the item was removed, the
      # number of uses resets. Adding an item never changes the number of uses,
      # even when you already have x99 of them."). Selling a half-used potion
      # and buying it back therefore refills its uses, exactly as RPG_RT does.
      if n < 0
        if c == 0
          @item_usage.delete(id)
        else
          @item_usage[id] = 0
        end
      end
      # Losing the last copy erases the bag entry outright, the same way
      # a reference implementation's own add-item routine does (ported from its source, NOT
      # independently confirmed against genuine RPG_RT under wine) when
      # `total_items <= 0` -- it removes the id/count/usage triple from its
      # arrays rather than storing a 0 count, and never inserts one at all
      # for an item that was never held in the first place (its own early
      # `!has` branch only inserts when `amount > 0`). Storing `@items[id] =
      # 0` here instead used to leave a phantom zero-count key sitting in
      # the bag hash forever -- invisible in ordinary play, since every
      # reader already guards on `count > 0`, but not invisible in the save
      # file: `#to_h`'s inventory writer builds chunk 109's `item_ids`/
      # `item_counts` straight off `@party.items.keys`, so the junk id got
      # written into SAVE_INVENTORY and read straight back by `.from_lsd`,
      # accumulating one row per item ever fully depleted for the life of
      # the save.
      if c == 0
        return c unless @items.key?(id)
        @items.delete(id)
      elsif @items.key?(id)
        return c if @items[id] == c
        @items[id] = c
      else
        insert_item_in_bag(id, c)
      end
      @revision += 1
      c
    end

    # Put a *newly* held id into the bag where RPG_RT puts it.
    #
    # The bag is stored, and listed, in the order the save carries -- cycle
    # #252 proved the Item screen never re-sorts it -- which left open where a
    # freshly gained id lands. Measured under wine (cycle #258): a Save01.lsd
    # whose chunk 109 `item_ids` was written deliberately out of order
    # ([42, 92, 67, 28, 103] = ショートソード/メイス/ファルシオン/グラディウス/
    # ロングスピア), resumed in genuine RPG_RT.exe, and one weapon bought from
    # Nepheshel's own weapon shop (Map0015 event 2, `--map 15 --at 5,9`):
    #   * buying **44** listed 42, **44**, 92, 67, 28, 103 -- inserted at index
    #     1, immediately before 92, the first *stored* entry whose id is larger;
    #   * buying **27** listed **27**, 42, 92, 67, 28, 103 -- index 0, before
    #     42, again the first larger stored id;
    #   * buying **127** listed 42, 92, 67, 28, 103, **127** -- appended,
    #     because no stored entry is larger.
    # So the rule is a single forward scan: insert immediately before the first
    # stored entry with a greater id, and append when there is none. It is not
    # an append (44 and 27 both landed ahead of entries that were already
    # there), not a sort of the whole bag (that would have reordered 92/67/28),
    # and not "after the last smaller id" (that would have put 44 at index 4).
    #
    # `@items` is a Hash whose insertion order *is* the bag order, so inserting
    # in the middle means re-appending the tail behind the new key.
    def insert_item_in_bag(id, count)
      keys = @items.keys
      at = keys.size
      i = 0
      while i < keys.size
        if keys[i] > id
          at = i
          break
        end
        i += 1
      end
      if at == keys.size
        @items[id] = count
        return count
      end
      tail = []
      j = at
      while j < keys.size
        k = keys[j]
        tail.push([k, @items.delete(k)])
        j += 1
      end
      @items[id] = count
      tail.each { |pair| @items[pair[0]] = pair[1] }
      count
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

    # 通常物品 (type 0): an item with no effect of its own -- a key item, a quest
    # token, something an event checks for. It is never *used*, which is why
    # #consume_item_use names it among the types it passes over untouched.
    ITEM_NORMAL = 0

    # The five equipment types (see Actor::EQUIP_ORDER for the slot mapping),
    # named here for #field_usable? / #battle_usable? / #use_item's `use_skill`
    # branch: an equipment item flagged `use_skill` (field 71) invokes its
    # `skill_id` skill directly from the Item menu, exactly like a type-9
    # special item, without being equipped. Ported from a reference
    # implementation's own use-item routine, NOT independently confirmed against genuine
    # RPG_RT under wine: its do-skill computation ORs `use_skill` with
    # this exact five-type check.
    ITEM_SHIELD = 2
    ITEM_ARMOR = 3
    ITEM_HELMET = 4
    ITEM_ACCESSORY = 5

    # The database row for a held item id, or nil when the database has no item
    # table (a bare test fixture) or no such row.
    def db_item(id)
      return nil unless @db.respond_to?(:item)
      @db.item[id]
    end

    # The database row for an enemy-group (troop) id, or nil when the database
    # has no enemy_group table (a bare test fixture) or the id is a dangling
    # reference -- a database shrink can leave one behind, shown as "?" in the
    # editor (see docs/TODO.md's runtime error catalog). `Game::Interpreter`
    # checks this *before* opening a battle for an Enemy Encounter command or a
    # random encounter, since `Game::Troop.new` itself tolerates a missing row
    # by degrading to an empty member list rather than raising.
    def db_enemy_group(id)
      return nil unless @db.respond_to?(:enemy_group)
      @db.enemy_group[id]
    end

    # Whether this party's database is an RPG2003 project (see
    # `LCF::Schema::Database#rpg2003?`), exposed here the same way `db_item` /
    # `db_skill` reach into `@db` for other callers -- a bare test fixture with
    # no `#rpg2003?` of its own reads false, the same answer a genuine RPG2000
    # database gives.
    def rpg2003?
      @db.respond_to?(:rpg2003?) && @db.rpg2003?
    end

    # Whether the database asks for RPG2003's sprite/gauge battle-screen
    # presentation instead of RPG2000's status-window-only one
    # (`battlecommands.battle_type`, database chunk 0x1D field 7 -- 0
    # traditional, 1 alternative, 2 gauge). Nothing in this runtime branches
    # on it yet -- rendering support lands in a follow-up change -- but it
    # needs to exist now so that follow-up can be reviewed against real data
    # instead of guessed. A bare test fixture with no `#battlecommands` table
    # reads false, the same answer a genuine RPG2000 database gives.
    def alternate_battle_layout?
      return false unless @db.respond_to?(:battlecommands)
      table = @db.battlecommands
      table && table.battle_type != 0 ? true : false
    end

    # Whether the database asks specifically for RPG2003's gauge battle-screen
    # presentation (`battlecommands.battle_type == 2`) -- distinct from
    # `#alternate_battle_layout?` above, which is also true for the plain
    # sprite-only layout (1). The party status panel reads this to know when
    # to replace its text status window with the gauge card layout (see
    # scene/battle.rb's `#refresh_battle_status`); an alternative-layout (1)
    # database, or one with no `#battlecommands` table at all, reads false.
    def gauge_battle_layout?
      return false unless @db.respond_to?(:battlecommands)
      table = @db.battlecommands
      table && table.battle_type == 2 ? true : false
    end

    # RPG2003's battle-sprite placement choice (`battlecommands.placement`,
    # chunk 29 field 2 -- 0 manual, 1 automatic; see schema.rb). Manual is
    # `Game::Actor#battle_x`/`#battle_y` read as literal screen coordinates;
    # automatic computes a grid formula (a reference implementation's own
    # base-grid-position / 2k3-battle-position calculation, ported in
    # scene/battle.rb's #automatic_battle_position, NOT independently
    # confirmed against genuine RPG_RT under wine) keyed by party index/size
    # and the encounter terrain. A bare test fixture with
    # no `#battlecommands` table, or an RPG2000 database (which never sets
    # this field), reads false/manual, same as `#alternate_battle_layout?`.
    def automatic_battle_placement?
      return false unless @db.respond_to?(:battlecommands)
      table = @db.battlecommands
      table && table.respond_to?(:placement) && table.placement == 1 ? true : false
    end

    # RPG2003's "Death Handler" (`battlecommands.death_handler`, chunk 29
    # field 0x0F -- see mruby-lcf/mrblib/schema.rb): when active, a random
    # (wandering-monster) encounter's party wipe skips the ordinary Game
    # Over screen and instead runs a common event and/or teleports the
    # party, gated on `rpg2003? && db.death_handler`. This gating and the
    # overall death-handler behavior are NOT independently confirmed against
    # genuine RPG_RT under wine -- first-principles reasoning from the
    # database field's own name and liblcf's schema only. A scripted Battle
    # Processing command's own [Defeat] handler is a separate,
    # already-correct mechanism (Interpreter#do_enemy_encounter's own
    # `defeat_game_over: cmd.param(4) == 0`) that never consults this -- the
    # death handler applies to wandering encounters only. A bare test
    # fixture with no `#battlecommands` table, or an RPG2000 database, reads
    # false, same as `#alternate_battle_layout?` above.
    def death_handler?
      return false unless rpg2003? && @db.respond_to?(:battlecommands)
      table = @db.battlecommands
      table && table.respond_to?(:death_handler) && table.death_handler ? true : false
    end

    # The common event id a Death Handler runs (`battlecommands.death_event`),
    # or 0 when the handler is not active. NOT independently confirmed
    # against genuine RPG_RT under wine (see `#death_handler?` above).
    def death_handler_event
      return 0 unless death_handler?
      table = @db.battlecommands
      table.respond_to?(:death_event) ? (table.death_event || 0) : 0
    end

    # The Death Handler's own teleport target as [map_id, x, y, facing] (the
    # same 1-based-facing-or-0-for-keep-current layout the Teleport event
    # command's own facing parameter uses -- see Interpreter
    # #teleport_facing, and schema.rb's `death_teleport_face` comment for
    # why they line up), or nil when no teleport is configured. NOT
    # independently confirmed against genuine RPG_RT under wine (see
    # `#death_handler?` above).
    def death_handler_teleport
      return nil unless death_handler?
      table = @db.battlecommands
      return nil unless table.respond_to?(:death_teleport) && table.death_teleport
      [table.death_teleport_id, table.death_teleport_x, table.death_teleport_y,
       table.death_teleport_face]
    end

    # Whether item `id` can be used from the field (main-menu) item screen: a
    # medicine or switch item the party holds whose "usable in field" occasion is
    # set (a battle-only medicine is hidden here, mirroring #battle_usable?), or a
    # skill book / seed (always field-only, no occasion to gate on).
    #
    # A **special** item defers to the skill it invokes, as RPG_RT does
    # (mirroring a reference implementation's own item-usability check, which
    # hands a special-type item straight to its skill-usability check, not
    # independently confirmed against genuine RPG_RT under wine): the item's
    # own occasion flags say nothing useful about a
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
    #
    # A database shrink can leave a party-held item id with no matching row
    # (docs/TODO.md's runtime error catalog) -- `db_item` degrades that to a
    # silent `nil`, which used to drop the item from the field menu with no
    # trace anywhere in the call chain. Logged here, the same way
    # #field_skills reports a dangling learned-skill id: this is the only
    # caller of #field_usable? with an id from the party's own bag, so it's
    # the one place that knows the gap came from *that* list rather than some
    # other `db_item` call with no menu behind it.
    def field_usable?(id, state = nil)
      it = db_item(id)
      if it.nil?
        $stderr.puts "[RPG2k] Item menu: party-held item ##{id} has no " \
                     'matching database row, excluding from field menu'
        return false
      end
      return false unless item_count(id) > 0
      return use_skill_item_usable?(it, false) if it.use_skill
      case it.type
      when ITEM_MEDICINE, ITEM_SKILL_BOOK, ITEM_SEED then true
      when ITEM_SWITCH then item_field_occasion?(it)
      when ITEM_SPECIAL then field_skill?(db_skill(it.skill_id), state)
      else false
      end
    end

    # RPG_RT's own extra usability gate an item flagged `use_skill` (field
    # 71) gets, checked *before* any of the item's own type-specific
    # occasion rules apply -- and a much looser test than the ordinary
    # #field_skill?/#battle_skill? usability check a type-9 Special item
    # goes through: no affect_hp / affect_sp / inflicted-state requirement
    # at all, just the invoked skill's scope. Ported from a reference
    # implementation, not independently confirmed against genuine RPG_RT
    # under wine: it
    # tests `item->use_skill` *ahead of* its own
    # `switch (item->type)` -- a comment in that source even flags the result as
    # its belief that this is an "RPG_RT BUG: Does not check if skill is usable" -- returning `skill &&
    # (in_battle || scope == Scope_self || scope == Scope_ally || scope ==
    # Scope_party)` (liblcf's `Scope_self`/`_ally`/`_party` are `2`/`3`/`4`,
    # i.e. `scope >= 2`). #field_usable?/#battle_usable? used to instead
    # route a use_skill equipment item through the same full usability check
    # a type-9 Special item gets, silently hiding a use_skill item whose
    # invoked skill only modifies stats (no HP/SP/state effect at all) even
    # though real RPG_RT offers it. `UseItem`'s own *effect*-dispatch flag
    # (`do_skill`, this codebase's #skill_invoking_item?/#use_item) is a
    # separate, correctly-already-five-types-restricted check -- only this
    # *usability* gate is type-unrestricted in RPG_RT.
    def use_skill_item_usable?(it, in_battle)
      sk = db_skill(it.skill_id)
      sk && (in_battle || sk.scope >= 2)
    end

    # An item's occasion flags, read by the **field name the format actually
    # uses**. RPG2000 gives an item three of them and they are not
    # interchangeable (ported from a reference implementation, not
    # independently confirmed against genuine RPG_RT under wine):
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

    # Use a switch item from the field menu: spend one use (#consume_item_use, so
    # a multi-use or 無制限 switch item is not eaten on its first flip) and return
    # the id of the switch to turn on (the caller owns the switch table). nil when
    # `id` is not a switch item the party holds, so nothing is consumed. Mirrors
    # a reference implementation, not independently confirmed against genuine
    # RPG_RT under wine, where UseItem consumes and the scene flips the switch.
    def use_switch_item(id)
      return nil unless switch_item?(id) && item_count(id) > 0
      consume_item_use(id)
      db_item(id).switch_id
    end

    # Every held item as `[id, count]` pairs in ascending id order, for the
    # item menu's list -- list membership and usability are two different
    # questions: a weapon, shield, armor, helmet or accessory sitting in the
    # bag is listed (and drawn disabled) exactly like a usable medicine, not
    # omitted, pixel-sampled against a genuine RPG_RT frame under wine, which
    # draws an unusable held item's row in a visibly darker color rather than
    # leaving it off the list. Usability (#field_usable?) is a separate
    # concern the menu scene consults only for the row's color and whether
    # Decision does anything. A party-held id with no matching database row
    # (a shrunk-database dangling reference) is the one thing still excluded
    # here -- there is nothing to draw a name for -- with the same warning
    # #field_usable? used to print as a side effect of filtering it out.
    # Bag order is the order the save carries, never sorted by id -- measured
    # against genuine RPG_RT.exe under wine (cycle #252): a Save01.lsd whose
    # chunk 109 `item_ids` was written deliberately out of order
    # ([60, 12, 45, 1], counts [5, 3, 9, 7]) listed on RPG_RT's own field Item
    # screen in exactly that order (クレセントムーン:5, ユニコーンの角:3,
    # バスタードソード:9, 薬草:7), not the 1/12/45/60 an id sort gives. `@items`
    # is built in the save's own order by `.from_lsd`, so preserving the hash's
    # insertion order is preserving RPG_RT's.
    #
    # Where RPG_RT *inserts* a newly gained id was left open by that capture and
    # is settled by cycle #258's: immediately before the first stored entry with
    # a greater id, appended when there is none. See #insert_item_in_bag, which
    # carries the three purchases that measured it.
    def field_items(state = nil)
      @items.keys.select do |id|
        it = db_item(id)
        if it.nil?
          $stderr.puts "[RPG2k] Item menu: party-held item ##{id} has no " \
                       'matching database row, excluding from field menu'
        end
        it
      end.map { |id| [id, item_count(id)] }
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
    # medicine **cures** them, unconditionally, matching a reference
    # implementation's own item algorithm (ported from its
    # source, NOT independently confirmed against genuine RPG_RT under
    # wine): it
    # calls its own state-remove helper for every flagged bit inside its
    # medicine-type
    # branch with no other condition attached at all -- unlike a weapon's own
    # `state_set` (#weapon_states) or a skill's (#skill_cured_states/
    # #skill_inflicted_states), `item.reverse_state_effect` (field 68) is
    # never once read there. `reverse_state_effect` is real data an item row
    # can carry, but it is a dead field for a medicine in the real engine --
    # the editor exposes the checkbox, RPG_RT itself simply never consults it
    # for this item type. This method previously mirrored it into an
    # inflict/cure split anyway (see #item_inflicted_states, since removed);
    # nothing in either test bed sets the flag on an item, so nothing was
    # ever known to depend on that behaviour.
    #
    # The polarity used to be read backwards too, at one point -- cures only
    # when the flag was *set* -- which meant no shipped curative item cured
    # anything. Neither test bed sets the flag on any item at all, while
    # Nepheshel has 13 medicines naming states without it and mtf-meido-action
    # one: アンチドーテ and ユニコーンの角 name all fifteen states, and 気付け薬 /
    # ドラゴンブラッド name state 1 alone, which is 戦闘不能 -- they are revives.
    # Reading those as "cures nothing" made every antidote and every revive
    # item in both games inert, in the menu and in a fight alike.
    def item_cured_states(it)
      item_state_ids(it)
    end

    # The states item `it` names in its `state_set` (a 0/1 byte per state, index
    # i -> state id i+1). Shared by #item_cured_states, mirroring #skill_state_ids.
    def item_state_ids(it)
      set = it.state_set
      return [] unless set
      out = []
      set.each_index { |i| out.push(i + 1) if set[i] && set[i] != 0 }
      out
    end

    # 蘇生専用 (`ko_only`): an item that does nothing at all to a target who is
    # still standing. Ported from a reference implementation (whose
    # `item.ko_only && !IsDead()` branch precedes both the HP and the state
    # effect computation), NOT independently confirmed against genuine
    # RPG_RT under wine: the ported behavior returns before either is
    # computed, so this is not "cures nothing" -- the percentage HP restore
    # does not land either.
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

    # 使用可能キャラ (`actor_set`, item field 62) / RPG2003's 使用可能クラス
    # (`class_set`, item field 73): whether item `it` may be used or equipped
    # by `actor_id` at all. Ported from a reference implementation. The
    # actor_set half is confirmed against genuine RPG_RT under wine
    # (2026-09-05): a solo party's only member, with damaged HP and a real
    # Medicine item in the bag whose actor_set explicitly excluded that one
    # actor, could select the item and target itself in the field Item menu
    # -- both stayed selectable, not greyed out -- but confirming the use
    # did nothing at all: no HP restored, no item consumed. A control run
    # with the identical setup and an unmodified (unrestricted) actor_set
    # healed normally and consumed the item, ruling out a fixture bug. It
    # reads exactly one of the two restriction lists per
    # item, chosen by a single *global*, database-wide RPG2003 toggle --
    # `System#equipment_setting` (LDB chunk 22 field 97) -- never both at
    # once and never per item: a database configured "by Class" ignores
    # actor_set entirely and checks class_set instead; RPG2000 (no classes
    # exist at all) and an RPG2003 database left on the default "by Actor"
    # setting both keep the ordinary actor_set behavior. This is the one
    # choke-point every item-usability check in this codebase funnels
    # through (equip-candidate listing, equip-from-bag, medicine/special/
    # switch items, ko_only revive gating, ...), matching a reference
    # implementation's own single funnel, which is likewise the one every
    # item-use path checks before ever looking at the item's own type. An
    # actor id the array is too short to reach defaults to allowed, the same
    # "missing entry reads as the field's default" rule this runtime's other
    # bit-array fields already follow.
    # One entry of an `actor_set` / `class_set` permission array, as a real
    # boolean. A genuine database stores these as **int8 flags**, where `0`
    # means "not permitted" -- and `0` is truthy in Ruby and mruby alike, so
    # the bare `set[i] ? true : false` this used to do read every restricted
    # row as permitted, exactly inverting the restriction. Confirmed against
    # genuine RPG_RT.exe under wine (cycle #250) and against the shipped data:
    # Nepheshel's item 26 (ダガー) carries `actor_set[14] == 0` for actor 15 and
    # never appears in RPG_RT's own equip list for that actor, while this
    # engine offered it.
    #
    # Accepts a boolean too, because the host harnesses' fixtures write these
    # arrays as `true`/`false` rather than the schema's own int8s; both readings
    # agree on every value either source produces.
    def self.usable_flag?(v)
      return false if v.nil? || v == false
      v != 0
    end

    # Whether a permission array carries a real restriction at all. An array of
    # nothing but zeros is the editor's *untouched* state, not "no actor may use
    # this": mtf-meido-action's item 5 (Stimulant) ships `actor_set` all-zero and
    # is a working revive item in that game -- `rpg2k_testbed_logic_check.rb`
    # has asserted it heals a fallen member since long before this reading was
    # examined. Nepheshel's item 26 (ダガー), by contrast, carries a *mixed*
    # array whose zero for actor 15 genuine RPG_RT.exe really does honour (it
    # never offers that weapon to that actor -- measured under wine, cycle
    # #250). So a set is consulted only when something in it is set.
    #
    # An alternative reading fits both observations equally well -- that the
    # per-actor list binds equipment only and medicines ignore it entirely --
    # and is NOT ruled out here: no capture was taken of a *medicine* with a
    # mixed actor_set, which is the one case that would separate the two. Left
    # deliberately as the narrower rule, which cannot wrongly refuse a shipped
    # item either way.
    def self.permission_set_active?(set)
      set.respond_to?(:any?) && set.any? { |v| usable_flag?(v) }
    end

    def item_usable_by?(it, actor_id)
      return item_usable_by_class?(it, actor_id) if equip_by_class?
      return true unless it.respond_to?(:actor_set) && it.actor_set
      return true if actor_id.nil?
      set = it.actor_set
      idx = actor_id - 1
      return true if idx < 0 || set.size <= idx
      return true unless Party.permission_set_active?(set)
      # The database stores this as an int8 flag per actor, and **0 means "this
      # actor may not use it"** -- but `0` is truthy in Ruby (and in mruby), so
      # a bare `set[idx] ? ...` read every restricted row as *allowed*, exactly
      # inverting the restriction. Confirmed against genuine RPG_RT.exe under
      # wine (cycle #250's Equip screen capture) and against the real database:
      # Nepheshel's item 26 (ダガー) carries actor_set[14] == 0 for actor 15 and
      # never appears in RPG_RT's own equip list for that actor, while this
      # engine offered it. Compared against 0 explicitly so the flag's own value
      # decides, not Ruby's notion of truthiness.
      Party.usable_flag?(set[idx])
    end

    # Whether this database is RPG2003 and configured for its "使用可能キャラ
    # -> by Class" global toggle rather than the default per-Actor one
    # (`System#equipment_setting == 1`, ported from a reference
    # implementation, not independently confirmed against genuine RPG_RT
    # under wine). A
    # bare test fixture whose `db.system` does not answer `equipment_setting`
    # at all reads as "by Actor", the same default the field itself has in a
    # genuine database. Rescued the same defensive way
    # `#seed_screen_transitions` already reads other `db.system` fields: a raw
    # `LCF::Database` driven through the pure-Ruby test-bed harness (not the
    # compiled engine) resolves `db.system` through `Kernel#system` before
    # ever reaching its own field lookup, so any error there — not just a
    # missing field — degrades to the ordinary "by Actor" default rather than
    # raising.
    def equip_by_class?
      rpg2003? && @db.respond_to?(:system) && @db.system.respond_to?(:equipment_setting) &&
        @db.system.equipment_setting == 1
    rescue StandardError
      false
    end

    # The class_set half of #item_usable_by?, used in place of actor_set once
    # #equip_by_class? is on. Indexed by the actor's own class id *directly*
    # (ported from a reference implementation, not independently confirmed
    # against genuine RPG_RT under wine) — not `class_id - 1` the way actor_set's
    # bit array is — since liblcf reserves class_set index 0 for "no class"
    # rather than naming a real row; the first real class is index 1. An
    # actor with no class at all (RPG2000 has none, and an RPG2003 actor can
    # simply start unclassed) reads index 0.
    def item_usable_by_class?(it, actor_id)
      return true unless it.respond_to?(:class_set) && it.class_set
      return true if actor_id.nil?
      actor = @roster[actor_id]
      class_id = actor && actor.respond_to?(:class_id) ? (actor.class_id || 0) : 0
      set = it.class_set
      return true if set.size <= class_id
      return true unless Party.permission_set_active?(set)
      # Same int8-zero-is-truthy trap as #item_usable_by? above -- see its own
      # citation. Not separately captured (no RPG2003 test bed with a genuine
      # RPG_RT.exe reaches this by-class path), but it reads the identically
      # shaped flag array from the identical schema type, so the same explicit
      # comparison applies.
      Party.usable_flag?(set[class_id])
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
          item_cured_states(it).any? { |s| actor.state?(s) }
      when ITEM_SKILL_BOOK
        s = it.skill_id
        !actor.dead? && !s.nil? && s != 0 && !actor.knows_skill?(s)
      when ITEM_SEED
        !actor.dead? && seed_boosts(it).any? { |b| b != 0 }
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

    # 使用回数 (`uses`, item field 6): how many times **one copy** of an item may
    # be used before it is spent. The editor's own wording is 使用回数, with 0
    # meaning 無制限 -- an item that is never consumed however often it is used
    # (Nepheshel's reusable tools are exactly this, and until now every one of
    # them vanished on first use). The default is 1: a plain potion is used up
    # by a single use, which is why every consumption site could get away with a
    # bare `lose_item(id, 1)` before this existed.
    #
    # A fixture item row with no `uses` field at all reads as 1, the schema's own
    # default (`LCF::Schema` item field 6), so a hand-built test item keeps the
    # single-use behaviour it has always had.
    def item_uses(it)
      u = it.respond_to?(:uses) ? it.uses : nil
      u.nil? ? 1 : u
    end

    # Spend one use of item `id`, consuming a copy only once its 使用回数 runs
    # out. This is the single consumption point for *using* an item -- the field
    # menu, the battle item action and every #use_* helper below go through it
    # instead of calling #lose_item themselves, mirroring a reference
    # implementation's own single consumption point, which is called once the
    # item is known to have done something (not independently confirmed
    # against genuine RPG_RT under wine).
    #
    # Three rules come from RPG_RT and none of them were modelled before:
    #
    #   * **Type gate.** A 通常物品 and the five equipment types are never
    #     consumed by use. The equipment case is the load-bearing one here: an
    #     item flagged 特殊効果 (`use_skill`) casts its skill straight from the
    #     Item menu, and RPG_RT does *not* eat the weapon for it -- it is
    #     `ConsumeItemUse`'s early `return`, not a missing branch. This build
    #     used to destroy such a weapon on its first use.
    #   * **`uses == 0` is unlimited.** Nothing is spent, ever.
    #   * **Partial use.** Otherwise the id's tally rises by one and the copy is
    #     only removed once the tally reaches `uses`, at which point it resets --
    #     so an item with 使用回数 3 held ×2 survives five uses and disappears on
    #     the sixth. #gain_item handles the reset for the other direction (an
    #     item leaving the bag by any route).
    #
    # A dangling id (no database row) is logged and left alone rather than
    # silently eaten, the same way #field_usable? reports one for the menu.
    def consume_item_use(id)
      it = db_item(id)
      if it.nil?
        $stderr.puts "[RPG2k] Item use: item ##{id} has no matching database " \
                     'row, consuming nothing'
        return
      end
      case it.type
      when ITEM_NORMAL, Actor::ITEM_WEAPON, ITEM_SHIELD, ITEM_ARMOR,
           ITEM_HELMET, ITEM_ACCESSORY
        return
      end
      uses = item_uses(it)
      return if uses == 0
      return unless item_count(id) > 0
      spent = (@item_usage[id] || 0) + 1
      if spent >= uses
        lose_item(id, 1) # clears the tally itself (see #gain_item)
      else
        @item_usage[id] = spent
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
      when Actor::ITEM_WEAPON, ITEM_SHIELD, ITEM_ARMOR, ITEM_HELMET, ITEM_ACCESSORY
        it.use_skill ? use_equip_skill_item(it, id, actor) : []
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
      consume_item_use(id) unless affected.empty?
      affected
    end

    # A weapon/shield/armour/helmet/accessory item flagged `use_skill` invokes
    # its `skill_id` skill directly, without being equipped -- the same free
    # cast #use_special_item gives a type-9 special item. `#item_usable_by?`
    # alone already covers whatever restriction this item carries, actor_set
    # or class_set alike (see its own doc) -- this used to additionally AND
    # in `#item_usable_by_class?` here, as if a use_skill equipment item were
    # the one place class_set applied; it is not a use_skill-specific rule at
    # all, just the ordinary database-wide "by Class" toggle every item type
    # is equally subject to.
    #
    # The weapon itself is **not** consumed, however often it is used: RPG_RT
    # returns from `ConsumeItemUse` on the five equipment types before it ever
    # looks at 使用回数 (see #consume_item_use), which is what makes a 特殊効果
    # weapon a reusable tool rather than a one-shot. Routing the consumption
    # through #consume_item_use is what gets that right -- this used to spend
    # the weapon on its first use and leave the party without it.
    #
    # An Escape/Teleport-type skill can't run through #cast_skill at all --
    # ported from a reference implementation, NOT independently confirmed
    # against genuine RPG_RT under wine: it gives these two types their own
    # branch, entirely separate from the ordinary HP/SP/state loop
    # #cast_skill ports -- it plays
    # only the skill's sound effect and marks itself used, never touching
    # HP/SP/a state, and never returning early/false the way an ordinary
    # skill with nothing to change on this target would. Since
    # the equipment-item counterpart to this method
    # forwards straight to that same skill-use path and
    # returns its used flag, a use_skill equipment item invoking one of
    # these two types always succeeds once #item_usable_by? passes --
    # treated here as `[actor]`, a one-element "changed" list, so the
    # caller's own empty-vs-non-empty success check (`Scene::ItemMenu#
    # apply_item`) plays the invoked skill's own animation SE rather than
    # Buzzer, matching that same reference implementation's identical
    # on-success branch (see `#play_item_use_se`'s own
    # citation). This used to fall through to #cast_skill unconditionally,
    # which has no notion of these two types at all and always found
    # nothing to change -- an empty `affected`, misreported to the caller
    # as failure and playing Buzzer instead. (A Switch-type skill needs no
    # equivalent branch here: `Scene::ItemMenu#choose_item` already routes
    # a use_skill equipment item invoking one to `#apply_special_switch_item`/
    # `#use_special_switch_item` before this method is ever reached, the
    # only path that calls #use_item today -- see #use_special_switch_item's
    # own doc.)
    def use_equip_skill_item(it, id, actor)
      return [] unless actor && item_usable_by?(it, actor.id)
      sk = db_skill(it.skill_id)
      if sk && (sk.type == SKILL_ESCAPE || sk.type == SKILL_TELEPORT)
        consume_item_use(id)
        return [actor]
      end
      affected = cast_skill(actor, it.skill_id, actor, true)
      consume_item_use(id) unless affected.empty?
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
      # Only a genuine type-9 special item takes this free-warp fast path --
      # ported from a reference implementation's source, NOT independently
      # confirmed against genuine RPG_RT under wine: its
      # Escape/Teleport dispatch sits
      # inside an item-type-and-skill-id gate, so
      # a `use_skill`-flagged weapon/shield/armor/helmet/accessory (field 71)
      # never reaches it at all -- it falls to the ordinary
      # actor-target picker instead, which routes through
      # the same skill-use path; for
      # a Teleport/Escape skill that path only plays the skill's
      # sound effect and marks itself used --
      # no warp of any kind.
      # A prior version of this comment assumed the two item kinds shared
      # this fast path from the item-use computation
      # without tracing one level further into what the skill-use path
      # itself does for these two skill types specifically.
      return nil unless it && it.type == ITEM_SPECIAL &&
                        actor && item_usable_by?(it, actor.id)
      target = cast_escape_skill(actor, it.skill_id, state, true)
      return nil unless target
      consume_item_use(id)
      target
    end

    # The same for a special item invoking a **Teleport**-type skill, to the
    # registered destination named by `map_id` (the caller's own picker chooses
    # which — see `Scene::SkillMenu`'s teleport list, which this mirrors).
    def use_special_teleport_item(id, actor, state, map_id)
      it = db_item(id)
      # Only a genuine type-9 special item takes this free-warp fast path --
      # see #use_special_escape_item's own citation just above; the same
      # item-menu/skill-use dispatch gap applies to
      # Teleport-type skills identically.
      return nil unless it && it.type == ITEM_SPECIAL &&
                        actor && item_usable_by?(it, actor.id)
      target = cast_teleport_skill(actor, it.skill_id, state, map_id, true)
      return nil unless target
      consume_item_use(id)
      target
    end

    # The same for a special item invoking a **Switch**-type skill: flip
    # its switch for free (the item pays, not `actor`'s SP) and return the
    # switch id to turn on, or nil when `id` does not name such an item or
    # `actor` may not use it -- ported from a reference implementation's
    # source, NOT
    # independently confirmed against genuine RPG_RT under wine:
    # its Switch-type skill arm
    # sits right beside its Escape/Teleport siblings, unconditionally
    # consuming the item and flipping the skill's own switch id (not the
    # item's) on the very same Decision press, no `Game::
    # State` needed unlike Escape/Teleport's registered-target lookup.
    def use_special_switch_item(id, actor)
      it = db_item(id)
      return nil unless it &&
                        (it.type == ITEM_SPECIAL ||
                         (it.use_skill && (1..5).cover?(it.type))) &&
                        actor && item_usable_by?(it, actor.id)
      switch = cast_switch_skill(actor, it.skill_id, true)
      return nil unless switch
      consume_item_use(id)
      switch
    end

    # A single-target medicine (scope 0) heals `actor`; an all-ally medicine
    # (scope 1) heals the whole party regardless of `actor`. Applies the recovery
    # (clamped to each target's maxima) and cures the item's status conditions,
    # and consumes one from the bag only when it actually did something to someone
    # (so using it on a full, unafflicted party wastes nothing).
    def use_medicine(it, id, actor)
      targets = it.scope == 1 ? @actors : [actor].compact
      cured = item_cured_states(it)
      affected = []
      targets.each do |t|
        # A downed target blocks the item outright unless it's a revive (one
        # that cures 戦闘不能) -- ported from a reference implementation's
        # source, NOT
        # independently confirmed against genuine RPG_RT under wine:
        # it checks whether the target is dead
        # *before* anything else and returns `false` immediately -- no state
        # cure, no HP change, no SP change at all -- unless `item->state_set
        # [0]` (state id 1, Death) is flagged. Without this, an ordinary
        # medicine with no Death cure (an Antidote that only cures Poison, or
        # a plain HP/MP potion) used on a KO'd member with some other
        # affliction silently cured it and/or topped up MP and consumed the
        # item -- `#change_hp` already happens to no-op for a dead actor on
        # its own (`return @hp if dead?`), which is what hid this for the HP
        # half alone, but the cure loop and `#change_mp` below have no such
        # guard of their own.
        next if t.dead? && !cured.include?(Game::Actor::DEATH_STATE)
        # A 蘇生専用 item passes over anyone still standing without touching
        # them -- not even the HP restore -- which is what keeps an all-party
        # revive from topping up the members who never fell. An actor_set
        # restriction does the same for a member the item simply is not
        # usable on, even under an all-party scope.
        next if ko_only_blocked?(it, t) || !item_usable_by?(it, t.id)
        changed = false
        was_dead = t.dead?
        # Cure first: a revive item (curing 戦闘不能) stands the actor back up so
        # the HP recovery below lands instead of being blocked as a no-op.
        cured.each do |s|
          if t.state?(s)
            t.remove_state(s)
            changed = true
          end
        end
        # Whether curing Death just revived `t` -- #remove_state's own
        # bare-revival fallback already floors it to 1 HP the instant Death
        # comes off, matching a reference implementation's own state-removal
        # handling (ported from its
        # source, NOT independently confirmed against genuine RPG_RT under
        # wine). That same source then adds the recovery amount minus the
        # revival floor,
        # not the full recovery, on top of that floor,
        # so a combined revive+HP
        # item must not add its full recovery on top of the 1 HP the cure
        # already granted.
        revived = was_dead && !t.dead?
        hp, mp = item_recovery(it, t)
        before_hp = t.hp
        before_mp = t.mp
        t.change_hp(revived ? hp - 1 : hp) if hp > 0
        t.change_mp(mp) if mp > 0
        changed ||= t.hp != before_hp || t.mp != before_mp
        affected.push(t) if changed
      end
      consume_item_use(id) unless affected.empty?
      affected
    end

    # A skill book teaches its skill (item field 53) to `actor` if the actor does
    # not already know it, consuming one book. A book with no skill, or used on an
    # actor who already knows the skill, does nothing and is not consumed.
    #
    # A Skill Book/Seed does nothing on a downed actor: not consumed, no effect
    # -- confirmed directly against genuine RPG_RT.exe under wine (cycle #156;
    # the prior comment here cited what it called "RPG_RT's own live source",
    # but that was a reference implementation's own
    # reimplementation, not RPG_RT's own source, which Anthropic has never had
    # access to -- the citation was wrong, though the underlying claim held up
    # once independently re-tested). Nepheshel's own item 401 (a Seed, +5 max
    # HP) used from the field Item menu on its own "デモ用" test actor (level
    # 50, hp/max_hp 600) via a raw Save01.lsd edit (chunk 108's own hp/state
    # fields, no synthetic map event at all -- see the methodology note below)
    # gave two directly comparable genuine screenshots: on a live target
    # (600/600 HP) the item count fell 3 -> 2 and Max HP rose to 605 in the
    # same target-confirm window; on the identical actor downed to 0/600 HP
    # (戦闘不能, the genuine incapacitated status, shown in the RPG_RT.exe menu
    # itself) applying the identical item left the count at 3 and HP/MaxHP
    # completely unchanged -- unlike Medicine, the one item type genuinely
    # meant to work on the dead (`#ko_only_blocked?`'s own `it.ko_only` case),
    # Book/Seed have no such exception. (Methodology note for whoever extends
    # this: editing chunk109's own party-roster field (`SAVE_INVENTORY`'s
    # `party`), even a same-length single-element swap, reliably crashed
    # genuine RPG_RT.exe under wine on this exact save/map the instant the
    # field menu was opened -- so this test left it untouched and used
    # whichever actor the save already, genuinely led with instead of adding
    # a second party member. Root cause since found (kk1.12, a later
    # session): `#to_lsd` wrote the roster into field 1 alone as a raw
    # int8_array and never wrote field 2 at all, but liblcf's own
    # generator/csv/fields.csv documents field 1 as the roster vector's
    # *count* and field 2 as its *data* -- the same count-then-data split
    # item_count/item_ids (11/12) already use. A save missing the data field
    # that a genuine RPG_RT.exe itself always writes crashes it on load
    # regardless of what the count says, roster edited or not; see
    # SAVE_INVENTORY's own comment. Separately, and unrelated to this claim: a
    # synthetic autostart map event of 2+ commands reliably wedges or crashes
    # genuine RPG_RT.exe on the very next Cancel/menu-open press on this same
    # save/map, reproducing cycles #137-151's own open "autostart-crash
    # mystery" fresh this session -- not investigated further here, since a
    # pure save-file edit sidesteps it entirely.)
    def use_skill_book(it, id, actor)
      skill = it.skill_id
      return [] unless actor && !actor.dead? && item_usable_by?(it, actor.id) &&
                       skill && skill != 0 && !actor.knows_skill?(skill)
      actor.learn_skill(skill)
      consume_item_use(id)
      [actor]
    end

    # The six permanent stat boosts a seed grants, in Actor::STAT_NAMES order
    # (max HP, max SP, attack, defence, spirit, agility). RPG2000 seeds use the
    # item's max_hp_points / max_sp_points and the *_points2 stat set -- distinct
    # from the *_points1 fields that carry equipment bonuses. Confirmed
    # directly against genuine RPG_RT.exe under wine (cycle #157, replacing a
    # former citation to a reference implementation's seed handling that was
    # never itself independently checked): Nepheshel206beta's own item 403 (a real
    # shipped "seed", 赤いドロップ/Red Drop, atk_points2=2) was duplicated with
    # atk_points1 additionally set to 77 on a second copy of the database, then
    # used from the field Item menu on the save's live leader in two
    # side-by-side genuine runs, ATK read via the Equip screen both times: the
    # unmodified item raised ATK 870 -> 872 (+2); the atk_points1=77 variant
    # raised it 870 -> 872 too, the identical +2, not +77 or +79, while the
    # item's name/description and its held count (1 -> 0 both runs) stayed
    # exactly the same, ruling out "the edit was silently ignored" as an
    # alternative explanation. See the matching regression check in
    # scripts/rpg2k_logic_check.rb ("a seed permanently raises the target
    # stats (points2 set, not points1)...") for the full write-up.
    def seed_boosts(it)
      [it.max_hp_points || 0, it.max_sp_points || 0,
       it.atk_points2 || 0, it.def_points2 || 0,
       it.spi_points2 || 0, it.agi_points2 || 0]
    end

    # A seed permanently raises `actor`'s base stats by seed_boosts (each applied
    # through Actor#change_param, so RPG2000's stat caps hold). Consumes one when
    # it carries any boost; a seed with no boost does nothing and is not consumed.
    # A Seed does nothing on a downed actor -- see #use_skill_book's own
    # comment for the full genuine-RPG_RT.exe evidence (cycle #156); this
    # shares the identical dead-actor guard.
    def use_seed(it, id, actor)
      return [] unless actor && !actor.dead? && item_usable_by?(it, actor.id)
      boosts = seed_boosts(it)
      return [] unless boosts.any? { |b| b != 0 }
      boosts.each_index { |i| actor.change_param(i, boosts[i]) if boosts[i] != 0 }
      consume_item_use(id)
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
    # [id, count] pairs **in the bag's own stored order, not ascending id
    # order** -- the candidate list for the equip menu's chosen slot.
    # Confirmed against genuine RPG_RT.exe under wine (cycle #250): a save
    # whose chunk-109 `item_ids` were written deliberately out of order
    # ([30, 27, 29, 28, 26, 66, 177], each with a distinct count so a listed
    # row identifies its id) opened the equip screen's weapon grid reading
    # 30/27/29/28/66 in exactly that order, and a fourteen-weapon rerun
    # ([44, 27, 45, 28, 46, 29, 47, 30, 48, 31, 49, 32, 50, 33]) listed all
    # fourteen the same way -- the same "stored order, never re-sorted"
    # rule cycle #252 measured for the field/battle Item lists. `@items` is
    # built in the save's own order by `Game::State.from_lsd`, so simply
    # not sorting here reproduces it. `actor` matters two ways: for the shield slot
    # (1), a 二刀流 (double_hand) actor's shield slot is a second weapon slot,
    # so it lists weapons there instead of shields -- mirroring a reference
    # implementation, not independently confirmed against genuine RPG_RT
    # under wine, which retargets the whole slot to weapon for such
    # an actor before filtering, rather than offering both kinds; and an
    # actor_set restriction (#item_usable_by?) drops an item this particular
    # actor cannot wear at all, matching that same source's equip-change
    # path, which reads the restriction the same way. Both actor-dependent filters are
    # simply skipped when no `actor` is given.
    def equip_candidates(slot, actor = nil)
      slot = Actor::WEAPON_SLOT if slot == Actor::SHIELD_SLOT && actor && actor.double_hand?
      @items.keys.select do |id|
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

    # Equip `item_id` on `actor` into equipment `slot`, moving it through the
    # inventory: take one from the bag if held, equip it, and return the
    # previously-equipped item (if any) to the bag. Shared mechanics behind
    # #equip_from_bag (the equip menu) and #equip_item_from_bag (the Change
    # Equipment event command) -- see each for the gating layered on top.
    def swap_equipment_through_bag(actor, item_id, slot)
      previous = actor.equipment[slot]
      # A 両手持ち weapon empties the other hand; whatever it was holding comes
      # back to the bag alongside the item this slot displaced.
      freed = actor.equip_item(item_id, slot)
      lose_item(item_id, 1)
      gain_item(previous, 1) if previous && previous != 0
      gain_item(freed, 1) if freed && freed != 0
      true
    end
    private :swap_equipment_through_bag

    # Equip bag item `item_id` on `actor` into equipment `slot`, the way the
    # equip menu does. `slot` defaults to the one the item's own type dictates
    # (so the Item menu's field-usable-item paths that never pass one keep
    # working unchanged); the equip menu always passes the slot its candidate
    # list (#equip_candidates) was built for, which is what lets a 二刀流
    # actor's second weapon land in the shield slot rather than overwriting the
    # first. A no-op returning false unless the party holds the item and it is
    # a genuine candidate for that slot on that actor (#equip_candidate_for?);
    # true on success. (Unlike the Change Equipment event command, which also
    # equips an item the party does not hold -- see #equip_item_from_bag --
    # the menu only ever offers what #equip_candidates already lists as held.)
    def equip_from_bag(actor, item_id, slot = nil)
      return false unless actor && item_count(item_id) > 0
      slot ||= equip_slot_for(item_id)
      return false if slot.nil? || !equip_candidate_for?(actor, item_id, slot)
      swap_equipment_through_bag(actor, item_id, slot)
    end

    # Equip `item_id` on `actor`, the way the Change Equipment event command
    # does: a copy already in the bag is consumed exactly as #equip_from_bag
    # would, but -- unlike the menu -- an item the party does not hold is
    # still equipped, RPG_RT fabricating a new copy rather than refusing
    # (community デフォ戦bot trivia: "held in the bag, equip from there; not
    # held, a new copy is created and equipped"; #lose_item's own floor-at-0
    # clamp is what makes consuming an unheld item a no-op instead of going
    # negative). The previously-equipped item, and any item a two-handed swap
    # frees, still return to the bag exactly as #equip_from_bag does. `slot`
    # is always the item's own type-based slot (the event command names no
    # slot, unlike the menu's candidate-list-driven choice); a non-equippable
    # or unknown item id is a no-op, matching a reference implementation's own
    # type-switch
    # default (ported, NOT independently confirmed against genuine RPG_RT
    # under wine). Callers apply any actor_set restriction themselves (per target,
    # same as #equip_candidate_for? would) before calling this.
    #
    # A 二刀流 (double_hand) actor gets the same dual-wield redirect
    # `Scene::EquipMenu` gets structurally from #equip_candidates, since this
    # command bypasses the candidate list entirely -- ported from a reference
    # implementation's
    # source, NOT independently confirmed against genuine RPG_RT under wine:
    # its own change-equipment command handler
    # special-cases the double-wield check before its
    # own equip call: a shield-type item is a complete no-op
    # (`continue`, nothing equipped, nothing consumed); a weapon-type item
    # equips into the *shield* slot instead when the weapon slot already
    # holds a (non-two-handed) weapon, the shield slot is empty, and the new
    # weapon is not two-handed either -- otherwise it falls through to the
    # ordinary weapon-slot overwrite. Previously this method equipped purely
    # by item type regardless of `double_hand?`, so a scripted "learn 二刀流,
    # here is your second blade" event overwrote the first weapon instead of
    # filling the empty second slot, and handing such an actor a shield
    # silently jammed it into their off-hand weapon slot instead of being
    # the no-op real RPG_RT makes it.
    def equip_item_from_bag(actor, item_id)
      return false unless actor
      slot = equip_slot_for(item_id)
      return false if slot.nil?
      if actor.double_hand?
        return false if slot == Actor::SHIELD_SLOT
        if slot == Actor::WEAPON_SLOT
          weapon = actor.equipment[Actor::WEAPON_SLOT]
          shield = actor.equipment[Actor::SHIELD_SLOT]
          if weapon && weapon != 0 && (shield.nil? || shield == 0) &&
             !actor.two_handed?(weapon) && !actor.two_handed?(item_id)
            slot = Actor::SHIELD_SLOT
          end
        end
      end
      swap_equipment_through_bag(actor, item_id, slot)
    end

    # Unequip `actor`'s `slot`, returning the removed item to the bag. 0..4
    # empties that one slot; EQUIP_ORDER.size (5) empties every slot, each
    # returning its own item to the bag in turn -- matching a reference
    # implementation's "remove all" case (not independently confirmed
    # against genuine RPG_RT under wine), which
    # is just this same per-slot swap looped over every slot.
    # Returns the removed item id (0 when the slot was already empty,
    # the slot is invalid, or "every slot" was requested -- there is no single
    # id to report there).
    def unequip_to_bag(actor, slot)
      return 0 unless actor
      if slot == Actor::EQUIP_ORDER.size
        Actor::EQUIP_ORDER.size.times { |s| unequip_to_bag(actor, s) }
        return 0
      end
      return 0 unless slot >= 0 && slot < Actor::EQUIP_ORDER.size
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

    # `db.term.<name>` as-is, or '' when the field doesn't exist or the
    # database carries no term table at all -- mirrors every scene's own
    # `#term` (`Scene::Base`), the shared reader for vocabulary a project can
    # rename. `Game::Interpreter` has no scene of its own to ask (it can run
    # outside one entirely, e.g. a common event), so it reads the database's
    # words through its party instead.
    def term(name)
      t = @db.respond_to?(:term) ? @db.term : nil
      s = t && t.respond_to?(name) ? t.send(name) : nil
      s.to_s
    end

    # The database's state (`situation`) table, for Game::States lookups --
    # priority, display name/colour, message text. nil for a fixture without
    # one, which every Game::States accessor already tolerates.
    def state_table
      @db.respond_to?(:situation) ? @db.situation : nil
    end

    # The SP `caster` pays to cast skill `sk`: a fixed cost (sp_type 0) or, on
    # an RPG2003 database only, a percentage of the caster's max SP (sp_type
    # 1). Ported from a reference implementation, NOT independently
    # confirmed against genuine RPG_RT under wine:
    # `(rpg2003? && skill.sp_type == percent) ? max_sp *
    # sp_percent / 100 / div : (sp_cost + half_sp_cost) / div`. RPG2000's
    # editor has no percent-cost UI at all, so the `rpg2003?` gate mirrors
    # `#calc_exp`'s own edition split rather than trusting a stray sp_type
    # byte a hand-edited RPG2000 database happened to carry.
    #
    # MP消費半分 gear halves the bill (`div` 2, else 1) -- but the two branches
    # round the halving *differently*, and it must stay that way rather than
    # applying one shared `(cost + 1) / 2` to whichever cost came out: a
    # fixed cost rounds **up** first (`+1` before the divide, so a 1-SP skill
    # still costs 1, not 0), while a percent cost has no such `+1` at all and
    # simply floors. Halving a percent-based cost via the fixed-cost rounding
    # used to overcharge by up to 1 SP whenever the intermediate percent cost
    # came out odd -- a 33-max-SP caster with half-cost gear casting a 10%
    # RPG2003 skill paid 2 SP (`(3 + 1) / 2`) instead of the correct 1
    # (`3 / 2`), a full 100% overcharge for that combination.
    def skill_cost(sk, caster)
      half = caster.respond_to?(:half_sp_cost?) && caster.half_sp_cost?
      div = half ? 2 : 1
      if rpg2003? && sk.sp_type == 1
        caster.max_mp * (sk.sp_percent || 0) / 100 / div
      else
        ((sk.sp_cost || 0) + (half ? 1 : 0)) / div
      end
    end

    # The rows the field Skill screen lists for `caster`, as `[skill_id, cost]`
    # pairs: **every** skill the actor knows, in the actor's own `#skills`
    # order -- confirmed against genuine RPG_RT.exe under wine (cycle #241,
    # 2026-09-06): a save whose leader's chunk-108 skill list was written as
    # `[32, 1, 33, 34, ...]` (a field heal, then an enemy-only wind attack,
    # then two more heals) showed exactly that order on the real screen,
    # マーフェ / サー / カル・マーフェ / ミラ・マーフェ ..., not the
    # ascending-id order this method used to `.sort` into; and the
    # enemy-scope サー / バマー / ハガザーム / チャレク rows, the
    # defence-buff ルーツ, the battle-only-state cures ハサウ / ルフィク /
    # ベルナ / 加護, an effect-less 結界護符 and a switch skill flagged
    # battle-only ([ブースト], `occasion_field` off) were all *listed* --
    # drawn in the windowskin's disabled colour, Decision doing nothing on
    # them -- rather than hidden. So this no longer filters on
    # `#field_skill?` at all; that (plus `#can_cast?`) is purely the
    # greyed-out / cannot-activate check `Scene::SkillMenu#skill_unavailable?`
    # applies per row. `state` is accepted for callers that have one to pass
    # (the scene threads it through for that usability check), but nothing
    # here reads it.
    #
    # Whether the actor's own `#skills` order is ever *not* ascending in a
    # save genuine RPG_RT itself wrote is a separate, still-open question --
    # `#learn_skill` keeps sorting on learn on its own (separately reasoned)
    # grounds; this method simply stops re-sorting what it is given, so a
    # hand-ordered save reads the same in both runtimes.
    #
    # A database shrink can leave a learned skill id with no matching row
    # (docs/TODO.md's runtime error catalog) -- `db_skill` degrades that to a
    # silent `nil`, and `#field_skill?`'s `return false unless sk` would drop
    # the skill from the menu with no trace. Logged here, at the one place
    # that knows the gap came from a *caster's own* skill list rather than
    # from some other `db_skill` call with no menu behind it.
    def field_skills(caster, _state = nil)
      return [] unless caster
      caster.skills.select do |sid|
        sk = db_skill(sid)
        if sk.nil?
          $stderr.puts "[RPG2k] Skill menu: caster's learned skill ##{sid} " \
                       'has no matching database row, excluding from field menu'
          next false
        end
        true
      end.map { |sid| [sid, skill_cost(db_skill(sid), caster)] }
    end

    # Whether skill row `sk` is *usable* from the field menu -- the greyed-
    # out / Decision-does-nothing check for a listed row, not list
    # membership (every known skill is listed; see #field_skills' own
    # cycle-#241 write-up, whose genuine-RPG_RT captures greyed exactly the
    # rows this returns false for: enemy scope, stat/attribute buffs,
    # battle-only-state cures, battle-only switch skills).
    #
    # The `occasion_field` / `occasion_battle` flags gate **switch skills only**.
    # That is not a simplification: the RPG2000 editor only offers the
    # 使用可能な場面 checkboxes for a スイッチ skill in the first place, so no
    # non-switch skill row can even carry these flags in a genuine database.
    # The bytes agree exactly: Nepheshel writes chunks 18/19 for 12 of its 306
    # skills and those 12 are precisely its 12 switch skills, while
    # mtf-meido-action, which has no switch skill, writes neither chunk for
    # any of its 134. Gating every skill on `occasion_battle` (default false,
    # so almost never set) is what used to leave the battle skill menu
    # holding 12 skills in one game and none at all in the other.
    #
    # An ordinary skill outside battle needs a target the field can offer (scope
    # >= 2, i.e. self or allies -- there is no enemy to aim at) and has to do
    # something once there: change HP/SP, or inflict a state.
    def field_skill?(sk, state = nil)
      return false unless sk
      case sk.type
      when SKILL_TELEPORT, SKILL_ESCAPE
        # A known Escape/Teleport skill is *always* listed on the field
        # menu, whether or not it is usable right this moment -- ported from
        # a reference implementation, NOT independently confirmed against genuine
        # RPG_RT under wine: its list-inclusion check
        # simply returns true
        # outside battle, with no per-type filter at all.
        # `#escape_skill_available?`/`#teleport_skill_available?` (access,
        # a registered target, not flying) are that same source's own
        # enable-check
        # logic, which only backs whether the entry greys out (greying the
        # entry / Buzzing on selection, `Scene::SkillMenu#choose_skill`) --
        # a genuinely separate real-engine check this method used to
        # conflate with list membership, hiding the skill outright instead
        # of listing it disabled.
        true
      when SKILL_SWITCH
        field_occasion?(sk)
      else
        return false unless sk.scope >= 2
        # The raw state set, not #skill_inflicted_states: a plain antidote cures
        # rather than inflicts (`reverse_state_effect` off), and curing poison
        # between fights is the whole point of the field skill menu. A
        # state-only skill (no affect_hp/affect_sp) only counts if at least
        # one of the states it touches actually "Continues after battle" --
        # ported from a reference implementation, NOT independently confirmed against
        # genuine RPG_RT under wine: its own usability check,
        # called with a persistence requirement hard-forced on for this exact
        # purpose, only
        # counts a state effect entry when the state's own type marks it as
        # persisting -- a battle-only state (the schema default,
        # `Battle::STATE_PERSISTS_ON_MAP`'s own inverse) never makes the
        # skill field-usable, even though it's a perfectly ordinary skill in
        # battle. A dangling/unknown state id fails the same way the
        # reference's own `state &&` guard does -- not usable.
        sk.affect_hp || sk.affect_sp ||
          skill_state_ids(sk).any? do |id|
            row = Game::States.row(id, state_table)
            row.respond_to?(:type) && (row.type || 0) == Battle::STATE_PERSISTS_ON_MAP
          end
      end
    end

    # Whether the Escape skill type (1) is usable right now: the party's escape
    # access is on, a Set Escape Target has registered a destination, and the
    # party is not flying (boarded the airship). Mirrors a reference
    # implementation's own Escape-type usability check, minus the "not in
    # battle" term — not independently confirmed against genuine RPG_RT
    # under wine —
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
    # picker (a reference implementation's own teleport screen, which lists every
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
    # registered escape destination as `{map_id:, x:, y:, switch_id:}` for the
    # scene to jump to (switch_id nil when the target has none), or nil when
    # `sid` is not a castable, available Escape skill. Ported from a
    # reference implementation's skill-cast path, NOT independently confirmed
    # against genuine RPG_RT under
    # wine: it jumps straight to the single registered escape
    # target with no picker; `switch_id` mirrors that same source's own
    # target-reserving step, which flips the target's switch when one is
    # set, applied by the
    # scene's own #queue_teleport once the warp itself lands.
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
      { map_id: target[:map_id], x: target[:x], y: target[:y], switch_id: target[:switch_id] }
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
      { map_id: map_id, x: target[:x], y: target[:y], switch_id: target[:switch_id] }
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
    # `free`, when true, skips the SP-cost gate/spend entirely -- the same
    # `free` flag `#cast_escape_skill`/`#cast_teleport_skill` already carry,
    # for a special/use_skill item's invoked switch skill (the item pays,
    # not the caster's SP; see #use_special_switch_item).
    def cast_switch_skill(caster, sid, free = false)
      return nil unless switch_skill?(sid) && (free ? !caster.nil? : can_cast?(caster, sid))
      sk = db_skill(sid)
      caster.change_mp(-skill_cost(sk, caster)) unless free
      sk.switch_id
    end

    # Whether `caster` can cast skill `sid` right now: it knows the skill, can
    # pay its SP cost, (see #weapon_attribute_ready?) is not missing a
    # required weapon-type Attribute, and (see Actor#skill_sealed?) is not
    # currently under a state that seals it -- ported from a reference
    # implementation's own usability check,
    # NOT independently confirmed against genuine RPG_RT
    # under wine: it checks the identical seal
    # unconditionally, in or out of a fight, and this is the field-menu's own
    # gate through which every field skill-cast path (#field_skill?/
    # #field_skills, #skill_effective?, #cast_skill/#cast_switch_skill)
    # already funnels. `Game::Battle#skill_sealed?` is this method's own
    # in-battle twin, already correct; a field-cast skill had no such check
    # at all until now.
    def can_cast?(caster, sid)
      sk = db_skill(sid)
      !sk.nil? && caster && caster.knows_skill?(sid) &&
        caster.mp >= skill_cost(sk, caster) && weapon_attribute_ready?(caster, sk) &&
        !(caster.respond_to?(:skill_sealed?) && caster.skill_sealed?(sk))
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
    # something looser. An `affect_attr_defence` skill (a resistance-shift
    # buff, see `#apply_attr_shift`) is exempt from this whole check,
    # regardless of which attribute it names -- ported from a reference
    # implementation's
    # source, NOT independently confirmed against genuine RPG_RT under wine:
    # its actor-level usability check
    # wraps its entire weapon-equip loop in this same exemption,
    # and none of that source's other usability checks have any such
    # check at all -- it exists only at that one actor level, guarded
    # by that flag. yado.tk's own text (cited above) never mentions the
    # exemption.
    def weapon_attribute_ready?(caster, sk)
      return true unless sk
      return true if sk.respond_to?(:affect_attr_defence) && sk.affect_attr_defence
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
    # afterwards too, matching a reference implementation's own stat accessor
    # being the one
    # accessor every context reads through, not a battle-only variant --
    # ported, NOT independently confirmed against genuine RPG_RT under wine).
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

    # `base` plus `b`'s own `mod_field` offset (a battle `Combatant`'s
    # `#atk_mod`/`#def_mod`/`#spi_mod`/`#agi_mod`, see `Game::Battle
    # #apply_stat_mods` -- a bare field-side `Game::Actor` has no such field
    # and reads a no-op 0 offset instead), clamped to 1..`Battle::
    # MAX_STAT_BATTLE_VALUE` the same way a reference implementation's own
    # stat-adjustment helper does before a state's own halve/double gets a
    # say (not independently confirmed against genuine RPG_RT under wine)
    # -- mirroring
    # `Game::Battle#modified_stat`'s identical clamp-then-adjust order, since
    # a reference implementation's own Atk/Def/Spi accessors are the one
    # accessor every
    # context (a basic Attack, a Skill, in battle or, for HP/SP only, out of
    # it) reads through.
    def modified_stat(base, b, mod_field)
      mod = b.respond_to?(mod_field) ? (b.send(mod_field) || 0) : 0
      Game.clamp(base + mod, 1, Battle::MAX_STAT_BATTLE_VALUE)
    end

    def effective_atk(b)
      adjust_stat(modified_stat(b.atk, b, :atk_mod), stat_mode(b, :affect_attack))
    end

    def effective_int(b)
      adjust_stat(modified_stat(b.int, b, :spi_mod), stat_mode(b, :affect_spirit))
    end

    def effective_def(b)
      base = (b.respond_to?(:def) ? b.def : 0) || 0
      adjust_stat(modified_stat(base, b, :def_mod), stat_mode(b, :affect_defense))
    end

    def effective_spi(b)
      base = (b.respond_to?(:spi) ? b.spi : 0) || 0
      adjust_stat(modified_stat(base, b, :spi_mod), stat_mode(b, :affect_spirit))
    end

    def effective_agi(b)
      base = (b.respond_to?(:agi) ? b.agi : 0) || 0
      adjust_stat(modified_stat(base, b, :agi_mod), stat_mode(b, :affect_agility))
    end

    # The base HP/SP amount a recovery skill restores, per RPG2000's formula
    # `power + physical_rate*attack/20 + magical_rate*spirit/40` (spirit is the
    # `int` stat), computed from the caster deterministically -- battle applies a
    # +/- variance, but field/menu use does not. Ported from a reference
    # implementation's own skill-effect formula, NOT independently confirmed against genuine
    # RPG_RT under wine (the ally-heal path has no target-defence term).
    def skill_effect(sk, caster)
      (sk.power || 0) +
        (sk.physical_rate || 0) * effective_atk(caster) / 20 +
        (sk.magical_rate || 0) * effective_int(caster) / 40
    end

    # How much of an enemy-scope skill's effect the target's own stats absorb.
    #
    # Ported from a reference implementation's own skill-effect formula, NOT
    # independently
    # confirmed against genuine RPG_RT under wine: the defence is scaled by
    # the *same two rates* that built the effect -- `physical_rate * def / 40
    # + magical_rate * spi / 80` -- so a physical skill is blunted by armour
    # and a magical one by the target's spirit. This used to be a flat
    # `def / 4`, which only coincides with that ported term when the skill is
    # purely physical at rate 10: 211 of Nepheshel's 276 enemy-scope skills
    # and 112 of mtf's 116 differ from it against a def-40 / spirit-40
    # target, and 141 and 81 of them are *purely magical*, so they were being
    # blunted by armour the caster's spell should not have cared about at
    # all.
    #
    # 0 when the skill ignores defence (the ported behavior skips the whole
    # subtraction) or there is no target to read stats from.
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
    # state, index i -> state id i+1). Per a reference implementation's own
    # skill-use path (not independently confirmed against genuine RPG_RT
    # under wine), the
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

    # Whether an enemy AI's own self/ally/troop-scope skill action `sk` could
    # possibly help anyone on `caster`'s side (`troop`, its full battle Combatant
    # roster including out-of-play members) -- ported from a reference
    # implementation's own enemy-AI target-effectiveness checks, NOT
    # independently confirmed against genuine RPG_RT under wine, which it
    # believes the real engine consults before letting an
    # AI-selected skill enter its weighted draw at all: an enemy-scope skill
    # (0 single enemy / 1 all enemies, aimed at the *party*) is always
    # considered worth trying -- RPG_RT never checks whether the party side
    # could be affected -- so only scope 2/3/4 (self/single ally/all allies,
    # always the caster's own troop) is filtered here, against `caster` alone
    # for scope 2 or every troop member for 3/4 (the real engine does not
    # distinguish single- from all-ally scope for this purpose, since a single
    # target is chosen only after an action is already selected). This port
    # always runs the *actual* RPG_RT behaviour (that source's own "emulate
    # the authentic bugs" mode
    # -- its alternate bug-fixed "RPG_RT+" algorithm is never selected here,
    # matching every other "authentic engine vs. improved-variant"
    # choice elsewhere in this file), which collapses two of the ported
    # function's branches to their `emulate_bugs` side outright: a
    # Knockout-flagged (state id 1, a revival) skill reads as effective on any
    # hidden/downed troop member purely from the flag being set -- an
    # authentic bug, ignoring `reverse_state_effect` and whether the target is
    # actually the one that is dead -- and an RPG2003 ally-scope skill with
    # `reverse_state_effect` set (see `#battle_skill_command`'s `heals_states`)
    # is checked by whether the target already *has* the state, the same as
    # an ordinary cure, rather than by whether inflicting it would do
    # anything.
    def skill_helps_troop?(sk, caster, troop)
      return true unless Party.normal_skill?(sk)
      scope = sk.respond_to?(:scope) ? sk.scope : 0
      return true if scope == 0 || scope == 1
      targets = scope == 2 ? [caster] : troop
      states = skill_state_ids(sk)
      targets.any? do |t|
        next false unless t
        if t.out_of_play?
          states.include?(1)
        else
          sk.affect_hp || sk.affect_sp || !skill_stat_mod_keys(sk).empty? ||
            states.any? { |sid| t.state?(sid) } ||
            (sk.respond_to?(:affect_attr_defence) && sk.affect_attr_defence && !skill_attributes(sk).empty?)
        end
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
        was_dead = t.dead?
        cured.each do |s|
          if t.state?(s)
            t.remove_state(s)
            changed = true
          end
        end
        # Whether curing Death just revived `t` -- #remove_state's own
        # bare-revival fallback already floors it to 1 HP the instant Death
        # comes off, matching a reference implementation's own state-removal
        # handling (not independently confirmed against genuine RPG_RT under
        # wine).
        revived = was_dead && !t.dead?
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
        t.states = Game::States.prune(t.states, state_table, keep: t.permanent_states) if landed
        before_hp = t.hp
        before_mp = t.mp
        if sk.affect_hp && amount > 0
          # Same `- revived` treatment as the Affect-HP-off branch just
          # below: a combined revive+HP skill must not add its full amount
          # on top of the 1 HP the Death cure above already granted --
          # ported from a reference implementation's own skill-use path, NOT
          # independently confirmed against genuine RPG_RT under wine: it
          # applies
          # the same revive-adjusted amount here too, not just in its
          # HP-percentage sibling branch.
          t.change_hp(revived ? amount - 1 : amount)
        elsif revived && amount > 0 && t.max_hp
          # A revival skill with Affect HP off heals a percentage of max HP
          # instead of leaving `t` on the bare revival floor of 1 -- ported
          # from a reference implementation, NOT independently
          # confirmed against genuine RPG_RT under wine, the out-of-
          # battle counterpart to its identical in-battle
          # rule (see Game::Battle#apply_skill_hit's own citation), with
          # that source's own comment claiming: "If
          # Death is cured and HP is not selected, we set a bool so it later
          # heals HP percentage" -- a percentage of max HP minus the revival floor,
          # additive on top of the cure's own HP-to-1
          # (`revived` there is the literal int 1, the same role `- 1`
          # plays here).
          t.change_hp(t.max_hp * amount / 100 - 1)
        end
        # `!t.dead?` mirrors a reference implementation's own skill-use SP
        # branch (ported from its source, NOT independently confirmed against
        # genuine RPG_RT under wine): `effect > 0 && skill->affect_sp &&
        # !HasFullSp() && !IsDead()`, the exact same `!IsDead()` guard its HP
        # sibling carries just above. `t.dead?` here already reflects any
        # Death cure this same loop iteration just applied (`cured.each`,
        # above), so a genuine revive skill with Affect SP on still restores
        # SP correctly -- only a target still dead at this point (the skill
        # did not cure Death) is blocked, matching the reference exactly.
        # `#change_hp`'s own `return @hp if dead?` guard gives the HP branch
        # this same protection incidentally; `#change_mp` has no such guard
        # of its own, so this needed to be explicit here.
        t.change_mp(amount) if sk.affect_sp && amount > 0 && !t.dead?
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

    # `sk.hit == -1` is a sentinel meaning "use the caster's own weapon-based
    # hit chance" rather than a fixed rate -- ported from a reference
    # implementation's own to-hit formula,
    # NOT independently confirmed against genuine RPG_RT under wine: it
    # reads it as its very first line, unconditionally, for
    # every skill (not gated behind any extension-only flag the way
    # the row terms a few lines further down are): the skill's own hit field,
    # or the caster's weapon-based hit chance when that field is the -1
    # sentinel. A `Combatant`
    # snapshot (every real caller today) already carries that merged figure
    # as its own `hit_rate` -- the same field `Game::Battle#to_hit` reads for
    # an ordinary Attack; a bare `Game::Actor`/`Game::Enemy`, should one ever
    # reach this, falls back to `Battle.hit_rate_of` instead, the identical
    # `attack_hit_rate`-reading helper a fresh `Combatant` is seeded from.
    def skill_hit(sk, source)
      return skill_hit_weapon_fallback(source) if sk.respond_to?(:hit) && sk.hit == -1
      sk.respond_to?(:hit) ? (sk.hit || 100) : 100
    end

    def skill_hit_weapon_fallback(source)
      return source.hit_rate || 90 if source.respond_to?(:hit_rate)
      Battle.hit_rate_of(source)
    end

    # A Skill's to-hit chance, ported from a reference implementation's own
    # to-hit formula,
    # NOT independently confirmed against genuine RPG_RT under wine. The overwhelming majority of skills use a flat
    # `skill.hit` reading (already what `skill_hit` returns), which ignores the
    # target's agility the way RPG_RT's non-physical skill formula does. Only an
    # *enemy-scope* skill the editor flagged with the "physical" failure message
    # (`failure_message == 3`) runs the fuller, agility-adjusted, evasion-aware
    # physical formula — RPG2000's own editor hides that flag, so in practice it
    # survives only from converted / hex-edited projects and a handful of 2k3
    # databases, but RPG_RT still honours the bit whenever it is set (see the
    # "Not implemented: CalcSkillToHit" note in docs/TODO.md). `source` is the
    # caster, `target` the first foe the skill lands on.
    # RPG2003 row accuracy does **not** extend to physical skills. A reference
    # implementation gates both its row hit and row damage terms
    # behind an extension-only field
    # the RPG Maker 2003 editor cannot set (absent from every real 2003 file),
    # so a vanilla skill is never row-adjusted -- only a basic attack (#to_hit /
    # #deal_attack on Game::Battle) is. A prior draft applied the same back-row
    # penalty a pre-reference guess had used for attacks; the reference settles
    # it: skills are untouched by rows. See ADR 0053/0054.
    def skill_to_hit(sk, source, target)
      return skill_hit(sk, source) unless sk.respond_to?(:failure_message) && sk.failure_message == 3
      # The physical formula is enemy-only: an ally/self-scoped skill (scope 2/3/4)
      # always falls back to the flat rate regardless of the flag — a reference
      # implementation guards the whole physical branch behind
      # an ally-scope check, and its own comment notes the 2k3 editor
      # can no longer even set the flag, so the branch is reached only by skills
      # that still target the opposing side (scope 0 single / 1 all enemy).
      scope = sk.respond_to?(:scope) ? sk.scope.to_i : 0
      return skill_hit(sk, source) unless scope == 0 || scope == 1

      to_hit = skill_hit(sk, source)
      # A do-nothing-restricted target cannot dodge: the attack always connects.
      return 100 if do_nothing_restricted?(target)
      # The caster's own statuses (e.g. Blind) sour its aim first, before the
      # agility term — the same ordering `Game::Battle#to_hit` already uses for a
      # basic attack.
      to_hit = to_hit * hit_modifier(source) / 100
      # 必中: a source that ignores evasion skips the agility term entirely.
      return to_hit if source.ignores_evasion
      src = effective_agi(source)
      src = 1 if src < 1
      tgt = effective_agi(target)
      agi_adjusted = 100 - (100 - to_hit) * (src + tgt) / (2 * src)
      # 物理回避率アップ: a shield/armour/helmet/accessory flagged
      # `raise_evasion` subtracts a flat 25, after the AGI term.
      agi_adjusted -= 25 if target.evasion_up
      Game.clamp(agi_adjusted, 0, 100)
    end

    # Whether any state afflicting `b` forces "do nothing" (restriction 1), in
    # which case it cannot dodge a physical skill. Mirrors
    # `Game::Battle#do_nothing_restricted?` but reads the state table through
    # this party's own `@db.situation` (a battle-skill's caster/target is
    # sometimes a bare Game::Actor with no Battle behind it, see Party#stat_mode).
    def do_nothing_restricted?(b)
      return false unless b.respond_to?(:states)
      (b.states || []).each do |sid|
        d = @db.respond_to?(:situation) ? @db.situation[sid] : nil
        return true if d.respond_to?(:restriction) && (d.restriction || 0) == 1
      end
      false
    end

    # How much `b`'s own statuses cut its accuracy: the lowest `reduce_hit_ratio`
    # among its states (matching a reference implementation's own running-min
    # helper, not independently confirmed against genuine RPG_RT under wine).
    # 100 means unhindered. Part of #skill_to_hit's physical
    # formula, mirroring `Game::Battle#hit_modifier`.
    def hit_modifier(b)
      m = 100
      return m unless b.respond_to?(:states)
      (b.states || []).each do |sid|
        d = @db.respond_to?(:situation) ? @db.situation[sid] : nil
        r = state_hit_ratio(d)
        m = r if r < m
      end
      m
    end

    # A state's `reduce_hit_ratio`, defaulting to 100 (no reduction) for an
    # unknown state or a fixture row without the field.
    def state_hit_ratio(d)
      return 100 unless d.respond_to?(:reduce_hit_ratio)
      v = d.reduce_hit_ratio
      v.nil? ? 100 : v
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
    # unconfirmed guess; a reference implementation's source is what this was
    # ported
    # from instead (NOT independently confirmed against genuine RPG_RT under
    # wine): it
    # computes the shift as +1 when the skill is "positive" and -1 otherwise,
    # right where it applies `affect_attr_defence`, and that "positive" flag was set
    # a few lines earlier from whether the skill targets allies,
    # which is simply the negation of targeting enemies -- true for every scope
    # except Scope_enemy(0)/Scope_enemies(1). `reverse_state_effect` plays no
    # part in this at all (that flag's own state-cure/inflict role is
    # `IsPositive() ^ reverse` -- see #battle_skill_command's own
    # `heals_states`, confirmed against genuine RPG_RT under wine to apply
    # under RPG2000 too, not gated to RPG2003 the way a reference
    # implementation's own source guards it).
    # So the direction is purely the skill's own target scope: an ally-scoped
    # skill (self/single ally/all allies, the "buff"
    # shape) always raises resistance, an enemy-scoped one (single/all
    # enemies, the "curse" shape) always lowers it -- matching
    # #battle_skill_target's own enemy-scope test (`scope == 0 || scope ==
    # 1`). nil when the skill does not touch attribute defence at all.
    def skill_attr_shift(sk)
      return nil unless sk.respond_to?(:affect_attr_defence) && sk.affect_attr_defence
      sk.scope == 0 || sk.scope == 1 ? -1 : 1
    end

    # The (skill field name -> Combatant ability-value key) pairs
    # #skill_stat_mod_keys checks; distinct from `affect_attr_defence`
    # (#skill_attr_shift), which shifts a resistance *rank* rather than a raw
    # ATK/DEF/SPI/AGI value. A reference implementation (not independently
    # confirmed against genuine RPG_RT under wine)
    # rolls each of `affect_attack`/`affect_defense`/`affect_spirit`/
    # `affect_agility` independently, alongside `affect_hp`/`affect_sp`, all
    # against the *same* signed effect value -- `Game::Battle#apply_skill_hit`
    # now rolls all six the same independent way (`#skill_effect_hits?`),
    # matching this. A previous version of this comment recorded a deliberate
    # decision to leave all six unrolled "for consistency" rather than half-fix
    # the gap; the fix closed the whole thing symmetrically instead.
    SKILL_STAT_MOD_FLAGS = { atk: :affect_attack, def: :affect_defense,
                              spi: :affect_spirit, agi: :affect_agility }.freeze

    # Which of `{atk:, def:, spi:, agi:}` skill `sk` touches, per its own
    # affect_attack/affect_defense/affect_spirit/affect_agility flags (schema
    # fields 33-36). `[]` when the skill touches none of the four. The actual
    # signed magnitude is not decided here: `Game::Battle#apply_skill_hit`
    # feeds whichever of these keys are present the exact same final signed
    # effect number (post elemental-attribute scaling, variance, and the
    # damage/recovery cap) it applies to HP/SP for the same hit, matching
    # a reference implementation reading one shared `effect` local for every
    # one of hp/sp/atk/
    # def/spi/agi rather than a separately-computed figure per stat. Applied
    # through `Game::Battle#apply_stat_mods`, which clamps the delta against
    # the target's own cap before it lands.
    def skill_stat_mod_keys(sk)
      SKILL_STAT_MOD_FLAGS.keys.select { |key| sk.respond_to?(SKILL_STAT_MOD_FLAGS[key]) && sk.send(SKILL_STAT_MOD_FLAGS[key]) }
    end

    # The command numbers for casting `sk` from `caster` on `target` (both
    # Combatant snapshots): the caster's SP `cost`, and the signed HP / SP deltas
    # to the target — negative HP for an attack skill (base effect less a quarter
    # of the target's defence, min 1), positive HP / SP for a recovery skill. An
    # attack skill also carries the states it may inflict and the roll chance.
    # Both branches carry the skill's own `variance` now — `Game::Battle#apply_
    # skill_hit` is what actually spreads either sign of effect by it, this
    # method just reports the number the skill row names.
    #
    # `free:` is for a skill invoked by a special/use_skill item rather than
    # chosen from the caster's own skill list — ported from a reference
    # implementation's own skill-start path, NOT independently confirmed
    # against genuine RPG_RT under wine — it
    # branches on whether an item backs the cast, consuming the item's own
    # use instead of the caster's SP — the item pays
    # instead of the caster's own SP, never both.
    def battle_skill_command(sk, caster, target, free: false)
      cost = free ? 0 : skill_cost(sk, caster)
      # A **switch** skill (type 3) has no HP/SP/state effect at all -- its
      # only job, in battle exactly as on the field (`#cast_switch_skill`), is
      # turning on its configured switch once cast. Ported from a reference
      # implementation, NOT independently confirmed
      # against genuine RPG_RT under wine, which
      # special-cases this before any of the ordinary hit/damage/state logic,
      # setting the affected switch and reporting success immediately.
      # `switch_id` rides the command the same way
      # `#command_item`'s own does for a switch item -- `Game::Battle#apply_
      # skill_hit`'s recovery branch already reads `cmd[:switch_id]` onto its
      # log entry, and `Scene::Battle#drive_battle_animate` already flips it
      # the same moment it does for a switch item; only the battle-cast
      # switch-skill command itself never carried one.
      return { cost: cost, switch_id: sk.switch_id } if sk.type == SKILL_SWITCH
      base = skill_effect(sk, caster)
      # Attribute-defence shifting isn't scoped to attack skills -- a "raise
      # my own resistance" buff and a "lower the enemy's" debuff are both this
      # same flag, just cast on a different side -- so it rides on both
      # branches below rather than only the attack one.
      shift = skill_attr_shift(sk)
      shift_ids = shift ? skill_attributes(sk) : []
      stat_keys = skill_stat_mod_keys(sk)
      enemy_scope = sk.scope == 0 || sk.scope == 1 # single or all enemies
      # A skill's own `state_effects` list normally cures on an ally/self scope
      # and inflicts on an enemy scope, XORed with `reverse_state_effect`:
      # an ally-scoped skill with it set inflicts its listed states instead of
      # curing them (a self-scoped Berserk that confuses its own caster, say),
      # and an enemy-scoped one with it set cures its target's states instead
      # of inflicting new ones. A reference implementation guards the reverse
      # term behind an RPG2003-only check (`IsPositive() ^ (Player::IsRPG2k3()
      # && skill.reverse_state_effect)`, matching #skill_attr_shift's own
      # citation of the identical formula) -- this codebase used to port that
      # gate too, on the assumption that a stock RPG2000 editor has no UI to
      # set the bit anyway (true) and so RPG_RT would never honour it there
      # regardless (unconfirmed). Checked directly against genuine RPG_RT.exe
      # under wine (2026-09-05), NOT independently confirmed further than
      # this one scope: a hand-authored RPG2000 database (real edition byte,
      # no RPG2003-only section) enemy-scope skill with the bit set cured a
      # state on its target instead of inflicting it, and the identical skill
      # with the bit clear inflicted normally -- RPG_RT reads and honours
      # `reverse_state_effect` under RPG2000 too, same as the already-known
      # "physical" skill-formula bit (`#skill_to_hit`'s own citation) the 2000
      # editor also cannot set but RPG_RT still reads. The gate is dropped
      # here to match; a database only the 2000 editor itself ever produced
      # still behaves identically, since it can never carry the bit set.
      reverse = sk.respond_to?(:reverse_state_effect) && sk.reverse_state_effect
      heals_states = !enemy_scope ^ reverse
      state_ids = skill_state_ids(sk)
      cure_ids = heals_states ? state_ids : []
      inflict_ids = heals_states ? [] : state_ids
      if enemy_scope # an attack skill
        dmg = base - skill_defence_term(sk, target)
        # Floored at 0, not 1: ported from a reference implementation's own
        # skill-effect formula, confirmed against a genuine RPG_RT.exe under
        # wine (2026-09-05): a purely-magical real skill (Nepheshel's own
        # skill 191, power 25, magical_rate 10) cast by a low-spirit enemy
        # against a target with spirit forced to 999 -- deeply negative
        # pre-clamp (dmg = 27 - 124 = -97) -- landed as a genuine
        # zero-damage hit, with RPG_RT printing its stock
        # "...はダメージを受けていない!" (took no damage) line rather than any
        # minimum-1 scratch message. `#apply_skill_hit` used to tell this
        # branch apart from a recovery skill purely by the sign of `hp`
        # (negative = attack), which broke exactly at this boundary once
        # `dmg` could reach 0 -- `attack: true` below now says so explicitly
        # instead.
        dmg = 0 if dmg < 0
        { cost: cost,
          # `hp`/`mp` each independently gate on their own affect_hp/affect_sp
          # flag now, mirroring the ally/recovery branch below -- ported from
          # a reference implementation, NOT independently confirmed against
          # genuine RPG_RT under wine: it reads the identical one shared
          # `effect` local into both the HP and SP affected-guards
          # rather than rolling either separately, so a dual HP+SP attack
          # skill deals the
          # *same* number to each pool, and an SP-only drain (affect_hp clear,
          # affect_sp set -- a real, valid Effects-tab combination, per
          # @2000_battle_bot/デフォ戦bot trivia on the HP-reaches-zero
          # interaction below) never touches HP at all.
          hp: sk.affect_hp ? -dmg : 0, mp: sk.affect_sp ? -dmg : 0, attack: true,
          inflict: inflict_ids, chance: skill_to_hit(sk, caster, target),
          variance: skill_variance(sk), attributes: skill_attributes(sk),
          # 吸収 — the caster takes what the target loses. Ported from a
          # reference implementation's "absorb and not positive" gate, NOT
          # independently
          # confirmed against genuine RPG_RT under wine: the ported behavior
          # reads the flag only on an *offensive* skill, so it rides only on
          # this branch: a healing skill that sets it drains nothing.
          absorb: skill_absorbs?(sk), attr_shift: shift, attr_ids: shift_ids,
          stat_mod_keys: stat_keys, cured: cure_ids,
          # The raw, un-gated effect (see the ally branch's own `stat_effect`
          # below) -- #apply_skill_hit's ATK/DEF/SPI/AGI modifier and its
          # damage pipeline (elemental scaling, critical, variance) both need
          # this even when affect_hp/affect_sp leave `hp`/`mp` at 0, the same
          # way a reference implementation reads its one `effect` local for
          # every affect_* branch
          # alike regardless of which ones are actually set (ported behavior,
          # NOT independently confirmed against genuine RPG_RT under wine).
          stat_effect: dmg,
          # The skill's own physical_rate (0-10), scaled to a 0..100 percent
          # -- #apply_skill_hit's own #shake_off_states call reads this the
          # same way a reference implementation scales its physical-state-heal
          # rate by it, ported and NOT
          # independently confirmed against genuine RPG_RT under wine. 0 for
          # a purely magical skill, which #shake_off_states already reads as
          # "never rolls".
          physical_rate: (sk.physical_rate || 0) * 10 }
      else
        { cost: cost, hp: sk.affect_hp ? base : 0, mp: sk.affect_sp ? base : 0,
          # Ported from a reference implementation's own skill-effect formula,
          # which runs
          # its attribute-multiplier step unconditionally --
          # there is no heal-vs-damage branch gating it -- so a recovery
          # skill tagged with an elemental attribute scales by the target's
          # resistance exactly like an attack skill's `attributes:` above.
          # This is what lets a database tag a heal with a custom attribute
          # and set a character's own resistance to it to make them
          # harder/easier to heal, or build a caster-excluding MP-restore via
          # 0% self-resistance -- independently confirmed by @2000_battle_bot/
          # デフォ戦bot trivia on this exact trick (the reference implementation
          # citation
          # above is the port target, NOT independently confirmed against
          # genuine RPG_RT under wine by itself).
          attributes: skill_attributes(sk),
          variance: skill_variance(sk), attr_shift: shift, attr_ids: shift_ids,
          stat_mod_keys: stat_keys,
          # The raw, un-gated effect a buff-only skill (affect_hp clear,
          # affect_attack/defense/spirit/agility set) still needs: `hp` above
          # is 0 for such a skill, but the ATK/DEF/SPI/AGI modifier applies
          # regardless, off the same `base` a reference implementation's one
          # shared `effect`
          # local would carry into every affect_* branch alike.
          stat_effect: base,
          # Reuses `Game::Battle#apply_skill_hit`'s existing `cmd[:cured]`
          # machinery when curing (no roll, matching a battle medicine's own
          # state cure) and its `cmd[:inflict]`/`cmd[:chance]` roll when the
          # RPG2003 reverse case above turns this into an inflict instead.
          cured: cure_ids, inflict: inflict_ids, chance: skill_to_hit(sk, caster, target) }
      end
    end

    # Whether item `it` invokes a skill directly (a type-9 Special item, or an
    # equipment item flagged `use_skill`, field 71) rather than being a plain
    # medicine/switch item — the same test `Scene::ItemMenu#choose_item`
    # inlines for the field menu's own dispatch, shared here for the battle
    # menu's identical one (see #battle_usable? just below, which already
    # gates such an item on its invoked skill being battle-usable at all).
    def skill_invoking_item?(it)
      it && (it.type == ITEM_SPECIAL || (it.use_skill && (1..5).cover?(it.type)))
    end

    # Whether item `id` can be used in battle: a medicine flagged occasion_battle
    # the party actually holds, or a **special** item whose skill is battle-usable
    # (the same deferral #field_usable? makes). Nepheshel's whole thrown-bomb line
    # — 火炎玉, 爆裂玉, 氷結玉, 雷撃玉 and the rest — is special items, so this is
    # what puts them in the battle item list at all.
    #
    # A dangling item id (see #field_usable?) is reported the same way here,
    # for the battle menu's own list.
    def battle_usable?(id)
      it = db_item(id)
      if it.nil?
        $stderr.puts "[RPG2k] Item menu: party-held item ##{id} has no " \
                     'matching database row, excluding from battle menu'
        return false
      end
      return false unless item_count(id) > 0
      return use_skill_item_usable?(it, true) if it.use_skill
      case it.type
      when ITEM_MEDICINE then !item_field_only?(it)
      when ITEM_SWITCH then item_battle_occasion?(it)
      when ITEM_SPECIAL then battle_skill?(db_skill(it.skill_id))
      else false
      end
    end

    # Every held item as `[id, count]` pairs in ascending id order, for the
    # battle item list -- mirrors #field_items exactly (see its own doc
    # comment for the full citation): confirmed against genuine RPG_RT.exe,
    # not just a reference implementation's "same list-widget class" claim
    # #field_items already
    # warned this method's own inclusion still needed independent checking --
    # a live battle with a usable Herb and a field-only (battle-unusable)
    # Smelling Salts held listed *both* in the item window, the unusable one
    # in the identical measured "disabled" swatch color the field-menu fix
    # found. #battle_usable? is now consulted only for enablement, the same
    # split as the field menu. The dangling-item exclusion (and its warning)
    # stays, the same defensible corner case #field_items keeps.
    # Stored bag order, not an id sort -- see #field_items' own citation for
    # the wine measurement (cycle #252); the in-battle list shares it.
    def battle_items
      @items.keys.select do |id|
        it = db_item(id)
        if it.nil?
          $stderr.puts "[RPG2k] Item menu: party-held item ##{id} has no " \
                       'matching database row, excluding from battle menu'
        end
        it
      end.map { |id| [id, item_count(id)] }
    end

    # The HP / SP a medicine restores to a battle `target` (Combatant snapshot)
    # plus the status conditions it cures, as `{ hp:, mp:, cured: [ids] }` — the
    # same recovery and (antidote / herb) cure the field menu applies. Pure
    # arithmetic: an actor_set (使用可能キャラ) restriction is a question of
    # which target may be *offered* at all, not of what this formula computes
    # once one legitimately is — see `Scene::Map#battle_ally_targets`, which is
    # where that gate actually lives for a battle-cast item.
    #
    # A 蘇生専用 (`ko_only`) item on a target who is not down does nothing at
    # all, not even the state cure -- ported from a reference implementation,
    # not independently confirmed against genuine RPG_RT under wine: it
    # returns before state removal *and* HP/SP recovery are ever
    # computed once the item is ko_only-flagged and the target is not dead.
    # `#use_medicine` already applies this on the field
    # menu path (`ko_only_blocked?`); the battle path had never checked it,
    # so a revive item cast on a still-standing ally quietly worked as a free
    # full heal instead of doing nothing.
    def battle_item_command(it, target)
      return { hp: 0, mp: 0, cured: [] } if ko_only_blocked?(it, target)
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

    # Bumped whenever a lookup through #lower / #upper could answer differently
    # than it did before, which today means only Tile Substitution -- the layer
    # arrays themselves are set once here and never written again. The map
    # renderer caches its composed tile layer and watches this to know when that
    # cache is stale (see Scene::Map#tile_cache_valid?), so anything that starts
    # rewriting tiles must bump it or the change will not reach the screen.
    attr_reader :revision

    def initialize(id, unit)
      @revision = 0
      @id = id
      @unit = unit
      @width = unit.width
      @height = unit.height
      @chipset_id = unit.chipset_id
      @lower = unit.lower_layer || []
      @upper = unit.upper_layer || []
      # Tile Substitution (11750) rewrites, per layer: a sparse { original_id =>
      # current_id } deviation from identity. Kept as a lookup applied on read
      # rather than as an edit of the layer arrays -- the map data stays
      # pristine, and passability follows the substituted tile because every
      # reader goes through #lower / #upper. Cleared with the map, so leaving
      # resets it. Ported from a reference implementation's source, NOT independently confirmed
      # against genuine RPG_RT under wine: its
      # substitution routines operate on a
      # persistent 144-entry table, `map_info.lower_tiles`/`upper_tiles`,
      # identity-initialized (`std::iota`) once per map load and mutated
      # in place every call via `DoSubstitute`, which scans by *current*
      # value, not original index: `for (i) if (tiles[i] == old_id) tiles[i]
      # = new_id;`. A second substitution therefore **chains** through the
      # first whenever its `old_id` matches the first's `new_id`, rather than
      # independently replacing it -- and "substituting a tile back to
      # itself" is not how a prior substitution is undone (see
      # #substitute_tile's own doc comment for the full correction; an
      # earlier, uncited pass here got both of these backwards).
      @substitutions = [{}, {}]
    end

    def in_bounds?(x, y)
      x >= 0 && y >= 0 && x < @width && y < @height
    end

    def lower(x, y); tile(@lower, 0, x, y); end
    def upper(x, y); tile(@upper, 1, x, y); end

    # Tile Substitution: from now on draw (and treat) as `new_id` every tile on
    # `layer` (0 lower, 1 upper) that *currently* renders as `old_id` -- not
    # just tiles whose original chipset id is `old_id`. Ported from a
    # reference implementation's own substitution routine (see the
    # constructor's fuller citation), NOT
    # independently confirmed against genuine RPG_RT under wine: it scans the persistent
    # substitution table by current value every call, so a later
    # substitution chains through an earlier one whenever its `old_id`
    # matches the earlier `new_id` -- e.g. substituting 5->8 then 8->12
    # leaves *both* original tiles 5 and 8 rendering as 12, not tile 5 stuck
    # at 8. `old_id == new_id` is not a special "undo" case either: it only
    # resets whichever tiles currently render as `old_id` back to `old_id`
    # (a no-op for most of them) -- reverting a specific earlier
    # substitution means substituting *from* its current (already-rewritten)
    # id, not its original one.
    def substitute_tile(layer, old_id, new_id)
      idx = layer == 0 ? 0 : 1
      rebuilt = {}
      @substitutions[idx].each { |k, v| rebuilt[k] = v == old_id ? new_id : v }
      rebuilt[old_id] = new_id unless rebuilt.key?(old_id)
      table = {}
      rebuilt.each { |k, v| table[k] = v unless k == v }
      @substitutions[idx] = table
      @revision += 1
    end

    # Whether any tile on either layer is currently rewritten.
    def substituted?
      !@substitutions[0].empty? || !@substitutions[1].empty?
    end

    # A snapshot ({old_id => new_id} per layer) safe to stash on Game::State
    # for a Save/Continue -- see Scene::Map#record_tile_substitutions -- dup'd
    # so later #substitute_tile calls on the live map cannot mutate a saved
    # copy out from under it. Called every frame regardless of whether a
    # substitution ever ran (Tile Substitution itself is a rare command), so
    # the dup'd pair is cached and only rebuilt when @substitutions[0]/[1]
    # are no longer the same objects last dup'd from -- #substitute_tile and
    # #restore_substitutions both only ever *reassign* those slots to a fresh
    # Hash/Array, never mutate one in place, so an unchanged object identity
    # here really does mean unchanged contents.
    def substitution_snapshot
      lower = @substitutions[0]
      upper = @substitutions[1]
      return @substitution_snapshot_cache if @substitution_snapshot_src_lower.equal?(lower) &&
                                              @substitution_snapshot_src_upper.equal?(upper)
      @substitution_snapshot_src_lower = lower
      @substitution_snapshot_src_upper = upper
      @substitution_snapshot_cache = [lower.dup, upper.dup]
    end

    # Reapply a snapshot taken by #substitution_snapshot (real RPG_RT's own
    # SaveMapInfo.lower_tiles/upper_tiles: a Save/Continue on the same map
    # restores whatever Tile Substitution had rewritten, unlike an ordinary
    # map re-visit -- see RPG2k#continue_game, main.rb). A no-op for a
    # fresh/never-substituted state (both hashes empty).
    def restore_substitutions(lower, upper)
      @substitutions = [lower || {}, upper || {}]
      @revision += 1
    end

    # Overwrite one tile's own authored id, unlike #substitute_tile's map-wide
    # "every tile with this id" rewrite -- the debug Map Editor's paint tool
    # (Scene::MapViewer's Edit mode) uses these, not the event-command-facing
    # Tile Substitution mechanism, since painting means "this one cell is now
    # a different tile", not "reinterpret an id everywhere it appears". A
    # no-op out of bounds, matching #lower/#upper's own bounds handling.
    def set_lower(x, y, tile_id); set_tile(@lower, x, y, tile_id); end
    def set_upper(x, y, tile_id); set_tile(@upper, x, y, tile_id); end

    # Push #set_lower/#set_upper edits back into the LCF chunk data (chunks
    # 71/72, both a plain :int16_array -- see mruby-lcf/mrblib/schema.rb)
    # through #unit's own schema-driven `[]=`, so #unit.to_lcf/#unit.save_to
    # actually carry them. Reading (#lower/#upper, and so Scene::Map's own
    # rendering) never needs this: both already read straight off the same
    # @lower/@upper arrays #set_lower/#set_upper mutate in place -- it is only
    # the file writer that goes through #unit's own separately-decoded copy.
    def sync_layers_to_unit
      @unit[71] = @lower
      @unit[72] = @upper
    end

    private

    def set_tile(layer, x, y, tile_id)
      return unless in_bounds?(x, y)
      layer[y * @width + x] = tile_id
      @revision += 1
    end

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
    # Diagonal directions (as the [horizontal, vertical] pairs #move_diagonal /
    # MoveRoute's own DIAGONAL table use, e.g. [6, 8] for Up-Right) are keyed
    # in too, rotated the same 90/180 degrees around the 8-way compass these
    # four cardinals sit on (Up=0, Up-Right=1, Right=2, Down-Right=3, Down=4,
    # Down-Left=5, Left=6, Up-Left=7; a turn moves +-2 steps, 180 moves 4) --
    # #jump_face_direction looks up a diagonal key here for a Turn/Face
    # command that follows a diagonal move inside a jump block; #turn_right/
    # #turn_left/#turn_around look one up too, for the identical
    # non-jump case, rotating #last_move_direction rather than the always-
    # cardinal @direction (see #last_move_direction's own citation for why
    # the two can diverge).
    TURN_RIGHT = { 8 => 6, 6 => 2, 2 => 4, 4 => 8,
                   [6, 8] => [6, 2], [6, 2] => [4, 2],
                   [4, 2] => [4, 8], [4, 8] => [6, 8] }.freeze
    TURN_LEFT  = { 8 => 4, 4 => 2, 2 => 6, 6 => 8,
                   [6, 8] => [4, 8], [4, 8] => [4, 2],
                   [4, 2] => [6, 2], [6, 2] => [6, 8] }.freeze
    TURN_180   = { 8 => 2, 2 => 8, 4 => 6, 6 => 4,
                   [6, 8] => [4, 2], [4, 2] => [6, 8],
                   [6, 2] => [4, 8], [4, 8] => [6, 2] }.freeze
    # The four cardinal directions, indexable for random selection.
    CARDINALS = [2, 4, 6, 8].freeze

    attr_accessor :direction, :move_speed, :move_frequency
    attr_accessor :through, :facing_locked, :animation_stopped, :transparency
    attr_accessor :layer, :overlap_forbidden
    # The map event id this character mirrors (Scene::Map#build_event), or
    # Scene::Map::MOVE_TARGET_PLAYER (10001) for the party's own forced
    # Set Move Route mirror (Scene::Map#start_player_route) -- an id-based
    # "is this the hero" test for #char_passable?/#char_can_land? that does
    # not depend on still holding the exact same object reference a route
    # started with. nil for a character built without either (a vehicle
    # mirror, which never reaches those two methods -- see VehicleWorld).
    attr_accessor :event_id
    # Whether this character's own page Animation Type is one of the three
    # "fixed direction" kinds (Game::EventGraphic.fixed_direction? -- a plain
    # or continuous walk with facing pinned, or a single never-animating
    # graphic). Set by Scene::Map#build_event from the page, alongside
    # #facing_locked (the move-route Direction Fix ON/OFF toggle): the two
    # are independent *sources* of the same lock -- ported from a reference
    # implementation's own facing-lock setter (the lock is set whenever
    # either an explicit lock or a fixed-direction Animation Type applies),
    # NOT independently confirmed against genuine RPG_RT
    # under wine: an Animation Type lock cannot be turned off by a
    # Direction Fix OFF sub-command, and unlike #facing_locked it is never
    # itself toggled by a move-route command.
    attr_accessor :fixed_facing
    attr_reader :graphic_name, :graphic_index, :x, :y

    # What a following move-route "Move Forward" sub-command walks in --
    # NOT simply "the direction actually walked/jumped by the last
    # successful move" the way an uncited yado.tk claim this comment used to
    # repeat had it. Ported from a reference implementation's own move-route
    # update path, which uses a single shared `direction` field for
    # both purposes: a Face/Turn sub-command's branch (Face Up/Right/Down/
    # Left, or a 90/180-degree/random/toward/away turn, each itself a
    # direction-setting call there) writes the exact same `direction` a later
    # Move-command branch reads for Move Forward --
    # so `Turn Right` immediately followed by `Move Forward` is believed to
    # walk in the *turned* direction, not whichever direction the character
    # was last physically stepped in before the route began. This whole
    # mechanism is NOT independently confirmed against genuine RPG_RT under
    # wine. #face!/#turn_right/#turn_left/#turn_around (the move-route
    # Face/Turn sub-commands) update this field for exactly that reason;
    # #move/#jump/#move_diagonal (actual steps) update it too, mirroring the
    # ported shared-field design. A blocked #do_move (turns to face an
    # obstruction but never steps) still leaves it alone, matching #face's
    # own lock-respecting, no-step nature.
    #
    # A plain numpad int (2/4/6/8) after #move/#jump/#face!/#turn_*, or a
    # `[horizontal, vertical]` pair after #move_diagonal -- see
    # #move_diagonal's own citation for why a diagonal step's full 8-way
    # direction has to survive here, not just one cardinal component.
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
      @fixed_facing = false     # keep facing fixed per the page's Animation Type
      @animation_stopped = false
      @transparency = 0         # 0 opaque .. 7 fully transparent
      @graphic_name = nil
      @graphic_index = 0
      @jumped = false
      @layer = 1                # priority type: same as normal characters
      @overlap_forbidden = false # LCF page field 35: collide regardless of layer
      @event_id = nil            # set by Scene::Map once it knows what this mirrors
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

    # Turn to face `dir` without moving (a no-op while facing is locked, by
    # either #facing_locked or #fixed_facing) -- movement-driven facing only
    # (#move, #jump, #move_diagonal). An explicit Face Direction / Turn
    # move-route sub-command always wins over a prior Direction Fix ON *or*
    # a fixed-direction Animation Type in the same route (yado.tk); see
    # #face!.
    def face(dir)
      @direction = dir unless @facing_locked || @fixed_facing || dir.nil?
    end

    # Turn to face `dir`, ignoring both the Direction Fix lock and a
    # fixed-direction Animation Type. The move-route "Face Up/Right/Down/
    # Left/Random/Hero/Away from Hero" sub-commands use this (Turn Right/
    # Left/180/Random already bypassed both locks by writing @direction
    # directly) -- neither lock suppresses anything but the facing change
    # that would otherwise happen from an ordinary move; an explicit facing
    # command issued later in the same route always wins, and (per a
    # reference implementation's own facing-update and move-route-parsing
    # handlers, not independently confirmed against genuine RPG_RT under
    # wine) so does one on a page whose Animation Type is itself
    # one of the fixed kinds -- RPG_RT still turns a "statue" NPC's sprite on
    # an explicit Face command even though it never turns while it walks.
    def face!(dir)
      return if dir.nil?
      @direction = dir
      @last_move_direction = dir
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
    # RPG_RT is believed to face the jump's **dominant axis**, vertical
    # winning a tie, which is not the direction of the last enclosed move: a
    # jump two right and two down lands facing down. #last_move_direction
    # always picks up that same dominant-axis direction, even for a jump
    # that ends where it started -- ported from a reference implementation's
    # own jump handler, which computes and applies the facing direction
    # (this codebase's #last_move_direction, what Move Forward reads)
    # unconditionally, before ever checking `dx != 0 || dy != 0` -- a null
    # jump's tie (`dy.abs() >= dx.abs()` when both are 0, `dy >= 0` when dy
    # is 0) always resolves to Down there. Only the *visible* facing
    # (`SetFacing`, this codebase's #face) is gated behind that displacement
    # check in the port (and, inside it, `IsFacingLocked`, which #face
    # already respects) -- so a jump going nowhere is believed to still
    # silently turn a character to face south internally without it showing
    # on screen. This whole dominant-axis/null-jump mechanism is NOT
    # independently confirmed against genuine RPG_RT under wine.
    def jump(x, y)
      dx = x - @x
      dy = y - @y
      dir = dy.abs >= dx.abs ? (dy >= 0 ? 2 : 8) : (dx >= 0 ? 6 : 4)
      @last_move_direction = dir
      face(dir) unless dx == 0 && dy == 0
      @x = x
      @y = y
      @jumped = true
    end

    # The facing a diagonal move settles on: whichever of the diagonal's two
    # cardinal components (`horizontal`/`vertical`) shares the axis the
    # character is *already* facing, unchanged if it was already on that
    # axis -- ported from a reference implementation's own facing-update
    # path, which only reverses the prior facing
    # when it matches *neither* of the
    # diagonal's two cardinal components, otherwise leaving it untouched
    # there. Since a 180-degree flip of a facing that is on neither
    # component always lands exactly on the component sharing its own axis
    # (Up flips to Down's opposite-axis partner... concretely: Down flips to
    # Up, Left flips to Right), the net effect is simply "keep the vertical
    # component if already facing vertically, keep the horizontal component
    # if already facing horizontally" in the port -- not the diagonal
    # always snapping to its vertical part the way this method's own prior,
    # uncited comment ("RPG2000 keeps a cardinal facing on diagonals, so we
    # face the vertical part") claimed. A character facing Left that steps
    # Up-Right would end up facing Right, not Up, under this design. This
    # whole mechanism is NOT independently confirmed against genuine RPG_RT
    # under wine.
    def diagonal_facing(horizontal, vertical)
      [8, 2].include?(@direction) ? vertical : horizontal
    end

    # Move one tile diagonally, combining a horizontal and a vertical direction.
    #
    # #last_move_direction is set to the `[horizontal, vertical]` pair itself,
    # not just one component, so a following Move Forward sub-command reads
    # back the full diagonal rather than collapsing to just its vertical
    # part -- a two-command route "Move Upper-Right, Move Forward" is thereby
    # made to move diagonally *twice*, not diagonally-then-straight-up. This
    # specific diagonal-repeats claim is NOT independently confirmed against
    # genuine RPG_RT under wine (the orthogonal Direction-Fix case
    # `#last_move_direction` was introduced for is the one covered by an
    # actual check -- see `changelog.d/move-route-forward-uses-last-moved-
    # direction.fixed.md` and `scripts/rpg2k_logic_check.rb`); storing the
    # full pair is still the strictly more information-preserving choice
    # either way, since it never discards data the vertical-only alternative
    # would have.
    def move_diagonal(horizontal, vertical)
      face(diagonal_facing(horizontal, vertical))
      @last_move_direction = [horizontal, vertical]
      hx, = DIR_DELTA[horizontal] || [0, 0]
      _, vy = DIR_DELTA[vertical] || [0, 0]
      @x += hx
      @y += vy
      @jumped = false
    end

    # Sibling gap to #jump_face_direction's own diagonal-Array fix
    # (MoveRoute, `docs/TODO.md`'s cycle #207 entry): the non-jump path had
    # the identical bug. `#last_move_direction` is what a following Move
    # Forward reads (see its own citation above) and can hold a diagonal
    # `[horizontal, vertical]` pair after #move_diagonal, but these three
    # methods used to just copy the newly-turned *cardinal* `@direction`
    # into it -- discarding any diagonal pair outright, rather than rotating
    # it, whenever a Turn Right/Left/180 (or Turn Random, which calls
    # #turn_right/#turn_left directly) followed a diagonal move-route
    # sub-command. `TURN_RIGHT`/`TURN_LEFT`/`TURN_180` already carry the
    # diagonal-pair keys `#jump_face_direction` needed for the identical
    # rotation inside a jump block, so the fix is the same one-line idiom:
    # look `@last_move_direction` itself up in the table (a plain cardinal
    # or a diagonal pair alike) instead of re-deriving it from `@direction`.
    # `@direction` (the visible, always-cardinal facing -- see
    # #last_move_direction's own citation) is untouched by this fix and
    # keeps rotating exactly as it already did.
    def turn_right
      @direction = TURN_RIGHT[@direction] || @direction
      @last_move_direction = TURN_RIGHT[@last_move_direction] || @last_move_direction
    end

    def turn_left
      @direction = TURN_LEFT[@direction] || @direction
      @last_move_direction = TURN_LEFT[@last_move_direction] || @last_move_direction
    end

    def turn_around
      @direction = TURN_180[@direction] || @direction
      @last_move_direction = TURN_180[@last_move_direction] || @last_move_direction
    end

    # Direction pointing from this character toward (tx, ty). ~~Ties (and
    # equal distance) resolve to the horizontal axis, matching RPG2000's
    # toward-hero behaviour; returns the current facing when already on the
    # tile.~~ Corrected to match a reference implementation's own
    # direction-to-character helper, which compares with a strict `>`,
    # so an exact tie -- and the degenerate
    # same-tile case (dx == dy == 0), which that reference does not
    # special-case at all -- falls through to the *vertical* branch, and
    # lands on Down there since `sy > 0` is false when `sy == 0`. This used
    # to compare with `>=` and treat the same-tile case as "keep the current
    # facing," neither of which the reference does. NOT independently
    # confirmed against genuine RPG_RT under wine.
    def direction_toward(tx, ty)
      dx = tx - @x
      dy = ty - @y
      if dx.abs > dy.abs
        dx > 0 ? 6 : 4
      else
        dy < 0 ? 8 : 2
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

    attr_reader :index, :commands

    def done?; @done; end
    def empty?; @commands.empty?; end
    def repeat?; @repeat; end
    def skippable?; @skippable; end

    # Resume this route's cursor at a saved index (Scene::Map#build_event
    # restoring a Save/Continue taken mid-route -- see Game::State
    # #map_event_route_index / #record_map_event_positions). `i` is whatever
    # raw #index a still-running route last snapshotted, including the
    # `@commands.size` sentinel #advance_cursor leaves behind on a *finished*
    # non-repeating route (@index left one past the last command, @done set
    # true) -- reproduced here rather than clamped into the last command, or
    # a save taken the instant such a route naturally finished would silently
    # re-run its final step on load. A mid-repeat-loop index (always
    # in-bounds, since #advance_cursor wraps a repeating route back to 0
    # itself rather than ever leaving it at the sentinel) resumes exactly
    # where it left off. Out-of-range in the other direction (a negative or
    # stale index from a shorter/edited route) clamps to the start instead of
    # raising.
    def resume_at(i)
      return if @commands.empty?
      if i >= @commands.size
        @index = @commands.size
        @done = true
      else
        @index = [i, 0].max
      end
    end

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
        # #last_move_direction is what RPG_RT's own shared `direction` field
        # holds at this point -- the immediately preceding Face/Turn
        # sub-command in this same route wins over whatever the character
        # last physically stepped in, since #face!/#turn_* update it too
        # (see #last_move_direction's own citation). A diagonal last
        # direction continues diagonally rather than collapsing to one
        # cardinal axis.
        last = character.last_move_direction
        if last.is_a?(Array)
          do_diagonal_dir(character, world, last[0], last[1])
        else
          do_move(character, world, last)
        end
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
      # Bounds are the internal 0..5 scale (real Move Speed 1..6 minus 1; see
      # Scene::Map::SLIDE_UNITS/#page_move_speed), shifted down by that same
      # offset -- i.e. a move-route Speed Up/Down can never push a character
      # outside real Move Speed 1..6.
      #
      # The SPEED_DOWN floor (0) is now confirmed against genuine RPG_RT
      # under wine, by timing a real, already-authored move route rather
      # than a synthetic one (cycle #179; the safe-splice discipline of
      # cycles #137-139/#178 applies here too, but no edit was even needed --
      # the route was used exactly as shipped). Nepheshel's `Map0465.lmu`
      # event 4 ("キマイラa", a visible on-map encounter monster, cond_flags
      # 0 so its page is always active) authors, on a genuine repeating move
      # route: 4 consecutive Speed Down commands from the page's own default
      # move_speed (editor 3, internal 2 -- `[2-1,-1,-1,-1].max(0)` per this
      # clamp would floor at internal 0 rather than go to -2), then after a
      # couple of moves and two Wait commands, 4 consecutive Speed Up
      # commands, then 6 Move Forward commands whose speed directly exposes
      # what the Speed Down block actually left behind: internal 4 (real 5)
      # if the floor held, or internal 2 (real 3, "Normal") if the raw value
      # went negative and the Ups only clawed back up from -2. These predict
      # 4 vs. 16 frames/tile (Scene::Map::SLIDE_UNITS's own table) -- a clean
      # 4x difference in wall-clock time for the same 6 real tiles (0.4s vs.
      # 1.6s), not a subtle one. Method: `gen-rpg2k-save.rb --map 465 --at
      # 1,1 --clear-scene` (the whole 20x15 map fits in one screen at that
      # corner, so the event needs no camera-follow bookkeeping and no
      # switch/contact contamination was found on this map); genuine
      # RPG_RT.exe booted under wine (`~/.wine-nepheshel32`, Xvfb, matchbox,
      # `LIBGL_ALWAYS_SOFTWARE=1`, `LANG=ja_JP.UTF-8`) and screenshotted via
      # a tight `xwd`-only capture loop (no per-frame `convert`) started the
      # instant the file-load Return was sent, sustaining ~55-58fps -- fast
      # enough to resolve individual frames of a 4-frames/tile slide.
      # Isolating the event's own sprite by its charset colour (fuzzy-masked
      # and `-trim`med to a bounding box, cross-checked against its known
      # map coordinates) gave a clean position trace: a still period, then a
      # steady 6-tile dash covering 192 screen-px in ~0.39-0.41s before the
      # trace's slope visibly drops back to the slow regime. That lands
      # squarely on the floor-confirmed 0.4s prediction (~4 frames/tile) and
      # rules out the unclamped 1.6s alternative by a wide margin (a 55fps
      # capture cannot mistake 0.4s for 1.6s).
      #
      # The SPEED_UP ceiling (5) got a direct measurement of its own in
      # cycle #180, on a different real route from a different, uncrowded
      # map (`Map0089.lmu` event 25, a lone "will-o-wisp" -- the only visible
      # sprite on this 20x15 map, its 24 sibling events all switch-gated off
      # by default; switch 262 flipped on in a scratch save to activate its
      # page 2, per this project's own established switch-flip technique).
      # Its own repeating route authors 8 consecutive Speed Ups from the
      # page's move_speed-1 (editor) default -- internal 0 -- immediately
      # followed by 8 Transparency-Up commands and then 7 move commands
      # (3 Move Toward Hero, 4 Move Random) at whatever speed those Ups
      # left behind, so the dash itself is dimmed but not literally
      # invisible: a relative-hue mask (green/pink tinted relative to the
      # grey background, robust to uniform transparency blending, unlike a
      # fixed-colour mask which loses the dimmed sprite entirely) tracked it
      # through the whole segment. Result, captured under wine the same way
      # as the floor probe (`~/.wine-nepheshel32`, tight `xwd`-only loop):
      # the post-Speed-Up dash is clearly **not** instantaneous -- it shows a
      # smooth, multi-frame slide (visibly interpolating across 9-14 capture
      # frames per dash, several times, over a 50s capture) covering roughly
      # 1-3 tiles each time. This alone rules out an unclamped raw internal
      # 8 (0+8 Speed Ups with no ceiling): `Scene::Map`'s own frames/tile
      # table (see `SLIDE_UNITS`, corrected this same cycle) predicts 64 /
      # (1 << 8) = 0.25 frames/tile at that raw value -- multiple tiles
      # completing within a single video frame, i.e. an instant teleport
      # with no visible intermediate frames, which is not what was observed.
      # The measured frames/tile across five clean dash segments (5.6-9.2,
      # skewed upward by Move Random's own occasional backtracking, which
      # this net-displacement measurement can't distinguish from a genuinely
      # slower dash) brackets the internal-5 ceiling's own prediction (2
      # frames/tile) and internal-4's (4 frames/tile) far better than
      # anything close to instantaneous, but the exact internal value (4 vs.
      # 5) is NOT pinned down to single-frame precision this cycle -- Move
      # Random's backtracking and the dimmed-sprite centroid's own animation
      # jitter both bias the measurement, and the same methodology's
      # baseline (the *slow*, internal-0 initial approach on this same
      # route, unaffected by backtracking since Move Toward Hero doesn't
      # double back) itself reads ~50-55 frames/tile against a clean 64
      # prediction -- a ~15-20% systematic undercount this measurement
      # doesn't fully explain, so the ceiling's exact value is left an open
      # follow-up rather than rounded to either 4 or 5 on this evidence
      # alone. **Conclusion: some ceiling clamp genuinely holds in RPG_RT.exe
      # (ruling out no-clamp-at-all); this codebase's existing ceiling of 5
      # is plausible and not contradicted, but not yet confirmed to the
      # exact internal value.** A real, shipped move route (Map0068, cycle
      # #178) also authors exactly 4 consecutive Speed Ups from its own page
      # default (internal 2) -- reaching internal 5 exactly if the ceiling
      # is 5, or overshooting a ceiling of 4 by one wasted command if it
      # isn't -- corroborating evidence either way, not a tiebreaker.
      # Left for a future cycle: a discriminating template with no Move
      # Random (so net displacement is trustworthy) and no transparency (so
      # the sprite needs no relative-hue tracking at all) would pin the
      # exact value down; none of this game's own authored "up-first" wisp
      # routes offer that combination.
      when SPEED_UP   then character.move_speed = [character.move_speed + 1, 5].min; [:effect, true]
      when SPEED_DOWN then character.move_speed = [character.move_speed - 1, 0].max; [:effect, true]
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
    #
    # A block caused specifically by the hero's own tile is reported as
    # `:touched_hero` rather than plain `:blocked` (same skippable/non-
    # skippable retry rule either way) -- purely a re-classification of an
    # outcome `world.passable?` already refused (a map event's own layer/
    # overlap-forbidden collision with the hero, `Scene::Map#char_passable?`;
    # a vehicle's own `vehicle_passable?` never blocks on the hero at all, so
    # this never reclassifies a vehicle route's own step), not a new
    # obstruction -- so it changes nothing about *whether* a move succeeds,
    # only what the caller does with a failure that was already going to
    # happen. `Scene::Map#step_event` turns it into this map event's own
    # Event Touch (2) trigger, mirroring `#move_autonomous`'s identical
    # dedicated hero check for a Random/Approach/Away-type move: ported from
    # a reference implementation's own move handler, which calls
    # its own collision-on-failure check there to start an Event Touch
    # page with no move-route-overwritten guard
    # (unlike the player's own touch check, gated on exactly that flag in
    # its own movement-update path) -- so a Set Move Route/page-authored
    # custom route walking a map event onto the party is believed to fire it
    # exactly like an autonomous move already does. This is NOT
    # independently confirmed against genuine RPG_RT under wine.
    def do_move(character, world, dir)
      return [:turned, true] if dir.nil?
      prev_dir = character.direction
      if character.through || world.passable?(character, dir)
        character.move(dir)
        [:moved, true]
      else
        character.face(dir) # an obstructed move still turns to face it --
        nx, ny = Character.step_tile(character.x, character.y, dir)
        status = world.hero_position == [nx, ny] ? :touched_hero : :blocked
        if @skippable
          # ...unless the route can skip past the block, in which case this
          # reverts the turn entirely before advancing to the next command --
          # ported from a reference implementation's own move-route update
          # path, which restores the prior direction and facing there
          # -- a skipped step is believed to have no visible effect at all,
          # not even a flinch toward the obstacle. A non-skippable route
          # keeps the turn (the same command retries next frame, still
          # facing the obstacle). NOT independently confirmed against
          # genuine RPG_RT under wine.
          character.direction = prev_dir
          [status, true]
        else
          [status, false]
        end
      end
    end

    # Begin Jump: the commands up to the matching End Jump do **not** step. They
    # name the jump's *destination* — each move command contributes its direction
    # as one tile of offset, each face / turn command only steers what the next
    # move contributes — and the character then hops there in a single move,
    # clearing whatever lies between. A port of a reference implementation's
    # own begin-jump handler (not independently confirmed against genuine
    # RPG_RT under wine).
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
    # hero) still pick one; Move Forward keeps the direction in hand. A
    # diagonal now leaves its own `[horizontal, vertical]` pair in hand too
    # (mirroring #move_diagonal's `#last_move_direction` outside a jump) --
    # it used to fall into the bare `else dir` catch-all alongside Move
    # Forward itself, so the diagonal never actually updated the running
    # `dir` a *later* Move Forward in the same jump block reads: "Begin
    # Jump, Move Upper-Right, Move Forward, End Jump" repeated the
    # *pre*-diagonal direction instead of the diagonal just walked, the same
    # root cause #last_move_direction was introduced for outside a jump (see
    # #move_diagonal's own doc comment), just never carried into this
    # separate jump-scan path. This still leaves the diagonal step's own
    # delta correct even before this fix, since #jump_delta computes it
    # straight from `id`, not `dir` -- only a *following* Move Forward was
    # affected.
    def jump_move_direction(id, dir, character, world)
      case id
      when MOVE_UP, MOVE_RIGHT, MOVE_DOWN, MOVE_LEFT then MOVE_DIR[id]
      when MOVE_UPRIGHT, MOVE_DOWNRIGHT, MOVE_DOWNLEFT, MOVE_UPLEFT then DIAGONAL[id]
      when MOVE_RANDOM then Character::CARDINALS[world.random(4)]
      when MOVE_TOWARD_HERO then toward_hero(character, world)
      when MOVE_AWAY_HERO then away_hero(character, world)
      else dir # Move Forward: keeps whatever direction (cardinal or diagonal pair) is in hand
      end
    end

    # The tile offset a move command inside a jump block adds. A diagonal
    # moves on both axes at once -- whether it comes from an explicit
    # diagonal sub-command (`id` itself names one) or from Move Forward
    # continuing a diagonal `dir` a prior diagonal command left in hand (a
    # two-element `[horizontal, vertical]` pair, see #jump_move_direction
    # above); everything else moves one tile along the cardinal `dir`.
    def jump_delta(id, dir)
      pair = DIAGONAL[id] || (dir if dir.is_a?(Array))
      if pair
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
    # A Turn Right/Left/180 (or the matching half of Turn 90 Right/Left/180
    # Random) right after a diagonal move in the same block used to be a
    # silent no-op: `dir` was the diagonal's own `[horizontal, vertical]`
    # pair by then (see #jump_move_direction above), and Character::
    # TURN_RIGHT/TURN_LEFT/TURN_180 only had cardinal-int keys, so the hash
    # lookup missed and `|| dir` left the pair completely unrotated -- a
    # following Move Forward kept walking the pre-turn diagonal instead of
    # the turned one. Fixed by keying those three hashes with the four
    # diagonal pairs too (see their own doc comment), rotated the same
    # 90/180 degrees the cardinal entries already encode; the lookups here
    # are unchanged.
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
      do_diagonal_dir(character, world, horizontal, vertical)
    end

    # The shared body of a diagonal step, whether it comes from an explicit
    # Move Upper-Right/etc. sub-command (#do_diagonal, which looks up its
    # `horizontal`/`vertical` pair from the move id) or from Move Forward
    # continuing a diagonal #last_move_direction (see #execute's own
    # MOVE_FORWARD case) -- mirroring a reference implementation's own
    # move-route update path,
    # which has no such split at all there: one call site handles
    # every move sub-command, cardinal or diagonal alike,
    # since its direction field is an 8-way enum that a diagonal move simply
    # leaves set. This structural choice is a design mirror, not a claim
    # independently confirmed against genuine RPG_RT under wine.
    def do_diagonal_dir(character, world, horizontal, vertical)
      prev_dir = character.direction
      character.face(character.diagonal_facing(horizontal, vertical))
      passable = character.through ||
                 (world.passable?(character, horizontal) &&
                  world.passable?(character, vertical))
      if passable
        character.move_diagonal(horizontal, vertical)
        [:moved, true]
      elsif @skippable
        # Same skippable-block reversion #do_move applies -- a diagonal that
        # can't move leaves no visible turn behind on a skippable route.
        character.direction = prev_dir
        [:blocked, true]
      else
        [:blocked, false]
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
  # direction the character should try to step next. ~~`random` picks a
  # cardinal~~ -- corrected after reading a reference implementation's
  # source (NOT
  # independently confirmed against genuine RPG_RT under wine): `random`
  # rolls a *relative* turn off the event's own current facing instead, and
  # sometimes skips the move attempt entirely -- see #random_direction's own citation;
  # `vertical`/`horizontal` keep bouncing along one axis, reversing when the way
  # ahead is blocked; `toward`/`away` chase or flee the hero, but only most of
  # the time and only in sight -- see #toward_away_direction's own citation.
  # Returns a numpad direction, or nil for "no autonomous movement" (stationary,
  # the custom-route type -- driven by a MoveRoute instead -- and a `random`
  # draw that skips this decision's move attempt entirely).
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
      when RANDOM     then random_direction(character, world)
      when VERTICAL   then bounce(character, world, [2, 8])
      when HORIZONTAL then bounce(character, world, [6, 4])
      when TOWARD then toward_away_direction(character, world, true)
      when AWAY   then toward_away_direction(character, world, false)
      else nil
      end
    end

    # Random movement is a *relative* roll off the event's own current facing,
    # not a uniform pick among the four absolute cardinals -- ported from
    # a reference implementation's own random-movement handler, NOT
    # independently confirmed against genuine RPG_RT under wine: it
    # draws a number 0-9: 0-2 (30%) keep
    # going straight with no turn at all, 3-4 (20%) turn 90 degrees left, 5-6
    # (20%) turn 90 degrees right, 7 (10%) turn 180 degrees, and 8-9 (20%)
    # skip the movement decision entirely -- that source resets its own stop
    # counter and returns
    # before its move step
    # is ever called, so there is no move attempt this tick at all, not even
    # one in the direction the character already faces.
    # Its 90/180-degree turn helpers are themselves plain direction
    # remaps with no
    # passability check of their own -- exactly this codebase's own
    # `Character::TURN_LEFT`/`TURN_RIGHT`/`TURN_180` hashes, confirmed to
    # match direction-for-direction (both rotate Up -> Left -> Down -> Right
    # -> Up for a left turn and the reverse for a right turn). Returns nil for
    # the skip draw -- already `#step_event`'s own sentinel for "no
    # autonomous movement this frame" (see STATIONARY/CUSTOM above), so no
    # caller-side change was needed to keep it distinct from a real
    # direction: nil never collides with a numpad direction (2/4/6/8 are all
    # truthy).
    def self.random_direction(character, world)
      draw = world.random(10)
      return character.direction if draw < 3
      return Character::TURN_LEFT[character.direction]  || character.direction if draw < 5
      return Character::TURN_RIGHT[character.direction] || character.direction if draw < 7
      return Character::TURN_180[character.direction]   || character.direction if draw == 7
      nil
    end

    # Approach/Away from Player is not the deterministic beeline it looks
    # like from the command's name: only 8 times out of 10 while the event
    # is actually on screen does it compute the real toward/away direction
    # (0 keeps the current facing, 1 picks a fully random cardinal, 2-9 the
    # real direction) -- and it picks a fully random cardinal
    # unconditionally, every time, while off screen (outside the view plus a
    # two-tile margin), making no attempt to track the player at all until
    # back in view. #direction_toward/#direction_away supply the real
    # geometric direction when one is needed; it is this surrounding
    # stochastic/visibility gate that was missing entirely -- every step
    # unconditionally computed the exact geometric direction, in sight or
    # not, which reads as a noticeably more precise (and, off screen,
    # omniscient) chase/flee than real RPG_RT's. NOT independently confirmed
    # against genuine RPG_RT under wine.
    def self.toward_away_direction(character, world, towards)
      return Character::CARDINALS[world.random(4)] unless world.in_sight?(character)
      draw = world.random(10)
      return character.direction if draw == 0
      return Character::CARDINALS[world.random(4)] if draw == 1
      hx, hy = world.hero_position
      towards ? character.direction_toward(hx, hy) : character.direction_away(hx, hy)
    end

    # Continue along the current axis direction, reversing to the other end of
    # `pair` when the way ahead is blocked. `pair[0]` is also the default when
    # the event is not currently facing either end of the axis at all (an
    # independent page field, so a Vertical/Horizontal-cycle event can start
    # -- or be knocked, by a Change Event Location or forced Face command --
    # facing perpendicular to its own cycle axis): only a facing that is
    # already exactly the *other* end of the pair reverses, every other
    # current facing (on-axis or not) takes `pair[0]`. Callers pass
    # `[Down, Up]`/`[Right, Left]` for Vertical/Horizontal cycle, so an event
    # caught facing off-axis takes its first step Down/Right, not Up/Left.
    # This particular default-direction choice is NOT independently
    # confirmed against genuine RPG_RT under wine -- first-principles/
    # by-hand reasoning, left for a future cycle to verify.
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
    # flags bits (chunk 1 of the page condition). Bit order confirmed against
    # liblcf's generated EventPageCondition::Flags declaration (switch_a,
    # switch_b, variable, item, actor, timer, timer2): TIMER is bit 5 (0x20),
    # a genuine RPG2000 page condition, not an RPG2003 extension. The next
    # bit, TIMER2 (0x40), *is* RPG2003-only -- see Game::EventPage's own
    # TIMER2 handling below for where that RPG2000-vs-2003 gating actually
    # lives in this codebase.
    SWITCH_A = 0x01
    SWITCH_B = 0x02
    VARIABLE = 0x04
    ITEM     = 0x08
    ACTOR    = 0x10
    TIMER    = 0x20
    TIMER2   = 0x40

    # `EventPageCondition::Comparison` (liblcf): the variable condition's own
    # RPG2003 operator, read only once `#active?`'s RPG2003 branch below
    # confirms it's in this valid 0..5 range -- an out-of-range value (never
    # written by a real editor, but not schema-clamped either) falls through
    # to "condition not checked", matching a reference implementation's own
    # 0..5 range guard exactly (not independently confirmed against genuine
    # RPG_RT under wine).
    def self.compare(a, b, op)
      case op
      when 0 then a == b
      when 1 then a >= b
      when 2 then a <= b
      when 3 then a > b
      when 4 then a < b
      when 5 then a != b
      end
    end

    def self.active?(cond, switches, variables, party, timer_seconds = 0, timer2_seconds = 0)
      return true if cond.nil?
      flags = cond.flags || 0
      return false if (flags & SWITCH_A) != 0 && !switches[cond.switch_a_id]
      return false if (flags & SWITCH_B) != 0 && !switches[cond.switch_b_id]
      if (flags & VARIABLE) != 0
        # RPG2000 always compares with plain >=; RPG2003 reads the page's own
        # operator instead -- ported from a reference implementation's own
        # condition check, NOT
        # independently confirmed against genuine RPG_RT under wine
        # (RPG2000 branches to the hardcoded >=, everything else
        # to the operator-based check) -- these are
        # genuinely different rules, not the same comparison with an
        # edition-gated constant.
        rpg2003 = party && party.respond_to?(:rpg2003?) && party.rpg2003?
        if rpg2003
          op = cond.compare_operator
          if op && op >= 0 && op <= 5
            return false unless compare(variables[cond.variable_id], cond.variable_value, op)
          end
        else
          return false if variables[cond.variable_id] < cond.variable_value
        end
      end
      if (flags & ITEM) != 0
        return false unless party && party.has_item?(cond.item_id)
      end
      if (flags & ACTOR) != 0
        return false unless party && party.include_actor?(cond.actor_id)
      end
      # Ported from a reference implementation's own condition check -- NOT
      # independently confirmed
      # against genuine RPG_RT under wine, active once Timer1 has counted
      # down to timer_sec or below, not on an exact match and not while
      # counting up.
      if (flags & TIMER) != 0
        return false if timer_seconds > cond.timer_sec
      end
      # TIMER2 is the identical rule against Timer2's own remaining seconds,
      # RPG2003-only -- ported from a reference implementation's own
      # RPG2003-gate check, NOT independently confirmed against genuine RPG_RT under wine.
      if (flags & TIMER2) != 0 && party && party.respond_to?(:rpg2003?) && party.rpg2003?
        return false if timer2_seconds > cond.timer2_sec
      end
      true
    end

    # Return [id, page] of the active page for an event, or nil when none apply.
    def self.select(pages, switches, variables, party, timer_seconds = 0, timer2_seconds = 0)
      return nil if pages.nil?
      chosen = nil
      pages.each do |id, page|
        chosen = [id, page] if active?(page.condition, switches, variables, party,
                                        timer_seconds, timer2_seconds)
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
    # Both the body and the argument order are taken from a reference
    # implementation, not
    # from guesswork (not independently confirmed against genuine RPG_RT
    # under wine): its turn-check helper is
    # `turns >= base && (turns - base) == 0` when multiple is 0
    # (which is just `turns == base`, written that way below) and
    # `turns >= base && (turns - base) % multiple == 0` otherwise; and
    # its condition check calls it with
    # the page's `turn_b` as `base` and `turn_a` as `multiple`, which reads backwards
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
    #
    # `source` is the battler a per-battler check runs *for* -- the scene passes
    # the battle's #acting_battler at a battler's action boundary. It gates the
    # turn_enemy / turn_actor / command_actor conditions the way a
    # reference implementation's own condition check does (ported, NOT independently
    # confirmed against genuine RPG_RT under wine): a page checked at one
    # battler's turn only fires off that battler's own counter/command, and a
    # command_actor page needs a source at all. A no-source round-boundary
    # check leaves those conditions ungated (turn_* test the named battler
    # regardless, command_actor fails), matching that ported behavior.
    def self.active?(cond, switches, variables, ctx, source = nil)
      # A page whose condition box is entirely unticked never runs -- ported
      # from a reference implementation's own condition check, which opens
      # with exactly this
      # test, NOT independently confirmed against genuine RPG_RT under wine.
      # Worth stating because the
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
      # turn_enemy / turn_actor / fatigue / command_actor are RPG2003-only
      # conditions -- ported from a reference implementation's own condition
      # check, NOT independently confirmed against genuine
      # RPG_RT under wine, which wraps all four in
      # its own RPG2003-commands gate. The RPG2000 editor's condition box
      # has no controls for any of these bits at all, so a genuine .lmt
      # should never set them on a non-2k3 database -- but an untested flag
      # with no guard reads as "always true" the instant one is set, exactly
      # the same silent-pass-through class of bug the map-event TIMER2
      # condition (Game::EventPage.active?, this file) was already fixed for.
      if (flags & TURN_ENEMY) != 0 && ctx.rpg2003?
        t = ctx.enemy_turn(cond.turn_enemy_id, source)
        return false if t.nil?
        return false unless check_turns(t, cond.turn_enemy_b, cond.turn_enemy_a)
      end
      if (flags & TURN_ACTOR) != 0 && ctx.rpg2003?
        t = ctx.actor_turn(cond.turn_actor_id, source)
        return false if t.nil?
        return false unless check_turns(t, cond.turn_actor_b, cond.turn_actor_a)
      end
      if (flags & COMMAND_ACTOR) != 0 && ctx.rpg2003?
        return false unless ctx.actor_command(cond.command_actor_id, source) == cond.command_id
      end
      if (flags & FATIGUE) != 0 && ctx.rpg2003?
        f = ctx.fatigue
        return false if f.nil?
        return false if f < cond.fatigue_min || f > cond.fatigue_max
      end
      true
    end

    # Every [id, page] whose condition currently holds, in page order — unlike
    # a map event (where the highest active page wins) RPG2000 runs *each*
    # matching battle page. `source` threads to #active? (the battler a
    # per-battler check runs for, see there).
    def self.select_all(pages, switches, variables, ctx, source = nil)
      out = []
      return out if pages.nil?
      pages.each { |id, page| out << [id, page] if active?(page.condition, switches, variables, ctx, source) }
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
    #
    # `:commands` is decoded eagerly only for AUTO_START/PARALLEL common
    # events -- the only ones anything here scans for every Scene::Map visit
    # (see #eligible and its callers in scene/map.rb), so their command lists
    # are genuinely needed up front. A CALLED-only common event (trigger 5,
    # invoked solely via a Call Event command) is never scanned that way; its
    # `:chunk` (the raw, undecoded LCF entry) is kept instead, and
    # EventResolver#common_event_commands decodes-and-caches it lazily, the
    # first time (if ever) a Call Event actually resolves that id. A real
    # project's common events skew heavily toward reusable CALLED-only
    # subroutines, so decoding all of them on every single map transition
    # (this method reruns per Scene::Map.new, not once per game) was pure
    # waste for however many of them a given map visit never calls.
    def self.load(db)
      list = []
      ce = db.common_event
      return list unless ce
      ce.each do |id, c|
        trigger = c.start_term
        eager = trigger == AUTO_START || trigger == PARALLEL
        list.push({ id: id, trigger: trigger, need_flag: c.need_flag,
                    switch_id: c.switch_id, chunk: c,
                    commands: (eager ? c.event : nil) })
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
  # Ported from a reference implementation, not independently confirmed
  # against genuine RPG_RT under wine: the style
  # ids are its own transition-type enum in order, the command-parameter tables
  # are its own erase/show-screen command switches, and the durations are its
  # own default-frames table.
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
    # two tables — that same reference implementation picks between them by
    # index parity, the erase slots being the even ones.
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

    # The scroll, combine / division, zoom, mosaic and wave styles: a black
    # mask cannot express them (the true old/new pixels have to move or
    # resample), so Scene::Map instead snapshots the screen once via
    # RGSS::Graphics.snap_to_bitmap when one of these starts and composites
    # that capture every frame -- see docs/TODO.md's "Screen effects" entry.
    # Scroll / combine / division / zoom composite through #capture_ops (a
    # list of blt/stretch_blt pieces); mosaic and wave instead want a native
    # per-pixel resample of the *whole* capture (mruby-rgss's
    # Bitmap#mosaic_blt / #wave_blt), so they go through their own
    # #mosaic_block_size / #wave_params accessors instead -- see #mosaic? /
    # #wave?. This class stays pure logic throughout (no Graphics access, per
    # the SCREEN_W/H comment above): it only computes the geometry or
    # resample parameters, never touches a Bitmap itself.
    CAPTURED = [SCROLL_UP_IN, SCROLL_DOWN_IN, SCROLL_LEFT_IN, SCROLL_RIGHT_IN,
                SCROLL_UP_OUT, SCROLL_DOWN_OUT, SCROLL_LEFT_OUT,
                SCROLL_RIGHT_OUT, VERTICAL_COMBINE, VERTICAL_DIVISION,
                HORIZONTAL_COMBINE, HORIZONTAL_DIVISION, CROSS_COMBINE,
                CROSS_DIVISION, ZOOM_IN, ZOOM_OUT, MOSAIC_IN, MOSAIC_OUT,
                WAVE_IN, WAVE_OUT].freeze

    # The random-blocks styles: a mask like BLIND_*/*_STRIPES_*/the window
    # pair above, but painted *incrementally* -- RPG_RT (and this port, see
    # #new_block_rects) only punches the blocks newly revealed this frame
    # rather than recomputing and repainting the whole cumulative mask every
    # frame, which is what the other mask styles' #visible_rects does and
    # what made this style expensive enough to be left unbuilt (~4800 blocks
    # by the last frame of a 320x240 screen). Scene::Map paints these via a
    # separate, identity-tracked path (#draw_random_blocks_transition)
    # instead of #visible_rects for exactly that reason.
    RANDOM_BLOCKS_STYLES = [RANDOM_BLOCKS, RANDOM_BLOCKS_DOWN,
                             RANDOM_BLOCKS_UP].freeze

    # Styles this build paints for real.
    DRAWN = [FADE_IN, FADE_OUT, BLIND_OPEN, BLIND_CLOSE, VERTICAL_STRIPES_IN,
             VERTICAL_STRIPES_OUT, HORIZONTAL_STRIPES_IN,
             HORIZONTAL_STRIPES_OUT, BORDER_TO_CENTER_IN, BORDER_TO_CENTER_OUT,
             CENTER_TO_BORDER_IN, CENTER_TO_BORDER_OUT, CUT_IN, CUT_OUT,
             NONE, *CAPTURED, *RANDOM_BLOCKS_STYLES].freeze

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

    # How long a style runs, in frames (per that same reference implementation's
    # own default-frames table): the plain
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

    # The random-blocks grid for a `width`x`height` screen: `[cols, rows]` of
    # BLOCK_SIZE-pixel blocks. Ported from a reference implementation's
    # source, NOT independently confirmed against genuine RPG_RT under
    # wine -- 320x240 is 80x60, 4800 blocks total, which
    # is where docs/TODO.md's "~120 of 4800" comes from (4800 blocks over the
    # 41-frame default length).
    BLOCK_SIZE = 4

    def self.block_grid(width, height)
      [width / BLOCK_SIZE, height / BLOCK_SIZE]
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
    # A reference implementation ramps the arriving screen in over
    # `total_frames - 2` (ported, not independently confirmed against genuine
    # RPG_RT under wine), so the fade
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

    # Whether this captured style is drawn by resampling (stretch_blt) rather
    # than pasted 1:1 (blt) -- Scene::Map uses this to pick which Bitmap method
    # matches #capture_ops's return shape for this style (see #zoom_rect).
    def zoom?
      @style == ZOOM_IN || @style == ZOOM_OUT
    end

    # Whether this captured style is drawn by mosaic/wave resample (native
    # `Bitmap#mosaic_blt` / `#wave_blt`) rather than #capture_ops's blt /
    # stretch_blt pieces -- Scene::Map checks these before falling back to
    # #capture_ops (see #zoom? for the sibling check that picks stretch_blt).
    def mosaic?
      @style == MOSAIC_IN || @style == MOSAIC_OUT
    end

    def wave?
      @style == WAVE_IN || @style == WAVE_OUT
    end

    # The pixel block size `Bitmap#mosaic_blt` resamples the captured screen
    # at this frame (matching a reference implementation's own mosaic-size
    # field, not independently confirmed against genuine RPG_RT under wine):
    # the "in" (Show)
    # style starts fully mosaic'd (block size @frames) and sharpens to 1 by
    # the last frame; the "out" (Erase) style runs the same ramp the other
    # way, starting sharp and getting chunkier. Only called when #mosaic? is
    # true.
    def mosaic_block_size
      mosaic_wave_progress
    end

    # `[depth, phase]` for `Bitmap#wave_blt` this frame (a reference
    # implementation's own depth/phase pair, ported from its wave-transition
    # case -- NOT independently confirmed against genuine RPG_RT under wine
    # -- which itself calls its own blit helper, ported to `mruby-rgss`'s
    # `bmp_wave_blt`): depth
    # is the same @frames..1 / 1..@frames progression #mosaic_block_size
    # uses (the wave settles to flat as a Show finishes, and grows wilder as
    # an Erase runs out), and phase is that same source's own `p * 5 * PI /
    # tf_off + PI` ramp (`tf_off` == #span). Only called when #wave? is true.
    def wave_params
      p = mosaic_wave_progress
      d = span
      phase = (d <= 0 ? 0 : p * 5 * Math::PI / d) + Math::PI
      [p, phase]
    end

    # The captured screen's pieces for this frame. For every style but zoom,
    # each piece is `[dx, dy, sx, sy, sw, sh]` -- paste the capture's `[sx, sy,
    # sw, sh]` region at `(dx, dy)` with `Bitmap#blt` (destination size always
    # matches source size). Zoom instead resamples, so its one piece is `[dx,
    # dy, dw, dh, sx, sy, sw, sh]` for `Bitmap#stretch_blt` -- see #zoom?.
    # Mosaic and wave are not returned here at all -- see #mosaic_block_size /
    # #wave_params instead. Only called for a captured, non-mosaic, non-wave
    # style; Scene::Map paints these over a black fill, so a piece that has
    # slid (or shrunk) off leaves black behind it.
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
      when ZOOM_IN, ZOOM_OUT
        [zoom_rect]
      else
        []
      end
    end

    # Whether this style is one of the random-blocks family (see
    # RANDOM_BLOCKS_STYLES) -- Scene::Map paints these through
    # #new_block_rects instead of #visible_rects.
    def random_blocks?
      RANDOM_BLOCKS_STYLES.include?(@style)
    end

    # The blocks newly revealed *this* frame only -- not the cumulative mask
    # #visible_rects's callers get from the other shaped styles. Each block is
    # `[x, y, BLOCK_SIZE, BLOCK_SIZE]`; painting only these over an overlay
    # that started (and stays) opaque black is a reference implementation's
    # own incremental
    # paint (ported from its source, NOT independently confirmed against
    # genuine RPG_RT under wine): its own block-count-to-print formula is
    # `#block_count_through(@frame)` here, and its previous-frame count
    # (the count already painted as of the previous frame) is
    # `#block_count_through(@frame - 1)`.
    #
    # #block_order (below) stands in for that same source's own block-index
    # vector
    # -- a full permutation of every block index, sliced by count rather than
    # walked one at a time, so calling this again for a frame already drawn
    # (replaying, or a test asserting on frame 5 after frame 3) returns the
    # exact same rects rather than depending on how many times it was called
    # before. That is a deliberate difference from that source's own
    # shuffle-and-track approach: this class
    # holds no Graphics access and no RNG state, only the two ints every
    # other style already carries (@frame, @frames), per the "pure logic,
    # unit-testable" precedent #capture_ops and #visible_rects set.
    def new_block_rects
      block_rects(block_count_through(@frame - 1), block_count_through(@frame))
    end

    # Every block revealed by (and including) this frame -- the full
    # cumulative mask, unlike #new_block_rects's this-frame-only delta.
    # Scene::Map uses this once, the first frame it paints a given
    # transition instance, to catch the overlay up in a single pass even
    # when that first paint lands after frame 0 (the frame counter has
    # already advanced once before the very first #update/render pass in
    # some call orders -- see the vertical-division capture test's own "frame
    # 1 is the first rendered frame" note in scripts/rpg2k_scene_check.rb):
    # #new_block_rects alone would only punch the delta since frame 0 and
    # silently leave frame 0's own blocks unrevealed forever in that case.
    def revealed_block_rects
      block_rects(0, block_count_through(@frame))
    end

    private

    # Pixel rects for block indices `[from, to)` in reveal order.
    def block_rects(from, to)
      cols = block_grid_cols
      block_order[from...to].map do |i|
        [(i % cols) * BLOCK_SIZE, (i / cols) * BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE]
      end
    end

    # The frame index the geometry is drawn at, and the span it runs over —
    # a reference implementation's own current-frame and total-frames-minus-one.
    def span; @frames - 1; end

    # `[p, d]` for the same frame0..1 linear ramp `border_to_center_rect` etc.
    # use below, factored out for the capture-geometry helpers.
    def frame_ratio
      d = span
      d <= 0 ? [1, 1] : [@frame, d]
    end

    # A reference implementation's own `p` for the mosaic/wave pair (ported
    # from its source, NOT
    # independently confirmed against genuine RPG_RT under wine):
    # `@frames - @frame` for the "in" (Show) styles, `@frame + 1` for "out"
    # (Erase) -- shared by #mosaic_block_size and #wave_params. Clamped to at
    # least 1 as a defensive floor for a frame at or past #done? (@frame ==
    # @frames), which never happens in normal play but would otherwise divide
    # by zero in #mosaic_blt's block size.
    def mosaic_wave_progress
      out = @style == MOSAIC_OUT || @style == WAVE_OUT
      p = out ? @frame + 1 : @frames - @frame
      p < 1 ? 1 : p
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

    # Zoom: the capture is drawn full-screen every frame, resampled from a
    # source region that shrinks toward the screen's centre (ZOOM_IN, an
    # Erase, shrinking the departing scene down to nothing) or grows back out
    # from it (ZOOM_OUT, a Show, growing the arriving scene up to full size).
    #
    # Ported from a reference implementation's own transition source, NOT independently confirmed
    # against genuine RPG_RT under wine: the destination rect is
    # always the full screen (`dst.StretchBlit(Rect(0, 0, w, h), *screen,
    # Rect(z_pos, z_size), 255)`), and it is the *source* rect that shrinks or
    # grows -- cropping progressively closer to the zoom point and stretching
    # that crop to fill the screen is what reads as "zooming in" on it, rather
    # than the drawn image itself shrinking to a small rect. `z_size` there
    # ramps `(tf_off - z_cf) / tf_off` with `z_cf = current_frame` for
    # ZoomIn (so it starts full and ends at zero) and `z_cf = tf_off -
    # current_frame` for ZoomOut (the same ramp run backwards) -- the same
    # shrink/grow direction this mirrors with #frame_ratio. That settles the
    # IN/OUT direction this build's own comment used to say was "left rather
    # than guessed": ZOOM_IN shrinks, ZOOM_OUT grows.
    #
    # That same reference implementation's own zoom point is the hero's
    # screen position on the map (the
    # screen centre otherwise); this class stays pure geometry with no scene
    # or player access (see the SCREEN_W/H comment above CAPTURED), so it
    # anchors on the screen centre unconditionally -- the same simplification
    # #cross_split_ops's own quadrant motion already documents.
    def zoom_rect
      p, d = frame_ratio
      if @style == ZOOM_OUT
        sw = @width * p / d
        sh = @height * p / d
      else
        sw = @width - @width * p / d
        sh = @height - @height * p / d
      end
      [0, 0, @width, @height, (@width - sw) / 2, (@height - sh) / 2, sw, sh]
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

    # This instance's block grid, in columns -- see .block_grid.
    def block_grid_cols
      @width / BLOCK_SIZE
    end

    # How many blocks are revealed by (and including) `frame`, clamped to the
    # block total -- matching a reference implementation's own blocks-to-print
    # formula. A negative `frame`
    # (#new_block_rects asking for the count *before* frame 0) is nothing
    # revealed yet.
    def block_count_through(frame)
      return 0 if frame < 0
      total = block_order.size
      d = span
      return total if d <= 0
      n = total * (frame + 1) / d
      n > total ? total : n
    end

    # A deterministic scramble of `index` into `0...total`, standing in for
    # `std::shuffle`'s randomness (see #new_block_rects) -- a multiplicative
    # hash mod the block count. BLOCK_SHUFFLE_STRIDE is prime and far smaller
    # than any screen's block total this build reaches, so the map stays a
    # bijection (a full reshuffle, not a lossy hash) for every grid actually
    # in use.
    BLOCK_SHUFFLE_STRIDE = 2749

    def block_shuffle_rank(index, total)
      (index * BLOCK_SHUFFLE_STRIDE) % total
    end

    # The reveal order for this transition's block grid: `order[k]` is the
    # block index (row-major, matching #new_block_rects's own `i % cols` /
    # `i / cols`) revealed at cumulative position `k`. Memoized -- @style /
    # @width / @height never change after #initialize, so this is the same
    # array on every call, computed once regardless of how many frames are
    # drawn.
    #
    # RANDOM_BLOCKS shuffles every block into one random order, matching
    # a reference implementation's own full-array shuffle (not independently
    # confirmed against genuine RPG_RT under wine). RANDOM_BLOCKS_DOWN/UP
    # bias that order by row (top rows first for
    # Down, bottom rows first for Up) rather than shuffling uniformly --
    # that same source's own version of that bias is a windowed per-row
    # shuffle-and-partial-sort (ported from its
    # source and NOT independently confirmed against genuine RPG_RT under
    # wine)
    # that this class does not attempt to port bit-for-bit: it depends on
    # replaying the same Mersenne Twister stream that source's own RNG
    # would produce, which is not meaningful to match without matching its
    # RNG too, and this class carries no RNG state at all (see
    # #new_block_rects). Sorting every block by `[row, shuffle rank]` (or
    # `[-row, shuffle rank]` for Up) keeps the same reasoned-simplification
    # policy #cross_split_ops's quadrant motion and #zoom_rect's screen-centre
    # anchor already use elsewhere in this class: reproduce the *behaviour* a
    # real style reads as (a top-to-bottom or bottom-to-top wave, shuffled
    # within it) rather than an unmatchable RNG trace.
    def compute_block_order
      cols = block_grid_cols
      total = cols * (@height / BLOCK_SIZE)
      indices = (0...total).to_a
      case @style
      when RANDOM_BLOCKS_DOWN
        indices.sort_by { |i| [i / cols, block_shuffle_rank(i, total)] }
      when RANDOM_BLOCKS_UP
        indices.sort_by { |i| [-(i / cols), block_shuffle_rank(i, total)] }
      else
        indices.sort_by { |i| block_shuffle_rank(i, total) }
      end
    end

    def block_order
      @block_order ||= compute_block_order
    end
  end

  # Screen-effect state driven by the screen event commands. Models tint,
  # shake, flash, pan and fade (Flash/Pan/Fade were later additions to this
  # class; each now has its own accessors and `update` branch below, the same
  # way Tint/Shake do):
  #
  # * **Tint** (Tint Screen, 11030): a colour multiplier given as RPG2000's four
  #   0..200 channels (red / green / blue / saturation, 100 = neutral). `tint_to`
  #   starts a transition to a target over N frames and `update` steps the
  #   channels toward it with the classic RPG2000/RGSS
  #   `cur += (target - cur) / frames_left` interpolation, which lands exactly on
  #   the target on the final frame. `Scene::Map#update_map_tone` applies this
  #   as the shared map `Viewport`'s `RGSS::Viewport` tone (and, while a fight
  #   is open, the battle backdrop's), so the tint does draw.
  # * **Shake** (Shake Screen, 11050): a horizontal camera offset that oscillates
  #   while active. `shake` starts a timed shake and `update` advances it with
  #   a direct port of a reference implementation's own shake-position/update
  #   logic
  #   (NOT independently confirmed against genuine RPG_RT under wine)
  #   rather than an approximation: a genuine `Math.sin` wave
  #   (`mruby-math` is already in this build's gem set, `build_config.rb` —
  #   `Scene::Map`'s enemy-levitate flying offset already reaches for
  #   `Math.sin`/`Math::PI` the same way, see `#draw_enemy_sprite`) whose
  #   amplitude is `1 + 2 * power` — not just `2 * power`, so even a nominal
  #   "power 0" shake still moves the view by +-1px, one of the two facts this
  #   port fixed over the previous triangle-wave guess — and whose per-frame
  #   *step* is separately capped at `(speed * amplitude) / 8 + 1` off the
  #   previous frame's own position, the other fixed fact (a smoothing clamp
  #   with no triangle-wave equivalent,
  #   the other reason "power 0" no longer reads as flatly inert). The scene
  #   reads `shake_offset` and offsets the camera by it, so the shake *is*
  #   visible.
  #
  # `update` (called once per frame by the scene) advances all of them.
  class Screen
    NEUTRAL = 100 # a channel value that leaves the screen unchanged

    # A continuous-shake restart constant (ported from a reference
    # implementation's source, NOT
    # independently confirmed against genuine RPG_RT under wine): the frame
    # count a
    # RPG2003 Shake Screen Begin strobe re-arms to every time it counts down
    # to 0, rather than settling -- that source's own comment on the constant
    # claims it deliberately avoids a real RPG_RT bug where a naive "forever"
    # sentinel let a continuous shake actually stop after 18m12s.
    SHAKE_CONTINUOUS_FRAMES = 65535

    def initialize
      @r = @g = @b = @sat = NEUTRAL
      @tr = @tg = @tb = @tsat = NEUTRAL
      @frames = 0 # frames left in the current tint transition (0 = settled)
      @shake_power = 0
      @shake_speed = 1
      @shake_frames = 0 # frames left in the current shake (0 = still)
      @shake_offset = 0
      @shake_continuous = false # RPG2003 Begin/End strobe: re-arms at 0 instead of settling
      @flash_r = @flash_g = @flash_b = 0
      @flash_power = 0 # peak strength of the current flash
      @flash_strength = 0 # current strength, fading to 0 over the duration
      @flash_frames = 0 # frames left in the current flash (0 = faded out)
      @flash_total = 0
      @flash_continuous = false # RPG2003 Begin/End strobe: re-arms at 0 instead of settling
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

    # Current tint as [red, green, blue, saturation] (each 0..200, 100
    # neutral), truncated to a whole number here -- ported from a reference
    # implementation's own tint-channel fields (`double` fields, truncated
    # only where they
    # are actually consumed, e.g. building the render `Tone`), NOT
    # independently confirmed against genuine RPG_RT under wine -- while
    # #update_tint keeps the full float precision internally between frames.
    # See #update_tint's own comment for why the two must not be the same
    # value.
    def tint; [@r.to_i, @g.to_i, @b.to_i, @sat.to_i]; end

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

    # The current pan offset [x, y] in whole pixels, added to the camera by the
    # scene. @pan_x/@pan_y themselves may sit at a sub-pixel value mid-pan (see
    # #pan_step_for) -- rounded only here, at the point of consumption, the
    # same way real RPG_RT's own 1/16-pixel subpixel pan position is only ever
    # rounded to a whole pixel for display.
    def pan_offset; [@pan_x.round, @pan_y.round]; end

    # Whether a Lock operation has frozen the camera in place — the scene stops
    # following the hero while this holds. The pan offset (see #pan_offset) is
    # applied by the scene independently of this flag.
    def pan_locked?; @pan_locked; end

    # True while a pan/reset scroll has not yet reached its target.
    def panning?; @pan_x != @pan_tx || @pan_y != @pan_ty; end

    # Persisted pan/lock state only, mirroring Weather's own `to_h`/`load_h`
    # idiom. Every *other* field this class holds (tint transition, shake,
    # flash, fade) stays deliberately transient -- see the class-level
    # "Transient screen-effect state" comment on `Game::State#initialize` --
    # but Pan Screen's Lock is not a per-frame effect the same way: it is a
    # standing camera mode a script can leave active indefinitely (e.g. a
    # cutscene that pans and locks the view before a Save event or the
    # player opening the menu to save), and dropping it silently snapped the
    # camera back to hero-centred *and* unlocked on every load -- the pan
    # offset and its still-in-flight target/step are carried too so a pan
    # that had not finished scrolling when the game was saved resumes the
    # rest of that scroll instead of jumping straight to (or short of) its
    # destination.
    def to_h
      { pan_x: @pan_x, pan_y: @pan_y, pan_tx: @pan_tx, pan_ty: @pan_ty,
        pan_step: @pan_step, pan_locked: @pan_locked }
    end

    def load_h(h)
      return unless h
      @pan_x = h[:pan_x] || 0
      @pan_y = h[:pan_y] || 0
      @pan_tx = h[:pan_tx] || 0
      @pan_ty = h[:pan_ty] || 0
      @pan_step = h[:pan_step] || 1
      @pan_locked = h[:pan_locked] ? true : false
    end

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

    # The raw tint state for `.lsd` chunk 102: [finish_rgbs, current_rgbs,
    # frames_left], matching liblcf's SaveScreen fields one-for-one (see
    # #restore_tint, its inverse).
    def tint_save_data
      [[@tr, @tg, @tb, @tsat], [@r, @g, @b, @sat], @frames]
    end

    # Restore a tint transition read back from `.lsd` chunk 102: `finish` and
    # `current` are each [red, green, blue, sat], `frames` the frames still
    # left. Unlike #tint_to, `current` need not equal `finish` -- a save made
    # mid-transition resumes interpolating from exactly where it left off.
    def restore_tint(finish, current, frames)
      @tr, @tg, @tb, @tsat = finish
      @r, @g, @b, @sat = current
      @frames = frames
    end

    # Begin a timed shake of the given power and speed for `frames` frames
    # (frames <= 0 stops the shake immediately). Power/speed clamp to sane ranges.
    def shake(power, speed, frames)
      @shake_power = Game.clamp(power, 0, 9)
      @shake_speed = Game.clamp(speed, 1, 9)
      if frames <= 0
        @shake_frames = 0
        @shake_offset = 0
      else
        @shake_continuous = false
        @shake_frames = frames
      end
    end

    # RPG2003 Shake Screen mode 1: begin an indefinite strobe at the given
    # strength/speed that re-arms every time it counts down instead of
    # settling -- matches a reference implementation's own indefinite-shake
    # start (not independently confirmed against genuine RPG_RT under wine),
    # which (unlike #shake)
    # takes no duration at all: only #shake_end (or a fresh one-shot #shake)
    # stops it. Shake position is deliberately left alone, same as #shake,
    # so an interrupting shake flows smoothly instead of snapping to centre.
    def shake_begin(power, speed)
      @shake_power = Game.clamp(power, 0, 9)
      @shake_speed = Game.clamp(speed, 1, 9)
      @shake_continuous = true
      @shake_frames = SHAKE_CONTINUOUS_FRAMES
    end

    # RPG2003 Shake Screen mode 2: stop a #shake_begin strobe immediately,
    # settled back to centre -- ported from a reference implementation's own
    # shake-stop handling, NOT
    # independently confirmed against genuine RPG_RT under wine: it
    # does not clear the continuous flag here (only a fresh one-shot/Begin
    # call does), though with @shake_frames at 0 it has no effect until
    # something else sets a shake running again.
    def shake_end
      @shake_offset = 0
      @shake_frames = 0
    end

    # Begin a flash of colour (r, g, b) at peak strength `power`, fading linearly
    # to 0 over `frames` frames (frames <= 0 clears any flash immediately). A
    # one-shot flash (RPG2003's Flash Screen mode 0, or the pre-2003 command
    # shape) — ported from a reference implementation, NOT
    # independently confirmed against genuine RPG_RT under wine: it always
    # clears any in-progress strobe.
    def flash(r, g, b, power, frames)
      @flash_continuous = false
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

    # RPG2003 Flash Screen mode 1: like #flash, but the strobe re-arms to peak
    # strength every time it fades out, indefinitely, until #flash_end (or a
    # fresh one-shot #flash) stops it — matches a reference implementation's
    # own indefinite-flash start (not independently confirmed against
    # genuine RPG_RT under wine).
    def flash_begin(r, g, b, power, frames)
      flash(r, g, b, power, frames)
      @flash_continuous = true
    end

    # RPG2003 Flash Screen mode 2: stop a #flash_begin strobe immediately,
    # settled at no flash — matches a reference implementation's own
    # flash-stop handling (not independently confirmed against genuine
    # RPG_RT under wine).
    def flash_end
      @flash_continuous = false
      @flash_frames = 0
      @flash_strength = 0
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

    # The reference implementation this was ported from (NOT independently
    # confirmed against genuine RPG_RT under wine) interpolates the tint in a
    # `double` (`tint_current_red` et al. --
    # confirmed against liblcf's own generated `SaveScreen` struct, where
    # those four fields are `double` while the `tint_finish_*` targets stay
    # `int32_t`) across every frame of the transition, via `interpolate(d,
    # x0, x1) = (x0*(d-1) + x1) / d` -- algebraically `x0 + (x1-x0)/d` -- and
    # only ever truncates to a whole number where the tint is actually read
    # (#tint, mirroring that reference implementation's own render-time cast).
    # A prior version of
    # this method instead used plain Ruby integer division and wrote the
    # truncated result straight back into `@r`/`@g`/`@b`/`@sat`, which the
    # *next* frame's own step then read back as its own starting point --
    # the same "feed the previous frame's truncated value back into the next
    # frame's own division" bug already fixed for `Game::Picture#step`
    # (rounding error compounding across the whole transition instead of
    # resetting each frame), just never applied here.
    def update_tint
      return if @frames <= 0
      @r += (@tr - @r) / @frames.to_f
      @g += (@tg - @g) / @frames.to_f
      @b += (@tb - @b) / @frames.to_f
      @sat += (@tsat - @sat) / @frames.to_f
      @frames -= 1
      return unless @frames.zero?
      @r = @tr; @g = @tg; @b = @tb; @sat = @tsat # land exactly on the target
    end

    # Port of a reference implementation's shake-update logic (NOT
    # independently confirmed against genuine RPG_RT under wine):
    # `@shake_frames` is the same role as its `time_left` (already converted
    # from tenths of a second to frames, see Interpreter#do_shake_screen), so
    # this mirrors its decrement-then-sample structure exactly rather than
    # re-deriving the timing separately.
    def update_shake
      if @shake_frames <= 0
        @shake_offset = 0
        return
      end
      @shake_frames -= 1
      if @shake_frames <= 0 && @shake_continuous
        # A Begin strobe never settles: re-arm for another full duration
        # instead of stopping, matching `Shake::Update`'s own continuous
        # re-arm.
        @shake_frames = SHAKE_CONTINUOUS_FRAMES
      end
      if @shake_frames <= 0
        @shake_offset = 0 # settle back to centre when the shake ends
        return
      end
      amplitude = 1 + 2 * @shake_power
      phase = (@shake_frames * 4 * (@shake_speed + 2)) % 256
      newpos = (amplitude * Math.sin(phase * Math::PI / 128) * -1).to_i
      # The step off the *previous* frame's own offset is separately capped,
      # a smoothing rule distinct from the amplitude bound above -- without
      # it a low-speed, high-power shake could otherwise jump between two far
      # apart sine samples in a single frame.
      cutoff = (@shake_speed * amplitude) / 8 + 1
      @shake_offset = Game.clamp(newpos, @shake_offset - cutoff, @shake_offset + cutoff)
    end

    def update_flash
      return if @flash_frames <= 0
      @flash_frames -= 1
      if @flash_frames <= 0 && @flash_continuous
        # A Begin strobe never settles: re-arm at peak strength for another
        # full duration, matching `Flash::Update`'s own continuous re-arm.
        @flash_frames = @flash_total
        @flash_strength = @flash_power
      else
        # Strength fades linearly from the peak power to 0 across the duration.
        @flash_strength = @flash_total > 0 ? @flash_power * @flash_frames / @flash_total : 0
      end
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

    # Pixels moved per frame for a pan speed (1..6): `(2 << speed) / 16.0`,
    # i.e. a raw `2 << speed` step through a 1/16-pixel subpixel space
    # (sixteen per this codebase's own real TILE = 16 px) -- 0.25, 0.5, 1, 2,
    # 4, 8 px/frame for speed 1..6, not a plain doubling starting at a whole
    # pixel (1, 2, 4, 8, 16, 32), which was 4x too fast at every setting.
    # @pan_x/@pan_y (see #approach/#pan_offset) accumulate this sub-pixel-
    # per-frame rate exactly at speeds 1/2 (0.25 and 0.5 are both exact
    # powers of two in binary floating point, so this never drifts), landing
    # on the same whole-pixel target #pan_offset's own rounding always
    # resolves to once a pan finishes.
    #
    # **Confirmed against genuine RPG_RT.exe under wine (cycle #178,
    # 2026-08-26)**, at speeds 1 and 3: Nepheshel's own `Map0521.lmu` event 1
    # page 1 (trigger=3 autostart, condition flags=0) is a genuine, already-
    # authored Pan Screen (op=2, direction=left, distance=9 tiles, **wait
    # ON**) immediately followed by Erase Screen then a Teleport -- the one
    # `wait==1` Pan Screen call found anywhere across every Nepheshel map
    # (checked by dumping every map's own event-command list), so its own
    # Erase Screen (a plain fade to black, ~35 frames/0.58s once the pan's
    # own interpreter wait releases it) is a directly observable, real-engine
    # marker of exactly when the pan finished. Timed with fixed-offset
    # screenshots (0.25s resolution) from the moment Continue loaded a save
    # standing on map 521 (no code, only Save01.lsd's own hero-position
    # chunk edited via `gen-rpg2k-save.rb --map 521 --clear-scene`):
    # at the genuine, unmodified speed 1 the screen was still visibly
    # scrolling at t=11.5s and fully black by t=12.0s; at speed 3 (the map's
    # own Pan Screen command's speed parameter edited in place from 1 to 3,
    # nothing else touched, then restored byte-identical afterward) the same
    # transition landed at t=4.5-5.0s instead. `(2<<3)/16.0 - (2<<1)/16.0 =
    # 0.75` px/frame more at speed 3 than speed 1 predicts a 144px/0.25 -
    # 144px/1.0 = 576 - 144 = 432-frame (7.2s) gap between the two runs'
    # pan durations; the observed gap between the two runs' own black-screen
    # landings was ~7.0s (12.0s - ~5.0s) -- matching to within the
    # measurement's own 0.25s screenshot resolution and ruling out the
    # rejected "plain doubling from a whole pixel" alternative by a wide
    # margin (that table predicts only a 2.4s - 0.6s = 1.8s gap between the
    # same two speeds, a 4x smaller difference than what genuine RPG_RT
    # actually shows). See docs/TODO.md's cycle #178 entry for the full
    # screenshot-by-screenshot timing table and the probe scripts.
    def pan_step_for(speed)
      (2 << Game.clamp(speed, 1, 6)) / 16.0
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

    # The position given to the most recent Show Picture call for this id --
    # `.lsd` chunk 103's own field 2/3, identified behaviorally by cycle #155
    # (see SAVE_PICTURE's own comment for the experiment): unlike `#x`/`#y`
    # below, a Move Picture (`#move_to`) never touches these, only a fresh
    # `Picture.new` (i.e. another Show Picture on this same id) does.
    attr_reader :show_x, :show_y

    # Every interpolated field is truncated to a whole number here (ported
    # from a reference implementation's own display-time truncation,
    # NOT independently confirmed against genuine RPG_RT under wine) but held
    # at full float precision internally between frames -- see #step's own
    # comment for why the two must not be the same value.
    def x; @x.to_i; end
    def y; @y.to_i; end
    def zoom; @zoom.to_i; end
    def opacity; @opacity.to_i; end
    def red; @red.to_i; end
    def green; @green.to_i; end
    def blue; @blue.to_i; end

    # The in-flight move's own target values and remaining frame count (nil/0
    # when never moved or already arrived) -- for `.lsd` chunk 103's own
    # finish_*/time_left fields, which #to_lsd writes from these while
    # #moving?, see SAVE_PICTURE's own comment on why fields 31/32/etc are
    # named finish_*, not current_*.
    def finish_x; @tx; end
    def finish_y; @ty; end
    def finish_zoom; @tzoom; end
    def finish_opacity; @topacity; end
    def finish_red; @tred; end
    def finish_green; @tgreen; end
    def finish_blue; @tblue; end
    def finish_saturation; @tsat; end
    def frames_left; @frames; end
    def saturation; @saturation.to_i; end

    # Whether this id is currently on screen -- false once #erase! has run.
    # A distinct flag rather than "name non-empty": a fresh `Picture.new`
    # with no `:name` (as several pre-existing scene-check fixtures build one
    # directly, skipping Show Picture, purely to seed a position for a Move/
    # Erase Picture check) must still read as shown -- only an *explicit*
    # #erase! turns this false. An id that has never been shown at all has no
    # `Picture` object in `Game::State#pictures` to begin with (see
    # `#erase_picture`'s own comment), so this predicate only ever needs to
    # distinguish "currently shown" from "was shown, now erased". Deliberately
    # independent of #moving? -- see #erase!'s own comment: an erased picture
    # can still be moving (invisibly) for a while after this goes false.
    def shown?; @shown; end

    def initialize(id, opts = {})
      @id = id
      @name = opts[:name] || ''
      @shown = true
      @x = opts[:x] || 0
      @y = opts[:y] || 0
      # Defaults to the shown position itself: the live Show Picture command
      # (#do_show_picture) never passes these explicitly, so an ordinary
      # fresh show records its own x/y as-shown, exactly matching genuine
      # RPG_RT. #restore_pictures passes the saved field 2/3 explicitly, for
      # a save whose picture was already mid-Move-Picture when written (so
      # `x`/`y` above hold the live *current* position, not the original
      # show position, which is what these must restore to instead).
      @show_x = opts[:show_x] || @x
      @show_y = opts[:show_y] || @y
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

    # Erase Picture (11130): turns #shown? false (so nothing draws --
    # `Scene::Map#draw_pictures` gates on it explicitly, since the name
    # itself is deliberately left alone here, see below) but otherwise leaves
    # name/position/zoom/tone exactly as they stood at the moment of erasure,
    # and -- confirmed by cycle #163, see below -- does NOT halt an in-flight
    # move: a picture erased mid-Move-Picture keeps gliding invisibly toward
    # its old target and only stops when the move's own duration elapses.
    # Confirmed against genuine RPG_RT.exe under wine (cycle #159): a Show
    # Picture immediately followed by Erase Picture, then an Open Save Menu,
    # produced a genuine `.lsd` chunk 103 entry with field 1 (name) *absent*
    # but fields 2/3/4/5/7/8/11-14/31/32/33/34/41-44 all still *present*,
    # carrying the exact values the picture held before erasure -- decisively
    # distinct from an id that was never shown at all, which cycle #154
    # already established writes as a fully field-less placeholder (every one
    # of those fields absent, not merely zero). `#to_lsd` reads `#shown?`,
    # not `#name`, to decide whether to write field 1 -- `@name` itself is
    # left untouched here (rather than cleared) because several pre-existing
    # scene-check fixtures build a `Picture.new` directly with no `:name` at
    # all, purely to seed a position, and must still read as shown; clearing
    # `@name` on erasure would have made an *empty* name ambiguous between
    # "never had one" and "erased". `Game::State` keeps this `Picture` object
    # in `@pictures` after an erase (see `#erase_picture`) specifically so
    # `#to_lsd` can still read these fields back out.
    #
    # Whether a picture still mid-move at the moment of Erase Picture freezes
    # at its live interpolated position or keeps gliding toward its old
    # target (left open by cycle #159, still open through cycle #162) is now
    # settled: cycle #163 drove genuine RPG_RT.exe under wine through two
    # scenarios sharing one Show Picture (x=50,y=50) -> Move Picture (to
    # x=250,y=250 over 10.0s, wait flag off) -> Erase Picture -> Wait N ->
    # Open Save Menu sequence, differing only in N (1.0s vs 5.0s), and read
    # each resulting genuine Save0N.lsd's raw chunk 103 with
    # `LCF::SaveData` + the raw-field reader: field 4/5 (current_x/y) came
    # back **70.0** after the 1.0s wait and **150.0** after the 5.0s wait --
    # both strictly between the 50/250 endpoints and increasing with elapsed
    # time since the erase, not frozen at a single value -- while field 51
    # (time_left) came back 540 and 300 respectively, a 240-frame drop across
    # 4.0s of extra elapsed time (60fps, matching the 600-frame/10.0s move
    # total implied by 540 + 1.0s*60fps). A frozen picture would have shown
    # identical current_x/y and time_left in both captures regardless of N;
    # instead both tracked continued, undisturbed progress toward the
    # original target exactly as if Erase Picture had never been issued,
    # except for the drawn sprite itself. This is simply what already
    # happens for free once `#erase!` stops forcing `@frames` to 0: `Game::
    # State#update_pictures` (`@pictures.each_value(&:update)`) already
    # iterates every id in `@pictures` regardless of `#shown?`, so an erased-
    # but-still-moving `Picture` keeps ticking down and interpolating exactly
    # like a shown one, invisibly, until its own move naturally completes.
    def erase!
      @shown = false
    end

    # Advance one frame of the in-flight move (a no-op when at rest). Every
    # parameter eases a `1/remaining` fraction toward its target, in float
    # precision, so it still lands exactly on the target on the final frame
    # (`(target - cur) / 1.0` is exactly `target - cur`).
    #
    # Ported from a reference implementation's own picture-update logic, NOT
    # independently confirmed against genuine RPG_RT under wine -- it
    # keeps this same running fraction in a double (`data.current_x` et al.,
    # `interpolate`'s `(finish - current) / dt + current`) across every frame
    # and truncates only for display (`int x =
    # data.current_x`) -- the truncation never feeds back into the next
    # frame's own calculation. A prior version of this method instead fed the
    # *already-truncated* `@x` (an Integer, via plain `/` integer division)
    # back into the next call, so the rounding error compounded frame over
    # frame instead of resetting each time: a 0->10 move over 7 frames here
    # produced 1, 2, 3, 4, 6, 8, 10 where real RPG_RT's own (float-precision,
    # truncate-for-display-only) sequence is 1, 2, 4, 5, 7, 8, 10 -- a
    # visibly different, laggier path any time the move distance is not an
    # exact multiple of the frame count, which is nearly every real Move
    # Picture call.
    def update
      return unless moving?
      @x = step(@x, @tx); @y = step(@y, @ty)
      @zoom = step(@zoom, @tzoom); @opacity = step(@opacity, @topacity)
      @red = step(@red, @tred); @green = step(@green, @tgreen)
      @blue = step(@blue, @tblue); @saturation = step(@saturation, @tsat)
      @frames -= 1
    end

    # Snapshot for this engine's own internal Marshal-style quick-resume
    # (Game::State#to_h/.load) -- a private format with none of `.lsd`'s own
    # field-count/byte-format constraints, so unlike `SAVE_PICTURE` (chunk
    # 103) this can and does carry every field this class holds, including
    # `fixed_to_map`/`use_transparent_color` (also modelled in `.lsd` as of
    # cycle #164 -- chunk 103 fields 6/9, see SAVE_PICTURE's own schema
    # comment for the genuine-RPG_RT.exe evidence) and the live in-flight
    # move target/frame-count, so a picture mid-Move-Picture at save time
    # keeps gliding after a resume instead of snapping to rest.
    def to_h
      { name: @name, x: @x, y: @y, show_x: @show_x, show_y: @show_y,
        zoom: @zoom, opacity: @opacity, red: @red, green: @green,
        blue: @blue, saturation: @saturation, fixed_to_map: @fixed_to_map,
        use_transparent_color: @use_transparent_color,
        tx: @tx, ty: @ty, tzoom: @tzoom, topacity: @topacity,
        tred: @tred, tgreen: @tgreen, tblue: @tblue, tsat: @tsat,
        frames: @frames }
    end

    # Inverse of #to_h. `Picture.new`'s own opts already cover every at-rest
    # field by the same key names; only the in-flight move state (absent from
    # `opts`) needs restoring afterward, the same two-step shape
    # `Game::State.restore_pictures` already uses for the `.lsd` path
    # (`Picture.new` then `#move_to`).
    def self.from_h(id, h)
      return nil unless h
      p = new(id, h)
      frames = h[:frames] || 0
      if frames > 0
        p.move_to(h[:tx], h[:ty], h[:tzoom], h[:topacity], h[:tred],
                  h[:tgreen], h[:tblue], h[:tsat], frames)
      end
      p
    end

    private

    def step(cur, target); cur + (target - cur) / @frames.to_f; end

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

    # Database flavour/effect text of item `id` ('' when missing) -- the line
    # the shop screen's own description bar shows for the highlighted good,
    # the same field `Scene::ItemMenu`'s description banner already reads.
    def description(id)
      it = @db.item[id]
      it ? it.description.to_s : ''
    end

    # Whether item `id` is equipment (weapon/shield/armour/helmet/accessory
    # -- database type 1..5, `Actor::ITEM_WEAPON`..`Party::ITEM_ACCESSORY`)
    # rather than a consumable/switch/special good. Drives the shop screen's
    # own mystery party-window band (`Scene::Map#draw_shop_party`) -- see its
    # doc comment and the cycle #145 docs/TODO.md entry.
    def equip?(id)
      it = @db.item[id]
      it && (Actor::ITEM_WEAPON..Party::ITEM_ACCESSORY).cover?(it.type)
    end

    # Half the database price — what a sale returns (RPG2000 rounds down).
    def sell_price(id); price(id) / 2; end

    # Whether item `id` can be sold: the party owns at least one and it has a
    # non-zero price (RPG2000 marks price-0 / key items as unsellable).
    def sellable?(id); price(id) > 0 && @party.item_count(id) > 0; end

    # Every item the party holds, id-ordered, for the sell list -- list
    # membership and sellability are two different questions: a price-0 (key)
    # item a player holds is assumed to still show up in the Sell list (just
    # refusing the sale, via the same #sellable? this class's own #max_sell
    # already, correctly, uses for the "can it actually be sold" question
    # that #open_shop_quantity gates Decision on) rather than being dropped
    # from the list outright.
    #
    # CONFIRMED against genuine RPG_RT.exe under wine (cycle #175), closing
    # out cycles #173/#174's own inconclusive attempts at the same question
    # (each blocked on an unrelated wine-methodology issue, not this claim
    # itself -- see git history for their own detail, since both are now
    # resolved and superseded rather than still open). This cycle repeated
    # #174's exact setup (Nepheshel's item-shop NPC, `Map0016.lmu` event 4,
    # item 17 "天使の翼" at price 0 added to the party's bag) after finding
    # and working around #174's real blocker: its wine probe approached event
    # 4 from the south, standing on (14,11) facing up, which a fresh
    # dump of the event's own command list (`Map0016.lmu` event 4 page 1)
    # shows is simply the wrong side -- the action-key trigger only fires
    # facing it from the west, at (13,10) facing right (confirmed by
    # contrast: identical setup, south side silent across 6 boots, west side
    # fired the NPC's greeting on the very first try every time it was
    # retried). A second, independent hazard surfaced along the way and was
    # also worked around: `scripts/gen-rpg2k-save.rb`'s own "keeps the old
    # map event states" warning is not just about the *foreground* event
    # (chunk 113, `--clear-scene`'s job) -- chunk 111 (`SAVE_MAP_EVENT` field
    # 11) independently carries a per-event-id position snapshot from
    # whichever map the save was captured on, and a cross-map move leaves it
    # in place; since Map0012 (the save's original map) and Map0016 both
    # happen to number their events 1-4, Map0012's own event 4 position
    # (19,24) silently overrode Map0016's authored (14,10) for event 4 until
    # that array was cleared by hand. With both worked around, walking the
    # party up to event 4 from the west and running Buy/Sell showed the Sell
    # list with both held items -- "薬草 : 5" (the ordinary, price>0 item
    # already in the save) and "天使の翼 : 1" (the added price-0 item) --
    # listed side by side, confirming a price-0 item the party holds does
    # appear in the Sell list on genuine RPG_RT.exe, exactly as this method
    # already assumed.
    def sellable_items
      @party.items.keys.sort
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

  # Which BGM (if any) a map auto-plays the instant the party arrives on it --
  # the initial map and every Transfer Player alike.
  #
  # Each map-tree node (RPG_RT.lmt `map_properties` field 11 `bgm_type`, 12
  # `bgm`) is the same tri-state shape as Backdrop's `backdrop_type` above
  # (liblcf's `BGMType` enum, shared across both fields), but the middle value
  # means something different for music than it does for a backdrop -- there
  # is no "terrain" concept for BGM, so it means "no music" instead:
  #
  #   0 親マップと同じ  inherit whatever the parent map resolves to
  #   1 指定なし        none -- leave whatever is already playing alone
  #   2 指定する        the map's own `bgm` chunk, every time this map loads
  #
  # Ported from a reference implementation, NOT independently confirmed
  # against genuine RPG_RT under wine: it
  # walks `music_type == 0` nodes up to their parent exactly like
  # `Backdrop.name_for`/`MapAccess` do, then -- once landed on a non-inheriting
  # node -- only actually plays when that node's own `music.name` is non-empty
  # *and* its type is not 1 (`if (current_info->music_type == 1) { return; }`,
  # a no-op that leaves whatever is currently playing alone rather than
  # silencing it); called unconditionally from a reference implementation's
  # own player-move handling right
  # after every map setup, i.e. the initial map and every Transfer
  # Player. A walk that runs off the root (or loops) resolves to nothing, the
  # same "give up and change nothing" outcome as an unset/type-1 node.
  module MapBgm
    TYPE_PARENT = 0
    TYPE_NONE   = 1
    TYPE_SPECIFIC = 2

    # The BGM chunk (responding to `file`/`volume`/`pitch`) to auto-play on
    # `map_id`, or nil when the resolved node has no music configured or is
    # explicitly type 1 (leave the current track alone). `properties` is the
    # map tree's map_properties table, same shape `Backdrop.name_for` takes.
    def self.chunk_for(map_id, properties)
      seen = {}
      id = map_id.to_i
      while id > 0 && !seen[id]
        seen[id] = true
        row = properties ? properties[id] : nil
        return nil unless row
        type = int_field(row, :bgm_type)
        if type == TYPE_PARENT
          id = int_field(row, :parent_map_id)
        else
          bgm = row.respond_to?(:bgm) ? row.bgm : nil
          name = bgm && bgm.respond_to?(:file) ? bgm.file.to_s : ''
          return (type == TYPE_SPECIFIC && !name.empty?) ? bgm : nil
        end
      end
      nil
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
  # walking "same as parent" nodes up until one pins Allow/Forbid, the same
  # tree-walk `Backdrop.name_for` above uses; a walk that runs off the root
  # (or loops) defaults to Allow, the schema's own default for an unset
  # field (`mruby-lcf/mrblib/schema.rb`'s `map_properties` fields 31/32/33
  # all default to 1 = Allow). This sits *underneath* the
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
      # A database shrink can leave a troop member naming a deleted individual
      # enemy id (chunk 14) -- shown as "?" in the editor, docs/TODO.md's
      # runtime error catalog, distinct from the enemy-*group* (troop) id case
      # `Game::Party#db_enemy_group`/Enemy Encounter already reports. Degrading
      # to a blank/1-HP model below is unchanged (by design, matching real
      # RPG_RT's own tolerance); only the gap is now visible. `respond_to?`
      # guarded the same way `db_item`/`db_enemy_group` reach into `@db`, so a
      # bare test fixture with no `enemy` table at all stays silent -- this is
      # only for a genuine dangling id in a real database.
      if row.nil? && id && id > 0 && db.respond_to?(:enemy)
        $stderr.puts "[RPG2k] Enemy: enemy id #{id} not found in the " \
                     'database, degrading to a blank placeholder'
      end
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
      # This member's own randomized starting phase for the `levitate` bob's
      # sine argument (0..63, matching a reference implementation's `frame_counter` seed --
      # see `#flying_phase`'s own attr comment below). Rolled per member by
      # `Troop#initialize`, not here, since only the troop has an RNG to
      # hand; left at the schema default of 0 for a bare fixture with none.
      @flying_phase = 0
      # Critical-hit chance as a whole percent (0 = never), from the enemy's
      # critical_hit flag and its 1-in-`critical_hit_chance` rate, truncated
      # the same way -- and for the same reason -- as Actor#crit_chance. An
      # enemy has no equipment, so unlike an actor's this is the whole of it.
      @crit_chance = if row && row.respond_to?(:critical_hit) && row.critical_hit
                       n = row.respond_to?(:critical_hit_chance) ? row.critical_hit_chance : 0
                       n && n > 0 ? (100.0 / n).to_i : 0
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
      # 70% base hit rate rather than the usual 90% (a reference implementation's GetHitChance).
      @miss = row && row.respond_to?(:miss) ? (row.miss ? true : false) : false
      # The "airborne" flag (field 28, `levitate`): purely a battle-screen
      # display effect (per a reference implementation's flying-offset logic) with no
      # accuracy/hit-related effect of any kind -- and, per that same source,
      # RPG2000 never renders it at all ("2k does not support flying, albeit
      # mentioned in the help file"), only RPG2003 does, gated by
      # `Scene::Map#flying_offset` the same way. Read here regardless of
      # edition, same as every other schema field this class exposes.
      @levitate = row && row.respond_to?(:levitate) ? (row.levitate ? true : false) : false
      # The "Appear Transparent" flag (field 10): the battle screen renders this
      # enemy's sprite at reduced opacity for the whole fight -- purely cosmetic,
      # like `levitate`, with no accuracy/evasion effect of any kind. Ported
      # from a reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: it
      # treats this as a bare passthrough, and
      # computes `alpha = 160 *
      # alpha / 255` whenever it is set -- 160/255 (~63%) of whatever opacity the
      # sprite would otherwise have (255 outside of the death-fade/explode
      # animations this codebase does not yet model).
      @transparent = row && row.respond_to?(:transparent) ? (row.transparent ? true : false) : false
      # The battle-graphic hue shift (field 3, degrees 0..359): lets a game
      # reuse one Monster/<name> bitmap for several palette-swapped variants
      # (a red slime and a blue slime sharing "Slime.png") instead of shipping
      # a separate file per colour. Ported from a reference implementation, NOT
      # independently confirmed against genuine RPG_RT under wine:
      # it treats this as a bare
      # passthrough, and
      # rotates the loaded bitmap through
      # a hue-change blit whenever it is nonzero, before the sprite is
      # ever shown -- purely a render-time recolour with no stat effect,
      # unlike every field above it.
      @battler_hue = row && row.respond_to?(:battler_hue) ? (row.battler_hue || 0) : 0
      # The 行動パターン table (field 42), decoded now since `row` isn't kept. An
      # enemy whose row lists none falls back to plain attacking.
      @actions = []
      list = row && row.respond_to?(:actions) ? row.actions : nil
      list.each { |_i, a| @actions << EnemyAction.new(a) } if list
    end

    # This enemy's action pattern (Game::EnemyAction list, possibly empty).
    attr_reader :actions

    attr_reader :crit_chance, :attribute_ranks, :state_ranks

    # The "airborne" flag (field 28) -- see the comment in #initialize for what
    # it does and does not affect.
    attr_reader :levitate

    # This member's own randomized starting phase (0..63) for `Scene::Battle
    # #flying_offset`'s sine bob. Ported from a reference implementation, NOT
    # independently confirmed against genuine RPG_RT under wine, which does
    # not bob every levitating troop
    # member in lockstep from one shared clock: it
    # reads a *per-battler* frame counter,
    # which
    # is seeded
    # independently per battler at battle start -- a random value in 0..63
    # -- before that counter
    # increments in lockstep for the rest of the
    # fight for every battler. So each
    # levitating member bobs on its own fixed, randomized phase relative to
    # the others, not in unison. Writable so `Troop#initialize` can roll it.
    attr_accessor :flying_phase

    # The "Appear Transparent" flag (field 10) -- see the comment in #initialize.
    attr_reader :transparent

    # The battle-graphic hue shift (field 3) -- see the comment in #initialize.
    attr_reader :battler_hue

    # Base to-hit percentage for this enemy's normal attack (70 when the "miss"
    # flag is set, otherwise 90); fed into the battle's to-hit roll.
    def attack_hit_rate; @miss ? 70 : 90; end

    def dead?; @hp <= 0; end

    # Re-seeds this troop member's own reward fields from `into` (a fresh
    # `Enemy` for whatever database row a mid-fight Transform just repointed
    # the parallel `Game::Battle::Combatant` at) -- what `RPG2k::Scene::
    # Battle#sync_troop_member_rewards` calls once it notices a combatant's
    # battler no longer matches the sprite it was drawn from. Only the fields
    # `#total_exp`/`#total_gold`/`#drops` actually read; everything else this
    # class carries (position, `levitate`, `hidden`) is transform-invariant --
    # a Transform keeps its place and never revives a hidden member.
    def reseed_rewards(into)
      @exp = into.exp
      @gold = into.gold
      @drop_id = into.drop_id
      @drop_prob = into.drop_prob
    end
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

    def initialize(db, id, rng = nil)
      row = db.enemy_group[id]
      @id = id
      @name = row ? row.name.to_s : ''
      @members = []
      # Array2D#each yields (id, entry); a plain Hash test double does the same.
      row.members.each { |_, m| @members << member(db, m) } if row && row.members
      @pages = row && row.respond_to?(:pages) ? row.pages : nil
      apply_appear_randomly(row, rng) if row && rng
      # Each levitating member's own `flying_phase` (see Enemy#flying_phase's
      # own citation): rolled once here, in member order, the same way
      # a reference implementation's own battle-reset seeds every battler's
      # frame counter
      # independently at battle start. RPG_RT actually rolls this for every
      # battler on both sides, levitating or not, party actor included --
      # deliberately narrowed here to only the members whose `flying_phase`
      # can ever be observed at all (a non-levitating member's own bob is
      # always 0, and only a Troop's own `Enemy` members bob in the first
      # place), so as not to shift the shared `rng`'s draw count for every
      # ordinary fight the way a full, unconditional port would.
      @members.each { |m| m.flying_phase = rng.random(64) if m.levitate } if rng
    end

    # EXP / gold / drops are only earned from members that actually fell in
    # this fight -- a member still flagged `hidden` at victory time (never
    # revealed by a Show Hidden Monster page, sent running by a page's own
    # Force Flee, sent running by its own basic Escape action, or blown up by
    # its own basic Autodestruct -- see `Game::Battle#enemy_autodestruct`)
    # contributes none of the three, even though a fight can end in victory
    # while such a member is technically still at full HP:
    # `Game::Battle#enemy_active?` (`mruby-rpg2k/mrblib/game.rb`) already
    # treats hidden the same as dead for win/loss purposes (`out_of_play?`),
    # so `enemy_active?(@enemies)` goes false -- and victory fires -- the
    # instant every *visible* member is down, with no requirement that a still-hidden
    # one ever engaged at all. Ported from a reference implementation, NOT
    # independently confirmed against genuine RPG_RT under wine:
    # its reward-generation routines each loop, skipping any member whose
    # HP is already zero, before
    # summing/rolling that member at all -- a hidden member's own
    # HP is never touched by never fighting, a Force-Fled/Escaped member's
    # isn't either (hidden alone, never killed), and neither is a
    # self-destructed one's (that routine only ever
    # hides its own caster, never touching its HP -- see
    # `enemy_autodestruct`'s own comment), so all three read as not dead and
    # are skipped by all three reward routines. This class
    # never lets a member's HP move at all -- the actual combat plays out on
    # parallel `Combatant` structs in `Game::Battle`, not on `Troop`'s own
    # `Enemy` objects -- so `hidden` (kept live by
    # `Scene::Map#reveal_battle_monster`/`#remove_fled_monster` for a battle
    # page's own commands, and by `Scene::Map#refresh_battle_sprites` for
    # anything a combatant does to itself mid-fight) is the one signal
    # available here, and by the "hidden ~ not dead" equivalence above it is
    # also the *correct* one: a non-hidden member reaching this call is
    # always the dead case.
    def total_exp;  live_members.reduce(0) { |s, e| s + e.exp } end
    def total_gold; live_members.reduce(0) { |s, e| s + e.gold } end

    # The item ids the troop yields on victory: each member carrying a drop item
    # rolls its `drop_prob` percentage against `rng` (0..99 < prob, a reference
    # implementation's percent-chance roll), so a 100% drop is certain, a 0% never lands, and the
    # same item can drop from several members. Returns the ids in member order.
    def drops(rng)
      live_members.each_with_object([]) do |e, out|
        next unless e.drop_id && e.drop_id > 0
        out << e.drop_id if rng.random(100) < e.drop_prob
      end
    end

    private

    # Members that actually took part and fell -- see the comment on
    # #total_exp/#total_gold/#drops above for why `hidden` is the right (and
    # only available) proxy for "dead" at this call site.
    def live_members; @members.reject(&:hidden) end

    def member(db, m)
      Enemy.new(db, m.enemy_id, m.x, m.y, m.invisible)
    end

    # ランダムに出現 (Appear Randomly, chunk 15 field 6): once per battle, roll
    # each initially-visible member for a 40% chance to start hidden instead,
    # stopping the instant only one member is left visible -- a fight always
    # needs at least one visible foe to open against. Ports a reference
    # implementation's battle-reset logic (NOT independently confirmed against
    # genuine RPG_RT under wine): a
    # per-member 40% chance roll, an already-hidden member
    # (its own individual chunk-15-member field 4, `invisible`) skipped
    # rather than re-rolled or counted against the "one must stay visible"
    # floor, and the roll happening once, in member order, not a
    # roll-then-reveal-one-back pass. `rng` is optional (nil skips the whole
    # pass) since most callers -- the seeded harness fixtures included --
    # have no RNG to hand in and expect a `Troop` to build deterministically.
    def apply_appear_randomly(row, rng)
      return unless row.respond_to?(:appear_randomly) && row.appear_randomly
      non_hidden = @members.count { |m| !m.hidden }
      @members.each do |m|
        break if non_hidden <= 1
        next if m.hidden
        next unless rng.random(100) < 40
        m.hidden = true
        non_hidden -= 1
      end
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

    # Whether `sk`, cast by `caster` against its own `troop`, could possibly
    # help anyone -- reuses Game::Party's own #skill_helps_troop? formula so an
    # enemy's own AI reads the exact same skill-effectiveness rules a field
    # cast's greyed-out-if-a-no-op check does. Defaults to "always worth
    # trying" without a party to ask, matching every other tolerant accessor
    # here.
    def skill_helps_troop?(sk, caster, troop)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return true unless party && party.respond_to?(:skill_helps_troop?)
      party.skill_helps_troop?(sk, caster, troop)
    end

    # Whether `sk` is even a legal in-battle action to name in an enemy's own
    # action pattern -- reuses Game::Party's own #battle_skill? so an enemy's
    # AI is gated the exact same way a field/battle actor cast is. Ported
    # from a reference implementation, NOT independently confirmed against genuine
    # RPG_RT under wine: it
    # rejects a skill action outright when
    # it is not usable at all -- before the action's own
    # weight is ever computed -- and that usability check,
    # which is reached in
    # battle, is unconditionally false for an Escape/Teleport-type skill and
    # gated on the skill's own `occasion_battle` flag for a Switch-type one.
    # Defaults to "usable" without a party to ask, matching every other
    # tolerant accessor here.
    def skill_battle_usable?(sk)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return true unless party && party.respond_to?(:battle_skill?)
      party.battle_skill?(sk)
    end

    # Whether `caster` (a live Game::Actor, not a battle Combatant snapshot —
    # #choose_auto_battle_command reaches through a Combatant's own `#actor`
    # to get one) can actually cast skill `sid` right now: reuses
    # Game::Party's own #can_cast? (affordability, silence and weapon-
    # Attribute equip-gating) so a Forced-AI actor's own skill eligibility
    # matches the ordinary field/menu gate exactly, mirroring a reference
    # implementation's own skill-usability check, the same function its
    # auto-battle rank calculation gates on. Defaults to "eligible" without a party to ask, matching every
    # other tolerant accessor here.
    def skill_ready?(caster, sid)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return true unless party && party.respond_to?(:can_cast?)
      party.can_cast?(caster, sid)
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
    # over (a reference implementation's average-level calculation). 0 with no party.
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

    # A state's `hp_change_type` / `sp_change_type` (RPG2003 fields 45/46):
    # which way its slip/regen amount moves the stat once its interval or
    # threshold lands. 0 (the schema default, and the only meaning a
    # pre-2003 database's absent field can carry) is **lose** -- every
    # existing "poison" state in either test bed relies on this default --
    # 1 is **gain** (a "regen" state that heals instead of drains), 2 is
    # **nothing** (neither, despite a possibly-nonzero configured amount).
    # Matches liblcf's own generated `lcf::rpg::State::ChangeType` enum
    # exactly (verified against its generated `state.h`), not guessed at.
    CHANGE_TYPE_LOSE    = 0
    CHANGE_TYPE_GAIN    = 1
    CHANGE_TYPE_NOTHING = 2

    def self.row(id, table)
      return nil if id.nil? || id <= 0 || table.nil?
      table[id]
    rescue StandardError
      nil
    end

    # The one state a battler *shows*, from the ids it carries: death outranks
    # everything, otherwise the highest `priority` wins, ties going to the later
    # id. A port of a reference implementation's own significant-state
    # selection, whose `>=` comparison
    # is what makes the tie go to the later one. nil when the battler is clear.
    def self.significant(ids, table)
      return nil if ids.nil? || ids.empty?
      best = nil
      best_priority = -1
      # Ascending id order, because the tie rule depends on it: the reference
      # implementation walks the
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

    # `ids` after the crowding-out rule a reference implementation's engine
    # implements: any
    # state 10+ priority below
    # the *significant* one it carries is dropped. Ported from a reference
    # implementation's own source rather than
    # assumed, but NOT independently confirmed against genuine RPG_RT under
    # wine: it computes the significant
    # state *after* inserting the new id, then clears
    # every state whose own `priority <= sig_state->priority - 10`. Death is
    # not exempt from this at all -- when carried, it *is* the significant
    # state (`GetSignificantState` returns Death's own row the instant it
    # sees it, before ever comparing priorities), so the threshold becomes
    # *Death's own configured priority* minus 10, which is why a lethal hit
    # clears a lower-priority ailment (Poison, Blind, ...) immediately: a
    # real database's Death priority is conventionally set high (RPG2000's
    # own default is 100) specifically so this rule wipes weaker states the
    # instant it lands, while Death itself always survives its own threshold
    # trivially (`p <= p - 10` is never true). #significant already returns
    # DEATH_ID the moment it is present, so reusing it here for `top` gets
    # this right for free -- no id needs to be singled out or exempted.
    # `ids` with one or fewer entries has nothing to compare, and comes back
    # unchanged.
    #
    # `keep:` is RPG2003 cursed armor's own exemption from this same pass --
    # a reference implementation's own state-add loop reads
    # `if (priority <= sig->priority - 10 &&
    # !ps.Has(i + 1)) { states[i] = 0; }`, `ps` being the caller's own
    # permanent-states set (from its own actor-side accessor): a state a worn cursed item is actively forcing on
    # survives the crowding-out pass even when it sits well below the
    # landing state's priority. Without it, a lethal hit (Death landing at
    # its own conventionally-high priority) stripped a low-priority cursed
    # state from `@states` outright -- and since every cure path can only
    # ever *keep* an id already present, never re-add a missing one, the
    # state stayed gone until the player physically unequipped and
    # re-equipped the cursed item, instead of the state persisting (as worn)
    # the whole time the way real RPG_RT's own exemption guarantees.
    def self.prune(ids, table, keep: [])
      return ids if ids.nil? || ids.size <= 1
      sig = significant(ids, table)
      return ids if sig.nil?
      top = priority_of(sig, table)
      ids.select { |id| keep.include?(id) || priority_of(id, table) > top - PRUNE_GAP }
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

    # RPG2003's per-state battle-sprite pose: which pose (0-indexed, the same
    # scheme `Scene::Battle::ACTOR_*_POSE` constants use) a `db.battleranimations`
    # entry should show while this state is the significant one on a living
    # party member. Ported from a reference implementation's own source, NOT
    # independently confirmed against genuine RPG_RT under wine:
    # it
    # reads the battler animation id field directly as
    # the pose to show (its own `+1`/`101->7` dance is that logic
    # translating into its own runtime `AnimationState` enum, which carries an
    # extra `Null` head element ahead of `Idle` that this schema's own 0-based
    # `battler_animation_id` field never had to begin with -- liblcf's own
    # schema default for this field, field 39 on the `situation` chunk, is
    # already `6`, this codebase's own `ACTOR_BAD_STATUS_POSE` index, not the
    # C++ side's raw pre-translation sentinel `100`). DEFAULT_ANIMATION_POSE
    # is that same fallback for a fixture/older-save row that omits the field
    # outright.
    DEFAULT_ANIMATION_POSE = 6
    def self.animation_pose(id, table)
      r = row(id, table)
      p = r && r.respond_to?(:battler_animation_id) ? r.battler_animation_id : nil
      p.nil? ? DEFAULT_ANIMATION_POSE : p
    end

    # RPG_RT's sentence for a state landing on `battler_name`. The database
    # stores the *predicate* only ("は毒にかかった！"), which RPG2000 prints
    # straight after the battler's name — a reference implementation's
    # state-message formatting, whose placeholder form is RPG2003-only. Actors and enemies get different
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

    # ... and the per-turn reminder a battler still carrying (or just having
    # shaken off) a state gets at the very start of its own turn, before its
    # action -- distinct from #inflict_message, which fires only the instant
    # a state first lands. One wording for both sides, like recovery.
    def self.affected_message(id, table, battler_name)
      message(battler_name, field(id, table, :message_affected))
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
    # `%S`-style placeholders a reference implementation supports are an RPG2003 / 2k3E feature, so
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
      # a reference implementation's damaged-message formatting; the
      # Western-encoding branch uses a plain
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

      # 「会心の一撃！！」 / 「痛恨の一撃！！」 — the extra line RPG_RT inserts
      # between the start line and the damage line on a critical hit
      # (`Scene_Battle_Rpg2k::ProcessBattleActionCritical`, which runs before
      # `ProcessBattleActionApply`). No battler name goes in front of it: the
      # 2k branch of a reference implementation's own critical-hit-message
      # formatting returns the bare term.
      #
      # ADR 0036 left this term unwired because which side keys it was
      # ambiguous from the test-bed data alone. A reference implementation's
      # own source was read as settling it the other way (keyed on the
      # target, the same way `actor_damaged`/`enemy_damaged` are) but that
      # reading was never checked against genuine RPG_RT and turned out
      # backwards: confirmed under wine (2026-09-05) by swapping the
      # database's own `actor_critical`/`enemy_critical` terms for distinct
      # ASCII markers -- an ally's own critical hit against an enemy showed
      # the `actor_critical` marker, and an enemy's critical hit against
      # that same ally showed the `enemy_critical` marker. That is keyed on
      # the **attacker's** side, the opposite of `actor_damaged`/
      # `enemy_damaged` (which genuinely are target-keyed, unaffected by
      # this fix) despite the naming symmetry suggesting otherwise.
      def self.critical(terms, attacker_ally)
        term(terms, attacker_ally ? :actor_critical : :enemy_critical)
      end

      # A miss. RPG2000 words it from the target's side ("...は身をかわした！"),
      # which is why one term serves both sides.
      def self.dodge(terms, target_name)
        action(terms, target_name, :dodge)
      end

      # A skill announces itself with its **own** two sentences rather than with
      # a term, which is why a skill has a voice and a plain attack does not.
      # `using_message1` follows the caster's name the way every other predicate
      # does; `using_message2` stands alone as a second line (a reference
      # implementation's second-start-message formatting returns the field
      # with no name in front),
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
      # borrows the dodge line (a reference implementation's skill-failure-message
      # formatting). Worded from
      # the target's side, like the dodge it can become.
      FAILURE_TERMS = [:skill_failure_a, :skill_failure_b, :skill_failure_c,
                       :dodge].freeze

      # An item has no sentence of its own — it borrows the `use_item` term, and
      # is the one line RPG2000 builds from *two* names: 「リトはポーションを使っ
      # た！」 is the caster, は, the item, and the term. `item.using_message`
      # (schema field 51) is an int, not a string — but it is not dead data: a
      # skill-casting item (special/use_skill) reads as 0 or nonzero, gating
      # whether *this* generic line or the invoked skill's own sentence(s)
      # opens the log entry — see Scene::Battle#skill_start_lines.
      def self.item_start(terms, caster_name, item_name)
        t = term(terms, :use_item)
        t && "#{caster_name}#{ALLY_PARTICLE.strip}#{item_name}#{t}"
      end

      # 「リトのＨＰが 30 回復した！」 — what a potion or a cure spell restored.
      # `points` is the 用語 name of the pool (`hp` / `mp`, which Nepheshel writes
      # full-width as ＨＰ / ＭＰ and mtf-meido-action as HP / MP), and the shape
      # is a reference implementation's HP/SP-recovered-message formatting:
      # name, の, pool, "が ", the amount,
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

      # 「リトの攻撃力が 10 上がった！」 / 「…下がった！」 — what an ATK/DEF/SPI
      # (mind)/AGI-affecting skill (`skill.affect_attack` and friends, applied
      # by `Game::Battle#apply_stat_mods`) did to a stat. `value` is the signed
      # delta actually applied (already clamped against RPG_RT's own -(base/2)
      # .. +base band); `points` is the 用語 name of the stat itself (`:attack`
      # / `:defense` / `:mind` / `:agility`) rather than a pool. Same の…が…
      # shape as #recovered above, but which of the two predicates
      # (`parameter_increase` / `parameter_decrease`) speaks is `value`'s own
      # sign rather than fixed -- a reference implementation's
      # parameter-change-message formatting.
      def self.parameter_change(terms, target_name, value, points)
        return nil if value.nil? || value == 0
        t = term(terms, value > 0 ? :parameter_increase : :parameter_decrease)
        pool = term(terms, points)
        return nil unless t && pool
        "#{target_name}の#{pool}が #{value.abs} #{t}"
      end

      # 「リトは火に対する耐性が 上がった！」 — an attribute-defence-shift skill
      # (`skill.affect_attr_defence`, applied by `Game::Battle#apply_attr_shift`)
      # moving a resistance rank. `positive` is the shift's own direction
      # (`Game::Party#skill_attr_shift`'s `attr_shift`, +1 raises / -1 lowers,
      # the same for every attribute id one skill cast touches) -- unlike the
      # parameter version above, a reference implementation's
      # attribute-shift-message formatting never
      # shows a magnitude here, only which way the rank moved, so there is no
      # `value` argument to speak of.
      def self.attribute_shift(terms, target_name, positive, attr_name)
        return nil if attr_name.nil? || attr_name.to_s.empty?
        t = term(terms, positive ? :resistance_increase : :resistance_decrease)
        return nil unless t
        "#{target_name}は#{attr_name} #{t}"
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
      [drain(r, steps, :hp_change_map_steps, :hp_change_map_val, :hp_change_type),
       drain(r, steps, :sp_change_map_steps, :sp_change_map_val, :sp_change_type)]
    end

    # The signed HP/SP delta this landing applies -- negative for the default
    # **lose** type (RPG2000's only meaning for this field), positive for an
    # explicit **gain**, 0 for **nothing** or for an interval this step does
    # not land on (see CHANGE_TYPE_LOSE/GAIN/NOTHING above).
    def self.drain(row, steps, steps_field, val_field, type_field)
      interval = int_field(row, steps_field)
      amount = int_field(row, val_field)
      return 0 if interval <= 0 || amount <= 0 || !(steps % interval).zero?
      case int_field(row, type_field)
      when CHANGE_TYPE_GAIN then amount
      when CHANGE_TYPE_NOTHING then 0
      else -amount
      end
    end

    def self.int_field(row, name)
      v = row.respond_to?(name) ? row.send(name) : nil
      v.nil? ? 0 : v
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

    # liblcf's own `SaveVehicleLocation.vehicle` ordinal (generator/csv/
    # fields.csv, field 101) -- the value #to_lsd's own vehicle-writing loop
    # stamps into that field, one per vehicle chunk (105/106/107).
    TYPE_ID = { boat: 1, ship: 2, airship: 3 }.freeze

    # RPG_RT's own built-in vehicle move speed, confirmed against a genuine
    # kk1.12 save under wine (move_speed 4/4/5 on the boat/ship/airship
    # location records, present even though the party never boarded any of
    # them that session). Nothing in this codebase tracks a live per-vehicle
    # speed to source this from instead -- #to_lsd's own vehicle-writing
    # loop uses it as a straight constant.
    DEFAULT_MOVE_SPEED = { boat: 4, ship: 4, airship: 5 }.freeze

    attr_accessor :map_id, :x, :y, :direction, :charset_name, :charset_index
    attr_reader :type

    def initialize(type, map_id = 0, x = 0, y = 0, direction = 2)
      @type = type
      @map_id = map_id || 0
      @x = x || 0
      @y = y || 0
      @direction = direction || 2
      # Empty/0 is the "uncustomized" sentinel Scene::Map's own
      # #vehicle_charset/#vehicle_charset_index (mrblib/scene/map.rb) test
      # for, falling back to the database's own System boat/ship/airship
      # name/index -- do not seed a non-empty placeholder here, or that
      # fallback silently stops firing.
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
      # liblcf's own 0..3 (up/right/down/left) convention on the wire --
      # #numpad_direction is the same conversion Change Event Location's own
      # facing sub-parameter and the database-side event-page facing field
      # already go through (EventGraphic::LCF_DIR_TO_NUMPAD).
      @direction = EventGraphic.numpad_direction(m.direction)
      @charset_name = m.charset_name || ''
      @charset_index = m.charset_index || 0
    end
  end

  # One of RPG_RT's countdown timers, driven by the Timer Operation command
  # (10230). RPG2000 has a single one; RPG2003 adds a second, selected by that
  # command's sixth parameter. Ported from a reference implementation's timer
  # handling, not independently confirmed against genuine RPG_RT under wine,
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

    # Timer Operation, "set": load the timer with `seconds` (see the note
    # above about the extra 59 frames). Not clamped -- ported from a
    # reference implementation's source, NOT independently confirmed against
    # genuine RPG_RT under wine: its timer-set handling seeds the frame count
    # with no upper bound at all, and its own timer-operation command
    # handling passes its
    # `ValueOrVariable`-sourced seconds straight through with no clamp
    # either -- so a Control Variables value above 99:59 (5999 s, an
    # arbitrary, player-reachable overflow) is believed to reach the frame
    # counter uncapped, per this ported behavior. ~~a reference
    # implementation's own timer-drawing routine
    # indexes its digit strip at an unbounded
    # `32 + 8 * (mins / 10)` with no ceiling either, so real RPG_RT's own
    # on-screen minutes display genuinely garbles past 99 rather than
    # capping cleanly -- this port's own pixel-digit renderer
    # (`Scene::Map#draw_timer_digits`, `mruby-rpg2k/mrblib/scene/map.rb`)
    # already indexes its own windowskin digit strip the identical
    # unbounded way, so it reproduces the same garbled-past-99 quirk for
    # free once this class stops clamping first.~~ Correction: confirmed
    # against a genuine RPG_RT.exe, not just its source, this claim was
    # wrong -- RPG_RT does not garble past 99 the same way a naive
    # unbounded single-glyph index would. See `Scene::Map#draw_timer_digits`
    # (`mruby-rpg2k/mrblib/scene/map.rb`) for the actual, empirically
    # characterized overflow behavior.
    def set(seconds)
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

    # liblcf's own declared default for chunk 108 field 80 (battle_commands):
    # seven "defer to class/database" slots -- see #to_lsd's own citation for
    # why this is written unconditionally (not merely when
    # Actor#battle_commands_changed?).
    BATTLE_COMMANDS_DEFAULT = [-1, -1, -1, -1, -1, -1, -1].freeze

    attr_reader :party, :switches, :variables, :message_config, :screen, :weather
    attr_accessor :map, :x, :y, :direction
    attr_reader :map_id
    # The battle background the runtime is *currently* carrying (SAVE_SYSTEM
    # field 125, liblcf's own "background"), or nil for "nothing loaded one --
    # resolve it from the map tree instead" (`Game::Backdrop.name_for`, which
    # is what `Scene::Battle#encounter_backdrop` falls back to).
    #
    # Confirmed against genuine RPG_RT.exe under wine (cycle #245): the
    # backdrop a fight draws is this stored value, NOT a fresh map-tree walk
    # at battle start. Nepheshel's map 2 inherits its parent map 9's
    # `backdrop_type == 2` / `backdrop_file == "black"`, yet a save whose
    # field 125 was hand-set to "light" (an unrelated Backdrop/light.png)
    # dropped straight into the map-2 slime fight drawing *light*, and one
    # with the field absent drew a flat black screen -- so loading a save
    # neither recomputes nor validates the field. Absent therefore has to
    # read as the empty string here (RPG_RT's own field default -> the flat
    # black field), not as "unknown", or a genuine save's own choice would be
    # silently overridden.
    #
    # Cleared by #map_id= so a Transfer Player leaves the stale value behind
    # and the next fight resolves the new map's own backdrop: RPG_RT's field
    # is written by its map setup (every genuine save carries the value its
    # own map resolves to), and where exactly that write happens -- arrival
    # only, or every step over a terrain whose own `background_name` differs
    # -- could not be settled here, because Nepheshel has no `backdrop_type
    # == 1` (per-terrain) map at all. See docs/TODO.md.
    attr_accessor :battle_background

    # Changing map drops the carried battle background (see above): the value
    # only ever described the map it was resolved on.
    def map_id=(id)
      @battle_background = nil if id != @map_id
      @map_id = id
    end
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
    # `#save_access`. Both default **on** (cycle #162, confirmed against
    # genuine RPG_RT.exe -- see `#to_lsd`'s own comment below), the same as
    # `#save_access`/`#menu_access`. Persisted in the save. Read by
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
    # The BGM #play_vehicle_bgm/#play_battle_bgm (Scene::Map) stash right
    # before boarding a vehicle or a fight opens, so #restore_pre_vehicle_bgm/
    # #restore_pre_battle_bgm can bring it back on disembark/after the fight --
    # nil the rest of the time (no ride or fight in progress). Confirmed
    # against a genuine kk1.12 save under wine: chunk 101 (SAVE_SYSTEM) fields
    # 76/77 (liblcf's own before_vehicle_music/before_battle_music) were both
    # present, as a BGM struct whose own `file` read the literal "(OFF)" --
    # RPG_RT's own placeholder for "nothing to restore", not either field
    # being absent -- confirmed in a session that never boarded a vehicle or
    # fought a battle, i.e. both nil here. Previously tracked only as a
    # transient Scene::Map instance variable, invisible to both save formats;
    # promoted onto Game::State so #to_h/#load_h and #to_lsd/.from_lsd can
    # round-trip it like #current_bgm above.
    attr_accessor :pre_vehicle_bgm, :pre_battle_bgm
    # The hero's own in-flight Flash Sprite (11320) or map-triggered battle-
    # animation flash, a `{ red:, green:, blue:, power:, frames:, total: }`
    # hash (see Scene::Map's own "Flash Sprite" section) or nil when nothing
    # is flashing -- previously tracked only as Scene::Map's own transient
    # `@player_flash`, invisible to both save formats, so a save taken mid-
    # flash and continued silently dropped it instead of resuming the fade.
    # Promoted onto Game::State so #to_h/#load_h and #to_lsd/.from_lsd can
    # round-trip it, wiring up chunk 104's own flash_red/_green/_blue/
    # _current_level/_time_left (liblcf's own generator/csv/fields.csv,
    # 0x51-0x55/81-85) -- see #to_lsd's own citation for exactly what is and
    # is not confirmed against genuine RPG_RT here.
    attr_accessor :player_flash
    # A live Set Move Route (11330) forced route targeting the player, a
    # `{ commands:, repeat:, skippable:, index:, frequency: }` hash (an array
    # of Game::MoveCommand for `commands`) or nil when the hero is walking
    # freely -- previously tracked only as Scene::Map's own transient
    # `@player_route`/`@player_char`, invisible to both save formats, so a
    # save taken mid-route and continued silently dropped it. `frequency` is
    # `@player_char`'s own live `move_frequency` (liblcf field 32); `index`
    # is the route's own cursor (field 43, the same field a map event's
    # custom route already uses via #map_event_route_index, here dedicated
    # to the hero instead). Promoted onto Game::State so #to_h/#load_h and
    # #to_lsd/.from_lsd can round-trip it -- see #to_lsd's own citation for
    # what is not independently confirmed (in particular, resuming this
    # restarts the route's own step-pacing timer from 0 rather than
    # wherever it was mid-count, the same category of imperfection already
    # accepted for #player_flash's own decay curve).
    attr_accessor :player_route
    # Whether a live #player_route is running in Through Mode (liblcf's own
    # `through`, field 51 -- "Walk Everywhere On"/"Off", 36/37): previously
    # Scene::Map's own transient `@player_through`, surviving between
    # routes (see that ivar's own citation there) but not a save. Nil/false
    # when not applicable.
    attr_accessor :player_through
    # Whether the current BGM has wrapped back to its start at least once — the
    # "BGM played once" conditional-branch test (12010 type 9). Cleared whenever
    # a new BGM starts; set by Scene::Map, which watches `RGSS::Audio.bgm_pos`
    # and treats a playback position that jumped backwards as a loop.
    attr_accessor :bgm_looped
    # Whether the current BGM has been faded/stopped since it last actually
    # started playing -- ported from a reference implementation's own
    # "music stopping" flag, set by Fade Out BGM/11520, NOT independently
    # confirmed against genuine RPG_RT under wine on its own. That
    # implementation's own BGM-play handling's "same
    # track: adjust volume in place, don't restart" shortcut is gated on
    # that flag -- so a Play BGM/Play Memorized BGM of the same
    # track right after a fade-out DOES restart it from the top, unlike an
    # ordinary same-name replay. Cleared unconditionally at the end of every
    # BGM-play call, restart or not, which
    # `#play_audio`'s `:bgm` branch and `#do_play_memorized_bgm` both mirror.
    # Round-trips through Save/Continue as liblcf's SaveSystem field 61 (see
    # `#to_lsd`/`.from_lsd`'s own field-61 comments and SAVE_SYSTEM in
    # schema.rb for the genuine-RPG_RT wine evidence this cycle gathered for
    # it) -- a save taken mid-fade and reloaded now correctly forces the next
    # same-name Play BGM to restart, matching real RPG_RT rather than
    # silently resetting to "not stopping" on every load.
    attr_accessor :bgm_stopping
    # Whether the party leader's map sprite is hidden, toggled by the Set
    # Transparent Flag / Change Player Visibility (11310) event command. Defaults
    # off (the hero is shown) and is persisted in the save.
    attr_accessor :player_transparent
    # Random-encounter step rate set by Change Encounter Rate (11740); nil until
    # a command overrides it (the map's own rate then applies).
    attr_accessor :encounter_rate
    # The wandering-monster accumulator Scene::Map's #check_random_encounter
    # builds up each step (ported from a reference implementation's own
    # per-step encounter-rate accumulator) —
    # persisted so a save mid-walk does not quietly reroll the chance of the
    # next few steps. The table index that reads it (that same
    # implementation's own last-encounter index) is deliberately *not*
    # persisted, matching that reference implementation (not independently
    # confirmed against genuine RPG_RT under wine):
    # it is a plain runtime counter, not part of the save.
    attr_accessor :encounter_total
    # How many tiles the party has walked. RPG2000 divides this into each
    # status condition's own step interval to decide when a field ailment slips
    # HP / SP (see Party#apply_map_step_damage), which is the only thing reading
    # it so far -- the encounter system that would share it is not built. It
    # persists in both the Marshal save and the `.lsd` (inventory chunk 109
    # field 42, see LCF::Schema::SAVE_INVENTORY), so a resumed real save
    # continues its count rather than restarting from 0.
    attr_accessor :steps
    # How many rounds the most recently finished battle ran for -- RPG2000's
    # "turns passed in latest battle" (inventory chunk 109 field 41, `turns`).
    # Nil until a battle has ever finished (matching the chunk's own
    # undefaulted read); `Scene::Map#finish_battle` sets it from
    # `Game::Battle#turn` (its live `@rounds` counter) right before the fought
    # `Battle` object is discarded, since nothing else keeps that count once
    # the fight ends. Persists in both the Marshal save and the `.lsd`, same
    # as `#steps`.
    attr_accessor :last_battle_turns
    # Running tallies RPG2000 keeps and exposes through the Control Variables
    # "Other" operand: how many times the game was saved, and how many battles
    # were fought / won / lost / escaped. All persist in the Marshal save; the
    # battle tallies (not `save_count`) also round-trip through the `.lsd`
    # inventory chunk (109 fields 32-35).
    attr_accessor :save_count, :battle_count, :win_count, :defeat_count,
                  :escape_count
    # The file-select screen's own face-thumbnail snapshot (title chunk 100,
    # fields 21/22..27/28, `LCF::Schema::SAVE_TITLE`'s face1..face4
    # name/index pairs) -- up to four `[faceset_name, faceset_index]` pairs,
    # or nil for a state that never carried one (a Marshal round-trip, or a
    # state built directly rather than loaded from a genuine `.lsd`).
    # Confirmed against a genuine RPG_RT.exe under wine: the save/load
    # file-select screen draws each occupied slot's face row from exactly
    # these title-chunk fields, not from whatever the slot's own party/actor
    # data says at preview time -- a synthetic save edited so the title
    # chunk's four face fields point at an unrelated FaceSet the actual
    # single-member party's own actor never carries showed precisely that
    # unrelated FaceSet on the real screen. `#to_lsd` already writes this
    # snapshot from the party's own members at save time (see its own
    # comment); only the read side was missing. `Scene::SaveLoad
    # #draw_slot_faces` reads this when present, falling back to deriving
    # from the live party's own members only when it is nil -- correct for
    # the Marshal round-trip path, which is not lossy (unlike `.lsd`'s own
    # per-actor chunk, which has no FaceSet fields at all) and so needs no
    # separate snapshot.
    attr_accessor :preview_faces
    # The file-select screen's own level/HP snapshot (title chunk 100, fields
    # 12/13, `hero_level`/`hero_hp`) -- nil for a state that never carried one
    # (a Marshal round-trip, or a state built directly rather than loaded from
    # a genuine `.lsd`). Confirmed against a genuine RPG_RT.exe under wine
    # exactly like `#preview_faces` above: a synthetic save whose title chunk
    # was edited to a level/HP the party leader's own live actor data (chunk
    # 108) never carried (7/321 against a live 50/600) showed precisely the
    # edited 7/321 on the real file-select screen, proving `Window_SaveFile`
    # draws this pair from the title chunk directly, never from any Actor
    # object. `#to_lsd` already writes this snapshot from the leader's own
    # level/hp at save time (see its own comment); only the read side was
    # missing. `Scene::SaveLoad#draw_level_hp` reads this when present,
    # falling back to the live leader's own level/hp only when it is nil --
    # correct for the Marshal round-trip path, which is not lossy and so
    # needs no separate snapshot.
    attr_accessor :preview_level, :preview_hp
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
    # chunks 21 / 23); Scene::Map reloads the windowskin when the override
    # changes.
    attr_accessor :system_graphic, :font_id
    # RPG2003's active-time wait/active toggle (`SaveSystem.atb_mode`, LSD
    # SAVE_SYSTEM chunk 140): 0 = active (gauges keep filling while a menu is
    # open and a ready non-controllable combatant's action interrupts it),
    # 1 = wait (a gauge battle's command menu pauses the fight) -- confirmed
    # against liblcf's own generated `AtbMode` enum (`AtbMode_atb_active =
    # 0, AtbMode_atb_wait = 1`), the opposite of an earlier, uncited pass
    # here. The field menu's Wait command (id 8) flips it and the gauge
    # battle scene reads it; default 0 (active), matching liblcf. RPG2000
    # saves never carry the chunk.
    attr_accessor :atb_mode
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
    # portable Marshal save (#to_h/.load); not persisted through `.lsd` at
    # all any more as of cycle #191 -- #common_event_exec below is the richer
    # mechanism that now backs chunk 114, and #new_parallel only ever falls
    # back to this cursor when that has nothing for a given common event id
    # (an older save, or one written by a build that predates cycle #191).
    # Kept, rather than replaced outright, because it is still exactly what
    # the portable Marshal save round-trips -- see #common_event_exec's own
    # comment for why that path was deliberately left alone.
    attr_accessor :common_event_progress
    # Full `Game::Interpreter` call-stack snapshot (see
    # Game::Interpreter#call_stack_snapshot) of whichever event currently
    # occupies the single shared foreground interpreter (Scene::Map's own
    # @interpreter) -- a map event (trigger 0 action key / 1 touch /
    # Auto-Start) or an Auto-Start Common Event, both of which run on that
    # one shared interpreter (see Scene::Map#start_autostart). A Hash
    # `{ event_id:, frames: }` (`frames` is #call_stack_snapshot's own return
    # value; `event_id` is the map event id it belongs to, or 0 for a common
    # event / no map character) when there is something mid-execution there,
    # nil otherwise -- true the overwhelming majority of the time a save
    # actually happens: an ordinary player-driven Save can only ever open
    # between events (Scene::Map#try_open_menu bails out on #event_busy?),
    # so the one reachable way to reach a non-nil value here is an event's
    # own Open Save Menu command (Cmd::OPEN_SAVE_MENU, 11910), which parks
    # the interpreter on a :save_menu wait rather than stopping it. Restoring
    # the wait itself (so the save menu would reopen the instant Continue
    # resumes) is deliberately out of scope, same as every other blocking-UI
    # wait #call_stack_snapshot's own comment already excludes -- the event
    # simply carries on with its very next command once resumed, which for
    # a completed Open Save Menu is exactly right (the menu already served
    # its purpose: writing this very save).
    #
    # Snapshotted every frame by Scene::Map#record_foreground_event_exec;
    # consumed once, at Continue time, by Scene::Map#initialize via
    # Scene::Map#restore_foreground_event_exec (Game::Interpreter
    # #restore_call_stack). Not persisted through the portable Marshal save
    # (#to_h/.load) -- see #common_event_exec's own comment for why. Round-
    # trips through a real `.lsd`'s chunk 113 (LCF::Schema::
    # SAVE_FOREGROUND_EVENT), as of cycle #191.
    attr_accessor :foreground_event_exec
    # Full `Game::Interpreter` call-stack snapshots of every currently-
    # running Common Event Parallel Process (Scene::Map's own @parallels,
    # the `common_event_id`-non-nil entries only -- a Map Event's own
    # parallel process has its own, separate #map_event_exec below, added by
    # cycle #193; this comment previously read "excluded... matching
    # #common_event_progress's identical scope", true when cycle #191 wrote
    # it, no longer true as of #map_event_exec's own addition): common event
    # id => Game::Interpreter#call_stack_snapshot's own return value.
    #
    # Snapshotted every tick by Scene::Map#record_parallel_progress
    # (superseding #common_event_progress for anything that has ever
    # actually run one full tick: unlike #resumable_index,
    # #call_stack_snapshot also captures a process mid a nested Call Event,
    # not only a clean between-commands cursor), consumed by
    # Scene::Map#new_parallel via Game::Interpreter#restore_call_stack,
    # falling back to #common_event_progress only when this hash has
    # nothing for a given id.
    #
    # Kept as a *separate* hash rather than folded into
    # #common_event_progress since the two round-trip through different save
    # formats by design: this one is `.lsd`-only (chunk 114, LCF::Schema::
    # SAVE_COMMON_EVENT), deliberately never added to the portable Marshal
    # save (#to_h/.load) -- that path already has full fidelity for free
    # within one process (a Transfer Player keeps the live
    # Game::Interpreter objects themselves, per #common_event_progress's own
    # comment above) and gets by with the coarser cursor otherwise, exactly
    # as it always has; Marshal-dumping a whole command-list snapshot (an
    # Array of LCF::EventCommand objects) every tick, for every running
    # Parallel Process, is unnecessary weight that path's own callers (dev
    # tooling, this test suite's own round-trip checks) have no need for.
    #
    # Unlike #map_event_exec below, a common event id is global (unique
    # across the whole database, not per-map), so this hash is safe to carry
    # forward across an ordinary Transfer Player untouched -- though in
    # practice #new_parallel never actually needs to for that case, since
    # #build_parallels already keeps the live Game::Interpreter object
    # itself across a same-session teleport (see its own comment); this hash
    # only ever gets a real look-in at Continue time, when there is no live
    # object to inherit from at all.
    attr_accessor :common_event_exec
    # Full `Game::Interpreter` call-stack snapshots of every currently-
    # running Map Event Parallel Process (a map event whose own page trigger
    # is Parallel Process -- distinct from #common_event_exec just above,
    # which is a Common Event's own Parallel Process): map event id =>
    # Game::Interpreter#call_stack_snapshot's own return value. Added by
    # cycle #193, closing the gap cycles #191/#192 both left open (a Map
    # Event's own Parallel Process previously had no persistence mechanism
    # at all -- not even the older, coarser #resumable_index-style cursor
    # #common_event_progress gives common events, since no such cursor ever
    # existed for map events in the first place -- see
    # Scene::Map#record_parallel_progress's own comment, which used to
    # document this as a deliberate no-op).
    #
    # Snapshotted every tick by the same Scene::Map#record_parallel_progress
    # that maintains #common_event_exec (the `p[:event]`, `p[:common_event_id]`-
    # nil entries of @parallels), consumed by Scene::Map#new_parallel via
    # Game::Interpreter#restore_call_stack exactly the same way, keyed by
    # the owning map event's own id instead of a common event id.
    #
    # Scoped to the single currently-loaded map only, UNLIKE
    # #common_event_exec: a map event's own id is per-map, not global (ids
    # repeat across maps -- see #map_event_positions' own comment on the
    # identical hazard), so carrying a stale entry across a genuine map
    # change risks feeding a same-numbered but wholly unrelated event on the
    # destination map someone else's captured call stack. Scene::Map
    # #perform_teleport clears this to `{}` for exactly that reason,
    # alongside #map_event_positions/#map_event_route_index (see there) --
    # which also means, unlike a Common Event's own Parallel Process, a Map
    # Event's own Parallel Process still always restarts fresh across an
    # ordinary Transfer Player (the pre-existing, deliberate behaviour
    # #build_parallels' own comment documents: "a real 'visit' gives a map
    # event's own parallel process no id that means anything on the map
    # being left"); this hash's full-fidelity resume is reachable only
    # through a genuine Save/Continue on the SAME map, the one channel
    # #perform_teleport's own reset does not touch.
    #
    # `.lsd`-only, the same rationale #common_event_exec's own comment gives
    # (round-trips through chunk 111's own SAVE_MOVABLE field 108,
    # LCF::Schema::SAVE_MOVABLE, one entry per live map event, nested inside
    # the same Array2D #map_event_positions/#map_event_route_index already
    # share -- see #to_lsd/.from_lsd) -- never added to the portable Marshal
    # save (#to_h/.load), which already gets full fidelity for free within
    # one process exactly the way #common_event_exec's own comment explains.
    attr_accessor :map_event_exec
    # The current map's own live event positions, event id => [x, y, direction],
    # snapshotted every frame by Scene::Map#record_map_event_positions. Real
    # RPG_RT's SaveMapEvent chunk carries exactly this (plus a move-route index,
    # see #map_event_route_index just below) for whichever map is loaded at
    # save time -- a wandering NPC's exact spot survives a Save/Continue on
    # the same map, distinct from an ordinary map re-visit (leave and return
    # with no save involved), which genuinely does reset every event to its
    # page's own default placement, matching the "Save / Load persistence"
    # list in docs/TODO.md. Scoped to the single currently-loaded map only:
    # event ids are per-map, not global, so this is cleared on every genuine
    # map change (Scene::Map#perform_teleport) rather than carried across
    # one, the same "resets on leaving-and-returning" family as
    # #encounter_rate/#parallax just above. Round-trips through both the
    # portable Marshal save (#to_h/.load) and a real `.lsd` (chunk 111,
    # LCF::Schema::SAVE_MOVABLE fields 12/13/22 -- see Game::State#to_lsd/
    # .from_lsd).
    attr_accessor :map_event_positions
    # The current map's own live custom-move-route (page move_type CUSTOM)
    # cursor, event id => Game::MoveRoute#index, snapshotted alongside
    # #map_event_positions. A map event mid-way through its page's own custom
    # route when a Save/Continue is taken now resumes at the exact same
    # command instead of restarting the route from the top, matching real
    # RPG_RT's SaveMapEvent chunk (LCF::Schema::SAVE_MOVABLE field 43,
    # move_route_index). Scoped identically to #map_event_positions in every
    # other way: per-map, reset on #perform_teleport, only ever consulted for
    # a page whose move_type is CUSTOM (Scene::Map#build_event's `e[:route]`)
    # -- a page with no custom route of its own leaves a stale entry here
    # unread and harmless -- and round-trips through both the portable
    # Marshal save and a real `.lsd` the same way #map_event_positions does.
    attr_accessor :map_event_route_index
    # The current map's own live Tile Substitution table (11750), [{old_id
    # => new_id} for the lower layer, same for upper] -- see Game::Map
    # #substitution_snapshot/#restore_substitutions. Real RPG_RT's SaveMapInfo
    # carries this (`lower_tiles`/`upper_tiles`) alongside the live event
    # table, so it survives a Save/Continue on the same map exactly like
    # #map_event_positions, while an ordinary map re-visit (leave and return
    # with no save involved) still resets it -- already-confirmed, separate
    # behaviour (docs/TODO.md). Scoped identically to #map_event_positions in
    # every other way: per-map, reset on #perform_teleport (a fresh
    # Game::Map's own #initialize starts with no substitutions), snapshotted
    # every frame by Scene::Map#record_tile_substitutions. Round-trips through
    # both the portable Marshal save (#to_h/.load) and a real `.lsd` (chunk
    # 111, LCF::Schema::SAVE_MAP_EVENT fields 21/22 -- see #to_lsd/.from_lsd).
    attr_accessor :tile_substitutions

    def initialize(party, map_id, x, y)
      @party = party
      @map_id = map_id
      @x = x
      @y = y
      @direction = 2
      @map = nil
      @pending_teleport = nil
      @switches = Switches.new
      # RPG2003's own wider +-9999999 variable range (see Game::Variables)
      # rather than RPG2000's +-999999 -- read once here from the party's
      # database, since #replace (State.load's own restore path) never
      # touches a Variables object's bound, only its stored values.
      @variables = Variables.new(party.respond_to?(:rpg2003?) && party.rpg2003?)
      @timers = [Timer.new, Timer.new]
      @message_config = MessageConfig.new
      @menu_access = true
      @save_access = true
      # Cycle #162: confirmed **on** by default against genuine RPG_RT.exe
      # (previously false here, the reverse of the confirmed default -- see
      # `#to_lsd`'s own comment for the capture evidence).
      @teleport_access = true
      @escape_access = true
      @current_bgm = nil
      @memorized_bgm = nil
      @pre_vehicle_bgm = nil
      @pre_battle_bgm = nil
      @player_flash = nil
      @player_route = nil
      @player_through = false
      @bgm_looped = false
      @bgm_stopping = false
      @player_transparent = false
      @encounter_rate = nil
      @encounter_total = 0
      @steps = 0
      @last_battle_turns = nil
      @save_count = 0
      @battle_count = 0
      @win_count = 0
      @defeat_count = 0
      @escape_count = 0
      @teleport_targets = {}
      @escape_target = nil
      @common_event_progress = {}
      @foreground_event_exec = nil
      @common_event_exec = {}
      @map_event_exec = {}
      @map_event_positions = {}
      @map_event_route_index = {}
      @tile_substitutions = [{}, {}]
      @system_bgm = {}
      @system_sfx = {}
      # nil = "not configured yet"; #seed_screen_transitions fills each slot in
      # from the database when the game starts.
      @screen_transitions = Array.new(SCREEN_TRANSITION_SLOTS, nil)
      @system_graphic = nil
      @font_id = 0
      # RPG2003's wait/active toggle; wait mode (0) is the default.
      @atb_mode = 0
      @weather = Weather.new
      # The three vehicles' saved locations (boat / ship / airship), persisted in
      # `.lsd` chunks 105-107. Unplaced until a save restores them.
      @vehicles = { boat: Vehicle.new(:boat), ship: Vehicle.new(:ship),
                    airship: Vehicle.new(:airship) }
      @boarded = nil
      # Screen effects: the tint transition now round-trips through a real
      # Save/Continue too (#to_lsd/.from_lsd, chunk 102's tint_finish_*/
      # tint_current_*/tint_time_left fields -- liblcf's SaveScreen, ported
      # from a reference implementation's own save-data handling, not
      # independently confirmed against genuine RPG_RT under wine,
      # a wholesale struct replace so a mid-transition tint resumes
      # interpolating exactly where it left off, not merely snapped to its
      # finish value). Shake/flash/fade/weather/battle-animation stay
      # transient (not serialised, so a reloaded game starts them neutral) --
      # a real gap vs RPG_RT's own SaveScreen, which models those too, left
      # as a separate future extension. The Pan Screen offset/lock *does*
      # also survive a save/load, but only through the internal Marshal-style
      # snapshot (`Game::Screen#to_h`/`#load_h`, `Game::State#to_h`/`.load`,
      # `main.rb`) used for quick-resume, not through `.lsd` chunk 102 itself.
      @screen = Screen.new
      # Shown pictures, id => Game::Picture. DOES round-trip through a real
      # Save/Continue (#to_lsd/.from_lsd, chunk 103, SAVE_PICTURE) -- a prior
      # version of this comment claimed otherwise; corrected the same day
      # chunk 103 was added (see docs/TODO.md). It now ALSO round-trips
      # through this engine's own internal Marshal-style quick-resume
      # (#to_h/.load, the same pair the Pan Screen offset above already
      # uses) -- cycle #158 found `#to_h` simply never mentioned `@pictures`
      # at all, so any picture on screen when Continue used the `.mrb` path
      # (main.rb's own documented preference over `.lsd` when both exist --
      # see scripts/compare-nepheshel-save-wine.bash's header) vanished on
      # resume with no trace, a real, player-visible loss this engine's own
      # `.lsd` path already avoided. See Picture#to_h/.from_h below.
      @pictures = {}
      # Runtime parallax override from a Change Parallax Background command (nil =
      # use the map's own panorama). Reset on a map change (#clear_parallax,
      # called alongside #erase_all_pictures) -- and, like @pictures, DOES
      # round-trip through a real Save/Continue on the same map (#to_lsd/
      # .from_lsd, chunk 111 fields 32-38): ported from a reference
      # implementation's own map-setup-from-save handling, NOT independently
      # confirmed against genuine RPG_RT under wine -- it restores
      # `SaveMapInfo`/`map_info` wholesale (the same struct a live Change
      # Parallax Background writes onto) and only a genuine map change
      # (its own map-setup routine) calls its own changed-background-clearing
      # helper -- two
      # genuinely different triggers a prior, uncited version of this
      # comment had conflated.
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
    # Gated on `#shown?`, not mere hash presence: since cycle #159, an erased
    # id's `Picture` object lingers in `@pictures` (see `#erase_picture`'s own
    # comment), and this must stay a no-op for that id exactly as it already
    # was for a never-shown one.
    def move_picture(id, *args)
      pic = @pictures[id]
      pic.move_to(*args) if pic&.shown?
    end

    # Erase Picture (11130): the `Picture` object itself is kept, not deleted
    # -- see `Picture#erase!`'s own comment for the genuine-RPG_RT.exe
    # evidence (cycle #159) that its position/zoom/tone fields must still
    # round-trip through `#to_lsd` after an erase, distinct from an id that
    # was never shown at all (which has no entry here to begin with, and
    # `#to_lsd` still writes as a fully field-less placeholder).
    def erase_picture(id)
      pic = @pictures[id]
      pic&.erase!
    end

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

    # Timer2's own remaining seconds -- RPG2003's map-event page TIMER2
    # condition reads this, not #timer_seconds (Timer1's).
    def timer2_seconds; timer(1).seconds; end
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
        pre_vehicle_bgm: @pre_vehicle_bgm, pre_battle_bgm: @pre_battle_bgm,
        player_flash: @player_flash, player_route: @player_route,
        player_through: @player_through,
        player_transparent: @player_transparent, weather: @weather.to_h,
        screen: @screen.to_h,
        pictures: @pictures.each_with_object({}) { |(id, p), out| out[id] = p.to_h },
        teleport_access: @teleport_access, escape_access: @escape_access,
        encounter_rate: @encounter_rate, encounter_total: @encounter_total,
        teleport_targets: @teleport_targets,
        common_event_progress: @common_event_progress,
        map_event_positions: @map_event_positions,
        map_event_route_index: @map_event_route_index,
        tile_substitutions: @tile_substitutions,
        steps: @steps, last_battle_turns: @last_battle_turns,
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
    #     each party member's FaceSet, so real RPG_RT and other reference
    #     tooling shows the party on the file screen;
    #   * system (101): switches, variables, save_count, the message-window
    #     configuration (position / transparency / face), the current and
    #     memorised BGM, the player-transparent flag and the
    #     menu/save/teleport/escape access flags;
    #   * hero (104): map position, facing and the leader's on-map CharSet (so a
    #     Change Sprite override survives);
    #   * actors (108): the per-actor level/exp/equipment/skills/HP/MP table;
    #   * inventory (109): the party roster / gold / item bag / both timers /
    #     the step counter / battle win/defeat/escape/victory tallies / the
    #     latest battle's round count.
    #
    # Switch and variable ids are 1-indexed in-game but 0-indexed in the save, so
    # they shift down by one; unset entries default to false / 0. +save_count+
    # goes in the system chunk (RPG_RT increments it on every save); +timestamp+
    # is the OLE-automation date shown on the file screen, defaulting to now;
    # +save_slot+ is the 1-indexed file slot this save is being written to
    # (SAVE_SYSTEM field 132) -- confirmed against genuine RPG_RT.exe under
    # wine (cycle #161): saving into File 1 (the project's own baseline
    # Save01.lsd fixture, save_count=4) leaves field 132 **absent**, while an
    # otherwise-identical autostart-Open-Save-Menu probe saved into File 2
    # writes field 132 present as **2** and, saved into File 3, present as
    # **3** -- matching the schema's own already-declared `default: 1` for
    # this field (LCF::Schema::SAVE_SYSTEM) exactly, the same "omit at
    # default" convention already confirmed for fields 41-44/51-54/61
    # (cycles #152/#153/#160). See #to_lsd's own sys[132] write below for the
    # gap this closed.
    #
    # That default used to be 0.0, and it is why the genuine RPG_RT refused to
    # load anything this wrote: a zero date is 1899-12-30, which RPG_RT reads as
    # an empty slot, so "Continue" stayed dead with no error at all. It was
    # found by stripping a real save down to exactly the chunks written here
    # (it still loaded, so nothing was missing), then swapping in one of ours at
    # a time until only the title chunk failed, then one field at a time within
    # it. See ADR 0021.
    #
    # Both Timer Operation countdowns, the step counter, the battle tallies,
    # the latest battle's round count and every roster member's Change Actor
    # Name and Change Actor Title overrides round-trip now too (see
    # LCF::Schema::SAVE_INVENTORY's timer1_*/timer2_*,
    # battles/defeats/escapes/victories/steps/turns fields and
    # SAVE_PARTY_ACTOR's actor_name/title), so this is a near-parity export.
    # `db`, when given, is consulted for the same database System boat/ship/
    # airship_name/_index fallback Scene::Map's own #vehicle_charset/
    # #vehicle_charset_index (mrblib/scene/map.rb) already apply for
    # rendering an uncustomized vehicle -- see the vehicle-writing loop
    # below -- and, together with `map_tree`, for SAVE_SYSTEM field 125 (see
    # that field's own citation further down). Every other caller (tests,
    # tools) omits either and gets the prior behavior (73/74 simply absent
    # for an uncustomized vehicle; field 125 omitted entirely).
    def to_lsd(save_count = 1, timestamp = nil, save_slot = 1, db = nil, map_tree = nil)
      timestamp = State.ole_now if timestamp.nil?
      save = LCF::SaveData.new

      leader = @party.leader
      members = @party.actors
      # Chunk 100 (the file-select screen's own title/preview data) used to be
      # written only when there was a leader to name, which left an entirely
      # empty party -- kk1.12's own genuine starting state, all five members
      # joining later through Change Party Member events, confirmed via a
      # genuine wine-driven capture (scripts/gen-lcf-save-wine.bash) taken
      # right after New Game -- with no chunk 100 at all rather than merely a
      # zero timestamp. That is the exact same failure mode ADR 0021 already
      # fixed for a *populated* party (a zero OLE date reads as an empty file
      # slot and Continue silently refuses it): a missing chunk leaves
      # `timestamp` at its own no-default nil, not the schema's own implicit
      # 0.0, but nil is exactly as unloadable as 0. The timestamp -- the one
      # field ADR 0021 actually pinned -- is now written unconditionally;
      # only the leader-specific name/level/hp fields, which have nothing to
      # read from an empty party, stay conditional.
      title = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TITLE })
      title[1] = timestamp.to_f
      if leader
        title[11] = leader.name
        title[12] = leader.level
        title[13] = leader.hp
      end
      # Up to four party faces fill the file-screen portrait slots (21/22 ..
      # 27/28), one FaceSet name+index pair per member -- a no-op loop for an
      # empty party, `members` being the same array `leader` is `.first`-ed
      # from.
      face_fields = [[21, 22], [23, 24], [25, 26], [27, 28]]
      members.each_index do |i|
        break if i >= face_fields.size
        nf, xf = face_fields[i]
        title[nf] = members[i].faceset_name
        # Elided at its own default (0) -- confirmed against a genuine
        # kk1.12 save under wine, whose leader's own FaceSet index was 0
        # and left field 22 (this member's own index slot) absent rather
        # than an explicit 0.
        idx = members[i].faceset_index
        title[xf] = idx if idx != 0
      end
      save[100] = title

      hero = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
      hero[11] = @map_id
      hero[12] = @x
      hero[13] = @y
      # @direction is RPG2000's own numpad convention (2/4/6/8); the wire
      # format is liblcf's 0..3 (up/right/down/left) -- CharSet::DIR_ROW is
      # the same numpad -> 0..3 table the renderer already uses to pick a
      # CharSet row, which is numerically identical to liblcf's own facing
      # enum (both walk up/right/down/left in that order).
      hero[22] = CharSet::DIR_ROW[@direction] || 2
      # Field 21 (liblcf's own `direction`/"sprite direction", distinct from
      # field 22's `facing`) mirrors field 22 -- see SAVE_MOVABLE's own
      # schema.rb comment for the genuine-save evidence and why this
      # codebase has no separate value to give it.
      hero[21] = hero[22]
      # Field 33 (liblcf's own `layer`): confirmed present as the constant 1
      # ("same as characters") on a genuine kk1.12 save under wine, on both
      # the hero's own record and every vehicle's (see the vehicle-writing
      # loop below) -- this codebase has no "Change Hero/Vehicle Layer"
      # concept at all (RPG2000/2003 never offers one; only a map *event*
      # page can be pinned below/above characters), so 1 is a true constant
      # here, not a live value with a default to elide at.
      hero[33] = 1
      # Fields 81-85 (flash_red/_green/_blue/_current_level/_time_left): see
      # SAVE_MOVABLE's own schema.rb comment for the full citation. The RGB
      # triple is written unconditionally (0 when nothing is flashing,
      # confirmed against genuine RPG_RT under wine -- not the schema's own
      # -1 generator default); the level/time_left pair only while
      # #player_flash is actually live, `flash_current_level` derived from
      # this codebase's own linear decay (`power * frames / total.to_f`,
      # matching Scene::Map#flash_tone) rather than independently confirmed.
      pf = @player_flash
      hero[81] = pf ? pf[:red] : 0
      hero[82] = pf ? pf[:green] : 0
      hero[83] = pf ? pf[:blue] : 0
      if pf && pf[:frames] && pf[:frames] > 0
        total = pf[:total] && pf[:total] > 0 ? pf[:total] : pf[:frames]
        hero[84] = pf[:power].to_f * pf[:frames] / total
        hero[85] = pf[:frames]
      end
      # Fields 32/41/43/51 (move_frequency/move_route/move_route_index/
      # through): a live Set Move Route (11330) forced route targeting the
      # player -- see Game::State#player_route's own citation for what is
      # and is not confirmed here. `Game::MoveCommand` (this codebase's own
      # class) already exposes the exact reader methods `LCF.
      # encode_move_commands` needs, so the route's own command list is
      # handed to it unconverted.
      pr = @player_route
      if pr
        hero[32] = pr[:frequency] if pr[:frequency]
        cmds = pr[:commands] || []
        route = LCF::Array1D.new('', { elements: LCF::Schema::MOVE_ROUTE })
        # Confirmed against the same genuine kk1.12 save: field 11
        # (command_size) is present alongside field 12, matching the real
        # command count -- redundant for #parse_move_commands' own
        # self-terminating read (it just runs to the end of field 12's own
        # blob), but written unconditionally to match. repeat (21)/
        # skippable (22) follow the ordinary per-field "omit at own
        # default" convention, same as every other boolean pair in this
        # schema -- confirmed in that same capture: repeat was present
        # (false, differing from its own true default) while skippable was
        # absent (at its own false default).
        route[11] = cmds.size
        route[12] = cmds
        route[21] = false unless pr[:repeat]
        route[22] = true if pr[:skippable]
        hero[41] = route
        hero[43] = pr[:index] if pr[:index]
      end
      hero[51] = true if @player_through
      # Set Transparent Flag's own override (Player Visibility, 11310) --
      # liblcf's own "0 or 3" convention for this field (see schema.rb's
      # SAVE_MOVABLE comment on why it lives here, on the hero's own movable
      # record, not the system chunk).
      hero[24] = @player_transparent ? 3 : 0
      # A live mirror of the leader's *currently drawn* CharSet graphic --
      # elided when blank, confirmed against genuine RPG_RT.exe under wine
      # (cycle #170): a leader whose graphic was blank (no override, blank
      # database default) left these fields absent, one whose *database* row
      # already carried a non-blank graphic (still no override) wrote them
      # present anyway, and one with a live Change Sprite Association
      # override also wrote them present with the overridden value -- so
      # this pair tracks "what the hero currently looks like", not "was
      # there a live override" (that is chunk 108's own sprite_name/
      # sprite_id/sprite_transparent job instead, on the *actor's* own
      # SAVE_PARTY_ACTOR entry -- see #to_lsd's own citation just below and
      # SAVE_PARTY_ACTOR's schema.rb comment). Continuing a save never reads
      # this pair back (see .from_lsd's own citation) -- it is write-only
      # parity with what genuine RPG_RT itself puts here, not a restore path.
      if leader && leader.charset_name && !leader.charset_name.empty?
        hero[73] = leader.charset_name
        hero[74] = leader.charset_index || 0
      end
      save[104] = hero

      # Vehicle locations (105 boat / 106 ship / 107 airship). Confirmed
      # against a genuine kk1.12 save under wine: all three chunks were
      # present even though the party never boarded any of them that
      # session (map_id/x/y all still 0, the never-placed sentinel) --
      # genuine RPG_RT writes every vehicle's record unconditionally, not
      # only once it has been placed.
      #
      # The same capture also had charset_name ("乗り物") and charset_index
      # (0/1/3) present on all three even though this engine's own model
      # never wrote them until customized -- that capture's own database
      # configures every vehicle's System boat/ship/airship_name/_index to
      # resolve to exactly those values, the same fallback Scene::Map's own
      # #vehicle_charset/#vehicle_charset_index (mrblib/scene/map.rb) apply
      # for rendering. Mirrored here off the optional `db` argument: when a
      # caller has one to give (main.rb's own #export_lsd does), an
      # uncustomized vehicle's 73/74 resolve the database's own name/index
      # instead of staying absent, exactly like rendering already does; a
      # caller with no `db` (tests, tools) keeps the prior absent-when-
      # uncustomized behavior.
      { 105 => :boat, 106 => :ship, 107 => :airship }.each do |chunk, type|
        v = @vehicles[type]
        mv = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
        mv[11] = v.map_id
        mv[12] = v.x
        mv[13] = v.y
        dir_row = CharSet::DIR_ROW[v.direction] || 2
        mv[21] = dir_row
        mv[22] = dir_row
        # Field 33 (layer): a true constant, see the hero's own field-33
        # citation just above.
        mv[33] = 1
        mv[35] = 0
        mv[37] = Vehicle::DEFAULT_MOVE_SPEED[type]
        if v.charset_name && !v.charset_name.empty?
          mv[73] = v.charset_name
          idx = v.charset_index || 0
          mv[74] = idx if idx != 0
        elsif db && db.respond_to?(:system) && db.system
          name_field = "#{type}_name"
          index_field = "#{type}_index"
          name = db.system.respond_to?(name_field) ? db.system.send(name_field) : nil
          if name && !name.to_s.empty?
            mv[73] = name.to_s
            idx = db.system.respond_to?(index_field) ? (db.system.send(index_field) || 0) : 0
            mv[74] = idx if idx != 0
          end
        end
        mv[101] = Vehicle::TYPE_ID[type]
        save[chunk] = mv
      end

      sys = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_SYSTEM })
      # liblcf's own `scene` field (0x01/1): a legacy field RPG_RT itself
      # always writes as 5 (its own "file menu" scene id) for any save file
      # and other reference tooling never reads back -- confirmed present with
      # exactly this value on a genuine kk1.12 save under wine.
      sys[1] = 5
      sw = @switches.to_h
      sw_max = sw.empty? ? 0 : sw.keys.max
      switches = Array.new(sw_max, false)
      sw.each { |id, v| switches[id - 1] = v ? true : false }
      # Field 31 (the count) is elided when no switch has ever been touched
      # (sw_max 0), but field 32 (the data array, empty in that case) is
      # still written -- confirmed against a genuine kk1.12 save under
      # wine: an early save whose party had never touched a switch omitted
      # field 31 entirely (rather than an explicit count of 0) while still
      # carrying field 32 present as a zero-length array.
      sys[31] = sw_max if sw_max > 0
      sys[32] = switches
      vr = @variables.to_h
      vr_max = vr.empty? ? 0 : vr.keys.max
      variables = Array.new(vr_max, 0)
      vr.each { |id, v| variables[id - 1] = v }
      sys[33] = vr_max
      sys[34] = variables
      # Message-window configuration (field 41 transparency is 0/1, 43 is the
      # inverse of our "pinned" flag: prevent-overlap true == not position_fixed,
      # 53 face side is 0 left / 1 right). Fields 41-44 are each written only
      # when they differ from SAVE_SYSTEM's own declared default for that
      # field (message_transparent false/0, message_position 2/bottom,
      # message_prevent_overlap true i.e. position_fixed false,
      # message_continue_events false) -- confirmed against a genuine
      # RPG_RT.exe save under wine this cycle: a synthetic autostart Change
      # Message Options (10120) call whose four params reproduce the exact
      # default state left every one of 41-44 absent (identical to never
      # issuing the command at all), the same call with all four params
      # changed away from default wrote all four fields present with the
      # changed values, and a further Change Message Options call putting
      # every param back to the default left all four absent again -- the
      # same value-based (not "ever touched") "omit at default" convention
      # field 61 (`bgm_stopping`) already established, now confirmed to
      # extend across this whole message-config field cluster too, not just
      # field 41 alone as cycle #152's own single-value spot check left
      # open.
      mc = @message_config
      sys[41] = 1 if mc.transparent
      sys[42] = mc.position if mc.position != MessageConfig::POS_BOTTOM
      sys[43] = false if mc.position_fixed
      sys[44] = true if mc.continue_events
      # Change Face Graphic (10130) state (SAVE_SYSTEM fields 51-54) follows
      # the exact same per-field "omit at default" convention as 41-44 above,
      # confirmed against a genuine RPG_RT.exe save under wine (cycle #160):
      # a synthetic autostart Change Face Graphic call left at its own
      # constructor default (no face shown at all) omitted all four fields;
      # the same call set to a real face/index/side/flip (all off-default)
      # wrote all four fields present with the exact set values; a further
      # Change Face Graphic('') resetting back to the default (still
      # mid-event, so the separate "yado.tk" auto-clear-on-event-finish rule
      # never fired) omitted all four again -- ruling out "ever touched" and
      # confirming per-value comparison, not an unconditional write (this
      # codebase's own prior behavior, which wrote all four fields on every
      # save regardless of state). A fourth capture -- a real face name at
      # otherwise-default index/side/flip -- wrote only field 51 and left
      # 52-54 absent, confirming the four fields are gated *independently*,
      # not as one all-or-nothing group keyed on "is a face shown at all".
      sys[51] = mc.face_name if mc.face?
      sys[52] = mc.face_index if mc.face_index != 0
      sys[53] = 1 if mc.face_right
      sys[54] = true if mc.face_flipped
      # liblcf's `music_stopping` (field 61) -- written only when true,
      # confirmed against a genuine RPG_RT.exe save under wine (see
      # SAVE_SYSTEM's own comment in schema.rb): a fresh Fade Out BGM
      # produces a save with this field present as a single 0x01 byte, while
      # both a save taken with no fade ever issued and one taken after a
      # later Play BGM cleared the flag back to false both omit it entirely.
      sys[61] = true if @bgm_stopping
      # Field 71 (title_bgm) has no live tracking of its own in this
      # codebase -- RPG_RT never lets Change System BGM touch it (see
      # SYSTEM_BGM_SAVE_FIELD's own comment) -- but a genuine save still
      # carries it present, always at its own blank-name default, alongside
      # 72-82. Written unconditionally to match.
      sys[71] = bgm_chunk({})
      sys[75] = bgm_chunk(@current_bgm) if @current_bgm
      # Fields 76/77 (before_vehicle_music/before_battle_music) are the
      # restore point #restore_pre_vehicle_bgm/#restore_pre_battle_bgm
      # (Scene::Map) bring back on disembark/after a fight -- unlike the
      # Change System BGM override slots just below, RPG_RT always writes a
      # real value here, "(OFF)" standing in for "nothing to restore" rather
      # than the field going absent. Confirmed against a genuine kk1.12 save
      # under wine, taken outside any vehicle/battle: both present, decoding
      # as a BGM struct whose own `file` read the literal "(OFF)".
      sys[76] = bgm_chunk(@pre_vehicle_bgm || { name: '(OFF)' })
      sys[77] = bgm_chunk(@pre_battle_bgm || { name: '(OFF)' })
      # Field 78 (stored_bgm/Memorize BGM's own stash, 11530) follows the
      # exact same "always present, (OFF) when nothing to hold" convention
      # as 76/77 above, not the "omit at default" this field used before --
      # confirmed against the same genuine kk1.12 save under wine: present
      # even though that session never ran Memorize BGM, decoding as a BGM
      # struct whose own `file` read the literal "(OFF)".
      sys[78] = bgm_chunk(@memorized_bgm || { name: '(OFF)' })
      # Change System BGM (10660) overrides (SYSTEM_BGM_SAVE_FIELD above) --
      # like field 71 and the SFX slots below, all seven are written
      # unconditionally (blank when unset), confirmed against the same
      # genuine kk1.12 save under wine: every one of battle_music(72)..
      # gameover_music(82) was present, blank-named, even though that
      # save's party never ran Change System BGM at all.
      SYSTEM_BGM_SAVE_FIELD.each do |slot, field|
        sys[field] = bgm_chunk(@system_bgm[slot] || {})
      end
      # Change System SFX (10670) overrides (SYSTEM_SFX_SAVE_FIELD above) --
      # unlike the BGM slots, all 12 are written unconditionally (blank when
      # unset), confirmed against a genuine kk1.12 save under wine: every
      # one of cursor_se(91)..item_se(102) was present, blank-named, even
      # though that save's party never ran Change System SFX at all.
      SYSTEM_SFX_SAVE_FIELD.each do |slot, field|
        sys[field] = se_chunk(@system_sfx[slot] || {})
      end
      # SAVE_SYSTEM fields 121-124 (Control Teleport/Escape/Save/Menu Access)
      # are all ONE uniform "omit at true default" cluster after all --
      # cycle #161 mistakenly split them into an "unconditional" pair
      # (121/122) and an "omit at true default" pair (123/124), because its
      # own probe for 121 only ever tested an ENABLE-then-DISABLE round trip
      # that ends at the codebase's *assumed* false default -- a test that
      # cannot distinguish "written unconditionally" from "written because
      # false is actually the non-default value", and it never independently
      # probed 122 at all (treated as sharing 121's convention "by analogy").
      # Cycle #162 closed both gaps against genuine RPG_RT.exe under wine
      # (same synthetic-autostart-event + Open-Save-Menu-with-no-Wait shape
      # cycles #160/#161 used): an ENABLE-only probe for each of 121
      # (`teleport_access`) and 122 (`escape_access`) -- leaving the flag at
      # **true**, the opposite end from every previous probe -- came back
      # with the field **absent**, while the project's own untouched
      # continued-game baseline (where prior story events had already left
      # both flags at false) and an ENABLE-then-DISABLE round trip (also
      # ending at false) both came back **present** with value false. That
      # present-at-false/absent-at-true split is exactly the per-value "omit
      # at true default" convention already confirmed for 123/124 (and for
      # fields 41-44/51-54/61/132 elsewhere in this schema) -- not a written-
      # regardless-of-value convention -- which also means this codebase's
      # own claimed *default* for 121/122 was backwards: genuine RPG_RT.exe
      # treats Teleport and Escape as **allowed** until an event forbids
      # them, the same on-by-default posture Save and Menu access already
      # had, not forbidden-by-default as `Game::State#initialize` used to set
      # (see its own updated comment above). This codebase's own #to_lsd used
      # to write 121/122 unconditionally (`@teleport_access ? true : false`
      # etc.), so a save taken with teleport/escape access still at their
      # true default carried explicit `true`-valued bytes a genuine
      # RPG_RT.exe save never does, the same species of over-writing bug
      # cycles #152/#153/#160 already fixed elsewhere in this schema, now
      # shown to cover this whole cluster.
      sys[121] = false unless @teleport_access
      sys[122] = false unless @escape_access
      sys[123] = false unless @save_access
      sys[124] = false unless @menu_access
      # Field 125 ("background" in liblcf's own generator/csv/fields.csv --
      # this schema's own :battle_background name was a disproven guess, see
      # SAVE_SYSTEM's own comment for the full history): the current map's
      # resolved encounter background, standing on whatever terrain the
      # party currently occupies -- the same `Game::Backdrop.name_for` walk
      # plus terrain lookup `Scene::Battle#encounter_backdrop` already uses
      # to pick a fight's own backdrop. Needs both `db` (a chipset to
      # resolve the tile's terrain id, and the terrain table's own
      # background_name) and `map_tree` (the map-tree's own backdrop_type
      # walk) to compute -- omitted when either is absent (tests, tools), or
      # this state has no map loaded (a fresh, unplayed save). Does not
      # account for a live Change Map Tileset override
      # (Scene::Map#apply_tileset_request's own `@tileset_id`), which this
      # codebase does not persist anywhere yet -- a separate, pre-existing
      # gap.
      if db && map_tree && self.map
        begin
          props = map_tree.respond_to?(:map_properties) ? map_tree.map_properties : nil
          terrain_name = ''
          if db.respond_to?(:chipset) && db.respond_to?(:terrain) && self.map.in_bounds?(@x, @y)
            chipset = ChipSet.new(db, self.map.chipset_id)
            tid = chipset.terrain(self.map.lower(@x, @y))
            row = db.terrain[tid]
            terrain_name = row.background_name.to_s if row && row.respond_to?(:background_name)
          end
          name = Backdrop.name_for(map_id, props, terrain_name)
          sys[125] = name unless name.nil? || name.empty?
        rescue StandardError => e
          $stderr.puts "[RPG2k] battle background lookup failed: #{e.message}"
        end
      end
      # Screen-transition slots 0..5 map to chunks 111..116 in order.
      @screen_transitions.each_with_index { |style, i| sys[111 + i] = style || 0 }
      # System windowskin / font override (Change System Graphics). Font id
      # is elided at its own declared default (0) -- confirmed against a
      # genuine kk1.12 save under wine, whose party never touched Change
      # System Graphics' font option, omitting field 23 entirely rather than
      # writing an explicit 0 the way this codebase's own writer always did.
      sys[21] = @system_graphic if @system_graphic
      sys[23] = @font_id if @font_id != 0
      # RPG2003's wait/active toggle (chunk 140). Written only when it leaves
      # the default 0 (wait) -- the chunk is 2003-only, so an RPG2000 save
      # must not gain a stray 0 here.
      sys[140] = @atb_mode if @atb_mode && @atb_mode != 0
      sys[131] = save_count
      # The file slot this save is being written to (SAVE_SYSTEM field 132).
      # Confirmed against genuine RPG_RT.exe under wine (cycle #161): field
      # 132 is omitted entirely from a save written to File 1 (matching the
      # schema's own `default: 1`) and present with the exact chosen slot
      # number for File 2 / File 3 -- the same per-field "omit at default"
      # convention already confirmed for fields 41-44/51-54/61. This used to
      # hardcode 1 regardless of the actual destination slot, the same
      # species of bug cycles #152/#153/#160 already fixed elsewhere in this
      # cluster (a field written unconditionally, and with the wrong value to
      # boot, when genuine RPG_RT gates it on the real state).
      sys[132] = save_slot if save_slot != 1
      save[101] = sys

      # Chunk 108 is the whole roster, one entry per actor the party has ever
      # held — that is what a genuine RPG_RT save carries, and it is what lets an
      # actor who is currently out of the party come back as they left.
      actors = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_PARTY_ACTOR })
      @party.roster.each do |a|
        e = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_PARTY_ACTOR })
        # Field 1 is the actor's current name, but ONLY while it actually
        # differs from the database row (#name_changed?) -- an untouched
        # actor writes the ADR 0014 "\x01" placeholder instead, confirmed
        # against a genuine kk1.12 save under wine (see #name_changed?'s own
        # citation); a prior version of this line wrote the current name
        # unconditionally, which happens to equal the database default for
        # any actor never hit by Change Actor Name, so it looked correct
        # against a save whose leader/party actually had been renamed
        # (Nepheshel Save01) while silently diverging from genuine RPG_RT
        # for every other, untouched roster entry.
        e[1] = a.name_changed? ? a.name : "\x01"
        # Field 2 is the actor's current title, gated on #title_changed? the
        # same way -- confirmed against liblcf's SaveActor field table (see
        # SAVE_PARTY_ACTOR's comment in schema.rb) for the field id, and
        # against the same genuine kk1.12 save for the placeholder gating.
        e[2] = a.title_changed? ? a.title : "\x01"
        # A live Change Sprite Association (10630) override -- fields 11
        # (sprite_name) / 12 (sprite_id) / 13 (sprite_transparent), gated on
        # #sprite_changed? (the command actually having run), not merely a
        # non-blank current graphic -- see SAVE_PARTY_ACTOR's own schema.rb
        # comment for the genuine-RPG_RT wine verification this cycle (#170)
        # that pinned these fields down, and for why chunk 104's own hero-
        # record mirror (fields 73/74) is *not* what a genuine Continue
        # restores the sprite from.
        if a.sprite_changed?
          e[11] = a.charset_name || ''
          e[12] = a.charset_index || 0
          e[13] = 3 if a.transparent
        end
        e[31] = a.level
        e[32] = a.exp
        e[51] = a.skills.size
        e[52] = a.skills
        e[61] = a.equipment
        e[71] = a.hp
        e[72] = a.mp
        # Field 82 is a dense array, one slot per database state id
        # (`total_state_count` long), not a sparse list of only the
        # currently-afflicted ids -- see Actor#total_state_count's own
        # citation. Written unconditionally (even all-zero) to match a
        # genuine save, the same "container present, contents sparse"
        # convention chunk 103's own 50-slot picture range already
        # established.
        n = a.total_state_count
        dense = Array.new(n, 0)
        a.states.each { |sid| dense[sid - 1] = 1 if sid >= 1 && sid <= n }
        e[81] = n
        e[82] = dense
        # A live Change Class survives Save/Continue too, not just the name/
        # title/sprite overrides above -- only once #change_class (or a
        # restored one) has actually run, matching the reference sentinel
        # value liblcf's own field default declares: `class_id != -1`
        # "changed at all", not merely "class_id > 0" -- Change Class to "no class"
        # (id 0) is itself a real, persisted change.
        e[90] = a.class_id if a.class_changed?
        # Field 80 (battle_commands) is written unconditionally -- liblcf's
        # own generator/csv/fields.csv declares its default as the literal
        # sentinel array `[-1]*7` (seven "defer to class/database" slots),
        # and a genuine kk1.12 save under wine carries field 80 present with
        # exactly that default on every actor whose commands were never
        # touched (field 83, `changed_battle_commands`, absent alongside
        # it) -- not omitted the way this codebase's own writer used to
        # treat "untouched" fields. Field 83 stays gated on
        # #battle_commands_changed? (matching a reference implementation's
        # own flag of the same name),
        # the actual "was this ever overridden" signal `.from_lsd` reads.
        e[80] = a.battle_commands_changed? ? a.battle_commands : BATTLE_COMMANDS_DEFAULT
        e[83] = true if a.battle_commands_changed?
        # RPG2003 battle row (0x5B/91, liblcf's `ChunkSaveActor::row`) --
        # only written off the front-row default, the same eliding-writer
        # convention `class_id`/`battle_commands` follow above, so an
        # RPG2000 save (or a 2003 save whose party never touched Row) never
        # gains the field.
        e[91] = a.battle_row if a.battle_row != Actor::ROW_FRONT
        # A live mirror of the actor's own current class/database-derived
        # combat toggles -- see SAVE_PARTY_ACTOR's own schema.rb comment.
        e[92] = true if a.double_hand?
        e[93] = true if a.equipment_fixed?
        e[94] = true if a.force_ai?
        e[95] = true if a.strong_defence?
        # A live Change Parameters edit (#change_param) survives Save/
        # Continue too -- see SAVE_PARTY_ACTOR's own comment for the
        # genuine-RPG_RT verification. `@base_raw` is the curve plus this
        # modifier with no equipment folded in, so subtracting the curve
        # back out isolates the same delta #change_param itself computes.
        raw = a.base_raw
        curve = a.base_stats(a.level)
        # hp_mod/sp_mod (33/34) are written unconditionally, delta 0
        # included -- confirmed against a genuine kk1.12 save under wine,
        # every actor's own untouched hp_mod/sp_mod present as an explicit
        # 0, distinct from liblcf's own declared -1 ("never touched")
        # default (see schema.rb's own comment on these two fields).
        # attack_mod/defense_mod/spirit_mod/agility_mod (41-44) keep the
        # opposite, "omit at zero" convention the same save confirms.
        e[33] = raw[0] - curve[0]
        e[34] = raw[1] - curve[1]
        [41, 42, 43, 44].each_with_index do |field, i|
          delta = raw[i + 2] - curve[i + 2]
          e[field] = delta if delta != 0
        end
        actors[a.id] = e
      end
      save[108] = actors

      # Chunk 102 is the screen tint transition (Tint Screen, 11030) -- its
      # own container is confirmed unconditional and its own fields
      # confirmed individually value-elided against genuine RPG_RT.exe under
      # wine this cycle (not a reference implementation's source, correcting
      # a prior comment here that mislabelled that reference implementation's
      # own save-handling source as "RPG_RT's live source"): a synthetic autostart
      # list that never touches Tint Screen at all still produced a genuine
      # Save2.lsd with chunk 102 *present* (a bare 1-byte, zero-field
      # container, not an absent chunk), and a second list issuing one Tint
      # Screen with every channel pushed off its own SAVE_SCREEN-declared
      # default (100) but frames=0 (instant, so the transition completes on
      # the same frame -- time_left settles right back to its own default 0)
      # wrote fields 1-4/11-14 (every channel, both finish and settled
      # current) present with the changed values while leaving field 15
      # (time_left) absent, still sitting at its own default -- i.e. the
      # container is unconditional but each field is elided independently at
      # its own default, the exact convention SAVE_SYSTEM's message-config
      # cluster (fields 41-44) already established, not the all-or-nothing
      # "omit the whole chunk when neutral" this file previously did (which
      # never once produced a byte-identical chunk-102 shape to genuine
      # RPG_RT.exe for the overwhelmingly common "tint never touched" case).
      # Only tint is modelled here (see @screen's own comment above); the
      # shake/flash/fade/weather/battle-animation fields liblcf's SaveScreen
      # also carries are a separate, larger gap this codebase doesn't model
      # in Game::Screen at all yet, left as a future extension.
      scr = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_SCREEN })
      finish, current, frames = @screen.tint_save_data
      scr[1] = finish[0] if finish[0] != Screen::NEUTRAL
      scr[2] = finish[1] if finish[1] != Screen::NEUTRAL
      scr[3] = finish[2] if finish[2] != Screen::NEUTRAL
      scr[4] = finish[3] if finish[3] != Screen::NEUTRAL
      scr[11] = current[0] if current[0] != Screen::NEUTRAL
      scr[12] = current[1] if current[1] != Screen::NEUTRAL
      scr[13] = current[2] if current[2] != Screen::NEUTRAL
      scr[14] = current[3] if current[3] != Screen::NEUTRAL
      scr[15] = frames if frames != 0
      pan_x, pan_y = @screen.pan_offset
      scr[41] = pan_x if pan_x != 0
      scr[42] = pan_y if pan_y != 0
      save[102] = scr

      # Chunk 103 is every picture slot RPG2000 offers (Show Picture, 11110)
      # -- its own container and its own 1..MAX_PICTURE_ID (50) slot range are
      # both confirmed unconditional against genuine RPG_RT.exe under wine
      # (cycle #154; not a reference implementation's source, correcting a
      # prior comment here that mislabelled that reference implementation's
      # own save-handling source as "RPG_RT's live source"): a synthetic autostart
      # list that never issues Show Picture at all still produced a genuine
      # Save2.lsd with chunk 103 *present*, holding exactly 50 sub-entries
      # (ids 1-50, RPG2000's own Show Picture id range -- `MAX_PICTURE_ID`
      # below) every one of them an empty (zero-field) placeholder, not an
      # absent chunk or a sparse 0-entry array; a second list showing only
      # picture id 5 produced a save with all 50 ids still present but only
      # id 5 carrying real field data, every other id (1-4, 6-50) still its
      # own empty placeholder entry alongside it -- so the whole fixed-size
      # slot range is unconditional, and only a slot's own field presence is
      # sparse, the opposite of this file's prior "omit the id from the
      # array entirely unless a picture has ever been shown there" shape
      # (which also, as a side effect, only ever emitted however many ids
      # had been *touched*, never the full 50-wide range genuine RPG_RT.exe
      # always carries). `@pictures` holds every id ever shown, including an
      # erased one (see `#erase_picture`'s own comment -- the entry lingers
      # so its fields keep round-tripping through here), so a shown-or-
      # erased id is a slot with an entry here and only a genuinely
      # untouched id is nil/absent from `@pictures`, both handled below.
      #
      # Field mapping is the exact mirror of `.restore_pictures`' own read
      # (see `SAVE_PICTURE`'s own comment for the full evidence behind each
      # field): 1 name; 6/9 the fixed_to_map/use_transparent_color flags
      # given to the picture's own Show Picture call, elided false like
      # every other picture flag (cycle #164 -- these two were previously
      # unwritten entirely, so a picture shown fixed-to-the-map or exempted
      # from the transparent color lost that flag on every Save/Continue
      # round trip); 2/3 show_x/show_y (the position last given to Show
      # Picture, untouched by any Move Picture since); 4/5/7/8/11-14 the
      # genuinely live current position/zoom/transparency/tone; 31/32
      # finish_x/finish_y (the move's target, equal to current at rest);
      # 33/34/41-44 the finish zoom/transparency/tone; 51 the in-flight
      # move's own remaining-frames counter. Cycle #155 confirmed against
      # genuine RPG_RT.exe under wine that 4/5/7/8/11-14 are written whether
      # or not a move is actually in flight (a picture shown and never moved
      # still carries them, equal to their own 31-34/41-44 counterparts,
      # matching real RPG_RT's own current-tracks-finish idle sync already
      # noted above) -- fixing a prior version of this method that wrote
      # them only while `Game::Picture#moving?`, silently dropping the
      # "genuinely live" current_* value on every picture at rest. Cycle
      # #155 also confirmed zoom/transparency/tone (both the current_* and
      # finish_* copies) are each elided independently at their own default
      # -- see SAVE_PICTURE's own comment for the controlled genuine-RPG_RT
      # A/B pair that pinned this down, ruling out cycle #154's own
      # "probe just happened to pick default values" alternative reading.
      pics = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_PICTURE })
      (1..MAX_PICTURE_ID).each do |id|
        p = @pictures[id]
        e = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_PICTURE })
        if p
          # Field 1 (name) is present only while the picture is actually
          # shown (`#shown?`, not mere name-emptiness -- see Picture#erase!'s
          # own comment for why) -- this table's own SAVE_PICTURE schema
          # comment carries cycle #159's genuine-RPG_RT evidence: an id that
          # was shown and then Erase Picture'd keeps every position/zoom/tone
          # field at its last value but drops the name outright, distinct
          # from an id that was never shown at all (which this loop leaves
          # as a fully field-less placeholder, `p` nil, matching cycle #154's
          # own finding unchanged).
          e[1] = p.name if p.shown?
          e[6] = true if p.fixed_to_map
          e[9] = true if p.use_transparent_color
          e[2] = p.show_x
          e[3] = p.show_y
          e[4] = p.x
          e[5] = p.y
          e[7] = p.zoom if p.zoom != 100
          cur_trans = Game.opacity_to_trans(p.opacity)
          e[8] = cur_trans if cur_trans != 0
          # Field 18 (current_bot_trans, RPG2003-only) has no independent
          # value of its own here -- see SAVE_PICTURE's own schema.rb comment
          # -- so it mirrors field 8 (top == bottom).
          e[18] = cur_trans if cur_trans != 0
          e[11] = p.red if p.red != 100
          e[12] = p.green if p.green != 100
          e[13] = p.blue if p.blue != 100
          e[14] = p.saturation if p.saturation != 100
          moving = p.moving?
          fx = moving ? p.finish_x : p.x
          fy = moving ? p.finish_y : p.y
          fzoom = moving ? p.finish_zoom : p.zoom
          fopacity = moving ? p.finish_opacity : p.opacity
          fred = moving ? p.finish_red : p.red
          fgreen = moving ? p.finish_green : p.green
          fblue = moving ? p.finish_blue : p.blue
          fsat = moving ? p.finish_saturation : p.saturation
          e[31] = fx
          e[32] = fy
          e[33] = fzoom if fzoom != 100
          fin_trans = Game.opacity_to_trans(fopacity)
          e[34] = fin_trans if fin_trans != 0
          # Field 35 (finish_bot_trans, RPG2003-only) mirrors field 34 for
          # the same reason field 18 mirrors field 8 above.
          e[35] = fin_trans if fin_trans != 0
          e[41] = fred if fred != 100
          e[42] = fgreen if fgreen != 100
          e[43] = fblue if fblue != 100
          e[44] = fsat if fsat != 100
          e[51] = p.frames_left if moving
        end
        pics[id] = e
      end
      save[103] = pics

      inv = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_INVENTORY })
      # party_count (1) / party (2): the same count-then-data split as
      # item_count/item_ids (11/12) just below -- see SAVE_INVENTORY's own
      # comment. A genuine RPG_RT.exe requires both fields; writing only the
      # count (or, as this used to, cramming the roster into field 1 alone
      # and never writing field 2 at all) crashes it outright on load.
      party_ids = @party.actors.map { |a| a.id }
      inv[1] = party_ids.size
      inv[2] = party_ids
      # Written in the bag's own order, not sorted: RPG_RT preserves the
      # stored order across a save/load (see Party#field_items' own wine
      # citation, cycle #252), so sorting here would silently reorder the
      # player's bag every time this engine saved. A save whose bag was
      # already in id order still round-trips byte-for-byte.
      item_ids = @party.items.keys
      inv[11] = item_ids.size
      inv[12] = item_ids
      inv[13] = item_ids.map { |i| @party.items[i] }
      # Field 14 runs parallel to 12/13: how many uses the copy in hand has
      # already spent (Party#consume_item_use). Written for every id, zeros
      # included, so the three arrays stay the same length the way a genuine
      # save keeps them -- .from_lsd and RPG_RT alike read them by index.
      inv[14] = item_ids.map { |i| @party.item_usage[i] || 0 }
      inv[21] = @party.gold
      # liblcf's own generator/csv/fields.csv declares every one of these
      # fields (timers, battle tallies, steps) at default 0/false, and a
      # genuine kk1.12 save under wine omits all of them -- confirmed even
      # for a save taken well into a real playthrough, so #to_lsd eliding
      # only at the literal never-touched value (not "close enough to
      # start") matches. #to_lsd previously wrote every one unconditionally.
      t1, t2 = @timers[0], @timers[1]
      inv[23] = t1.frames if t1.frames != 0
      inv[24] = true if t1.running
      inv[25] = true if t1.visible
      inv[26] = true if t1.in_battle
      inv[27] = t2.frames if t2.frames != 0
      inv[28] = true if t2.running
      inv[29] = true if t2.visible
      inv[30] = true if t2.in_battle
      inv[32] = @battle_count if @battle_count != 0
      inv[33] = @defeat_count if @defeat_count != 0
      inv[34] = @escape_count if @escape_count != 0
      inv[35] = @win_count if @win_count != 0
      inv[42] = @steps if @steps != 0
      # Undefaulted, like the other counters -- absent until a battle has ever
      # finished (see #last_battle_turns).
      inv[41] = @last_battle_turns if @last_battle_turns
      save[109] = inv

      # Chunk 110 is every Set Teleport Target (11810) / Set Escape Target
      # (11830) destination registered so far -- re-confirmed against genuine
      # RPG_RT.exe under wine this cycle (not a reference implementation's
      # source, correcting a prior comment here that mislabelled that
      # reference implementation's own save-handling source as "RPG_RT's
      # live source"): eight independent synthetic-autostart wine captures,
      # none of which ever issued Set Teleport/Escape Target, all produced a
      # genuine save with chunk 110 *present*, holding exactly one entry --
      # array id 0, the escape-target slot, with every one of its own fields
      # individually absent (default-constructed/empty) since no Set Escape
      # Target had run. That is precisely this code's own existing shape:
      # array id 0 always written (fields left at their own defaults when
      # `@escape_target` is nil), followed by one entry per registered
      # teleport target keyed by its own destination map id
      # (`AddTeleportTarget`'s own `tgt.ID = map_id`) -- so this claim, unlike
      # its neighbours in chunks 102/103 below, needed no code change, only
      # this citation swap.
      targets = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_TARGET })
      esc = @escape_target
      e0 = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TARGET })
      if esc
        e0[1] = esc[:map_id]
        e0[2] = esc[:x]
        e0[3] = esc[:y]
        e0[4] = !esc[:switch_id].nil?
        e0[5] = esc[:switch_id] || 1
      end
      targets[0] = e0
      @teleport_targets.each do |map_id, t|
        e = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TARGET })
        e[1] = map_id
        e[2] = t[:x]
        e[3] = t[:y]
        e[4] = !t[:switch_id].nil?
        e[5] = t[:switch_id] || 1
        targets[map_id] = e
      end
      save[110] = targets

      # Chunk 111 (SAVE_MAP_EVENT/SAVE_MOVABLE) is the currently-loaded map's
      # own live event table, mirrored straight from #map_event_positions/
      # #map_event_route_index/#map_event_exec (the last added by cycle
      # #193, field 108 -- see its own comment), plus its Tile Substitution
      # table (#tile_substitutions, fields 21/22), a live Change Encounter
      # Rate override (#encounter_rate, field 3), a live Change Parallax
      # Background override (#parallax, fields 32-38), and the camera scroll
      # (fields 1/2) -- all scoped to the current map only, see their own
      # doc comments above. Camera scroll is the view's top-left pixel in
      # 1/16 pixel, computed the same way `Scene::Map#camera_position` does
      # every frame (`Game.camera_offset` against the hero's pixel centre and
      # the map's own size). RPG_RT restores this from the save rather than
      # deriving it from the hero -- confirmed against the genuine runtime:
      # an edited save missing these fields drew the map's top-left corner,
      # not a hero-centred view, and a correct pair reproduced the exact same
      # frame our own hero-centred renderer already draws (ADR 0021's
      # "comparing an ordinary map" addendum). Omitted entirely on a State
      # with no map loaded (e.g. a fresh, unplayed save), the same "absent
      # means nothing to restore" rule the unplaced-vehicle chunks above use.
      lower_subs, upper_subs = @tile_substitutions
      if self.map || !@map_event_positions.empty? || !@map_event_exec.empty? ||
         !lower_subs.empty? || !upper_subs.empty? || @encounter_rate || @parallax
        mapev = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MAP_EVENT })
        if self.map
          hero_px = @x * TILE + TILE / 2
          hero_py = @y * TILE + TILE / 2
          cam_x = Game.camera_offset(hero_px, SCREEN_W, self.map.width * TILE)
          cam_y = Game.camera_offset(hero_py, SCREEN_H, self.map.height * TILE)
          mapev[1] = cam_x * LCF::Schema::SCROLL_UNITS_PER_PIXEL
          mapev[2] = cam_y * LCF::Schema::SCROLL_UNITS_PER_PIXEL
        end
        # The union of #map_event_positions' and #map_event_exec's own ids:
        # in practice every map event with a live Parallel Process call-stack
        # snapshot also has a position (both are recorded every frame, by
        # #record_map_event_positions/#record_parallel_progress, for as long
        # as the event has a live Game::Character at all), but the two are
        # deliberately not assumed to stay in lockstep here -- an id present
        # in only one still gets its own entry, with just that one field set.
        unless @map_event_positions.empty? && @map_event_exec.empty?
          events = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
          ids = @map_event_positions.keys | @map_event_exec.keys
          ids.each do |id|
            e = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
            pos = @map_event_positions[id]
            if pos
              x, y, direction = pos
              e[12] = x
              e[13] = y
              e[22] = CharSet::DIR_ROW[direction] || 2
              idx = @map_event_route_index[id]
              e[43] = idx if idx
            end
            frames = @map_event_exec[id]
            e[108] = self.class.build_event_exec_state(frames) if frames && !frames.empty?
            events[id] = e
          end
          mapev[11] = events
        end
        mapev[21] = self.class.tile_replacement_bytes(lower_subs) unless lower_subs.empty?
        mapev[22] = self.class.tile_replacement_bytes(upper_subs) unless upper_subs.empty?
        mapev[3] = @encounter_rate if @encounter_rate
        if @parallax
          mapev[32] = @parallax[:name].to_s
          mapev[33] = @parallax[:loop_x]
          mapev[34] = @parallax[:loop_y]
          mapev[35] = @parallax[:auto_x]
          mapev[36] = @parallax[:sx]
          mapev[37] = @parallax[:auto_y]
          mapev[38] = @parallax[:sy]
        end
        save[111] = mapev
      end

      # Chunk 113 (SAVE_FOREGROUND_EVENT): the shared foreground
      # interpreter's own live call stack, when something is actually
      # mid-execution there at save time -- see #foreground_event_exec's own
      # comment for when that is genuinely reachable. Absent otherwise,
      # matching every other "nothing to restore" chunk in this method.
      if @foreground_event_exec && @foreground_event_exec[:frames]
        fg = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_FOREGROUND_EVENT })
        fg[1] = self.class.build_event_exec_state(@foreground_event_exec[:frames])
        save[113] = fg
      end

      # Chunk 114 (SAVE_COMMON_EVENT): one entry per currently-running Common
      # Event Parallel Process -- see #common_event_exec's own comment. A
      # genuine RPG_RT save writes one entry per common event *in the
      # database* (505 of them on a real Nepheshel capture, see
      # LCF::Schema::SAVE_COMMON_EVENT's own comment); this only ever writes
      # the ones this engine actually has live state for, since nothing here
      # ever reads the rest back and this method has no reliable way to
      # enumerate "every common event id in the database" without a `db`
      # argument it is not always given.
      running_common = @common_event_exec.select { |_, frames| frames && !frames.empty? }
      unless running_common.empty?
        ce = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_COMMON_EVENT })
        running_common.each do |id, frames|
          entry = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_COMMON_EVENT })
          entry[1] = self.class.build_event_exec_state(frames)
          ce[id] = entry
        end
        save[114] = ce
      end

      save
    end

    # Build a BGM chunk (an LCF::Array1D over the BGM schema) from our stored
    # A Tile Substitution layer's {old_id => new_id} table as real RPG_RT's
    # own SAVE_MAP_EVENT fields 21/22 store it: a 144-entry byte array where
    # index `i` is "what tile does chip `i` currently display/act as",
    # identity (`i`) everywhere untouched -- see Game::Map#substitute_tile's
    # own doc comment for why this port keeps only the diff rather than the
    # full table live.
    TILE_REPLACEMENT_SLOTS = 144
    # Class methods (not instance) so both #to_lsd (an instance method) and
    # .from_lsd (a class method, see below) can reach them.
    def self.tile_replacement_bytes(subs)
      bytes = (0...TILE_REPLACEMENT_SLOTS).to_a
      subs.each { |old_id, new_id| bytes[old_id] = new_id if old_id >= 0 && old_id < TILE_REPLACEMENT_SLOTS }
      bytes
    end

    # The inverse of .tile_replacement_bytes: every index whose stored value
    # differs from its own identity is a live substitution.
    def self.tile_replacement_hash(bytes)
      h = {}
      bytes.each_with_index { |v, i| h[i] = v if v != i }
      h
    end

    # Build a SAVE_EVENT_EXEC_STATE chunk (an LCF::Array1D) from a
    # Game::Interpreter#call_stack_snapshot-shaped `frames` array -- shared by
    # #to_lsd's chunk 113 and 114 writers above (class methods, not instance,
    # for the same reason .tile_replacement_bytes/_hash are just above: both
    # #to_lsd and .from_lsd need to reach them). `stack`'s own array ids are
    # 1-based, ascending outer to inner -- see SAVE_EVENT_EXEC_STATE's own
    # schema.rb comment on why that particular numbering, not a confirmed
    # genuine-file convention (nothing to check it against was available).
    def self.build_event_exec_state(frames)
      state = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_EVENT_EXEC_STATE })
      stack = LCF::Array2D.new('', { elements: LCF::Schema::SAVE_EVENT_EXEC_FRAME })
      frames.each_with_index do |f, i|
        frame = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_EVENT_EXEC_FRAME })
        cmds = f[:commands] || []
        # Mirrors field 2's own encoded byte length exactly, the same
        # size-field convention MAP_EVENT_PAGE's own event_command_size
        # (field 51) already established -- see that field's own comment.
        frame[1] = LCF.encode_event_commands(cmds).bytesize
        frame[2] = cmds
        frame[11] = f[:current_command] || 0
        frame[12] = f[:event_id] || 0
        frame[13] = !!f[:triggered_by_decision_key]
        stack[i + 1] = frame
      end
      state[1] = stack
      state
    end

    # The inverse of .build_event_exec_state: decode a SAVE_EVENT_EXEC_STATE
    # Array1D (chunk 113/114's own field 1) back into a
    # Game::Interpreter#call_stack_snapshot-shaped frames array, outermost
    # frame first (`stack`'s own #each already yields ascending by array id,
    # which .build_event_exec_state always writes in that same
    # outer-to-inner order). nil for an absent chunk, a stack absent/empty,
    # or one this reader cannot make sense of -- all three mean "nothing to
    # restore" to Scene::Map#restore_foreground_event_exec/#new_parallel
    # alike.
    #
    # The third case is real, not defensive-programming boilerplate: a
    # genuine kk1.12 save (scripts/gen-lcf-save-wine.bash, EasyRPG Player's
    # F9 debug-menu Save) carries a chunk 113 whose own field 1 does not
    # decode as this schema's SAVE_EVENT_EXEC_STATE at all -- `stack`'s own
    # bytes are a single 0x01, which Array2D#initialize reads as "1 row" and
    # then has nothing left to read that row's own id from, raising
    # "truncated BER integer" out of LCF.read_ber. SAVE_EVENT_EXEC_STATE's
    # own schema.rb comment already flags exactly this risk ("not confirmed
    # against a genuine multi-frame capture, since none was available"),
    # and this is that capture, not matching. Rather than guess a corrected
    # byte layout with nothing to confirm it against (the discipline every
    # other schema field here is held to -- see SAVE_DATA's own chunk
    # 112/200 comment), a malformed capture degrades the same way an absent
    # one already does: Continue starts the affected event/process fresh
    # instead of crashing outright -- confirmed against this exact kk1.12
    # save, which used to abort Game::State.from_lsd entirely and now loads
    # cleanly. Whether this is a genuine liblcf field-layout gap or an
    # artifact of EasyRPG's own F9 debug-save path (never RPG_RT.exe's own
    # Open Save Menu command, the only save-taking path this schema's own
    # field-108/113/114 comments were written against) is not yet known --
    # left for whoever gets a genuine RPG_RT.exe capture of this chunk
    # populated to compare against.
    def self.read_event_exec_frames(exec_state)
      return nil unless exec_state
      stack = exec_state.stack
      return nil unless stack
      frames = []
      stack.each do |_, frame|
        frames << {
          commands: frame.commands || [],
          current_command: frame.current_command || 0,
          event_id: frame.event_id || 0,
          triggered_by_decision_key: !!frame.triggered_by_decision_key,
        }
      end
      frames.empty? ? nil : frames
    rescue StandardError => e
      $stderr.puts "[RPG2k] Save: chunk 113/114 execution state did not " \
                   "decode (#{e.class}: #{e.message}), resuming without it"
      nil
    end

    # Build a BGM chunk (an LCF::Array1D over the BGM schema) from our stored
    # `{ name:, volume:, tempo:, balance:, fadein: }` hash: file (1), fade-in
    # (2), volume (3), pitch (4) and balance (5). Used for the system chunk's
    # current-BGM (75) and stored-BGM (78) slots, and (below) every Change
    # System BGM override slot. Balance is a first-class field of a reference
    # implementation's own BGM data structure (ported from its own play-BGM
    # command handling, round-tripped whole the same way every other field
    # here already is), NOT independently confirmed against genuine RPG_RT
    # under wine.
    #
    # Field 2 (fade_in) was entirely unwritten here until this cycle even
    # when the stored hash carried a real non-zero `:fadein` -- do_change_
    # system_bgm (interpreter.rb) has stashed a Play BGM/Change System BGM
    # command's own fade-in milliseconds on the hash since fadein first
    # landed, but this encoder silently dropped it on every Save, the exact
    # same class of gap as the picture/message fields ADR 0019 catalogues
    # elsewhere in this file. Now written on the same "elide at the schema
    # default" idiom the other fields already use.
    def bgm_chunk(bgm)
      b = LCF::Array1D.new('', { elements: LCF::Schema::BGM })
      b[1] = bgm[:name] || ''
      # Elided at their own schema default (0/100/100/50) -- confirmed
      # against a genuine kk1.12 save under wine for fields 3-5: an untouched
      # BGM record's raw bytes carried field 1 (name) alone, with fields 3-5
      # entirely absent, not present holding the default values this
      # codebase's own writer used to always emit. Field 2's own default-
      # elision is inferred from that same "write only a non-default field"
      # pattern liblcf's schema documents for every other field here, NOT
      # independently confirmed against genuine RPG_RT under wine on its own.
      fadein = bgm[:fadein] || 0
      vol = bgm[:volume] || 100
      tempo = bgm[:tempo] || 100
      bal = bgm[:balance] || 50
      b[2] = fadein if fadein != 0
      b[3] = vol if vol != 100
      b[4] = tempo if tempo != 100
      b[5] = bal if bal != 50
      b
    end

    # Build an SE chunk (an LCF::Array1D over the SE schema) from our stored
    # `{ name:, volume:, tempo:, balance: }` hash: file (1), volume (3),
    # pitch (4) and balance (5). #bgm_chunk's SE counterpart, used for every
    # Change System SFX override slot -- the same balance field #bgm_chunk's
    # own fix just above restores, and `#do_change_system_sfx`
    # (`mruby-rpg2k/mrblib/interpreter.rb`) already tracks it in-memory
    # (`balance: cmd.param(3)`), so only this save-side round-trip was
    # dropping it.
    def se_chunk(se)
      s = LCF::Array1D.new('', { elements: LCF::Schema::SE })
      s[1] = se[:name] || ''
      # Elided at default, the same as #bgm_chunk's own fields 3-5 -- see
      # that method's own citation.
      vol = se[:volume] || 100
      tempo = se[:tempo] || 100
      bal = se[:balance] || 50
      s[3] = vol if vol != 100
      s[4] = tempo if tempo != 100
      s[5] = bal if bal != 50
      s
    end

    # Change System BGM (10660) slot -> LCF::Schema::SAVE_SYSTEM field id,
    # ported from a reference implementation's own system-BGM slot enum
    # (Battle 0, Victory/BattleEnd 1, Inn 2, Boat 3, Ship 4, Airship 5,
    # GameOver 6), NOT
    # independently confirmed against genuine RPG_RT under wine, against the
    # save's title_bgm(71)/battle_bgm(72)/battle_end_bgm(73)/inn_bgm(74)/
    # current_bgm(75)/stored_bgm(78)/boat_bgm(79)/ship_bgm(80)/airship_bgm(81)/
    # gameover_bgm(82) fields. Field 71 (title_bgm) has no Change System BGM
    # slot -- RPG_RT never lets that command override the title screen's own
    # music -- so it is intentionally absent here.
    SYSTEM_BGM_SAVE_FIELD = {
      0 => 72, 1 => 73, 2 => 74, 3 => 79, 4 => 80, 5 => 81, 6 => 82
    }.freeze

    # Change System SFX (10670) slot -> LCF::Schema::SAVE_SYSTEM field id.
    # Slot N is always field 91+N -- the save's cursor_se(91)..item_se(102)
    # run keeps the exact same order as Scene::Base::DB_SE_FIELD's slots 0..11
    # (cursor, decision, cancel, buzzer, battle/escape, the six per-hit
    # sounds), just renamed and renumbered for the save chunk.
    SYSTEM_SFX_SAVE_FIELD = (0..11).each_with_object({}) { |slot, h| h[slot] = 91 + slot }.freeze

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
      # `item_usage` (chunk 109 field 14) runs parallel to the id/count arrays:
      # how many uses the copy currently in hand has already spent, so a potion
      # with 使用回数 3 that RPG_RT had used twice resumes with one use left
      # rather than three (see Party#consume_item_use).
      usage_arr = inv.item_usage || []
      usage = {}
      ids.each_index do |i|
        items[ids[i]] = counts[i] || 0
        usage[ids[i]] = usage_arr[i] if usage_arr[i] && usage_arr[i] != 0
      end
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
          # The class comes back first, mirroring Party#load_state's own
          # ordering comment: it decides which growth/EXP curves the level
          # and exp restored just below are read against. -1 (liblcf's own
          # field default) means "never changed", not "class 0" -- Change
          # Class to "no class" is itself a real, persisted change.
          cid = sa.class_id
          actor.restore_class(cid) if cid && cid != -1
          actor.set_level(sa.level) if sa.level
          actor.exp = sa.exp if sa.exp
          # A live Change Parameters edit (#change_param) -- #set_level just
          # above re-seeds @base/@base_raw from the level-derived baseline,
          # discarding it, so it's restored after, the same order the
          # Marshal-save path (Party#load_state) already uses. hp_mod/sp_mod
          # (fields 33/34) default to -1 (liblcf's own "never touched"
          # sentinel, distinct from a real 0 the other four fields already
          # use); the other four default to 0 outright. Confirmed against a
          # genuine RPG_RT.exe -- see SAVE_PARTY_ACTOR's own comment.
          hp_mod = sa.hp_mod
          sp_mod = sa.sp_mod
          mods = [hp_mod && hp_mod != -1 ? hp_mod : 0,
                  sp_mod && sp_mod != -1 ? sp_mod : 0,
                  sa.attack_mod || 0, sa.defense_mod || 0,
                  sa.spirit_mod || 0, sa.agility_mod || 0]
          if mods.any? { |m| m != 0 }
            curve = actor.base_stats(actor.level)
            actor.restore_base(Array.new(curve.size) { |i| curve[i] + mods[i] })
          end
          actor.equip(sa.equipment) if sa.equipment
          actor.skills = sa.skills if sa.skills
          # sa.states is the same dense, database-sized array #to_lsd now
          # writes (see Actor#total_state_count's own citation) -- a
          # nonzero slot means "afflicted", regardless of its actual
          # turn-counter value, which this codebase does not otherwise
          # track once a state survives past the battle that inflicted it.
          if sa.states
            ids = []
            sa.states.each_index { |i| ids << (i + 1) if sa.states[i] && sa.states[i] != 0 }
            actor.states = ids
          end
          # A live Change Battle Commands (or a Change Class, which also
          # materializes the list) -- gated on `changed_battle_commands` the
          # same way a reference implementation's own read does, not merely
          # "the field is
          # present", since an empty list is schema.rb's own declared
          # default rather than a real Change Battle Commands to nothing.
          actor.battle_commands = sa.battle_commands if sa.changed_battle_commands
          # RPG2003 battle row (0x5B/91) -- the schema default (0/front)
          # restores the same as never having touched it, so no changed-flag
          # gating is needed the way battle_commands' own nil-vs-empty
          # ambiguity requires above.
          actor.battle_row = sa.row if sa.respond_to?(:row)
          # A Change Actor Name override on *any* roster member, not just the
          # leader (whose name chunk 100's title also carries below). ADR
          # 0014 already flagged this field's other case when it was first
          # decoded: "reserve actors store only a placeholder" -- an actor
          # with no real override writes a single 0x01 byte here rather than
          # an empty string, matched against a genuine save under wine (every
          # roster actor other than the true leader carries exactly this
          # placeholder). Applying it verbatim overwrites the actor's correct
          # database name with a control character, which then defeats any
          # later lookup by name (see the title-chunk leader fixup below).
          nm = sa.actor_name
          actor.name = nm if nm && !nm.empty? && nm != "\x01"
          # Field 2 (title) has no equivalent "blank means unchanged" rule --
          # do_change_actor_title explicitly lets an empty string *clear* the
          # title -- so an empty string is applied, unlike actor_name above;
          # only the reserve-actor placeholder byte is skipped.
          tt = sa.title
          actor.title = tt if tt && tt != "\x01"
          # A live Change Sprite Association override (chunk 108 fields
          # 11/12/13) -- what genuine RPG_RT.exe itself restores the on-map
          # sprite from, not chunk 104's hero-record mirror (fields 73/74,
          # never read back -- see #to_lsd's own citation and
          # SAVE_PARTY_ACTOR's schema.rb comment for cycle #170's wine
          # verification of both halves of this). Gated on sprite_name's own
          # presence, the same "the command actually ran" signal #to_lsd
          # writes it under; an absent field leaves the actor's own database
          # default charset (#initialize) untouched.
          sn = sa.sprite_name
          actor.set_charset(sn, sa.sprite_id || 0) if sn
          actor.transparent = (sa.sprite_transparent || 0) != 0 if sn
        end
        hp[aid] = sa.hp if sa.hp
        mp[aid] = sa.mp if sa.mp
      end
      party.load_state(items: items, item_usage: usage, gold: inv.gold,
                       hp: hp, mp: mp)
      state = new(party, hero.map_id, hero.x, hero.y)
      # liblcf's own 0..3 (up/right/down/left) convention on the wire; see
      # #to_lsd's own citation for why this needs the same conversion
      # EventGraphic::LCF_DIR_TO_NUMPAD already applies to the identically-
      # encoded database-side event-page facing field.
      state.direction = EventGraphic.numpad_direction(hero.direction)
      # Set Transparent Flag's own override (Player Visibility, 11310):
      # liblcf's "0 or 3" convention on the hero's own movable record (see
      # #to_lsd's own citation on why this lives here, not the system chunk).
      state.player_transparent = (hero.transparency || 0) != 0
      # Fields 81-85 (flash_red/_green/_blue/_current_level/_time_left): see
      # #to_lsd's own citation. A flash is only "live" once time_left is
      # actually present and positive -- the RGB triple alone (0 or a stale
      # colour) carries no flash of its own without it. `power` is
      # recovered from `current_level` at its own peak strength (frames ==
      # total, the instant it starts) since liblcf has no separate field for
      # the original peak; a save resumed mid-decay therefore restarts that
      # decay from its own already-decayed current level, one frame short of
      # exactly reproducing genuine RPG_RT's own remaining fade -- close
      # enough that the visual difference is a single frame, not a
      # citation this codebase can make stronger without a wine capture of
      # an actual in-progress flash to compare against.
      if hero.flash_time_left && hero.flash_time_left > 0
        frames = hero.flash_time_left
        level = hero.flash_current_level || 0.0
        state.player_flash = { red: hero.flash_red || 0, green: hero.flash_green || 0,
                               blue: hero.flash_blue || 0, power: level.round, frames: frames,
                               total: frames }
      end
      # Fields 32/41/43/51 (move_frequency/move_route/move_route_index/
      # through): see #to_lsd's own citation. A route is only "live" once
      # field 41 is actually present with at least one command -- an absent
      # chunk (or one with zero commands, which #to_lsd never itself
      # writes) leaves the hero walking freely.
      route = hero.move_route
      if route && route.commands && !route.commands.empty?
        state.player_route = { commands: route.commands, repeat: route.repeat ? true : false,
                               skippable: route.skippable ? true : false,
                               index: hero.move_route_index, frequency: hero.move_frequency }
      end
      state.player_through = (hero.through || false) ? true : false
      # Vehicle locations (chunks 105 boat / 106 ship / 107 airship), each a
      # SAVE_MOVABLE; an absent chunk leaves that vehicle unplaced.
      state.vehicle(:boat).load_movable(save.boat)
      state.vehicle(:ship).load_movable(save.ship)
      state.vehicle(:airship).load_movable(save.airship)
      # Chunk 110 (SAVE_TARGET): every Set Teleport Target/Set Escape Target
      # destination, the same shape #to_lsd writes -- see that method's own
      # citation. Array id 0 is always the escape slot (RPG_RT's own
      # save-data convention); `map_id` absent/0 there
      # means "never set" (matching a default-constructed `SaveTarget`, the
      # same sentinel real RPG_RT itself carries when Set Escape Target was
      # never run). Every other id is a teleport target keyed by its own
      # destination map id.
      targets = save[110]
      if targets
        esc = targets[0]
        if esc && esc.map_id && esc.map_id != 0
          state.escape_target = { map_id: esc.map_id, x: esc.x || 0, y: esc.y || 0,
                                  switch_id: esc.switch_on ? esc.switch_id : nil }
        end
        targets.each do |id, t|
          next if id == 0 || t.map_id.nil?
          state.teleport_targets[t.map_id] =
            { x: t.x || 0, y: t.y || 0, switch_id: t.switch_on ? t.switch_id : nil }
        end
      end
      # A live Change Sprite Association override is restored per-actor above,
      # from chunk 108's own sprite_name/sprite_id/sprite_transparent fields
      # (not chunk 104's hero-record mirror, fields 73/74 -- see #to_lsd's own
      # citation and SAVE_PARTY_ACTOR's schema.rb comment for why).
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
      # An absent field 61 (the schema's own default) means "not stopping",
      # matching a genuine save that never wrote the field at all -- see
      # SAVE_SYSTEM's own comment in schema.rb.
      state.bgm_stopping = sys.bgm_stopping ? true : false
      # Overridden BGM playback state; an empty file name means "none".
      state.current_bgm = bgm_from_chunk(sys.current_bgm)
      state.memorized_bgm = bgm_from_chunk(sys.stored_bgm)
      # The vehicle/battle BGM restore point -- "(OFF)" (RPG_RT's own
      # placeholder, see #to_lsd's own citation) reads back as nil, the same
      # as an empty file name, via #bgm_from_chunk's own sentinel handling.
      state.pre_vehicle_bgm = bgm_from_chunk(sys.before_vehicle_music)
      state.pre_battle_bgm = bgm_from_chunk(sys.before_battle_music)
      # Change System BGM (10660) / Change System SFX (10670) overrides, read
      # back by the same slot -> field map #to_lsd wrote them with. A slot the
      # save left un-overridden is simply absent from the hash, matching
      # do_change_system_bgm/_sfx's own "unset slot" state.
      system_bgm = {}
      SYSTEM_BGM_SAVE_FIELD.each do |slot, field|
        bgm = bgm_from_chunk(sys[field])
        system_bgm[slot] = bgm if bgm
      end
      state.system_bgm = system_bgm
      system_sfx = {}
      SYSTEM_SFX_SAVE_FIELD.each do |slot, field|
        se = se_from_chunk(sys[field])
        system_sfx[slot] = se if se
      end
      state.system_sfx = system_sfx
      # Access flags: only an explicitly-stored value overrides the constructor
      # default (so a foreign save that omits them keeps our defaults).
      state.teleport_access = sys.teleport_allowed unless sys.teleport_allowed.nil?
      state.escape_access = sys.escape_allowed unless sys.escape_allowed.nil?
      state.save_access = sys.save_allowed unless sys.save_allowed.nil?
      state.menu_access = sys.menu_allowed unless sys.menu_allowed.nil?
      # How many times the menu's Save command has been used (RPG_RT increments
      # this on every save; see #to_lsd's sys[131] write above).
      state.save_count = sys.save_count unless sys.save_count.nil?
      # The carried battle background (field 125). Read unconditionally, an
      # absent chunk included: an absent field is RPG_RT's own empty default,
      # which draws the flat black field rather than falling back to a
      # map-tree walk -- see #battle_background's own citation for the wine
      # captures this was measured from.
      state.battle_background = sys.battle_background.to_s
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
      # RPG2003's wait/active toggle. The chunk's own default is 0 (wait), so
      # an absent chunk (RPG2000 saves, or a wait-mode 2003 save) reads wait.
      state.atb_mode = sys.atb_mode || 0
      # The leader's display name from the file-screen title chunk. This used
      # to be treated as always redundant with chunk 109's own party list
      # (field 1: "both hold the same live name in a genuine save"), so a
      # mismatch was "fixed" by just relabelling whoever chunk 109 put first
      # -- right name, wrong actor underneath. Verified wrong under wine
      # against a genuine RPG_RT.exe on a real Nepheshel save: chunk 109's
      # party list names actor 1 ("リト"), but RPG_RT's own menu shows actor
      # 15 ("デモ用", level 50/600HP) throughout, matching the title chunk's
      # hero_name/hero_level/hero_hp exactly. Chunk 108 already instantiated
      # every actor id the save mentions (the loop above), so when the names
      # disagree the real leader can be found in the roster by the title's
      # cached name and promoted, rather than cosmetically relabelled.
      title = save[100]
      if title && party.leader
        nm = title.hero_name
        if nm && !nm.empty? && nm != party.leader.name
          real_leader = party.roster.all.find { |a| a.name == nm }
          if real_leader
            party.promote_to_leader(real_leader)
          else
            party.leader.name = nm
          end
        end
      end
      if title
        # The file-select screen's own face-thumbnail snapshot -- see
        # State#preview_faces. Read straight off the title chunk's four
        # name/index pairs, each skipped (nil) when its name is blank (an
        # unfilled slot, e.g. a save written by tooling -- a reference
        # implementation's own debug-menu save feature -- that never
        # populates them), the same "blank
        # name -> no face" rule Scene::SaveLoad#draw_slot_faces already
        # applies elsewhere.
        faces = [[title.face1_name, title.face1_index],
                 [title.face2_name, title.face2_index],
                 [title.face3_name, title.face3_index],
                 [title.face4_name, title.face4_index]].map do |name, index|
          name && !name.empty? ? [name, index] : nil
        end
        state.preview_faces = faces if faces.any?
        # The level/HP pair the file-select screen actually draws -- see
        # State#preview_level/#preview_hp. Independently nil-checked (unlike
        # the name promotion above, which already guarantees party.leader.name
        # matches title.hero_name one way or another) because there is no
        # equivalent stat-sync step for level/hp: the promoted leader's own
        # chunk-108 entry happens to agree in every genuine save this codebase
        # has seen, but RPG_RT itself never reads that entry for this screen
        # at all, so this build should not either.
        state.preview_level = title.hero_level unless title.hero_level.nil?
        state.preview_hp = title.hero_hp unless title.hero_hp.nil?
      end
      # Chunk 102 is the screen tint transition; only #restore_tint's tint
      # sub-fields are modelled here (see #to_lsd's own comment on chunk 102
      # for why, including why the chunk itself is present unconditionally
      # -- cycle #154). An absent chunk (a save written before this fix, or
      # by anything else that omits it outright) leaves the fresh
      # `Screen.new` neutral defaults in place, the same as a present chunk
      # whose own tint fields are all individually absent at their own
      # SAVE_SCREEN defaults.
      scr = save[102]
      if scr
        state.screen.restore_tint([scr.tint_finish_red, scr.tint_finish_green,
                                    scr.tint_finish_blue, scr.tint_finish_sat],
                                   [scr.tint_current_red, scr.tint_current_green,
                                    scr.tint_current_blue, scr.tint_current_sat],
                                   scr.tint_time_left)
        # The live Pan Screen offset (fields 41/42) -- a genuine save never
        # carries a separate in-flight target, so this restores at rest
        # (current == target), the same idle-sync convention already used
        # for tint/pictures elsewhere in this method.
        px = scr.pan_x || 0
        py = scr.pan_y || 0
        state.screen.load_h(pan_x: px, pan_y: py, pan_tx: px, pan_ty: py)
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
      # Step counter and battle win/defeat/escape/victory tallies (inventory
      # chunk 109 fields 32-35/42); a save written before this landed simply
      # omits them, leaving the fresh State's zeroed defaults in place.
      state.battle_count = inv.battles unless inv.battles.nil?
      state.defeat_count = inv.defeats unless inv.defeats.nil?
      state.escape_count = inv.escapes unless inv.escapes.nil?
      state.win_count = inv.victories unless inv.victories.nil?
      state.steps = inv.steps unless inv.steps.nil?
      # "Turns passed in latest battle" (field 41); absent on a save written
      # before this landed, or one taken before any battle ever finished.
      state.last_battle_turns = inv.turns unless inv.turns.nil?
      # The currently-loaded map's own live event table (chunk 111,
      # #to_lsd's write above): position/facing into #map_event_positions, a
      # page's custom-route cursor (field 43) into #map_event_route_index,
      # and (cycle #193) a map event's own Parallel Process call-stack
      # snapshot (field 108, SAVE_EVENT_EXEC_STATE) into #map_event_exec --
      # see that attribute's own comment. An absent chunk (a save written
      # before this landed, or a state that never recorded any positions)
      # leaves the constructor's empty {} defaults in place; an entry with no
      # field 43 restores its position but nothing for
      # #map_event_route_index, matching build_event's existing "no saved
      # index means start the custom route from the top" fallback; an entry
      # with no field 108 (the overwhelming majority -- most map events run
      # no Parallel Process at all) simply gets no #map_event_exec entry,
      # matching #new_parallel's own "nothing to restore" fallback to a
      # fresh start. Field 108 is read independently of whether `mv.x`/`mv.y`
      # are present, unlike positions/route_index just below -- see
      # #map_event_exec's own comment on why the two are not assumed to
      # always co-occur.
      map_events = save[111]
      saved_events = map_events && map_events.events
      if saved_events
        positions = {}
        route_index = {}
        exec_snapshots = {}
        saved_events.each do |id, mv|
          if mv.x && mv.y
            positions[id] = [mv.x, mv.y, EventGraphic.numpad_direction(mv.direction)]
            idx = mv.move_route_index
            route_index[id] = idx unless idx.nil?
          end
          frames = read_event_exec_frames(mv.parallel_event_execstate)
          exec_snapshots[id] = frames if frames
        end
        state.map_event_positions = positions
        state.map_event_route_index = route_index
        state.map_event_exec = exec_snapshots
      end
      # The same chunk's Tile Substitution table (fields 21/22): absent on a
      # save that never rewrote a tile, or one written before this landed.
      if map_events
        lower = map_events.chip_replacement_lower
        upper = map_events.chip_replacement_upper
        state.tile_substitutions = [
          lower ? tile_replacement_hash(lower) : {},
          upper ? tile_replacement_hash(upper) : {},
        ]
      end
      # The same chunk's own Change Encounter Rate override (field 3): -1 (its
      # schema default, matching liblcf's own `SaveMapInfo.encounter_steps`)
      # or absent both mean "no override, use the map's own rate", the same
      # `nil` #encounter_rate already means live -- see
      # Scene::Map#current_encounter_steps.
      steps = map_events && map_events.encounter_steps
      state.encounter_rate = steps if steps && steps >= 0
      # The same chunk's own Change Parallax Background override (fields
      # 32-38): a blank/absent name means "no override, use the map's own
      # panorama" -- matching a reference implementation's own blank-name
      # check (ported from that source, NOT
      # independently confirmed against genuine RPG_RT under wine), which
      # that implementation
      # itself cannot distinguish from "never overridden" either (its own
      # map-change handling writes a default-constructed, empty-name struct).
      pname = map_events && map_events.parallax_name
      if pname && !pname.empty?
        state.set_parallax(name: pname, loop_x: !!map_events.parallax_horz,
                           loop_y: !!map_events.parallax_vert,
                           auto_x: !!map_events.parallax_horz_auto,
                           sx: map_events.parallax_horz_speed,
                           auto_y: !!map_events.parallax_vert_auto,
                           sy: map_events.parallax_vert_speed)
      end
      # Chunk 113 (SAVE_FOREGROUND_EVENT): whatever event was mid-execution
      # in the shared foreground interpreter at save time -- see
      # #foreground_event_exec's own comment for when a genuine save
      # actually carries one. Absent on the overwhelming majority of saves
      # (nothing to restore, matching every save taken between events), and
      # on any save written before cycle #191. Consumed once, at Continue
      # time, by Scene::Map#restore_foreground_event_exec -- this method
      # itself only decodes the chunk onto Game::State, it does not touch a
      # live interpreter (there is none to touch here).
      fg_state = save[113] && save[113].execution_state
      fg_frames = read_event_exec_frames(fg_state)
      state.foreground_event_exec = fg_frames && { event_id: fg_frames.first[:event_id], frames: fg_frames }
      # Chunk 114 (SAVE_COMMON_EVENT): one entry per currently-running Common
      # Event Parallel Process -- see #common_event_exec's own comment.
      # Absent, or missing individual ids, on a save written before cycle
      # #191; Scene::Map#new_parallel falls back to #common_event_progress
      # (or a fresh #start) for any id this does not cover.
      common_events = save[114]
      if common_events
        common_events.each do |id, entry|
          frames = read_event_exec_frames(entry.execution_state)
          state.common_event_exec[id] = frames if frames
        end
      end
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
    # Zoom (field 33), transparency (34) and tone (41-44) are now restored too,
    # not just the name and centre position. The earlier version left these at
    # Picture's defaults, reasoning that with no sample save pinning a picture
    # off its defaults, wiring them would be guesswork -- but the schema's own
    # field names (rpg2kpsp: 拡大率/透明度/色調, "zoom rate/transparency/tone")
    # already match Show Picture's own param5/param6/param8-11 one for one (see
    # #do_show_picture), and that live path is exercised and tested elsewhere in
    # this codebase: zoom is a raw percentage fed straight into Picture#zoom
    # (default 100), tone is raw ints fed straight into Picture's red/green/
    # blue/saturation (default 100, neutral), and transparency is the same
    # 0 (opaque) .. 100 (clear) scale #trans_to_opacity already converts to a
    # 0..255 opacity for the live command. There is nothing save-format-specific
    # left to guess: the save's fields and the command's params are the same
    # numbers, so they are read the same way here.
    #
    # A picture still mid-Move-Picture when the save was written (time_left,
    # field 51, > 0) is shown at its genuinely live current_*/current_x/y
    # (fields 4/5/7/8/11-14) instead of its finish_*/31/32/etc, then
    # immediately started moving again toward finish_*/31/32/etc over the
    # saved time_left frames -- confirmed against a genuine RPG_RT.exe: a
    # save edited with current and finish deliberately different, resumed
    # under the real runtime, visibly kept gliding from the saved current
    # position toward the saved finish one rather than sitting statically at
    # either. See SAVE_PICTURE's own comment for the field-mapping evidence.
    # `pic.time_left`/`current_*` both default to 0/the same neutral values a
    # fresh `Game::Picture` starts at, so a save written before this landed
    # (missing all of fields 4/5/7/8/11-14/51) reads time_left as 0 and
    # restores identically to before -- unaffected by this change.
    #
    # Field 2/3 (show_x/show_y, see SAVE_PICTURE's own comment for how cycle
    # #155 identified them) are passed through explicitly rather than via
    # `Game::Picture.new`'s own "defaults to the shown position" fallback --
    # `pic.key?` (not `pic.show_x` alone) gates it, since the schema default
    # of 0.0 would otherwise look like a real, present value of (0,0) for a
    # save written before this field was modelled, wrongly overriding the
    # fallback for exactly the legacy saves it exists to cover.
    def self.restore_pictures(state, pictures)
      return unless pictures
      pictures.each do |id, pic|
        next unless pic
        name = pic.name
        # A blank name means either "never shown" (a fully field-less
        # placeholder -- see SAVE_PICTURE's own comment) or "shown, then
        # Erase Picture'd" (every position/zoom/tone field still present,
        # only the name dropped -- confirmed against genuine RPG_RT.exe,
        # cycle #159). `#key?(4)` (current_x) tells the two apart: it is
        # written unconditionally for any id ever shown at all, and only
        # for one, so its presence is exactly "this id has stale state to
        # keep" -- a never-touched id is truly empty and must stay skipped.
        # Reconstructing the erased case (rather than dropping it, this
        # method's own prior behavior) matters for round-trip stability:
        # this engine's own live Show Picture -> Erase Picture -> Save
        # already keeps these fields through `#to_lsd` (see
        # `Game::State#erase_picture`'s own comment), so a save loaded with
        # an id already in that state must carry it into *this* Continue's
        # own eventual next save too, the same way genuine RPG_RT keeps
        # rewriting the identical stale bytes indefinitely -- not silently
        # revert to a blank placeholder after a single load/save cycle.
        if name.nil? || name.empty?
          next unless pic.key?(4)
          name = ''
        end
        time_left = pic.time_left || 0
        moving = time_left > 0
        transparency = moving ? pic.current_transparency : pic.transparency
        state.show_picture(id, name: name,
                               x: ((moving ? pic.current_x : pic.finish_x) || 0).to_i,
                               y: ((moving ? pic.current_y : pic.finish_y) || 0).to_i,
                               show_x: pic.key?(2) ? pic.show_x : nil,
                               show_y: pic.key?(3) ? pic.show_y : nil,
                               zoom: moving ? pic.current_zoom : pic.zoom,
                               opacity: transparency ? Game.trans_to_opacity(transparency) : nil,
                               red: moving ? pic.current_tone_red : pic.tone_red,
                               green: moving ? pic.current_tone_green : pic.tone_green,
                               blue: moving ? pic.current_tone_blue : pic.tone_blue,
                               saturation: moving ? pic.current_tone_saturation : pic.tone_saturation,
                               fixed_to_map: pic.fixed_to_map,
                               use_transparent_color: pic.use_transparent_color)
        state.erase_picture(id) if pic.name.nil? || pic.name.empty?
        next unless moving
        finish_trans = pic.transparency
        state.move_picture(id, (pic.finish_x || 0).to_i, (pic.finish_y || 0).to_i,
                           pic.zoom,
                           finish_trans ? Game.trans_to_opacity(finish_trans) : 255,
                           pic.tone_red, pic.tone_green, pic.tone_blue,
                           pic.tone_saturation, time_left)
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

    # Rebuild our `{ name:, volume:, tempo:, balance: }` BGM hash from a
    # parsed BGM chunk (an LCF::Array1D over the BGM schema). Returns nil for
    # an absent chunk, an empty file name (the "use the database value"
    # sentinel), or the literal file name "(OFF)" -- liblcf's own Music-struct
    # schema default, and RPG_RT's own "play nothing" placeholder wherever a
    # BGM slot is left unset (#play_bgm_or_stop's own comment already
    # documents this same literal for live playback; a save round-trip
    # carries the identical sentinel and needs the same treatment, or an
    # editor-set-to-"(OFF)" override, or a before_vehicle_music/
    # before_battle_music restore point with nothing to restore, would
    # decode as a real request to play a file literally named "(OFF)").
    def self.bgm_from_chunk(chunk)
      return nil unless chunk
      name = chunk.file
      return nil if name.nil? || name.empty? || name == '(OFF)'
      { name: name, volume: chunk.volume || 100, tempo: chunk.pitch || 100,
        balance: chunk.balance || 50, fadein: chunk.fade_in || 0 }
    end

    # #bgm_from_chunk's SE counterpart: rebuild our `{ name:, volume:, tempo: }`
    # SE hash from a parsed SE chunk (an LCF::Array1D over the SE schema).
    def self.se_from_chunk(chunk)
      return nil unless chunk
      name = chunk.file
      return nil if name.nil? || name.empty?
      { name: name, volume: chunk.volume || 100, tempo: chunk.pitch || 100,
        balance: chunk.balance || 50 }
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
      state.pre_vehicle_bgm = h[:pre_vehicle_bgm]
      state.pre_battle_bgm = h[:pre_battle_bgm]
      state.player_flash = h[:player_flash]
      state.player_route = h[:player_route]
      state.player_through = h[:player_through] ? true : false
      state.player_transparent = h[:player_transparent] ? true : false
      state.weather.load_h(h[:weather])
      state.screen.load_h(h[:screen])
      # A save written before this existed carries no `pictures` key at all
      # (nil), restoring the pre-fix "no pictures shown" behaviour rather
      # than raising on a missing hash.
      (h[:pictures] || {}).each do |id, ph|
        pic = Picture.from_h(id, ph)
        state.pictures[id] = pic if pic
      end
      # Cycle #162: these two used to coerce a missing key straight to false
      # (`h[:teleport_access] ? true : false`) instead of falling back to the
      # constructor default the way `#menu_access`/`#save_access` just above
      # do -- harmless while the constructor default was itself false, but
      # wrong now that it is true (see `Game::State#initialize`'s own
      # comment): a quicksave written before these two keys existed should
      # resume with Teleport/Escape allowed, the same "defaults on" fallback
      # `#menu_access`/`#save_access` already give an older save.
      state.teleport_access = h[:teleport_access] unless h[:teleport_access].nil?
      state.escape_access = h[:escape_access] unless h[:escape_access].nil?
      # Registries default empty / unset; a save written before these existed
      # simply restores nothing.
      state.encounter_rate = h[:encounter_rate]
      state.encounter_total = h[:encounter_total] || 0
      state.steps = h[:steps] || 0
      state.last_battle_turns = h[:last_battle_turns]
      state.save_count = h[:save_count] || 0
      state.battle_count = h[:battle_count] || 0
      state.win_count = h[:win_count] || 0
      state.defeat_count = h[:defeat_count] || 0
      state.escape_count = h[:escape_count] || 0
      state.teleport_targets = h[:teleport_targets] || {}
      state.common_event_progress = h[:common_event_progress] || {}
      state.map_event_positions = h[:map_event_positions] || {}
      state.map_event_route_index = h[:map_event_route_index] || {}
      state.tile_substitutions = h[:tile_substitutions] || [{}, {}]
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
