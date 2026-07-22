module LCF
  module Schema
    COMMON_EVENT = {
      1 => {
        name: :name, type: :string, default: ''
      },
      11 => {
        name: :start_term, type: :int, default: 5, enums: {
          3 => :auto_start,
          4 => :parallel,
          5 => :called,
        }
      },
      12 => {
        name: :need_flag, type: :bool, default: false
      },
      13 => {
        name: :switch_id, type: :int, default: 1
      },
      21 => {
        name: :event_size, type: :int
      },
      22 => {
        name: :event, type: :event
      },
    }

    BGM = {
      1 => { name: :file, type: :string },
      2 => { name: :fade_in, type: :int, default: 0 },
      3 => { name: :volume, type: :int, default: 100 },
      4 => { name: :pitch, type: :int, default: 100 },
      5 => { name: :balance, type: :int, default: 50 },
    }

    SE = {
      1 => { name: :file, type: :string },
      3 => { name: :volume, type: :int, default: 100 },
      4 => { name: :pitch, type: :int, default: 100 },
      5 => { name: :balance, type: :int, default: 50 },
    }

    DATABASE = {
      name: :DataBase, type: :Array1D,
      elements: {
        11 => {
          name: :player, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :title, type: :string, default: '' },
            3 => { name: :charset_name, type: :string, default: '' },
            4 => { name: :charset_index, type: :int, default: 0 },
            5 => { name: :semi_transparent, type: :bool, default: false },
            7 => { name: :initial_level, type: :int, default: 1 },
            8 => { name: :max_level, type: :int, default: -> { LCF.max_level } },
            9 => { name: :has_critical_rate, type: :bool, default: true },
            10 => { name: :critical_rate, type: :int, default: 30 },

            15 => { name: :faceset_name, type: :string, default: '' },
            16 => { name: :faceset_index, type: :int, default: 0 },

            21 => { name: :double_hand, type: :bool, default: false },
            22 => { name: :force_auto_move, type: :bool, default: false },
            23 => { name: :strong_defence, type: :bool, default: false },

            31 => { name: :status, type: :int16_array, order: [:max_hp, :max_mp, :atk, :def, :int, :agi] },

            41 => { name: :exp_basic, type: :int, default: -> { LCF.exp_default } },
            42 => { name: :exp_increase, type: :int, default: -> { LCF.exp_default } },
            43 => { name: :exp_correction, type: :int, default: -> { LCF.exp_default } },

            44 => { name: :initial_equipment, type: :int16_array, order: [:weapon, :shield, :armor, :head, :other] },
          }
        },
        12 => {
          name: :skill, type: :Array2D,
          elements: {
          }
        },
        13 => {
          name: :Item, type: :Array2D,
          elements: {
          }
        },
        14 => {
          name: :Enemy, type: :Array2D,
          elements: {
          }
        },
        15 => {
          name: :EnemyGroup, type: :Array2D,
          elements: {
          }
        },
        16 => {
          name: :Terrain, type: :Array2D,
          elements: {
          }
        },
        17 => {
          name: :Property, type: :Array2D,
          elements: {
          }
        },
        18 => {
          name: :Situation, type: :Array2D,
          elements: {
          }
        },
        19 => {
          name: :BattleAnime, type: :Array2D,
          elements: {
          }
        },
        20 => {
          name: :ChipSet, type: :Array2D,
          elements: {
            1 => {
              name: :name, type: :string, default: ''
            },
            2 => {
              name: :chipset_name, type: :string, default: ''
            }
          }
        },
        21 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E7%94%A8%E8%AA%9E
          name: :term, type: :Array1D,
          elements: {
            # Title Commands
            114 => { name: :new_game, type: :string },
            115 => { name: :continue, type: :string },
            117 => { name: :shutdown, type: :string },

            # Battle Menu Commands
            101 => { name: :battle_fight, type: :string },
            102 => { name: :battle_auto, type: :string },
            103 => { name: :battle_escape, type: :string },
            104 => { name: :battle_attack, type: :string },
            105 => { name: :battle_defend, type: :string },
            106 => { name: :battle_item, type: :string },
            107 => { name: :battle_skill, type: :string },
            108 => { name: :battle_equipment, type: :string },
            110 => { name: :battle_save, type: :string },
            112 => { name: :battle_end_game, type: :string },

            # Save/Load Related
            146 => { name: :save_file_select, type: :string },
            147 => { name: :load_file_select, type: :string },
            148 => { name: :file, type: :string },
            151 => { name: :end_game_confirm, type: :string },
            152 => { name: :yes, type: :string },
            153 => { name: :no, type: :string },

            # Status Terms
            123 => { name: :level, type: :string },
            124 => { name: :hp, type: :string },
            125 => { name: :mp, type: :string },
            126 => { name: :normal_status, type: :string },
            127 => { name: :exp_short, type: :string },
            128 => { name: :level_short, type: :string },
            129 => { name: :hp_short, type: :string },
            130 => { name: :mp_short, type: :string },
            131 => { name: :mp_cost, type: :string },
            132 => { name: :attack, type: :string },
            133 => { name: :defense, type: :string },
            134 => { name: :mind, type: :string },
            135 => { name: :agility, type: :string },
            136 => { name: :weapon, type: :string },
            137 => { name: :shield, type: :string },
            138 => { name: :armor, type: :string },
            139 => { name: :helmet, type: :string },
            140 => { name: :accessory, type: :string },
          }
        },
        22 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%82%B7%E3%82%B9%E3%83%86%E3%83%A0
          name: :system, type: :Array1D,
          elements: {
            17 => { name: :title, type: :string },
            # System/ graphic that supplies the window skin (background, frame
            # border and selection cursor).
            19 => { name: :system_graphic, type: :string }
          }
        },
        23 => {
          name: :Switch, type: :Array2D,
          elements: {
            1 => {
              name: :name, type: :string, default: ''
            }
          }
        },
        24 => {
          name: :Variable, type: :Array2D,
          elements: {
            1 => {
              name: :name, type: :string, default: ''
            }
          }
        },
        26 => {
          name: :CommonEvent, type: :Array2D,
          elements: COMMON_EVENT
        },
        27 => {
          name: :CommonEvent2, type: :Array2D,
          elements: COMMON_EVENT
        },
        28 => {
          name: :CommonEvent3, type: :Array2D,
          elements: COMMON_EVENT
        },
        29 => {
          name: :CommonEvent4, type: :Array2D,
          elements: COMMON_EVENT
        },
        30 => {
          name: :BattleCommand, type: :Array2D,
          elements: {
          }
        },
        31 => {
          name: :Job, type: :Array2D,
          elements: {
          }
        },
        32 => {
          name: :Job, type: :Array2D,
          elements: {
          }
        },
        33 => {
          name: :BattleAnime2, type: :Array2D,
          elements: {
          }
        },
      },
    }

    MAP_TREE = [
      {
        name: :map_properties, type: :Array2D,
        elements: {
          1 => { name: :name, type: :string },
          2 => { name: :parent_map_id, type: :int },
          # Editor-only node depth / management data.
          3 => { name: :indentation, type: :int },
          # 0 = root, 1 = normal map, 2 = area.
          4 => { name: :type, type: :int, default: 1 },
          5 => { name: :x_scroll, type: :bool, default: false },
          6 => { name: :y_scroll, type: :bool, default: false },
          7 => { name: :node_extracted, type: :bool, default: false },
          11 => { name: :bgm_type, type: :int, default: 0 },
          12 => { name: :bgm, type: :Array1D, elements: BGM },
          21 => { name: :backdrop_type, type: :int, default: 0 },
          22 => { name: :backdrop_file, type: :string },
          31 => { name: :teleport, type: :int, default: 1 },
          32 => { name: :escape, type: :int, default: 1 },
          33 => { name: :save, type: :int, default: 1 },
          41 => { name: :enemy_groups, type: :Array2D, elements: {1 => { name: :enemy_group_id, type: :int, default: 1 }}},
          44 => { name: :encount_steps, type: :int, default: 25 },
          # Area bounds, only used by area nodes (type == 2): [X1, Y1, X2 + 1, Y2 + 1].
          51 => { name: :area, type: :int16_array, order: [:left, :top, :right, :bottom] },
        }
      },
      {
        name: :tree,
        type: :Tree,
      },
      {
        name: :initial,
        type: :Array1D,
        elements: {
          1 => { name: :initial_map_id, type: :int },
          2 => { name: :initial_x, type: :int },
          3 => { name: :initial_y, type: :int },

          11 => { name: :boat_map_id, type: :int },
          12 => { name: :boat_x, type: :int },
          13 => { name: :boat_y, type: :int },

          21 => { name: :ship_map_id, type: :int },
          22 => { name: :ship_x, type: :int },
          23 => { name: :ship_y, type: :int },

          31 => { name: :airship_map_id, type: :int },
          32 => { name: :airship_x, type: :int },
          33 => { name: :airship_y, type: :int },
        },
      },
    ]

    # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%9E%E3%83%83%E3%83%97
    #
    # Conditions that must hold for an event page to be active.
    MAP_EVENT_PAGE_CONDITION = {
      # Bit flags selecting which of the conditions below are enabled.
      1 => { name: :flags, type: :int, default: 0 },
      2 => { name: :switch_a_id, type: :int, default: 1 },
      3 => { name: :switch_b_id, type: :int, default: 1 },
      4 => { name: :variable_id, type: :int, default: 1 },
      5 => { name: :variable_value, type: :int, default: 0 },
      6 => { name: :item_id, type: :int, default: 1 },
      7 => { name: :actor_id, type: :int, default: 1 },
      8 => { name: :timer_sec, type: :int, default: 0 },
    }

    MOVE_ROUTE = {
      11 => { name: :command_size, type: :int, default: 0 },
      12 => { name: :commands, type: :event },
      21 => { name: :repeat, type: :bool, default: true },
      22 => { name: :skippable, type: :bool, default: false },
    }

    MAP_EVENT_PAGE = {
      2 => { name: :condition, type: :Array1D, elements: MAP_EVENT_PAGE_CONDITION },
      21 => { name: :charset_name, type: :string, default: '' },
      22 => { name: :charset_index, type: :int, default: 0 },
      # 2 = down, 4 = left, 6 = right, 8 = up.
      23 => { name: :direction, type: :int, default: 2 },
      24 => { name: :pattern, type: :int, default: 1 },
      25 => { name: :translucent, type: :bool, default: false },
      31 => { name: :move_type, type: :int, default: 0 },
      32 => { name: :move_frequency, type: :int, default: 3 },
      # Start condition: 0 = action key, 1 = touch by player, ...
      33 => { name: :trigger, type: :int, default: 0 },
      # Layer / priority: 0 = below, 1 = same, 2 = above the player.
      34 => { name: :layer, type: :int, default: 0 },
      35 => { name: :overlap_forbidden, type: :bool, default: false },
      36 => { name: :animation_type, type: :int, default: 0 },
      37 => { name: :move_speed, type: :int, default: 3 },
      41 => { name: :move_route, type: :Array1D, elements: MOVE_ROUTE },
      51 => { name: :event_command_size, type: :int, default: 0 },
      52 => { name: :event_commands, type: :event },
    }

    MAP_EVENT = {
      1 => { name: :name, type: :string, default: '' },
      2 => { name: :x, type: :int, default: 0 },
      3 => { name: :y, type: :int, default: 0 },
      5 => { name: :pages, type: :Array2D, elements: MAP_EVENT_PAGE },
    }

    MAP_UNIT = {
      name: :Map, type: :Array1D,
      elements: {
        1 => { name: :chipset_id, type: :int, default: 1 },
        2 => { name: :width, type: :int, default: 20 },
        3 => { name: :height, type: :int, default: 15 },
        # 0 = none, 1 = vertical, 2 = horizontal, 3 = both.
        11 => { name: :scroll_type, type: :int, default: 0 },
        31 => { name: :parallax_flag, type: :bool, default: false },
        32 => { name: :parallax_name, type: :string, default: '' },
        33 => { name: :parallax_loop_x, type: :bool, default: false },
        34 => { name: :parallax_loop_y, type: :bool, default: false },
        35 => { name: :parallax_autoloop_x, type: :bool, default: false },
        36 => { name: :parallax_sx, type: :int, default: 0 },
        37 => { name: :parallax_autoloop_y, type: :bool, default: false },
        38 => { name: :parallax_sy, type: :int, default: 0 },
        # width * height signed shorts, one tile id per cell.
        71 => { name: :lower_layer, type: :int16_array },
        72 => { name: :upper_layer, type: :int16_array },
        81 => { name: :events, type: :Array2D, elements: MAP_EVENT },
        91 => { name: :save_count, type: :int, default: 0 },
      }
    }

    # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%82%BB%E3%83%BC%E3%83%96%E3%83%87%E3%83%BC%E3%82%BF
    #
    # Snapshot of a hero or vehicle on the map. Vehicles reuse the same layout.
    SAVE_MOVABLE = {
      11 => { name: :map_id, type: :int },
      12 => { name: :x, type: :int },
      13 => { name: :y, type: :int },
      # 0 = down, 1 = right, 2 = up, 3 = left.
      22 => { name: :direction, type: :int },
      35 => { name: :animation_type, type: :int },
      37 => { name: :move_speed, type: :int },
      73 => { name: :charset_name, type: :string },
      75 => { name: :charset_index, type: :int },
    }

    SAVE_SYSTEM = {
      # 0 map, 1 menu, 2 battle, 3 shop, 4 name input, 5 save/load,
      # 6 title, 7 game over, 8 F9 debug menu.
      1 => { name: :scene, type: :int, default: 0 },
      11 => { name: :frame_count, type: :int },
      15 => { name: :system_graphic, type: :string },
      16 => { name: :wallpaper_type, type: :int },
      17 => { name: :font, type: :int },
      31 => { name: :switch_size, type: :int, default: 0 },
      32 => { name: :switches, type: :bool_array },
      33 => { name: :variable_size, type: :int, default: 0 },
      34 => { name: :variables, type: :int32_array },
      # 0 = normal, 1 = transparent.
      41 => { name: :message_transparent, type: :int, default: 0 },
      # 0 = top, 1 = middle, 2 = bottom.
      42 => { name: :message_position, type: :int, default: 2 },
      43 => { name: :message_prevent_overlap, type: :bool, default: true },
      44 => { name: :message_continue_events, type: :bool, default: false },
      51 => { name: :face_name, type: :string, default: '' },
      52 => { name: :face_index, type: :int, default: 0 },
      53 => { name: :face_right_position, type: :int, default: 0 },
      54 => { name: :face_flip, type: :bool, default: false },
      55 => { name: :transparent, type: :bool, default: false },
      # Overridden BGM/SE playback state. An empty file name means "use the
      # database value".
      71 => { name: :title_bgm, type: :Array1D, elements: BGM },
      72 => { name: :battle_bgm, type: :Array1D, elements: BGM },
      73 => { name: :battle_end_bgm, type: :Array1D, elements: BGM },
      74 => { name: :inn_bgm, type: :Array1D, elements: BGM },
      75 => { name: :current_bgm, type: :Array1D, elements: BGM },
      78 => { name: :stored_bgm, type: :Array1D, elements: BGM },
      79 => { name: :boat_bgm, type: :Array1D, elements: BGM },
      80 => { name: :ship_bgm, type: :Array1D, elements: BGM },
      81 => { name: :airship_bgm, type: :Array1D, elements: BGM },
      82 => { name: :gameover_bgm, type: :Array1D, elements: BGM },
      91 => { name: :cursor_se, type: :Array1D, elements: SE },
      92 => { name: :decision_se, type: :Array1D, elements: SE },
      93 => { name: :cancel_se, type: :Array1D, elements: SE },
      94 => { name: :buzzer_se, type: :Array1D, elements: SE },
      95 => { name: :battle_start_se, type: :Array1D, elements: SE },
      96 => { name: :escape_se, type: :Array1D, elements: SE },
      97 => { name: :enemy_attack_se, type: :Array1D, elements: SE },
      98 => { name: :enemy_damaged_se, type: :Array1D, elements: SE },
      99 => { name: :ally_damaged_se, type: :Array1D, elements: SE },
      100 => { name: :evasion_se, type: :Array1D, elements: SE },
      101 => { name: :enemy_death_se, type: :Array1D, elements: SE },
      102 => { name: :item_se, type: :Array1D, elements: SE },
      # Transition effects. A value of 0xff means "use the database value".
      111 => { name: :teleport_erase_transition, type: :int },
      112 => { name: :teleport_show_transition, type: :int },
      113 => { name: :battle_start_erase_transition, type: :int },
      114 => { name: :battle_start_show_transition, type: :int },
      115 => { name: :battle_end_erase_transition, type: :int },
      116 => { name: :battle_end_show_transition, type: :int },
      121 => { name: :teleport_allowed, type: :bool },
      122 => { name: :escape_allowed, type: :bool },
      123 => { name: :save_allowed, type: :bool },
      124 => { name: :menu_allowed, type: :bool },
      125 => { name: :battle_background, type: :string },
      131 => { name: :save_count, type: :int },
      132 => { name: :save_slot, type: :int, default: 1 },
    }

    # Fields shown on the file-select screen (chunk 100 of the save file). The
    # wiki lists them inline at the top of the save-data page.
    SAVE_TITLE = {
      1 => { name: :timestamp, type: :double },
      11 => { name: :hero_name, type: :string },
      12 => { name: :hero_level, type: :int },
      13 => { name: :hero_hp, type: :int },
      21 => { name: :face1_name, type: :string },
      22 => { name: :face1_index, type: :int, default: 0 },
      23 => { name: :face2_name, type: :string },
      24 => { name: :face2_index, type: :int, default: 0 },
      25 => { name: :face3_name, type: :string },
      26 => { name: :face3_index, type: :int, default: 0 },
      27 => { name: :face4_name, type: :string },
      28 => { name: :face4_index, type: :int, default: 0 },
    }

    SAVE_DATA = {
      name: :Save, type: :Array1D,
      elements: {
        100 => { name: :title, type: :Array1D, elements: SAVE_TITLE },
        101 => { name: :system, type: :Array1D, elements: SAVE_SYSTEM },
        104 => { name: :hero, type: :Array1D, elements: SAVE_MOVABLE },
        105 => { name: :boat, type: :Array1D, elements: SAVE_MOVABLE },
        106 => { name: :ship, type: :Array1D, elements: SAVE_MOVABLE },
        107 => { name: :airship, type: :Array1D, elements: SAVE_MOVABLE },
      }
    }
  end

  class File
    def initialize io
      @io = io
      h_len = LCF.read_ber io
      h = io.read h_len
      raise "Invalid header: #{h} (expected: #{header})" if h != header
      if schema.is_a? Array
        sections = LCF::Sections.new
        schema.each { |s| sections.add s[:name], LCF.read_section(io, s) }
        @root = sections
      else
        @root = LCF.const_get(schema[:type]).new io, schema
      end
    end

    def header; raise end
    def schema; raise end

    def method_missing sym, *args
      @root.send sym, *args
    end
  end

  class Database < File
    def header; "LcfDataBase" end
    def schema; LCF::Schema::DATABASE end
  end

  class MapTree < File
    def header; "LcfMapTree" end
    def schema; LCF::Schema::MAP_TREE end
  end

  class MapUnit < File
    def header; "LcfMapUnit" end
    def schema; LCF::Schema::MAP_UNIT end
  end

  class SaveData < File
    def header; "LcfSaveData" end
    def schema; LCF::Schema::SAVE_DATA end
  end
end
