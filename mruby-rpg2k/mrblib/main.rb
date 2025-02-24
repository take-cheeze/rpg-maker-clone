class Object
  include RGSS
end

class RPG2k
  WIDTH = 320
  HEIGHT = 240

  module Scene
    class Base
      def initialize parent
        @db = parent.db
        @map_tree = parent.map_tree
      end
      def update ; end

      attr_reader :db, :map_tree
    end

    class Title < Base
      def initialize parent
        super parent

        @title = Sprite.new
        @title.bitmap = Bitmap.new "Title/#{db.system.title}"

        menu_items = [db.term.new_game, db.term.continue, db.term.shutdown]

        @window = Window.new 128, 148, 64, 64
        win_cont = Bitmap.new 64, 64
        win_cont.draw_text 0, 0, 12 * 4, 12
        @window.contents = win_cont
      end

      def update
      end
    end
  end

  attr_reader :db, :map_tree

  def initialize args
    @db = LCF::Database.new File.open "#{GAME_DIR}/RPG_RT.ldb"
    @map_tree = LCF::MapTree.new File.open "#{GAME_DIR}/RPG_RT.lmt"
    @scenes = []
    push Scene::Title.new self
  end

  def push scene
    @scenes.push scene
  end

  def start
    loop do
      @scenes.last.update
      Input.update
      Graphics.update
    end
  rescue RGSS::Timeout
  end
end
