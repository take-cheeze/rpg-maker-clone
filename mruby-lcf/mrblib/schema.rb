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
            17 => { name: :title, type: :string }
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
          3 => { name: :_reserved, type: :int },
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
          41 => { name: :enemy_groups, type: :Array2D, elements: {1 => { name: :enemy_group_id, type: :int }}},
          44 => { name: :encount_steps, type: :int, default: 25 },
          51 => { name: :area, type: :Araa },
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
  end

  class File
    def initialize io
      @io = io
      h_len = LCF.read_ber io
      h = io.read h_len
      raise "Invalid header: #{h} (expected: #{header})" if h != header
      if schema.is_a? Array
        @root = LCF.const_get(schema.first[:type]).new io, schema.first
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
    end

  class SaveData < File
    def header; "LcfSaveData" end
    end
end
