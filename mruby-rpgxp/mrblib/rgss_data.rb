# RPG Maker XP data layer.
#
# An RMXP project keeps its whole database in Data/*.rxdata files. Each one is a
# Ruby `Marshal` dump of the editor's `RPG::*` objects (and the RGSS value types
# `Table`/`Color`/`Tone`, which use custom `_dump`/`_load`). Unlike the RPG2000
# LCF format — a bespoke chunk stream this project hand-parses in mruby-lcf —
# these files load straight through `Marshal.load`, because the bundled
# mruby-marshal gem reads the 4.8 stream and instantiates each object by name.
#
# So the "parser" for XP is just the class table below: every class the editor
# serialises has to exist (Marshal allocates it and sets its instance variables
# directly, calling no `initialize`), and the `Table`/`Color`/`Tone` value types
# have to answer `_load`. `Color`/`Tone`/`Table` already ship as native RGSS
# classes (mruby-rgss, src/lib.cxx) with `_dump`/`_load`, and this file is loaded
# where `Object` includes `RGSS`, so the bare `Table`/`Color`/`Tone` names in the
# stream resolve to them. Here we only need to declare the `RPG::*` schema.
#
# The classes are plain attribute holders. They are deliberately behaviour-free:
# they mirror the editor's data model 1:1 so the runtime (RPGXP scenes) and the
# host-side test-bed check (scripts/rpgxp_testbed_check.rb, which loads this exact
# file under CRuby over a real game) read the same fields. Field names and their
# nesting follow the RPGXP RGSS reference:
# https://www.rpgmaker.fixato.org/Manual/RPGXP/ .

module RPG
  # A referenced BGM/BGS/ME/SE: a file name (under Audio/<kind>/) plus volume and
  # pitch. Used all over System/Map for the auto-play and system sounds.
  class AudioFile
    attr_accessor :name, :volume, :pitch
  end

  class Actor
    attr_accessor :id, :name, :class_id, :initial_level, :final_level,
                  :exp_basis, :exp_inflation, :character_name, :character_hue,
                  :battler_name, :battler_hue, :parameters,
                  :weapon_id, :armor1_id, :armor2_id, :armor3_id, :armor4_id,
                  :weapon_fix, :armor1_fix, :armor2_fix, :armor3_fix, :armor4_fix
  end

  class Class
    attr_accessor :id, :name, :position, :weapon_set, :armor_set,
                  :element_ranks, :state_ranks, :learnings

    class Learning
      attr_accessor :level, :skill_id
    end
  end

  class Item
    attr_accessor :id, :name, :icon_name, :description, :scope, :occasion,
                  :animation1_id, :animation2_id, :menu_se, :common_event_id,
                  :price, :consumable, :parameter_type, :parameter_points,
                  :recover_hp_rate, :recover_hp, :recover_sp_rate, :recover_sp,
                  :hit, :pdef_f, :mdef_f, :variance, :element_set,
                  :plus_state_set, :minus_state_set
  end

  class Skill
    attr_accessor :id, :name, :icon_name, :description, :scope, :occasion,
                  :animation1_id, :animation2_id, :menu_se, :common_event_id,
                  :sp_cost, :power, :atk_f, :eva_f, :str_f, :dex_f, :agi_f,
                  :int_f, :hit, :pdef_f, :mdef_f, :variance, :element_set,
                  :plus_state_set, :minus_state_set
  end

  class Weapon
    attr_accessor :id, :name, :icon_name, :description, :animation1_id,
                  :animation2_id, :price, :atk, :pdef, :mdef, :str_plus,
                  :dex_plus, :agi_plus, :int_plus, :element_set,
                  :plus_state_set, :minus_state_set
  end

  class Armor
    attr_accessor :id, :name, :icon_name, :description, :kind, :auto_state_id,
                  :price, :pdef, :mdef, :eva, :str_plus, :dex_plus, :agi_plus,
                  :int_plus, :guard_element_set, :guard_state_set
  end

  class State
    attr_accessor :id, :name, :animation_id, :restriction, :nonresistance,
                  :zero_hp, :cant_get_exp, :cant_evade, :slip_damage,
                  :rating, :hit_rate, :maxhp_rate, :maxsp_rate, :str_rate,
                  :dex_rate, :agi_rate, :int_rate, :atk_rate, :pdef_rate,
                  :mdef_rate, :eva, :battle_only, :hold_turn, :auto_release_prob,
                  :shock_release_prob, :guard_element_set, :plus_state_set,
                  :minus_state_set
  end

  class Animation
    attr_accessor :id, :name, :animation_name, :animation_hue, :position,
                  :frame_max, :frames, :timings

    class Frame
      attr_accessor :cell_max, :cell_data
    end

    class Timing
      attr_accessor :frame, :se, :flash_scope, :flash_color, :flash_duration,
                    :condition
    end
  end

  class Tileset
    attr_accessor :id, :name, :tileset_name, :autotile_names, :panorama_name,
                  :panorama_hue, :fog_name, :fog_hue, :fog_opacity,
                  :fog_blend_type, :fog_zoom, :fog_sx, :fog_sy, :battleback_name,
                  :passages, :priorities, :terrain_tags
  end

  class CommonEvent
    attr_accessor :id, :name, :trigger, :switch_id, :list
  end

  class MapInfo
    attr_accessor :name, :parent_id, :order, :expanded, :scroll_x, :scroll_y
  end

  class Map
    attr_accessor :tileset_id, :width, :height, :autoplay_bgm, :bgm,
                  :autoplay_bgs, :bgs, :encounter_list, :encounter_step,
                  :data, :events
  end

  # A map event: a named grid entity at (x, y) with one or more pages, only the
  # top-most page whose Condition is satisfied being active at a time.
  class Event
    attr_accessor :id, :name, :x, :y, :pages

    class Page
      attr_accessor :condition, :graphic, :move_type, :move_speed,
                    :move_frequency, :move_route, :walk_anime, :step_anime,
                    :direction_fix, :through, :always_on_top, :trigger, :list

      # Gate for a page: any/all of switch1, switch2, a variable threshold, and a
      # self switch. A page with everything invalid is unconditionally active.
      class Condition
        attr_accessor :switch1_valid, :switch1_id, :switch2_valid, :switch2_id,
                      :variable_valid, :variable_id, :variable_value,
                      :self_switch_valid, :self_switch_ch
      end

      # What the event looks like: either a tile (tile_id >= 384) or a character
      # graphic (character_name) with hue/direction/pattern/opacity/blend.
      class Graphic
        attr_accessor :tile_id, :character_name, :character_hue, :direction,
                      :pattern, :opacity, :blend_type
      end
    end
  end

  # One event-command line: a numeric code, an indent level and a parameter
  # list whose shape depends on the code.
  class EventCommand
    attr_accessor :code, :indent, :parameters
  end

  # A movement script: a list of MoveCommands with repeat/skippable flags.
  class MoveRoute
    attr_accessor :repeat, :skippable, :list
  end

  class MoveCommand
    attr_accessor :code, :parameters
  end

  class Enemy
    attr_accessor :id, :name, :battler_name, :battler_hue, :maxhp, :maxsp,
                  :str, :dex, :agi, :int, :atk, :pdef, :mdef, :eva,
                  :animation1_id, :animation2_id, :element_ranks, :state_ranks,
                  :actions, :exp, :gold, :item_id, :weapon_id, :armor_id,
                  :treasure_prob

    class Action
      attr_accessor :kind, :basic, :skill_id, :condition_turn_a,
                    :condition_turn_b, :condition_hp, :condition_level,
                    :condition_switch_id, :rating
    end
  end

  class Troop
    attr_accessor :id, :name, :members, :pages

    class Member
      attr_accessor :enemy_id, :x, :y, :hidden, :immortal
    end

    class Page
      attr_accessor :condition, :span, :list

      class Condition
        attr_accessor :turn_valid, :enemy_valid, :actor_valid, :switch_valid,
                      :turn_a, :turn_b, :enemy_index, :enemy_hp, :actor_id,
                      :actor_hp, :switch_id
      end
    end
  end

  # The single System object: start position, party, referenced graphics/audio,
  # element/switch/variable name tables, and the vocabulary (Words).
  class System
    attr_accessor :magic_number, :party_members, :elements, :switches,
                  :variables, :windowskin_name, :title_name, :gameover_name,
                  :battle_transition, :title_bgm, :battle_bgm, :battle_end_me,
                  :gameover_me, :cursor_se, :decision_se, :cancel_se, :buzzer_se,
                  :equip_se, :shop_se, :save_se, :load_se, :battle_start_se,
                  :escape_se, :actor_collapse_se, :enemy_collapse_se,
                  :words, :test_battlers, :test_troop_id, :start_map_id,
                  :start_x, :start_y, :battleback_name, :battler_name,
                  :battler_hue, :edit_map_id

    # In-game vocabulary shown by the default menus/battle UI.
    class Words
      attr_accessor :gold, :hp, :sp, :str, :dex, :agi, :int, :atk, :pdef,
                    :mdef, :weapon, :armor1, :armor2, :armor3, :armor4,
                    :attack, :skill, :guard, :item, :equip
    end

    class TestBattler
      attr_accessor :actor_id, :level, :weapon_id,
                    :armor1_id, :armor2_id, :armor3_id, :armor4_id
    end
  end
end

class RPGXP
  # Loads and holds an RMXP project's database. Mirrors LCF::Database's role for
  # the RPG2000 side, but each accessor is simply the `Marshal.load` of the
  # matching Data/*.rxdata file. The array-typed tables (Actors, Items, ...) are
  # 1-based with a nil at index 0, exactly as the editor writes them; MapInfos is
  # a Hash keyed by map id. Maps themselves are large and loaded on demand.
  class RGSSData
    # The Data/ files that hold an index-addressed array or a hash of records.
    # Each becomes a reader of the same (lower-cased, singular-ish) name.
    ARRAY_FILES = {
      actors: "Actors", classes: "Classes", skills: "Skills",
      items: "Items", weapons: "Weapons", armors: "Armors",
      enemies: "Enemies", troops: "Troops", states: "States",
      animations: "Animations", tilesets: "Tilesets",
      common_events: "CommonEvents"
    }.freeze

    def initialize(game_dir)
      @game_dir = game_dir
      @system = load_data("System")
      @map_infos = load_data("MapInfos")
      @cache = {}
      ARRAY_FILES.each do |name, file|
        @cache[name] = load_data(file)
      end
    end

    attr_reader :system, :map_infos, :game_dir

    ARRAY_FILES.each_key do |name|
      define_method(name) { @cache[name] }
    end

    # Load one map (Data/MapNNN.rxdata) by id. Maps are big, so they are not
    # cached with the rest of the database — the caller loads the one it needs.
    def load_map(id)
      load_data(format("Map%03d", id))
    end

    # Absolute path of a Data/ entry.
    def data_path(base)
      "#{@game_dir}/Data/#{base}.rxdata"
    end

    private

    def load_data(base)
      File.open(data_path(base), "rb") { |f| Marshal.load(f.read) }
    end
  end
end
