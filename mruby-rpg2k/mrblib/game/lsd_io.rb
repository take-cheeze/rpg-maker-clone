# Game::State's RPG_RT-interop (.lsd) save/load path, split out of mrblib/
# game.rb's own #to_h/.load Marshal round-trip: to_lsd/export_lsd exist so a
# Save<N>.lsd this game writes is readable by real RPG_RT and other
# RPG2000/2003 tooling, and from_lsd exists so a genuine editor-written
# Save<N>.lsd
# can be loaded here in turn -- see main.rb's own #save_game/#load_save_state
# comments for how the two formats relate (the Marshal dump is this game's
# own authoritative save; the .lsd export/import is a best-effort, secondary
# interop path layered on top of it, not required for Save/Continue to work
# at all).
#
# wio has no PC to hand a save file to and no editor tooling of its own to
# receive one from, so this whole file is dropped from that build alone (see
# mrbgem.rake) -- main.rb's own export_lsd/load_save_state guard each call
# with respond_to? so Save/Continue keeps working there through the Marshal
# path unchanged, just without the .lsd side effect/fallback. `Dir.glob(...)
# .sort` loads this file after mrblib/game.rb regardless of target
# (`game.rb` < `game/lsd_io.rb` lexically), so Game::State already exists by
# the time this file's own reopening runs. See docs/adr/0128-wio-strip-lsd-
# interop.md.

module Game
  class State
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
  end
end
