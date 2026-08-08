class RPG2k
  module Scene
    class Base
      def initialize parent
        @parent = parent
        @db = parent.db
        @map_tree = parent.map_tree
      end
      def update ; end
      def dispose ; end

      attr_reader :parent, :db, :map_tree

      # Load the System/ windowskin declared in the database (nil when missing,
      # so Window falls back to a plain panel). Colour-keyed, matching the map
      # and title scenes' own loads of the same file: the skin's palette entry 0
      # is transparent, and every menu built on this would otherwise draw the
      # cursor and frame corners on opaque blocks.
      def make_windowskin
        name = @db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      # Draw `text` the way RPG_RT draws every piece of window text: a shadow
      # glyph one pixel down and right filled from the System image's shadow
      # block, then the glyph itself filled from colour `idx`'s 16x16 swatch, so
      # the text carries the windowskin's own gradient. Falls back to the flat
      # font colour when there is no windowskin (or the colour index is out of
      # range), which is all `draw_text` can do.
      def draw_system_text(bmp, x, y, w, h, text, skin, idx = 0, align = 0)
        unless skin && Game::MessagePalette.valid?(idx)
          bmp.draw_text x, y, w, h, text, align
          return
        end
        cell = Game::MessagePalette::CELL
        off = Game::MessagePalette::SHADOW_OFFSET
        shx, shy = Game::MessagePalette.shadow_origin
        bmp.blend_text x + off, y + off, w, h, text, skin, shx, shy, cell, cell,
                       align
        sx, sy = Game::MessagePalette.cell_origin(idx)
        bmp.blend_text x, y, w, h, text, skin, sx, sy, cell, cell, align
      end

      # The condition a battler carrying `states` shows, as [text, palette colour
      # index]: the significant state's name in its own colour, or the database's
      # "normal" term when there is none. A state the database does not name
      # falls back to its id, so an unnamed one still reads as *something* rather
      # than silently as normal.
      #
      # The single place the state table's display side is read, so the battle
      # status panel (which lays its own columns out and needs the pieces) and
      # the field windows (which draw straight) cannot drift apart.
      # The database's status-condition table (the `situation` array), or nil for
      # a scene built on a fixture database that has none.
      def state_table
        db.respond_to?(:situation) ? db.situation : nil
      end

      def state_display(states)
        table = state_table
        id = Game::States.significant(states, table)
        return [normal_status_term, 0] unless id
        [Game::States.name(id, table) || "state #{id}",
         Game::States.color(id, table)]
      end

      # Draw an actor's condition, as RPG_RT does in every field window that
      # shows one — the menu party list, the item / skill target list and the
      # status screen (EasyRPG's Window_Base#DrawActorState).
      def draw_actor_state(bmp, actor, x, y, w, h, skin, align = 0)
        text, color = state_display(actor.states)
        draw_system_text bmp, x, y, w, h, text, skin, color, align
      end

      # The database's word for "no condition" (RPG_RT shows it rather than
      # leaving the column blank), or a plain English stand-in for a database
      # that leaves the term unset.
      def normal_status_term
        t = db.respond_to?(:term) ? db.term : nil
        s = t && t.respond_to?(:normal_status) ? t.normal_status : nil
        s.nil? || s.to_s.empty? ? 'Normal' : s
      end
    end

    # Adapter that exposes the running map to the movement engine
    # (Game::MoveRoute / Game::MoveType). It bridges their small `world` protocol
    # — passability, hero position, switch and sound side effects, randomness —
    # onto the owning Scene::Map and its Game::State.
    class MapWorld
      def initialize(scene, rng)
        @scene = scene
        @rng = rng
      end

      def passable?(character, dir)
        @scene.char_passable?(character, dir)
      end

      # Whether a jump may land on (x, y) — only the destination is tested, the
      # tiles crossed on the way are not (see Game::MoveRoute#do_jump).
      def can_land?(character, x, y)
        @scene.char_can_land?(character, x, y)
      end

      def hero_position
        s = @scene.state
        [s.x, s.y]
      end

      def set_switch(id, on)
        @scene.state.switches[id] = on
      end

      def play_sound(name, volume, tempo, _balance)
        return if name.nil? || name.empty?
        RGSS::Audio.se_play(name, volume, tempo)
      rescue StandardError => e
        $stderr.puts "[RPG2k] event SE '#{name}' playback failed: #{e.message}"
        nil
      end

      def random(n)
        @rng.random(n)
      end
    end

    # Resolves the command list a Call Event refers to. Common events are looked
    # up by id; a map event's page is fetched from the loaded map unit (best
    # effort — the page index follows the LCF page numbering).
    class EventResolver
      def initialize(common_by_id, map_events)
        @common = common_by_id || {}
        @map_events = map_events || {}
      end

      def common_event_commands(id)
        @common[id]
      end

      def map_event_commands(id, page_index)
        ev = @map_events[id]
        return nil unless ev
        pages = ev.pages
        return nil unless pages
        page = pages[page_index]
        page && page.event_commands
      rescue StandardError
        nil
      end
    end

  end
end
