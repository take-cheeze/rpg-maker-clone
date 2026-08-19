# RPG Maker VX (RGSS2) and VX Ace (RGSS3) data schema.
#
# Both editions store their database exactly the way RPG Maker XP does — one
# Ruby `Marshal` dump per `Data/` file — so, as for XP (see
# mruby-rpgxp/mrblib/rgss_data.rb), the "parser" is just the class table below:
# `Marshal.load` allocates each object by name and sets its instance variables
# directly, calling no `initialize`. Only the file extension changes:
# `.rvdata` for VX, `.rvdata2` for VX Ace. The RGSS value types
# (`Table`/`Color`/`Tone`/`Rect`) are the native mruby-rgss classes bound at the
# top level by mruby-rpgxp's lib.rb, so the bare names in the stream resolve.
#
# What *does* change is the schema. RGSS2 reworked the RPG2000-era record layout
# XP used (icon indices instead of icon file names, `parameters` tables, faces,
# vehicles, terms), and RGSS3 reworked it again around a feature system: most
# records gain `features` and derive from `RPG::BaseItem`, skills/items carry a
# `damage` formula plus an `effects` list instead of fixed recovery fields, and
# actors/classes moved their stats into `RPG::Class#params`.
#
# ## One RPG:: namespace, three editions
#
# A single build links the XP and VX runtimes, and `Marshal` resolves a class by
# its absolute path from `Object` — so `RPG::Actor` in an `.rvdata2` stream and
# `RPG::Actor` in an `.rxdata` stream are necessarily the *same* class. This file
# therefore reopens the shared classes and adds the RGSS2/RGSS3 fields rather
# than declaring a competing schema; a record only ever carries the ivars its own
# stream wrote, so the unused accessors simply read back nil.
#
# The RGSS3 superclass chain (BaseItem → UsableItem / EquipItem → Skill / Item /
# Weapon / Armor / Actor / Class / Enemy / State) is real inheritance, not just
# documented in a comment: a genuine VX Ace project exposes these as editable
# script sections (the editor's "RPG" folder), and every one of them reasserts
# its superclass on its very first line, e.g. `class RPG::Actor <
# RPG::BaseItem`. Since a class's superclass cannot change once set, and
# mruby-rpgxp/mrblib/rgss_data.rb declares these classes first (XP has no
# BaseItem concept, but the build is shared), the chain has to start there —
# see the comment above `class BaseItem` in that file. This file only reopens
# them to add the RGSS2/RGSS3 fields (via the `*Fields` modules, still needed
# for BaseItem/UsableItem/EquipItem's own fields) rather than declaring a
# competing schema; a record only ever carries the ivars its own stream wrote,
# so the unused accessors simply read back nil. Everything here is deliberately
# behaviour-free: these are attribute holders that mirror the editor's data
# model 1:1, so the runtime and the host-side check
# (scripts/rpgvx_testbed_check.rb, which loads this exact file under CRuby)
# read the same fields.
#
# Field names and their nesting follow the RGSS2 / RGSS3 references (the VX and
# VX Ace help files' "RPG module" chapters); see
# docs/adr/0024-rpgvx-rgss2-rgss3-data-layer.md for the sourcing. Fields present
# in only one edition are marked `(VX)` or `(Ace)`.

module RPG
  # ---- RGSS3 record bases ---------------------------------------------------

  # Fields every database record carries. VX has `id`/`name`/`icon_index`/
  # `description`/`note`; VX Ace adds `features`, the list of
  # `RPG::BaseItem::Feature` entries that replaced RGSS2's fixed trait fields.
  module BaseItemFields
    attr_accessor :id, :name, :icon_index, :description, :features, :note
  end

  # Fields of a usable (skill / item). RGSS2 spells its effect out in fixed
  # fields (`base_damage`, `atk_f`, the recovery rates on Item); RGSS3 replaced
  # them with a `damage` formula object plus a list of `effects`.
  module UsableItemFields
    include BaseItemFields

    attr_accessor :scope, :occasion, :speed, :animation_id
    # RGSS2 (VX).
    attr_accessor :common_event_id, :base_damage, :variance, :atk_f, :spi_f,
                  :physical_attack, :damage_to_mp, :absorb_damage,
                  :ignore_defense, :element_set, :plus_state_set,
                  :minus_state_set
    # RGSS3 (Ace).
    attr_accessor :success_rate, :repeats, :tp_gain, :hit_type, :damage,
                  :effects
  end

  # Fields of an equippable (weapon / armour). RGSS3 only; VX's Weapon/Armor
  # spell their price and stat bonuses out individually (see below).
  module EquipItemFields
    include BaseItemFields

    attr_accessor :price, :etype_id, :params
  end

  # The abstract RGSS3 record classes. Nothing is ever serialised *as* one, but
  # `Feature`, `Damage` and `Effect` are nested inside them, so the namespaces
  # have to exist — and having them carry their fields keeps the documented
  # hierarchy honest.
  class BaseItem
    include BaseItemFields

    # An RGSS3 trait: a `code` (element rate, parameter, skill add, ...), the
    # `data_id` it applies to and its `value`.
    class Feature
      attr_accessor :code, :data_id, :value
    end
  end

  class UsableItem < BaseItem
    include UsableItemFields

    # An RGSS3 damage formula: `type` (none/HP damage/MP recover/...), the
    # element, the Ruby `formula` string the engine evals, its `variance`
    # percentage and whether it can crit.
    class Damage
      attr_accessor :type, :element_id, :formula, :variance, :critical
    end

    # One RGSS3 use effect (recover HP, add state, learn skill, ...).
    class Effect
      attr_accessor :code, :data_id, :value1, :value2
    end
  end

  class EquipItem < BaseItem
    include EquipItemFields
  end

  # ---- Audio ----------------------------------------------------------------

  # RGSS2 introduced one class per audio slot. They are plain AudioFile
  # subclasses in the data (RGSS gives them `play`/`stop` helpers); a stream
  # names them, so they must exist. AudioFile itself is declared by
  # mruby-rpgxp's schema and shared.
  class AudioFile
    attr_accessor :name, :volume, :pitch
  end

  class BGM < AudioFile
    attr_accessor :pos # (Ace) resume position, saved with the game
  end

  class BGS < AudioFile
    attr_accessor :pos # (Ace)
  end

  class ME < AudioFile
  end

  class SE < AudioFile
  end

  # ---- Database records -----------------------------------------------------

  # BaseItem's fields (id/name/icon_index/description/features/note) come from
  # `< BaseItem`, set by mruby-rpgxp/mrblib/rgss_data.rb's first declaration —
  # see the comment there.
  class Actor
    attr_accessor :class_id, :initial_level, :character_name, :character_index,
                  :face_name, :face_index
    # (VX) stats live on the actor, as in XP, and equipment is five id fields.
    attr_accessor :exp_basis, :exp_inflation, :parameters, :weapon_id,
                  :armor1_id, :armor2_id, :armor3_id, :armor4_id,
                  :two_swords_style, :fix_equipment, :auto_battle,
                  :super_guard, :pharmacology, :critical_bonus
    # (Ace) stats moved to the class; equipment is one `equips` array and the
    # traits above became `features`.
    attr_accessor :nickname, :max_level, :equips
  end

  class Class
    attr_accessor :learnings
    # (VX)
    attr_accessor :position, :weapon_set, :armor_set, :element_ranks,
                  :state_ranks, :skill_name_valid, :skill_name
    # (Ace) the level-curve parameters and the 8 x max-level stat table.
    attr_accessor :exp_params, :params

    class Learning
      attr_accessor :level, :skill_id, :note
    end
  end

  class Skill
    attr_accessor :mp_cost, :message1, :message2
    attr_accessor :hit # (VX)
    # (Ace)
    attr_accessor :stype_id, :tp_cost, :required_wtype_id1, :required_wtype_id2
  end

  class Item
    attr_accessor :price, :consumable
    # (VX)
    attr_accessor :hp_recovery_rate, :hp_recovery, :mp_recovery_rate,
                  :mp_recovery, :parameter_type, :parameter_points
    attr_accessor :itype_id # (Ace) normal item / key item
  end

  class Weapon
    attr_accessor :animation_id
    # (VX)
    attr_accessor :hit, :atk, :def, :spi, :agi, :two_handed, :fast_attack,
                  :dual_attack, :critical_bonus, :element_set, :state_set
    attr_accessor :wtype_id # (Ace)
  end

  class Armor
    # (VX) — `kind` is the slot (shield/helmet/body/accessory) VX Ace renamed to
    # `etype_id`, with `atype_id` becoming the armour *type*.
    attr_accessor :kind, :eva, :atk, :def, :spi, :agi, :prevent_critical,
                  :half_mp_cost, :double_exp_gain, :auto_hp_recover,
                  :element_set, :state_set
    attr_accessor :atype_id # (Ace)
  end

  class Enemy
    attr_accessor :battler_name, :battler_hue, :exp, :gold, :actions
    # (VX)
    attr_accessor :maxhp, :maxmp, :atk, :def, :spi, :agi, :hit, :eva,
                  :drop_item1, :drop_item2, :levitate, :has_critical,
                  :element_ranks, :state_ranks
    # (Ace) the eight-stat array and the three-slot drop table.
    attr_accessor :params, :drop_items

    class Action
      attr_accessor :skill_id, :condition_type, :condition_param1,
                    :condition_param2, :rating
      attr_accessor :kind, :basic # (VX) attack / defend / escape / skill
    end

    class DropItem
      attr_accessor :kind, :denominator
      attr_accessor :item_id, :weapon_id, :armor_id # (VX)
      attr_accessor :data_id                        # (Ace)
    end
  end

  class State
    attr_accessor :restriction, :priority, :message1, :message2, :message3,
                  :message4
    # (VX)
    attr_accessor :atk_rate, :def_rate, :spi_rate, :agi_rate, :nonresistance,
                  :offset_by_opposite, :slip_damage, :reduce_hit_ratio,
                  :battle_only, :release_by_damage, :hold_turn,
                  :auto_release_prob, :element_set, :state_set
    # (Ace) removal is described declaratively instead.
    attr_accessor :remove_at_battle_end, :remove_by_restriction,
                  :auto_removal_timing, :min_turns, :max_turns,
                  :remove_by_damage, :chance_by_damage, :remove_by_walking,
                  :steps_to_remove
  end

  # RGSS2 split the single XP animation sheet into two (`animation1_*` behind
  # the battler, `animation2_*` in front).
  class Animation
    attr_accessor :id, :name, :animation1_name, :animation1_hue,
                  :animation2_name, :animation2_hue, :position, :frame_max,
                  :frames, :timings

    class Frame
      attr_accessor :cell_max, :cell_data
    end

    class Timing
      attr_accessor :frame, :se, :flash_scope, :flash_color, :flash_duration
    end
  end

  # (Ace) VX Ace restored per-map tilesets: nine sheet names (A1..A5, B..E) and
  # one flags table of 8192 passage/priority/terrain words. VX has a single
  # game-wide tileset whose flags live in `RPG::System#passages`, and no
  # `Tilesets` file at all.
  class Tileset
    attr_accessor :id, :mode, :name, :tileset_names, :flags, :note
  end

  # (VX) A named rectangle on a map with its own encounter list — VX Ace dropped
  # areas in favour of the region ids painted into the map's fourth data layer.
  class Area
    attr_accessor :id, :name, :map_id, :rect, :encounter_list, :order
  end

  class CommonEvent
    attr_accessor :id, :name, :trigger, :switch_id, :list

    # `trigger`: 0 none, 1 autorun, 2 parallel -- real RGSS3's stock
    # Game_Map#setup_autorun_common_event/#parallel_common_events call these
    # predicates directly rather than comparing `trigger` themselves, and
    # every VX Ace project's default Game_Map does so unmodified.
    def autorun?
      @trigger == 1
    end

    def parallel?
      @trigger == 2
    end
  end

  class MapInfo
    attr_accessor :name, :parent_id, :order, :expanded, :scroll_x, :scroll_y
  end

  class Map
    attr_accessor :width, :height, :scroll_type, :autoplay_bgm, :bgm,
                  :autoplay_bgs, :bgs, :disable_dashing, :encounter_list,
                  :encounter_step, :parallax_name, :parallax_loop_x,
                  :parallax_loop_y, :parallax_sx, :parallax_sy, :parallax_show,
                  :data, :events
    # (Ace) — VX has neither a per-map tileset nor a per-map battleback, and its
    # `encounter_list` is a plain troop-id array where Ace's holds Encounters.
    attr_accessor :display_name, :tileset_id, :specify_battleback,
                  :battleback1_name, :battleback2_name, :note

    # (Ace) one weighted encounter entry, optionally restricted to regions.
    class Encounter
      attr_accessor :troop_id, :weight, :region_set
    end
  end

  class Event
    attr_accessor :id, :name, :x, :y, :pages

    class Page
      attr_accessor :condition, :graphic, :move_type, :move_speed,
                    :move_frequency, :move_route, :walk_anime, :step_anime,
                    :direction_fix, :through, :priority_type, :trigger, :list

      # RGSS2 added the item / actor page conditions and replaced XP's
      # `always_on_top` with the three-way `priority_type` on the page.
      class Condition
        attr_accessor :switch1_valid, :switch2_valid, :variable_valid,
                      :self_switch_valid, :item_valid, :actor_valid,
                      :switch1_id, :switch2_id, :variable_id, :variable_value,
                      :self_switch_ch, :item_id, :actor_id
      end

      # A character sheet holds eight characters from VX on, so the graphic
      # picks one with `character_index` instead of XP's per-file hue.
      class Graphic
        attr_accessor :tile_id, :character_name, :character_index, :direction,
                      :pattern
      end
    end
  end

  class EventCommand
    attr_accessor :code, :indent, :parameters

    # Real RGSS documents this constructor -- scripts synthesize new event
    # commands with it directly (this same release's error-log utility
    # inserts a `EventCommand.new(355, 0, [...])` "script call" at the front
    # of every common event's own list, to stamp its id before running).
    def initialize(code = 0, indent = 0, parameters = [])
      @code = code
      @indent = indent
      @parameters = parameters
    end
  end

  class MoveRoute
    attr_accessor :repeat, :skippable, :wait, :list
  end

  class MoveCommand
    attr_accessor :code, :parameters
  end

  class Troop
    attr_accessor :id, :name, :members, :pages

    class Member
      attr_accessor :enemy_id, :x, :y, :hidden
      attr_accessor :immortal # (VX)
    end

    class Page
      attr_accessor :condition, :span, :list

      class Condition
        attr_accessor :turn_ending, :turn_valid, :enemy_valid, :actor_valid,
                      :switch_valid, :turn_a, :turn_b, :enemy_index, :enemy_hp,
                      :actor_id, :actor_hp, :switch_id
      end
    end
  end

  class System
    attr_accessor :game_title, :version_id, :party_members, :elements,
                  :switches, :variables, :boat, :ship, :airship, :title_bgm,
                  :battle_bgm, :battle_end_me, :gameover_me, :sounds,
                  :test_battlers, :test_troop_id, :start_map_id, :start_x,
                  :start_y, :terms, :battler_name, :battler_hue, :edit_map_id
    # (VX) the game-wide tileset's 8192-entry passage table.
    attr_accessor :passages
    # (Ace)
    attr_accessor :japanese, :currency_unit, :skill_types, :weapon_types,
                  :armor_types, :title1_name, :title2_name, :opt_draw_title,
                  :opt_use_midi, :opt_transparent, :opt_followers,
                  :opt_slip_death, :opt_floor_death, :opt_display_tp,
                  :opt_extra_exp, :window_tone, :battleback1_name,
                  :battleback2_name

    # The in-game vocabulary (XP's `RPG::System::Words`). VX names every term
    # individually; VX Ace collapsed them into four indexed arrays.
    class Terms
      # (VX)
      attr_accessor :level, :level_a, :hp, :hp_a, :mp, :mp_a, :atk, :def, :spi,
                    :agi, :weapon, :armor1, :armor2, :armor3, :armor4,
                    :weapon1, :weapon2, :attack, :skill, :guard, :item, :equip,
                    :status, :save, :game_end, :fight, :escape, :new_game,
                    :continue, :shutdown, :to_title, :cancel, :gold
      # (Ace) basic[8] (level/HP/MP/TP...), params[8], etypes[5], commands[23].
      attr_accessor :basic, :params, :etypes, :commands
    end

    # A boat / ship / airship: its sheet, start position and BGM.
    class Vehicle
      attr_accessor :character_name, :character_index, :bgm, :start_map_id,
                    :start_x, :start_y
    end

    class TestBattler
      attr_accessor :actor_id, :level
      attr_accessor :weapon_id, :armor1_id, :armor2_id, :armor3_id,
                    :armor4_id # (VX)
      attr_accessor :equips    # (Ace)
    end
  end
end
