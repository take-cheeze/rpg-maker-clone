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
        build_desc_window
        build_item_window
      end

      def dispose
        @desc_window.dispose if @desc_window
        @item_window.dispose if @item_window
        @target_window.dispose if @target_window
        @teleport_window.dispose if @teleport_window
      end

      def update
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
          enter_teleport_target
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
        # The description banner and item-list box both narrow/change content
        # for :target mode -- see #left_panel_w and #build_possessed_window.
        # Both rebuild their own content (including a #refresh_desc call), so
        # this needs no separate refresh_desc of its own.
        build_desc_window
        build_item_window
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
      # a switch is typically what a waiting map event is watching for). A use
      # that consumed nothing (not actually a held switch item) plays Buzzer
      # and stays put, with no message -- see #apply_item's own citation
      # (confirmed directly against a genuine RPG_RT.exe under wine: a
      # no-effect Decision on this menu's target/confirm screen shows no
      # message window at all, just the buzzer, and leaves the screen open)
      # for why this file no longer fabricates one here either. This branch
      # is unreachable through ordinary play -- #choose_item only ever
      # dispatches here for an id already known to be a held switch item
      # (`it.type == ITEM_SWITCH`, from the held-items list `#items` builds),
      # so `#use_switch_item`'s own `switch_item?(id) && item_count(id) > 0`
      # guard can never actually fail -- but it is kept in the same no-message
      # shape as every reachable sibling below for consistency.
      def apply_switch_item(id)
        sid = @state.party.use_switch_item(id)
        if sid
          @state.switches[sid] = true
          @parent.pop_to_map
        else
          play_system_se(SFX_BUZZER)
        end
      end

      # A special item invoking an Escape-type skill: cast from the party
      # leader (mirroring the self/all-ally special-item branch above), free.
      # A successful cast closes the whole menu stack at once, matching
      # Scene::SkillMenu#apply_escape_skill -- there is no field-menu message
      # shown afterwards, since the map that would show it is gone before the
      # next frame draws. The failure branch is likewise unreachable in
      # ordinary play (`#choose_item` already buzzes-and-returns via
      # `#escape_skill_available?` before ever calling this), kept
      # message-free for the same reason #apply_switch_item is above.
      def apply_escape_item(id)
        target = @state.party.use_special_escape_item(id, @state.party.leader, @state)
        if target
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
        end
      end

      # The same for a special item invoking a Switch-type skill: no target,
      # no confirmation message -- a successful cast closes the whole menu
      # stack at once, matching Scene::SkillMenu#apply_switch_skill (and
      # this scene's own #apply_switch_item, the plain switch-item case).
      # Failure is unreachable the same way as that sibling.
      def apply_special_switch_item(id)
        switch = @state.party.use_special_switch_item(id, @state.party.leader)
        if switch
          @state.switches[switch] = true
          @parent.pop_to_map
        else
          play_system_se(SFX_BUZZER)
        end
      end

      # The same for a Teleport-type skill, once a destination is chosen from
      # the list built by #build_teleport_window. Failure is unreachable the
      # same way #apply_escape_item's is (`#teleport_skill_available?` gates
      # `#choose_item` first).
      def apply_teleport_item(id, map_id)
        target = @state.party.use_special_teleport_item(id, @state.party.leader, @state, map_id)
        if target
          queue_teleport(target)
        else
          play_system_se(SFX_BUZZER)
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
      # column -- the identical shape this class's own item list already
      # ports, confirmed against genuine RPG_RT under wine with a five-item
      # bag (see `COLUMN_MAX`'s own comment above), carried over on the
      # strength of that shared shape rather than separately re-measured.
      # With exactly two destinations, DOWN/UP are
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

      # :teleport_target's own left side -- unlike :target mode (which
      # narrows the description banner/item grid to make room for a
      # right-anchored panel, cycle #140), the destination picker removes
      # both entirely, leaving raw map background where they used to be --
      # confirmed against genuine RPG_RT.exe under wine (cycle #142, closing
      # the lead cycles #140/#141 both explicitly left open): a real type-9
      # special item repointed at a synthetic Teleport-type skill (Nepheshel's
      # own database has no Escape/Teleport-type skill or item to begin with
      # -- see docs/TODO.md's own cycle #142 entry for the full recipe, and
      # Scene::SkillMenu's identical #enter_teleport_target for the shared
      # citation) opened onto a solid map-coloured band across the whole top
      # two-thirds of the screen, no window border/gradient anywhere in it,
      # directly above the destination list's own full-width, bottom-anchored
      # box -- not the banner/grid merely covered (the destination box does
      # not span that height) nor narrowed (its own box runs the full
      # `SCREEN_W`, not `SCREEN_W - TARGET_W`). Tested at both ends of the
      # registered-destination-count boundary this cycle could reach (1 and 3
      # targets); both left the same bare band above the list. Cancelling out
      # (confirmed live, both counts) restores the ordinary full-width
      # `:items` banner and grid exactly, which #leave_teleport_target's own
      # rebuild (mirroring #enter_teleport_target) now matches.
      def enter_teleport_target
        if @desc_window
          @desc_window.dispose
          @desc_window = nil
        end
        if @item_window
          @item_window.dispose
          @item_window = nil
        end
        build_teleport_window
      end

      def leave_teleport_target
        @pending_item = nil
        @mode = :items
        if @teleport_window
          @teleport_window.dispose
          @teleport_window = nil
        end
        build_desc_window
        build_item_window
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
        # Back to full width now that :target mode's own narrowed banner is
        # gone -- see #left_panel_w. Rebuilds rather than a plain
        # #refresh_desc so the width actually changes back, not just the text.
        build_desc_window
      end

      # The description banner and the item-list box below it both run the
      # full screen width in :items mode, but narrow to leave room for the
      # right-anchored target panel once :target mode is entered -- confirmed
      # against genuine RPG_RT.exe under wine (cycle #140): both boxes sit
      # flush against the target panel's own left edge (`SCREEN_W -
      # TARGET_W`), not the full screen. :teleport_target never reaches this
      # formula at all -- #enter_teleport_target disposes both windows
      # outright rather than narrowing them (cycle #142; see its own doc
      # comment), so `@mode == :teleport_target` never calls #build_desc_
      # window/#build_item_window in the first place. Left branchless (only
      # :target narrows) rather than adding a dead :teleport_target case.
      def left_panel_w
        @mode == :target ? SCREEN_W - TARGET_W : SCREEN_W
      end

      # The highlighted item's flavour text, in a one-line banner across the
      # very top of the screen -- confirmed against genuine RPG_RT under
      # wine (e.g. "HPを80ポイント程度回復する" for a healing item), the same
      # gap Scene::EquipMenu had. Tracks the item under the cursor in :items
      # mode. Once :target mode narrows this banner (see #left_panel_w), real
      # RPG_RT switches its text too -- confirmed against genuine RPG_RT.exe
      # under wine (cycle #140): it shows the pending item's own *name*
      # ("薬草"), not its description, while target mode is open. This method
      # is never reached in :teleport_target mode at all (see
      # #enter_teleport_target, cycle #142) since that mode disposes
      # `@desc_window` outright rather than refreshing its text.
      def build_desc_window
        @desc_window.dispose if @desc_window
        w = left_panel_w
        inner_w = w - Window::BORDER * 2
        @desc_window = Window.new(0, 0, w, DESC_H)
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
        text = if it.nil?
                 ''
               elsif @mode == :target
                 it.name.to_s
               else
                 it.description.to_s
               end
        @desc_contents.clear
        @desc_contents.font.color = Color.new(255, 255, 255, 255)
        @desc_contents.draw_text 0, 0, @desc_contents.width, LINE_H, text
      end

      # Column width for the item grid (see the COLUMN_MAX comment above).
      def item_col_w
        (SCREEN_W - Window::BORDER * 2) / COLUMN_MAX
      end

      # The item grid itself in :items mode; a single-row "held count" box in
      # its place once :target mode is entered -- see #build_possessed_window.
      def build_item_window
        @item_window.dispose if @item_window
        if @mode == :target
          build_possessed_window
          return
        end
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

      # The "held count" box that replaces the item grid once :target mode is
      # entered -- confirmed against genuine RPG_RT.exe under wine (cycle
      # #140): the item list is not merely covered by the target panel, it is
      # replaced outright by a second, short box directly under the
      # (also-narrowed, see #left_panel_w) description banner -- together the
      # two read as the "narrower, split into two stacked boxes" cycle #132
      # first flagged as an open lead without investigating. Measured on a
      # single-target medicine (薬草) with a bag count of 5: the box sits at
      # the item grid's own top-left corner (`(0, DESC_H)`), is exactly
      # `DESC_H` tall (one row) regardless of how many items are actually in
      # the bag -- there is only ever the one pending item to report on here
      # -- and as wide as the narrowed banner above it. Its one line is the
      # database's own `possessed_items` term ("所持数"/"Possessed") flush
      # left, and the held count flush right (`align` 2) -- independently
      # matching `Scene::Map#draw_shop_status`'s own identical "term left,
      # count right" row and its own separately-measured `SHOP_STATUS_W ==
      # 136 == SCREEN_W - TARGET_W` panel width, a real recurring RPG_RT
      # layout rather than a coincidence of this one screen.
      #
      # :teleport_target does not get a possessed-count box of its own at
      # all -- confirmed against genuine RPG_RT.exe under wine (cycle #142):
      # unlike :target, the destination picker does not narrow-and-replace
      # the left column, it removes it outright (see #enter_teleport_
      # target's own doc comment).
      def build_possessed_window
        w = left_panel_w
        inner_w = w - Window::BORDER * 2
        @item_window = Window.new(0, DESC_H, w, DESC_H)
        @item_window.z = 400
        @item_window.windowskin = @skin
        c = Bitmap.new(inner_w, LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, LINE_H, term(:possessed_items, 'Possessed')
        count = @pending_item ? @state.party.item_count(@pending_item) : 0
        c.draw_text 0, 0, inner_w, LINE_H, count.to_s, 2
        @item_window.contents = c
      end

      # The actor-target picker's own geometry -- confirmed against a genuine
      # RPG_RT.exe under wine (cycle #132), replacing a guess this class had
      # never independently re-verified: a *bottom-anchored, full-width* bar
      # sized to `party.size * (LINE_H * 2)`, two lines per actor (name +
      # condition on the first, HP/MP on the second). Real RPG_RT instead
      # draws a **right-anchored panel the full height of the screen**,
      # sized the same regardless of party size (RPG2000's own party cap
      # keeps it at 4 members either way, well inside this fixed panel — the
      # same reasoning #move_battle_target_cursor's own doc comment, cycle
      # #131, already established for the battle-side target list), with
      # each actor on **three** lines -- name; level + HP; condition + MP --
      # not two, and the HP/MP *value* column starting partway across the
      # row rather than immediately after the label. There is also a blank
      # gutter to the left of every line, of a piece with the cursor
      # highlight (see #refresh_target_cursor below) -- cycle #132 guessed
      # this might be an undrawn face-graphic slot but could not confirm it
      # (Nepheshel's only reachable test actor, the debug save's solo
      # "デモ用" character, carries no faceset); cycle #136 then confirmed
      # the guess right for a *non-first* row (row 1: actor 2, ファル, drew
      # its real 48x48 FaceSet/face.png cell 1 at panel-local (8, 66)) but
      # left row 0's own offset unconfirmed. Settled this cycle (#137, with a
      # genuine RPG_RT.exe under wine): row 0 draws its face **flush at the
      # top of its own row** (panel-local (8, 0)), *not* at the same "+18px
      # into the row" offset row 1 (and, unconfirmed, every later row) uses.
      # Measured by giving the debug save's own sole actor (15, デモ用, no
      # native faceset) a live Change Actor Face (event code 10640) onto the
      # same FaceSet/face.png cell 1 actor 2 already carries, so row 0 could
      # be tested directly -- both alone and side-by-side with actor 2 (added
      # to the party without ever removing the original leader, cycle #136's
      # own proven-safe shape) so both rows' faces were visible in the same
      # capture at once: row 0's face top edge landed at native y ~0 (screen
      # y ~2-4 of a 640x480 capture) while row 1's landed at native y 66,
      # exactly reproducing cycle #136's own figure in the same frame --
      # ruling out a capture-to-capture calibration error -- and confirmed
      # independent of which row the cursor was actually highlighting (the
      # two faces stayed exactly where they were when the cursor moved from
      # row 0 to row 1, so this is a per-row-index quirk, not a
      # currently-selected-row one). Rows 2/3 (unreachable without risking
      # the party-growth crash below) are *not* confirmed to continue the
      # "+18" pattern past row 1 -- left as this fix's own open lead, the
      # same shape as cycle #132's original multi-row-stacking caveat.
      #
      # Left as a genuine, separate open lead this cycle could not chase
      # further (out of scope for the face question above): a synthetic
      # autostart page carrying *only* a Change Party Member and/or Change
      # Actor Face command or two (a short command list, well short of the
      # genuine Enemy-Encounter-through-EndBattle tail cycles #130-136's own
      # probes always spliced onto) crashed genuine RPG_RT.exe outright, but
      # only on the *next* screen transition (confirmed alive for a full 2s
      # after the map settled, dead within 0.3s of the following Escape) --
      # even a page with **no actor-related command at all** (two bare
      # BlankLines) reproduced it, while a *single*-command page (one
      # BlankLine) and the long genuine battle-tail-based pages (cycles
      # #130-136's own recipe, and this cycle's own working recipe) did not.
      # Command content is therefore not the trigger; something about a
      # *short* synthetic command list specifically is. Not chased further --
      # this cycle's own probes worked around it by keeping the spliced
      # command list exactly as long as cycles #130-136's proven-safe shape
      # (their full Enemy-Encounter-through-EndBattle tail, escaped out of
      # rather than fought) -- but it is a real, reproducible crash a future
      # cycle investigating short synthetic autostart pages should know about
      # before assuming a short page is automatically safe.
      #
      # Pixel values measured directly (640x480 wine capture, so divided by 2
      # for native 320x240 coordinates): panel at native (136, 0), 184x240 --
      # i.e. `SCREEN_W - TARGET_W` .. `SCREEN_W`, full `SCREEN_H`; each row's
      # own *content* (face + its three 16px text lines) is 48px tall, but
      # successive rows are pitched 58px apart, not 48 -- see
      # `TARGET_ROW_PITCH` below for the citation. The label column
      # (name/level/condition) starts 56px into the panel's own content area,
      # the value column (HP/MP) at 114px; the face 48x48 at x=8 (ending
      # exactly where the label column begins).
      TARGET_W = 184
      TARGET_ROW_H = LINE_H * 3
      # Follow-up (cycle #138, 2026-08-25): RPG_RT does *not* pack these rows
      # edge-to-edge at the 48px `TARGET_ROW_H` cycle #132 measured from a
      # single visible row -- it leaves a 10px gap between them, so
      # consecutive rows are 58px apart, and that 58px pitch applies to
      # *every* row, row 0 included. This supersedes cycle #137's own
      # `TARGET_FACE_Y_EXTRA` model (a flush row 0 plus a flat "+18" pushed
      # into every later row), which was a curve-fit to exactly two data
      # points (row 0 and row 1) that happens to be indistinguishable from
      # this one at row 1 -- `48*1 + 18 == 58*1 + 0` -- and only diverges
      # from row 2 onward, which cycle #137 could not yet reach. Confirmed
      # against genuine RPG_RT.exe under wine (Xvfb 640x480x16,
      # LIBGL_ALWAYS_SOFTWARE=1, matchbox-window-manager, LANG=ja_JP.UTF-8)
      # with a real 4-actor faceted party (デモ用 id 15 given actor 2's own
      # face via a live Change Actor Face, event code 10640, so row 0 could
      # be tested with a face too; ファル/ティララ/ディーヴァ, ids 2/3/4,
      # added via cycle #136's proven-safe Change Party Member technique) --
      # grown via a synthetic autostart event on a scratch copy of Map0012
      # whose command list is a live Change Actor Face plus three Change
      # Party Member commands prepended onto Map0478 event 2 page 2's own
      # genuine Enemy-Encounter-through-EndBattle tail (troop 103, escaped
      # out of via the battle options window's Escape entry), keeping the
      # spliced list at least as long as cycles #130-137's own proven-safe
      # shape throughout. All four faces template-matched pixel-exact
      # against `FaceSet/face.png`'s own cells (`compare -subimage-search`,
      # RMSE ~0) at content-local y = 0, 58, 116, 174 -- i.e. `58 * row`
      # exactly, no row-0 exception -- cross-confirmed by the selection
      # cursor's own top border (independently detected by its windowskin
      # colour) landing on the identical four values. This also resolves
      # cycle #137's own "row 0 face top edge landed at native y ~0" reading
      # as measurement slop, not a real flush-top special case: it was a
      # manual "screen y 2-4" estimate against a 640x480 capture, 8px off
      # the true value found here (screen y 16) -- the automated
      # template-match this cycle used is precise to the pixel and was
      # cross-checked two independent ways (face content and cursor border)
      # on two separate captures, so it supersedes that earlier estimate.
      # Bare arithmetic check: 4 rows at this 58px pitch top out at
      # content-local y `58 * 3 + 48 == 222`, two pixels inside this
      # method's own `SCREEN_H - Window::BORDER * 2 == 224`-tall content
      # bitmap with no room to spare -- a good sign this is the real
      # constant and not a coincidental near-fit.
      TARGET_ROW_PITCH = 58
      TARGET_LABEL_X = 56
      TARGET_VALUE_X = 114
      TARGET_FACE_X = 8
      TARGET_FACE_SIZE = 48

      def build_target_window
        @target_window.dispose if @target_window
        party = @state.party.actors
        inner_w = TARGET_W - Window::BORDER * 2
        @target_window = Window.new(SCREEN_W - TARGET_W, 0, TARGET_W, SCREEN_H)
        @target_window.z = 450
        @target_window.windowskin = @skin
        c = Bitmap.new(inner_w, SCREEN_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        party.each_with_index do |a, i|
          y = i * TARGET_ROW_PITCH
          draw_target_face c, a, y
          c.draw_text TARGET_LABEL_X, y, inner_w - TARGET_LABEL_X, LINE_H, a.name.to_s
          c.draw_text TARGET_LABEL_X, y + LINE_H, TARGET_VALUE_X - TARGET_LABEL_X, LINE_H,
                      "#{term(:level_short, 'Lv')} #{a.level}"
          # HP/MP recolor the same way the field Status screen's row does
          # (Scene::Base#draw_stat_segment, ported from EasyRPG's
          # `Window_Base::GetValueFontColor` -- see that helper's own
          # citation): only the current-value figure, never its label or max,
          # dims to knockout gray at 0 HP or critical red/orange at or below a
          # quarter of max. This target list used to draw both as flat-white
          # text, the same gap the Status screen and battle status panel each
          # had before their own earlier fixes (see docs/TODO.md).
          draw_stat_segment(c, TARGET_VALUE_X, y + LINE_H, inner_w, LINE_H,
                            "#{term(:hp_short, 'HP')} ", a.hp, a.display_max_hp, true, @skin)
          # RPG_RT's target list shows each member's condition (its
          # Window_ActorTarget draws one) -- which is most of the point of the
          # list, since it is where you pick who to use an antidote on.
          draw_actor_state c, a, TARGET_LABEL_X, y + LINE_H * 2,
                           TARGET_VALUE_X - TARGET_LABEL_X, LINE_H, @skin
          draw_stat_segment(c, TARGET_VALUE_X, y + LINE_H * 2, inner_w, LINE_H,
                            "#{term(:mp_short, 'MP')} ", a.mp, a.display_max_mp, false, @skin)
        end
        @target_window.contents = c
        refresh_target_cursor
      end

      # Row `row`'s 48x48 face crop, or nothing at all for an actor with no
      # faceset set (or one that fails to load) -- matching the same "a
      # missing portrait draws nothing" rule `Scene::Map#load_face_bitmap`/
      # `#draw_kana_face` and `Scene::Battle#draw_battle_gauge_face` already
      # use, and `#respond_to?`-guarded the same way for a bare test-fixture
      # actor with no faceset fields at all. Flush at the row's own top for
      # every row, row 0 included -- see `TARGET_ROW_PITCH`'s own citation
      # above for why an earlier cycle once thought row 0 was special.
      def draw_target_face(c, actor, y)
        return unless actor.respond_to?(:faceset_name)
        face = load_face_bitmap(actor.faceset_name)
        return unless face
        index = actor.respond_to?(:faceset_index) ? (actor.faceset_index || 0) : 0
        src = Rect.new((index % 4) * TARGET_FACE_SIZE, (index / 4) * TARGET_FACE_SIZE,
                       TARGET_FACE_SIZE, TARGET_FACE_SIZE)
        c.blt TARGET_FACE_X, y, face, src
      end

      # This screen has no `@map` to borrow `#load_face_bitmap` from (unlike
      # Scene::Battle's own face draw) -- mirrors `Scene::SaveLoad#load_face_
      # bitmap` exactly, including the colour-key transparency every FaceSet
      # sheet needs.
      def load_face_bitmap(name)
        return nil if name.nil? || name.empty?
        Bitmap.new "FaceSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{name}' load failed: #{e.message}"
        nil
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
          # Content-width, not window-width, matching the measured single-row
          # cursor's own left edge (see the geometry comment above) --
          # `TARGET_LABEL_X - 2` lands the highlight's left edge right at the
          # measured card border, a couple of pixels ahead of the text itself.
          # The box's own *height* stays `TARGET_ROW_H` (48px, matching the
          # row's own content) even though rows are pitched 58px apart --
          # confirmed cycle #138: the cursor border measured 48px tall at
          # every row, leaving the same 10px gap below it that separates the
          # rows themselves (see `TARGET_ROW_PITCH`'s own citation).
          @target_window.cursor_rect =
            Rect.new(TARGET_LABEL_X - 2, @target_index * TARGET_ROW_PITCH,
                     @target_window.contents.width - (TARGET_LABEL_X - 2), TARGET_ROW_H)
        end
      end

    end

  end
end
