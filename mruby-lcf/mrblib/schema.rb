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
          name: :Term, type: :Array2D,
          elements: {
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
  end

  class File
    def initialize io
      @io = io
      h_len = LCF.read_ber io
      h = io.read h_len
      raise "Invalid header: #{h} (expected: #{header})" if h != header
      @root = LCF.const_get(schema[:type]).new io, schema
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
    end

  class MapUnit < File
    def header; "LcfMapUnit" end
    end

  class SaveData < File
    def header; "LcfSaveData" end
    end
end
