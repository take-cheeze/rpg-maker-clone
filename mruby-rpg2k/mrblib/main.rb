class Object
  include RGSS
end

class RPG2k
  WIDTH = 320
  HEIGHT = 240

  def initialize args
    @db = LCF::Database.new File.open "#{GAME_DIR}/RPG_RT.ldb"
    # @map_tree = LCF::MapTree.new "#{GAME_DIR}/RPG_RT.lmt"

    @title = Sprite.new
    @title.bitmap = Bitmap.new "Title/#{@db.system.title}"

    @window = Sprite.new
    win_bmp = Bitmap.new 100, 100
    win_bmp.draw_text(0, 0, 100, 100, "test テスト")
    @window.bitmap = win_bmp
    @window.x = 100
    @window.y = 100
    @window.z = 100
  end

  def start
    loop do
      # Input.update
      Graphics.update
    end
  rescue RGSS::Timeout
  end
end
