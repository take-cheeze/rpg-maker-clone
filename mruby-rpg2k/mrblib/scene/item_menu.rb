class RPG2k
  module Scene
    # The field item screen (main menu -> Item). Lists the party's usable
    # medicines with their held counts; picking one either applies it to the
    # whole party (an all-ally item) or asks which ally to use it on (a
    # single-target item). Using an item consumes one and refreshes the list; an
    # item that would have no effect (everyone already full) is reported and not
    # consumed. A switch item instead flips its game switch and closes the
    # whole menu stack outright, with no "Used on ..." message -- the same as
    # a special item invoking an Escape or Teleport skill, which warps the
    # party instead, the same as Scene::SkillMenu's own Escape/Teleport skills:
    # Escape jumps straight to its one registered target, Teleport opens a
    # picker of every registered destination. All decision logic lives in
    # Game::Party (field_items / use_item / use_switch_item / item_effective? /
    # use_special_escape_item / use_special_teleport_item), which the host
    # harnesses test; this class is the RGSS UI over it, mirroring
    # Scene::Menu's window/cursor/message helpers.
    class ItemMenu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16

      # Height of the item-description banner at the very top of the screen
      # (see #build_desc_window) -- mirrors Scene::EquipMenu's own banner,
      # which the item list is offset down by.
      DESC_H = LINE_H + Window::BORDER * 2

      # The item list is a two-column grid, not a single stacked column --
      # confirmed against genuine RPG_RT under wine with a five-item bag,
      # which filled row-major (item 0 top-left, item 1 top-right, item 2
      # second row left, ...) and left an incomplete last row's second cell
      # blank rather than reflowing. Cursor movement is grid-aware but not
      # symmetric between axes -- confirmed directly against EasyRPG's own
      # `Window_Selectable::Update` (`src/window_selectable.cpp`), which has
      # no method actually named `CursorDown`/`Up`/`Right`/`Left`: DOWN/UP
      # move by COLUMN_MAX and are genuinely column-locked, a no-op with no
      # cell below/above (tried pressing DOWN off the last, partial row --
      # the cursor simply stayed); RIGHT/LEFT move by one, bounded only by
      # the list's own absolute start/end, with no row-boundary check at
      # all -- RIGHT off a row's last cell flows into the next row's first
      # cell (and LEFT the mirror), rather than stopping at the row's edge.
      COLUMN_MAX = 2

      def initialize parent, state
        super parent
        @state = state
        @skin = make_windowskin
        @mode = :items          # :items list, :target selection, or :teleport_target
        @item_index = 0
        @target_index = 0
        @target_lock = nil
        @teleport_index = 0
        @pending_item = nil
        @message = nil
        build_desc_window
        build_item_window
      end

      def dispose
        close_message
        @desc_window.dispose if @desc_window
        @item_window.dispose if @item_window
        @target_window.dispose if @target_window
        @teleport_window.dispose if @teleport_window
      end

      def update
        return drive_message if @message
        case @mode
        when :target then update_target
        when :teleport_target then update_teleport_target
        else update_items
        end
      end

      private

      # Cached list of [id, count] pairs; invalidated after a use changes counts.
      # `@state` decides whether a special item invoking an Escape/Teleport
      # skill belongs in it (see Game::Party#field_items).
      def items
        @items ||= @state.party.field_items(@state)
      end

      def invalidate_items
        @items = nil
      end

      # Holding a direction auto-repeats the cursor after the initial delay,
      # not just a single step per tap -- `Window_Selectable::Update`
      # (`src/window_selectable.cpp`), the base every real RPG2000 list is
      # built on, falls through to `Input::IsRepeated` for all four
      # directions right after its own `IsTriggered` check. `Input.repeat?`'s
      # own timing already matches EasyRPG's repeat constants exactly -- see
      # `Scene::SaveLoad`'s identical fix and its fuller writeup in
      # docs/TODO.md -- so every check below just gains an `|| #repeat?`
      # alongside it, the same pure-wiring shape.
      def update_items
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          @parent.pop
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_item_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_item_cursor(-COLUMN_MAX)
        # Right/Left cross a row boundary rather than stopping at the row's
        # own edge -- confirmed directly against RPG_RT's live source:
        # `Window_Selectable::Update` (`src/window_selectable.cpp`) has no
        # method actually named `CursorRight`/`CursorLeft`; its real Right/
        # Left branches are a flat `index +- 1`, bounded only by the list's
        # own absolute start/end (`index < item_max - 1` / `index > 0`),
        # structurally unlike Down/Up (genuinely column-locked there,
        # `index < item_max - column_max`). #move_item_cursor's own bound
        # (`target < 0 || target >= items.size`) already matches this
        # exactly -- the row-edge guard removed here was the only thing
        # stopping Right/Left short of it.
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          move_item_cursor(1)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          move_item_cursor(-1)
        elsif Input.trigger?(Input::C)
          choose_item
        end
      end

      # Move the item cursor by `delta` cells (a row for +-COLUMN_MAX, a
      # column for +-1), ignored if that cell is off the grid -- confirmed
      # against genuine RPG_RT under wine, which leaves the cursor put
      # rather than wrapping (see the COLUMN_MAX comment above).
      def move_item_cursor(delta)
        return if items.empty?
        target = @item_index + delta
        return if target < 0 || target >= items.size
        @item_index = target
        refresh_item_cursor
        play_system_se(SFX_CURSOR)
      end

      def choose_item
        if items.empty?
          play_system_se(SFX_BUZZER)
          return
        end
        id, = items[@item_index]
        # A row now can hold an item #field_items lists but is not
        # field-usable (see its own doc comment) -- selectable, since the
        # cursor moves freely onto it, but Decision just buzzes and stays,
        # the same "greyed entry" shape Scene::SkillMenu#choose_skill
        # already gates its own dispatch behind.
        unless @state.party.field_usable?(id, @state)
          play_system_se(SFX_BUZZER)
          return
        end
        it = @state.party.db_item(id)
        sk = (it && (it.type == Game::Party::ITEM_SPECIAL ||
                    (it.use_skill && (1..5).cover?(it.type)))) ?
               @state.party.db_skill(it.skill_id) : nil
        # Only a genuine type-9 special item warps for an Escape/Teleport
        # skill (or is buzzer-gated on access/target before it even tries)
        # -- confirmed against genuine RPG_RT's own live source:
        # `Scene_Item::vUpdate` (`src/scene_item.cpp`) gates its whole
        # ReserveTeleport/Scene_Teleport dispatch behind `item.type ==
        # Type_special`; a `use_skill`-flagged weapon/shield/armor/helmet/
        # accessory item (schema field 71) invoking the very same skill type
        # always falls to the generic `else` branch there instead (a plain
        # `Scene_ActorTarget` push), and `Game_Battler::UseSkill`'s own
        # Escape/Teleport branch for it plays only the skill's sound effect,
        # no warp at all (see `#use_special_escape_item`'s own citation).
        # `#use_equip_skill_item` already mirrors that exact "SE only, no
        # warp" outcome once a target is confirmed (see its own doc), so
        # this scene needs no special dispatch for that case beyond the
        # ordinary `#prompt_item_target` every other targeted item already
        # takes. This used to route a use_skill equipment item through the
        # special-item Escape/Teleport branches too, which let it warp the
        # party for free -- something real RPG_RT never does for such an
        # item. A Switch-type skill is unaffected either way: `Game_Battler
        # ::UseSkill`'s Switch branch flips the switch through the same
        # shared `do_skill` path for both item kinds, which `#apply_special
        # _switch_item`/`#use_special_switch_item` below already gets right
        # for both.
        special = it && it.type == Game::Party::ITEM_SPECIAL
        # An Escape/Teleport-invoking special item is always listed (see
        # Game::Party#field_skill?, which #field_usable?'s special-item
        # branch now defers to) but only castable once access and a
        # registered target are there. Confirmed against RPG_RT's own live
        # source: `Scene_Item::vUpdate` (`src/scene_item.cpp`) gates its
        # *entire* per-type dispatch behind `item_window->CheckEnable
        # (item_id)` before ever reaching the Escape/Teleport branches --
        # disabled plays only the buzzer and returns, no attempt, no
        # message, exactly like an unavailable skill in
        # Scene::SkillMenu#choose_skill. Left to #apply_escape_item /
        # #apply_teleport_item's own nil-return fallback instead, this would
        # show a fabricated "It had no effect." message and a stray
        # Decision-then-Buzzer double beep that RPG_RT never produces for a
        # disabled entry.
        if special && sk && sk.type == Game::Party::SKILL_ESCAPE &&
           @state.party.respond_to?(:escape_skill_available?) &&
           !@state.party.escape_skill_available?(@state)
          play_system_se(SFX_BUZZER)
          return
        end
        if special && sk && sk.type == Game::Party::SKILL_TELEPORT &&
           @state.party.respond_to?(:teleport_skill_available?) &&
           !@state.party.teleport_skill_available?(@state)
          play_system_se(SFX_BUZZER)
          return
        end
        play_system_se(SFX_DECISION)
        # A switch item has no actor target; an all-ally medicine skips the
        # target prompt; single-target medicines / skill books ask who to use on.
        # A special item follows the *skill* it invokes, since that is what
        # decides the scope — self (2) or all-ally (4) needs no prompt.
        if it && it.type == Game::Party::ITEM_SWITCH
          apply_switch_item(id)
        elsif sk && special && sk.type == Game::Party::SKILL_ESCAPE
          # Escape has one registered target and no picker -- mirroring
          # Scene::SkillMenu#apply_escape_skill, a successful cast warps
          # straight there with no confirmation message. Genuine special
          # items only -- see this method's own doc comment above.
          apply_escape_item(id)
        elsif sk && special && sk.type == Game::Party::SKILL_TELEPORT
          # Teleport opens a third list of every registered destination, the
          # same as Scene::SkillMenu's own teleport picker. Genuine special
          # items only -- see this method's own doc comment above.
          @pending_item = id
          @mode = :teleport_target
          @teleport_index = 0
          build_teleport_window
          refresh_desc
        elsif sk
          if sk.type == Game::Party::SKILL_SWITCH
            # A switch skill has no target and no confirmation message either
            # -- mirroring Scene::SkillMenu#apply_switch_skill, a successful
            # cast closes the whole menu stack at once. Both item kinds take
            # this branch -- see this method's own doc comment above.
            apply_special_switch_item(id)
          elsif sk.type == Game::Party::SKILL_ESCAPE || sk.type == Game::Party::SKILL_TELEPORT
            # A use_skill equipment item invoking Escape/Teleport: no warp,
            # no picker of its own -- the ordinary single-target prompt
            # below, exactly like ordinary equipment (see this method's own
            # doc comment above and #use_equip_skill_item's).
            prompt_item_target(id)
          elsif sk.scope == 2 || sk.scope == 4
            # Unlike a medicine (whose all-ally scope needs no actor at all --
            # #use_medicine reads the whole party off `@actors`, ignoring the
            # argument), a special item's `actor` argument is the *caster*
            # #use_special_item casts the skill from (mirroring
            # Scene::SkillMenu, which always has a caster selected) -- the
            # party leader, the only actor this menu ever casts a special
            # item's skill from. A self (2) lock highlights the leader's own
            # row; an all-ally (4) lock highlights the whole list -- see
            # #enter_target_confirm's own doc comment for why this codebase
            # still shows the confirm screen for both rather than skipping it.
            @pending_item = id
            enter_target_confirm(sk.scope == 2 ? :self : :party)
          else
            prompt_item_target(id)
          end
        elsif it && it.scope == 1 && it.type == Game::Party::ITEM_MEDICINE
          @pending_item = id
          enter_target_confirm(:party)
        else
          prompt_item_target(id)
        end
      end

      # Ask which party member the pending item is used on.
      def prompt_item_target(id)
        @pending_item = id
        enter_target_confirm(nil)
      end

      # Open the target-confirm screen (`@mode = :target`), locking the
      # cursor when `lock` names who the effect already, unavoidably, lands
      # on: `:self` to the party leader's own row, `:party` to the whole list
      # (an all-ally medicine or all-ally invoked skill). See
      # Scene::SkillMenu#enter_target_confirm's identical doc comment for the
      # full RPG_RT citation -- this mirrors it exactly.
      #
      # Both locked cases pin `@target_index` to the leader, not just `:self`:
      # #update_target's Decision handler always passes `party[@target_index]`
      # on to #apply_item as its `actor` argument, and for a special/
      # use_skill item that argument is the *caster* #use_special_item casts
      # from (mirroring Scene::SkillMenu, which always has a caster
      # selected) -- the party leader, whatever their roster slot. A plain
      # all-ally medicine ignores the argument entirely (#use_medicine's own
      # `it.scope == 1 ? @actors : ...`), so the leader is a harmless choice
      # there too.
      def enter_target_confirm(lock)
        @mode = :target
        @target_lock = lock
        @target_index = lock ? leader_target_index : 0
        build_target_window
        refresh_desc
      end

      # The party roster index of the leader -- who a special/use_skill
      # item's invoked self-scope skill always casts from (see #choose_item).
      # 0 (the roster's own front slot) if the leader is somehow not found in
      # it, which should not happen on real data.
      def leader_target_index
        @state.party.actors.index(@state.party.leader) || 0
      end

      # A switch item turns on its game switch (the menu owns the switch table)
      # and consumes one -- then closes the whole menu stack at once, the same
      # as a special item invoking Escape or Teleport (RPG_RT never leaves a
      # switch item's user sitting in the item list afterwards, since flipping
      # a switch is typically what a waiting map event is watching for). No
      # confirmation message on success, matching that same Escape/Teleport
      # precedent; a use that consumed nothing (not actually a held switch
      # item) reports "It had no effect." and stays put instead.
      def apply_switch_item(id)
        sid = @state.party.use_switch_item(id)
        if sid
          @state.switches[sid] = true
          @parent.pop_to_map
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # A special item invoking an Escape-type skill: cast from the party
      # leader (mirroring the self/all-ally special-item branch above), free.
      # A successful cast closes the whole menu stack at once, matching
      # Scene::SkillMenu#apply_escape_skill -- there is no field-menu message
      # shown afterwards, since the map that would show it is gone before the
      # next frame draws.
      def apply_escape_item(id)
        target = @state.party.use_special_escape_item(id, @state.party.leader, @state)
        if target
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # The same for a special item invoking a Switch-type skill: no target,
      # no confirmation message -- a successful cast closes the whole menu
      # stack at once, matching Scene::SkillMenu#apply_switch_skill (and
      # this scene's own #apply_switch_item, the plain switch-item case).
      def apply_special_switch_item(id)
        switch = @state.party.use_special_switch_item(id, @state.party.leader)
        if switch
          @state.switches[switch] = true
          @parent.pop_to_map
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # The same for a Teleport-type skill, once a destination is chosen from
      # the list built by #build_teleport_window.
      def apply_teleport_item(id, map_id)
        target = @state.party.use_special_teleport_item(id, @state.party.leader, @state, map_id)
        if target
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
          show_message("It had no effect.")
        end
      end

      # Queue the warp for Scene::Map (see Game::State#pending_teleport) and pop
      # every menu on top of it in one step -- the same shape (switch flip
      # included) Scene::SkillMenu#queue_teleport uses.
      def queue_teleport(target)
        @state.switches[target[:switch_id]] = true if target[:switch_id]
        @state.pending_teleport = [target[:map_id], target[:x], target[:y], 0]
        @parent.pop_to_map
      end

      # The destination list is a two-column grid too, not a single stacked
      # column -- confirmed against genuine RPG_RT's own live source:
      # `Window_Teleport` (`src/window_teleport.cpp`) sets `column_max = 2`
      # (`Window_Selectable`'s `wrap_limit` default is also 2, the exact
      # threshold `Window_Selectable::Update`'s RIGHT/LEFT handling gates on),
      # the identical shape this class's own item list already ports (see
      # `COLUMN_MAX`'s comment). With exactly two destinations, DOWN/UP are
      # no-ops (nothing in the row below/above) and RIGHT reaches the second
      # one -- not DOWN, which this scene wrongly wired to a single-column
      # modulo wrap with no RIGHT/LEFT handling at all.
      def update_teleport_target
        targets = teleport_targets
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_teleport_target
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          move_teleport_cursor(COLUMN_MAX)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          move_teleport_cursor(-COLUMN_MAX)
        # Right/Left cross a row boundary rather than stopping at the row's
        # own edge -- the same fix as #update_items's identical RIGHT/LEFT
        # handling (confirmed directly against `Window_Selectable::Update`,
        # `src/window_selectable.cpp`: Right/Left are a flat `index +- 1`
        # bounded only by the list's own absolute start/end, no
        # row-boundary check), never propagated to this sibling list when
        # that one was corrected.
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          move_teleport_cursor(1)
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          move_teleport_cursor(-1)
        elsif Input.trigger?(Input::C) && !targets.empty?
          play_system_se(SFX_DECISION)
          map_id, = targets[@teleport_index]
          apply_teleport_item(@pending_item, map_id)
        end
      end

      # Move the teleport-target cursor by `delta` grid cells, ignored if that
      # cell is off the grid -- mirrors #move_item_cursor exactly (see its
      # own comment).
      def move_teleport_cursor(delta)
        targets = teleport_targets
        return if targets.empty?
        target = @teleport_index + delta
        return if target < 0 || target >= targets.size
        @teleport_index = target
        refresh_teleport_cursor
        play_system_se(SFX_CURSOR)
      end

      def leave_teleport_target
        @pending_item = nil
        @mode = :items
        if @teleport_window
          @teleport_window.dispose
          @teleport_window = nil
        end
        refresh_desc
      end

      # The registered teleport destinations as `[map_id, name]` pairs,
      # ascending by map id -- see Scene::SkillMenu#teleport_targets, which
      # this mirrors exactly.
      def teleport_targets
        @state.teleport_targets.keys.sort.map { |id| [id, map_display_name(id)] }
      end

      # A map's editor name for the teleport picker, or its bare id when the
      # tree carries no name for it -- see Scene::SkillMenu#map_display_name.
      def map_display_name(map_id)
        row = map_tree.respond_to?(:map_properties) ? map_tree.map_properties[map_id] : nil
        name = row && row.respond_to?(:name) ? row.name.to_s : nil
        name.nil? || name.empty? ? "Map #{map_id}" : name
      end

      # Column width for the teleport-destination grid (see #update_teleport_target's
      # grid comment above; identical formula to #item_col_w).
      def teleport_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      def build_teleport_window
        @teleport_window.dispose if @teleport_window
        rows = teleport_targets
        inner_w = SCREEN_W - Window::BORDER * 2
        grid_rows = [(rows.size / COLUMN_MAX.to_f).ceil, 1].max
        h = grid_rows * LINE_H
        @teleport_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                      SCREEN_W, h + Window::BORDER * 2)
        @teleport_window.z = 450
        @teleport_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        if rows.empty?
          c.draw_text 0, 0, inner_w, LINE_H, "No destinations"
        else
          col_w = teleport_col_w
          rows.each_with_index do |(_id, name), i|
            x = (i % COLUMN_MAX) * col_w
            y = (i / COLUMN_MAX) * LINE_H
            c.draw_text x, y, col_w, LINE_H, name
          end
        end
        @teleport_window.contents = c
        refresh_teleport_cursor
      end

      def refresh_teleport_cursor
        return unless @teleport_window
        h = teleport_targets.empty? ? 0 : LINE_H
        x = (@teleport_index % COLUMN_MAX) * teleport_col_w
        y = (@teleport_index / COLUMN_MAX) * LINE_H
        @teleport_window.cursor_rect = Rect.new(x, y, teleport_col_w, h)
      end

      def update_target
        party = @state.party.actors
        if Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          leave_target_mode
        elsif !@target_lock && (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN))
          @target_index += 1
          @target_index %= party.size
          refresh_target_cursor
          play_system_se(SFX_CURSOR)
        elsif !@target_lock && (Input.trigger?(Input::UP) || Input.repeat?(Input::UP))
          @target_index -= 1
          @target_index %= party.size
          refresh_target_cursor
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          apply_item(@pending_item, party[@target_index])
        end
      end

      # A used item that changed nothing (everyone already full, an
      # ineffective status cure, ...) plays Buzzer rather than the item's own
      # success cue -- matching RPG_RT's own invalid-use handling elsewhere in
      # `Scene_Item` (a rejected action gets the same SE as a confirm on an
      # empty list or a disabled command, not a silent no-op). A *successful*
      # use stays on this same target screen too, exactly like a no-effect
      # one -- confirmed against RPG_RT's own live source:
      # `Scene_ActorTarget::UpdateItem` (`src/scene_actortarget.cpp`) never
      # calls `Scene::Pop()` on Decision, success or failure alike; the only
      # `Scene::Pop()` in the whole file is `vUpdate`'s own Cancel branch.
      # `#use_item`'s own `item_count(id) > 0` gate already answers what
      # happens on a repeat use once the item runs out (an empty `affected`,
      # the same Buzzer path), matching the reference's own `GetItemCount(id)
      # <= 0` check ahead of `UseItem` -- depletion buzzes, it does not
      # auto-exit either.
      #
      # No confirmation message either way -- `UpdateItem`'s own success/
      # failure branches only ever call `SePlay`/`Refresh`, never build a
      # message window; this class used to show "Used on X."/"It had no
      # effect." here (and `#update_target` played a Decision-click SE ahead
      # of every use, matching neither branch), a fabricated dialog this
      # runtime invented that also forced an extra dismiss press before the
      # next target could be picked -- a genuine slowdown a screen this
      # runtime already got right for the Switch/Escape/Teleport special
      # items (`#apply_special_switch_item` etc.) never had.
      def apply_item(id, actor)
        affected = @state.party.use_item(id, actor)
        if affected.empty?
          play_system_se(SFX_BUZZER)
        else
          play_item_use_se(id)
        end
      end

      # The item's own success cue -- confirmed against RPG_RT's own live
      # source: `Scene_ActorTarget::UpdateItem` plays the invoked skill's own
      # animation SE for a Type_special item or a `use_skill`-flagged
      # weapon/shield/armor/helmet/accessory item (the identical `do_skill`
      # condition `Game::Party#use_special_escape_item` already mirrors for
      # its own free-use gate), and the database's own Item system SE
      # (`SFX_UseItem`) for every other item type.
      def play_item_use_se(id)
        it = @state.party.db_item(id)
        do_skill = it && (it.type == Game::Party::ITEM_SPECIAL ||
                           (it.use_skill && (1..5).cover?(it.type)))
        if do_skill
          sk = @state.party.db_skill(it.skill_id)
          play_animation_se(sk && sk.animation_id)
        else
          play_system_se(SFX_ITEM)
        end
      end

      # Back to the item list, rebuilt so it reflects whatever changed while
      # target mode was open (a count fell, a depleted item dropped out) --
      # only reached via Cancel now that a successful use no longer forces
      # this on its own (see #apply_item). Keeps the cursor in range when the
      # last of an item was used up.
      def leave_target_mode
        @pending_item = nil
        @target_lock = nil
        @mode = :items
        if @target_window
          @target_window.dispose
          @target_window = nil
        end
        invalidate_items
        @item_index = items.size - 1 if @item_index >= items.size
        @item_index = 0 if @item_index < 0
        build_item_window
        refresh_desc
      end

      # The highlighted item's flavour text, in a one-line banner across the
      # very top of the screen -- confirmed against genuine RPG_RT under
      # wine (e.g. "HPを80ポイント程度回復する" for a healing item), the same
      # gap Scene::EquipMenu had. Tracks the item under the cursor in :items
      # mode; the :target/:teleport_target pickers keep showing the pending
      # item's own description, since it is still the one thing on screen a
      # description could be about.
      def build_desc_window
        @desc_window.dispose if @desc_window
        inner_w = SCREEN_W - Window::BORDER * 2
        @desc_window = Window.new(0, 0, SCREEN_W, DESC_H)
        @desc_window.z = 400
        @desc_window.windowskin = @skin
        @desc_contents = Bitmap.new(inner_w, LINE_H)
        @desc_window.contents = @desc_contents
        refresh_desc
      end

      def refresh_desc
        return unless @desc_contents
        id = if @mode == :items
               rows = items
               rows.empty? ? nil : rows[@item_index].first
             else
               @pending_item
             end
        it = id && id != 0 ? @state.party.db_item(id) : nil
        text = it ? it.description.to_s : ''
        @desc_contents.clear
        @desc_contents.font.color = Color.new(255, 255, 255, 255)
        @desc_contents.draw_text 0, 0, @desc_contents.width, LINE_H, text
      end

      # Column width for the item grid (see the COLUMN_MAX comment above).
      def item_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      def build_item_window
        @item_window.dispose if @item_window
        rows = items
        inner_w = SCREEN_W - Window::BORDER * 2
        grid_rows = [(rows.size / COLUMN_MAX.to_f).ceil, 1].max
        h = grid_rows * LINE_H
        @item_window = Window.new(0, DESC_H, SCREEN_W, h + Window::BORDER * 2)
        @item_window.z = 400
        @item_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        col_w = item_col_w
        # An empty bag draws no placeholder text -- confirmed against genuine
        # RPG_RT under wine, which shows a blank list row (still with a
        # visible, empty cursor box; see #refresh_item_cursor) rather than
        # any "no items" message.
        #
        # A row whose item is not field-usable (an unequipped weapon/shield/
        # armor/helmet/accessory, say) is still drawn, in the windowskin's
        # disabled swatch (index 3) rather than the enabled one (0) -- the
        # same convention the title screen's Continue label uses, and
        # confirmed here directly: pixel-sampling a genuine RPG_RT frame
        # (a held, unusable Dagger next to a usable Herb) found the two
        # rows in visibly different, distinct colors.
        rows.each_with_index do |(id, count), i|
          it = @state.party.db_item(id)
          name = (it && it.name.to_s)
          name = "Item #{id}" if name.nil? || name.empty?
          x = (i % COLUMN_MAX) * col_w
          y = (i / COLUMN_MAX) * LINE_H
          idx = @state.party.field_usable?(id, @state) ? 0 : 3
          draw_system_text(c, x, y + 2, col_w - 40, LINE_H, name, @skin, idx)
          draw_system_text(c, x + col_w - 40, y + 2, 40, LINE_H, ":#{count}", @skin, idx)
        end
        @item_window.contents = c
        refresh_item_cursor
      end

      def refresh_item_cursor
        return unless @item_window
        # The cursor box stays visible on the empty row even with no items --
        # matched against genuine RPG_RT under wine, which highlights the
        # blank slot rather than hiding the cursor. It highlights just the
        # one grid cell, not the full row -- confirmed by the same captures
        # that found the grid layout itself (see the COLUMN_MAX comment).
        x = (@item_index % COLUMN_MAX) * item_col_w
        y = (@item_index / COLUMN_MAX) * LINE_H
        @item_window.cursor_rect = Rect.new(x, y, item_col_w, LINE_H)
        refresh_desc
      end

      def build_target_window
        @target_window.dispose if @target_window
        party = @state.party.actors
        inner_w = SCREEN_W - Window::BORDER * 2
        h = party.size * (LINE_H * 2)
        @target_window = Window.new(0, SCREEN_H - h - Window::BORDER * 2,
                                    SCREEN_W, h + Window::BORDER * 2)
        @target_window.z = 450
        @target_window.windowskin = @skin
        c = Bitmap.new(inner_w, h)
        c.font.color = Color.new(255, 255, 255, 255)
        party.each_with_index do |a, i|
          y = i * LINE_H * 2
          c.draw_text 0, y, inner_w, LINE_H, a.name.to_s
          # RPG_RT's target list shows each member's condition (its
          # Window_ActorTarget draws one) -- which is most of the point of the
          # list, since it is where you pick who to use an antidote on.
          draw_actor_state c, a, 0, y, inner_w, LINE_H, @skin, 2
          c.draw_text 0, y + LINE_H, inner_w, LINE_H,
                      "#{term(:hp_short, 'HP')} #{a.hp}/#{a.display_max_hp}  " \
                      "#{term(:mp_short, 'MP')} #{a.mp}/#{a.display_max_mp}"
        end
        @target_window.contents = c
        refresh_target_cursor
      end

      def refresh_target_cursor
        return unless @target_window
        # A :party lock (an all-ally medicine or invoked skill) highlights
        # every row at once -- see Scene::SkillMenu#refresh_target_cursor's
        # identical comment/RPG_RT citation.
        if @target_lock == :party
          @target_window.cursor_rect =
            Rect.new(0, 0, @target_window.contents.width, @target_window.contents.height)
        else
          @target_window.cursor_rect =
            Rect.new(0, @target_index * LINE_H * 2, @target_window.contents.width,
                     LINE_H * 2)
        end
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        close_message
      end

      def show_message(text)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - 40, w, 14 + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, 14)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, 14, text
        win.contents = c
        @message = { window: win }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
      end
    end

  end
end
