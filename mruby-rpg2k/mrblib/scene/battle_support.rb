# Battle-only Scene::Base helpers dropped from mrblib/scene/base.rb: wio's
# own battle exclusion (mruby-rpg2k/mrbgem.rake) left these dead the same
# way mrblib/game/battle_support.rb's own header explains -- every one of
# them is called only from mrblib/scene/battle.rb (dropped for wio) or, for
# the word-wrap helpers, mrblib/scene/map_viewer.rb / chipset_editor.rb
# (dropped since ADR 0097). `Dir.glob(...).sort` loads this after
# mrblib/scene/base.rb regardless of target (`scene/base.rb` <
# `scene/battle_support.rb` lexically), so `class Base` already exists by
# the time this file's own reopen runs. See
# docs/adr/0124-rpg2k-battle-only-helpers-trim.md.

class RPG2k
  module Scene
    class Base
      # One frame of the shared blink phase, and whether that phase is "on".
      def advance_list_arrow_anim(anim)
        ((anim || 0) + 1) % (LIST_ARROW_BLINK_FRAMES * 2)
      end

      def list_arrow_blink_on?(anim)
        (anim || 0) < LIST_ARROW_BLINK_FRAMES
      end

      # The top row a scrolling list shows, given the one it *already* showed
      # (`top`) and where the cursor now is. RPG_RT's scroll offset is
      # **sticky**: it keeps whatever offset it had and moves by the smallest
      # amount that brings the cursor's row back into the box, rather than
      # deriving the offset from the cursor row afresh. Confirmed against
      # genuine RPG_RT.exe under wine (cycle #249) on the in-battle Skill and
      # Item lists (26 skills / 27 items, four visible rows): four Downs from
      # the top scrolled the box to top row 1, and an Up from there left the
      # top row exactly where it was (the cursor moved up inside the box
      # instead of the box moving back), on both lists; the same held on the
      # way down from the bottom (top row 9 with the cursor walked back up to
      # row 10, where a cursor-derived offset would have shown row 7 first).
      # A cursor-derived offset would have scrolled back on every one of
      # those steps. The field Item and Skill grids were re-confirmed to do
      # the same thing on the same captures' recipe, which is what they
      # already implemented.
      def sticky_list_top(top, sel_row, row_count, visible_rows)
        max_top = [row_count - visible_rows, 0].max
        top = 0 if top.nil? || top.negative?
        top = max_top if top > max_top
        top = sel_row if sel_row < top
        top = sel_row - visible_rows + 1 if sel_row >= top + visible_rows
        top.negative? ? 0 : top
      end

      # Greedily packs `text`'s whitespace-separated words into as many lines
      # as it takes to each fit within `w` px (measured via #text_size, the
      # current font) -- unlike #clip_text_to_width above, which drops
      # whatever doesn't fit, this keeps every word by wrapping onto the next
      # line instead. Written for the debug editors' key-binding hint lines
      # (Scene::MapViewer, Scene::ChipsetEditor): a single #draw_text call
      # neither wraps nor clips its own text (see #clip_text_to_width's own
      # comment), so a hint longer than one line's width used to run straight
      # off the bitmap's right edge and simply vanish there instead of
      # appearing at all. A single over-wide word (wider than `w` on its own)
      # still overflows its line -- this only ever breaks *between* words.
      def wrap_text_to_width(c, text, w)
        lines = []
        line = ''
        text.split(' ').each do |word|
          candidate = line.empty? ? word : "#{line} #{word}"
          if !line.empty? && c.text_size(candidate).width > w
            lines << line
            line = word
          else
            line = candidate
          end
        end
        lines << line unless line.empty?
        lines
      end

      # Draws `text` word-wrapped to `@contents`' own width (see
      # #wrap_text_to_width), one #draw_text call per line, each `line_h` px
      # apart starting at `y`.
      def draw_wrapped_hint(text, y, line_h)
        wrap_text_to_width(@contents, text, @contents.width).each_with_index do |line, i|
          @contents.draw_text 0, y + i * line_h, @contents.width, line_h, line
        end
      end

      # The screen size the native host actually configured (src/main.cxx sets
      # RPG2K_SCREEN_WIDTH/HEIGHT from the finalized --width/--height once the
      # XP/VX auto-detect override, if any, is resolved), never smaller than
      # RPG2000/2003's own fixed 320x240. Real gameplay scenes (Scene::Map and
      # everything built on top of it) must stay at that fixed resolution to
      # reproduce RPG_RT's own rendering -- they use RPG2k::WIDTH/HEIGHT
      # directly and always will -- but a debug-only authoring tool like
      # Scene::MapViewer has no such fidelity to protect, so there's no reason
      # for it to sit in a small corner of a window the user explicitly asked
      # to be bigger. Guarded the same way RPG2k#map_editor? is (see its own
      # comment): the CRuby-only host harnesses that load this file never
      # define RPG2K_SCREEN_WIDTH/HEIGHT, so an undefined reference here just
      # falls back to the fixed resolution, leaving every existing check's
      # behaviour unchanged.
      def screen_width
        [RPG2K_SCREEN_WIDTH, RPG2k::WIDTH].max
      rescue NameError
        RPG2k::WIDTH
      end

      def screen_height
        [RPG2K_SCREEN_HEIGHT, RPG2k::HEIGHT].max
      rescue NameError
        RPG2k::HEIGHT
      end

    end
  end
end
