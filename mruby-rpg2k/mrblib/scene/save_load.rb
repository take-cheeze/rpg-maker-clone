class RPG2k
  module Scene
    # RPG2000's save-select screen: a scrollable list of the MAX_SAVE_SLOTS
    # file slots, each its own bordered box (not rows in one shared list
    # window) showing the party leader, level and HP when the slot holds a
    # save, or just the file label when it does not -- confirmed against
    # genuine RPG_RT under wine (see VISIBLE_SLOTS/SLOT_BOX_H below for the
    # specifics this ports). Pushed in two shapes:
    #
    #   * `:save`, from Scene::Menu's Save command, with the running
    #     Game::State to write out. Every slot -- occupied or not -- is
    #     selectable; confirming one calls RPG2k#save_game(state, slot) and
    #     pops straight back to the menu the same frame, no feedback of any
    #     kind either way -- independently confirmed against a genuine
    #     RPG_RT.exe under wine (cycle #126, see #confirm_selection's own
    #     fuller writeup below), not just EasyRPG's `Scene_Save::Action`
    #     (`src/scene_save.cpp`), which discards `Save`'s own boolean result
    #     outright.
    #   * `:load`, from Scene::Title's Continue entry, with `state` nil (there
    #     is no running game yet). Only an occupied slot is selectable;
    #     confirming one calls RPG2k#continue_game(slot), which tears down the
    #     whole scene stack (this screen included) and enters the map -- the
    #     same transition Continue always performed, just now aimed at
    #     whichever slot the player picked instead of a hardcoded one.
    #
    # Cancelling (B) always just pops back to whichever scene pushed this one.
    #
    # Every slot's preview is read once, up front, through
    # RPG2k#load_save_state -- the same "our own .mrb, else a genuine
    # Save<N>.lsd, else empty" lookup #continue_game itself uses, so the list
    # shows exactly what Continue would resume.
    class SaveLoad < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      SLOT_COUNT = RPG2k::MAX_SAVE_SLOTS
      LINE_H = 16
      HEADER_H = LINE_H + Window::BORDER * 2

      # Each visible slot is its own bordered window, three text lines tall
      # (file label, leader name, level+HP) -- confirmed against genuine
      # RPG_RT under wine, which draws File 1/2/3 as three separate boxes
      # stacked below the header, not rows inside one shared list window
      # (scripts/rpg2k_scene_check.rb's fixtures aside, a real screenshot
      # showed each box's own purple border independently). An empty slot's
      # box shows only the label line, the other two blank -- no "No Data"
      # placeholder text at all, the same class of gap the Item/Skill empty-
      # list placeholders turned out to be (see docs/TODO.md).
      SLOT_LINES = 3
      SLOT_BOX_H = LINE_H * SLOT_LINES + Window::BORDER * 2

      # RPG2000 FaceSet geometry (mirrors Scene::Map's own FACE_SIZE): a
      # 48x48 cell cropped straight out of a member's FaceSet sheet, never
      # scaled. `SLOT_BOX_H`'s own content height (LINE_H * SLOT_LINES = 48)
      # already matches this exactly, which is why a slot box fits one row
      # of faces with no extra vertical space to spare.
      FACE_SIZE = 48
      # The 56px pitch between face slots (48px cell + 8px gap) -- confirmed
      # against a genuine RPG_RT.exe under wine: a synthetic save whose title
      # chunk pointed all four face slots at the same FaceSet sheet at
      # indices 0-3 showed them at x=96/152/208/264 (logical, i.e. screen
      # pixels) on the real screen, an exact 56px stride.
      FACE_SPACING = 56
      MAX_SLOT_FACES = 4

      # (SCREEN_H - HEADER_H) / SLOT_BOX_H, i.e. how many slot boxes fit
      # below the header -- 3 on RPG2000's 320x240 screen (32 + 3*64 = 224,
      # leaving 16px for the scroll indicator #build_arrow_sprites draws).
      # Matches the reference capture exactly: three boxes on screen, the
      # rest reached by scrolling.
      VISIBLE_SLOTS = (SCREEN_H - HEADER_H) / SLOT_BOX_H

      # The list-scroll indicator: two independent blinking arrow sprites
      # (not a scrollbar/track -- there is no such thing anywhere in
      # RPG_RT), pinned at the very top and bottom of the whole slot
      # viewport and shown only while a slot is hidden in that direction.
      # Ported from EasyRPG's own `Scene_File` (`src/scene_file.cpp`,
      # `MakeArrowSprite`/`UpdateArrows`), NOT independently confirmed
      # against genuine RPG_RT under wine: this is entirely `Scene_File`'s
      # own doing, outside `Window_SaveFile` (which has no scroll logic of
      # its own -- it just draws one slot's contents) and outside the
      # generic `Window_Selectable` scroll-arrow mechanism other list
      # windows use. It reuses the identical windowskin cells and 20-frame
      # on/off blink this build's own `Window` already tracks for its
      # "waiting for input" pause arrow (`Window::ARROW_*` -- RPG_RT draws
      # both from the same System graphic block, the pause arrow and this
      # screen's down arrow sharing one cell). The up arrow is the same
      # block one row up (y=8 vs. y=16), which nothing in this codebase
      # needed a constant for until now.
      ARROW_W = Window::ARROW_W
      ARROW_H = Window::ARROW_H
      ARROW_SRC_X = Window::ARROW_SRC_X
      UP_ARROW_SRC_Y = 8
      DOWN_ARROW_SRC_Y = Window::ARROW_SRC_Y
      ARROW_BLINK_FRAMES = Window::ARROW_BLINK_FRAMES

      def initialize parent, state, mode
        super parent
        @state = state
        @mode = mode # :save or :load
        @skin = make_windowskin
        # One Game::State (or nil for an empty slot) per slot, read once so
        # scrolling the list never re-touches disk.
        @slots = (1..SLOT_COUNT).map { |slot| parent.load_save_state(slot) }
        @index = initial_index
        @top = [@index - VISIBLE_SLOTS + 1, 0].max
        @arrow_anim = 0
        @slot_windows = []
        build_header_window
        build_slot_windows
        build_arrow_sprites
      end

      def dispose
        @header_window.dispose if @header_window
        @slot_windows.each(&:dispose)
        @up_arrow.dispose if @up_arrow
        @down_arrow.dispose if @down_arrow
      end

      def update
        tick_arrows

        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        # Holding Down/Up auto-repeats the cursor after the initial delay, not
        # just a single step per tap -- `Input.repeat?`'s own timing (this
        # build's own `mruby-rgss/mrblib/lib.rb`) is independently measured
        # against the genuine RPG_RT.exe under wine, the same title/menu-
        # cursor timing every other list here gets wired the same way. This
        # list hand-rolls its own selection/scroll index rather than sharing
        # a generic list-cursor helper with item/skill/message lists, so it
        # needed that `|| #repeat?` wiring added by hand too.
        #
        # This list never wraps past the first/last slot at all, on a tap or a
        # held key alike -- independently confirmed against a genuine
        # RPG_RT.exe under wine (cycle #127): from the file-select screen's
        # opening cursor (File 1), a single Up tap left the captured frame
        # unchanged (still File 1, no scroll); walking Down to File 15 (the
        # last of MAX_SAVE_SLOTS) and tapping Down once more likewise left the
        # frame unchanged, as did a full ~1.5s hold of Down there and of Up
        # back at File 1. This replaces an earlier claim -- cited only to
        # EasyRPG's own `Scene_File::vUpdate` (`index = (index + 1) %
        # file_windows.size()` unconditionally on a fresh trigger, gated on
        # `index < max_index` only on a bare repeat) -- that a fresh tap
        # wraps around while a held key stops at the boundary; real RPG_RT
        # does neither, matching this list's own siblings instead (e.g.
        # `Scene::ItemMenu#move_item_cursor`'s identical bounded, no-wrap
        # `return if target < 0 || target >= size`).
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_selection(1)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_selection(-1)
        elsif Input.trigger?(Input::C)
          confirm_selection
        end
      end

      private

      # RPG_RT opens this screen with the cursor already on whichever slot
      # was saved most recently, not always slot 1 -- independently
      # confirmed against a genuine RPG_RT.exe under wine (cycle #123), not
      # just EasyRPG's source (`Scene_File::Start`, `src/scene_file.cpp`,
      # whose `index = latest_slot; ...` shape this was originally, and
      # still correctly, ported from). Two title-only `Save<N>.lsd` siblings
      # written directly into Nepheshel's game dir, differing only in chunk
      # 100 field 1 (`title.timestamp`): with slot 2 given the larger value,
      # a fresh RPG_RT.exe boot -> Continue landed the cursor on File 2, not
      # File 1; swapping which slot carried the larger timestamp swapped
      # which slot the cursor landed on too (File 1 the second time) --
      # ruling out "just the highest-numbered occupied slot" as an
      # alternative explanation for the first result. `Game::State#to_lsd`
      # already writes that exact field into each slot's exported
      # `Save<N>.lsd` sibling (`title[1] = timestamp.to_f`, defaulting to
      # the real save-time "now") -- reading it back here is the same
      # genuine on-disk field RPG_RT itself reads, not a filesystem-mtime
      # proxy.
      def initial_index
        best = 0
        best_time = -Float::INFINITY
        (1..SLOT_COUNT).each do |slot|
          ts = slot_timestamp(slot)
          next unless ts && ts > best_time
          best_time = ts
          best = slot - 1
        end
        best
      end

      # A slot's `title.timestamp`, read straight from its exported
      # `Save<N>.lsd` sibling -- nil for a slot with no `.lsd`, an unreadable
      # one, or one with no title chunk at all (the same defensive shape
      # `RPG2k#load_save_state` already uses for this exact file).
      def slot_timestamp(slot)
        path = parent.lsd_path(slot)
        return nil unless path && File.exist?(path)
        title = LCF::SaveData.new(File.open(path, "rb"))[100]
        title && title.timestamp
      rescue StandardError
        nil
      end

      # Move the slot cursor by `delta`, clamped at the first/last slot -- see
      # #update's own citation for why this never wraps, on a tap or a held
      # key alike.
      def move_selection(delta)
        target = @index + delta
        return if target < 0 || target >= SLOT_COUNT
        @index = target
        @top = @index if @index < @top
        @top = @index - VISIBLE_SLOTS + 1 if @index >= @top + VISIBLE_SLOTS
        refresh_slot_windows
        refresh_arrows
        play_system_se(SFX_CURSOR)
      end

      # A :save confirm pops straight back to the menu the same frame, with
      # no feedback of any kind -- this was previously cited only to
      # EasyRPG's `Scene_Save::Action` (`src/scene_save.cpp`, `Save(fs,
      # index + 1); Scene::Pop();`), mislabeled at the time as "RPG_RT's own
      # live source." Independently confirmed (cycle #126, 2026-08-23)
      # against a genuine RPG_RT.exe under wine: with Change Save Access
      # forced on (a save's own system chunk field 123, edited directly --
      # the same class of scratch edit already established for switches),
      # opening the field menu's Save command, picking the already-occupied
      # File 1 and pressing Decision closed the file-select screen and
      # returned to the command list with no window/message of any kind in
      # between -- the very next captured frame already shows the plain
      # command list, and `Save01.lsd` on disk changed size and content in
      # that same step, confirming the save genuinely happened rather than
      # silently failing. There is no "Save failed."/"Game saved." path in
      # real RPG_RT at all -- a save pops back exactly the same way whether
      # or not the write actually succeeds.
      def confirm_selection
        slot = @index + 1
        case @mode
        when :save
          play_system_se(SFX_DECISION)
          @parent.save_game(@state, slot)
          @parent.pop
        when :load
          # An empty slot has nothing to resume -- refused (Buzzer), like the
          # selection key on a title screen Continue with no save at all
          # (Scene::Title#update).
          if @slots[@index]
            play_system_se(SFX_DECISION)
            @parent.continue_game(slot)
          else
            play_system_se(SFX_BUZZER)
          end
        end
      end

      # Tick the blink phase every frame (RPG_RT's own arrows keep animating
      # even while, say, this screen's save-result message is up, per
      # EasyRPG's `UpdateArrows` -- NOT independently confirmed against
      # genuine RPG_RT under wine -- there is nothing in it that gates the
      # blink on anything besides whether more slots are hidden) and refresh
      # visibility from it.
      def tick_arrows
        return unless @up_arrow
        @arrow_anim = (@arrow_anim + 1) % (ARROW_BLINK_FRAMES * 2)
        refresh_arrows
      end

      # An arrow shows only while blinking "on" *and* there is a slot hidden
      # in that direction -- `@top > 0` for up, and for down: whether the
      # viewport's last visible row (`@top + VISIBLE_SLOTS - 1`) is still
      # short of the last real slot (`SLOT_COUNT - 1`), i.e. `@top <
      # SLOT_COUNT - VISIBLE_SLOTS` -- matching EasyRPG's own
      # `top_index < max_index - 2` for its fixed 3-visible layout, NOT
      # independently confirmed against genuine RPG_RT under wine.
      def refresh_arrows
        return unless @up_arrow
        blink_on = @arrow_anim < ARROW_BLINK_FRAMES
        @up_arrow.visible = blink_on && @top > 0
        @down_arrow.visible = blink_on && @top < SLOT_COUNT - VISIBLE_SLOTS
      end

      # Two independent sprites (not part of any one slot's own Window),
      # pinned to the top and bottom edge of the whole slot viewport and
      # centred horizontally -- see the class comment above VISIBLE_SLOTS.
      def build_arrow_sprites
        @up_arrow = build_arrow_sprite(UP_ARROW_SRC_Y)
        @up_arrow.y = HEADER_H
        @down_arrow = build_arrow_sprite(DOWN_ARROW_SRC_Y)
        @down_arrow.y = SCREEN_H - ARROW_H
        refresh_arrows
      end

      def build_arrow_sprite(src_y)
        sprite = Sprite.new
        sprite.z = 450
        sprite.x = (SCREEN_W - ARROW_W) / 2
        bmp = Bitmap.new(ARROW_W, ARROW_H)
        if @skin
          bmp.blt 0, 0, @skin, Rect.new(ARROW_SRC_X, src_y, ARROW_W, ARROW_H)
        else
          draw_arrow_fallback(bmp, src_y == UP_ARROW_SRC_Y)
        end
        sprite.bitmap = bmp
        sprite.visible = false
        sprite
      end

      # No windowskin to take the arrow art from -- a small solid triangle,
      # mirroring Window#draw_arrow_fallback's own shape (narrowing toward
      # the point) but in either direction, since this screen needs both.
      def draw_arrow_fallback(bmp, pointing_up)
        color = Color.new(232, 232, 248, 255)
        ARROW_H.times do |row|
          r = pointing_up ? ARROW_H - 1 - row : row
          w = ARROW_W - r * 2
          next if w <= 0
          bmp.fill_rect r, row, w, 1, color
        end
      end

      def build_header_window
        @header_window = Window.new(0, 0, SCREEN_W, HEADER_H)
        @header_window.z = 400
        @header_window.windowskin = @skin
        inner_w = SCREEN_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        header = @mode == :save ? term(:save_file_select, 'Save which file?') :
                                   term(:load_file_select, 'Load which file?')
        c.draw_text 0, 0, inner_w, LINE_H, header
        @header_window.contents = c
      end

      def build_slot_windows
        VISIBLE_SLOTS.times do |i|
          w = Window.new(0, HEADER_H + i * SLOT_BOX_H, SCREEN_W, SLOT_BOX_H)
          w.z = 400
          w.windowskin = @skin
          @slot_windows << w
        end
        refresh_slot_windows
      end

      # Redraw every visible slot box for the current scroll offset (`@top`)
      # and put the cursor on the selected one -- called whenever the
      # selection moves or a save just changed a slot's preview.
      def refresh_slot_windows
        inner_w = SCREEN_W - Window::BORDER * 2
        @slot_windows.each_with_index do |win, i|
          slot_index = @top + i
          draw_slot_box(win, inner_w, slot_index)
        end
      end

      def slot_label(slot_index)
        "#{term(:file, 'File')} #{slot_index + 1}"
      end

      # `slot_index`'s box: the file label always, and -- when the slot holds
      # a save -- the leader's name and level+HP beneath it, plus up to four
      # party face thumbnails along the right edge (`#draw_slot_faces`,
      # reading the same title-chunk FaceSet data `Game::State#to_lsd`
      # already exports -- see docs/TODO.md). Confirmed against genuine
      # RPG_RT under wine: an empty slot shows only the label (no
      # placeholder text at all), and an occupied one shows neither gold nor
      # the current map, and HP with no `/max`, unlike this screen's own
      # previous single-list-window layout.
      #
      # Every line renders through `#draw_system_text` (the windowskin
      # system-colour swatch blend, with RPG_RT's own one-pixel shadow) now,
      # not a flat `draw_text` -- ported from EasyRPG's `Window_SaveFile::
      # Refresh` (`src/window_savefile.cpp`), NOT independently confirmed
      # against genuine RPG_RT under wine: it draws every text element in
      # the box through `TextDraw(x, y, fc, text)`, never a raw colour, with `fc`
      # itself `has_save ? Font::ColorDefault : Font::ColorDisabled` (system
      # colour index 0 or 3, `src/font.h`) for the file label specifically --
      # the same disabled-swatch convention `Scene::Title`'s own Continue
      # entry already reads (see docs/TODO.md). This screen used to draw
      # every line flat white regardless of a windowskin's own palette *or*
      # whether the slot was empty, so an empty slot's "File N" label never
      # read as dimmed/disabled the way a genuine RPG_RT save screen's does,
      # and an occupied slot's name/level/HP never took the windowskin's
      # shading at all.
      def draw_slot_box(win, inner_w, slot_index)
        label = slot_label(slot_index)
        c = Bitmap.new(inner_w, LINE_H * SLOT_LINES)
        state = @slots[slot_index]
        draw_system_text c, 0, 0, inner_w, LINE_H, label, @skin, state ? 0 : 3
        if state
          leader = state.party.leader
          name = leader ? leader.name.to_s : ''
          # The title-chunk snapshot (`State#preview_level`/`#preview_hp`,
          # see its own citation) when the save carries one, falling back to
          # the live leader's own level/hp only for a state that never had a
          # snapshot to read (the Marshal round-trip path) -- the same
          # snapshot-first, live-fallback shape `#draw_slot_faces` already
          # uses for the face row below.
          has_preview = state.respond_to?(:preview_level) && !state.preview_level.nil?
          level = has_preview ? state.preview_level : (leader ? leader.level : 0)
          hp = has_preview ? state.preview_hp : (leader ? leader.hp : 0)
          draw_system_text c, 0, LINE_H, inner_w, LINE_H, name, @skin
          rpg2003 = state.party.respond_to?(:rpg2003?) && state.party.rpg2003?
          draw_level_hp(c, LINE_H * 2, level, hp, rpg2003)
          draw_slot_faces(c, inner_w, state)
        end
        win.contents = c
        win.cursor_rect = if slot_index == @index
                             Rect.new(0, 0, c.text_size(label).width, LINE_H)
                           else
                             Rect.new(0, 0, 0, 0)
                           end
      end

      # The level/HP line at RPG_RT's own fixed pixel columns (x=4 for the
      # level label, x=46 for HP), not proportioned to the label text --
      # ported from EasyRPG's `Window_SaveFile::Refresh`
      # (`src/window_savefile.cpp`), NOT independently confirmed against
      # genuine RPG_RT under wine: it is four separate `TextDraw` calls at
      # those exact x-coordinates, each number space-padded to a fixed
      # width (`std::setw(2)` for level, `std::setw(Player::IsRPG2k3() ? 4
      # : 3)` for HP) -- so a level 9 vs. 99 leader never shifts where "HP"
      # sits on screen, unlike a single interpolated string with a literal
      # gap between the two halves.
      def draw_level_hp(c, y, level, hp, rpg2003)
        lvl_label = fixed_width_term(:level_short, 'Lv')
        hp_label = fixed_width_term(:hp_short, 'HP')
        draw_system_text c, 4, y, c.width, LINE_H, lvl_label, @skin
        lx = c.text_size(lvl_label).width
        draw_system_text c, 4 + lx, y, c.width, LINE_H, level.to_s.rjust(2), @skin
        draw_system_text c, 46, y, c.width, LINE_H, hp_label, @skin
        hx = c.text_size(hp_label).width
        draw_system_text c, 46 + hx, y, c.width, LINE_H, hp.to_s.rjust(rpg2003 ? 4 : 3), @skin
      end

      # Clamp a database term string to exactly 2 characters, space-padded
      # if shorter -- ported from EasyRPG's own `lvl_short`/`hp_short`
      # handling (`Window_SaveFile::Refresh`: `if (lvl_short.size() != 2)
      # lvl_short.resize(2, ' ')`), NOT independently confirmed against
      # genuine RPG_RT under wine.
      def fixed_width_term(name, fallback)
        s = term(name, fallback)
        s.length > 2 ? s[0, 2] : s.ljust(2)
      end

      # Up to `MAX_SLOT_FACES` party face thumbnails, right-anchored within
      # the slot box, at the same 56px pitch in seat order, flush against the
      # box's own right edge -- the last face's right edge lands exactly on
      # `inner_w`, with no trailing 56-48=8px gap past it (unlike the gap
      # between each pair of faces). Confirmed against a genuine RPG_RT.exe
      # under wine: a synthetic save's four same-sheet faces measured at
      # x=96/152/208/264 on the real screen, landing the fourth face's right
      # edge (264+48) exactly on this screen's own 312 = 320-8 content
      # boundary -- `inner_w - MAX_SLOT_FACES * FACE_SPACING` (this file's
      # prior formula) instead reserved a phantom fifth gap after the last
      # face, measurably landing the whole row 8px too far left (x=88 instead
      # of 96, confirmed against our own engine's screenshot of the same
      # save before this fix).
      #
      # The real screen also draws this row from the save's own title-chunk
      # snapshot (`Game::State#preview_faces`, see its own citation), not
      # from whatever the slot's party/actor data says -- so that is tried
      # first, falling back to deriving from the live party's own members
      # (`actors[0..3]`, the same per-member order `Game::State#to_lsd`
      # writes the snapshot in) only when a state never carried one (the
      # Marshal round-trip path, which loses nothing and so never needs the
      # snapshot). A blank name -- no FaceSet set, or a snapshot slot the
      # save left empty -- simply leaves that slot empty, matching
      # `#draw_message_face`'s own "blank name -> no face" rule
      # (`Scene::Map#load_face_bitmap`).
      def draw_slot_faces(c, inner_w, state)
        pairs = state.respond_to?(:preview_faces) ? state.preview_faces : nil
        pairs ||= state.party.actors.first(MAX_SLOT_FACES).map do |actor|
          [actor.respond_to?(:faceset_name) ? actor.faceset_name : nil,
           actor.respond_to?(:faceset_index) ? actor.faceset_index : 0]
        end
        start_x = inner_w - ((MAX_SLOT_FACES - 1) * FACE_SPACING + FACE_SIZE)
        pairs.first(MAX_SLOT_FACES).each_with_index do |(name, index), i|
          next if name.nil? || name.empty?
          sheet = load_face_bitmap(name)
          next unless sheet
          cell = build_face_cell(sheet, index || 0)
          c.blt start_x + i * FACE_SPACING, 0, cell, Rect.new(0, 0, FACE_SIZE, FACE_SIZE)
        end
      end

      # Load a FaceSet graphic by name, or nil for a missing file (the caller
      # then draws no thumbnail for that member). Mirrors
      # `Scene::Map#load_face_bitmap` exactly, including the colour-key
      # transparency every FaceSet sheet needs.
      def load_face_bitmap(name)
        Bitmap.new "FaceSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{name}' load failed: #{e.message}"
        nil
      end

      # Crop one 48x48 cell out of a FaceSet sheet. Unlike
      # `Scene::Map#build_face_cell`, this screen never mirrors a face --
      # ported from EasyRPG's own `Window_Base::DrawFace` call for the
      # save-file screen, NOT independently confirmed against genuine
      # RPG_RT under wine: it always passes `flip: false`, unlike a message
      # window's Change Face Graphic, the only place a mirror flag exists
      # in the data at all.
      def build_face_cell(sheet, index)
        src_x = (index % 4) * FACE_SIZE
        src_y = (index / 4) * FACE_SIZE
        cell = Bitmap.new(FACE_SIZE, FACE_SIZE)
        cell.blt 0, 0, sheet, Rect.new(src_x, src_y, FACE_SIZE, FACE_SIZE)
        cell
      end

    end
  end
end
